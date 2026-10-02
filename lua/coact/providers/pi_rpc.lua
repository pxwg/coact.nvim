local config = require("coact.config")
local provider = require("coact.providers.pi")
local util = require("coact.util")

local runtime_scope = require("coact.runtime")
local M = runtime_scope.state({
  clients = {},
  by_thread = {},
  starting = {},
  utility = nil,
  prewarm_generation = 0,
})
local next_client_id = 1

local Client = {}
Client.__index = Client

local function encode(value)
  return vim.json.encode(value)
end

local function decode(line)
  return vim.json.decode(line)
end

local function schedule(callback)
  runtime_scope.schedule(callback)
end

local function expected_exit(code, stopping)
  return stopping or code == 0 or code == 15 or code == 143
end

local function expected_send_failure(err)
  return tostring(err or ""):match("closed stream") ~= nil
end

local function app_server_env()
  local env = vim.fn.environ()
  for key in pairs(env) do
    if key:match("^MallocStackLogging") then
      env[key] = nil
    end
  end
  return env
end

local function env_empty(env)
  for _ in pairs(env or {}) do
    return false
  end
  return true
end

local function sanitize_malloc_env_enabled(opts)
  return not (opts.adapter and opts.adapter.sanitize_malloc_env == false)
end

local function invoke(client, callback, ...)
  if type(callback) ~= "function" then
    return nil
  end
  return provider.with_runtime(client.runtime, callback, ...)
end

local function client_api(client)
  client._request_message = function(first, ...)
    if first == client then
      return Client._request_message(client, ...)
    end
    return Client._request_message(client, first, ...)
  end
  client.request = function(first, ...)
    if first == client then
      return Client.request(client, ...)
    end
    return Client.request(client, first, ...)
  end
  client.notify = function(first, ...)
    if first == client then
      return Client.notify(client, ...)
    end
    return Client.notify(client, first, ...)
  end
  client.send = function(first, ...)
    if first == client then
      return Client.send(client, ...)
    end
    return Client.send(client, first, ...)
  end
  client.respond = function(first, ...)
    local id, result
    if first == client then
      id, result = ...
    else
      id, result = first, ...
    end
    return Client.send(client, { id = id, result = result or vim.empty_dict() })
  end
  client.respond_error = function(first, ...)
    local id, message, code, data
    if first == client then
      id, message, code, data = ...
    else
      id, message, code, data = first, ...
    end
    return Client.send(client, {
      id = id,
      error = {
        code = code or -32603,
        message = message,
        data = data,
      },
    })
  end
  client.is_running = function()
    return Client.is_running(client)
  end
  return client
end

local function new_client(launch)
  local id = ("pi-client-%d"):format(next_client_id)
  next_client_id = next_client_id + 1
  local runtime = provider.new_runtime()
  runtime.adapter_context = config.context()
  runtime.client_id = id
  runtime.suppress_state_updates = true
  local client = client_api(setmetatable({
    id = id,
    runtime = runtime,
    launch = launch or {},
    speculative = launch and launch.speculative == true or false,
    thread_id = nil,
    job_id = nil,
    next_id = 1,
    pending = {},
    stdout_tail = "",
    stderr_tail = "",
    initialized = false,
    starting = false,
    stopping = false,
    start_callbacks = {},
  }, Client))
  M.clients[id] = client
  return client
end

local function current_thread_id()
  local ok, state = pcall(require, "coact.state")
  if not ok then
    return nil
  end
  local thread = state.thread_for_buf(0)
  return thread and thread.id or state.active_thread_id
end

local function handlers()
  local ok, rpc = pcall(require, "coact.rpc")
  return ok and rpc.handlers or {}
end

local function current_owner(client)
  return not client.thread_id or M.by_thread[client.thread_id] == client
end

local function force_thread_id(entry, thread_id)
  if type(entry) ~= "table" or not thread_id then
    return entry
  end
  local message = entry.message
  if type(message) ~= "table" then
    return entry
  end
  message.params = type(message.params) == "table" and message.params or {}
  message.params.threadId = thread_id
  return entry
end

