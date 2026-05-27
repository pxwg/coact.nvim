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

local function handle_item(params, completed)
  local item = state.upsert_item(params.threadId, params.turnId, params.item)
  if completed then
    item.completed = true
  end
  schedule(params.threadId)
end

local handlers = {}

handlers["error"] = function(params)
  util.notify(params and params.message or "codex app-server error", vim.log.levels.ERROR)
end

handlers["thread/started"] = function(params)
  local thread = handle_thread(params.thread)
  hooks.emit("thread_opened", { thread = thread })
end

handlers["thread/name/updated"] = function(params)
  local thread = state.get_thread(params.threadId)
  if thread then
    thread.title = params.name
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

handlers["turn/started"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  thread.active_turn_id = params.turn.id
  schedule(params.threadId)
end

handlers["turn/completed"] = function(params)
  local thread = state.ensure_thread(params.threadId)
  state.add_turn(params.threadId, params.turn)
  if thread.active_turn_id == params.turn.id then
    thread.active_turn_id = nil
  end
  hooks.emit("generation_completed", { thread = thread, turn = params.turn })
  schedule(params.threadId)
end

handlers["item/started"] = function(params)
  handle_item(params, false)
end

handlers["item/completed"] = function(params)
  handle_item(params, true)
end

handlers["item/agentMessage/delta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "agentMessage")
  append_field(item, "text", params.delta)
  schedule(params.threadId)
end

handlers["item/reasoning/textDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.content = item.content or {}
  local index = (params.contentIndex or 0) + 1
  item.content[index] = (item.content[index] or "") .. (params.delta or "")
  schedule(params.threadId)
end

handlers["item/reasoning/summaryTextDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  item.summary[1] = (item.summary[1] or "") .. (params.delta or "")
  schedule(params.threadId)
end

handlers["item/reasoning/summaryPartAdded"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "reasoning")
  item.summary = item.summary or {}
  table.insert(item.summary, params.text or "")
  schedule(params.threadId)
end

handlers["item/plan/delta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "plan")
  append_field(item, "text", params.delta)
  schedule(params.threadId)
end

handlers["item/commandExecution/outputDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "commandExecution")
  append_field(item, "aggregatedOutput", params.delta)
  schedule(params.threadId)
end

handlers["item/fileChange/outputDelta"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  append_field(item, "output", params.delta)
  schedule(params.threadId)
end

handlers["item/fileChange/patchUpdated"] = function(params)
  local item = state.ensure_item(params.threadId, params.turnId, params.itemId, "fileChange")
  item.changes = params.changes or {}
  schedule(params.threadId)
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
  end
end

function M.handle_server_request(message)
  if message.method == "item/fileChange/requestApproval" or message.method == "applyPatchApproval" then
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
