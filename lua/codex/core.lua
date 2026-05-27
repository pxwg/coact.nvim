local buffers = require("codex.buffers")
local hooks = require("codex.hooks")
local state = require("codex.state")
local util = require("codex.util")

local M = {}

local function schedule(thread_id)
  if thread_id then
    buffers.schedule_render(thread_id)
  end
end

local function append_limited(list, value, limit)
  table.insert(list, value)
  limit = limit or 100
  while #list > limit do
    table.remove(list, 1)
  end
end

local function extract_thread_id(params)
  if type(params) ~= "table" then
    return state.active_thread_id
  end
  return params.threadId
    or params.thread_id
    or params.conversationId
    or (type(params.thread) == "table" and params.thread.id)
    or state.active_thread_id
end

local function thread_for_params(params)
  local thread_id = extract_thread_id(params)
  return thread_id and state.ensure_thread(thread_id) or nil
end

local function inspect_summary(value, limit)
  local ok, text = pcall(vim.inspect, value)
  return util.truncate(ok and text or tostring(value), limit or 160)
end

local function append_timeline(method, params, title, state_value, text)
  local thread = thread_for_params(params)
  if not thread then
    return
  end
  local block = {
    type = "AgentTimelineBlock",
    message_id = params and params.turnId,
    item_id = tostring(
      (params and (params.reviewId or params.requestId)) or (params and params.run and params.run.id) or method
    ),
    title = title,
    state = state_value,
    text = text or inspect_summary(params),
    metadata = { source = method },
    raw = params,
    local_only = true,
  }
  append_limited(thread.timeline_blocks, block)
  schedule(thread.id)
end

local function append_raw_event(method, params)
  local thread = thread_for_params(params)
  if not thread then
    return
  end
  append_limited(thread.raw_blocks, {
    type = "RawEventBlock",
    title = method,
    text = inspect_summary(params, 400),
    raw = {
      method = method,
      params = params,
    },
    local_only = true,
  }, 200)
  schedule(thread.id)
end

local function process_key(params)
  return tostring(params.processId or params.processHandle or "process")
end

local function decode_output_delta(params)
  if type(params) ~= "table" then
    return ""
  end
  if params.delta and params.delta ~= "" then
    return params.delta
  end
  if not params.deltaBase64 or params.deltaBase64 == "" then
    return ""
  end
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, params.deltaBase64)
    if ok then
      return decoded
    end
  end
  return "[base64 output: " .. util.truncate(params.deltaBase64, 80) .. "]"
end

local function process_output_block(method, params, tool_name)
  local thread = thread_for_params(params)
  if not thread then
    return nil
  end
  thread.process_blocks_by_id = thread.process_blocks_by_id or {}
  local key = tool_name .. ":" .. process_key(params)
  local block = thread.process_blocks_by_id[key]
  if not block then
    block = {
      type = "ToolCallBlock",
      item_id = key,
      tool = tool_name,
      state = "running",
      input = {
        process = process_key(params),
        stream = params.stream,
      },
      output = "",
      metadata = { source = method },
      raw = params,
      local_only = true,
    }
    thread.process_blocks_by_id[key] = block
    append_limited(thread.local_blocks, block)
  end
  return block, thread
end

local function append_field(item, field, delta)
  item[field] = (item[field] or "") .. (delta or "")
end

local function handle_thread(thread)
  local record = state.update_thread_from_payload(thread)
  if record and record.bufnr then
    schedule(record.id)
  end
  return record
end

local function set_generation(thread, generation, message)
  if thread then
    thread.generation = generation
    thread.status_message = message
  end
end

local function handle_item(params, completed)
  local item = state.upsert_item(params.threadId, params.turnId, params.item)
  if completed then
    item.completed = true
  end
  local thread = state.get_thread(params.threadId)
  if thread and not completed then
    if
      item.type == "commandExecution"
      or item.type == "mcpToolCall"
      or item.type == "dynamicToolCall"
      or item.type == "fileChange"
      or item.type == "webSearch"
      or item.type == "imageGeneration"
      or item.type == "collabAgentToolCall"
    then
      set_generation(thread, "tool_running", "Codex is using tools...")
    elseif item.type == "reasoning" then
      set_generation(thread, "streaming", "Codex is reasoning...")
    elseif item.type == "agentMessage" then
      set_generation(thread, "streaming", "Codex is responding...")
    end
  end
  schedule(params.threadId)
end

local handlers = {}

handlers["error"] = function(params)
  util.notify(params and params.message or "codex app-server error", vim.log.levels.ERROR)
end

handlers["thread/started"] = function(params)
  local thread = handle_thread(params.thread)
  if thread then
    thread.generation = thread.generation or "idle"
  end
  hooks.emit("thread_opened", { thread = thread })
end

