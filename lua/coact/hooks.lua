local M = {}

local listeners = {}

local function autocmd_patterns(event)
  local legacy = "Coact" .. event:gsub("^%l", string.upper)
  local camel = "Coact" .. event:gsub("(^%l)", string.upper):gsub("_(%l)", function(char)
    return char:upper()
  end)
  if camel == legacy then
    return { legacy }
  end
  return { camel, legacy }
end

function M.on(event, callback)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], callback)
  return function()
    for index, existing in ipairs(listeners[event] or {}) do
      if existing == callback then
        table.remove(listeners[event], index)
        return
      end
    end
  end
end

function M.emit(event, payload)
  for _, callback in ipairs(listeners[event] or {}) do
    local ok, err = pcall(callback, payload)
    if not ok then
      vim.schedule(function()
        vim.notify(("coact.nvim hook %s failed: %s"):format(event, err), vim.log.levels.ERROR)
      end)
    end
  end
  for _, pattern in ipairs(autocmd_patterns(event)) do
    vim.api.nvim_exec_autocmds("User", {
      pattern = pattern,
      data = payload,
    })
  end
end

return M
