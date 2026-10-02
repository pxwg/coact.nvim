local config = require("coact.config")
local provider = require("coact.providers.claude")
local catalog = require("coact.providers.claude_catalog")
local history = require("coact.providers.claude_history")
local start_entry
local runtime = require("coact.runtime")
local M = runtime.state({ clients = {}, started = false, next_id = 0 })
local function obj(value)
  return type(value) == "table" and value or {}
end
local function str(value)
  return type(value) == "string" and value or ""
end
local function uid()
  local b = { string.byte(vim.uv.random(16), 1, 16) }
  b[7], b[9] = bit.bor(bit.band(b[7], 15), 64), bit.bor(bit.band(b[9], 63), 128)
  local s = {}
  for i, n in ipairs(b) do
    s[i] = string.format("%02x", n)
  end
  return table.concat(s, "", 1, 4)
    .. "-"
    .. table.concat(s, "", 5, 6)
    .. "-"
    .. table.concat(s, "", 7, 8)
    .. "-"
    .. table.concat(s, "", 9, 10)
    .. "-"
    .. table.concat(s, "", 11, 16)
end
local function emit(client, method, params)
  params.threadId = client.id
  local handler = require("coact.rpc").handlers.notification
  if handler then
    handler({ method = method, params = params })
  end
end
local function send(client, message)
  if not client.job then
    return false, "Claude process is not running"
  end
  local ok, result = pcall(vim.fn.chansend, client.job, vim.json.encode(message) .. "\n")
  return ok and result > 0, ok and "Claude stdin is closed" or tostring(result)
end
local function finish(client, status, error_message)
  local turn = client.turn
  if not turn then
    return
  end
  turn.status = status
  turn.error = error_message and { message = error_message } or nil
  client.turn, client.compacting = nil, false
  emit(client, "turn/completed", { turn = vim.deepcopy(turn) })
  runtime.schedule(function()
    if client.job and client.initialized and not client.turn and not client.interrupting and not client.closing then
      local entry = table.remove(client.queue or {}, 1)
      if entry then
        start_entry(client, entry)
      end
    end
  end)
end
local function cancel_queue(client, status, reason)
  local queue = client.queue or {}
  client.queue = {}
  for _, entry in ipairs(queue) do
    entry.turn.status = status
    entry.turn.error = reason and { message = reason } or nil
    emit(client, "turn/completed", { turn = entry.turn })
  end
end
local function close(client, reason)
  local job = client.job
  client.job, client.initialized, client.closing = nil, false, true
  cancel_queue(client, "failed", reason)
  -- Patch reviews are cancelled by the same keyboard-independent session API.
  if client.review then
    require("coact.patch_session").cancel(client.review)
    client.review = nil
  end
  local pending = client.pending
  client.pending = {}
  for _, entry in pairs(pending) do
    entry.callback({ message = reason }, nil)
  end
  finish(client, "failed", reason)
  if job then
    pcall(vim.fn.jobstop, job)
  end
end
local function control(client, request, callback)
  M.next_id = M.next_id + 1
  local id = "coact-" .. M.next_id
  local entry = { callback = callback or function() end }
  client.pending[id] = entry
  local ok, err = send(client, { type = "control_request", request_id = id, request = request })
  if not ok then
    client.pending[id] = nil
    entry.callback({ message = err })
    return
  end
  runtime.defer(function()
    if client.pending[id] == entry then
      client.pending[id] = nil
      entry.callback({ message = "Claude control request timed out: " .. request.subtype })
      close(client, "Claude control request timed out")
    end
  end, provider.options().initialize_timeout_ms or 30000)
end
local function item_event(client, item, completed)
  if not client.turn then
    return
  end
  local found = false
  for i, existing in ipairs(client.turn.items) do
    if existing.id == item.id then
      client.turn.items[i], found = item, true
      break
    end
  end
  if not found then
    table.insert(client.turn.items, item)
  end
  emit(client, completed and "item/completed" or "item/started", { turnId = client.turn.id, item = vim.deepcopy(item) })
end
local function block_item(client, block, index, message_id)
  local id = message_id .. ":" .. index
  if block.type == "text" then
    return { id = id, type = "agentMessage", text = str(block.text) }
  elseif block.type == "thinking" then
    return { id = id, type = "reasoning", content = { str(block.thinking) }, summary = {} }
  elseif block.type == "tool_use" and str(block.id) ~= "" then
    return {
      id = block.id,
      type = "dynamicToolCall",
      tool = str(block.name),
      arguments = obj(block.input),
      status = "inProgress",
      contentItems = {},
    }
  end
