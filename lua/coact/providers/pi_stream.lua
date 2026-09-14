-- Pi messages, not agent turns, own content slots. RPC deltas have no partial
-- snapshot in current Pi; reconstruct only the slot needed by the adapter.
local util = require("coact.util")
local M = {}

function M.new()
  return { sequence = 0, slots = {} }
end

function M.start(stream, message)
  stream.sequence = stream.sequence + 1
  stream.slots = {}
  for index, block in ipairs(type(message.content) == "table" and message.content or {}) do
    stream.slots[index] = vim.deepcopy(block)
  end
end

function M.scope(stream)
  return stream.sequence > 1 and ("message-" .. stream.sequence) or nil
end

function M.update(stream, event)
  local index = (tonumber(util.value(event.contentIndex)) or 0) + 1
  local slot = stream.slots[index]
  local partial = type(event.partial) == "table" and event.partial or {}
  local content = type(partial.content) == "table" and partial.content or {}
  local supplied = util.value(event.toolCall) or content[index] or (partial.type == "toolCall" and partial)
  if type(supplied) == "table" then
    slot = vim.deepcopy(supplied)
  elseif event.type == "toolcall_start" then
    slot = { type = "toolCall", id = util.value(event.id), name = util.value(event.toolName), arguments = {} }
  elseif event.type == "toolcall_delta" and slot then
    slot.partialJson = (util.value(slot.partialJson) or "") .. tostring(util.value(event.delta) or "")
    local ok, args = pcall(vim.json.decode, slot.partialJson)
    if ok and type(args) == "table" then
      slot.arguments = args
    end
  end
  if slot then
    stream.slots[index] = slot
  end
  return slot
end

return M
