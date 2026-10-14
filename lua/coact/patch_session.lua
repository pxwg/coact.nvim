local config = require("coact.config")
local context = require("coact.context")
local model = require("coact.review.model")
local review_notes = require("coact.review.notes")
local state = require("coact.state")
local util = require("coact.util")

-- In-buffer patch review. The live buffer W is the only source of truth for
-- positions: pending hunks are recomputed as diff(A, W) for the current
-- changedtick, where A is the accepted base. Extmarks only render that state.
local M = {}

local diff_ns = vim.api.nvim_create_namespace("coact.patch_session.diff")
local hint_ns = vim.api.nvim_create_namespace("coact.patch_session.hint")
local active_by_buf = {}

local default_keymaps = {
  accept = ".",
  reject = ",",
  accept_all = "ga",
  reject_all = "gr",
  auto_apply = "gA",
  cancel = "q",
  next = "n",
  prev = "p",
  help = "?",
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CoactPatchReviewHint", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewHintKey", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewHintTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewUser", { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewUserLabel", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewNote", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewBefore", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewBeforeChar", { default = true, link = "DiffText" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewAfterChar", { default = true, link = "DiffText" })
  vim.api.nvim_set_hl(0, "CoactPatchReviewDeleteMarker", { default = true, link = "DiffDelete" })
end

local function configured_keymaps()
  local edit = config.get().edit or {}
  local review = type(edit.review) == "table" and edit.review or {}
  local user_keymaps = type(review.keymaps) == "table" and review.keymaps or {}
  local resolved = vim.deepcopy(default_keymaps)
  for name, _ in pairs(default_keymaps) do
    if user_keymaps[name] ~= nil then
      local value = user_keymaps[name]
      resolved[name] = type(value) == "string" and value ~= "" and value or nil
    end
  end
  return resolved
end

local function keymap_label(session, name)
  local keymaps = session and session.keymaps or default_keymaps
  return keymaps[name] or "-"
end

local function review_config()
  local edit = config.get().edit or {}
  return type(edit.review) == "table" and edit.review or {}
end

local function diff_algorithm()
  local algorithm = review_config().diff_algorithm
  return type(algorithm) == "string" and algorithm ~= "" and algorithm or "minimal"
end

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
  for _, line in ipairs(util.split_lines(change.diff or "")) do
    local header = parse_hunk_header(line)
    if header then
      current = vim.tbl_extend("force", header, { header = line, lines = {}, old_lines = {}, new_lines = {} })
      table.insert(hunks, current)
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
      end
      -- "\ No newline at end of file" is metadata, not buffer content.
    end
  end
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

local function is_normal_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid).relative == ""
end

local function is_review_window(winid)
  if not is_normal_window(winid) then
    return false
  end
  return not context.is_coact_buffer(vim.api.nvim_win_get_buf(winid))
end

