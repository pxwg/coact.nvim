local config = require("codex.config")
local context = require("codex.context")
local state = require("codex.state")
local util = require("codex.util")

local M = {}

local diff_ns = vim.api.nvim_create_namespace("codex.patch_session.diff")
local hint_ns = vim.api.nvim_create_namespace("codex.patch_session.hint")
local active_by_buf = {}

local keymaps = {
  accept = "<leader>ca",
  reject = "<leader>cr",
  accept_all = "<leader>cA",
  reject_all = "<leader>cR",
  fallback = "<leader>cf",
  cancel = "<leader>cq",
  next = "]c",
  prev = "[c",
}

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = tostring(line or ""):match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  return {
    old_start = tonumber(old_start),
    old_count = tonumber(old_count ~= "" and old_count or "1"),
    new_start = tonumber(new_start),
    new_count = tonumber(new_count ~= "" and new_count or "1"),
  }
end

local function parse_change_hunks(change)
  local hunks = {}
  local current = nil

  local function flush()
    if current then
      table.insert(hunks, current)
    end
    current = nil
  end

  for _, line in ipairs(util.split_lines(change.diff or "")) do
    local header = parse_hunk_header(line)
    if header then
      flush()
      current = vim.tbl_extend("force", header, {
        header = line,
        lines = {},
        old_lines = {},
        new_lines = {},
      })
    elseif current then
      table.insert(current.lines, line)
      local prefix = line:sub(1, 1)
      local body = line:sub(2)
      if prefix == " " then
        table.insert(current.old_lines, body)
        table.insert(current.new_lines, body)
      elseif prefix == "-" then
        table.insert(current.old_lines, body)
      elseif prefix == "+" then
        table.insert(current.new_lines, body)
      elseif prefix == "\\" then
        -- "\ No newline at end of file" is metadata, not buffer content.
      end
    end
  end
  flush()

  return hunks
end

local function absolute_path(cwd, path)
  path = util.value(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fn.expand(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(cwd or config.cwd(), path))
end

local function find_buffer(path)
  local normalized = vim.fs.normalize(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and vim.fs.normalize(name) == normalized then
      return bufnr
    end
  end
  return nil
end

local function normal_window()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(winid).relative == "" then
      return winid
    end
  end
  return nil
end

local function target_window(thread)
  if thread and thread.context_winid and vim.api.nvim_win_is_valid(thread.context_winid) then
    if vim.api.nvim_win_get_config(thread.context_winid).relative == "" then
      return thread.context_winid
    end
  end
  local bufnr = thread and context.target_buffer(thread) or nil
  local winid = bufnr and context.window_for_buffer(bufnr, thread) or nil
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid).relative == "" then
    return winid
  end
  return normal_window()
end

local function set_buffer_lines(bufnr, start_row, end_row, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, lines)
end

local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function slice_matches(bufnr, start_row, expected)
  if #expected == 0 then
    return true
  end
  if start_row < 0 then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + #expected, false)
  return same_lines(lines, expected)
end

local function find_slice(bufnr, expected)
  if #expected == 0 then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for start_row = 0, math.max(0, #lines - #expected) do
    local ok = true
    for index, expected_line in ipairs(expected) do
      if lines[start_row + index] ~= expected_line then
        ok = false
        break
      end
    end
    if ok then
      return start_row
    end
  end
  return nil
end

local function lines_to_text(lines)
  if not lines or #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function normalized_final_lines(file)
  local final_lines = vim.api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
  if (file.is_new or file.kind == "delete") and #final_lines == 1 and final_lines[1] == "" then
    return {}
  end
  return final_lines
end

local function hunk_label(hunk)
  local path = hunk.file and hunk.file.relative_path or "patch"
  return ("%s hunk %d"):format(path, hunk.index or 0)
end

local function hunk_position(hunk)
  local row = hunk.applied_start_row or 0
  local end_row = row + #(hunk.new_lines or {})
  if hunk.extmark_id and vim.api.nvim_buf_is_valid(hunk.bufnr) then
    local extmark = vim.api.nvim_buf_get_extmark_by_id(hunk.bufnr, diff_ns, hunk.extmark_id, { details = true })
    if #extmark > 0 then
      row = extmark[1]
      end_row = extmark[3] and extmark[3].end_row or end_row
    end
  end
  if #(hunk.new_lines or {}) == 0 then
    end_row = row
  end
  return row, end_row
end

local function remove_hunk_marks(hunk)
  if not hunk.bufnr or not vim.api.nvim_buf_is_valid(hunk.bufnr) then
    return
  end
  if hunk.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, hunk.bufnr, diff_ns, hunk.extmark_id)
    hunk.extmark_id = nil
  end
  if hunk.old_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, hunk.bufnr, diff_ns, hunk.old_extmark_id)
    hunk.old_extmark_id = nil
  end
