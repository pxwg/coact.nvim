-- A minimal Pi RPC client for one Coact thread: JSONL commands, responses,
-- events and extension-UI requests over the child's stdio.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")

local M = {}

local Client = {}
Client.__index = Client

function M.extension_path()
  return vim.fs.joinpath(lsp.plugin_root(), "extensions", "pi", "coact-mode.ts")
end

--- Build the command for a thread's session.
function M.command(opts)
  local pi = config.get().pi
  local cmd = vim.deepcopy(pi.command)
  vim.list_extend(cmd, { "--session-dir", opts.session_dir, "--session-id", opts.session_id })
  vim.list_extend(cmd, { "--extension", M.extension_path() })
  if pi.model then
    vim.list_extend(cmd, { "--model", pi.model })
  end
  vim.list_extend(cmd, pi.args or {})
  return cmd
end

--- Start Pi. opts: cwd, root, session_dir, session_id, on_event(event),
--- on_ui(request, respond), on_exit(code, stderr).
function M.start(opts)
  local self = setmetatable({
    opts = opts,
    next_id = 0,
    pending = {},
    buffer = "",
    stderr = {},
    closed = false,
  }, Client)
  local env = vim.tbl_extend("force", config.get().pi.env or {}, { COACT_MODE_WORKSPACE = opts.root })
  local keep = config.get().compact.keep_recent_tokens
  if keep then
    env.COACT_MODE_KEEP_RECENT_TOKENS = tostring(keep)
  end
  local ok, proc = pcall(vim.system, M.command(opts), {
    cwd = opts.cwd,
    env = env,
    stdin = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          self:feed(data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        table.insert(self.stderr, data)
        if #self.stderr > 50 then
          table.remove(self.stderr, 1)
        end
      end
    end,
  }, function(result)
    vim.schedule(function()
      self:exited(result.code)
    end)
  end)
  if not ok then
    return nil, tostring(proc)
  end
  self.proc = proc
  return self
end

function Client:feed(data)
  self.buffer = self.buffer .. data
  while true do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1):gsub("\r$", "")
    self.buffer = self.buffer:sub(newline + 1)
    if line ~= "" then
      local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(message) == "table" then
        self:dispatch(message)
      end
    end
  end
end

function Client:dispatch(message)
  if message.type == "response" and message.id and self.pending[message.id] then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    callback(
      message.success == false and (message.error or "Pi rejected " .. tostring(message.command)) or nil,
      message.data
    )
  elseif message.type == "extension_ui_request" then
    local responded = false
    local function respond(fields)
      if responded or message.method == "notify" then
        return
      end
      responded = true
      self:send(vim.tbl_extend("force", { type = "extension_ui_response", id = message.id }, fields))
    end
    self.opts.on_ui(message, respond)
  else
    self.opts.on_event(message)
  end
end

function Client:send(message)
  if self.closed or not self.proc then
    return false
  end
  local ok = pcall(self.proc.write, self.proc, vim.json.encode(message) .. "\n")
  return ok
end

--- Send a command; callback(err, data) receives its response.
function Client:request(type, fields, callback)
  self.next_id = self.next_id + 1
  local id = "coact-mode-" .. self.next_id
  self.pending[id] = callback or function() end
  local message = vim.tbl_extend("force", fields or {}, { id = id, type = type })
  if not self:send(message) then
    self.pending[id] = nil
    if callback then
      callback("Pi is not running")
    end
  end
end

function Client:prompt(text, callback)
  self:request("prompt", { message = text }, callback)
end

function Client:exited(code)
  if self.closed then
    return
  end
  self.closed = true
  for id, callback in pairs(self.pending) do
    self.pending[id] = nil
    callback("Pi exited")
  end
  self.opts.on_exit(code, table.concat(self.stderr))
end

function Client:is_running()
  return not self.closed
end

--- Close stdin for an orderly shutdown; kill if Pi lingers.
function Client:stop()
  if self.closed or not self.proc then
    return
  end
  pcall(self.proc.write, self.proc, nil)
  local proc = self.proc
  vim.defer_fn(function()
    if not proc:is_closing() then
      pcall(proc.kill, proc, "sigterm")
    end
  end, 3000)
end

return M
