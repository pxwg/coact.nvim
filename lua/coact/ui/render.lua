local config = require("coact.config")
local events = require("coact.events")
local activity_summary = require("coact.ui.activity_summary")
local metadata = require("coact.ui.metadata")
local providers = require("coact.providers")
local tool_renderers = require("coact.ui.tool_renderers")
local util = require("coact.util")

local M = {}

local ns = vim.api.nvim_create_namespace("coact.nvim")
local render_atom_ns = vim.api.nvim_create_namespace("coact.nvim.render_atoms")
local follow_threshold = 5
local pending_render_timers = {}
local pending_spinner_timers = {}
local pending_stream_flush_timers = {}
local pending_stream_flushes = {}
local highlights_ready = false
local highlights_autocmd_ready = false
local stream_delta_flush_ms = 16

local foldable_types = {
  UserBlock = true,
  QueuedUserBlock = true,
  AssistantBlock = true,
  ErrorBlock = true,
}

local placeholder_types = {
  ActivitySummaryBlock = true,
  BranchSummaryBlock = true,
  CompactionSummaryBlock = true,
  ReasoningBlock = true,
  ToolCallBlock = true,
  PatchBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  PlanBlock = true,
}

local assistant_content_types = {
  ActivitySummaryBlock = true,
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
  ActivitySummaryBlock = { kind = "thinking", marker = "▎ ", hl_group = "CoactStreamPlan" },
  BranchSummaryBlock = { kind = "branch_summary", marker = "↳ ", hl_group = "CoactStreamBranchSummary" },
  CompactionSummaryBlock = {
    kind = "compaction_summary",
    marker = "◇ ",
    hl_group = "CoactStreamCompactionSummary",
  },
  ToolCallBlock = { kind = "tool", marker = "▌ ", hl_group = "CoactStreamTool" },
  PatchBlock = { kind = "patch", marker = "▌ ", hl_group = "CoactStreamPatch" },
  AgentTimelineBlock = { kind = "agent", marker = "▎ ", hl_group = "CoactStreamAgent" },
  RawEventBlock = { kind = "raw", marker = "╎ ", hl_group = "CoactStreamRaw" },
  PlanBlock = { kind = "plan", marker = "▎ ", hl_group = "CoactStreamPlan" },
}

local function define_highlights()
  vim.api.nvim_set_hl(0, "CoactHeaderUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactHeaderQueued", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactHeaderAssistant", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CoactHeaderAgent", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CoactHeaderSection", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactHeaderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactSpinner", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CoactReasoningText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactReasoningBorder", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "CoactComposerCommand", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "CoactComposerMention", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactComposerContext", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "CoactStreamTool", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactStreamPatch", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactStreamBranchSummary", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactStreamCompactionSummary", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactStreamAgent", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CoactStreamRaw", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactStreamPlan", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "CoactBlockPlaceholder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactBlockPlaceholderTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactBlockPlaceholderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactBlockPlaceholderHint", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "CoactStatusLineTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CoactStatusLineKey", { default = true, link = "Keyword" })
  vim.api.nvim_set_hl(0, "CoactStatusLineValue", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "CoactStatusLineState", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CoactStatusLineContext", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactStatusLineMessage", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CoactStatusLineWidget", { default = true, link = "String" })
  vim.api.nvim_set_hl(0, "CoactStatusLineHint", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactStatusLineSeparator", { default = true, link = "Delimiter" })
end

local function setup_highlights()
  if highlights_ready then
    return
  end
  define_highlights()
  highlights_ready = true
  if not highlights_autocmd_ready then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("coact.nvim.ui.highlights", { clear = true }),
      callback = define_highlights,
    })
    highlights_autocmd_ready = true
  end
end

M.setup_highlights = setup_highlights

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

local function fence_match(line)
  local indent, fence, rest = tostring(line or ""):match("^( *)([`~]+)(.*)$")
  if not indent or #indent > 3 or #fence < 3 then
    return nil
  end
  local char = fence:sub(1, 1)
  if not fence:match("^" .. vim.pesc(char) .. "+$") then
    return nil
  end
  return {
    char = char,
    len = #fence,
    rest = rest or "",
  }
end

local function unclosed_fence(lines)
  local open = nil
  for _, line in ipairs(lines or {}) do
    local fence = fence_match(line)
    if fence then
      if open then
        if fence.char == open.char and fence.len >= open.len and fence.rest:match("^%s*$") then
          open = nil
        end
      elseif fence.char == "~" or not fence.rest:find("`", 1, true) then
        open = fence
      end
    end
  end
  return open
end

local function mark_auto_closed_fence(thread, line)
  if not line then
    return
  end
  table.insert(thread.auto_closed_fence_lines, line)
end

