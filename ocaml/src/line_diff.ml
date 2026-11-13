type op = Keep of string | Delete of string | Insert of string

let lines text =
  match String.split_on_char '\n' text with
  | l when List.length l > 1 && List.nth l (List.length l - 1) = "" ->
      List.rev (List.tl (List.rev l))
  | l -> l

let diff a b =
  let a = Array.of_list a and b = Array.of_list b in
  let n = Array.length a and m = Array.length b in
  let table = Array.make_matrix (n + 1) (m + 1) 0 in
  for i = n - 1 downto 0 do
    for j = m - 1 downto 0 do
      table.(i).(j) <-
        (if a.(i) = b.(j) then table.(i + 1).(j + 1) + 1
         else max table.(i + 1).(j) table.(i).(j + 1))
    done
  done;
  let rec walk i j acc =
    if i < n && j < m && a.(i) = b.(j) then walk (i + 1) (j + 1) (Keep a.(i) :: acc)
    else if i < n && (j = m || table.(i + 1).(j) >= table.(i).(j + 1)) then
      walk (i + 1) j (Delete a.(i) :: acc)
    else if j < m then walk i (j + 1) (Insert b.(j) :: acc)
    else List.rev acc
  in
  walk 0 0 []

let inserted a b =
  let _, acc =
    List.fold_left
      (fun (j, acc) op ->
        match op with
        | Keep _ -> (j + 1, acc)
        | Insert _ -> (j + 1, j :: acc)
        | Delete _ -> (j, acc))
      (0, []) (diff a b)
  in
  List.rev acc

let unified ?(context = 1) a b =
  let ops = Array.of_list (diff a b) in
  let n = Array.length ops in
  let changed i = match ops.(i) with Keep _ -> false | _ -> true in
  if not (Array.exists (function Keep _ -> false | _ -> true) ops) then None
  else
    let near i =
      let lo = max 0 (i - context) and hi = min (n - 1) (i + context) in
      let rec any k = k <= hi && (changed k || any (k + 1)) in
      any lo
    in
    let buf = Buffer.create 256 in
    let gap = ref false in
    Array.iteri
      (fun i op ->
        if near i then (
          if !gap then Buffer.add_string buf "...\n";
          gap := false;
          match op with
          | Keep l -> Buffer.add_string buf ("  " ^ l ^ "\n")
          | Delete l -> Buffer.add_string buf ("- " ^ l ^ "\n")
          | Insert l -> Buffer.add_string buf ("+ " ^ l ^ "\n"))
        else if Buffer.length buf > 0 then gap := true)
      ops;
    Some (Buffer.contents buf)
