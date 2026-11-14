open Coact_zk
open Fixture

let chat =
  {|* Chat
:PROPERTIES:
:ID: chat
:THREAD_ID: pi:x
:PIN: true
:END:
#+zk_include: :target note
** What is a monad?
:PROPERTIES:
:ID: q1
:CONTEXT_KIND: user
:END:
What is a monad?
** Answer
:PROPERTIES:
:ID: a1
:CONTEXT_KIND: assistant
:END:
A monad is a *burrito*.
*** Aside
:PROPERTIES:
:ID: aside
:END:
nested
** Question
:PROPERTIES:
:ID: q2
:CONTEXT_KIND: user
:END:
Why?
|}

let other = {|* Note
:PROPERTIES:
:ID: note
:END:
Monoids, see [[id:a1][the answer]].
* Loose
:PROPERTIES:
:ID: loose
:CONTEXT_KIND: synthesis
:END:
Free monads.
|}

let docs = [ ("c.org", chat); ("n.org", other) ]
let json j = print_endline (Yojson.Safe.pretty_to_string j)

let%expect_test "thread outline and card reads" =
  let ws = analyze docs in
  json (Result.get_ok (Query.thread_view ws ~main:"chat"));
  json (Result.get_ok (Query.card_read ws ~id:"a1" ~offset:1 ~limit:1 ~raw:false));
  json (Query.card_search ws ~query:"MONAD free" ~limit:5);
  [%expect {|
    {
      "main": "chat",
      "title": "Chat",
      "thread": "pi:x",
      "pinned": true,
      "items": [
        {
          "index": 0,
          "id": "note",
          "kind": null,
          "title": "Note",
          "included": true,
          "tokens": 18
        },
        {
          "index": 1,
          "id": "q1",
          "kind": "user",
          "title": "What is a monad?",
          "included": false,
          "tokens": 21
        },
        {
          "index": 2,
          "id": "a1",
          "kind": "assistant",
          "title": "Answer",
          "included": false,
          "tokens": 34
        },
        {
          "index": 3,
          "id": "q2",
          "kind": "user",
          "title": "Question",
          "included": false,
          "tokens": 16
        }
      ],
      "tokens": 89
    }
    {
      "id": "a1",
      "title": "Answer",
      "kind": "assistant",
      "thread": null,
      "pinned": false,
      "file": "c.org",
      "lines": "1-1 of 2",
      "text": "A monad is a *burrito*.",
      "nested": [ { "id": "aside", "kind": null, "title": "Aside" } ],
      "links": [],
      "backlinks": [ { "id": "note", "kind": null, "title": "Note" } ],
      "more": "1 more lines; read again with offset 2"
    }
    [
      {
        "id": "loose",
        "kind": "synthesis",
        "title": "Loose",
        "thread": null,
        "snippet": "Free monads."
      }
    ]
    |}]

let%expect_test "card edits stay in the card's own text" =
  let ws = analyze docs in
  let try_ name r = match r with Ok edits -> print_string (List.assoc "c.org" (apply docs edits)) | Error e -> Printf.printf "%s: %s\n" name e in
  try_ "missing" (Plan.edit ws ~id:"a1" [ ("burritos", "x") ]);
  try_ "nested" (Plan.edit ws ~id:"a1" [ ("nested", "x") ]);
  try_ "heading" (Plan.edit ws ~id:"a1" [ ("burrito", "x\n** New") ]);
  try_ "drawer" (Plan.edit ws ~id:"a1" [ ("burrito", "x\n:PROPERTIES:") ]);
  try_ "twice" (Plan.edit ws ~id:"chat" [ ("", "x") ]);
  (match Plan.edit ws ~id:"a1" [ ("*burrito*", "monoid in endofunctors") ] with
  | Ok edits ->
      let text = List.assoc "c.org" (apply docs edits) in
      print_endline (List.find (fun l -> String.starts_with ~prefix:"A monad" l) (String.split_on_char '\n' text))
  | Error e -> print_endline e);
  [%expect {|
    missing: Card a1 has no text "burritos"
    nested: Card a1 has no text "nested"
    heading: "** New" would end this card. Section headings in a card at level 2 need at least 3 stars; use '-' for list items
    drawer: Card text may not contain a property drawer; create a card for that instead
    twice: An empty old text only fills a blank card
    A monad is a monoid in endofunctors.
    |}]

