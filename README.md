# codex.nvim

`codex.nvim` is a Neovim client for Codex app-server. It keeps the Codex chat surface inside Neovim: each Codex thread has a buffer, thread navigation can use a picker, prompt tokens complete through `blink.cmp`, and file edits are reviewed as patch proposals in an editor-native approval window.

The plugin talks to Codex through:

```sh
codex app-server --listen stdio://
```

Codex app-server is experimental upstream, so this plugin keeps the transport layer small and explicit.

## Features

- Buffer-per-thread chat UI at `codex://thread/<id>`.
- `:Codex new`, `:Codex pick`, `:Codex resume`, `:Codex submit`, and `:Codex stop`.
- Alma-style TUI render: Codex items are normalized into blocks, then drawn with extmark headers, placeholders, virtual lines, stream gutters, composer token highlights, and a busy spinner.
- Streaming render for agent messages, reasoning, plans, command output, MCP calls, dynamic tool calls, collab-agent calls, web search, image events, and file changes.
- Expandable reasoning/tool/agent/patch placeholders with `za`; detail scratch views with `K` or `:Codex detail`.
- Patch review window for `item/fileChange/requestApproval` and legacy `applyPatchApproval`.
- Basic command and permission approval prompts.
- Optional dynamic tools exposed to Codex under the `nvim` namespace:
  - `nvim.current_buffer`
  - `nvim.diagnostics`
  - `nvim.quickfix`
- `blink.cmp` source for `/`, `$`, `@`, and `>` prompt tokens.
- Thread picker via `snacks.picker` when available, with `vim.ui.select` fallback.

## Requirements

- Neovim 0.10 or newer.
- A working `codex` executable with `app-server` support.
- Optional: `snacks.nvim` for thread picking.
- Optional: `blink.cmp` for prompt completions.

## Installation

Use your plugin manager of choice. With `lazy.nvim`:

```lua
{
  "path/to/codex.nvim",
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
  },
})
```

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
:Codex restart
```

Inside a Codex thread buffer, write below `## Prompt` and press `<C-s>` to submit. Use `za` on a placeholder block to expand or collapse reasoning/tool/agent details. Use `K` to open the full block detail buffer.

## Prompt Tokens

`codex.nvim` treats the chat buffer as the main UI surface. Prompt token completions are available through the `blink.cmp` source:

- `/new`, `/pick`, `/resume`, `/stop`, `/submit`
- `$model:<id>`, `$skill:<name>`, `$reasoning:high`
- `@file:`, `@buffer`, `@diagnostics`
- `>buffer`, `>selection`, `>diagnostics`, `>quickfix`

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

`>buffer`, `>diagnostics`, and `>quickfix` are expanded into extra Codex text inputs. `$skill:<name>` is converted to a Codex skill input when the skill has been loaded into the local catalog.

## Patch Review

Codex app-server sends file edits as file-change approval requests. `codex.nvim` normalizes these into a single patch proposal model and opens a review window.

Review keys:

- `a`: accept
- `A`: accept for session
- `d`: decline
- `c`: cancel
- `q`: close the review window without answering

For modern app-server file changes, Codex still owns the final patch application after approval. For future custom editor tools, the same patch review UI can be reused with Neovim owning the final apply step.

## Architecture

The plugin follows the same shape as a native Neovim chat client:

- `lua/codex/rpc.lua`: stdio JSONL app-server client.
- `lua/codex/state.lua`: thread, turn, item, pending-request, render-index, expansion, and cache state.
- `lua/codex/core.lua`: app-server notification and server-request reducer; maps Codex lifecycle events to UI generation states.
- `lua/codex/events.lua`: Codex `ThreadItem` to Alma-style block normalization.
- `lua/codex/buffers.lua`: `codex://thread/<id>` buffers, window option management, prompt collection, and block keymaps.
- `lua/codex/ui/render.lua`: extmark TUI renderer for headers, placeholders, virtual lines, spinner, stream gutters, and composer tokens.
- `lua/codex/ui/tool_renderers.lua`: smart renderers for command, patch, and generic tool output.
- `lua/codex/ui/detail.lua`: scratch detail buffers for the block under cursor.
- `lua/codex/patch_review.lua`: patch proposal review UI.
- `lua/codex/completion/blink.lua`: `blink.cmp` source.
- `lua/codex/dynamic_tools.lua`: Neovim-backed dynamic tools.

## Verification

Run the smoke test:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

The smoke test loads the plugin, exercises parser/completion behavior, verifies app-server initialization and empty thread creation, and asserts that the TUI renderer creates extmarks, placeholders, detail output, and a busy spinner.
