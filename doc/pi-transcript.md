# Pi transcript: selected-branch history

## Three different views

- **Tree:** all persisted branches and their parent/child relationships. An entry
  shown below another branch's leaf need not have happened after that leaf.
- **Chat:** the selected branch's root-to-leaf history, including compactions at
  the points where they happened. Compaction never deletes chat ancestors.
- **Model context:** the summary and retained messages selected by Pi. This is
  not the chat history, and is not used as its data source.

We initially used `get_messages` for chat hydration. That reproduced Pi's
context ordering but placed the newest compaction summary above older retained
messages and hid summarized history. The agreed chat contract is historical
order, not the native TUI's context-oriented projection.

## Native API and projection

Verified against installed Pi 0.85.1's `dist/modes/rpc/rpc-mode.js`,
`dist/core/session-manager.js`, and `dist/modes/json-event.js`. See upstream
[RPC](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/rpc.md)
and [session format](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/session-format.md).

Pi already supports this model:

- SDK `SessionManager.getBranch()` returns the root-to-leaf entry path.
- RPC `get_entries` returns all entries with stable `id`/`parentId` and the
  current `leafId` in one response.
- RPC `get_messages` returns current model context, not complete history.

`pi_history.lua` indexes `get_entries`, walks parents from the returned leaf,
and reverses the path. It never sorts by timestamp or JSONL append order, and
never infers the leaf from the final entry. Null leaf means an empty branch.
Missing ancestors, cycles and duplicate IDs fail projection rather than
silently replacing chat with an incomplete or unrelated branch.

Message entries become user/assistant/tool blocks. Compaction and branch
summary entries become independent historical blocks. A compaction's
`firstKeptEntryId` or newer `retainedTail` does not prune ancestors or insert
copies of retained messages into history. Displayable custom messages and
shell executions are preserved. Model/thinking settings, labels, session
metadata and extension-private custom entries remain non-chat data; arbitrary
extension TUI renderers are not reimplemented.

Entry IDs determine persisted message/block identities and tree navigation
annotations. Repeated text on sibling branches does not affect identity.
Assistant content order and tool declaration/result correlation are preserved.

## Streaming and reconciliation

Pi's backend turn, assistant message and tool execution are distinct:

- `pi_stream.lua` reconstructs modern RPC tool argument slots without requiring
  legacy cumulative `partial` snapshots, which it also accepts.
- Each assistant start advances message identity. Items carry `piMessageId`
  and `piContentIndex`; late blocks occupy their message's content slot.
- Tool argument completion is not execution completion. Results and cumulative
  progress update the original tool block, including rewritten/empty progress.
- Thinking and tools retain independently foldable blocks rather than being
  moved beneath a later answer's `Thinking finished` group.
- History projection uses an isolated runtime, not the live tool registry.
- After `agent_settled`, history is reconciled with persisted entries. Resume,
  tree navigation and successful compaction refresh use the same projection.
  Compaction during generation is reconciled after the run settles.
- Authoritative snapshots replace stale live/history IDs, not append duplicate
  copies. Reads during streaming return metadata only. Event revisions and
  request sequencing prevent stale asynchronous reads from replacing newer
  history. Invalid/unsupported `get_entries` does not silently fall back to
  context history.

The current implementation fetches a complete snapshot on reconciliation.
Pi's `since` cursor could later optimize transfer; parent-path selection must
still follow the returned leaf, even when a switch appends no entries.

## Verification

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

Smoke includes `scripts/pi-transcript-test.lua` and `scripts/pi-history-test.lua`:
modern/legacy deltas, ordered slots, repeated assistant messages, tool errors,
nulls, live/history races, branch switches with identical prompts, multiple
compactions, retained-tail non-duplication, empty leaves and broken graphs.

Launch one disposable Kitty environment from the repository root:

```sh
nvim -u scripts/pi-transcript-ui.lua -i NONE --listen /tmp/coact-pi-ui.sock
```

Reuse that same environment/socket for all RPC checks:

```lua
CoactPiTranscriptCheck('live')
CoactPiTranscriptCheck('reload')
CoactPiTranscriptCheck('compact')
CoactPiTranscriptCheck('branch')
```

The deterministic JSONL peer exercises subprocess transport, adapter, state and
rendering without model credentials or workspace writes. `reload` checks
normalized parity; `compact` checks the unchanged history prefix followed by
summary events; `branch` verifies sibling exclusion. This is not a live-model
generation test.
