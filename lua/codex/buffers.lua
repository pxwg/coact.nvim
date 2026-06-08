local config = require("codex.config")
local context = require("codex.context")
local hooks = require("codex.hooks")
local metadata = require("codex.ui.metadata")
local render = require("codex.ui.render")
local state = require("codex.state")
local util = require("codex.util")
local window = require("codex.ui.window")

local M = {}

local group = vim.api.nvim_create_augroup("codex.nvim.buffers", { clear = true })
local view_autocmds_setup = false
local window_snapshots = {}
local save_draft

local restorable_window_options = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "wrap",
  "linebreak",
  "foldmethod",
  "foldexpr",
  "foldenable",
  "foldlevel",
  "conceallevel",
  "winbar",
  "winfixheight",
}

local history_window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = true,
  linebreak = true,
  foldmethod = "expr",
  foldexpr = "v:lua.CodexFoldExpr(v:lnum)",
  foldenable = true,
  foldlevel = 99,
}

local prompt_window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = true,
  linebreak = true,
  foldmethod = "manual",
  foldexpr = "0",
  foldenable = false,
  foldlevel = 99,
  winfixheight = true,
}

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function current_window_buffer(winid)
  return valid_win(winid) and vim.api.nvim_win_get_buf(winid) or nil
end

local function unique_insert(list, seen, value)
  if value and not seen[value] then
    seen[value] = true
    table.insert(list, value)
  end
end

local function close_thread_windows(thread, fallback_win)
  if thread and save_draft then
    save_draft(thread)
    thread.ui_state = "preview"
  end
  local wins = {}
  local seen = {}
  if thread then
    unique_insert(wins, seen, thread.prompt_winid)
    unique_insert(wins, seen, thread.winid)
    for _, bufnr in ipairs({ thread.prompt_bufnr, thread.bufnr }) do
      if valid_buf(bufnr) then
        for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
          unique_insert(wins, seen, winid)
        end
      end
    end
  end
  unique_insert(wins, seen, fallback_win)
  for _, winid in ipairs(wins) do
    if valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
end

local function statusline_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function prompt_winbar(thread)
  render.setup_highlights()
  local labels = metadata.composer_labels(thread)
  local ctx = metadata.context_label(thread)
  if ctx then
    table.insert(labels, ctx)
  end
  local meta = #labels > 0 and (" | " .. table.concat(labels, " | ")) or ""
  return table.concat({
    "%#CodexHeaderUser#",
    statusline_escape(" Codex input "),
    "%#CodexHeaderMeta#",
    statusline_escape(meta),
    "%*",
  })
end

local function composer_config()
  local ui = config.get().ui or {}
  return ui.composer or {}
end

local function dimension(value, fallback, total)
  if type(value) ~= "number" then
    return fallback
  end
  if value > 0 and value < 1 then
    return math.max(1, math.floor((total or vim.o.lines) * value))
  end
  return math.max(1, math.floor(value))
end

local function composer_bounds()
  local opts = composer_config()
  local min_height = math.max(2, dimension(opts.min_height, 2))
  local max_height = dimension(opts.max_height, math.max(min_height, math.floor(vim.o.lines * 0.33)))
  return min_height, math.max(min_height, max_height)
end

local function clamp(value, min_value, max_value)
  return math.min(math.max(value, min_value), max_value)
end

function M.is_prompt_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return valid_buf(bufnr) and vim.b[bufnr].codex_composer == true
end

local function prompt_bufnr_for_thread(thread)
  if thread and valid_buf(thread.prompt_bufnr) then
    return thread.prompt_bufnr
  end
  return nil
end

local function prompt_bufnr_for(bufnr, create)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local thread = state.thread_for_buf(bufnr)
  if M.is_prompt_buffer(bufnr) then
    return bufnr, thread
  end
  if thread then
    if create then
      return M.ensure_prompt(thread.id), thread
    end
    return prompt_bufnr_for_thread(thread), thread
  end
  return nil, nil
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

local function prompt_lines(bufnr)
  if not valid_buf(bufnr) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function normalize_prompt_lines(lines)
  lines = vim.deepcopy(lines or {})
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  return lines
end

