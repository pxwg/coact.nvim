local config = require("codex.config")

local M = {}

local loaded = {}

local function provider_id()
  local id = config.provider_id()
  if id == "pi-agent" or id == "pi_agent" then
    return "pi"
  end
  return id
end

function M.current_id()
  return provider_id()
end

function M.current()
  local id = provider_id()
  if not loaded[id] then
    local ok, provider = pcall(require, "codex.providers." .. id)
    if not ok then
      error(("codex.nvim: unknown provider %q: %s"):format(tostring(id), tostring(provider)))
    end
    loaded[id] = provider
  end
  return loaded[id]
end

function M.is(name)
  return provider_id() == name
end

function M.title()
  local provider = M.current()
  return provider.title or provider.name or provider_id()
end

function M.agent_label()
  local provider = M.current()
  return provider.agent_label or provider.title or provider.name or provider_id()
end

return M