end
local function stream(client, event)
  if event.type == "message_start" then
    client.message_id = str(obj(event.message).id)
    if client.message_id == "" then
      client.message_id = uid()
    end
    client.blocks = {}
  elseif event.type == "content_block_start" then
    local item = block_item(client, obj(event.content_block), tonumber(event.index) or 0, client.message_id or uid())
    client.blocks[event.index or 0] = item
    if item then
      item_event(client, item, false)
    end
  elseif event.type == "content_block_delta" then
    local item = client.blocks[event.index or 0]
    local delta = obj(event.delta)
    if not item or not client.turn then
      return
    end
    local method, value
    if delta.type == "text_delta" then
      value, method = str(delta.text), "item/agentMessage/delta"
      item.text = str(item.text) .. value
    elseif delta.type == "thinking_delta" then
      value, method = str(delta.thinking), "item/reasoning/textDelta"
      item.content[1] = item.content[1] .. value
    elseif delta.type == "input_json_delta" then
      item.partial_json = (item.partial_json or "") .. str(delta.partial_json)
    end
    if method and value ~= "" then
      emit(client, method, { turnId = client.turn.id, itemId = item.id, delta = value, contentIndex = 0 })
    end
  elseif event.type == "content_block_stop" then
    local item = client.blocks[event.index or 0]
    if item then
      if item.partial_json then
        local ok, args = pcall(vim.json.decode, item.partial_json)
        if ok then
          item.arguments = obj(args)
        end
        item.partial_json = nil
      end
      item_event(client, item, item.type ~= "dynamicToolCall")
    end
  end
end

