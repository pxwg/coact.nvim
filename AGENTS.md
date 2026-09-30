# Project Rules

## Verification

- Run all validation on the remote test host, including headless Neovim, formatting/syntax checks, DeepSeek integration, and native Claude Code integration. Do not run those tests on the development machine.
- `scripts/test-claude-remote.sh` syncs source and runs the Claude checks remotely. Keep API credentials in private remote environment files or launchers, never in the repository. Claude tests use API authentication through Neovim, not Claude account login.

- After behavior changes to coact.nvim Lua, docs, app-server/RPC handling, parser/completion, slash commands, patch review, dynamic tools, or TUI rendering, run the headless smoke script:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

- Pair the smoke script with focused checks for the files changed, such as `stylua` for touched Lua files and `git diff --check` for whitespace issues.
- When changing native `apply_patch` hook behavior, also run focused hook checks: shell syntax checks for hook scripts, Node syntax checks for probe scripts when touched, `scripts/native-apply-patch-hook-live-test.sh`, and focused PreToolUse allow/deny probes when the approval protocol changes.

## App-Server Handling

- Classify every app-server notification deliberately as a cache update, timeline block, raw diagnostic block, or user-visible chat content.
- High-volume startup/status notifications such as `mcpServer/startupStatus/updated` and `app/list/updated` should refresh caches without appearing in the chat timeline by default.
- Add or update smoke assertions when changing app-server event mappings.
- Treat Codex app-server JSON `null` values as `vim.NIL` in Neovim, and normalize them as absent before string concatenation, indexing, title rendering, status rendering, stream aggregation, or output rendering.
- Add smoke coverage with synthetic `vim.NIL` notifications when handling new app-server fields.

## Context And Dynamic Tools

- Prompt context tokens and Neovim dynamic tools must target the source buffer that opened the Coact thread, not the chat buffer.
- Preserve source-buffer targeting when changing parser, completion, context, buffers, or dynamic tools.

## Edit Modes

- For the Codex provider in pair edit mode, workspace edits should use Codex's native `apply_patch` tool.
- Pair mode routes native `apply_patch` through a Neovim `PreToolUse` hook that opens interactive file-buffer hunk review before the native tool completes.
- After Neovim review, accepted hunks are written through the `patch_session` file-buffer path, then coact.nvim returns to native `apply_patch` with an approval and no-op completion patch.
- Pair mode should accept native app-server permission/file-change approvals only for `apply_patch` items already reviewed by the Neovim hook; unreviewed native file changes should be declined.
- Do not call `nvim.apply_patch` in pair mode unless explicit legacy compatibility is enabled for that path.
- Patch application must refuse modified loaded buffers unless a future safe path explicitly preserves or reconciles user buffer changes.
- Yolo mode uses native `apply_patch` directly without the Neovim `PreToolUse` review hook.
- Claude pair mode deliberately permits Bash for tests/builds/inspection; it is a cooperative review policy, not a write sandbox. Prompt file modifications through MCP `edit` (precise replacements) or `openDiff` (full contents), both using Neovim review.
- Claude review tools may target paths outside the thread workspace. Preserve dirty-buffer refusal and exact-match/conflict checks; do not restore workspace containment restrictions without a new user decision.
- Claude history navigation reuses the Pi tree UI/keymaps but explicitly confirms conversation-only rewind into a new native branch. Preserve original sessions and never implicitly roll back workspace files; `r` only reveals local transcript entries.
- Claude busy submissions are FIFO follow-ups, not immediate steering. Keep queue state per thread, cancel unsent entries on stop/exit, and include separate-Neovim restart tests when changing disk history or pending-fork restoration.

## Commits

- Use Conventional Commits for every commit in this repository.
- Format commit subjects as `<type>(<scope>): <description>` or `<type>: <description>`.
- Prefer these types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Keep the description imperative, concise, and lowercase unless it contains a proper noun.
- Use an optional scope when it clarifies the touched area, for example `feat(parser): attach image assets`.
- Use `!` after the type or scope for breaking changes, and include a `BREAKING CHANGE:` footer when applicable.
- Add a body when the reason, migration notes, or behavioral impact are not obvious from the subject.

Examples:

- `feat(parser): support quoted context asset paths`
- `fix(rpc): sanitize app-server malloc environment`
