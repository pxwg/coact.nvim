local config = require("codex.config")
local util = require("codex.util")

local M = {}

M.job_id = nil
M.next_id = 1
M.pending = {}
M.handlers = {}
M.stdout_tail = ""
M.stderr_tail = ""
M.initialized = false

local function encode(value)
  return vim.json.encode(value)
end

local function decode(line)
  return vim.json.decode(line)
end

local function schedule(fn)
  vim.schedule(fn)
end

function M.set_handlers(handlers)
  M.handlers = handlers or {}
end

local function dispatch(message)
  if type(message) ~= "table" then
    return
  end
  if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
    local key = tostring(message.id)
    local pending = M.pending[key]
    M.pending[key] = nil
    if pending then
      schedule(function()
        pending.callback(message.error, message.result)
      end)
    end
    return
  end

  if message.method and message.id ~= nil then
    if M.handlers.server_request then
      schedule(function()
        M.handlers.server_request(message)
      end)
    end
    return
  end

  if message.method and M.handlers.notification then
    schedule(function()
      M.handlers.notification(message)
    end)
  end
end

local function handle_line(line)
  if line == nil or line == "" then
    return
  end
  local ok, message = pcall(decode, line)
  if not ok then
    util.notify("failed to decode app-server message: " .. tostring(message), vim.log.levels.ERROR)
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

function M.start(callback)
  if M.is_running() then
    if callback then
      callback(nil, true)
    end
    return
  end

  local opts = config.get()
  local command = opts.app_server.command
  M.stdout_tail = ""
  M.stderr_tail = ""
  M.initialized = false

  M.job_id = vim.fn.jobstart(command, {
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
      schedule(function()
        for _, entry in pairs(pending) do
          entry.callback({ code = code, message = "codex app-server exited" }, nil)
        end
        if code ~= 0 then
          util.notify("codex app-server exited with code " .. tostring(code), vim.log.levels.ERROR)
        end
      end)
    end,
  })

  if M.job_id <= 0 then
    local err = "failed to start codex app-server"
    M.job_id = nil
    if callback then
      callback({ message = err }, nil)
    else
      util.notify(err, vim.log.levels.ERROR)
    end
    return
  end

  M.request("initialize", {
    clientInfo = {
      name = "codex.nvim",
      title = "Codex.nvim",
      version = "0.1.0",
    },
    capabilities = {
      experimentalApi = true,
    },
  }, function(err, result)
    if err then
      if callback then
        callback(err, nil)
      else
        util.notify("codex initialize failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
      end
      return
    end
    M.initialized = true
    M.notify("initialized", {})
    if callback then
      callback(nil, result or true)
    end
  end)
end

function M.stop()
  if M.is_running() then
    vim.fn.jobstop(M.job_id)
  end
  M.job_id = nil
  M.pending = {}
  M.initialized = false
end

function M.send(message)
  if not M.is_running() then
    error("codex app-server is not running")
  end
  vim.fn.chansend(M.job_id, encode(message) .. "\n")
end

function M.request(method, params, callback)
  callback = callback or function() end
  local id = M.next_id
  M.next_id = M.next_id + 1
  M.pending[tostring(id)] = {
    method = method,
    callback = callback,
  }
  local message = {
    id = id,
    method = method,
  }
  if params ~= nil then
    message.params = params
  end
  local ok, err = pcall(M.send, message)
  if not ok then
    M.pending[tostring(id)] = nil
    callback({ message = err }, nil)
  end
  return id
end

function M.notify(method, params)
  local message = {
    method = method,
  }
  if params ~= nil then
    message.params = params
  end
  M.send(message)
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

return M
