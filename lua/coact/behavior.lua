local config = require("coact.config")
local context = require("coact.context")
local state = require("coact.state")
local util = require("coact.util")

local M = {}

local group = vim.api.nvim_create_augroup("coact.nvim.behavior", { clear = true })
local did_setup = false
local anchors = {}

local function thread_key(thread_id)
  thread_id = thread_id or state.active_thread_id or "global"
  return tostring(thread_id)
end

local function now_label()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function path_in_workspace(path, cwd)
  if not path or path == "" then
    return false
  end
  local normalized = vim.fs.normalize(vim.fn.expand(path))
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  return normalized == cwd or vim.startswith(normalized, cwd .. "/")
end

local function is_trackable_buffer(bufnr, cwd)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  if context.is_coact_buffer(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return vim.bo[bufnr].buflisted or vim.bo[bufnr].modified
  end
  return path_in_workspace(name, cwd)
end

local function buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.expand(name))
end

local function buffer_key(bufnr)
  return buffer_path(bufnr) or ("buf:" .. tostring(bufnr))
end

local function path_label(path, cwd)
  if not path or path == "" then
    return ""
  end
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  path = vim.fs.normalize(vim.fn.expand(path))
  if path == cwd then
    return vim.fn.fnamemodify(path, ":t")
  end
  if vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

local function buffer_label(bufnr, path, cwd)
  if path and path ~= "" then
    return path_label(path, cwd)
  end
  return ("[No Name #%d]"):format(bufnr)
end

local function read_buffer_lines(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function read_file_lines(path)
  if not path or path == "" then
    return nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

local function lines_text(lines)
  lines = lines or {}
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function same_lines(left, right)
  left = left or {}
  right = right or {}
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if line ~= right[index] then
      return false
    end
  end
  return true
end

local function anchor_dir(anchor)
  local state_dir = vim.fn.stdpath("state")
  local workspace = vim.fn.sha256(anchor.cwd or config.cwd()):sub(1, 16)
  local thread = tostring(anchor.thread_id or "global"):gsub("[^%w_.%-]", "_")
  return vim.fs.joinpath(state_dir, "coact.nvim", "behavior", workspace, thread)
end

local function write_pack(anchor, text)
  local dir = vim.fs.joinpath(anchor_dir(anchor), "packs")
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "latest.diff")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  anchor.latest_pack_path = path
  return path
end

local function ensure_baseline(anchor, bufnr)
  if not is_trackable_buffer(bufnr, anchor.cwd) then
    return nil
  end
  local key = buffer_key(bufnr)
  local unnamed_key = "buf:" .. tostring(bufnr)
  if key ~= unnamed_key and anchor.baselines[unnamed_key] then
    local migrated = anchor.baselines[unnamed_key]
    anchor.baselines[unnamed_key] = nil
    migrated.key = key
    anchor.baselines[key] = migrated
    for index, ordered_key in ipairs(anchor.order or {}) do
      if ordered_key == unnamed_key then
        anchor.order[index] = key
        break
      end
    end
  end
  local existing = anchor.baselines[key]
  if existing then
    existing.bufnr = bufnr
    existing.path = existing.path or buffer_path(bufnr)
    existing.label = buffer_label(bufnr, existing.path, anchor.cwd)
    return existing
  end
  local path = buffer_path(bufnr)
  local baseline = {
    key = key,
    bufnr = bufnr,
    path = path,
    label = buffer_label(bufnr, path, anchor.cwd),
    filetype = vim.bo[bufnr].filetype,
    lines = read_buffer_lines(bufnr) or {},
    created_at_ms = util.now_ms(),
    created_at = now_label(),
  }
  anchor.baselines[key] = baseline
  table.insert(anchor.order, key)
  return baseline
end

local function ensure_all_baselines(bufnr)
  for _, anchor in pairs(anchors) do
    ensure_baseline(anchor, bufnr)
  end
end

local function mark_touched(bufnr)
  for _, anchor in pairs(anchors) do
    local baseline = ensure_baseline(anchor, bufnr)
    if baseline then
      baseline.touched_at_ms = util.now_ms()
      baseline.touched_at = now_label()
      baseline.modified = vim.bo[bufnr].modified
      baseline.changedtick = vim.b[bufnr].changedtick
    end
  end
end

local function capture_current(bufnr, closed)
  for _, anchor in pairs(anchors) do
    local baseline = ensure_baseline(anchor, bufnr)
    if baseline then
      baseline.current_lines = read_buffer_lines(bufnr)
      baseline.closed = closed == true
      baseline.modified = vim.bo[bufnr].modified
      baseline.changedtick = vim.b[bufnr].changedtick
    end
  end
end

local function snapshot_loaded_buffers(anchor)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    ensure_baseline(anchor, bufnr)
  end
end

local function refresh_loaded_buffers(anchor)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      ensure_baseline(anchor, bufnr)
    end
  end
end

local function current_lines_for(baseline)
  local bufnr = baseline.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return read_buffer_lines(bufnr) or {}
  end
  if baseline.current_lines then
    return baseline.current_lines
  end
  return read_file_lines(baseline.path) or {}
end

local function current_modified_for(baseline)
  local bufnr = baseline.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.bo[bufnr].modified
  end
  return baseline.modified == true
