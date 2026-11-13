(** Structural edit plans. OCaml computes byte-range edits against the
    analyzed text; Neovim applies them after checking buffer versions.
    Edits of one plan never overlap and all refer to the original text. *)

type edit = { path : string; start : int; stop : int; text : string }

(** Display labels written into new cards. *)
type labels = {
  question : string;
  answer : string;
  summary : string;
  trace : string;
  trace_source : string;
  sources : string;
  from : string;
  card : string;
}

val default_labels : labels

(** Pin the card at [offset], or the nearest enclosing card without
    [CONTEXT_KIND]; a plain heading becomes a card. Binds [thread] when the
    card has no [THREAD_ID] and unpins every other card. Returns the main
    card and its thread. *)
val pin :
  Workspace.t -> path:string -> offset:int -> thread:string -> now:float ->
  (edit list * string * string, string) result

(** Unpin the card at [offset] (or the pinned card); [THREAD_ID] stays. *)
val unpin : Workspace.t -> path:string -> offset:int -> (edit list * string, string) result

(** A new top-level card at the end of the file. With a selection, the
    card quotes it and the selection links to the card. *)
val new_card :
  Workspace.t -> path:string -> selection:(int * int) option -> title:string option ->
  labels -> now:float -> (edit list * string, string) result

type submit =
  | Ready of { edits : edit list; question : string; answer : string }
      (** the question card and the empty answer slot *)
  | Draft of { edits : edit list; draft : string }
      (** no question yet: an empty user card to write it in *)

(** Determine this turn's question and answer position. Trailing text in
    the main card becomes a user card. *)
val submit : Workspace.t -> main:string -> labels -> now:float -> (submit, string) result

type answer = {
  edits : edit list;
  draft : string option;  (** the next question card *)
  trace : string option;  (** the readable trace card *)
  removed : bool;  (** an empty slot was removed *)
}

(** Write the final answer into its slot, record the run in trace cards
    at [trace_path], and open the next question card. *)
val answer :
  Workspace.t -> answer:string -> text:string -> entries:Yojson.Safe.t list ->
  trace_path:string -> labels -> now:float -> (answer, string) result

(** Replace the first [count] conversation items of [main] with a new
    synthesis card. Summarized nested cards move after the main card,
    re-leveled; summarized transclusions are removed. Nothing is deleted. *)
val compact :
  Workspace.t -> main:string -> count:int -> summary:string -> labels -> now:float ->
  (edit list * string, string) result
