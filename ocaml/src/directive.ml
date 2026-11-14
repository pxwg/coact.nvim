type kind = Command | Context
type entry = { name : string; description : string }
type registry = { commands : entry list; contexts : entry list }
type t = { kind : kind; name : string; args : string; start : int; stop : int }

let empty = { commands = []; contexts = [] }
let kind_name = function Command -> "command" | Context -> "context"

let describe registry d =
  let list = match d.kind with Command -> registry.commands | Context -> registry.contexts in
  match List.find_opt (fun (e : entry) -> e.name = d.name) list with Some e -> e.description | None -> ""

let known list name = List.exists (fun (e : entry) -> e.name = name) list
let is_space c = c = ' ' || c = '\t' || c = '\r'
let command_char = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | ':' | '-' -> true | _ -> false
let context_char = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false

(* Byte ranges of a line hidden from directives: inline math and links. *)
let hidden line =
  let n = String.length line in
  let rec go i acc =
    if i >= n then acc
    else if line.[i] = '$' then
      match String.index_from_opt line (i + 1) '$' with
      | Some j -> go (j + 1) ((i, j + 1) :: acc)
      | None -> acc
    else if i + 1 < n && line.[i] = '[' && line.[i + 1] = '[' then
      let rec close k = if k + 1 >= n then n else if line.[k] = ']' && line.[k + 1] = ']' then k + 2 else close (k + 1) in
      let j = close (i + 2) in
      go j ((i, j) :: acc)
    else go (i + 1) acc
  in
  go 0 []

let scan_line registry ~base line =
  let n = String.length line in
  let hide = hidden line in
  let visible i = not (List.exists (fun (a, b) -> i >= a && i < b) hide) in
  let rec span f i = if i < n && f line.[i] then span f (i + 1) else i in
  let command =
    let s = span is_space 0 in
    if s < n && line.[s] = '/' then
      let e = span command_char (s + 1) in
      let name = String.sub line (s + 1) (e - s - 1) in
      if name <> "" && (e = n || is_space line.[e]) && known registry.commands name then
        [ { kind = Command; name; args = String.trim (String.sub line e (n - e)); start = base + s; stop = base + e } ]
      else []
    else []
  in
  let rec contexts i acc =
    if i >= n then List.rev acc
    else if line.[i] = '@' && visible i && (i = 0 || is_space line.[i - 1] || line.[i - 1] = '(') then
      let e = span context_char (i + 1) in
      let name = String.sub line (i + 1) (e - i - 1) in
      if name <> "" && (e = n || not (line.[e] = ':' || line.[e] = '.' && e + 1 < n && context_char line.[e + 1]))
         && known registry.contexts name
      then contexts e ({ kind = Context; name; args = ""; start = base + i; stop = base + e } :: acc)
      else contexts (i + 1) acc
    else contexts (i + 1) acc
  in
  command @ contexts 0 []

let scan registry ~base text =
  let lines = String.split_on_char '\n' text in
  let _, _, out =
    List.fold_left
      (fun (offset, block, acc) line ->
        let t = String.lowercase_ascii (String.trim line) in
        let next = offset + String.length line + 1 in
        if block then (next, not (String.starts_with ~prefix:"#+end_" t), acc)
        else if String.starts_with ~prefix:"#+begin_" t then (next, true, acc)
        else (next, false, List.rev_append (scan_line registry ~base:offset line) acc))
      (base, false, []) lines
  in
  List.rev out

let in_card registry (file : Org.file) card =
  List.concat_map
    (fun (a, b) -> scan registry ~base:a (Org.sub file.text a b))
    (Plan.own_segments file card)
