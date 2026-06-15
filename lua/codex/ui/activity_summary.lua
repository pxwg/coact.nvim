local events = require("codex.events")
local tool_renderers = require("codex.ui.tool_renderers")
local util = require("codex.util")

local M = {}

local function title(block)
  if block.type == "ReasoningBlock" then
    return "Reasoning" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "ToolCallBlock" or block.type == "PatchBlock" then
    return tostring(block.tool or "tool") .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "AgentTimelineBlock" then
    return "Agent: " .. tostring(block.title or "event") .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "PlanBlock" then
    return "Plan" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "RawEventBlock" then
    return "Raw Event: " .. tostring(block.title or "unknown")
  end
  return tostring(block.type or "Block")
end

local function append_child(lines, child)
  local has_meta = false
  table.insert(lines, "### " .. title(child))
  if child.item_id then
    table.insert(lines, "item: " .. tostring(child.item_id))
    has_meta = true
  end
  if child.tool_call_id then
    table.insert(lines, "tool_call_id: " .. tostring(child.tool_call_id))
    has_meta = true
  end
  if child.metadata and child.metadata.source then
    table.insert(lines, "source: " .. tostring(child.metadata.source))
    has_meta = true
  end
  if has_meta then
    table.insert(lines, "")
  end
  if child.type == "ToolCallBlock" or child.type == "PatchBlock" then
    for _, rendered_line in ipairs(tool_renderers.render(child)) do
      table.insert(lines, rendered_line)
    end
  else
    local text = events.block_text(child)
    if text ~= "" then
      util.list_extend(lines, util.split_lines(text))
    else
      table.insert(lines, "(no rendered content)")
    end
  end
  table.insert(lines, "")
end

function M.lines(children)
  local lines = {}
  for _, child in ipairs(children or {}) do
    append_child(lines, child)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

function M.text(children)
  return table.concat(M.lines(children), "\n")
end

return M
