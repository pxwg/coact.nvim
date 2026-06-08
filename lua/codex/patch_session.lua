local config = require("codex.config")
local context = require("codex.context")
local state = require("codex.state")
local util = require("codex.util")

local M = {}

local diff_ns = vim.api.nvim_create_namespace("codex.patch_session.diff")
local hint_ns = vim.api.nvim_create_namespace("codex.patch_session.hint")
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
  vim.api.nvim_set_hl(0, "CodexPatchReviewHint", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewHintKey", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewHintTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewBefore", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewBeforeChar", { default = true, link = "DiffText" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewAfterChar", { default = true, link = "DiffText" })
  vim.api.nvim_set_hl(0, "CodexPatchReviewDeleteMarker", { default = true, link = "DiffDelete" })
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

local function changed_blocks(lines)
  local blocks = {}
  local current = nil
  local old_offset = 0
  local new_offset = 0

  local function ensure_block()
    if not current then
      current = {
        old_start = old_offset,
        new_start = new_offset,
        old_lines = {},
        new_lines = {},
      }
    end
    return current
  end

  local function flush()
    if current and (#current.old_lines > 0 or #current.new_lines > 0) then
      current.old_count = #current.old_lines
      current.new_count = #current.new_lines
      table.insert(blocks, current)
    end
    current = nil
  end

  for _, line in ipairs(lines or {}) do
    local prefix = line:sub(1, 1)
    local body = line:sub(2)
    if prefix == " " then
      flush()
      old_offset = old_offset + 1
      new_offset = new_offset + 1
    elseif prefix == "-" then
      table.insert(ensure_block().old_lines, body)
      old_offset = old_offset + 1
    elseif prefix == "+" then
      table.insert(ensure_block().new_lines, body)
      new_offset = new_offset + 1
    elseif prefix == "\\" then
      -- "\ No newline at end of file" is metadata, not buffer content.
    end
  end
  flush()

  return blocks
end

local function parse_change_hunks(change)
  local hunks = {}
  local current = nil

  local function flush()
    if current then
      current.changed_blocks = changed_blocks(current.lines)
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

local function is_normal_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_config(winid).relative == ""
end

local function is_review_window(winid)
  if not is_normal_window(winid) then
    return false
  end
  return not context.is_codex_buffer(vim.api.nvim_win_get_buf(winid))
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

local function block_label(block)
  local hunk = block and block.hunk or nil
  local file = (block and block.file) or (hunk and hunk.file) or nil
  local path = file and file.relative_path or "patch"
  return ("%s block %d"):format(path, block and block.index or 0)
end

local function block_bufnr(block)
  local hunk = block and block.hunk or nil
  return block and (block.bufnr or (hunk and hunk.bufnr)) or nil
end

local function block_position(block)
  local hunk = block and block.hunk or nil
  local bufnr = block_bufnr(block)
  local row = (hunk and hunk.applied_start_row or 0) + (block and block.new_start or 0)
  local end_row = row + #(block and block.new_lines or {})
  local mark_id = block and (block.display_extmark_id or block.old_extmark_id) or nil
  if mark_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local extmark = vim.api.nvim_buf_get_extmark_by_id(bufnr, diff_ns, mark_id, { details = true })
    if #extmark > 0 then
      row = extmark[1]
      end_row = extmark[3] and extmark[3].end_row or (row + #(block.new_lines or {}))
    end
  end
  if #(block and block.new_lines or {}) == 0 then
    end_row = row
  end
  return row, end_row
end

local function remove_block_marks(block)
  local bufnr = block_bufnr(block)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if block.display_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, diff_ns, block.display_extmark_id)
    block.display_extmark_id = nil
  end
  if block.old_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, diff_ns, block.old_extmark_id)
    block.old_extmark_id = nil
  end
  for _, mark_id in ipairs(block.new_char_extmark_ids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, diff_ns, mark_id)
  end
  block.new_char_extmark_ids = nil
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