local function set_prompt_lines(bufnr, lines)
  if not valid_buf(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #lines > 0 and lines or { "" })
end

local function all_prompt_lines(thread)
  local bufnr = prompt_bufnr_for_thread(thread)
  if bufnr then
    return prompt_lines(bufnr)
  end
  if type(thread and thread.draft_lines) == "table" and #thread.draft_lines > 0 then
    return vim.deepcopy(thread.draft_lines)
  end
  return { "" }
end

save_draft = function(thread)
  if not thread then
    return
  end
  local lines = all_prompt_lines(thread)
  thread.draft_lines = #lines > 0 and vim.deepcopy(lines) or { "" }
  local winid = thread.prompt_winid
  if valid_win(winid) and current_window_buffer(winid) == thread.prompt_bufnr then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok and cursor then
      thread.draft_cursor = cursor
    end
  end
end

local function restore_prompt_buffer(thread, bufnr)
  local lines = type(thread.draft_lines) == "table" and thread.draft_lines or { "" }
  set_prompt_lines(bufnr, lines)
end

local function clear_draft(thread)
  if not thread then
    return
  end
  thread.draft_lines = { "" }
  thread.draft_cursor = { 1, 0 }
  if valid_buf(thread.prompt_bufnr) then
    set_prompt_lines(thread.prompt_bufnr, {})
  end
end

local function restore_draft(thread, snapshot)
  if not thread or not snapshot then
    return
  end
  thread.draft_lines = vim.deepcopy(snapshot.lines or { "" })
  thread.draft_cursor = snapshot.cursor and vim.deepcopy(snapshot.cursor) or { 1, 0 }
  if valid_buf(thread.prompt_bufnr) then
    restore_prompt_buffer(thread, thread.prompt_bufnr)
  end
end

function M.snapshot_prompt(bufnr)
  local _, thread = prompt_bufnr_for(bufnr, true)
  if not thread then
    return nil
  end
  save_draft(thread)
  return {
    lines = vim.deepcopy(thread.draft_lines or { "" }),
    cursor = thread.draft_cursor and vim.deepcopy(thread.draft_cursor) or { 1, 0 },
  }
end

function M.restore_prompt(bufnr, snapshot)
  local _, thread = prompt_bufnr_for(bufnr, true)
  restore_draft(thread, snapshot)
  if thread then
    M.refresh_composer(thread)
  end
end

local function prompt_visual_height(thread)
  local bufnr = prompt_bufnr_for_thread(thread)
  local winid = thread and thread.prompt_winid
  if valid_win(winid) and current_window_buffer(winid) == bufnr and vim.api.nvim_win_text_height then
    local ok, result = pcall(vim.api.nvim_win_text_height, winid, {
      start_row = 0,
      end_row = -1,
    })
    if ok and type(result) == "table" and result.all then
      return math.max(1, result.all)
    end
  end
  return math.max(1, #prompt_lines(bufnr))
end

local function setup_view_autocmds()
  if view_autocmds_setup then
    return
  end
  view_autocmds_setup = true
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(event)
      local data = event.data or {}
      local v_event = vim.v.event or {}
      local win = tonumber(data.winid or v_event.winid or event.match)
      if not valid_win(win) then
        return
      end
      local bufnr = vim.api.nvim_win_get_buf(win)
      local thread = state.thread_for_buf(bufnr)
      if thread and not M.is_prompt_buffer(bufnr) then
        render.on_user_view_changed(thread, win, "viewport")
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local winid = tonumber(event.match)
      window_snapshots[winid] = nil
      for _, thread in pairs(state.threads) do
        if thread.winid == winid then
          thread.winid = nil
        end
        if thread.prompt_winid == winid then
          save_draft(thread)
          thread.prompt_winid = nil
          thread.ui_state = "preview"
          if valid_win(thread.winid) then
            window.apply_history_layout(thread.winid)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, thread in pairs(state.threads) do
        if thread.ui_state == "compose" then
          M.refresh_composer(thread)
        elseif valid_win(thread.winid) then
          window.apply_history_layout(thread.winid)
        end
      end
    end,
  })
end

local function submit_keymap(bufnr)
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    require("codex").submit()
  end, { buffer = bufnr, desc = "Submit Codex prompt" })
end

local function history_insert_intent_keymaps(bufnr)
  local keys = { "i", "a", "I", "A", "o", "O", "gi", "c", "cc", "S" }
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, function()
      M.enter_compose(vim.b[bufnr].codex_thread_id, { source = "insert_intent" })
    end, { buffer = bufnr, silent = true, desc = "Start Codex prompt input" })
  end
end

local function context_tab_keymap(bufnr)
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-n>"
    end
    if require("codex.context").trigger_hook() then
      return ""
    end
    return "\t"
  end, { buffer = bufnr, expr = true, desc = "Trigger Codex context hook" })
end

