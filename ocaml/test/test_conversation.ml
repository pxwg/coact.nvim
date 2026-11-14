open Coact_zk
open Fixture

let record =
  String.concat "\n"
    [
      {|{"type":"message","id":"e1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"look"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"a.ml"}}],"api":"anthropic-messages","provider":"anthropic","model":"m","usage":{},"stopReason":"toolUse","timestamp":1}}|};
      {|{"type":"message","id":"e2","message":{"role":"toolResult","toolCallId":"c1","toolName":"read","content":[{"type":"text","text":"let x = 1"}],"isError":false,"timestamp":2}}|};
      {|{"type":"message","id":"e3","message":{"role":"assistant","content":[{"type":"text","text":"x is **one**"}],"api":"anthropic-messages","provider":"anthropic","model":"m","usage":{},"stopReason":"stop","timestamp":3}}|};
    ]

let main_file =
  {|* Main
:PROPERTIES:
:ID: main
:THREAD_ID: pi:t1
:PIN: true
:END:
#+zk_include: :target note
** What is x?
:PROPERTIES:
:ID: q1
:CONTEXT_KIND: user
:END:
What is x?
** Answer
:PROPERTIES:
:ID: a1
:CONTEXT_KIND: assistant
:END:
[[id:tr][Trace]]
x is *one*
** Q2
:PROPERTIES:
:ID: q2
:CONTEXT_KIND: user
:END:
And y?
* Note
:PROPERTIES:
:ID: note
:END:
Background [[id:a1][answer]].
|}

let trace_file =
  "* Record\n:PROPERTIES:\n:ID: src\n:CONTEXT_KIND: trace\n:END:\n#+begin_src jsonl\n" ^ record
  ^ "\n#+end_src\n* Trace\n:PROPERTIES:\n:ID: tr\n:CONTEXT_KIND: trace\n:END:\n#+coact_trace: :target src\n"

let docs = [ ("main.org", main_file); ("trace/main.org", trace_file) ]
let options = { Conversation.require_question = true; baseline = None; now = 0. }

let%expect_test "linearize a thread with a replayed trace" =
  let ws = analyze docs in
  print_diagnostics (ws.diagnostics @ Thread.check ws);
  (match Conversation.export ws ~main:"main" options with
  | Ok (a, ds) ->
      print_artifact a;
      print_diagnostics ds;
      Printf.printf "question=%s\n" (Option.value ~default:"-" a.question)
  | Error ds -> print_diagnostics ds);
  [%expect {|
    #0 note custom/coact.note: Reference card \"Note\":\n\nBackground [[id:a1][answer]].
    #1 q1 user: What is x?
    #2 a1 assistant: thinking | call:read
    #2 a1 toolResult: let x = 1
    #2 a1 assistant: x is *one*
    #3 q2 user: And y?
    warning no-kind [314,320): Card without CONTEXT_KIND is sent as reference material
    question=q2
    |}]

let%expect_test "revisions between turns precede the question" =
  let ws = analyze docs in
  let a, _ = Result.get_ok (Conversation.export ws ~main:"main" options) in
  let baseline =
    List.map
      (fun (c : Conversation.card_text) -> if c.id = "a1" then { c with text = "x is two" } else c)
      a.cards
  in
  let a, _ = Result.get_ok (Conversation.export ws ~main:"main" { options with baseline = Some baseline }) in
  List.iter (fun m -> print_endline (message_line m)) (List.rev a.messages |> fun l -> [ List.nth l 1; List.hd l ]);
  [%expect {|
    custom/coact.revision: Since your last reply the user revised the conversation cards. The current text is authoritative; the changes are:\n\nRevised card \"Answer\":\n- x is two\n+ x is *one*
    user: And y?
    |}]

let%expect_test "structure errors block export" =
  let ws = analyze [ ("a.org", "* A\n:PROPERTIES:\n:ID: a\n:PIN: true\n:END:\n* B\n:PROPERTIES:\n:ID: b\n:PIN: true\n:THREAD_ID: t\n:CONTEXT_KIND: user\n:END:\n") ] in
  print_diagnostics (Thread.check ws);
  (match Conversation.export ws ~main:"b" options with Ok _ -> print_endline "exported" | Error _ -> print_endline "blocked");
  [%expect {|
    error thread-missing [4,40): Pinned card has no THREAD_ID; pin it again with :CoactMode pin to bind a thread
    error pin-conflict [4,40): Only one card can be pinned; also pinned: b
    error pin-conflict [45,115): Only one card can be pinned; also pinned: a
    error thread-kind [45,115): A thread main card organizes the conversation and cannot declare CONTEXT_KIND
    blocked
    |}]

let%expect_test "submit, answer and compact" =
  let docs = [ ("c.org", "* Chat\n:PROPERTIES:\n:ID: chat\n:THREAD_ID: pi:x\n:PIN: true\n:END:\nWhat is a monad?\n") ] in
  let ws = analyze docs in
  let edits, question, answer =
    match unwrap (Plan.submit ws ~main:"chat" Plan.default_labels ~now:0.) with
    | Ready { edits; question; answer } -> (edits, question, answer)
    | Draft _ -> failwith "draft"
  in
  let docs = apply docs edits in
  let ws = analyze docs in
  let a, _ = Result.get_ok (Conversation.export ws ~main:"chat" options) in
  let ids = ref [ question; answer ] in
  let mask s = Str_ids.mask !ids s in
  let print_artifact (a : Conversation.artifact) =
    List.iter2
      (fun m (s : Conversation.source) -> print_endline (mask (Printf.sprintf "#%d %s %s" s.item s.card (message_line m))))
      a.messages a.sources
  in
  print_artifact a;
  let entries =
    [ Yojson.Safe.from_string {|{"type":"message","id":"r1","message":{"role":"assistant","content":[{"type":"text","text":"A *monoid* in endofunctors."}],"api":"x","provider":"p","model":"m","usage":{},"stopReason":"stop","timestamp":5}}|} ]
  in
  let r = unwrap (Plan.answer ws ~answer ~text:"A **monoid** in endofunctors." ~entries ~trace_path:"trace/chat.org" Plan.default_labels ~now:0.) in
  let docs = apply docs r.edits in
  ids := [ question; answer; Option.get r.draft; "-"; Option.get r.trace ];
  let ws = analyze docs in
  print_diagnostics (ws.diagnostics @ Thread.check ws @ Conversation.lint ws);
  let a, _ = Result.get_ok (Conversation.export ws ~main:"chat" { options with require_question = false }) in
  print_artifact a;
  (* Write a follow-up, then compact the first exchange. *)
  let draft = Option.get r.draft in
  let docs =
    List.map
      (fun (p, t) ->
        if p <> "c.org" then (p, t)
        else
          let ws = analyze [ (p, t) ] in
          let _, c = Option.get (Workspace.find ws draft) in
          (p, String.sub t 0 c.stop ^ "Why endofunctors?\n" ^ String.sub t c.stop (String.length t - c.stop)))
      docs
  in
  let ws = analyze docs in
  let edits, notes, synthesis =
    unwrap (Plan.compact ws ~main:"chat" ~count:2 ~summary:"Monads are monoids." ~dir:"cards" Plan.default_labels ~now:0.)
  in
  List.iter (fun (n : Plan.note) -> Printf.printf "note %s | %s | %s\n" (Filename.basename n.path) n.anchor n.note) notes;
  let docs = apply docs edits in
  ids := [ question; answer; draft; synthesis; Option.get r.trace ];
  let ws = analyze docs in
  print_diagnostics (ws.diagnostics @ Thread.check ws @ Conversation.lint ws);
  let a, _ = Result.get_ok (Conversation.export ws ~main:"chat" options) in
  print_artifact a;
  print_string (mask (List.assoc "trace/chat.org" docs));
  print_string (mask (List.assoc ("cards/" ^ synthesis ^ ".org") docs));
  let text = List.assoc "c.org" docs in
  let normalize = Str_ids.mask [ question; answer; draft; synthesis; Option.get r.trace ] in
  print_string (normalize text);
  [%expect {|
    #0 Q user: What is a monad?
    #0 Q user: What is a monad?
    #1 A assistant: A *monoid* in endofunctors.
    note 19700101T080000-7741.org | * Summary | Synthesis of 2 items that leave the thread
    note c.org | #+zk_include: :target 19700101T080000-7741 | Transcluded into the thread: 19700101T080000-7741
    note c.org | * What is a monad? | Left the thread; the card is kept here
    note c.org | * Answer | Left the thread; the card is kept here
    #0 S custom/coact.synthesis: Synthesis card \"Summary\" (knowledge distilled from earlier discussion):\n\nMonads are monoids.\n\nSources: [[id:Q][What is a monad?]], [[id:A][Answer]]
    #1 D user: Why endofunctors?
    #+title: Trace: Chat

    * Trace record: Chat
    :PROPERTIES:
    :ID: 19700101T080000-31f2
    :CONTEXT_KIND: trace
    :END:
    #+begin_src jsonl
    {"type":"message","id":"r1","message":{"role":"assistant","content":[{"type":"text","text":"A *monoid* in endofunctors."}],"api":"x","provider":"p","model":"m","usage":{},"stopReason":"stop","timestamp":5}}
    #+end_src

    * Trace: Chat
    :PROPERTIES:
    :ID: T
    :CONTEXT_KIND: trace
    :END:
    #+coact_trace: :target 19700101T080000-31f2
    #+title: Summary

    * Summary
    :PROPERTIES:
    :ID: S
    :CONTEXT_KIND: synthesis
    :END:
    Monads are monoids.

    Sources: [[id:Q][What is a monad?]], [[id:A][Answer]]
    * Chat
    :PROPERTIES:
    :ID: chat
    :THREAD_ID: pi:x
    :PIN: true
    :END:
    #+zk_include: :target S
    ** Question
    :PROPERTIES:
    :ID: D
    :CONTEXT_KIND: user
    :END:

    Why endofunctors?

    * What is a monad?
    :PROPERTIES:
    :ID: Q
    :CONTEXT_KIND: user
    :END:
    What is a monad?

    * Answer
    :PROPERTIES:
    :ID: A
    :CONTEXT_KIND: assistant
    :END:
    [[id:T][Trace]]
    A *monoid* in endofunctors.
    |}]