local function visible_review_window(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if is_review_window(winid) then
      return winid
    end
  end
  return nil
end

local function normal_window()
  local current = vim.api.nvim_get_current_win()
  if is_review_window(current) then
    return current
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if is_review_window(winid) then
      return winid
    end
  end
  return nil
end

local function target_window(thread)
  if thread and is_review_window(thread.context_winid) then
    return thread.context_winid
  end
  local bufnr = thread and context.target_buffer(thread) or nil
  local winid = bufnr and context.is_context_buffer(bufnr) and context.window_for_buffer(bufnr, thread) or nil
  if is_review_window(winid) then
    return winid
  end
  return normal_window()
end

local function create_review_window()
  vim.cmd("botright split")
  return vim.api.nvim_get_current_win()
end

local function review_window(session)
  if is_review_window(session.review_winid) then
    return session.review_winid
  end
  local winid = target_window(session.thread)
  if not winid then
    winid = create_review_window()
  end
  session.review_winid = winid
  return winid
end

local function review_width(bufnr)
  local width = vim.o.columns
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if is_review_window(winid) then
      width = vim.api.nvim_win_get_width(winid)
      break
    end
  end
  return math.max(32, math.min(width - 6, 132))
end

local function utf8_tokens(line)
  local tokens = {}
  line = tostring(line or "")
  local index = 1
  while index <= #line do
    local byte = line:byte(index) or 0
    local size
    if byte < 0x80 then
      size = 1
    elseif byte < 0xE0 then
      size = 2
    elseif byte < 0xF0 then
      size = 3
    elseif byte < 0xF8 then
      size = 4
    else
      size = 1
    end
    local finish = math.min(#line, index + size - 1)
    table.insert(tokens, {
      text = line:sub(index, finish),
      start_col = index - 1,
      end_col = finish,
    })
    index = finish + 1
  end
  return tokens
end

local function token_text(tokens)
  if not tokens or #tokens == 0 then
    return ""
  end
  local lines = {}
  for _, token in ipairs(tokens) do
    table.insert(lines, token.text)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function prefix_suffix_char_spans(old_tokens, new_tokens)
  local prefix = 1
  while prefix <= #old_tokens and prefix <= #new_tokens and old_tokens[prefix].text == new_tokens[prefix].text do
    prefix = prefix + 1
  end

  if prefix > #old_tokens and prefix > #new_tokens then
    return {}, {}
  end

  local old_suffix = #old_tokens
  local new_suffix = #new_tokens
  while old_suffix >= prefix and new_suffix >= prefix and old_tokens[old_suffix].text == new_tokens[new_suffix].text do
    old_suffix = old_suffix - 1
    new_suffix = new_suffix - 1
  end

  local old_spans = {}
  local new_spans = {}
  if old_suffix >= prefix and old_tokens[prefix] then
    table.insert(old_spans, {
      start_col = old_tokens[prefix].start_col,
      end_col = old_tokens[old_suffix].end_col,
    })
  end
  if new_suffix >= prefix and new_tokens[prefix] then
    table.insert(new_spans, {
      start_col = new_tokens[prefix].start_col,
      end_col = new_tokens[new_suffix].end_col,
    })
  end
  return old_spans, new_spans
end

local function line_char_spans(old_line, new_line)
  local old_tokens = utf8_tokens(old_line)
  local new_tokens = utf8_tokens(new_line)
  if #old_tokens == 0 and #new_tokens == 0 then
    return {}, {}
  end

  local ok, indices = pcall(vim.diff, token_text(old_tokens), token_text(new_tokens), {
    result_type = "indices",
  })
  if not ok or type(indices) ~= "table" then
    return prefix_suffix_char_spans(old_tokens, new_tokens)
  end

  local old_spans = {}
  local new_spans = {}
  for _, range in ipairs(indices) do
    local old_start = tonumber(range[1]) or 0
    local old_count = tonumber(range[2]) or 0
    local new_start = tonumber(range[3]) or 0
    local new_count = tonumber(range[4]) or 0
    if old_count > 0 and old_tokens[old_start] then
      local last = old_tokens[old_start + old_count - 1]
      table.insert(old_spans, {
        start_col = old_tokens[old_start].start_col,
        end_col = last and last.end_col or old_tokens[old_start].end_col,
      })
    end
    if new_count > 0 and new_tokens[new_start] then
      local last = new_tokens[new_start + new_count - 1]
      table.insert(new_spans, {
        start_col = new_tokens[new_start].start_col,
        end_col = last and last.end_col or new_tokens[new_start].end_col,
      })
    end
  end
  return old_spans, new_spans
end

local function block_char_spans(block)
  if block.old_char_spans and block.new_char_spans then
    return block.old_char_spans, block.new_char_spans
  end

  local old_spans = {}
  local new_spans = {}
  local pairs_count = math.min(#(block.old_lines or {}), #(block.new_lines or {}))
  for index = 1, pairs_count do
    old_spans[index], new_spans[index] = line_char_spans(block.old_lines[index], block.new_lines[index])
  end
  block.old_char_spans = old_spans
  block.new_char_spans = new_spans
  return old_spans, new_spans
end

local function block_char_diff_allowed(block)
  local review = review_config()
  local max_lines = math.max(0, tonumber(review.char_diff_max_lines) or 120)
  local max_line_bytes = math.max(0, tonumber(review.char_diff_max_line_bytes) or 1000)
  local max_total_bytes = math.max(0, tonumber(review.char_diff_max_total_bytes) or 20000)
  local pairs_count = math.min(#(block.old_lines or {}), #(block.new_lines or {}))
  if pairs_count == 0 or pairs_count > max_lines then
    return false
  end
  local total = 0
  for index = 1, pairs_count do
    local old_len = #(block.old_lines[index] or "")
    local new_len = #(block.new_lines[index] or "")
    if old_len > max_line_bytes or new_len > max_line_bytes then
      return false
    end
    total = total + old_len + new_len
    if total > max_total_bytes then
      return false
    end
  end
  return true
end

local function span_hl_for_col(spans, start_col, end_col)
  for _, span in ipairs(spans or {}) do
    if start_col < span.end_col and end_col > span.start_col then
      return true
    end
  end
  return false
end

local function line_chunks(prefix, line, spans, base_hl, char_hl, width)
  local virt_lines = {}
  local has_spans = spans and #spans > 0
  local prefix_width = vim.fn.strdisplaywidth(prefix)
  local available = math.max(12, width - prefix_width)
  if not has_spans and not line:find("[\128-\255]") then
    if vim.fn.strdisplaywidth(line) <= available then
      return { { { prefix, base_hl }, { line, base_hl } } }
    end
    local chunks = {}
    local index = 1
    while index <= #line do
      local part = line:sub(index, index + available - 1)
      table.insert(chunks, { { index == 1 and prefix or string.rep(" ", prefix_width), base_hl }, { part, base_hl } })
      index = index + #part
      if part == "" then
        break
      end
    end
    return chunks
  end

  local tokens = utf8_tokens(line)
  local chunks = { { prefix, base_hl } }
  local used = 0
  local current_text = ""
  local current_hl = nil

  local function flush_text()
    if current_text ~= "" then
      table.insert(chunks, { current_text, current_hl or base_hl })
      current_text = ""
    end
  end

  local function push_line()
    flush_text()
    table.insert(virt_lines, chunks)
    chunks = { { string.rep(" ", prefix_width), base_hl } }
    used = 0
    current_hl = nil
  end

  if #tokens == 0 then
    return { chunks }
  end

  for _, token in ipairs(tokens) do
    local token_width = math.max(1, vim.fn.strdisplaywidth(token.text))
    if used > 0 and used + token_width > available then
      push_line()
    end
    local hl = span_hl_for_col(spans, token.start_col, token.end_col) and char_hl or base_hl
    if current_hl ~= hl then
      flush_text()
      current_hl = hl
    end
    current_text = current_text .. token.text
    used = used + token_width
  end
  flush_text()
  table.insert(virt_lines, chunks)
  return virt_lines
end

local function set_buffer_lines(bufnr, start_row, end_row, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, lines)
end

local function lines_to_text(lines)
  if not lines or #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function content_lines(content)
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Buffer text with an empty new or deleted file normalized to zero lines.
local function buffer_lines(file)
  local lines = vim.api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
  if file.empty_is_zero and #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

local normalized_final_lines = buffer_lines

local function hunk_label(hunk)
  local path = hunk.file and hunk.file.relative_path or "patch"
  local suffix = hunk.edited and " (user-edited)" or ""
  if hunk.b_count == 0 then
    return ("%s after L%d%s"):format(path, hunk.b_start, suffix)
  elseif hunk.b_count == 1 then
    return ("%s L%d%s"):format(path, hunk.b_start, suffix)
  end
  return ("%s L%d-%d%s"):format(path, hunk.b_start, hunk.b_start + hunk.b_count - 1, suffix)
end

local function undo_seq(bufnr)
  local ok, seq = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
  return ok and tonumber(seq) or 0
end

-- Close the current undo block so the next change is undone on its own.
local function break_undo(bufnr)
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
  end)
end

-- Undo entries on the path from the root to the current state. Neovim keeps
-- the current branch as the top-level entry chain, also after :undo N jumps.
local function undo_path(bufnr)
  local ok, tree = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.undotree()
  end)
  if not ok or type(tree) ~= "table" then
    return nil, 0
  end
  local current = tonumber(tree.seq_cur) or 0
  local path, found = {}, current == 0
  if current > 0 then
    for _, entry in ipairs(tree.entries or {}) do
      path[entry.seq] = true
      if entry.seq == current then
        found = true
        break
      end
    end
  end
  if not found then
    path = {}
    for _, entry in ipairs(tree.entries or {}) do
      if entry.seq <= current then
        path[entry.seq] = true
      end
    end
  end
  return path, current
end

-- Rebuild the accepted base from approvals still on the undo path, in the
-- order they were made; each approval was relative to exactly that prefix.
local function replay_accepted(session, file)
  local lines = vim.deepcopy(file.original_lines or {})
  for _, decision in ipairs(session.decisions) do
    if decision.file == file and decision.status == "accepted" and decision.hunk and not decision.undone then
      lines = model.approve(lines, decision.hunk)
    end
  end
  file.accepted_lines = lines
end

-- Decisions are native undo steps: one that leaves the undo path is undone,
-- and redo restores it. Undo may not cross the previewed proposal.
local function sync_undo(session, file)
  local path, current = undo_path(file.bufnr)
  if not path then
    return
  end
  if file.baseline_seq and file.baseline_seq > 0 and not path[file.baseline_seq] then
    pcall(vim.api.nvim_buf_call, file.bufnr, function()
      vim.cmd("silent undo " .. file.baseline_seq)
    end)
    util.notify(
      ("Coact review: undo cannot go past the proposed patch; reject changes with %s instead."):format(
        keymap_label(session, "reject")
      ),
      vim.log.levels.WARN
    )
    path, current = undo_path(file.bufnr)
    if not path then
      return
    end
  end
  local key = current .. ":" .. #session.decisions
  if file.sync_key == key then
    return
  end
  file.sync_key = key
  for _, decision in ipairs(session.decisions) do
    if decision.file == file and decision.seq then
      decision.undone = not path[decision.seq]
    end
  end
  replay_accepted(session, file)
end

-- Pending hunks for the current changedtick, classified as agent or user.
local function refresh_file(session, file)
  if not file.bufnr or not vim.api.nvim_buf_is_valid(file.bufnr) then
    return {}
  end
  local tick = vim.api.nvim_buf_get_changedtick(file.bufnr)
  if file.cache and file.cache.tick == tick then
    return file.cache.hunks
  end
  sync_undo(session, file)
  tick = vim.api.nvim_buf_get_changedtick(file.bufnr)
  local algorithm = diff_algorithm()
  local working = buffer_lines(file)
  local hunks = model.hunks(file.accepted_lines, working, algorithm)
  local map = model.line_map(file.proposed_lines, working, algorithm)
  local marks = model.project_marks(file.agent_marks, file.proposed_lines, working, algorithm)
  local notes = model.project_notes(file.notes, map)
  for _, hunk in ipairs(hunks) do
    hunk.file = file
    hunk.bufnr = file.bufnr
    local agent, edited = model.classify(marks, hunk)
    hunk.origin = agent and "agent" or "user"
    hunk.edited = edited
    hunk.notes = hunk.origin == "agent" and model.notes_for(notes, hunk) or {}
  end
  file.cache = { tick = tick, hunks = hunks }
  return hunks
end

local function agent_hunks(session, file)
  local out = {}
  for _, hunk in ipairs(refresh_file(session, file)) do
    if hunk.origin == "agent" then
      table.insert(out, hunk)
    end
  end
  return out
end

local function pending_hunks(session)
  local out = {}
  if session.completed then
    return out
  end
  for _, file in ipairs(session.file_order or {}) do
    vim.list_extend(out, agent_hunks(session, file))
  end
  return out
end

local function file_for_buf(session, bufnr)
  for _, file in ipairs(session.file_order or {}) do
    if file.bufnr == bufnr then
      return file
    end
  end
  return nil
end

local function cursor_line(bufnr)
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    winid = visible_review_window(bufnr)
  end
  if not winid then
    return nil
  end
  return vim.api.nvim_win_get_cursor(winid)[1]
end

-- The pending agent hunk nearest the cursor in bufnr.
local function target_hunk(session, bufnr)
  local file = file_for_buf(session, bufnr)
  local line = file and cursor_line(bufnr) or nil
  if not line then
    return nil
  end
  return model.nearest(agent_hunks(session, file), line)
end

-- Where virtual lines describing a hunk attach: above its first line, or for
-- a deletion above the following line (below the last line at end of file).
local function hunk_anchor(hunk)
  local line_count = vim.api.nvim_buf_line_count(hunk.bufnr)
  local row = hunk.b_count > 0 and hunk.b_start - 1 or hunk.b_start
  if row >= line_count then
    return math.max(0, line_count - 1), false
  end
  return math.max(0, row), true
end

local function wrap_text(prefix, text, hl, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
    vim.list_extend(out, line_chunks(prefix, paragraph, nil, hl, hl, width))
    prefix = string.rep(" ", vim.fn.strdisplaywidth(prefix))
  end
  return out
end

local function note_summary(notes, width)
  local first = vim.split(notes[1] or "", "\n", { plain = true })[1] or ""
  local more = #notes > 1 or #vim.split(notes[1] or "", "\n", { plain = true }) > 1
  local text = first .. (more and " …" or "")
  local max = math.max(12, width - 4)
  if vim.fn.strdisplaywidth(text) > max then
    text = vim.fn.strcharpart(text, 0, max - 1) .. "…"
  end
  return { { { "✎ ", "CoactPatchReviewNote" }, { text, "CoactPatchReviewNote" } } }
end

local function old_virtual_lines(hunk, width, detailed)
  local virt_lines = {}
  if #hunk.old_lines == 0 then
    return virt_lines
  end
  local title = hunk.origin == "user" and ("before your edit %s"):format(hunk_label(hunk))
    or ("before %s"):format(hunk_label(hunk))
  table.insert(virt_lines, { { title, "CoactPatchReviewHintTitle" } })
  local old_spans = detailed and block_char_spans(hunk) or {}
  for index, line in ipairs(hunk.old_lines) do
    vim.list_extend(
      virt_lines,
      line_chunks("- ", line, old_spans[index], "CoactPatchReviewBefore", "CoactPatchReviewBeforeChar", width)
    )
  end
  return virt_lines
end

local function mark_new_char_spans(hunk)
  local _, new_spans = block_char_spans(hunk)
  for line_index, spans in pairs(new_spans or {}) do
    local row = hunk.b_start + line_index - 2
    for _, span in ipairs(spans or {}) do
      if span.end_col > span.start_col then
        vim.api.nvim_buf_set_extmark(hunk.bufnr, diff_ns, row, span.start_col, {
          end_row = row,
          end_col = span.end_col,
          hl_group = "CoactPatchReviewAfterChar",
          hl_mode = "combine",
          priority = 20002,
          strict = false,
        })
      end
    end
  end
end

local function render_hunk(hunk, detailed, width)
  local bufnr = hunk.bufnr
  local agent = hunk.origin == "agent"
  if hunk.b_count > 0 then
    hunk.display_mark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, hunk.b_start - 1, 0, {
      end_row = hunk.b_start - 1 + hunk.b_count,
      hl_group = agent and "CoactPatchReviewAdd" or "CoactPatchReviewUser",
      hl_eol = true,
      hl_mode = "combine",
      priority = 20000,
      strict = false,
    })
    if detailed then
      mark_new_char_spans(hunk)
    end
  else
    local row = hunk_anchor(hunk)
    local count = #hunk.old_lines
    hunk.display_mark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, row, 0, {
      virt_text = {
        { ("[- deleted %d line%s]"):format(count, count == 1 and "" or "s"), "CoactPatchReviewDeleteMarker" },
      },
      virt_text_pos = "eol",
      priority = 20000,
    })
  end
  if not agent or hunk.edited then
    local first = hunk.b_count > 0 and hunk.b_start - 1 or hunk_anchor(hunk)
    vim.api.nvim_buf_set_extmark(bufnr, diff_ns, first, 0, {
      virt_text = { { agent and " agent + edited" or " user edit", "CoactPatchReviewUserLabel" } },
      virt_text_pos = "eol",
      priority = 19998,
    })
  end
  local virt_lines = {}
  if agent and #hunk.notes > 0 and not detailed then
    vim.list_extend(virt_lines, note_summary(hunk.notes, width))
  end
  vim.list_extend(virt_lines, old_virtual_lines(hunk, width, detailed))
  if #virt_lines > 0 then
    local row, above = hunk_anchor(hunk)
    hunk.old_mark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = above,
      priority = detailed and 20004 or 19999,
    })
  end
