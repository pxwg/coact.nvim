-- Run only in the remote validation workspace. COACT_CLAUDE_LIVE selects a
-- private launcher; its credentials never enter this file or test output.
local live = vim.env.COACT_CLAUDE_LIVE
local command = live and { live } or { "node", vim.fn.getcwd() .. "/scripts/claude-rpc-fixture.mjs" }
require("coact").setup({
  provider = "claude",
  providers = {
    claude = {
      command = command,
      initialize_timeout_ms = 60000,
      models = live and { "deepseek-reasoner", "deepseek-chat" } or nil,
    },
  },
})
local rpc = require("coact.rpc")
local state = require("coact.state")
local backend = require("coact.providers.claude_rpc")
local function request(method, params)
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
local workspace = vim.fn.tempname()
require("coact.providers.claude").options().config_dir = workspace .. "/config"
vim.fn.mkdir(workspace .. "/.claude/skills/coact-proof", "p")
vim.fn.writefile({
  "---",
  "name: coact-proof",
  "description: Coact skill protocol test",
  "---",
  "Reply with exactly SKILL_OK. Do not use tools.",
}, workspace .. "/.claude/skills/coact-proof/SKILL.md")
local outside = vim.fn.tempname()
vim.fn.mkdir(outside, "p")
local function run()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "COACT_CLAUDE_OK" })
  vim.api.nvim_set_current_buf(buf)
  rpc.start(function(err)
    assert(not err, vim.inspect(err))
  end)
  local first = request("thread/start", { cwd = workspace }).thread
  local thread = state.update_thread_from_payload(first)
  require("coact.context").capture_thread_buffer(thread, buf, vim.api.nvim_get_current_win())
  local second
  if not live then
    local opts = require("coact.providers.claude").options()
    opts.env.COACT_FIXTURE_SKILL = "other-skill"
    second = request("thread/start", { cwd = workspace }).thread
    opts.env.COACT_FIXTURE_SKILL = nil
    local previous_active = state.active_thread_id
    state.active_thread_id = second.id
    local parsed = require("coact.parser").parse("$skill:coact-proof", { thread = thread })
    assert(
      parsed[1].type == "skill" and parsed[1].name == "coact-proof",
      "explicit source thread must select its own catalog"
    )
    assert(
      require("coact.catalog").find_skill("other-skill") and not require("coact.catalog").find_skill("coact-proof"),
      "active catalog must not leak another thread's skills"
    )
    state.active_thread_id = previous_active
  end
  local models = request("model/list", { threadId = first.id }).data
  assert(#models >= 2, "model catalog missing")
  local skills = request("skills/list", { threadId = first.id }).data[1].skills
  assert(
    vim.iter(skills):any(function(skill)
      return skill.name == "coact-proof" and skill.command == "/coact-proof"
    end),
    "project skill missing"
  )
  local result = request("turn/start", {
    threadId = first.id,
    input = {
      {
        type = "text",
        text = live
            and "Call mcp__coact__getCurrentSelection to read my source buffer. Reply with exactly the marker found there. Do not use other tools."
          or "hello",
      },
    },
  })
  local id = result.turn.id
  assert(
    vim.wait(180000, function()
      return thread.turns[id] and thread.turns[id].status ~= "inProgress"
    end, 10),
    "turn timeout"
  )
  local turn = thread.turns[id]
  assert(turn.status == "completed", vim.inspect(turn.error))
  local output, tools = "", 0
  for _, item_id in ipairs(thread.item_order) do
    local item = thread.items[item_id]
    if item.type == "agentMessage" then
      output = output .. (item.text or "")
    end
    if item.type == "dynamicToolCall" then
      tools = tools + 1
    end
  end
  assert(output:find("COACT_CLAUDE_OK", 1, true), "missing assistant output: " .. output)
  local client = backend.clients[first.id]
  local selected_model = live and "deepseek-chat" or "fixture-next"
  local old_select = vim.ui.select
  local selected = false
  vim.ui.select = function(items, _, choose)
    for _, item in ipairs(items) do
      if item.model == selected_model then
        selected = true
        choose(item)
        return
      end
    end
    error("configured model missing from /model picker")
  end
  assert(require("coact.slash").dispatch("/model", first.id, {}))
  vim.ui.select = old_select
  assert(selected and vim.wait(65000, function()
    return not client.setting_model
  end, 10), "model picker did not finish")
  assert(client.model == selected_model and thread.config.model == selected_model)
  local listed_skill = false
  vim.ui.select = function(items, _, choose)
    listed_skill = vim.iter(items):any(function(item)
      return item.name == "coact-proof"
    end)
    choose(nil)
  end
  assert(require("coact.slash").dispatch("/skills", first.id, {}))
  vim.ui.select = old_select
  assert(listed_skill, "/skills picker must list the thread's project skill")
  local skill_input = require("coact.parser").parse("$skill:coact-proof", { thread = thread })
  assert(skill_input[1].type == "skill", "skill completion must become a typed invocation")
  local skill_turn = request("turn/start", { threadId = first.id, input = skill_input }).turn
  assert(
    vim.wait(180000, function()
      return thread.turns[skill_turn.id].status ~= "inProgress"
    end, 10),
    "skill timeout"
  )
  assert(thread.turns[skill_turn.id].status == "completed")
  assert(
    vim.iter(thread.turns[skill_turn.id].items):any(function(item)
      return item.type == "agentMessage" and item.text:find("SKILL_OK", 1, true)
    end),
    "skill invocation failed"
  )
  assert(require("coact.slash").dispatch("/compact", first.id, {}))
  assert(client.compacting and thread.generation == "summarizing")
  local compact_turn = client.turn.id
  local busy_error
  rpc.request(
    "turn/start",
    { threadId = first.id, input = { { type = "text", text = "must not overlap" } } },
    function(err)
      busy_error = err
    end
  )
  assert(busy_error, "compaction must reserve the execution unit")
  local submit_error
  require("coact").submit_text("must not overlap", first.id, {
    on_error = function(err)
      submit_error = err
    end,
  })
  assert(submit_error and thread.generation == "summarizing", "rejected UI submission must preserve compaction status")
  assert(
    vim.wait(180000, function()
      return not client.turn
    end, 10),
    "compact timeout"
  )
  assert(thread.turns[compact_turn].status == "completed" and client.compact_metadata)
  assert(thread.generation == "idle", "compaction must clear busy state")
  if not live then
    local done, rejected = false, nil
    rpc.request("thread/settings/update", { threadId = first.id, model = "bad-model" }, function(err)
      rejected, done = err, true
    end)
    assert(vim.wait(5000, function()
      return done
    end, 10))
    assert(rejected and client.model == selected_model and thread.config.model == selected_model)
  end
  if live then
    assert(tools > 0, "live turn did not invoke MCP IDE tool")
    local client = backend.clients[first.id]
    local write_turn = request("turn/start", {
      threadId = first.id,
      input = {
        {
          type = "text",
          text = "Call mcp__coact__openDiff exactly once to create proof.txt with exactly VERIFIED followed by a newline. Do not use any other tools. After it succeeds reply DONE.",
        },
      },
    }).turn
    assert(
      vim.wait(180000, function()
        return client.review ~= nil
      end, 10),
      "live review never opened"
    )
    assert(vim.fn.filereadable(workspace .. "/proof.txt") == 0, "must not write before review")
    local review = client.review
    for _, block in ipairs(review.blocks) do
      require("coact.patch_session")._accept_block(review, block)
    end
    assert(
      vim.wait(180000, function()
        return thread.turns[write_turn.id].status ~= "inProgress"
      end, 10),
      "review turn timeout"
    )
    assert(thread.turns[write_turn.id].status == "completed")
    assert(vim.fn.readfile(workspace .. "/proof.txt")[1] == "VERIFIED")
    vim.fn.writefile({ "original outside" }, outside .. "/external.txt")
    local edit_turn = request("turn/start", {
      threadId = first.id,
      input = {
        {
          type = "text",
          text = "First run Bash with command printf COACT_BASH_OK. Then call mcp__coact__edit on "
            .. outside
            .. '/external.txt with edits [{"oldText":"original outside","newText":"reviewed outside"}]. Do not use other tools or write via Bash. After approval reply DONE.',
        },
      },
    }).turn
    assert(
      vim.wait(180000, function()
        return client.review ~= nil
      end, 10),
      "outside edit review never opened"
    )
    assert(vim.fn.readfile(outside .. "/external.txt")[1] == "original outside")
    local edit_review = client.review
    for _, block in ipairs(edit_review.blocks) do
      require("coact.patch_session")._accept_block(edit_review, block)
    end
    assert(
      vim.wait(180000, function()
        return thread.turns[edit_turn.id].status ~= "inProgress"
      end, 10),
      "edit timeout"
    )
    assert(thread.turns[edit_turn.id].status == "completed")
    assert(vim.fn.readfile(outside .. "/external.txt")[1] == "reviewed outside")
    assert(
      vim.iter(thread.turns[edit_turn.id].items):any(function(item)
        return item.tool == "Bash" and item.success == true
      end),
      "Bash did not execute successfully in pair mode"
    )
    local interrupt_turn = request("turn/start", {
      threadId = first.id,
      input = {
        {
          type = "text",
          text = "Call mcp__coact__openDiff to replace proof.txt contents with CANCELLED followed by a newline. Do not use any other tools.",
        },
      },
    }).turn
    assert(
      vim.wait(180000, function()
        return client.review ~= nil
      end, 10),
      "interrupt review never opened"
    )
    request("turn/interrupt", { threadId = first.id, turnId = interrupt_turn.id })
    assert(
      vim.wait(30000, function()
        return thread.turns[interrupt_turn.id].status ~= "inProgress"
      end, 10),
      "interrupt did not finish turn"
    )
    assert(thread.turns[interrupt_turn.id].status == "interrupted")
    assert(not client.review and vim.fn.readfile(workspace .. "/proof.txt")[1] == "VERIFIED")
  end
  if not live then
    assert(rpc.client_count() == 2, "thread processes must be isolated")
    assert(backend.clients[second.id].turn == nil, "second thread must remain idle")
    assert(output == "COACT_CLAUDE_OK", "final message must replace streamed text, not duplicate it")
    local follow = request("turn/start", { threadId = first.id, input = { { type = "text", text = "again" } } }).turn
    assert(vim.wait(5000, function()
      return thread.turns[follow.id].status == "completed"
    end, 10))
    local client = backend.clients[first.id]
    backend._dispatch(client, { type = "system", subtype = "status", status = vim.NIL })
    backend._dispatch(client, { type = "stream_event", event = vim.NIL })
    backend._dispatch(client, { type = "assistant", message = vim.NIL })
    backend._dispatch(client, { type = "control_response", response = vim.NIL })
    local failed
    rpc.request("not-supported", { threadId = first.id }, function(err)
      failed = err
    end)
    assert(failed and failed.code == -32601)
    backend._feed(client, { '{"type":"sys' })
    backend._feed(client, { 'tem","subtype":"status"}', "" })
    assert(client.job and client.tail == "", "split JSON frames must be reassembled")
    backend._feed(client, { '{"type":"sys', 'tem"}' })
    -- The preceding newline intentionally creates malformed JSON: fail closed.
    assert(not client.job, "malformed wire data must close its client")
    assert(backend.clients[second.id].job, "malformed data must not close another thread")
    local opts = require("coact.providers.claude").options()
    for _, mode in ipairs({ "exit", "hang" }) do
      opts.env.COACT_FIXTURE_MODE = mode
      opts.initialize_timeout_ms = 500
      local calls, error_result = 0, nil
      rpc.request("thread/start", { cwd = workspace }, function(err)
        calls, error_result = calls + 1, err
      end)
      assert(
        vim.wait(5000, function()
          return calls > 0
        end, 10),
        "startup failure callback missing"
      )
      assert(error_result and calls == 1, "startup failure must complete exactly once")
      assert(rpc.pending_count() == 0, "startup failure must drain pending requests")
    end
    opts.env.COACT_FIXTURE_MODE = nil
  end
  print(live and "Claude live Neovim + DeepSeek + MCP: PASS" or "Claude provider fixture: PASS")
end
local ok, err = xpcall(run, debug.traceback)
rpc.stop()
vim.fn.delete(workspace, "rf")
vim.fn.delete(outside, "rf")
assert(rpc.client_count() == 0 and rpc.pending_count() == 0, "transport cleanup")
if not ok then
  error(err)
end
vim.cmd("qa!")
