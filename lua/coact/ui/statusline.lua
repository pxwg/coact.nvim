local config = require("coact.config")
local providers = require("coact.providers")
local state = require("coact.state")
local util = require("coact.util")

local M = {}

local function composer_statusline_config()
  local ui = config.get().ui or {}
  local composer = ui.composer or {}
  local statusline = composer.statusline
  if type(statusline) ~= "table" then
    statusline = {}
  end
  return statusline
end

local function provider_ui(thread)
  local ui = thread and thread.provider_ui
  if type(ui) ~= "table" then
    return nil
  end
  return ui
end

local function is_pi_thread(thread)
  return providers.current_id(thread) == "pi" or tostring(thread and thread.id or ""):match("^pi:") ~= nil
end

local function clean_status_text(text)
  local value = util.value(text)
  if value == nil then
    return nil
  end
  value = util.strip_ansi(value):gsub("[\r\n\t]", " "):gsub(" +", " ")
  value = util.trim(value)
  if value == "" then
    return nil
  end
  return value
end

local function label(value)
  return clean_status_text(value)
end

local function format_tokens(count)
  count = tonumber(util.value(count))
  if not count then
    return nil
  end
  if count < 1000 then
    return tostring(count)
  end
  if count < 10000 then
    return ("%.1fk"):format(count / 1000)
  end
  if count < 1000000 then
    return ("%dk"):format(math.floor(count / 1000 + 0.5))
  end
  if count < 10000000 then
    return ("%.1fM"):format(count / 1000000)
  end
  return ("%dM"):format(math.floor(count / 1000000 + 0.5))
end

local function setting_label(value)
  if type(value) == "table" then
    return label(value.id) or label(value.name) or label(value.label) or label(value.title) or label(value.type)
  end
  return label(value)
end

local function setting_labels(thread)
  local cfg = config.get().thread or {}
  local effective = state.effective_thread_settings(thread, cfg)
  return {
    model = setting_label(effective.model),
    provider = setting_label(effective.model_provider),
    service_tier = setting_label(effective.service_tier),
    effort = setting_label(effective.reasoning_effort),
  }
end

local function add_segment(segments, key, value, opts)
  value = label(value)
  if not value then
    return
  end
  table.insert(segments, {
    key = key,
    value = value,
    value_hl = opts and opts.value_hl,
    key_hl = opts and opts.key_hl,
  })
end

local function usage_value(usage, ...)
  if type(usage) ~= "table" then
    return nil
  end
  for index = 1, select("#", ...) do
    local key = select(index, ...)
    local value = util.value(usage[key])
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function usage_context(usage)
  if type(usage) ~= "table" then
    return nil
  end
  return type(usage.contextUsage) == "table" and usage.contextUsage
    or type(usage.context_usage) == "table" and usage.context_usage
    or nil
end

local function auto_compaction_enabled(thread, usage)
  local value = util.value(thread and thread.auto_compaction_enabled)
  if value ~= nil then
    return value == true
  end
  value = util.value(usage and (usage.autoCompactionEnabled or usage.auto_compaction_enabled))
  if value ~= nil then
    return value == true
  end
  value = util.value(
    thread and thread.thread and (thread.thread.autoCompactionEnabled or thread.thread.auto_compaction_enabled)
  )
  return value == true
end

local function context_usage_text(thread)
  local usage = type(thread and thread.token_usage) == "table" and thread.token_usage or nil
  local context = usage_context(usage)
  if not context then
    return nil
  end
  local context_window = util.value(context.contextWindow or context.context_window)
  local percent = util.value(context.percent)
  local text
  if percent == nil or percent == vim.NIL then
    text = "?/" .. tostring(format_tokens(context_window) or "?")
  else
    text = ("%.1f%%/%s"):format(tonumber(percent) or 0, format_tokens(context_window) or "?")
  end
  if auto_compaction_enabled(thread, usage) then
    text = text .. " (auto)"
  end
  return text
end

