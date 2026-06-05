vim.opt.runtimepath:append(".")

local codex = require("codex")
codex.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CodexNvimLifecycle", event = "VimLeavePre" }) == 1,
  "explicit setup should register lifecycle cleanup"
)
local start_params = codex._thread_start_params({ cwd = vim.fn.getcwd() })
assert(
  type(start_params.developerInstructions) == "string"
    and start_params.developerInstructions:match("native apply_patch"),
  "thread/start should instruct Codex to use native apply_patch in pair mode"
)
assert(
  start_params.developerInstructions:match("PreToolUse hook")
    and start_params.developerInstructions:match("updatedInput%.command"),
  "pair edit mode should route native apply_patch through Neovim hook review"
)
assert(
  start_params.developerInstructions:match("Do not request dangerous approval"),
  "pair edit mode should not ask Codex to bypass approvals for native apply_patch"
)
assert(
  start_params.developerInstructions:match("Do not call nvim%.apply_patch"),
  "pair edit mode should not ask Codex to use nvim.apply_patch"
)
assert(
  not start_params.developerInstructions:match("Patch syntax must match")
    and not start_params.developerInstructions:match("%*%*%* Add File:")
    and not start_params.developerInstructions:match("pair%-coding feedback"),
  "thread/start should not duplicate the native apply_patch tool protocol"
)
assert(
  not (start_params.config and start_params.config.bypass_hook_trust == true),
  "thread/start should not enable global hook trust bypass for Neovim apply_patch review"
)
local composed_instructions = codex._compose_developer_instructions("custom instruction")
assert(composed_instructions:match("custom instruction"), "default edit instruction should preserve user instructions")
assert(composed_instructions:match("native apply_patch"), "default edit instruction should mention native apply_patch")
local dynamic_tools_for_config = require("codex.dynamic_tools")
local pair_specs = dynamic_tools_for_config.specs() or {}
assert(not vim.iter(pair_specs):any(function(spec)
  return spec.namespace == "nvim" and spec.name == "apply_patch"
end), "pair edit mode should not expose nvim.apply_patch")
local native_hook = require("codex.native_apply_patch_hook")
assert(
  native_hook._hook_config_arg():match("hooks%.PreToolUse")
    and native_hook._hook_config_arg():match("apply_patch")
    and native_hook._hook_config_arg():match("codex%-nvim%-apply%-patch%-hook"),
  "pair edit mode should be able to inject a PreToolUse apply_patch hook"
)
assert(
  not table.concat(native_hook._command_with_hook({ "codex", "app-server" }), " "):match("bypass_hook_trust=true"),
  "pair edit mode should not use global hook trust bypass"
)
local native_hook_trust_edits = native_hook.trust_edits_from_hooks_response({
  data = {
    {
      hooks = {
        {
          enabled = true,
          handlerType = "command",
          eventName = "preToolUse",
          matcher = "^apply_patch$",
          command = native_hook._hook_command(),
          key = "/<session-flags>/config.toml:pre_tool_use:0:0",
          currentHash = "sha256:abc123",
          trustStatus = "untrusted",
        },
      },
    },
  },
})
assert(
  #native_hook_trust_edits == 1
    and native_hook_trust_edits[1].keyPath == 'hooks.state."/<session-flags>/config.toml:pre_tool_use:0:0".trusted_hash'
    and native_hook_trust_edits[1].value == "sha256:abc123",
  "pair edit mode should persist trust for only the injected apply_patch hook hash"
)
local hook_script = table.concat(vim.fn.readfile("scripts/codex-nvim-apply-patch-hook"), "\n")
assert(
  hook_script:match("review_file_async") and hook_script:match("'result':"),
  "apply_patch hook script should queue Neovim review asynchronously and wait on a result file"
)
assert(
  hook_script:match("< /dev/null"),
  "apply_patch hook script should not let Neovim client inherit Codex hook stdin"
)
assert(
  hook_script:match('tmpdir="%${TMPDIR:%-/tmp}"') and hook_script:match('tmpdir="%${tmpdir%%/}"'),
  "apply_patch hook script should normalize TMPDIR before building remote payload paths"
)
do
  local native_hook_gen_dir = vim.fn.tempname()
  vim.fn.mkdir(native_hook_gen_dir, "p")
  vim.fn.writefile({ "one", "two" }, vim.fs.joinpath(native_hook_gen_dir, "smoke-native-hook.txt"))
  local native_hook_completion_patch = native_hook._noop_patch(native_hook_gen_dir, "smoke-native-hook")
  assert(
    native_hook_completion_patch:match("%*%*%* Delete File: %.codex%-nvim%-apply%-patch%-noop")
      and not native_hook_completion_patch:match("%*%*%* Add File:"),
    "native apply_patch hook should return a delete-marker completion patch after Neovim writes"
  )
  local native_hook_marker =
    native_hook_completion_patch:match("%*%*%* Delete File:%s*(%.codex%-nvim%-apply%-patch%-noop[^\n]+)")
  assert(
    native_hook_marker and vim.fn.filereadable(vim.fs.joinpath(native_hook_gen_dir, native_hook_marker)) == 1,
    "native apply_patch hook no-op marker should exist before app-server verification reads it"
  )
  assert(
    dynamic_tools_for_config._changes_from_native_apply_patch(native_hook_gen_dir, native_hook_completion_patch),
    "native apply_patch hook no-op completion patch should validate through Codex apply_patch"
  )
  local stale_marker = vim.fs.joinpath(native_hook_gen_dir, ".codex-nvim-apply-patch-noop-stale")
  local fresh_marker = vim.fs.joinpath(native_hook_gen_dir, ".codex-nvim-apply-patch-noop-fresh")
  vim.fn.writefile({ "stale" }, stale_marker)
  vim.fn.writefile({ "fresh" }, fresh_marker)
  local old_time = os.time() - 600
  vim.uv.fs_utime(stale_marker, old_time, old_time)
  local cleanup_result = native_hook._cleanup_stale_noop_markers(native_hook_gen_dir, 300)
  assert(
    vim.fn.filereadable(stale_marker) == 0
      and vim.fn.filereadable(fresh_marker) == 1
      and vim.tbl_contains(cleanup_result.removed, ".codex-nvim-apply-patch-noop-stale"),
    "native apply_patch hook should clean only stale no-op markers"
  )
  vim.fn.delete(fresh_marker)
  local native_hook_review_file = vim.fs.joinpath(native_hook_gen_dir, "native-hook-review.txt")
  vim.fn.writefile({ "left", "right" }, native_hook_review_file)
  local native_hook_review_output = nil
  native_hook.review_payload_async({
    cwd = native_hook_gen_dir,
    tool_name = "apply_patch",
    tool_use_id = "native-hook-review",
    tool_input = {
      command = table.concat({
        "*** Begin Patch",
        "*** Update File: native-hook-review.txt",
        "@@",
        " left",
        "-right",
        "+from-codex",
        "*** End Patch",
      }, "\n"),
    },
  }, function(output)
    native_hook_review_output = output
  end)
  local native_hook_review_session = nil
  vim.wait(1000, function()
    local bufnr = vim.fn.bufnr(native_hook_review_file)
    if bufnr > 0 then
      native_hook_review_session = require("codex.patch_session")._active_session(bufnr)
    end
    return native_hook_review_session ~= nil
  end, 20)
  assert(native_hook_review_session, "native apply_patch hook should open file-buffer patch review")
  local native_hook_review_buf = native_hook_review_session.blocks[1].bufnr
  local native_hook_diag_ns = vim.api.nvim_create_namespace("codex-smoke-native-hook-diagnostics")
  vim.diagnostic.set(native_hook_diag_ns, native_hook_review_buf, {
    {
      lnum = 1,
      col = 0,
      message = "native hook edited buffer diagnostic",
      severity = vim.diagnostic.severity.ERROR,
      source = "smoke",
    },
  }, {})
  vim.api.nvim_buf_set_lines(native_hook_review_buf, 1, 2, false, { "from-nvim" })
  require("codex.patch_session")._accept_block(native_hook_review_session, native_hook_review_session.blocks[1])
  vim.wait(1000, function()
    return native_hook_review_output ~= nil
  end, 20)
  assert(native_hook_review_output, "native apply_patch hook file-buffer review should complete")
  assert(
    native_hook_review_output:match('"permissionDecision":"allow"')
      and native_hook_review_output:match("%+from%-nvim")
      and native_hook_review_output:match("%-from%-codex")
      and native_hook_review_output:match("USER MODIFICATIONS TO CODEX PROPOSAL")
      and native_hook_review_output:match("## nvim%.diagnostics")
      and native_hook_review_output:match("native hook edited buffer diagnostic")
      and not native_hook_review_output:match("%+from%-codex"),
    "native apply_patch hook should report user edits and edited-buffer diagnostics in its review summary"
  )
  assert(
    native_hook_review_output:match("%.codex%-nvim%-apply%-patch%-noop")
      and vim.fn.readfile(native_hook_review_file)[2] == "from-nvim",
    "native apply_patch hook should write through the same patch_session path as nvim.apply_patch"
  )
  local native_hook_reject_file = vim.fs.joinpath(native_hook_gen_dir, "native-hook-reject.txt")
  vim.fn.writefile({ "left", "right" }, native_hook_reject_file)
  local native_hook_reject_output = nil
  native_hook.review_payload_async({
    cwd = native_hook_gen_dir,
    tool_name = "apply_patch",
    tool_use_id = "native-hook-reject",
    tool_input = {
      command = table.concat({
        "*** Begin Patch",
        "*** Update File: native-hook-reject.txt",
        "@@",
        " left",
        "-right",
        "+discarded",
        "*** End Patch",
      }, "\n"),
    },
  }, function(output)
    native_hook_reject_output = output
  end)
  local native_hook_reject_session = nil
  vim.wait(1000, function()
    local bufnr = vim.fn.bufnr(native_hook_reject_file)
    if bufnr > 0 then
      native_hook_reject_session = require("codex.patch_session")._active_session(bufnr)
    end
    return native_hook_reject_session ~= nil
  end, 20)
  assert(native_hook_reject_session, "native apply_patch hook should open rejected block review")
  require("codex.patch_session")._reject_block(
    native_hook_reject_session,
    native_hook_reject_session.blocks[1],
    "keep right"
  )
  vim.wait(1000, function()
    return native_hook_reject_output ~= nil
  end, 20)
  assert(
    native_hook_reject_output
      and native_hook_reject_output:match('"permissionDecision":"deny"')
      and native_hook_reject_output:match("User rejected Codex native apply_patch")
      and native_hook_reject_output:match("keep right"),
    "native apply_patch hook should deny all-rejected patches with user rejection feedback"
  )
  assert(
    vim.fn.readfile(native_hook_reject_file)[2] == "right",
    "rejected native hook patch should keep original content"
  )