end

local function review_hint_lines(session, hunk, width)
  local pending = #pending_hunks(session)
  local lines = {
    {
      { "Coact Review", "CoactPatchReviewHintTitle" },
      { "  " .. hunk_label(hunk), "CoactPatchReviewHint" },
      { ("  %d pending"):format(pending), "CoactPatchReviewHint" },
    },
  }
  local current = {}
  local function push_action(name, label)
    local key = keymap_label(session, name)
    if key == "-" then
      return
    end
    local action = {
      { key, "CoactPatchReviewHintKey" },
      { " " .. label .. "  ", "CoactPatchReviewHint" },
    }
    local used = 0
    for _, chunk in ipairs(current) do
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    if #current > 0 and used + vim.fn.strdisplaywidth(key .. " " .. label .. "  ") > width then
      table.insert(lines, current)
      current = {}
    end
    vim.list_extend(current, action)
  end
  push_action("accept", "approve/comment")
  push_action("reject", "reject")
  push_action("next", "next")
  push_action("prev", "prev")
  push_action("accept_all", "approve rest")
  push_action("reject_all", "reject rest")
  if session.on_auto_apply then
    push_action("auto_apply", "auto")
  end
  push_action("cancel", "cancel")
  push_action("help", "help")
  if #current > 0 then
    table.insert(lines, current)
  end
  for _, note in ipairs(hunk.notes or {}) do
    vim.list_extend(lines, wrap_text("✎ ", note, "CoactPatchReviewNote", width))
  end
  return lines
