type kind = User | Assistant | Synthesis | Trace
type relation = Reference | Inclusion | Child | Trace_of
type metadata = { kind : kind option; thread : string option; pin : bool }

let default_metadata = { kind = None; thread = None; pin = false }
let kind_property = "CONTEXT_KIND"
let thread_property = "THREAD_ID"
let pin_property = "PIN"
let auto_title_property = "AUTO_TITLE"
let ask_from_property = "ASK_FROM"

let kinds =
  [ ("user", User); ("assistant", Assistant); ("synthesis", Synthesis); ("trace", Trace) ]

let kind_name kind = fst (List.find (fun (_, k) -> k = kind) kinds)

let relation_name = function
  | Reference -> "reference"
  | Inclusion -> "inclusion"
  | Child -> "child"
  | Trace_of -> "trace"

let decode (properties : Org.property list) =
  let find key = List.find_opt (fun (p : Org.property) -> p.key = key) properties in
  let ( let* ) = Result.bind in
  let* kind =
    match find kind_property with
    | None -> Ok None
    | Some p -> (
        match List.assoc_opt (String.lowercase_ascii p.value) kinds with
        | Some k -> Ok (Some k)
        | None ->
            Error (p, "CONTEXT_KIND must be one of user, assistant, synthesis or trace"))
  in
  let* thread =
    match find thread_property with
    | None -> Ok None
    | Some p when Org.valid_id p.value -> Ok (Some p.value)
    | Some p -> Error (p, "THREAD_ID must be a non-empty identifier without spaces")
  in
  let* pin =
    match find pin_property with
    | None -> Ok false
    | Some p -> (
        match String.lowercase_ascii p.value with
        | "true" | "t" | "yes" -> Ok true
        | "false" | "nil" | "no" -> Ok false
        | _ -> Error (p, "PIN must be true or false"))
  in
  Ok { kind; thread; pin }
