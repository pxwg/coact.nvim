vim.opt.runtimepath:append(".")

local codex = require("codex")
codex.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CodexNvimLifecycle", event = "VimLeavePre" }) == 1,
  "explicit setup should register lifecycle cleanup"
)
local start_params = codex._thread_start_params({ cwd = vim.fn.getcwd() })
assert(
  type(start_params.developerInstructions) == "string" and start_params.developerInstructions:match("nvim%.apply_patch"),
  "thread/start should instruct Codex to prefer Neovim patch review"
)
assert(
  start_params.developerInstructions:match("small, focused unified diffs"),
  "thread/start should include strict nvim.apply_patch diff sizing protocol"
)
assert(
  start_params.developerInstructions:match("Do not repeatedly retry failed patches against stale context"),
  "thread/start should forbid stale failed patch retries"
)
local composed_instructions = codex._compose_developer_instructions("custom instruction")
assert(composed_instructions:match("custom instruction"), "default edit instruction should preserve user instructions")
assert(composed_instructions:match("nvim%.apply_patch"), "default edit instruction should mention nvim.apply_patch")
local dynamic_tools_for_config = require("codex.dynamic_tools")
local pair_specs = dynamic_tools_for_config.specs() or {}
assert(
  vim.iter(pair_specs):any(function(spec)
    return spec.namespace == "nvim" and spec.name == "apply_patch"
  end),
  "pair edit mode should expose nvim.apply_patch"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("small, focused unified diffs"),
  "nvim.apply_patch tool description should include strict diff protocol"
)
assert(
  dynamic_tools_for_config._stale_patch_retry_message():match("Re%-read the current buffer"),
  "nvim.apply_patch failure guidance should require refreshing buffer state"
)
codex.setup({ edit = { mode = "yolo" } })
local yolo_start_params = codex._thread_start_params({ cwd = vim.fn.getcwd() })
assert(
  yolo_start_params.developerInstructions:match("native apply_patch tool directly"),
  "yolo edit mode should instruct Codex to use native apply_patch directly"
)
assert(not vim.iter(dynamic_tools_for_config.specs() or {}):any(function(spec)
  return spec.namespace == "nvim" and spec.name == "apply_patch"
end), "yolo edit mode should not expose nvim.apply_patch")
local rpc = require("codex.rpc")
local original_rpc_respond_for_mode = rpc.respond
local rejected_disabled_tool = nil
rpc.respond = function(_, result)
  rejected_disabled_tool = result
end
dynamic_tools_for_config.handle_call({
  id = "disabled-apply-patch",
  params = {
    namespace = "nvim",
    tool = "apply_patch",
    arguments = { patch = "diff --git a/x b/x\n--- a/x\n+++ b/x" },
  },
})
rpc.respond = original_rpc_respond_for_mode
assert(
  rejected_disabled_tool and rejected_disabled_tool.success == false,
  "disabled nvim.apply_patch calls should fail"
)
assert(
  rejected_disabled_tool.contentItems[1].text:match("not exposed"),
  "disabled nvim.apply_patch calls should explain exposure gating"
)
codex.setup({ dynamic_tools = { prefer_nvim_apply_patch = false } })
assert(require("codex.config").edit_mode() == "yolo", "legacy prefer_nvim_apply_patch=false should select yolo mode")
codex.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CodexNvimLifecycle", event = "VimLeavePre" }) == 1,
  "repeated setup should not duplicate lifecycle cleanup"
)
local initial_status = codex.status()
assert(initial_status.server_running == false, "status should report stopped server before startup")
assert(type(initial_status.pending_rpc_requests) == "number", "status should expose pending rpc count")
assert(
  vim.tbl_contains(codex.complete_command("sta", "Codex sta"), "status"),
  "command completion should filter commands"
)
assert(vim.tbl_contains(codex.complete_command("", "Codex attach "), "all"), "attach completion should include all")
local health = require("codex.health")
assert(health._executable({ "codex", "app-server" }) == "codex", "health should resolve table commands")
assert(health._executable("codex app-server") == "codex", "health should resolve string commands")
local app_server_supported, app_server_help = health._app_server_supported("codex")
assert(app_server_supported, "health should detect codex app-server support: " .. tostring(app_server_help))
health.check()

