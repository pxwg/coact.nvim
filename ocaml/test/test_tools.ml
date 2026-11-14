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
  try_ "heading" (Plan.edit ws ~id:"a1" [ ("burrito", "x\n* New") ]);
  try_ "twice" (Plan.edit ws ~id:"chat" [ ("", "x") ]);
  (match Plan.edit ws ~id:"a1" [ ("*burrito*", "monoid in endofunctors") ] with
  | Ok edits ->
      let text = List.assoc "c.org" (apply docs edits) in
      print_endline (List.find (fun l -> String.starts_with ~prefix:"A monad" l) (String.split_on_char '\n' text))
  | Error e -> print_endline e);
  [%expect {|
    missing: Card a1 has no text "burritos"
    nested: Card a1 has no text "nested"
    heading: A replacement may not contain a heading or a property drawer; create a new card instead
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
  let edit, id, path = Result.get_ok (Plan.create ws ~dir:"w" ~title:"Free\nmonads" ~kind:(Some Model.Synthesis) ~body:"# Idea\n**bold**" ~now:0.) in
  print_string (Str_ids.mask [ id ] edit.text);
  print_endline (Str_ids.mask [ id ] path);
  [%expect {|
    #+title: Free monads

    * Free monads
    :PROPERTIES:
    :ID: Q
    :CONTEXT_KIND: synthesis
    :END:
    *Idea*
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
