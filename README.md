# codex.nvim

`codex.nvim` is a Neovim client for coding-agent providers. It keeps the chat surface inside Neovim: each provider thread has a buffer, thread navigation can use a picker, prompt tokens complete through `blink.cmp`, provider file changes are reviewed as patch proposals where supported, and Codex pair-mode native `apply_patch` calls are reviewed and applied through Neovim.

Codex is the default provider and talks through:

```sh
codex app-server --listen stdio://
```

Pi is also supported through:

```sh
pi --mode rpc
```

The provider layer keeps each backend protocol small and explicit while normalizing sessions, turns, messages, tool calls, and settings into the same Neovim UI model.

## Features

- Buffer-per-thread chat UI at `codex://thread/<id>`.
- `:Codex new`, `:Codex pick`, `:Codex resume`, `:Codex submit`, and `:Codex stop`.
- `:Codex status` and `require("codex").status()` for lightweight runtime state.
- Modern Neovim TUI render: provider items are normalized into blocks, then drawn with extmark headers, placeholders, virtual lines, stream gutters, composer token highlights, and a busy spinner.
- Streaming render for agent messages, reasoning, plans, command output, MCP calls, dynamic tool calls, collab-agent calls, web search, image events, and file changes.
- Expandable reasoning/tool/agent/patch placeholders with `za`; detail scratch views with `K` or `:Codex detail`.
- Prompt-anchor window following that keeps the composer stable while Codex streams, but suspends auto-follow when you scroll away.
- App-server lifecycle notifications are preserved as timeline blocks; unknown notifications are retained as raw blocks and can be shown for debugging.
- Patch review window for `item/fileChange/requestApproval` and legacy `applyPatchApproval`.
- Pair-mode native `apply_patch` review through a Codex `PreToolUse` hook, using the same file-buffer changed-block UI as the internal Neovim patch tool.
- Basic command and permission approval prompts.
- Optional dynamic tools exposed to Codex under the `nvim` namespace:
  - `nvim.current_buffer`
  - `nvim.diagnostics`
  - `nvim.quickfix`
- Source-buffer tracking so prompt context and Neovim tools target the buffer that opened the thread.
- `blink.cmp` source where `$` comes from provider skills, `/` opens CLI-style slash commands, and `@` expands Neovim context.
- Thread picker via `snacks.picker` when available, with `vim.ui.select` fallback.

## Requirements

- Neovim 0.10 or newer.
- A working provider executable:
  - `codex` with `app-server` support for the default Codex provider.
  - Optional: `pi` with `--mode rpc` support for the Pi provider.
