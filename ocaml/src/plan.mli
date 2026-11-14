(** Structural edit plans. OCaml computes byte-range edits against the
    analyzed text; Neovim applies them after checking buffer versions.
    Edits of one plan never overlap and all refer to the original text. *)

type edit = { path : string; start : int; stop : int; text : string }

(** How generated cards are laid out: a blank line before each card's
    heading, and between its drawer and its body. *)
type layout = { blank_before_heading : bool; blank_after_drawer : bool }

val default_layout : layout

(** Display labels and the layout of new cards. *)
type labels = {
  layout : layout;
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

(** A new top-level card: at the end of the file, or, with [into], alone
    in a new file [into/<id>.org]. With a selection, the card quotes it and
    the selection links to the card. Returns the card and its file. *)
val new_card :
  Workspace.t -> path:string -> ?into:string -> selection:(int * int) option ->
  title:string option -> labels -> now:float -> (edit list * string * string, string) result

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

(** The byte ranges of a card's own text: after its drawer, around nested
    cards, before a block card's end line. *)
val own_segments : Org.file -> Org.card -> (int * int) list

(** A review note: [anchor] is a line of the proposed text of [path]. *)
type note = { path : string; anchor : string; note : string }

(** A card in a new file [dir/<id>.org]. [kind] [None] makes a plain note.
    The body is made Org-safe. Returns the edit, the card and its file. *)
val create :
  Workspace.t -> layout:layout -> dir:string -> title:string -> kind:Model.kind option -> body:string -> now:float ->
  (edit * string * string, string) result

(** Exact replacements in a card's own text: never in its heading, drawer or
    nested cards. Each [old] must occur exactly once; an empty [old] fills a
    blank card. Replacements may not start a heading or a drawer. *)
val edit : ?layout:layout -> Workspace.t -> id:string -> (string * string) list -> (edit list, string) result

(** Set the conversation items of thread [main] to [ids], in order. Cards
    leaving the thread move after the main card, unchanged; new ones are
    transcluded. Org nesting cannot follow a transclusion, so every item up
    to the last transcluded one is transcluded, its nested card moving after
    the main card too. Nothing is deleted. *)
val arrange :
  ?layout:layout -> Workspace.t -> main:string -> string list -> (edit list * note list, string) result

(** Compaction as a changeset: a synthesis card in [dir/<id>.org] replaces
    the first [count] items of [main]. Returns its edits, review notes and
    the synthesis card. *)
val compact :
  Workspace.t -> main:string -> count:int -> summary:string -> dir:string -> labels -> now:float ->
  (edit list * note list * string, string) result
