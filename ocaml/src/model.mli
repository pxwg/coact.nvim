(** Coact card vocabulary: conversation kinds, relations and metadata. *)

(** The role a card plays in the current conversation. Authorship and
    revision provenance are recorded separately. *)
type kind = User | Assistant | Synthesis | Trace

type relation =
  | Reference  (** [[[id:X]]] *)
  | Inclusion  (** [#+zk_include] *)
  | Child  (** a nested card, from its parent *)
  | Trace_of  (** [#+coact_trace], from a readable trace to its source *)

type metadata = {
  kind : kind option;  (** [:CONTEXT_KIND:] *)
  thread : string option;  (** [:THREAD_ID:], the persistent chat thread *)
  pin : bool;  (** [:PIN:], whether this card is the current chat entry *)
}

val default_metadata : metadata

(** Property names: [CONTEXT_KIND], [THREAD_ID], [PIN]. *)
val kind_property : string

val thread_property : string
val pin_property : string

val kinds : (string * kind) list
val kind_name : kind -> string
val relation_name : relation -> string

(** Decode the Coact properties of a card; other properties are ignored.
    [Error] names the offending property and its value. *)
val decode : Org.property list -> (metadata, Org.property * string) result
