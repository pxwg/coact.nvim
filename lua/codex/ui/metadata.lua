local util = require("codex.util")

local M = {}

local function add(labels, value)
  local label = util.label(value)
  if label then
    table.insert(labels, label)
  end
end

function M.composer_labels(thread)
  local labels = {}
  local cfg = thread and thread.config or {}
  add(labels, cfg.model)
  add(labels, cfg.reasoning_effort and ("effort " .. cfg.reasoning_effort))
  if thread and thread.status then
    add(labels, thread.status)
  end
  return labels
end

function M.user_labels(_, block)
  local labels = {}
  add(labels, block and block.state)
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