- `git` on `$PATH` is optional for legacy unified-diff compatibility in the internal `nvim.apply_patch` implementation.
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
  provider = "codex", -- "codex" or "pi"
  app_server = {
    command = { "codex", "app-server", "--listen", "stdio://" },
    initialize_timeout_ms = 10000,
    sanitize_malloc_env = true,
  },
  providers = {
    codex = {},
    pi = {
      command = { "pi", "--mode", "rpc" },
      config_dir = nil,
      session_dir = nil,
      provider = nil,
      model = nil,
      thinking = nil,
      no_session = false,
      no_extensions = nil,
      no_skills = nil,
      no_context_files = nil,
      offline = nil,
      tools = nil,
      exclude_tools = nil,
      extra_args = {},
    },
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
    composer = {
      min_height = 2,
      max_height = 0.33,
    },
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
  edit = {
    mode = "pair", -- "pair" or "yolo"
    review = {
      char_diff_max_lines = 120,
      char_diff_max_line_bytes = 1000,
      char_diff_max_total_bytes = 20000,
      keymaps = {
        accept = ".",
        reject = ",",
        accept_all = "ga",
        reject_all = "gr",
        auto_apply = "gA",
        cancel = "q",
        next = "n",
        prev = "p",
        help = "?",
      },
    },
    native_apply_patch_hook = {
      enabled = true,
      timeout_sec = 600,
      status_message = "Reviewing patch in Neovim",
    },
  },
  dynamic_tools = {
    enabled = true,
    prefer_nvim_apply_patch = false,
  },
})
```

On macOS, `sanitize_malloc_env` removes inherited `MallocStackLogging*` variables before spawning app-server. This avoids noisy malloc runtime messages from parent GUI environments; set it to `false` if you intentionally need those variables while debugging Codex.

To use Pi instead of Codex:

```lua
require("codex").setup({
  provider = "pi",
  providers = {
    pi = {
      command = { "pi", "--mode", "rpc" },
      -- Optional isolation. Omit these to use Pi's normal ~/.pi/agent state.
      config_dir = nil,
      session_dir = nil,
      edit_bridge = {
        enabled = true,
        timeout_sec = 600,
      },
    },
  },
})
```

The Pi provider adapts Pi RPC sessions into codex.nvim threads, maps prompts to Pi `prompt` commands, maps `/model` and reasoning changes to Pi model/thinking commands, and normalizes Pi streaming, thinking, and tool events into the same renderer blocks used by Codex. In pair edit mode, `edit_bridge.enabled` dynamically injects a temporary Pi extension into only the Pi process started by codex.nvim. That extension overrides Pi's built-in `edit` and `write` tools, turns them into Neovim-reviewed file-change proposals, and then lets the existing in-buffer patch review write accepted hunks. It does not install or modify user Pi extensions or settings.

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

Opening a provider thread starts in preview state with a read-only `codex-history` transcript buffer using the full UI height. Press an insert-intent key such as `i`, `a`, `I`, `A`, `o`, `O`, `gi`, `c`, `cc`, or `S` to open the unnamed `codex-input` composer below it. Type in the composer and press `<C-s>` or normal-mode `<CR>` to submit; normal-mode `q` closes the composer and returns to preview without discarding the draft. The composer grows with wrapped input up to `ui.composer.max_height`, then scrolls internally. The composer buffer is left unnamed rather than using a `codex://` URI so path-oriented completion sources keep a normal editing context. Use `za` on a placeholder block to expand or collapse reasoning/tool/agent details. Use `K` to open the full block detail buffer. During streaming, transcript windows near the bottom keep following the conversation; scrolling away suspends that follow state for the window.

`:Codex status` reports whether the provider process is running, current and active thread ids, pending request counts, and the current thread generation/status. The same data is available programmatically through `require("codex").status()` for statuslines or custom integrations.

`:Codex attach` reruns the configured buffer attach hook for the current thread buffer. `:Codex attach all` reruns it for every loaded transcript or composer buffer. Use `buffer.on_attach = function(bufnr, payload) ... end` or `require("codex").on("buffer_attached", cb)` to attach editor-local helpers such as input-method LSP clients, formula concealers, or buffer-local keymaps after codex.nvim creates a chat buffer.

`:Codex add-buffer` appends the current source buffer path to the active chat prompt using Codex's official `@path` syntax. `:Codex add-selection` appends `@selection` when the source buffer has a visual selection.

Command-line completion covers subcommands, `attach all`, loaded chat buffer numbers, and loaded thread ids for `open`/`resume`.

## Health

Run `:checkhealth codex` to verify the Neovim version, active provider executable and protocol support, the Codex apply_patch runtime when the Codex provider is active in pair mode, optional picker/completion integrations, and dynamic tool registration. `:Codex health` still performs runtime provider initialization.

## Prompt Tokens

Prompt token completions are available in the `codex-input` composer through the `blink.cmp` source:

- `$skill:<name>` from the active provider's skill catalog where supported
- `/model`, `/status`, and other active-provider slash commands handled by codex.nvim
- `@buffer`, `@selection`, `@cursor`, `@diagnostics`, `@quickfix`, `@buffers`, `@cwd`, `@behavior`, `@file:`, `@image:`, and direct `@path/to/file`

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

`@...` tokens are expanded by Neovim into extra provider inputs. Argument providers use `@provider:input`; paths with spaces can wrap the path in backticks:

```text
@file:`path with spaces.lua`
@image:`assets/screenshot.png`
@lua/codex/init.lua
```

