(** Located findings reported to the editor. *)

type severity = Error | Warning | Information | Hint

type t = {
  span : Ospero_core.Provenance.span;
  severity : severity;
  code : string;
  message : string;
}

let make ?(severity = Error) ~code span message = { span; severity; code; message }
let is_error d = d.severity = Error
