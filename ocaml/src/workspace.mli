(** One analysis of a chat workspace: parsed files, the observation, and
    diagnostics. Files with syntax or metadata errors stay available for
    navigation but are left out of the observation, so a broken file
    cannot contribute stale semantics. *)
module Observation := Ospero_core.Observation
module Provenance := Ospero_core.Provenance

type document = { path : string; text : string }

type t = {
  files : Org.file list;
  observation : Frontend.observation option;
      (** [None] when identities conflict or the graph is invalid *)
  diagnostics : Diagnostic.t list;  (** syntax, metadata and observation *)
}

val analyze : document list -> t
val file : t -> string -> Org.file option

(** The card and its file, by identity (first definition wins). *)
val find : t -> string -> (Org.file * Org.card) option

val mem : t -> string -> bool

(** Decoded metadata of a card in the observation, else from its source. *)
val metadata : t -> string -> Model.metadata

val kind : t -> string -> Model.kind option

(** Observed body of a card. *)
val body :
  t -> string -> Frontend.consumption Observation.Observed.content Provenance.located list option

val title : t -> string -> string