end

local review_window_option_names = {
  "wrap",
  "linebreak",
  "breakindent",
  "foldenable",
}

local function apply_review_window_options(session, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  session.window_options = session.window_options or {}
  if not session.window_options[winid] then
    local stored = {}
    for _, name in ipairs(review_window_option_names) do
      stored[name] = vim.wo[winid][name]
    end
    session.window_options[winid] = stored
  end
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].breakindent = true
  vim.wo[winid].foldenable = false
end

local function restore_review_window_options(session)
  for winid, options in pairs(session.window_options or {}) do
    if vim.api.nvim_win_is_valid(winid) then
      for name, value in pairs(options) do
        pcall(function()
          vim.wo[winid][name] = value
        end)
      end
    end
  end
end

-- Redraw a file when its text, cursor target, or width changed.
local function render_file(session, file, force)
  local bufnr = file.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local hunks = refresh_file(session, file)
  local target = target_hunk(session, bufnr)
  local width = review_width(bufnr)
  local key = table.concat({ file.cache.tick, target and target.lo or "-", width, #session.decisions }, ":")
  if not force and file.render_key == key then
    return
  end
  file.render_key = key
  vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
  for _, hunk in ipairs(hunks) do
    render_hunk(hunk, hunk == target and block_char_diff_allowed(hunk), width)
  end
  if target then
    local row, above = hunk_anchor(target)
    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, row, 0, {
      virt_lines = review_hint_lines(session, target, width),
      virt_lines_above = above,
      priority = 20003,
    })
  end
end

local function render(session, force)
  if session.completed then
    return
  end
  for _, file in ipairs(session.file_order or {}) do
    render_file(session, file, force)
  end
  -- Edits may leave only user-owned hunks; say how to finish.
  local bufnr = vim.api.nvim_get_current_buf()
  local file = file_for_buf(session, bufnr)
  if file and #pending_hunks(session) == 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, 0, 0, {
      virt_lines = {
        {
          { "Coact Review", "CoactPatchReviewHintTitle" },
          { "  no pending agent changes  ", "CoactPatchReviewHint" },
          { keymap_label(session, "accept"), "CoactPatchReviewHintKey" },
          { " finish and keep your edits", "CoactPatchReviewHint" },
        },
      },
      virt_lines_above = true,
      priority = 20003,
    })
    file.render_key = nil
  end
end

local function schedule_render(session)
  if session.render_scheduled then
    return
  end
  session.render_scheduled = true
  vim.schedule(function()
    session.render_scheduled = false
    render(session, false)
  end)
end

local function ensure_hunk_window(session, hunk)
  local winid = visible_review_window(hunk.bufnr) or review_window(session)
  vim.api.nvim_set_current_win(winid)
  if vim.api.nvim_win_get_buf(winid) ~= hunk.bufnr then
    vim.api.nvim_win_set_buf(winid, hunk.bufnr)
  end
  apply_review_window_options(session, winid)
  return winid
end

local function jump_to(session, hunk)
  if not hunk or session.completed or not vim.api.nvim_buf_is_valid(hunk.bufnr) then
    return false
  end
  local winid = ensure_hunk_window(session, hunk)
  local line_count = vim.api.nvim_buf_line_count(hunk.bufnr)
  local line = hunk.b_count > 0 and hunk.b_start or hunk.b_start + 1
  vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(line_count, line)), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zvzz")
  end)
  render(session, false)
  return true
end

local function file_index(session, file)
  for index, candidate in ipairs(session.file_order or {}) do
    if candidate == file then
      return index
    end
  end
  return 0
end