local function dispatch_decoded(client, entry)
  if not client.thread_id then
    return
  end
  entry = force_thread_id(entry, client.thread_id)
  if type(entry) ~= "table" then
    return
  end
  local current_handlers = handlers()
  if entry.kind == "server_request" and current_handlers.server_request then
    schedule(function()
      if current_owner(client) then
        invoke(client, current_handlers.server_request, entry.message)
      end
    end)
  elseif entry.kind == "notification" and current_handlers.notification then
    schedule(function()
      if current_owner(client) then
        invoke(client, current_handlers.notification, entry.message)
      end
    end)
  end
end

local function dispatch(client, message)
  if type(message) ~= "table" or not current_owner(client) then
    return
  end
  if client.speculative and message.type == "extension_ui_request" then
    if message.id ~= nil then
      pcall(client.send, client, {
        type = "extension_ui_response",
        id = message.id,
        cancelled = true,
      })
    end
    return
  end
  if type(provider.handle_raw_message) == "function" then
    local handled = provider.with_runtime(client.runtime, provider.handle_raw_message, message, client)
    if handled then
      return
    end
  end

  local response = type(provider.decode_response) == "function"
      and provider.with_runtime(client.runtime, provider.decode_response, message)
    or nil
  if response then
    local key = tostring(response.id)
    local pending = client.pending[key]
    client.pending[key] = nil
    if pending then
      schedule(function()
        if current_owner(client) then
          invoke(client, pending.callback, response.error, response.result)
        else
          invoke(client, pending.callback, { message = "discarded response from a stale Pi execution unit" }, nil)
        end
      end)
    end
    return
  end

  local decoded = type(provider.decode_notification) == "function"
      and provider.with_runtime(client.runtime, provider.decode_notification, message)
    or nil
  if decoded then
    if vim.islist(decoded) then
      for _, entry in ipairs(decoded) do
        dispatch_decoded(client, entry)
      end
    else
      dispatch_decoded(client, decoded)
    end
  end
end

local function handle_line(client, line)
  if line == nil or line == "" then
    return
  end
  local ok, message = pcall(decode, line)
  if not ok then
    util.notify("failed to decode Pi provider message: " .. tostring(message), vim.log.levels.ERROR)
    return
  end
  dispatch(client, message)
end

local function feed_stdout(client, data)
  if not data then
    return
  end
  for index, chunk in ipairs(data) do
    if index == 1 then
      chunk = client.stdout_tail .. chunk
      client.stdout_tail = ""
    end
    if index < #data then
      handle_line(client, chunk)
    else
      client.stdout_tail = chunk
    end
  end
end

local function feed_stderr(client, data)
  if not data then
    return
  end
  local text = table.concat(data, "\n")
  if client.launch and client.launch.session_id then
    text = text:gsub("Warning: No project session found with id '[^']+'; creating a new session with that id%.?\n?", "")
  end
  if text == "" then
    return
  end
  client.stderr_tail = text
  if client.speculative then
    return
  end
  local stderr_handler = handlers().stderr
  if stderr_handler then
    schedule(function()
      invoke(client, stderr_handler, text)
    end)
  end
end

local function render_disconnected_thread(client, code, expected)
  if not client.thread_id then
    return
  end
  local ok, state = pcall(require, "coact.state")
  if not ok then
    return
  end
  local thread = state.get_thread(client.thread_id)
  if not thread then
    return
  end
  thread.provider_client_id = nil
  thread.active_turn_id = nil
  thread.pi_agent_active = false
  thread.lifecycle = "disconnected"
  thread.generation = "idle"
  thread.status_message = nil
  if not expected then
    thread.last_error = "Pi provider exited with code " .. tostring(code)
  end
  local buffers_ok, buffers = pcall(require, "coact.buffers")
  if buffers_ok and thread.bufnr then
    buffers.schedule_render(thread.id)
  end
end

local function remove_client(client)
  if M.clients[client.id] == client then
    M.clients[client.id] = nil
  end
  if client.thread_id and M.by_thread[client.thread_id] == client then
    M.by_thread[client.thread_id] = nil
  end
  if M.utility == client then
    M.utility = nil
  end
end

