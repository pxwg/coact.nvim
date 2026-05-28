local config = require("codex.config")

local M = {}

local function command_label(command)
  if type(command) == "table" then
    return table.concat(vim.tbl_map(tostring, command), " ")
  end
  return tostring(command or "")
end

local function executable(command)
  if type(command) == "table" then
    return command[1]
  end
  if type(command) == "string" then
    return vim.split(command, "%s+", { trimempty = true })[1]
  end
end

local function system_text(command, timeout_ms)
  local ok, result = pcall(function()
    return vim.system(command, { text = true }):wait(timeout_ms)
  end)
  if not ok then
    return nil, tostring(result)
  end
  if result.code ~= 0 then
    return nil, result.stderr ~= "" and result.stderr or result.stdout
  end
  return vim.trim(result.stdout ~= "" and result.stdout or result.stderr)
end

local function app_server_help(executable_name)
  if not executable_name or executable_name == "" then
    return nil, "missing executable"
  end
  return system_text({ executable_name, "app-server", "--help" }, 5000)
end

local function app_server_supported(executable_name)
  local help, err = app_server_help(executable_name)
  if not help then
    return false, err
  end
  return help:match("app%-server") ~= nil and help:match("%-%-listen") ~= nil, help
end

local function has_module(name)
  local ok = pcall(require, name)
  return ok
end

function M.check()
  vim.health.start("codex.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim version is 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local opts = config.get()
  local app_command = opts.app_server and opts.app_server.command
  local app_executable = executable(app_command)
  if app_executable and vim.fn.executable(app_executable) == 1 then
    local version, err = system_text({ app_executable, "--version" })
    vim.health.ok(("Codex executable found: %s"):format(app_executable))
    if version and version ~= "" then
      vim.health.info(version)
    elseif err and err ~= "" then
      vim.health.warn(("Could not read Codex version: %s"):format(vim.trim(err)))
    end
    local supported, support_err = app_server_supported(app_executable)
    if supported then
      vim.health.ok("Codex executable supports app-server stdio mode")
    else
      vim.health.error(
        ("Codex executable does not appear to support app-server stdio mode: %s"):format(vim.trim(support_err or ""))
      )
    end
  else
    vim.health.error(("Codex executable is not available: %s"):format(app_executable or command_label(app_command)))
  end

  if type(app_command) == "table" and vim.tbl_contains(app_command, "app-server") then
    vim.health.ok(("App-server command configured: %s"):format(command_label(app_command)))
  else
    vim.health.warn(("App-server command does not visibly include app-server: %s"):format(command_label(app_command)))
  end

  local nvim_apply_patch_enabled = opts.dynamic_tools
    and opts.dynamic_tools.enabled ~= false
    and config.edit_mode() == "pair"
  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is available for nvim.apply_patch")
  elseif nvim_apply_patch_enabled then
    vim.health.error("git is required when nvim.apply_patch is enabled in pair edit mode")
  else
    vim.health.warn("git is not available; nvim.apply_patch will not work")
  end

  if has_module("codex.completion.blink") then
    vim.health.ok("codex blink.cmp source can be loaded")
  else
    vim.health.error("codex blink.cmp source cannot be loaded")
  end

  if has_module("snacks.picker") then
    vim.health.ok("snacks.picker is available for thread picking")
  else
    vim.health.info("snacks.picker is optional; vim.ui.select fallback will be used")
  end

  if has_module("blink.cmp") then
    vim.health.ok("blink.cmp is available for prompt completions")
  else
    vim.health.info("blink.cmp is optional; Codex prompt completions will be unavailable unless configured")
  end

  if opts.dynamic_tools and opts.dynamic_tools.enabled then
    local specs = require("codex.dynamic_tools").specs() or {}
    vim.health.ok(("Neovim dynamic tools enabled: %d tools (edit mode: %s)"):format(#specs, config.edit_mode()))
  else
    vim.health.info("Neovim dynamic tools are disabled")
  end
end

M._command_label = command_label
M._executable = executable
M._app_server_supported = app_server_supported

return M
