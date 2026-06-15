local config = require("coact.config")
local util = require("coact.util")

local M = {
  name = "codex",
  title = "Codex",
  agent_label = "Codex",
  protocol = "codex-app-server",
  slash = {
    commands = "all",
  },
}

function M.command(opts)
  return opts.app_server and opts.app_server.command or { "codex", "app-server", "--listen", "stdio://" }
end

function M.prepare_command(command, env)
  return require("coact.native_apply_patch_hook").prepare_app_server(command, env)
end

function M.initialize(rpc, callback)
  rpc._request_message("initialize", {
    clientInfo = {
      name = "coact.nvim",
      title = "Coact.nvim",
      version = "0.1.0",
    },
    capabilities = {
      experimentalApi = true,
    },
  }, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    rpc._register_native_hook_trust(function(trust_err)
      if trust_err then
        callback(trust_err, nil)
        return
      end
      rpc.notify("initialized", {})
      callback(nil, result or true)
    end)
  end)
end

function M.request_message(method, params, id)
  local message = {
    id = id,
    method = method,
  }
  if params ~= nil then
    message.params = params
  end
  return message
end

function M.notify_message(method, params)
  local message = {
    method = method,
  }
  if params ~= nil then
    message.params = params
  end
  return message
end

function M.decode_response(message)
  if type(message) ~= "table" or message.id == nil or (message.result == nil and message.error == nil) then
    return nil
  end
  return {
    id = tostring(message.id),
    error = message.error,
    result = message.result,
  }
end

function M.decode_notification(message)
  if type(message) == "table" and message.method and message.id ~= nil then
    return {
      kind = "server_request",
      message = message,
    }
  end
  if type(message) == "table" and message.method then
    return {
      kind = "notification",
      message = message,
    }
  end
  return nil
end

function M.command_label()
  return "Codex app-server"
end

function M.executable(opts)
  local command = M.command(opts or config.get())
  if type(command) == "table" then
    return command[1]
  end
  if type(command) == "string" then
    return vim.split(command, "%s+", { trimempty = true })[1]
  end
  return nil
end

function M.health(opts, health)
  opts = opts or config.get()
  health.info("active provider: codex")
  local app_command = M.command(opts)
  local app_executable = M.executable(opts)
  if app_executable and vim.fn.executable(app_executable) == 1 then
    local version, err = health.system_text({ app_executable, "--version" })
    health.ok(("Codex executable found: %s"):format(app_executable))
    if version and version ~= "" then
      health.info(version)
    elseif err and err ~= "" then
      health.warn(("Could not read Codex version: %s"):format(vim.trim(err)))
    end
    local supported, support_err = health.app_server_supported(app_executable)
    if supported then
      health.ok("Codex executable supports app-server stdio mode")
    else
      health.error(
        ("Codex executable does not appear to support app-server stdio mode: %s"):format(vim.trim(support_err or ""))
      )
    end
  else
    health.error(("Codex executable is not available: %s"):format(app_executable or health.command_label(app_command)))
  end

  if type(app_command) == "table" and vim.tbl_contains(app_command, "app-server") then
    health.ok(("App-server command configured: %s"):format(health.command_label(app_command)))
  else
    health.warn(
      ("App-server command does not visibly include app-server: %s"):format(health.command_label(app_command))
    )
  end
end

function M.default_status_config()
  return {
    model = util.value(config.get().thread.model),
    service_tier = util.value(config.get().thread.service_tier),
  }
end

return M
