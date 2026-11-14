-- Control commands: /model and /thinking change the pinned thread's Pi
-- settings. They run when their completion is accepted in a card (leaving
-- no text) or as :CoactMode model / thinking. Pi records the choice in the
-- thread's session; each answer shows the model and thinking level it was
-- written with.
local run = require("coact.mode.run")
local workspace = require("coact.mode.workspace")

local M = {}

M.list = {
  { name = "model", description = "Choose the model of this thread" },
  { name = "thinking", description = "Choose the thinking level of this thread" },
}

local function notify(message, level)
  vim.notify("Coact mode: " .. message, level or vim.log.levels.INFO)
end

-- The pinned thread's Pi, started if needed: callback(client).
local function with_pi(bufnr, callback)
  if run.busy() then
    return notify("wait for the running call, or stop it first", vim.log.levels.WARN)
  end
  run.pinned(bufnr, function(err, card)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    local client, start_err = run.ensure(workspace.root(card.bufnr), card.thread)
    if not client then
      return notify("could not start Pi: " .. tostring(start_err), vim.log.levels.ERROR)
    end
    client:request("get_state", {}, function(_, state)
      callback(client, state or {})
    end)
  end)
end

local function model_name(model)
  return ("%s/%s"):format(model.provider, model.id)
end

function M.model(bufnr)
  with_pi(bufnr, function(client, state)
    client:request("get_available_models", {}, function(err, data)
      if err then
        return notify(err, vim.log.levels.ERROR)
      end
      local models = data and data.models or {}
      if #models == 0 then
        return notify("Pi offers no models; log in or configure a provider", vim.log.levels.WARN)
      end
      local current = state.model and model_name(state.model)
      vim.ui.select(models, {
        prompt = "Model of this thread",
        format_item = function(model)
          local name = model_name(model)
          return (name == current and "● " or "  ")
            .. name
            .. (model.name and model.name ~= model.id and ("  " .. model.name) or "")
        end,
      }, function(model)
        if not model then
          return
        end
        client:request("set_model", { provider = model.provider, modelId = model.id }, function(set_err)
          if set_err then
            return notify(set_err, vim.log.levels.ERROR)
          end
          notify("model " .. model_name(model))
        end)
      end)
    end)
  end)
end

function M.thinking(bufnr)
  with_pi(bufnr, function(client, state)
    client:request("get_available_thinking_levels", {}, function(err, data)
      if err then
        return notify(err, vim.log.levels.ERROR)
      end
      local levels = data and data.levels or {}
      if #levels <= 1 then
        return notify("this thread's model has no thinking levels", vim.log.levels.WARN)
      end
      vim.ui.select(levels, {
        prompt = "Thinking level of this thread",
        format_item = function(level)
          return (level == state.thinkingLevel and "● " or "  ") .. level
        end,
      }, function(level)
        if not level then
          return
        end
        client:request("set_thinking_level", { level = level }, function(set_err)
          if set_err then
            return notify(set_err, vim.log.levels.ERROR)
          end
          notify("thinking " .. level)
        end)
      end)
    end)
  end)
end

--- Run a control command for the thread of bufnr.
function M.run(name, bufnr)
  local fn = M[name]
  if type(fn) ~= "function" or name == "run" then
    return notify("unknown command /" .. tostring(name), vim.log.levels.ERROR)
  end
  fn(bufnr)
end

return M