end

local function unified_diff(baseline, current)
  local old_text = lines_text(baseline.lines)
  local new_text = lines_text(current)
  if old_text == new_text then
    return ""
  end
  local ok, diff = pcall(vim.diff, old_text, new_text, {
    result_type = "unified",
    ctxlen = 3,
    linematch = true,
  })
  if not ok or not diff or diff == "" then
    return ""
  end
  local label = baseline.label or baseline.path or baseline.key
  local old_label = #baseline.lines == 0 and "/dev/null" or ("a/" .. label)
  local new_label = #current == 0 and "/dev/null" or ("b/" .. label)
  local lines = {
    "diff --codex-behavior " .. old_label .. " " .. new_label,
    "--- " .. old_label,
    "+++ " .. new_label,
  }
  vim.list_extend(lines, vim.split(diff:gsub("\n$", ""), "\n", { plain = true }))
  return table.concat(lines, "\n")
end

local function resolve_thread_id(thread_or_id)
  if type(thread_or_id) == "table" then
    return thread_or_id.id
  end
  return thread_or_id or state.active_thread_id
end

function M.anchor(thread_or_id, opts)
  opts = opts or {}
  local thread_id = resolve_thread_id(thread_or_id)
  local key = thread_key(thread_id)
  local anchor = {
    id = tostring(util.now_ms()),
    thread_id = thread_id,
    cwd = vim.fs.normalize(vim.fn.expand(opts.cwd or config.cwd())),
    reason = opts.reason or "submit",
    created_at_ms = util.now_ms(),
    created_at = now_label(),
    baselines = {},
    order = {},
  }
  anchors[key] = anchor
  snapshot_loaded_buffers(anchor)
  return anchor
end

function M.reset(thread_or_id)
  return M.anchor(thread_or_id, { reason = "manual-reset" })
end

function M.get_anchor(thread_or_id)
  return anchors[thread_key(resolve_thread_id(thread_or_id))]
end

function M.changed_entries(thread_or_id)
  local anchor = M.get_anchor(thread_or_id)
  if not anchor then
    return {}, nil
  end
  refresh_loaded_buffers(anchor)
  local entries = {}
  for _, key in ipairs(anchor.order or {}) do
    local baseline = anchor.baselines[key]
    if baseline then
      local current = current_lines_for(baseline)
      if not same_lines(baseline.lines, current) then
        table.insert(entries, {
          baseline = baseline,
          current = current,
          modified = current_modified_for(baseline),
        })
      end
    end
  end
  return entries, anchor
end

function M.pack(thread_or_id)
  local entries, anchor = M.changed_entries(thread_or_id)
  if not anchor then
    return table.concat({
      "Neovim editor behavior since previous agent turn",
      "- no behavior anchor has been recorded for this thread",
    }, "\n")
  end

  local unsaved = 0
  for _, entry in ipairs(entries) do
    if entry.modified then
      unsaved = unsaved + 1
    end
  end

  local lines = {
    "Neovim editor behavior since previous agent turn",
    "- anchor: " .. anchor.created_at,
    "- current: " .. now_label(),
    ("- files changed: %d"):format(#entries),
    "- includes unsaved buffers: " .. tostring(unsaved > 0),
  }
  if #entries == 0 then
    table.insert(lines, "")
    table.insert(lines, "No editor buffer changes recorded since the behavior anchor.")
  else
    table.insert(lines, "")
    table.insert(lines, "Changed buffers:")
    for _, entry in ipairs(entries) do
      local marker = entry.modified and "unsaved" or "saved"
      table.insert(lines, ("- %s (%s)"):format(entry.baseline.label, marker))
    end
    table.insert(lines, "")
    table.insert(lines, "```diff")
    for index, entry in ipairs(entries) do
      if index > 1 then
        table.insert(lines, "")
      end
      table.insert(lines, unified_diff(entry.baseline, entry.current))
    end
    table.insert(lines, "```")
  end

  local text = table.concat(lines, "\n")
  local pack_path = write_pack(anchor, text)
  return text .. "\n\nBehavior pack written to: " .. pack_path
end

function M.status_text(thread_or_id)
  local entries, anchor = M.changed_entries(thread_or_id)
  if not anchor then
    return "behavior recorder: no anchor for this thread"
  end
  local lines = {
    "behavior recorder",
    "- anchor: " .. anchor.created_at,
    ("- tracked buffers: %d"):format(#(anchor.order or {})),
    ("- changed buffers: %d"):format(#entries),
  }
  for _, entry in ipairs(entries) do
    table.insert(lines, ("  - %s%s"):format(entry.baseline.label, entry.modified and " (unsaved)" or ""))
  end
  if anchor.latest_pack_path then
    table.insert(lines, "- latest pack: " .. anchor.latest_pack_path)
  end
  return table.concat(lines, "\n")
end

function M.context(arg, opts)
  opts = opts or {}
  return M.pack(opts.thread or opts.thread_id or state.active_thread_id)
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    callback = function(event)
      ensure_all_baselines(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      mark_touched(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      mark_touched(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(event)
      capture_current(event.buf, true)
    end,
  })
end

M._anchors = anchors
M._is_trackable_buffer = is_trackable_buffer
M._unified_diff = unified_diff

return M
