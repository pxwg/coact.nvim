local M = {}

local hooks = {}
local image_exts = {
  bmp = true,
  gif = true,
  heic = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}

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
  local filetype = vim.bo[bufnr].filetype
  return vim.b[bufnr].codex_thread_id ~= nil
    or filetype == "codex"
    or filetype == "codex-history"
    or filetype == "codex-input"
    or name:match("^codex://") ~= nil
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

function M.display_path(path)
  path = vim.fs.normalize(vim.fn.expand(tostring(path or "")))
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel ~= "" and rel ~= path and not rel:match("^%.%./") then
    path = rel
  end
  if path:find("%s") then
    return "`" .. path:gsub("`", "\\`") .. "`"
  end
  return path
end

function M.selection_for_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
  local start_line = start_mark[1]
  local end_line = end_mark[1]
  if start_line == 0 or end_line == 0 then
    return nil
  end
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line - 1, end_line, false)
  if not ok or #lines == 0 then
    return nil
  end
  local content = table.concat(lines, "\n")
  if content:gsub("^%s+", ""):gsub("%s+$", "") == "" then
    return nil
  end

  return {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    filename = M.buffer_label(bufnr),
    filetype = vim.bo[bufnr].filetype,
    content = content,
  }
end

local function workspace_files(kind)
  local config = require("codex.config")
  local cwd = config.cwd()
  local files = {}
  if vim.fn.executable("rg") == 1 and vim.system then
    local result = vim.system({ "rg", "--files", "--hidden", "-g", "!.git" }, { cwd = cwd, text = true }):wait()
    if result and result.code == 0 then
      files = vim.split(result.stdout or "", "\n", { plain = true, trimempty = true })
    end
  end
  if #files == 0 then
    for _, path in ipairs(vim.fn.globpath(cwd, "**/*", false, true)) do
      if vim.fn.filereadable(path) == 1 then
        table.insert(files, vim.fn.fnamemodify(path, ":."))
      end
    end
  end
  if kind == "image" then
    files = vim.tbl_filter(function(path)
      local ext = tostring(path):match("%.([^./\\]+)$")
      return ext and image_exts[ext:lower()] or false
    end, files)
  end
  table.sort(files)
  return files
end

local function token_before_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)
  local start_col, end_col, token, name, arg = before:find("(@([%w_./~%-]+):(.*))$")
  if not name and col < #line then
    before = line:sub(1, col + 1)
    start_col, end_col, token, name, arg = before:find("(@([%w_./~%-]+):(.*))$")
  end
  if not name then
    return nil
  end
  return {
    token = token,
    name = name,
    arg = arg or "",
    row = row,
    start_col = start_col - 1,
    end_col = end_col,
  }
end

local function replace_context_token(bufnr, range, text)
  vim.api.nvim_buf_set_text(bufnr, range.row - 1, range.start_col, range.row - 1, range.end_col, { text })
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_set_cursor(winid, { range.row, range.start_col + #text })
      return
    end
  end
end

local function context_replacement(payload, path)
  if payload.name == "image" then
    return "@image:" .. M.display_path(path)
  end
  return "@" .. M.display_path(path)
end

local function snacks_item_path(item, cwd)
  if not item then
    return nil
  end
  local ok, picker_util = pcall(require, "snacks.picker.util")
  if ok and picker_util.path then
    local path = picker_util.path(item)
    if path and path ~= "" then
      return path
    end
  end
  local file = item.file or item.path or item.text
  if not file or file == "" then
    return nil
  end
  if file:match("^/") or file:match("^%a:[/\\]") then
    return file
  end
  return vim.fs.joinpath(item.cwd or cwd, file)
end

local function snacks_pick_path(payload)
  local ok, snacks = pcall(require, "snacks")
  if not (ok and snacks.picker and snacks.picker.files) then
    return false
  end

  local cwd = require("codex.config").cwd()
  local opts = {
    cwd = cwd,
    hidden = true,
    title = payload.name == "image" and "Codex Image Context" or "Codex File Context",
    confirm = function(picker, item)
      picker:close()
      local path = snacks_item_path(item, cwd)
      if not path then
        return
      end
      replace_context_token(payload.bufnr, payload.range, context_replacement(payload, path))
    end,
  }
  if payload.name == "image" then
    opts.ft = vim.tbl_keys(image_exts)
  end
  snacks.picker.files(opts)
  return true
end

local function select_pick_path(payload)
  local files = workspace_files(payload.name)
  if #files == 0 then
    vim.notify("No files found for Codex context", vim.log.levels.WARN, { title = "codex.nvim" })
    return
  end
  vim.ui.select(files, {
    prompt = payload.name == "image" and "Codex image context" or "Codex file context",
  }, function(choice)
    if not choice then
      return
    end
    replace_context_token(payload.bufnr, payload.range, context_replacement(payload, choice))
  end)
end

local function pick_path(payload)
  if snacks_pick_path(payload) then
    return
  end
  select_pick_path(payload)
end

hooks.file = pick_path
hooks.image = pick_path

function M.register_hook(name, callback)
  hooks[name] = callback
end

function M.trigger_hook()
  local token = token_before_cursor()
  if not token then
    return false
  end
  local callback = hooks[token.name]
  if not callback then
    return false
  end
  local payload = {
    name = token.name,
    arg = token.arg,
    bufnr = vim.api.nvim_get_current_buf(),
    range = {
      row = token.row,
      start_col = token.start_col,
      end_col = token.end_col,
    },
  }
  vim.schedule(function()
    callback(payload)
  end)
  return true
end

M._workspace_files = workspace_files
M._token_before_cursor = token_before_cursor
M._snacks_item_path = snacks_item_path

return M
