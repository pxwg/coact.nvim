module Graph = Ospero_core.Graph
module Observation = Ospero_core.Observation
module Provenance = Ospero_core.Provenance

type document = { path : string; text : string }

type t = {
  files : Org.file list;
  observation : Frontend.observation option;
  diagnostics : Diagnostic.t list;
}

let file t path = List.find_opt (fun (f : Org.file) -> f.path = path) t.files

let find t id =
  List.find_map
    (fun (f : Org.file) -> Option.map (fun c -> (f, c)) (Org.find f id))
    t.files

let mem t id = Option.is_some (find t id)

let vertex t id =
  match (t.observation, Graph.Vertex_id.of_string id) with
  | Some obs, Ok v -> Graph.find_vertex (Observation.graph obs) v
  | _ -> None

let metadata t id =
  match vertex t id with
  | Some v -> v.note.metadata
  | None -> (
      match find t id with
      | Some (_, c) -> (
          match Model.decode c.properties with Ok m -> m | Error _ -> Model.default_metadata)
      | None -> Model.default_metadata)

let kind t id = (metadata t id).kind

let title t id =
  match vertex t id with
  | Some v -> v.note.title
  | None -> ( match find t id with Some (_, c) -> c.title | None -> id)

let body t id =
  match (t.observation, Graph.Vertex_id.of_string id) with
  | Some obs, Ok v -> Observation.body obs v
  | _ -> None

let span path start stop = { Provenance.file = path; start; stop }

(* Locations of every definition of an identity, for conflict reports. *)
let definitions files id =
  List.concat_map
    (fun (f : Org.file) ->
      List.filter_map
        (fun (c : Org.card) -> if c.id = id then Some (span f.path c.heading.start c.heading.stop) else None)
        (Org.cards f))
    files

let issue_diagnostics files (issue : Frontend.Action.error Observation.issue) =
  let at_id code id message =
    let id = Graph.Vertex_id.to_string id in
    List.map (fun s -> Diagnostic.make ~code s (message id)) (definitions files id)
  in
  match issue with
  | Duplicate_definition id | Graph_issue (Duplicate_vertex id) ->
      at_id "duplicate-id" id (Printf.sprintf "Card ID %s is defined more than once")
  | Unregistered_definition id ->
      at_id "unregistered" id (Printf.sprintf "Card %s is not registered")
  | Missing_body id | Duplicate_body id | Unknown_body_vertex id ->
      at_id "body" id (Printf.sprintf "Card %s has an inconsistent body")
  | Graph_issue (Duplicate_edge _) | Graph_issue (Missing_endpoint _) -> []
  | Action_error (_, _) -> .

let analyze documents =
  let parsed =
    List.map (fun (d : document) -> Org.parse ~path:d.path d.text) documents
  in
  let files = List.map fst parsed in
  let syntax =
    List.concat_map
      (fun (_, errors) ->
        List.map
          (fun (e : Org.error) -> Diagnostic.make ~code:"syntax" e.span e.message)
          errors)
      parsed
  in
  let metadata =
    List.concat_map
      (fun f ->
        List.map
          (fun (d : Frontend.diagnostic) -> Diagnostic.make ~code:"metadata" d.span d.message)
          (Frontend.check_metadata f))
      files
  in
  let clean =
    List.filter
      (fun (f : Org.file) ->
        not
          (List.exists
             (fun (d : Diagnostic.t) -> d.span.file = f.path && Diagnostic.is_error d)
             (syntax @ metadata)))
      files
  in
  let observation, observe =
    match Frontend.observe clean with
    | Ok obs -> (Some obs, [])
    | Error (Parse ds) ->
        (None, List.map (fun (d : Frontend.diagnostic) -> Diagnostic.make ~code:"metadata" d.span d.message) ds)
    | Error (Observe issues) -> (None, List.concat_map (issue_diagnostics files) issues)
  in
  { files; observation; diagnostics = syntax @ metadata @ observe }