local function old_virtual_lines(hunk, block, width, detailed)
  local old_lines = block.old_lines or {}
  if #old_lines == 0 then
    return {}
  end
  local virt_lines = {}
  local label = #(hunk.changed_blocks or {}) > 1 and block_label(block) or hunk_label(hunk)
  table.insert(virt_lines, { { ("before %s"):format(label), "CodexPatchReviewHintTitle" } })
  local old_spans = detailed and block_char_spans(block) or {}
  for index, line in ipairs(old_lines) do
    vim.list_extend(
      virt_lines,
      line_chunks("- ", line, old_spans[index], "CodexPatchReviewBefore", "CodexPatchReviewBeforeChar", width)
    )
  end
  return virt_lines
end

local function clamp_extmark_row(bufnr, row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return math.max(0, math.min(row or 0, line_count))
end

local function mark_new_char_spans(bufnr, block, block_start)
  if not block_char_diff_allowed(block) then
    return
  end
  local _, new_spans = block_char_spans(block)
  block.new_char_extmark_ids = {}
  for line_index, spans in pairs(new_spans or {}) do
    local row = block_start + line_index - 1
    for _, span in ipairs(spans or {}) do
      if span.end_col > span.start_col then
        local mark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, row, span.start_col, {
          end_row = row,
          end_col = span.end_col,
          hl_group = "CodexPatchReviewAfterChar",
          hl_mode = "combine",
          priority = 20002,
          right_gravity = false,
          end_right_gravity = true,
        })
        table.insert(block.new_char_extmark_ids, mark_id)
      end
    end
  end
end

local function block_start_row(block)
  local hunk = block and block.hunk or nil
  local bufnr = block_bufnr(block)
  if not block or not hunk or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return clamp_extmark_row(bufnr, (hunk.applied_start_row or 0) + (block.new_start or 0))
end

local function set_block_old_mark(block, detailed)
  local bufnr = block_bufnr(block)
  local hunk = block and block.hunk or nil
  local start_row = block_start_row(block)
  if not bufnr or not hunk or not start_row then
    return
  end
  local previous_old_extmark_id = block.old_extmark_id
  if block.old_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, diff_ns, block.old_extmark_id)
    block.old_extmark_id = nil
  end
  local use_detail = detailed == true and block_char_diff_allowed(block)
  local virt_lines = old_virtual_lines(hunk, block, review_width(bufnr), use_detail)
  if #virt_lines > 0 then
    block.old_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, start_row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
      priority = use_detail and 20004 or 19999,
      right_gravity = false,
    })
    if previous_old_extmark_id and hunk.old_extmark_ids then
      for index, mark_id in ipairs(hunk.old_extmark_ids) do
        if mark_id == previous_old_extmark_id then
          hunk.old_extmark_ids[index] = block.old_extmark_id
          break
        end
      end
    end
  end
end

local function clear_block_char_marks(block)
  local bufnr = block_bufnr(block)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, mark_id in ipairs(block.new_char_extmark_ids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, diff_ns, mark_id)
  end
  block.new_char_extmark_ids = nil
end

local function render_block_detail(session, block)
  if session.detail_block == block or not block or block.status then
    return
  end
  if session.detail_block and not session.detail_block.status then
    clear_block_char_marks(session.detail_block)
    set_block_old_mark(session.detail_block, false)
  end
  session.detail_block = block
  if block_char_diff_allowed(block) then
    local bufnr = block_bufnr(block)
    local start_row = block_start_row(block)
    if not bufnr or not start_row then
      return
    end
    clear_block_char_marks(block)
    mark_new_char_spans(bufnr, block, start_row)
    set_block_old_mark(block, true)
  end
end

local function mark_hunk(session, hunk)
  local bufnr = hunk.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  hunk.display_extmark_ids = {}
  hunk.old_extmark_ids = {}

  local start_row = clamp_extmark_row(bufnr, hunk.applied_start_row or 0)
  hunk.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, start_row, 0, {
    end_row = clamp_extmark_row(bufnr, start_row + #(hunk.new_lines or {})),
    right_gravity = false,
    end_right_gravity = true,
  })

  for index, block in ipairs(hunk.changed_blocks or {}) do
    if not block.status then
      block.index_in_hunk = index
      local block_start = clamp_extmark_row(bufnr, (hunk.applied_start_row or 0) + (block.new_start or 0))
      if #(block.new_lines or {}) > 0 then
        block.display_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, block_start, 0, {
          end_row = clamp_extmark_row(bufnr, block_start + #block.new_lines),
          hl_group = "DiffAdd",
          hl_eol = true,
          hl_mode = "combine",
          priority = 20000,
          right_gravity = false,
          end_right_gravity = true,
        })
        table.insert(hunk.display_extmark_ids, block.display_extmark_id)
      else
        block.display_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, diff_ns, block_start, 0, {
          virt_text = {
            {
              ("[- deleted %d line%s]"):format(#block.old_lines, #block.old_lines == 1 and "" or "s"),
              "CodexPatchReviewDeleteMarker",
            },
          },
          virt_text_pos = "eol",
          priority = 20000,
          right_gravity = false,
        })
        table.insert(hunk.display_extmark_ids, block.display_extmark_id)
      end

      set_block_old_mark(block, false)
      if block.old_extmark_id then
        table.insert(hunk.old_extmark_ids, block.old_extmark_id)
      end
    end
  end
