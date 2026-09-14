-- History is the selected root-to-leaf path, NOT buildSessionContext().
-- A compaction is a historical event; it never removes or reorders ancestors.
local util = require("coact.util")
local M = {}

function M.messages(payload)
  if type(payload) ~= "table" or type(payload.entries) ~= "table" then
    return nil, "Pi get_entries returned no entries"
  end
  if payload.leafId == nil then
    return nil, "Pi get_entries returned no leafId"
  end
  local by_id = {}
  for _, entry in ipairs(payload.entries) do
    local id = type(entry) == "table" and util.value(entry.id)
    if id then
      if by_id[id] then
        return nil, "duplicate Pi entry: " .. tostring(id)
      end
      by_id[id] = entry
    end
  end
  local path, seen = {}, {}
  local id = util.value(payload.leafId)
  while id do
    if seen[id] then
      return nil, "cycle in Pi branch: " .. tostring(id)
    end
    local entry = by_id[id]
    if not entry then
      return nil, "missing Pi branch entry: " .. tostring(id)
    end
    seen[id] = true
    table.insert(path, entry)
    id = util.value(entry.parentId)
  end
  local messages = {}
  for index = #path, 1, -1 do
    local entry = path[index]
    local message
    if entry.type == "message" and type(entry.message) == "table" then
      message = vim.deepcopy(entry.message)
    elseif entry.type == "compaction" or entry.type == "branch_summary" then
      message = {
        role = entry.type == "compaction" and "compactionSummary" or "branchSummary",
        summary = util.value(entry.summary),
        tokensBefore = util.value(entry.tokensBefore),
        fromId = util.value(entry.fromId),
        firstKeptEntryId = util.value(entry.firstKeptEntryId),
      }
    elseif entry.type == "custom_message" and entry.display == true then
      message = { role = "custom", customType = entry.customType, content = entry.content, display = true }
    end
    -- Model/thinking settings, labels, session metadata and extension-private
    -- custom entries are not chat messages. Keep them in the path, not the UI.
    if message then
      message.timestamp = util.value(message.timestamp) or util.value(entry.timestamp)
      message._piEntry = { id = entry.id, parentId = util.value(entry.parentId) }
      table.insert(messages, message)
    end
  end
  return messages
end

return M