end
assert(
  native_hook._approval_item_id({ toolUse = { id = "nested-native-approval" } }) == "nested-native-approval",
  "native apply_patch hook review should match nested approval item ids"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("native Codex apply_patch format"),
  "nvim.apply_patch tool description should include native patch protocol"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("directly in arguments%.patch")
    and dynamic_tools_for_config._apply_patch_protocol_text():match("%*%*%* Add File:")
    and dynamic_tools_for_config._apply_patch_protocol_text():match("%*%*%* Update File:")
    and dynamic_tools_for_config._apply_patch_protocol_text():match("%*%*%* Delete File:"),
  "nvim.apply_patch tool description should mirror native apply_patch usage"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("writes only through Neovim"),
  "nvim.apply_patch tool description should preserve Neovim-backed edit semantics"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("pair%-coding feedback"),
  "nvim.apply_patch tool description should frame returned feedback as edit guidance"
)
assert(
  dynamic_tools_for_config._apply_patch_protocol_text():match("Neovim auto%-apply"),
  "nvim.apply_patch tool description should keep auto-apply on the Neovim path"
)
assert(
  dynamic_tools_for_config._stale_patch_retry_message():match("Re%-read the current buffer"),
  "nvim.apply_patch failure guidance should require refreshing buffer state"
);
(function()
  local stale_dir = vim.fn.tempname()
  vim.fn.mkdir(stale_dir, "p")
  vim.fn.writefile({ "current alpha", "current beta" }, vim.fs.joinpath(stale_dir, "stale.txt"))
  local stale_patch = table.concat({
    "*** Begin Patch",
    "*** Update File: stale.txt",
    "@@",
    "-old alpha",
    "+new alpha",
    "*** End Patch",
  }, "\n")
  local stale_context = dynamic_tools_for_config._stale_context_for_patch(stale_dir, stale_patch)
  assert(
    stale_context:match("STALE CONTEXT RECOVERY") and stale_context:match("current alpha"),
    "stale patch recovery should include current file excerpts"
  )
end)()
codex.setup({ edit = { mode = "yolo" } })
local yolo_start_params = codex._thread_start_params({ cwd = vim.fn.getcwd() })
assert(
  yolo_start_params.developerInstructions:match("native apply_patch tool directly"),
  "yolo edit mode should instruct Codex to use native apply_patch directly"
)
assert(
  not yolo_start_params.developerInstructions:match("pair%-coding feedback"),
  "yolo edit mode should not include pair-mode feedback protocol"
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
    arguments = { patch = "*** Begin Patch\n*** Add File: x\n+hi\n*** End Patch\n" },
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
codex.setup({ thread = { model = "gpt-5", service_tier = "fast", reasoning_effort = "high" } })
local configured_composer_labels = metadata.composer_labels({ config = {}, status = "active" })
assert(
  vim.deep_equal(configured_composer_labels, { "gpt-5", "fast", "effort high", "active" }),
  "composer metadata should include configured model, fast tier, and reasoning effort"
)
codex.setup({ thread = { model = "gpt-5", reasoning_effort = "high" } })
local stale_header_thread = state.ensure_thread("smoke-thread-settings-header", {
  config = { model = "gpt-5-codex", service_tier = "fast", reasoning_effort = "xhigh" },
  status = "active",
})
stale_header_thread.settings = { effort = "medium" }
state.apply_thread_settings(stale_header_thread, stale_header_thread.settings)
assert(
  vim.deep_equal(metadata.composer_labels(stale_header_thread), { "gpt-5-codex", "fast", "effort medium", "active" }),
  "composer metadata should prefer updated thread state over stale defaults"
)
local effective_turn_params = codex._turn_start_params("smoke-thread-settings-header", {})
assert(effective_turn_params.effort == "medium", "turn/start should use updated thread reasoning effort")
assert(effective_turn_params.serviceTier == "fast", "turn/start should use updated thread service tier")
stale_header_thread.settings = { serviceTier = vim.NIL }
state.apply_thread_settings(stale_header_thread, stale_header_thread.settings)
assert(
  vim.deep_equal(metadata.composer_labels(stale_header_thread), { "gpt-5-codex", "effort medium", "active" }),
  "composer metadata should stop showing fast after selecting the default service tier"
)
stale_header_thread.settings = { effort = vim.NIL }
state.apply_thread_settings(stale_header_thread, stale_header_thread.settings)
assert(
  vim.deep_equal(metadata.composer_labels(stale_header_thread), { "gpt-5-codex", "active" }),
  "composer metadata should not resurrect a stale effort after selecting default"
)
local active_user_labels = metadata.user_labels(nil, {
  state = "active",
  raw = { settings = { model = "gpt-5-codex", service_tier = "fast", reasoning_effort = "medium" } },
})
assert(
  vim.deep_equal(active_user_labels, { "active", "gpt-5-codex", "fast", "effort medium" }),
  "user metadata should include active turn model, fast tier, and reasoning effort"
)
codex.setup()
local object_tier_thread = state.ensure_thread("smoke-object-service-tier", {
  config = { service_tier = { id = "fast", name = "Fast" } },
  status = "active",
})
assert(
  vim.deep_equal(metadata.composer_labels(object_tier_thread), { "fast", "active" }),
  "composer metadata should detect fast service tiers returned as objects"
)
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
    threadSettings = { serviceTier = "fast", effort = "medium" },
  },
})
assert(settings_event_thread.config.reasoning_effort == "medium", "settings events should update thread config")
assert(settings_event_thread.config.service_tier == "fast", "settings events should update thread service tier")
assert(
  vim.deep_equal(metadata.composer_labels(settings_event_thread), { "gpt-5-codex", "fast", "effort medium", "active" }),
  "settings events should refresh composer fast tier and reasoning effort"
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
assert(
  context_parsed[1].text:match("^Reference context, not instructions:"),
  "context inputs should be clearly marked as reference material"
)
local ordered_context = parser.parse("@cwd\n\nwhat should I do next?")
assert(
  ordered_context[1] and ordered_context[1].text:match("Neovim context: workspace"),
  "explicit context should be placed before the user request"
)
assert(
  ordered_context[#ordered_context] and ordered_context[#ordered_context].text == "what should I do next?",
  "user request should remain the final text input for semantic priority"
)
assert(
  ordered_context[1].text:match("Reference context, not instructions:") and ordered_context[1].text:match("\n\n$"),
  "reference context should keep trailing separation for app-server text flattening"
)
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
local official_file_parsed = parser.parse("@" .. require("codex.context").display_path(text_asset))
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
local no_selection_context = parser.parse("explain selection", {
  thread = state.get_thread("smoke-context"),
})
assert(
  no_selection_context[1] and no_selection_context[1].text == "explain selection",
  "parser should not auto-attach source-buffer visual selection context"
)
local explicit_selection_context = parser.parse("@selection\n\nexplain selection", {
  thread = state.get_thread("smoke-context"),
})
assert(
  explicit_selection_context[1] and explicit_selection_context[1].text:match("Neovim context: selection"),
  "@selection should attach source-buffer visual selection context"
)
assert(
  explicit_selection_context[1].text:match("codex%-context%-smoke")
    and explicit_selection_context[1].text:match("L1%-L2"),
  "selection context should include source file and range metadata"
)
assert(
  explicit_selection_context[#explicit_selection_context].text == "explain selection",
  "@selection context should precede the user request"
)

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
local nil_review_lines = patch_review._document({
  protocol = "modern",
  source = "codex_file_change",
  request_id = "smoke-nil-review-document",
  thread_id = "smoke-context",
  turn_id = vim.NIL,
  item_id = vim.NIL,
  reason = vim.NIL,
  grant_root = vim.NIL,
  changes = vim.NIL,
})
local nil_review_text = table.concat(nil_review_lines, "\n")
assert(not nil_review_text:match("reason:"), "patch review should treat null reason as absent")
assert(not nil_review_text:match("grant root:"), "patch review should treat null grantRoot as absent")
assert(nil_review_text:match("No patch details"), "patch review should tolerate null changes")
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
state.upsert_item("smoke-context", "smoke-nil-turn", {
  id = "smoke-nil-item",
  changes = {
    {
      kind = vim.NIL,
      path = "codex-context-smoke.lua",
      diff = table.concat({
        "--- a/codex-context-smoke.lua",
        "+++ b/codex-context-smoke.lua",
        "@@ -1,2 +1,3 @@",
        " local codex_context_smoke = true",
        "+local nil_review_anchor = true",
        " return codex_context_smoke",
      }, "\n"),
    },
  },
})
local nil_request_buf = patch_review.request_approval({
  id = "smoke-nil-approval",
  method = "item/fileChange/requestApproval",
  params = {
    threadId = "smoke-context",
    turnId = vim.NIL,
    itemId = "smoke-nil-item",
    reason = vim.NIL,
    grantRoot = vim.NIL,
  },
})
assert(nil_request_buf and vim.api.nvim_buf_is_valid(nil_request_buf), "patch approval should open with null fields")
local nil_request_text = table.concat(vim.api.nvim_buf_get_lines(nil_request_buf, 0, -1, false), "\n")
assert(not nil_request_text:match("reason:"), "patch approval should omit null reason")
assert(nil_request_text:match("## update codex%-context%-smoke%.lua"), "patch approval should normalize null kind")
assert(state.pop_pending_request("smoke-nil-approval"), "patch approval should record pending request after opening")
for _, winid in ipairs(vim.fn.win_findbuf(nil_request_buf)) do
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
end
if vim.api.nvim_buf_is_valid(nil_request_buf) then
  vim.api.nvim_buf_delete(nil_request_buf, { force = true })
end
local original_patch_review_open = patch_review.open
local original_rpc_respond_for_failed_review = require("codex.rpc").respond
local failed_review_response = nil
require("codex.rpc").respond = function(id, result)
  failed_review_response = { id = id, result = result }
end
patch_review.open = function()
  error("smoke patch review failure")
end
local failed_review_buf = patch_review.request_approval({
  id = "smoke-failed-approval",
  method = "item/fileChange/requestApproval",
  params = {
    threadId = "smoke-context",
    turnId = "smoke-nil-turn",
    itemId = "smoke-nil-item",
  },
})
patch_review.open = original_patch_review_open
require("codex.rpc").respond = original_rpc_respond_for_failed_review
assert(failed_review_buf == nil, "failed patch review should not return a buffer")
assert(
  failed_review_response
    and failed_review_response.id == "smoke-failed-approval"
    and failed_review_response.result.decision == "cancel",
  "failed patch review should cancel the app-server approval"
)
assert(not state.pop_pending_request("smoke-failed-approval"), "failed patch review should not leave a pending request")
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
vim.fn.writefile({ "one", "two" }, vim.fs.joinpath(patch_dir, "native.txt"))
local native_apply_patch = table.concat({
  "*** Begin Patch",
  "*** Update File: native.txt",
  "@@",
  " one",
  "-two",
  "+three",
  "*** End Patch",
}, "\n")
local native_changes, native_err = dynamic_tools._changes_from_native_apply_patch(patch_dir, native_apply_patch)
assert(native_changes, native_err)
assert(
  #native_changes == 1
    and native_changes[1].path == "native.txt"
    and native_changes[1].diff:match("%-two")
    and native_changes[1].diff:match("%+three"),
  "nvim.apply_patch should convert native Codex apply_patch edits to review diffs"
)
local absolute_native_target = vim.fn.tempname() .. ".txt"
local absolute_native_patch = table.concat({
  "*** Begin Patch",
  "*** Add File: " .. absolute_native_target,
  "+absolute",
  "*** End Patch",
}, "\n")
local rejected_absolute_native_changes, rejected_absolute_native_err =
  dynamic_tools._changes_from_native_apply_patch(patch_dir, absolute_native_patch)
assert(
  not rejected_absolute_native_changes and rejected_absolute_native_err:match("must be relative"),
  "nvim.apply_patch should keep rejecting absolute native patch paths by default"
)
local absolute_native_changes, absolute_native_err =
  dynamic_tools._changes_from_native_apply_patch(patch_dir, absolute_native_patch, { allow_absolute = true })
assert(absolute_native_changes, absolute_native_err)
assert(
  #absolute_native_changes == 1
    and absolute_native_changes[1].path == vim.fs.normalize(absolute_native_target)
    and absolute_native_changes[1].diff:match("%+absolute"),
  "native Codex apply_patch review should accept absolute paths"
)
assert(
  vim.fn.filereadable(absolute_native_target) == 0,
  "native Codex apply_patch review should not write absolute paths during verification"
)
local native_written = false
require("codex.patch_session").open({
  cwd = patch_dir,
  changes = native_changes,
  interactive = false,
  on_complete = function(summary, success)
    assert(success, summary)
    native_written = true
  end,
})
assert(native_written, "native nvim.apply_patch review should complete when accepted non-interactively")
assert(
  vim.fn.readfile(vim.fs.joinpath(patch_dir, "native.txt"))[2] == "three",
  "native nvim.apply_patch should write accepted edits"
)
vim.fn.writefile({ "left", "right" }, vim.fs.joinpath(patch_dir, "review-only.txt"))
local review_only_patch = table.concat({
  "*** Begin Patch",
  "*** Update File: review-only.txt",
  "@@",
  " left",
  "-right",
  "+changed",
  "*** End Patch",
}, "\n")
local review_only_changes = assert(dynamic_tools._changes_from_native_apply_patch(patch_dir, review_only_patch))
local review_only_seen_final = false
require("codex.patch_session").open({
  cwd = patch_dir,
  changes = review_only_changes,
  interactive = false,
  apply_on_complete = false,
  restore_on_complete = true,
  on_complete = function(_, success, session_result)
    assert(success, "review-only patch session should still report accepted blocks as success")
    review_only_seen_final = session_result.file_order[1].final_lines[2] == "changed"
  end,
})
assert(review_only_seen_final, "review-only patch session should expose accepted final buffer lines")
assert(
  vim.fn.readfile(vim.fs.joinpath(patch_dir, "review-only.txt"))[2] == "right",
  "review-only patch session should restore buffers without writing accepted edits"
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
    assert(not success, "rejected block should report a failed/partial patch review")
    assert(summary:match("keep beta"), "patch review summary should include rejection feedback")
    session_done = true
  end,
})
assert(
  vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())) == vim.uv.fs_realpath(session_file),
  "nvim.apply_patch review should open directly in the edited file buffer"
)
assert(patch_session._active_session(0) == session, "patch session should track active edited buffers")
local diff_ns = vim.api.nvim_get_namespaces()["codex.patch_session.diff"]
local session_hunk = session.hunks[1]
local session_block = session.blocks[1]
assert(
  #session_hunk.changed_blocks == 1
    and #session_hunk.changed_blocks[1].old_lines == 1
    and #session_hunk.changed_blocks[1].new_lines == 1,
  "patch session should distinguish changed lines from hunk context"
)
local session_add_mark = vim.api.nvim_buf_get_extmark_by_id(
  session_hunk.bufnr,
  diff_ns,
  session_hunk.display_extmark_ids[1],
  { details = true }
)
assert(
  session_add_mark[1] == 1 and session_add_mark[3].end_row == 2,
  "patch session should highlight only the changed replacement line"
)
local session_old_mark =
  vim.api.nvim_buf_get_extmark_by_id(session_hunk.bufnr, diff_ns, session_hunk.old_extmark_ids[1], { details = true })
