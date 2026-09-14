# coact.nvim

`coact.nvim` is a Neovim workspace for human-agent pair writing. It keeps the conversation, context, patch review, and branch navigation inside the editor, so coding agents become collaborators that propose, revise, and negotiate changes instead of unattended code generators.

Provider threads are rendered as Neovim buffers, prompt tokens complete through `blink.cmp` with file-picking delegated to Neovim pickers, provider file changes become reviewable patch proposals, and pair-mode native `apply_patch` calls are reviewed and applied through Neovim before they touch the workspace.

Built-in provider adapters currently include Codex app-server:

```sh
codex app-server --listen stdio://
```

and Pi RPC:

```sh
pi --mode rpc
```

The provider layer keeps each backend protocol small and explicit while normalizing sessions, turns, messages, tool calls, and settings into the same Neovim UI model.

## Features

- Buffer-per-thread chat UI at `coact://thread/<id>`.
- `:Coact new`, `:Coact pick`, `:Coact resume`, `:Coact submit`, and `:Coact stop`.
- `:Coact status` and `require("coact").status()` for lightweight runtime state.
- Modern Neovim TUI render: provider items are normalized into blocks, then drawn with extmark headers, placeholders, virtual lines, stream gutters, composer token highlights, and a busy spinner.
- Streaming render for agent messages, reasoning, plans, command output, MCP calls, dynamic tool calls, collab-agent calls, web search, image events, and file changes.
- Expandable reasoning/tool/agent/patch placeholders with `za`; detail scratch views with `K` or `:Coact detail`.
- Extmark-anchored render atoms that coalesce updates across multiple transcript positions without moving the separate composer; streaming preserves each transcript window's cursor and view by default, with per-window auto-follow available as an opt-in.
- App-server lifecycle notifications are preserved as timeline blocks; unknown notifications are retained as raw blocks and can be shown for debugging.
- Patch review window for `item/fileChange/requestApproval` and legacy `applyPatchApproval`.
- Pair-mode file-change review through provider-specific bridges, using the same file-buffer changed-block UI as the internal Neovim patch tool.
- Basic command and permission approval prompts.
- Optional dynamic tools exposed to supported providers under the `nvim` namespace:
  - `nvim.current_buffer`
  - `nvim.diagnostics`
  - `nvim.quickfix`
- Source-buffer tracking so prompt context and Neovim tools target the buffer that opened the thread.
- `blink.cmp` source where `$` comes from provider skills, `/` opens CLI-style slash commands, and `@` expands Neovim context; `@file:`/`@image:` path selection opens picker integrations instead of blink path candidates.
- Thread picker via `snacks.picker` when available, with `vim.ui.select` fallback.

## Requirements

- Neovim 0.10 or newer.
- A working provider executable:
  - `codex` with `app-server` support for the default Codex provider.
  - Optional: `pi` with `--mode rpc`, `--session-id`, and RPC `get_entries` support for the Pi provider.
- `git` on `$PATH` is optional for legacy unified-diff compatibility in the internal `nvim.apply_patch` implementation.
- Optional: `snacks.nvim` for thread picking.
- Optional: `blink.cmp` for prompt completions.

## Installation

Use your plugin manager of choice. With `lazy.nvim`:

```lua
{
  "pxwg/coact.nvim",
  config = function()
    require("coact").setup()
  end,
}
```

## Setup

Default configuration:

