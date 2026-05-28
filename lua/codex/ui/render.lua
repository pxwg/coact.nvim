local config = require("codex.config")
local events = require("codex.events")
local metadata = require("codex.ui.metadata")
local tool_renderers = require("codex.ui.tool_renderers")
local util = require("codex.util")

local M = {}

local ns = vim.api.nvim_create_namespace("codex.nvim")
local follow_threshold = 5
local pending_render_timers = {}
local pending_spinner_timers = {}

local foldable_types = {
  UserBlock = true,
  AssistantBlock = true,
  ErrorBlock = true,
}

local placeholder_types = {
  ReasoningBlock = true,
  ToolCallBlock = true,
  PatchBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  PlanBlock = true,
}

local assistant_content_types = {
  AssistantBlock = true,
  ReasoningBlock = true,
  ToolCallBlock = true,
  PatchBlock = true,
  RawEventBlock = true,
  PlanBlock = true,
  ErrorBlock = true,
}

local composer_token_prefixes = {
  ["/"] = true,
  ["@"] = true,
  ["$"] = true,
  [">"] = true,
}

local composer_trailing_punctuation = {
  [","] = true,
  ["."] = true,
  [";"] = true,
  ["!"] = true,
  ["?"] = true,
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
}

local stream_decoration_by_type = {
  ToolCallBlock = { kind = "tool", marker = "▌ ", hl_group = "CodexStreamTool" },
  PatchBlock = { kind = "patch", marker = "▌ ", hl_group = "CodexStreamPatch" },
  AgentTimelineBlock = { kind = "agent", marker = "▎ ", hl_group = "CodexStreamAgent" },
  RawEventBlock = { kind = "raw", marker = "╎ ", hl_group = "CodexStreamRaw" },
  PlanBlock = { kind = "plan", marker = "▎ ", hl_group = "CodexStreamPlan" },
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CodexHeaderUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CodexHeaderAssistant", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CodexHeaderAgent", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CodexHeaderSection", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CodexHeaderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexHeaderSeparator", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexSpinner", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CodexReasoningText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexReasoningBorder", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "CodexComposerCommand", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "CodexComposerMention", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CodexComposerContext", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "CodexStreamTool", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexStreamPatch", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CodexStreamAgent", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CodexStreamRaw", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CodexStreamPlan", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "CodexBlockPlaceholder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexBlockPlaceholderTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CodexBlockPlaceholderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexBlockPlaceholderHint", { default = true, link = "DiagnosticHint" })
end

local function add(lines, value)
  local text_lines = util.split_lines(value)
  if #text_lines == 0 then
    table.insert(lines, "")
  else
    for _, line in ipairs(text_lines) do
      table.insert(lines, line)
    end
  end
  return #lines
end

local function add_text(lines, value)
  local text_lines = util.split_lines(value)
  if #text_lines == 0 then
    add(lines, "")
    return
  end
  for _, line in ipairs(text_lines) do
    add(lines, line)
  end
end

local function compact_text(value)
  return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate_display(value, limit)
  value = tostring(value or "")
  limit = limit or 96
  if #value <= limit then
    return value
  end
  return value:sub(1, limit - 1) .. "..."
end

local function line_count(value)
  value = tostring(value or "")
  if value == "" then
    return 0
  end
  local _, count = value:gsub("\n", "")
  return count + 1
end

local function virtual_block_config()
  return config.get().render.virtual_blocks or {}
end

local function default_expanded()
  return virtual_block_config().default_expanded == true
end

local function default_block_expanded(block)
  if block and block.type == "AgentTimelineBlock" and block.state == "cleared" then
    return false
  end
  return default_expanded()
end

local function max_virtual_lines()
  return tonumber(virtual_block_config().max_lines) or 80
end

local function max_virtual_width()
  return tonumber(virtual_block_config().max_width) or 180
end

local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks or {}) do
    width = width + vim.fn.strdisplaywidth(chunk[1] or "")
  end
  return width
end

local function repeat_to_width(text, target_width)
  local unit_width = math.max(1, vim.fn.strdisplaywidth(text))
  return string.rep(text, math.max(1, math.ceil(target_width / unit_width)))
end

local function window_text_width(win)
  local width = vim.api.nvim_win_get_width(win)
  local ok, info = pcall(vim.fn.getwininfo, win)
  if ok and info and info[1] and info[1].textoff then
    width = width - info[1].textoff
  end
  return math.max(20, width)