end

local function refresh_diff_marks(session)
  session.detail_block = nil
  for bufnr in pairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    end
  end
  for _, hunk in ipairs(session.hunks or {}) do
    mark_hunk(session, hunk)
  end
end

local function current_block(session)
  return session.blocks[session.current_index or 1]
end

local function pending_blocks(session)
  local pending = {}
  for _, block in ipairs(session.blocks or {}) do
    if not block.status then
      table.insert(pending, block)
    end
  end
  return pending
end

local function chunks_display_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks or {}) do
    width = width + vim.fn.strdisplaywidth(chunk[1] or "")
  end
  return width
end

local function review_hint_lines(session, block, width)
  local total = #(session.blocks or {})
  local pending = #pending_blocks(session)
  local header = {
    { "Codex Review", "CodexPatchReviewHintTitle" },
    { ("  %d/%d"):format(block.index or 0, total), "CodexPatchReviewHint" },
    { ("  %d pending"):format(pending), "CodexPatchReviewHint" },
  }
  local lines = { header }
  local current = {}

  local function push_action(name, label)
    local key = keymap_label(session, name)
    if key == "-" then
      return
    end
    local action = {
      { key, "CodexPatchReviewHintKey" },
      { " " .. label .. "  ", "CodexPatchReviewHint" },
    }
    if #current > 0 and chunks_display_width(current) + chunks_display_width(action) > width then
      table.insert(lines, current)
      current = {}
    end
    vim.list_extend(current, action)
  end

  push_action("accept", "accept")
  push_action("reject", "reject")
  push_action("next", "next")
  push_action("prev", "prev")
  push_action("accept_all", "accept rest")
  push_action("reject_all", "reject rest")
  if session.on_auto_apply then
    push_action("auto_apply", "auto")
  end
  push_action("cancel", "cancel")
  push_action("help", "help")
  if #current > 0 then
    table.insert(lines, current)
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

local function update_hints(session)
  for bufnr in pairs(session.buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
    end
  end

  local block = current_block(session)
  local bufnr = block_bufnr(block)
  if not block or block.status or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  render_block_detail(session, block)
  local start_row = block_position(block)
  vim.api.nvim_buf_set_extmark(bufnr, hint_ns, start_row, 0, {
    virt_lines = review_hint_lines(session, block, review_width(bufnr)),
    virt_lines_above = true,
    priority = 20003,
    right_gravity = false,
  })
end

local function ensure_block_window(session, block)
  local bufnr = block_bufnr(block)
  local winid = visible_review_window(bufnr) or review_window(session)
  vim.api.nvim_set_current_win(winid)
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  apply_review_window_options(session, winid)
  return winid
end

local function navigate_to(session, index)
  if not session or session.completed or #session.blocks == 0 then
    return false
  end
  local block = session.blocks[index]
  local bufnr = block_bufnr(block)
  if not block or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  session.current_index = index
  local winid = ensure_block_window(session, block)
  local start_row = block_position(block)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(line_count, start_row + 1)), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zvzz")
  end)
  update_hints(session)
  return true
end

local function navigate_next(session)
  local total = #session.blocks
  if total == 0 then
    return false
  end
  local start = session.current_index or 1
  for offset = 1, total do
    local index = ((start + offset - 1) % total) + 1
    if not session.blocks[index].status then
      return navigate_to(session, index)
    end
  end
  return false
end

