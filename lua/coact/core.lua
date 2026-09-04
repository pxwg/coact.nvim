local buffers = require("coact.buffers")
local config = require("coact.config")
local hooks = require("coact.hooks")
local providers = require("coact.providers")
local state = require("coact.state")
local util = require("coact.util")

local M = {}

local function schedule(thread_id)
  if thread_id then
    buffers.schedule_render(thread_id)
  end
end

local function refresh_composer(thread)
  if thread and thread.prompt_bufnr then
    buffers.refresh_composer(thread)
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
  return util.value(params.threadId)
    or util.value(params.thread_id)
    or util.value(params.conversationId)
    or (type(params.thread) == "table" and util.value(params.thread.id))
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

local function text_value(value)
  value = util.value(value)
  if value == nil then
    return ""
  end
  return tostring(value)
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

local function hook_event_name(run)
  return tostring(util.value(run.eventName) or util.value(run.event_name) or util.value(run.id) or "hook")
end

local function hook_run_id(method, params, run, group)
  return tostring(
    util.value(run.id)
      or util.value(run.runId)
      or util.value(run.run_id)
      or util.value(params.runId)
      or util.value(params.run_id)
      or ("%s:%d"):format(method, #(group.hook_run_order or {}) + 1)
  )
end

local function hook_group_id(params, run)
  local turn_id = util.value(params.turnId) or util.value(params.turn_id) or util.value(run.turnId) or "thread"
  return "hook:" .. tostring(turn_id) .. ":" .. hook_event_name(run)
end

local function hook_status(method, run)
  return tostring(util.value(run.status) or (method == "hook/started" and "running" or "completed"))
end

local function hook_group_state(group)
  local latest = "completed"
  for _, id in ipairs(group.hook_run_order or {}) do
    local run = group.hook_runs and group.hook_runs[id]
    if run then
      latest = run.status or latest
      if run.status == "running" then
        return "running"
      end
    end
  end
  return latest
end

local function hook_group_text(group)
  local order = group.hook_run_order or {}
  local total = #order
  local latest = total > 0 and group.hook_runs[order[total]] or nil
  local latest_status = latest and latest.status or group.state or "completed"
  local lines = {
    ("%d hook run%s for %s; latest %s."):format(
      total,
      total == 1 and "" or "s",
      tostring(group.hook_event or "hook"),
      tostring(latest_status)
    ),
  }
  for _, id in ipairs(order) do
    local run = group.hook_runs[id]
    if run then
      table.insert(lines, ("- %s: %s"):format(util.short_id(id), tostring(run.status or "unknown")))
      if run.summary and run.summary ~= "" then
        table.insert(lines, "  " .. run.summary)
      end
    end
  end
  return table.concat(lines, "\n")
end

local function upsert_hook_timeline(method, params)
  local thread = thread_for_params(params)
  if not thread then
    return
  end
  local run = type(params.run) == "table" and params.run or {}
  local event_name = hook_event_name(run)
  local group_id = hook_group_id(params, run)
  thread.hook_timeline_blocks = thread.hook_timeline_blocks or {}
  local block = thread.hook_timeline_blocks[group_id]
  if not block then
    block = {
      type = "AgentTimelineBlock",
      message_id = params and params.turnId,
      item_id = group_id,
      title = "Hook: " .. event_name,
      state = "running",
      text = "",
      metadata = { source = "hook", eventName = event_name },
      raw = params,
      local_only = true,
      hook_event = event_name,
      hook_runs = {},
      hook_run_order = {},
    }
    thread.hook_timeline_blocks[group_id] = block
    append_limited(thread.timeline_blocks, block)
  end

  local run_id = hook_run_id(method, params, run, block)
  if not block.hook_runs[run_id] then
    table.insert(block.hook_run_order, run_id)
  end
  block.hook_runs[run_id] = {
    status = hook_status(method, run),
    method = method,
    summary = inspect_summary(run, 180),
    raw = run,
  }
  block.state = hook_group_state(block)
  block.text = hook_group_text(block)
  block.raw = params
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
  return tostring(util.value(params.processId) or util.value(params.processHandle) or "process")
end

local function decode_output_delta(params)
  if type(params) ~= "table" then
    return ""
  end
  local delta = util.value(params.delta)
  if delta and delta ~= "" then
    return util.clean_tool_output(delta)
  end
  local delta_base64 = util.value(params.deltaBase64)
  if not delta_base64 or delta_base64 == "" then
    return ""
  end
  delta_base64 = tostring(delta_base64)
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, delta_base64)
    if ok and decoded ~= nil then
      return util.clean_tool_output(decoded)
    end
  end
  return "[base64 output: " .. util.truncate(delta_base64, 80) .. "]"
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
        stream = util.value(params.stream),
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
  delta = util.value(delta)
  if delta == nil then
    return
  end
  item[field] = text_value(item[field]) .. tostring(delta)