end

local function narrowest_buffer_text_width(bufnr)
  local width = vim.o.columns
  local found = false
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      width = math.min(width, window_text_width(win))
      found = true
    end
  end
  return math.max(20, found and width or vim.o.columns)
end

local function header_target_width(bufnr)
  local width = vim.o.columns
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      width = math.max(width, window_text_width(win))
    end
  end
  return width + 32
end

local function meta_chunk(item)
  if type(item) == "table" then
    return tostring(item.text or item[1] or ""), item.hl_group or item.hl or "CodexHeaderMeta"
  end
  return tostring(item or ""), "CodexHeaderMeta"
end

local function header_hl(kind)
  if kind == "user" then
    return "CodexHeaderUser"
  end
  if kind == "assistant" then
    return "CodexHeaderAssistant"
  end
  if kind == "agent" then
    return "CodexHeaderAgent"
  end
  return "CodexHeaderSection"
end

local function mark_header(thread, line, kind, title, meta, block)
  table.insert(thread.header_marks, {
    line = line,
    kind = kind,
    title = title,
    meta = meta or {},
    block = block,
  })
end

local function mark_reasoning_lines(thread, start_line, finish_line)
  if finish_line >= start_line then
    table.insert(thread.reasoning_marks, { start_line = start_line, finish_line = finish_line })
  end
end

local function mark_stream_decoration(thread, start_line, finish_line, decoration, block)
  if decoration and finish_line >= start_line then
    table.insert(thread.stream_decoration_marks, {
      start_line = start_line,
      finish_line = finish_line,
      marker = decoration.marker,
      hl_group = decoration.hl_group,
      block = block,
    })
  end
end

local function mark_spinner(thread, line)
  thread.spinner_mark = { line = line }
end

local function block_key(block, opts)
  return table.concat({
    tostring(opts and opts.block_index or ""),
    tostring(block.type or "Block"),
    tostring(block.message_id or ""),
    tostring(block.item_id or ""),
    tostring(block.tool_call_id or ""),
    tostring(block.tool or ""),
    tostring(block.title or ""),
  }, ":")
end

local function placeholder_expanded(thread, key, block)
  local expanded = thread.expanded_blocks and thread.expanded_blocks[key]
  if expanded == nil then
    return default_block_expanded(block)
  end
  return expanded == true
end

local function stream_decoration_for_block(block)
  return stream_decoration_by_type[block and block.type]
end

local function placeholder_meta(block)
  if block.type == "ReasoningBlock" then
    local text = events.block_text(block)
    if text == "" then
      return { "empty" }
    end
    return { tostring(line_count(text)) .. " lines", block.state }
  end
  if block.type == "ToolCallBlock" or block.type == "PatchBlock" then
    local meta = {}
    local summary = truncate_display(compact_text(tool_renderers.summary(block)), 88)
    local status = tool_renderers.status(block)
    if summary ~= "" then
      table.insert(meta, summary)
    end
    if status then
      table.insert(meta, status)
    end
    if block.tool_call_id then
      table.insert(meta, "id " .. truncate_display(block.tool_call_id, 18))
    end
    return meta
  end
  if block.type == "AgentTimelineBlock" then
    local summary = truncate_display(compact_text(events.block_text(block)), 88)
    return summary ~= "" and { block.state, summary } or { block.state }
  end
  if block.type == "PlanBlock" then
    return { block.state, tostring(line_count(events.block_text(block))) .. " lines" }
  end
  if block.type == "RawEventBlock" then
    return { "debug event" }
  end
  return {}
end

local function placeholder_title(block)
  if block.type == "ReasoningBlock" then
    return "Reasoning" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "ToolCallBlock" or block.type == "PatchBlock" then
    return tostring(block.tool or "tool") .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "AgentTimelineBlock" then
    return "Agent: " .. tostring(block.title or "event")
  end
  if block.type == "PlanBlock" then
    return "Plan" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "RawEventBlock" then
    return "Raw Event: " .. tostring(block.title or "unknown")
  end
  return tostring(block.type or "Block")
end

local function placeholder_body_lines(block)
  if block.type == "ReasoningBlock" or block.type == "PlanBlock" or block.type == "AgentTimelineBlock" then
    return util.split_lines(events.block_text(block))
  end
  if block.type == "ToolCallBlock" or block.type == "PatchBlock" then
    local body = {}
    if block.tool_call_id then
      table.insert(body, "tool_call_id: " .. tostring(block.tool_call_id))
    end
    for _, rendered_line in ipairs(tool_renderers.render(block)) do
      table.insert(body, rendered_line)
    end
    return body
  end
  if block.type == "RawEventBlock" then
    return util.split_lines(vim.inspect(block.raw or block))
  end
  return util.split_lines(events.block_text(block))