local session_old_virtual = vim.inspect(session_old_mark[3].virt_lines)
assert(
  session_old_virtual:match("%- beta")
    and not session_old_virtual:match("alpha")
    and not session_old_virtual:match("gamma"),
  "patch session should show only deleted lines as old virtual diff content"
)
patch_session._reject_block(session, session_block, "keep beta")
vim.wait(1000, function()
  return session_done
end, 20)
assert(vim.fn.readfile(session_file)[2] == "beta", "rejected patch block should restore original file content")
do
  local previous_active_thread_id = require("codex.state").active_thread_id
  vim.cmd("tabnew")
  local codex_review_win = vim.api.nvim_get_current_win()
  local codex_review_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(codex_review_buf, "codex://thread/smoke-patch-window")
  vim.bo[codex_review_buf].buftype = "nofile"
  vim.bo[codex_review_buf].filetype = "codex"
  vim.b[codex_review_buf].codex_thread_id = "smoke-patch-window"
  vim.api.nvim_win_set_buf(codex_review_win, codex_review_buf)
  local smoke_window_state = require("codex.state")
  smoke_window_state.set_buffer("smoke-patch-window", codex_review_buf, codex_review_win)
  local preserve_chat_file = vim.fs.joinpath(session_dir, "preserve-chat.txt")
  vim.fn.writefile({ "chat", "old" }, preserve_chat_file)
  local preserve_chat_patch = table.concat({
    "diff --git a/preserve-chat.txt b/preserve-chat.txt",
    "--- a/preserve-chat.txt",
    "+++ b/preserve-chat.txt",
    "@@ -1,2 +1,2 @@",
    " chat",
    "-old",
    "+new",
  }, "\n")
  local preserve_chat_session = patch_session.open({
    cwd = session_dir,
    thread_id = "smoke-patch-window",
    changes = dynamic_tools._changes_from_unified_patch(preserve_chat_patch),
  })
  assert(
    vim.api.nvim_win_get_buf(codex_review_win) == codex_review_buf,
    "patch session should not replace the Codex chat window with the review file buffer"
  )
  assert(
    vim.api.nvim_get_current_win() ~= codex_review_win and patch_session._active_session(0) == preserve_chat_session,
    "patch session should open a separate review window when launched from a Codex chat buffer"
  )
  patch_session._accept_block(preserve_chat_session, preserve_chat_session.blocks[1])
  assert(vim.fn.readfile(preserve_chat_file)[2] == "new", "separate review window should still write accepted edits")
  vim.cmd("tabclose")
  smoke_window_state.active_thread_id = previous_active_thread_id