end

local function old_virtual_lines(hunk)
  local old_lines = hunk.old_lines or {}
  if #old_lines == 0 then
    return {}
  end
  local virt_lines = {}
  table.insert(virt_lines, { { ("--- before %s"):format(hunk_label(hunk)), "DiffDelete" } })
  for _, line in ipairs(old_lines) do
    table.insert(virt_lines, { { "- " .. line, "DiffDelete" } })
  end
  return virt_lines
end

local function mark_hunk(hunk)
  local bufnr = hunk.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_row = math.max(0, math.min(hunk.applied_start_row or 0, math.max(0, line_count - 1)))
  if #(hunk.new_lines or {}) > 0 then
    hunk.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, start_row, 0, {
      end_row = start_row + #hunk.new_lines,
      hl_group = "DiffAdd",
      hl_eol = true,
      hl_mode = "combine",
      priority = 20000,
    })
  else
    hunk.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, start_row, 0, {
      virt_text = {
        { ("[deleted %d line%s]"):format(#hunk.old_lines, #hunk.old_lines == 1 and "" or "s"), "DiffDelete" },
      },
      virt_text_pos = "right_align",
      priority = 20000,
    })
  end

  local virt_lines = old_virtual_lines(hunk)
  if #virt_lines > 0 then
    hunk.old_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, start_row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = start_row > 0,
      priority = 19999,
    })
  end
end

local function current_hunk(session)
  return session.hunks[session.current_index or 1]
end

local function pending_hunks(session)
  local pending = {}
  for _, hunk in ipairs(session.hunks or {}) do
    if not hunk.status then
      table.insert(pending, hunk)
    end
  end
  return pending
end

local function update_hints(session)
  for bufnr in pairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
    end
  end

  local hunk = current_hunk(session)
  if not hunk or hunk.status or not vim.api.nvim_buf_is_valid(hunk.bufnr) then
    return
  end

  local start_row = hunk_position(hunk)
  local total = #(session.hunks or {})
  local pending = #pending_hunks(session)
  vim.api.nvim_buf_set_extmark(hunk.bufnr, hint_ns, start_row, 0, {
    virt_text = {
      {
        ("Codex patch %d/%d (%d pending): %s accept, %s reject, %s all, %s reject-all, %s fallback"):format(
          hunk.index,
          total,
          pending,
          keymaps.accept,
          keymaps.reject,
          keymaps.accept_all,
          keymaps.reject_all,
          keymaps.fallback
        ),
        "Comment",
      },
    },
    virt_text_pos = "right_align",
    priority = 20001,
  })
end

local function ensure_hunk_window(session, hunk)
  local winid = target_window(session.thread)
  if not winid then
    vim.cmd("botright split")
    winid = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(winid)
  if vim.api.nvim_win_get_buf(winid) ~= hunk.bufnr then
    vim.api.nvim_win_set_buf(winid, hunk.bufnr)
  end
  return winid
end

local function navigate_to(session, index)
  if not session or session.completed or #session.hunks == 0 then
    return false
  end
  local hunk = session.hunks[index]
  if not hunk then
    return false
  end
  session.current_index = index
  local winid = ensure_hunk_window(session, hunk)
  local start_row = hunk_position(hunk)
  local line_count = vim.api.nvim_buf_line_count(hunk.bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(line_count, start_row + 1)), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zz")
  end)
  update_hints(session)
  return true
end

local function navigate_next(session)
  local total = #session.hunks
  if total == 0 then
    return false
  end
  local start = session.current_index or 1
  for offset = 1, total do
    local index = ((start + offset - 1) % total) + 1
    if not session.hunks[index].status then
      return navigate_to(session, index)
    end
  end
  return false
end

local function navigate_prev(session)
  local total = #session.hunks
  if total == 0 then
    return false
  end
  local start = session.current_index or 1
  for offset = 1, total do
    local index = ((start - offset - 1) % total) + 1
    if not session.hunks[index].status then
      return navigate_to(session, index)
    end
  end
  return false
end

local function restore_original_files(session)
  for _, file in pairs(session.files or {}) do
    if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      set_buffer_lines(file.bufnr, 0, -1, vim.deepcopy(file.original_lines or {}))
      vim.bo[file.bufnr].modified = false
    end
  end
end