let%expect_test "arranging a thread keeps every card" =
  let ws = analyze docs in
  (match Plan.arrange ws ~main:"chat" [ "q1"; "loose"; "q2" ] with
  | Ok (edits, notes) ->
      List.iter (fun (n : Plan.note) -> Printf.printf "note %s | %s\n" n.anchor n.note) notes;
      let docs = apply docs edits in
      print_string (List.assoc "c.org" docs);
      let ws = analyze docs in
      print_diagnostics (ws.diagnostics @ Thread.check ws);
      let a, _ = Result.get_ok (Conversation.export ws ~main:"chat" { require_question = true; baseline = None; now = 0. }) in
      print_artifact a
  | Error e -> print_endline e);
  (match Plan.arrange ws ~main:"chat" [ "q1"; "q1" ] with Ok _ -> () | Error e -> print_endline e);
  (match Plan.arrange ws ~main:"chat" [ "aside" ] with Ok _ -> () | Error e -> print_endline e);
  [%expect {|
    note #+zk_include: :target q1 | Now transcluded: What is a monad?
    note * What is a monad? | Defined here, after the thread, and transcluded into it
    note #+zk_include: :target loose | Transcluded into the thread: Loose
    note * Answer | Left the thread; the card is kept here
    * Chat
    :PROPERTIES:
    :ID: chat
    :THREAD_ID: pi:x
    :PIN: true
    :END:
    #+zk_include: :target q1
    #+zk_include: :target loose
    ** Question
    :PROPERTIES:
    :ID: q2
    :CONTEXT_KIND: user
    :END:
    Why?

    * What is a monad?
    :PROPERTIES:
    :ID: q1
    :CONTEXT_KIND: user
    :END:
    What is a monad?

    * Answer
    :PROPERTIES:
    :ID: a1
    :CONTEXT_KIND: assistant
    :END:
    A monad is a *burrito*.
    ** Aside
    :PROPERTIES:
    :ID: aside
    :END:
    nested

    #0 q1 user: What is a monad?
    #1 loose custom/coact.synthesis: Synthesis card \"Loose\" (knowledge distilled from earlier discussion):\n\nFree monads.
    #2 q2 user: Why?
    An item appears twice
    Card aside is already inside the thread
    |}]

let%expect_test "created cards get their own file" =
  let ws = analyze docs in
  let edit, id, path = Result.get_ok (Plan.create ws ~layout:Plan.default_layout ~dir:"w" ~title:"Free\nmonads" ~kind:(Some Model.Synthesis) ~body:"# Idea\n**bold**" ~now:0.) in
  print_string (Str_ids.mask [ id ] edit.text);
  print_endline (Str_ids.mask [ id ] path);
  [%expect {|
    #+title: Free monads

    * Free monads
    :PROPERTIES:
    :ID: Q
    :CONTEXT_KIND: synthesis
    :END:

    ** Idea
    *bold*
    w/Q.org
    |}]

let%expect_test "turn directives are registered names outside markup" =
  let registry =
    {
      Directive.commands = [ { name = "skill:typst"; description = "Typst style" } ];
      contexts = [ { name = "diagnostics"; description = "" }; { name = "buffer"; description = "" } ];
    }
  in
  let text =
    String.concat "\n"
      [
        "/skill:typst please";
        "/Users/me/file.org is a path, /italic/ too";
        "see @diagnostics and @buffer, not @label or $x @diagnostics$ or [[id:a][@buffer]]";
        "mail me@diagnostics.org, or @diagnostics.";
        "#+begin_src sh";
        "/skill:typst";
        "#+end_src";
        "/skill:unknown x";
      ]
  in
  List.iter
    (fun (d : Directive.t) ->
      Printf.printf "%s %s [%s] %S\n" (Directive.kind_name d.kind) d.name d.args (String.sub text d.start (d.stop - d.start)))
    (Directive.scan registry ~base:0 text);
  [%expect {|
    command skill:typst [please] "/skill:typst"
    context diagnostics [] "@diagnostics"
    context buffer [] "@buffer"
    context diagnostics [] "@diagnostics"
    |}]

