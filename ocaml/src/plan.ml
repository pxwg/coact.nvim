type edit = { path : string; start : int; stop : int; text : string }

type layout = { blank_before_heading : bool; blank_after_drawer : bool }

let default_layout = { blank_before_heading = true; blank_after_drawer = true }

type labels = {
  layout : layout;
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
    layout = default_layout;
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

(* Layout of generated cards, one rule for all of them:
   - [card_text] lays out a card: heading, drawer, a blank line when
     [blank_after_drawer], then the body;
   - [separate] joins a card to the text before it, adding a blank line when
     [blank_before_heading] and the text does not already end with one;
   - [gap] is the same between two generated cards. *)
let separate layout text at =
  if at = 0 then ""
  else if not layout.blank_before_heading then if text.[at - 1] = '\n' then "" else "\n"
  else if at >= 2 && text.[at - 1] = '\n' && text.[at - 2] = '\n' then ""
  else if text.[at - 1] = '\n' then "\n"
  else "\n\n"

let gap layout = if layout.blank_before_heading then "\n" else ""
let after_drawer layout = if layout.blank_after_drawer then "\n" else ""

let ensure_newline s = if s = "" || s.[String.length s - 1] = '\n' then s else s ^ "\n"

let label s = String.map (function '[' | ']' -> ' ' | '\n' -> ' ' | c -> c) s

let card_text ~layout ~level ~title ~properties ~body =
  let props = List.map (fun (k, v) -> Printf.sprintf ":%s: %s\n" k v) properties in
  Printf.sprintf "%s %s\n:PROPERTIES:\n%s:END:\n%s%s" (String.make (max 1 level) '*') title
    (String.concat "" props) (after_drawer layout) (ensure_newline body)

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

let new_card ws ~path ?into ~selection ~title labels ~now =
  let layout = labels.layout in
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
            (* A blank line keeps the question its own paragraph. *)
            Printf.sprintf "#+begin_quote\n%s\n#+end_quote\n%s\n" quote from
      in
      (* An empty last line to write in. *)
      let body = body ^ "\n" in
      let card = card_text ~layout ~level:1 ~title ~properties:[ ("ID", id) ] ~body in
      let target, place =
        match into with
        | Some dir ->
            let target = Filename.concat dir (id ^ ".org") in
            (target, { path = target; start = 0; stop = 0; text = Printf.sprintf "#+title: %s\n\n%s" title card })
        | None ->
            let at = String.length text in
            (path, { path; start = at; stop = at; text = separate layout text at ^ card })
      in
      let link =
        match (selection, selected) with
        | Some (a, b), Some s when not (String.contains s '\n' || String.contains s ']' || String.contains s '[') ->
            [ { path; start = a; stop = b; text = Printf.sprintf "[[id:%s][%s]]" id s } ]
        | Some (_, b), Some _ ->
            let at = Org.line_after text (max 0 (b - 1)) in
            [ { path; start = at; stop = at; text = prefix_for text at ^ Printf.sprintf "[[id:%s][%s]]\n" id (label title) } ]
        | _ -> []
      in
      Ok (link @ [ place ], id, target)

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
  let layout = labels.layout in
  match Workspace.find ws main with
  | None -> Error ("Unknown card " ^ main)
  | Some (file, card) -> (
      let text = file.text in
      let fresh = Ids.supply ~now ~taken:(taken ws) in
      let level = card.level + 1 in
      let answer_card id =
        card_text ~layout ~level ~title:labels.answer ~properties:[ ("ID", id); kind_property Model.Assistant ] ~body:""
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
          card_text ~layout ~level ~title:(let t = Org_text.headline body in if t = "" then labels.question else t)
            ~properties:[ ("ID", question); kind_property Model.User ] ~body
        in
        Ok
          (Ready
             {
               edits =
                 [
                   {
                     path = file.path;
                     start = region_start;
                     stop = card.stop;
                     text =
                       (if last = None then prefix_for text region_start else separate layout text region_start)
                       ^ user ^ gap layout ^ answer_card answer;
                   };
                 ];
               question;
               answer;
             })
      else
        let draft () =
          let id = fresh () in
          let at = card.stop in
          let user = card_text ~layout ~level ~title:labels.question ~properties:[ ("ID", id); kind_property Model.User ] ~body:"\n" in
          let sep = if items = [] then prefix_for text at else separate layout text at in
          Ok (Draft { edits = [ { path = file.path; start = at; stop = at; text = sep ^ user } ]; draft = id })
        in
        match List.rev items with
        | Child c :: _ when kind c = Some Model.User && own c <> "" ->
            let answer = fresh () in
            let at = c.stop in
            Ok (Ready { edits = [ { path = file.path; start = at; stop = at; text = separate layout text at ^ answer_card answer } ];
                        question = c.id; answer })
        | Child a :: Child q :: _
          when kind a = Some Model.Assistant && own a = "" && kind q = Some Model.User && own q <> "" ->
            Ok (Ready { edits = []; question = q.id; answer = a.id })
        | Child c :: _ when kind c = Some Model.User -> Error "Write your question in the last question card first"
        | _ -> draft ())

type answer = { edits : edit list; draft : string option; trace : string option; removed : bool }

let answer ws ~answer ~text ~entries ~trace_path labels ~now =
  let layout = labels.layout in
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
                card_text ~layout ~level:1 ~title:(Printf.sprintf "%s: %s" labels.trace_source main_title)
                  ~properties:[ ("ID", source); kind_property Model.Trace ]
                  ~body:(Trace.block entries)
              in
              let account =
                card_text ~layout ~level:1 ~title:(Printf.sprintf "%s: %s" labels.trace main_title)
                  ~properties:[ ("ID", readable); kind_property Model.Trace ]
                  ~body:(Printf.sprintf "#+coact_trace: :target %s" source)
              in
              let cards = record ^ gap layout ^ account in
              let edit =
                match Workspace.file ws trace_path with
                | Some f ->
                    let at = String.length f.text in
                    { path = trace_path; start = at; stop = at; text = separate layout f.text at ^ cards }
                | None ->
                    { path = trace_path; start = 0; stop = 0;
                      text = Printf.sprintf "#+title: %s: %s\n\n%s" labels.trace main_title cards }
              in
              ([ edit ], Some readable)
          in
          let link = match trace with Some id -> Printf.sprintf "[[id:%s][%s]]\n" id labels.trace | None -> "" in
          let draft = fresh () in
          let next =
            card_text ~layout ~level:card.level ~title:labels.question
              ~properties:[ ("ID", draft); kind_property Model.User ] ~body:"\n"
          in
          let replacement = after_drawer layout ^ link ^ ensure_newline body ^ gap layout ^ next in
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
let archived ~layout (file : Org.file) (card : Org.card) ~level =
  let text = file.text in
  if card.block then
    let end_line = line_start text (max card.content_start (card.stop - 1)) in
    let content = Org.sub text card.content_start end_line in
    let properties = ("ID", card.id) :: List.map (fun (p : Org.property) -> (p.key, p.value)) card.properties in
    card_text ~layout ~level ~title:card.title ~properties ~body:content
  else
    let delta = card.level - level in
    (* Every line kept as written, blank separators included. *)
    let lines = String.split_on_char '\n' (Org.sub text card.start card.stop) in
    let relevel l =
      let n = String.length l in
      let rec stars i = if i < n && l.[i] = '*' then stars (i + 1) else i in
      let s = stars 0 in
      if s > 0 && (s = n || l.[s] = ' ' || l.[s] = '\t') then String.make (max 1 (s - delta)) '*' ^ String.sub l s (n - s)
      else l
    in
    ensure_newline (String.concat "\n" (List.map relevel lines))
    |> fun s -> if String.ends_with ~suffix:"\n\n" s then s else s ^ gap layout

type note = { path : string; anchor : string; note : string }

let one_line s = String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) (String.trim s)