local function add_guarded_text(thread, lines, value)
  local text_lines = util.split_lines(value)
  if #text_lines == 0 then
    local line = add(lines, "")
    return line, line, nil
  end

  local start_line = #lines + 1
  for _, line in ipairs(text_lines) do
    table.insert(lines, line)
  end

  local open = unclosed_fence(text_lines)
  local auto_closed_line = nil
  if open then
    table.insert(lines, string.rep(open.char, open.len))
    auto_closed_line = #lines
    mark_auto_closed_fence(thread, #lines)
  end

  return start_line, #lines, auto_closed_line
end

local function compact_text(value)
  return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate_display(value, limit)
  value = tostring(value or "")
  limit = tonumber(limit) or 96
  if limit <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(value) <= limit then
    return value
  end
  local suffix = "..."
  local target_width = math.max(0, limit - vim.fn.strdisplaywidth(suffix))
  local out = ""
  for index = 1, vim.fn.strchars(value) do
    local candidate = vim.fn.strcharpart(value, 0, index)
    if vim.fn.strdisplaywidth(candidate) > target_width then
      break
    end
    out = candidate
  end
  return out .. suffix
end

local function line_count(value)
  value = tostring(value or "")
  if value == "" then
    return 0
  end
  local _, count = value:gsub("\n", "")
  return count + 1
end

local function summary_preview(value)
  local fallback = ""
  local in_goal = false
  for _, line in ipairs(util.split_lines(value)) do
    local text = util.trim(line)
    if text:match("^##%s+Goal%s*$") then
      in_goal = true
    elseif in_goal and text:match("^##%s+") then
      in_goal = false
    elseif text ~= "" and not text:match("^#+%s*") then
      text = text:gsub("^[-*]%s+", ""):gsub("^%[[ xX]%]%s*", "")
      if in_goal then
        return truncate_display(compact_text(text), 88)
      end
      if fallback == "" and not text:match("^The user explored a different conversation branch") then
        fallback = text
      end
    end
  end
  return truncate_display(compact_text(fallback), 88)
end

local function summary_line_meta(block)
  local count = line_count(events.block_text(block))
  return count > 0 and (tostring(count) .. " line" .. (count == 1 and "" or "s")) or nil
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

local function meta_chunk(item)
  if type(item) == "table" then
    return tostring(item.text or item[1] or ""), item.hl_group or item.hl or "CoactHeaderMeta"
  end
  return tostring(item or ""), "CoactHeaderMeta"
end

local function header_hl(kind)
  if kind == "user" then
    return "CoactHeaderUser"
  end
  if kind == "queued" then
    return "CoactHeaderQueued"
  end
  if kind == "assistant" then
    return "CoactHeaderAssistant"
  end
  if kind == "agent" then
    return "CoactHeaderAgent"
  end
  return "CoactHeaderSection"
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

local function activity_counts(children)
  local counts = {
    reasoning = 0,
    tool = 0,
    patch = 0,
    plan = 0,
    agent = 0,
    raw = 0,
  }
  for _, child in ipairs(children or {}) do
    if child.type == "ReasoningBlock" then
      counts.reasoning = counts.reasoning + 1
    elseif child.type == "ToolCallBlock" then
      counts.tool = counts.tool + 1
    elseif child.type == "PatchBlock" then
      counts.patch = counts.patch + 1
    elseif child.type == "PlanBlock" then
      counts.plan = counts.plan + 1
    elseif child.type == "AgentTimelineBlock" then
      counts.agent = counts.agent + 1
    elseif child.type == "RawEventBlock" then
      counts.raw = counts.raw + 1
    end
  end
  return counts
end

local function plural_count(count, label)
  if count <= 0 then
    return nil
  end
  return tostring(count) .. " " .. label .. (count == 1 and "" or "s")
end

local function activity_count_labels(block)
  local counts = activity_counts(block and block.children)
  local labels = {}
  for _, label in ipairs({
    plural_count(counts.reasoning, "reasoning"),
    plural_count(counts.tool, "tool"),
    plural_count(counts.patch, "patch"),
    plural_count(counts.plan, "plan"),
    plural_count(counts.agent, "agent"),
    plural_count(counts.raw, "raw"),
  }) do
    if label then
      table.insert(labels, label)
    end
  end
  return labels
end

local function placeholder_meta(block)
  if block.type == "ActivitySummaryBlock" then
    local meta = activity_count_labels(block)
    table.insert(meta, 1, block.state or "finished")
    return meta
  end
  if block.type == "BranchSummaryBlock" or block.type == "CompactionSummaryBlock" then
    local meta = {}
    if block.type == "CompactionSummaryBlock" and tonumber(block.tokens_before) then
      table.insert(meta, tostring(math.floor(tonumber(block.tokens_before) + 0.5)) .. " tokens before")
    end
    local preview = summary_preview(events.block_text(block))
    if preview ~= "" then
      table.insert(meta, preview)
    end
    local lines = summary_line_meta(block)
    if lines then
      table.insert(meta, lines)
    end
    return meta
  end
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
  if block.type == "ActivitySummaryBlock" then
    return "Thinking finished"
  end
  if block.type == "BranchSummaryBlock" then
    return "Branch summary"
  end
  if block.type == "CompactionSummaryBlock" then
    return "Context compacted"
  end
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
  if block.type == "ActivitySummaryBlock" then
    return activity_summary.lines(block.children)
  end
  if block.type == "BranchSummaryBlock" then
    return util.split_lines(events.block_text(block))
  end
  if block.type == "CompactionSummaryBlock" then
    local lines = {}
    if tonumber(block.tokens_before) then
      table.insert(lines, ("Compacted from %d tokens."):format(math.floor(tonumber(block.tokens_before) + 0.5)))
      table.insert(lines, "")
    end
    vim.list_extend(lines, util.split_lines(events.block_text(block)))
    return lines
  end
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
  if block.item_id then
    thread.placeholder_by_item_id = thread.placeholder_by_item_id or {}
    thread.placeholder_by_item_id[tostring(block.item_id)] = mark
  end
  return mark
end

local function header_virt_text(mark)
  local hl_group = header_hl(mark.kind)
  return {
    { "▍ ", hl_group },
    { tostring(mark.title or ""), hl_group },
  }
end

local function header_meta_virt_text(mark)
  local chunks = {}
  if mark.meta and #mark.meta > 0 then
    for index, item in ipairs(mark.meta) do
      local text, hl_group = meta_chunk(item)
      if text ~= "" and text ~= "nil" then
        if #chunks > 0 then
          table.insert(chunks, { " · ", "CoactHeaderMeta" })
        end
        table.insert(chunks, { text, hl_group })
      end
    end
  end
  return chunks
end

local function resolve_mark_line(bufnr, namespace, mark)
  if not mark or not mark.extmark_id then
    return mark and mark.line or nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark.extmark_id, {})
  if type(pos) == "table" and #pos >= 2 then
    mark.line = pos[1] + 1
  end
  return mark.line