end
local delete_only_file = vim.fs.joinpath(session_dir, "delete-only.txt")
vim.fn.writefile({ "left context", "remove this", "right context" }, delete_only_file)
local delete_only_patch = table.concat({
  "diff --git a/delete-only.txt b/delete-only.txt",
  "--- a/delete-only.txt",
  "+++ b/delete-only.txt",
  "@@ -1,3 +1,2 @@",
  " left context",
  "-remove this",
  " right context",
}, "\n")
local delete_only_session = patch_session.open({
  cwd = session_dir,
  changes = dynamic_tools._changes_from_unified_patch(delete_only_patch),
})
local delete_only_hunk = delete_only_session.hunks[1]
local delete_only_mark = vim.api.nvim_buf_get_extmark_by_id(
  delete_only_hunk.bufnr,
  diff_ns,
  delete_only_hunk.display_extmark_ids[1],
  { details = true }
)
local delete_only_old_mark = vim.api.nvim_buf_get_extmark_by_id(
  delete_only_hunk.bufnr,
  diff_ns,
  delete_only_hunk.old_extmark_ids[1],
  { details = true }
)
local delete_only_virtual = vim.inspect(delete_only_old_mark[3].virt_lines)
assert(
  #delete_only_hunk.display_extmark_ids == 1
    and delete_only_mark[1] == 1
    and delete_only_mark[3].virt_text[1][1]:match("%[deleted 1 line%]")
    and delete_only_virtual:match("%- remove this")
    and not delete_only_virtual:match("left context")
    and not delete_only_virtual:match("right context"),
  "patch session should render deletion-only blocks without context lines"
)
patch_session._accept_block(delete_only_session, delete_only_session.blocks[1])
local multi_file = vim.fs.joinpath(session_dir, "multi.txt")
vim.fn.writefile({ "top", "old one", "middle", "old two", "bottom" }, multi_file)
local multi_patch = table.concat({
  "diff --git a/multi.txt b/multi.txt",
  "--- a/multi.txt",
  "+++ b/multi.txt",
  "@@ -1,5 +1,5 @@",
  " top",
  "-old one",
  "+new one",
  " middle",
  "-old two",
  "+new two",
  " bottom",
}, "\n")
local multi_done = false
local multi_session = patch_session.open({
  cwd = session_dir,
  changes = dynamic_tools._changes_from_unified_patch(multi_patch),
  on_complete = function(summary, success, session_result)
    assert(not success, "partially rejected blocks should report a partial patch review")
    assert(summary:match("keep old one"), "block-level patch review should report the rejected block reason")
    multi_done = session_result.accepted_blocks == 1 and session_result.rejected_blocks == 1
  end,
})
local multi_hunk = multi_session.hunks[1]
assert(
  #multi_session.hunks == 1
    and #multi_session.blocks == 2
    and #multi_hunk.changed_blocks == 2
    and #multi_hunk.display_extmark_ids == 2
    and #multi_hunk.old_extmark_ids == 2,
  "patch session should keep one review hunk while rendering multiple changed blocks"
)
local first_multi_mark =
  vim.api.nvim_buf_get_extmark_by_id(multi_hunk.bufnr, diff_ns, multi_hunk.display_extmark_ids[1], { details = true })
