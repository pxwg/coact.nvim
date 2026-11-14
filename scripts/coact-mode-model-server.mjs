// A scripted OpenAI-compatible chat server for Coact mode tests.
//
// Prints its base URL on stdout, then answers /chat/completions with
// streamed replies chosen from the last message, and appends every request
// body to $COACT_TEST_LOG as one JSON line.
//   - a summarization request          -> a fixed summary
//   - the last message is a tool result -> a final answer quoting it
//   - "please read <path>"             -> a read tool call
//   - "please create <path>"           -> a write tool call
//   - "please edit <path> <old> <new>" -> an edit tool call
//   - "please outline"                 -> thread_view
//   - "please fix <id> <old> <new>"    -> card_edit
//   - "please note <title>"            -> card_create
//   - "please wait"                    -> a slow stream, for stopping
//   - "fill the context"               -> usage near the context window
//   - a card-naming request            -> "Titled <kind>" for each card
//   - otherwise                        -> "Echo: <question>"
import { appendFileSync } from "node:fs";
import { createServer } from "node:http";

const log = process.env.COACT_TEST_LOG;

function text(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((part) => part.text ?? "").join("");
  return "";
}

function reply(messages) {
  const last = messages[messages.length - 1] ?? {};
  const all = messages.map((m) => text(m.content)).join("\n");
  if (/Name each card below/.test(all)) {
    const names = {};
    for (const m of all.matchAll(/<card id="([^"]+)" kind="([^"]+)">/g)) names[m[1]] = "Titled " + m[2];
    const passage = all.match(/<passage>\n([^\n]*)/);
    const anchor = passage ? passage[1].trim().split(/\s+/)[0] : undefined;
    return { text: JSON.stringify({ titles: names, anchor }) };
  }
  if (/<conversation>/.test(all)) return { text: "SUMMARY: monads were discussed; open question: why endofunctors?" };
  if (last.role === "tool") return { text: "Final answer: the file says " + text(last.content).trim() };
  const question = text(last.content);
  const read = question.match(/please read (\S+)/);
  if (read) return { tool: { name: "read", arguments: { path: read[1] } } };
  if (/please outline/.test(question)) return { tool: { name: "thread_view", arguments: {} } };
  const fix = question.match(/please fix (\S+) (\S+) (\S+)/);
  if (fix) return { tool: { name: "card_edit", arguments: { id: fix[1], edits: [{ oldText: fix[2], newText: fix[3] }] } } };
  const note = question.match(/please note (.+)/);
  if (note) return { tool: { name: "card_create", arguments: { title: note[1].trim(), body: "Free monads are free.", kind: "synthesis" } } };
  const edit = question.match(/please edit (\S+) (\S+) (\S+)/);
  if (edit) return { tool: { name: "edit", arguments: { path: edit[1], edits: [{ oldText: edit[2], newText: edit[3] }] } } };
  const create = question.match(/please create (\S+)/);
  if (create) return { tool: { name: "write", arguments: { path: create[1], content: "* Created\n:PROPERTIES:\n:ID: created-card\n:END:\nby the agent\n" } } };
  if (/please wait/.test(question)) return { text: "Waiting patiently for a long time, one word after another.", delay: 300 };
  if (/fill the context/.test(question)) return { text: "Echo: the context is full", usage: 127000 };
  return { text: "Echo: " + question.trim().split("\n").pop() };
}

let calls = 0;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const server = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => (body += chunk));
  request.on("end", async () => {
    const payload = JSON.parse(body || "{}");
    if (log) appendFileSync(log, JSON.stringify(payload) + "\n");
    const answer = reply(payload.messages ?? []);
    const id = "chatcmpl-" + ++calls;
    const chunk = (delta, finish) => ({
      id,
      object: "chat.completion.chunk",
      created: 0,
      model: payload.model,
      choices: [{ index: 0, delta, finish_reason: finish ?? null }],
    });
    response.writeHead(200, { "content-type": "text/event-stream" });
    const send = (value) => response.write("data: " + JSON.stringify(value) + "\n\n");
    send(chunk({ role: "assistant" }));
    if (answer.tool) {
      send(chunk({ tool_calls: [{ index: 0, id: "call_" + calls, type: "function", function: { name: answer.tool.name, arguments: JSON.stringify(answer.tool.arguments) } }] }));
      send(chunk({}, "tool_calls"));
    } else {
      for (const piece of answer.text.match(/.{1,12}/gs) ?? [""]) {
        if (response.destroyed) return;
        send(chunk({ content: piece }));
        if (answer.delay) await sleep(answer.delay);
      }
      send(chunk({}, "stop"));
    }
    const prompt = answer.usage ?? 10;
    send({ id, object: "chat.completion.chunk", created: 0, model: payload.model, choices: [], usage: { prompt_tokens: prompt, completion_tokens: 5, total_tokens: prompt + 5 } });
    response.end("data: [DONE]\n\n");
  });
});

server.listen(0, "127.0.0.1", () => {
  process.stdout.write("http://127.0.0.1:" + server.address().port + "/v1\n");
});