local function token_usage_segments(thread)
  local usage = type(thread and thread.token_usage) == "table" and thread.token_usage or nil
  if not usage then
    return {}
  end
  local segments = {}
  local input = format_tokens(usage_value(usage, "inputTokens", "input_tokens", "input"))
  local output = format_tokens(usage_value(usage, "outputTokens", "output_tokens", "output"))
  local cache_read =
    format_tokens(usage_value(usage, "cacheReadTokens", "cache_read_tokens", "cacheRead", "cache_read"))
  local cache_write =
    format_tokens(usage_value(usage, "cacheWriteTokens", "cache_write_tokens", "cacheWrite", "cache_write"))
  add_segment(segments, nil, input and ("↑" .. input) or nil)
  add_segment(segments, nil, output and ("↓" .. output) or nil)
  add_segment(segments, nil, cache_read and ("R" .. cache_read) or nil)
  add_segment(segments, nil, cache_write and ("W" .. cache_write) or nil)
  add_segment(segments, "context", context_usage_text(thread), { value_hl = "CoactStatusLineContext" })
  local cost = usage_value(usage, "cost", "totalCost", "total_cost")
  if type(cost) == "table" then
    cost = usage_value(cost, "total")
  end
  cost = tonumber(util.value(cost))
  if cost then
    add_segment(segments, nil, ("$%.3f"):format(cost))
  end
  return segments
end

local function status_entries(ui)
  local statuses = type(ui and ui.statuses) == "table" and ui.statuses or {}
  local keys = vim.tbl_keys(statuses)
  table.sort(keys)
  local entries = {}
  for _, key in ipairs(keys) do
    local text = clean_status_text(statuses[key])
    if text then
      table.insert(entries, { key = tostring(key), text = text })
    end
  end
  return entries
end

local function widget_entries(ui, placement)
  local by_key = type(ui and ui.widgets) == "table" and ui.widgets[placement] or nil
  if type(by_key) ~= "table" then
    return {}
  end
  local keys = vim.tbl_keys(by_key)
  table.sort(keys)
  local entries = {}
  for _, key in ipairs(keys) do
    local value = by_key[key]
    local lines = type(value) == "table" and value.lines or nil
    if type(lines) == "table" and #lines > 0 then
      table.insert(entries, { key = tostring(key), lines = lines })
    end
  end
  return entries
end

local function has_provider_ui_content(thread)
  local ui = provider_ui(thread)
  if not ui then
    return false
  end
  if label(ui.title) then
    return true
  end
  if #status_entries(ui) > 0 then
    return true
  end
  if #widget_entries(ui, "aboveEditor") > 0 or #widget_entries(ui, "belowEditor") > 0 then
    return true
  end
  return false
end

local function has_settings_or_usage(thread)
  local settings = setting_labels(thread)
  if settings.model or settings.provider or settings.service_tier or settings.effort then
    return true
  end
  if #token_usage_segments(thread) > 0 then
    return true
  end
  return label(thread and thread.status_message) ~= nil
end

function M.visible(thread)
  local opts = composer_statusline_config()
  if opts.enabled == false then
    return false
  end
  if thread and thread.composer_statusline_visible ~= nil then
    return thread.composer_statusline_visible == true
  end
  return opts.default_visible ~= false
end

function M.has_content(thread)
  if not thread then
    return false
  end
  if has_provider_ui_content(thread) then
    return true
  end
  return is_pi_thread(thread) or has_settings_or_usage(thread)
end

local function display_width(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function truncate_to_width(text, width)
  text = tostring(text or "")
  width = tonumber(width)
  if not width or width <= 0 or display_width(text) <= width then
    return text
  end
  local ellipsis = "…"
  local limit = math.max(0, width - display_width(ellipsis))
  local out = ""
  for index = 1, vim.fn.strchars(text) do
    local candidate = vim.fn.strcharpart(text, 0, index)
    if display_width(candidate) > limit then
      break
    end
    out = candidate
  end
  return out .. ellipsis
end

local function line_width(opts)
  opts = opts or {}
  local cfg = composer_statusline_config()
  local width = tonumber(opts.width)
  local max_width = tonumber(cfg.max_width)
  if width and max_width and max_width > 0 then
    width = math.min(width, max_width)
  elseif not width then
    width = max_width
  end
  if not width or width <= 0 then
    return nil
  end
  return math.max(20, math.floor(width))
end

local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks or {}) do
    width = width + display_width(chunk[1])
  end
  return width
end

local function truncate_chunks(chunks, opts)
  local width = line_width(opts)
  if not width then
    return chunks
  end
  local remaining = width
  local truncated = {}
  for _, chunk in ipairs(chunks or {}) do
    local text = tostring(chunk[1] or "")
    local hl = chunk[2]
    local chunk_width = display_width(text)
    if chunk_width <= remaining then
      table.insert(truncated, chunk)
      remaining = remaining - chunk_width
    elseif remaining > 0 then
      table.insert(truncated, { truncate_to_width(text, remaining), hl })
      break
    else
      break
    end
  end
  return truncated
end