let%expect_test "new cards are set apart by a blank line" =
  let docs = [ ("c.org", "* Chat\n:PROPERTIES:\n:ID: chat\n:THREAD_ID: pi:x\n:PIN: true\n:END:\n** Question\n:PROPERTIES:\n:ID: q\n:CONTEXT_KIND: user\n:END:\nHello there\n") ] in
  let ws = analyze docs in
  (match Plan.submit ws ~main:"chat" Plan.default_labels ~now:0. with
  | Ok (Ready { edits; answer; _ }) -> (
      let docs = apply docs edits in
      let ws = analyze docs in
      match Plan.answer ws ~answer ~text:"Hi." ~entries:[] ~trace_path:"t.org" Plan.default_labels ~now:0. with
      | Ok r -> print_string (Str_ids.mask [ answer; Option.get r.draft ] (List.assoc "c.org" (apply docs r.edits)))
      | Error e -> print_endline e)
  | _ -> print_endline "not ready");
  [%expect {|
    * Chat
    :PROPERTIES:
    :ID: chat
    :THREAD_ID: pi:x
    :PIN: true
    :END:
    ** Question
    :PROPERTIES:
    :ID: q
    :CONTEXT_KIND: user
    :END:
    Hello there

    ** Answer
    :PROPERTIES:
    :ID: Q
    :CONTEXT_KIND: assistant
    :END:

    Hi.

    ** Question
    :PROPERTIES:
    :ID: A
    :CONTEXT_KIND: user
    :END:
    |}]

let%expect_test "semantic titles spare cards named by hand" =
  let chat =
    {|* Chat
:PROPERTIES:
:ID: chat
:THREAD_ID: pi:x
:PIN: true
:END:
** Question
:PROPERTIES:
:ID: q
:CONTEXT_KIND: user
:END:
Why does the two-point computation give a scale quotient?

** Answer
:PROPERTIES:
:ID: a
:CONTEXT_KIND: assistant
:END:
The annulus homotopy removes the common scale.

** My own name
:PROPERTIES:
:ID: m
:CONTEXT_KIND: assistant
:END:
Kept as named.

** Question
:PROPERTIES:
:ID: draft
:CONTEXT_KIND: user
:END:

|}
  in
  let docs = [ ("c.org", chat) ] in
  let ws = analyze docs in
  let labels = Plan.default_labels in
  let requests = Plan.title_requests ws labels (Plan.thread_items ws ~main:"chat") in
  List.iter (fun (r : Plan.title_request) -> Printf.printf "request %s %s\n" r.id r.kind) requests;
  let rev id = (List.find (fun (r : Plan.title_request) -> r.id = id) requests).revision in
  let edits, applied, skipped =
    Plan.retitle ws labels
      [ ("q", rev "q", "** Why a scale quotient?"); ("a", "stale", "Annulus homotopy"); ("m", "x", "Renamed:") ]
  in
  List.iter (fun (id, why) -> Printf.printf "skipped %s: %s\n" id why) skipped;
  Printf.printf "applied %s\n" (String.concat "," applied);
  let docs = apply docs edits in
  let text = List.assoc "c.org" docs in
  print_string (String.concat "\n" (List.filteri (fun i _ -> i >= 6 && i < 13) (String.split_on_char '\n' text)));
  print_newline ();
  (* An automatic title can be renamed again; once edited by hand it stays. *)
  let ws = analyze docs in
  Printf.printf "still automatic: %d\n" (List.length (Plan.title_requests ws labels [ "q" ]));
  let docs = [ ("c.org", String.concat "\n" (List.map (fun l -> if l = "** Why a scale quotient?" then "** Mine" else l) (String.split_on_char '\n' text))) ] in
  Printf.printf "after a hand edit: %d\n" (List.length (Plan.title_requests (analyze docs) labels [ "q" ]));
  [%expect {|
    request a assistant
    request q user
    skipped a: the card changed while it was named
    skipped m: the title was set by hand
    applied q
    ** Why a scale quotient?
    :PROPERTIES:
    :ID: q
    :CONTEXT_KIND: user
    :AUTO_TITLE: Why a scale quotient?
    :END:
    Why does the two-point computation give a scale quotient?
    still automatic: 1
    after a hand edit: 0
    |}]