local function flush_start_callbacks(client, err, result)
  local callbacks = client.start_callbacks
  client.start_callbacks = {}
  for _, callback in ipairs(callbacks) do
    invoke(client, callback, err, result)
  end
end

function Client:is_running()
  return self.job_id ~= nil and self.job_id > 0
end

function Client:start(callback)
  callback = callback or function() end
  if self.initialized and self:is_running() then
    invoke(self, callback, nil, true)
    return
  end
  table.insert(self.start_callbacks, callback)
  if self.starting then
    return
  end
  self.starting = true
  self.stdout_tail = ""
  self.stderr_tail = ""
  self.stopping = false

  local opts = config.get()
  local command = provider.command(opts, self.launch)
  local env = sanitize_malloc_env_enabled(opts) and app_server_env() or {}
  env.COACT_NVIM_PI_CLIENT_ID = self.id
  if type(provider.env) == "function" then
    env = provider.env(opts, env) or env
    env.COACT_NVIM_PI_CLIENT_ID = self.id
  end
  local prepare_err
  if type(provider.prepare_command) == "function" then
    command, env, prepare_err = provider.prepare_command(command, env, {
      client_id = self.id,
      session_id = self.launch.session_id,
      session_file = self.launch.session_file,
      speculative = self.speculative,
    })
    if not command then
      self.starting = false
      remove_client(self)
      flush_start_callbacks(self, { message = prepare_err }, nil)
      return
    end
  end

  local job_opts = {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      feed_stdout(self, data)
    end,
    on_stderr = function(_, data)
      feed_stderr(self, data)
    end,
    on_exit = function(_, code)
      local pending = self.pending
      self.pending = {}
      self.job_id = nil
      self.initialized = false
      self.starting = false
      local stopping = self.stopping
      self.stopping = false
      local expected = expected_exit(code, stopping)
      remove_client(self)
      schedule(function()
        invoke(self, function()
          if not expected then
            for _, entry in pairs(pending) do
              entry.callback({ code = code, message = "Pi provider exited" }, nil)
            end
            if not self.speculative then
              util.notify("Pi provider exited with code " .. tostring(code), vim.log.levels.ERROR)
            end
          end
          if #self.start_callbacks > 0 then
            flush_start_callbacks(self, { code = code, message = "Pi provider exited during initialization" }, nil)
          end
          render_disconnected_thread(self, code, expected)
        end)
      end)
    end,
  }

  if sanitize_malloc_env_enabled(opts) then
    job_opts.clear_env = true
    job_opts.env = env
  elseif not env_empty(env) then
    job_opts.env = env
  end

  self.job_id = runtime_scope.jobstart(command, job_opts)
  if self.job_id <= 0 then
    self.job_id = nil
    self.starting = false
    remove_client(self)
    flush_start_callbacks(self, { message = "failed to start Pi provider" }, nil)
    return
  end

  provider.with_runtime(self.runtime, provider.initialize, self, function(err, result)
    if err then
      self.starting = false
      flush_start_callbacks(self, err, nil)
      self:stop()
      return
    end
    if self.stopping or not self:is_running() then
      return
    end
    self.starting = false
    self.initialized = true
    flush_start_callbacks(self, nil, result or true)
  end)
end

function Client:stop()
  if self:is_running() then
    self.stopping = true
    vim.fn.jobstop(self.job_id)
  end
  self.job_id = nil
  self.initialized = false
  self.starting = false
  self.pending = {}
  remove_client(self)
end

function Client:send(message)
  if not self:is_running() then
    error("Pi provider is not running for " .. tostring(self.thread_id or self.id))
  end
  vim.fn.chansend(self.job_id, encode(message) .. "\n")
end

local function wire_params(params)
  local normalized = type(params) == "table" and vim.deepcopy(params) or params
  if type(normalized) == "table" then
    normalized.threadId = nil
    normalized.thread_id = nil
    normalized.conversationId = nil
    normalized._coactClientBound = nil
  end
  return normalized
end