handlers["thread/name/updated"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.title = util.value(params.name)
    schedule(params.threadId)
  end
end

handlers["thread/status/changed"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.status = params.status
    schedule(params.threadId)
  end
end

handlers["thread/archived"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.status = "archived"
    schedule(params.threadId)
  end
end

handlers["thread/unarchived"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.status = "active"
    schedule(params.threadId)
  end
end

handlers["thread/closed"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.lifecycle = "closed"
    set_generation(thread, "idle", nil)
    schedule(params.threadId)
  end
end

handlers["thread/goal/updated"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.goal = params.goal
  append_timeline("thread/goal/updated", params, "Goal updated", "updated", inspect_summary(params.goal or params, 200))
end

handlers["thread/goal/cleared"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.goal = nil
  append_timeline("thread/goal/cleared", params, "Goal cleared", "cleared", "Thread goal cleared.")
end

handlers["thread/settings/updated"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.settings = params.settings or params
  append_timeline(
    "thread/settings/updated",
    params,
    "Settings updated",
    "updated",
    inspect_summary(thread.settings, 200)
  )
end

handlers["thread/tokenUsage/updated"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.token_usage = params.tokenUsage or params.usage or params
    schedule(params.threadId)
  end
end

handlers["skills/changed"] = function()
  require("codex.catalog").invalidate("skills")
end

handlers["turn/started"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  thread.active_turn_id = params.turn.id
  set_generation(thread, "submitted", "Codex is thinking...")
  schedule(params.threadId)
end

handlers["hook/started"] = function(params)
  local run = params.run or {}
  append_timeline(
    "hook/started",
    params,
    "Hook: " .. tostring(run.eventName or run.id or "started"),
    "running",
    inspect_summary(run, 220)
  )
end

handlers["turn/completed"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  if thread.active_turn_id == params.turn.id then
    thread.active_turn_id = nil
  end
  thread.pending_request = nil
  set_generation(thread, "idle", nil)
  hooks.emit("generation_completed", { thread = thread, turn = params.turn })
  schedule(params.threadId)
end

handlers["hook/completed"] = function(params)
  local run = params.run or {}
  append_timeline(
    "hook/completed",
    params,
    "Hook: " .. tostring(run.eventName or run.id or "completed"),
    tostring(run.status or "completed"),
    inspect_summary(run, 220)
  )
end

handlers["item/started"] = function(params)
  handle_item(params, false)
end

handlers["item/autoApprovalReview/started"] = function(params)
  append_timeline(
    "item/autoApprovalReview/started",
    params,
    "Auto approval review",
    "running",
    inspect_summary(params.review or params.action or params, 220)
  )
end

handlers["item/autoApprovalReview/completed"] = function(params)
  append_timeline(
    "item/autoApprovalReview/completed",
    params,
    "Auto approval review",
    tostring(params.decisionSource or "completed"),
    inspect_summary(params.review or params.action or params, 220)
  )
end

handlers["item/completed"] = function(params)
  handle_item(params, true)
end

handlers["rawResponseItem/completed"] = function(params)
  append_raw_event("rawResponseItem/completed", params)
end

handlers["item/agentMessage/delta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "agentMessage")
  append_field(item, "text", params.delta)
  set_generation(state.get_thread(params.threadId), "streaming", "Codex is responding...")
  schedule(params.threadId)
end

handlers["item/reasoning/textDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.content = item.content or {}
  local index = (params.contentIndex or 0) + 1
  item.content[index] = (item.content[index] or "") .. (params.delta or "")
  set_generation(state.get_thread(params.threadId), "streaming", "Codex is reasoning...")
  schedule(params.threadId)
end

handlers["item/reasoning/summaryTextDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  item.summary[1] = (item.summary[1] or "") .. (params.delta or "")
  set_generation(state.get_thread(params.threadId), "streaming", "Codex is reasoning...")
  schedule(params.threadId)
end

handlers["item/reasoning/summaryPartAdded"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  table.insert(item.summary, params.text or "")
  set_generation(state.get_thread(params.threadId), "streaming", "Codex is reasoning...")
  schedule(params.threadId)
end

handlers["item/plan/delta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "plan")
  append_field(item, "text", params.delta)
  set_generation(state.get_thread(params.threadId), "streaming", "Codex is planning...")
  schedule(params.threadId)
end

handlers["item/commandExecution/outputDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "commandExecution")
  append_field(item, "aggregatedOutput", params.delta)
  set_generation(state.get_thread(params.threadId), "tool_running", "Codex is running a command...")
  schedule(params.threadId)
end

handlers["command/exec/outputDelta"] = function(params)
  local block, thread = process_output_block("command/exec/outputDelta", params, "command/exec")
  if block and thread then
    block.output = (block.output or "") .. decode_output_delta(params)
    block.state = params.capReached and "truncated" or "running"
    block.raw = params
    set_generation(thread, "tool_running", "Codex is streaming command output...")
    schedule(thread.id)
  end
end

handlers["process/outputDelta"] = function(params)
  local block, thread = process_output_block("process/outputDelta", params, "process/spawn")
  if block and thread then
    block.output = (block.output or "") .. decode_output_delta(params)
    block.state = params.capReached and "truncated" or "running"
    block.raw = params
    set_generation(thread, "tool_running", "Codex is streaming process output...")
    schedule(thread.id)
  end
end

handlers["process/exited"] = function(params)
  local block, thread = process_output_block("process/exited", params, "process/spawn")
  if block and thread then
    local stdout = params.stdout and params.stdout ~= "" and ("\nstdout:\n" .. params.stdout) or ""
    local stderr = params.stderr and params.stderr ~= "" and ("\nstderr:\n" .. params.stderr) or ""
    if stdout ~= "" or stderr ~= "" then
      block.output = (block.output or "") .. stdout .. stderr
    end
    block.state = "exit " .. tostring(params.exitCode)
    block.raw = params
    set_generation(thread, "idle", nil)
    schedule(thread.id)
  end
end

handlers["item/commandExecution/terminalInteraction"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "commandExecution")
  item.terminal_interaction = params
  set_generation(state.get_thread(params.threadId), "tool_running", "Codex is waiting for terminal interaction...")
  schedule(params.threadId)
end

handlers["item/fileChange/outputDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  append_field(item, "output", params.delta)
  set_generation(state.get_thread(params.threadId), "tool_running", "Codex is preparing edits...")
  schedule(params.threadId)
end

handlers["item/fileChange/patchUpdated"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  item.changes = params.changes or {}
  set_generation(state.get_thread(params.threadId), "tool_running", "Codex is preparing edits...")
  schedule(params.threadId)
end

handlers["item/mcpToolCall/progress"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "mcpToolCall")
  item.progress = params
  set_generation(state.get_thread(params.threadId), "tool_running", "Codex is using an MCP tool...")
  schedule(params.threadId)
end

handlers["mcpServer/startupStatus/updated"] = function(params)
  require("codex.catalog").invalidate("tools")
  append_timeline(
    "mcpServer/startupStatus/updated",
    params,
    "MCP server status",
    "updated",
    inspect_summary(params, 220)
  )
end

handlers["app/list/updated"] = function(params)
  require("codex.catalog").invalidate("tools")
  append_timeline("app/list/updated", params, "App list updated", "updated", inspect_summary(params, 220))
end

handlers["turn/diff/updated"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.turn_diff = params
  set_generation(thread, "tool_running", "Codex is updating the diff...")
  schedule(params.threadId)
end

handlers["serverRequest/resolved"] = function(params)
  append_timeline(
    "serverRequest/resolved",
    params,
    "Server request resolved",
    "resolved",
    "requestId: " .. tostring(params.requestId)
  )
end

handlers["turn/plan/updated"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.turn_plan = params
  set_generation(thread, "streaming", "Codex is planning...")
  schedule(params.threadId)
end

handlers["thread/compacted"] = function(params)
  append_timeline("thread/compacted", params, "Context compacted", "completed", "Context was compacted.")
end

handlers["model/rerouted"] = function(params)
  append_timeline(
    "model/rerouted",
    params,
    "Model rerouted",
    "rerouted",
    tostring(params.fromModel) .. " -> " .. tostring(params.toModel) .. " (" .. tostring(params.reason) .. ")"
  )
end

handlers["model/verification"] = function(params)
  append_timeline(
    "model/verification",
    params,
    "Model verification",
    "checked",
    inspect_summary(params.verifications or params, 220)
  )
end

handlers["warning"] = function(params)
  util.notify(params and (params.message or vim.inspect(params)) or "codex warning", vim.log.levels.WARN)
end

handlers["configWarning"] = handlers["warning"]
handlers["guardianWarning"] = handlers["warning"]
handlers["deprecationNotice"] = handlers["warning"]

function M.handle_notification(message)
  local handler = handlers[message.method]
  if handler then
    handler(message.params or {})
  else
    append_raw_event(message.method or "notification", message.params or {})
  end
end

function M.handle_server_request(message)
  if message.method == "item/fileChange/requestApproval" or message.method == "applyPatchApproval" then
    local params = message.params or {}
    local thread = state.get_thread(params.threadId or params.conversationId)
    set_generation(thread, "patch_review", "Waiting for patch review...")
    if thread then
      schedule(thread.id)
    end
    require("codex.patch_review").request_approval(message)
    return
  end
  if message.method == "item/commandExecution/requestApproval" or message.method == "execCommandApproval" then
    require("codex.approvals").command(message)
    return
  end
  if message.method == "item/permissions/requestApproval" then
    require("codex.approvals").permissions(message)
    return
  end
  if message.method == "item/tool/call" then
    require("codex.dynamic_tools").handle_call(message)
    return
  end
  require("codex.rpc").respond_error(message.id, "codex.nvim does not handle server request: " .. message.method)
end

function M.setup()
  require("codex.rpc").set_handlers({
    notification = M.handle_notification,
    server_request = M.handle_server_request,
    stderr = function(text)
      if text:match("%S") then
        vim.schedule(function()
          vim.notify(text, vim.log.levels.DEBUG, { title = "codex app-server" })
        end)
      end
    end,
  })
end

return M