local function configure_history_buffer(bufnr, thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = "codex-history"
  vim.b[bufnr].codex_thread_id = thread_id
  vim.b[bufnr].codex_role = "history"
  submit_keymap(bufnr)
  history_insert_intent_keymaps(bufnr)
  vim.keymap.set("n", "q", function()
    close_thread_windows(state.thread_for_buf(bufnr), vim.api.nvim_get_current_win())
  end, { buffer = bufnr, desc = "Close Codex windows" })
  vim.keymap.set("n", "za", function()
    require("codex.ui.render").toggle_under_cursor()
  end, { buffer = bufnr, silent = true, desc = "Toggle Codex block" })
  vim.keymap.set("n", "K", function()
    require("codex.ui.detail").open()
  end, { buffer = bufnr, silent = true, desc = "Open Codex block detail" })
end

local function configure_prompt_buffer(bufnr, thread_id)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = "codex-input"
  vim.b[bufnr].codex_thread_id = thread_id
  vim.b[bufnr].codex_composer = true
  vim.b[bufnr].codex_role = "composer"
  submit_keymap(bufnr)
  context_tab_keymap(bufnr)
  vim.keymap.set("n", "q", function()
    M.enter_preview(vim.b[bufnr].codex_thread_id, { source = "composer_q", focus = true })
  end, { buffer = bufnr, desc = "Close Codex input" })
  vim.keymap.set("n", "<CR>", function()
    require("codex").submit()
  end, { buffer = bufnr, desc = "Submit Codex prompt" })
end

function M.apply_window_options(win, bufnr)
  win = win or vim.api.nvim_get_current_win()
  if not valid_win(win) then
    return
  end
  bufnr = bufnr or vim.api.nvim_win_get_buf(win)
  local thread = bufnr and state.thread_for_buf(bufnr)
  if not thread or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  if not window_snapshots[win] then
    local snapshot = {}
    for _, option in ipairs(restorable_window_options) do
      snapshot[option] = vim.wo[win][option]
    end
    window_snapshots[win] = snapshot
  end
  local is_prompt = M.is_prompt_buffer(bufnr)
  local options = is_prompt and prompt_window_options or history_window_options
  for option, value in pairs(options) do
    vim.wo[win][option] = value
  end
  if is_prompt then
    vim.wo[win].conceallevel = 0
    vim.wo[win].winbar = prompt_winbar(thread)
  else
    vim.wo[win].conceallevel = math.max(vim.wo[win].conceallevel, 1)
  end
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

local function setup_history_autocmds(bufnr)
  setup_view_autocmds()
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
      save_draft(state.thread_for_buf(bufnr))
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
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local thread = state.thread_for_buf(bufnr)
      if thread and vim.api.nvim_win_get_buf(win) == bufnr then
        render.on_user_view_changed(thread, win, "cursor")
      end
    end,
  })
end

local function setup_prompt_autocmds(bufnr)
  setup_view_autocmds()
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
        save_draft(thread)
        thread.prompt_bufnr = nil
        thread.prompt_winid = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local thread = state.thread_for_buf(bufnr)
      if not thread then
        return
      end
      vim.schedule(function()
        if valid_buf(bufnr) then
          save_draft(thread)
          M.refresh_composer(thread)
        end
      end)
    end,
  })
end

