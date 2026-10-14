-- Model-authored rationales waiting for the next review of a file.
local M = {}

local ttl_ns = 30 * 60 * 1e9
local pending = {}

local function key(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

-- Store { anchor, note } items for path; returns the number stored.
function M.add(path, notes)
  if type(path) ~= "string" or path == "" or type(notes) ~= "table" then
    return 0
  end
  local k = key(path)
  local now = vim.uv.hrtime()
  local list = pending[k] or {}
  local count = 0
  for _, item in ipairs(notes) do
    local note = type(item) == "table" and type(item.note) == "string" and vim.trim(item.note) or ""
    if note ~= "" then
      table.insert(list, { anchor = type(item.anchor) == "string" and item.anchor or "", note = note, at = now })
      count = count + 1
    end
  end
  pending[k] = list
  return count
end

-- Consume fresh notes stored for path.
function M.take(path)
  if type(path) ~= "string" or path == "" then
    return {}
  end
  local k = key(path)
  local list = pending[k] or {}
  pending[k] = nil
  local now = vim.uv.hrtime()
  local out = {}
  for _, item in ipairs(list) do
    if now - item.at <= ttl_ns then
      table.insert(out, { anchor = item.anchor, note = item.note })
    end
  end
  return out
end

function M._clear()
  pending = {}
end

return M