local function final_diff(session)
  local sections = {}
  for _, file in ipairs(session.file_order or {}) do
    if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      local final_lines = normalized_final_lines(file)
      local diff = vim.diff(lines_to_text(file.original_lines or {}), lines_to_text(final_lines), {
        result_type = "unified",
        ctxlen = 2,
      })
      diff = util.trim(diff or "")
      if diff ~= "" then
        table.insert(sections, ("### %s\n```diff\n%s\n```"):format(file.relative_path, diff))
      end
    end
  end
  return table.concat(sections, "\n\n")
end

local function file_hunk_counts(file)
  local accepted = 0
  local rejected = 0
  local pending = 0
  for _, hunk in ipairs(file.hunks or {}) do
    if hunk.status == "accepted" then
      accepted = accepted + 1
    elseif hunk.status == "rejected" then
      rejected = rejected + 1
    else
      pending = pending + 1
    end
  end
  return accepted, rejected, pending
end

local function write_files(session)
  local errors = {}
  for _, file in ipairs(session.file_order or {}) do
    local bufnr = file.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local final_lines = normalized_final_lines(file)
      if same_lines(final_lines, file.original_lines or {}) then
        vim.bo[bufnr].modified = false
      elseif file.kind == "delete" and #final_lines == 0 then
        local ok, err = pcall(vim.fn.delete, file.path)
        if not ok or (err ~= 0 and err ~= nil) then
          table.insert(errors, ("delete failed for %s: %s"):format(file.relative_path, tostring(err)))
        else
          vim.bo[bufnr].modified = false
        end
      else
        local dir = vim.fn.fnamemodify(file.path, ":h")
        if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
          vim.fn.mkdir(dir, "p")
        end
        local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent write")
        end)
        if not ok then
          table.insert(errors, ("write failed for %s: %s"):format(file.relative_path, tostring(err)))
        end
      end
    end
  end
  return #errors == 0, table.concat(errors, "\n")
end

local function build_summary(session, write_error)
  local accepted = 0
  local rejected = 0
  local pending = 0
  for _, hunk in ipairs(session.hunks or {}) do
    if hunk.status == "accepted" then
      accepted = accepted + 1
    elseif hunk.status == "rejected" then
      rejected = rejected + 1
    else
      pending = pending + 1
    end
  end

  local lines = {
    "# NVIM APPLY PATCH REVIEW",
    "",
    ("accepted_hunks: %d"):format(accepted),
    ("rejected_hunks: %d"):format(rejected),
    ("pending_hunks: %d"):format(pending),
  }
  if write_error and write_error ~= "" then
    table.insert(lines, "write_error: " .. write_error)
  end
  table.insert(lines, "")
  table.insert(lines, "## FILES")
  for _, file in ipairs(session.file_order or {}) do
    local file_accepted, file_rejected, file_pending = file_hunk_counts(file)
    table.insert(
      lines,
      ("- %s: accepted=%d rejected=%d pending=%d"):format(
        file.relative_path,
        file_accepted,
        file_rejected,
        file_pending
      )
    )
  end

  if rejected > 0 then
    table.insert(lines, "")
    table.insert(lines, "## USER REJECTION FEEDBACK")
    for _, hunk in ipairs(session.hunks or {}) do
      if hunk.status == "rejected" then
        table.insert(lines, ("- %s: %s"):format(hunk_label(hunk), hunk.reason or "no reason provided"))
      end
    end
  end

  local diff = final_diff(session)
  if diff ~= "" then
    table.insert(lines, "")
    table.insert(lines, "## FINAL DIFF")
    table.insert(lines, diff)
  end

  return table.concat(lines, "\n")
end

local function cleanup(session)
  for bufnr in pairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
      active_by_buf[bufnr] = nil
      for _, lhs in pairs(keymaps) do
        pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", lhs)
      end
    end
  end
  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  end
end

local function complete(session, force_failure)
  if session.completed then
    return
  end
  session.completed = true
  local write_ok, write_error = write_files(session)
  local rejected = 0
  for _, hunk in ipairs(session.hunks or {}) do
    if hunk.status == "rejected" then
      rejected = rejected + 1
    end
  end
  local summary = build_summary(session, write_error)
  cleanup(session)
  if session.on_complete then
    session.on_complete(summary, write_ok and rejected == 0 and not force_failure)
  end
end

local function finish_after_decision(session)
  if #pending_hunks(session) == 0 then
    complete(session, false)
  else
    navigate_next(session)
  end
end

local function accept_hunk(session, hunk)
  hunk = hunk or current_hunk(session)
  if not hunk or hunk.status then
    return
  end
  hunk.status = "accepted"
  remove_hunk_marks(hunk)
  finish_after_decision(session)
end

