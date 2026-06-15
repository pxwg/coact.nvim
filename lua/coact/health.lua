local config = require("coact.config")
local providers = require("coact.providers")

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

local health_api = {
  ok = function(message)
    vim.health.ok(message)
  end,
  warn = function(message)
    vim.health.warn(message)
  end,
  error = function(message)
    vim.health.error(message)
  end,
  info = function(message)
    vim.health.info(message)
  end,
  command_label = command_label,
  system_text = system_text,
  app_server_supported = app_server_supported,
}

local function has_module(name)
  local ok = pcall(require, name)
  return ok
end

function M.check()
  vim.health.start("coact.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim version is 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local opts = config.get()
  local provider = providers.current()
  if type(provider.health) == "function" then
    provider.health(opts, health_api)
  else
    vim.health.info("active provider: " .. providers.current_id())
  end

  local app_executable = type(provider.executable) == "function" and provider.executable(opts)
    or executable(opts.app_server and opts.app_server.command)

  local native_pair_hook_enabled = config.edit_mode() == "pair"
    and opts.edit
    and opts.edit.native_apply_patch_hook
    and opts.edit.native_apply_patch_hook.enabled ~= false
  if
    native_pair_hook_enabled
    and (vim.fn.executable("apply_patch") == 1 or (app_executable and vim.fn.executable(app_executable) == 1))
  then
    vim.health.ok("Codex apply_patch runtime is available for native hook validation")
  elseif native_pair_hook_enabled then
    vim.health.error("Codex apply_patch runtime is required for native apply_patch hook validation in pair mode")
  end
  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is available for legacy unified-diff nvim.apply_patch compatibility")
  elseif native_pair_hook_enabled then
    vim.health.info("git is not available; native Codex apply_patch-format reviews still work")
  else
    vim.health.info("git is not available")
  end

  if has_module("coact.completion.blink") then
    vim.health.ok("coact blink.cmp source can be loaded")
  else
    vim.health.error("coact blink.cmp source cannot be loaded")
  end

  if has_module("snacks.picker") then
    vim.health.ok("snacks.picker is available for thread picking")
  else
    vim.health.info("snacks.picker is optional; vim.ui.select fallback will be used")
  end

  if has_module("blink.cmp") then
    vim.health.ok("blink.cmp is available for prompt completions")
  else
    vim.health.info("blink.cmp is optional; Coact prompt completions will be unavailable unless configured")
  end

  if opts.dynamic_tools and opts.dynamic_tools.enabled then
    local specs = require("coact.dynamic_tools").specs() or {}
    vim.health.ok(("Neovim dynamic tools enabled: %d tools (edit mode: %s)"):format(#specs, config.edit_mode()))
  else
    vim.health.info("Neovim dynamic tools are disabled")
  end
end

M._command_label = command_label
M._executable = executable
M._app_server_supported = app_server_supported
M._system_text = system_text

return M