end

local function mark_placeholder(thread, line, key, block, body_lines)
  local expanded = placeholder_expanded(thread, key, block)
  local mark = {
    line = line,
    key = key,
    block = block,
    title = placeholder_title(block),
    meta = placeholder_meta(block),
    body_lines = body_lines or {},
    expanded = expanded,
    decoration = stream_decoration_for_block(block),
  }
  table.insert(thread.placeholder_marks, mark)
  thread.placeholder_index[line] = mark
  thread.render_index[line] = block
  return mark
end

local function header_virt_text(mark, target_width)
  local title = " " .. tostring(mark.title or "") .. " "
  local chunks = { { title, header_hl(mark.kind) } }
  if mark.meta and #mark.meta > 0 then
    table.insert(chunks, { " ", "CodexHeaderMeta" })
    for index, item in ipairs(mark.meta) do
      local text, hl_group = meta_chunk(item)
      if text ~= "" and text ~= "nil" then
        if index > 1 then
          table.insert(chunks, { " · ", "CodexHeaderMeta" })
        end
        table.insert(chunks, { text, hl_group })
      end
    end
    table.insert(chunks, { " ", "CodexHeaderMeta" })
  end
  local sep = config.get().render.separator or "---"
  local remaining = math.max(vim.fn.strdisplaywidth(sep), target_width - chunks_width(chunks))
  table.insert(chunks, { repeat_to_width(sep, remaining), "CodexHeaderSeparator" })
  return chunks
end

local function apply_header_marks(thread, bufnr)
  local target_width = header_target_width(bufnr)
  for _, mark in ipairs(thread.header_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
      conceal = "",
      virt_text = header_virt_text(mark, target_width),
      virt_text_pos = "overlay",
      priority = 2000,
      strict = false,
    })
    if mark.block then
      thread.render_index[mark.line] = mark.block
    end
  end
end

local function placeholder_virt_text(mark)
  local icon = mark.expanded and "▾ " or "▸ "
  local chunks = {
    { icon, mark.decoration and mark.decoration.hl_group or "CodexBlockPlaceholder" },
    { tostring(mark.title or "Block"), "CodexBlockPlaceholderTitle" },
  }
  for _, item in ipairs(mark.meta or {}) do
    local text = type(item) == "table" and (item.text or item[1]) or item
    if text and text ~= "" and text ~= "nil" then
      table.insert(chunks, { " · " .. tostring(text), "CodexBlockPlaceholderMeta" })
    end
  end
  table.insert(chunks, { mark.expanded and " · za collapse" or " · za expand", "CodexBlockPlaceholderHint" })
  return chunks
end

local function virtual_body_lines(mark)
  if not mark.expanded then
    return nil
  end
  local limit = max_virtual_lines()
  local width = max_virtual_width()
  local lines = {}
  for index, line in ipairs(mark.body_lines or {}) do
    if index > limit then
      table.insert(lines, { { "  ... truncated; open details for full content", "CodexBlockPlaceholderHint" } })
      break
    end
    table.insert(lines, {
      { "  │ ", mark.decoration and mark.decoration.hl_group or "CodexBlockPlaceholder" },
      { truncate_display(line, width), "CodexBlockPlaceholder" },
    })
  end
  if #lines == 0 then
    table.insert(lines, { { "  │ (empty)", "CodexBlockPlaceholderMeta" } })
  end
  return lines
end

local function apply_placeholder_marks(thread, bufnr)
  for _, mark in ipairs(thread.placeholder_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
      conceal = "",
      virt_text = placeholder_virt_text(mark),
      virt_text_pos = "overlay",
      virt_lines = virtual_body_lines(mark),
      priority = 1900,
      strict = false,
    })
  end
end

local function apply_reasoning_marks(thread, bufnr)
  for _, mark in ipairs(thread.reasoning_marks or {}) do
    for lnum = mark.start_line, mark.finish_line do
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = { { "▏ ", "CodexReasoningBorder" } },
        virt_text_pos = "inline",
        priority = 1200,
        strict = false,
      })
      if line ~= "" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
          end_col = #line,
          hl_group = "CodexReasoningText",
          hl_mode = "combine",
          priority = 900,
          strict = false,
        })
      end
    end
  end