let%expect_test "an asked passage links back without changing its words" =
  let source =
    {|* Notes
:PROPERTIES:
:ID: src
:END:
The annulus homotopy removes the common scale, see $s$ and [[id:other][scale]].
The scale quotient follows.
#+begin_src text
annulus homotopy
#+end_src
|}
  in
  let docs = [ ("n.org", source) ] in
  let ws = analyze docs in
  let edits, id, path =
    Result.get_ok
      (Plan.new_card ws ~path:"n.org" ~into:"w" ~selection:(Some (36, 77)) ~title:None Plan.default_labels ~now:0.)
  in
  let docs = apply docs edits in
  print_string (Str_ids.mask [ id ] (List.assoc path docs));
  Printf.printf "source unchanged: %b\n" (List.assoc "n.org" docs = source);
  (* The asked card becomes a thread. *)
  let docs =
    List.map
      (fun (p, t) ->
        if p <> path then (p, t)
        else
          let marker = "\n:END:\n" in
          let rec find i = if String.sub t i (String.length marker) = marker then i else find (i + 1) in
          let i = find 0 in
          (p, String.sub t 0 i ^ "\n:THREAD_ID: pi:t\n:PIN: true" ^ String.sub t i (String.length t - i)))
      docs
  in
  let ws = analyze docs in
  (match Plan.link_candidate ws ~main:id with
  | Some (src, passage) -> Printf.printf "candidate %s: %s\n" src passage
  | None -> print_endline "no candidate");
  List.iter
    (fun anchor ->
      match Plan.link_back ws ~main:id ~anchor with
      | Ok (edits, _) ->
          let text = List.assoc "n.org" (apply docs edits) in
          print_endline (Str_ids.mask [ id ] (List.nth (String.split_on_char '\n' text) 4))
      | Error e -> Printf.printf "%s: %s\n" anchor e)
    [ "scale"; "annulus homotopy"; "s$"; "common scale" ];
  [%expect {|
    #+title: New card

    * New card
    :PROPERTIES:
    :ID: Q
    :AUTO_TITLE: New card
    :ASK_FROM: src
    :END:

    #+begin_quote
    The annulus homotopy removes the common s
    #+end_quote
    From [[id:src][Notes]]


    source unchanged: true
    candidate src: The annulus homotopy removes the common s
    scale: "scale" occurs more than once in the source card
    The [[id:Q][annulus homotopy]] removes the common scale, see $s$ and [[id:other][scale]].
    s$: The source card has no plain text "s$"
    The annulus homotopy removes the [[id:Q][common scale]], see $s$ and [[id:other][scale]].
    |}]

let%expect_test "cards may hold section headings below their own" =
  let ws = analyze docs in
  (match Plan.edit ws ~id:"a1" [ ("A monad is a *burrito*.", "*** Definition\nA monad is a monoid.") ] with
  | Ok edits ->
      let docs = apply docs edits in
      let ws = analyze docs in
      print_diagnostics (ws.diagnostics @ Thread.check ws);
      let _, c = Option.get (Workspace.find ws "a1") in
      Printf.printf "a1 still holds: %s\n" (String.concat "," (List.filter_map (function Org.Card c -> Some c.id | _ -> None) c.items))
  | Error e -> print_endline e);
  (match Plan.create ws ~layout:Plan.default_layout ~dir:"w" ~title:"Idea" ~kind:None ~body:"* item" ~now:0. with
  | Ok _ -> print_endline "created"
  | Error e -> print_endline e);
  print_endline (Org_text.of_markdown ~level:2 "# Overview\n*** Kept\n* bullet\n## Detail");
  [%expect {|
    a1 still holds: aside
    "* item" would end this card. Section headings in a card at level 1 need at least 2 stars; use '-' for list items
    *** Overview
    *** Kept
    - bullet
    **** Detail
    |}]

