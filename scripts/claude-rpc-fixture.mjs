import readline from 'node:readline';
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
const send = (m) => process.stdout.write(JSON.stringify(m) + '\n');
const arg = (name) => process.argv.find((x) => x.startsWith(`--${name}=`))?.slice(name.length + 3);
const resume = arg('resume');
const session = arg('session-id') || resume || randomUUID();
const dir = join(process.env.CLAUDE_CONFIG_DIR, 'projects', process.cwd().replace(/[^a-zA-Z0-9]/g, '-'));
const path = join(dir, `${session}.jsonl`);
let records = [];
if (resume && existsSync(join(dir, `${resume}.jsonl`))) {
  records = readFileSync(join(dir, `${resume}.jsonl`), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  const at = arg('resume-session-at');
  if (at) records = records.slice(0, records.findIndex((e) => e.uuid === at) + 1);
}
let parent = records.at(-1)?.uuid || null;
let materialized = existsSync(path);
const persist = (record) => {
  mkdirSync(dir, { recursive: true });
  if (!materialized) {
    writeFileSync(path, records.map((e) => JSON.stringify(e)).join('\n') + (records.length ? '\n' : ''));
    materialized = true;
  }
  const e = { ...record, parentUuid: parent, cwd: process.cwd(), sessionId: session, timestamp: new Date().toISOString() };
  appendFileSync(path, JSON.stringify(e) + '\n');
  records.push(e); parent = e.uuid;
};
let count = 0, timer;
let model = 'fixture';
const skill = process.env.COACT_FIXTURE_SKILL || 'coact-proof';
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line);
  if (m.type === 'control_request') {
    if (process.env.COACT_FIXTURE_MODE === 'exit') process.exit(0);
    if (process.env.COACT_FIXTURE_MODE === 'hang') return;
    if (m.request.subtype === 'set_model') {
      if (m.request.model === 'bad-model') {
        send({ type: 'control_response', response: { subtype: 'error', request_id: m.request_id, error: 'model rejected' } });
        return;
      }
      model = m.request.model;
    }
    const response = m.request.subtype === 'initialize' ? {
      models: [{ value: 'fixture', displayName: 'Fixture' }, { value: 'fixture-next' }, null],
      commands: [{ name: skill, description: 'Fixture skill' }, { name: 'compact', builtin: true }, null],
    } : {};
    send({ type: 'control_response', response: { subtype: 'success', request_id: m.request_id, response } });
    if (m.request.subtype === 'interrupt') {
      clearTimeout(timer);
      send({ type: 'result', subtype: 'success', is_error: false, usage: null });
    }
  } else if (m.type === 'user') {
    if (m.message.content === '/compact') {
      send({ type: 'system', subtype: 'status', status: 'compacting' });
      timer = setTimeout(() => {
        send({ type: 'system', subtype: 'compact_boundary', compact_metadata: null });
        send({ type: 'result', subtype: 'success', is_error: false, usage: null });
      }, 25);
      return;
    }
    const user = { type: 'user', uuid: m.uuid || randomUUID(), message: m.message };
    persist(user); send(user);
    const output = m.message.content.startsWith(`/${skill}`) ? 'SKILL_OK' : 'COACT_CLAUDE_OK';
    const id = `message-${++count}-${session}`;
    send({ type: 'system', subtype: 'init', model, session_id: session, skills: [skill] });
    timer = setTimeout(() => {
      send({ type: 'stream_event', event: { type: 'message_start', message: { id } } });
      send({ type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } } });
      send({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: output } } });
      send({ type: 'stream_event', event: { type: 'content_block_stop', index: 0 } });
      const assistant = { type: 'assistant', uuid: randomUUID(), message: { id, model, role: 'assistant', content: [{ type: 'text', text: output }] } };
      persist(assistant); send(assistant);
      send({ type: 'result', subtype: 'success', is_error: false, usage: null });
    }, 120);
  }
});