end

local function apply_header_marks(thread, bufnr)
  for _, mark in ipairs(thread.header_marks or {}) do
    resolve_mark_line(bufnr, ns, mark)
    local line = vim.api.nvim_buf_get_lines(bufnr, mark.line - 1, mark.line, false)[1] or ""
    local header_opts = {
      conceal = "",
      end_col = #line,
      virt_text = header_virt_text(mark),
      virt_text_pos = "overlay",
      priority = 2000,
      strict = false,
    }
    if mark.extmark_id then
      header_opts.id = mark.extmark_id
    end
    mark.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, header_opts)
    local meta = header_meta_virt_text(mark)
    if #meta > 0 then
      local meta_opts = {
        virt_text = meta,
        virt_text_pos = "right_align",
        priority = 1900,
        strict = false,
      }
      if mark.meta_extmark_id then
        meta_opts.id = mark.meta_extmark_id
      end
      mark.meta_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, meta_opts)
    end
    if mark.block then
      thread.render_index[mark.line] = mark.block
    end
  end
end

local function placeholder_virt_text(mark)
  local icon = mark.expanded and "▾ " or "▸ "
  local chunks = {
    { icon, mark.decoration and mark.decoration.hl_group or "CoactBlockPlaceholder" },
    { tostring(mark.title or "Block"), "CoactBlockPlaceholderTitle" },
  }
  for _, item in ipairs(mark.meta or {}) do
    local text = type(item) == "table" and (item.text or item[1]) or item
    if text and text ~= "" and text ~= "nil" then
      table.insert(chunks, { " · " .. tostring(text), "CoactBlockPlaceholderMeta" })
    end
  end
  table.insert(chunks, { mark.expanded and " · za collapse" or " · za expand", "CoactBlockPlaceholderHint" })
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
      table.insert(lines, { { "  ... truncated; open details for full content", "CoactBlockPlaceholderHint" } })
      break
    end
    table.insert(lines, {
      { "  │ ", mark.decoration and mark.decoration.hl_group or "CoactBlockPlaceholder" },
      { truncate_display(line, width), "CoactBlockPlaceholder" },
    })
  end
  if #lines == 0 then
    table.insert(lines, { { "  │ (empty)", "CoactBlockPlaceholderMeta" } })
  end
  return lines
end

local function apply_placeholder_mark(_, bufnr, mark)
  if not mark or not mark.line then
    return
  end
  resolve_mark_line(bufnr, ns, mark)
  local opts = {
    conceal = "",
    virt_text = placeholder_virt_text(mark),
    virt_text_pos = "overlay",
    virt_lines = virtual_body_lines(mark),
    priority = 1900,
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

local function apply_placeholder_marks(thread, bufnr)
  for _, mark in ipairs(thread.placeholder_marks or {}) do
    apply_placeholder_mark(thread, bufnr, mark)
  end
end

local function apply_reasoning_marks(thread, bufnr)
  for _, mark in ipairs(thread.reasoning_marks or {}) do
    local lines = vim.api.nvim_buf_get_lines(bufnr, mark.start_line - 1, mark.finish_line, false)
    if #lines > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, mark.start_line - 1, 0, {
        end_row = mark.finish_line - 1,
        end_col = #(lines[#lines] or ""),
        hl_group = "CoactReasoningText",
        hl_mode = "combine",
        priority = 900,
        strict = false,
      })
    end
    for offset = 1, #lines do
      vim.api.nvim_buf_set_extmark(bufnr, ns, mark.start_line + offset - 2, 0, {
        virt_text = { { "▏ ", "CoactReasoningBorder" } },
        virt_text_pos = "inline",
        priority = 1200,
        strict = false,
      })
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

local function buffer_line_length(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return #line
end

local function apply_auto_closed_fence_marks(thread, bufnr)
  for _, line in ipairs(thread.auto_closed_fence_lines or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      end_col = buffer_line_length(bufnr, line),
      hl_group = "Comment",
      priority = 1200,
      strict = false,
    })
  end
end

local spinner_frames = {
  "⠋",
  "⠙",
  "⠹",
  "⠸",
  "⠼",
  "⠴",
  "⠦",
  "⠧",
  "⠇",
  "⠏",
}

