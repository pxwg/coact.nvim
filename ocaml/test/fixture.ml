open Coact_zk

let analyze docs = Workspace.analyze (List.map (fun (path, text) -> { Workspace.path; text }) docs)

(* Apply plan edits (all relative to the original texts) to documents. *)
let apply docs (edits : Plan.edit list) =
  let paths = List.sort_uniq compare (List.map fst docs @ List.map (fun (e : Plan.edit) -> e.path) edits) in
  List.map
    (fun path ->
      let text = Option.value ~default:"" (List.assoc_opt path docs) in
      let mine = List.filter (fun (e : Plan.edit) -> e.path = path) edits in
      let mine = List.stable_sort (fun (a : Plan.edit) (b : Plan.edit) -> compare b.start a.start) mine in
      (path, List.fold_left (fun t (e : Plan.edit) ->
        String.sub t 0 e.start ^ e.text ^ String.sub t e.stop (String.length t - e.stop)) text mine))
    paths

let print_diagnostics ds =
  List.iter
    (fun (d : Diagnostic.t) ->
      Printf.printf "%s %s [%d,%d): %s\n"
        (match d.severity with Error -> "error" | Warning -> "warning" | Information -> "info" | Hint -> "hint")
        d.code d.span.start d.span.stop d.message)
    ds

let message_line json =
  let m k = match json with `Assoc f -> List.assoc_opt k f | _ -> None in
  let s k = match m k with Some (`String s) -> s | _ -> "" in
  let content =
    match m "content" with
    | Some (`String s) -> s
    | Some (`List bs) ->
        String.concat " | "
          (List.map
             (fun b ->
               let g k = match b with `Assoc f -> (match List.assoc_opt k f with Some (`String s) -> s | _ -> "") | _ -> "" in
               match g "type" with
               | "text" -> g "text"
               | "toolCall" -> "call:" ^ g "name"
               | t -> t)
             bs)
    | _ -> ""
  in
  let tag = match s "role" with "custom" -> "custom/" ^ s "customType" | r -> r in
  Printf.sprintf "%s: %s" tag (String.escaped content)

let print_artifact (a : Conversation.artifact) =
  List.iter2
    (fun m (s : Conversation.source) -> Printf.printf "#%d %s %s\n" s.item s.card (message_line m))
    a.messages a.sources

let unwrap = function Ok x -> x | Error e -> failwith e
