(** The conversation consumer: linearize a thread main card into Pi's
    native AgentMessage sequence.

    The main card's nested cards and transclusions are consumed in order.
    [user] and [assistant] cards become the corresponding messages;
    [synthesis] becomes a [coact.synthesis] custom message, which Pi sends
    as user content; a card without [CONTEXT_KIND] is reference material.
    An assistant card's links to trace cards are process dependencies: the
    recorded tool calls and results come first, then the card's current
    text replaces the recorded final answer. Provenance travels beside the
    messages, never inside them. *)

type source = { item : int; card : string; role : string }

type item = {
  card : string;
  title : string;
  kind : Model.kind option;
  included : bool;  (** transcluded rather than nested *)
}

(** A card's rendered text, used to describe revisions between turns. *)
type card_text = { id : string; title : string; kind : string option; text : string }

type artifact = {
  main : string;
  thread : string option;
  messages : Yojson.Safe.t list;  (** Pi AgentMessage values *)
  sources : source list;  (** one per message *)
  items : item list;  (** the main card's conversation items *)
  cards : card_text list;
  question : string option;  (** the trailing user card *)
}

type options = {
  require_question : bool;
  baseline : card_text list option;
      (** cards as of the previous turn; changes become a revision note *)
  now : float;
}

(** Export fails closed: any error diagnostic withholds the artifact. *)
val export :
  Workspace.t -> main:string -> options -> (artifact * Diagnostic.t list, Diagnostic.t list) result

(** Consumer diagnostics of every thread main card. *)
val lint : Workspace.t -> Diagnostic.t list

(** Strip blank leading and trailing lines and trailing whitespace. *)
val trim_text : string -> string

val to_json : artifact -> Yojson.Safe.t
val cards_of_json : Yojson.Safe.t -> card_text list
