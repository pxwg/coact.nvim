# codex.nvim

`codex.nvim` is a Neovim client for Codex app-server. It keeps the Codex chat surface inside Neovim: each Codex thread has a buffer, thread navigation can use a picker, prompt tokens complete through `blink.cmp`, app-server file changes are reviewed as patch proposals, and `nvim.apply_patch` edits are reviewed hunk-by-hunk in the edited file buffer.

The plugin talks to Codex through:

```sh
codex app-server --listen stdio://
```

Codex app-server is experimental upstream, so this plugin keeps the transport layer small and explicit.

## Features

- Buffer-per-thread chat UI at `codex://thread/<id>`.
- `:Codex new`, `:Codex pick`, `:Codex resume`, `:Codex submit`, and `:Codex stop`.
- `:Codex status` and `require("codex").status()` for lightweight runtime state.
- Modern Neovim TUI render: Codex items are normalized into blocks, then drawn with extmark headers, placeholders, virtual lines, stream gutters, composer token highlights, and a busy spinner.
- Streaming render for agent messages, reasoning, plans, command output, MCP calls, dynamic tool calls, collab-agent calls, web search, image events, and file changes.
- Expandable reasoning/tool/agent/patch placeholders with `za`; detail scratch views with `K` or `:Codex detail`.
- Prompt-anchor window following that keeps the composer stable while Codex streams, but suspends auto-follow when you scroll away.
- App-server lifecycle notifications are preserved as timeline blocks; unknown notifications are retained as raw blocks and can be shown for debugging.
- Patch review window for `item/fileChange/requestApproval` and legacy `applyPatchApproval`.
- Interactive in-buffer hunk review for `nvim.apply_patch`, including reject feedback returned to the agent loop.
- Basic command and permission approval prompts.
- Optional dynamic tools exposed to Codex under the `nvim` namespace:
  - `nvim.current_buffer`
  - `nvim.diagnostics`
  - `nvim.quickfix`
  - `nvim.apply_patch`
- Source-buffer tracking so prompt context and Neovim tools target the buffer that opened the thread.
- `blink.cmp` source where `$` comes from Codex app-server skills, `/` opens CLI-style slash commands, and `@` expands Neovim context.
- Thread picker via `snacks.picker` when available, with `vim.ui.select` fallback.

## Requirements

- Neovim 0.10 or newer.
- A working `codex` executable with `app-server` support.
- `git` on `$PATH` for the Neovim-owned `nvim.apply_patch` dynamic tool.
- Optional: `snacks.nvim` for thread picking.
- Optional: `blink.cmp` for prompt completions.

## Installation

Use your plugin manager of choice. With `lazy.nvim`:

```lua
{
  "pxwg/codex.nvim",
  config = function()
    require("codex").setup()
  end,
}
```

## Setup

Default configuration:

```lua
require("codex").setup({
  app_server = {
    command = { "codex", "app-server", "--listen", "stdio://" },
    initialize_timeout_ms = 10000,
    sanitize_malloc_env = true,
  },
  thread = {
    model = nil,
    model_provider = nil,
    service_tier = nil,
    approval_policy = "on-request",
    approvals_reviewer = "user",
    sandbox = "workspace-write",
    permissions = nil,
    developer_instructions = nil,
    base_instructions = nil,
    personality = nil,
    ephemeral = false,
  },
  buffer = {
    on_attach = nil,
  },
  ui = {
    layout = "float",
    width = 0.82,
    height = 0.82,
    sidebar_width = 0.42,
    render_delay_ms = 35,
    auto_scroll = true,
  },
  render = {
    prompt_marker = "## Prompt",
    separator = "───",
    show_raw_events = false,
    virtual_blocks = {
      default_expanded = false,
      max_lines = 80,
      max_width = 180,
    },
  },
  completion = {
    enabled = true,
    ttl_ms = 30000,
  },
  dynamic_tools = {
    enabled = true,
    prefer_nvim_apply_patch = true,
  },
})
```

On macOS, `sanitize_malloc_env` removes inherited `MallocStackLogging*` variables before spawning app-server. This avoids noisy malloc runtime messages from parent GUI environments; set it to `false` if you intentionally need those variables while debugging Codex.

## Commands

```vim
:Codex new [initial prompt]
:Codex open [thread-id]
:Codex resume <thread-id>
:Codex pick
:Codex list
:Codex submit
:Codex stop
:Codex detail
:Codex health
:Codex status
:Codex restart
:Codex attach [all]
:Codex add-buffer
:Codex add-selection
```

