import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Execute the actual generated bridge helpers, without starting Pi or an agent.
const source = readFileSync(new URL('../lua/coact/providers/pi_edit_bridge.lua', import.meta.url), 'utf8');
const helpers = source.slice(source.indexOf('function treeTextContent('), source.indexOf('function parseTreeArgs('));
const { treePickerNodes } = vm.runInNewContext(`${helpers}; ({ treePickerNodes });`);
const root = { entry: { id: '0', parentId: null, type: 'message', message: {
  role: 'assistant', content: [
    { type: 'thinking', thinking: 'PRIVATE_THINKING' },
    { type: 'image', data: 'PRIVATE_IMAGE' },
    { type: 'toolCall', id: 'call', name: 'read', arguments: { path: '/tmp/test', details: { secret: 'PRIVATE_ARGS' } } },
  ],
} }, label: 'checkpoint', children: [] };
let last = root;
for (let i = 1; i <= 1500; i++) {
  const child = { entry: { id: String(i), parentId: String(i - 1), type: 'message',
    message: { role: 'user', content: `entry ${i}` } }, children: [] };
  last.children.push(child);
  last = child;
}
root.children.push({ entry: { id: 'sibling', parentId: '0', type: 'custom', data: { secret: 'PRIVATE_DATA' } }, children: [] });
const result = treePickerNodes([root]);
assert.equal(result.nodes.length, 1502);
assert.equal(result.nodes[1].entry.id, '1');
assert.equal(result.nodes.at(-1).entry.id, 'sibling');
assert.equal(result.entriesById.get('0'), root.entry);
assert.equal(result.nodes[0].label, 'checkpoint');
assert.equal(result.nodes[0].entry.message.content[0].text, '');
assert.equal(result.nodes[0].entry.message.content[1].arguments.path, '/tmp/test');
const wire = JSON.stringify({ __coactNvimPiTree: true, nodes: result.nodes, leafId: '1500' });
assert(!wire.includes('PRIVATE_'));
assert(!wire.includes('children'));
// stdout is consumed by the headless smoke test through Neovim's real decoder.
process.stdout.write(wire);
