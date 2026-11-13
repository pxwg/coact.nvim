module Graph = Ospero_core.Graph
module Obs = Ospero_core.Observation
module Prov = Ospero_core.Provenance

let utf8_length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let tokens s = (utf8_length s + 3) / 4
let vid = Graph.Vertex_id.to_string
let str s = `String s
let opt = function Some s -> `String s | None -> `Null
let kind_json ws id = opt (Option.map Model.kind_name (Workspace.kind ws id))

(* The whole subtree of a card, as the conversation renders it. *)
let subtree ws id =
  match Workspace.find ws id with Some (f, c) -> Org.sub f.text c.start c.stop | None -> ""

let trace_links ws id =
  match Workspace.body ws id with
  | None -> []
  | Some body ->
      List.filter_map
        (fun (c : _ Prov.located) ->
          match c.value with
          | Obs.Observed.Consume (Frontend.Link { target; _ }) when Workspace.kind ws (vid target) = Some Model.Trace ->
              Some (vid target)
          | _ -> None)
        body
      |> List.sort_uniq compare

let trace_tokens ws id =
  match Trace.record ws id with
  | Ok entries -> List.fold_left (fun n (e : Trace.entry) -> n + tokens (Yojson.Safe.to_string e.message)) 0 entries
  | Error _ -> 0

let thread_view ws ~main =
  match Workspace.find ws main with
  | None -> Error ("Unknown card " ^ main)
  | Some _ -> (
      let meta = Workspace.metadata ws main in
      match Workspace.body ws main with
      | None -> Error "The workspace has errors; see the diagnostics"
      | Some body ->
          let items =
            List.filter_map
              (fun (c : _ Prov.located) ->
                match c.value with
                | Obs.Observed.Consume (Frontend.Child t) -> Some (vid t, false)
                | Consume (Include t) -> Some (vid t, true)
                | _ -> None)
              body
          in
          let total = ref 0 in
          let items =
            List.mapi
              (fun i (id, included) ->
                let size = tokens (subtree ws id) in
                total := !total + size;
                let traces =
                  List.map
                    (fun t ->
                      let n = trace_tokens ws t in
                      total := !total + n;
                      `Assoc [ ("id", str t); ("tokens", `Int n) ])
                    (if Workspace.kind ws id = Some Model.Assistant then trace_links ws id else [])
                in
                `Assoc
                  ([
                     ("index", `Int i);
                     ("id", str id);
                     ("kind", kind_json ws id);
                     ("title", str (Workspace.title ws id));
                     ("included", `Bool included);
                     ("tokens", `Int size);
                   ]
                  @ if traces = [] then [] else [ ("traces", `List traces) ]))
              items
          in
          Ok
            (`Assoc
               [
                 ("main", str main);
                 ("title", str (Workspace.title ws main));
                 ("thread", opt meta.thread);
                 ("pinned", `Bool meta.pin);
                 ("items", `List items);
                 ("tokens", `Int !total);
               ]))