The blink source completes paths after `@file:` and `@image:` using the same backtick form. Its documentation window previews the context that the selected `@...` completion will inject, including file contents, image attachment metadata, selections, diagnostics, and behavior diffs when available. In insert mode, pressing `<Tab>` immediately after `@file:` opens `snacks.picker.files` when available, with `vim.ui.select` only as a fallback; the selected file is inserted as direct `@path/to/file` syntax. `@image:` keeps the provider form because image inputs need image-specific attachment metadata. Custom hooks can be registered with `require("codex.context").register_hook(name, callback)`.

When a thread is opened from another window, `codex.nvim` remembers that source buffer as the thread target, so `@buffer`, `@selection`, `@cursor`, `@diagnostics`, and Neovim dynamic tools do not accidentally read a Codex UI buffer itself. `@selection` uses the source buffer's visual selection marks and includes file/range metadata plus diagnostics in the selected range. Selection context is attached only when the prompt explicitly contains `@selection` or you run `:Codex add-selection`, keeping context injection fully controlled by the prompt. Expanded text contexts are sent before the user request and are labeled as reference context, not instructions; the user request remains the final text input for semantic priority. `@buffer` includes buffer id, path, filetype, cursor, modified state, line count, and buffer text. `$skill:<name>` is converted to the provider's skill invocation format when the provider exposes skills. Slash commands are handled locally before `turn/start`, so `/...` entries are not sent as model-visible tool calls; accepting a slash completion removes the typed prefix and opens that command's page or picker instead of inserting text. Slash completions and `/help` are filtered by the active provider, so Codex app-server-only pages such as `/permissions`, `/sandbox`, `/goal`, or `/experimental` do not appear when the Pi provider is active. Each slash command declares a return form (`page`, `select`, `notify`, `insert`, or `action`) and uses one presenter for Neovim rendering. Settings commands such as `/model`, `/fast`, `/permissions`, `/sandbox`, `/reasoning`, `/personality`, and `/experimental` open Neovim pickers backed by provider catalog responses where available and update the active thread where the provider supports it. `/model` also offers the selected model's advertised thinking-effort choices when the provider returns them. Legacy `>buffer`, `>diagnostics`, and `>quickfix` still parse as Neovim context aliases, but new completions use `@`.

## Patch Review

The Codex provider sends app-server file edits as file-change approval requests. `codex.nvim` normalizes these into a single patch proposal model and opens a review window.

Review keys:

- `a`: accept
- `A`: accept for session
- `d`: decline
- `c`: cancel
- `[c` / `]c`: jump between indexed file changes or diff hunks
- `<CR>` / `o`: open the related file at the hunk location when available
- `q`: close the review window without answering

The review buffer indexes file changes and unified-diff hunk headers with extmarks, so large patches can be inspected without manually scanning the whole markdown document. Outside pair mode, Codex still owns the final app-server file-change application after approval.

`edit.mode = "pair"` is the default. In pair mode, codex.nvim tells Codex to use the native `apply_patch` tool and injects a stable `PreToolUse` hook into the app-server process it starts. The plugin registers trust for that exact hook hash through Codex config, while per-session Neovim RPC details are passed through environment variables, so pair mode does not need `--dangerously-bypass-hook-trust`. That hook previews the patch in the affected Neovim file buffers before the native tool completes. Accepting the review writes accepted changed blocks through the same path as `nvim.apply_patch`, then returns `permissionDecision: "allow"` with a no-op `updatedInput.command` so Codex native `apply_patch` can complete without repeating the real edit; rejecting returns `permissionDecision: "deny"` with the user's reason. Follow-up app-server apply_patch permission and file-change approvals are automatically accepted only when their item id was already reviewed by the Neovim hook, so pair mode does not require `--dangerously-bypass-approvals-and-sandbox`.

