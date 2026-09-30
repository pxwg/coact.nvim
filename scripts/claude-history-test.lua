-- Run phases 1/2/3 in separate remote Neovim processes (see remote runner).
local root = assert(vim.env.COACT_HISTORY_ROOT, "COACT_HISTORY_ROOT required")
local phase = tonumber(vim.env.COACT_HISTORY_PHASE or "1")
local live = vim.env.COACT_CLAUDE_LIVE
local command = live and { live } or { "node", vim.fn.getcwd() .. "/scripts/claude-rpc-fixture.mjs" }
local workspace = root .. "/workspace"
vim.fn.mkdir(workspace, "p")
require("coact").setup({
  provider = "claude",
  providers = {
    claude = {
      command = command,
      config_dir = root .. "/config",
      model = live and "deepseek-chat" or "fixture",
    },
  },
})
local rpc, state = require("coact.rpc"), require("coact.state")
local back, hist = require("coact.providers.claude_rpc"), require("coact.providers.claude_history")
local coact, buffers = require("coact"), require("coact.buffers")
local manifest_path = root .. "/manifest.json"
local function req(method, params)
  local done, err, result = false, nil, nil
  rpc.request(method, params, function(e, r)
    err, result, done = e, r, true
  end)
  assert(
    vim.wait(65000, function()
      return done
    end, 10),
    method .. " timeout"
  )
  assert(not err, method .. ": " .. vim.inspect(err))
  return result
end
local function settled(id)
  assert(
    vim.wait(180000, function()
      local c = back.clients[id]
      return c and not c.turn and #c.queue == 0
    end, 10),
    "generation timeout"
  )
end
local function prompt(id, text)
  return req("turn/start", { threadId = id, input = { { type = "text", text = text } } }).turn