local function segment_chunks(segment)
  local chunks = {}
  if segment.key then
    table.insert(chunks, { tostring(segment.key) .. ": ", segment.key_hl or "CoactStatusLineKey" })
  end
  table.insert(chunks, { tostring(segment.value or ""), segment.value_hl or "CoactStatusLineValue" })
  return chunks
end

local function append_chunks(dst, chunks)
  for _, chunk in ipairs(chunks or {}) do
    table.insert(dst, chunk)
  end
end

local function segment_lines(segments, opts)
  local width = line_width(opts)
  if not width then
    local chunks = {}
    for index, segment in ipairs(segments or {}) do
      if index > 1 then
        table.insert(chunks, { "  ", "CoactStatusLineSeparator" })
      end
      append_chunks(chunks, segment_chunks(segment))
    end
    return #chunks > 0 and { chunks } or {}
  end

  local lines = {}
  local current = {}
  local current_width = 0
  for _, segment in ipairs(segments or {}) do
    local group = segment_chunks(segment)
    local group_width = chunks_width(group)
    local sep_width = #current > 0 and 2 or 0
    if #current > 0 and current_width + sep_width + group_width > width then
      table.insert(lines, truncate_chunks(current, opts))
      current = {}
      current_width = 0
      sep_width = 0
    end
    if #current > 0 then
      table.insert(current, { "  ", "CoactStatusLineSeparator" })
      current_width = current_width + 2
    end
    append_chunks(current, group)
    current_width = current_width + group_width
  end
  if #current > 0 then
    table.insert(lines, truncate_chunks(current, opts))
  end
  return lines
end

local function text_line(prefix, text, hl, opts)
  local cleaned = clean_status_text(text)
  if not cleaned then
    return nil
  end
  local chunks = {}
  if prefix and prefix ~= "" then
    table.insert(chunks, { prefix .. ": ", "CoactStatusLineKey" })
  end
  table.insert(chunks, { cleaned, hl or "CoactStatusLineValue" })
  return truncate_chunks(chunks, opts)
end

local function provider_title(thread)
  if is_pi_thread(thread) then
    return "Pi"
  end
  return providers.title(thread)
end

local function thread_state_label(thread)
  if not thread then
    return nil
  end
  if thread.generation and thread.generation ~= "idle" then
    return thread.generation
  end
  return thread.status or thread.lifecycle or (is_pi_thread(thread) and "ready" or nil)
end

local function summary_lines(thread, opts)
  local settings = setting_labels(thread)
  local segments = {}
  add_segment(segments, nil, provider_title(thread), { value_hl = "CoactStatusLineTitle" })
  add_segment(segments, "session", thread and thread.title)
  add_segment(segments, "model", settings.model)
  add_segment(segments, "provider", settings.provider)
  add_segment(segments, "tier", settings.service_tier)
  add_segment(segments, is_pi_thread(thread) and "thinking" or "effort", settings.effort)
  add_segment(segments, "state", thread_state_label(thread), {
    value_hl = "CoactStatusLineState",
  })
  add_segment(segments, nil, thread.status_message, { value_hl = "CoactStatusLineMessage" })
  if #segments <= 1 and not (has_provider_ui_content(thread) or is_pi_thread(thread)) then
    return {}
  end
  return segment_lines(segments, opts)
end

local function stats_lines(thread, opts)
  local segments = token_usage_segments(thread)
  if #segments == 0 then
    return {}
  end
  return segment_lines(segments, opts)
end

local function provider_title_line(thread, opts)
  local ui = provider_ui(thread)
  if not ui then
    return nil
  end
  return text_line("title", ui.title, "CoactStatusLineValue", opts)
end

local function extension_status_lines(thread, opts)
  local ui = provider_ui(thread)
  local entries = status_entries(ui)
  if #entries == 0 then
    return {}
  end
  local status_segments = {}
  for _, entry in ipairs(entries) do
    table.insert(status_segments, { key = entry.key, value = entry.text, value_hl = "CoactStatusLineMessage" })
  end
  return segment_lines(status_segments, opts)
end

local function widget_lines(thread, placement, opts)
  local cfg = composer_statusline_config()
  if cfg.widgets == false then
    return {}
  end
  local ui = provider_ui(thread)
  local lines = {}
  for _, entry in ipairs(widget_entries(ui, placement)) do
    for _, line in ipairs(entry.lines) do
      local cleaned = clean_status_text(line)
      if cleaned then
        table.insert(lines, text_line(entry.key, cleaned, "CoactStatusLineWidget", opts))
      end
    end
  end
  return lines
