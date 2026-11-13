module Graph = Ospero_core.Graph
module Obs = Ospero_core.Observation
module Prov = Ospero_core.Provenance

type source = { item : int; card : string; role : string }
type item = { card : string; title : string; kind : Model.kind option; included : bool }
type card_text = { id : string; title : string; kind : string option; text : string }

type artifact = {
  main : string;
  thread : string option;
  messages : Yojson.Safe.t list;
  sources : source list;
  items : item list;
  cards : card_text list;
  question : string option;
}

type options = { require_question : bool; baseline : card_text list option; now : float }

let vid = Graph.Vertex_id.to_string

type state = {
  ws : Workspace.t;
  now_ms : int;
  mutable diagnostics : Diagnostic.t list;
}

let report st ?(severity = Diagnostic.Error) ~code span message =
  if not (List.exists (fun (d : Diagnostic.t) -> d.span = span && d.code = code) st.diagnostics) then
    st.diagnostics <- Diagnostic.make ~severity ~code span message :: st.diagnostics

let heading_span ws id =
  match Workspace.find ws id with
  | Some (f, c) -> Some { Prov.file = f.path; start = c.heading.start; stop = c.heading.stop }
  | None -> None

let report_card st ?severity ~code id message =
  Option.iter (fun span -> report st ?severity ~code span message) (heading_span st.ws id)

(* Strip blank leading and trailing lines and trailing whitespace. *)
let trim_text text =
  let lines = Line_diff.lines text in
  let blank l = String.trim l = "" in
  let rec drop = function l :: tl when blank l -> drop tl | l -> l in
  let lines = List.rev (drop (List.rev (drop lines))) in
  let rstrip l =
    let n = String.length l in
    let rec go i = if i > 0 && (l.[i - 1] = ' ' || l.[i - 1] = '\t' || l.[i - 1] = '\r') then go (i - 1) else i in
    String.sub l 0 (go n)
  in
  String.concat "\n" (List.map rstrip lines)

let is_trace st id = Workspace.kind st.ws id = Some Model.Trace

let rec render st ~stack ~depth ~strip_traces id =
  match Workspace.body st.ws id with
  | None -> ""
  | Some body ->
      let buf = Buffer.create 256 in
      List.iter
        (fun (c : _ Prov.located) ->
          let at code message = Option.iter (fun span -> report st ~code span message) c.span in
          match c.value with
          | Obs.Observed.Text s -> Buffer.add_string buf s
          | Consume (Frontend.Link { target; source }) ->
              if not (strip_traces && is_trace st (vid target)) then Buffer.add_string buf source
          | Consume (Unresolved { target; form; source }) -> (
              match form with
              | Cited ->
                  Option.iter
                    (fun span ->
                      report st ~severity:Diagnostic.Warning ~code:"unresolved-link" span
                        ("Unknown card " ^ target))
                    c.span;
                  Buffer.add_string buf source
              | Included -> at "unresolved-include" ("Cannot transclude unknown card " ^ target)
              | Traced -> at "unresolved-trace" ("Unknown trace source " ^ target))
          | Consume (Include t | Child t) ->
              let t = vid t in
              if List.mem t stack then at "include-cycle" ("Transclusion cycle through " ^ t)
              else
                let inner = trim_text (render st ~stack:(t :: stack) ~depth:(depth + 1) ~strip_traces:false t) in
                Buffer.add_string buf
                  (Printf.sprintf "%s %s\n%s%s" (String.make (depth + 1) '*') (Workspace.title st.ws t) inner
                     (if inner = "" then "" else "\n"))
          | Consume (Trace t) -> (
              match Trace.record st.ws (vid t) with
              | Ok entries -> Buffer.add_string buf (String.concat "\n" (Trace.readable entries) ^ "\n")
              | Error e -> at "trace" e))
        body;
      Buffer.contents buf