function Client:_request_message(method, params, callback)
  callback = callback or function() end
  local id = self.next_id
  self.next_id = self.next_id + 1
  self.pending[tostring(id)] = {
    method = method,
    callback = callback,
  }
  local message = provider.with_runtime(self.runtime, provider.request_message, method, wire_params(params), id)
  local ok, err = pcall(self.send, message)
  if not ok then
    self.pending[tostring(id)] = nil
    invoke(self, callback, { message = err }, nil)
  end
  return id
end

function Client:request(method, params, callback)
  return provider.with_runtime(self.runtime, function()
    if type(provider.custom_request) == "function" then
      local handled, id = provider.custom_request(self, method, params, callback or function() end)
      if handled then
        return id
      end
    end
    return self._request_message(method, params, callback)
  end)
end

function Client:notify(method, params)
  if self.stopping or not self:is_running() then
    return false
  end
  local message = provider.with_runtime(self.runtime, provider.notify_message, method, wire_params(params))
  local ok, err = pcall(self.send, message)
  if not ok and not self.stopping and not expected_send_failure(err) then
    util.notify("Pi provider notify failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function bind_client(client, thread_id)
  thread_id = util.value(thread_id)
  if type(thread_id) ~= "string" or thread_id == "" then
    return nil, { message = "Pi provider returned a missing thread id" }
  end
  local existing = M.by_thread[thread_id]
  if existing and existing ~= client and existing:is_running() then
    return nil, { message = "Pi thread already owns another running execution unit: " .. thread_id }
  end
  if client.thread_id and client.thread_id ~= thread_id and M.by_thread[client.thread_id] == client then
    M.by_thread[client.thread_id] = nil
  end
  client.thread_id = thread_id
  client.speculative = false
  client.runtime.bound_thread_id = thread_id
  client.runtime.current_thread_id = thread_id
  client.runtime.suppress_state_updates = false
  M.by_thread[thread_id] = client
  if M.utility == client then
    M.utility = nil
  end
  local ok, state = pcall(require, "coact.state")
  if ok then
    local thread = state.get_thread(thread_id)
    if thread then
      thread.provider_client_id = client.id
      thread.lifecycle = "ready"
      thread.last_error = nil
    end
  end
  return client
end

local function any_running_client()
  local target = current_thread_id()
  local active = target and M.by_thread[target] or nil
  if active and active.initialized and active:is_running() then
    return active
  end
  if M.utility and M.utility.initialized and M.utility:is_running() then
    return M.utility
  end
  for _, client in pairs(M.clients) do
    if client.initialized and client:is_running() then
      return client
    end
  end
  return nil
end

local function start_new_client(callback, launch)
  local client = new_client(launch)
  client:start(function(err)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, client)
  end)
  return client
end

local function acquire_unbound_client(callback)
  local utility = M.utility
  if utility and not utility.thread_id and (utility.starting or utility:is_running()) then
    M.utility = nil
    M.prewarm_generation = M.prewarm_generation + 1
    utility.speculative = false
    utility:start(function(err)
      callback(err, err and nil or utility)
    end)
    return utility
  end
  return start_new_client(callback)
end

local function ensure_any_client(callback)
  local client = any_running_client()
  if client then
    callback(nil, client)
    return client
  end
  return start_new_client(function(err, started)
    if not err and started and not started.thread_id then
      M.utility = started
    end
    callback(err, started)
  end)
end

local function request_on_client(client, method, params, callback)
  return client:request(method, params, callback or function() end)
end

local function session_file_for_thread(thread_id)
  local ok, state = pcall(require, "coact.state")
  local record = ok and state.get_thread(thread_id) or nil
  local payload = record and record.thread or {}
  local usage = record and record.token_usage or {}
  local path = util.value(payload.sessionFile or payload.session_file)
    or util.value(usage.sessionFile or usage.session_file)
  if path and vim.fn.filereadable(path) == 1 then
    return path
  end
  return provider._resolve_session_file((record and record.cwd) or config.cwd(), thread_id)
end

local function finish_waiters(thread_id, err, client, result)
  local waiters = M.starting[thread_id] or {}
  M.starting[thread_id] = nil
  for _, callback in ipairs(waiters) do
    callback(err, client, result)
  end
end

local set_thread_open_state