let create ws ~layout ~dir ~title ~kind ~body ~now =
  let title = one_line title in
  if title = "" then Error "A card needs a title"
  else
    let id = Ids.fresh ~now ~taken:(taken ws) in
    let path = Filename.concat dir (id ^ ".org") in
    let properties = ("ID", id) :: (match kind with Some k -> [ kind_property k ] | None -> []) in
    let card = card_text ~layout ~level:1 ~title ~properties ~body:(Org_text.of_markdown body) in
    Ok ({ path; start = 0; stop = 0; text = Printf.sprintf "#+title: %s\n\n%s" title card }, id, path)

(* Offsets of [sub] in [text] within [start, stop). *)
let occurrences text sub start stop =
  let n = String.length sub in
  let rec go i acc =
    if i + n > stop then List.rev acc
    else if String.sub text i n = sub then go (i + 1) (i :: acc)
    else go (i + 1) acc
  in
  go start []

let structural line =
  let t = String.trim line in
  let n = String.length line in
  let rec stars i = if i < n && line.[i] = '*' then stars (i + 1) else i in
  let s = stars 0 in
  (s > 0 && (s = n || line.[s] = ' ' || line.[s] = '\t'))
  || String.uppercase_ascii t = ":PROPERTIES:"
  || String.uppercase_ascii t = ":END:"

