(** The Coact Org frontend under the ospero-core standard contract.

    [parse] lowers card syntax into an Observation project whose bodies keep
    source text verbatim between reference occurrences; [interpret] turns
    each action into ordered contributions. Observation owns recursive
    expansion and note-context switching. *)
open Ospero_core

type id = Graph.Vertex_id.t

(** Body consumptions. References outside the identity space stay
    unresolved and keep their source text. *)
type consumption =
  | Link of { target : id; source : string }
  | Include of id
  | Child of id
  | Trace of id
  | Unresolved of { target : string; form : form; source : string }

and form = Cited | Included | Traced

module Action : sig
  type t =
    | Cite of { target : string; source : string }
    | Transclude of { target : string; source : string }
    | Trace of { target : string; source : string }
    | Define of (Model.metadata, t) Observation.Source.note Provenance.located

  (** Interpretation cannot fail; invalid input is rejected while parsing. *)
  type error = |
end

type diagnostic = { span : Provenance.span; message : string }

include
  Frontend.FRONTEND
    with type metadata := Model.metadata
     and type relation := Model.relation
     and type consumption := consumption
     and type action := Action.t
     and type error := Action.error
     and type parse_error := diagnostic
     and type input := Org.file list

type observation = (Model.metadata, Model.relation, consumption) Observation.t

type error =
  | Parse of diagnostic list
  | Observe of Action.error Observation.issue list

(** [Frontend.Make]: parse, expand, assemble. Policy is evaluated elsewhere. *)
val observe : Org.file list -> (observation, error) result

(** Decode every card's metadata, reporting each invalid property. *)
val check_metadata : Org.file -> diagnostic list

val id : string -> id