end

local function append_output_field(item, field, delta)
  delta = util.value(delta)
  if delta == nil then
    return
  end
  item[field] = text_value(item[field]) .. util.clean_tool_output(delta)
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
    local changed = thread.generation ~= generation or thread.status_message ~= message
    thread.generation = generation
    thread.status_message = message
    if changed then
      refresh_composer(thread)
    end
  end
end

local function agent_label()
  return providers.agent_label()
end

local function refresh_completed_pi_compaction(params)
  local provider = providers.current()
  if type(provider.on_compaction_completed) ~= "function" then
    return
  end
  local ok, err = pcall(provider.on_compaction_completed, params)
  if not ok then
    util.notify("coact.nvim Pi compaction refresh failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function queued_request(request)
  return type(request) == "table" and (request.streaming_behavior or request.streamingBehavior) ~= nil
end

local function pending_request_for_turn(thread, turn_id)
  local fallback
  for _, request in ipairs(state.get_thread_pending_requests(thread)) do
    if request.turn_id == turn_id then
      return request
    end
    if not fallback and not request.turn_id and not queued_request(request) then
      fallback = request
    end
  end
  return fallback
end

local function has_queued_request(thread)
  for _, request in ipairs(state.get_thread_pending_requests(thread)) do
    if queued_request(request) then
      return true
    end
  end
  return false
end

local placeholder_stream_item_types = {
  commandExecution = true,
  mcpToolCall = true,
  dynamicToolCall = true,
  fileChange = true,
  webSearch = true,
  imageGeneration = true,
  collabAgentToolCall = true,
  reasoning = true,
  plan = true,
}

local function handle_item(params, completed)
  local item = state.upsert_item(params.threadId, params.turnId, params.item)
  if completed then
    item.completed = true
  end
  local thread = state.get_thread(params.threadId)
  if thread and item.type == "userMessage" then
    local echoed = {}
    for _, pending in ipairs(state.get_thread_pending_requests(thread)) do
      if pending.turn_id == params.turnId then
        table.insert(echoed, pending)
      end
    end
    for _, pending in ipairs(echoed) do
      state.remove_thread_pending_request(thread, pending)
    end
  end
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
      set_generation(thread, "tool_running", agent_label() .. " is using tools...")
    elseif item.type == "reasoning" then
      set_generation(thread, "streaming", agent_label() .. " is reasoning...")
    elseif item.type == "agentMessage" then
      set_generation(thread, "streaming", agent_label() .. " is responding...")
    end
  end
  if placeholder_stream_item_types[item.type] and buffers.try_stream_placeholder_delta(params.threadId, item.id) then
    return
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
    thread.status = util.status_label(params.status) or thread.status
    thread.status_payload = util.value(params.status)
    refresh_composer(thread)
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
  pcall(function()
    require("coact.dynamic_tools").clear_thread_state(params.threadId)
  end)
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
  thread.settings = params.threadSettings or params.settings or params
  state.apply_thread_settings(thread, thread.settings)
  refresh_composer(thread)
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
    refresh_composer(thread)
    schedule(params.threadId)
  end
end

handlers["skills/changed"] = function()
  require("coact.catalog").invalidate("skills")
end

handlers["turn/started"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  thread.active_turn_id = params.turn.id
  local pending = pending_request_for_turn(thread, params.turn.id)
  if pending then
    pending.turn_id = params.turn.id
    state.set_turn_settings(params.threadId, params.turn.id, pending.settings)
  end
  set_generation(thread, "submitted", agent_label() .. " is thinking...")
  schedule(params.threadId)
end

handlers["hook/started"] = function(params)
  upsert_hook_timeline("hook/started", params)
end

handlers["turn/completed"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  pcall(function()
    require("coact.dynamic_tools").clear_turn_state(params.threadId, params.turn.id)
  end)
  if thread.active_turn_id == params.turn.id then
    thread.active_turn_id = nil
  end
  local completed_pending = {}
  local fallback_pending
  for _, pending in ipairs(state.get_thread_pending_requests(thread)) do
    if pending.turn_id == params.turn.id then
      table.insert(completed_pending, pending)
    elseif not fallback_pending and not pending.turn_id and not queued_request(pending) then
      fallback_pending = pending
    end
  end
  if #completed_pending == 0 and fallback_pending then
    table.insert(completed_pending, fallback_pending)
  end
  for _, pending in ipairs(completed_pending) do
    state.remove_thread_pending_request(thread, pending)
  end
  if #state.get_thread_pending_requests(thread) > 0 then
    local message = has_queued_request(thread) and (agent_label() .. " has a queued follow-up...")
      or (agent_label() .. " is thinking...")
    set_generation(thread, "submitted", message)
  elseif thread.pi_agent_active then
    -- Pi turn completion only closes one model/tool turn. The rollout stays
    -- active until pi/agent_settled, including automatic tool continuations.
    set_generation(thread, "submitted", agent_label() .. " is thinking...")
  else
    set_generation(thread, "idle", nil)
  end
  local event = { thread = thread, turn = params.turn }
  hooks.emit("generation_completed", event)
  local provider = providers.current()
  if type(provider.on_generation_completed) == "function" then
    local ok, err = pcall(provider.on_generation_completed, event)
    if not ok then
      util.notify("coact.nvim provider generation hook failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  schedule(params.threadId)
end

handlers["hook/completed"] = function(params)
  upsert_hook_timeline("hook/completed", params)
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
  set_generation(state.get_thread(params.threadId), "streaming", agent_label() .. " is responding...")
  if not buffers.try_stream_delta(params.threadId, params.itemId, params.delta) then
    schedule(params.threadId)
  end
end

handlers["item/reasoning/textDelta"] = function(params)
  if util.value(params.delta) == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.content = item.content or {}
  local index = (tonumber(util.value(params.contentIndex)) or 0) + 1
  item.content[index] = text_value(item.content[index]) .. text_value(params.delta)
  set_generation(state.get_thread(params.threadId), "streaming", agent_label() .. " is reasoning...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/reasoning/summaryTextDelta"] = function(params)
  if util.value(params.delta) == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  local index = (tonumber(util.value(params.summaryIndex)) or 0) + 1
  item.summary[index] = text_value(item.summary[index]) .. text_value(params.delta)
  set_generation(state.get_thread(params.threadId), "streaming", agent_label() .. " is reasoning...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/reasoning/summaryPartAdded"] = function(params)
  local summary_index = tonumber(util.value(params.summaryIndex))
  local text = util.value(params.text)
  if summary_index == nil and text == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  if summary_index ~= nil then
    local index = summary_index + 1
    item.summary[index] = text_value(item.summary[index])
  else
    table.insert(item.summary, text_value(text))
  end
  set_generation(state.get_thread(params.threadId), "streaming", agent_label() .. " is reasoning...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/plan/delta"] = function(params)
  if util.value(params.delta) == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "plan")
  append_field(item, "text", params.delta)
  set_generation(state.get_thread(params.threadId), "streaming", agent_label() .. " is planning...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/commandExecution/outputDelta"] = function(params)
  if util.value(params.delta) == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "commandExecution")
  append_output_field(item, "aggregatedOutput", params.delta)
  set_generation(state.get_thread(params.threadId), "tool_running", agent_label() .. " is running a command...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["command/exec/outputDelta"] = function(params)
  local block, thread = process_output_block("command/exec/outputDelta", params, "command/exec")
  if block and thread then
    block.output = text_value(block.output) .. decode_output_delta(params)
    block.state = util.value(params.capReached) and "truncated" or "running"
    block.raw = params
    set_generation(thread, "tool_running", agent_label() .. " is streaming command output...")
    schedule(thread.id)
  end
end

handlers["process/outputDelta"] = function(params)
  local block, thread = process_output_block("process/outputDelta", params, "process/spawn")
  if block and thread then
    block.output = text_value(block.output) .. decode_output_delta(params)
    block.state = util.value(params.capReached) and "truncated" or "running"
    block.raw = params
    set_generation(thread, "tool_running", agent_label() .. " is streaming process output...")
    schedule(thread.id)
  end
end

handlers["process/exited"] = function(params)
  local block, thread = process_output_block("process/exited", params, "process/spawn")
  if block and thread then
    local stdout_text = util.clean_tool_output(text_value(params.stdout))
    local stderr_text = util.clean_tool_output(text_value(params.stderr))
    local stdout = stdout_text ~= "" and ("\nstdout:\n" .. stdout_text) or ""
    local stderr = stderr_text ~= "" and ("\nstderr:\n" .. stderr_text) or ""
    if stdout ~= "" or stderr ~= "" then
      block.output = text_value(block.output) .. stdout .. stderr
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
  set_generation(
    state.get_thread(params.threadId),
    "tool_running",
    agent_label() .. " is waiting for terminal interaction..."
  )
  schedule(params.threadId)
end

handlers["item/fileChange/outputDelta"] = function(params)
  if util.value(params.delta) == nil then
    return
  end
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  append_field(item, "output", params.delta)
  set_generation(state.get_thread(params.threadId), "tool_running", agent_label() .. " is preparing edits...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/fileChange/patchUpdated"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  item.changes = params.changes or {}
  set_generation(state.get_thread(params.threadId), "tool_running", agent_label() .. " is preparing edits...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["item/mcpToolCall/progress"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "mcpToolCall")
  item.progress = util.value(params.progress) or util.value(params.message) or params
  if util.value(params.toolName) then
    item.tool = util.value(params.toolName)
  end
  if type(params.args) == "table" then
    item.arguments = params.args
    item.input = params.args
  end
  local message = util.value(params.message)
  if message ~= nil then
    item.progressText = util.clean_tool_output(message)
    item.progress = item.progressText
  end
  append_output_field(item, "output", params.delta)
  set_generation(state.get_thread(params.threadId), "tool_running", agent_label() .. " is using a tool...")
  if not buffers.try_stream_placeholder_delta(params.threadId, params.itemId) then
    schedule(params.threadId)
  end
end

handlers["mcpServer/startupStatus/updated"] = function()
  require("coact.catalog").invalidate("tools")
end

handlers["app/list/updated"] = function()
  require("coact.catalog").invalidate("tools")
end

handlers["turn/diff/updated"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.turn_diff = params
  set_generation(thread, "tool_running", agent_label() .. " is updating the diff...")
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
  set_generation(thread, "streaming", agent_label() .. " is planning...")
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

handlers["pi/agent_start"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.pi_agent_active = true
  thread.active_turn_id = params.turnId or thread.active_turn_id
  set_generation(thread, "submitted", "Pi is thinking...")
  schedule(params.threadId)
end

handlers["pi/queued_turn_started"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  for _, pending in ipairs(state.get_thread_pending_requests(thread)) do
    if pending.turn_id == params.queuedTurnId then
      state.set_turn_settings(params.threadId, params.turnId, pending.settings)
      state.remove_thread_pending_request(thread, pending)
      break
    end
  end
end

handlers["pi/agent_end"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  if params.willRetry then
    set_generation(thread, "waiting_backend", "Pi is retrying...")
  elseif has_queued_request(thread) then
    set_generation(thread, "submitted", agent_label() .. " has a queued follow-up...")
  elseif thread.pi_agent_active then
    -- agent_end may still be followed by extension work, compaction, retry, or
    -- queued continuations. Only agent_settled is authoritative rollout end.
    set_generation(thread, "waiting_backend", "Pi is settling...")
  else
    set_generation(thread, "idle", nil)
  end
  require("coact.rpc").request("account/rateLimits/read", { threadId = params.threadId }, function()
    schedule(params.threadId)
  end)
  schedule(params.threadId)
end

handlers["pi/agent_settled"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  local pending_compaction_refresh = thread.pi_compaction_refresh
  thread.pi_compaction_refresh = nil
  thread.pi_agent_active = false
  thread.active_turn_id = nil
  thread.pi_queue = { steering = {}, follow_up = {} }
  state.clear_thread_pending_requests(thread)
  set_generation(thread, "idle", nil)
  if pending_compaction_refresh then
    refresh_completed_pi_compaction(pending_compaction_refresh)
  end
  schedule(params.threadId)
end

handlers["pi/queue_update"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.pi_queue = {
    steering = type(params.steering) == "table" and vim.deepcopy(params.steering) or {},
    follow_up = type(params.followUp) == "table" and vim.deepcopy(params.followUp) or {},
  }
  refresh_composer(thread)
end

handlers["pi/compaction_start"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.pi_compaction_active = true
  set_generation(thread, "summarizing", "Pi is compacting context...")
  schedule(params.threadId)
end

handlers["pi/compaction_end"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  thread.pi_compaction_active = false
  local has_pending_request = #state.get_thread_pending_requests(thread) > 0
  local result = util.value(params.result)
  if type(result) == "table" then
    if util.value(params.willRetry) == true or thread.pi_agent_active or has_pending_request then
      thread.pi_compaction_refresh = vim.deepcopy(params)
    else
      refresh_completed_pi_compaction(params)
    end
  elseif util.value(params.aborted) == true then
    append_timeline(
      "pi/compaction_end",
      params,
      "Pi compaction cancelled",
      "cancelled",
      "Context compaction was cancelled."
    )
  else
    append_timeline(
      "pi/compaction_end",
      params,
      "Pi compaction failed",
      "error",
      tostring(util.value(params.errorMessage) or "No compaction summary was produced.")
    )
  end

  if util.value(params.willRetry) == true then
    set_generation(thread, "waiting_backend", "Pi is retrying after compaction...")
  elseif has_pending_request then
    local message = has_queued_request(thread) and (agent_label() .. " has a queued follow-up...")
      or (agent_label() .. " is thinking...")
    set_generation(thread, "submitted", message)
  elseif thread.pi_agent_active then
    set_generation(thread, "waiting_backend", "Pi is settling...")
  else
    set_generation(thread, "idle", nil)
  end
  schedule(params.threadId)
end

-- Pi renders retries as transient status. The surrounding agent lifecycle
-- already drives generation state, so keep these notifications handled without
-- leaving timeline blocks behind.
handlers["pi/auto_retry_start"] = function() end
handlers["pi/auto_retry_end"] = function() end

handlers["pi/extension_error"] = function(params)
  append_timeline(
    "pi/extension_error",
    params,
    "Pi extension error",
    "error",
    tostring(params.error or "extension error")
  )
end

handlers["configWarning"] = handlers["warning"]
handlers["guardianWarning"] = handlers["warning"]
handlers["deprecationNotice"] = handlers["warning"]

local function nvim_apply_patch_pair_mode()
  return config.edit_mode() == "pair"
end

local function native_apply_patch_debug_log(event, data)
  local ok, native_hook = pcall(require, "coact.native_apply_patch_hook")
  if ok and type(native_hook.debug_log) == "function" then
    native_hook.debug_log(event, data)
  end
end

local function native_file_change_accept_response(method)
  if method == "applyPatchApproval" then
    return { decision = "approved" }
  end
  return { decision = "accept" }
end

local function native_file_change_decline_response(method)
  if method == "applyPatchApproval" then
    return { decision = "denied" }
  end
  return { decision = "decline" }
end

local function decline_native_file_change_in_pair_mode(message)
  if not nvim_apply_patch_pair_mode() then
    return false
  end

  local params = message.params or {}
  native_apply_patch_debug_log("file_change_decline_unreviewed", {
    method = message.method,
    request_id = message.id,
    params = params,
  })
  append_timeline(
    message.method or "item/fileChange/requestApproval",
    params,
    "Native patch declined",
    "declined",
    "pair edit mode requires native apply_patch to pass the Neovim PreToolUse review hook first"
  )
  require("coact.rpc").respond(message.id, native_file_change_decline_response(message.method))
  util.notify("pair mode declined unreviewed native apply_patch", vim.log.levels.WARN)
  return true
end

local function accept_reviewed_native_file_change(message)
  if not nvim_apply_patch_pair_mode() then
    return false
  end
  local params = message.params or {}
  native_apply_patch_debug_log("file_change_request_seen", {
    method = message.method,
    request_id = message.id,
    params = params,
  })
  if not require("coact.native_apply_patch_hook").consume_reviewed_approval(params) then
    return false
  end
  native_apply_patch_debug_log("file_change_accept_reviewed", {
    method = message.method,
    request_id = message.id,
    params = params,
  })
  append_timeline(
    message.method or "item/fileChange/requestApproval",
    params,
    "Native patch approved",
    "approved",
    "apply_patch was already reviewed by Neovim PreToolUse hook"
  )
  require("coact.rpc").respond(message.id, native_file_change_accept_response(message.method))
  return true
end

local function accept_reviewed_native_permission(message)
  if not nvim_apply_patch_pair_mode() then
    return false
  end
  local params = message.params or {}
  native_apply_patch_debug_log("permission_request_seen", {
    method = message.method,
    request_id = message.id,
    params = params,
  })
  if not require("coact.native_apply_patch_hook").consume_reviewed_approval(params, "permission") then
    return false
  end
  native_apply_patch_debug_log("permission_accept_reviewed", {
    method = message.method,
    request_id = message.id,
    params = params,
  })
  append_timeline(
    message.method or "item/permissions/requestApproval",
    params,
    "Native apply_patch permission approved",
    "approved",
    "apply_patch permission was already reviewed by Neovim PreToolUse hook"
  )
  require("coact.rpc").respond(message.id, { decision = "accept" })
  return true
end

function M.handle_notification(message)
  if tostring(message.method or ""):lower():match("hook") then
    native_apply_patch_debug_log("app_server_hook_notification", {
      method = message.method,
      params = message.params,
    })
  end
  local handler = handlers[message.method]
  if handler then
    handler(message.params or {})
  else
    append_raw_event(message.method or "notification", message.params or {})
  end
end

function M.handle_server_request(message)
  if message.method == "item/fileChange/requestApproval" or message.method == "applyPatchApproval" then
    if accept_reviewed_native_file_change(message) then
      return
    end
    if decline_native_file_change_in_pair_mode(message) then
      return
    end
    local params = message.params or {}
    local thread = state.get_thread(params.threadId or params.conversationId)
    set_generation(thread, "patch_review", "Waiting for patch review...")
    if thread then
      schedule(thread.id)
    end
    require("coact.patch_review").request_approval(message)
    return
  end
  if message.method == "item/commandExecution/requestApproval" or message.method == "execCommandApproval" then
    require("coact.approvals").command(message)
    return
  end
  if message.method == "item/permissions/requestApproval" then
    if accept_reviewed_native_permission(message) then
      return
    end
    require("coact.approvals").permissions(message)
    return
  end
  if message.method == "item/tool/call" then
    require("coact.dynamic_tools").handle_call(message)
    return
  end
  require("coact.rpc").respond_error(message.id, "coact.nvim does not handle server request: " .. message.method)
end

function M.setup()
  require("coact.rpc").set_handlers({
    notification = M.handle_notification,
    server_request = M.handle_server_request,
    stderr = function(text)
      if text:match("%S") then
        vim.schedule(function()
          vim.notify(util.clean_tool_output(text), vim.log.levels.DEBUG, { title = "codex app-server" })
        end)
      end
    end,
  })
end

return M
