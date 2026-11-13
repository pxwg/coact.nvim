(** Trace records: Pi session entries kept verbatim in an Org card.

    A source card stores its record in a [#+begin_src jsonl] block. A
    readable card consumes a source through [#+coact_trace: :target ID].
    Neither reading nor rendering re-executes any tool. *)

type entry = { id : string option; message : Yojson.Safe.t }

(** Entries of a jsonl block in a card's own text. [Ok None] when the card
    has no record block. *)
val parse : string -> (entry list option, string) result

(** Resolve a readable or source card to the source card's identity. *)
val source : Workspace.t -> string -> (string, string) result

(** The record behind a readable or source card. *)
val record : Workspace.t -> string -> (entry list, string) result

val role : Yojson.Safe.t -> string option

(** Visible text of a message's text blocks. *)
val text : Yojson.Safe.t -> string

(** The final answer: the last assistant message, when it calls no tools. *)
val final_answer : entry list -> Yojson.Safe.t option

(** Process messages that precede the final answer: assistant and tool
    result messages in original order. *)
val process : entry list -> entry list

(** A short human-readable account, one item per line. *)
val readable : entry list -> string list

(** The Org source block holding entries, one JSON object per line. *)
val block : Yojson.Safe.t list -> string