end
local function text_of(thread)
  local parts = {}
  for _, id in ipairs(thread.item_order) do
    local item = thread.items[id]
    if item.type == "agentMessage" then
      parts[#parts + 1] = item.text or ""
    end
  end
  return table.concat(parts, "\n")
end
local function last_text(thread)
  for i = #thread.item_order, 1, -1 do
    local item = thread.items[thread.item_order[i]]
    if item.type == "agentMessage" then
      return item.text or ""
    end
  end
  return ""
end
local function save(data)
  vim.fn.writefile({ vim.json.encode(data) }, manifest_path)
end
local function load()
  return vim.json.decode(table.concat(vim.fn.readfile(manifest_path), "\n"))
end
local function resume(id)
  coact.resume(id)
  assert(
    vim.wait(65000, function()
      return back.is_initialized(id) and state.get_thread(id) and state.get_thread(id).winid
    end, 10),
    "resume UI timeout"
  )
  return state.get_thread(id)
end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
end
local function rewind_ui(id, entry_id)
  local thread = state.get_thread(id)
  vim.api.nvim_set_current_win(thread.winid)
  vim.cmd("stopinsert")
  assert(buffers.reveal_tree_entry(id, entry_id))
  keys("gT")
  assert(vim.bo.filetype == "coact-claude-tree", "gT should open Claude history")
  local old_select = vim.ui.select
  local confirmed = false
  vim.ui.select = function(items, opts, choose)
    assert(opts.prompt:find("original history is preserved", 1, true))
    confirmed = true
    choose(items[1], 1)
  end
  keys("<CR>")
  vim.ui.select = old_select
  assert(confirmed, "rewind must require confirmation")
  assert(
    vim.wait(65000, function()
      return state.active_thread_id ~= id and back.is_initialized(state.active_thread_id)
    end, 10),
    "rewind branch timeout"
  )
  return state.get_thread(state.active_thread_id)
end
local function run()
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "history test source" })
  vim.api.nvim_set_current_buf(source)
  rpc.start()
  if phase == 1 then
    vim.fn.writefile({ "FILES MUST STAY UNCHANGED" }, workspace .. "/sentinel.txt")
    local t = req("thread/start", { cwd = workspace }).thread
    local thread = state.update_thread_from_payload(t)
    require("coact.context").capture_thread_buffer(thread, source, vim.api.nvim_get_current_win())
    local first =
      prompt(t.id, "The current test marker is APPLE. Reply with exactly FIRST. Do not use tools or store files.")
    local queued
    coact.submit_text(
      "Change the current test marker to BANANA. Reply with exactly SECOND. Do not use tools or store files.",
      t.id,
      {
        on_success = function(turn)
          queued = turn
        end,
      }
    )
    assert(queued and #back.clients[t.id].queue == 1, "busy submission must queue")
    assert(state.get_thread_pending_requests(thread)[1].streaming_behavior == "followUp")
    local otherdir = root .. "/other"
    vim.fn.mkdir(otherdir, "p")
    local other = req("thread/start", { cwd = otherdir }).thread
    state.update_thread_from_payload(other)
    prompt(other.id, "Reply with exactly OTHER. Do not use tools.")
    settled(t.id)
    settled(other.id)
    assert(thread.turns[first.id].status == "completed" and thread.turns[queued.id].status == "completed")
    assert(#state.get_thread_pending_requests(thread) == 0 and rpc.pending_count(t.id) == 0)
    if live then
      assert(text_of(thread):find("FIRST", 1, true) and text_of(thread):find("SECOND", 1, true))
    end
    local snapshot = assert(hist.read(t.id))
    local disk_text = {}
    for _, turn in ipairs(hist.thread(snapshot).turns) do
      for _, item in ipairs(turn.items) do
        if item.type == "agentMessage" then
          disk_text[#disk_text + 1] = item.text
        end
      end
    end
    assert(
      text_of(thread) == table.concat(disk_text, "\n"),
      "streamed text must match native persisted history exactly"
    )
    local users, answers = {}, {}
    for _, e in ipairs(snapshot.chain) do
      if hist.user(e) then
        users[#users + 1] = e.uuid
      elseif e.type == "assistant" and hist.text(e.message.content) ~= "" then
        answers[#answers + 1] = e.uuid
      end
    end
    assert(#users == 2 and #answers >= 2)
    assert(users[1] == first.user_uuid, "CLI must preserve the outgoing user checkpoint UUID")
    local otherturn = prompt(other.id, "Reply with exactly CANCEL_TEST. Do not use tools.")
    local cancelled
    coact.submit_text("must never be sent", other.id, {
      on_success = function(turn)
        cancelled = turn
      end,
    })
    assert(cancelled)
    assert(#back.clients[other.id].queue == 1)
    req("turn/interrupt", { threadId = other.id, turnId = otherturn.id })
    settled(other.id)
    assert(state.get_thread(other.id).turns[cancelled.id].status == "interrupted")
    assert(#back.clients[other.id].queue == 0 and #state.get_thread_pending_requests(state.get_thread(other.id)) == 0)
    local list = req("thread/list", { cwd = workspace }).data
    assert(#list == 1 and list[1].id == t.id, "history list must filter by source cwd")
    save({
      id = t.id,
      user = users[2],
      first_answer = answers[1],
      last_answer = answers[#answers],
      transcript = text_of(thread),
    })
  elseif phase == 2 then
    local m = load()
    local list = req("thread/list", { cwd = workspace }).data
    assert(#list == 1 and list[1].id == m.id, "disk history must be discoverable in a fresh Neovim")
    local thread = resume(m.id)
    assert(#thread.turn_order == 2, "resume should hydrate both disk turns")
    assert(text_of(thread) == m.transcript, "disk restore must retain the complete transcript")
    assert(thread.context_bufnr == source, "resume must keep source targeting")
    vim.api.nvim_set_current_win(thread.winid)
    assert(buffers.reveal_tree_entry(m.id, m.user))
    keys("gT")
    assert(vim.bo.filetype == "coact-claude-tree")
    local maps = vim.api.nvim_buf_get_keymap(0, "n")
    assert(vim.iter(maps):any(function(map)
      return map.lhs == "r"
    end))
    keys("r")
    assert(state.active_thread_id == m.id and rpc.client_count() == 1, "reveal must not rewind")
    keys("<Esc><Esc>")
    assert(vim.bo.filetype == "coact-claude-tree", "double escape must share history UI")
    keys("q")
    local branch = rewind_ui(m.id, m.user)
    assert(branch.id ~= m.id and branch.context_bufnr == source)
    assert(#branch.turn_order == 1, "rewind before user should drop that user's turn from the branch")
    assert(
      table.concat(branch.draft_lines, "\n"):find("BANANA", 1, true),
      "rewind user text should become an editable draft"
    )
    assert(vim.fn.readfile(workspace .. "/sentinel.txt")[1] == "FILES MUST STAY UNCHANGED")
    assert(#hist.read(m.id).chain >= 4, "original conversation must remain intact")
    assert(hist.read(branch.id).pending_fork, "fork before first prompt must be persisted as branch metadata")
    m.branch = branch.id
    save(m)
  else
    local m = load()
    local thread = resume(m.branch)
    assert(#thread.turn_order == 1, "pending fork must resume after Neovim restart")
    prompt(m.branch, "What is the current test marker? Reply only with the marker. Do not use tools or store files.")
    settled(m.branch)
    if live then
      assert(
        last_text(thread):find("APPLE", 1, true) and not last_text(thread):find("BANANA", 1, true),
        "rewind must remove BANANA from backend context"
      )
    end
    if live then
      req("thread/compact/start", { threadId = m.branch })
      settled(m.branch)
      local restored = req("thread/rewind", { threadId = m.branch, entryId = m.first_answer }).thread
      state.update_thread_from_payload(restored)
      prompt(
        restored.id,
        "What is the current test marker? Reply only with the marker. Do not use tools or store files."
      )
      settled(restored.id)
      assert(
        last_text(state.get_thread(restored.id)):find("APPLE", 1, true),
        "rewind must work across a native compaction boundary"
      )
    end
    local snapshot = assert(hist.read(m.branch))
    assert(not snapshot.pending_fork)
    local tree, owners = hist.tree(snapshot)
    assert(owners[m.last_answer] == hist.uuid(m.id), "tree must retain the original branch")
    -- Navigate a different saved branch with the same tree picker. This entry
    -- is intentionally absent from the current transcript, so r cannot jump.
    local completed = false
    req("thread/read", { threadId = m.branch })
    local choice_buf
    require("coact.providers.claude_tree").open(
      { threadId = m.branch, initialSelectedId = m.last_answer },
      function(err, result)
        assert(not err, vim.inspect(err))
        local restored = state.update_thread_from_payload(result.thread)
        m.restored = restored.id
        completed = true
      end
    )
    choice_buf = vim.api.nvim_get_current_buf()
    assert(vim.bo[choice_buf].filetype == "coact-claude-tree" and #tree.nodes > 0)
    local old_select = vim.ui.select
    vim.ui.select = function(items, _, choose)
      choose(items[1], 1)
    end
    keys("<CR>")
    vim.ui.select = old_select
    assert(vim.wait(65000, function()
      return completed
    end, 10))
    prompt(m.restored, "What is the current test marker? Reply only with the marker. Do not use tools or store files.")
    settled(m.restored)
    if live then
      assert(
        last_text(state.get_thread(m.restored)):find("BANANA", 1, true),
        "rewind to original later response must restore that context"
      )
    end
    assert(vim.fn.readfile(workspace .. "/sentinel.txt")[1] == "FILES MUST STAY UNCHANGED")
  end
  print((live and "Claude LIVE" or "Claude fixture") .. " history/queue/tree phase " .. phase .. ": PASS")
end
local ok, err = xpcall(run, debug.traceback)
rpc.stop()
if not ok then
  error(err)
end
vim.cmd("qa!")
