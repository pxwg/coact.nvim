-- Coact mode options. Every field is optional; see :help coact-mode-config.
local M = {}

--- What the model is told about Coact mode, in its system prompt. The card
--- tools describe themselves.
M.default_prompt = table.concat({
  "This conversation lives in Org cards that the user reads and edits in Neovim.",
  "The messages you receive are rendered from the current cards before each request, so they reflect the user's latest edits, not your earlier output.",
  "Your final reply becomes the body of a new assistant card.",
  "The card and thread tools let you inspect the cards and change them; the user reviews every change to an existing card.",
}, " ")

local defaults = {
  -- The system prompt section: nil for the default, a string to replace it,
  -- function(default) returning the text, or false for none.
  prompt = nil,
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
  -- Semantic titles: after a turn, a background call names its cards by
  -- what they discuss. Titles set by hand are never replaced.
  titles = {
    enabled = true,
    -- "provider/id" of the naming model; nil uses the thread's model.
    model = nil,
  },
  -- Layout of generated cards: a blank line before each card's heading,
  -- and between its property drawer and its body.
  layout = {
    blank_before_heading = true,
    blank_after_drawer = true,
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
    -- After an asked thread's first answer, link a phrase of the passage to
    -- it; the words of the passage stay as they were.
    link = true,
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

--- Card titles and layout, as the server takes them.
function M.labels()
  return vim.tbl_extend("force", options.labels, { layout = options.layout })
end

--- The prompt section to send, or "" for none.
function M.prompt()
  local prompt = options.prompt
  if prompt == false then
    return ""
  elseif type(prompt) == "function" then
    return tostring(prompt(M.default_prompt) or "")
  elseif type(prompt) == "string" then
    return prompt
  end
  return M.default_prompt
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