local function reject_hunk(session, hunk, reason)
  hunk = hunk or current_hunk(session)
  if not hunk or hunk.status then
    return
  end
  local start_row, end_row = hunk_position(hunk)
  if #(hunk.new_lines or {}) == 0 then
    set_buffer_lines(hunk.bufnr, start_row, start_row, vim.deepcopy(hunk.old_lines or {}))
  else
    set_buffer_lines(hunk.bufnr, start_row, end_row, vim.deepcopy(hunk.old_lines or {}))
  end
  hunk.status = "rejected"
  hunk.reason = util.trim(reason or "") ~= "" and util.trim(reason or "") or "no reason provided"
  remove_hunk_marks(hunk)
  finish_after_decision(session)
end

local function reject_hunk_without_finish(session, hunk, reason)
  if not hunk or hunk.status then
    return
  end
  local start_row, end_row = hunk_position(hunk)
  if #(hunk.new_lines or {}) == 0 then
    set_buffer_lines(hunk.bufnr, start_row, start_row, vim.deepcopy(hunk.old_lines or {}))
  else
    set_buffer_lines(hunk.bufnr, start_row, end_row, vim.deepcopy(hunk.old_lines or {}))
  end
  hunk.status = "rejected"
  hunk.reason = util.trim(reason or "") ~= "" and util.trim(reason or "") or "no reason provided"
  remove_hunk_marks(hunk)
end

local function prompt_reject(session, hunk)
  vim.ui.input({ prompt = "Why reject this Codex patch hunk? " }, function(reason)
    reject_hunk(session, hunk, reason)
  end)
end

local function accept_all(session)
  for _, hunk in ipairs(session.hunks or {}) do
    if not hunk.status then
      hunk.status = "accepted"
      remove_hunk_marks(hunk)
    end
  end
  complete(session, false)
end

local function reject_all(session)
  vim.ui.input({ prompt = "Why reject the remaining Codex patch hunks? " }, function(reason)
    local pending = pending_hunks(session)
    for _, hunk in ipairs(pending) do
      reject_hunk_without_finish(session, hunk, reason)
    end
    complete(session, true)
  end)
end

local function cancel(session)
  vim.ui.input({ prompt = "Why cancel this Codex patch review? " }, function(reason)
    local pending = pending_hunks(session)
    for _, hunk in ipairs(pending) do
      reject_hunk_without_finish(session, hunk, reason or "patch review cancelled")
    end
    if not session.completed then
      complete(session, true)
    end
  end)
end

local function fallback(session)
  if not session.on_fallback then
    util.notify("native apply_patch fallback is not available for this patch", vim.log.levels.WARN)
    return
  end
  restore_original_files(session)
  cleanup(session)
  session.completed = true
  session.on_fallback()
end

local function setup_keymaps(session, bufnr)
  local opts = function(desc)
    return { buffer = bufnr, silent = true, desc = desc }
  end
  vim.keymap.set("n", keymaps.accept, function()
    accept_hunk(session)
  end, opts("Accept Codex patch hunk"))
  vim.keymap.set("n", keymaps.reject, function()
    prompt_reject(session, current_hunk(session))
  end, opts("Reject Codex patch hunk"))
  vim.keymap.set("n", keymaps.accept_all, function()
    accept_all(session)
  end, opts("Accept all Codex patch hunks"))
  vim.keymap.set("n", keymaps.reject_all, function()
    reject_all(session)
  end, opts("Reject all Codex patch hunks"))
  vim.keymap.set("n", keymaps.fallback, function()
    fallback(session)
  end, opts("Use native apply_patch fallback"))
  vim.keymap.set("n", keymaps.cancel, function()
    cancel(session)
  end, opts("Cancel Codex patch review"))
  vim.keymap.set("n", keymaps.next, function()
    navigate_next(session)
  end, opts("Next Codex patch hunk"))
  vim.keymap.set("n", keymaps.prev, function()
    navigate_prev(session)
  end, opts("Previous Codex patch hunk"))
end

local function setup_autocmds(session)
  session.augroup = vim.api.nvim_create_augroup("codex.patch_session." .. tostring(session.id), { clear = true })
  for bufnr in pairs(session.buffers or {}) do
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = session.augroup,
      buffer = bufnr,
      callback = function()
        update_hints(session)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufWipeout" }, {
      group = session.augroup,
      buffer = bufnr,
      callback = function()
        if not session.completed then
          complete(session, true)
        end
      end,
    })
  end
end