local spinner_interval_ms = 80

local busy_generations = {
  submitted = true,
  waiting_backend = true,
  streaming = true,
  summarizing = true,
  tool_running = true,
  patch_review = true,
  reconciling = true,
  cancelling = true,
}

local busy_sync_states = {
  starting = true,
  restoring = true,
  hydrating = true,
}

local function thread_busy(thread)
  return thread and (busy_generations[thread.generation] == true or busy_sync_states[thread.sync] == true)
end

local function spinner_label(thread)
  if busy_generations[thread.generation] ~= true and busy_sync_states[thread.sync] == true then
    return thread.sync_message or "Opening provider session…"
  end
  return thread.generation == "tool_running" and "tooling"
    or thread.generation == "patch_review" and "reviewing patch"
    or thread.generation == "waiting_backend" and "waiting"
    or thread.generation == "summarizing" and "summarizing..."
    or thread.generation == "reconciling" and "syncing"
    or thread.generation == "cancelling" and "stopping"
    or thread.generation == "submitted" and "thinking"
    or "streaming"
end

local function spinner_virt_text(thread)
  if thread.sync == "failed" then
    local message = tostring(thread.sync_message or "Could not open provider session")
    if thread.last_error and thread.last_error ~= "" then
      message = message .. " · " .. tostring(thread.last_error):gsub("\n", " ")
    end
    return { { "×  Coact · " .. message, "DiagnosticError" } }
  end
  local index = (math.floor(util.now_ms() / spinner_interval_ms) % #spinner_frames) + 1
  local separator = busy_generations[thread.generation] ~= true and busy_sync_states[thread.sync] == true and " · "
    or " "
  return { { spinner_frames[index] .. "  Coact" .. separator .. spinner_label(thread), "CoactSpinner" } }
end

local function apply_spinner_mark(thread, bufnr, mark)
  if not mark then
    return
  end
  resolve_mark_line(bufnr, ns, mark)
  if not mark.line or mark.line < 1 or mark.line > vim.api.nvim_buf_line_count(bufnr) then
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
  end, spinner_interval_ms)
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
    return "CoactComposerCommand"
  end
  if prefix == "@" then
    return "CoactComposerMention"
  end
  if prefix == ">" then
    return "CoactComposerContext"
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

function M.apply_prompt_marks(_, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for offset, line in ipairs(lines) do
    local lnum0 = offset - 1
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

local function header(thread)
  return { "# Coact: " .. tostring(thread.title or util.short_id(thread.id)) }
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

local anchor_follow_window

local function capture_follow_windows(thread, bufnr)
  local wins = {}
  if not config.get().ui.auto_scroll then
    return wins
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local state = view_state_for_win(thread, win)
      if state.follow == nil then
        state.follow = M.window_near_bottom(thread, win)
        state.suspended_by_user = not state.follow
      end
      if state.follow and not state.suspended_by_user then
        table.insert(wins, win)
      end
    end
  end
  return wins
end

local function apply_follow_windows(thread, wins)
  for _, win in ipairs(wins or {}) do
    if valid_window_for_buffer(win, thread.bufnr) then
      anchor_follow_window(thread, win)
    end
  end
end

local function follow_cursor_line(thread, line_count_value)
  if thread.prompt_start then
    return clamp_lnum(thread.prompt_start + 1, line_count_value)
  end
  return line_count_value
end

anchor_follow_window = function(thread, win)
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

function M.follow_latest(thread, win)
  if not thread or not win then
    return
  end
  anchor_follow_window(thread, win)
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
      require("coact.buffers").apply_window_options(win, bufnr)
      if snapshot and snapshot.prompt_anchor then
        restore_prompt_anchor(thread, win, snapshot)
      elseif config.get().ui.auto_scroll and view_state.follow and not view_state.suspended_by_user then
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

local function apply_manual_folds(thread, bufnr)
  bufnr = bufnr or (thread and thread.bufnr)
  if not thread or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local line_total = vim.api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        vim.wo[win].foldmethod = "manual"
        vim.wo[win].foldenable = true
        vim.wo[win].foldlevel = 99
        vim.cmd("silent! normal! zE")
        for _, fold in ipairs(thread.folds or {}) do
          local start_line = tonumber(fold.start)
          local finish_line = tonumber(fold.finish)
          if start_line and finish_line and finish_line > start_line and start_line >= 1 then
            finish_line = math.min(finish_line, line_total)
            if finish_line > start_line then
              vim.cmd(("silent! %d,%dfold"):format(start_line, finish_line))
            end
          end
        end
        vim.cmd("silent! normal! zR")
        vim.fn.winrestview(view)
      end)
    end
  end
end

M.apply_manual_folds = apply_manual_folds

local function guarded_text_lines(value)
  local lines = util.split_lines(value)
  if #lines == 0 then
    return { "" }, nil
  end
  local open = unclosed_fence(lines)
  if open then
    local copy = vim.deepcopy(lines)
    table.insert(copy, string.rep(open.char, open.len))
    return copy, #copy
  end
  return lines, nil
end

local function text_has_fence(value)
  for _, line in ipairs(util.split_lines(value)) do
    if fence_match(line) then
      return true
    end
  end
  return false
end

