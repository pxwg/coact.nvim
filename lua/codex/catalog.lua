local config = require("codex.config")
local state = require("codex.state")

local M = {}
local inflight = {}

local static = {
  ["/"] = {
    { label = "/new", detail = "Create a new Codex thread" },
    { label = "/pick", detail = "Pick a Codex thread" },
    { label = "/resume", detail = "Resume a Codex thread by id" },
    { label = "/stop", detail = "Stop the active Codex turn" },
    { label = "/submit", detail = "Submit the current prompt" },
  },
  [">"] = {
    { label = ">buffer", detail = "Attach current buffer text" },
    { label = ">selection", detail = "Attach current visual selection" },
    { label = ">diagnostics", detail = "Attach current buffer diagnostics" },
    { label = ">quickfix", detail = "Reference the quickfix list" },
  },
  ["@"] = {
    { label = "@file:", detail = "Mention a file path" },
    { label = "@buffer", detail = "Mention the current buffer" },
    { label = "@diagnostics", detail = "Mention diagnostics context" },
  },
  ["$"] = {
    { label = "$model:", detail = "Set or reference a model" },
    { label = "$skill:", detail = "Attach a Codex skill" },
    { label = "$reasoning:low", detail = "Low reasoning effort" },
    { label = "$reasoning:medium", detail = "Medium reasoning effort" },
    { label = "$reasoning:high", detail = "High reasoning effort" },
  },
}

local function cache_key(kind)
  return "catalog:" .. kind
end

local function normalize_model(model)
  local id = model.id or model.model
  if not id then
    return nil
  end
  return {
    label = "$model:" .. id,
    detail = model.displayName or model.description or "Codex model",
    documentation = model.description,
    data = model,
  }
end

local function normalize_skill(skill)
  if not skill.name then
    return nil
  end
  return {
    label = "$skill:" .. skill.name,
    detail = skill.shortDescription or skill.description or "Codex skill",
    documentation = skill.description,
    data = skill,
  }
end

function M.static_for_trigger(trigger)
  return vim.deepcopy(static[trigger] or {})
end

function M.dynamic(kind)
  if not kind then
    return {}
  end
  return state.get_cache(cache_key(kind), config.get().completion.ttl_ms or 30000) or {}
end

local function refresh_models(callback)
  require("codex.rpc").request("model/list", { limit = 100, includeHidden = false }, function(err, result)
    if err then
      callback({})
      return
    end
    local items = {}
    for _, model in ipairs(result.data or {}) do
      local item = normalize_model(model)
      if item then
        table.insert(items, item)
      end
    end
    state.set_cache(cache_key("models"), items)
    callback(items)
  end)
end

local function refresh_skills(callback)
  require("codex.rpc").request("skills/list", { cwds = { config.cwd() }, forceReload = false }, function(err, result)
    if err then
      callback({})
      return
    end
    local items = {}
    for _, entry in ipairs(result.data or {}) do
      for _, skill in ipairs(entry.skills or {}) do
        local item = normalize_skill(skill)
        if item then
          table.insert(items, item)
        end
      end
    end
    state.set_cache(cache_key("skills"), items)
    callback(items)
  end)
end

function M.refresh(kind, callback)
  callback = callback or function() end
  if inflight[kind] then
    callback(M.dynamic(kind))
    return
  end
  inflight[kind] = true
  local done = function(items)
    inflight[kind] = nil
    callback(items or {})
  end
  if kind == "models" then
    refresh_models(done)
  elseif kind == "skills" then
    refresh_skills(done)
  else
    done({})
  end
end

function M.ensure_refresh(kind)
  if not kind or state.get_cache(cache_key(kind), config.get().completion.ttl_ms or 30000) then
    return
  end
  if not require("codex.rpc").is_running() then
    return
  end
  M.refresh(kind)
end

function M.kind_for_trigger(trigger, prefix)
  if trigger ~= "$" then
    return nil
  end
  if prefix and vim.startswith(prefix, "$skill:") then
    return "skills"
  end
  if prefix and vim.startswith(prefix, "$model:") then
    return "models"
  end
  return nil
end

function M.find_skill(name)
  for _, item in ipairs(M.dynamic("skills")) do
    if item.data and item.data.name == name then
      return item.data
    end
  end
  return nil
end

return M
