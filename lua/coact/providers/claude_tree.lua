local config = require("coact.config")
local M = {}
function M.open(params, callback)
  local rpc = require("coact.providers.claude_rpc")
  local history = require("coact.providers.claude_history")
  local client = rpc.clients[params.threadId]
  if client and (client.turn or client.setting_model or client.rewinding or #(client.queue or {}) > 0) then
    callback({ message = "Stop generation and queued follow-ups before opening rewind history" })
    return
  end
  local snapshot, err = rpc.snapshot(params.threadId)
  if not snapshot then
    callback({ message = err or "No saved Claude history yet" })
    return
  end
  local payload, owners = history.tree(snapshot)
  if params.initialSelectedId and not owners[params.initialSelectedId] then
    callback({ message = "This message is not in saved history yet; retry after the turn finishes" })
    return
  end
  payload.initialSelectedId = params.initialSelectedId
  local finished = false
  local function done(e, r)
    if finished then
      return
    end
    finished = true
    callback(e, r)
  end
  return require("coact.providers.pi_tree").select(
    { options = { payload } },
    config.bind(function(choice)
      if not choice then
        done(nil, { treeAction = { __coactTreeAction = true, action = "cancel" } })
        return
      end
      if type(choice) == "table" then
        if choice.action == "reveal" then
          done(nil, { treeAction = choice })
        else
          done({ message = choice.reason or "Entry is not visible in this transcript; Enter explicitly rewinds" })
        end
        return
      end
      local source = owners[choice]
      local target, target_err = history.read(source)
      if not target then
        done({ message = target_err })
        return
      end
      local checkpoint
      checkpoint, target_err = history.checkpoint(target, choice)
      if not checkpoint then
        done({ message = target_err })
        return
      end
      local label = checkpoint.draft and "Rewind before this user message" or "Rewind after this assistant response"
      vim.ui.select(
        { "Rewind conversation into a new branch (files unchanged)", "Cancel" },
        {
          prompt = label .. "; original history is preserved:",
        },
        config.bind(function(_, index)
          if index ~= 1 then
            done(nil, { treeAction = { __coactTreeAction = true, action = "cancel" } })
            return
          end
          rpc.rewind(params.threadId, choice, done, source)
        end)
      )
    end),
    {
      thread_id = params.threadId,
      title = "Claude rewind history",
      action_label = "rewind",
      search_prompt = "Claude history search: ",
      filetype = "coact-claude-tree",
      reveal_only = true,
    }
  )
end
return M
