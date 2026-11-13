(** Org cards as source-located syntax.

    A card is a heading whose property drawer declares [:ID:], or a
    [#+begin_zk :id ...] block. Headings without an ID belong to the
    enclosing card. Parsing recognizes the reference forms and nested cards
    and assigns no graph semantics. Offsets are zero-based bytes. *)

type span = Ospero_core.Provenance.span

type property = {
  key : string;  (** upper-cased *)
  value : string;
  line : span;  (** the whole property line, without its newline *)
  value_span : span;
}

type link = {
  target : string;
  label : string option;
  span : span;  (** [[[id:X]]] or [[[id:X][label]]] *)
}

(** A keyword line such as [#+zk_include: :target X]. [span] covers the
    line including its newline. *)
type keyword = { target : string; span : span; target_span : span }

type item =
  | Text of span  (** verbatim source between other items *)
  | Link of link
  | Include of keyword  (** [#+zk_include: :target X] *)
  | Trace of keyword  (** [#+coact_trace: :target X] *)
  | Card of card  (** a nested card, at its position *)

and card = {
  id : string;
  level : int;  (** heading depth; a zk block is one deeper than its parent *)
  title : string;
  title_span : span;
  heading : span;  (** the heading or [#+begin_zk] line, without newline *)
  drawer : span option;  (** from [:PROPERTIES:] to [:END:] *)
  properties : property list;
  start : int;  (** heading start *)
  content_start : int;  (** first byte after the heading and drawer *)
  stop : int;  (** end of the subtree or block, exclusive *)
  block : bool;  (** declared by [#+begin_zk] *)
  items : item list;  (** own content and nested cards, in source order *)
}

type heading = {
  level : int;
  start : int;  (** heading line start *)
  stop : int;  (** subtree end *)
  title : string;
  line_stop : int;  (** heading line end, without newline *)
  drawer : span option;
  properties : property list;
}

type file = {
  path : string;
  text : string;
  cards : card list;  (** root cards, in source order *)
  headings : heading list;  (** every heading line, cards or not *)
}

type error = { span : span; message : string }

(** Parse a whole file. Malformed declarations are reported and skipped; the
    remaining cards are still returned. *)
val parse : path:string -> string -> file * error list

(** Cards in pre-order, nested cards after their parent. *)
val cards : file -> card list

val find : file -> string -> card option

(** The innermost card whose subtree contains the offset. *)
val card_at : file -> int -> card option

(** Ancestors of a card, innermost first. *)
val ancestors : file -> card -> card list

val property : card -> string -> property option

(** The source between two offsets. *)
val sub : string -> int -> int -> string

(** The card's own text with nested cards removed. *)
val own_text : file -> card -> string

(** Whether an identity is usable in [:ID:] and [id:] links. *)
val valid_id : string -> bool

(** Byte offset just after the end of the line containing [offset]
    (after its newline, or the end of text). *)
val line_after : string -> int -> int