-- Next or previous pending agent hunk relative to a (file, point) position.
local function adjacent_hunk(session, file, point, direction)
  local pending = pending_hunks(session)
  if #pending == 0 then
    return nil
  end
  local origin = file and file_index(session, file) or 0
  local function after(hunk)
    local index = file_index(session, hunk.file)
    return index > origin or (index == origin and hunk.lo > point)
  end
  local function before(hunk)
    local index = file_index(session, hunk.file)
    return index < origin or (index == origin and hunk.hi < point)
  end
  if direction > 0 then
    for _, hunk in ipairs(pending) do
      if after(hunk) then
        return hunk
      end
    end
    return pending[1]
  end
  for index = #pending, 1, -1 do
    if before(pending[index]) then
      return pending[index]
    end
  end
  return pending[#pending]
end

local function cursor_position(session)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = file_for_buf(session, bufnr)
  if not file then
    return nil, 0
  end
  return file, 2 * vim.api.nvim_win_get_cursor(0)[1] - 1
end

local function navigate(session, direction)
  if session.completed then
    return false
  end
  local file, point = cursor_position(session)
  return jump_to(session, adjacent_hunk(session, file, point, direction))
end

local function restore_original_files(session)
  for _, file in pairs(session.files or {}) do
    if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      set_buffer_lines(file.bufnr, 0, -1, vim.deepcopy(file.original_lines or {}))
      vim.bo[file.bufnr].modified = false
    end
  end
end

local function file_diff(old_lines, new_lines)
  local diff = vim.diff(lines_to_text(old_lines), lines_to_text(new_lines), {
    result_type = "unified",
    ctxlen = 2,
  })
  return util.trim(diff or "")
end

local function final_diff(session)
  local sections = {}
  for _, file in ipairs(session.file_order or {}) do
    if type(file.final_lines) == "table" then
      local diff = file_diff(file.original_lines or {}, file.final_lines)
      if diff ~= "" then
        table.insert(sections, ("### %s\n```diff\n%s\n```"):format(file.relative_path, diff))
      end
    end
  end
  return table.concat(sections, "\n\n")
end

local function proposal_delta_diff(session)
  local sections = {}
  for _, file in ipairs(session.file_order or {}) do
    if type(file.proposed_lines) == "table" and type(file.final_lines) == "table" then
      local diff = file_diff(file.proposed_lines, file.final_lines)
      if diff ~= "" then
        table.insert(sections, ("### %s\n```diff\n%s\n```"):format(file.relative_path, diff))
      end
    end
  end
  return table.concat(sections, "\n\n")
end

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function diagnostics_summary(session)
  local sections = {}
  for _, file in ipairs(session.file_order or {}) do
    local bufnr = file.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local diagnostics = vim.diagnostic.get(bufnr)
      if #diagnostics > 0 then
        table.sort(diagnostics, function(a, b)
          if a.lnum == b.lnum then
            return (a.col or 0) < (b.col or 0)
          end
          return (a.lnum or 0) < (b.lnum or 0)
        end)
        table.insert(sections, "### " .. file.relative_path)
        for _, diagnostic in ipairs(diagnostics) do
          local severity = severity_names[diagnostic.severity] or "INFO"
          local source = diagnostic.source and diagnostic.source ~= "" and (" [" .. diagnostic.source .. "]") or ""
          table.insert(
            sections,
            ("- L%d:C%d %s%s %s"):format(
              (diagnostic.lnum or 0) + 1,
              (diagnostic.col or 0) + 1,
              severity,
              source,
              tostring(diagnostic.message or "")
            )
          )
        end
      end
    end
  end
  if #sections == 0 then
    return "No diagnostics in edited buffers."
  end
  return table.concat(sections, "\n")
end

local function decision_counts(session, file)
  local counts = { accepted = 0, rejected = 0, user = 0 }
  for _, decision in ipairs(session.decisions or {}) do
    if (not file or decision.file == file) and not decision.undone then
      counts[decision.status] = (counts[decision.status] or 0) + 1
    end
  end
  return counts
end

local function write_files(session)
  local errors = {}
  for _, file in ipairs(session.file_order or {}) do
    local bufnr = file.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local final_lines = normalized_final_lines(file)
      if model.same_lines(final_lines, file.original_lines or {}) then
        vim.bo[bufnr].modified = false
      elseif file.kind == "delete" and #final_lines == 0 then
        local ok, err = pcall(vim.fn.delete, file.path)
        if not ok or (err ~= 0 and err ~= nil) then
          table.insert(errors, ("delete failed for %s: %s"):format(file.relative_path, tostring(err)))
        else
          vim.bo[bufnr].modified = false
        end
      elseif file.change and file.change.move_path then
        local dest = absolute_path(session.cwd, file.change.move_path)
        local dest_label = dest and vim.fn.fnamemodify(dest, ":.") or tostring(file.change.move_path)
        if not dest then
          table.insert(errors, ("move failed for %s: missing destination"):format(file.relative_path))
        else
          local dir = vim.fn.fnamemodify(dest, ":h")
          if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, "p")
          end
          local ok, err = pcall(vim.fn.writefile, final_lines, dest)
          if not ok or (err ~= 0 and err ~= nil) then
            table.insert(errors, ("write failed for %s: %s"):format(dest_label, tostring(err)))
          else
            if vim.fs.normalize(dest) ~= vim.fs.normalize(file.path) then
              ok, err = pcall(vim.fn.delete, file.path)
              if not ok or (err ~= 0 and err ~= nil) then
                table.insert(errors, ("delete failed for %s: %s"):format(file.relative_path, tostring(err)))
              end
            end
            vim.bo[bufnr].modified = false
          end
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

local function diagnostics_settle_ms(session)
  if session.diagnostics_settle_ms ~= nil then
    return math.max(0, tonumber(session.diagnostics_settle_ms) or 0)
  end
  local edit = config.get().edit or {}
  return math.max(0, tonumber(edit.diagnostics_settle_ms) or 0)
end

local function has_lsp_client(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.lsp) then
    return false
  end
  if vim.lsp.get_clients then
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end
  if vim.lsp.get_active_clients then
    return #vim.lsp.get_active_clients({ bufnr = bufnr }) > 0
  end
  return false
end

local function wait_for_fresh_diagnostics(session)
  local timeout = diagnostics_settle_ms(session)
  if timeout <= 0 then
    return
  end

  local watched = {}
  for bufnr in pairs(session.buffers or {}) do
    if has_lsp_client(bufnr) then
      table.insert(watched, bufnr)
    end
  end
  if #watched == 0 then
    return
  end

  local changed = false
  local group =
    vim.api.nvim_create_augroup("coact.patch_session.diagnostics." .. tostring(session.id), { clear = true })
  for _, bufnr in ipairs(watched) do
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = group,
      buffer = bufnr,
      callback = function()
        changed = true
      end,
    })
  end
  pcall(vim.cmd, "silent! checktime")
  vim.wait(timeout, function()
    return changed
  end, 25)
  pcall(vim.api.nvim_del_augroup_by_id, group)
end

local function approval_comment(value)
  local comment = util.trim(value or "")
  return comment ~= "" and comment or nil
end