end

local function apply_stream_decoration_marks(thread, bufnr)
  for _, mark in ipairs(thread.stream_decoration_marks or {}) do
    for lnum = mark.start_line, mark.finish_line do
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = { { mark.marker, mark.hl_group } },
        virt_text_pos = "inline",
        priority = 1100,
        strict = false,
      })
    end
  end
end

local spinner_frames = {
  "▰▱▱▱▱",
  "▰▰▱▱▱",
  "▰▰▰▱▱",
  "▰▰▰▰▱",
  "▰▰▰▰▰",
  "▱▰▰▰▰",
  "▱▱▰▰▰",
  "▱▱▱▰▰",
  "▱▱▱▱▰",
}

local busy_generations = {
  submitted = true,
  waiting_backend = true,
  streaming = true,
  tool_running = true,
  patch_review = true,
  reconciling = true,
  cancelling = true,
}

local function thread_busy(thread)
  return thread and busy_generations[thread.generation] == true
end

local function spinner_label(thread)
  return thread.generation == "tool_running" and "tooling"
    or thread.generation == "patch_review" and "reviewing patch"
    or thread.generation == "waiting_backend" and "waiting"
    or thread.generation == "reconciling" and "syncing"
    or thread.generation == "cancelling" and "stopping"
    or thread.generation == "submitted" and "thinking"
    or "streaming"
end

local function spinner_virt_text(thread)
  local index = (math.floor(util.now_ms() / 140) % #spinner_frames) + 1
  return { { spinner_frames[index] .. "  Codex " .. spinner_label(thread), "CodexSpinner" } }
end

local function apply_spinner_mark(thread, bufnr, mark)
  if not mark or not mark.line or mark.line < 1 or mark.line > vim.api.nvim_buf_line_count(bufnr) then
    return
  end
  local opts = {
    conceal = "",
    virt_text = spinner_virt_text(thread),
    virt_text_pos = "overlay",
    priority = 1800,
    strict = false,
  }
  if mark.extmark_id then
    opts.id = mark.extmark_id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, mark.line - 1, 0, opts)
  if ok then
    mark.extmark_id = id
  else
    opts.id = nil
    mark.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, opts)
  end
end

local function apply_spinner_marks(thread, bufnr)
  if thread.spinner_mark then
    apply_spinner_mark(thread, bufnr, thread.spinner_mark)
  end
end

local function schedule_spinner_tick(thread)
  if not thread or not thread.id or not thread_busy(thread) then
    return
  end
  local key = tostring(thread.id)
  if pending_spinner_timers[key] then
    return
  end
  pending_spinner_timers[key] = vim.defer_fn(function()
    pending_spinner_timers[key] = nil
    M.update_spinner(thread)
  end, 140)
end

function M.update_spinner(thread)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end
  if not thread_busy(thread) or not thread.spinner_mark then
    return
  end
  apply_spinner_mark(thread, thread.bufnr, thread.spinner_mark)
  schedule_spinner_tick(thread)
end

local function composer_token_hl(token)
  local prefix = token:sub(1, 1)
  if prefix == "/" or prefix == "$" then
    return "CodexComposerCommand"
  end
  if prefix == "@" then
    return "CodexComposerMention"
  end
  if prefix == ">" then
    return "CodexComposerContext"
  end
  return nil
end

local function composer_token_boundary(line, index)
  return index <= 1 or line:sub(index - 1, index - 1):match("%s") ~= nil
end

local function composer_candidate_end(line, index)
  local pos = index
  while pos <= #line and not line:sub(pos, pos):match("%s") do
    pos = pos + 1
  end
  return pos - 1
end

local function trim_composer_candidate(raw)
  local finish = #raw
  while finish > 1 and composer_trailing_punctuation[raw:sub(finish, finish)] do
    finish = finish - 1
  end
  return raw:sub(1, finish)
end

local function next_composer_candidate(line, start_index)
  local index = start_index
  while index <= #line do
    local ch = line:sub(index, index)
    if composer_token_prefixes[ch] and composer_token_boundary(line, index) then
      local raw_finish = composer_candidate_end(line, index)
      local token = trim_composer_candidate(line:sub(index, raw_finish))
      if #token > 1 then
        return index, index + #token - 1, token, raw_finish + 1
      end
      index = raw_finish + 1
    else
      index = index + 1
    end
  end
  return nil
