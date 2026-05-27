local config = require("codex.config")
local render = require("codex.ui.render")
local state = require("codex.state")
local window = require("codex.ui.window")

local M = {}

local PROMPT_MARKER = "## Prompt"

local function configure_buffer(bufnr, thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codex"
  vim.b[bufnr].codex_thread_id = thread_id
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    require("codex").submit()
  end, { buffer = bufnr, desc = "Submit Codex prompt" })
  vim.keymap.set("n", "q", function()
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(winid, true)
  end, { buffer = bufnr, desc = "Close Codex window" })
end

local function prompt_start(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if line == PROMPT_MARKER then
      return index + 1
    end
  end
  return #lines + 1
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
  state.set_buffer(thread_id, bufnr, nil)
  M.render(thread_id, {})
  return bufnr
end

function M.open(thread_id)
  local bufnr = M.ensure(thread_id)
  local winid = window.open(bufnr)
  state.set_buffer(thread_id, bufnr, winid)
  local start = prompt_start(bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.max(1, start + 1), 0 })
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
  local lines = render.thread(thread, prompt_lines)
  local was_modifiable = vim.bo[thread.bufnr].modifiable
  vim.bo[thread.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(thread.bufnr, 0, -1, false, lines)
  vim.bo[thread.bufnr].modifiable = was_modifiable
  if config.get().ui.auto_scroll and thread.winid and vim.api.nvim_win_is_valid(thread.winid) then
    local prompt_line = prompt_start(thread.bufnr)
    vim.api.nvim_win_set_cursor(thread.winid, { math.min(prompt_line + 1, #lines), 0 })
  end
end

function M.schedule_render(thread_id)
  local timers = state.render_timers
  if timers[thread_id] then
    timers[thread_id]:stop()
    timers[thread_id]:close()
  end
  local timer = vim.uv.new_timer()
  timers[thread_id] = timer
  timer:start(config.get().ui.render_delay_ms, 0, function()
    timer:stop()
    timer:close()
    timers[thread_id] = nil
    vim.schedule(function()
      M.render(thread_id)
    end)
  end)
end

return M