local second_multi_mark =
  vim.api.nvim_buf_get_extmark_by_id(multi_hunk.bufnr, diff_ns, multi_hunk.display_extmark_ids[2], { details = true })
assert(
  first_multi_mark[1] == 1
    and first_multi_mark[3].end_row == 2
    and second_multi_mark[1] == 3
    and second_multi_mark[3].end_row == 4,
  "patch session should render each changed block without highlighting intervening context"
)
patch_session._reject_block(multi_session, multi_session.blocks[1], "keep old one")
assert(
  not multi_session.completed and multi_session.blocks[1].status == "rejected" and not multi_session.blocks[2].status,
  "rejecting one patch block should leave other blocks in the same hunk pending"
)
patch_session._accept_block(multi_session, multi_session.blocks[2])
vim.wait(1000, function()
  return multi_done
end, 20)
assert(multi_done, "mixed block decisions should complete the patch session")
local multi_lines = vim.fn.readfile(multi_file)
assert(
  multi_lines[2] == "old one" and multi_lines[4] == "new two",
  "block-level patch review should allow mixed decisions inside one hunk"
);
(function()
  local shift_file = vim.fs.joinpath(session_dir, "shift.txt")
  vim.fn.writefile({ "top", "remove me", "middle", "old tail", "bottom" }, shift_file)
  local shift_patch = table.concat({
    "diff --git a/shift.txt b/shift.txt",
    "--- a/shift.txt",
    "+++ b/shift.txt",
    "@@ -1,5 +1,4 @@",
    " top",
    "-remove me",
    " middle",
    "-old tail",
    "+new tail",
    " bottom",
  }, "\n")
  local shift_session = patch_session.open({
    cwd = session_dir,
    changes = dynamic_tools._changes_from_unified_patch(shift_patch),
  })
  assert(
    #shift_session.hunks == 1 and #shift_session.blocks == 2,
    "line-shifting patch review should still split changed blocks inside one hunk"
  )
  patch_session._reject_block(shift_session, shift_session.blocks[1], "keep removed line")
  patch_session._accept_block(shift_session, shift_session.blocks[2])
  local shift_lines = vim.fn.readfile(shift_file)
  assert(
    table.concat(shift_lines, "\n") == "top\nremove me\nmiddle\nnew tail\nbottom",
    "rejecting a line-shifting block should keep later block approvals aligned"
  )
end)()
codex.setup({ dynamic_tools = { prefer_nvim_apply_patch = true } })
local tool_dir = vim.fn.tempname()
vim.fn.mkdir(tool_dir, "p")
local tool_file = vim.fs.joinpath(tool_dir, "tool.txt")
vim.fn.writefile({ "red", "green", "blue" }, tool_file)
local tool_patch = table.concat({
  "*** Begin Patch",
  "*** Update File: tool.txt",
  "@@",
  " red",
  "-green",
  "+emerald",
  " blue",
  "*** End Patch",
}, "\n")
local rpc = require("codex.rpc")
local original_rpc_respond = rpc.respond;
(function()
  local stale_tool_file = vim.fs.joinpath(tool_dir, "stale-tool.txt")
  vim.fn.writefile({ "fresh red", "fresh green" }, stale_tool_file)
  local stale_tool_response = nil
  rpc.respond = function(id, result)
    assert(id == "tool-apply-stale", "stale dynamic tool should respond to the original request id")
    stale_tool_response = result
  end
  dynamic_tools.handle_call({
    id = "tool-apply-stale",
    params = {
      namespace = "nvim",
      tool = "apply_patch",
      threadId = "smoke-context",
      arguments = {
        cwd = tool_dir,
        patch = table.concat({
          "*** Begin Patch",
          "*** Update File: stale-tool.txt",
          "@@",
          "-old red",
          "+new red",
          "*** End Patch",
        }, "\n"),
      },
    },
  })
  rpc.respond = original_rpc_respond
  assert(stale_tool_response and stale_tool_response.success == false, "stale dynamic patch should fail")
  assert(
    stale_tool_response.contentItems[1].text:match("STALE CONTEXT RECOVERY")
      and stale_tool_response.contentItems[1].text:match("fresh red"),
    "stale dynamic patch response should include current file excerpts"
  )
end)()
local smoke_diag_ns = vim.api.nvim_create_namespace("codex-smoke-apply-patch-diagnostics")
vim.diagnostic.set(smoke_diag_ns, source_buf, {
  {
    lnum = 0,
    col = 6,
    message = "smoke target diagnostic",
    severity = vim.diagnostic.severity.WARN,
  },
}, {})
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
assert(tool_session and tool_session.blocks[1], "nvim.apply_patch dynamic tool should open an in-buffer patch session")
patch_session._reject_block(tool_session, tool_session.blocks[1], "not this color")
vim.wait(1000, function()
  return tool_response ~= nil
end, 20)
rpc.respond = original_rpc_respond
assert(tool_response and tool_response.success == false, "rejected dynamic patch should respond as unsuccessful")
assert(
  tool_response.contentItems[1].text:match("not this color"),
  "dynamic nvim.apply_patch response should include rejection feedback"
)
assert(
  tool_response.contentItems[1].text:match("## nvim%.diagnostics")
    and tool_response.contentItems[1].text:match("smoke target diagnostic"),
  "dynamic nvim.apply_patch response should include target buffer diagnostics"
)
local accept_tool_file = vim.fs.joinpath(tool_dir, "accepted.txt")
vim.fn.writefile({ "cyan", "magenta", "yellow" }, accept_tool_file)
local accept_tool_patch = table.concat({
  "*** Begin Patch",
  "*** Update File: accepted.txt",
  "@@",
  " cyan",
  "-magenta",
  "+violet",
  " yellow",
  "*** End Patch",
}, "\n")
local accept_tool_response = nil
rpc.respond = function(id, result)
  assert(id == "tool-apply-accept", "accepted dynamic tool should respond to the original request id")
  accept_tool_response = result
end
dynamic_tools.handle_call({
  id = "tool-apply-accept",
  params = {
    namespace = "nvim",
    tool = "apply_patch",
    threadId = "smoke-context",
    arguments = {
      cwd = tool_dir,
      patch = accept_tool_patch,
    },
  },
})
local accept_tool_session = patch_session._active_session(0)
assert(accept_tool_session and accept_tool_session.blocks[1], "accepted nvim.apply_patch should open a patch session")
patch_session._accept_block(accept_tool_session, accept_tool_session.blocks[1])
vim.wait(1000, function()
  return accept_tool_response ~= nil
end, 20)
rpc.respond = original_rpc_respond
assert(
  accept_tool_response and accept_tool_response.success == true,
  "accepted dynamic patch should respond as successful"
)
assert(
  accept_tool_response.contentItems[1].text:match("## nvim%.diagnostics")
    and accept_tool_response.contentItems[1].text:match("smoke target diagnostic"),
  "successful dynamic nvim.apply_patch response should include target buffer diagnostics"
)
assert(vim.fn.readfile(accept_tool_file)[2] == "violet", "accepted dynamic patch should write accepted file content")
local auto_apply_tool_file = vim.fs.joinpath(tool_dir, "auto-apply.txt")
vim.fn.writefile({ "north", "center", "south" }, auto_apply_tool_file)
local auto_apply_tool_patch = table.concat({
  "*** Begin Patch",
  "*** Update File: auto-apply.txt",
  "@@",
  " north",
  "-center",
  "+middle",
  " south",
  "*** End Patch",
}, "\n")
local auto_apply_tool_response = nil
rpc.respond = function(id, result)
  assert(id == "tool-apply-auto", "auto-applied dynamic tool should respond to the original request id")
  auto_apply_tool_response = result
