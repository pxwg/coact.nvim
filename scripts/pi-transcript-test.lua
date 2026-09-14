-- Shared by headless smoke and the fixed Kitty/RPC UI fixture.
local M = {}

function M.run()
  local pi = require("coact.providers.pi")
  local state = require("coact.state")
  local render = require("coact.ui.render")
  local runtime = pi.new_runtime()
  local id = "pi:transcript-regression"
  runtime.bound_thread_id = id
  local thread = state.update_thread_from_payload({ id = id, replaceTurns = true })
  local function send(event)
    pi.with_runtime(runtime, function()
      local decoded = pi.decode_notification(event)
      if decoded and decoded.kind then
        require("coact.core").handle_notification(decoded.message)
      else
        for _, entry in ipairs(decoded or {}) do
          require("coact.core").handle_notification(entry.message)
        end
      end
    end)
  end
  local function update(event)
    send({ type = "message_update", assistantMessageEvent = event })
  end
  local function roles()
    local out = {}
    for _, item_id in ipairs(thread.item_order) do
      table.insert(out, thread.items[item_id].type)
    end
    return table.concat(out, ",")
  end
  send({ type = "turn_start" })
  send({ type = "message_start", message = { role = "user", content = "Inspect the transcript" } })
  send({ type = "message_start", message = { role = "assistant", content = {} } })
  update({ type = "thinking_start", contentIndex = 0 })
  update({ type = "thinking_delta", contentIndex = 0, delta = "Check source order" })
  update({ type = "text_start", contentIndex = 1 })
  update({ type = "text_delta", contentIndex = 1, delta = "Before tool" })
  update({ type = "toolcall_start", contentIndex = 2, id = "transcript-call", toolName = "read" })
  update({ type = "toolcall_delta", contentIndex = 2, delta = '{"path":' })
  assert(thread.items["transcript-call"].partialJson == '{"path":', "modern RPC must render partial arguments")
  update({ type = "toolcall_delta", contentIndex = 2, delta = '"README.md"}' })
  assert(thread.items["transcript-call"].arguments.path == "README.md")
  -- Deliberately deliver a later slot before an earlier one. Placement must be
  -- a property of contentIndex, not event arrival or tool execution timing.
  update({ type = "text_delta", contentIndex = 4, delta = "After tool" })
  update({ type = "thinking_delta", contentIndex = 3, delta = "A second thought" })
  assert(roles() == "userMessage,reasoning,agentMessage,dynamicToolCall,reasoning,agentMessage", roles())
  local assistant = {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "Check source order" },
      { type = "text", text = "Before tool" },
      { type = "toolCall", id = "transcript-call", name = "read", arguments = { path = "README.md" } },
      { type = "thinking", thinking = "A second thought" },
      { type = "text", text = "After tool" },
    },
  }
  update({ type = "toolcall_end", contentIndex = 2, toolCall = assistant.content[3] })
  assert(thread.items["transcript-call"].status == "running", "argument completion is not execution completion")
  send({ type = "message_end", message = assistant })
  assert(thread.items["transcript-call"].completed ~= true, "assistant completion cannot complete tool execution")
  send({
    type = "tool_execution_start",
    toolCallId = "transcript-call",
    toolName = "read",
    args = { path = "README.md" },
  })
  send({
    type = "tool_execution_end",
    toolCallId = "transcript-call",
    toolName = "read",
    isError = true,
    result = { content = { { type = "text", text = "Permission denied" } } },
  })
  send({ type = "message_end", message = assistant })
  assert(
    thread.items["transcript-call"].status == "error",
    "authoritative message replay must retain execution failure"
  )
  -- A second assistant message can share a backend turn. Replaying history in
  -- between must not replace the active stream's slot/tool registry.
  pi.with_runtime(runtime, function()
    pi._turns_from_messages({ assistant }, id)
  end)
  send({ type = "message_start", message = { role = "assistant", content = {} } })
  update({ type = "text_delta", contentIndex = 0, delta = "Distinct assistant message" })
  send({
    type = "message_end",
    message = { role = "assistant", content = { { type = "text", text = "Distinct assistant message" } } },
  })
  assert(#thread.item_order == 7, "assistant messages must not overwrite equal content indexes")
  assert(thread.items[thread.item_order[3]].text == "Before tool")
  assert(thread.items["transcript-call"].status == "error")
  send({
    type = "message_start",
    message = { role = "branchSummary", summary = "Branch checkpoint", fromId = vim.NIL, timestamp = vim.NIL },
  })
  send({
    type = "message_start",
    message = { role = "compactionSummary", summary = "Compaction checkpoint", tokensBefore = vim.NIL },
  })
  send({ type = "message_start", message = { role = "user", content = "Continue after checkpoint" } })
  send({ type = "message_start", message = { role = "assistant", content = {} } })
  update({ type = "thinking_start", contentIndex = 0 })
  update({ type = "thinking_delta", contentIndex = 0, delta = vim.NIL })
  update({ type = "text_delta", contentIndex = 1, delta = "Final answer" })
  local final = {
    role = "assistant",
    content = { { type = "thinking", thinking = vim.NIL }, { type = "text", text = "Final answer" } },
  }
  send({ type = "message_end", message = final })
  send({ type = "turn_end", message = final })

  local before = {}
  for _, item_id in ipairs(thread.item_order) do
    if thread.items[item_id].type == "compactionSummary" then
      before = {}
    end
    table.insert(before, thread.items[item_id].type)
  end
  local after = {}
  for _, block in ipairs(render.select_render_tree(thread)) do
    if block.type == "ActivitySummaryBlock" then
      for _, child in ipairs(block.children) do
        table.insert(after, child.raw.type)
      end
    else
      table.insert(after, block.raw.type)
    end
  end
  assert(vim.deep_equal(before, after), "render tree must preserve the exact transcript order")

  local history = pi._turns_from_messages({
    { role = "user", content = "History" },
    assistant,
    {
      role = "toolResult",
      toolCallId = "transcript-call",
      toolName = "read",
      isError = true,
      content = { { type = "text", text = "Permission denied" } },
    },
    { role = "branchSummary", summary = "Boundary" },
    { role = "assistant", content = { { type = "text", text = "After boundary" } } },
  }, "pi:transcript-history")
  local history_thread =
    state.update_thread_from_payload({ id = "pi:transcript-history", replaceTurns = true, turns = history })
  assert(#history_thread.item_order == 8, "tool results must update the call slot, not append duplicate items")
  local call = history_thread.items["transcript-call"]
  assert(call.arguments.path == "README.md" and call.status == "error" and call.output == "Permission denied")
  -- Activity cannot jump over a summary to be folded under a later response.
  local boundary = state.update_thread_from_payload({
    id = "pi:transcript-boundary",
    replaceTurns = true,
    turns = pi._turns_from_messages({
      { role = "assistant", content = { { type = "thinking", thinking = "Before checkpoint" } } },
      { role = "compactionSummary", summary = "Checkpoint" },
      { role = "assistant", content = { { type = "text", text = "After checkpoint" } } },
    }),
  })
  local blocks = render.select_render_tree(boundary)
  assert(#blocks == 2 and blocks[1].type == "CompactionSummaryBlock" and blocks[2].type == "AssistantBlock")
  -- Rewritten and empty cumulative progress must replace, never append.
  send({ type = "tool_execution_start", toolCallId = "rewrite-progress", toolName = "read", args = {} })
  for _, value in ipairs({ "old progress", "replacement", "" }) do
    send({
      type = "tool_execution_update",
      toolCallId = "rewrite-progress",
      toolName = "read",
      partialResult = { content = { { type = "text", text = value } } },
    })
    assert(thread.items["rewrite-progress"].output == value, "progress snapshots must replace output")
  end

  local function snapshot(race, streaming)
    local result
    pi.with_runtime(runtime, function()
      pi.custom_request(
        {
          _request_message = function(method, _, callback)
            if method == "get_state" then
              callback(nil, { sessionId = "transcript-regression", isStreaming = streaming })
            elseif method == "get_entries" then
              if race then
                send({ type = "message_start", message = { role = "assistant", content = {} } })
                update({ type = "text_delta", contentIndex = 0, delta = "New live content" })
              end
              callback(nil, {
                leafId = "snapshot",
                entries = {
                  {
                    id = "snapshot",
                    parentId = vim.NIL,
                    type = "message",
                    message = { role = "user", content = "Snapshot" },
                  },
                },
              })
            else
              callback(nil, {})
            end
          end,
        },
        "thread/read",
        { threadId = id, _coactClientBound = true },
        function(err, value)
          assert(not err)
          result = value.thread
        end
      )
    end)
    return result
  end
  local interrupted = pi._turns_from_messages({
    {
      role = "assistant",
      stopReason = "aborted",
      errorMessage = "Cancelled",
      content = { { type = "text", text = "Partial answer" } },
    },
  })
  assert(
    #interrupted[1].items == 2 and interrupted[1].items[2].text == "Cancelled",
    "partial answers must not hide terminal errors"
  )
  local null_user = pi._turns_from_messages({ { role = "user", content = { { type = "text", text = vim.NIL } } } })
  assert(null_user[1].items[1].content[1].text == "", "null user text is absent")
  pi.with_runtime(runtime, function()
    pi._remember_state({ sessionId = "transcript-regression" })
    assert(pi._remember_state({ sessionId = vim.NIL }) == id, "null session identity must not relabel a thread")
  end)
  local clean = snapshot(false, false)
  assert(clean.replaceTurns and clean.turns, "context snapshots replace rather than merge live/history IDs")
  local raced = snapshot(true, false)
  assert(not raced.replaceTurns and not raced.turns, "a racing snapshot must not erase live messages")
  local active = snapshot(false, true)
  assert(not active.replaceTurns and not active.turns, "active streams must not be replaced with context snapshots")
  return thread
end

return M