local function navigate_prev(session)
  local total = #session.blocks
  if total == 0 then
    return false
  end
  local start = session.current_index or 1
  for offset = 1, total do
    local index = ((start - offset - 1) % total) + 1
    if not session.blocks[index].status then
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

local function proposal_delta_diff(session)
  local sections = {}
  for _, file in ipairs(session.file_order or {}) do
    local proposed_lines = file.proposed_lines
    local final_lines = file.final_lines
    if
      type(proposed_lines) == "table"
      and type(final_lines) == "table"
      and not same_lines(proposed_lines, final_lines)
    then
      local diff = vim.diff(lines_to_text(proposed_lines), lines_to_text(final_lines), {
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

local function file_block_counts(file)
  local accepted = 0
  local rejected = 0
  local pending = 0
  for _, block in ipairs(file.blocks or {}) do
    if block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    else
      pending = pending + 1
    end
  end
  return accepted, rejected, pending
end

local function hunk_block_counts(hunk)
  local accepted = 0
  local rejected = 0
  local pending = 0
  for _, block in ipairs(hunk.changed_blocks or {}) do
    if block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    else
      pending = pending + 1
    end
  end
  return accepted, rejected, pending
end

local function update_hunk_status(hunk)
  if not hunk then
    return
  end
  local accepted, rejected, pending = hunk_block_counts(hunk)
  if pending > 0 then
    hunk.status = nil
    return
  end
  if rejected == 0 and accepted > 0 then
    hunk.status = "accepted"
  elseif accepted == 0 and rejected > 0 then
    hunk.status = "rejected"
  elseif accepted > 0 and rejected > 0 then
    hunk.status = "partial"
  else
    hunk.status = "accepted"
  end
  if hunk.extmark_id and hunk.bufnr and vim.api.nvim_buf_is_valid(hunk.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, hunk.bufnr, diff_ns, hunk.extmark_id)
    hunk.extmark_id = nil
  end
end

local function session_block_counts(session)
  local accepted = 0
  local rejected = 0
  local pending = 0
  for _, block in ipairs(session.blocks or {}) do
    if block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    else
      pending = pending + 1
    end
  end
  return accepted, rejected, pending
end

local function session_hunk_counts(session)
  local accepted = 0
  local rejected = 0
  local partial = 0
  local pending = 0
  for _, hunk in ipairs(session.hunks or {}) do
    update_hunk_status(hunk)
    if hunk.status == "accepted" then
      accepted = accepted + 1
    elseif hunk.status == "rejected" then
      rejected = rejected + 1
    elseif hunk.status == "partial" then
      partial = partial + 1
    else
      pending = pending + 1
    end
  end
  return accepted, rejected, partial, pending
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
    vim.api.nvim_create_augroup("codex.patch_session.diagnostics." .. tostring(session.id), { clear = true })
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

local function build_summary(session, write_error)
  local accepted, rejected, pending = session_block_counts(session)

  local lines = {
    "# NVIM APPLY PATCH REVIEW",
    "",
    ("accepted_blocks: %d"):format(accepted),
    ("rejected_blocks: %d"):format(rejected),
    ("pending_blocks: %d"):format(pending),
  }
  if write_error and write_error ~= "" then
    table.insert(lines, "write_error: " .. write_error)
  end
  table.insert(lines, "")
  table.insert(lines, "## FILES")
  for _, file in ipairs(session.file_order or {}) do
    local file_accepted, file_rejected, file_pending = file_block_counts(file)
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
    for _, block in ipairs(session.blocks or {}) do
      if block.status == "rejected" then
        table.insert(lines, ("- %s: %s"):format(block_label(block), block.reason or "no reason provided"))
      end
    end
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
    end
  end
  restore_review_window_options(session)
  if session.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  end
end

local function complete(session, force_failure)
  if session.completed then
    return
  end
  session.completed = true
  session.force_failure = force_failure == true
  local write_ok, write_error = true, nil
  if session.apply_on_complete ~= false then
    write_ok, write_error = write_files(session)
  end
  wait_for_fresh_diagnostics(session)
  session.write_ok = write_ok
  session.write_error = write_error
  local accepted, rejected, pending = session_block_counts(session)
  local accepted_hunks, rejected_hunks, partial_hunks, pending_hunks = session_hunk_counts(session)
  session.accepted_blocks = accepted
  session.rejected_blocks = rejected
  session.pending_blocks = pending
  session.accepted_hunks = accepted_hunks
  session.rejected_hunks = rejected_hunks
  session.partial_hunks = partial_hunks
  session.pending_hunks = pending_hunks
  for _, file in ipairs(session.file_order or {}) do
    file.final_lines = normalized_final_lines(file)
  end
  local summary = build_summary(session, write_error)
  session.summary = summary
  local success = write_ok and rejected == 0 and not force_failure
  if session.restore_on_complete == true then
    restore_original_files(session)
  end
  cleanup(session)
  if session.on_complete then
    session.on_complete(summary, success, session)
  end
end

local function finish_after_decision(session)
  if #pending_blocks(session) == 0 then
    complete(session, false)
  else
    navigate_next(session)
  end
end

local function accept_block_without_finish(block)
  if not block or block.status then
    return
  end
  block.status = "accepted"
  remove_block_marks(block)
  update_hunk_status(block.hunk)
end

local function accept_block(session, block)
  block = block or current_block(session)
  if not block or block.status then
    return
  end
  accept_block_without_finish(block)
  finish_after_decision(session)
end

local function reject_block_without_finish(block, reason)
  if not block or block.status then
    return
  end
  local bufnr = block_bufnr(block)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local start_row, end_row = block_position(block)
  if #(block.new_lines or {}) == 0 then
    set_buffer_lines(bufnr, start_row, start_row, vim.deepcopy(block.old_lines or {}))
  else
    set_buffer_lines(bufnr, start_row, end_row, vim.deepcopy(block.old_lines or {}))
  end
  block.status = "rejected"
  block.reason = util.trim(reason or "") ~= "" and util.trim(reason or "") or "no reason provided"
  remove_block_marks(block)
  update_hunk_status(block.hunk)
end

local function reject_block(session, block, reason)
  block = block or current_block(session)
  if not block or block.status then
    return
  end
  reject_block_without_finish(block, reason)
  finish_after_decision(session)
end

local function accept_hunk(session, hunk)
  hunk = hunk or (current_block(session) and current_block(session).hunk)
  if not hunk then
    return
  end
  for _, block in ipairs(hunk.changed_blocks or {}) do
    accept_block_without_finish(block)
  end
  finish_after_decision(session)
end

local function reject_hunk_without_finish(session, hunk, reason)
  if not hunk then
    return
  end
  for _, block in ipairs(hunk.changed_blocks or {}) do
    reject_block_without_finish(block, reason)
  end
end

local function reject_hunk(session, hunk, reason)
  hunk = hunk or (current_block(session) and current_block(session).hunk)
  if not hunk then
    return
  end
  reject_hunk_without_finish(session, hunk, reason)
  finish_after_decision(session)
end

local function prompt_reject(session, block)
  vim.ui.input({ prompt = "Why reject this Codex patch block? " }, function(reason)
    reject_block(session, block, reason)
  end)
end

local function accept_all(session)
  for _, block in ipairs(session.blocks or {}) do
    if not block.status then
      accept_block_without_finish(block)
    end
  end
  complete(session, false)
end

local function reject_all(session)
  vim.ui.input({ prompt = "Why reject the remaining Codex patch blocks? " }, function(reason)
    local pending = pending_blocks(session)
    for _, block in ipairs(pending) do
      reject_block_without_finish(block, reason)
    end
    complete(session, true)
  end)
end

local function cancel(session)
  vim.ui.input({ prompt = "Why cancel this Codex patch review? " }, function(reason)
    local pending = pending_blocks(session)
    for _, block in ipairs(pending) do
      reject_block_without_finish(block, reason or "patch review cancelled")
    end
    if not session.completed then
      complete(session, true)
    end
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
    "Codex Patch Review",
    "",
    ("  %s  accept current change"):format(keymap_label(session, "accept")),
    ("  %s  reject current change with a reason"):format(keymap_label(session, "reject")),
    ("  %s  next pending change"):format(keymap_label(session, "next")),
    ("  %s  previous pending change"):format(keymap_label(session, "prev")),
    ("  %s  accept remaining changes"):format(keymap_label(session, "accept_all")),
    ("  %s  reject remaining changes"):format(keymap_label(session, "reject_all")),
    ("  %s  cancel review"):format(keymap_label(session, "cancel")),
  }
  if session.on_auto_apply then
    table.insert(
      lines,
      #lines,
      ("  %s  auto-apply future nvim.apply_patch calls"):format(keymap_label(session, "auto_apply"))
    )
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local width = math.min(58, math.max(36, vim.o.columns - 8))
  local height = math.min(#lines, math.max(8, vim.o.lines - 6))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "single",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Codex Review Keys ",
    title_pos = "center",
  })
  local close = function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, desc = "Close Codex review help" })
  vim.keymap.set("n", "?", close, { buffer = bufnr, silent = true, desc = "Close Codex review help" })