local function ensure_thread_client(thread_id, callback)
  local existing = M.by_thread[thread_id]
  if existing and existing.initialized and existing:is_running() then
    callback(nil, existing, nil)
    return existing
  end
  if M.starting[thread_id] then
    table.insert(M.starting[thread_id], callback)
    return nil
  end
  M.starting[thread_id] = { callback }
  set_thread_open_state(thread_id, "starting", "starting", "Starting Pi execution unit…")
  local session_file = session_file_for_thread(thread_id)
  if not session_file then
    finish_waiters(
      thread_id,
      { message = "Pi session file was not found for thread " .. tostring(thread_id) },
      nil,
      nil
    )
    return nil
  end
  return acquire_unbound_client(function(start_err, client)
    if start_err then
      set_thread_open_state(thread_id, "failed", "failed", "Could not start Pi", start_err)
      finish_waiters(thread_id, start_err, nil, nil)
      return
    end
    set_thread_open_state(thread_id, "starting", "restoring", "Restoring Pi session…")
    request_on_client(client, "thread/resume", {
      threadId = thread_id,
      sessionFile = session_file,
      cwd = config.cwd(),
      excludeTurns = false,
      persistExtendedHistory = false,
    }, function(resume_err, result)
      if resume_err then
        client:stop()
        set_thread_open_state(thread_id, "failed", "failed", "Could not restore Pi session", resume_err)
        finish_waiters(thread_id, resume_err, nil, nil)
        return
      end
      local actual = result and result.thread and result.thread.id
      if actual ~= thread_id then
        client:stop()
        finish_waiters(thread_id, {
          message = ("Pi resumed %s while %s was requested"):format(tostring(actual), tostring(thread_id)),
        }, nil, nil)
        return
      end
      local bound, bind_err = bind_client(client, thread_id)
      if not bound then
        client:stop()
        finish_waiters(thread_id, bind_err, nil, nil)
        return
      end
      result.thread.providerClientId = client.id
      result.thread.replaceTurns = true
      finish_waiters(thread_id, nil, client, result)
    end)
  end)
end

local global_request_methods = {
  ["app/list"] = true,
  ["mcpServerStatus/list"] = true,
  ["model/list"] = true,
  ["permissionProfile/list"] = true,
  ["skills/list"] = true,
}

set_thread_open_state = function(thread_id, lifecycle, sync, message, err)
  local ok, state = pcall(require, "coact.state")
  if not ok or not thread_id then
    return
  end
  local thread = state.ensure_thread(thread_id)
  thread.lifecycle = lifecycle or thread.lifecycle
  thread.sync = sync or thread.sync
  thread.sync_message = message
  thread.last_error = err and tostring(err.message or err) or nil
  local buffers_ok, buffers = pcall(require, "coact.buffers")
  if buffers_ok and thread.bufnr then
    buffers.schedule_render(thread_id)
  end
end

local function list_threads(params)
  local threads = provider._list_local_sessions(params.cwd or config.cwd())
  local indices = {}
  for index, thread in ipairs(threads) do
    indices[thread.id] = index
  end
  local ok, state = pcall(require, "coact.state")
  if not ok then
    return threads
  end
  for thread_id, client in pairs(M.by_thread) do
    if client.initialized and client:is_running() then
      local record = state.get_thread(thread_id)
      local payload = vim.deepcopy(record and record.thread or {})
      payload.id = thread_id
      payload.cwd = util.value(payload.cwd) or (record and record.cwd) or config.cwd()
      payload.name = (record and record.title) or util.value(payload.name) or "Pi session"
      payload.preview = util.value(payload.preview) or payload.name
      payload.status = (record and record.status) or util.value(payload.status) or "ready"
      payload.token_usage = record and record.token_usage or payload.token_usage
      if record then
        local effective = state.effective_thread_settings(record, config.get().thread)
        payload.model = effective.model or payload.model
        payload.modelProvider = effective.model_provider or payload.modelProvider
        payload.reasoningEffort = effective.reasoning_effort or payload.reasoningEffort
      end
      payload.providerClientId = client.id
      local index = indices[thread_id]
      if index then
        threads[index] = vim.tbl_extend("force", threads[index], payload)
      else
        table.insert(threads, 1, payload)
        for id, existing_index in pairs(indices) do
          indices[id] = existing_index + 1
        end
        indices[thread_id] = 1
      end
    end
  end
  local limit = tonumber(params.limit)
  if limit and limit > 0 and #threads > limit then
    threads = vim.list_slice(threads, 1, limit)
  end
  return threads