let text_block text = `Assoc [ ("type", `String "text"); ("text", `String text) ]

let user st text =
  `Assoc [ ("role", `String "user"); ("content", `List [ text_block text ]); ("timestamp", `Int st.now_ms) ]

let custom st kind text =
  `Assoc
    [
      ("role", `String "custom");
      ("customType", `String kind);
      ("content", `String text);
      ("display", `Bool true);
      ("timestamp", `Int st.now_ms);
    ]

let zero_usage =
  let cost = `Assoc (List.map (fun k -> (k, `Int 0)) [ "input"; "output"; "cacheRead"; "cacheWrite"; "total" ]) in
  `Assoc
    (List.map (fun k -> (k, `Int 0)) [ "input"; "output"; "cacheRead"; "cacheWrite"; "totalTokens" ]
    @ [ ("cost", cost) ])

let member key = function `Assoc f -> List.assoc_opt key f | _ -> None

(* The card's text replaces the recorded answer; model fields are kept so
   Pi treats the turn as the original provider's. *)
let assistant st ~template text =
  let field key default =
    match Option.bind template (member key) with Some v -> v | None -> default
  in
  `Assoc
    [
      ("role", `String "assistant");
      ("content", `List [ text_block text ]);
      ("api", field "api" (`String "coact"));
      ("provider", field "provider" (`String "coact"));
      ("model", field "model" (`String "coact-card"));
      ("usage", zero_usage);
      ("stopReason", `String "stop");
      ("timestamp", field "timestamp" (`Int st.now_ms));
    ]

let entry_key (e : Trace.entry) =
  match e.id with Some id -> id | None -> Yojson.Safe.to_string e.message

(* Trace cards linked from an assistant card, in body order. *)
let trace_links st id =
  match Workspace.body st.ws id with
  | None -> []
  | Some body ->
      List.filter_map
        (fun (c : _ Prov.located) ->
          match c.value with
          | Obs.Observed.Consume (Frontend.Link { target; _ }) when is_trace st (vid target) ->
              Some (vid target, c.span)
          | _ -> None)
        body

let consume st ~main =
  let body = Option.value ~default:[] (Workspace.body st.ws main) in
  let items =
    List.filter_map
      (fun (c : _ Prov.located) ->
        match c.value with
        | Obs.Observed.Consume (Frontend.Child t) -> Some (vid t, false)
        | Consume (Include t) -> Some (vid t, true)
        | Consume (Unresolved { target; form = Included; _ }) ->
            Option.iter (fun span -> report st ~code:"unresolved-include" span ("Cannot transclude unknown card " ^ target)) c.span;
            None
        | _ -> None)
      body
  in
  if items <> [] then
    List.iter
      (fun (c : _ Prov.located) ->
        match c.value with
        | Obs.Observed.Text s when String.trim s <> "" ->
            Option.iter
              (fun span ->
                report st ~severity:Diagnostic.Hint ~code:"outside-conversation" span
                  "Text outside conversation cards is not sent to the model")
              c.span
        | _ -> ())
      body;
  let seen = Hashtbl.create 16 in
  let messages = ref [] in
  let add item card role message = messages := (message, { item; card; role }) :: !messages in
  let texts = ref [] in
  List.iteri
    (fun index (card, _) ->
      let kind = Workspace.kind st.ws card in
      let title = Workspace.title st.ws card in
      let text strip = trim_text (render st ~stack:[ card; main ] ~depth:0 ~strip_traces:strip card) in
      let remember text = texts := { id = card; title; kind = Option.map Model.kind_name kind; text } :: !texts in
      match kind with
      | Some Model.User ->
          let t = text false in
          remember t;
          if t <> "" then add index card "user" (user st t)
      | Some Assistant ->
          let template = ref None in
          List.iter
            (fun (trace, span) ->
              match Trace.record st.ws trace with
              | Error e -> Option.iter (fun span -> report st ~code:"trace" span e) span
              | Ok entries ->
                  if !template = None then template := Trace.final_answer entries;
                  List.iter
                    (fun (e : Trace.entry) ->
                      let key = entry_key e in
                      if not (Hashtbl.mem seen key) then (
                        Hashtbl.add seen key ();
                        add index card (Option.value ~default:"" (Trace.role e.message)) e.message))
                    (Trace.process entries))
            (trace_links st card);
          let t = text true in
          remember t;
          if t <> "" then add index card "assistant" (assistant st ~template:!template t)
      | Some Synthesis ->
          let t = text false in
          remember t;
          if t <> "" then
            add index card "custom"
              (custom st "coact.synthesis"
                 (Printf.sprintf "Synthesis card \"%s\" (knowledge distilled from earlier discussion):\n\n%s" title t))
      | Some Trace -> (
          match Trace.record st.ws card with
          | Error e -> report_card st ~code:"trace" card e
          | Ok entries ->
              List.iter
                (fun (e : Trace.entry) ->
                  let key = entry_key e in
                  if not (Hashtbl.mem seen key) then (
                    Hashtbl.add seen key ();
                    match Trace.role e.message with
                    | Some ("assistant" | "toolResult" as role) -> add index card role e.message
                    | _ -> ()))
                entries)
      | None ->
          report_card st ~severity:Diagnostic.Warning ~code:"no-kind" card
            "Card without CONTEXT_KIND is sent as reference material";
          let t = text false in
          remember t;
          if t <> "" then
            add index card "custom" (custom st "coact.note" (Printf.sprintf "Reference card \"%s\":\n\n%s" title t)))
    items;
  let messages = List.rev !messages in
  (* Tool results must answer an earlier call; orphans are dropped. *)
  let calls = Hashtbl.create 16 in
  let messages =
    List.filter
      (fun (m, (s : source)) ->
        (match member "content" m with
        | Some (`List blocks) when s.role = "assistant" ->
            List.iter
              (fun b ->
                match (member "type" b, member "id" b) with
                | Some (`String "toolCall"), Some (`String id) -> Hashtbl.replace calls id ()
                | _ -> ())
              blocks
        | _ -> ());
        match (s.role, member "toolCallId" m) with
        | "toolResult", Some (`String id) when not (Hashtbl.mem calls id) ->
            report_card st ~severity:Diagnostic.Warning ~code:"orphan-result" s.card
              ("Recorded tool result " ^ id ^ " has no preceding call and is left out");
            false
        | _ -> true)
      messages
  in
  let items =
    List.map
      (fun (card, included) ->
        { card; title = Workspace.title st.ws card; kind = Workspace.kind st.ws card; included })
      items
  in
  (items, messages, List.rev !texts)

let revision ~baseline ~current ~question =
  let find id l = List.find_opt (fun (c : card_text) -> c.id = id) l in
  let changes =
    List.filter_map
      (fun (c : card_text) ->
        if Some c.id = question then None
        else
          match find c.id baseline with
          | None -> Some (Printf.sprintf "Added card \"%s\"." c.title)
          | Some old -> (
              match Line_diff.unified (Line_diff.lines old.text) (Line_diff.lines c.text) with
              | None -> None
              | Some diff -> Some (Printf.sprintf "Revised card \"%s\":\n%s" c.title (String.trim diff))))
      current
    @ List.filter_map
        (fun (c : card_text) ->
          if find c.id current = None then Some (Printf.sprintf "Removed card \"%s\"." c.title) else None)
        baseline
  in
  if changes = [] then None
  else
    Some
      ("Since your last reply the user revised the conversation cards. The current text is authoritative; the changes are:\n\n"
      ^ String.concat "\n\n" changes)

let export ws ~main options =
  let st = { ws; now_ms = int_of_float (options.now *. 1000.); diagnostics = [] } in
  let fail message =
    match heading_span ws main with
    | Some span -> Error [ Diagnostic.make ~code:"export" span message ]
    | None -> Error []
  in
  if ws.Workspace.observation = None then fail "The workspace has errors; fix them before sending"
  else if not (Workspace.mem ws main) then fail ("Unknown card " ^ main)
  else
    let structure = List.filter Diagnostic.is_error (Thread.check ws) in
    if structure <> [] then Error structure
    else
      let meta = Workspace.metadata ws main in
      if meta.thread = None then fail "This card is not bound to a thread; pin it first"
      else
        let items, messages, cards = consume st ~main in
        let question =
          match List.rev messages with
          | (_, (s : source)) :: _ when s.role = "user" -> Some s.card
          | _ -> None
        in
        if options.require_question && question = None then
          report_card st ~code:"no-question" main "Nothing to send: write a question in the last user card";
        let messages =
          match (options.baseline, question) with
          | Some baseline, Some q -> (
              match revision ~baseline ~current:cards ~question:(Some q) with
              | None -> messages
              | Some note ->
                  let rec insert = function
                    | [ ((_, (s : source)) as last) ] -> [ (custom st "coact.revision" note, { s with role = "custom" }); last ]
                    | x :: tl -> x :: insert tl
                    | [] -> []
                  in
                  insert messages)
          | _ -> messages
        in
        let diagnostics = List.rev st.diagnostics in
        if List.exists Diagnostic.is_error diagnostics then Error diagnostics
        else
          Ok
            ( {
                main;
                thread = meta.thread;
                messages = List.map fst messages;
                sources = List.map snd messages;
                items;
                cards;
                question;
              },
              diagnostics )

let lint ws =
  if ws.Workspace.observation = None then []
  else
    List.concat_map
      (fun (t : Thread.t) ->
        let st = { ws; now_ms = 0; diagnostics = [] } in
        ignore (consume st ~main:t.main);
        st.diagnostics)
      (Thread.all ws)

let to_json a =
  let str s = `String s in
  let opt = function Some s -> `String s | None -> `Null in
  `Assoc
    [
      ("main", str a.main);
      ("thread", opt a.thread);
      ("messages", `List a.messages);
      ( "sources",
        `List
          (List.map
             (fun (s : source) -> `Assoc [ ("item", `Int s.item); ("card", str s.card); ("role", str s.role) ])
             a.sources) );
      ( "items",
        `List
          (List.map
             (fun (i : item) ->
               `Assoc
                 [
                   ("card", str i.card);
                   ("title", str i.title);
                   ("kind", opt (Option.map Model.kind_name i.kind));
                   ("included", `Bool i.included);
                 ])
             a.items) );
      ( "cards",
        `List
          (List.map
             (fun (c : card_text) ->
               `Assoc [ ("id", str c.id); ("title", str c.title); ("kind", opt c.kind); ("text", str c.text) ])
             a.cards) );
      ("question", opt a.question);
    ]

let cards_of_json json =
  match json with
  | `List l ->
      List.filter_map
        (fun c ->
          match (member "id" c, member "title" c, member "text" c) with
          | Some (`String id), Some (`String title), Some (`String text) ->
              let kind = match member "kind" c with Some (`String k) -> Some k | _ -> None in
              Some { id; title; kind; text }
          | _ -> None)
        l
  | _ -> []
