// Exercises the real /coact-nvim-side helpers and submit_annotation against a fake Pi context.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Execute the actual generated bridge helpers, without starting Pi or an agent.
const source = readFileSync(new URL('../lua/coact/providers/pi_edit_bridge.lua', import.meta.url), 'utf8');
const slice = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));
const helpers = slice('function parseTreeArgs(', 'function treeAction(')
  + slice('function sideAction(', 'export default function');
assert.ok(source.includes('pi.registerCommand("coact-nvim-side"'));
assert.ok(source.includes('pi.on("session_before_tree"'));
const Type = { Object: (value) => value, String: (value) => value };
const api = vm.runInNewContext(helpers + '; ({ handleSideCommand, executeSubmitAnnotation, pending: () => sideState?.pendingSummary });', { Type });
const plain = (value) => JSON.parse(JSON.stringify(value));

function session(list, leaf) {
  const byId = new Map(list.map((entry) => [entry.id, entry]));
  const state = { leaf, navigations: [], reports: [], summaries: [], tools: ['read', 'edit'] };
  const pi = { getActiveTools: () => [...state.tools], setActiveTools: (names) => { state.tools = [...names]; } };
  const ctx = {
    waitForIdle: async () => {},
    sessionManager: {
      getLeafId: () => state.leaf,
      getEntry: (id) => byId.get(id),
      getBranch: () => {
        const out = [];
        for (let entry = byId.get(state.leaf); entry; entry = byId.get(entry.parentId)) out.unshift(entry);
        return out;
      },
    },
    navigateTree: async (id, options) => {
      state.navigations.push(plain({ id, ...options }));
      if (options.summarize) {
        // What Pi does with a session_before_tree summary: a branch_summary child of the target.
        const summary = api.pending();
        assert.ok(summary, 'summarize navigation needs the pending annotation');
        const entry = { type: 'branch_summary', id: 'note' + byId.size, parentId: id, summary: summary.summary, details: summary.details };
        byId.set(entry.id, entry);
        state.summaries.push(plain(entry));
        state.leaf = entry.id;
      } else {
        state.leaf = id;
      }
      return { cancelled: false };
    },
    ui: { select: async (_title, options) => { state.reports.push(plain(options[0])); return 'ok'; } },
  };
  return { ctx, pi, state, run: (args) => api.handleSideCommand(JSON.stringify(args), ctx, pi) };
}
const msg = (id, parentId, role, content = []) => ({ type: 'message', id, parentId, message: { role, content } });
const answer = '😀 The monad is a monoid';
const tree = () => [
  msg('u1', null, 'user'),
  msg('a1', 'u1', 'assistant', [{ type: 'thinking', thinking: 'x' }, { type: 'text', text: answer }, { type: 'toolCall', id: 't' }]),
  msg('t1', 'a1', 'toolResult'),
  msg('a2', 't1', 'assistant', [{ type: 'text', text: 'done' }]),
  msg('u2', 'a2', 'user'),
  msg('a3', 'u2', 'assistant', [{ type: 'text', text: 'later' }]),
];
// "monad" in JavaScript offsets (the emoji is two UTF-16 units).
const anchor = { entryId: 'a1', block: 1, start: answer.indexOf('monad'), end: answer.indexOf('monad') + 5, quote: 'monad' };

{
  const s = session(tree(), 'a3');
  await s.run({ action: 'open', anchor });
  assert.deepEqual(s.state.navigations, [{ id: 'a2', summarize: false }], 'branch at the end of the selected turn');
  const opened = s.state.reports[0];
  assert.equal(opened.action, 'opened');
  assert.equal(opened.originLeafId, 'a3');
  assert.equal(opened.prefix, '😀 The ');
  assert.equal(opened.suffix, ' is a monoid');

  await assert.rejects(api.executeSubmitAnnotation({ question: 'q' }), /only available after the user confirms/);
  await s.run({ action: 'close', annotate: true });
  assert.equal(s.state.reports[1].action, 'error', 'no annotation without a submission');

  await s.run({ action: 'arm' });
  assert.deepEqual(s.state.tools, ['read', 'edit', 'submit_annotation']);
  const result = await api.executeSubmitAnnotation({ question: 'What is a monad?', answer_brief: 'A monoid.', summary: 'Monads are monoids.', answer_detail: 'In the category of endofunctors.' });
  assert.equal(result.terminate, true);
  await s.run({ action: 'close', annotate: true });
  const closed = s.state.reports[3];
  assert.equal(closed.action, 'closed');
  assert.equal(closed.annotationIndex, 1);
  assert.deepEqual(s.state.tools, ['read', 'edit'], 'tools restored after the side');
  assert.deepEqual(s.state.navigations[1], { id: 'a3', summarize: true });
  const note = s.state.summaries[0];
  assert.equal(note.parentId, 'a3', 'the note follows the main leaf');
  assert.equal(closed.leafId, note.id);
  const [head, ...body] = note.summary.split('\n');
  assert.deepEqual(JSON.parse(head.replace(/^<!-- coact-anchor /, '').replace(/ -->$/, '')), { index: 1, entryId: 'a1', block: 1, start: anchor.start, end: anchor.end });
  assert.equal(body[0], '> monad[^coact-1]');
  assert.ok(note.summary.includes('[^coact-1]: Monads are monoids.'));
  assert.ok(note.summary.includes('    In the category of endofunctors.'));
  assert.equal(note.details.coactAnnotation.question, 'What is a monad?');
  assert.equal(api.pending(), undefined);

  // A later side counts earlier notes on the main branch.
  await s.run({ action: 'open', anchor });
  await s.run({ action: 'arm' });
  await api.executeSubmitAnnotation({ question: 'again', answer_brief: 'b', summary: 's', answer_detail: 'd' });
  await s.run({ action: 'close', annotate: true });
  assert.equal(s.state.reports.at(-1).annotationIndex, 2);
}
{
  const s = session(tree(), 'a3');
  await s.run({ action: 'open', anchor: { ...anchor, quote: 'monoid' } });
  assert.equal(s.state.reports[0].action, 'error', 'quote must match the stored text');
  await s.run({ action: 'open', anchor: { ...anchor, block: 0 } });
  assert.equal(s.state.reports[1].action, 'error', 'anchors must point into a text block');
  await s.run({ action: 'open', anchor: { ...anchor, entryId: 'u2' } });
  assert.equal(s.state.reports[2].action, 'error', 'anchors must point into an assistant message');
  assert.deepEqual(s.state.navigations, []);
}
{
  const s = session(tree(), 'a3');
  await s.run({ action: 'open', source: { file: 'a.lua', startLine: 1, endLine: 1, quote: 'x' } });
  assert.deepEqual(s.state.navigations, [], 'source selections branch at the leaf');
  await s.run({ action: 'close' });
  assert.equal(s.state.reports[1].action, 'closed');
  assert.deepEqual(s.state.navigations, [], 'nothing to restore without side turns');
}
{
  const s = session(tree(), 'u2');
  await s.run({ action: 'open', anchor });
  assert.equal(s.state.reports[0].action, 'error', 'an unanswered prompt cannot be restored after navigation');
}
console.log('pi side extension: PASS');
