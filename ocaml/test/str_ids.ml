(* Replace generated identities with stable letters for expect output:
   the n-th identity becomes the n-th of Q, A, D, S, T. *)

let letters = [| "Q"; "A"; "D"; "S"; "T" |]

let replace text id letter =
  let b = Buffer.create (String.length text) in
  let n = String.length id in
  let rec go i =
    if i >= String.length text then ()
    else if n > 0 && i + n <= String.length text && String.sub text i n = id then (
      Buffer.add_string b letter;
      go (i + n))
    else (
      Buffer.add_char b text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

let mask ids text =
  let text = ref text in
  List.iteri (fun i id -> if i < Array.length letters then text := replace !text id letters.(i)) ids;
  !text
