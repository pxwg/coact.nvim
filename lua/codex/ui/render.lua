local util = require("codex.util")

local M = {}

local function append(lines, text)
  for _, line in ipairs(util.split_lines(text)) do
    table.insert(lines, line)
  end
end

local function input_text(input)
  if input.type == "text" then
    return input.text
  end
  if input.type == "localImage" then
    return "[local image] " .. input.path
  end
  if input.type == "image" then
    return "[image] " .. input.url
  end
  if input.type == "skill" then
    return "$" .. input.name
  end
  if input.type == "mention" then
    return "@" .. input.name .. " (" .. input.path .. ")"
  end
  return vim.inspect(input)
end

local function item_title(item)
  if item.type == "userMessage" then
    return "You"
  end
  if item.type == "agentMessage" then
    return "Codex"
  end
  if item.type == "reasoning" then
    return "Reasoning"
  end
  if item.type == "plan" then
    return "Plan"
  end
  if item.type == "commandExecution" then
    return "Command"
  end
  if item.type == "fileChange" then
    return "Patch Proposal"
  end
  if item.type == "mcpToolCall" then
    return "MCP Tool"
  end
  if item.type == "dynamicToolCall" then
    return "Editor Tool"
  end
  if item.type == "webSearch" then
    return "Web Search"
  end
  return item.type or "Item"
end

local function render_user(lines, item)
  table.insert(lines, "### " .. item_title(item))
  local chunks = {}
  for _, input in ipairs(item.content or {}) do
    table.insert(chunks, input_text(input))
  end
  append(lines, table.concat(chunks, "\n\n"))
end

local function render_agent(lines, item)
  table.insert(lines, "### " .. item_title(item))
  append(lines, item.text or "")
end

local function render_reasoning(lines, item)
  table.insert(lines, "### " .. item_title(item))
  if item.summary and #item.summary > 0 then
    append(lines, table.concat(item.summary, "\n"))
  end
  if item.content and #item.content > 0 then
    table.insert(lines, "")
    table.insert(lines, "```text")
    append(lines, table.concat(item.content, "\n"))
    table.insert(lines, "```")
  end
end

local function render_plan(lines, item)
  table.insert(lines, "### " .. item_title(item))
  append(lines, item.text or "")
end

local function render_command(lines, item)
  table.insert(lines, "### " .. item_title(item))
  table.insert(lines, "```sh")
  append(lines, item.command or "")
  table.insert(lines, "```")
  if item.status then
    table.insert(lines, "status: " .. tostring(item.status))
  end
  if item.aggregatedOutput and item.aggregatedOutput ~= "" then
    table.insert(lines, "")
    table.insert(lines, "```text")
    append(lines, item.aggregatedOutput)
    table.insert(lines, "```")
  end
end

local function render_file_change(lines, item)
  table.insert(lines, "### " .. item_title(item))
  table.insert(lines, "status: " .. tostring(item.status or "pending"))
  for _, change in ipairs(item.changes or {}) do
    table.insert(lines, "")
    table.insert(lines, ("#### %s %s"):format(change.kind or "update", change.path or ""))
    if change.diff and change.diff ~= "" then
      table.insert(lines, "```diff")
      append(lines, change.diff)
      table.insert(lines, "```")
    end
  end
end

local function render_tool(lines, item)
  table.insert(lines, "### " .. item_title(item))
  if item.server and item.tool then
    table.insert(lines, ("`%s/%s`"):format(item.server, item.tool))
  elseif item.tool then
    table.insert(lines, "`" .. item.tool .. "`")
  end
  if item.status then
    table.insert(lines, "status: " .. tostring(item.status))
  end
  if item.arguments then
    table.insert(lines, "")
    table.insert(lines, "```json")
    append(lines, vim.json.encode(item.arguments))
    table.insert(lines, "```")
  end
end

local renderers = {
  userMessage = render_user,
  agentMessage = render_agent,
  reasoning = render_reasoning,
  plan = render_plan,
  commandExecution = render_command,
  fileChange = render_file_change,
  mcpToolCall = render_tool,
  dynamicToolCall = render_tool,
  webSearch = render_tool,
}

function M.thread(thread, prompt_lines)
  local lines = {}
  local title = util.value(thread.title) or util.truncate(thread.id, 18)
  table.insert(lines, "# Codex: " .. title)
  table.insert(lines, "")
  table.insert(lines, ("thread: `%s`"):format(thread.id))
  if thread.cwd then
    table.insert(lines, ("cwd: `%s`"):format(thread.cwd))
  end
  if thread.status then
    table.insert(lines, ("status: `%s`"):format(thread.status))
  end
  if thread.last_error then
    table.insert(lines, "")
    table.insert(lines, "> error: " .. tostring(thread.last_error))
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  for _, item_id in ipairs(thread.item_order) do
    local item = thread.items[item_id]
    if item then
      local renderer = renderers[item.type]
      if renderer then
        renderer(lines, item)
      else
        table.insert(lines, "### " .. item_title(item))
        table.insert(lines, "```lua")
        append(lines, vim.inspect(item))
        table.insert(lines, "```")
      end
      table.insert(lines, "")
    end
  end

  table.insert(lines, "## Prompt")
  table.insert(lines, "")
  if prompt_lines and #prompt_lines > 0 then
    vim.list_extend(lines, prompt_lines)
  end
  return lines
end

return M
