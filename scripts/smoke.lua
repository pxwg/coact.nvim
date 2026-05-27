vim.opt.runtimepath:append(".")

local codex = require("codex")
codex.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CodexNvimLifecycle", event = "VimLeavePre" }) == 1,
  "explicit setup should register lifecycle cleanup"
)
codex.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CodexNvimLifecycle", event = "VimLeavePre" }) == 1,
  "repeated setup should not duplicate lifecycle cleanup"
)
local initial_status = codex.status()
assert(initial_status.server_running == false, "status should report stopped server before startup")
assert(type(initial_status.pending_rpc_requests) == "number", "status should expose pending rpc count")
local health = require("codex.health")
assert(health._executable({ "codex", "app-server" }) == "codex", "health should resolve table commands")
assert(health._executable("codex app-server") == "codex", "health should resolve string commands")
health.check()

local parser = require("codex.parser")
local parsed = parser.parse("hello\n>diagnostics")
assert(#parsed >= 1, "parser should produce user input")

local state = require("codex.state")
local catalog = require("codex.catalog")
state.set_cache(catalog.cache_key("skills"), {
  { label = "$skill:smoke", detail = "Smoke skill", data = { name = "smoke", path = "/tmp/smoke" } },
})
state.set_cache(catalog.cache_key("tools"), {
  { label = "/smoke/read", detail = "Smoke MCP tool", filterText = "/read smoke" },
})
local context_parsed = parser.parse("@cwd")
assert(context_parsed[1] and context_parsed[1].text:match("Neovim context: workspace"), "@cwd should expand context")
local buffer_context = parser.parse("@buffer")
assert(buffer_context[1] and buffer_context[1].text:match("bufnr:"), "@buffer should include Neovim buffer metadata")
local skill_parsed = parser.parse("$skill:smoke")
assert(skill_parsed[1] and skill_parsed[1].type == "skill", "$skill should expand to a skill input")

local buffers = require("codex.buffers")
local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source_buf, "/tmp/codex-context-smoke.lua")
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
  "local codex_context_smoke = true",
  "return codex_context_smoke",
})
vim.bo[source_buf].filetype = "lua"
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_win_set_cursor(0, { 2, 7 })
local context_thread_buf = buffers.open("smoke-context")
assert(vim.api.nvim_get_current_buf() == context_thread_buf, "opening a Codex thread should focus its buffer")
local codex_buffer_context = parser.parse("@buffer")
local codex_context_text = codex_buffer_context[1] and codex_buffer_context[1].text or ""
assert(codex_context_text:match("Neovim context: target buffer"), "@buffer should describe the target buffer")
assert(codex_context_text:match("codex%-context%-smoke"), "@buffer should use the pre-chat source buffer")
assert(codex_context_text:match("cursor: L2:C8"), "@buffer should preserve the source window cursor")

