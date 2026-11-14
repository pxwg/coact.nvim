(** Turn directives written in a user card: [/name args] at the start of a
    line runs a Pi skill or prompt template, [@name] adds Neovim context.
    Only registered names count, so paths, Org emphasis and Typst
    references stay text. Source blocks, inline [$...$] math and [[[...]]]
    links are skipped. Directives take effect once, when their card is the
    question being sent. *)

type kind = Command | Context
type entry = { name : string; description : string }
type registry = { commands : entry list; contexts : entry list }

type t = {
  kind : kind;
  name : string;
  args : string;  (** the rest of the line, for commands *)
  start : int;  (** the token, from [/] or [@] *)
  stop : int;
}

val empty : registry
val describe : registry -> t -> string

(** Directives of a text starting at byte [base] of its file. *)
val scan : registry -> base:int -> string -> t list

(** Directives in a card's own text. *)
val in_card : registry -> Org.file -> Org.card -> t list

val kind_name : kind -> string