end

local function target_thread_id(params)
  params = type(params) == "table" and params or {}
  return util.value(params.threadId)
    or util.value(params.thread_id)
    or util.value(params.conversationId)
    or current_thread_id()
end

function M.prewarm(callback)
  callback = callback or function() end
  local pi = config.get().adapter or {}
  if pi.picker_prewarm == false then
    callback(nil, false)
    return nil
  end
  local utility = M.utility
  if utility and not utility.thread_id and (utility.starting or utility:is_running()) then
    utility:start(function(err)
      callback(err, not err)
    end)
    return utility
  end

  M.prewarm_generation = M.prewarm_generation + 1
  local generation = M.prewarm_generation
  utility = new_client({ speculative = true })
  M.utility = utility
  utility:start(function(err)
    if err and M.utility == utility then
      M.utility = nil
    end
    callback(err, not err)
  end)

  local timeout = math.max(0, tonumber(pi.prewarm_idle_timeout_ms) or 60000)
  if timeout > 0 then
    runtime_scope.defer(function()
      if generation == M.prewarm_generation and M.utility == utility and not utility.thread_id then
        M.utility = nil
        utility:stop()
      end
    end, timeout)
  end
  return utility
end

function M.start(callback)
  callback = callback or function() end
  local client = any_running_client()
  if client then
    callback(nil, true)
    return client
  end
  if M.utility and M.utility.starting then
    M.utility:start(function(err, result)
      callback(err, result)
    end)
    return M.utility
  end
  local utility = new_client()
  M.utility = utility
  utility:start(function(err, result)
    if err and M.utility == utility then
      M.utility = nil
    end
    callback(err, result)
  end)
  return utility
end

function M.request(method, params, callback)
  callback = callback or function() end
  params = params or {}

  if method == "thread/start" then
    local requested_session_id = util.value(params.sessionId or params.session_id)
    local expected_thread_id = requested_session_id and ("pi:" .. tostring(requested_session_id)) or nil
    local function start_with_client(start_client)
      return start_client(function(start_err, client)
        if start_err then
          callback(start_err, nil)
          return
        end
        local request_params = vim.deepcopy(params)
        if expected_thread_id then
          request_params.threadId = expected_thread_id
          request_params._coactUseInitialSession = true
        end
        request_on_client(client, method, request_params, function(err, result)
          if err then
            client:stop()
            callback(err, nil)
            return
          end
          local thread_id = result and result.thread and result.thread.id
          if expected_thread_id and thread_id ~= expected_thread_id then
            client:stop()
            callback({
              message = ("Pi created %s while %s was requested"):format(tostring(thread_id), expected_thread_id),
            }, nil)
            return
          end
          local bound, bind_err = bind_client(client, thread_id)
          if not bound then
            client:stop()
            callback(bind_err, nil)
            return
          end
          result.thread.providerClientId = client.id
          callback(nil, result)
        end)
      end)
    end
    if requested_session_id then
      return start_with_client(function(done)
        return start_new_client(done, { session_id = tostring(requested_session_id) })
      end)
    end
    return start_with_client(acquire_unbound_client)
  end

  if method == "thread/list" then
    callback(nil, { data = list_threads(params) })
    return nil
  end

  if global_request_methods[method] then
    return ensure_any_client(function(err, client)
      if err then
        callback(err, nil)
        return
      end
      request_on_client(client, method, params, callback)
    end)
  end

  if method == "thread/read" or method == "thread/resume" then
    local thread_id = target_thread_id(params)
    if not thread_id then
      callback({ message = "Pi thread id is required for " .. method }, nil)
      return nil
    end
    local existing = M.by_thread[thread_id]
    if existing and existing.initialized and existing:is_running() then
      local bound_params = vim.deepcopy(params)
      bound_params._coactClientBound = true
      return request_on_client(existing, method, bound_params, function(err, result)
        local actual = result and result.thread and result.thread.id
        if not err and actual ~= thread_id then
          existing:stop()
          callback({
            message = ("Pi execution unit for %s reported session %s"):format(tostring(thread_id), tostring(actual)),
          }, nil)
          return
        end
        callback(err, result)
      end)
    end
    return ensure_thread_client(thread_id, function(err, _, result)
      callback(err, result)
    end)
  end

  local thread_id = target_thread_id(params)
  if thread_id and tostring(thread_id):match("^pi:") then
    local existing = M.by_thread[thread_id]
    if existing and existing.initialized and existing:is_running() then
      return request_on_client(existing, method, params, callback)
    end
    return ensure_thread_client(thread_id, function(err, client)
      if err then
        callback(err, nil)
        return
      end
      request_on_client(client, method, params, callback)
    end)
  end

  return ensure_any_client(function(err, client)
    if err then
      callback(err, nil)
      return
    end
    request_on_client(client, method, params, callback)
  end)