end

local function add_history_item(items, key, value, value_hl, key_hl)
  value = clean_status_text(value)
  if not value then
    return
  end
  table.insert(items, {
    key = tostring(key or "status"),
    value = value,
    value_hl = value_hl or "CoactStatusLineValue",
    key_hl = key_hl or "CoactStatusLineKey",
  })
end

local function pad_display(text, width)
  text = tostring(text or "")
  local pad = math.max(0, width - display_width(text))
  return text .. string.rep(" ", pad)
end

local function history_width(opts)
  return line_width(opts) or 80
end

local function border_line(title, opts, bottom)
  local width = history_width(opts)
  if bottom then
    return { { "╰" .. string.rep("─", math.max(1, width - 1)), "CoactStatusLineSeparator" } }
  end
  title = tostring(title or "Status")
  local prefix = "╭─ "
  local suffix_width = math.max(1, width - display_width(prefix) - display_width(title) - 1)
  return {
    { prefix, "CoactStatusLineSeparator" },
    { title, "CoactStatusLineTitle" },
    { " " .. string.rep("─", suffix_width), "CoactStatusLineSeparator" },
  }
end

local function history_row(item, key_width, opts)
  local width = history_width(opts)
  local key = pad_display(truncate_to_width(item.key, key_width), key_width)
  local prefix_width = display_width("│ ") + key_width + 2
  local value_width = math.max(1, width - prefix_width)
  return {
    { "│ ", "CoactStatusLineSeparator" },
    { key, item.key_hl or "CoactStatusLineKey" },
    { "  ", "CoactStatusLineSeparator" },
    { truncate_to_width(item.value, value_width), item.value_hl or "CoactStatusLineValue" },
  }
end

local function history_hint_line(opts)
  local text = truncate_to_width("g? help  gs details  gS hide status", history_width(opts))
  return { { text, "CoactStatusLineHint" } }
end

local function token_usage_text(thread)
  local values = {}
  for _, segment in ipairs(token_usage_segments(thread)) do
    if segment.value and not segment.key then
      table.insert(values, segment.value)
    end
  end
  return #values > 0 and table.concat(values, " ") or nil
end

function M.footer_chunks(thread, opts)
  opts = opts or {}
  if not M.visible(thread) or not M.has_content(thread) then
    return {}
  end
  local settings = setting_labels(thread)
  local segments = {}
  if opts.role == "composer" then
    add_segment(segments, nil, token_usage_text(thread))
    add_segment(segments, "ctx", context_usage_text(thread), { value_hl = "CoactStatusLineContext" })
    add_segment(segments, "state", thread_state_label(thread), { value_hl = "CoactStatusLineState" })
    add_segment(segments, nil, thread and thread.status_message, { value_hl = "CoactStatusLineMessage" })
  else
    local provider_statuses = status_entries(provider_ui(thread))
    local provider_model = nil
    for _, entry in ipairs(provider_statuses) do
      if entry.key == "model" then
        provider_model = entry.text
        break
      end
    end
    add_segment(segments, nil, provider_title(thread), { value_hl = "CoactStatusLineTitle" })
    add_segment(segments, "model", provider_model or settings.model)
    add_segment(segments, "ctx", context_usage_text(thread), { value_hl = "CoactStatusLineContext" })
    add_segment(segments, is_pi_thread(thread) and "thinking" or "effort", settings.effort)
    for _, entry in ipairs(provider_statuses) do
      if entry.key ~= "model" then
        add_segment(segments, entry.key, entry.text, { value_hl = "CoactStatusLineMessage" })
      end
    end
    add_segment(segments, "state", thread_state_label(thread), { value_hl = "CoactStatusLineState" })
  end
  local lines = segment_lines(segments, opts)
  return lines[1] or {}
end

function M.chunks_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(parts, tostring(chunk[1] or ""))
  end
  return table.concat(parts)
end

function M.footer_text(thread, opts)
  return M.chunks_text(M.footer_chunks(thread, opts))
end