function M._dispatch(client, message)
  if type(message) ~= "table" then
    return
  end
  if message.type == "control_response" then
    local response = obj(message.response)
    local id = str(response.request_id)
    local entry = client.pending[id]
    client.pending[id] = nil
    if entry then
      entry.callback(response.subtype == "error" and { message = str(response.error) } or nil, obj(response.response))
    end
  elseif message.type == "control_request" then
    local request = obj(message.request)
    local request_id = str(message.request_id)
    local function reply(result, err)
      if client.cancelled[request_id] or not client.job then
        return
      end
      send(client, {
        type = "control_response",
        response = { subtype = err and "error" or "success", request_id = request_id, response = result, error = err },
      })
    end
    if request.subtype == "mcp_message" and request.server_name == "coact" then
      local previous_review = client.review
      local ok, err = pcall(require("coact.providers.claude_mcp").handle, client, obj(request.message), function(result)
        reply({ mcp_response = result })
      end)
      if client.review and client.review ~= previous_review then
        client.review_request_id = request_id
      end
      if not ok then
        reply(nil, tostring(err))
      end
    elseif request.subtype == "can_use_tool" then
      local name = str(request.tool_name)
      if
        name:match("^mcp__coact__")
        or name == "Bash"
        or name == "Skill"
        or name == "Read"
        or name == "Glob"
        or name == "Grep"
        or config.edit_mode() == "yolo"
      then
        reply({ behavior = "allow", updatedInput = obj(request.input) })
      else
        reply({
          behavior = "deny",
          message = "Use mcp__coact__edit or mcp__coact__openDiff for reviewed edits.",
        })
      end
    else
      reply(nil, "Unsupported Claude control request: " .. str(request.subtype))
    end
  elseif message.type == "control_cancel_request" then
    client.cancelled[str(message.request_id)] = true
    if client.review and client.review_request_id == message.request_id then
      require("coact.patch_session").cancel(client.review)
      client.review = nil
    end
  elseif message.type == "system" then
    -- Init/status/task messages are cache-only, never transcript prose.
    if message.subtype == "init" then
      -- Preserve a selected alias (e.g. sonnet); init reports its resolved id.
      client.model = client.model or (type(message.model) == "string" and message.model or nil)
      client.metadata = message
      emit(client, "thread/started", { thread = { id = client.id, cwd = client.cwd, model = client.model } })
    elseif message.subtype == "status" and message.status == "compacting" then
      emit(client, "thread/compaction/started", {})
    elseif message.subtype == "compact_boundary" then
      client.compact_metadata = obj(message.compact_metadata)
      emit(client, "thread/compacted", { turnId = client.turn and client.turn.id, metadata = client.compact_metadata })
    end
  elseif message.parent_tool_use_id ~= nil and message.parent_tool_use_id ~= vim.NIL then
    -- Subagent output is already represented by its parent tool result.
    return
  elseif message.type == "stream_event" then
    stream(client, obj(message.event))
  elseif message.type == "assistant" and client.turn then
    local msg = obj(message.message)
    local id = str(msg.id)
    if id == "" then
      id = client.message_id or uid()
    end
    for index, block in ipairs(obj(msg.content)) do
      block = obj(block)
      local item = block_item(client, block, index - 1, str(message.uuid) ~= "" and message.uuid or id)
      -- Claude emits singleton final blocks with the same message id. Match
      -- them to their streamed block indices instead of overwriting index 0.
      if item and client.message_id == id then
        for _, streamed in pairs(client.blocks) do
          if
            not streamed.final_uuid
            and streamed.type == item.type
            and (item.type ~= "agentMessage" or streamed.text == item.text)
            and (item.type ~= "dynamicToolCall" or streamed.id == item.id)
          then
            item.id = streamed.id
            streamed.final_uuid = message.uuid or true
            break
          end
        end
      end
      if item then
        item.treeEntryId = type(message.uuid) == "string" and message.uuid or nil
        item_event(client, item, item.type ~= "dynamicToolCall")
      end
    end
  elseif message.type == "user" and client.turn then
    if type(message.uuid) == "string" and message.uuid == client.turn.user_uuid then
      local user = client.turn.items[1]
      user.treeEntryId = message.uuid
      item_event(client, user, true)
    end
    for _, block in ipairs(obj(obj(message.message).content)) do
      if block.type == "tool_result" then
        for _, item in ipairs(client.turn.items) do
          if item.id == block.tool_use_id then
            item.status = block.is_error == true and "failed" or "completed"
            item.success = block.is_error ~= true
            item.contentItems = {
              {
                type = "inputText",
                text = type(block.content) == "string" and block.content or vim.json.encode(obj(block.content)),
              },
            }
            item_event(client, item, true)
            break
          end
        end
      end
    end
  elseif message.type == "result" then
    client.usage = obj(message.usage)
    local function number(value)
      return type(value) == "number" and value or nil
    end
    emit(client, "thread/tokenUsage/updated", {
      tokenUsage = {
        input = number(client.usage.input_tokens),
        output = number(client.usage.output_tokens),
        cacheRead = number(client.usage.cache_read_input_tokens),
        cacheWrite = number(client.usage.cache_creation_input_tokens),
        cost = number(message.total_cost_usd),
      },
    })
    local failed = message.is_error == true or (str(message.subtype) ~= "" and message.subtype ~= "success")
    local err = failed and (str(message.result) ~= "" and message.result or table.concat(obj(message.errors), "\n"))
      or nil
    finish(client, client.interrupting and "interrupted" or (failed and "failed" or "completed"), err)
    client.interrupting = false
  end
end

local function feed(client, data)
  if not data then
    return
  end
  for index, chunk in ipairs(data) do
    if index == 1 then
      chunk = client.tail .. chunk
      client.tail = ""
    end
    if #chunk > (provider.options().max_message_bytes or 8 * 1024 * 1024) then
      close(client, "Claude protocol frame exceeds size limit")
      return
    end
    if index == #data then
      client.tail = chunk
    elseif chunk ~= "" then
      local ok, message = pcall(vim.json.decode, chunk)
      if not ok then
        close(client, "Invalid JSON from Claude stdout")
        return
      end
      local handled = pcall(M._dispatch, client, message)
      if not handled then
        close(client, "Invalid Claude protocol message")
        return
      end
    end
  end
end

function M.start(callback)
  if vim.fn.executable(provider.executable()) ~= 1 then
    if callback then
      callback({ message = "Claude Code executable not found: " .. provider.executable() })
    end
    return
  end
  M.started = true
  if callback then
    callback(nil, true)
  end
end
function M.is_running(id)
  return id and M.clients[id] ~= nil and M.clients[id].job ~= nil or (not id and M.started)
end
function M.is_initialized(id)
  return id and M.clients[id] ~= nil and M.clients[id].initialized == true or (not id and M.started)
end
function M.client_count()
  local n = 0
  for _, c in pairs(M.clients) do
    if c.job then
      n = n + 1
    end
  end
  return n
