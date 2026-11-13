(** Chat threads: main cards that declare [:THREAD_ID:] or [:PIN:].

    Thread structure is checked by an ospero-core policy over the observed
    graph. A failed check blocks export; nothing is created to replace a
    missing or conflicting identity. *)

type t = { main : string; thread : string option; pin : bool }

(** Cards declaring a thread or a pin, in source order. *)
val all : Workspace.t -> t list

(** The pinned main card, when exactly one is pinned and bound. *)
val pinned : Workspace.t -> t option

(** Policy diagnostics for thread structure. *)
val check : Workspace.t -> Diagnostic.t list

(** The thread main card enclosing a card through nesting, if any. *)
val main_of : Workspace.t -> string -> t option
