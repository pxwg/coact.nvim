type entry = { id : string option; message : Yojson.Safe.t }

let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string_member key json = match member key json with Some (`String s) -> Some s | _ -> None
let role message = string_member "role" message

let entry_of_json json =
  match string_member "type" json, member "message" json with
  | Some "message", Some message -> Some { id = string_member "id" json; message }
  | _, _ -> (
      match role json with Some _ -> Some { id = None; message = json } | None -> None)

let parse text =
  let lines = Line_diff.lines text in
  let lower l = String.lowercase_ascii (String.trim l) in
  let rec find = function
    | [] -> None
    | l :: rest ->
        let t = lower l in
        if t = "#+begin_src jsonl" || t = "#+begin_src json" || String.starts_with ~prefix:"#+begin_src jsonl " t
        then Some rest
        else find rest
  in
  match find lines with
  | None -> Ok None
  | Some rest ->
      let rec collect acc n = function
        | [] -> Error "Unterminated jsonl block"
        | l :: _ when lower l = "#+end_src" -> Ok (List.rev acc)
        | l :: tl when String.trim l = "" -> collect acc (n + 1) tl
        | l :: tl -> (
            let l = Org_text.unescape_block_line l in
            match Yojson.Safe.from_string l with
            | json -> (
                match entry_of_json json with
                | Some e -> collect (e :: acc) (n + 1) tl
                | None -> collect acc (n + 1) tl)
            | exception Yojson.Json_error message ->
                Error (Printf.sprintf "Invalid JSON on record line %d: %s" n message))
      in
      Result.map Option.some (collect [] 1 rest)

let own_text ws id =
  match Workspace.find ws id with
  | Some (file, card) -> Some (Org.own_text file card)
  | None -> None

let trace_target ws id =
  match Workspace.body ws id with
  | Some body ->
      List.find_map
        (fun (c : _ Ospero_core.Provenance.located) ->
          match c.value with
          | Ospero_core.Observation.Observed.Consume (Frontend.Trace v) ->
              Some (Ospero_core.Graph.Vertex_id.to_string v)
          | _ -> None)
        body
  | None -> None

let has_record ws id =
  match own_text ws id with
  | Some text -> ( match parse text with Ok (Some _) -> true | _ -> false)
  | None -> false

let source ws id =
  if not (Workspace.mem ws id) then Error ("Unknown trace card " ^ id)
  else if Workspace.kind ws id <> Some Model.Trace then Error (Printf.sprintf "Card %s is not a trace card" id)
  else
    match trace_target ws id with
    | Some target ->
        if Workspace.kind ws target <> Some Model.Trace then
          Error (Printf.sprintf "Trace source %s is not a trace card" target)
        else if has_record ws target then Ok target
        else Error (Printf.sprintf "Trace source %s has no jsonl record" target)
    | None ->
        if has_record ws id then Ok id
        else Error (Printf.sprintf "Trace card %s has neither a record nor #+coact_trace" id)

let record ws id =
  match source ws id with
  | Error e -> Error e
  | Ok src -> (
      match own_text ws src with
      | None -> Error ("Unknown trace card " ^ src)
      | Some text -> (
          match parse text with
          | Ok (Some entries) -> Ok entries
          | Ok None -> Error (Printf.sprintf "Trace source %s has no jsonl record" src)
          | Error e -> Error e))

let blocks message = match member "content" message with Some (`List l) -> l | _ -> []

let text message =
  match member "content" message with
  | Some (`String s) -> s
  | _ ->
      blocks message
      |> List.filter_map (fun b ->
             match string_member "type" b with Some "text" -> string_member "text" b | _ -> None)
      |> String.concat ""

let calls_tools message =
  List.exists (fun b -> string_member "type" b = Some "toolCall") (blocks message)

let final_answer entries =
  match List.rev entries with
  | { message; _ } :: _ when role message = Some "assistant" && not (calls_tools message) -> Some message
  | _ -> None

let process entries =
  let entries =
    match final_answer entries with
    | Some _ -> List.rev (List.tl (List.rev entries))
    | None -> entries
  in
  List.filter
    (fun e -> match role e.message with Some ("assistant" | "toolResult") -> true | _ -> false)
    entries

let shorten ?(limit = 100) s =
  let s = String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) (String.trim s) in
  if String.length s <= limit then s
  else
    let rec cut i = if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then cut (i - 1) else i in
    String.sub s 0 (cut limit) ^ "…"

let arguments_summary = function
  | `Assoc fields ->
      fields
      |> List.map (fun (k, v) ->
             let v = match v with `String s -> s | v -> Yojson.Safe.to_string v in
             k ^ "=" ^ shorten ~limit:40 v)
      |> String.concat " "
  | _ -> ""

let readable entries =
  List.concat_map
    (fun { message; _ } ->
      match role message with
      | Some "assistant" ->
          List.filter_map
            (fun b ->
              match string_member "type" b with
              | Some "thinking" -> (
                  match string_member "thinking" b with
                  | Some t when String.trim t <> "" -> Some ("- thinking: " ^ shorten t)
                  | _ -> None)
              | Some "toolCall" ->
                  let name = Option.value ~default:"tool" (string_member "name" b) in
                  let args = arguments_summary (Option.value ~default:`Null (member "arguments" b)) in
                  Some (Printf.sprintf "- call %s %s" name args)
              | Some "text" -> (
                  match string_member "text" b with
                  | Some t when String.trim t <> "" -> Some ("- says: " ^ shorten t)
                  | _ -> None)
              | _ -> None)
            (blocks message)
          @ (match string_member "stopReason" message with
            | Some ("error" | "aborted" as r) ->
                [ Printf.sprintf "- stopped (%s)%s" r
                    (match string_member "errorMessage" message with Some m -> ": " ^ shorten m | None -> "") ]
            | _ -> [])
      | Some "custom" -> (
          let name =
            match member "details" message with
            | Some d -> Option.value ~default:"" (string_member "name" d)
            | None -> ""
          in
          match string_member "customType" message with
          | Some "coact.command" -> [ Printf.sprintf "- ran /%s (%d characters)" name (String.length (text message)) ]
          | Some "coact.context" -> [ Printf.sprintf "- added @%s (%d characters)" name (String.length (text message)) ]
          | _ -> [])
      | Some "toolResult" ->
          let name = Option.value ~default:"tool" (string_member "toolName" message) in
          let status = match member "isError" message with Some (`Bool true) -> "error" | _ -> "ok" in
          [ Printf.sprintf "- result %s (%s): %s" name status (shorten (text message)) ]
      | _ -> [])
    entries

let block entries =
  let lines = List.map (fun e -> Org_text.escape_block_line (Yojson.Safe.to_string e)) entries in
  String.concat "\n" (("#+begin_src jsonl" :: lines) @ [ "#+end_src" ])