end
function M.pending_count(id)
  local n = 0
  for key, c in pairs(M.clients) do
    if not id or id == key then
      for _ in pairs(c.pending) do
        n = n + 1
      end
      n = n + #(c.queue or {})
    end
  end
  return n
end
function M.stop()
  M.started = false
  for _, client in pairs(M.clients) do
    close(client, "Claude transport stopped")
  end
  M.clients = {}
end
function M.prewarm(callback)
  if callback then
    callback(nil, false)
  end
end
function M.notify()
  return false
end
function M.send()
  error("Claude messages must be scoped to a thread")
end

local function payload(client)
  if client.seed and not client.hydrated then
    return history.thread(client.seed, client.id)
  end
  local thread = require("coact.state").get_thread(client.id)
  local turns = {}
  if thread then
    for _, id in ipairs(thread.turn_order) do
      table.insert(turns, vim.deepcopy(thread.turns[id]))
    end
  end
  return { id = client.id, cwd = client.cwd, model = client.model, name = "Claude Code session", turns = turns }
end
local function launch(params, callback)
  local session = params.sessionId or uid()
  local client = {
    id = "claude:" .. session,
    cwd = params.cwd or config.cwd(),
    pending = {},
    cancelled = {},
    blocks = {},
    tail = "",
    model = params.model or provider.options().model,
    seed = params.seed,
    queue = {},
  }
  local instructions = str(params.developerInstructions)
  local cmd = provider.command(nil, {
    session_id = session,
    resume = params.resume,
    fork = params.fork,
    resume_at = params.resume_at,
    model = client.model,
    instructions = instructions ~= "" and instructions or nil,
  })
  if str(params.baseInstructions) ~= "" then
    vim.list_extend(cmd, { "--system-prompt", params.baseInstructions })
  end
  local env = vim.fn.environ()
  for key in pairs(env) do
    if key:match("^MallocStackLogging") or key == "CLAUDECODE" or key == "NVIM" or key == "NVIM_LISTEN_ADDRESS" then
      env[key] = nil
    end
  end
  for key, value in pairs(provider.options().env or {}) do
    env[key] = value
  end
  env.CLAUDE_CODE_ENTRYPOINT = "sdk-cli"
  env.CLAUDE_CONFIG_DIR = history.config_dir()
  client.job = runtime.jobstart(cmd, {
    cwd = client.cwd,
    env = env,
    clear_env = true,
    stdin = "pipe",
    on_stdout = function(_, data)
      runtime.schedule(function()
        if client.job then
          feed(client, data)
        end
      end)
    end,
    -- Never put raw stderr/environment (which can contain credentials) in chat.
    on_stderr = function(_, data)
      client.stderr_seen = client.stderr_seen or #table.concat(data, "") > 0
    end,
    on_exit = function(_, code)
      runtime.schedule(function()
        if client.job then
          if client.tail ~= "" then
            feed(client, { "", "" })
          end
          close(client, "Claude process exited (" .. code .. ")")
        end
      end)
    end,
  })
  M.clients[client.id] = client
  if client.job <= 0 then
    client.job = nil
    M.clients[client.id] = nil
    callback({ message = "Could not start Claude Code" })
    return
  end
  control(client, { subtype = "initialize" }, function(err, result)
    if err then
      close(client, "Claude initialization failed")
      M.clients[client.id] = nil
      callback(err)
      return
    end
    client.initialized, client.init = true, result
    local restored = payload(client)
    client.hydrated = true
    callback(nil, { thread = restored })
  end)
end

start_entry = function(client, entry, callback)
  client.turn = entry.turn
  client.blocks, client.message_id = {}, nil
  local ok, err = send(client, {
    type = "user",
    uuid = entry.turn.user_uuid,
    session_id = "",
    message = { role = "user", content = entry.content },
    parent_tool_use_id = vim.NIL,
  })
  if not ok then
    if callback then
      client.turn = nil
      callback({ message = err })
    else
      finish(client, "failed", err)
    end
    return
  end
  if callback then
    callback(nil, { turn = vim.deepcopy(client.turn) })
  end
  emit(client, "turn/started", { turn = vim.deepcopy(client.turn) })
end