Inside a Codex thread buffer, write below `## Prompt` and press `<C-s>` to submit. Use `za` on a placeholder block to expand or collapse reasoning/tool/agent details. Use `K` to open the full block detail buffer. During streaming, windows near the prompt keep following the composer; scrolling away suspends that follow state for the window.

`:Codex status` reports whether app-server is running, current and active thread ids, pending request counts, and the current thread generation/status. The same data is available programmatically through `require("codex").status()` for statuslines or custom integrations.

`:Codex attach` reruns the configured Codex buffer attach hook for the current thread buffer. `:Codex attach all` reruns it for every loaded Codex thread buffer. Use `buffer.on_attach = function(bufnr, payload) ... end` or `require("codex").on("buffer_attached", cb)` to attach editor-local helpers such as input-method LSP clients, formula concealers, or buffer-local keymaps after codex.nvim creates the chat buffer.

`:Codex add-buffer` appends the current source buffer path to the active chat prompt using Codex's official `@path` syntax. `:Codex add-selection` appends `@selection` when the source buffer has a visual selection.

Command-line completion covers subcommands, `attach all`, loaded Codex buffer numbers, and loaded thread ids for `open`/`resume`.

## Health

Run `:checkhealth codex` to verify the Neovim version, `codex` executable, app-server stdio support, app-server command shape, `git` for `nvim.apply_patch`, optional picker/completion integrations, and dynamic tool registration. `:Codex health` still performs the runtime app-server initialization check.

## Prompt Tokens

`codex.nvim` treats the chat buffer as the main UI surface. Prompt token completions are available through the `blink.cmp` source:

- `$skill:<name>` from Codex app-server `skills/list`
- `/model`, `/permissions`, `/mcp`, `/status`, and other CLI-style slash commands handled by codex.nvim
- `@buffer`, `@selection`, `@cursor`, `@diagnostics`, `@quickfix`, `@buffers`, `@cwd`, `@file:`, `@image:`, and direct `@path/to/file`

