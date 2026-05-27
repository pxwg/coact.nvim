local config = require("codex.config")
local render = require("codex.ui.render")
local state = require("codex.state")
local window = require("codex.ui.window")

local M = {}

local group = vim.api.nvim_create_augroup("codex.nvim.buffers", { clear = true })
local window_snapshots = {}

local restorable_window_options = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "wrap",
  "linebreak",
  "foldmethod",
  "foldexpr",
  "foldlevel",
  "conceallevel",
}

local codex_window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = true,
  linebreak = true,
  foldmethod = "expr",
  foldexpr = "v:lua.CodexFoldExpr(v:lnum)",
  foldlevel = 0,
}

local function configure_buffer(bufnr, thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = "codex"
  vim.b[bufnr].codex_thread_id = thread_id
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    require("codex").submit()
  end, { buffer = bufnr, desc = "Submit Codex prompt" })
  vim.keymap.set("n", "q", function()
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(winid, true)
  end, { buffer = bufnr, desc = "Close Codex window" })
  vim.keymap.set("n", "za", function()
    require("codex.ui.render").toggle_under_cursor()
  end, { buffer = bufnr, silent = true, desc = "Toggle Codex block" })
end

local function prompt_start(bufnr)
  local thread = state.thread_for_buf(bufnr)
  if thread and thread.prompt_start then
    return thread.prompt_start
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local marker = config.get().render.prompt_marker
  for index, line in ipairs(lines) do
    if line == marker then
      return index + 1
    end
  end
  return #lines + 1
end

function M.apply_window_options(win, bufnr)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  bufnr = bufnr or vim.api.nvim_win_get_buf(win)
  if not bufnr or not state.thread_for_buf(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  if not window_snapshots[win] then
    local snapshot = {}
    for _, option in ipairs(restorable_window_options) do
      snapshot[option] = vim.wo[win][option]
    end
    window_snapshots[win] = snapshot
  end
  for option, value in pairs(codex_window_options) do
    vim.wo[win][option] = value
  end
  vim.wo[win].conceallevel = math.max(vim.wo[win].conceallevel, 1)
end

function M.restore_window_options(win)
  win = win or vim.api.nvim_get_current_win()
  local snapshot = win and window_snapshots[win]
  if not snapshot then
    return
  end
  if vim.api.nvim_win_is_valid(win) then
    for _, option in ipairs(restorable_window_options) do
      pcall(function()
        vim.wo[win][option] = snapshot[option]
      end)
    end
  end
  window_snapshots[win] = nil
end

local function setup_buffer_autocmds(bufnr)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.apply_window_options(vim.api.nvim_get_current_win(), bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.restore_window_options(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      local thread = state.thread_for_buf(bufnr)
      if thread then
        thread.bufnr = nil
      end
    end,
  })
end

function M.collect_prompt(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local start = prompt_start(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start, -1, false)
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  return table.concat(lines, "\n")
end

function M.clear_prompt(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local start = prompt_start(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, start, -1, false, {})
end

function M.get_thread_id(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].codex_thread_id
end

function M.ensure(thread_id)
  local thread = state.ensure_thread(thread_id)
  if thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr) then
    return thread.bufnr
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "codex://thread/" .. thread_id)
  configure_buffer(bufnr, thread_id)
  state.bind_buffer(thread, bufnr)
  if pcall(vim.treesitter.start, bufnr, "markdown") then
    vim.bo[bufnr].syntax = ""
    vim.b[bufnr].current_syntax = nil
  else
    vim.bo[bufnr].syntax = "markdown"
  end
  setup_buffer_autocmds(bufnr)
  M.render(thread_id, {})
  return bufnr
end

function M.open(thread_id)
  local bufnr = M.ensure(thread_id)
  local winid = window.open(bufnr)
  state.set_buffer(thread_id, bufnr, winid)
  M.apply_window_options(winid, bufnr)
  local start = prompt_start(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.min(math.max(1, start + 1), line_count), 0 })
  return bufnr, winid
end

function M.render(thread_id, prompt_lines)
  local thread = state.get_thread(thread_id)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end
  if prompt_lines == nil then
    local prompt = M.collect_prompt(thread.bufnr)
    prompt_lines = prompt ~= "" and vim.split(prompt, "\n", { plain = true }) or {}
  end
  thread.prompt_lines = prompt_lines
  render.render(thread)
end

function M.schedule_render(thread_id)
  local thread = state.get_thread(thread_id)
  render.schedule(thread, config.get().ui.render_delay_ms)
end

return M