let card_ref ws id = `Assoc [ ("id", str id); ("kind", kind_json ws id); ("title", str (Workspace.title ws id)) ]

let own_with_placeholders (file : Org.file) (card : Org.card) =
  let buf = Buffer.create 512 in
  List.iter
    (function
      | Org.Text s -> Buffer.add_string buf (Org.sub file.text s.start s.stop)
      | Link l -> Buffer.add_string buf (Org.sub file.text l.span.start l.span.stop)
      | Include k | Trace k -> Buffer.add_string buf (Org.sub file.text k.span.start k.span.stop)
      | Card c -> Buffer.add_string buf (Printf.sprintf "[nested card %s: %s]\n" c.id c.title))
    card.items;
  Buffer.contents buf

let references (card : Org.card) =
  List.filter_map
    (function Org.Link l -> Some l.target | Include k | Trace k -> Some k.target | _ -> None)
    card.items

let card_read ws ~id ~offset ~limit ~raw =
  match Workspace.find ws id with
  | None -> Error ("Unknown card " ^ id)
  | Some (file, card) ->
      let meta = Workspace.metadata ws id in
      let text =
        if meta.kind = Some Model.Trace && not raw then
          match Trace.record ws id with
          | Ok entries -> String.concat "\n" (Trace.readable entries)
          | Error _ -> own_with_placeholders file card
        else own_with_placeholders file card
      in
      let lines = Line_diff.lines (Conversation.trim_text text) in
      let total = List.length lines in
      let offset = max 1 offset and limit = max 1 limit in
      let shown = List.filteri (fun i _ -> i + 1 >= offset && i + 1 < offset + limit) lines in
      let last = min total (offset + limit - 1) in
      let children = List.filter_map (function Org.Card c -> Some (card_ref ws c.id) | _ -> None) card.items in
      let links = List.sort_uniq compare (references card) |> List.filter (Workspace.mem ws) |> List.map (card_ref ws) in
      let backlinks =
        List.concat_map
          (fun (f : Org.file) ->
            List.filter_map
              (fun (c : Org.card) -> if c.id <> id && List.mem id (references c) then Some (card_ref ws c.id) else None)
              (Org.cards f))
          ws.Workspace.files
      in
      let more =
        if last < total then [ ("more", str (Printf.sprintf "%d more lines; read again with offset %d" (total - last) (last + 1))) ]
        else []
      in
      Ok
        (`Assoc
           ([
              ("id", str id);
              ("title", str card.title);
              ("kind", kind_json ws id);
              ("thread", opt meta.thread);
              ("pinned", `Bool meta.pin);
              ("file", str file.path);
              ("lines", str (Printf.sprintf "%d-%d of %d" (min offset total) last total));
              ("text", str (String.concat "\n" shown));
              ("nested", `List children);
              ("links", `List links);
              ("backlinks", `List backlinks);
            ]
           @ more))

let find_ci hay needle =
  let h = String.lowercase_ascii hay and n = String.lowercase_ascii needle in
  let lh = String.length h and ln = String.length n in
  let rec go i = if i + ln > lh then None else if String.sub h i ln = n then Some i else go (i + 1) in
  if ln = 0 then None else go 0

let snippet text at =
  let n = String.length text in
  let boundary i = let rec back i = if i > 0 && i < n && Char.code text.[i] land 0xC0 = 0x80 then back (i - 1) else i in back i in
  let a = boundary (max 0 (at - 60)) and b = boundary (min n (at + 100)) in
  String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) (String.sub text a (b - a)) |> String.trim

let card_search ws ~query ~limit =
  let words = String.split_on_char ' ' query |> List.map String.trim |> List.filter (( <> ) "") in
  let hits =
    List.concat_map
      (fun (f : Org.file) ->
        List.filter_map
          (fun (c : Org.card) ->
            let own = Org.own_text f c in
            let record = Workspace.kind ws c.id = Some Model.Trace && (match Trace.parse own with Ok (Some _) -> true | _ -> false) in
            let hay = c.title ^ "\n" ^ own in
            if record || words = [] || not (List.for_all (fun w -> find_ci hay w <> None) words) then None
            else
              let in_title = List.exists (fun w -> find_ci c.title w <> None) words in
              let at = Option.value ~default:0 (find_ci own (List.hd words)) in
              Some (in_title, c, snippet own at))
          (Org.cards f))
      ws.Workspace.files
  in
  let hits = List.stable_sort (fun (a, _, _) (b, _, _) -> compare b a) hits in
  let hits = List.filteri (fun i _ -> i < limit) hits in
  `List
    (List.map
       (fun (_, (c : Org.card), s) ->
         `Assoc
           [
             ("id", str c.id);
             ("kind", kind_json ws c.id);
             ("title", str c.title);
             ("thread", opt (Workspace.metadata ws c.id).thread);
             ("snippet", str s);
           ])
       hits)
