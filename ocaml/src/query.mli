(** Read-only views for the agent's card tools: structure first, text on
    demand. Results are JSON for the tool layer. *)

(** Rough token count of a text: four characters a token. *)
val tokens : string -> int

(** A thread's outline: its items in order with card IDs, kinds, titles,
    nesting and sizes, and the traces their answers replay. No text. *)
val thread_view : Workspace.t -> main:string -> (Yojson.Safe.t, string) result

(** One card: metadata, its own text (nested cards as one-line placeholders)
    from line [offset] (1-based) for at most [limit] lines, its nested
    cards, links and backlinks. A trace card reads as its readable account
    unless [raw]. *)
val card_read :
  Workspace.t -> id:string -> offset:int -> limit:int -> raw:bool -> (Yojson.Safe.t, string) result

(** Cards whose title or own text contain every word of [query]
    (case-insensitive), title matches first, with a snippet. Raw trace
    records are left out. *)
val card_search : Workspace.t -> query:string -> limit:int -> Yojson.Safe.t