end
dynamic_tools._mark_nvim_apply_patch_auto_apply({ threadId = "smoke-context", turnId = "turn-auto-apply" })
dynamic_tools.handle_call({
  id = "tool-apply-auto",
  params = {
    namespace = "nvim",
    tool = "apply_patch",
    threadId = "smoke-context",
    turnId = "turn-auto-apply",
    arguments = {
      cwd = tool_dir,
      patch = auto_apply_tool_patch,
    },
  },
})
vim.wait(1000, function()
  return auto_apply_tool_response ~= nil
end, 20)
rpc.respond = original_rpc_respond
assert(
  auto_apply_tool_response and auto_apply_tool_response.success == true,
  "Neovim auto-apply should report successful dynamic patches"
)
assert(
  auto_apply_tool_response.contentItems[1].text:match("Neovim auto%-apply")
    and auto_apply_tool_response.contentItems[1].text:match("nvim%.apply_patch"),
  "Neovim auto-apply response should keep the agent on nvim.apply_patch"
)
assert(vim.fn.readfile(auto_apply_tool_file)[2] == "middle", "Neovim auto-apply should write through Neovim")
dynamic_tools.clear_thread_state("smoke-context")
vim.diagnostic.reset(smoke_diag_ns, source_buf)
assert(vim.fn.readfile(tool_file)[2] == "green", "dynamic patch rejection should preserve original file content")
local auto_apply_thread = { id = "thread-auto-apply", active_turn_id = "turn-auto-apply" }
local auto_apply_params = { threadId = "thread-auto-apply", turnId = "turn-auto-apply" }
assert(
  not dynamic_tools._nvim_apply_patch_auto_apply_active(auto_apply_params, auto_apply_thread),
  "Neovim auto-apply should start disabled"
)
dynamic_tools._mark_nvim_apply_patch_auto_apply(auto_apply_params, auto_apply_thread)
assert(
  dynamic_tools._nvim_apply_patch_auto_apply_active(auto_apply_params, auto_apply_thread),
  "accept-for-session should enable Neovim auto-apply for the session"
)
assert(
  dynamic_tools._nvim_apply_patch_auto_apply_message():match("nvim%.apply_patch"),
  "Neovim auto-apply message should keep Codex on the Neovim tool path"
)
dynamic_tools.clear_thread_state("thread-auto-apply")
assert(
  not dynamic_tools._nvim_apply_patch_auto_apply_active(auto_apply_params, auto_apply_thread),
  "thread cleanup should clear Neovim auto-apply"
)
dynamic_tools._mark_nvim_apply_patch_auto_apply(auto_apply_params, auto_apply_thread, "turn")
assert(
  dynamic_tools._nvim_apply_patch_auto_apply_active(auto_apply_params, auto_apply_thread),
  "turn-scoped Neovim auto-apply should be supported"
)
dynamic_tools.clear_turn_state("thread-auto-apply", "turn-auto-apply")
assert(
  not dynamic_tools._nvim_apply_patch_auto_apply_active(auto_apply_params, auto_apply_thread),
  "turn cleanup should clear turn-scoped Neovim auto-apply"
)
codex.setup()

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

local selection_completion_done = false
source:get_completions({
  bufnr = context_thread_buf,
  line = "@sel",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "@selection", "completion should return @selection")
  assert(
    result.items[1].documentation
      and result.items[1].documentation:match("local codex_context_smoke")
      and result.items[1].documentation:match("L1%-L2"),
    "@selection completion should preview source-buffer selection content"
  )
  selection_completion_done = true
end)
assert(selection_completion_done, "selection completion callback should run synchronously")
pcall(vim.api.nvim_buf_del_mark, source_buf, "<")
pcall(vim.api.nvim_buf_del_mark, source_buf, ">")

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
state.ensure_thread("thread-fast-status", {
  config = { model = "gpt-5-codex", service_tier = "fast" },
  status = "active",
})
local util = require("codex.util")
local original_notify = util.notify
local fast_status_message = nil
util.notify = function(message)
  fast_status_message = message
end
rpc.request = function(method, params, callback)
  assert(method == "model/list", "slash /fast status should request model/list")
  callback(nil, {
    data = {
      {
        id = "gpt-5-codex",
        model = "gpt-5-codex",
        hidden = false,
        isDefault = true,
        serviceTiers = {
          { id = "standard", name = "Standard" },
          { id = "fast", name = "Fast" },
        },
      },
    },
    nextCursor = vim.NIL,
  })
end
slash.dispatch("/fast status", "thread-fast-status", {
  ensure_server = function(callback)
    callback()
  end,
})
rpc.request = original_rpc_request
util.notify = original_notify
assert(fast_status_message == "Fast tier: on", "/fast status should read the effective thread service tier")
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
local original_rpc_request_for_hook_refresh = rpc.request
local hook_trust_requests = {}
local hook_trust_done = false
rpc.request = function(method, params, callback)
  table.insert(hook_trust_requests, { method = method, params = params })
  if method == "hooks/list" then
    callback(nil, {
      data = {
        {
          hooks = {
            {
              enabled = true,
              handlerType = "command",
              eventName = "preToolUse",
              matcher = "^apply_patch$",
              command = native_hook._hook_command(),
              key = "/<session-flags>/config.toml:pre_tool_use:0:0",
              currentHash = "sha256:abc123",
              trustStatus = "untrusted",
            },
          },
        },
      },
    })
  elseif method == "config/batchWrite" then
    callback(nil, { status = "ok" })
  else
    callback({ message = "unexpected method " .. tostring(method) })
  end
end
rpc._register_native_hook_trust(function(err)
  assert(err == nil, err and err.message or "native apply_patch hook trust should register")
  hook_trust_done = true
end)
rpc.request = original_rpc_request_for_hook_refresh
assert(hook_trust_done, "native apply_patch hook trust registration should complete")
assert(
  #hook_trust_requests == 2
    and hook_trust_requests[1].method == "hooks/list"
    and hook_trust_requests[2].method == "config/batchWrite",
  "native apply_patch hook trust should list hooks then write the trusted hash"
)
assert(
  hook_trust_requests[2].params.edits[1].keyPath
      == 'hooks.state."/<session-flags>/config.toml:pre_tool_use:0:0".trusted_hash'
    and hook_trust_requests[2].params.edits[1].value == "sha256:abc123"
    and hook_trust_requests[2].params.reloadUserConfig == true,
  "native apply_patch hook trust should write the quoted hook trusted_hash"
)

