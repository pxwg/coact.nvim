local config = require("coact.config")

local M = {}

local loaded = {}

local function provider_id(thread)
  local ctx = thread and config.thread_context(thread.id)
  local id = ctx and ctx.options.adapter.provider or config.provider_id()
  return id
end

function M.current_id(thread)
  return provider_id(thread)
end

function M.current(thread)
  local id = provider_id(thread)
  if not loaded[id] then
    local ok, provider = pcall(require, "coact.providers." .. id)
    if not ok then
      error(("coact.nvim: unknown provider %q: %s"):format(tostring(id), tostring(provider)))
    end
    loaded[id] = provider
  end
  return loaded[id]
end

function M.is(name)
  return provider_id() == name
end

function M.title(thread)
  local provider = M.current(thread)
  return provider.title or provider.name or provider_id(thread)
end

function M.agent_label(thread)
  local provider = M.current(thread)
  return provider.agent_label or provider.title or provider.name or provider_id(thread)
end

return M
