module P = Ospero_core.Provenance

type span = P.span

type property = { key : string; value : string; line : span; value_span : span }
type link = { target : string; label : string option; span : span }
type keyword = { target : string; span : span; target_span : span }

type item =
  | Text of span
  | Link of link
  | Include of keyword
  | Trace of keyword
  | Card of card

and card = {
  id : string;
  level : int;
  title : string;
  title_span : span;
  heading : span;
  drawer : span option;
  properties : property list;
  start : int;
  content_start : int;
  stop : int;
  block : bool;
  items : item list;
}

type heading = {
  level : int;
  start : int;
  stop : int;
  title : string;
  line_stop : int;
  drawer : span option;
  properties : property list;
}
type file = { path : string; text : string; cards : card list; headings : heading list }
type error = { span : span; message : string }

let sub text start stop = String.sub text start (stop - start)

let is_space = function ' ' | '\t' | '\r' -> true | _ -> false

let valid_id id =
  id <> ""
  && not
       (String.exists
          (function ' ' | '\t' | '\n' | '\r' | '[' | ']' -> true | _ -> false)
          id)

let line_after text offset =
  match String.index_from_opt text offset '\n' with
  | Some n -> n + 1
  | None -> String.length text

(* Lines as (start, stop) byte ranges; [stop] excludes the newline. *)
let lines text =
  let n = String.length text in
  let rec loop start acc =
    if start > n then List.rev acc
    else
      match String.index_from_opt text start '\n' with
      | Some i -> loop (i + 1) ((start, i) :: acc)
      | None -> if start = n then List.rev acc else List.rev ((start, n) :: acc)
  in
  Array.of_list (loop 0 [])

let next_line_start text (_, stop) = if stop < String.length text then stop + 1 else stop

let skip_spaces text stop i =
  let rec go i = if i < stop && is_space text.[i] then go (i + 1) else i in
  go i

let rtrim text start stop =
  let rec go j = if j > start && is_space text.[j - 1] then go (j - 1) else j in
  go stop

let heading_level text (s, e) =
  let rec stars i = if i < e && text.[i] = '*' then stars (i + 1) else i in
  let i = stars s in
  let n = i - s in
  if n > 0 && (i = e || text.[i] = ' ' || text.[i] = '\t') then Some n else None

(* Title bytes after the stars, without trailing Org tags. *)
let title_range text (s, e) level =
  let start = skip_spaces text e (s + level) in
  let stop = rtrim text start e in
  let stop =
    if stop - start >= 3 && text.[stop - 1] = ':' then
      let rec back j = if j > start && not (is_space text.[j - 1]) then back (j - 1) else j in
      let tag_start = back stop in
      if tag_start > start && text.[tag_start] = ':' && tag_start < stop - 1 then
        rtrim text start tag_start
      else stop
    else stop
  in
  (start, stop)

let trimmed text (s, e) =
  let a = skip_spaces text e s in
  let b = rtrim text a e in
  sub text a b

let lower_trimmed text range = String.lowercase_ascii (trimmed text range)

let file_span path start stop = { P.file = path; start; stop }

(* [:KEY: value] *)
let property_of_line path text (s, e) =
  let a = skip_spaces text e s in
  if a < e && text.[a] = ':' then
    match String.index_from_opt text (a + 1) ':' with
    | Some k when k < e && k > a + 1 ->
        let key = String.uppercase_ascii (sub text (a + 1) k) in
        if String.exists is_space key then None
        else
          let vs = skip_spaces text e (k + 1) in
          let ve = rtrim text vs e in
          Some
            {
              key;
              value = sub text vs ve;
              line = file_span path s e;
              value_span = file_span path vs ve;
            }
    | _ -> None
  else None

(* Header arguments: [:key value :key "quoted value"], keys lower-cased. *)
let header_args path text start stop =
  let rec loop i acc =
    let i = skip_spaces text stop i in
    if i >= stop then List.rev acc
    else if text.[i] = ':' then
      let rec word j = if j < stop && not (is_space text.[j]) then word (j + 1) else j in
      let ke = word i in
      let key = String.lowercase_ascii (sub text (i + 1) ke) in
      let vs = skip_spaces text stop ke in
      if vs < stop && text.[vs] = '"' then
        let close =
          match String.index_from_opt text (vs + 1) '"' with
          | Some c when c < stop -> c
          | _ -> stop
        in
        let value = sub text (vs + 1) close in
        loop (min stop (close + 1))
          ((key, value, file_span path (vs + 1) close) :: acc)
      else if vs < stop && text.[vs] = ':' then loop vs ((key, "", file_span path vs vs) :: acc)
      else
        let ve = word vs in
        loop ve ((key, sub text vs ve, file_span path vs ve) :: acc)
    else
      (* A bare word: treat it as a positional target. *)
      let rec word j = if j < stop && not (is_space text.[j]) then word (j + 1) else j in
      let we = word i in
      loop we (("", sub text i we, file_span path i we) :: acc)
  in
  loop start []