local function restore(thread_id, callback)
  local existing = M.clients[thread_id]
  if existing and existing.job then
    if existing.initialized then
      callback(nil, { thread = payload(existing) })
    else
      callback({ message = "Claude session is already opening" })
    end
    return
  end
  local snap, err = history.read(thread_id)
  if not snap then
    callback({ message = err })
    return
  end
  local params = { sessionId = snap.session_id, cwd = snap.cwd, model = snap.model, seed = snap }
  if snap.pending_fork then
    if snap.branch.at then
      params.resume, params.fork, params.resume_at =
        history.native_source(snap.branch.parent, snap.branch.at), true, snap.branch.at
      if not params.resume then
        callback({ message = "Rewind source is missing or its checkpoint is no longer resumable after compaction" })
        return
      end
    end
  else
    params.resume = snap.session_id
  end
  launch(params, callback)
end

function M.snapshot(thread_id)
  return history.read(thread_id)
end

function M.rewind(thread_id, selected_id, callback, source_id)
  local client = M.clients[thread_id]
  if client and (client.turn or client.setting_model or client.rewinding or #(client.queue or {}) > 0) then
    callback({ message = "Stop generation and queued follow-ups before rewinding" })
    return
  end
  local snap, err = history.read(source_id or thread_id)
  if not snap then
    callback({ message = err })
    return
  end
  local checkpoint
  checkpoint, err = history.checkpoint(snap, selected_id)
  if not checkpoint then
    callback({ message = err })
    return
  end
  local native_source = checkpoint.at and history.native_source(snap.session_id, checkpoint.at) or nil
  if checkpoint.at and not native_source then
    callback({ message = "Claude cannot resume this pre-compaction checkpoint and no resumable ancestor remains" })
    return
  end
  local session = uid()
  local seed = vim.deepcopy(snap)
  seed.chain = checkpoint.chain
  seed.id, seed.session_id, seed.leaf = "claude:" .. session, session, checkpoint.at
  seed.branch = {
    parent = snap.session_id,
    root = snap.branch and snap.branch.root or snap.session_id,
    at = checkpoint.at or false,
  }
  seed.records, seed.by_id = vim.deepcopy(checkpoint.chain), {}
  for _, e in ipairs(seed.records) do
    seed.by_id[e.uuid] = e
  end
  if client then
    client.rewinding = true
  end
  local launched, launch_error = pcall(launch, {
    sessionId = session,
    cwd = snap.cwd,
    model = client and client.model or snap.model,
    seed = seed,
    resume = native_source,
    fork = checkpoint.at ~= nil,
    resume_at = checkpoint.at,
  }, function(launch_err, result)
    if client then
      client.rewinding = false
    end
    if launch_err then
      callback(launch_err)
      return
    end
    local ok, save_err = pcall(history.save_branch, session, snap.session_id, checkpoint.at)
    if not ok then
      close(M.clients[seed.id], "Could not save rewind branch")
      M.clients[seed.id] = nil
      callback({ message = tostring(save_err) })
      return
    end
    result.draftText = checkpoint.draft
    result.treeAction = { __coactTreeAction = true, action = "rewind", id = selected_id }
    callback(nil, result)
  end)
  if not launched then
    if client then
      client.rewinding = false
    end
    callback({ message = tostring(launch_error) })
  end
end

function M.catalog_client(thread_id)
  local id = thread_id or require("coact.state").active_thread_id
  local client = id and M.clients[id]
  return client and client.initialized and client.job and client or nil
end

function M.request(method, params, callback)
  callback = callback or function() end
  params = obj(params)
  if method == "thread/start" then
    local ok, err = pcall(launch, params, callback)
    if not ok then
      callback({ message = tostring(err) })
    end
    return
  elseif method == "thread/list" then
    local data = history.list(params.cwd)
    local seen = {}
    for _, t in ipairs(data) do
      seen[t.id] = true
    end
    for _, client in pairs(M.clients) do
      if client.job and not seen[client.id] and (not params.cwd or client.cwd == params.cwd) then
        table.insert(data, payload(client))
      end
    end
    callback(nil, { data = data })
    return
  elseif method == "thread/read" or method == "thread/resume" then
    local ok, err = pcall(restore, params.threadId, callback)
    if not ok then
      callback({ message = tostring(err) })
    end
    return
  elseif method == "thread/tree" then
    require("coact.providers.claude_tree").open(params, callback)
    return
  elseif method == "thread/rewind" then
    M.rewind(params.threadId, params.entryId, callback)
    return
  end
  if method == "model/list" or method == "skills/list" then
    local client = M.catalog_client(params.threadId)
    if not client then
      callback({ message = "Open a Claude thread before requesting its catalog" })
      return
    end
    if method == "model/list" then
      callback(nil, { data = catalog.models(client) })
    else
      callback(nil, { data = { { cwd = client.cwd, skills = catalog.skills(client) } } })
    end
    return
  end
  local client = M.clients[params.threadId]
  if not client or not client.initialized or not client.job then
    callback({ message = "Claude thread is not running; create a new thread" })
    return
  end
  if method == "thread/read" or method == "thread/resume" then
    callback(nil, { thread = payload(client) })
  elseif method == "thread/settings/update" then
    if client.turn or client.setting_model or client.rewinding or #(client.queue or {}) > 0 then
      callback({ message = "Wait for the Claude thread to become idle before changing model" })
      return
    end
    for key, value in pairs(params) do
      if key ~= "threadId" and key ~= "model" and value ~= nil and value ~= vim.NIL then
        callback({ message = "Unsupported Claude setting: " .. key })
        return
      end
    end
    local model = params.model == vim.NIL and "default" or str(params.model)
    if model == "" then
      callback({ message = "A model is required" })
      return
    end
    client.setting_model = true
    control(client, { subtype = "set_model", model = model }, function(err, result)
      client.setting_model = false
      if not err then
        client.model = model
        emit(client, "thread/settings/updated", { settings = { model = model } })
      end
      callback(err, result)
    end)
  elseif method == "thread/compact/start" then
    if client.turn or client.setting_model or client.rewinding or #(client.queue or {}) > 0 then
      callback({ message = "Wait for the Claude thread to become idle before compacting" })
      return
    end
    client.turn = { id = "claude-compact-" .. uid(), status = "inProgress", items = {} }
    client.compacting = true
    local ok, err = send(client, {
      type = "user",
      session_id = "",
      message = { role = "user", content = "/compact" },
      parent_tool_use_id = vim.NIL,
    })
    if not ok then
      client.turn, client.compacting = nil, false
      callback({ message = err })
      return
    end
    emit(client, "turn/started", { turn = vim.deepcopy(client.turn) })
    emit(client, "thread/compaction/started", {})
    callback(nil, {})
  elseif method == "turn/start" then
    if client.setting_model or client.compacting or client.rewinding then
      callback({ message = "Claude thread is compacting, changing model, or rewinding" })
      return
    end
    if params.streamingBehavior == "steer" then
      callback({ message = "Claude supports queued followUp, not immediate steering" })
      return
    end
    local content, input_err = catalog.prompt(client, params.input)
    if not content then
      callback({ message = input_err })
      return
    end
    if params.model and params.model ~= client.model then
      callback({ message = "Use /model to change this Claude thread's model before submitting" })
      return
    end
    local user_uuid = uid()
    local entry = {
      content = content,
      turn = {
        id = "claude-turn-" .. uid(),
        user_uuid = user_uuid,
        status = "inProgress",
        items = {
          { id = user_uuid, treeEntryId = user_uuid, type = "userMessage", content = vim.deepcopy(params.input) },
        },
      },
    }
    if client.turn or #(client.queue or {}) > 0 then
      if #(client.queue or {}) >= (provider.options().max_queued_prompts or 20) then
        callback({ message = "Claude follow-up queue is full" })
        return
      end
      table.insert(client.queue, entry)
      callback(nil, { queued = true, streamingBehavior = "followUp", turn = { id = entry.turn.id, items = {} } })
    else
      start_entry(client, entry, callback)
    end
  elseif method == "turn/interrupt" then
    if params.turnId and client.turn and params.turnId ~= client.turn.id then
      callback({ message = "Claude interrupt refers to a stale turn" })
      return
    end
    cancel_queue(client, "interrupted", "Queued follow-up cancelled")
    if not client.turn then
      callback(nil, {})
      return
    end
    if params.turnId and params.turnId ~= client.turn.id then
      callback({ message = "Claude interrupt refers to a stale turn" })
      return
    end
    client.interrupting = true
    if client.review then
      require("coact.patch_session").cancel(client.review)
      client.review = nil
    end
    control(client, { subtype = "interrupt" }, callback)
  else
    callback({ code = -32601, message = "Unsupported Claude operation: " .. method })
  end
end
M.request_raw = M.request
M._feed = feed
return M