local function set_modifiable_text(bufnr, fn)
  local previous_modifiable = vim.bo[bufnr].modifiable
  local previous_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].undolevels = -1
  local ok, err = pcall(fn)
  vim.bo[bufnr].undolevels = previous_undolevels
  vim.bo[bufnr].modifiable = previous_modifiable
  if not ok then
    error(err)
  end
end

local function record_render_atom(thread, block, range)
  local atom = vim.tbl_extend("force", range, {
    block = block,
    item_id = block.item_id and tostring(block.item_id) or nil,
  })
  atom.text_offset = atom.text_start and (atom.text_start - atom.start) or nil
  atom.has_auto_closed_fence = atom.auto_closed_line ~= nil
  table.insert(thread.render_atoms, atom)
  if block.type == "AssistantBlock" and atom.item_id and atom.text_start then
    thread.stream_atoms_by_item_id[atom.item_id] = atom
  end
  return atom
end

local function apply_render_atom_anchors(thread, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, render_atom_ns, 0, -1)
  for _, atom in ipairs(thread.render_atoms or {}) do
    atom.start_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, render_atom_ns, atom.start - 1, 0, {
      right_gravity = false,
      strict = false,
    })
    atom.finish_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, render_atom_ns, atom.finish, 0, {
      right_gravity = true,
      strict = false,
    })
  end
end

local function resolve_render_atom(bufnr, atom)
  if not atom or not atom.start_extmark_id or not atom.finish_extmark_id then
    return false
  end
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, render_atom_ns, atom.start_extmark_id, {})
  local finish_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, render_atom_ns, atom.finish_extmark_id, {})
  if #start_pos < 2 or #finish_pos < 2 then
    return false
  end
  atom.start = start_pos[1] + 1
  atom.finish = finish_pos[1]
  if atom.finish < atom.start then
    return false
  end
  if atom.text_offset then
    atom.text_start = atom.start + atom.text_offset
    atom.text_finish = atom.finish
  end
  atom.auto_closed_line = atom.has_auto_closed_fence and atom.finish or nil
  return true
end

local function refresh_render_atom_indexes(thread)
  local bufnr = thread and thread.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  thread.render_index = {}
  thread.placeholder_index = {}
  thread.placeholder_by_item_id = {}
  thread.stream_atoms_by_item_id = {}
  thread.auto_closed_fence_lines = {}

  for _, atom in ipairs(thread.render_atoms or {}) do
    if resolve_render_atom(bufnr, atom) then
      for lnum = atom.start, atom.finish do
        thread.render_index[lnum] = atom.block
      end
      if atom.item_id and atom.block.type == "AssistantBlock" and atom.text_start then
        thread.stream_atoms_by_item_id[atom.item_id] = atom
      end
      if atom.has_auto_closed_fence then
        table.insert(thread.auto_closed_fence_lines, atom.finish)
      end
      if atom.fold then
        atom.fold.start = atom.start
        atom.fold.finish = atom.finish
      end
    end
  end

  for _, mark in ipairs(thread.header_marks or {}) do
    resolve_mark_line(bufnr, ns, mark)
    if mark.block and mark.line then
      thread.render_index[mark.line] = mark.block
    end
  end
  for _, mark in ipairs(thread.placeholder_marks or {}) do
    resolve_mark_line(bufnr, ns, mark)
    if mark.line then
      thread.placeholder_index[mark.line] = mark
      thread.render_index[mark.line] = mark.block
    end
    if mark.block and mark.block.item_id then
      thread.placeholder_by_item_id[tostring(mark.block.item_id)] = mark
    end
  end
  resolve_mark_line(bufnr, ns, thread.spinner_mark)
end

local compact_hook_timeline_blocks

local activity_summary_types = {
  ReasoningBlock = true,
  ToolCallBlock = true,
  PatchBlock = true,
  AgentTimelineBlock = true,
  PlanBlock = true,
  RawEventBlock = true,
}

local function visible_assistant_block(block)
  return block and block.type == "AssistantBlock" and util.trim(events.block_text(block)) ~= ""
end

