local M = {}

local function normalize_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

function M.is_codex_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return vim.b[bufnr].codex_thread_id ~= nil or vim.bo[bufnr].filetype == "codex" or name:match("^codex://") ~= nil
end

function M.is_context_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and not M.is_codex_buffer(bufnr)
end

function M.capture_thread_buffer(thread, bufnr, winid)
  if not thread then
    return
  end
  bufnr = normalize_bufnr(bufnr)
  if not M.is_context_buffer(bufnr) then
    return
  end
  thread.context_bufnr = bufnr
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    thread.context_winid = winid
  else
    local current_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
      thread.context_winid = current_win
    end
  end
end

local function active_thread()
  local state = require("codex.state")
  return state.thread_for_buf(0) or state.get_thread(state.active_thread_id)
end

function M.target_buffer(thread)
  thread = thread or active_thread()
  if thread and thread.context_bufnr and M.is_context_buffer(thread.context_bufnr) then
    return thread.context_bufnr
  end

  local current = vim.api.nvim_get_current_buf()
  if M.is_context_buffer(current) then
    return current
  end

  return current
end

function M.window_for_buffer(bufnr, thread)
  bufnr = normalize_bufnr(bufnr)
  if thread and thread.context_winid and vim.api.nvim_win_is_valid(thread.context_winid) then
    if vim.api.nvim_win_get_buf(thread.context_winid) == bufnr then
      return thread.context_winid
    end
  end

  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
    return current_win
  end

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

function M.cursor_for_buffer(bufnr, thread)
  bufnr = normalize_bufnr(bufnr)
  local winid = M.window_for_buffer(bufnr, thread)
  if winid then
    return vim.api.nvim_win_get_cursor(winid)
  end
  return { 1, 0 }
end

function M.buffer_label(bufnr)
  bufnr = normalize_bufnr(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and name or "[No Name]"
end

return M
