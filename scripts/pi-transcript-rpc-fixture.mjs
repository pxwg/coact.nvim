// Deterministic Pi JSONL peer for transport + Kitty UI regression tests.
// No network, model credentials, workspace tools, or extensions are used.
import { createInterface } from 'node:readline';
const args = process.argv.slice(2);
const sessionId = args[args.indexOf('--session-id') + 1] || 'transcript-e2e';
const emit = (event) => process.stdout.write(JSON.stringify(event) + '\n');
const text = (value) => ({ type: 'text', text: value });
let messages = [];
const entries = [];
let leafId = null;
function append(entry) {
  entry = { ...entry, id: `entry-${entries.length + 1}`, parentId: leafId };
  entries.push(entry);
  leafId = entry.id;
}
function appendMessage(message) { messages.push(message); append({ type: 'message', message }); }
let streaming = false;
const response = (command, data = {}) => emit({ type: 'response', id: command.id, command: command.type, success: true, data });
const pause = () => new Promise((resolve) => setTimeout(resolve, 25));
async function run(command) {
  response(command);
  streaming = true;
  emit({ type: 'agent_start' });
  emit({ type: 'turn_start' });
  const user = { role: 'user', content: command.message };
  appendMessage(user);
  emit({ type: 'message_start', message: user });
  emit({ type: 'message_end', message: user });
  const assistant = { role: 'assistant', content: [
    { type: 'thinking', thinking: 'Keep message and content order' },
    text('Before tool'),
    { type: 'toolCall', id: 'e2e-read', name: 'read', arguments: { path: 'README.md' } },
    text('After tool declaration'),
  ] };
  emit({ type: 'message_start', message: { role: 'assistant', content: [] } });
  const updates = [
    { type: 'thinking_start', contentIndex: 0 },
    { type: 'thinking_delta', contentIndex: 0, delta: assistant.content[0].thinking },
    { type: 'text_start', contentIndex: 1 },
    { type: 'text_delta', contentIndex: 1, delta: assistant.content[1].text },
    { type: 'toolcall_start', contentIndex: 2, id: 'e2e-read', toolName: 'read' },
    { type: 'toolcall_delta', contentIndex: 2, delta: '{"path":' },
    { type: 'toolcall_delta', contentIndex: 2, delta: '"README.md"}' },
    { type: 'toolcall_end', contentIndex: 2, toolCall: assistant.content[2] },
    { type: 'text_start', contentIndex: 3 },
    { type: 'text_delta', contentIndex: 3, delta: assistant.content[3].text },
  ];
  for (const event of updates) { emit({ type: 'message_update', assistantMessageEvent: event }); await pause(); }
  appendMessage(assistant);
  emit({ type: 'message_end', message: assistant });
  emit({ type: 'tool_execution_start', toolCallId: 'e2e-read', toolName: 'read', args: { path: 'README.md' } });
  const result = { role: 'toolResult', toolCallId: 'e2e-read', toolName: 'read', content: [text('Fixture read output')], isError: false };
  appendMessage(result);
  emit({ type: 'tool_execution_end', toolCallId: 'e2e-read', toolName: 'read', result, isError: false });
  emit({ type: 'turn_end', message: assistant, toolResults: [result] });
  emit({ type: 'turn_start' });
  const final = { role: 'assistant', content: [text('Final answer: source order preserved')] };
  emit({ type: 'message_start', message: { role: 'assistant', content: [] } });
  emit({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: final.content[0].text } });
  appendMessage(final);
  emit({ type: 'message_end', message: final });
  emit({ type: 'turn_end', message: final, toolResults: [] });
  streaming = false;
  emit({ type: 'agent_end', messages, willRetry: false });
  emit({ type: 'agent_settled' });
}
for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line);
  switch (command.type) {
    case 'get_state': response(command, { sessionId, isStreaming: streaming, model: null, autoCompactionEnabled: true }); break;
    case 'get_messages': response(command, { messages }); break;
    case 'get_entries': response(command, { entries, leafId }); break;
    case 'fixture_branch': {
      const parent = leafId;
      leafId = entries[0].id;
      appendMessage({ role: 'user', content: 'Alternate branch only' });
      response(command, { leafId, previousLeafId: parent });
      break;
    }
    case 'get_session_stats': response(command, { tokens: {}, cost: 0 }); break;
    case 'get_commands': response(command, { commands: [] }); break;
    case 'prompt':
      if (command.message.startsWith('/coact-')) response(command);
      else void run(command);
      break;
    case 'compact': {
      emit({ type: 'compaction_start', reason: 'manual' });
      const result = { summary: 'Compacted context checkpoint', tokensBefore: 12345 };
      append({ type: 'compaction', ...result, firstKeptEntryId: entries[entries.length - 1].id });
      append({ type: 'branch_summary', summary: 'Branch checkpoint', fromId: null });
      messages = [{ role: 'compactionSummary', ...result }, ...messages.slice(-1), { role: 'branchSummary', summary: 'Branch checkpoint', fromId: null }];
      emit({ type: 'compaction_end', result, reason: 'manual', aborted: false, willRetry: false });
      response(command, result);
      break;
    }
    default: response(command);
  }
}