local function build_summary(session, write_error)
  local counts = decision_counts(session)
  local lines = {
    "# NVIM APPLY PATCH REVIEW",
    "",
    ("accepted_blocks: %d"):format(counts.accepted),
    ("rejected_blocks: %d"):format(counts.rejected),
    ("pending_blocks: %d"):format(session.pending_blocks or 0),
    ("user_edit_blocks: %d"):format(counts.user),
  }
  if write_error and write_error ~= "" then
    table.insert(lines, "write_error: " .. write_error)
  end
  table.insert(lines, "")
  table.insert(lines, "## FILES")
  for _, file in ipairs(session.file_order or {}) do
    local file_counts = decision_counts(session, file)
    table.insert(
      lines,
      ("- %s: accepted=%d rejected=%d pending=%d user_edits=%d"):format(
        file.relative_path,
        file_counts.accepted,
        file_counts.rejected,
        file.pending_at_completion or 0,
        file_counts.user
      )
    )
  end

  local approval_comments = {}
  local rejections = {}
  local edited_approvals = {}
  for _, decision in ipairs(session.decisions or {}) do
    if not decision.undone and decision.status == "accepted" and decision.edited then
      table.insert(edited_approvals, "- " .. decision.label)
    end
    if not decision.undone then
      if decision.status == "accepted" and decision.comment then
        table.insert(approval_comments, ("- %s: %s"):format(decision.label, decision.comment))
      elseif decision.status == "rejected" then
        table.insert(rejections, ("- %s: %s"):format(decision.label, decision.reason))
      end
    end
  end
  if #approval_comments > 0 then
    table.insert(lines, "")
    table.insert(lines, "## USER APPROVAL COMMENTS")
    vim.list_extend(lines, approval_comments)
  end
  if #rejections > 0 then
    table.insert(lines, "")
    table.insert(lines, "## USER REJECTION FEEDBACK")
    vim.list_extend(lines, rejections)
  end
  if #edited_approvals > 0 then
    table.insert(lines, "")
    table.insert(lines, "## APPROVED AFTER USER EDITS")
    table.insert(lines, "The user changed these proposed hunks before approving them; see the modifications below.")
    vim.list_extend(lines, edited_approvals)
  end

  local proposal_delta = proposal_delta_diff(session)
  if proposal_delta ~= "" then
    table.insert(lines, "")
    table.insert(lines, "## USER MODIFICATIONS TO CODEX PROPOSAL")
    table.insert(lines, "Diff from Codex's previewed patch result to the final Neovim-reviewed buffer state.")
    table.insert(lines, proposal_delta)
  end

  local diff = final_diff(session)
  if diff ~= "" then
    table.insert(lines, "")
    table.insert(lines, "## FINAL DIFF")
    table.insert(lines, diff)
  end

  table.insert(lines, "")
  table.insert(lines, "## nvim.diagnostics")
  table.insert(lines, diagnostics_summary(session))

  return table.concat(lines, "\n")
end

local function cleanup(session)
  for bufnr in pairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
      active_by_buf[bufnr] = nil
      for _, lhs in pairs(session.keymaps or {}) do
        if lhs then
          pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", lhs)
        end
      end
      for _, name in ipairs({ "accept", "reject" }) do
        local lhs = session.keymaps and session.keymaps[name]
        if lhs then
          pcall(vim.api.nvim_buf_del_keymap, bufnr, "x", lhs)
        end
      end
    end
  end
  restore_review_window_options(session)
  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  end
  if session.write_guard then
    pcall(vim.api.nvim_del_augroup_by_id, session.write_guard)
    session.write_guard = nil
  end
end

local function complete(session, force_failure)
  if session.completed then
    return
  end
  -- Remaining user-owned hunks are the user's own edits: accept them.
  local pending = 0
  for _, file in ipairs(session.file_order or {}) do
    file.pending_at_completion = 0
    local hunks = refresh_file(session, file)
    -- Bottom-up keeps earlier base line numbers valid while approving.
    for index = #hunks, 1, -1 do
      local hunk = hunks[index]
      if hunk.origin == "user" then
        table.insert(session.decisions, { status = "user", file = file, label = hunk_label(hunk) })
        file.accepted_lines = model.approve(file.accepted_lines, hunk)
      else
        file.pending_at_completion = file.pending_at_completion + 1
        pending = pending + 1
      end
    end
  end
  session.completed = true
  session.force_failure = force_failure == true
  if session.write_guard then
    pcall(vim.api.nvim_del_augroup_by_id, session.write_guard)
    session.write_guard = nil
  end
  local write_ok, write_error = true, nil
  if session.apply_on_complete ~= false then
    write_ok, write_error = write_files(session)
  end
  wait_for_fresh_diagnostics(session)
  session.write_ok = write_ok
  session.write_error = write_error
  local counts = decision_counts(session)
  session.accepted_blocks = counts.accepted
  session.rejected_blocks = counts.rejected
  session.pending_blocks = pending
  session.user_blocks = counts.user
  session.accepted_hunks = counts.accepted
  session.rejected_hunks = counts.rejected
  session.partial_hunks = 0
  session.pending_hunks = pending
  for _, file in ipairs(session.file_order or {}) do
    if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
      file.final_lines = normalized_final_lines(file)
    end
  end
  local summary = build_summary(session, write_error)
  session.summary = summary
  local success = write_ok and counts.rejected == 0 and not force_failure
  if session.restore_on_complete == true then
    restore_original_files(session)
  end
  cleanup(session)
  if session.on_complete then
    session.on_complete(summary, success, session)
  end
end

-- Decisions resolve the snapshot against hunks for the current changedtick
-- first, so they act on content rather than on positions captured earlier.
local function resolve(session, snapshot)
  if session.completed or not snapshot or not snapshot.file then
    return nil
  end
  return model.resolve(refresh_file(session, snapshot.file), snapshot)
end

local function approve_hunk(session, snapshot, comment)
  local hunk = resolve(session, snapshot)
  if not hunk then
    return nil
  end
  table.insert(session.decisions, {
    status = "accepted",
    file = hunk.file,
    label = hunk_label(hunk),
    comment = approval_comment(comment),
    origin = hunk.origin,
    edited = hunk.edited,
    hunk = { a_start = hunk.a_start, a_count = hunk.a_count, new_lines = vim.deepcopy(hunk.new_lines) },
  })
  -- Rewrite one line unchanged so the approval is a native undo step.
  local row = hunk_anchor(hunk)
  set_buffer_lines(hunk.bufnr, row, row + 1, vim.api.nvim_buf_get_lines(hunk.bufnr, row, row + 1, false))
  hunk.file.cache = nil
  return hunk
end

local function reject_hunk_now(session, snapshot, reason)
  local hunk = resolve(session, snapshot)
  if not hunk then
    return nil
  end
  local start_row, end_row = model.buffer_range(hunk)
  set_buffer_lines(hunk.bufnr, start_row, end_row, vim.deepcopy(hunk.old_lines))
  hunk.file.cache = nil
  reason = util.trim(reason or "")
  table.insert(session.decisions, {
    status = "rejected",
    file = hunk.file,
    label = hunk_label(hunk),
    reason = reason ~= "" and reason or "no reason provided",
    origin = hunk.origin,
  })
  return hunk
end

-- Apply decisions as one undo step and stamp them with its sequence number.
-- actions: list of { accept = boolean, hunk = snapshot, text = comment/reason }.
local function decide(session, actions)
  local buffers = {}
  for _, action in ipairs(actions) do
    if action.hunk and action.hunk.bufnr then
      buffers[action.hunk.bufnr] = true
    end
  end
  for bufnr in pairs(buffers) do
    break_undo(bufnr)
  end
  local first = #session.decisions + 1
  local decided, missing = nil, false
  for _, action in ipairs(actions) do
    local hunk
    if action.accept then
      hunk = approve_hunk(session, action.hunk, action.text)
    else
      hunk = reject_hunk_now(session, action.hunk, action.text)
    end
    decided = hunk or decided
    missing = missing or not hunk
  end
  for bufnr in pairs(buffers) do
    break_undo(bufnr)
  end
  for index = first, #session.decisions do
    local decision = session.decisions[index]
    decision.seq = undo_seq(decision.file.bufnr)
  end
  return decided, missing