(* [#+name:] at the start of a trimmed line, case-insensitive; returns the
   offset after the colon. *)
let keyword_line text (s, e) name =
  let a = skip_spaces text e s in
  let prefix = "#+" ^ name ^ ":" in
  let n = String.length prefix in
  if a + n <= e && String.lowercase_ascii (sub text a (a + n)) = prefix then Some (a + n)
  else None

(* [#+begin_name rest]: returns (name, offset after name). *)
let begin_block text (s, e) =
  let a = skip_spaces text e s in
  let prefix = "#+begin_" in
  let n = String.length prefix in
  if a + n < e && String.lowercase_ascii (sub text a (a + n)) = prefix then
    let rec word j = if j < e && not (is_space text.[j]) then word (j + 1) else j in
    let we = word (a + n) in
    Some (String.lowercase_ascii (sub text (a + n) we), we)
  else None

let is_end_block text range name = lower_trimmed text range = "#+end_" ^ name

let verbatim_blocks = [ "src"; "example"; "export"; "comment"; "verse" ]

type ctx = {
  path : string;
  text : string;
  lines : (int * int) array;
  errors : error list ref;
}

let error ctx start stop message =
  ctx.errors := { span = file_span ctx.path start stop; message } :: !(ctx.errors)

(* Index of the line starting at [offset]. Lines are sorted by start. *)
let line_index ctx offset =
  let rec search lo hi =
    if lo >= hi then lo
    else
      let mid = (lo + hi) / 2 in
      if fst ctx.lines.(mid) < offset then search (mid + 1) hi else search lo mid
  in
  search 0 (Array.length ctx.lines)

(* Inline [[id:X]] and [[id:X][label]] links within [start, stop). *)
let scan_links ctx start stop =
  let text = ctx.text in
  let rec find i acc =
    match
      if i >= stop then None
      else
        let rec look j =
          if j + 5 > stop then None
          else if String.sub text j 5 = "[[id:" then Some j
          else look (j + 1)
        in
        look i
    with
    | None -> List.rev acc
    | Some j -> (
        let ts = j + 5 in
        let rec close k = if k < stop && text.[k] <> ']' && text.[k] <> '[' then close (k + 1) else k in
        let te = close ts in
        if te + 1 < stop && text.[te] = ']' && text.[te + 1] = ']' then
          let target = sub text ts te in
          if valid_id target then
            find (te + 2)
              ({ target; label = None; span = file_span ctx.path j (te + 2) } :: acc)
          else find (j + 1) acc
        else if te + 1 < stop && text.[te] = ']' && text.[te + 1] = '[' then
          match String.index_from_opt text (te + 2) ']' with
          | Some le when le + 1 < stop && text.[le + 1] = ']' ->
              let target = sub text ts te in
              if valid_id target then
                find (le + 2)
                  ({
                     target;
                     label = Some (sub text (te + 2) le);
                     span = file_span ctx.path j (le + 2);
                   }
                  :: acc)
              else find (j + 1) acc
          | _ -> find (j + 1) acc
        else find (j + 1) acc)
  in
  find start []

let keyword_item ctx (s, e) after name =
  let args = header_args ctx.path ctx.text after e in
  let target =
    match List.find_opt (fun (k, _, _) -> k = "target") args with
    | Some (_, v, sp) -> Some (v, sp)
    | None -> (
        match List.find_opt (fun (k, _, _) -> k = "") args with
        | Some (_, v, sp) -> Some (v, sp)
        | None -> None)
  in
  match target with
  | Some (target, target_span) when valid_id target ->
      let stop = next_line_start ctx.text (s, e) in
      Some { target; span = file_span ctx.path s stop; target_span }
  | _ ->
      error ctx s e (Printf.sprintf "#+%s needs :target <card-id>" name);
      None

(* Items of a region made of whole lines. [level] is the enclosing card's. *)
let rec scan_region ctx ~level start stop =
  let text = ctx.text in
  let items = ref [] in
  let text_start = ref None in
  let push item = items := item :: !items in
  let flush upto =
    (match !text_start with
    | Some s when upto > s -> push (Text (file_span ctx.path s upto))
    | _ -> ());
    text_start := None
  in
  let add_text s e =
    (match !text_start with None -> text_start := Some s | Some _ -> ());
    ignore e
  in
  let add_line_with_links (s, e) =
    let next = next_line_start text (s, e) in
    let links = scan_links ctx s e in
    let cursor =
      List.fold_left
        (fun cursor (l : link) ->
          add_text cursor l.span.start;
          flush l.span.start;
          push (Link l);
          l.span.stop)
        s links
    in
    add_text cursor next
  in
  let first = line_index ctx start in
  let n = Array.length ctx.lines in
  let rec loop i =
    if i >= n || fst ctx.lines.(i) >= stop then ()
    else
      let ((s, e) as range) = ctx.lines.(i) in
      match keyword_line text range "zk_include" with
      | Some after ->
          flush s;
          Option.iter (fun k -> push (Include k)) (keyword_item ctx range after "zk_include");
          loop (i + 1)
      | None -> (
          match keyword_line text range "coact_trace" with
          | Some after ->
              flush s;
              Option.iter (fun k -> push (Trace k)) (keyword_item ctx range after "coact_trace");
              loop (i + 1)
          | None -> (
              match begin_block text range with
              | Some ("zk", after) -> (
                  let rec find_end j =
                    if j >= n || fst ctx.lines.(j) >= stop then None
                    else if is_end_block text ctx.lines.(j) "zk" then Some j
                    else find_end (j + 1)
                  in
                  match find_end (i + 1) with
                  | None ->
                      error ctx s e "Unterminated #+begin_zk block";
                      add_text s (next_line_start text range);
                      loop (i + 1)
                  | Some j -> (
                      flush s;
                      let end_range = ctx.lines.(j) in
                      let block_stop = next_line_start text end_range in
                      let content_start = next_line_start text range in
                      let args = header_args ctx.path text after e in
                      let get k = List.find_opt (fun (key, _, _) -> key = k) args in
                      match get "id" with
                      | Some (_, id, _) when valid_id id ->
                          let title, title_span =
                            match get "title" with
                            | Some (_, t, sp) -> (t, sp)
                            | None -> ("", file_span ctx.path s s)
                          in
                          let properties =
                            List.filter_map
                              (fun (k, v, sp) ->
                                if k = "" || k = "title" || k = "id" then None
                                else
                                  Some
                                    {
                                      key = String.uppercase_ascii k;
                                      value = v;
                                      line = file_span ctx.path s e;
                                      value_span = sp;
                                    })
                              args
                          in
                          let items =
                            scan_region ctx ~level:(level + 1) content_start (fst end_range)
                          in
                          push
                            (Card
                               {
                                 id;
                                 level = level + 1;
                                 title;
                                 title_span;
                                 heading = file_span ctx.path s e;
                                 drawer = None;
                                 properties;
                                 start = s;
                                 content_start;
                                 stop = block_stop;
                                 block = true;
                                 items;
                               });
                          loop (j + 1)
                      | _ ->
                          error ctx s e "#+begin_zk needs a valid :id";
                          add_text s block_stop;
                          loop (j + 1)))
              | Some (name, _) when List.mem name verbatim_blocks -> (
                  (* Verbatim content: no references, kept as text. *)
                  let rec find_end j =
                    if j >= n || fst ctx.lines.(j) >= stop then None
                    else if is_end_block text ctx.lines.(j) name then Some j
                    else find_end (j + 1)
                  in
                  match find_end (i + 1) with
                  | Some j ->
                      add_text s (next_line_start text ctx.lines.(j));
                      loop (j + 1)
                  | None ->
                      add_line_with_links range;
                      loop (i + 1))
              | _ ->
                  add_line_with_links range;
                  loop (i + 1)))
  in
  loop first;
  flush stop;
  List.rev !items

type raw_heading = {
  h_level : int;
  h_line : int * int;
  h_stop : int;
  h_title : int * int;
  h_drawer : (span * property list * int) option;  (* drawer, properties, content start *)
}

let parse ~path text =
  let ctx = { path; text; lines = lines text; errors = ref [] } in
  let n = Array.length ctx.lines in
  let total = String.length text in
  let headings =
    let acc = ref [] in
    Array.iteri
      (fun i range ->
        match heading_level text range with
        | Some level -> acc := (i, level, range) :: !acc
        | None -> ())
      ctx.lines;
    List.rev !acc
  in
  let drawer_after i =
    let j = i + 1 in
    let planning j =
      j < n
      &&
      let t = String.uppercase_ascii (trimmed text ctx.lines.(j)) in
      List.exists
        (fun p -> String.starts_with ~prefix:p t)
        [ "SCHEDULED:"; "DEADLINE:"; "CLOSED:" ]
    in
    let j = if planning j then j + 1 else j in
    if j < n && String.uppercase_ascii (trimmed text ctx.lines.(j)) = ":PROPERTIES:" then
      let rec scan k props =
        if k >= n || heading_level text ctx.lines.(k) <> None then (
          let s, e = ctx.lines.(j) in
          error ctx s e "Unterminated property drawer";
          None)
        else if String.uppercase_ascii (trimmed text ctx.lines.(k)) = ":END:" then
          let s, _ = ctx.lines.(j) in
          let _, e = ctx.lines.(k) in
          Some (file_span path s e, List.rev props, next_line_start text ctx.lines.(k))
        else
          match property_of_line path text ctx.lines.(k) with
          | Some p -> scan (k + 1) (p :: props)
          | None ->
              let s, e = ctx.lines.(k) in
              error ctx s e "Invalid property line";
              scan (k + 1) props
      in
      scan (j + 1) []
    else None
  in
  let raw =
    let arr = Array.of_list headings in
    Array.to_list
      (Array.mapi
         (fun idx (i, level, range) ->
           let rec stop k =
             if k >= Array.length arr then total
             else
               let _, l, (s, _) = arr.(k) in
               if l <= level then s else stop (k + 1)
           in
           {
             h_level = level;
             h_line = range;
             h_stop = stop (idx + 1);
             h_title = title_range text range level;
             h_drawer = drawer_after i;
           })
         arr)
  in
  let card_id h =
    match h.h_drawer with
    | Some (_, props, _) -> (
        match List.find_opt (fun p -> p.key = "ID") props with
        | Some p when valid_id p.value -> Some p.value
        | Some p ->
            error ctx p.value_span.start p.value_span.stop "Invalid card ID";
            None
        | None -> None)
    | None -> None
  in
  let card_heads = List.filter_map (fun h -> Option.map (fun id -> (id, h)) (card_id h)) raw in
  (* Nest cards by subtree containment. *)
  let rec build (id, h) rest =
    let s, e = h.h_line in
    let children, remaining =
      let rec take acc = function
        | ((_, h') as c) :: tl when fst h'.h_line < h.h_stop -> take (c :: acc) tl
        | tl -> (List.rev acc, tl)
      in
      take [] rest
    in
    let rec build_all = function
      | [] -> []
      | c :: tl ->
          let card, tl' = build c tl in
          card :: build_all tl'
    in
    let child_cards = build_all children in
    let drawer, properties, content_start =
      match h.h_drawer with
      | Some (d, props, cs) -> (Some d, props, cs)
      | None -> (None, [], next_line_start text h.h_line)
    in
    let content_start = min content_start h.h_stop in
    (* Own regions between nested child subtrees. *)
    let items =
      let rec go cursor = function
        | [] -> scan_region ctx ~level:h.h_level cursor h.h_stop
        | (c : card) :: tl ->
            scan_region ctx ~level:h.h_level cursor c.start @ (Card c :: go c.stop tl)
      in
      go content_start child_cards
    in
    let ts, te = h.h_title in
    ( {
        id;
        level = h.h_level;
        title = sub text ts te;
        title_span = file_span path ts te;
        heading = file_span path s e;
        drawer;
        properties;
        start = s;
        content_start;
        stop = h.h_stop;
        block = false;
        items;
      },
      remaining )
  in
  let rec roots = function
    | [] -> []
    | c :: tl ->
        let card, tl' = build c tl in
        card :: roots tl'
  in
  let cards = roots card_heads in
  let headings =
    List.map
      (fun h ->
        let ts, te = h.h_title in
        let drawer, properties =
          match h.h_drawer with Some (d, props, _) -> (Some d, props) | None -> (None, [])
        in
        {
          level = h.h_level;
          start = fst h.h_line;
          stop = h.h_stop;
          title = sub text ts te;
          line_stop = snd h.h_line;
          drawer;
          properties;
        })
      raw
  in
  ({ path; text; cards; headings }, List.rev !(ctx.errors))

let rec preorder (c : card) =
  c :: List.concat_map (function Card c' -> preorder c' | _ -> []) c.items

let cards (file : file) = List.concat_map preorder file.cards
let find (file : file) id = List.find_opt (fun (c : card) -> c.id = id) (cards file)

let card_at (file : file) offset =
  List.fold_left
    (fun best (c : card) ->
      if c.start <= offset && (offset < c.stop || (offset = c.stop && c.stop = String.length file.text))
      then match best with Some (b : card) when b.start > c.start -> best | _ -> Some c
      else best)
    None (cards file)

let ancestors (file : file) (card : card) =
  List.filter
    (fun (c : card) ->
      c.id <> card.id && c.start <= card.start && card.stop <= c.stop
      && (c.start < card.start || c.stop > card.stop))
    (cards file)
  |> List.sort (fun (a : card) (b : card) -> compare b.start a.start)

let property (card : card) key = List.find_opt (fun p -> p.key = key) card.properties

let own_text (file : file) (card : card) =
  let buf = Buffer.create 256 in
  List.iter
    (function
      | Text s -> Buffer.add_string buf (sub file.text s.start s.stop)
      | Link l -> Buffer.add_string buf (sub file.text l.span.start l.span.stop)
      | Include k | Trace k -> Buffer.add_string buf (sub file.text k.span.start k.span.stop)
      | Card _ -> ())
    card.items;
  Buffer.contents buf