```lua
require("coact").setup({
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
      picker_prewarm = true,
      prewarm_delay_ms = 50,
      prewarm_idle_timeout_ms = 60000,
      edit_bridge = {
        enabled = true,
        timeout_sec = 600,
        direct_write = true,
      },
      nvim_tools = {
        enabled = true,
        max_code_bytes = 64 * 1024,
        max_result_bytes = 50 * 1024,
        max_result_lines = 2000,
      },
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
    auto_scroll = false,
    composer = {
      min_height = 2,
      max_height = 0.33,
      statusline = {
        enabled = true,
        default_visible = true,
        widgets = true,
        max_width = 160,
      },
    },
  },
  render = {
    prompt_marker = "## Prompt",
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

To use Pi as the active provider:

```lua
require("coact").setup({
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
        direct_write = true,
      },
      nvim_tools = {
        enabled = true,
      },
    },
  },
})
```

The Pi provider adapts Pi RPC sessions into coact.nvim threads, maps prompts to Pi `prompt` commands, maps `/model` and reasoning changes to Pi model/thinking commands, and normalizes Pi streaming, thinking, and tool events into the same renderer blocks used by the rest of coact.nvim. Every active Pi thread owns an independent `pi --mode rpc` process, request table, event stream, turn/queue/tool runtime, settings, statistics, and extension UI state. The thread id is bound to that execution unit after Pi reports its session id; UI focus never selects the transport destination. Different Pi sessions can therefore generate concurrently and accept interleaved submissions without switching, aborting, or relabeling another session. Closing a thread window only hides its view, while `:Coact restart` or Neovim shutdown stops the execution units. Concurrent workspace edits remain governed by the existing edit/review behavior.

Pi chat displays the **selected branch's history**, not the model's compacted context. Native `get_entries` plus `leafId` selects the root-to-leaf path: history stays intact, compaction stays where it happened, and sibling branches are excluded. The renderer hides the prefix before the latest compact without deleting it from state or the session. After a reply finishes, adjacent completed thinking/tool blocks collapse into a `Thinking finished` cluster in place; text, user messages and summaries remain hard boundaries. Results update the original call in place. Settled runs, resume and tree navigation reconcile against persisted entry IDs. Reads racing active streaming cannot overwrite live blocks. See [Pi transcript design and verification](doc/pi-transcript.md).

The thread picker reads Pi's `parentSession` metadata, groups forked session files beneath their parent with tree connectors, and keeps every fork independently selectable. Local JSONL metadata is cached by file size and modification time, so opening the picker does not require starting Pi and unchanged sessions are not reparsed. After the picker becomes visible, `picker_prewarm` opportunistically starts one unbound Pi RPC client after `prewarm_delay_ms`; a selected session claims that same client even when it is still starting, and an unclaimed client stops after `prewarm_idle_timeout_ms`. `/reasoning` queries Pi for the current model's available thinking levels when the picker opens, so model-declared holes and extended levels such as `max` are honored. Submitting another prompt while one Pi thread is generating queues it as a Pi `followUp` for that same thread; submitting in another Pi thread starts or queues work only in that thread. Queued prompts remain visible once under a distinct `Queued request` header with queue state and FIFO position until Pi delivers each user message, at which point the normal user message replaces the pending block without duplication. Pi queue updates stay internal rather than creating transcript blocks, and Pi's settled event clears the busy indicator. Choosing a summary during Pi tree navigation keeps the transcript observable with a `Coact summarizing...` spinner until Pi finishes the branch summary and navigation. The completed Pi `branchSummary` then remains as a collapsed `Branch summary` block at its active-branch position: after a selected non-user entry, after the parent of a selected user prompt restored to the composer, or at the transcript root when revisiting the first prompt. Pi compaction entries render as `Context compacted` sections and prune only the rendered prefix before the latest compact; the selected-branch history remains intact. Compaction and branch summaries contain their full text as real buffer lines inside native Neovim folds: `za` expands directly selectable/copyable text, while `K` still opens detail. Branch summaries never prune earlier content. Pi extension UI status requests (`ctx.ui.setStatus`, `setWidget`, and `setTitle`) are mirrored into window status chrome so Pi-side status customizations remain visible in Neovim without overloading the split separator or input box.

When `nvim_tools.enabled` is true, coact.nvim injects a process-local Pi extension that registers `nvim_exec_lua`. The tool executes Lua with the thread's remembered source window or buffer temporarily current. Its chunk can begin with `local ctx, args = ...`, use `vim.cmd`, `vim.api`, `vim.fn`, or plugin Lua APIs, and return one JSON-serializable value. Calls are serialized, and results larger than `max_result_bytes` or `max_result_lines` are written as JSON to a temporary file. If `providers.pi.tools` is an explicit allowlist, include `nvim_exec_lua` to activate it.

`nvim_exec_lua` is a full-trust escape hatch into the live editor: it can read unsaved buffers, mutate editor state, write files, run shell-capable Ex commands, or close Neovim. Routine workspace file changes should continue to use the reviewed `edit` and `write` tools. Set `nvim_tools.enabled = false` when that live-editor capability should not be exposed.

In pair edit mode, `edit_bridge.enabled` dynamically injects a separate temporary Pi extension into only the Pi process started by coact.nvim. That extension overrides Pi's built-in `edit` and `write` tools, turns them into Neovim-reviewed file-change proposals, and then lets the existing in-buffer patch review write accepted hunks. Neither injected extension installs or modifies user Pi extensions or settings.

`edit_bridge.direct_write = true` builds a directory allowlist once during setup from the current operating system's temporary directories. Canonical targets beneath those directories skip the interactive window and use the same Neovim patch-session write path as a full approval with no comment. The allowlist and bypass decision are not added to Pi's prompt, tool schemas/descriptions, environment, or tool result; Pi receives the ordinary fully accepted review summary.

Set `direct_write = false` to disable all default temporary-directory bypasses. To extend or replace the defaults, use a setup-time function. It runs after the defaults and receives the same allowlist abstraction used by the built-in OS initializer:

```lua
edit_bridge = {
  direct_write = function(allowlist, context)
    allowlist:add("/absolute/path/to/another/scratch-directory")
    allowlist:remove(context.os_tmpdir)

    -- To replace every default instead:
    -- allowlist:clear()
    -- allowlist:add("/absolute/path/to/the/only/scratch-directory")
  end,
}
```

The callback also receives `context.cwd`, `context.sysname`, `context.uname`, `context.os_tmpdir`, `context.nvim_tmpdir`, and the relevant temporary-directory environment values in `context.env`. `allowlist:add()` and `allowlist:remove()` accept a path or list of paths; `allowlist:paths()` returns the current snapshot and `allowlist:contains()` tests a path. Relative configured paths resolve from the setup workspace. Matching is directory-component aware and resolves existing symlinks, so prefix siblings and symlink escapes are not bypassed.

## Commands

```vim
:Coact new [initial prompt]
:Coact open [thread-id]
:Coact resume <thread-id>
:Coact pick
:Coact list
:Coact submit
:Coact stop
:Coact detail
:Coact health
:Coact status
:Coact statusline [toggle|show|hide]
:Coact restart
:Coact attach [all]
:Coact add-buffer
:Coact add-selection
```

Opening a provider thread starts in preview state with a read-only `coact-history` transcript buffer using the full UI height. Pi opens that buffer immediately from local session metadata and shows a transient in-buffer session loading spinner while its independent execution unit starts, restores the session, and hydrates conversation history; loading state is renderer chrome rather than transcript content, and failures remain visible in the opened buffer. New Pi sessions receive their final session id before launch so the loading buffer already belongs to the eventual execution unit. Press an insert-intent key such as `i`, `a`, `I`, `A`, `o`, `O`, `gi`, `c`, `cc`, or `S` to open the unnamed `coact-input` composer below it. Type in the composer and press `<C-s>` or normal-mode `<CR>` to submit; normal-mode `q` closes the composer and returns to preview without discarding the draft. Press normal-mode `K` over an `@...` context token in the composer to open the same LSP-style hover float used by completion documentation. With the Pi provider, submitting while a turn is still generating queues the text as a follow-up. The composer grows with wrapped input up to `ui.composer.max_height`, then scrolls internally. The composer buffer is left unnamed rather than using a `coact://` URI so path-oriented completion sources keep a normal editing context. In history, use `za` on a placeholder block to expand or collapse reasoning/tool/agent details, `K` to open the full block detail buffer, `g?` for history key help, `gs` to toggle the status detail page, `gS` to show/hide the status chrome, `gt` for the Pi tree, `gT` to open the Pi tree preselected at the user/assistant message under cursor, normal-mode `<Esc><Esc>` to open the Pi tree preselected at the current message when available (or as a normal tree from the composer), `r` inside the Pi tree to reveal a selected entry in the current Neovim transcript when it is already on the rendered branch, `gc` for runtime status, `gy` to copy the latest output, `gd` for workspace diff, `gr` to refresh rendering, and `g]` / `g[` to jump to the next/previous message block. During streaming, transcript windows preserve their cursor and view by default. Set `ui.auto_scroll = true` to make windows near the bottom follow the conversation; cursor movement or scrolling away then suspends follow for that window.

