open Ospero_core
module Source = Observation.Source

type id = Graph.Vertex_id.t

type consumption =
  | Link of { target : id; source : string }
  | Include of id
  | Child of id
  | Trace of id
  | Unresolved of { target : string; form : form; source : string }

and form = Cited | Included | Traced

module Action = struct
  type t =
    | Cite of { target : string; source : string }
    | Transclude of { target : string; source : string }
    | Trace of { target : string; source : string }
    | Define of (Model.metadata, t) Source.note Provenance.located

  type error = |
end

type diagnostic = { span : Provenance.span; message : string }
type observation = (Model.metadata, Model.relation, consumption) Observation.t

let id s =
  match Graph.Vertex_id.of_string s with
  | Ok id -> id
  | Error message -> invalid_arg message

let located span value = Provenance.located ~span value

let metadata (card : Org.card) =
  match Model.decode card.properties with Ok m -> Ok m | Error (p, message) -> Error { span = p.value_span; message }

let check_metadata file =
  List.filter_map
    (fun card -> match metadata card with Ok _ -> None | Error d -> Some d)
    (Org.cards file)

let span (file : Org.file) start stop = { Provenance.file = file.path; start; stop }

let rec note (file : Org.file) (card : Org.card) =
  let ( let* ) = Result.bind in
  let* meta = metadata card in
  let* body =
    List.fold_right
      (fun item acc ->
        let* rest = acc in
        let* content =
          match (item : Org.item) with
          | Text s -> Ok (located s (Source.Text (Org.sub file.text s.start s.stop)))
          | Link l ->
              Ok
                (located l.span
                   (Source.Action
                      (Action.Cite
                         { target = l.target; source = Org.sub file.text l.span.start l.span.stop })))
          | Include k ->
              Ok
                (located k.span
                   (Source.Action
                      (Action.Transclude
                         { target = k.target; source = Org.sub file.text k.span.start k.span.stop })))
          | Trace k ->
              Ok
                (located k.span
                   (Source.Action
                      (Action.Trace
                         { target = k.target; source = Org.sub file.text k.span.start k.span.stop })))
          | Card c ->
              let* n = note file c in
              Ok (located (span file c.start c.stop) (Source.Action (Action.Define n)))
        in
        Ok (content :: rest))
      card.items (Ok [])
  in
  let metadata_span =
    match card.drawer with Some d -> Some d | None -> if card.block then Some card.heading else None
  in
  Ok
    (located (span file card.start card.stop)
       {
         Source.id = id card.id;
         title = located card.title_span card.title;
         metadata = Provenance.located ?span:metadata_span meta;
         body = located (span file card.content_start card.stop) body;
       })

let parse (files : Org.file list) =
  let identities = List.concat_map (fun f -> List.map (fun (c : Org.card) -> id c.id) (Org.cards f)) files in
  let notes, errors =
    List.fold_left
      (fun (notes, errors) (file : Org.file) ->
        List.fold_left
          (fun (notes, errors) card ->
            match note file card with
            | Ok n -> (n :: notes, errors)
            | Error d -> (notes, d :: errors))
          (notes, errors) file.cards)
      ([], []) files
  in
  if errors <> [] then Error (List.rev errors)
  else Ok { Observation.identities; notes = List.rev notes }

let unresolved form target source =
  Observation.Emit (Observation.Observed.Consume (Unresolved { target; form; source }))

let emit c = Observation.Emit (Observation.Observed.Consume c)

let interpret (ctx : Model.metadata Observation.context) (action : Action.t) =
  let resolve target = match Graph.Vertex_id.of_string target with
    | Ok v when ctx.is_registered v -> Some v
    | _ -> None
  in
  match action with
  | Cite { target; source } -> (
      match resolve target with
      | Some v -> Ok [ Observation.Relate { target = v; relation = Model.Reference }; emit (Link { target = v; source }) ]
      | None -> Ok [ unresolved Cited target source ])
  | Transclude { target; source } -> (
      match resolve target with
      | Some v -> Ok [ Observation.Relate { target = v; relation = Model.Inclusion }; emit (Include v) ]
      | None -> Ok [ unresolved Included target source ])
  | Trace { target; source } -> (
      match resolve target with
      | Some v -> Ok [ Observation.Relate { target = v; relation = Model.Trace_of }; emit (Trace v) ]
      | None -> Ok [ unresolved Traced target source ])
  | Define n ->
      let child = n.value.id in
      Ok [ Observation.Define n; Observation.Relate { target = child; relation = Model.Child }; emit (Child child) ]

module Driver = Frontend.Make (struct
  type metadata = Model.metadata
  type relation = Model.relation
  type nonrec consumption = consumption
  type action = Action.t
  type error = Action.error
  type parse_error = diagnostic
  type input = Org.file list

  let parse = parse
  let interpret = interpret
end)

type error = Driver.error =
  | Parse of diagnostic list
  | Observe of Action.error Observation.issue list

let observe = Driver.observe