local patch_review = require("codex.patch_review")
local hunk = patch_review._parse_hunk_header("@@ -3,2 +3,3 @@")
assert(hunk and hunk.old_start == 3 and hunk.new_start == 3, "patch review should parse unified diff hunks")
local review_proposal = {
  protocol = "modern",
  source = "smoke",
  request_id = "smoke-review",
  thread_id = "smoke-context",
  cwd = "/tmp",
  changes = {
    {
      kind = "update",
      path = "codex-context-smoke.lua",
      diff = table.concat({
        "--- a/codex-context-smoke.lua",
        "+++ b/codex-context-smoke.lua",
        "@@ -1,2 +1,3 @@",
        " local codex_context_smoke = true",
        "+local review_anchor = true",
        " return codex_context_smoke",
      }, "\n"),
    },
  },
}
local review_lines, review_anchors = patch_review._document(review_proposal)
assert(table.concat(review_lines, "\n"):match("%[c/%]c jump"), "patch review should document jump keys")
assert(#review_anchors == 1 and review_anchors[1].old_start == 1, "patch review should index hunk anchors")
local review_buf = patch_review.open(review_proposal)
assert(
  vim.b[review_buf].codex_patch_review_anchors[1].path == "codex-context-smoke.lua",
  "review buffer should store anchors"
)
for _, winid in ipairs(vim.fn.win_findbuf(review_buf)) do
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
end
if vim.api.nvim_buf_is_valid(review_buf) then
  vim.api.nvim_buf_delete(review_buf, { force = true })
end
local dynamic_tools = require("codex.dynamic_tools")
local patch_dir = vim.fn.tempname()
vim.fn.mkdir(patch_dir, "p")
vim.fn.writefile({ "one", "two" }, vim.fs.joinpath(patch_dir, "sample.txt"))
local apply_patch = table.concat({
  "diff --git a/sample.txt b/sample.txt",
  "--- a/sample.txt",
  "+++ b/sample.txt",
  "@@ -1,2 +1,2 @@",
  " one",
  "-two",
  "+three",
}, "\n")
local apply_changes = dynamic_tools._changes_from_unified_patch(apply_patch)
assert(#apply_changes == 1 and apply_changes[1].path == "sample.txt", "nvim.apply_patch should parse patch files")
local apply_ok, apply_message = dynamic_tools._apply_unified_patch(patch_dir, apply_patch, apply_changes)
assert(apply_ok, apply_message)
assert(
  vim.fn.readfile(vim.fs.joinpath(patch_dir, "sample.txt"))[2] == "three",
  "nvim.apply_patch should apply approved patches"
)

local done = false
local source = require("codex.completion.blink").new()
source:get_completions({
  line = "@dia",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "@diagnostics", "completion should return @diagnostics")
  done = true
end)
assert(done, "completion callback should run synchronously for Neovim context items")

local skill_done = false
source:get_completions({
  line = "$",
  cursor = { 1, 1 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "$skill:smoke", "skill completion should use catalog cache")
  skill_done = true
end)
assert(skill_done, "skill completion should run from cached official catalog")

local tool_done = false
source:get_completions({
  line = "/read",
  cursor = { 1, 5 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "/smoke/read", "tool completion should use catalog cache")
  tool_done = true
end)
assert(tool_done, "tool completion should run from cached official catalog")

local nvim_tool_done = false
source:get_completions({
  line = "/nvim/apply",
  cursor = { 1, 11 },
}, function(result)
  assert(
    #result.items == 1 and result.items[1].label == "/nvim/apply_patch",
    "tool completion should include Neovim tools"
  )
  nvim_tool_done = true
end)
assert(nvim_tool_done, "Neovim tool completion should run from local dynamic tools")
assert(require("codex.pickers")._label({ id = "thread-1", name = vim.NIL, preview = vim.NIL }):match("%[untitled%]"))

local rpc_done = false
require("codex.rpc").start(function(err)
  assert(err == nil, err and err.message or "app-server should initialize")
  rpc_done = true
end)
vim.wait(3000, function()
  return rpc_done
end, 20)
assert(rpc_done, "app-server initialize timed out")
local running_status = codex.status()
assert(running_status.server_running == true, "status should report running server after startup")
assert(running_status.server_initialized == true, "status should report initialized server after startup")

local thread_done = false
codex.new_thread()
vim.wait(3000, function()
  thread_done = require("codex.state").active_thread_id ~= nil
  return thread_done
end, 20)
assert(thread_done, "thread/start timed out")
assert(codex.status().active_thread_id ~= nil, "status should expose the active thread")

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
thread.pending_request = { prompt = "hello", created_at = vim.uv.now() }
assert(#require("codex.events").pending_blocks(thread) == 0, "pending user block should hide after userMessage echo")
thread.pending_request = { prompt = "not echoed yet", created_at = vim.uv.now() }
assert(#require("codex.events").pending_blocks(thread) == 1, "pending user block should render before userMessage echo")
thread.pending_request = nil
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

local function assert_handles_notification(message, label)
  local ok, err = pcall(core.handle_notification, message)
  assert(ok, label .. ": " .. tostring(err))
end

local command_before = thread.items["tool-1"].aggregatedOutput
assert_handles_notification({
  method = "item/commandExecution/outputDelta",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "tool-1",
    delta = vim.NIL,
  },
}, "command output should ignore null delta")
assert(thread.items["tool-1"].aggregatedOutput == command_before, "null command delta should not alter output")

local reasoning_before = thread.items["reasoning-1"].content[1]
local summary_before = thread.items["reasoning-1"].summary[1]
assert_handles_notification({
  method = "item/reasoning/textDelta",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "reasoning-1",
    contentIndex = vim.NIL,
    delta = vim.NIL,
  },
}, "reasoning text should ignore null delta")
assert_handles_notification({
  method = "item/reasoning/summaryTextDelta",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "reasoning-1",
    delta = vim.NIL,
  },
}, "reasoning summary should ignore null delta")
assert(thread.items["reasoning-1"].content[1] == reasoning_before, "null reasoning delta should not alter content")
assert(thread.items["reasoning-1"].summary[1] == summary_before, "null summary delta should not alter content")
assert_handles_notification({
  method = "item/reasoning/summaryPartAdded",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "reasoning-1",
    text = vim.NIL,
  },
}, "reasoning summary parts should accept null text")
assert(type(thread.items["reasoning-1"].summary[#thread.items["reasoning-1"].summary]) == "string")

assert_handles_notification({
  method = "process/outputDelta",
  params = {
    threadId = "smoke-extmarks",
    processHandle = "smoke-process-nil",
    stream = vim.NIL,
    delta = vim.NIL,
    deltaBase64 = vim.NIL,
    capReached = vim.NIL,
  },
}, "process output should ignore null delta")
local nil_process_block = thread.process_blocks_by_id["process/spawn:smoke-process-nil"]
assert(nil_process_block.output == "", "null process delta should not append output")
assert(nil_process_block.state == "running", "null capReached should not mark output as truncated")
assert_handles_notification({
  method = "process/exited",
  params = {
    threadId = "smoke-extmarks",
    processHandle = "smoke-process-nil",
    stdout = vim.NIL,
    stderr = vim.NIL,
    exitCode = 0,
  },
}, "process exit should ignore null stdio")

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
local timeline_count = #(thread.timeline_blocks or {})
state.set_cache(catalog.cache_key("tools"), { { label = "/stale/tool" } })
core.handle_notification({
  method = "mcpServer/startupStatus/updated",
  params = {
    name = "smoke",
    tools = {},
  },
})
assert(#(thread.timeline_blocks or {}) == timeline_count, "MCP startup updates should not render timeline spam")
local dynamic_tools_after_mcp_update = catalog.dynamic("tools")
assert(
  not vim.tbl_contains(
    vim.tbl_map(function(item)
      return item.label
    end, dynamic_tools_after_mcp_update),
    "/stale/tool"
  ),
  "MCP startup updates should invalidate remote tool completion cache"
)
assert(
  #dynamic_tools_after_mcp_update > 0,
  "local Neovim tool completions should remain available without remote cache"
)
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
