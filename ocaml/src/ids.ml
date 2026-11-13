(** Fresh card identities: [YYYYMMDDTHHMMSS-xxxx], unique against [taken]. *)

let () = Random.self_init ()

let stamp now =
  let t = Unix.localtime now in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
    t.tm_hour t.tm_min t.tm_sec

let fresh ~now ~taken =
  let base = stamp now in
  let rec go n =
    let id = Printf.sprintf "%s-%04x" base (Random.int 0x10000) in
    if taken id && n < 1000 then go (n + 1) else id
  in
  go 0

(** A supply that never repeats within one plan. *)
let supply ~now ~taken =
  let used = Hashtbl.create 8 in
  fun () ->
    let id = fresh ~now ~taken:(fun id -> taken id || Hashtbl.mem used id) in
    Hashtbl.replace used id ();
    id