(* The card's own text: between its drawer and its end, around nested cards. *)
let own_segments (file : Org.file) (card : Org.card) =
  let own_stop = if card.block then line_start file.text (max card.content_start (card.stop - 1)) else card.stop in
  let children = List.filter_map (function Org.Card c -> Some c | _ -> None) card.items in
  let rec segments cursor = function
    | [] -> [ (cursor, own_stop) ]
    | (c : Org.card) :: tl -> (cursor, c.start) :: segments c.stop tl
  in
  List.filter (fun (a, b) -> b > a) (segments card.content_start children)

let edit ?(layout = default_layout) ws ~id replacements =
  match Workspace.find ws id with
  | None -> Error ("Unknown card " ^ id)
  | Some (file, card) ->
      let segments = own_segments file card in
      let blank = List.for_all (fun (a, b) -> String.trim (Org.sub file.text a b) = "") segments in
      let one (old, rep) =
        if List.exists structural (Line_diff.lines rep) then
          Error "A replacement may not contain a heading or a property drawer; create a new card instead"
        else if old = "" then
          let stop = match segments with (_, b) :: _ -> b | [] -> card.content_start in
          if blank then
            Ok { path = file.path; start = card.content_start; stop; text = after_drawer layout ^ ensure_newline rep ^ gap layout }
          else Error "An empty old text only fills a blank card"
        else
          match List.concat_map (fun (a, b) -> occurrences file.text old a b) segments with
          | [ at ] -> Ok { path = file.path; start = at; stop = at + String.length old; text = rep }
          | [] -> Error (Printf.sprintf "Card %s has no text %S" id old)
          | _ -> Error (Printf.sprintf "Text %S occurs more than once in card %s; include more context" old id)
      in
      let rec all acc = function
        | [] -> Ok (List.rev acc)
        | r :: tl -> ( match one r with Ok e -> all (e :: acc) tl | Error e -> Error e)
      in
      if replacements = [] then Error "No edits given"
      else
        match all [] replacements with
        | Error e -> Error e
        | Ok edits ->
            let sorted = List.sort (fun a b -> compare a.start b.start) edits in
            let rec overlap = function
              | a :: (b :: _ as tl) -> a.stop > b.start || (a.start = b.start && a.stop = a.start && b.stop = b.start) || overlap tl
              | _ -> false
            in
            if overlap sorted then Error "Edits overlap" else Ok edits

(* ---- rearranging a thread ---- *)

type slot = Keep of conv | Add of string

let conv_id = function Child c -> c.Org.id | Included k -> k.target
let same a b = item_start a = item_start b

let first_line s = match Line_diff.lines s with l :: _ -> l | [] -> ""

let rearrange ~layout ws (file : Org.file) (main : Org.card) slots =
  let text = file.text in
  let items = conversation_items main in
  let kept = List.filter_map (function Keep c -> Some c | Add _ -> None) slots in
  let removed = List.filter (fun c -> not (List.exists (same c) kept)) items in
  (* Own text before the first item, between items, and after the last. *)
  let prefix, middle, trailing =
    match items with
    | [] -> (Org.sub text main.content_start main.stop, [], "")
    | first :: _ ->
        let rec gaps = function
          | a :: (b :: _ as tl) -> Org.sub text (item_stop a) (item_start b) :: gaps tl
          | _ -> []
        in
        let trailing =
          match List.rev items with Included k :: _ -> Org.sub text k.span.stop main.stop | _ -> ""
        in
        (Org.sub text main.content_start (item_start first), gaps items, trailing)
  in
  let middle = List.filter (fun s -> String.trim s <> "") middle in
  let last_included =
    List.fold_left max (-1)
      (List.mapi (fun i s -> match s with Add _ | Keep (Included _) -> i | Keep (Child _) -> -1) slots)
  in
  let level = main.level in
  let notes = ref [] in
  let note anchor n = if anchor <> "" then notes := { path = file.path; anchor; note = n } :: !notes in
  let includes = Buffer.create 128 and nested = Buffer.create 1024 and moved = Buffer.create 1024 in
  let move_out (c : Org.card) message =
    let card = archived ~layout file c ~level in
    note (first_line card) message;
    Buffer.add_string moved card
  in
  List.iteri
    (fun i slot ->
      let id = match slot with Add id -> id | Keep c -> conv_id c in
      if i <= last_included then (
        let line = Printf.sprintf "#+zk_include: :target %s" id in
        Buffer.add_string includes (line ^ "\n");
        match slot with
        | Add _ -> note line ("Transcluded into the thread: " ^ Workspace.title ws id)
        | Keep (Child c) ->
            note line ("Now transcluded: " ^ c.title);
            move_out c "Defined here, after the thread, and transcluded into it"
        | Keep (Included _) -> ())
      else match slot with Keep (Child c) -> Buffer.add_string nested (archived ~layout file c ~level:(level + 1)) | _ -> ())
    slots;
  List.iter
    (function
      | Child c -> move_out c "Left the thread; the card is kept here"
      | Included k -> ignore k)
    removed;
  if String.trim trailing <> "" && Buffer.length nested > 0 then
    Error "The main card has unsent text after its cards; submit or clear it first"
  else
    let own = ensure_newline prefix ^ String.concat "" (List.map ensure_newline middle) in
    let body =
      own ^ Buffer.contents includes
      ^ (if Buffer.length nested = 0 then trailing else "")
      ^ Buffer.contents nested
    in
    let body =
      if Buffer.length moved = 0 then body
      else
        let body = ensure_newline body in
        (if String.ends_with ~suffix:"\n\n" body || body = "" then body else body ^ gap layout) ^ Buffer.contents moved
    in
    Ok ([ { path = file.path; start = main.content_start; stop = main.stop; text = body } ], List.rev !notes)

let thread_card ws main =
  match Workspace.find ws main with
  | None -> Error ("Unknown card " ^ main)
  | Some (_, (c : Org.card)) when c.block -> Error "A thread's main card must be a heading card"
  | Some (file, card) ->
      if (Workspace.metadata ws main).thread = None then Error (Printf.sprintf "Card %s is not a thread's main card" main)
      else Ok (file, card)

let arrange ?(layout = default_layout) ws ~main ids =
  match thread_card ws main with
  | Error e -> Error e
  | Ok (file, card) -> (
      let items = conversation_items card in
      let ancestors = card :: Org.ancestors file card in
      let rec dup = function x :: tl -> List.mem x tl || dup tl | [] -> false in
      if dup ids then Error "An item appears twice"
      else
        let slot id =
          match List.find_opt (fun c -> conv_id c = id) items with
          | Some c -> Ok (Keep c)
          | None -> (
              match Workspace.find ws id with
              | None -> Error ("Unknown card " ^ id)
              | Some (f, c) ->
                  if List.exists (fun (a : Org.card) -> a.id = id) ancestors then
                    Error (Printf.sprintf "Card %s contains the thread" id)
                  else if f.path = file.path && c.start > card.start && c.stop <= card.stop then
                    Error (Printf.sprintf "Card %s is already inside the thread" id)
                  else Ok (Add id))
        in
        let rec slots acc = function
          | [] -> Ok (List.rev acc)
          | id :: tl -> ( match slot id with Ok s -> slots (s :: acc) tl | Error e -> Error e)
        in
        match slots [] ids with Error e -> Error e | Ok s -> rearrange ~layout ws file card s)

let compact ws ~main ~count ~summary ~dir labels ~now =
  match thread_card ws main with
  | Error e -> Error e
  | Ok (file, card) ->
      let items = conversation_items card in
      let n = List.length items in
      if count < 1 || count >= n then Error "Compaction must summarize at least one item and keep the rest"
      else
        let summarized = List.filteri (fun i _ -> i < count) items in
        let sources =
          List.map
            (fun i -> let t = conv_id i in Printf.sprintf "[[id:%s][%s]]" t (label (Workspace.title ws t)))
            summarized
        in
        let body = Org_text.of_markdown summary ^ "\n\n" ^ labels.sources ^ ": " ^ String.concat ", " sources in
        match create ws ~layout:labels.layout ~dir ~title:labels.summary ~kind:(Some Model.Synthesis) ~body ~now with
        | Error e -> Error e
        | Ok (definition, id, path) -> (
            let slots = Add id :: List.map (fun c -> Keep c) (List.filteri (fun i _ -> i >= count) items) in
            match rearrange ~layout:labels.layout ws file card slots with
            | Error e -> Error e
            | Ok (edits, notes) ->
                let notes =
                  { path; anchor = "* " ^ labels.summary;
                    note = Printf.sprintf "Synthesis of %d item%s that leave the thread" count (if count = 1 then "" else "s") }
                  :: notes
                in
                Ok (definition :: edits, notes, id))
