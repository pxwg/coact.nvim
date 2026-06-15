local M = {}

local ns = vim.api.nvim_create_namespace("coact.nvim.pi_tree")
local root_key = "\0root"

local filter_modes = { "default", "no-tools", "user-only", "labeled-only", "all" }

local function value(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

local function as_table(v)
  return type(v) == "table" and v or {}
end

local function entry(node)
  return as_table(as_table(node).entry)
end

local function children(node)
  return as_table(as_table(node).children)
end

local function entry_id(entry_or_node)
  local e = entry_or_node and entry_or_node.entry and entry(entry_or_node) or as_table(entry_or_node)
  local id = value(e.id)
  return id and tostring(id) or nil
end

local function parent_id(e, parent_map)
  local id = entry_id(e)
  local parent = value(as_table(e).parentId)
  if parent ~= nil then
    return tostring(parent)
  end
  return id and parent_map[id] or nil
end

local function copy_list(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    table.insert(out, item)
  end
  return out
end

local function normalize_text(text)
  return tostring(text or ""):gsub("[\n\t]", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate(text, max_len)
  text = tostring(text or "")
  max_len = max_len or 200
  if #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 3) .. "..."
end

local function text_content(content, max_len)
  if type(content) == "string" then
    return truncate(content, max_len)
  end
  local out = {}
  local length = 0
  for _, block in ipairs(as_table(content)) do
    if type(block) == "table" and block.type == "text" and block.text then
      local text = tostring(block.text)
      length = length + #text
      table.insert(out, text)
      if length >= (max_len or 200) then
        return truncate(table.concat(out), max_len)
      end
    end
  end
  return table.concat(out)
end

local function has_text_content(content)
  return normalize_text(text_content(content, 200)) ~= ""
end

local function build_maps(roots)
  local node_map = {}
  local parent_map = {}
  local function visit(node, parent)
    local e = entry(node)
    local id = entry_id(e)
    if id then
      node_map[id] = node
      parent_map[id] = parent
    end
    for _, child in ipairs(children(node)) do
      visit(child, id)
    end
  end
  for _, root in ipairs(roots) do
    visit(root, nil)
  end
  return node_map, parent_map
end

local function build_active_path(leaf_id, node_map, parent_map)
  local active = {}
  local current = value(leaf_id)
  current = current and tostring(current) or nil
  while current and current ~= "" do
    active[current] = true
    local node = node_map[current]
    if not node then
      break
    end
    current = parent_id(entry(node), parent_map)
  end
  return active
end

local function ordered_by_active(nodes, contains_active)
  local prioritized = {}
  local rest = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(contains_active[node] and prioritized or rest, node)
  end
  vim.list_extend(prioritized, rest)
  return prioritized
end

local function collect_tool_calls(state, node)
  local e = entry(node)
  if e.type ~= "message" then
    return
  end
  local message = as_table(e.message)
  if message.role ~= "assistant" then
    return
  end
  for _, block in ipairs(as_table(message.content)) do
    if type(block) == "table" and block.type == "toolCall" then
      local id = value(block.id) or value(block.toolCallId)
      if id then
        state.tool_call_map[tostring(id)] = {
          name = value(block.name) or "tool",
          arguments = as_table(value(block.arguments) or value(block.args)),
        }
      end
    end
  end
end

local function flatten_tree(state)
  local roots = state.roots
  local contains_active = {}
  local function mark(node)
    local id = entry_id(entry(node))
    local has = id ~= nil and state.active_path_ids[id] == true
    for _, child in ipairs(children(node)) do
      if mark(child) then
        has = true
      end
    end
    contains_active[node] = has
    return has
  end
  for _, root in ipairs(roots) do
    mark(root)
  end

  state.tool_call_map = {}
  state.multiple_roots = #roots > 1

  local stack = {}
  local ordered_roots = ordered_by_active(roots, contains_active)
  for i = #ordered_roots, 1, -1 do
    table.insert(stack, {
      node = ordered_roots[i],
      indent = state.multiple_roots and 1 or 0,
      just_branched = state.multiple_roots,
      show_connector = state.multiple_roots,
      is_last = i == #ordered_roots,
      gutters = {},
      is_virtual_root_child = state.multiple_roots,
    })
  end

  local result = {}
  while #stack > 0 do
    local item = table.remove(stack)
    collect_tool_calls(state, item.node)
    table.insert(result, {
      node = item.node,
      indent = item.indent,
      show_connector = item.show_connector,
      is_last = item.is_last,
      gutters = item.gutters,
      is_virtual_root_child = item.is_virtual_root_child,
    })

    local node_children = children(item.node)
    local multiple_children = #node_children > 1
    local ordered_children = ordered_by_active(node_children, contains_active)
    local child_indent
    if multiple_children then
      child_indent = item.indent + 1
    elseif item.just_branched and item.indent > 0 then
      child_indent = item.indent + 1
    else
      child_indent = item.indent
    end

    local connector_displayed = item.show_connector and not item.is_virtual_root_child
    local display_indent = state.multiple_roots and math.max(0, item.indent - 1) or item.indent
    local connector_position = math.max(0, display_indent - 1)
    local child_gutters = item.gutters
    if connector_displayed then
      child_gutters = copy_list(item.gutters)
      table.insert(child_gutters, { position = connector_position, show = not item.is_last })
    end

    for i = #ordered_children, 1, -1 do
      table.insert(stack, {
        node = ordered_children[i],
        indent = child_indent,
        just_branched = multiple_children,
        show_connector = multiple_children,
        is_last = i == #ordered_children,
        gutters = child_gutters,
        is_virtual_root_child = false,
      })
    end
  end

  return result
end

local function searchable_text(state, node)
  local e = entry(node)
  local parts = {}
  if node.label then
    table.insert(parts, tostring(node.label))
  end
  if e.type == "message" then
    local message = as_table(e.message)
    table.insert(parts, tostring(message.role or ""))
    table.insert(parts, text_content(message.content, 200))
    if message.role == "bashExecution" then
      table.insert(parts, tostring(message.command or ""))
    end
  elseif e.type == "custom_message" then
    table.insert(parts, tostring(e.customType or ""))
    table.insert(parts, text_content(e.content, 200))
  elseif e.type == "branch_summary" then
    table.insert(parts, "branch summary")
    table.insert(parts, tostring(e.summary or ""))
  elseif e.type == "session_info" then
    table.insert(parts, "title")
    table.insert(parts, tostring(e.name or ""))
  elseif e.type == "model_change" then
    table.insert(parts, "model")
    table.insert(parts, tostring(e.modelId or ""))
  elseif e.type == "thinking_level_change" then
    table.insert(parts, "thinking")
    table.insert(parts, tostring(e.thinkingLevel or ""))
  elseif e.type == "custom" or e.type == "label" then
    table.insert(parts, tostring(e.type))
    table.insert(parts, tostring(e.customType or e.label or ""))
  else
    table.insert(parts, tostring(e.type or "entry"))
  end
  return table.concat(parts, " ")
end

local function passes_filter(state, flat_node)
  local e = entry(flat_node.node)
  local id = entry_id(e)
  local is_current_leaf = id ~= nil and id == state.leaf_id

  if e.type == "message" then
    local message = as_table(e.message)
    if message.role == "assistant" and not is_current_leaf then
      local stop_reason = value(message.stopReason)
      local error_message = value(message.errorMessage)
      local is_error_or_aborted = stop_reason ~= nil and stop_reason ~= "stop" and stop_reason ~= "toolUse"
      if not has_text_content(message.content) and not is_error_or_aborted and not error_message then
        return false
      end
    end
  end

  local is_settings = e.type == "label"
    or e.type == "custom"
    or e.type == "model_change"
    or e.type == "thinking_level_change"
    or e.type == "session_info"
  local mode = state.filter_mode or "default"
  if mode == "user-only" then
    if not (e.type == "message" and as_table(e.message).role == "user") then
      return false
    end
  elseif mode == "no-tools" then
    if is_settings or (e.type == "message" and as_table(e.message).role == "toolResult") then
      return false
    end
  elseif mode == "labeled-only" then
    if flat_node.node.label == nil then
      return false
    end
  elseif mode ~= "all" and is_settings then
    return false
  end

  local query = normalize_text(state.search_query or ""):lower()
  if query ~= "" then
    local haystack = searchable_text(state, flat_node.node):lower()
    for token in query:gmatch("%S+") do
      if not haystack:find(token, 1, true) then
        return false
      end
    end
  end

  return true
end

local function find_nearest_visible_index(state, id)
  if #state.filtered_nodes == 0 then
    return 1
  end
  local visible_index = {}
  for index, flat_node in ipairs(state.filtered_nodes) do
    local node_id = entry_id(entry(flat_node.node))
    if node_id then
      visible_index[node_id] = index
    end
  end
  local current = id and tostring(id) or nil
  while current do
    if visible_index[current] then
      return visible_index[current]
    end
    local node = state.node_map[current]
    if not node then
      break
    end
    current = parent_id(entry(node), state.parent_map)
  end
  return #state.filtered_nodes
end

local function recalculate_visual_structure(state)
  if #state.filtered_nodes == 0 then
    return
  end
  local visible_ids = {}
  local filtered_by_id = {}
  for _, flat_node in ipairs(state.filtered_nodes) do
    local id = entry_id(entry(flat_node.node))
    if id then
      visible_ids[id] = true
      filtered_by_id[id] = flat_node
    end
  end

  local function visible_ancestor(node_id)
    local current = state.parent_map[node_id]
    while current do
      if visible_ids[current] then
        return current
      end
      current = state.parent_map[current]
    end
    return nil
  end

  local visible_parent = {}
  local visible_children = { [root_key] = {} }
  for _, flat_node in ipairs(state.filtered_nodes) do
    local id = entry_id(entry(flat_node.node))
    if id then
      local ancestor = visible_ancestor(id)
      local key = ancestor or root_key
      visible_parent[id] = ancestor
      visible_children[key] = visible_children[key] or {}
      table.insert(visible_children[key], id)
    end
  end

  state.multiple_roots = #(visible_children[root_key] or {}) > 1
  state.visible_parent_map = visible_parent
  state.visible_children_map = visible_children

  local stack = {}
  local roots = visible_children[root_key] or {}
  for i = #roots, 1, -1 do
    table.insert(stack, {
      id = roots[i],
      indent = state.multiple_roots and 1 or 0,
      just_branched = state.multiple_roots,
      show_connector = state.multiple_roots,
      is_last = i == #roots,
      gutters = {},
      is_virtual_root_child = state.multiple_roots,
    })
  end

  while #stack > 0 do
    local item = table.remove(stack)
    local flat_node = filtered_by_id[item.id]
    if flat_node then
      flat_node.indent = item.indent
      flat_node.show_connector = item.show_connector
      flat_node.is_last = item.is_last
      flat_node.gutters = item.gutters
      flat_node.is_virtual_root_child = item.is_virtual_root_child

      local node_children = visible_children[item.id] or {}
      local multiple_children = #node_children > 1
      local child_indent
      if multiple_children then
        child_indent = item.indent + 1
      elseif item.just_branched and item.indent > 0 then
        child_indent = item.indent + 1
      else
        child_indent = item.indent
      end

      local connector_displayed = item.show_connector and not item.is_virtual_root_child
      local display_indent = state.multiple_roots and math.max(0, item.indent - 1) or item.indent
      local connector_position = math.max(0, display_indent - 1)
      local child_gutters = item.gutters
      if connector_displayed then
        child_gutters = copy_list(item.gutters)
        table.insert(child_gutters, { position = connector_position, show = not item.is_last })
      end

      for i = #node_children, 1, -1 do
        table.insert(stack, {
          id = node_children[i],
          indent = child_indent,
          just_branched = multiple_children,
          show_connector = multiple_children,
          is_last = i == #node_children,
          gutters = child_gutters,
          is_virtual_root_child = false,
        })
      end
    end
  end
end

local function apply_filter(state)
  state.last_selected_id = state.filtered_nodes
      and state.filtered_nodes[state.selected_index]
      and entry_id(entry(state.filtered_nodes[state.selected_index].node))
    or state.last_selected_id
  state.filtered_nodes = {}
  for _, flat_node in ipairs(state.flat_nodes or {}) do
    if passes_filter(state, flat_node) then
      table.insert(state.filtered_nodes, flat_node)
    end
  end
  recalculate_visual_structure(state)
  state.selected_index = find_nearest_visible_index(state, state.last_selected_id or state.leaf_id)
  state.last_selected_id = state.filtered_nodes[state.selected_index]
      and entry_id(entry(state.filtered_nodes[state.selected_index].node))
    or state.last_selected_id
end

local function shorten_path(path)
  path = tostring(path or "")
  local home = vim.fn.expand("~")
  if home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function json_preview(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  encoded = ok and encoded or "{}"
  return truncate(encoded, 40)
end

local function format_tool_call(name, args)
  name = tostring(name or "tool")
  args = as_table(args)
  if name == "read" then
    local path = shorten_path(value(args.path) or value(args.file_path) or "")
    local offset = value(args.offset)
    local limit = value(args.limit)
    if offset ~= nil or limit ~= nil then
      local start = tonumber(offset) or 1
      local limit_number = tonumber(limit)
      local finish = limit_number and (start + limit_number - 1) or nil
      path = path .. ":" .. tostring(start) .. (finish and ("-" .. finish) or "")
    end
    return "[read: " .. path .. "]"
  elseif name == "write" or name == "edit" then
    return ("[%s: %s]"):format(name, shorten_path(value(args.path) or value(args.file_path) or ""))
  elseif name == "bash" then
    local raw = tostring(value(args.command) or "")
    local cmd = truncate(normalize_text(raw), 50)
    return "[bash: " .. cmd .. "]"
  elseif name == "grep" then
    return ("[grep: /%s/ in %s]"):format(tostring(value(args.pattern) or ""), shorten_path(value(args.path) or "."))
  elseif name == "find" then
    return ("[find: %s in %s]"):format(tostring(value(args.pattern) or ""), shorten_path(value(args.path) or "."))
  elseif name == "ls" then
    return "[ls: " .. shorten_path(value(args.path) or ".") .. "]"
  end
  return ("[%s: %s]"):format(name, json_preview(args))
end

local function make_segments()
  return { text = "", spans = {} }
end

local function append_segment(line, text, hl_group)
  text = tostring(text or "")
  if text == "" then
    return
  end
  local start_col = #line.text
  line.text = line.text .. text
  if hl_group then
    table.insert(line.spans, { start_col = start_col, end_col = #line.text, hl_group = hl_group })
  end
end

local function entry_segments(state, node)
  local e = entry(node)
  local segments = make_segments()
  if node.label then
    append_segment(segments, "[" .. tostring(node.label) .. "] ", "CoactPiTreeLabel")
  end
  if e.type == "message" then
    local message = as_table(e.message)
    local role = tostring(message.role or "message")
    if role == "user" then
      append_segment(segments, "user: ", "CoactPiTreeUser")
      append_segment(segments, truncate(normalize_text(text_content(message.content, 200)), 200), "CoactPiTreeText")
    elseif role == "assistant" then
      append_segment(segments, "assistant: ", "CoactPiTreeAssistant")
      local text = truncate(normalize_text(text_content(message.content, 200)), 200)
      if text ~= "" then
        append_segment(segments, text, "CoactPiTreeText")
      elseif message.stopReason == "aborted" then
        append_segment(segments, "(aborted)", "CoactPiTreeMuted")
      elseif message.errorMessage then
        append_segment(segments, truncate(normalize_text(message.errorMessage), 80), "CoactPiTreeError")
      else
        append_segment(segments, "(no content)", "CoactPiTreeMuted")
      end
    elseif role == "toolResult" then
      local tool_call_id = value(message.toolCallId)
      local tool_call = tool_call_id and state.tool_call_map[tostring(tool_call_id)] or nil
      if tool_call then
        append_segment(segments, format_tool_call(tool_call.name, tool_call.arguments), "CoactPiTreeTool")
      else
        append_segment(segments, "[" .. tostring(message.toolName or "tool") .. "]", "CoactPiTreeTool")
      end
    elseif role == "bashExecution" then
      append_segment(segments, "[bash]: ", "CoactPiTreeTool")
      append_segment(segments, truncate(normalize_text(message.command or ""), 120), "CoactPiTreeMuted")
    else
      append_segment(segments, "[" .. role .. "]", "CoactPiTreeMuted")
    end
  elseif e.type == "custom_message" then
    append_segment(segments, "[" .. tostring(e.customType or "custom") .. "]: ", "CoactPiTreeCustom")
    append_segment(segments, truncate(normalize_text(text_content(e.content, 200)), 200), "CoactPiTreeText")
  elseif e.type == "branch_summary" then
    append_segment(segments, "[branch summary]: ", "CoactPiTreeBranchSummary")
    append_segment(segments, truncate(normalize_text(e.summary or ""), 200), "CoactPiTreeText")
  elseif e.type == "compaction" then
    append_segment(
      segments,
      ("[compaction: %dk tokens]"):format(math.floor((tonumber(e.tokensBefore) or 0) / 1000 + 0.5)),
      "CoactPiTreeCompaction"
    )
  elseif e.type == "model_change" then
    append_segment(segments, "[model: " .. tostring(e.modelId or "") .. "]", "CoactPiTreeMuted")
  elseif e.type == "thinking_level_change" then
    append_segment(segments, "[thinking: " .. tostring(e.thinkingLevel or "") .. "]", "CoactPiTreeMuted")
  elseif e.type == "session_info" then
    append_segment(segments, "[title: " .. tostring(e.name or "empty") .. "]", "CoactPiTreeMuted")
  elseif e.type == "label" then
    append_segment(segments, "[label: " .. tostring(e.label or "(cleared)") .. "]", "CoactPiTreeMuted")
  else
    append_segment(segments, "[" .. tostring(e.type or "entry") .. "]", "CoactPiTreeMuted")
  end
  return segments
end

local function prefix_text(state, flat_node)
  local display_indent = state.multiple_roots and math.max(0, (flat_node.indent or 0) - 1) or (flat_node.indent or 0)
  local connector = flat_node.show_connector and not flat_node.is_virtual_root_child
  local connector_position = connector and (display_indent - 1) or -1
  local total_chars = display_indent * 3
  local chars = {}
  for i = 0, total_chars - 1 do
    local level = math.floor(i / 3)
    local pos = i % 3
    local gutter_at_level
    for _, gutter in ipairs(flat_node.gutters or {}) do
      if gutter.position == level then
        gutter_at_level = gutter
        break
      end
    end
    if gutter_at_level then
      table.insert(chars, pos == 0 and (gutter_at_level.show and "│" or " ") or " ")
    elseif connector and level == connector_position then
      if pos == 0 then
        table.insert(chars, flat_node.is_last and "└" or "├")
      elseif pos == 1 then
        table.insert(chars, "─")
      else
        table.insert(chars, " ")
      end
    else
      table.insert(chars, " ")
    end
  end
  return table.concat(chars)
end

local function status_labels(state)
  local mode = state.filter_mode or "default"
  if mode == "default" then
    return ""
  end
  return " [" .. mode .. "]"
end

local function selected_entry_id(state)
  local flat_node = state.filtered_nodes[state.selected_index]
  return flat_node and entry_id(entry(flat_node.node)) or nil
end

local function render_model(state, width, height)
  width = math.max(40, tonumber(width) or 100)
  height = math.max(8, tonumber(height) or 20)
  local lines = {}
  local spans = {}
  local line_hls = {}
  local row_to_index = {}
  local function add_plain(text, hl)
    table.insert(lines, text)
    spans[#lines] = hl and { { start_col = 0, end_col = #text, hl_group = hl } } or {}
  end

  add_plain("Session Tree" .. status_labels(state), "CoactPiTreeTitle")
  add_plain(
    "j/k ctrl-n/p move · ctrl-d/u half-page · ctrl-f/b page · gg/G edge · h/l branch · d/t/u/L/a filters · / search",
    "CoactPiTreeHelp"
  )
  add_plain("Type / to search: " .. tostring(state.search_query or ""), "CoactPiTreeHelp")
  add_plain(string.rep("─", math.max(1, width)), "CoactPiTreeConnector")

  if #state.filtered_nodes == 0 then
    add_plain("  No entries found", "CoactPiTreeMuted")
    add_plain("  (0/0)" .. status_labels(state), "CoactPiTreeHelp")
    return { lines = lines, spans = spans, line_hls = line_hls, selected_row = #lines }
  end

  local max_visible = math.max(5, height - 5)
  local start_index =
    math.max(1, math.min(state.selected_index - math.floor(max_visible / 2), #state.filtered_nodes - max_visible + 1))
  local end_index = math.min(start_index + max_visible - 1, #state.filtered_nodes)
  local selected_row = nil
  for index = start_index, end_index do
    local flat_node = state.filtered_nodes[index]
    local id = entry_id(entry(flat_node.node))
    local line = make_segments()
    local is_selected = index == state.selected_index
    append_segment(line, is_selected and "› " or "  ", is_selected and "CoactPiTreeCursor" or nil)
    append_segment(line, prefix_text(state, flat_node), "CoactPiTreeConnector")
    append_segment(
      line,
      id and state.active_path_ids[id] and "• " or "  ",
      id and state.active_path_ids[id] and "CoactPiTreeActive" or nil
    )
    local content = entry_segments(state, flat_node.node)
    local base_col = #line.text
    line.text = line.text .. content.text
    for _, span in ipairs(content.spans) do
      table.insert(line.spans, {
        start_col = base_col + span.start_col,
        end_col = base_col + span.end_col,
        hl_group = span.hl_group,
      })
    end
    table.insert(lines, line.text)
    row_to_index[#lines] = index
    spans[#lines] = line.spans
    if is_selected then
      selected_row = #lines
      line_hls[#lines] = "CoactPiTreeSelected"
    end
  end
  add_plain(("(%d/%d)%s"):format(state.selected_index, #state.filtered_nodes, status_labels(state)), "CoactPiTreeHelp")
  return {
    lines = lines,
    spans = spans,
    line_hls = line_hls,
    row_to_index = row_to_index,
    selected_row = selected_row or 5,
  }
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CoactPiTreeTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CoactPiTreeHelp", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPiTreeConnector", { default = true, link = "LineNr" })
  vim.api.nvim_set_hl(0, "CoactPiTreeCursor", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactPiTreeActive", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactPiTreeSelected", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "CoactPiTreeUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CoactPiTreeAssistant", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "CoactPiTreeTool", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPiTreeMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "CoactPiTreeText", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "CoactPiTreeLabel", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactPiTreeCustom", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactPiTreeBranchSummary", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "CoactPiTreeCompaction", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "CoactPiTreeError", { default = true, link = "DiagnosticError" })
end

local function make_state(payload)
  payload = as_table(payload)
  local roots = as_table(payload.tree)
  local node_map, parent_map = build_maps(roots)
  local leaf_id = value(payload.leafId) or value(payload.leaf_id)
  leaf_id = leaf_id and tostring(leaf_id) or nil
  local state = {
    roots = roots,
    node_map = node_map,
    parent_map = parent_map,
    leaf_id = leaf_id,
    active_path_ids = build_active_path(leaf_id, node_map, parent_map),
    filter_mode = "default",
    search_query = "",
    selected_index = 1,
    last_selected_id = leaf_id,
    filtered_nodes = {},
  }
  state.flat_nodes = flatten_tree(state)
  apply_filter(state)
  return state
end

local function set_modifiable(bufnr, modifiable)
  vim.bo[bufnr].readonly = not modifiable
  vim.bo[bufnr].modifiable = modifiable
end

local function draw(state)
  if
    not (
      state.winid
      and vim.api.nvim_win_is_valid(state.winid)
      and state.bufnr
      and vim.api.nvim_buf_is_valid(state.bufnr)
    )
  then
    return
  end
  local model = render_model(state, vim.api.nvim_win_get_width(state.winid), vim.api.nvim_win_get_height(state.winid))
  state.drawing = true
  state.row_to_index = model.row_to_index or {}
  set_modifiable(state.bufnr, true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, model.lines)
  set_modifiable(state.bufnr, false)
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for row, row_spans in pairs(model.spans) do
    for _, span in ipairs(row_spans) do
      pcall(vim.api.nvim_buf_set_extmark, state.bufnr, ns, row - 1, span.start_col, {
        end_col = span.end_col,
        hl_group = span.hl_group,
      })
    end
  end
  for row, hl_group in pairs(model.line_hls) do
    pcall(vim.api.nvim_buf_set_extmark, state.bufnr, ns, row - 1, 0, { line_hl_group = hl_group })
  end
  pcall(vim.api.nvim_win_set_cursor, state.winid, { model.selected_row, 0 })
  state.drawing = false
end

local function cycle_filter(state, delta)
  local index = 1
  for i, mode in ipairs(filter_modes) do
    if mode == state.filter_mode then
      index = i
      break
    end
  end
  index = ((index - 1 + delta) % #filter_modes) + 1
  state.filter_mode = filter_modes[index]
  apply_filter(state)
end

local function find_branch_segment_start(state, direction)
  local selected_id = selected_entry_id(state)
  if not selected_id then
    return state.selected_index
  end
  local index_by_id = {}
  for index, flat_node in ipairs(state.filtered_nodes) do
    local id = entry_id(entry(flat_node.node))
    if id then
      index_by_id[id] = index
    end
  end
  local current = selected_id
  if direction == "down" then
    while current do
      local node_children = state.visible_children_map[current] or {}
      if #node_children == 0 then
        return index_by_id[current] or state.selected_index
      end
      if #node_children > 1 then
        return index_by_id[node_children[1]] or state.selected_index
      end
      current = node_children[1]
    end
    return state.selected_index
  end

  while current do
    local parent = state.visible_parent_map[current]
    if not parent then
      return index_by_id[current] or state.selected_index
    end
    local siblings = state.visible_children_map[parent] or {}
    if #siblings > 1 then
      local segment_start = index_by_id[current]
      if segment_start and segment_start < state.selected_index then
        return segment_start
      end
    end
    current = parent
  end
  return state.selected_index
end

local function finish(state, choice)
  if state.finished then
    return
  end
  state.finished = true
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
  if state.callback then
    state.callback(choice)
  end
end

local function force_normal_mode(state)
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_set_current_win, state.winid)
  end
  pcall(vim.cmd, "stopinsert")
end

local function sync_selection_from_cursor(state)
  if state.finished or state.drawing then
    return
  end
  if
    not (
      state.winid
      and vim.api.nvim_win_is_valid(state.winid)
      and state.bufnr
      and vim.api.nvim_buf_is_valid(state.bufnr)
    )
  then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  local index = state.row_to_index and state.row_to_index[row] or nil
  if index and index ~= state.selected_index then
    state.selected_index = index
    draw(state)
  end
end

local function lock_picker_modes(state)
  vim.bo[state.bufnr].readonly = true
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].undolevels = -1
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = state.bufnr,
    callback = function()
      vim.schedule(function()
        if not state.finished and vim.api.nvim_buf_is_valid(state.bufnr) then
          force_normal_mode(state)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = state.bufnr,
    callback = function()
      sync_selection_from_cursor(state)
    end,
  })
end

local function map_keys(state)
  local function key(lhs, fn)
    if type(lhs) == "table" then
      for _, item in ipairs(lhs) do
        key(item, fn)
      end
      return
    end
    vim.keymap.set("n", lhs, fn, { buffer = state.bufnr, silent = true, nowait = true })
  end
  local function redraw_after(fn)
    return function()
      fn()
      draw(state)
    end
  end
  local function move_by(delta)
    if #state.filtered_nodes == 0 then
      return
    end
    state.selected_index = math.max(1, math.min(#state.filtered_nodes, state.selected_index + delta))
  end
  local function window_step(multiplier)
    return math.max(5, math.floor(vim.api.nvim_win_get_height(state.winid) * multiplier))
  end
  key(
    { "j", "<C-n>", "<Down>" },
    redraw_after(function()
      if #state.filtered_nodes == 0 then
        return
      end
      state.selected_index = state.selected_index == #state.filtered_nodes and 1 or state.selected_index + 1
    end)
  )
  key(
    { "k", "<C-p>", "<Up>" },
    redraw_after(function()
      if #state.filtered_nodes == 0 then
        return
      end
      state.selected_index = state.selected_index == 1 and #state.filtered_nodes or state.selected_index - 1
    end)
  )
  key(
    "<C-d>",
    redraw_after(function()
      move_by(window_step(0.5))
    end)
  )
  key(
    "<C-u>",
    redraw_after(function()
      move_by(-window_step(0.5))
    end)
  )
  key(
    { "<C-f>", "<PageDown>" },
    redraw_after(function()
      move_by(window_step(1.0))
    end)
  )
  key(
    { "<C-b>", "<PageUp>" },
    redraw_after(function()
      move_by(-window_step(1.0))
    end)
  )
  key(
    "gg",
    redraw_after(function()
      state.selected_index = 1
    end)
  )
  key(
    "G",
    redraw_after(function()
      state.selected_index = math.max(1, #state.filtered_nodes)
    end)
  )
  key(
    { "h", "<Left>" },
    redraw_after(function()
      state.selected_index = find_branch_segment_start(state, "up")
    end)
  )
  key(
    { "l", "<Right>" },
    redraw_after(function()
      state.selected_index = find_branch_segment_start(state, "down")
    end)
  )
  key("<CR>", function()
    finish(state, selected_entry_id(state))
  end)
  key("q", function()
    finish(state, nil)
  end)
  key("<Esc>", function()
    if state.search_query ~= "" then
      state.search_query = ""
      apply_filter(state)
      draw(state)
    else
      finish(state, nil)
    end
  end)
  key("/", function()
    vim.ui.input({ prompt = "Pi tree search: ", default = state.search_query }, function(input)
      if state.finished then
        return
      end
      if input ~= nil then
        state.search_query = input
        apply_filter(state)
        draw(state)
      end
    end)
  end)
  local function filter_key(lhs, mode)
    key(
      lhs,
      redraw_after(function()
        state.filter_mode = mode
        apply_filter(state)
      end)
    )
  end
  filter_key("d", "default")
  filter_key("t", "no-tools")
  filter_key("u", "user-only")
  filter_key("L", "labeled-only")
  filter_key("a", "all")
  key(
    "<BS>",
    redraw_after(function()
      if state.search_query ~= "" then
        state.search_query = state.search_query:sub(1, -2)
      end
      apply_filter(state)
    end)
  )
  key(
    "o",
    redraw_after(function()
      cycle_filter(state, 1)
    end)
  )
  key(
    "O",
    redraw_after(function()
      cycle_filter(state, -1)
    end)
  )
  key({ "i", "I", "A", "s", "S", "c", "C", "r", "R", "p", "P", "x", "X", "~", "<Insert>", "v", "V", "<C-v>" }, "<Nop>")
end

function M.is_request(message)
  local options = as_table(as_table(message).options)
  return type(options[1]) == "table" and options[1].__coactNvimPiTree == true
end

function M.select(message, callback)
  local options = as_table(as_table(message).options)
  local payload = as_table(options[1])
  local state = make_state(payload)
  state.callback = callback
  setup_highlights()

  local bufnr = vim.api.nvim_create_buf(false, true)
  state.bufnr = bufnr
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "coact-pi-tree"
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false

  local width = math.min(math.max(72, math.floor(vim.o.columns * 0.86)), math.max(40, vim.o.columns - 4))
  local height = math.min(math.max(16, math.floor(vim.o.lines * 0.72)), math.max(8, vim.o.lines - vim.o.cmdheight - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = " Pi session tree ",
    title_pos = "center",
  })
  if not ok then
    vim.cmd("botright split")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  state.winid = winid
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  lock_picker_modes(state)
  map_keys(state)
  draw(state)
  force_normal_mode(state)
end

function M._render_for_test(payload, opts)
  local state = make_state(payload)
  return render_model(state, opts and opts.width or 120, opts and opts.height or 24)
end

return M
