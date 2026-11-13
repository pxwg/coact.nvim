type edit = { path : string; start : int; stop : int; text : string }

type labels = {
  question : string;
  answer : string;
  summary : string;
  trace : string;
  trace_source : string;
  sources : string;
  from : string;
  card : string;
}

let default_labels =
  {
    question = "Question";
    answer = "Answer";
    summary = "Summary";
    trace = "Trace";
    trace_source = "Trace record";
    sources = "Sources";
    from = "From";
    card = "New card";
  }

let ( let* ) = Result.bind

let ends_with_newline text at = at = 0 || text.[at - 1] = '\n'
let prefix_for text at = if ends_with_newline text at then "" else "\n"

let ensure_newline s = if s = "" || s.[String.length s - 1] = '\n' then s else s ^ "\n"

let label s = String.map (function '[' | ']' -> ' ' | '\n' -> ' ' | c -> c) s

let card_text ~level ~title ~properties ~body =
  let props = List.map (fun (k, v) -> Printf.sprintf ":%s: %s\n" k v) properties in
  Printf.sprintf "%s %s\n:PROPERTIES:\n%s:END:\n%s" (String.make (max 1 level) '*') title
    (String.concat "" props) (ensure_newline body)

let taken ws id = Workspace.mem ws id

(* Start of the line holding [offset]. *)
let line_start text offset =
  match String.rindex_from_opt text (max 0 (offset - 1)) '\n' with
  | Some i when offset > 0 -> i + 1
  | _ -> 0

(* Set drawer properties on a heading; one drawer insertion when absent. *)
let set_properties (file : Org.file) ~heading_start ~(drawer : Org.span option)
    ~(properties : Org.property list) pairs =
  let existing, missing =
    List.partition (fun (k, _) -> List.exists (fun (p : Org.property) -> p.key = k) properties) pairs
  in
  let replace =
    List.map
      (fun (k, v) ->
        let p = List.find (fun (p : Org.property) -> p.key = k) properties in
        { path = file.path; start = p.value_span.start; stop = p.value_span.stop; text = v })
      existing
  in
  let lines = String.concat "" (List.map (fun (k, v) -> Printf.sprintf ":%s: %s\n" k v) missing) in
  let insert =
    if missing = [] then []
    else
      match drawer with
      | Some d ->
          let at = line_start file.text d.stop in
          [ { path = file.path; start = at; stop = at; text = lines } ]
      | None ->
          let at = Org.line_after file.text heading_start in
          [ { path = file.path; start = at; stop = at;
              text = prefix_for file.text at ^ ":PROPERTIES:\n" ^ lines ^ ":END:\n" } ]
  in
  replace @ insert

let set_card_properties (file : Org.file) (card : Org.card) pairs =
  if card.block then Error "Thread properties need a heading card, not a #+begin_zk block"
  else Ok (set_properties file ~heading_start:card.start ~drawer:card.drawer ~properties:card.properties pairs)

let thread_target ws (file : Org.file) offset =
  match Org.card_at file offset with
  | Some card -> (
      let candidates = card :: Org.ancestors file card in
      match List.find_opt (fun (c : Org.card) -> (Workspace.metadata ws c.id).kind = None) candidates with
      | Some c -> Ok (`Card c)
      | None -> Error "Every card around the cursor is a conversation card; pin their thread card instead")
  | None -> (
      let heading =
        List.fold_left
          (fun best (h : Org.heading) ->
            if h.start <= offset && offset <= h.stop then
              match best with Some (b : Org.heading) when b.start > h.start -> best | _ -> Some h
            else best)
          None file.headings
      in
      match heading with
      | Some h -> Ok (`Heading h)
      | None -> Error "Place the cursor in a card")

let others_pinned ws ~except =
  List.concat_map
    (fun (t : Thread.t) ->
      if t.pin && t.main <> except then
        match Workspace.find ws t.main with
        | Some (f, c) -> ( match set_card_properties f c [ (Model.pin_property, "false") ] with Ok e -> e | Error _ -> [])
        | None -> []
      else [])
    (Thread.all ws)