end

function M.request_raw(method, params, callback)
  local thread_id = target_thread_id(params)
  local function send(err, client)
    if err then
      if callback then
        callback(err, nil)
      end
      return
    end
    client:_request_message(method, params, callback)
  end
  if thread_id and tostring(thread_id):match("^pi:") then
    return ensure_thread_client(thread_id, send)
  end
  return ensure_any_client(send)
end

function M.send(message)
  local client = any_running_client()
  if not client then
    error("Pi provider has no running execution unit")
  end
  return client:send(message)
end

function M.notify(method, params)
  local thread_id = target_thread_id(params)
  local client = thread_id and M.by_thread[thread_id] or any_running_client()
  return client and client:notify(method, params) or false
end

function M.with_client(thread_id, callback)
  return config.with_context(config.thread_context(thread_id), function()
    return ensure_thread_client(thread_id, config.bind(callback))
  end)
end

function M.client_for_thread(thread_id)
  local ctx = config.thread_context(thread_id)
  return config.with_context(ctx, function()
    return M.by_thread[thread_id]
  end)
end

function M.thread_id_for_client(client_id)
  local thread_id
  M._each_context(function()
    local client = client_id and M.clients[client_id] or nil
    thread_id = client and client.thread_id or thread_id
  end)
  return thread_id
end

function M.is_running(thread_id)
  if thread_id then
    local client = M.by_thread[thread_id]
    return client ~= nil and client:is_running()
  end
  for _, client in pairs(M.clients) do
    if client:is_running() then
      return true
    end
  end
  return false
end

function M.is_initialized(thread_id)
  if thread_id then
    local client = M.by_thread[thread_id]
    return client ~= nil and client.initialized and client:is_running()
  end
  for _, client in pairs(M.clients) do
    if client.initialized and client:is_running() then
      return true
    end
  end
  return false
end

function M.pending_count(thread_id)
  local total = 0
  if thread_id then
    local client = M.by_thread[thread_id]
    for _ in pairs(client and client.pending or {}) do
      total = total + 1
    end
    return total
  end
  for _, client in pairs(M.clients) do
    for _ in pairs(client.pending) do
      total = total + 1
    end
  end
  return total
end

function M.client_count()
  local total = 0
  for _, client in pairs(M.clients) do
    if client:is_running() then
      total = total + 1
    end
  end
  return total
end

function M.stop(thread_id)
  if thread_id then
    local client = M.by_thread[thread_id]
    if client then
      client:stop()
    end
    return
  end
  local clients = {}
  for _, client in pairs(M.clients) do
    table.insert(clients, client)
  end
  for _, client in ipairs(clients) do
    client:stop()
  end
  M.clients = {}
  M.by_thread = {}
  M.starting = {}
  M.utility = nil
  M.prewarm_generation = M.prewarm_generation + 1
end

M._list_threads = list_threads
M._new_client = new_client
M._bind_client = bind_client
M._dispatch = dispatch
M._force_thread_id = force_thread_id
M._remove_client = remove_client

return M