local function open_buffer_for_file(session, file, focus)
  local bufnr = find_buffer(file.path)
  if focus then
    local winid = target_window(session.thread)
    if winid then
      vim.api.nvim_set_current_win(winid)
    end
    vim.cmd("edit " .. vim.fn.fnameescape(file.path))
    bufnr = vim.api.nvim_get_current_buf()
  elseif not bufnr then
    bufnr = vim.fn.bufadd(file.path)
    vim.fn.bufload(bufnr)
  elseif not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  if file.is_new then
    set_buffer_lines(bufnr, 0, -1, {})
  end

  file.bufnr = bufnr
  file.original_lines = file.is_new and {} or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  session.buffers[bufnr] = true
  active_by_buf[bufnr] = session
  return bufnr
end

local function prepare_files(session)
  local focused = false
  for _, change in ipairs(session.changes or {}) do
    local path = absolute_path(session.cwd, change.path)
    if not path then
      return nil, "Patch change has no path."
    end
    local relative_path = vim.fn.fnamemodify(path, ":.")
    local file = {
      path = path,
      relative_path = relative_path,
      kind = change.kind or change.type or "update",
      is_new = vim.fn.filereadable(path) ~= 1 and (change.kind == "add" or change.type == "add"),
      change = change,
      hunks = {},
      line_offset = 0,
    }
    table.insert(session.file_order, file)
    session.files[path] = file
    local bufnr = open_buffer_for_file(session, file, not focused)
    focused = true
    if vim.bo[bufnr].modified and not file.is_new then
      return nil, "Refusing to preview patch over modified buffer: " .. relative_path
    end
  end
  return true
end

local function apply_preview_hunk(file, hunk)
  local bufnr = file.bufnr
  local start_row
  if #hunk.old_lines == 0 then
    start_row = hunk.old_start + file.line_offset
  else
    start_row = hunk.old_start + file.line_offset - 1
  end
  start_row = math.max(0, start_row)

  if not slice_matches(bufnr, start_row, hunk.old_lines) then
    local found = find_slice(bufnr, hunk.old_lines)
    if not found then
      return nil, ("Could not locate %s in %s."):format(hunk.header, file.relative_path)
    end
    start_row = found
  end

  local end_row = start_row + #hunk.old_lines
  if file.is_new and hunk.index_in_file == 1 and #hunk.old_lines == 0 then
    end_row = -1
  end

  set_buffer_lines(bufnr, start_row, end_row, vim.deepcopy(hunk.new_lines))
  hunk.bufnr = bufnr
  hunk.file = file
  hunk.applied_start_row = start_row
  hunk.applied_end_row = start_row + #hunk.new_lines
  file.line_offset = file.line_offset + (#hunk.new_lines - #hunk.old_lines)
  return true
end

local function apply_preview(session)
  local hunk_index = 0
  for _, file in ipairs(session.file_order or {}) do
    local hunks = parse_change_hunks(file.change)
    for index, hunk in ipairs(hunks) do
      hunk_index = hunk_index + 1
      hunk.index = hunk_index
      hunk.index_in_file = index
      hunk.relative_path = file.relative_path
      local ok, err = apply_preview_hunk(file, hunk)
      if not ok then
        return nil, err
      end
      table.insert(file.hunks, hunk)
      table.insert(session.hunks, hunk)
    end
  end

  for _, hunk in ipairs(session.hunks) do
    mark_hunk(hunk)
  end
  return true
end

function M.open(opts)
  opts = opts or {}
  local thread = opts.thread_id and state.get_thread(opts.thread_id) or nil
  local session = {
    id = opts.request_id or tostring(vim.uv.hrtime()),
    cwd = vim.fs.normalize(vim.fn.expand(opts.cwd or config.cwd())),
    changes = opts.changes or {},
    thread = thread,
    on_complete = opts.on_complete,
    on_fallback = opts.on_fallback,
    files = {},
    file_order = {},
    buffers = {},
    hunks = {},
    current_index = 1,
    completed = false,
  }

  local ok, err = prepare_files(session)
  if not ok then
    restore_original_files(session)
    cleanup(session)
    return nil, err
  end

  ok, err = apply_preview(session)
  if not ok then
    restore_original_files(session)
    cleanup(session)
    return nil, err
  end

  for bufnr in pairs(session.buffers) do
    setup_keymaps(session, bufnr)
  end
  setup_autocmds(session)

  if #session.hunks == 0 then
    complete(session, false)
    return session
  end

  if opts.interactive == false then
    accept_all(session)
    return session
  end

  navigate_to(session, 1)
  return session
end

function M._active_session(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return active_by_buf[bufnr]
end

M._parse_change_hunks = parse_change_hunks
M._reject_hunk = reject_hunk
M._accept_hunk = accept_hunk
M._keymaps = keymaps

return M
