(* Substring search for completion contexts. *)

let last s token =
  let n = String.length s and m = String.length token in
  let rec go i = if i < 0 then None else if String.sub s i m = token then Some i else go (i - 1) in
  if m > n then None else go (n - m)
