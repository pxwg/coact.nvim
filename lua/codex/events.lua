local util = require("codex.util")

local M = {}

local function first_string(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return ""
end

local function compact(value)
  return util.trim(tostring(value or ""):gsub("%s+", " "))
end

local function encode(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  if type(value) == "string" then
    return value
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or vim.inspect(value)
end

local function user_input_text(input)
  if input.type == "text" then
    return input.text or ""
  end
  if input.type == "image" then
    return "[image] " .. tostring(input.url or "")
  end
  if input.type == "localImage" then
    return "[local image] " .. tostring(input.path or "")
  end
  if input.type == "skill" then
    return "$skill:" .. tostring(input.name or input.path or "")
  end
  if input.type == "mention" then
    return "@" .. tostring(input.name or input.path or "")
  end
  return vim.inspect(input)
end

local function user_text(content)
  local out = {}
  for _, input in ipairs(content or {}) do
    local text = user_input_text(input)
    if text ~= "" then
      table.insert(out, text)
    end
  end
  return table.concat(out, "\n\n")
end

local function status_of(item)
  return first_string(item.status, item.phase, item.state, item.completed and "completed" or nil)
end

local function command_input(item)
  return {
    command = item.command,
    cwd = item.cwd,
    source = item.source,
    actions = item.commandActions,
  }
end

local function command_output(item)
  return {
    stdout = item.aggregatedOutput,
    exitCode = item.exitCode,
    durationMs = item.durationMs,
  }
end

local function file_change_output(item)
  return {
    changes = item.changes or {},
    output = item.output,
  }
end

local function tool_name(item)
  if item.type == "commandExecution" then
    return "Bash"
  end
  if item.type == "fileChange" then
    return "apply_patch"
  end
  if item.type == "mcpToolCall" then
    return (item.server and (item.server .. "/") or "") .. tostring(item.tool or "mcp")
  end
  if item.type == "dynamicToolCall" then
    return (item.namespace and (item.namespace .. ".") or "") .. tostring(item.tool or "dynamic")
  end
  if item.type == "webSearch" then
    return "web_search"
  end
  if item.type == "imageView" then
    return "view_image"
  end
  if item.type == "imageGeneration" then
    return "image_generation"
  end
  return tostring(item.type or "tool")
end

local function tool_block(item, turn_id)
  local input = item.arguments or item.input or item
  local output = item.result or item.output or item.error
  if item.type == "commandExecution" then
    input = command_input(item)
    output = command_output(item)
  elseif item.type == "fileChange" then
    input = { changes = item.changes }
    output = file_change_output(item)
  elseif item.type == "webSearch" then
    input = { query = item.query, action = item.action }
    output = item.action
  elseif item.type == "imageView" then
    input = { path = item.path }
    output = { path = item.path }
  elseif item.type == "imageGeneration" then
    input = { revisedPrompt = item.revisedPrompt }
    output = { result = item.result, savedPath = item.savedPath }
  end
  return {
    type = item.type == "fileChange" and "PatchBlock" or "ToolCallBlock",
    message_id = turn_id,
    item_id = item.id,
    tool_call_id = item.id,
    tool = tool_name(item),
    state = status_of(item),
    input = input,
    output = output,
    text = first_string(item.text, item.aggregatedOutput, item.output),
    raw = item,
  }
end

local function agent_states_text(states)
  local lines = {}
  for id, agent in pairs(states or {}) do
    table.insert(lines, ("- %s: %s"):format(id, compact(encode(agent))))
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

local function collab_agent_block(item, turn_id)
  local receivers = table.concat(item.receiverThreadIds or {}, ", ")
  local text = {}
  table.insert(text, "tool: " .. tostring(item.tool or "agent"))
  if item.prompt and item.prompt ~= "" then
    table.insert(text, "")
    table.insert(text, item.prompt)
  end
  if receivers ~= "" then
    table.insert(text, "")
    table.insert(text, "receivers: " .. receivers)
  end
  local states = agent_states_text(item.agentsStates)
  if states ~= "" then
    table.insert(text, "")
    table.insert(text, states)
  end
  return {
    type = "AgentTimelineBlock",
    message_id = turn_id,
    item_id = item.id,
    title = tostring(item.tool or "agent"),
    state = status_of(item),
    text = table.concat(text, "\n"),
    metadata = {
      source = "collabAgentToolCall",
      senderThreadId = item.senderThreadId,
      receiverThreadIds = item.receiverThreadIds,
      model = item.model,
      reasoningEffort = item.reasoningEffort,
    },
    raw = item,
  }
end

local item_converters = {}

item_converters.userMessage = function(item, turn_id)
  return {
    type = "UserBlock",
    message_id = turn_id,
    item_id = item.id,
    text = user_text(item.content),
    raw = item,
  }
end

item_converters.agentMessage = function(item, turn_id)
  return {
    type = "AssistantBlock",
    message_id = turn_id,
    item_id = item.id,
    text = item.text or "",
    state = status_of(item),
    raw = item,
  }
end

item_converters.reasoning = function(item, turn_id)
  local text = table.concat(item.content or {}, "\n")
  local summary = table.concat(item.summary or {}, "\n")
  if text == "" then
    text = summary
  elseif summary ~= "" then
    text = summary .. "\n\n" .. text
  end
  return {
    type = "ReasoningBlock",
    message_id = turn_id,
    item_id = item.id,
    text = text,
    state = status_of(item),
    raw = item,
  }
end

item_converters.plan = function(item, turn_id)
  return {
    type = "PlanBlock",
    message_id = turn_id,
    item_id = item.id,
    title = "Plan",
    text = item.text or "",
    state = status_of(item),
    raw = item,
  }
end

item_converters.commandExecution = tool_block
item_converters.fileChange = tool_block
item_converters.mcpToolCall = tool_block
item_converters.dynamicToolCall = tool_block
item_converters.webSearch = tool_block
item_converters.imageView = tool_block
item_converters.imageGeneration = tool_block
item_converters.collabAgentToolCall = collab_agent_block

item_converters.hookPrompt = function(item, turn_id)
  return {
    type = "ToolCallBlock",
    message_id = turn_id,
    item_id = item.id,
    tool = "hook_prompt",
    state = status_of(item),
    input = item.fragments,
    raw = item,
  }
end

item_converters.contextCompaction = function(item, turn_id)
  return {
    type = "AgentTimelineBlock",
    message_id = turn_id,
    item_id = item.id,
    title = "Context Compaction",
    state = "completed",
    text = "Context was compacted.",
    raw = item,
  }
end

item_converters.enteredReviewMode = function(item, turn_id)
  return {
    type = "AgentTimelineBlock",
    message_id = turn_id,
    item_id = item.id,
    title = "Review Mode",
    state = "entered",
    text = item.review or "",
    raw = item,
  }
end

item_converters.exitedReviewMode = function(item, turn_id)
  return {
    type = "AgentTimelineBlock",
    message_id = turn_id,
    item_id = item.id,
    title = "Review Mode",
    state = "exited",
    text = item.review or "",
    raw = item,
  }
end

function M.block_text(block)
  return tostring(block and block.text or "")
end

function M.block_for_item(item, turn_id)
  if type(item) ~= "table" then
    return nil
  end
  local converter = item_converters[item.type]
  if converter then
    return converter(item, turn_id)
  end
  return {
    type = "RawEventBlock",
    message_id = turn_id,
    item_id = item.id,
    title = tostring(item.type or "unknown"),
    text = compact(encode(item)),
    raw = item,
  }
end

function M.normalize_thread(thread)
  local blocks = {}
  for _, item_id in ipairs(thread.item_order or {}) do
    local item = thread.items[item_id]
    local block = M.block_for_item(item, thread.item_turns and thread.item_turns[item_id])
    if block then
      table.insert(blocks, block)
    end
  end
  return blocks
end

function M.pending_blocks(thread)
  local blocks = {}
  local request = thread and thread.pending_request
  if not request then
    return blocks
  end
  if request.prompt and request.prompt ~= "" then
    table.insert(blocks, {
      type = "UserBlock",
      message_id = "__pending_user__",
      text = request.prompt,
      state = "submitted",
      local_only = true,
      raw = request,
    })
  end
  return blocks
end

return M
