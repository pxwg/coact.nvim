(* The Coact chat-workspace language server.

   Standard requests serve Org card navigation and diagnostics; the coact/*
   requests expose conversation export and structural edit plans to
   coact.nvim. Messages use JSON-RPC over stdio with Content-Length framing.
   Positions are UTF-16 code units, as LSP requires. *)
open Coact_zk

module J = Yojson.Safe

(* ---- framing ---- *)

let read_message ic =
  let rec headers length =
    match In_channel.input_line ic with
    | None -> None
    | Some line ->
        let line = String.trim line in
        if line = "" then length
        else
          let lower = String.lowercase_ascii line in
          let prefix = "content-length:" in
          if String.starts_with ~prefix lower then
            let v = String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)) in
            headers (int_of_string_opt v)
          else headers length
  in
  match headers None with
  | None -> None
  | Some n -> ( try Some (really_input_string ic n) with End_of_file -> None)

let write_lock = Mutex.create ()

let send json =
  let body = J.to_string json in
  Mutex.lock write_lock;
  Printf.printf "Content-Length: %d\r\n\r\n%s" (String.length body) body;
  flush stdout;
  Mutex.unlock write_lock

let respond id result = send (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ])

let respond_error id code message =
  send
    (`Assoc
      [ ("jsonrpc", `String "2.0"); ("id", id);
        ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]) ])

let notify meth params =
  send (`Assoc [ ("jsonrpc", `String "2.0"); ("method", `String meth); ("params", params) ])

(* ---- json helpers ---- *)

let member k = function `Assoc f -> ( match List.assoc_opt k f with Some v -> v | None -> `Null) | _ -> `Null
let str = function `String s -> Some s | _ -> None
let int = function `Int i -> Some i | `Float f -> Some (int_of_float f) | _ -> None
let bool = function `Bool b -> Some b | _ -> None
let list = function `List l -> l | _ -> []
let opt_str = function Some s -> `String s | None -> `Null

exception Request_failed of string

let fail fmt = Printf.ksprintf (fun s -> raise (Request_failed s)) fmt

(* ---- uris and paths ---- *)

let percent_decode s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '%' && i + 2 < n then (
      (match int_of_string_opt ("0x" ^ String.sub s (i + 1) 2) with
      | Some c -> Buffer.add_char b (Char.chr c)
      | None -> Buffer.add_string b (String.sub s i 3));
      go (i + 3))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

let percent_encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' -> Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let normalize path = try Unix.realpath path with Unix.Unix_error _ -> path

let path_of_uri uri =
  let prefix = "file://" in
  if not (String.starts_with ~prefix uri) then fail "Only file URIs are supported: %s" uri;
  percent_decode (String.sub uri (String.length prefix) (String.length uri - String.length prefix))

let uri_of_path path = "file://" ^ percent_encode path

(* ---- documents ---- *)

type doc = { text : string; version : int }

let root = ref (Sys.getcwd ())
let opened : (string, doc) Hashtbl.t = Hashtbl.create 16
let disk : (string, float * string) Hashtbl.t = Hashtbl.create 64

let rec scan dir acc =
  match Sys.readdir dir with
  | entries ->
      Array.fold_left
        (fun acc name ->
          let path = Filename.concat dir name in
          if String.length name > 0 && (name.[0] = '.' || name = "_build" || name = "node_modules") then acc
          else if Sys.is_directory path then scan path acc
          else if Filename.check_suffix name ".org" then path :: acc
          else acc)
        acc entries
  | exception Sys_error _ -> acc

let read_disk path =
  match Unix.stat path with
  | st -> (
      match Hashtbl.find_opt disk path with
      | Some (mtime, text) when mtime = st.st_mtime -> Some text
      | _ -> (
          match In_channel.with_open_bin path In_channel.input_all with
          | text ->
              Hashtbl.replace disk path (st.st_mtime, text);
              Some text
          | exception Sys_error _ -> None))
  | exception Unix.Unix_error _ -> None

let text_of path =
  match Hashtbl.find_opt opened path with Some d -> Some d.text | None -> read_disk path

let documents () =
  let paths = scan !root [] in
  let paths = Hashtbl.fold (fun p _ acc -> if List.mem p acc then acc else p :: acc) opened paths in
  List.sort compare paths
  |> List.filter_map (fun path -> Option.map (fun text -> { Workspace.path; text }) (text_of path))

let cache : (Workspace.document list * Workspace.t) option ref = ref None

(* Turn directives known to Neovim: Pi's commands and Neovim contexts. *)
let registry = ref Directive.empty

let set_registry params =
  let entries key =
    List.filter_map
      (fun e ->
        match str (member "name" e) with
        | Some name when name <> "" ->
            Some { Directive.name; description = Option.value ~default:"" (str (member "description" e)) }
        | _ -> None)
      (list (member key params))
  in
  registry := { Directive.commands = entries "commands"; contexts = entries "contexts" }

(* Directives of the user cards in a file. *)
let file_directives ws (f : Org.file) =
  List.concat_map
    (fun (c : Org.card) -> if Workspace.kind ws c.id = Some Model.User then Directive.in_card !registry f c else [])
    (Org.cards f)

let analysis () =
  let docs = documents () in
  match !cache with
  | Some (d, ws) when d = docs -> ws
  | _ ->
      let ws = Workspace.analyze docs in
      cache := Some (docs, ws);
      ws

(* ---- positions ---- *)

let line_starts text =
  let acc = ref [ 0 ] in
  String.iteri (fun i c -> if c = '\n' then acc := (i + 1) :: !acc) text;
  Array.of_list (List.rev !acc)

let utf16_units text start stop =
  let rec go i n =
    if i >= stop then n
    else
      let d = String.get_utf_8_uchar text i in
      let len = Uchar.utf_decode_length d in
      let code = Uchar.to_int (Uchar.utf_decode_uchar d) in
      go (i + len) (n + if code > 0xffff then 2 else 1)
  in
  go start 0

let position text offset =
  let offset = max 0 (min offset (String.length text)) in
  let starts = line_starts text in
  let rec find lo hi = if lo >= hi then lo else
      let mid = (lo + hi + 1) / 2 in
      if starts.(mid) <= offset then find mid hi else find lo (mid - 1)
  in
  let line = find 0 (Array.length starts - 1) in
  `Assoc [ ("line", `Int line); ("character", `Int (utf16_units text starts.(line) offset)) ]

let offset text pos =
  let line = Option.value ~default:0 (int (member "line" pos)) in
  let character = Option.value ~default:0 (int (member "character" pos)) in
  let starts = line_starts text in
  if line >= Array.length starts then String.length text
  else
    let stop = if line + 1 < Array.length starts then starts.(line + 1) - 1 else String.length text in
    let rec go i n =
      if i >= stop || n >= character then i
      else
        let d = String.get_utf_8_uchar text i in
        let code = Uchar.to_int (Uchar.utf_decode_uchar d) in
        go (i + Uchar.utf_decode_length d) (n + if code > 0xffff then 2 else 1)
    in
    go starts.(line) 0

let range text start stop = `Assoc [ ("start", position text start); ("end", position text stop) ]

let location (span : Ospero_core.Provenance.span) =
  match text_of span.file with
  | Some text -> Some (`Assoc [ ("uri", `String (uri_of_path span.file)); ("range", range text span.start span.stop) ])
  | None -> None

(* ---- request context ---- *)

let doc_path params = normalize (path_of_uri (Option.value ~default:"" (str (member "uri" (member "textDocument" params)))))

let doc_text path = match text_of path with Some t -> t | None -> fail "Unknown document %s" path

let doc_offset params =
  let path = doc_path params in
  (path, offset (doc_text path) (member "position" params))

let version path = match Hashtbl.find_opt opened path with Some d -> `Int d.version | None -> `Null

(* Group plan edits by file as {uri, version, exists, edits}. *)
let edits_json (edits : Plan.edit list) =
  let paths = List.sort_uniq compare (List.map (fun (e : Plan.edit) -> e.path) edits) in
  `List
    (List.map
       (fun path ->
         let text = text_of path in
         let t = Option.value ~default:"" text in
         `Assoc
           [
             ("uri", `String (uri_of_path path));
             ("path", `String path);
             ("version", version path);
             ("exists", `Bool (text <> None));
             ( "edits",
               `List
                 (List.filter_map
                    (fun (e : Plan.edit) ->
                      if e.path <> path then None
                      else
                        Some
                          (`Assoc
                            [
                              ("range", range t e.start e.stop);
                              ("newText", `String e.text);
                              ("startByte", `Int e.start);
                              ("stopByte", `Int e.stop);
                            ]))
                    edits) );
           ])
       paths)

let layout params =
  let l = member "layout" (member "labels" params) in
  let get k d = Option.value ~default:d (bool (member k l)) in
  let d = Plan.default_layout in
  {
    Plan.blank_before_heading = get "blank_before_heading" d.blank_before_heading;
    blank_after_drawer = get "blank_after_drawer" d.blank_after_drawer;
  }

let labels params =
  let l = member "labels" params in
  let get k d = Option.value ~default:d (str (member k l)) in
  let d = Plan.default_labels in
  {
    Plan.layout = layout params;
    question = get "question" d.question;
    answer = get "answer" d.answer;
    summary = get "summary" d.summary;
    trace = get "trace" d.trace;
    trace_source = get "trace_source" d.trace_source;
    sources = get "sources" d.sources;
    from = get "from" d.from;
    card = get "card" d.card;
  }

let ok_or = function Ok v -> v | Error e -> fail "%s" e

(* ---- diagnostics ---- *)

let published : (string, unit) Hashtbl.t = Hashtbl.create 16

let severity = function
  | Diagnostic.Error -> 1
  | Warning -> 2
  | Information -> 3
  | Hint -> 4

let all_diagnostics ws = ws.Workspace.diagnostics @ Thread.check ws @ Conversation.lint ws

let publish () =
  let ws = analysis () in
  let diags = all_diagnostics ws in
  let by_path = Hashtbl.create 16 in
  List.iter
    (fun (d : Diagnostic.t) ->
      Hashtbl.replace by_path d.span.file (d :: Option.value ~default:[] (Hashtbl.find_opt by_path d.span.file)))
    diags;
  let paths =
    Hashtbl.fold (fun p _ acc -> p :: acc) by_path []
    @ Hashtbl.fold (fun p _ acc -> p :: acc) published []
    |> List.sort_uniq compare
  in
  Hashtbl.reset published;
  List.iter
    (fun path ->
      let ds = List.rev (Option.value ~default:[] (Hashtbl.find_opt by_path path)) in
      if ds <> [] then Hashtbl.replace published path ();
      let text = Option.value ~default:"" (text_of path) in
      notify "textDocument/publishDiagnostics"
        (`Assoc
          [
            ("uri", `String (uri_of_path path));
            ( "diagnostics",
              `List
                (List.map
                   (fun (d : Diagnostic.t) ->
                     `Assoc
                       [
                         ("range", range text d.span.start d.span.stop);
                         ("severity", `Int (severity d.severity));
                         ("code", `String d.code);
                         ("source", `String "coact-zk");
                         ("message", `String d.message);
                       ])
                   ds) );
          ]))
    paths

let diagnostics_json ds =
  `List
    (List.map
       (fun (d : Diagnostic.t) ->
         let text = Option.value ~default:"" (text_of d.span.file) in
         `Assoc
           [
             ("uri", `String (uri_of_path d.span.file));
             ("range", range text d.span.start d.span.stop);
             ("severity", `Int (severity d.severity));
             ("message", `String d.message);
           ])
       ds)

(* ---- navigation ---- *)

type target = { target : string; span : Org.span }

let rec card_targets (c : Org.card) =
  List.concat_map
    (function
      | Org.Link l -> [ { target = l.target; span = l.span } ]
      | Include k | Trace k -> [ { target = k.target; span = k.span } ]
      | Card c -> card_targets c
      | Text _ -> [])
    c.items

let file_targets (f : Org.file) = List.concat_map card_targets f.cards

let target_at ws path off =
  match Workspace.file ws path with
  | None -> None
  | Some f -> List.find_opt (fun t -> t.span.start <= off && off < t.span.stop) (file_targets f)

let card_location ws id =
  match Workspace.find ws id with
  | Some (f, c) -> location { Ospero_core.Provenance.file = f.path; start = c.heading.start; stop = c.heading.stop }
  | None -> None

let kind_label ws id = match Workspace.kind ws id with Some k -> Model.kind_name k | None -> "card"

let excerpt ?(lines = 12) text =
  let ls = Line_diff.lines (Conversation.trim_text text) in
  let rec take n = function [] -> [] | x :: tl -> if n = 0 then [ "…" ] else x :: take (n - 1) tl in
  String.concat "\n" (take lines ls)

let card_markdown ws id =
  match Workspace.find ws id with
  | None -> Printf.sprintf "Unknown card %s" id
  | Some (f, c) ->
      let meta = Workspace.metadata ws id in
      let header = Printf.sprintf "**%s** · %s · %s" c.title (kind_label ws id) id in
      let thread =
        match meta.thread with
        | Some t -> Printf.sprintf "\n\nthread %s%s" t (if meta.pin then " · pinned" else "")
        | None -> ""
      in
      let body =
        if Workspace.kind ws id = Some Model.Trace then
          match Trace.record ws id with
          | Ok entries -> String.concat "\n" (Trace.readable entries)
          | Error e -> e
        else "```org\n" ^ excerpt (Org.own_text f c) ^ "\n```"
      in
      header ^ thread ^ "\n\n" ^ body

let directive_hover ws path off =
  match Workspace.file ws path with
  | None -> None
  | Some f ->
      List.find_map
        (fun (d : Directive.t) ->
          if d.start <= off && off < d.stop then
            let token = (match d.kind with Command -> "/" | Context -> "@") ^ d.name in
            let what = Directive.describe !registry d in
            Some
              (`Assoc
                 [
                   ( "contents",
                     `Assoc
                       [
                         ("kind", `String "markdown");
                         ( "value",
                           `String
                             (Printf.sprintf "**%s** · %s%s\n\nTakes effect once, when this card is the question being sent."
                                token (Directive.kind_name d.kind) (if what = "" then "" else "\n\n" ^ what)) );
                       ] );
                 ])
          else None)
        (file_directives ws f)

let hover params =
  let path, off = doc_offset params in
  let ws = analysis () in
  match directive_hover ws path off with
  | Some h -> h
  | None ->
  let id =
    match target_at ws path off with
    | Some t when Workspace.mem ws t.target -> Some t.target
    | _ -> (
        match Workspace.file ws path with
        | Some f -> (
            match Org.card_at f off with
            | Some c when off >= c.heading.start && off <= c.heading.stop -> Some c.id
            | _ -> None)
        | None -> None)
  in
  match id with
  | None -> `Null
  | Some id -> `Assoc [ ("contents", `Assoc [ ("kind", `String "markdown"); ("value", `String (card_markdown ws id)) ]) ]

let definition params =
  let path, off = doc_offset params in
  let ws = analysis () in
  match target_at ws path off with
  | Some t -> Option.value ~default:`Null (card_location ws t.target)
  | None -> `Null

let references params =
  let path, off = doc_offset params in
  let ws = analysis () in
  let id =
    match target_at ws path off with
    | Some t -> Some t.target
    | None -> Option.bind (Workspace.file ws path) (fun f -> Option.map (fun (c : Org.card) -> c.id) (Org.card_at f off))
  in
  match id with
  | None -> `List []
  | Some id ->
      `List
        (List.concat_map
           (fun (f : Org.file) ->
             List.filter_map (fun t -> if t.target = id then location t.span else None) (file_targets f))
           ws.files)

let symbol_kind ws id = match Workspace.kind ws id with
  | Some Model.User -> 24 (* Event *) | Some Assistant -> 12 (* Function *)
  | Some Synthesis -> 23 (* Struct *) | Some Trace -> 21 (* Null *) | None -> 3 (* Namespace *)

let document_symbols params =
  let path = doc_path params in
  let ws = analysis () in
  match Workspace.file ws path with
  | None -> `List []
  | Some f ->
      let rec symbol (c : Org.card) =
        `Assoc
          [
            ("name", `String (if c.title = "" then c.id else c.title));
            ("detail", `String (kind_label ws c.id));
            ("kind", `Int (symbol_kind ws c.id));
            ("range", range f.text c.start c.stop);
            ("selectionRange", range f.text c.heading.start c.heading.stop);
            ("children", `List (List.filter_map (function Org.Card c -> Some (symbol c) | _ -> None) c.items));
          ]
      in
      `List (List.map symbol f.cards)

let completion params =
  let path, off = doc_offset params in
  let text = doc_text path in
  let line_start = match String.rindex_from_opt text (max 0 (off - 1)) '\n' with Some i when off > 0 -> i + 1 | _ -> 0 in
  let prefix = String.sub text line_start (off - line_start) in
  let ws = analysis () in
  let ends_with_token token =
    match Str_find.last prefix token with Some i -> Some (String.sub prefix (i + String.length token) (String.length prefix - i - String.length token)) | None -> None
  in
  let card_items partial =
    List.concat_map
      (fun (f : Org.file) ->
        List.filter_map
          (fun (c : Org.card) ->
            if String.contains partial ']' || String.contains partial ' ' then None
            else
              Some
                (`Assoc
                   [
                     ("label", `String c.id);
                     ("detail", `String (c.title ^ " · " ^ kind_label ws c.id));
                     ("filterText", `String (c.id ^ " " ^ c.title));
                     ("kind", `Int 18 (* Reference *));
                   ]))
          (Org.cards f))
      ws.files
  in
  let directive_items sigil (entries : Directive.entry list) at kind =
    let start = position text (line_start + at) and stop = position text off in
    List.map
      (fun (e : Directive.entry) ->
        let token = sigil ^ e.name in
        `Assoc
          [
            ("label", `String token);
            ("filterText", `String token);
            ("detail", `String e.description);
            ("kind", `Int kind);
            ("textEdit", `Assoc [ ("range", `Assoc [ ("start", start); ("end", stop) ]); ("newText", `String (token ^ " ")) ]);
          ])
      entries
  in
  let token_chars ok s = String.for_all ok s in
  let command_at =
    let lead = let rec go i = if i < String.length prefix && (prefix.[i] = ' ' || prefix.[i] = '\t') then go (i + 1) else i in go 0 in
    if lead < String.length prefix && prefix.[lead] = '/'
       && token_chars (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | ':' | '-' -> true | _ -> false)
            (String.sub prefix (lead + 1) (String.length prefix - lead - 1))
    then Some lead
    else None
  in
  let context_at =
    match String.rindex_opt prefix '@' with
    | Some i
      when (i = 0 || prefix.[i - 1] = ' ' || prefix.[i - 1] = '\t' || prefix.[i - 1] = '(')
           && token_chars (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
                (String.sub prefix (i + 1) (String.length prefix - i - 1)) ->
        Some i
    | _ -> None
  in
  let upper = String.uppercase_ascii (String.trim prefix) in
  let items =
    match (command_at, context_at) with
    | Some at, _ when !registry.commands <> [] -> directive_items "/" !registry.commands at 3
    | _, Some at when !registry.contexts <> [] -> directive_items "@" !registry.contexts at 6
    | _ ->
    if String.starts_with ~prefix:":CONTEXT_KIND:" upper then
      List.map (fun (name, _) -> `Assoc [ ("label", `String name); ("kind", `Int 20) ]) Model.kinds
    else if String.starts_with ~prefix:":PIN:" upper then
      List.map (fun v -> `Assoc [ ("label", `String v); ("kind", `Int 12) ]) [ "true"; "false" ]
    else
      match ends_with_token "[[id:" with
      | Some partial -> card_items partial
      | None -> (
          match ends_with_token ":target " with
          | Some partial when String.starts_with ~prefix:"#+" (String.trim prefix) -> card_items partial
          | _ ->
              if String.trim prefix = "#+" || String.trim prefix = "#" then
                List.map
                  (fun k -> `Assoc [ ("label", `String k); ("insertText", `String (String.sub k 2 (String.length k - 2))); ("kind", `Int 14) ])
                  [ "#+zk_include: :target "; "#+coact_trace: :target "; "#+begin_zk :id "; "#+begin_src " ]
              else [])
  in
  `List items

(* ---- coact requests ---- *)

let now () = Unix.gettimeofday ()

let card_info ws id =
  let meta = Workspace.metadata ws id in
  `Assoc
    [
      ("id", `String id);
      ("title", `String (Workspace.title ws id));
      ("kind", opt_str (Option.map Model.kind_name meta.kind));
      ("thread", opt_str meta.thread);
      ("pin", `Bool meta.pin);
      ( "uri",
        match Workspace.find ws id with Some (f, _) -> `String (uri_of_path f.path) | None -> `Null );
      ( "line",
        match Workspace.find ws id with
        | Some (f, c) -> member "line" (position f.text c.start)
        | None -> `Null );
    ]

let coact_card params =
  let path, off = doc_offset params in
  let ws = analysis () in
  match Workspace.file ws path with
  | None -> `Null
  | Some f -> (
      match Org.card_at f off with
      | None -> `Null
      | Some c ->
          let main = Option.map (fun (t : Thread.t) -> card_info ws t.main) (Thread.main_of ws c.id) in
          ( match card_info ws c.id with
          | `Assoc fields -> `Assoc (fields @ [ ("main", Option.value ~default:`Null main) ])
          | j -> j ))

let threads _ =
  let ws = analysis () in
  `List (List.map (fun (t : Thread.t) -> card_info ws t.main) (Thread.all ws))

let pin params =
  let path, off = doc_offset params in
  let thread = match str (member "thread" params) with Some t -> t | None -> fail "pin needs a thread id" in
  let edits, main, thread = ok_or (Plan.pin (analysis ()) ~path ~offset:off ~thread ~now:(now ())) in
  `Assoc [ ("edits", edits_json edits); ("main", `String main); ("thread", `String thread) ]

let unpin params =
  let path, off = doc_offset params in
  let edits, main = ok_or (Plan.unpin (analysis ()) ~path ~offset:off) in
  `Assoc [ ("edits", edits_json edits); ("main", `String main) ]

let new_card params =
  let path = doc_path params in
  let text = doc_text path in
  let selection =
    match member "range" params with
    | `Null -> None
    | r ->
        let a = offset text (member "start" r) and b = offset text (member "end" r) in
        if b > a then Some (a, b) else None
  in
  let into = if bool (member "newFile" params) = Some true then Some !root else None in
  let edits, id, target =
    ok_or
      (Plan.new_card (analysis ()) ~path ?into ~selection ~title:(str (member "title" params)) (labels params)
         ~now:(now ()))
  in
  `Assoc [ ("edits", edits_json edits); ("id", `String id); ("uri", `String (uri_of_path target)) ]

let main_param params = match str (member "main" params) with Some m -> m | None -> fail "missing main card"

let submit params =
  let ws = analysis () in
  let main = main_param params in
  let thread = opt_str (Workspace.metadata ws main).thread in
  match ok_or (Plan.submit ws ~main (labels params) ~now:(now ())) with
  | Plan.Ready { edits; question; answer } ->
      `Assoc
        [ ("status", `String "ready"); ("edits", edits_json edits); ("question", `String question);
          ("answer", `String answer); ("main", `String main); ("thread", thread) ]
  | Draft { edits; draft } ->
      `Assoc [ ("status", `String "draft"); ("edits", edits_json edits); ("draft", `String draft); ("main", `String main) ]

let artifact params =
  let ws = analysis () in
  let main = main_param params in
  let baseline =
    match member "baseline" params with `Null -> None | b -> Some (Conversation.cards_of_json b)
  in
  let require_question = Option.value ~default:true (bool (member "requireQuestion" params)) in
  let versions =
    `Assoc (Hashtbl.fold (fun p (d : doc) acc -> (uri_of_path p, `Int d.version) :: acc) opened [])
  in
  match Conversation.export ws ~main { require_question; baseline; now = now () } with
  | Ok (a, ds) ->
      (* The artifact travels as a string so Neovim hands Pi exactly these
         messages; only the card texts are read on the way. *)
      let json = Conversation.to_json a in
      let directives =
        match Option.bind a.question (Workspace.find ws) with
        | Some (f, c) ->
            List.map
              (fun (d : Directive.t) ->
                `Assoc
                  [ ("kind", `String (Directive.kind_name d.kind)); ("name", `String d.name); ("args", `String d.args) ])
              (Directive.in_card !registry f c)
        | None -> []
      in
      `Assoc
        [
          ("ok", `Bool true);
          ("directives", `List directives);
          ("artifactJson", `String (J.to_string json));
          ("cards", member "cards" json);
          ("diagnostics", diagnostics_json ds);
          ("versions", versions);
        ]
  | Error ds -> `Assoc [ ("ok", `Bool false); ("diagnostics", diagnostics_json ds) ]

let answer params =
  let ws = analysis () in
  let id = match str (member "answer" params) with Some a -> a | None -> fail "missing answer card" in
  let main = match Thread.main_of ws id with Some t -> t.main | None -> "thread" in
  let trace_path = Filename.concat (Filename.concat !root "trace") (main ^ ".org") in
  let result =
    ok_or
      (Plan.answer ws ~answer:id
         ~text:(Option.value ~default:"" (str (member "text" params)))
         ~entries:
           (match str (member "entriesJson" params) with
           | Some s -> ( match J.from_string s with `List l -> l | _ -> fail "entriesJson is not a list")
           | None -> list (member "entries" params))
         ~trace_path (labels params) ~now:(now ()))
  in
  `Assoc
    [
      ("edits", edits_json result.edits);
      ("draft", opt_str result.draft);
      ("trace", opt_str result.trace);
      ("removed", `Bool result.removed);
    ]

let notes_json (notes : Plan.note list) =
  `List
    (List.map
       (fun (n : Plan.note) -> `Assoc [ ("path", `String n.path); ("anchor", `String n.anchor); ("note", `String n.note) ])
       notes)

let compact params =
  let ws = analysis () in
  let main = main_param params in
  let count = match int (member "count" params) with Some n -> n | None -> fail "missing count" in
  let summary = Option.value ~default:"" (str (member "summary" params)) in
  let edits, notes, id = ok_or (Plan.compact ws ~main ~count ~summary ~dir:!root (labels params) ~now:(now ())) in
  `Assoc [ ("edits", edits_json edits); ("notes", notes_json notes); ("synthesis", `String id) ]

(* ---- the agent's card tools ---- *)

(* The given thread, else the pinned one. *)
let thread_param ws params =
  match str (member "main" params) with
  | Some m when m <> "" -> m
  | _ -> (
      match Thread.pinned ws with
      | Some t -> t.main
      | None -> fail "No thread is pinned; give a main card ID")

let thread_view params =
  let ws = analysis () in
  ok_or (Query.thread_view ws ~main:(thread_param ws params))

let id_param params = match str (member "id" params) with Some id -> id | None -> fail "missing card id"

let card_read params =
  ok_or
    (Query.card_read (analysis ()) ~id:(id_param params)
       ~offset:(Option.value ~default:1 (int (member "offset" params)))
       ~limit:(Option.value ~default:200 (int (member "limit" params)))
       ~raw:(bool (member "raw" params) = Some true))

let card_search params =
  Query.card_search (analysis ())
    ~query:(Option.value ~default:"" (str (member "query" params)))
    ~limit:(Option.value ~default:20 (int (member "limit" params)))

let card_create params =
  let kind =
    match str (member "kind" params) with
    | None | Some "" | Some "note" -> None
    | Some k -> (
        match List.assoc_opt k Model.kinds with Some k -> Some k | None -> fail "kind must be user, assistant, synthesis, trace or note")
  in
  let edit, id, path =
    ok_or
      (Plan.create (analysis ()) ~layout:(layout params) ~dir:!root
         ~title:(Option.value ~default:"" (str (member "title" params)))
         ~kind ~body:(Option.value ~default:"" (str (member "body" params))) ~now:(now ()))
  in
  `Assoc [ ("edits", edits_json [ edit ]); ("id", `String id); ("path", `String path) ]

let card_edit params =
  let replacements =
    List.map
      (fun e ->
        match (str (member "oldText" e), str (member "newText" e)) with
        | Some o, Some n -> (o, n)
        | _ -> fail "each edit needs oldText and newText")
      (list (member "edits" params))
  in
  `Assoc [ ("edits", edits_json (ok_or (Plan.edit ~layout:(layout params) (analysis ()) ~id:(id_param params) replacements))) ]

let thread_arrange params =
  let ws = analysis () in
  let main = thread_param ws params in
  let ids = List.filter_map str (list (member "items" params)) in
  let edits, notes = ok_or (Plan.arrange ~layout:(layout params) ws ~main ids) in
  `Assoc [ ("edits", edits_json edits); ("notes", notes_json notes); ("main", `String main) ]

(* Error diagnostics of the whole workspace, for reports after a change. *)
let errors _ =
  let ws = analysis () in
  diagnostics_json (List.filter Diagnostic.is_error (all_diagnostics ws))

(* Assistant text the user has revised, against the recorded answer. *)
let human_edits ws (f : Org.file) (c : Org.card) =
  match Workspace.body ws c.id with
  | None -> []
  | Some body -> (
      let trace =
        List.find_map
          (fun (x : _ Ospero_core.Provenance.located) ->
            match x.value with
            | Ospero_core.Observation.Observed.Consume (Frontend.Link { target; _ })
              when Workspace.kind ws (Ospero_core.Graph.Vertex_id.to_string target) = Some Model.Trace ->
                Some (Ospero_core.Graph.Vertex_id.to_string target)
            | _ -> None)
          body
      in
      match Option.map (Trace.record ws) trace with
      | Some (Ok entries) -> (
          match Trace.final_answer entries with
          | None -> []
          | Some message ->
              let original = Line_diff.lines (Org_text.of_markdown (Trace.text message)) in
              (* Own lines of the card, with their offsets, skipping trace links. *)
              let own =
                let acc = ref [] in
                let pos = ref c.content_start in
                let stop = match List.find_map (function Org.Card k -> Some k.start | _ -> None) c.items with Some s -> s | None -> c.stop in
                while !pos < stop do
                  let e = match String.index_from_opt f.text !pos '\n' with Some e when e < stop -> e | _ -> stop in
                  let line = String.sub f.text !pos (e - !pos) in
                  let is_trace_link =
                    match trace with
                    | Some t -> String.starts_with ~prefix:("[[id:" ^ t ^ "]") (String.trim line)
                    | None -> false
                  in
                  if not is_trace_link then acc := (line, !pos, e) :: !acc;
                  pos := e + 1
                done;
                List.rev !acc
              in
              let own =
                let blank (l, _, _) = String.trim l = "" in
                let rec drop = function x :: tl when blank x -> drop tl | l -> l in
                List.rev (drop (List.rev (drop own)))
              in
              let current = List.map (fun (l, _, _) -> l) own in
              let changed = Line_diff.inserted original current in
              List.filter_map
                (fun i ->
                  let l, s, e = List.nth own i in
                  if String.trim l = "" then None else Some (s, e))
                changed)
      | _ -> [])

let decorations params =
  let path = doc_path params in
  let ws = analysis () in
  match Workspace.file ws path with
  | None -> `Assoc [ ("cards", `List []); ("edited", `List []) ]
  | Some f ->
      let cards = Org.cards f in
      let edited =
        List.concat_map
          (fun (c : Org.card) -> if Workspace.kind ws c.id = Some Model.Assistant then human_edits ws f c else [])
          cards
      in
      let origin (c : Org.card) =
        match Workspace.kind ws c.id with
        | Some Model.Assistant ->
            if List.exists (fun (s, _) -> s >= c.content_start && s < c.stop) edited then "agent+user" else "agent"
        | Some Model.Trace -> "agent"
        | _ -> "user"
      in
      `Assoc
        [
          ( "cards",
            `List
              (List.map
                 (fun (c : Org.card) ->
                   let meta = Workspace.metadata ws c.id in
                   `Assoc
                     [
                       ("id", `String c.id);
                       ("kind", opt_str (Option.map Model.kind_name meta.kind));
                       ("line", member "line" (position f.text c.start));
                       ("pin", `Bool meta.pin);
                       ("thread", opt_str meta.thread);
                       ("origin", `String (origin c));
                     ])
                 cards) );
          ("edited", `List (List.map (fun (s, e) -> range f.text s e) edited));
          ( "directives",
            `List
              (List.map
                 (fun (d : Directive.t) ->
                   `Assoc [ ("range", range f.text d.start d.stop); ("kind", `String (Directive.kind_name d.kind)) ])
                 (file_directives ws f)) );
        ]

let trace params =
  let ws = analysis () in
  let id =
    match str (member "id" params) with
    | Some id -> id
    | None -> (
        let path, off = doc_offset params in
        match target_at ws path off with
        | Some t when Workspace.kind ws t.target = Some Model.Trace -> t.target
        | _ -> (
            match Option.bind (Workspace.file ws path) (fun f -> Org.card_at f off) with
            | Some c when Workspace.kind ws c.id = Some Model.Trace -> c.id
            | _ -> fail "Place the cursor on a trace card or a link to one"))
  in
  let entries = ok_or (Trace.record ws id) in
  `Assoc [ ("id", `String id); ("title", `String (Workspace.title ws id)); ("lines", `List (List.map (fun l -> `String l) (Trace.readable entries))) ]

let locate params =
  match str (member "id" params) with
  | Some id -> Option.value ~default:`Null (card_location (analysis ()) id)
  | None -> `Null

(* ---- dispatch ---- *)

let shutdown_requested = ref false

let initialize params =
  (match str (member "rootUri" params) with
  | Some uri -> root := normalize (path_of_uri uri)
  | None -> ( match str (member "rootPath" params) with Some p -> root := normalize p | None -> ()));
  `Assoc
    [
      ( "capabilities",
        `Assoc
          [
            ( "textDocumentSync",
              `Assoc [ ("openClose", `Bool true); ("change", `Int 1); ("save", `Assoc [ ("includeText", `Bool false) ]) ] );
            ("hoverProvider", `Bool true);
            ("definitionProvider", `Bool true);
            ("referencesProvider", `Bool true);
            ("documentSymbolProvider", `Bool true);
            ("completionProvider", `Assoc [ ("triggerCharacters", `List [ `String ":"; `String "+"; `String "/"; `String "@" ]) ]);
          ] );
      ("serverInfo", `Assoc [ ("name", `String "coact-zk-lsp"); ("version", `String "0.1.0") ]);
    ]

let did_open params =
  let td = member "textDocument" params in
  let path = normalize (path_of_uri (Option.value ~default:"" (str (member "uri" td)))) in
  Hashtbl.replace opened path
    { text = Option.value ~default:"" (str (member "text" td)); version = Option.value ~default:0 (int (member "version" td)) };
  publish ()

let did_change params =
  let td = member "textDocument" params in
  let path = normalize (path_of_uri (Option.value ~default:"" (str (member "uri" td)))) in
  match List.rev (list (member "contentChanges" params)) with
  | last :: _ ->
      Hashtbl.replace opened path
        { text = Option.value ~default:"" (str (member "text" last)); version = Option.value ~default:0 (int (member "version" td)) };
      publish ()
  | [] -> ()

let did_close params =
  let path = doc_path params in
  Hashtbl.remove opened path;
  publish ()

let requests =
  [
    ("initialize", initialize);
    ("shutdown", fun _ -> shutdown_requested := true; `Null);
    ("textDocument/hover", hover);
    ("textDocument/definition", definition);
    ("textDocument/references", references);
    ("textDocument/documentSymbol", document_symbols);
    ("textDocument/completion", completion);
    ("coact/card", coact_card);
    ("coact/threads", threads);
    ("coact/pin", pin);
    ("coact/unpin", unpin);
    ("coact/new", new_card);
    ("coact/submit", submit);
    ("coact/artifact", artifact);
    ("coact/answer", answer);
    ("coact/compact", compact);
    ("coact/decorations", decorations);
    ("coact/trace", trace);
    ("coact/locate", locate);
    ("coact/thread_view", thread_view);
    ("coact/card_read", card_read);
    ("coact/card_search", card_search);
    ("coact/card_create", card_create);
    ("coact/card_edit", card_edit);
    ("coact/thread_arrange", thread_arrange);
    ("coact/errors", errors);
  ]

let notifications =
  [
    ("textDocument/didOpen", did_open);
    ("textDocument/didChange", did_change);
    ("textDocument/didClose", did_close);
    ("textDocument/didSave", fun _ -> publish ());
    ("workspace/didChangeWatchedFiles", fun _ -> publish ());
    ("coact/refresh", fun _ -> publish ());
    ("coact/registry", set_registry);
  ]

let handle json =
  let meth = Option.value ~default:"" (str (member "method" json)) in
  let params = member "params" json in
  match member "id" json with
  | `Null -> (
      if meth = "exit" then exit (if !shutdown_requested then 0 else 1);
      match List.assoc_opt meth notifications with
      | Some f -> ( try f params with e -> prerr_endline ("coact-zk-lsp: " ^ Printexc.to_string e))
      | None -> ())
  | id -> (
      match List.assoc_opt meth requests with
      | None -> respond_error id (-32601) ("Method not found: " ^ meth)
      | Some f -> (
          match f params with
          | result -> respond id result
          | exception Request_failed message -> respond_error id (-32803) message
          | exception e -> respond_error id (-32603) (Printexc.to_string e)))

(* ---- index mode: coact-zk-lsp --index <root> ---- *)

(* Every card of a workspace as JSON, for pickers outside any open buffer. *)
let index dir =
  root := normalize dir;
  let ws = analysis () in
  let first_line text =
    Line_diff.lines (Conversation.trim_text text)
    |> List.find_opt (fun l -> let t = String.trim l in t <> "" && not (String.starts_with ~prefix:"#+" t))
    |> Option.map String.trim
  in
  let shorten n s = if String.length s <= n then s else String.sub s 0 n in
  let card (f : Org.file) (c : Org.card) =
    let meta = Workspace.metadata ws c.id in
    let top = List.exists (fun (r : Org.card) -> r.id = c.id && r.start = c.start) f.cards in
    let own = Org.own_text f c in
    (* For a thread, the latest question that has text. *)
    let last_question =
      List.fold_left
        (fun acc -> function
          | Org.Card q when (Workspace.metadata ws q.id).kind = Some Model.User -> (
              match Org_text.headline (Org.own_text f q) with "" -> acc | l -> Some l)
          | _ -> acc)
        None c.items
    in
    let turns =
      List.length
        (List.filter
           (function Org.Card q -> (Workspace.metadata ws q.id).kind = Some Model.Assistant | _ -> false)
           c.items)
    in
    `Assoc
      [
        ("id", `String c.id);
        ("title", `String c.title);
        ("kind", opt_str (Option.map Model.kind_name meta.kind));
        ("thread", opt_str meta.thread);
        ("pin", `Bool meta.pin);
        ("path", `String f.path);
        ("line", member "line" (position f.text c.start));
        ("preview", opt_str (first_line own));
        ("text", `String (shorten 2000 (Conversation.trim_text own)));
        ("last", opt_str last_question);
        ("turns", `Int turns);
        ("top", `Bool top);
        (* A root card is found by any text of its subtree. *)
        ( "subtree",
          if top then `String (shorten 20000 (Conversation.trim_text (Org.sub f.text c.content_start c.stop))) else `Null );
      ]
  in
  let cards = List.concat_map (fun (f : Org.file) -> List.map (card f) (Org.cards f)) ws.files in
  print_string (J.to_string (`Assoc [ ("root", `String !root); ("cards", `List cards) ]));
  exit 0

let () =
  (match Array.to_list Sys.argv with
  | _ :: "--index" :: dir :: _ -> index dir
  | _ -> ());
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let rec loop () =
    match read_message stdin with
    | None -> ()
    | Some body ->
        (match J.from_string body with
        | json -> handle json
        | exception Yojson.Json_error e -> prerr_endline ("coact-zk-lsp: invalid JSON: " ^ e));
        loop ()
  in
  loop ()