local smoke_codex_home = vim.fn.tempname()
vim.fn.mkdir(smoke_codex_home, "p")
local previous_codex_home = vim.env.CODEX_HOME
vim.env.CODEX_HOME = smoke_codex_home
local rpc_done = false
rpc.start(function(err)
  assert(err == nil, err and err.message or "app-server should initialize")
  rpc_done = true
end)
vim.wait(3000, function()
  return rpc_done
end, 20)
assert(rpc_done, "app-server initialize timed out")
vim.env.CODEX_HOME = previous_codex_home
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
local repaired_fence_block = events.block_for_item({
  id = "user-fence",
  type = "userMessage",
  content = {
    { type = "text", text = "```typst\nlet x = 1\n```next prompt", text_elements = {} },
  },
}, "turn-fence")
assert(
  repaired_fence_block.text:match("```%s*\nnext prompt"),
  "userMessage rendering should repair flattened fenced context boundaries"
)
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
thread.pending_request = {
  prompt = "not echoed yet",
  settings = { model = "gpt-5-codex", service_tier = "fast", reasoning_effort = "medium" },
  created_at = vim.uv.now(),
}
local pending_header_blocks = events.pending_blocks(thread)
assert(#pending_header_blocks == 1, "pending user block should render before userMessage echo")
assert(
  vim.deep_equal(metadata.user_labels(thread, pending_header_blocks[1]), {
    "submitted",
    "gpt-5-codex",
    "fast",
    "effort medium",
  }),
  "pending userMessage headers should use submitted turn settings"
)
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
  serviceTier = "fast",
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
    "fast",
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
do
  local markdown_guard_thread = state.ensure_thread("smoke-markdown-guard", {
    title = "Smoke markdown guard",
    cwd = vim.fn.getcwd(),
  })
  local unclosed_agent_text = "```diff\n+ leaked highlight"
  state.upsert_item("smoke-markdown-guard", "turn-markdown-guard", {
    id = "assistant-markdown-guard",
    type = "agentMessage",
    text = unclosed_agent_text,
  })
  state.upsert_item("smoke-markdown-guard", "turn-after-markdown-guard", {
    id = "user-after-markdown-guard",
    type = "userMessage",
    content = {
      { type = "text", text = "after the fence", text_elements = {} },
    },
  })
  local markdown_guard_buf = buffers.ensure("smoke-markdown-guard")
  render.render(markdown_guard_thread)
  local markdown_guard_lines = vim.api.nvim_buf_get_lines(markdown_guard_buf, 0, -1, false)
  local markdown_guard_close = nil
  local user_header_after_guard = nil
  for index, line in ipairs(markdown_guard_lines) do
    if line == "```" and not markdown_guard_close then
      markdown_guard_close = index
    elseif markdown_guard_close and line == "## You" then
      user_header_after_guard = index
      break
    end
  end
  assert(markdown_guard_close ~= nil, "assistant rendering should close unclosed fenced code blocks")
  assert(
    markdown_guard_thread.items["assistant-markdown-guard"].text == unclosed_agent_text,
    "markdown fence guard should not mutate raw assistant messages"
  )
  assert(
    user_header_after_guard and markdown_guard_close < user_header_after_guard,
    "markdown fence guard should close the assistant block before the next user header"
  )
  assert(
    markdown_guard_thread.auto_closed_fence_lines[1] == markdown_guard_close,
    "markdown fence guard should record the render-only auto-close line"
  )
  assert(
    vim.treesitter.highlighter.active and vim.treesitter.highlighter.active[markdown_guard_buf],
    "codex markdown rendering should keep native buffer-wide Tree-sitter highlighting"
  )
end
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
codex.setup();
(function()
  local final_compact_thread = state.ensure_thread("smoke-final-activity", {
    title = "Smoke final activity",
    cwd = vim.fn.getcwd(),
    generation = "idle",
  })
  state.upsert_item("smoke-final-activity", "turn-final", {
    id = "reasoning-final",
    type = "reasoning",
    summary = { "checked the UI state" },
    content = { "kept intermediate details" },
    status = "completed",
  })
  state.upsert_item("smoke-final-activity", "turn-final", {
    id = "tool-final",
    type = "commandExecution",
    command = "echo done",
    cwd = vim.fn.getcwd(),
    status = "completed",
    aggregatedOutput = "done",
    exitCode = 0,
  })
  state.upsert_item("smoke-final-activity", "turn-final", {
    id = "commentary-final",
    type = "agentMessage",
    text = "intermediate progress update",
    status = "commentary",
  })
  state.upsert_item("smoke-final-activity", "turn-final", {
    id = "assistant-final",
    type = "agentMessage",
    text = "final answer",
    status = "completed",
  })
  final_compact_thread.timeline_blocks = {
    {
      type = "AgentTimelineBlock",
      message_id = "turn-final",
      item_id = "timeline-final",
      title = "Model rerouted",
      state = "rerouted",
      text = "gpt-5 -> gpt-5.1",
      local_only = true,
    },
  }
  local final_blocks = render.select_render_tree(final_compact_thread)
  local summary_block = nil
  local standalone_activity = 0
  local assistant_seen = false
  local commentary_index = nil
  local summary_index = nil
  local final_index = nil
  for index, block in ipairs(final_blocks) do
    if block.type == "ActivitySummaryBlock" then
      summary_block = block
      summary_index = index
    elseif
      block.type == "ReasoningBlock"
      or block.type == "ToolCallBlock"
      or block.type == "PatchBlock"
      or block.type == "PlanBlock"
      or block.type == "AgentTimelineBlock"
    then
      standalone_activity = standalone_activity + 1
    elseif block.type == "AssistantBlock" and block.state == "commentary" then
      commentary_index = index
    elseif block.type == "AssistantBlock" and block.text == "final answer" then
      assistant_seen = true
      final_index = index
    end
  end
  assert(summary_block ~= nil, "completed assistant turns should compact activity into one summary block")
  assert(assistant_seen, "completed activity compaction should keep the final assistant answer visible")
  assert(commentary_index ~= nil, "completed activity compaction should keep commentary visible")
  assert(
    commentary_index < summary_index and summary_index < final_index,
    "completed activity summary should separate commentary from final answer"
  )
  assert(standalone_activity == 0, "completed activity compaction should hide standalone reasoning/tool/agent rows")
  assert(
    summary_block.children and #summary_block.children == 3,
    "completed activity summary should retain reasoning, tool, and agent timeline children"
  )
  assert(
    summary_block.text:match("### Reasoning")
      and summary_block.text:match("echo done")
      and summary_block.text:match("Agent: Model rerouted"),
    "completed activity summary should preserve child details"
  )
  local final_compact_buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(final_compact_thread, final_compact_buf)
  render.render(final_compact_thread)
  local final_compact_lines = vim.api.nvim_buf_get_lines(final_compact_buf, 0, -1, false)
  assert(vim.tbl_contains(final_compact_lines, "final answer"), "completed activity render should show final answer")
  assert(
    final_compact_thread.placeholder_marks[1]
      and final_compact_thread.placeholder_marks[1].block.type == "ActivitySummaryBlock"
      and final_compact_thread.placeholder_marks[1].title == "Thinking finished",
    "completed activity render should expose one collapsed thinking-finished row"
  )
  local final_detail_lines = require("codex.ui.detail").lines_for(summary_block)
  assert(
    table.concat(final_detail_lines, "\n"):match("# Thinking finished"),
    "activity summary detail should have a clear title"
  )

  local busy_activity_thread = state.ensure_thread("smoke-busy-activity", {
    title = "Smoke busy activity",
    cwd = vim.fn.getcwd(),
    generation = "streaming",
  })
  state.upsert_item("smoke-busy-activity", "turn-busy", {
    id = "busy-reasoning",
    type = "reasoning",
    summary = { "still thinking" },
    status = "inProgress",
  })
  state.upsert_item("smoke-busy-activity", "turn-busy", {
    id = "busy-commentary",
    type = "agentMessage",
    text = "progress update",
    status = "commentary",
  })
  local busy_blocks = render.select_render_tree(busy_activity_thread)
  assert(not vim.iter(busy_blocks):any(function(block)
    return block.type == "ActivitySummaryBlock"
  end), "busy commentary activity should remain fully inspectable until the final answer starts")
  assert(
    vim.iter(busy_blocks):any(function(block)
      return block.type == "ReasoningBlock"
    end),
    "busy activity should keep standalone reasoning rows"
  )

  local streaming_final_thread = state.ensure_thread("smoke-streaming-final-activity", {
    title = "Smoke streaming final activity",
    cwd = vim.fn.getcwd(),
    generation = "streaming",
  })
  streaming_final_thread.active_turn_id = "turn-streaming-final"
  state.upsert_item("smoke-streaming-final-activity", "turn-streaming-final", {
    id = "streaming-reasoning",
    type = "reasoning",
    summary = { "done thinking" },
    status = "completed",
  })
  state.upsert_item("smoke-streaming-final-activity", "turn-streaming-final", {
    id = "streaming-commentary",
    type = "agentMessage",
    text = "progress before final",
    status = "commentary",
  })
  state.upsert_item("smoke-streaming-final-activity", "turn-streaming-final", {
    id = "streaming-tool",
    type = "commandExecution",
    command = "echo streamed",
    cwd = vim.fn.getcwd(),
    status = "completed",
    aggregatedOutput = "streamed",
    exitCode = 0,
  })
  state.upsert_item("smoke-streaming-final-activity", "turn-streaming-final", {
    id = "streaming-final",
    type = "agentMessage",
    text = "partial final answer",
    status = "final_answer",
  })
  local streaming_blocks = render.select_render_tree(streaming_final_thread)
  local streaming_commentary_index = nil
  local streaming_summary_index = nil
  local streaming_final_index = nil
  local streaming_standalone_activity = 0
  for index, block in ipairs(streaming_blocks) do
    if block.type == "ActivitySummaryBlock" then
      streaming_summary_index = index
    elseif block.type == "ReasoningBlock" or block.type == "ToolCallBlock" then
      streaming_standalone_activity = streaming_standalone_activity + 1
    elseif block.type == "AssistantBlock" and block.state == "commentary" then
      streaming_commentary_index = index
    elseif block.type == "AssistantBlock" and block.text == "partial final answer" then
      streaming_final_index = index
    end
  end
  assert(streaming_summary_index ~= nil, "streaming final answers should compact finished activity")
  assert(streaming_commentary_index ~= nil, "streaming final compaction should keep commentary visible")
  assert(streaming_final_index ~= nil, "streaming final compaction should keep the final answer visible")
  assert(streaming_standalone_activity == 0, "streaming final compaction should hide standalone reasoning/tool rows")
  assert(
    streaming_commentary_index < streaming_summary_index and streaming_summary_index < streaming_final_index,
    "streaming final compaction should put thinking-finished between commentary and final answer"
  )
end)()
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
dynamic_tools._mark_nvim_apply_patch_auto_apply(
  { threadId = "smoke-core-pending", turnId = "turn-core" },
  core_pending_thread,
  "turn"
)
assert(
  dynamic_tools._nvim_apply_patch_auto_apply_active({ threadId = "smoke-core-pending", turnId = "turn-core" }),
  "turn-scoped Neovim auto-apply should be active before turn completion"
)
local original_rpc_respond_for_pair_native = rpc.respond
local pair_native_response = nil
rpc.respond = function(id, result)
  pair_native_response = { id = id, result = result }
end
native_hook.mark_reviewed("native-write")
core.handle_server_request({
  id = "pair-native-permission-approval",
  method = "item/permissions/requestApproval",
  params = {
    threadId = "smoke-core-pending",
    turnId = "turn-core",
    itemId = "native-write",
  },
})
assert(
  pair_native_response
    and pair_native_response.id == "pair-native-permission-approval"
    and pair_native_response.result.decision == "accept",
  "pair mode should accept apply_patch permissions already reviewed by the Neovim hook"
)
pair_native_response = nil
core.handle_server_request({
  id = "pair-native-approval",
  method = "item/fileChange/requestApproval",
  params = {
    threadId = "smoke-core-pending",
    turnId = "turn-core",
    itemId = "native-write",
  },
})
rpc.respond = original_rpc_respond_for_pair_native
assert(
  pair_native_response
    and pair_native_response.id == "pair-native-approval"
    and pair_native_response.result.decision == "accept",
  "pair mode should accept native file changes already reviewed by the Neovim hook"
)
assert(
  not native_hook.consume_reviewed_item("native-write"),
  "pair mode should consume reviewed native apply_patch approvals after the file change"
)
pair_native_response = nil
rpc.respond = function(id, result)
  pair_native_response = { id = id, result = result }
end
core.handle_server_request({
  id = "pair-native-unreviewed-approval",
  method = "item/fileChange/requestApproval",
  params = {
    threadId = "smoke-core-pending",
    turnId = "turn-core",
    itemId = "native-unreviewed-write",
  },
})
rpc.respond = original_rpc_respond_for_pair_native
assert(
  pair_native_response
    and pair_native_response.id == "pair-native-unreviewed-approval"
    and pair_native_response.result.decision == "decline",
  "pair mode should decline native file changes that did not pass Neovim hook review"
)
core.handle_notification({
  method = "turn/completed",
  params = {
    threadId = "smoke-core-pending",
    turn = { id = "turn-core", items = {} },
  },
})
assert(
  not dynamic_tools._nvim_apply_patch_auto_apply_active({ threadId = "smoke-core-pending", turnId = "turn-core" }),
  "turn/completed should clear turn-scoped Neovim auto-apply"
)
dynamic_tools._mark_nvim_apply_patch_auto_apply({ threadId = "smoke-thread-close" })
assert(
  dynamic_tools._nvim_apply_patch_auto_apply_active({ threadId = "smoke-thread-close" }),
  "session-scoped Neovim auto-apply should be active before thread close"
)
core.handle_notification({
  method = "thread/closed",
  params = {
    threadId = "smoke-thread-close",
  },
})
assert(
  not dynamic_tools._nvim_apply_patch_auto_apply_active({ threadId = "smoke-thread-close" }),
  "thread/closed should clear session-scoped Neovim auto-apply"
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
assert(
  vim.treesitter.highlighter.active and vim.treesitter.highlighter.active[thread.bufnr],
  "codex buffers should use native buffer-wide Markdown Tree-sitter"
)
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
local timeline_count = #(thread.timeline_blocks or {});
(function()
  core.handle_notification({
    method = "hook/started",
    params = {
      threadId = "smoke-extmarks",
      turnId = "turn-1",
      run = {
        id = "hook-run-1",
        eventName = "preToolUse",
        command = "codex-nvim-apply-patch-hook",
      },
    },
  })
  core.handle_notification({
    method = "hook/completed",
    params = {
      threadId = "smoke-extmarks",
      turnId = "turn-1",
      run = {
        id = "hook-run-1",
        eventName = "preToolUse",
        status = "completed",
        command = "codex-nvim-apply-patch-hook",
      },
    },
  })
  core.handle_notification({
    method = "hook/started",
    params = {
      threadId = "smoke-extmarks",
      turnId = "turn-1",
      run = {
        id = "hook-run-2",
        eventName = "preToolUse",
        command = "codex-nvim-apply-patch-hook",
      },
    },
  })
  core.handle_notification({
    method = "hook/completed",
    params = {
      threadId = "smoke-extmarks",
      turnId = "turn-1",
      run = {
        id = "hook-run-2",
        eventName = "preToolUse",
        status = "completed",
        command = "codex-nvim-apply-patch-hook",
      },
    },
  })
  local hook_block = thread.hook_timeline_blocks and thread.hook_timeline_blocks["hook:turn-1:preToolUse"]
  assert(
    #(thread.timeline_blocks or {}) == timeline_count + 1
      and hook_block
      and hook_block.title == "Hook: preToolUse"
      and hook_block.state == "completed"
      and #(hook_block.hook_run_order or {}) == 2
      and hook_block.text:match("2 hook runs"),
    "hook notifications should aggregate into one expandable timeline block per turn and event"
  )
  local legacy_hook_thread = {
    timeline_blocks = {
      {
        type = "AgentTimelineBlock",
        message_id = "legacy-turn",
        item_id = "legacy-hook-1",
        title = "Hook: preToolUse",
        state = "running",
        text = "legacy started",
      },
      {
        type = "AgentTimelineBlock",
        message_id = "legacy-turn",
        item_id = "legacy-hook-2",
        title = "Hook: preToolUse",
        state = "completed",
        text = "legacy completed",
      },
    },
  }
  local legacy_hook_blocks = require("codex.ui.render").select_render_tree(legacy_hook_thread)
  local legacy_hook_count = 0
  local legacy_hook_block = nil
  for _, block in ipairs(legacy_hook_blocks) do
    if block.type == "AgentTimelineBlock" and block.title == "Hook: preToolUse" then
      legacy_hook_count = legacy_hook_count + 1
      legacy_hook_block = block
    end
  end
  assert(
    legacy_hook_count == 1 and legacy_hook_block.text:match("2 hook events"),
    "render should compact legacy hook timeline rows into one expandable block"
  )
end)()
timeline_count = #(thread.timeline_blocks or {})
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