One user run keeps a single Coact response frame even when a provider splits it across internal turn ids. For Codex, activity before each visible assistant output compacts into a collapsed `Thinking finished` row. Activity emitted after partial output stays as live reasoning/tool placeholders until the next output boundary, preserving folded activity → output → folded activity → output chronology.

`:Coact status` reports whether the current thread's provider execution unit is running, the total provider client count, current and active thread ids, pending request counts, and the current thread generation/status. The same data is available programmatically through `require("coact").status()` for statuslines or custom integrations.

`:Coact statusline [toggle|show|hide]` controls the window status chrome. It is enabled by default via `ui.composer.statusline` and mirrors provider/model/context/token state plus Pi RPC extension status when the Pi provider is active. Float layouts render a one-line summary in the history/composer window footer; sidebar layouts render the summary in local winbars. The transcript buffer remains plain chat markdown, and `gs` opens the structured status detail page for full Pi widgets and provider UI details. Status fields wrap using the target window width and expose `CoactStatusLine*` highlight groups for colorscheme/user overrides.

`:Coact attach` reruns the configured buffer attach hook for the current thread buffer. `:Coact attach all` reruns it for every loaded transcript or composer buffer. Use `buffer.on_attach = function(bufnr, payload) ... end` or `require("coact").on("buffer_attached", cb)` to attach editor-local helpers such as input-method LSP clients, formula concealers, or buffer-local keymaps after coact.nvim creates a chat buffer.