local function response_groups(blocks)
  local groups = {}
  local groups_by_turn = {}
  local group_by_block = {}
  local current = nil

  local function start_group(block)
    local seed = util.value(block and block.item_id) or util.value(block and block.message_id) or tostring(#groups + 1)
    local group = {
      id = "response:" .. tostring(seed),
      outputs = {},
    }
    table.insert(groups, group)
    current = group
    return group
  end

  for _, block in ipairs(blocks or {}) do
    local turn_id = util.value(block.message_id)
    local group = turn_id and groups_by_turn[turn_id] or nil
    if block.type == "BranchSummaryBlock" or block.type == "CompactionSummaryBlock" then
      current = nil
      groups_by_turn = {}
      group = nil
    elseif block.type == "UserBlock" then
      group = start_group(block)
      if turn_id then
        groups_by_turn[turn_id] = group
      end
    elseif not group and turn_id and block.local_only ~= true then
      -- Pi may use several backend turn ids for one user/assistant run. Only
      -- ordered provider blocks extend it; appended local blocks must refer
      -- to an id that was already assigned.
      group = current or start_group(block)
      groups_by_turn[turn_id] = group
    end

    if group then
      group_by_block[block] = group
      if visible_assistant_block(block) then
        table.insert(group.outputs, block)
      end
    end
  end

  return groups, group_by_block
end

local function response_grouped_block(block, group)
  if not group or block.type == "UserBlock" then
    return block
  end
  return vim.tbl_extend("force", {}, block, { response_group_id = group.id })
end

local function activity_summary_block(group, output, children)
  local output_id = util.value(output.item_id) or util.value(output.message_id) or group.id
  return {
    type = "ActivitySummaryBlock",
    message_id = output.message_id,
    item_id = "activity-summary:" .. tostring(output_id),
    title = "Thinking finished",
    state = "finished",
    children = children,
    raw = {
      children = children,
    },
    local_only = true,
    response_group_id = group.id,
  }
end

local function compact_activity_segments(thread, blocks)
  local _, group_by_block = response_groups(blocks)
  local next_output = {}
  local target_by_activity = {}

  for index = #blocks, 1, -1 do
    local block = blocks[index]
    local group = group_by_block[block]
    if group then
      if visible_assistant_block(block) then
        next_output[group] = block
      elseif activity_summary_types[block.type] then
        local target = next_output[group]
        if not target and block.local_only == true and not thread_busy(thread) then
          target = group.outputs[#group.outputs]
        end
        target_by_activity[block] = target
      end
    end
  end

  local children_by_output = {}
  for _, block in ipairs(blocks or {}) do
    local output = target_by_activity[block]
    if output then
      children_by_output[output] = children_by_output[output] or {}
      table.insert(children_by_output[output], block)
    end
  end

  local out = {}
  for _, block in ipairs(blocks or {}) do
    local output = target_by_activity[block]
    if not output then
      if visible_assistant_block(block) and children_by_output[block] then
        table.insert(out, activity_summary_block(group_by_block[block], block, children_by_output[block]))
      end
      table.insert(out, response_grouped_block(block, group_by_block[block]))
    end
  end
  return out
end

-- Pi owns placement through messages/content slots. Reasoning and tools keep
-- their own foldable blocks; wrapping them under a later output would change
-- both identity and placement as streaming output arrives.
local function pi_render_blocks(blocks)
  local _, group_by_block = response_groups(blocks)
  local out = {}
  for _, block in ipairs(blocks) do
    table.insert(out, response_grouped_block(block, group_by_block[block]))
  end
  return out
end

function M.select_render_tree(thread)
  local blocks = {}
  util.list_extend(blocks, events.normalize_thread(thread))
  util.list_extend(blocks, compact_hook_timeline_blocks(thread.timeline_blocks))
  util.list_extend(blocks, events.pending_blocks(thread))
  util.list_extend(blocks, thread.local_blocks or {})
  if config.get().render.show_raw_events then
    util.list_extend(blocks, thread.raw_blocks or {})
  end
  if tostring(thread.id):match("^pi:") then
    return pi_render_blocks(blocks)
  end
  return compact_activity_segments(thread, blocks)
end

local function user_meta(thread, block)
  local labels = metadata.user_labels(thread, block)
  local ctx = metadata.context_label(thread, block)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
end

local function queued_user_meta(thread, block)
  local labels = user_meta(thread, block)
  if block.queue_count and block.queue_count > 1 then
    labels[1] = ("queued %d/%d"):format(block.queue_position or 1, block.queue_count)
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

local function assistant_group_id(block)
  if not block or not assistant_content_types[block.type] then
    return nil
  end
  return util.value(block.response_group_id) or util.value(block.message_id) or "__assistant__"
end

local function legacy_hook_timeline_block(block)
  return block
    and block.type == "AgentTimelineBlock"
    and not block.hook_run_order
    and tostring(block.title or ""):match("^Hook:")
end

compact_hook_timeline_blocks = function(blocks)
  local out = {}
  local groups = {}
  for _, block in ipairs(blocks or {}) do
    if legacy_hook_timeline_block(block) then
      local key = table.concat({
        tostring(block.message_id or ""),
        tostring(block.title or "Hook"),
      }, ":")
      local group = groups[key]
      if not group then
        group = {
          type = "AgentTimelineBlock",
          message_id = block.message_id,
          item_id = "compact:" .. key,
          title = block.title,
          state = block.state,
          text = "",
          metadata = vim.tbl_extend("force", block.metadata or {}, { source = "hook" }),
          raw = block.raw,
          local_only = block.local_only,
          compact_hook_events = {},
        }
        groups[key] = group
        table.insert(out, group)
      end
      if block.state == "running" then
        group.state = "running"
      else
        group.state = block.state or group.state
      end
      local summary = truncate_display(compact_text(events.block_text(block)), 140)
      table.insert(
        group.compact_hook_events,
        ("- %s: %s"):format(
          tostring(block.state or "unknown"),
          summary ~= "" and summary or tostring(block.item_id or "hook")
        )
      )
      group.text = ("%d hook event%s for %s.\n%s"):format(
        #group.compact_hook_events,
        #group.compact_hook_events == 1 and "" or "s",
        tostring(block.title or "Hook"),
        table.concat(group.compact_hook_events, "\n")
      )
    else
      table.insert(out, block)
    end
  end
  return out
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
  local text_start = nil
  local text_finish = nil
  local auto_closed_line = nil
  if block.type == "UserBlock" then
    local line = add(lines, "## You")
    mark_header(thread, line, "user", "You", user_meta(thread, block), block)
    add(lines, "")
    add_guarded_text(thread, lines, block.text)
  elseif block.type == "QueuedUserBlock" then
    local line = add(lines, "## Queued request")
    mark_header(thread, line, "queued", "Queued request", queued_user_meta(thread, block), block)
    add(lines, "")
    add_guarded_text(thread, lines, block.text)
  elseif block.type == "AssistantBlock" then
    if not opts.assistant_body then
      local line = add(lines, "## Coact")
      mark_header(thread, line, "assistant", providers.agent_label(), assistant_meta(thread, block), block)
      add(lines, "")
    end
    text_start, text_finish, auto_closed_line = add_guarded_text(thread, lines, block.text)
  elseif placeholder_types[block.type] then
    render_placeholder(thread, lines, block, opts)
  elseif block.type == "ErrorBlock" then
    local line = add(lines, "### Error")
    mark_header(thread, line, "section", "Error", {}, block)
    add_guarded_text(thread, lines, events.block_text(block))
  else
    local title = tostring(block.type or "Block")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_guarded_text(thread, lines, events.block_text(block))
  end
  local finish = #lines
  for lnum = start, finish do
    thread.render_index[lnum] = block
  end
  if block.type == "ReasoningBlock" and finish > start then
    mark_reasoning_lines(thread, start, finish)
  end
  local fold_index = nil
  if foldable_types[block.type] and finish > start then
    table.insert(thread.folds, { start = start, finish = finish })
    fold_index = #thread.folds
  end
  local decoration = stream_decoration_for_block(block)
  if decoration and not placeholder_types[block.type] then
    local decoration_start = finish > start and start + 1 or start
    mark_stream_decoration(thread, decoration_start, finish, decoration, block)
  end
  local atom = record_render_atom(thread, block, {
    start = start,
    finish = finish,
    text_start = text_start,
    text_finish = text_finish,
    auto_closed_line = auto_closed_line,
    has_fence = text_has_fence(block.text or events.block_text(block)),
  })
  if fold_index then
    atom.fold = thread.folds[fold_index]
  end
  add(lines, "")
end

local function render_assistant_group(thread, lines, blocks, index)
  local group_id = assistant_group_id(blocks[index])
  local header_block = blocks[index]
  local cursor = index
  while cursor <= #blocks and assistant_group_id(blocks[cursor]) == group_id do
    if visible_assistant_block(blocks[cursor]) then
      header_block = blocks[cursor]
    end
    cursor = cursor + 1
  end

  local line = add(lines, "## Coact")
  mark_header(thread, line, "assistant", providers.agent_label(), assistant_meta(thread, header_block), header_block)
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
  thread.prompt_lines = nil
  thread.prompt_start = nil
  thread.render_index = {}
  thread.placeholder_index = {}
  thread.placeholder_by_item_id = {}
  thread.render_atoms = {}
  thread.stream_atoms_by_item_id = {}
  thread.placeholder_marks = {}
  thread.header_marks = {}
  thread.auto_closed_fence_lines = {}
  thread.reasoning_marks = {}
  thread.stream_decoration_marks = {}
  thread.spinner_mark = nil
  thread.folds = {}

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

  if thread_busy(thread) or thread.sync == "failed" then
    local line = add(lines, " ")
    mark_spinner(thread, line)
    add(lines, "")
  end

  vim.bo[bufnr].modifiable = true
  replace_buffer_lines(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  apply_render_atom_anchors(thread, bufnr)
  apply_auto_closed_fence_marks(thread, bufnr)
  apply_header_marks(thread, bufnr)
  apply_placeholder_marks(thread, bufnr)
  apply_reasoning_marks(thread, bufnr)
  apply_stream_decoration_marks(thread, bufnr)
  apply_spinner_marks(thread, bufnr)
  apply_composer_token_marks(thread, bufnr)
  vim.bo[bufnr].modifiable = false

  local virt = workspace_virt_text(thread, bufnr, title_line)
  if virt then
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_text = virt,
      virt_text_pos = "right_align",
    })
  end

  apply_window_views(thread, bufnr, snapshots)
  apply_manual_folds(thread, bufnr)
  prune_view_states(thread, bufnr)
  local buffers = require("coact.buffers")
  buffers.refresh_composer(thread)
  buffers.refresh_chrome(thread)
  if thread_busy(thread) then
    schedule_spinner_tick(thread)
  end
end

local function replace_stream_atom_text(thread, atom, value)
  local bufnr = thread.bufnr
  local lines, auto_closed_index = guarded_text_lines(value)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, atom.text_start - 1, atom.text_finish)
  set_modifiable_text(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, atom.text_start - 1, atom.text_finish, false, lines)
  end)
  atom.has_auto_closed_fence = auto_closed_index ~= nil
  atom.has_fence = text_has_fence(value)
  if atom.has_auto_closed_fence then
    local line = atom.text_start + auto_closed_index - 1
    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
      end_col = buffer_line_length(bufnr, line),
      hl_group = "Comment",
      priority = 1200,
      strict = false,
    })
  end
