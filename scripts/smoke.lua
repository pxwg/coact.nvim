vim.opt.runtimepath:append(".")

local codex = require("codex")
codex.setup()

local parser = require("codex.parser")
local parsed = parser.parse("hello\n>diagnostics")
assert(#parsed >= 1, "parser should produce user input")

local done = false
require("codex.completion.blink").new():get_completions({
  line = ">dia",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1, "completion should return >diagnostics")
  done = true
end)
assert(done, "completion callback should run synchronously for static items")

local rpc_done = false
require("codex.rpc").start(function(err)
  assert(err == nil, err and err.message or "app-server should initialize")
  rpc_done = true
end)
vim.wait(3000, function()
  return rpc_done
end, 20)
assert(rpc_done, "app-server initialize timed out")

local thread_done = false
codex.new_thread()
vim.wait(3000, function()
  thread_done = require("codex.state").active_thread_id ~= nil
  return thread_done
end, 20)
assert(thread_done, "thread/start timed out")

local state = require("codex.state")
local buffers = require("codex.buffers")
local thread = state.ensure_thread("smoke-extmarks", {
  title = "Smoke extmarks",
  cwd = vim.fn.getcwd(),
  generation = "tool_running",
})
state.upsert_item("smoke-extmarks", "turn-1", {
  id = "user-1",
  type = "userMessage",
  content = {
    { type = "text", text = "hello", text_elements = {} },
  },
})
state.upsert_item("smoke-extmarks", "turn-1", {
  id = "reasoning-1",
  type = "reasoning",
  summary = { "thinking" },
  content = { "step 1" },
  status = "inProgress",
})
state.upsert_item("smoke-extmarks", "turn-1", {
  id = "tool-1",
  type = "commandExecution",
  command = "echo hello",
  cwd = vim.fn.getcwd(),
  status = "inProgress",
  aggregatedOutput = "hello",
})
buffers.ensure("smoke-extmarks")
vim.api.nvim_set_current_buf(thread.bufnr)
buffers.apply_window_options(vim.api.nvim_get_current_win(), thread.bufnr)
local extmarks =
  vim.api.nvim_buf_get_extmarks(thread.bufnr, require("codex.ui.render").namespace(), 0, -1, { details = true })
assert(#extmarks > 0, "render should create extmarks")
assert(#(thread.placeholder_marks or {}) >= 2, "reasoning and tool blocks should be placeholders")
assert(thread.spinner_mark ~= nil, "busy thread should render a spinner mark")
assert(thread.fold_levels and thread.fold_levels[3] == ">1", "render should create fold levels for user blocks")
assert(_G.CodexFoldExpr(3) == ">1", "foldexpr should read thread fold levels")
local detail_lines = require("codex.ui.detail").lines_for(thread.placeholder_marks[1].block)
assert(table.concat(detail_lines, "\n"):match("# Reasoning"), "detail should render block title")

local render = require("codex.ui.render")
local win = vim.api.nvim_get_current_win()
render.prepare_submit_follow(thread, win)
assert(thread.view_state and thread.view_state[win], "prepare_submit_follow should store per-window state")
render.on_user_view_changed(thread, win, "cursor")

local core = require("codex.core")
core.handle_notification({
  method = "model/rerouted",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    fromModel = "gpt-5",
    toModel = "gpt-5.1",
    reason = "capacity",
  },
})
assert(#(thread.timeline_blocks or {}) > 0, "known lifecycle notifications should render as timeline blocks")
core.handle_notification({
  method = "process/outputDelta",
  params = {
    processHandle = "smoke-process",
    stream = "stdout",
    delta = "process output",
  },
})
assert(
  (thread.local_blocks[#thread.local_blocks].output or ""):match("process output"),
  "process output should become a tool block"
)
core.handle_notification({
  method = "unknown/smoke",
  params = {
    threadId = "smoke-extmarks",
    value = "kept",
  },
})
assert(#(thread.raw_blocks or {}) > 0, "unknown notifications should be retained as raw blocks")

require("codex.rpc").stop()
