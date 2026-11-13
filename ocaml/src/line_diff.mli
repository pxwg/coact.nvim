(** Line diffs by longest common subsequence. *)

type op = Keep of string | Delete of string | Insert of string

val diff : string list -> string list -> op list

(** Indices of [after] lines that are not kept from [before]. *)
val inserted : string list -> string list -> int list

(** A compact unified rendering with [context] lines around changes.
    [None] when the inputs are equal. *)
val unified : ?context:int -> string list -> string list -> string option

val lines : string -> string list
