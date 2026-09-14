local M = {}
function M.run()
  local history = require("coact.providers.pi_history")
  local pi = require("coact.providers.pi")
  local state = require("coact.state")
  local function entry(id, parent, role, text)
    return {
      id = id,
      parentId = parent,
      type = "message",
      message = { role = role, content = { { type = "text", text = text } } },
    }
  end
  local entries = {
    entry("root", vim.NIL, "user", "Original request"),
    entry("answer", "root", "assistant", "Original answer"),
    {
      id = "compact1",
      parentId = "answer",
      type = "compaction",
      summary = "First summary",
      firstKeptEntryId = "answer",
    },
    entry("branchA", "compact1", "user", "Repeated prompt"),
    entry("branchB", "compact1", "user", "Repeated prompt"),
    entry("answerB", "branchB", "assistant", "Sibling answer must be absent"),
    { id = "summaryA", parentId = "branchA", type = "branch_summary", summary = "Branch summary", fromId = "answerB" },
    entry("answerA", "summaryA", "assistant", "Selected answer"),
    {
      id = "compact2",
      parentId = "answerA",
      type = "compaction",
      summary = "Second summary",
      retainedTail = { { role = "user", content = "Do not duplicate materialized context" } },
    },
  }
  local function project(leaf)
    local messages, err = history.messages({ entries = entries, leafId = leaf })
    assert(messages, err)
    return state.update_thread_from_payload({
      id = "pi:branch-history-test",
      replaceTurns = true,
      turns = pi._turns_from_messages(messages),
    })
  end
  local thread = project("compact2")
  local ids = {}
  for _, id in ipairs(thread.item_order) do
    table.insert(ids, thread.items[id].treeEntryId)
  end
  assert(
    vim.deep_equal(ids, { "root", "answer", "compact1", "branchA", "summaryA", "answerA", "compact2" }),
    vim.inspect(ids)
  )
  assert(
    thread.items[thread.item_order[1]].content[1].text == "Original request",
    "compaction cannot erase old history"
  )
  local stable = thread.item_order[2]
  thread = project("answerB")
  assert(#thread.item_order == 5 and thread.items[thread.item_order[5]].text == "Sibling answer must be absent")
  assert(thread.item_order[2] == stable, "shared ancestor item identity must survive branch switches")
  thread = project("compact2")
  assert(#thread.item_order == 7 and thread.item_order[2] == stable)
  assert(#project(vim.NIL).item_order == 0, "null leaf is an empty branch, not the last appended entry")
  assert(not history.messages({ entries = entries, leafId = "missing" }))
  assert(not history.messages({ entries = { { id = "cycle", parentId = "cycle" } }, leafId = "cycle" }))
  assert(not history.messages({ entries = { { id = "orphan", parentId = "missing" } }, leafId = "orphan" }))
  local messages = assert(history.messages({
    entries = {
      { id = "private", type = "custom", parentId = vim.NIL, data = { secret = true } },
      {
        id = "visible",
        type = "custom_message",
        parentId = "private",
        display = true,
        customType = "notice",
        content = "Visible extension message",
      },
      {
        id = "bash",
        type = "message",
        parentId = "visible",
        message = { role = "bashExecution", command = "pwd", output = "/fixture", exitCode = 0 },
      },
    },
    leafId = "bash",
  }))
  assert(#messages == 2, "extension-private state must not become chat")
  local turns = pi._turns_from_messages(messages)
  assert(turns[1].items[1].type == "piCustomMessage" and turns[1].items[2].type == "commandExecution")

  local held = {}
  local runtime = pi.new_runtime()
  local fake = {
    _request_message = function(method, _, callback)
      if method == "get_state" then
        callback(nil, { sessionId = "history-race" })
      elseif method == "get_session_stats" then
        callback(nil, {})
      elseif method == "get_entries" then
        table.insert(held, callback)
      else
        error("unexpected history RPC: " .. method)
      end
    end,
  }
  local function refresh()
    pi.with_runtime(runtime, function()
      pi._refresh_current_thread(fake, { threadId = "pi:history-race" }, function(err)
        assert(not err)
      end)
    end)
  end
  refresh()
  refresh()
  pi.with_runtime(runtime, function()
    held[2](nil, { entries = entries, leafId = "answerB" })
    held[1](nil, { entries = entries, leafId = "compact2" })
  end)
  local latest = state.get_thread("pi:history-race")
  assert(
    latest.items[latest.item_order[#latest.item_order]].treeEntryId == "answerB",
    "older snapshot cannot overwrite a newer branch selection"
  )
end
return M