end

local function setup_keymaps(session, bufnr)
  local opts = function(desc)
    return { buffer = bufnr, silent = true, desc = desc }
  end
  local set = function(name, callback, desc)
    local lhs = session.keymaps and session.keymaps[name] or nil
    if lhs then
      vim.keymap.set("n", lhs, callback, opts(desc))
    end
  end
  set("accept", function()
    accept_block(session)
  end, "Accept Codex patch block")
  set("reject", function()
    prompt_reject(session, current_block(session))
  end, "Reject Codex patch block")
  set("accept_all", function()
    accept_all(session)
  end, "Accept all Codex patch blocks")
  set("reject_all", function()
    reject_all(session)
  end, "Reject all Codex patch blocks")
  if session.on_auto_apply then
    set("auto_apply", function()
      auto_apply(session)
    end, "Use Neovim auto-apply for this session")
  end
  set("cancel", function()
    cancel(session)
  end, "Cancel Codex patch review")
  set("next", function()
    navigate_next(session)
  end, "Next Codex patch block")
  set("prev", function()
    navigate_prev(session)
  end, "Previous Codex patch block")
  set("help", function()
    show_help(session)
  end, "Show Codex patch review keys")
end

local function setup_autocmds(session)
  session.augroup = vim.api.nvim_create_augroup("codex.patch_session." .. tostring(session.id), { clear = true })
  for bufnr in pairs(session.buffers or {}) do
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = session.augroup,
      buffer = bufnr,
      callback = function()
        apply_review_window_options(session, visible_review_window(bufnr))
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
  vim.api.nvim_create_autocmd("WinResized", {
    group = session.augroup,
    callback = function()
      if not session.completed then
        refresh_diff_marks(session)
        update_hints(session)
      end
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
      blocks = {},
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
  local block_index = 0
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
      for block_in_hunk, block in ipairs(hunk.changed_blocks or {}) do
        block_index = block_index + 1
        block.index = block_index
        block.index_in_hunk = block_in_hunk
        block.hunk = hunk
        block.file = file
        block.bufnr = hunk.bufnr
        table.insert(file.blocks, block)
        table.insert(session.blocks, block)
      end
    end
  end

  refresh_diff_marks(session)
  for _, file in ipairs(session.file_order or {}) do
    file.proposed_lines = normalized_final_lines(file)
  end
  return true
end

function M.open(opts)
  opts = opts or {}
  setup_highlights()
  local thread = opts.thread or (opts.thread_id and state.get_thread(opts.thread_id)) or nil
  local session = {
    id = opts.request_id or tostring(vim.uv.hrtime()),
    cwd = vim.fs.normalize(vim.fn.expand(opts.cwd or config.cwd())),
    changes = opts.changes or {},
    thread = thread,
    on_complete = opts.on_complete,
    on_auto_apply = opts.on_auto_apply,
    diagnostics_settle_ms = opts.diagnostics_settle_ms,
    apply_on_complete = opts.apply_on_complete,
    restore_on_complete = opts.restore_on_complete,
    files = {},
    file_order = {},
    buffers = {},
    hunks = {},
    blocks = {},
    keymaps = opts.keymaps or configured_keymaps(),
    window_options = {},
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

  if #session.blocks == 0 then
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
M._reject_block = reject_block
M._accept_block = accept_block
M._reject_hunk = reject_hunk
M._accept_hunk = accept_hunk
M._keymaps = default_keymaps
M._configured_keymaps = configured_keymaps
M._line_char_spans = line_char_spans

return M