end

local function apply_composer_token_marks(thread, bufnr)
  if not thread.prompt_start then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, thread.prompt_start, -1, false)
  for offset, line in ipairs(lines) do
    local lnum0 = thread.prompt_start + offset - 1
    local search_from = 1
    while search_from <= #line do
      local start_col1, finish_col1, token, next_index = next_composer_candidate(line, search_from)
      if not start_col1 then
        break
      end
      local hl_group = composer_token_hl(token)
      if hl_group then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum0, start_col1 - 1, {
          end_col = finish_col1,
          hl_group = hl_group,
          hl_mode = "combine",
          priority = 1300,
          strict = false,
        })
      end
      search_from = next_index
    end
  end
end

local function existing_prompt(thread)
  if not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) or not thread.prompt_start then
    return { "" }
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, thread.bufnr, thread.prompt_start, -1, false)
  if ok and #lines > 0 then
    return lines
  end
  return { "" }
end

local function header(thread)
  return { "# Codex: " .. tostring(thread.title or util.short_id(thread.id)) }
end

local function workspace_label(thread)
  local cwd = thread and thread.cwd
  return cwd and vim.fn.fnamemodify(cwd, ":t") or nil
end

local function workspace_virt_text(thread, bufnr, title_line)
  local label = workspace_label(thread)
  if not label or label == "" then
    return nil
  end
  local chunks = { { tostring(label), "Comment" } }
  local available = narrowest_buffer_text_width(bufnr) - vim.fn.strdisplaywidth(title_line or "") - 2
  return chunks_width(chunks) <= available and chunks or nil
end

local function valid_window_for_buffer(win, bufnr)
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr
end

local function ensure_view_state(thread)
  thread.view_state = thread.view_state or {}
  return thread.view_state
end

local function view_state_for_win(thread, win)
  local states = ensure_view_state(thread)
  states[win] = states[win]
    or {
      follow = nil,
      suspended_by_user = false,
      programmatic = 0,
      last_programmatic = false,
    }
  return states[win]
end

local function window_info(win)
  local ok, info = pcall(vim.fn.getwininfo, win)
  if ok and info and info[1] then
    return info[1]
  end
  return nil
end

local function cursor_line(win)
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if ok and cursor then
    return cursor[1]
  end
  return 1
end

local function clamp_lnum(lnum, line_count_value)
  return math.min(math.max(tonumber(lnum) or 1, 1), math.max(1, line_count_value))
end

local function line_col(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return math.min(tonumber(col) or 0, #line)
end

local function save_window_view(win)
  local ok, view = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.winsaveview()
  end)
  return ok and view or nil
end

local function with_programmatic_view(thread, win, fn)
  local state = view_state_for_win(thread, win)
  state.programmatic = (state.programmatic or 0) + 1
  state.last_programmatic = true
  local ok, err = pcall(fn)
  state.programmatic = math.max((state.programmatic or 1) - 1, 0)
  if not ok then
    error(err)
  end
end

local function restore_window_view(thread, win, snapshot)
  local bufnr = thread.bufnr
  if not snapshot or not snapshot.view or not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count_value = vim.api.nvim_buf_line_count(bufnr)
  local view = vim.deepcopy(snapshot.view)
  view.lnum = clamp_lnum(view.lnum, line_count_value)
  view.topline = clamp_lnum(view.topline, line_count_value)
  view.col = line_col(bufnr, view.lnum, view.col)
  view.curswant = view.curswant or view.col
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end)
end

local function follow_cursor_line(thread, line_count_value)
  if thread.prompt_start then
    return clamp_lnum(thread.prompt_start + 1, line_count_value)
  end
  return line_count_value
end

local function anchor_follow_window(thread, win)
  local bufnr = thread.bufnr
  if not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count_value = vim.api.nvim_buf_line_count(bufnr)
  local lnum = follow_cursor_line(thread, line_count_value)
  local col = line_col(bufnr, lnum, 0)
  local height = math.max(1, vim.api.nvim_win_get_height(win))
  local topline = math.max(1, line_count_value - height + 1)
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_set_cursor(win, { lnum, col })
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({
        lnum = lnum,
        col = col,
        curswant = col,
        topline = topline,
        leftcol = 0,
        skipcol = 0,
      })
    end)
    vim.api.nvim_win_set_cursor(win, { lnum, col })
  end)
  local state = view_state_for_win(thread, win)
  state.follow = true
  state.suspended_by_user = false