Configure `blink.cmp` with:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "codex" },
    providers = {
      codex = {
        name = "Codex",
        module = "codex.completion.blink",
      },
    },
  },
})
```

`@...` tokens are expanded by Neovim into extra Codex inputs. Argument providers use `@provider:input`; paths with spaces can wrap the path in backticks:

```text
@file:`path with spaces.lua`
@image:`assets/screenshot.png`
@lua/codex/init.lua
```

The blink source completes paths after `@file:` and `@image:` using the same backtick form. In insert mode, pressing `<Tab>` immediately after `@file:` opens `snacks.picker.files` when available, with `vim.ui.select` only as a fallback; the selected file is inserted as direct `@path/to/file` syntax. `@image:` keeps the provider form because image inputs need image-specific attachment metadata. Custom hooks can be registered with `require("codex.context").register_hook(name, callback)`.

When a thread is opened from another window, `codex.nvim` remembers that source buffer as the thread target, so `@buffer`, `@selection`, `@cursor`, `@diagnostics`, and Neovim dynamic tools do not accidentally read the chat buffer itself. `@selection` uses the source buffer's visual selection marks and includes file/range metadata plus diagnostics in the selected range. If the source buffer has a visual selection, that selection context is automatically attached to each submitted prompt unless the prompt already contains `@selection`. `@buffer` includes buffer id, path, filetype, cursor, modified state, line count, and buffer text. `$skill:<name>` is converted to a Codex skill input using the skill metadata returned by app-server. Slash commands are handled locally before `turn/start`, so `/...` entries are not sent as model-visible tool calls; accepting a slash completion removes the typed prefix and opens that command's page or picker instead of inserting text. Each slash command declares a return form (`page`, `select`, `notify`, `insert`, or `action`) and uses one presenter for Neovim rendering. Settings commands such as `/model`, `/fast`, `/permissions`, `/sandbox`, `/reasoning`, `/personality`, and `/experimental` open Neovim pickers backed by Codex app-server catalog responses where available and update the active thread where app-server supports it. `/model` also offers the selected model's advertised thinking-effort choices when app-server returns them. Legacy `>buffer`, `>diagnostics`, and `>quickfix` still parse as Neovim context aliases, but new completions use `@`.

## Patch Review

Codex app-server sends file edits as file-change approval requests. `codex.nvim` normalizes these into a single patch proposal model and opens a review window.

Review keys:

- `a`: accept
- `A`: accept for session
- `d`: decline
- `c`: cancel
- `[c` / `]c`: jump between indexed file changes or diff hunks
- `<CR>` / `o`: open the related file at the hunk location when available
- `q`: close the review window without answering

The review buffer indexes file changes and unified-diff hunk headers with extmarks, so large patches can be inspected without manually scanning the whole markdown document. For modern app-server file changes, Codex still owns the final patch application after approval.

The `nvim.apply_patch` dynamic tool uses a different in-buffer flow. Neovim refuses to overwrite modified loaded buffers, runs `git apply --check`, opens the edited file directly, previews proposed changes as real buffer edits with old content shown as virtual lines, and writes only after the user resolves the hunks.

In a `nvim.apply_patch` buffer review:

- `<leader>ca`: accept current hunk
- `<leader>cr`: reject current hunk and prompt for a reason
- `<leader>cA`: accept all remaining hunks
- `<leader>cR`: reject all remaining hunks and prompt for a reason
- `<leader>cf`: switch the current turn to native `apply_patch` fallback
- `<leader>cq`: cancel the review
- `[c` / `]c`: jump between pending hunks

Rejected hunk reasons, partial-apply status, final file state, and a final diff are returned to Codex as the dynamic tool result so the agent can continue from the user's feedback. When `dynamic_tools.prefer_nvim_apply_patch` is enabled, codex.nvim adds thread developer instructions that ask Codex to prefer `nvim.apply_patch` for workspace edits while preserving any user-provided developer instructions.

## Events

`codex.nvim` emits `User` autocmds for editor integrations:

- `CodexBufferAttached`: after the Codex buffer attach hook point runs for a thread buffer. `event.data` includes `bufnr`, `thread_id`, and `thread`.
- `CodexBufferOpened`: after a thread buffer is opened in a window. `event.data` includes `bufnr`, `winid`, `thread_id`, and `thread`.
- `CodexThreadOpened`: when app-server reports a thread start.
- `CodexGenerationCompleted`: when app-server reports a completed generation.

## Architecture

The plugin follows the same shape as a native Neovim chat client:

- `lua/codex/rpc.lua`: stdio JSONL app-server client.
- `lua/codex/state.lua`: thread, turn, item, pending-request, render-index, expansion, view, timeline/raw, and cache state.
- `lua/codex/core.lua`: app-server notification and server-request reducer; maps Codex lifecycle events to UI generation states and timeline/raw blocks.
- `lua/codex/context.lua`: source-buffer tracking for prompt context and Neovim dynamic tools.
- `lua/codex/events.lua`: Codex `ThreadItem` to modern Neovim TUI block normalization.
- `lua/codex/buffers.lua`: `codex://thread/<id>` buffers, window option management, prompt collection, and block keymaps.
- `lua/codex/ui/render.lua`: extmark TUI renderer for headers, placeholders, virtual lines, spinner, stream gutters, composer tokens, prompt-anchor follow, and foldexpr ranges.
- `lua/codex/ui/tool_renderers.lua`: smart renderers for command, patch, and generic tool output.
- `lua/codex/ui/detail.lua`: scratch detail buffers for the block under cursor.
- `lua/codex/patch_review.lua`: app-server patch proposal review UI.
- `lua/codex/patch_session.lua`: in-buffer hunk review for `nvim.apply_patch`.
- `lua/codex/slash.lua`: CLI-style slash command catalog, declared return forms, local dispatch, result presenter, and settings pickers.
- `lua/codex/completion/blink.lua`: `blink.cmp` source.
- `lua/codex/dynamic_tools.lua`: Neovim-backed dynamic tools.
- `lua/codex/health.lua`: `:checkhealth codex` provider.

## Verification

Run the smoke test:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

The smoke test loads the plugin, exercises health and status helpers, parser/completion behavior, verifies source-buffer context tracking, checks `@file:` picker hooks and direct `@path` syntax, verifies patch-review hunk indexing, verifies Neovim-owned patch application and in-buffer hunk rejection feedback, verifies app-server initialization and empty thread creation, and asserts that the TUI renderer creates extmarks, placeholders, fold levels, detail output, view-follow state, timeline/raw event blocks, process output blocks, and a busy spinner.

## License

MIT. See [LICENSE](LICENSE).