local function history_items(thread)
  local settings = setting_labels(thread)
  local items = {}
  add_history_item(items, "session", thread and thread.title)
  add_history_item(items, "model", settings.model)
  add_history_item(items, "provider", settings.provider)
  add_history_item(items, "tier", settings.service_tier)
  add_history_item(items, is_pi_thread(thread) and "thinking" or "effort", settings.effort)
  add_history_item(items, "state", thread_state_label(thread), "CoactStatusLineState")
  add_history_item(items, "message", thread and thread.status_message, "CoactStatusLineMessage")
  add_history_item(items, "context", context_usage_text(thread), "CoactStatusLineContext")
  add_history_item(items, "tokens", token_usage_text(thread))

  local ui = provider_ui(thread)
  if ui then
    add_history_item(items, "title", ui.title)
    for _, entry in ipairs(status_entries(ui)) do
      add_history_item(items, entry.key, entry.text, "CoactStatusLineMessage")
    end
    for _, placement in ipairs({ "aboveEditor", "belowEditor" }) do
      for _, entry in ipairs(widget_entries(ui, placement)) do
        for _, line in ipairs(entry.lines) do
          add_history_item(items, entry.key, line, "CoactStatusLineWidget")
        end
      end
    end
  end
  return items
end

function M.history_lines(thread, opts)
  if not M.visible(thread) or not M.has_content(thread) then
    return {}
  end
  local items = history_items(thread)
  if #items == 0 then
    return {}
  end
  local width = history_width(opts)
  local key_width = 0
  for _, item in ipairs(items) do
    key_width = math.max(key_width, display_width(item.key))
  end
  key_width = math.min(key_width, math.max(8, math.floor(width * 0.35)))
  local lines = { border_line(provider_title(thread) .. " status", opts, false) }
  for _, item in ipairs(items) do
    table.insert(lines, history_row(item, key_width, opts))
  end
  table.insert(lines, border_line(nil, opts, true))
  table.insert(lines, history_hint_line(opts))
  return lines
end

function M.above_lines(thread, opts)
  if not M.visible(thread) or not M.has_content(thread) then
    return {}
  end
  local lines = {}
  local title = provider_title_line(thread, opts)
  if title then
    table.insert(lines, title)
  end
  vim.list_extend(lines, summary_lines(thread, opts))
  vim.list_extend(lines, stats_lines(thread, opts))
  vim.list_extend(lines, extension_status_lines(thread, opts))
  vim.list_extend(lines, widget_lines(thread, "aboveEditor", opts))
  return lines
end

function M.below_lines(thread, opts)
  if not M.visible(thread) or not M.has_content(thread) then
    return {}
  end
  return widget_lines(thread, "belowEditor", opts)
end

function M.line_count(thread, opts)
  return #M.above_lines(thread, opts) + #M.below_lines(thread, opts)
end

local function detail_thread(thread)
  return thread or state.thread_for_buf(0) or state.get_thread(state.active_thread_id)
end

function M.detail_lines(thread)
  thread = detail_thread(thread)
  if not thread then
    return { "# Coact Status", "", "No active Coact thread." }
  end
  local lines = {
    "# " .. provider_title(thread) .. " status",
    "",
    "thread: " .. tostring(thread.id or "unknown"),
  }
  if thread.cwd then
    table.insert(lines, "cwd: " .. tostring(thread.cwd))
  end
  table.insert(lines, "")
  table.insert(lines, "## Summary")
  table.insert(lines, "")
  for _, item in ipairs(history_items(thread)) do
    table.insert(lines, ("- **%s**: %s"):format(item.key, item.value))
  end
  if type(thread.provider_ui) == "table" then
    table.insert(lines, "")
    table.insert(lines, "## Provider UI")
    table.insert(lines, "")
    table.insert(lines, "```lua")
    for _, line in ipairs(vim.split(vim.inspect(thread.provider_ui), "\n", { plain = true })) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
  end
  return lines
end

function M.toggle_detail(thread)
  thread = detail_thread(thread)
  if not thread then
    util.notify("no active Coact thread", vim.log.levels.WARN)
    return nil
  end
  if thread.status_detail_winid and vim.api.nvim_win_is_valid(thread.status_detail_winid) then
    pcall(vim.api.nvim_win_close, thread.status_detail_winid, true)
    thread.status_detail_winid = nil
    return nil
  end
  local bufnr = thread.status_detail_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    thread.status_detail_bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, "coact://status/" .. tostring(thread.id))
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "markdown"
    vim.keymap.set("n", "q", function()
      pcall(vim.api.nvim_win_close, 0, true)
    end, { buffer = bufnr, silent = true, desc = "Close Coact status detail" })
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.detail_lines(thread))
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_height(winid, math.max(12, math.floor(vim.o.lines * 0.35)))
  thread.status_detail_winid = winid
  return bufnr, winid
end

M._clean_status_text = clean_status_text
M._format_tokens = format_tokens
M._status_entries = status_entries

return M