`:Coact add-buffer` appends the current source buffer path to the active chat prompt using compact direct `@path` mention syntax. `:Coact add-selection` appends `@selection` when the source buffer has a remembered Visual selection.

Command-line completion covers subcommands, `attach all`, loaded chat buffer numbers, and loaded thread ids for `open`/`resume`.

## Health

Run `:checkhealth coact` to verify the Neovim version, active provider executable and protocol support, the Codex apply_patch runtime when the Codex provider is active in pair mode, optional picker/completion integrations, and dynamic tool registration. `:Coact health` still performs runtime provider initialization.

## Prompt Tokens

Prompt token completions are available in the `coact-input` composer through the `blink.cmp` source:

- `$skill:<name>` from the active provider's skill catalog where supported
- `/model`, `/status`, and other active-provider slash commands handled by coact.nvim
- `@buffer`, `@selection`, `@cursor`, `@diagnostics`, `@quickfix`, `@buffers`, `@cwd`, `@behavior`, `@file:`, `@image:`, and compact direct `@path/to/file` file mentions

Configure `blink.cmp` with:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "coact" },
    providers = {
      coact = {
        name = "Coact",
        module = "coact.completion.blink",
      },
    },
  },
})
```

Most `@...` context tokens are expanded by Neovim into extra provider inputs. Argument providers use `@provider:input`; paths with spaces can wrap the path in backticks. Direct `@path/to/file` mentions stay as compact prompt text so they do not eagerly paste file contents into the model context:

```text
@file:`path with spaces.lua`
@image:`assets/screenshot.png`
@lua/coact/init.lua
```

The blink source intentionally does not complete filesystem paths after `@file:` or `@image:`. Instead, pressing `<Tab>` after those provider tokens opens the picker adapter (`snacks.picker.files` when available, with `vim.ui.select` as a fallback). The selected file is inserted with a workspace-relative path: `@relative/path/to/file` as a compact file mention, and `@image:relative/path/to/image.png` for image inputs. Use explicit `@file:relative/path` when you want Neovim to eagerly inject full file contents. Completion and hover documentation still use context-specific compact previews when available, including explicit file context, image attachment metadata, selections, diagnostics, and behavior diffs without necessarily showing the full submitted reference prompt. Custom hooks can be registered with `require("coact.context").register_hook(name, callback)`.

When a thread is opened from another window, `coact.nvim` remembers that source buffer as the thread target, so `@buffer`, `@selection`, `@cursor`, `@diagnostics`, and Neovim dynamic tools do not accidentally read a Coact UI buffer itself. `@selection` remembers the last non-Coact Visual selection per source buffer, captures precise characterwise, linewise, or blockwise text from Neovim's visual marks and mode, and includes file/range metadata plus diagnostics in the selected range. Selection context is attached only when the prompt explicitly contains `@selection` or you run `:Coact add-selection`, keeping context injection fully controlled by the prompt. Expanded text contexts are sent before the user request and are labeled as reference context, not instructions; the user request remains the final text input for semantic priority. `@buffer` includes buffer id, path, filetype, cursor, modified state, line count, and buffer text. `$skill:<name>` is converted to the provider's skill invocation format when the provider exposes skills. Slash commands are handled locally before `turn/start`, so `/...` entries are not sent as model-visible tool calls; accepting a slash completion removes the typed prefix and opens that command's page or picker instead of inserting text. Slash completions and `/help` are filtered by the active provider, so Codex app-server-only pages such as `/permissions`, `/sandbox`, `/goal`, or `/experimental` do not appear when the Pi provider is active. Each slash command declares a return form (`page`, `select`, `notify`, `insert`, or `action`) and uses one presenter for Neovim rendering. Settings commands such as `/model`, `/fast`, `/permissions`, `/sandbox`, `/reasoning`, `/personality`, and `/experimental` open Neovim pickers backed by provider catalog responses where available and update the active thread where the provider supports it. `/model` also offers the selected model's advertised thinking-effort choices when the provider returns them. With Pi, `/reasoning` loads the current model's supported levels from `get_available_thinking_levels` at picker time. Legacy `>buffer`, `>diagnostics`, and `>quickfix` still parse as Neovim context aliases, but new completions use `@`.

## Patch Review

Provider file edits are normalized into a single patch proposal model and opened in a review window. Codex app-server file-change approvals and Pi `edit`/`write` bridge proposals use the same review path.

Review keys:

- `a`: accept
- `A`: accept for session
- `d`: decline
- `c`: cancel
- `[c` / `]c`: jump between indexed file changes or diff hunks
- `<CR>` / `o`: open the related file at the hunk location when available
- `q`: close the review window without answering

The review buffer indexes file changes and unified-diff hunk headers with extmarks, so large patches can be inspected without manually scanning the whole markdown document. Outside pair mode, the active provider still owns the final file-change application after approval.

`edit.mode = "pair"` is the default. With the Codex provider, coact.nvim tells the app-server to use the native `apply_patch` tool and injects a stable `PreToolUse` hook into the process it starts. The plugin registers trust for that exact hook hash through Codex config, while per-session Neovim RPC details are passed through environment variables, so pair mode does not need `--dangerously-bypass-hook-trust`. That hook previews the patch in the affected Neovim file buffers before the native tool completes. Approving the review writes approved changed blocks through the same path as `nvim.apply_patch`, then returns `permissionDecision: "allow"` with a no-op `updatedInput.command` so Codex native `apply_patch` can complete without repeating the real edit; rejecting returns `permissionDecision: "deny"` with the user's reason. Follow-up app-server apply_patch permission and file-change approvals are automatically accepted only when their item id was already reviewed by the Neovim hook, so pair mode does not require `--dangerously-bypass-approvals-and-sandbox`.

The pair-mode native review uses file-buffer changed-block controls with visible in-buffer hints: `.` approves the current changed block and prompts for an approval comment, `,` rejects it with a reason, `n` / `p` jumps between pending changed blocks, `ga` approves the rest with one approval-comment prompt, `gr` rejects the rest with a reason, `q` cancels, and `?` opens the key help. The review display wraps long before-lines into readable virtual lines and highlights changed characters inside the current replacement block when it fits the `edit.review.char_diff_*` budget. You can edit the previewed file buffer before approving; coact.nvim writes the final approved buffer state and returns the review summary to the provider as hook context, including approval comments, rejection reasons, and any diff between the provider proposal and the final Neovim-reviewed state. The previous `nvim.apply_patch` dynamic tool implementation remains in the codebase for compatibility and internal tests, but it is no longer exposed by default in pair mode.

For the Pi provider, pair mode uses a process-local extension override instead of Pi's global extension configuration. coact.nvim appends `--extension <tempfile>` while starting Pi RPC and passes the Neovim RPC socket, nonce, and timeout through environment variables. The override computes the proposed `edit`/`write` file content, opens the same in-buffer `patch_session` review used by `nvim.apply_patch`, and reports the accepted or rejected result back to Pi as the tool result. Targets accepted by `providers.pi.edit_bridge.direct_write` run that patch session non-interactively and return the same full-approval result without disclosing the configured directories to Pi.

`edit.mode = "yolo"` tells the active provider to use its native file-edit path directly without the Neovim review bridge. Calls to `nvim.apply_patch` are rejected while the tool is not exposed. The legacy option `dynamic_tools.prefer_nvim_apply_patch = false` still selects yolo mode unless `edit.mode` is set explicitly.

For the legacy/internal `nvim.apply_patch` buffer review:

- `.`: approve current changed block and prompt for a comment
- `,`: reject current changed block and prompt for a reason
- `ga`: approve all remaining changed blocks and prompt for one comment
- `gr`: reject all remaining changed blocks and prompt for a reason
- `gA`: use Neovim auto-apply for the session
- `q`: cancel the review
- `n` / `p`: jump between pending changed blocks
- `?`: show review keys

Approval comments, rejected changed-block reasons, partial-apply status, final file state, a final diff, and the target buffer's `nvim.diagnostics` output are returned to the provider as the dynamic tool result so the agent can continue from the user's feedback when that legacy tool is explicitly enabled.

## Events

`coact.nvim` emits `User` autocmds for editor integrations:

- `CoactBufferAttached`: after the buffer attach hook point runs for a thread buffer. `event.data` includes `bufnr`, `thread_id`, and `thread`.
- `CoactBufferOpened`: after a thread buffer is opened in a window. `event.data` includes `bufnr`, `winid`, `thread_id`, and `thread`.
- `CoactThreadOpened`: when app-server reports a thread start.
- `CoactGenerationCompleted`: when app-server reports a completed generation.

## Architecture

The plugin follows the same shape as a native Neovim chat client:

- `lua/coact/rpc.lua`: provider-driven stdio JSONL client.
- `lua/coact/providers/`: provider adapters for Codex app-server and Pi RPC, including process-local edit and `nvim_exec_lua` bridges.
- `lua/coact/providers/pi_rpc.lua`: thread-owned Pi process/client manager, immutable event routing, lazy session resume, and per-client request lifecycle.
- `lua/coact/state.lua`: thread, turn, item, pending-request, render-index, expansion, view, timeline/raw, and cache state.
- `lua/coact/core.lua`: provider notification and server-request reducer; maps normalized lifecycle events to UI generation states and timeline/raw blocks.
- `lua/coact/context.lua`: source-buffer tracking for prompt context and Neovim dynamic tools.
- `lua/coact/events.lua`: normalized provider item to modern Neovim TUI block conversion.
- `lua/coact/buffers.lua`: `coact://thread/<id>` `coact-history` transcript buffers, unnamed `coact-input` composer buffers, window option management, prompt collection, and block keymaps.
- `lua/coact/ui/render.lua`: extmark TUI renderer for headers, placeholders, virtual lines, spinner, stream gutters, composer tokens, view follow, and manual fold ranges.
- `lua/coact/ui/tool_renderers.lua`: smart renderers for command, patch, and generic tool output.
- `lua/coact/ui/detail.lua`: scratch detail buffers for the block under cursor.
- `lua/coact/patch_review.lua`: app-server patch proposal review UI.
- `lua/coact/patch_session.lua`: in-buffer hunk review for `nvim.apply_patch`.
- `lua/coact/slash.lua`: CLI-style slash command catalog, declared return forms, local dispatch, result presenter, and settings pickers.
- `lua/coact/completion/blink.lua`: `blink.cmp` source.
- `lua/coact/dynamic_tools.lua`: Neovim-backed dynamic tools.
- `lua/coact/health.lua`: `:checkhealth coact` provider.

## Verification

Run the smoke test:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

The smoke test loads the plugin, exercises health and status helpers, provider selection and Pi event normalization, verifies two independent Pi RPC processes can stream interleaved turns and retain per-session model settings, checks parser/completion and source-buffer targeting, verifies patch-review and Neovim-owned patch application behavior, and asserts that the TUI renderer creates extmarks, placeholders, fold levels, detail output, view-follow state, timeline/raw event blocks, process output blocks, and a busy spinner.

## License

MIT. See [LICENSE](LICENSE).