local function is_codex_buffer(bufnr)
  if not valid_buf(bufnr) then
    return false
  end
  return vim.b[bufnr].codex_thread_id ~= nil or vim.api.nvim_buf_get_name(bufnr):match("^codex://thread/") ~= nil
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not is_codex_buffer(bufnr) then
    return false
  end

  local thread = state.thread_for_buf(bufnr)
  local payload = {
    bufnr = bufnr,
    is_composer = M.is_prompt_buffer(bufnr),
    thread = thread,
    thread_id = thread and thread.id or vim.b[bufnr].codex_thread_id,
  }

  local on_attach = config.get().buffer and config.get().buffer.on_attach
  if type(on_attach) == "function" then
    local ok, err = pcall(on_attach, bufnr, payload)
    if not ok then
      util.notify("codex.nvim buffer.on_attach failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  hooks.emit("buffer_attached", payload)
  return true
end

function M.attach_all()
  local count = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_codex_buffer(bufnr) and M.attach(bufnr) then
      count = count + 1
    end
  end
  return count
end

function M.ensure_prompt(thread_id)
  local thread = state.ensure_thread(thread_id)
  if valid_buf(thread.prompt_bufnr) then
    return thread.prompt_bufnr
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  configure_prompt_buffer(bufnr, thread_id)
  thread.prompt_bufnr = bufnr
  restore_prompt_buffer(thread, bufnr)
  render.apply_prompt_marks(thread, bufnr)
  setup_prompt_autocmds(bufnr)
  return bufnr
end

function M.collect_prompt(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local prompt_bufnr, thread = prompt_bufnr_for(bufnr, true)
  if prompt_bufnr then
    save_draft(thread)
    return table.concat(normalize_prompt_lines(all_prompt_lines(thread)), "\n")
  end

  local start = prompt_start(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start, -1, false)
  return table.concat(normalize_prompt_lines(lines), "\n")
end

function M.clear_prompt(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local prompt_bufnr, thread = prompt_bufnr_for(bufnr, true)
  if prompt_bufnr then
    clear_draft(thread)
    M.refresh_composer(thread)
    return
  end

  local start = prompt_start(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, start, -1, false, {})
end

function M.append_prompt_line(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local prompt_bufnr, thread = prompt_bufnr_for(bufnr, true)
  line = tostring(line or "")
  if not prompt_bufnr then
    local start = prompt_start(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start, -1, false)
    if #lines == 0 or (#lines == 1 and lines[1] == "") then
      vim.api.nvim_buf_set_lines(bufnr, start, -1, false, { line })
      return
    end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { line })
    return
  end

  local lines = prompt_lines(prompt_bufnr)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    set_prompt_lines(prompt_bufnr, { line })
  else
    vim.api.nvim_buf_set_lines(prompt_bufnr, #lines, #lines, false, { line })
  end
  save_draft(thread)
  M.refresh_composer(thread)
  if thread and valid_win(thread.prompt_winid) then
    local line_count = vim.api.nvim_buf_line_count(prompt_bufnr)
    local last = vim.api.nvim_buf_get_lines(prompt_bufnr, line_count - 1, line_count, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, thread.prompt_winid, { line_count, #last })
  end
end

function M.get_thread_id(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.b[bufnr].codex_thread_id
end

function M.resize_prompt(thread)
  thread = type(thread) == "table" and thread or state.get_thread(thread)
  if not thread or not valid_buf(thread.prompt_bufnr) then
    return
  end
  local winid = valid_win(thread.prompt_winid) and thread.prompt_winid or nil
  if not winid then
    local wins = vim.fn.win_findbuf(thread.prompt_bufnr)
    winid = wins[1]
    thread.prompt_winid = winid
  end
  if not valid_win(winid) then
    return
  end
  local min_height, max_height = composer_bounds()
  local height = clamp(prompt_visual_height(thread), min_height, max_height)
  thread.prompt_height = height
  window.apply_thread_layout(thread.winid, winid, height)
end

function M.refresh_composer(thread)
  thread = type(thread) == "table" and thread or state.get_thread(thread)
  if not thread or not valid_buf(thread.prompt_bufnr) then
    return
  end
  render.apply_prompt_marks(thread, thread.prompt_bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(thread.prompt_bufnr)) do
    if valid_win(winid) and current_window_buffer(winid) == thread.prompt_bufnr then
      thread.prompt_winid = winid
      M.apply_window_options(winid, thread.prompt_bufnr)
    end
  end
  M.resize_prompt(thread)
end

local function history_win_for_thread(thread)
  if valid_win(thread and thread.winid) and current_window_buffer(thread.winid) == thread.bufnr then
    return thread.winid
  end
  if thread and valid_buf(thread.bufnr) then
    for _, winid in ipairs(vim.fn.win_findbuf(thread.bufnr)) do
      if valid_win(winid) and current_window_buffer(winid) == thread.bufnr then
        thread.winid = winid
        return winid
      end
    end
  end
  return nil
end

local function restore_prompt_cursor(thread)
  if not thread or not valid_win(thread.prompt_winid) or not valid_buf(thread.prompt_bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(thread.prompt_bufnr)
  local cursor = thread.draft_cursor or { line_count, 0 }
  local lnum = clamp(cursor[1] or line_count, 1, line_count)
  local line = vim.api.nvim_buf_get_lines(thread.prompt_bufnr, lnum - 1, lnum, false)[1] or ""
  local col = clamp(cursor[2] or #line, 0, #line)
  pcall(vim.api.nvim_win_set_cursor, thread.prompt_winid, { lnum, col })
end

function M.enter_preview(thread_or_id, opts)
  opts = opts or {}
  local thread = type(thread_or_id) == "table" and thread_or_id or state.get_thread(thread_or_id)
  if not thread then
    return false
  end
  save_draft(thread)
  thread.ui_state = "preview"
  local prompt_winid = thread.prompt_winid
  thread.prompt_winid = nil
  if valid_win(prompt_winid) then
    pcall(vim.api.nvim_win_close, prompt_winid, true)
  end
  local history_winid = history_win_for_thread(thread)
  if valid_win(history_winid) then
    window.apply_history_layout(history_winid)
    M.apply_window_options(history_winid, thread.bufnr)
    if opts.focus ~= false then
      vim.api.nvim_set_current_win(history_winid)
    end
  end
  if opts.stopinsert ~= false then
    pcall(vim.cmd, "stopinsert")
  end
  if opts.follow_latest == true and valid_win(history_winid) then
    render.follow_latest(thread, history_winid)
  end
  return true
end

function M.enter_compose(thread_or_id, opts)
  opts = opts or {}
  local thread_id = type(thread_or_id) == "table" and thread_or_id.id or thread_or_id
  if not thread_id then
    return false
  end
  local bufnr = M.ensure(thread_id)
  local thread = state.get_thread(thread_id)
  local history_winid = history_win_for_thread(thread)
  if not valid_win(history_winid) then
    history_winid = window.open_history(bufnr)
    state.set_buffer(thread_id, bufnr, history_winid)
    M.apply_window_options(history_winid, bufnr)
  end
  local prompt_bufnr = M.ensure_prompt(thread_id)
  restore_prompt_buffer(thread, prompt_bufnr)
  thread.ui_state = "compose"
  local prompt_winid = thread.prompt_winid
  if not (valid_win(prompt_winid) and current_window_buffer(prompt_winid) == prompt_bufnr) then
    local min_height = composer_bounds()
    prompt_winid = window.open_composer(history_winid, prompt_bufnr, thread.prompt_height or min_height)
    thread.prompt_winid = prompt_winid
  end
  M.apply_window_options(history_winid, bufnr)
  M.apply_window_options(prompt_winid, prompt_bufnr)
  M.refresh_composer(thread)
  if valid_win(thread.prompt_winid) then
    vim.api.nvim_set_current_win(thread.prompt_winid)
    restore_prompt_cursor(thread)
  end
  if opts.startinsert ~= false then
    vim.schedule(function()
      if valid_win(thread.prompt_winid) then
        vim.api.nvim_set_current_win(thread.prompt_winid)
        vim.cmd("startinsert")
      end
    end)
  end
  return true
end

function M.ensure(thread_id)
  local thread = state.ensure_thread(thread_id)
  if thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr) then
    M.ensure_prompt(thread_id)
    return thread.bufnr
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "codex://thread/" .. thread_id)
  configure_history_buffer(bufnr, thread_id)
  state.bind_buffer(thread, bufnr)
  M.ensure_prompt(thread_id)
  if pcall(vim.treesitter.start, bufnr, "markdown") then
    vim.bo[bufnr].syntax = ""
    vim.b[bufnr].current_syntax = nil
  else
    vim.bo[bufnr].syntax = "markdown"
  end
  setup_history_autocmds(bufnr)
  M.render(thread_id, {})
  return bufnr
end

function M.open(thread_id)
  local bufnr = M.ensure(thread_id)
  local thread = state.get_thread(thread_id)
  local prompt_bufnr = M.ensure_prompt(thread_id)
  context.capture_thread_buffer(thread, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  local winid = window.open_history(bufnr)
  state.set_buffer(thread_id, bufnr, winid)
  thread.ui_state = "preview"
  thread.prompt_winid = nil
  M.apply_window_options(winid, bufnr)
  M.refresh_composer(thread)
  M.attach(bufnr)
  M.attach(prompt_bufnr)
  hooks.emit("buffer_opened", {
    bufnr = bufnr,
    winid = winid,
    prompt_bufnr = prompt_bufnr,
    prompt_winid = nil,
    thread = thread,
    thread_id = thread_id,
  })
  if valid_win(winid) then
    vim.api.nvim_set_current_win(winid)
    render.follow_latest(thread, winid)
  end
  return bufnr, winid, prompt_bufnr, nil
end

function M.render(thread_id, prompt_lines_arg)
  local thread = state.get_thread(thread_id)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end
  if prompt_lines_arg ~= nil then
    set_prompt_lines(M.ensure_prompt(thread_id), prompt_lines_arg)
  end
  render.render(thread)
end

function M.schedule_render(thread_id)
  local thread = state.get_thread(thread_id)
  render.schedule(thread, config.get().ui.render_delay_ms)
end

return M