end

local function cursor_near_bottom(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return false
  end
  local line_count_value = vim.api.nvim_buf_line_count(thread.bufnr)
  local lnum = cursor_line(win)
  if line_count_value - lnum <= follow_threshold then
    return true
  end
  if thread.prompt_start and lnum >= math.max(1, thread.prompt_start - follow_threshold) then
    return true
  end
  return false
end

local function viewport_near_bottom(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return false
  end
  local line_count_value = vim.api.nvim_buf_line_count(thread.bufnr)
  local info = window_info(win)
  local botline = info and info.botline or cursor_line(win)
  return line_count_value - botline <= follow_threshold
end

function M.window_near_bottom(thread, win)
  return cursor_near_bottom(thread, win) or viewport_near_bottom(thread, win)
end

function M.prepare_submit_follow(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return
  end
  local state = view_state_for_win(thread, win)
  local follow = M.window_near_bottom(thread, win)
  state.follow = follow
  state.suspended_by_user = not follow
end

function M.on_user_view_changed(thread, win, source)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return
  end
  local state = view_state_for_win(thread, win)
  if (state.programmatic or 0) > 0 then
    return
  end
  local follow = source == "viewport" and viewport_near_bottom(thread, win) or cursor_near_bottom(thread, win)
  state.follow = follow
  state.suspended_by_user = not follow
end

local function capture_prompt_anchor(thread, win)
  if not thread.prompt_start then
    return nil
  end
  local info = window_info(win)
  if not info then
    return nil
  end
  local top = info.topline or 1
  local bottom = info.botline or top + vim.api.nvim_win_get_height(win) - 1
  local prompt_line = thread.prompt_start
  if prompt_line < top or prompt_line > bottom then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  cursor = ok and cursor or { prompt_line + 1, 0 }
  return {
    prompt_row = prompt_line - top,
    cursor_delta = cursor[1] - prompt_line,
    cursor_col = cursor[2] or 0,
  }
end

local function restore_prompt_anchor(thread, win, snapshot)
  if not snapshot or not snapshot.prompt_anchor or not thread.prompt_start then
    restore_window_view(thread, win, snapshot)
    return
  end
  local bufnr = thread.bufnr
  if not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count_value = vim.api.nvim_buf_line_count(bufnr)
  local anchor = snapshot.prompt_anchor
  local view = vim.deepcopy(snapshot.view or {})
  local lnum = clamp_lnum(thread.prompt_start + anchor.cursor_delta, line_count_value)
  local col = line_col(bufnr, lnum, anchor.cursor_col)
  view.lnum = lnum
  view.col = col
  view.curswant = col
  view.topline = clamp_lnum(thread.prompt_start - anchor.prompt_row, line_count_value)
  view.leftcol = view.leftcol or 0
  view.skipcol = view.skipcol or 0
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_set_cursor(win, { lnum, col })
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
    vim.api.nvim_win_set_cursor(win, { lnum, col })
  end)
end

local function capture_window_views(thread, bufnr)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local prompt_anchor = capture_prompt_anchor(thread, win)
      local state = view_state_for_win(thread, win)
      if prompt_anchor then
        state.follow = true
        state.suspended_by_user = false
      elseif state.follow == nil then
        state.follow = M.window_near_bottom(thread, win)
        state.suspended_by_user = not state.follow
      end
      snapshots[win] = {
        view = save_window_view(win),
        prompt_anchor = prompt_anchor,
      }
    end
  end
  return snapshots
end

local function apply_window_views(thread, bufnr, snapshots)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local snapshot = snapshots[win]
      local view_state = view_state_for_win(thread, win)
      require("codex.buffers").apply_window_options(win, bufnr)
      if snapshot and snapshot.prompt_anchor then
        restore_prompt_anchor(thread, win, snapshot)
      elseif
        config.get().ui.auto_scroll
        and thread_busy(thread)
        and view_state.follow
        and not view_state.suspended_by_user
      then
        anchor_follow_window(thread, win)
      elseif snapshot then
        restore_window_view(thread, win, snapshot)
      end
    end
  end
end

local function prune_view_states(thread, bufnr)
  for win, _ in pairs(thread.view_state or {}) do
    if not valid_window_for_buffer(win, bufnr) then
      thread.view_state[win] = nil
    end
  end
end

local function changed_line_range(current, lines)
  local current_count = #current
  local next_count = #lines
  local prefix = 0
  local prefix_limit = math.min(current_count, next_count)
  while prefix < prefix_limit and current[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix == current_count and prefix == next_count then
    return nil
  end
  local suffix = 0
  while
    suffix < current_count - prefix
    and suffix < next_count - prefix
    and current[current_count - suffix] == lines[next_count - suffix]
  do
    suffix = suffix + 1
  end
  local replacement = {}
  for index = prefix + 1, next_count - suffix do
    table.insert(replacement, lines[index])
  end
  return prefix, current_count - suffix, replacement
end

local function replace_buffer_lines(bufnr, lines)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_line, end_line, replacement = changed_line_range(current, lines)
  if not start_line then
    return false
  end
  local fold_snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      fold_snapshots[win] = {
        foldmethod = vim.wo[win].foldmethod,
        foldenable = vim.wo[win].foldenable,
      }
      vim.wo[win].foldmethod = "manual"
      vim.wo[win].foldenable = false
    end
  end
  local previous_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, start_line, end_line, false, replacement)
  vim.bo[bufnr].undolevels = previous_undolevels
  for win, snapshot in pairs(fold_snapshots) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].foldmethod = snapshot.foldmethod
      vim.wo[win].foldenable = snapshot.foldenable
    end
  end
  if not ok then
    error(err)
  end
  return true
end

function _G.CodexFoldExpr(lnum)
  local thread = require("codex.state").thread_for_buf(0)
  if not thread then
    return "0"
  end
  return (thread.fold_levels and thread.fold_levels[lnum]) or "0"
end

local function build_fold_levels(thread)
  local levels = {}
  for _, fold in ipairs(thread.folds or {}) do
    if fold.finish and fold.start and fold.finish > fold.start then
      levels[fold.start] = ">1"
      for lnum = fold.start + 1, fold.finish - 1 do
        levels[lnum] = "1"
      end
      levels[fold.finish] = "<1"
    end
  end
  thread.fold_levels = levels
end

function M.select_render_tree(thread)
  local blocks = {}
  util.list_extend(blocks, events.normalize_thread(thread))
  util.list_extend(blocks, thread.timeline_blocks or {})
  util.list_extend(blocks, events.pending_blocks(thread))
  util.list_extend(blocks, thread.local_blocks or {})
  if config.get().render.show_raw_events then
    util.list_extend(blocks, thread.raw_blocks or {})
  end
  return blocks
end

local function user_meta(thread, block)
  local labels = metadata.user_labels(thread, block)
  local ctx = metadata.context_label(thread, block)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
end

local function assistant_meta(thread, block)
  local labels = metadata.assistant_labels(thread, block)
  local ctx = metadata.context_label(thread, block)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
end

local function composer_meta(thread)
  local labels = metadata.composer_labels(thread)
  local ctx = metadata.context_label(thread)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
end

local function assistant_group_id(block)
  if not block or not assistant_content_types[block.type] then
    return nil
  end
  return block.message_id or "__assistant__"
end

local render_block

local function render_placeholder(thread, lines, block, opts)
  local key = block_key(block, opts)
  local expanded = placeholder_expanded(thread, key, block)
  local body_lines = expanded and placeholder_body_lines(block) or {}
  local line = add(lines, " ")
  local mark = mark_placeholder(thread, line, key, block, body_lines)
  if mark.decoration then
    mark_stream_decoration(thread, line, line, mark.decoration, block)
  end
end

render_block = function(thread, lines, block, opts)
  opts = opts or {}
  local start = #lines + 1
  if block.type == "UserBlock" then
    local line = add(lines, "## You")
    mark_header(thread, line, "user", "You", user_meta(thread, block), block)
    add(lines, "")
    add_text(lines, block.text)
  elseif block.type == "AssistantBlock" then
    if not opts.assistant_body then
      local line = add(lines, "## Codex")
      mark_header(thread, line, "assistant", "Codex", assistant_meta(thread, block), block)
      add(lines, "")
    end
    add_text(lines, block.text)
  elseif placeholder_types[block.type] then
    render_placeholder(thread, lines, block, opts)
  elseif block.type == "ErrorBlock" then
    local line = add(lines, "### Error")
    mark_header(thread, line, "section", "Error", {}, block)
    add_text(lines, events.block_text(block))
  else
    local title = tostring(block.type or "Block")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_text(lines, events.block_text(block))
  end
  local finish = #lines
  for lnum = start, finish do
    thread.render_index[lnum] = block
  end
  if block.type == "ReasoningBlock" and finish > start then
    mark_reasoning_lines(thread, start, finish)
  end
  if foldable_types[block.type] and finish > start then
    table.insert(thread.folds, { start = start, finish = finish })
  end
  local decoration = stream_decoration_for_block(block)
  if decoration and not placeholder_types[block.type] then
    local decoration_start = finish > start and start + 1 or start
    mark_stream_decoration(thread, decoration_start, finish, decoration, block)
  end
  add(lines, "")
end

local function render_assistant_group(thread, lines, blocks, index)
  local group_id = assistant_group_id(blocks[index])
  local first_block = blocks[index]
  local line = add(lines, "## Codex")
  mark_header(thread, line, "assistant", "Codex", assistant_meta(thread, first_block), first_block)
  add(lines, "")
  while index <= #blocks and assistant_group_id(blocks[index]) == group_id do
    render_block(thread, lines, blocks[index], { assistant_body = true, block_index = index })
    index = index + 1
  end
  return index
end

function M.render(thread)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end
  setup_highlights()

  local bufnr = thread.bufnr
  local snapshots = capture_window_views(thread, bufnr)
  local prompt = thread.prompt_lines or existing_prompt(thread)
  thread.prompt_lines = nil
  thread.render_index = {}
  thread.placeholder_index = {}
  thread.placeholder_marks = {}
  thread.header_marks = {}
  thread.reasoning_marks = {}
  thread.stream_decoration_marks = {}
  thread.spinner_mark = nil
  thread.folds = {}
  thread.fold_levels = {}

  local lines = {}
  local title_line
  for _, line in ipairs(header(thread)) do
    title_line = title_line or line
    add(lines, line)
  end
  add(lines, "")

  local blocks = M.select_render_tree(thread)
  local index = 1
  while index <= #blocks do
    if assistant_group_id(blocks[index]) then
      index = render_assistant_group(thread, lines, blocks, index)
    else
      render_block(thread, lines, blocks[index], { block_index = index })
      index = index + 1
    end
  end

  if thread_busy(thread) then
    local line = add(lines, " ")
    mark_spinner(thread, line)
    add(lines, "")
  end

  local prompt_marker = config.get().render.prompt_marker
  local prompt_line = add(lines, prompt_marker)
  mark_header(thread, prompt_line, "user", "You", composer_meta(thread), nil)
  add(lines, "")
  local prompt_start = #lines
  for _, prompt_text in ipairs(#prompt > 0 and prompt or { "" }) do
    add(lines, prompt_text)
  end
  thread.prompt_start = prompt_start
  build_fold_levels(thread)

  vim.bo[bufnr].modifiable = true
  replace_buffer_lines(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  apply_header_marks(thread, bufnr)
  apply_placeholder_marks(thread, bufnr)
  apply_reasoning_marks(thread, bufnr)
  apply_stream_decoration_marks(thread, bufnr)
  apply_spinner_marks(thread, bufnr)
  apply_composer_token_marks(thread, bufnr)
  vim.bo[bufnr].modifiable = true

  local virt = workspace_virt_text(thread, bufnr, title_line)
  if virt then
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_text = virt,
      virt_text_pos = "right_align",
    })
  end

  apply_window_views(thread, bufnr, snapshots)
  prune_view_states(thread, bufnr)
  if thread_busy(thread) then
    schedule_spinner_tick(thread)
  end
end

function M.toggle_under_cursor()
  local thread = require("codex.state").thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not a Codex thread buffer", vim.log.levels.ERROR)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local mark = thread.placeholder_index and thread.placeholder_index[lnum]
  if not mark then
    util.notify("No expandable Codex block under cursor", vim.log.levels.WARN)
    return
  end
  thread.expanded_blocks = thread.expanded_blocks or {}
  thread.expanded_blocks[mark.key] = not placeholder_expanded(thread, mark.key, mark.block)
  M.render(thread)
end

function M.schedule(thread, delay)
  if not thread or not thread.id then
    return
  end
  local key = tostring(thread.id)
  if pending_render_timers[key] then
    return
  end
  pending_render_timers[key] = vim.defer_fn(function()
    pending_render_timers[key] = nil
    M.render(thread)
  end, delay or config.get().ui.render_delay_ms)
end

function M.namespace()
  return ns
end

return M