end

local function stale_notice()
  util.notify("Coact review: that change was edited meanwhile; review it again.", vim.log.levels.WARN)
end

local function finish_after_decision(session, decided)
  if session.completed then
    return
  end
  if #pending_hunks(session) == 0 then
    complete(session, false)
    return
  end
  local next_hunk = adjacent_hunk(session, decided and decided.file, decided and decided.lo - 1 or 0, 1)
  if not jump_to(session, next_hunk) then
    render(session, false)
  end
end

local function accept_block(session, block, comment)
  if session.completed then
    return
  end
  block = block or target_hunk(session, vim.api.nvim_get_current_buf())
  if not block and #pending_hunks(session) == 0 then
    complete(session, false)
    return
  end
  local decided = decide(session, { { accept = true, hunk = block, text = comment } })
  if decided then
    finish_after_decision(session, decided)
  end
end

local function reject_block(session, block, reason)
  if session.completed then
    return
  end
  block = block or target_hunk(session, vim.api.nvim_get_current_buf())
  if not block and #pending_hunks(session) == 0 then
    complete(session, false)
    return
  end
  local decided = decide(session, { { accept = false, hunk = block, text = reason } })
  if decided then
    finish_after_decision(session, decided)
  end
end

-- Targets for an action: the hunks touching a visual range, or the pending
-- hunk nearest the cursor. Without one, finish or move to the next change.
local function action_targets(session, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = file_for_buf(session, bufnr)
  if range and file then
    local lo, hi = 2 * range[1] - 2, 2 * range[2]
    local out = {}
    for _, hunk in ipairs(agent_hunks(session, file)) do
      if hunk.lo <= hi and hunk.hi >= lo then
        table.insert(out, hunk)
      end
    end
    return out
  end
  local hunk = target_hunk(session, bufnr)
  return hunk and { hunk } or {}
end

local function no_target(session)
  if #pending_hunks(session) == 0 then
    complete(session, false)
    return
  end
  util.notify("Coact review: moved to the next pending change.", vim.log.levels.INFO)
  navigate(session, 1)
end

local function prompt_decision(session, range, accept)
  if session.completed then
    return
  end
  local targets = action_targets(session, range)
  if #targets == 0 then
    no_target(session)
    return
  end
  local noun = #targets == 1 and "this Coact change" or ("these %d Coact changes"):format(#targets)
  local prompt = accept and ("Approval comment for %s (optional): "):format(noun) or ("Why reject %s? "):format(noun)
  vim.ui.input({ prompt = prompt }, function(input)
    if input == nil or session.completed then
      return
    end
    local actions = {}
    for index = #targets, 1, -1 do
      table.insert(actions, { accept = accept, hunk = targets[index], text = input })
    end
    local decided, missing = decide(session, actions)
    if missing then
      stale_notice()
    end
    if decided then
      finish_after_decision(session, decided)
    end
  end)
end

local function accept_all(session, comment)
  local actions = {}
  for _, hunk in ipairs(pending_hunks(session)) do
    table.insert(actions, { accept = true, hunk = hunk, text = comment })
  end
  decide(session, actions)
  complete(session, false)
end

local function reject_pending(session, reason)
  local pending = pending_hunks(session)
  local actions = {}
  for index = #pending, 1, -1 do
    table.insert(actions, { accept = false, hunk = pending[index], text = reason })
  end
  decide(session, actions)
end

local function prompt_accept_all(session)
  if #pending_hunks(session) == 0 then
    complete(session, false)
    return
  end
  vim.ui.input({ prompt = "Approval comment for remaining Coact changes (optional): " }, function(comment)
    if comment == nil or session.completed then
      return
    end
    accept_all(session, comment)
  end)
end

local function reject_all(session)
  vim.ui.input({ prompt = "Why reject the remaining Coact changes? " }, function(reason)
    if reason == nil or session.completed then
      return
    end
    reject_pending(session, reason)
    complete(session, true)
  end)
end

local function cancel(session)
  vim.ui.input({ prompt = "Why cancel this Coact patch review? " }, function(reason)
    if reason == nil or session.completed then
      return
    end
    reject_pending(session, reason ~= "" and reason or "patch review cancelled")
    complete(session, true)
  end)
end

local function auto_apply(session)
  if session.on_auto_apply then
    local ok, err = pcall(session.on_auto_apply)
    if not ok then
      util.notify("Neovim auto-apply setup failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  accept_all(session)
end

local function show_help(session)
  local lines = {
    "Coact Patch Review",
    "",
    ("  %s  approve the change nearest the cursor"):format(keymap_label(session, "accept")),
    ("  %s  reject the change nearest the cursor"):format(keymap_label(session, "reject")),
    "     (visual mode: every change in the selection)",
    ("  %s  next pending change"):format(keymap_label(session, "next")),
    ("  %s  previous pending change"):format(keymap_label(session, "prev")),
    ("  %s  approve remaining changes with a comment"):format(keymap_label(session, "accept_all")),
    ("  %s  reject remaining changes"):format(keymap_label(session, "reject_all")),
    ("  %s  cancel review"):format(keymap_label(session, "cancel")),
    "",
    "Edit freely: changes are recomputed from the buffer.",
    "Your own edits are marked 'user edit' and accepted at the end.",
  }
  if session.on_auto_apply then
    table.insert(
      lines,
      11,
      ("  %s  auto-apply future nvim.apply_patch calls"):format(keymap_label(session, "auto_apply"))
    )
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local width = math.min(64, math.max(36, vim.o.columns - 8))
  local height = math.min(#lines, math.max(8, vim.o.lines - 6))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "single",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Coact Review Keys ",
    title_pos = "center",
  })
  local close = function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, desc = "Close Coact review help" })
  vim.keymap.set("n", "?", close, { buffer = bufnr, silent = true, desc = "Close Coact review help" })
end

local function visual_range()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return { math.min(first, last), math.max(first, last) }
end

local function setup_keymaps(session, bufnr)
  local set = function(name, callback, desc, mode)
    local lhs = session.keymaps and session.keymaps[name] or nil
    if lhs then
      vim.keymap.set(mode or "n", lhs, callback, { buffer = bufnr, silent = true, desc = desc })
    end
  end
  set("accept", function()
    prompt_decision(session, nil, true)
  end, "Approve the Coact change nearest the cursor")
  set("reject", function()
    prompt_decision(session, nil, false)
  end, "Reject the Coact change nearest the cursor")
  set("accept", function()
    prompt_decision(session, visual_range(), true)
  end, "Approve Coact changes in the selection", "x")
  set("reject", function()
    prompt_decision(session, visual_range(), false)
  end, "Reject Coact changes in the selection", "x")
  set("accept_all", function()
    prompt_accept_all(session)
  end, "Approve all Coact changes with comment")
  set("reject_all", function()
    reject_all(session)
  end, "Reject all Coact changes")
  if session.on_auto_apply then
    set("auto_apply", function()
      auto_apply(session)
    end, "Use Neovim auto-apply for this session")
  end
  set("cancel", function()
    cancel(session)
  end, "Cancel Coact patch review")
  set("next", function()
    navigate(session, 1)
  end, "Next Coact change")
  set("prev", function()
    navigate(session, -1)
  end, "Previous Coact change")
  set("help", function()
    show_help(session)
  end, "Show Coact patch review keys")
