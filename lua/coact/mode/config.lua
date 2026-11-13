-- Coact mode options. Every field is optional; see :help coact-mode-config.
local M = {}

local defaults = {
  -- Parent directory of chat workspaces created by :CoactMode init.
  workspace_root = vim.fs.joinpath(vim.fn.stdpath("data"), "coact-mode"),
  lsp = {
    -- Server command. Default: the server built in this plugin's ocaml/
    -- directory, else coact-zk-lsp on $PATH.
    cmd = nil,
  },
  pi = {
    command = { "pi", "--mode", "rpc" },
    -- Model pattern passed as --model, e.g. "anthropic/claude-sonnet-4-5".
    model = nil,
    -- Extra arguments, e.g. { "--no-extensions" } to keep user extensions
    -- from also rewriting the context.
    args = {},
    env = {},
  },
  -- Titles and labels written into new cards.
  labels = {
    question = "Question",
    answer = "Answer",
    summary = "Summary",
    trace = "Trace",
    trace_source = "Trace record",
    sources = "Sources",
    from = "From",
    card = "New card",
  },
  icons = {
    user = "󰀄",
    assistant = "󰚩",
    synthesis = "󰛨",
    trace = "󰙨",
    note = "󰎚",
    pin = "󰐃",
    revised = "󰏫",
    busy = "󰔟",
  },
  -- Buffer-local mappings in workspace Org buffers; false disables one, or
  -- set keymaps = false to disable all. <Plug>(CoactMode…) targets exist too.
  keymaps = {
    submit = "<localleader>cs",
    stop = "<localleader>cx",
    pin = "<localleader>cp",
    unpin = "<localleader>cu",
    new = "<localleader>cn",
    ask = "<localleader>ca",
    compact = "<localleader>cc",
    trace = "<localleader>ct",
  },
  ask = {
    -- How :CoactMode ask opens the new card's file: an Ex command taking the
    -- path ("vsplit", "split", "tabedit", "edit") or a function(path).
    open = "vsplit",
  },
  compact = {
    -- Recent context kept verbatim when compacting (Pi's keepRecentTokens);
    -- nil uses Pi's default.
    keep_recent_tokens = nil,
  },
  stream = {
    -- Streaming answer lines shown under the answer heading.
    max_lines = 12,
  },
}

local options = vim.deepcopy(defaults)

function M.setup(user)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user or {})
  if user and user.keymaps == false then
    options.keymaps = false
  end
  if user and user.pi and user.pi.command then
    options.pi.command = vim.deepcopy(user.pi.command)
  end
end

function M.get()
  return options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
