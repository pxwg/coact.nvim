local M = {}

local listeners = {}

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
        vim.notify(("codex.nvim hook %s failed: %s"):format(event, err), vim.log.levels.ERROR)
      end)
    end
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "Codex" .. event:gsub("^%l", string.upper),
    data = payload,
  })
end

return M
