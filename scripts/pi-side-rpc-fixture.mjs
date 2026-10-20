// Deterministic Pi peer with a session tree, for side-discussion tests.
// Emulates the coact.nvim extension's /coact-nvim-side command and the
// submit_annotation tool over the RPC protocol; no network or models.
import { createInterface } from 'node:readline';
const args = process.argv.slice(2);
const sessionId = args[args.indexOf('--session-id') + 1] || 'side-fixture';
const emit = (event) => process.stdout.write(JSON.stringify(event) + '\n');
const text = (value) => ({ type: 'text', text: value });
const entries = [];
let leafId = null;
let streaming = false;
let idleWaiters = [];
let uiSeq = 0;
const uiPending = new Map();
let side = null; // { originLeafId, anchor, source, armed, submission }
const byId = (id) => entries.find((entry) => entry.id === id);
function branch() {
  const out = [];
  for (let entry = byId(leafId); entry; entry = byId(entry.parentId)) out.unshift(entry);
  return out;
}
function append(entry) {
  entry = { ...entry, id: 'e' + (entries.length + 1), parentId: leafId, timestamp: Date.now() };
  entries.push(entry);
  leafId = entry.id;
  return entry;
}
const appendMessage = (message) => append({ type: 'message', message });
const response = (command, data = {}) => emit({ type: 'response', id: command.id, command: command.type, success: true, data });
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitForIdle = () => (streaming ? new Promise((resolve) => idleWaiters.push(resolve)) : Promise.resolve());
function select(payload) {
  const id = 'ui-' + (++uiSeq);
  emit({ type: 'extension_ui_request', id, method: 'select', title: 'Coact Pi side', options: [payload] });
  return new Promise((resolve) => uiPending.set(id, resolve));
}
async function run(command) {
  response(command);
  streaming = true;
  emit({ type: 'agent_start' });
  emit({ type: 'turn_start' });
  const user = { role: 'user', content: command.message };
  appendMessage(user);
  emit({ type: 'message_start', message: user });
  emit({ type: 'message_end', message: user });
  const asked = command.message.replace(/^<coact-side-context>[\s\S]*?<\/coact-side-context>\s*/, '');
  if (side?.armed && asked.includes('submit_annotation')) {
    side.submission = { question: 'what does it mean?', answer_brief: 'It is the first question.', summary: 'Learned the meaning.', answer_detail: 'Full detail.' };
    const call = { type: 'toolCall', id: 'note-1', name: 'submit_annotation', arguments: side.submission };
    const assistant = { role: 'assistant', content: [call] };
    emit({ type: 'message_start', message: { role: 'assistant', content: [] } });
    appendMessage(assistant);
    emit({ type: 'message_end', message: assistant });
    const result = { role: 'toolResult', toolCallId: 'note-1', toolName: 'submit_annotation', content: [text('Annotation recorded.')], isError: false };
    appendMessage(result);
    emit({ type: 'tool_execution_start', toolCallId: 'note-1', toolName: 'submit_annotation', args: side.submission });
    emit({ type: 'tool_execution_end', toolCallId: 'note-1', toolName: 'submit_annotation', result, isError: false });
    emit({ type: 'turn_end', message: assistant, toolResults: [result] });
  } else {
    const ctx = command.message.startsWith('<coact-side-context>') ? 'ctx=yes' : 'ctx=no';
    if (asked.includes('slow')) await pause(500);
    const final = { role: 'assistant', content: [text('😀 Answer to: ' + asked.trim() + ' ' + ctx)] };
    emit({ type: 'message_start', message: { role: 'assistant', content: [] } });
    emit({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: final.content[0].text } });
    appendMessage(final);
    emit({ type: 'message_end', message: final });
    emit({ type: 'turn_end', message: final, toolResults: [] });
  }
  streaming = false;
  emit({ type: 'agent_end', messages: [], willRetry: false });
  emit({ type: 'agent_settled' });
  const waiters = idleWaiters;
  idleWaiters = [];
  waiters.forEach((resolve) => resolve());
}
const isPrompt = (entry) => entry?.type === 'message' && entry.message.role === 'user';
function noteText(index) {
  const anchor = side.anchor;
  const head = anchor ? { index, entryId: anchor.entryId, block: anchor.block, start: anchor.start, end: anchor.end }
    : { index, file: side.source.file };
  const quote = anchor ? anchor.quote : side.source.quote;
  return '<!-- coact-anchor ' + JSON.stringify(head) + ' -->\n> ' + quote + '[^coact-' + index + ']\n\n[^coact-' + index + ']: ' + side.submission.summary;
}
async function sideCommand(command, payload) {
  await waitForIdle();
  const report = async (data) => { await select({ __coactNvimPiSide: true, ...data }); response(command); };
  if (payload.action === 'open') {
    const path = branch();
    const origin = leafId;
    if (!origin || isPrompt(path[path.length - 1])) return report({ action: 'error', message: 'no answered turn' });
    let target = origin;
    const anchor = payload.anchor;
    if (anchor) {
      const entry = byId(anchor.entryId);
      const block = entry?.message?.content?.[anchor.block];
      if (block?.type !== 'text' || block.text.slice(anchor.start, anchor.end) !== anchor.quote) {
        return report({ action: 'error', message: 'The selected text does not match the stored message.' });
      }
      const index = path.findIndex((item) => item.id === anchor.entryId);
      let end = index;
      for (let i = index + 1; i < path.length && !isPrompt(path[i]); i++) end = i;
      target = path[end].id;
    }
    leafId = target;
    side = { originLeafId: origin, anchor, source: payload.source };
    return report({ action: 'opened', originLeafId: origin, branchPointId: target, leafId });
  }
  if (payload.action === 'arm') { side.armed = true; return report({ action: 'armed' }); }
  if (payload.action === 'disarm') { side.armed = false; return report({ action: 'disarmed' }); }
  const sideLeafId = leafId;
  let index;
  if (payload.annotate) {
    if (!side?.submission) return report({ action: 'error', message: 'The model did not submit an annotation.' });
    index = entries.filter((entry) => entry.type === 'branch_summary').length + 1;
    leafId = payload.originLeafId;
    append({ type: 'branch_summary', fromId: payload.originLeafId, summary: noteText(index) });
  } else if (payload.originLeafId) {
    leafId = payload.originLeafId;
  }
  side = null;
  return report({ action: 'closed', leafId, sideLeafId, annotationIndex: index });
}
for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line);
  if (command.type === 'extension_ui_response') {
    const resolve = uiPending.get(command.id);
    uiPending.delete(command.id);
    if (resolve) resolve(command);
    continue;
  }
  switch (command.type) {
    case 'get_state': response(command, { sessionId, isStreaming: streaming, model: null, autoCompactionEnabled: true }); break;
    case 'get_entries': response(command, { entries: branch(), leafId }); break;
    case 'get_session_stats': response(command, { tokens: {}, cost: 0 }); break;
    case 'get_commands': response(command, { commands: [] }); break;
    case 'fixture_state': response(command, { leafId, entries, branch: branch().map((entry) => entry.id) }); break;
    case 'prompt':
      if (command.message.startsWith('/coact-nvim-side ')) void sideCommand(command, JSON.parse(command.message.slice(17)));
      else if (command.message.startsWith('/coact-')) response(command);
      else void run(command);
      break;
    default: response(command);
  }
}
