local M = {}
local util = require("coact.util")

local highlights_ready = false

local function ensure_highlights()
  if highlights_ready then
    return
  end
  highlights_ready = true
  vim.api.nvim_set_hl(0, "CoactPickerIcon", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CoactPickerIconMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPickerTree", { default = true, link = "LineNr" })
  vim.api.nvim_set_hl(0, "CoactPickerTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CoactPickerPreview", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPickerMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPickerModel", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactPickerCount", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CoactPickerTime", { default = true, link = "Number" })
  vim.api.nvim_set_hl(0, "CoactPickerPath", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "CoactPickerSeparator", { default = true, link = "Delimiter" })
end

local function compact_text(value)
  value = util.value(value)
  if value == nil then
    return nil
  end
  local text = util.trim(tostring(value):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("%s+", " "))
  if text == "" then
    return nil
  end
  return text
end

local function first_value(...)
  for index = 1, select("#", ...) do
    local value = util.value(select(index, ...))
    if value ~= nil and value ~= "" then
      return value
    end
  end
  return nil
end

local function first_text(...)
  for index = 1, select("#", ...) do
    local text = compact_text(select(index, ...))
    if text then
      return text
    end
  end
  return nil
end

local function truncate_display(value, width)
  local text = tostring(value or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local ellipsis_width = vim.fn.strdisplaywidth(ellipsis)
  local out = {}
  local used = 0
  for index = 0, math.max(0, vim.fn.strchars(text) - 1) do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if used + char_width + ellipsis_width > width then
      break
    end
    table.insert(out, char)
    used = used + char_width
  end
  return table.concat(out) .. ellipsis
end

local function path_label(path)
  path = compact_text(path)
  if not path then
    return nil
  end
  local ok, label = pcall(vim.fn.fnamemodify, path, ":~")
  return ok and label or path
end

local function path_tail(path)
  path = path_label(path)
  if not path then
    return nil
  end
  local ok, tail = pcall(vim.fn.fnamemodify, path, ":t")
  if ok and tail and tail ~= "" then
    return tail
  end
  return path
end

local function preview_summary(thread, title)
  local preview = first_text(thread.preview, thread.summary, thread.description)
  if not preview or preview == title then
    return nil
  end
  local session = first_text(thread.sessionFile, thread.session_file, thread.sessionId, thread.session_id)
  if preview == session or preview:match("%.jsonl$") then
    return nil
  end
  return preview
end

local function message_count_label(thread)
  local count = first_value(thread.messageCount, thread.message_count, thread.messages)
  if type(count) == "table" then
    count = #count
  end
  count = tonumber(count)
  if not count then
    return nil
  end
  return count == 1 and "1 msg" or (tostring(count) .. " msgs")
end

local function time_label(value)
  value = util.value(value)
  if value == nil or value == "" then
    return nil
  end
  if type(value) == "number" then
    return os.date("%m-%d %H:%M", value)
  end
  local text = compact_text(value)
  if not text then
    return nil
  end
  local year, month, day, hour, minute = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)")
  if year then
    if year == os.date("%Y") then
      return ("%s-%s %s:%s"):format(month, day, hour, minute)
    end
    return ("%s-%s-%s %s:%s"):format(year, month, day, hour, minute)
  end
  return text
end

local function model_label(thread)
  return first_text(thread.model, thread.modelId, thread.modelName)
end

local function provider_label(thread)
  return first_text(thread.modelProvider, thread.model_provider, thread.provider)
end

local function thinking_label(thread)
  return first_text(thread.reasoningEffort, thread.reasoning_effort, thread.thinking, thread.thinkingLevel)
end

local function status_icon(thread)
  local status = first_text(thread.generation, thread.status, thread.lifecycle)
  if status and status ~= "ready" and status ~= "idle" then
    return "●", "CoactPickerIcon", status
  end
  return "◦", "CoactPickerIconMuted", status or "ready"
end

local function thread_meta(thread)
  thread = thread or {}
  local title = first_text(thread.name, thread.title) or first_text(thread.preview, thread.summary) or "[untitled]"
  local preview = preview_summary(thread, title)
  local icon, icon_hl, status = status_icon(thread)
  return {
    title = title,
    preview = preview,
    cwd = path_label(thread.cwd),
    cwd_tail = path_tail(thread.cwd),
    model = model_label(thread),
    provider = provider_label(thread),
    thinking = thinking_label(thread),
    message_count = message_count_label(thread),
    updated = time_label(first_value(thread.updated_at, thread.updatedAt, thread.lastActivityAt, thread.created_at)),
    session = path_label(first_value(thread.sessionFile, thread.session_file)),
    parent_session = path_label(
      first_value(
        thread.parentSessionPath,
        thread.parent_session_path,
        thread.parentSessionFile,
        thread.parent_session_file
      )
    ),
    icon = icon,
    icon_hl = icon_hl,
    status = status,
  }
end

local function parent_thread_id(thread)
  local id = first_value(thread.parentThreadId, thread.parent_thread_id)
  return id and tostring(id) or nil
end

local function session_tree(threads)
  local nodes = {}
  local by_id = {}
  for index, thread in ipairs(threads or {}) do
    local id = util.value(thread.id)
    local node = {
      thread = thread,
      index = index,
      id = id and tostring(id) or nil,
      parent_id = parent_thread_id(thread),
      children = {},
    }
    table.insert(nodes, node)
    if node.id and not by_id[node.id] then
      by_id[node.id] = node
    end
  end

  for _, node in ipairs(nodes) do
    node.parent_candidate = node.parent_id and by_id[node.parent_id] or nil
  end

  local function creates_cycle(node, parent)
    local seen = { [node] = true }
    local current = parent
    while current do
      if seen[current] then
        return true
      end
      seen[current] = true
      current = current.parent_candidate
    end
    return false
  end

  local linked = 0
  for _, node in ipairs(nodes) do
    local parent = node.parent_candidate
    if parent and parent ~= node and not creates_cycle(node, parent) then
      node.parent = parent
      table.insert(parent.children, node)
      linked = linked + 1
    end
  end

  local function display_node(node, depth, ancestor_continues, is_last)
    return {
      thread = node.thread,
      depth = depth,
      is_last = is_last,
      ancestor_continues = ancestor_continues,
    }
  end

  if linked == 0 then
    local flat = {}
    for index, node in ipairs(nodes) do
      table.insert(flat, display_node(node, 0, {}, index == #nodes))
    end
    return flat
  end

  local function update_latest(node)
    local latest = node.index
    for _, child in ipairs(node.children) do
      latest = math.min(latest, update_latest(child))
    end
    node.latest_index = latest
    return latest
  end

  local function sort_nodes(list)
    table.sort(list, function(a, b)
      if a.latest_index == b.latest_index then
        return a.index < b.index
      end
      return a.latest_index < b.latest_index
    end)
    for _, node in ipairs(list) do
      sort_nodes(node.children)
    end
  end

  local roots = {}
  for _, node in ipairs(nodes) do
    if not node.parent then
      table.insert(roots, node)
    end
  end
  for _, root in ipairs(roots) do
    update_latest(root)
  end
  sort_nodes(roots)

  local flat = {}
  local function walk(node, depth, ancestor_continues, is_last)
    table.insert(flat, display_node(node, depth, ancestor_continues, is_last))
    for index, child in ipairs(node.children) do
      local child_ancestors = vim.list_slice(ancestor_continues)
      table.insert(child_ancestors, depth > 0 and not is_last or false)
      walk(child, depth + 1, child_ancestors, index == #node.children)
    end
  end
  for index, root in ipairs(roots) do
    walk(root, 0, {}, index == #roots)
  end
  return flat
end

local function tree_prefix(tree_node)
  if not tree_node or (tree_node.depth or 0) == 0 then
    return ""
  end
  local parts = {}
  for _, continues in ipairs(tree_node.ancestor_continues or {}) do
    table.insert(parts, continues and "│  " or "   ")
  end
  table.insert(parts, tree_node.is_last and "└─ " or "├─ ")
  return table.concat(parts)
end

local function label_from_meta(meta)
  local parts = { truncate_display(meta.title, 72) }
  if meta.preview then
    table.insert(parts, "— " .. truncate_display(meta.preview, 72))
  end
  local chips = {}
  if meta.model then
    table.insert(chips, meta.model)
  end
  if meta.message_count then
    table.insert(chips, meta.message_count)
  end
  if meta.updated then
    table.insert(chips, meta.updated)
  end
  if meta.cwd_tail then
    table.insert(chips, meta.cwd_tail)
  end
  if #chips > 0 then
    table.insert(parts, "· " .. table.concat(chips, " · "))
  end
  return table.concat(parts, " ")
end

local function label(thread)
  return label_from_meta(thread_meta(thread))
end

local function add_detail(lines, key, value)
  value = compact_text(value)
  if value then
    table.insert(lines, ("- **%s** `%s`"):format(key, value:gsub("`", "'")))
  end
end

local function preview_quote(lines, preview)
  preview = util.value(preview)
  if preview == nil or preview == "" then
    return
  end
  local added = 0
  for _, line in ipairs(vim.split(tostring(preview), "\n", { plain = true })) do
    line = util.trim(line)
    if line ~= "" then
      table.insert(lines, "> " .. truncate_display(line, 120))
      added = added + 1
      if added >= 6 then
        break
      end
    end
  end
end

local function preview_text(thread)
  local meta = thread_meta(thread)
  local lines = { "# " .. meta.title }
  if meta.preview then
    table.insert(lines, "")
    preview_quote(lines, meta.preview)
  end
  table.insert(lines, "")
  table.insert(lines, "## Details")
  add_detail(lines, "Status", meta.status)
  add_detail(lines, "Workspace", meta.cwd)
  add_detail(lines, "Model", meta.model)
  add_detail(lines, "Provider", meta.provider)
  add_detail(lines, "Thinking", meta.thinking)
  add_detail(lines, "Messages", meta.message_count)
  add_detail(lines, "Updated", meta.updated)
  add_detail(lines, "Session", meta.session)
  add_detail(lines, "Forked from", meta.parent_session)
  return table.concat(lines, "\n")
end

local function append(chunks, text, hl)
  if text and text ~= "" then
    table.insert(chunks, { text, hl })
  end
end

local function format_item(item)
  ensure_highlights()
  local meta = item.coact_meta or thread_meta(item.thread or {})
  local chunks = {}
  append(chunks, item.coact_tree_prefix, "CoactPickerTree")
  append(chunks, meta.icon .. " ", meta.icon_hl)
  append(chunks, truncate_display(meta.title, 36), "CoactPickerTitle")
  if meta.preview then
    append(chunks, "  ", "CoactPickerSeparator")
    append(chunks, truncate_display(meta.preview, 46), "CoactPickerPreview")
  end
  if meta.model then
    append(chunks, "  ", "CoactPickerSeparator")
    append(chunks, truncate_display(meta.model, 24), "CoactPickerModel")
  end
  if meta.message_count then
    append(chunks, "  ", "CoactPickerSeparator")
    append(chunks, meta.message_count, "CoactPickerCount")
  end
  if meta.updated then
    append(chunks, "  ", "CoactPickerSeparator")
    append(chunks, meta.updated, "CoactPickerTime")
  end
  if meta.cwd_tail then
    append(chunks, "  ", "CoactPickerSeparator")
    append(chunks, meta.cwd_tail, "CoactPickerPath")
  end
  return chunks
end

local function picker_item(tree_node)
  local thread = tree_node.thread
  local meta = thread_meta(thread)
  local prefix = tree_prefix(tree_node)
  return {
    text = prefix .. label_from_meta(meta),
    preview = {
      text = preview_text(thread),
      ft = "markdown",
      loc = false,
    },
    thread = thread,
    coact_meta = meta,
    coact_tree = tree_node,
    coact_tree_prefix = prefix,
  }
end

M._label = label
M._preview_text = preview_text
M._thread_meta = thread_meta
M._format_item = format_item
M._session_tree = session_tree
M._tree_prefix = tree_prefix

local function schedule_provider_prewarm()
  local provider = require("coact.providers").current()
  if provider.transport_scope ~= "thread" or type(provider.picker_prewarm_options) ~= "function" then
    return
  end
  local opts = provider.picker_prewarm_options()
  if not opts or opts.enabled == false then
    return
  end
  local delay = math.max(0, tonumber(opts.delay_ms) or 0)
  require("coact.runtime").defer(function()
    require("coact.rpc").prewarm(function() end)
  end, delay)
end

function M.threads(opts)
  opts = opts or {}
  local config = require("coact.config")
  local ctx = config.context()
  local source_bufnr = opts.source_bufnr or vim.api.nvim_get_current_buf()
  local source_winid = opts.source_winid or vim.api.nvim_get_current_win()
  local resume = config.bind(function(thread)
    require("coact").resume(thread.id, {
      thread = thread,
      source_bufnr = source_bufnr,
      source_winid = source_winid,
    })
  end, ctx)
  require("coact").list_threads(function(threads)
    local provider_title = require("coact.providers").title()
    if #threads == 0 then
      vim.notify(
        "No " .. provider_title .. " threads for this workspace",
        vim.log.levels.INFO,
        { title = "coact.nvim" }
      )
      return
    end

    local tree_nodes = session_tree(threads)
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.picker then
      ensure_highlights()
      snacks.picker.pick({
        title = provider_title .. " Threads",
        items = vim.tbl_map(picker_item, tree_nodes),
        format = format_item,
        matcher = { sort_empty = false },
        sort = { fields = { "score:desc", "idx" } },
        preview = "preview",
        confirm = function(picker, item)
          picker:close()
          resume(item.thread)
        end,
      })
      schedule_provider_prewarm()
      return
    end

    vim.ui.select(tree_nodes, {
      prompt = provider_title .. " threads",
      format_item = function(tree_node)
        return tree_prefix(tree_node) .. label(tree_node.thread)
      end,
    }, function(tree_node)
      if tree_node then
        resume(tree_node.thread)
      end
    end)
    schedule_provider_prewarm()
  end)
end

-- Put the configured default first rather than pre-filling the search query.
-- This also gives vim.ui.select (which has no portable selected-index option)
-- the same initial choice as Snacks.
function M.adapters(opts)
  opts = opts or {}
  local config = require("coact.config")
  local root = config.root()
  local items = {}
  for name, adapter in pairs(root.adapters) do
    items[#items + 1] = {
      name = name,
      text = name
        .. "  ("
        .. (adapter.provider or name)
        .. ")"
        .. (name == root.default_adapter and "  [default]" or ""),
    }
  end
  table.sort(items, function(a, b)
    if a.name == root.default_adapter then
      return b.name ~= root.default_adapter
    end
    if b.name == root.default_adapter then
      return false
    end
    return a.name < b.name
  end)
  local context = require("coact.context")
  local source_bufnr = vim.api.nvim_get_current_buf()
  if context.is_coact_buffer(source_bufnr) then
    source_bufnr = context.target_buffer()
  end
  local source_winid = vim.api.nvim_get_current_win()
  local function choose(item)
    if not item then
      return
    end
    local ctx = config.select_adapter(item.name)
    local proceed = config.bind(function(action)
      if action == "new" then
        require("coact").new_thread({
          adapter = item.name,
          prompt = opts.prompt,
          source_bufnr = source_bufnr,
          source_winid = source_winid,
        })
      elseif action == "pick" then
        M.threads({ source_bufnr = source_bufnr, source_winid = source_winid })
      end
    end, ctx)
    if opts.action then
      proceed(opts.action)
    else
      vim.ui.select({ "new", "pick" }, {
        prompt = item.name,
        format_item = function(action)
          return action == "new" and "New session" or "Resume session"
        end,
      }, proceed)
    end
  end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.pick({
      title = "Coact Adapters",
      items = items,
      format = "text",
      matcher = { sort_empty = false },
      sort = { fields = { "score:desc", "idx" } },
      confirm = function(picker, item)
        picker:close()
        vim.schedule(function()
          choose(item)
        end)
      end,
    })
  else
    vim.ui.select(items, {
      prompt = "Coact adapter",
      format_item = function(item)
        return item.text
      end,
    }, choose)
  end
end

return M