end

local function setup_autocmds(session)
  session.augroup = vim.api.nvim_create_augroup("coact.patch_session." .. tostring(session.id), { clear = true })
  session.write_guard =
    vim.api.nvim_create_augroup("coact.patch_session.write." .. tostring(session.id), { clear = true })
  for bufnr in pairs(session.buffers or {}) do
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      group = session.augroup,
      buffer = bufnr,
      callback = function()
        schedule_render(session)
      end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = session.augroup,
      buffer = bufnr,
      callback = function()
        apply_review_window_options(session, visible_review_window(bufnr))
        render(session, false)
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
    -- Unreviewed proposals must not reach disk through :write.
    vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
      group = session.write_guard,
      buffer = bufnr,
      callback = function()
        util.notify(
          ("Coact review in progress: finish it (%s / %s) before writing this buffer."):format(
            keymap_label(session, "accept"),
            keymap_label(session, "reject")
          ),
          vim.log.levels.ERROR
        )
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinResized", {
    group = session.augroup,
    callback = function()
      render(session, true)
    end,
  })
end

local function open_buffer_for_file(session, file, focus)
  local bufnr = find_buffer(file.path)
  if focus then
    local winid = visible_review_window(bufnr)
    if not winid then
      winid = review_window(session)
    end
    vim.api.nvim_set_current_win(winid)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_win_set_buf(winid, bufnr)
    else
      vim.cmd("edit " .. vim.fn.fnameescape(file.path))
      bufnr = vim.api.nvim_get_current_buf()
    end
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
  local focused = not session.interactive
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

local function comparable(lines)
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

local function proposed_lines(file)
  if type(file.change.new_content) == "string" then
    -- Full contents are only trusted against the text they were derived from.
    if
      type(file.change.old_content) == "string"
      and not model.same_lines(comparable(content_lines(file.change.old_content)), comparable(file.original_lines))
    then
      return nil, ("%s changed since the proposal was made; read it again before retrying."):format(file.relative_path)
    end
    return content_lines(file.change.new_content)
  end
  local hunks = parse_change_hunks(file.change)
  local lines, err, hunk = model.apply_hunks(file.original_lines, hunks)
  if not lines then
    local why = err == "ambiguous" and "matches several places; add more context" or "does not match the file"
    return nil, ("Could not locate %s in %s: hunk %s."):format(hunk and hunk.header or "hunk", file.relative_path, why)
  end
  return lines
end

-- Write P into the buffer as minimal splices, bottom-up, so unrelated lines
-- keep their marks, then record the undo baseline the review must not cross.
local function apply_preview(session)
  local algorithm = diff_algorithm()
  for _, file in ipairs(session.file_order or {}) do
    local proposed, err = proposed_lines(file)
    if not proposed then
      return nil, err
    end
    local base = file.original_lines
    file.empty_is_zero = #base == 0 or #proposed == 0 or file.kind == "delete"
    local current = buffer_lines(file)
    break_undo(file.bufnr)
    if #current == 0 or #proposed == 0 then
      set_buffer_lines(file.bufnr, 0, -1, vim.deepcopy(proposed))
    else
      local ranges = model.indices(current, proposed, algorithm)
      for index = #ranges, 1, -1 do
        local range = ranges[index]
        local start_row = range[2] > 0 and range[1] - 1 or range[1]
        local replacement = {}
        for line = range[3], range[3] + range[4] - 1 do
          table.insert(replacement, proposed[line])
        end
        set_buffer_lines(file.bufnr, start_row, start_row + range[2], replacement)
      end
    end
    file.proposed_lines = proposed
    file.accepted_lines = vim.deepcopy(base)
    file.agent_marks = model.agent_marks(base, proposed, algorithm)
    local raw_notes = type(file.change.notes) == "table" and vim.deepcopy(file.change.notes) or {}
    vim.list_extend(raw_notes, review_notes.take(file.path))
    file.notes = model.anchor_notes(raw_notes, base, proposed, algorithm)
    break_undo(file.bufnr)
    file.baseline_seq = undo_seq(file.bufnr)
  end
  return true
end

local function compat_index(session, key)
  if key == "blocks" or key == "hunks" then
    return pending_hunks(session)
  end
  return nil
end

function M.open(opts)
  opts = opts or {}
  setup_highlights()
  local thread = opts.thread or (opts.thread_id and state.get_thread(opts.thread_id)) or nil
  local session = setmetatable({
    id = opts.request_id or tostring(vim.uv.hrtime()),
    cwd = vim.fs.normalize(vim.fn.expand(opts.cwd or config.cwd())),
    changes = opts.changes or {},
    thread = thread,
    on_complete = opts.on_complete,
    on_auto_apply = opts.on_auto_apply,
    diagnostics_settle_ms = opts.diagnostics_settle_ms,
    apply_on_complete = opts.apply_on_complete,
    restore_on_complete = opts.restore_on_complete,
    interactive = opts.interactive ~= false,
    files = {},
    file_order = {},
    buffers = {},
    decisions = {},
    keymaps = opts.keymaps or configured_keymaps(),
    window_options = {},
    completed = false,
  }, { __index = compat_index })

  local ok, err = prepare_files(session)
  if ok then
    ok, err = apply_preview(session)
  end
  if not ok then
    restore_original_files(session)
    cleanup(session)
    return nil, err
  end

  if session.interactive then
    for bufnr in pairs(session.buffers) do
      setup_keymaps(session, bufnr)
    end
    setup_autocmds(session)
  end

  local pending = pending_hunks(session)
  if #pending == 0 then
    complete(session, false)
    return session
  end

  if not session.interactive then
    accept_all(session)
    return session
  end

  jump_to(session, pending[1])
  return session
end

-- Abort an outstanding provider review when its transport closes or cancels.
function M.cancel(session)
  if session and not session.completed then
    reject_pending(session, "provider review cancelled")
    complete(session, true)
  end
end

function M._active_session(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return active_by_buf[bufnr]
end

M._parse_change_hunks = parse_change_hunks
M._reject_block = reject_block
M._accept_block = accept_block
M._reject_hunk = reject_block
M._accept_hunk = accept_block
M._target = function(session, bufnr)
  return target_hunk(session, bufnr or vim.api.nvim_get_current_buf())
end
M._render = render
M._keymaps = default_keymaps
M._configured_keymaps = configured_keymaps
M._line_char_spans = line_char_spans

return M
