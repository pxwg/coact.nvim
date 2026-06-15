local config = require("coact.config")
local context = require("coact.context")
local state = require("coact.state")
local util = require("coact.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("coact.patch_review")

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

local function object(value)
  value = util.value(value)
  return type(value) == "table" and value or {}
end

local function text(value)
  value = util.value(value)
  if value == nil or value == "" then
    return nil
  end
  return tostring(value)
end

local function first_text(...)
  for index = 1, select("#", ...) do
    local value = text(select(index, ...))
    if value then
      return value
    end
  end
end

local function normalized_change(change)
  change = object(change)
  return {
    kind = first_text(change.kind, change.type) or "update",
    path = text(change.path) or "",
    diff = first_text(change.diff, change.unified_diff, change.content) or "",
  }
end

local function normalized_changes(changes)
  changes = util.value(changes)
  if type(changes) ~= "table" then
    return {}
  end
  local normalized = {}
  for _, change in ipairs(changes) do
    table.insert(normalized, normalized_change(change))
  end
  return normalized
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = tostring(line or ""):match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  return {
    old_start = tonumber(old_start),
    old_count = tonumber(old_count ~= "" and old_count or "1"),
    new_start = tonumber(new_start),
    new_count = tonumber(new_count ~= "" and new_count or "1"),
  }
end

local function document_for(proposal)
  local lines = {}
  local anchors = {}

  local function push(line)
    table.insert(lines, line)
    return #lines
  end

  push("# Coact Patch Review")
  push("")
  local source = text(proposal.source) or "unknown"
  push("source: " .. source)
  push("thread: " .. (text(proposal.thread_id) or ""))
  local turn_id = text(proposal.turn_id)
  if turn_id then
    push("turn: " .. turn_id)
  end
  local item_id = text(proposal.item_id)
  if item_id then
    push("item: " .. item_id)
  end
  local reason = text(proposal.reason)
  if reason then
    push("reason: " .. reason)
  end
  local grant_root = text(proposal.grant_root)
  if grant_root then
    push("grant root: " .. grant_root)
  end
  push("")
  local accept_session = "A accept for session"
  if source == "nvim_apply_patch" then
    accept_session = "A use Neovim auto-apply for this session"
  end
  push(("Keys: a accept, %s, d decline, c cancel, [c/]c jump, <CR>/o open file, q close"):format(accept_session))
  push("")
  push("---")

  local changes = normalized_changes(proposal.changes)
  if #changes == 0 then
    push("")
    push("No patch details are available yet. The app-server request can still be declined or cancelled.")
    return lines, anchors
  end

  for index, change in ipairs(changes) do
    local kind = change.kind
    local path = change.path
    push("")
    local file_lnum = push(("## %s %s"):format(kind, path))
    local file_anchor = {
      type = "file",
      lnum = file_lnum,
      change_index = index,
      path = path,
      kind = kind,
    }
    local diff = change.diff
    if diff ~= "" then
      local hunk_count = 0
      push("```diff")
      for _, line in ipairs(util.split_lines(diff)) do
        local lnum = push(line)
        local hunk = parse_hunk_header(line)
        if hunk then
          hunk_count = hunk_count + 1
          table.insert(
            anchors,
            vim.tbl_extend("force", file_anchor, {
              type = "hunk",
              lnum = lnum,
              hunk_index = hunk_count,
              old_start = hunk.old_start,
              old_count = hunk.old_count,
              new_start = hunk.new_start,
              new_count = hunk.new_count,
            })
          )
        end
      end
      push("```")
      if hunk_count == 0 then
        table.insert(anchors, file_anchor)
      end
    else
      table.insert(anchors, file_anchor)
    end
  end
  return lines, anchors
end

local function close_window(bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
end

local function jump_to_anchor(proposal, direction)
  local anchors = proposal.anchors or {}
  if #anchors == 0 then
    util.notify("patch review has no navigable changes", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil
  if direction > 0 then
    for _, anchor in ipairs(anchors) do
      if anchor.lnum > cursor then
        target = anchor
        break
      end
    end
    target = target or anchors[1]
  else
    for index = #anchors, 1, -1 do
      if anchors[index].lnum < cursor then
        target = anchors[index]
        break
      end
    end
    target = target or anchors[#anchors]
  end

  vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
end

local function anchor_under_cursor(proposal)
  local anchors = proposal.anchors or {}
  if #anchors == 0 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local target = anchors[1]
  for _, anchor in ipairs(anchors) do
    if anchor.lnum > cursor then
      break
    end
    target = anchor
  end
  return target
end

local function absolute_path(proposal, path)
  path = text(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fn.expand(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(text(proposal.cwd) or config.cwd(), path))
end

local function target_window(proposal)
  local thread = state.get_thread(text(proposal.thread_id))
  local context_winid = thread and thread.context_winid
  if
    context_winid
    and vim.api.nvim_win_is_valid(context_winid)
    and vim.api.nvim_win_get_config(context_winid).relative == ""
    and context.is_context_buffer(vim.api.nvim_win_get_buf(context_winid))
  then
    return context_winid
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if
      vim.api.nvim_win_get_config(winid).relative == "" and context.is_context_buffer(vim.api.nvim_win_get_buf(winid))
    then
      return winid
    end
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(winid).relative == "" then
      return winid
    end
  end
end

local function open_anchor(proposal)
  local anchor = anchor_under_cursor(proposal)
  local path = anchor and absolute_path(proposal, anchor.path)
  if not path then
    util.notify("no file path under cursor", vim.log.levels.WARN)
    return
  end

  local winid = target_window(proposal)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
  else
    vim.cmd("botright split")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local line_count = vim.api.nvim_buf_line_count(0)
  local lnum = math.max(1, math.min(line_count, anchor.old_start or anchor.new_start or 1))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

local function apply_anchor_marks(bufnr, anchors)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, anchor in ipairs(anchors or {}) do
    local label = anchor.type == "hunk" and ("hunk -> L" .. tostring(anchor.old_start or anchor.new_start or 1))
      or "file"
    vim.api.nvim_buf_set_extmark(bufnr, namespace, anchor.lnum - 1, 0, {
      virt_text = { { label, "Comment" } },
      virt_text_pos = "right_align",
    })
  end
end

local function submit_decision(proposal, action)
  if proposal.on_decision then
    local ok, err = pcall(proposal.on_decision, action, proposal)
    if not ok then
      util.notify("patch review decision failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    proposal._resolved = true
    if proposal.bufnr and vim.api.nvim_buf_is_valid(proposal.bufnr) then
      close_window(proposal.bufnr)
    end
    util.notify("patch review: " .. action)
    return
  end

  local rpc = require("coact.rpc")
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
    title = " Coact Patch Review ",
    title_pos = "center",
  })
end

function M.open(proposal)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines, anchors = document_for(proposal)
  proposal.anchors = anchors or {}
  proposal.bufnr = bufnr
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, "coact://approval/" .. tostring(proposal.request_id))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].coact_patch_review_anchors = proposal.anchors
  apply_anchor_marks(bufnr, proposal.anchors)
  vim.bo[bufnr].modifiable = false

  local map = function(lhs, action, desc)
    vim.keymap.set("n", lhs, function()
      submit_decision(proposal, action)
    end, { buffer = bufnr, desc = desc })
  end
  map("a", "accept", "Accept Coact patch")
  map("A", "accept_session", "Accept Coact patches for session")
  map("d", "decline", "Decline Coact patch")
  map("c", "cancel", "Cancel Coact patch")
  vim.keymap.set("n", "]c", function()
    jump_to_anchor(proposal, 1)
  end, { buffer = bufnr, desc = "Next Coact patch hunk" })
  vim.keymap.set("n", "[c", function()
    jump_to_anchor(proposal, -1)
  end, { buffer = bufnr, desc = "Previous Coact patch hunk" })
  vim.keymap.set("n", "<CR>", function()
    open_anchor(proposal)
  end, { buffer = bufnr, desc = "Open Coact patch file" })
  vim.keymap.set("n", "o", function()
    open_anchor(proposal)
  end, { buffer = bufnr, desc = "Open Coact patch file" })
  vim.keymap.set("n", "q", function()
    if proposal.on_close and not proposal._resolved then
      local ok, err = pcall(proposal.on_close, proposal)
      if not ok then
        util.notify("patch review close hook failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
    close_window(bufnr)
  end, { buffer = bufnr, desc = "Close patch review" })

  open_window(bufnr)
  return bufnr
end

local function modern_proposal(message)
  local params = object(message.params)
  local thread_id = text(params.threadId)
  local item_id = text(params.itemId)
  local thread = state.get_thread(thread_id)
  local item = thread and item_id and thread.items[item_id] or nil
  return {
    protocol = "modern",
    source = "codex_file_change",
    request_id = message.id,
    thread_id = thread_id,
    turn_id = text(params.turnId),
    item_id = item_id,
    cwd = thread and thread.cwd,
    reason = text(params.reason),
    grant_root = text(params.grantRoot),
    changes = normalized_changes(item and item.changes),
  }
end

local function legacy_changes(file_changes)
  local changes = {}
  file_changes = util.value(file_changes)
  if type(file_changes) ~= "table" then
    return changes
  end
  for path, change in pairs(file_changes) do
    change = object(change)
    path = text(path) or ""
    local change_type = text(change.type)
    if change_type == "update" then
      table.insert(changes, {
        path = path,
        kind = "update",
        diff = first_text(change.unified_diff, change.diff, change.content) or "",
      })
    elseif change_type == "add" then
      table.insert(changes, {
        path = path,
        kind = "add",
        diff = first_text(change.content, change.unified_diff, change.diff) or "",
      })
    elseif change_type == "delete" then
      table.insert(changes, {
        path = path,
        kind = "delete",
        diff = first_text(change.content, change.unified_diff, change.diff) or "",
      })
    end
  end
  return changes
end

local function legacy_proposal(message)
  local params = object(message.params)
  return {
    protocol = "legacy",
    source = "legacy_apply_patch",
    request_id = message.id,
    thread_id = text(params.conversationId),
    item_id = text(params.callId),
    cwd = text(params.cwd),
    reason = text(params.reason),
    grant_root = text(params.grantRoot),
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
  local ok, bufnr = pcall(M.open, proposal)
  if not ok then
    local rpc = require("coact.rpc")
    local responded = pcall(rpc.respond, proposal.request_id, response_for(proposal, "cancel"))
    local suffix = responded and "approval cancelled" or "approval could not be cancelled"
    util.notify("patch review failed: " .. tostring(bufnr) .. "; " .. suffix, vim.log.levels.ERROR)
    return nil
  end
  state.set_pending_request(message.id, proposal)
  return bufnr
end

M._document = document_for
M._parse_hunk_header = parse_hunk_header

return M