local parser = require("codex.parser")
local parsed = parser.parse("hello\n>diagnostics")
assert(#parsed >= 1, "parser should produce user input")

local state = require("codex.state")
local status_thread = state.update_thread_from_payload({
  id = "smoke-status-object",
  status = { type = "active", activeFlags = {} },
})
assert(status_thread.status == "active", "thread payload status objects should normalize to labels")
local metadata = require("codex.ui.metadata")
local status_labels = metadata.composer_labels({ config = {}, status = { type = "active", activeFlags = {} } })
assert(#status_labels == 1 and status_labels[1] == "active", "composer metadata should not stringify tables")
codex.setup({ thread = { model = "gpt-5", reasoning_effort = "high" } })
local configured_composer_labels = metadata.composer_labels({ config = {}, status = "active" })
assert(
  vim.deep_equal(configured_composer_labels, { "gpt-5", "effort high", "active" }),
  "composer metadata should include configured model and reasoning effort"
)
local stale_header_thread = state.ensure_thread("smoke-thread-settings-header", {
  config = { model = "gpt-5-codex", reasoning_effort = "xhigh" },
  status = "active",
})
stale_header_thread.settings = { effort = "medium" }
state.apply_thread_settings(stale_header_thread, stale_header_thread.settings)
assert(
  vim.deep_equal(metadata.composer_labels(stale_header_thread), { "gpt-5-codex", "effort medium", "active" }),
  "composer metadata should prefer updated thread effort over stale defaults"
)
local effective_turn_params = codex._turn_start_params("smoke-thread-settings-header", {})
assert(effective_turn_params.effort == "medium", "turn/start should use updated thread reasoning effort")
stale_header_thread.settings = { effort = vim.NIL }
state.apply_thread_settings(stale_header_thread, stale_header_thread.settings)
assert(
  vim.deep_equal(metadata.composer_labels(stale_header_thread), { "gpt-5-codex", "active" }),
  "composer metadata should not resurrect a stale effort after selecting default"
)
local active_user_labels = metadata.user_labels(nil, {
  state = "active",
  raw = { settings = { model = "gpt-5-codex", reasoning_effort = "medium" } },
})
assert(
  vim.deep_equal(active_user_labels, { "active", "gpt-5-codex", "effort medium" }),
  "user metadata should include active turn model and reasoning effort"
)
codex.setup()
require("codex.core").handle_notification({
  method = "thread/status/changed",
  params = {
    threadId = "smoke-status-object",
    status = { type = "active", activeFlags = { network = true } },
  },
})
assert(status_thread.status == "active (network)", "status change objects should normalize to labels")
local settings_event_thread = state.ensure_thread("smoke-settings-event", {
  config = { model = "gpt-5-codex", reasoning_effort = "xhigh" },
  status = "active",
})
require("codex.core").handle_notification({
  method = "thread/settings/updated",
  params = {
    threadId = "smoke-settings-event",
    threadSettings = { effort = "medium" },
  },
})
assert(settings_event_thread.config.reasoning_effort == "medium", "settings events should update thread config")
assert(
  vim.deep_equal(metadata.composer_labels(settings_event_thread), { "gpt-5-codex", "effort medium", "active" }),
  "settings events should refresh composer reasoning effort"
)
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
local asset_dir = vim.fn.tempname()
vim.fn.mkdir(asset_dir, "p")
local text_asset = vim.fs.joinpath(asset_dir, "space file.txt")
local image_asset = vim.fs.joinpath(asset_dir, "sample image.png")
vim.fn.writefile({ "text asset with spaces" }, text_asset)
vim.fn.writefile({ "fake png" }, image_asset)
local file_asset_parsed = parser.parse("@file:`" .. text_asset .. "`")
assert(
  file_asset_parsed[1] and file_asset_parsed[1].text:match("text asset with spaces"),
  "@file should accept backtick-quoted paths with spaces"
)
local official_file_parsed = parser.parse("@" .. require("codex.context").display_path(text_asset), {
  auto_selection = false,
})
assert(
  official_file_parsed[1] and official_file_parsed[1].text:match("text asset with spaces"),
  "@path should expand Codex official file context syntax"
)
local image_asset_parsed = parser.parse("@image:`" .. image_asset .. "`")
assert(image_asset_parsed[1] and image_asset_parsed[1].type == "localImage", "@image should attach local images")
assert(image_asset_parsed[1].path == vim.fs.normalize(image_asset), "@image should normalize local image paths")
local remote_image_parsed = parser.parse("@image:https://example.com/smoke.png")
assert(remote_image_parsed[1] and remote_image_parsed[1].type == "image", "@image should attach image URLs")

local buffers = require("codex.buffers")
local buffer_opened_events = {}
local attached_buffers = {}
local buffer_attached_events = {}
codex.on("buffer_attached", function(payload)
  table.insert(buffer_attached_events, payload)
end)
codex.setup({
  buffer = {
    on_attach = function(bufnr, payload)
      attached_buffers[bufnr] = payload.thread_id
    end,
  },
})
vim.api.nvim_create_autocmd("User", {
  pattern = "CodexBufferOpened",
  callback = function(event)
    table.insert(buffer_opened_events, event.data)
  end,
})
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
assert(attached_buffers[context_thread_buf] == "smoke-context", "buffer.on_attach should run for Codex buffers")
assert(
  buffer_attached_events[1] and buffer_attached_events[1].bufnr == context_thread_buf,
  "opening a Codex thread should emit buffer_attached hooks"
)
attached_buffers[context_thread_buf] = nil
assert(codex.attach_buffer(context_thread_buf), "attach_buffer should attach a Codex buffer")
assert(attached_buffers[context_thread_buf] == "smoke-context", "attach_buffer should rerun buffer.on_attach")
assert(codex.attach_all_buffers() >= 1, "attach_all_buffers should find existing Codex buffers")
assert(
  vim.tbl_contains(
    codex.complete_command(tostring(context_thread_buf), "Codex attach " .. context_thread_buf),
    tostring(context_thread_buf)
  ),
  "attach completion should include Codex buffer numbers"
)
assert(
  vim.tbl_contains(codex.complete_command("smoke", "Codex resume smoke"), "smoke-context"),
  "resume completion should include loaded thread ids"
)
assert(
  buffer_opened_events[1] and buffer_opened_events[1].bufnr == context_thread_buf,
  "opening a Codex thread should emit CodexBufferOpened"
)
assert(
  buffer_opened_events[1] and buffer_opened_events[1].thread_id == "smoke-context",
  "CodexBufferOpened should include the thread id"
)
local codex_buffer_context = parser.parse("@buffer")
local codex_context_text = codex_buffer_context[1] and codex_buffer_context[1].text or ""
assert(codex_context_text:match("Neovim context: target buffer"), "@buffer should describe the target buffer")
assert(codex_context_text:match("codex%-context%-smoke"), "@buffer should use the pre-chat source buffer")
assert(codex_context_text:match("cursor: L2:C8"), "@buffer should preserve the source window cursor")
vim.api.nvim_buf_set_mark(source_buf, "<", 1, 0, {})
vim.api.nvim_buf_set_mark(source_buf, ">", 2, 0, {})
local auto_selection_context = parser.parse("explain selection", {
  thread = state.get_thread("smoke-context"),
})
assert(
  auto_selection_context[2] and auto_selection_context[2].text:match("Neovim context: selection"),
  "parser should auto-attach source-buffer visual selection context"
)
assert(
  auto_selection_context[2].text:match("codex%-context%-smoke") and auto_selection_context[2].text:match("L1%-L2"),
  "selection context should include source file and range metadata"
)
pcall(vim.api.nvim_buf_del_mark, source_buf, "<")
pcall(vim.api.nvim_buf_del_mark, source_buf, ">")

local original_ui_select_for_context = vim.ui.select
local original_snacks_for_context = package.loaded["snacks"]
local hook_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(hook_buf)
vim.api.nvim_buf_set_lines(hook_buf, 0, -1, false, { "@file:" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.ui.select = function()
  error("snacks file picker should be used before vim.ui.select fallback")
end
local snacks_file_picker_called = false
package.loaded["snacks"] = {
  picker = {
    files = function(opts)
      snacks_file_picker_called = true
      assert(opts.title == "Codex File Context", "file context hook should use snacks file picker title")
      assert(opts.hidden == true, "file context hook should include hidden workspace files")
      opts.confirm({
        close = function() end,
      }, {
        file = "README.md",
        cwd = opts.cwd,
      })
    end,
  },
}
package.loaded["snacks.picker.util"] = {
  path = function(item)
    return vim.fs.joinpath(item.cwd, item.file)
  end,
}
assert(require("codex.context").trigger_hook(), "@file: should trigger context hook")
vim.wait(1000, function()
  return vim.api.nvim_buf_get_lines(hook_buf, 0, 1, false)[1] == "@README.md"
end, 20)
vim.ui.select = original_ui_select_for_context
package.loaded["snacks"] = original_snacks_for_context
package.loaded["snacks.picker.util"] = nil
assert(snacks_file_picker_called, "@file: hook should reuse snacks file picker when available")
assert(
  vim.api.nvim_buf_get_lines(hook_buf, 0, 1, false)[1] == "@README.md",
  "@file: hook should replace provider syntax with official @path syntax"
)
vim.api.nvim_set_current_buf(source_buf)
codex.add_current_buffer()
local added_context_prompt = buffers.collect_prompt(context_thread_buf)
assert(
  added_context_prompt:match("@.*codex%-context%-smoke%.lua"),
  "Codex add-buffer should append the current source buffer path to the chat prompt"
)
buffers.clear_prompt(context_thread_buf)

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
local session_dir = vim.fn.tempname()
vim.fn.mkdir(session_dir, "p")
local session_file = vim.fs.joinpath(session_dir, "session.txt")
vim.fn.writefile({ "alpha", "beta", "gamma" }, session_file)
local session_patch = table.concat({
  "diff --git a/session.txt b/session.txt",
  "--- a/session.txt",
  "+++ b/session.txt",
  "@@ -1,3 +1,3 @@",
  " alpha",
  "-beta",
  "+bravo",
  " gamma",
}, "\n")
local session_done = false
local patch_session = require("codex.patch_session")
local session = patch_session.open({
  cwd = session_dir,
  changes = dynamic_tools._changes_from_unified_patch(session_patch),
  on_complete = function(summary, success)
    assert(not success, "rejected hunk should report a failed/partial patch review")
    assert(summary:match("keep beta"), "patch review summary should include rejection feedback")
    session_done = true
  end,
})
assert(
  vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())) == vim.uv.fs_realpath(session_file),
  "nvim.apply_patch review should open directly in the edited file buffer"
)
assert(patch_session._active_session(0) == session, "patch session should track active edited buffers")
patch_session._reject_hunk(session, session.hunks[1], "keep beta")
vim.wait(1000, function()
  return session_done
end, 20)
assert(vim.fn.readfile(session_file)[2] == "beta", "rejected patch hunk should restore original file content")
local tool_dir = vim.fn.tempname()
vim.fn.mkdir(tool_dir, "p")
local tool_file = vim.fs.joinpath(tool_dir, "tool.txt")
vim.fn.writefile({ "red", "green", "blue" }, tool_file)
local tool_patch = table.concat({
  "diff --git a/tool.txt b/tool.txt",
  "--- a/tool.txt",
  "+++ b/tool.txt",
  "@@ -1,3 +1,3 @@",
  " red",
  "-green",
  "+emerald",
  " blue",
}, "\n")
local rpc = require("codex.rpc")
local original_rpc_respond = rpc.respond
local tool_response = nil
rpc.respond = function(id, result)
  assert(id == "tool-apply-review", "dynamic tool should respond to the original request id")
  tool_response = result
end
dynamic_tools.handle_call({
  id = "tool-apply-review",
  params = {
    namespace = "nvim",
    tool = "apply_patch",
    threadId = "smoke-context",
    arguments = {
      cwd = tool_dir,
      patch = tool_patch,
    },
  },
})
local tool_session = patch_session._active_session(0)
assert(tool_session and tool_session.hunks[1], "nvim.apply_patch dynamic tool should open an in-buffer patch session")
patch_session._reject_hunk(tool_session, tool_session.hunks[1], "not this color")
vim.wait(1000, function()
  return tool_response ~= nil
end, 20)
rpc.respond = original_rpc_respond
assert(tool_response and tool_response.success == false, "rejected dynamic patch should respond as unsuccessful")
assert(
  tool_response.contentItems[1].text:match("not this color"),
  "dynamic nvim.apply_patch response should include rejection feedback"
)
assert(vim.fn.readfile(tool_file)[2] == "green", "dynamic patch rejection should preserve original file content")
local fallback_thread = { id = "thread-fallback", active_turn_id = "turn-fallback" }
local fallback_params = { threadId = "thread-fallback", turnId = "turn-fallback" }
assert(
  not dynamic_tools._native_apply_patch_fallback_active(fallback_params, fallback_thread),
  "native apply_patch fallback should start disabled"
)
dynamic_tools._mark_native_apply_patch_fallback(fallback_params, fallback_thread)
assert(
  dynamic_tools._native_apply_patch_fallback_active(fallback_params, fallback_thread),
  "accept-for-session should enable native apply_patch fallback for the turn"
)
assert(
  dynamic_tools._native_apply_patch_fallback_message():match("native `apply_patch`"),
  "native apply_patch fallback message should tell Codex what tool to use"
)
dynamic_tools.clear_turn_state("thread-fallback", "turn-fallback")
assert(
  not dynamic_tools._native_apply_patch_fallback_active(fallback_params, fallback_thread),
  "turn cleanup should clear native apply_patch fallback"
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

local path_done = false
local file_completion_line = "@file:`" .. asset_dir .. "/space"
source:get_completions({
  line = file_completion_line,
  cursor = { 1, #file_completion_line },
}, function(result)
  assert(#result.items >= 1, "file path completion should return path candidates")
  assert(result.items[1].label:match("^@file:`"), "file path completion should use backtick quoting")
  path_done = true
end)
assert(path_done, "path completion callback should run synchronously")

local image_path_done = false
local image_completion_line = "@image:`" .. asset_dir .. "/sample"
source:get_completions({
  line = image_completion_line,
  cursor = { 1, #image_completion_line },
}, function(result)
  assert(
    #result.items == 1 and result.items[1].label:match("sample image%.png"),
    "image completion should return image files"
  )
  image_path_done = true
end)
assert(image_path_done, "image path completion callback should run synchronously")

local skill_done = false
source:get_completions({
  line = "$",
  cursor = { 1, 1 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "$skill:smoke", "skill completion should use catalog cache")
  skill_done = true
end)
assert(skill_done, "skill completion should run from cached official catalog")

local slash_done = false
source:get_completions({
  line = "/mo",
  cursor = { 1, 3 },
}, function(result)
  assert(
    vim.tbl_contains(
      vim.tbl_map(function(item)
        return item.label
      end, result.items),
      "/model"
    ),
    "slash completion should return CLI command items"
  )
  slash_done = true
end)
assert(slash_done, "slash completion should run from local command catalog")

local nvim_tool_done = false
source:get_completions({
  line = "/nvim/apply",
  cursor = { 1, 11 },
}, function(result)
  assert(#result.items == 0, "slash completion should not expose Neovim dynamic tools")
  nvim_tool_done = true
end)
assert(nvim_tool_done, "slash completion should filter dynamic tool-looking prefixes")

local slash = require("codex.slash")
assert(slash.parse("/model").name == "model", "slash parser should parse command names")
assert(slash.parse("/goal ship it").raw_args == "ship it", "slash parser should keep raw args")
for _, command in ipairs(slash._commands) do
  assert(slash._return_forms[command.name], "slash command should declare return form: " .. command.name)
end
local select_formatted = nil
local original_ui_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  select_formatted = opts.format_item(items[1])
  callback(nil)
end
slash._present_result({
  kind = "select",
  title = "Smoke",
  items = { { label = "profile: smoke", detail = vim.NIL } },
  format_item = function(item)
    return item.label
  end,
})
vim.ui.select = original_ui_select
assert(select_formatted == "profile: smoke", "slash select presenter should stringify vim.NIL-safe labels")
local rpc = require("codex.rpc")
local original_rpc_request = rpc.request
local model_list_requests = 0
rpc.request = function(method, params, callback)
  assert(method == "model/list", "slash /model smoke should request model/list")
  model_list_requests = model_list_requests + 1
  callback(nil, { data = {}, nextCursor = vim.NIL })
end
slash.dispatch("/model", nil, {
  ensure_server = function(callback)
    callback()
  end,
})
rpc.request = original_rpc_request
assert(model_list_requests == 1, "slash list pagination should treat vim.NIL nextCursor as absent")
local model_select_prompts = {}
local model_settings_update = nil
vim.ui.select = function(items, opts, callback)
  table.insert(model_select_prompts, opts.prompt)
  if opts.prompt == "Codex model" then
    callback(items[1])
  elseif opts.prompt == "Codex thinking effort" then
    callback(items[3])
  else
    callback(nil)
  end
end
rpc.request = function(method, params, callback)
  if method == "model/list" then
    callback(nil, {
      data = {
        {
          id = "gpt-5-codex",
          model = "gpt-5-codex",
          displayName = "GPT-5 Codex",
          description = "Smoke model",
          hidden = false,
          defaultReasoningEffort = "medium",
          supportedReasoningEfforts = {
            { reasoningEffort = "medium", description = "Balanced thinking" },
            { reasoningEffort = "high", description = "Deeper thinking" },
          },
          defaultServiceTier = vim.NIL,
        },
      },
      nextCursor = vim.NIL,
    })
    return
  end
  assert(method == "thread/settings/update", "slash /model effort smoke should update thread settings")
  model_settings_update = params
  callback(nil, {})
end
slash.dispatch("/model", "thread-model-effort", {
  ensure_server = function(callback)
    callback()
  end,
})
rpc.request = original_rpc_request
vim.ui.select = original_ui_select
assert(
  vim.deep_equal(model_select_prompts, { "Codex model", "Codex thinking effort" }),
  "slash /model should prompt for model-supported thinking effort"
)
assert(model_settings_update.threadId == "thread-model-effort", "slash /model should target the active thread")
assert(model_settings_update.model == "gpt-5-codex", "slash /model should update the selected model")
assert(model_settings_update.effort == "high", "slash /model should update the selected thinking effort")
local permission_items = {}
vim.ui.select = function(items, opts, callback)
  for _, item in ipairs(items) do
    table.insert(permission_items, opts.format_item(item))
  end
  callback(nil)
end
rpc.request = function(method, params, callback)
  assert(method == "permissionProfile/list", "slash /permissions smoke should request permissionProfile/list")
  callback(nil, { data = { { id = "smoke", description = vim.NIL } } })
end
slash.dispatch("/permissions", nil, {
  ensure_server = function(callback)
    callback()
  end,
})
rpc.request = original_rpc_request
vim.ui.select = original_ui_select
assert(
  vim.tbl_contains(permission_items, "profile: smoke - Codex permission profile"),
  "slash /permissions should stringify vim.NIL profile descriptions"
)
local slash_new_prompt = nil
assert(
  slash.dispatch("/new start here", nil, {
    new_thread = function(opts)
      slash_new_prompt = opts.prompt
    end,
  }),
  "slash dispatch should handle known commands locally"
)
assert(slash_new_prompt == "start here", "slash /new should call the local thread action")
assert(slash._sandbox_policy("read-only").type == "readOnly", "slash sandbox helper should map app-server policy")

local original_submit_text = codex.submit_text
local executed_slash = nil
local execute_default_new_text = nil
local execute_done = false
codex.submit_text = function(text)
  executed_slash = text
end
source:execute({
  bufnr = vim.api.nvim_get_current_buf(),
}, {
  label = "/model",
  insertText = "/model",
  textEdit = {
    newText = "/model",
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 3 },
    },
  },
  data = {
    source = "codex.nvim.slash",
    command = "model",
  },
}, function()
  execute_done = true
end, function(_, item)
  execute_default_new_text = item.textEdit and item.textEdit.newText or item.insertText
end)
vim.wait(1000, function()
  return executed_slash ~= nil and execute_done
end, 20)
codex.submit_text = original_submit_text
assert(execute_default_new_text == "", "accepting slash completion should remove the typed slash prefix")
assert(executed_slash == "/model", "accepting slash completion should execute the slash command")
assert(execute_done, "slash completion execute should call blink callback")

assert(require("codex.pickers")._label({ id = "thread-1", name = vim.NIL, preview = vim.NIL }):match("%[untitled%]"))

local rpc = require("codex.rpc")
vim.env.MallocStackLogging = "0"
vim.env.MallocStackLoggingNoCompact = "0"
local app_server_env = rpc._app_server_env()
assert(app_server_env.MallocStackLogging == nil, "rpc should strip MallocStackLogging from app-server env")
assert(
  app_server_env.MallocStackLoggingNoCompact == nil,
  "rpc should strip MallocStackLoggingNoCompact from app-server env"
)

local rpc_done = false
rpc.start(function(err)
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
local events = require("codex.events")
state.upsert_item("smoke-extmarks", "turn-1", {
  id = "user-1",
  type = "userMessage",
  content = {
    { type = "text", text = "hello", text_elements = {} },
  },
})
thread.pending_request = { prompt = "hello", created_at = vim.uv.now() }
thread.active_turn_id = "turn-1"
assert(#events.pending_blocks(thread) == 0, "pending user block should hide after userMessage echo")
thread.active_turn_id = "turn-2"
thread.pending_request = { prompt = "hello", created_at = vim.uv.now() }
assert(#events.pending_blocks(thread) == 1, "pending user block should not hide behind earlier turns")
thread.pending_request = { prompt = "not echoed yet", created_at = vim.uv.now() }
assert(#events.pending_blocks(thread) == 1, "pending user block should render before userMessage echo")
thread.pending_request = nil
thread.active_turn_id = nil
local asset_prompt = "@image:`" .. image_asset .. "`\n\ninspect image"
local asset_input = parser.parse(asset_prompt)
local asset_pending_thread = state.ensure_thread("smoke-pending-asset", {
  title = "Smoke pending asset",
  cwd = vim.fn.getcwd(),
})
asset_pending_thread.active_turn_id = "turn-asset"
asset_pending_thread.pending_request = { prompt = asset_prompt, input = asset_input, created_at = vim.uv.now() }
state.upsert_item("smoke-pending-asset", "turn-old", {
  id = "user-old-asset",
  type = "userMessage",
  content = asset_input,
})
local asset_pending_blocks = events.pending_blocks(asset_pending_thread)
assert(#asset_pending_blocks == 1, "pending asset prompt should render before userMessage echo")
assert(asset_pending_blocks[1].text:match("@image:"), "pending asset prompt should preserve raw provider syntax")
assert(
  events._pending_text(asset_pending_thread.pending_request):match("%[local image%]"),
  "pending asset prompt should compute canonical image text"
)
assert(
  #events._pending_candidates(asset_pending_thread.pending_request) == 2,
  "pending asset prompt should keep raw and canonical candidates"
)
state.upsert_item("smoke-pending-asset", "turn-asset", {
  id = "user-asset",
  type = "userMessage",
  content = asset_input,
})
assert(
  #events.pending_blocks(asset_pending_thread) == 0,
  "pending asset prompt should hide after canonical userMessage echo"
)
local turn_settings_thread = state.ensure_thread("smoke-turn-settings", {
  title = "Smoke turn settings",
  cwd = vim.fn.getcwd(),
})
state.set_turn_settings("smoke-turn-settings", "turn-settings", {
  model = "gpt-5-codex",
  effort = "high",
})
state.upsert_item("smoke-turn-settings", "turn-settings", {
  id = "user-turn-settings",
  type = "userMessage",
  status = "active",
  content = {
    { type = "text", text = "turn settings prompt", text_elements = {} },
  },
})
local turn_setting_blocks = events.normalize_thread(turn_settings_thread)
assert(
  vim.deep_equal(metadata.user_labels(turn_settings_thread, turn_setting_blocks[1]), {
    "active",
    "gpt-5-codex",
    "effort high",
  }),
  "userMessage headers should use saved turn settings"
)
local server_echo_thread = state.ensure_thread("smoke-pending-server-echo", {
  title = "Smoke pending server echo",
  cwd = vim.fn.getcwd(),
})
server_echo_thread.active_turn_id = "turn-server-echo"
server_echo_thread.pending_request = { prompt = asset_prompt, input = asset_input, created_at = vim.uv.now() }
state.upsert_item("smoke-pending-server-echo", "turn-server-echo", {
  id = "user-server-echo",
  type = "userMessage",
  content = {
    { type = "text", text = "server canonicalized this prompt differently", text_elements = {} },
  },
})
assert(
  #events.pending_blocks(server_echo_thread) == 0,
  "pending asset prompt should hide once the same turn has a userMessage echo"
)
local render = require("codex.ui.render")
local cleared_event_thread = state.ensure_thread("smoke-cleared-event", {
  title = "Smoke cleared event",
  cwd = vim.fn.getcwd(),
})
local cleared_event_buf = vim.api.nvim_create_buf(false, true)
state.bind_buffer(cleared_event_thread, cleared_event_buf)
cleared_event_thread.timeline_blocks = {
  {
    type = "AgentTimelineBlock",
    title = "Goal cleared",
    state = "cleared",
    text = "Thread goal cleared.",
    local_only = true,
  },
}
codex.setup({ render = { virtual_blocks = { default_expanded = true } } })
render.render(cleared_event_thread)
local cleared_event_lines = vim.api.nvim_buf_get_lines(cleared_event_buf, 0, -1, false)
assert(not vim.tbl_contains(cleared_event_lines, "## Codex"), "cleared agent events should not open a Codex group")
assert(
  cleared_event_thread.placeholder_marks[1] and cleared_event_thread.placeholder_marks[1].expanded == false,
  "cleared agent events should default to collapsed"
)
codex.setup()
local core_pending_thread = state.ensure_thread("smoke-core-pending", {
  title = "Smoke core pending",
  cwd = vim.fn.getcwd(),
})
core_pending_thread.pending_request = { prompt = "core pending", created_at = vim.uv.now() }
local core = require("codex.core")
core.handle_notification({
  method = "turn/started",
  params = {
    threadId = "smoke-core-pending",
    turn = { id = "turn-core", items = {} },
  },
})
assert(
  core_pending_thread.pending_request.turn_id == "turn-core",
  "turn/started should bind pending requests to the active turn"
)
dynamic_tools._mark_native_apply_patch_fallback(
  { threadId = "smoke-core-pending", turnId = "turn-core" },
  core_pending_thread
)
assert(
  dynamic_tools._native_apply_patch_fallback_active({ threadId = "smoke-core-pending", turnId = "turn-core" }),
  "native apply_patch fallback should be active before turn completion"
)
core.handle_notification({
  method = "turn/completed",
  params = {
    threadId = "smoke-core-pending",
    turn = { id = "turn-core", items = {} },
  },
})
assert(
  not dynamic_tools._native_apply_patch_fallback_active({ threadId = "smoke-core-pending", turnId = "turn-core" }),
  "turn/completed should clear native apply_patch fallback"
)
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