end

local function append_stream_atom_delta(thread, atom, delta)
  local bufnr = thread.bufnr
  local current_line = vim.api.nvim_buf_get_lines(bufnr, atom.text_finish - 1, atom.text_finish, false)[1] or ""
  local parts = vim.split(delta, "\n", { plain = true })
  set_modifiable_text(bufnr, function()
    vim.api.nvim_buf_set_text(bufnr, atom.text_finish - 1, #current_line, atom.text_finish - 1, #current_line, parts)
  end)
end

local function stream_flush_key(thread)
  return tostring(thread.id or "")
end

local function flush_stream_atoms(key)
  local pending = pending_stream_flushes[key]
  pending_stream_flushes[key] = nil
  pending_stream_flush_timers[key] = nil
  if not pending then
    return
  end

  local thread = pending.thread
  local bufnr = thread and thread.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local edits = {}
  for item_id, item_pending in pairs(pending.items) do
    local atom = thread.stream_atoms_by_item_id and thread.stream_atoms_by_item_id[item_id]
    local item = thread.items and thread.items[item_id]
    if atom and item and item.type == "agentMessage" and resolve_render_atom(bufnr, atom) then
      table.insert(edits, {
        atom = atom,
        item = item,
        pending = item_pending,
      })
    end
  end
  table.sort(edits, function(left, right)
    return left.atom.start > right.atom.start
  end)

  local follows = capture_follow_windows(thread, bufnr)
  for _, edit in ipairs(edits) do
    local atom = edit.atom
    local item = edit.item
    local desired = tostring(item.text or "")
    local rendered = tostring(atom.block.text or "")
    if desired ~= rendered and resolve_render_atom(bufnr, atom) then
      local can_append = not atom.has_auto_closed_fence
        and not atom.has_fence
        and not edit.pending.has_fence
        and desired == rendered .. edit.pending.delta
      if can_append then
        append_stream_atom_delta(thread, atom, edit.pending.delta)
      else
        replace_stream_atom_text(thread, atom, desired)
      end
    end
    atom.block.text = desired
    atom.block.raw = item
    atom.block.state = item.status or item.phase or item.state or atom.block.state
  end

  refresh_render_atom_indexes(thread)
  if thread_busy(thread) and thread.spinner_mark then
    apply_spinner_mark(thread, bufnr, thread.spinner_mark)
    schedule_spinner_tick(thread)
  end
  apply_follow_windows(thread, follows)
end

local function queue_stream_delta(thread, item_id, delta)
  local key = stream_flush_key(thread)
  local pending = pending_stream_flushes[key]
  if not pending then
    pending = {
      thread = thread,
      items = {},
    }
    pending_stream_flushes[key] = pending
  end

  item_id = tostring(item_id)
  local item_pending = pending.items[item_id]
  if not item_pending then
    item_pending = {
      delta = "",
      has_fence = false,
    }
    pending.items[item_id] = item_pending
  end
  delta = tostring(delta or "")
  item_pending.delta = item_pending.delta .. delta
  item_pending.has_fence = item_pending.has_fence
    or delta:find("```", 1, true) ~= nil
    or delta:find("~~~", 1, true) ~= nil

  if not pending_stream_flush_timers[key] then
    pending_stream_flush_timers[key] = vim.defer_fn(function()
      flush_stream_atoms(key)
    end, stream_delta_flush_ms)
  end
end

function M.try_stream_delta(thread, item_id, delta)
  delta = util.value(delta)
  if not thread or not item_id or delta == nil or delta == "" then
    return false
  end
  local bufnr = thread.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  item_id = tostring(item_id)
  local atom = thread.stream_atoms_by_item_id and thread.stream_atoms_by_item_id[item_id]
  if not atom or not resolve_render_atom(bufnr, atom) then
    return false
  end
  local item = thread.items and thread.items[item_id]
  if not item or item.type ~= "agentMessage" then
    return false
  end
  queue_stream_delta(thread, item_id, delta)
  return true
end

local function refresh_placeholder_block(thread, mark, item_id)
  resolve_mark_line(thread.bufnr, ns, mark)
  local item = thread.items and thread.items[tostring(item_id)]
  if item then
    local turn_id = thread.item_turns and thread.item_turns[tostring(item_id)]
    local block = events.block_for_item(item, turn_id)
    if block then
      mark.block = block
    end
  end
  mark.title = placeholder_title(mark.block)
  mark.meta = placeholder_meta(mark.block)
  mark.decoration = stream_decoration_for_block(mark.block)
  mark.body_lines = mark.expanded and placeholder_body_lines(mark.block) or {}
  thread.render_index[mark.line] = mark.block
end

function M.try_stream_placeholder_delta(thread, item_id)
  if not thread or not item_id or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return false
  end
  local mark = thread.placeholder_by_item_id and thread.placeholder_by_item_id[tostring(item_id)]
  if not mark then
    return false
  end
  refresh_placeholder_block(thread, mark, item_id)
  apply_placeholder_mark(thread, thread.bufnr, mark)
  if thread_busy(thread) and thread.spinner_mark then
    apply_spinner_mark(thread, thread.bufnr, thread.spinner_mark)
    schedule_spinner_tick(thread)
  end
  return true
end

function M.toggle_under_cursor()
  local thread = require("coact.state").thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not a Coact thread buffer", vim.log.levels.ERROR)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local mark = thread.placeholder_index and thread.placeholder_index[lnum]
  if not mark then
    util.notify("No expandable Coact block under cursor", vim.log.levels.WARN)
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
