# Project Rules

## Verification

- After behavior changes to codex.nvim Lua, docs, app-server/RPC handling, parser/completion, slash commands, patch review, dynamic tools, or TUI rendering, run the headless smoke script:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

- Pair the smoke script with focused checks for the files changed, such as `stylua` for touched Lua files and `git diff --check` for whitespace issues.

## App-Server Handling

- Classify every app-server notification deliberately as a cache update, timeline block, raw diagnostic block, or user-visible chat content.
- High-volume startup/status notifications such as `mcpServer/startupStatus/updated` and `app/list/updated` should refresh caches without appearing in the chat timeline by default.
- Add or update smoke assertions when changing app-server event mappings.
- Treat Codex app-server JSON `null` values as `vim.NIL` in Neovim, and normalize them as absent before string concatenation, indexing, title rendering, status rendering, stream aggregation, or output rendering.
- Add smoke coverage with synthetic `vim.NIL` notifications when handling new app-server fields.

## Context And Dynamic Tools

- Prompt context tokens and Neovim dynamic tools must target the source buffer that opened the Codex thread, not the chat buffer.
- Preserve source-buffer targeting when changing parser, completion, context, buffers, or dynamic tools.

## Edit Modes

- In pair edit mode, workspace edits must stay on the `nvim.apply_patch` dynamic tool path.
- Pair mode should decline native app-server file-change/apply_patch approvals; Neovim auto-apply may skip interactive hunk review, but it must still verify, apply, write, and report diagnostics through Neovim.
- Yolo mode is the path for native `apply_patch`.

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
