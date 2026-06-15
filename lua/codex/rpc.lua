local config = require("codex.config")
local providers = require("codex.providers")
local util = require("codex.util")

local M = {}

M.job_id = nil
M.next_id = 1
M.pending = {}
M.handlers = {}
M.stdout_tail = ""
M.stderr_tail = ""
M.initialized = false
M.stopping = false

local function encode(value)
  return vim.json.encode(value)
end

local function decode(line)
  return vim.json.decode(line)
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
  return not (opts.app_server and opts.app_server.sanitize_malloc_env == false)
end

local function schedule(fn)
  vim.schedule(fn)
end

local function expected_exit(code, stopping)
  return stopping or code == 0 or code == 15 or code == 143
end

local function expected_send_failure(err)
  return tostring(err or ""):match("closed stream") ~= nil
end

function M.set_handlers(handlers)
  M.handlers = handlers or {}
end

local function dispatch(message)
  if type(message) ~= "table" then
    return
  end
  local provider = providers.current()
  if type(provider.handle_raw_message) == "function" and provider.handle_raw_message(message, M) then
    return
  end
  local response = type(provider.decode_response) == "function" and provider.decode_response(message) or nil
  if response then
    local key = tostring(response.id)
    local pending = M.pending[key]
    M.pending[key] = nil
    if pending then
      schedule(function()
        pending.callback(response.error, response.result)
      end)
    end
    return
  end

  local decoded = type(provider.decode_notification) == "function" and provider.decode_notification(message) or nil
  local function dispatch_decoded(entry)
    if type(entry) ~= "table" then
      return
    end
    if entry.kind == "server_request" and M.handlers.server_request then
      schedule(function()
        M.handlers.server_request(entry.message)
      end)
    elseif entry.kind == "notification" and M.handlers.notification then
      schedule(function()
        M.handlers.notification(entry.message)
      end)
    end
  end

  if decoded then
    if vim.islist(decoded) then
      for _, entry in ipairs(decoded) do
        dispatch_decoded(entry)
      end
    else
      dispatch_decoded(decoded)
    end
  end
end

local function handle_line(line)
  if line == nil or line == "" then
    return
  end
  local ok, message = pcall(decode, line)
  if not ok then
    util.notify(
      "failed to decode " .. providers.title() .. " provider message: " .. tostring(message),
      vim.log.levels.ERROR
    )
    return
  end
  dispatch(message)
end

local function feed_stdout(data)
  if not data then
    return
  end
  for index, chunk in ipairs(data) do
    if index == 1 then
      chunk = M.stdout_tail .. chunk
      M.stdout_tail = ""
    end
    if index < #data then
      handle_line(chunk)
    else
      M.stdout_tail = chunk
    end
  end
end

local function feed_stderr(data)
  if not data then
    return
  end
  local text = table.concat(data, "\n")
  if text == "" then
    return
  end
  M.stderr_tail = text
  if M.handlers.stderr then
    schedule(function()
      M.handlers.stderr(text)
    end)
  end
end

function M.is_running()
  return M.job_id ~= nil and M.job_id > 0
end

local function register_native_hook_trust(callback)
  local ok, native_hook = pcall(require, "codex.native_apply_patch_hook")
  if not ok or type(native_hook.enabled) ~= "function" or not native_hook.enabled() then
    callback()
    return
  end
  if type(native_hook.debug_log) == "function" then
    native_hook.debug_log("trust_hooks_list_request", {})
  end
  M.request("hooks/list", native_hook.hooks_list_params(), function(list_err, result)
    if type(native_hook.debug_log) == "function" then
      native_hook.debug_log("trust_hooks_list_done", {
        error = list_err,
        result = result,
      })
    end
    if list_err then
      callback({
        message = "codex native apply_patch hook trust discovery failed: " .. tostring(list_err.message or list_err),
      })
      return
    end

    if type(native_hook.has_matching_hook) == "function" and not native_hook.has_matching_hook(result) then
      callback({
        message = "codex native apply_patch hook was not found in app-server hooks/list",
      })
      return
    end

    local edits = native_hook.trust_edits_from_hooks_response(result)
    if #edits == 0 then
      callback()
      return
    end

    if type(native_hook.debug_log) == "function" then
      native_hook.debug_log("trust_config_write_request", { edits = edits })
    end
    M.request("config/batchWrite", {
      edits = edits,
      reloadUserConfig = true,
    }, function(write_err)
      if type(native_hook.debug_log) == "function" then
        native_hook.debug_log("trust_config_write_done", {
          error = write_err,
        })
      end
      if write_err then
        callback({
          message = "codex native apply_patch hook trust write failed: " .. tostring(write_err.message or write_err),
        })
        return
      end
      callback()
    end)
  end)
