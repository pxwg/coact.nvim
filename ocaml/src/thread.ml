module Graph = Ospero_core.Graph
module Policy = Ospero_core.Policy
module Wiring = Ospero_core.Policy_wiring

type t = { main : string; thread : string option; pin : bool }

let all ws =
  List.concat_map
    (fun f ->
      List.filter_map
        (fun (c : Org.card) ->
          let m = Workspace.metadata ws c.id in
          if m.thread <> None || m.pin then Some { main = c.id; thread = m.thread; pin = m.pin } else None)
        (Org.cards f))
    ws.Workspace.files

let main_of ws id =
  match Workspace.find ws id with
  | None -> None
  | Some (file, card) ->
      let threads = all ws in
      List.find_map
        (fun (c : Org.card) -> List.find_opt (fun t -> t.main = c.id) threads)
        (card :: Org.ancestors file card)

type issue = { vertex : string; code : string; message : string }

let id_string = Graph.Vertex_id.to_string

(* Structure issues over the observed graph. Nesting follows Child edges. *)
let issues (graph : (Model.metadata Graph.note, Model.relation) Graph.t) =
  let vertices = Graph.vertices graph in
  let meta (v : _ Graph.vertex) = v.note.Graph.metadata in
  let threads = List.filter (fun v -> (meta v).Model.thread <> None || (meta v).pin) vertices in
  let pinned = List.filter (fun v -> (meta v).Model.pin) threads in
  let parent v =
    match Graph.incoming graph v with
    | Some edges ->
        List.find_map
          (fun (e : _ Graph.edge) -> if e.relation = Model.Child then Some e.source else None)
          edges
    | None -> None
  in
  let rec enclosing v =
    match parent v with
    | None -> None
    | Some p -> (
        match Graph.find_vertex graph p with
        | Some pv when (meta pv).Model.thread <> None || (meta pv).pin -> Some p
        | _ -> enclosing p)
  in
  List.concat_map
    (fun (v : _ Graph.vertex) ->
      let (m : Model.metadata) = meta v in
      let id = id_string v.id in
      let missing =
        if m.pin && m.thread = None then
          [ { vertex = id; code = "thread-missing";
              message = "Pinned card has no THREAD_ID; pin it again with :CoactMode pin to bind a thread" } ]
        else []
      in
      let many =
        if m.pin && List.length pinned > 1 then
          let others =
            List.filter_map (fun (o : _ Graph.vertex) -> if o.id = v.id then None else Some (id_string o.id)) pinned
          in
          [ { vertex = id; code = "pin-conflict";
              message = "Only one card can be pinned; also pinned: " ^ String.concat ", " others } ]
        else []
      in
      let duplicate =
        match m.thread with
        | Some t ->
            let others =
              List.filter_map
                (fun (o : _ Graph.vertex) ->
                  if o.id <> v.id && (meta o).Model.thread = Some t then Some (id_string o.id) else None)
                threads
            in
            if others = [] then []
            else
              [ { vertex = id; code = "thread-conflict";
                  message = Printf.sprintf "THREAD_ID %s is also declared by %s" t (String.concat ", " others) } ]
        | None -> []
      in
      let nested =
        match enclosing v.id with
        | Some outer ->
            [ { vertex = id; code = "thread-nested";
                message = "A thread card cannot be nested inside thread card " ^ id_string outer } ]
        | None -> []
      in
      let kind =
        if m.kind <> None then
          [ { vertex = id; code = "thread-kind";
              message = "A thread main card organizes the conversation and cannot declare CONTEXT_KIND" } ]
        else []
      in
      missing @ many @ duplicate @ nested @ kind)
    threads

let input = Result.get_ok (Policy.Invocation_id.of_string "observation")
let structure_id = Result.get_ok (Policy.Invocation_id.of_string "thread-structure")

let structure =
  Policy.make (Policy.Cons Policy.Nil)
    ~check:(fun (graph, ()) -> issues graph)
    (fun (graph, ()) ->
      {
        Policy.vertex = (fun id -> (Option.get (Graph.find_vertex graph id)).note);
        edge = (fun id -> (Option.get (Graph.find_edge graph id)).relation);
      })

let check ws =
  match ws.Workspace.observation with
  | None -> []
  | Some obs -> (
      let graph = Ospero_core.Observation.graph obs in
      match
        Wiring.compile ~initial:graph ~input
          [ { Policy.id = structure_id; inputs = [ input ]; definition = structure } ]
      with
      | Error _ -> []
      | Ok compiled ->
          List.concat_map
            (fun (id, outcome) ->
              match (outcome : _ Policy.outcome) with
              | Error (Failure { issues; _ }) when id = structure_id ->
                  List.concat_map
                    (fun (i : issue) ->
                      match Workspace.find ws i.vertex with
                      | Some (file, card) ->
                          let span =
                            match card.drawer with
                            | Some d -> d
                            | None -> { Ospero_core.Provenance.file = file.path; start = card.heading.start; stop = card.heading.stop }
                          in
                          [ Diagnostic.make ~code:i.code span i.message ]
                      | None -> [])
                    issues
              | _ -> [])
            (Wiring.evaluate compiled))

let pinned ws =
  if List.exists Diagnostic.is_error (check ws) then None
  else List.find_opt (fun t -> t.pin && t.thread <> None) (all ws)
