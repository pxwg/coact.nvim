(** Org-safe text for content written into cards.

    Agent answers often arrive as Markdown. Converting the few constructs
    that would break card structure keeps the answer inside its card: a
    column-0 [* ] would start a new heading, and fenced code becomes an Org
    source block whose heading-like lines are comma-escaped. *)

let starts_with ~prefix s = String.starts_with ~prefix s

let is_fence line =
  let t = String.trim line in
  starts_with ~prefix:"```" t || starts_with ~prefix:"~~~" t

let fence_lang line =
  let t = String.trim line in
  let t = String.sub t 3 (String.length t - 3) in
  String.trim t

(* Inside an Org block, lines starting with [*] or [#+] need a comma. *)
let escape_block_line line =
  if starts_with ~prefix:"*" line || starts_with ~prefix:"#+" line || starts_with ~prefix:"," line
  then "," ^ line
  else line

let unescape_block_line line =
  if starts_with ~prefix:",*" line || starts_with ~prefix:",#+" line || starts_with ~prefix:",," line
  then String.sub line 1 (String.length line - 1)
  else line

let replace_pairs ~marker ~by line =
  (* Replace balanced [marker]text[marker] pairs on one line. *)
  let ml = String.length marker in
  let buf = Buffer.create (String.length line) in
  let rec go i =
    match
      let rec find j =
        if j + ml > String.length line then None
        else if String.sub line j ml = marker then Some j
        else find (j + 1)
      in
      find i
    with
    | None -> Buffer.add_string buf (String.sub line i (String.length line - i))
    | Some a -> (
        let rec find j =
          if j + ml > String.length line then None
          else if String.sub line j ml = marker then Some j
          else find (j + 1)
        in
        match find (a + ml) with
        | Some b when b > a + ml ->
            Buffer.add_string buf (String.sub line i (a - i));
            Buffer.add_string buf by;
            Buffer.add_string buf (String.sub line (a + ml) (b - a - ml));
            Buffer.add_string buf by;
            go (b + ml)
        | _ -> Buffer.add_string buf (String.sub line i (String.length line - i)))
  in
  go 0;
  Buffer.contents buf

let heading_line line =
  (* Markdown ATX heading: up to six #, then a space. *)
  let n = String.length line in
  let rec hashes i = if i < n && line.[i] = '#' then hashes (i + 1) else i in
  let h = hashes 0 in
  if h >= 1 && h <= 6 && h < n && line.[h] = ' ' then
    Some (String.trim (String.sub line h (n - h)))
  else None

let star_bullet line =
  let n = String.length line in
  let rec stars i = if i < n && line.[i] = '*' then stars (i + 1) else i in
  let s = stars 0 in
  if s > 0 && (s = n || line.[s] = ' ' || line.[s] = '\t') then
    Some (String.trim (String.sub line s (n - s)))
  else None

let inline line =
  line |> replace_pairs ~marker:"**" ~by:"*" |> replace_pairs ~marker:"`" ~by:"~"

let of_markdown text =
  let lines = Line_diff.lines text in
  let rec go in_fence acc = function
    | [] ->
        let acc = if in_fence then "#+end_src" :: acc else acc in
        List.rev acc
    | line :: rest when is_fence line ->
        if in_fence then go false ("#+end_src" :: acc) rest
        else
          let lang = fence_lang line in
          let header = if lang = "" then "#+begin_src text" else "#+begin_src " ^ lang in
          go true (header :: acc) rest
    | line :: rest when in_fence -> go true (escape_block_line line :: acc) rest
    | line :: rest -> (
        match heading_line line with
        | Some title -> go false (("*" ^ title ^ "*") :: acc) rest
        | None -> (
            match star_bullet line with
            | Some item -> go false (("- " ^ inline item) :: acc) rest
            | None -> go false (inline line :: acc) rest))
  in
  let out = go false [] lines in
  (* Trim leading and trailing blank lines. *)
  let blank l = String.trim l = "" in
  let rec drop = function l :: tl when blank l -> drop tl | l -> l in
  let out = List.rev (drop (List.rev (drop out))) in
  String.concat "\n" out

(** Plain text of a heading title: first non-blank line, shortened. *)
let title_of ?(limit = 60) text =
  let line =
    match List.find_opt (fun l -> String.trim l <> "") (Line_diff.lines text) with
    | Some l -> String.trim l
    | None -> ""
  in
  let line = String.map (function '\t' -> ' ' | c -> c) line in
  let line = if String.starts_with ~prefix:"#+" line then "" else line in
  if String.length line <= limit then line
  else
    (* Cut on a UTF-8 boundary. *)
    let rec cut i = if i > 0 && Char.code line.[i] land 0xC0 = 0x80 then cut (i - 1) else i in
    String.sub line 0 (cut limit) ^ "…"