end

function M.start(callback)
  if M.is_running() then
    if callback then
      callback(nil, true)
    end
    return
  end

  local opts = config.get()
  local provider = providers.current()
  local command = provider.command and provider.command(opts) or opts.app_server.command
  M.stdout_tail = ""
  M.stderr_tail = ""
  M.initialized = false
  local env = sanitize_malloc_env_enabled(opts) and app_server_env() or {}
  if type(provider.env) == "function" then
    env = provider.env(opts, env) or env
  end
  local hook_err
  if type(provider.prepare_command) == "function" then
    command, env, hook_err = provider.prepare_command(command, env)
    if not command then
      if callback then
        callback({ message = hook_err }, nil)
      else
        util.notify(hook_err, vim.log.levels.ERROR)
      end
      return
    end
  end

  local job_opts = {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      feed_stdout(data)
    end,
    on_stderr = function(_, data)
      feed_stderr(data)
    end,
    on_exit = function(_, code)
      local pending = M.pending
      M.pending = {}
      M.job_id = nil
      M.initialized = false
      local stopping = M.stopping
      M.stopping = false
      schedule(function()
        local expected = expected_exit(code, stopping)
        if not expected then
          for _, entry in pairs(pending) do
            entry.callback({ code = code, message = providers.title() .. " provider exited" }, nil)
          end
        end
        if code ~= 0 and not expected then
          util.notify(providers.title() .. " provider exited with code " .. tostring(code), vim.log.levels.ERROR)
        end
      end)
    end,
  }

  if sanitize_malloc_env_enabled(opts) then
    job_opts.clear_env = true
    job_opts.env = env
  elseif not env_empty(env) then
    job_opts.env = env
  end

  M.job_id = vim.fn.jobstart(command, job_opts)

  if M.job_id <= 0 then
    local err = "failed to start " .. providers.title() .. " provider"
    M.job_id = nil
    if callback then
      callback({ message = err }, nil)
    else
      util.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  provider.initialize(M, function(err, result)
    if err then
      if callback then
        callback(err, nil)
      else
        util.notify(
          providers.title() .. " provider initialize failed: " .. tostring(err.message or err),
          vim.log.levels.ERROR
        )
      end
      return
    end
    if M.stopping or not M.is_running() then
      return
    end
    M.initialized = true
    if callback then
      callback(nil, result or true)
    end
  end)
end

function M.stop()
  if M.is_running() then
    M.stopping = true
    vim.fn.jobstop(M.job_id)
  end
  M.job_id = nil
  M.pending = {}
  M.initialized = false
end

function M.send(message)
  if not M.is_running() then
    error(providers.title() .. " provider is not running")
  end
  vim.fn.chansend(M.job_id, encode(message) .. "\n")
end

function M._request_message(method, params, callback)
  callback = callback or function() end
  local id = M.next_id
  M.next_id = M.next_id + 1
  M.pending[tostring(id)] = {
    method = method,
    callback = callback,
  }
  local provider = providers.current()
  local message = provider.request_message(method, params, id)
  local ok, err = pcall(M.send, message)
  if not ok then
    M.pending[tostring(id)] = nil
    callback({ message = err }, nil)
  end
  return id
end

function M.request(method, params, callback)
  local provider = providers.current()
  if type(provider.custom_request) == "function" then
    local handled, id = provider.custom_request(M, method, params, callback or function() end)
    if handled then
      return id
    end
  end
  return M._request_message(method, params, callback)
end

function M.notify(method, params)
  if M.stopping or not M.is_running() then
    return false
  end
  local provider = providers.current()
  local message = provider.notify_message(method, params)
  local ok, err = pcall(M.send, message)
  if not ok and not M.stopping and not expected_send_failure(err) then
    util.notify(providers.title() .. " provider notify failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

function M.respond(id, result)
  M.send({ id = id, result = result or vim.empty_dict() })
end

function M.respond_error(id, message, code, data)
  M.send({
    id = id,
    error = {
      code = code or -32603,
      message = message,
      data = data,
    },
  })
end

M._app_server_env = app_server_env
M._sanitize_malloc_env_enabled = sanitize_malloc_env_enabled
M._register_native_hook_trust = register_native_hook_trust
M._dispatch = dispatch

return M
