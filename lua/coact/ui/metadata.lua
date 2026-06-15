local util = require("coact.util")
local config = require("coact.config")
local state = require("coact.state")

local M = {}

local function add(labels, value)
  local label = util.label(value)
  if label then
    table.insert(labels, label)
  end
end

local function first_label(...)
  for index = 1, select("#", ...) do
    local label = util.label(select(index, ...))
    if label then
      return label
    end
  end
  return nil
end

local function source_model(source)
  if type(source) ~= "table" then
    return nil
  end
  return first_label(source.model, source.modelId, source.modelName)
end

local function source_effort(source)
  if type(source) ~= "table" then
    return nil
  end
  local reasoning = type(source.reasoning) == "table" and source.reasoning or {}
  return first_label(source.reasoning_effort, source.reasoningEffort, source.effort, reasoning.effort)
end

local function service_tier_label(value)
  if type(value) == "table" then
    return first_label(value.id, value.name, value.label, value.title, value.type)
  end
  return util.label(value)
end

local function source_service_tier(source)
  if type(source) ~= "table" then
    return nil
  end
  return service_tier_label(source.service_tier) or service_tier_label(source.serviceTier)
end

local function source_fast_label(source)
  local service_tier = source_service_tier(source)
  if service_tier and service_tier:lower():find("fast", 1, true) then
    return "fast"
  end
  return nil
end

local function add_settings_labels(labels, ...)
  local model
  local fast
  local effort
  for index = 1, select("#", ...) do
    local source = select(index, ...)
    model = model or source_model(source)
    fast = fast or source_fast_label(source)
    effort = effort or source_effort(source)
  end
  add(labels, model)
  add(labels, fast)
  if effort then
    add(labels, "effort " .. effort)
  end
end

function M.composer_labels(thread)
  local labels = {}
  local cfg = config.get().thread or {}
  add_settings_labels(labels, state.effective_thread_settings(thread, cfg))
  if thread and thread.status then
    add(labels, thread.status)
  end
  return labels
end

function M.user_labels(_, block)
  local labels = {}
  add(labels, block and block.state)
  local raw = block and block.raw
  add_settings_labels(labels, block and block.metadata, type(raw) == "table" and raw.settings or nil, raw)
  return labels
end

function M.assistant_labels(_, block)
  local labels = {}
  add(labels, block and block.state)
  return labels
end

function M.context_label(thread, block)
  if block and block.context_count and block.context_count > 0 then
    return "ctx " .. tostring(block.context_count)
  end
  local usage = thread and thread.token_usage
  if type(usage) ~= "table" then
    return nil
  end
  local input = usage.inputTokens or usage.input_tokens
  local output = usage.outputTokens or usage.output_tokens
  if input or output then
    return ("tok %s/%s"):format(tostring(input or "?"), tostring(output or "?"))
  end
  return nil
end

return M
