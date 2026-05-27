local state = require("codex.state")
local util = require("codex.util")

local M = {}

local decisions = {
  modern = {
    accept = "accept",
    accept_session = "acceptForSession",
    decline = "decline",
    cancel = "cancel",
  },
  legacy = {
    accept = "approved",
    accept_session = "approved_for_session",
    decline = "denied",
    cancel = "abort",
  },
}

local function response_for(proposal, action)
  local decision = decisions[proposal.protocol][action]
  return { decision = decision }
end

local function lines_for(proposal)
  local lines = {
    "# Codex Patch Review",
    "",
    "source: " .. proposal.source,
    "thread: " .. (proposal.thread_id or ""),
  }
  if proposal.turn_id then
    table.insert(lines, "turn: " .. proposal.turn_id)
  end
  if proposal.item_id then
    table.insert(lines, "item: " .. proposal.item_id)
  end
  if proposal.reason then
    table.insert(lines, "reason: " .. proposal.reason)
  end
  if proposal.grant_root then
    table.insert(lines, "grant root: " .. proposal.grant_root)
  end
  table.insert(lines, "")
  table.insert(lines, "Keys: a accept, A accept for session, d decline, c cancel, q close")
  table.insert(lines, "")
  table.insert(lines, "---")

  if not proposal.changes or #proposal.changes == 0 then
    table.insert(lines, "")
    table.insert(
      lines,
      "No patch details are available yet. The app-server request can still be declined or cancelled."
    )
    return lines
  end

  for _, change in ipairs(proposal.changes) do
    table.insert(lines, "")
    table.insert(lines, ("## %s %s"):format(change.kind or change.type or "update", change.path or ""))
    local diff = change.diff or change.unified_diff or change.content or ""
    if diff ~= "" then
      table.insert(lines, "```diff")
      for _, line in ipairs(util.split_lines(diff)) do
        table.insert(lines, line)
      end
      table.insert(lines, "```")
    end
  end
  return lines
end

local function close_window(bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
end

local function submit_decision(proposal, action)
  local rpc = require("codex.rpc")
  local request = state.pop_pending_request(proposal.request_id)
  if not request then
    util.notify("approval request is no longer pending", vim.log.levels.WARN)
    return
  end
  rpc.respond(proposal.request_id, response_for(proposal, action))
  if proposal.bufnr and vim.api.nvim_buf_is_valid(proposal.bufnr) then
    close_window(proposal.bufnr)
  end
  util.notify("patch review: " .. action)
end

local function open_window(bufnr)
  local width = math.max(60, math.floor(vim.o.columns * 0.86))
  local height = math.max(18, math.floor(vim.o.lines * 0.86))
  return vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    title = " Codex Patch Review ",
    title_pos = "center",
  })
end

function M.open(proposal)
  local bufnr = vim.api.nvim_create_buf(false, true)
  proposal.bufnr = bufnr
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, "codex://approval/" .. tostring(proposal.request_id))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_for(proposal))
  vim.bo[bufnr].modifiable = false

  local map = function(lhs, action, desc)
    vim.keymap.set("n", lhs, function()
      submit_decision(proposal, action)
    end, { buffer = bufnr, desc = desc })
  end
  map("a", "accept", "Accept Codex patch")
  map("A", "accept_session", "Accept Codex patches for session")
  map("d", "decline", "Decline Codex patch")
  map("c", "cancel", "Cancel Codex patch")
  vim.keymap.set("n", "q", function()
    close_window(bufnr)
  end, { buffer = bufnr, desc = "Close patch review" })

  open_window(bufnr)
  return bufnr
end

local function modern_proposal(message)
  local params = message.params or {}
  local thread = state.get_thread(params.threadId)
  local item = thread and thread.items[params.itemId] or nil
  return {
    protocol = "modern",
    source = "codex_file_change",
    request_id = message.id,
    thread_id = params.threadId,
    turn_id = params.turnId,
    item_id = params.itemId,
    reason = params.reason,
    grant_root = params.grantRoot,
    changes = item and item.changes or {},
  }
end

local function legacy_changes(file_changes)
  local changes = {}
  for path, change in pairs(file_changes or {}) do
    if change.type == "update" then
      table.insert(changes, {
        path = path,
        kind = "update",
        diff = change.unified_diff,
      })
    elseif change.type == "add" then
      table.insert(changes, {
        path = path,
        kind = "add",
        diff = change.content,
      })
    elseif change.type == "delete" then
      table.insert(changes, {
        path = path,
        kind = "delete",
        diff = change.content,
      })
    end
  end
  return changes
end

local function legacy_proposal(message)
  local params = message.params or {}
  return {
    protocol = "legacy",
    source = "legacy_apply_patch",
    request_id = message.id,
    thread_id = params.conversationId,
    item_id = params.callId,
    reason = params.reason,
    grant_root = params.grantRoot,
    changes = legacy_changes(params.fileChanges),
  }
end

function M.request_approval(message)
  local proposal
  if message.method == "applyPatchApproval" then
    proposal = legacy_proposal(message)
  else
    proposal = modern_proposal(message)
  end
  state.set_pending_request(message.id, proposal)
  return M.open(proposal)
end

return M
