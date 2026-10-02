-- Adapter-scoped transport state and asynchronous callback ownership.
local config = require("coact.config")
local M = {}

function M.state(initial, shared_keys)
  local states, methods, shared = {}, {}, {}
  for _, key in ipairs(shared_keys or {}) do
    shared[key] = true
  end
  local function current()
    local ctx = config.context()
    if not states[ctx] then
      states[ctx] = vim.deepcopy(initial)
    end
    return states[ctx]
  end
  methods._each_context = function(callback)
    for ctx in pairs(states) do
      config.with_context(ctx, callback)
    end
  end
  return setmetatable({}, {
    __index = function(_, key)
      if shared[key] then
        return initial[key]
      end
      if methods[key] ~= nil then
        return methods[key]
      end
      return current()[key]
    end,
    __newindex = function(_, key, value)
      if shared[key] then
        initial[key] = value
      elseif type(value) == "function" or methods[key] ~= nil then
        methods[key] = value
      else
        current()[key] = value
      end
    end,
  })
end

function M.schedule(callback)
  vim.schedule(config.bind(callback))
end

function M.defer(callback, delay)
  return vim.defer_fn(config.bind(callback), delay)
end

function M.jobstart(command, opts)
  for _, key in ipairs({ "on_stdout", "on_stderr", "on_exit" }) do
    if opts[key] then
      opts[key] = config.bind(opts[key])
    end
  end
  return vim.fn.jobstart(command, opts)
end

return M