The pair-mode native review uses file-buffer changed-block controls with visible in-buffer hints: `.` accepts the current changed block, `,` rejects it with a reason, `n` / `p` jumps between pending changed blocks, `ga` accepts the rest, `gr` rejects the rest, `q` cancels, and `?` opens the key help. The review display wraps long before-lines into readable virtual lines and highlights changed characters inside the current replacement block when it fits the `edit.review.char_diff_*` budget. You can edit the previewed file buffer before accepting; codex.nvim writes the final accepted buffer state and returns the review summary to Codex as hook context, including rejection reasons and any diff between Codex's proposal and the final Neovim-reviewed state. The previous `nvim.apply_patch` dynamic tool implementation remains in the codebase for compatibility and internal tests, but it is no longer exposed by default in pair mode.

For the Pi provider, pair mode uses a process-local extension override instead of Pi's global extension configuration. codex.nvim appends `--extension <tempfile>` while starting Pi RPC and passes the Neovim RPC socket, nonce, and timeout through environment variables. The override computes the proposed `edit`/`write` file content, opens the same in-buffer `patch_session` review used by `nvim.apply_patch`, and reports the accepted or rejected result back to Pi as the tool result.

`edit.mode = "yolo"` tells Codex to use the native `apply_patch` tool directly without the Neovim PreToolUse review hook. Calls to `nvim.apply_patch` are rejected while the tool is not exposed. The legacy option `dynamic_tools.prefer_nvim_apply_patch = false` still selects yolo mode unless `edit.mode` is set explicitly.

For the legacy/internal `nvim.apply_patch` buffer review:

- `.`: accept current changed block
- `,`: reject current changed block and prompt for a reason
- `ga`: accept all remaining changed blocks
- `gr`: reject all remaining changed blocks and prompt for a reason
- `gA`: use Neovim auto-apply for the session
- `q`: cancel the review
- `n` / `p`: jump between pending changed blocks
- `?`: show review keys

Rejected changed-block reasons, partial-apply status, final file state, a final diff, and the target buffer's `nvim.diagnostics` output are returned to Codex as the dynamic tool result so the agent can continue from the user's feedback when that legacy tool is explicitly enabled.

## Events

`codex.nvim` emits `User` autocmds for editor integrations:

- `CodexBufferAttached`: after the buffer attach hook point runs for a thread buffer. `event.data` includes `bufnr`, `thread_id`, and `thread`.
- `CodexBufferOpened`: after a thread buffer is opened in a window. `event.data` includes `bufnr`, `winid`, `thread_id`, and `thread`.
- `CodexThreadOpened`: when app-server reports a thread start.
- `CodexGenerationCompleted`: when app-server reports a completed generation.

## Architecture

The plugin follows the same shape as a native Neovim chat client:

- `lua/codex/rpc.lua`: provider-driven stdio JSONL client.
- `lua/codex/providers/`: provider adapters for Codex app-server and Pi RPC.
- `lua/codex/state.lua`: thread, turn, item, pending-request, render-index, expansion, view, timeline/raw, and cache state.
- `lua/codex/core.lua`: provider notification and server-request reducer; maps normalized lifecycle events to UI generation states and timeline/raw blocks.
- `lua/codex/context.lua`: source-buffer tracking for prompt context and Neovim dynamic tools.
- `lua/codex/events.lua`: normalized provider item to modern Neovim TUI block conversion.
- `lua/codex/buffers.lua`: `codex://thread/<id>` `codex-history` transcript buffers, unnamed `codex-input` composer buffers, window option management, prompt collection, and block keymaps.
- `lua/codex/ui/render.lua`: extmark TUI renderer for headers, placeholders, virtual lines, spinner, stream gutters, composer tokens, view follow, and foldexpr ranges.
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

The smoke test loads the plugin, exercises health and status helpers, provider selection and Pi event normalization, parser/completion behavior, verifies source-buffer context tracking, checks `@file:` picker hooks and direct `@path` syntax, verifies patch-review hunk indexing, verifies Neovim-owned patch application and in-buffer changed-block rejection feedback, verifies provider initialization and empty thread creation, and asserts that the TUI renderer creates extmarks, placeholders, fold levels, detail output, view-follow state, timeline/raw event blocks, process output blocks, and a busy spinner.

## License

MIT. See [LICENSE](LICENSE).
