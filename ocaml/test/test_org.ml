open Coact_zk

let%expect_test "cards, drawers, nesting and references" =
  let text = {|#+title: demo
* Main :tag:
:PROPERTIES:
:ID: main
:THREAD_ID: pi:abc
:PIN: true
:END:
intro [[id:q1][the question]] here
#+zk_include: :target note
** Q
:PROPERTIES:
:ID: q1
:CONTEXT_KIND: user
:END:
Why?
*** plain sub heading
still q1
** A
:PROPERTIES:
:ID: a1
:CONTEXT_KIND: assistant
:END:
#+begin_src org
[[id:ignored]]
#+end_src
#+begin_zk :id z1 :title "Block card" :context_kind synthesis
inside
#+end_zk
tail
|} in
  let file, errors = Org.parse ~path:"f.org" text in
  List.iter (fun (e : Org.error) -> print_endline e.message) errors;
  List.iter
    (fun (c : Org.card) ->
      Printf.printf "%s level=%d title=%S props=%s\n" c.id c.level c.title
        (String.concat "," (List.map (fun (p : Org.property) -> p.key ^ "=" ^ p.value) c.properties));
      List.iter
        (function
          | Org.Text s -> Printf.printf "  text %S\n" (Org.sub text s.start s.stop)
          | Link l -> Printf.printf "  link %s\n" l.target
          | Include k -> Printf.printf "  include %s\n" k.target
          | Trace k -> Printf.printf "  trace %s\n" k.target
          | Card c -> Printf.printf "  card %s\n" c.id)
        c.items)
    (Org.cards file);
  [%expect {|
    main level=1 title="Main" props=ID=main,THREAD_ID=pi:abc,PIN=true
      text "intro "
      link q1
      text " here\n"
      include note
      card q1
      card a1
    q1 level=2 title="Q" props=ID=q1,CONTEXT_KIND=user
      text "Why?\n*** plain sub heading\nstill q1\n"
    a1 level=2 title="A" props=ID=a1,CONTEXT_KIND=assistant
      text "#+begin_src org\n[[id:ignored]]\n#+end_src\n"
      card z1
      text "tail\n"
    z1 level=3 title="Block card" props=CONTEXT_KIND=synthesis
      text "inside\n"
    |}]

let%expect_test "malformed declarations are reported" =
  let _, errors =
    Org.parse ~path:"f.org"
      "* A\n:PROPERTIES:\n:ID: a\n* B\n:PROPERTIES:\n:ID: b\n:END:\n#+zk_include:\n#+begin_zk :title x\n#+end_zk\n"
  in
  List.iter (fun (e : Org.error) -> Printf.printf "[%d,%d) %s\n" e.span.start e.span.stop e.message) errors;
  [%expect {|
    [4,16) Unterminated property drawer
    [54,67) #+zk_include needs :target <card-id>
    [68,87) #+begin_zk needs a valid :id
    |}]

let%expect_test "markdown answers become org-safe" =
  print_endline
    (Org_text.of_markdown "# Title\n\n* item **bold** and `code`\n\n```ocaml\n* not a heading\nlet x = 1\n```\n");
  [%expect {|
    *Title*

    - item *bold* and ~code~

    #+begin_src ocaml
    ,* not a heading
    let x = 1
    #+end_src
    |}]

let%expect_test "a question after quoted material names its card" =
  print_endline (Org_text.headline "#+begin_quote\nAfter\n#+end_quote\nFrom [[id:a][Answer]]\n\nWhat does after mean?\nMore detail.\n");
  print_endline (Org_text.headline "What is a monad?\n");
  [%expect {|
    What does after mean?
    What is a monad?
    |}]