let pin ws ~path ~offset ~thread ~now =
  match Workspace.file ws path with
  | None -> Error "This file is not part of the chat workspace"
  | Some file -> (
      let* target = thread_target ws file offset in
      match target with
      | `Card c ->
          let meta = Workspace.metadata ws c.id in
          let thread = Option.value meta.thread ~default:thread in
          let pairs =
            (if meta.thread = None then [ (Model.thread_property, thread) ] else [])
            @ [ (Model.pin_property, "true") ]
          in
          let* edits = set_card_properties file c pairs in
          Ok (edits @ others_pinned ws ~except:c.id, c.id, thread)
      | `Heading (h : Org.heading) ->
          let id =
            match List.find_opt (fun (p : Org.property) -> p.key = "ID") h.properties with
            | Some p when Org.valid_id p.value -> p.value
            | _ -> Ids.fresh ~now ~taken:(taken ws)
          in
          let edits =
            set_properties file ~heading_start:h.start ~drawer:h.drawer ~properties:h.properties
              [ ("ID", id); (Model.thread_property, thread); (Model.pin_property, "true") ]
          in
          Ok (edits @ others_pinned ws ~except:id, id, thread))

let unpin ws ~path ~offset =
  match Workspace.file ws path with
  | None -> Error "This file is not part of the chat workspace"
  | Some file -> (
      let at_cursor =
        match thread_target ws file offset with
        | Ok (`Card c) when (Workspace.metadata ws c.id).pin -> Some c.id
        | _ -> None
      in
      let target =
        match at_cursor with
        | Some id -> Some id
        | None -> Option.map (fun (t : Thread.t) -> t.main) (List.find_opt (fun (t : Thread.t) -> t.pin) (Thread.all ws))
      in
      match target with
      | None -> Error "No card is pinned"
      | Some id -> (
          match Workspace.find ws id with
          | None -> Error ("Unknown card " ^ id)
          | Some (f, c) ->
              let* edits = set_card_properties f c [ (Model.pin_property, "false") ] in
              Ok (edits, id)))

let new_card ws ~path ~selection ~title labels ~now =
  match Workspace.file ws path with
  | None -> Error "This file is not part of the chat workspace"
  | Some file ->
      let text = file.text in
      let id = Ids.fresh ~now ~taken:(taken ws) in
      let selected = Option.map (fun (a, b) -> Org.sub text a b) selection in
      let title =
        match title with
        | Some t when String.trim t <> "" -> String.trim t
        | _ -> (
            match Option.map (fun s -> Org_text.title_of s) selected with
            | Some t when t <> "" -> t
            | _ -> labels.card)
      in
      let source = Option.bind selection (fun (a, _) -> Org.card_at file a) in
      let body =
        match selected with
        | None -> ""
        | Some s ->
            let quote = String.concat "\n" (List.map Org_text.escape_block_line (Line_diff.lines s)) in
            let from =
              match source with
              | Some (c : Org.card) -> Printf.sprintf "%s [[id:%s][%s]]\n" labels.from c.id (label c.title)
              | None -> ""
            in
            Printf.sprintf "#+begin_quote\n%s\n#+end_quote\n%s" quote from
      in
      (* An empty last line to write in. *)
      let body = body ^ "\n" in
      let at = String.length text in
      let card = card_text ~level:1 ~title ~properties:[ ("ID", id) ] ~body in
      let append = { path; start = at; stop = at; text = prefix_for text at ^ "\n" ^ card } in
      let link =
        match (selection, selected) with
        | Some (a, b), Some s when not (String.contains s '\n' || String.contains s ']' || String.contains s '[') ->
            [ { path; start = a; stop = b; text = Printf.sprintf "[[id:%s][%s]]" id s } ]
        | Some (_, b), Some _ ->
            let at = Org.line_after text (max 0 (b - 1)) in
            [ { path; start = at; stop = at; text = prefix_for text at ^ Printf.sprintf "[[id:%s][%s]]\n" id (label title) } ]
        | _ -> []
      in
      Ok (link @ [ append ], id)

type submit =
  | Ready of { edits : edit list; question : string; answer : string }
  | Draft of { edits : edit list; draft : string }

type conv = Child of Org.card | Included of Org.keyword

let conversation_items (card : Org.card) =
  List.filter_map
    (function Org.Card c -> Some (Child c) | Org.Include k -> Some (Included k) | _ -> None)
    card.items

let item_stop = function Child c -> c.Org.stop | Included k -> k.span.stop
let item_start = function Child c -> c.Org.start | Included k -> k.span.start

let kind_property kind = (Model.kind_property, Model.kind_name kind)

let submit ws ~main labels ~now =
  match Workspace.find ws main with
  | None -> Error ("Unknown card " ^ main)
  | Some (file, card) -> (
      let text = file.text in
      let fresh = Ids.supply ~now ~taken:(taken ws) in
      let level = card.level + 1 in
      let answer_card id =
        card_text ~level ~title:labels.answer ~properties:[ ("ID", id); kind_property Model.Assistant ] ~body:""
      in
      let items = conversation_items card in
      let last = match List.rev items with x :: _ -> Some x | [] -> None in
      let region_start = match last with Some i -> item_stop i | None -> card.content_start in
      let trailing = Org.sub text region_start card.stop in
      let kind (c : Org.card) = (Workspace.metadata ws c.id).kind in
      let own (c : Org.card) = String.trim (Org.own_text file c) in
      if String.trim trailing <> "" then
        let question = fresh () and answer = fresh () in
        let body = Conversation.trim_text trailing in
        let user =
          card_text ~level ~title:(Org_text.title_of body)
            ~properties:[ ("ID", question); kind_property Model.User ] ~body
        in
        Ok
          (Ready
             {
               edits = [ { path = file.path; start = region_start; stop = card.stop;
                           text = prefix_for text region_start ^ user ^ answer_card answer } ];
               question;
               answer;
             })
      else
        let draft () =
          let id = fresh () in
          let at = card.stop in
          let user = card_text ~level ~title:labels.question ~properties:[ ("ID", id); kind_property Model.User ] ~body:"\n" in
          Ok (Draft { edits = [ { path = file.path; start = at; stop = at; text = prefix_for text at ^ user } ]; draft = id })
        in
        match List.rev items with
        | Child c :: _ when kind c = Some Model.User && own c <> "" ->
            let answer = fresh () in
            let at = c.stop in
            Ok (Ready { edits = [ { path = file.path; start = at; stop = at; text = prefix_for text at ^ answer_card answer } ];
                        question = c.id; answer })
        | Child a :: Child q :: _
          when kind a = Some Model.Assistant && own a = "" && kind q = Some Model.User && own q <> "" ->
            Ok (Ready { edits = []; question = q.id; answer = a.id })
        | Child c :: _ when kind c = Some Model.User -> Error "Write your question in the last question card first"
        | _ -> draft ())

type answer = { edits : edit list; draft : string option; trace : string option; removed : bool }

let answer ws ~answer ~text ~entries ~trace_path labels ~now =
  match Workspace.find ws answer with
  | None -> Error ("The answer card " ^ answer ^ " no longer exists")
  | Some (file, card) ->
      if (Workspace.metadata ws card.id).kind <> Some Model.Assistant then
        Error ("Card " ^ answer ^ " is not an assistant card")
      else
        let body = Org_text.of_markdown text in
        if String.trim body = "" then
          Ok { edits = [ { path = file.path; start = card.start; stop = card.stop; text = "" } ];
               draft = None; trace = None; removed = true }
        else
          let fresh = Ids.supply ~now ~taken:(taken ws) in
          let trace_edits, trace =
            if entries = [] then ([], None)
            else
              let source = fresh () and readable = fresh () in
              let main_title =
                match Thread.main_of ws card.id with Some t -> Workspace.title ws t.main | None -> card.title
              in
              let record =
                card_text ~level:1 ~title:(Printf.sprintf "%s: %s" labels.trace_source main_title)
                  ~properties:[ ("ID", source); kind_property Model.Trace ]
                  ~body:(Trace.block entries)
              in
              let account =
                card_text ~level:1 ~title:(Printf.sprintf "%s: %s" labels.trace main_title)
                  ~properties:[ ("ID", readable); kind_property Model.Trace ]
                  ~body:(Printf.sprintf "#+coact_trace: :target %s" source)
              in
              let cards = record ^ "\n" ^ account in
              let edit =
                match Workspace.file ws trace_path with
                | Some f ->
                    let at = String.length f.text in
                    { path = trace_path; start = at; stop = at; text = prefix_for f.text at ^ "\n" ^ cards }
                | None ->
                    { path = trace_path; start = 0; stop = 0;
                      text = Printf.sprintf "#+title: %s: %s\n\n%s" labels.trace main_title cards }
              in
              ([ edit ], Some readable)
          in
          let link = match trace with Some id -> Printf.sprintf "[[id:%s][%s]]\n" id labels.trace | None -> "" in
          let draft = fresh () in
          let next =
            card_text ~level:card.level ~title:labels.question
              ~properties:[ ("ID", draft); kind_property Model.User ] ~body:"\n"
          in
          let replacement = link ^ ensure_newline body ^ "\n" ^ next in
          let start = card.content_start in
          let replacement = prefix_for file.text start ^ replacement in
          Ok
            {
              edits = { path = file.path; start; stop = card.stop; text = replacement } :: trace_edits;
              draft = Some draft;
              trace;
              removed = false;
            }

(* Re-level a nested subtree so its top heading sits at [level]. *)
let archived (file : Org.file) (card : Org.card) ~level =
  let text = file.text in
  if card.block then
    let end_line = line_start text (max card.content_start (card.stop - 1)) in
    let content = Org.sub text card.content_start end_line in
    let properties = ("ID", card.id) :: List.map (fun (p : Org.property) -> (p.key, p.value)) card.properties in
    card_text ~level ~title:card.title ~properties ~body:content
  else
    let delta = card.level - level in
    let lines = Line_diff.lines (Org.sub text card.start card.stop) in
    let relevel l =
      let n = String.length l in
      let rec stars i = if i < n && l.[i] = '*' then stars (i + 1) else i in
      let s = stars 0 in
      if s > 0 && (s = n || l.[s] = ' ' || l.[s] = '\t') then String.make (max 1 (s - delta)) '*' ^ String.sub l s (n - s)
      else l
    in
    ensure_newline (String.concat "\n" (List.map relevel lines))

let compact ws ~main ~count ~summary labels ~now =
  match Workspace.find ws main with
  | None -> Error ("Unknown card " ^ main)
  | Some (file, card) ->
      let items = conversation_items card in
      let n = List.length items in
      if count < 1 || count >= n then Error "Compaction must summarize at least one item and keep the rest"
      else
        let summarized = List.filteri (fun i _ -> i < count) items in
        let id = Ids.fresh ~now ~taken:(taken ws) in
        let target = function Child c -> c.Org.id | Included k -> k.target in
        let sources =
          List.map
            (fun i -> let t = target i in Printf.sprintf "[[id:%s][%s]]" t (label (Workspace.title ws t)))
            summarized
        in
        let body = Org_text.of_markdown summary ^ "\n\n" ^ labels.sources ^ ": " ^ String.concat ", " sources in
        (* A heading inserted among the main card's own transclusion lines would
           swallow the lines after it, so a summary that replaces a
           transclusion is itself transcluded and defined after the main card. *)
        let nested = match summarized with Child _ :: _ -> true | _ -> false in
        let synthesis ~level =
          card_text ~level ~title:labels.summary ~properties:[ ("ID", id); kind_property Model.Synthesis ] ~body
        in
        let first =
          if nested then synthesis ~level:(card.level + 1)
          else Printf.sprintf "#+zk_include: :target %s\n" id
        in
        let edits =
          List.mapi
            (fun i item ->
              { path = file.path; start = item_start item; stop = item_stop item; text = (if i = 0 then first else "") })
            summarized
        in
        let archive =
          (if nested then "" else synthesis ~level:card.level)
          ^ String.concat ""
              (List.filter_map (function Child c -> Some (archived file c ~level:card.level) | Included _ -> None) summarized)
        in
        let archive_edit =
          if archive = "" then []
          else [ { path = file.path; start = card.stop; stop = card.stop; text = prefix_for file.text card.stop ^ archive } ]
        in
        Ok (edits @ archive_edit, id)
