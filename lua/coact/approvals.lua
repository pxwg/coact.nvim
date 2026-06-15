local util = require("coact.util")

local M = {}

local function choose(title, choices, callback)
  vim.ui.select(choices, { prompt = title }, function(choice)
    callback(choice or "cancel")
  end)
end

function M.command(message)
  local params = message.params or {}
  local rpc = require("coact.rpc")
  local title = params.command and ("Run command: " .. params.command) or "Approve Coact command"
  local choices = { "accept", "acceptForSession", "decline", "cancel" }
  if params.availableDecisions and #params.availableDecisions > 0 then
    choices = params.availableDecisions
  end
  choose(title, choices, function(decision)
    if type(decision) == "table" then
      rpc.respond(message.id, { decision = decision })
    else
      rpc.respond(message.id, { decision = decision })
    end
    util.notify("command approval: " .. (type(decision) == "string" and decision or vim.inspect(decision)))
  end)
end

function M.permissions(message)
  local rpc = require("coact.rpc")
  choose("Approve Coact permission request", { "accept", "decline", "cancel" }, function(decision)
    rpc.respond(message.id, { decision = decision })
  end)
end

return M
