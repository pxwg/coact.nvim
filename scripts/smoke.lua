vim.opt.runtimepath:append(".")

local coact = require("coact")
coact.setup()
assert(require("coact.config").get().ui.auto_scroll == false, "streaming should preserve the cursor by default")
assert(
  #vim.api.nvim_get_autocmds({ group = "CoactNvimLifecycle", event = "VimLeavePre" }) == 1,
  "explicit setup should register lifecycle cleanup"
)
local start_params = coact._thread_start_params({ cwd = vim.fn.getcwd() })
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
local composed_instructions = coact._compose_developer_instructions("custom instruction")
assert(composed_instructions:match("custom instruction"), "default edit instruction should preserve user instructions")
assert(composed_instructions:match("native apply_patch"), "default edit instruction should mention native apply_patch")
local dynamic_tools_for_config = require("coact.dynamic_tools")
local pair_specs = dynamic_tools_for_config.specs() or {}
assert(not vim.iter(pair_specs):any(function(spec)
  return spec.namespace == "nvim" and spec.name == "apply_patch"
end), "pair edit mode should not expose nvim.apply_patch")
local native_hook = require("coact.native_apply_patch_hook")
assert(
  native_hook._hook_config_arg():match("hooks%.PreToolUse")
    and native_hook._hook_config_arg():match("apply_patch")
    and native_hook._hook_config_arg():match("coact%-nvim%-apply%-patch%-hook"),
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
local hook_script = table.concat(vim.fn.readfile("scripts/coact-nvim-apply-patch-hook"), "\n")
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
    native_hook_completion_patch:match("%*%*%* Delete File: %.coact%-nvim%-apply%-patch%-noop")
      and not native_hook_completion_patch:match("%*%*%* Add File:"),
    "native apply_patch hook should return a delete-marker completion patch after Neovim writes"
  )
  local native_hook_marker =
    native_hook_completion_patch:match("%*%*%* Delete File:%s*(%.coact%-nvim%-apply%-patch%-noop[^\n]+)")
  assert(
    native_hook_marker and vim.fn.filereadable(vim.fs.joinpath(native_hook_gen_dir, native_hook_marker)) == 1,
    "native apply_patch hook no-op marker should exist before app-server verification reads it"
  )
  assert(
    dynamic_tools_for_config._changes_from_native_apply_patch(native_hook_gen_dir, native_hook_completion_patch),
    "native apply_patch hook no-op completion patch should validate through Codex apply_patch"
  )
  local stale_marker = vim.fs.joinpath(native_hook_gen_dir, ".coact-nvim-apply-patch-noop-stale")
  local fresh_marker = vim.fs.joinpath(native_hook_gen_dir, ".coact-nvim-apply-patch-noop-fresh")
  vim.fn.writefile({ "stale" }, stale_marker)
  vim.fn.writefile({ "fresh" }, fresh_marker)
  local old_time = os.time() - 600
  vim.uv.fs_utime(stale_marker, old_time, old_time)
  local cleanup_result = native_hook._cleanup_stale_noop_markers(native_hook_gen_dir, 300)
  assert(
    vim.fn.filereadable(stale_marker) == 0
      and vim.fn.filereadable(fresh_marker) == 1
      and vim.tbl_contains(cleanup_result.removed, ".coact-nvim-apply-patch-noop-stale"),
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
      native_hook_review_session = require("coact.patch_session")._active_session(bufnr)
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
  require("coact.patch_session")._accept_block(native_hook_review_session, native_hook_review_session.blocks[1])
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
    native_hook_review_output:match("%.coact%-nvim%-apply%-patch%-noop")
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
      native_hook_reject_session = require("coact.patch_session")._active_session(bufnr)
    end
    return native_hook_reject_session ~= nil
  end, 20)
  assert(native_hook_reject_session, "native apply_patch hook should open rejected block review")
  vim.diagnostic.set(native_hook_diag_ns, native_hook_reject_session.blocks[1].bufnr, {
    {
      lnum = 1,
      col = 0,
      message = "native hook reject diagnostic",
      severity = vim.diagnostic.severity.WARN,
      source = "smoke",
    },
  }, {})
  require("coact.patch_session")._reject_block(
    native_hook_reject_session,
    native_hook_reject_session.blocks[1],
    "keep right"
  )
  vim.wait(1000, function()
    return native_hook_reject_output ~= nil
  end, 20)
  _G.__coact_smoke_native_hook_reject = vim.json.decode(native_hook_reject_output).hookSpecificOutput
  _G.__coact_smoke_native_hook_reject_context = _G.__coact_smoke_native_hook_reject
      and _G.__coact_smoke_native_hook_reject.additionalContext
    or ""
  assert(
    _G.__coact_smoke_native_hook_reject
      and _G.__coact_smoke_native_hook_reject.permissionDecision == "deny"
      and _G.__coact_smoke_native_hook_reject.permissionDecisionReason == "User rejected Codex native apply_patch in Neovim."
      and _G.__coact_smoke_native_hook_reject_context:match("User rejected Codex native apply_patch")
      and _G.__coact_smoke_native_hook_reject_context:match("keep right")
      and _G.__coact_smoke_native_hook_reject_context:match("## nvim%.diagnostics")
      and _G.__coact_smoke_native_hook_reject_context:match("native hook reject diagnostic")
      and not _G.__coact_smoke_native_hook_reject.permissionDecisionReason:match("NVIM APPLY PATCH REVIEW"),
    "native apply_patch hook should deny with concise reason and contextual rejection diagnostics"
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
coact.setup({ edit = { mode = "yolo" } })
local yolo_start_params = coact._thread_start_params({ cwd = vim.fn.getcwd() })
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
local rpc = require("coact.rpc")
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
coact.setup({ dynamic_tools = { prefer_nvim_apply_patch = false } })
assert(require("coact.config").edit_mode() == "yolo", "legacy prefer_nvim_apply_patch=false should select yolo mode")
coact.setup()
assert(
  #vim.api.nvim_get_autocmds({ group = "CoactNvimLifecycle", event = "VimLeavePre" }) == 1,
  "repeated setup should not duplicate lifecycle cleanup"
)
local initial_status = coact.status()
assert(initial_status.server_running == false, "status should report stopped server before startup")
assert(type(initial_status.pending_rpc_requests) == "number", "status should expose pending rpc count")
assert(
  vim.tbl_contains(coact.complete_command("sta", "Coact sta"), "status"),
  "command completion should filter commands"
)
assert(vim.tbl_contains(coact.complete_command("", "Coact attach "), "all"), "attach completion should include all")
local health = require("coact.health")
assert(health._executable({ "codex", "app-server" }) == "codex", "health should resolve table commands")
assert(health._executable("codex app-server") == "codex", "health should resolve string commands")
local app_server_supported, app_server_help = health._app_server_supported("codex")
assert(app_server_supported, "health should detect codex app-server support: " .. tostring(app_server_help))
health.check()
do
  local state = require("coact.state")
  local pi_temp = vim.fn.tempname()
  vim.fn.mkdir(pi_temp, "p")
  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        config_dir = vim.fs.joinpath(pi_temp, "config"),
        session_dir = vim.fs.joinpath(pi_temp, "sessions"),
        offline = true,
        no_extensions = true,
        no_skills = true,
        no_context_files = true,
        no_session = true,
      },
    },
    thread = {
      model = "openai/gpt-4o",
      reasoning_effort = "high",
    },
  })
  local providers = require("coact.providers")
  assert(providers.current_id() == "pi", "provider selector should switch to pi")
  assert(not native_hook.enabled(), "Pi provider should not enable the Codex native apply_patch hook")
  local pi_provider = require("coact.providers.pi")
  local pi_command = pi_provider.command(require("coact.config").get())
  assert(vim.tbl_contains(pi_command, "pi"), "Pi provider command should invoke pi")
  assert(
    vim.tbl_contains(pi_command, "--mode") and vim.tbl_contains(pi_command, "rpc"),
    "Pi provider should use RPC mode"
  )
  assert(vim.tbl_contains(pi_command, "--offline"), "Pi provider should pass configured offline flag")
  local targeted_pi_command = pi_provider.command(require("coact.config").get(), { session_id = "smoke-session-id" })
  local targeted_session_arg
  for index, part in ipairs(targeted_pi_command) do
    if part == "--session-id" then
      targeted_session_arg = targeted_pi_command[index + 1]
      break
    end
  end
  assert(
    targeted_session_arg == "smoke-session-id",
    "Pi provider should launch a new execution unit with a preassigned session id"
  )
  local pi_bridge = require("coact.providers.pi_edit_bridge")
  assert(pi_bridge.enabled(), "Pi provider should enable the edit bridge in pair mode by default")
  local prepared_pi_command, prepared_pi_env, prepared_pi_err = pi_provider.prepare_command(pi_command, {})
  assert(prepared_pi_command ~= nil, "Pi edit bridge command preparation should succeed: " .. tostring(prepared_pi_err))
  assert(
    prepared_pi_command[1] == "env"
      and vim.tbl_contains(prepared_pi_command, "-u")
      and vim.tbl_contains(prepared_pi_command, "NVIM")
      and vim.tbl_contains(prepared_pi_command, "NVIM_LISTEN_ADDRESS"),
    "Pi provider should scrub host Neovim RPC environment before starting Pi"
  )
  assert(vim.tbl_contains(prepared_pi_command, "--extension"), "Pi edit bridge should inject a process-local extension")
  local extension_index
  for index, part in ipairs(prepared_pi_command) do
    if part == "--extension" then
      extension_index = index
      break
    end
  end
  assert(
    extension_index and vim.fn.filereadable(prepared_pi_command[extension_index + 1]) == 1,
    "Pi edit bridge should write a temporary extension file"
  )
  assert(
    prepared_pi_env.COACT_NVIM_PI_EDIT_BRIDGE_ADDR
      and prepared_pi_env.COACT_NVIM_PI_EDIT_BRIDGE_NONCE
      and prepared_pi_env.COACT_NVIM_PI_EDIT_BRIDGE_NVIM
      and prepared_pi_env.COACT_NVIM_PI_EDIT_BRIDGE_TIMEOUT_MS
      and prepared_pi_env.COACT_NVIM_PI_CLIENT_ID,
    "Pi edit bridge should pass runtime connection details through env vars"
  )
  local pi_nvim_bridge = require("coact.providers.pi_nvim_bridge")
  assert(pi_nvim_bridge.enabled(), "Pi provider should expose the Neovim Lua bridge by default")
  assert(prepared_pi_env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE, "Pi Neovim Lua bridge should pass a process-local nonce")
  local injected_extension_count = 0
  for _, part in ipairs(prepared_pi_command) do
    if part == "--extension" then
      injected_extension_count = injected_extension_count + 1
    end
  end
  assert(injected_extension_count == 2, "Pi should inject separate edit-review and Neovim Lua extensions")
  local pi_nvim_extension_source = pi_nvim_bridge._extension_source()
  assert(
    pi_nvim_extension_source:match('name: "nvim_exec_lua"')
      and pi_nvim_extension_source:match("__coactNvimExecLua")
      and pi_nvim_extension_source:match("local ctx, args = %.%.%.")
      and pi_nvim_extension_source:match('executionMode: "sequential"'),
    "Pi Neovim bridge extension should register the serialized nvim_exec_lua tool"
  )
  local pi_extension_source = pi_bridge._extension_source()
  assert(
    pi_extension_source:match('name: "edit"') and pi_extension_source:match('name: "write"'),
    "Pi edit bridge extension should override edit and write tools"
  )
  assert(
    pi_extension_source:find("COACT_NVIM_PI_CLIENT_ID", 1, true) and pi_extension_source:find("clientId", 1, true),
    "Pi edit bridge should carry the owning execution-unit id into Neovim review"
  )
  assert(
    pi_extension_source:match("interactive approval before anything is written")
      and not pi_extension_source:find("direct_write", 1, true),
    "Pi direct-write policy should not change or disclose itself through the agent-facing tool interface"
  )
  assert(
    pi_extension_source:match("small cooperative deltas") and pi_extension_source:match("return control to the user"),
    "Pi edit bridge edit prompt should discourage autonomous bulk generation"
  )
  assert(
    pi_extension_source:match('registerCommand%("coact%-nvim%-tree"')
      and pi_extension_source:match("navigateTree")
      and pi_extension_source:match("__coactNvimPiTreeAction")
      and pi_extension_source:match('registerCommand%("coact%-nvim%-branch%-snapshot"')
      and pi_extension_source:match("__coactNvimPiBranchSnapshot"),
    "Pi edit bridge extension should register tree navigation and branch snapshots"
  )
  assert(
    pi_extension_source:find('const treeSummaryStatusKey = "coact.nvim.tree-summary";', 1, true)
      and pi_extension_source:find('ctx.ui.setStatus(treeSummaryStatusKey, "summarizing");', 1, true)
      and pi_extension_source:find("result = await ctx.navigateTree", 1, true)
      and pi_extension_source:find("ctx.ui.setStatus(treeSummaryStatusKey, undefined);", 1, true),
    "Pi tree navigation should bracket branch summarization with an observable status lifecycle"
  )
  assert(
    pi_extension_source:find("ctx.sessionManager.buildContextEntries()", 1, true)
      and pi_extension_source:find('role: "branchSummary"', 1, true)
      and pi_extension_source:find('role: "compactionSummary"', 1, true),
    "Pi branch snapshots should retain active branch and compaction summary entry identities"
  );
  (function()
    local pi_tree = require("coact.providers.pi_tree")
    local rendered_tree = pi_tree._render_for_test({
      __coactNvimPiTree = true,
      leafId = "branch-user",
      tree = {
        {
          entry = {
            id = "root-user",
            type = "message",
            message = { role = "user", content = { { type = "text", text = "root prompt" } } },
          },
          children = {
            {
              entry = {
                id = "assistant",
                parentId = "root-user",
                type = "message",
                message = {
                  role = "assistant",
                  content = {
                    { type = "text", text = "assistant answer" },
                    { type = "toolCall", id = "tool-call", name = "bash", arguments = { command = "echo smoke" } },
                  },
                },
              },
              children = {
                {
                  entry = {
                    id = "tool-result",
                    parentId = "assistant",
                    type = "message",
                    message = { role = "toolResult", toolCallId = "tool-call", toolName = "bash" },
                  },
                  children = {},
                },
                {
                  entry = {
                    id = "branch-user",
                    parentId = "assistant",
                    type = "message",
                    message = { role = "user", content = { { type = "text", text = "branch prompt" } } },
                  },
                  children = {},
                },
              },
            },
          },
        },
      },
    }, { width = 140, height = 20 })
    local root_col, assistant_col
    local body = table.concat(rendered_tree.lines, "\n")
    for _, line in ipairs(rendered_tree.lines) do
      if line:find("user: root prompt", 1, true) then
        root_col = line:find("user:", 1, true)
      elseif line:find("assistant: assistant answer", 1, true) then
        assistant_col = line:find("assistant:", 1, true)
      end
    end
    assert(root_col == assistant_col, "Pi tree renderer should keep single-child chains visually flat")
    assert(body:find("├", 1, true) and body:find("└", 1, true), "Pi tree renderer should draw branch connectors")
    local seen_hl = {}
    for _, spans in pairs(rendered_tree.spans) do
      for _, span in ipairs(spans) do
        seen_hl[span.hl_group] = true
      end
    end
    assert(
      seen_hl.CoactPiTreeUser
        and seen_hl.CoactPiTreeAssistant
        and seen_hl.CoactPiTreeTool
        and seen_hl.CoactPiTreeConnector,
      "Pi tree renderer should expose role and connector highlights"
    )
    assert(
      rendered_tree.lines[2]:find("j/k ctrl%-n/p move") and not rendered_tree.lines[2]:find("↑", 1, true),
      "Pi tree help should advertise native Neovim navigation without arrow hints"
    )
    local picker_payload = {
      __coactNvimPiTree = true,
      leafId = "root-user",
      initialSelectedId = "assistant",
      tree = {
        {
          entry = {
            id = "root-user",
            type = "message",
            message = { role = "user", content = { { type = "text", text = "root prompt" } } },
          },
          children = {
            {
              entry = {
                id = "assistant",
                parentId = "root-user",
                type = "message",
                message = { role = "assistant", content = { { type = "text", text = "second row" } } },
              },
              children = {},
            },
          },
        },
      },
    }
    pi_tree.select({ options = { picker_payload } }, function() end)
    local picker_bufnr = vim.api.nvim_get_current_buf()
    assert(vim.bo[picker_bufnr].filetype == "coact-pi-tree", "Pi tree picker should open its own buffer")
    assert(not vim.bo[picker_bufnr].modifiable and vim.bo[picker_bufnr].readonly, "Pi tree picker should be read-only")
    assert(vim.fn.mode() ~= "i", "Pi tree picker should enter normal mode")
    assert(vim.fn.maparg("i", "n", false, true).rhs == "<Nop>", "Pi tree picker should block insert mode")
    assert(type(vim.fn.maparg("j", "n", false, true).callback) == "function", "Pi tree picker should bind j")
    assert(type(vim.fn.maparg("<C-n>", "n", false, true).callback) == "function", "Pi tree picker should bind ctrl-n")
    assert(type(vim.fn.maparg("<C-p>", "n", false, true).callback) == "function", "Pi tree picker should bind ctrl-p")
    assert(
      type(vim.fn.maparg("<Down>", "n", false, true).callback) == "function",
      "Pi tree picker should allow down arrow"
    )
    assert(
      type(vim.fn.maparg("<Right>", "n", false, true).callback) == "function",
      "Pi tree picker should allow right arrow"
    )
    assert(type(vim.fn.maparg("<C-d>", "n", false, true).callback) == "function", "Pi tree picker should bind ctrl-d")
    assert(type(vim.fn.maparg("gg", "n", false, true).callback) == "function", "Pi tree picker should bind gg")
    local assistant_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(picker_bufnr, 0, -1, false)) do
      if line:find("assistant: second row", 1, true) then
        assistant_row = row
        break
      end
    end
    assert(assistant_row, "Pi tree picker smoke should find the second row")
    local initially_selected_line = vim.api.nvim_buf_get_lines(picker_bufnr, assistant_row - 1, assistant_row, false)[1]
      or ""
    assert(
      initially_selected_line:match("^›") and initially_selected_line:find("assistant: second row", 1, true),
      "Pi tree picker should honor initialSelectedId"
    )
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { assistant_row, 0 })
    vim.cmd("doautocmd <nomodeline> CursorMoved")
    local synced_line = vim.api.nvim_buf_get_lines(picker_bufnr, assistant_row - 1, assistant_row, false)[1] or ""
    assert(
      synced_line:match("^›") and synced_line:find("assistant: second row", 1, true),
      "Pi tree picker should sync selection from native cursor movement"
    )
    pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)

    local pi_buffers = require("coact.buffers")
    local reveal_thread_id = "pi:tree-reveal-smoke"
    state.upsert_item(reveal_thread_id, "tree-reveal-turn", {
      id = "tree-reveal-user-item",
      type = "userMessage",
      content = { { type = "text", text = "tree reveal prompt" } },
      treeEntryId = "entry-reveal-user",
    })
    local reveal_bufnr, reveal_winid = pi_buffers.open(reveal_thread_id)
    local reveal_choice = nil
    pi_tree.select({
      options = {
        {
          __coactNvimPiTree = true,
          leafId = "entry-reveal-user",
          initialSelectedId = "entry-reveal-user",
          tree = {
            {
              entry = {
                id = "entry-reveal-user",
                type = "message",
                message = { role = "user", content = { { type = "text", text = "tree reveal prompt" } } },
              },
              children = {},
            },
          },
        },
      },
    }, function(choice)
      reveal_choice = choice
    end, { thread_id = reveal_thread_id })
    assert(type(vim.fn.maparg("r", "n", false, true).callback) == "function", "Pi tree picker should bind local reveal")
    vim.fn.maparg("r", "n", false, true).callback()
    assert(
      reveal_choice
        and reveal_choice.__coactNvimPiTreeAction == true
        and reveal_choice.action == "reveal"
        and reveal_choice.id == "entry-reveal-user",
      "Pi tree reveal should return a local reveal action"
    )
    assert(vim.api.nvim_get_current_buf() == reveal_bufnr, "Pi tree reveal should focus the history buffer")
    local reveal_cursor = vim.api.nvim_win_get_cursor(reveal_winid)
    local reveal_cursor_line = vim.api.nvim_buf_get_lines(reveal_bufnr, reveal_cursor[1] - 1, reveal_cursor[1], false)[1]
      or ""
    assert(reveal_cursor_line:find("## You", 1, true), "Pi tree reveal should jump to the rendered message header")

    local fallback_choice = nil
    pi_tree.select({
      options = {
        {
          __coactNvimPiTree = true,
          leafId = "entry-reveal-user",
          initialSelectedId = "entry-other-branch",
          tree = {
            {
              entry = {
                id = "entry-other-branch",
                type = "message",
                message = { role = "user", content = { { type = "text", text = "other branch prompt" } } },
              },
              children = {},
            },
          },
        },
      },
    }, function(choice)
      fallback_choice = choice
    end, { thread_id = reveal_thread_id })
    vim.fn.maparg("r", "n", false, true).callback()
    assert(
      fallback_choice
        and fallback_choice.__coactNvimPiTreeAction == true
        and fallback_choice.action == "navigateTree"
        and fallback_choice.id == "entry-other-branch",
      "Pi tree reveal should fall back to native tree navigation when the entry is not on the current branch"
    )
  end)()
  local pi_thread = pi_provider._thread_from_state({
    sessionId = "smoke-session",
    sessionName = "Smoke Pi",
    thinkingLevel = "high",
    model = { provider = "openai", id = "gpt-4o" },
  })
  assert(pi_thread.id == "pi:smoke-session", "Pi session state should normalize to a thread id")
  assert(pi_thread.model == "openai/gpt-4o", "Pi model state should normalize provider/model")
  local pi_max_model = pi_provider._normalize_model({
    provider = "openai",
    id = "gpt-5.6-sol",
    reasoning = true,
    thinkingLevelMap = {
      off = "none",
      minimal = vim.NIL,
      low = "low",
      medium = "medium",
      high = "high",
      xhigh = vim.NIL,
      max = "max",
    },
  })
  local pi_max_model_efforts = vim.tbl_map(function(option)
    return option.effort
  end, pi_max_model.supportedReasoningEfforts)
  assert(
    vim.deep_equal(pi_max_model_efforts, { "off", "low", "medium", "high", "max" }),
    "Pi model normalization should honor thinkingLevelMap holes and max support"
  )
  local pi_prompt = pi_provider._prompt_from_input({
    { type = "text", text = "hello" },
    { type = "skill", name = "smoke" },
  })
  assert(pi_prompt:match("hello") and pi_prompt:match("/skill:smoke"), "Pi prompts should flatten Coact inputs")
  _G.__coact_smoke_pi_image_path = vim.fs.joinpath(pi_temp, "pi smoke image.png")
  vim.fn.writefile({ "fake png" }, _G.__coact_smoke_pi_image_path)
  _G.__coact_smoke_pi_image_prompt, _G.__coact_smoke_pi_images = pi_provider._prompt_from_input({
    { type = "localImage", path = _G.__coact_smoke_pi_image_path },
  })
  assert(
    _G.__coact_smoke_pi_image_prompt:match("%[local image%]"),
    "Pi image-only prompts should include an image reference"
  )
  assert(
    #_G.__coact_smoke_pi_images == 1
      and _G.__coact_smoke_pi_images[1].type == "image"
      and _G.__coact_smoke_pi_images[1].mimeType == "image/png"
      and _G.__coact_smoke_pi_images[1].data,
    "Pi prompts should encode local image attachments for RPC"
  )
  _G.__coact_smoke_pi_mismatched_image_path = vim.fs.joinpath(pi_temp, "pi smoke mismatched.png")
  vim.fn.writefile({ "GIF89a" }, _G.__coact_smoke_pi_mismatched_image_path)
  _G.__coact_smoke_pi_mismatched_prompt, _G.__coact_smoke_pi_mismatched_images = pi_provider._prompt_from_input({
    { type = "localImage", path = _G.__coact_smoke_pi_mismatched_image_path },
  })
  assert(
    _G.__coact_smoke_pi_mismatched_images[1] and _G.__coact_smoke_pi_mismatched_images[1].mimeType == "image/gif",
    "Pi image attachments should prefer sniffed MIME type over extension fallback"
  )
  local pi_response = pi_provider.decode_response({
    id = "req-1",
    type = "response",
    command = "get_state",
    success = false,
    error = "boom",
  })
  assert(pi_response and pi_response.error.message == "boom", "Pi RPC errors should decode as request errors")
  pi_provider._runtime.current_thread_id = "pi:smoke-session"
  pi_provider._runtime.active_turn_id = "pi-turn-smoke"
  local pi_delta = pi_provider.decode_notification({
    type = "message_update",
    assistantMessageEvent = {
      type = "text_delta",
      contentIndex = 0,
      delta = "hello from pi",
    },
  })
  assert(
    pi_delta
      and pi_delta.message.method == "item/agentMessage/delta"
      and pi_delta.message.params.itemId == "pi-turn-smoke:assistant:0",
    "Pi text deltas should normalize to assistant message deltas"
  )
  require("coact.core").handle_notification(pi_delta.message)
  local pi_state_thread = state.get_thread("pi:smoke-session")
  assert(
    pi_state_thread
      and pi_state_thread.items["pi-turn-smoke:assistant:0"]
      and pi_state_thread.items["pi-turn-smoke:assistant:0"].text == "hello from pi",
    "Pi normalized deltas should update the shared thread item model"
  )
  local pi_toolcall_start = pi_provider.decode_notification({
    type = "message_update",
    assistantMessageEvent = {
      type = "toolcall_start",
      contentIndex = 1,
      partial = {
        role = "assistant",
        content = {
          { type = "text", text = "hello from pi" },
          {
            type = "toolCall",
            id = "pi-tool-call",
            name = "read",
            arguments = { path = "README.md" },
            partialArgs = '{"path":"README.md"}',
          },
        },
      },
    },
  })
  assert(
    pi_toolcall_start
      and pi_toolcall_start.message.method == "item/started"
      and pi_toolcall_start.message.params.item.id == "pi-tool-call"
      and pi_toolcall_start.message.params.item.tool == "read",
    "Pi toolcall_start should normalize the content block instead of creating a pi.dynamic stub"
  )
  require("coact.core").handle_notification(pi_toolcall_start.message)
  assert(
    pi_state_thread.items["pi-tool-call"]
      and pi_state_thread.items["pi-tool-call"].tool == "read"
      and pi_state_thread.items["pi-tool-call"].arguments.path == "README.md"
      and not pi_state_thread.items["pi-turn-smoke:assistant:1"],
    "Pi tool call streaming should use the real tool id and avoid assistant-id stubs"
  )
  local pi_toolcall_delta = pi_provider.decode_notification({
    type = "message_update",
    assistantMessageEvent = {
      type = "toolcall_delta",
      contentIndex = 1,
      partial = {
        role = "assistant",
        content = {
          { type = "text", text = "hello from pi" },
          {
            type = "toolCall",
            id = "pi-tool-call",
            name = "read",
            arguments = { path = "README.md", offset = 2 },
            partialArgs = '{"path":"README.md","offset":2}',
          },
        },
      },
    },
  })
  require("coact.core").handle_notification(pi_toolcall_delta.message)
  local pi_tool_block = require("coact.events").block_for_item(pi_state_thread.items["pi-tool-call"], "pi-turn-smoke")
  assert(
    pi_state_thread.items["pi-tool-call"].arguments.offset == 2 and pi_tool_block.tool == "pi.read",
    "Pi toolcall_delta should stream concrete tool arguments under the Pi namespace"
  )
  local pi_tool_start = pi_provider.decode_notification({
    type = "tool_execution_start",
    toolCallId = "tool-smoke",
    toolName = "bash",
    args = { command = "pwd" },
  })
  require("coact.core").handle_notification(pi_tool_start.message)
  local pi_tool_update = pi_provider.decode_notification({
    type = "tool_execution_update",
    toolCallId = "tool-smoke",
    toolName = "bash",
    partialResult = { content = { { type = "text", text = "one\ntwo" } } },
  })
  require("coact.core").handle_notification(pi_tool_update.message)
  assert(
    pi_state_thread.items["tool-smoke"].command == "pwd"
      and pi_state_thread.items["tool-smoke"].aggregatedOutput:match("one\ntwo"),
    "Pi bash tool events should normalize to commandExecution items"
  )
  local pi_dynamic_tool_start = pi_provider.decode_notification({
    type = "tool_execution_start",
    toolCallId = "tool-read",
    toolName = "read",
    args = { path = "README.md" },
  })
  require("coact.core").handle_notification(pi_dynamic_tool_start.message)
  local pi_dynamic_tool_update = pi_provider.decode_notification({
    type = "tool_execution_update",
    toolCallId = "tool-read",
    toolName = "read",
    partialResult = { content = { { type = "text", text = "partial read output" } } },
  })
  require("coact.core").handle_notification(pi_dynamic_tool_update.message)
  assert(
    pi_state_thread.items["tool-read"].tool == "read"
      and pi_state_thread.items["tool-read"].output:match("partial read output"),
    "Pi dynamic tool progress should stream into tool output before completion"
  );
  (function()
    local pi_ui_sent = {}
    local pi_ui_rpc = {
      send = function(message)
        table.insert(pi_ui_sent, message)
      end,
    }
    local original_pi_ui_select = vim.ui.select
    vim.ui.select = function(items, opts, callback)
      assert(opts.prompt == "Pi session tree", "Pi extension select should use the request title")
      callback(items[2])
    end
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-select-smoke",
        method = "select",
        title = "Pi session tree",
        options = { "first", "second" },
      }, pi_ui_rpc),
      "Pi provider should handle extension select requests"
    )
    vim.wait(1000, function()
      return #pi_ui_sent == 1
    end, 10)
    vim.ui.select = original_pi_ui_select
    assert(
      pi_ui_sent[1]
        and pi_ui_sent[1].type == "extension_ui_response"
        and pi_ui_sent[1].id == "pi-select-smoke"
        and pi_ui_sent[1].value == "second",
      "Pi extension select should respond with the selected value"
    )
    local nvim_exec_bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(nvim_exec_bufnr, vim.fs.joinpath(pi_temp, "nvim-exec-source.lua"))
    vim.api.nvim_buf_set_lines(nvim_exec_bufnr, 0, -1, false, { "return 'source'" })
    pi_state_thread.context_bufnr = nvim_exec_bufnr
    pi_state_thread.context_winid = nil
    local nvim_exec_response_count = #pi_ui_sent
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-nvim-exec-smoke",
        method = "select",
        title = "coact.nvim nvim_exec_lua",
        options = {
          {
            __coactNvimExecLua = true,
            version = 1,
            nonce = prepared_pi_env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE,
            code = table.concat({
              "local ctx, args = ...",
              "vim.b[ctx.bufnr].coact_nvim_exec_smoke = args.value",
              "vim.cmd([[let b:coact_nvim_exec_cmd_smoke = 'from-vim-cmd']])",
              "return { bufnr = ctx.bufnr, current = vim.api.nvim_get_current_buf(), value = args.value, cmd = vim.b.coact_nvim_exec_cmd_smoke }",
            }, "\n"),
            args = { value = "from-pi" },
          },
        },
      }, pi_ui_rpc),
      "Pi provider should handle nvim_exec_lua host requests"
    )
    vim.wait(1000, function()
      return #pi_ui_sent == nvim_exec_response_count + 1
    end, 10)
    local nvim_exec_response = pi_ui_sent[#pi_ui_sent]
    local nvim_exec_result = nvim_exec_response and nvim_exec_response.value
    assert(
      nvim_exec_response
        and nvim_exec_response.type == "extension_ui_response"
        and nvim_exec_response.id == "pi-nvim-exec-smoke"
        and nvim_exec_result.__coactNvimExecLuaResult == true
        and nvim_exec_result.ok == true
        and nvim_exec_result.value.bufnr == nvim_exec_bufnr
        and nvim_exec_result.value.current == nvim_exec_bufnr
        and nvim_exec_result.value.value == "from-pi"
        and nvim_exec_result.value.cmd == "from-vim-cmd"
        and nvim_exec_result.target.before.bufnr == nvim_exec_bufnr
        and vim.b[nvim_exec_bufnr].coact_nvim_exec_smoke == "from-pi",
      "nvim_exec_lua should execute inside the thread source buffer and return structured JSON"
    )
    local invalid_nonce_result = pi_nvim_bridge.execute_request({
      __coactNvimExecLua = true,
      version = 1,
      nonce = "invalid",
      code = "return true",
    }, { thread_id = "pi:smoke-session" })
    assert(
      invalid_nonce_result.__coactNvimExecLuaResult == true
        and invalid_nonce_result.ok == false
        and invalid_nonce_result.error:match("invalid Neovim bridge nonce"),
      "nvim_exec_lua should reject requests outside the injected bridge"
    )
    local non_serializable_result = pi_nvim_bridge.execute_request({
      __coactNvimExecLua = true,
      version = 1,
      nonce = prepared_pi_env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE,
      code = "return function() end",
    }, { thread_id = "pi:smoke-session" })
    assert(
      non_serializable_result.ok == false and non_serializable_result.error:match("JSON%-serializable"),
      "nvim_exec_lua should reject non-serializable return values"
    )
    vim.api.nvim_buf_delete(nvim_exec_bufnr, { force = true })
    pi_state_thread.context_bufnr = nil
    local saved_snapshot_runtime_thread_id = pi_provider._runtime.current_thread_id
    pi_provider._runtime.current_thread_id = "pi:branch-snapshot-smoke"
    local snapshot_thread = state.ensure_thread("pi:branch-snapshot-smoke")
    state.upsert_item("pi:branch-snapshot-smoke", "tree-turn", {
      id = "tree-user-item",
      type = "userMessage",
      content = { { type = "text", text = "snapshot user" } },
    })
    state.upsert_item("pi:branch-snapshot-smoke", "tree-turn", {
      id = "tree-assistant-item",
      type = "agentMessage",
      text = "snapshot assistant",
    })
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-branch-snapshot-smoke",
        method = "select",
        title = "Coact Pi branch snapshot",
        options = {
          {
            __coactNvimPiBranchSnapshot = true,
            entries = {
              { id = "entry-user-smoke", role = "user", text = "snapshot user" },
              { id = "entry-assistant-smoke", role = "assistant", text = "snapshot assistant" },
            },
          },
        },
      }, pi_ui_rpc),
      "Pi provider should handle branch snapshot sync requests"
    )
    assert(
      snapshot_thread.items["tree-user-item"].treeEntryId == "entry-user-smoke"
        and snapshot_thread.items["tree-assistant-item"].treeEntryId == "entry-assistant-smoke"
        and pi_provider._runtime.branch_snapshot.entries[1].id == "entry-user-smoke"
        and pi_ui_sent[#pi_ui_sent].id == "pi-branch-snapshot-smoke"
        and pi_ui_sent[#pi_ui_sent].value == "ok",
      "Pi branch snapshot sync should annotate existing user and assistant items without a picker"
    )
    pi_provider._runtime.current_thread_id = saved_snapshot_runtime_thread_id
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-editor-smoke",
        method = "set_editor_text",
        text = "restored prompt",
      }, pi_ui_rpc),
      "Pi provider should handle extension editor text updates"
    )
    assert(
      pi_state_thread.draft_lines and pi_state_thread.draft_lines[1] == "restored prompt",
      "Pi set_editor_text should restore the current composer prompt"
    )
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-title-smoke",
        method = "setTitle",
        title = "pi - smoke",
      }, pi_ui_rpc),
      "Pi provider should handle extension title updates"
    )
    pi_state_thread.generation = "idle"
    pi_state_thread.status_message = nil
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-tree-summary-start-smoke",
        method = "setStatus",
        statusKey = "coact.nvim.tree-summary",
        statusText = "summarizing",
      }, pi_ui_rpc),
      "Pi provider should handle tree summary lifecycle updates"
    )
    assert(
      pi_state_thread.generation == "summarizing" and pi_state_thread.status_message == "Pi is summarizing a branch...",
      "Pi tree summary start should enter an observable summarizing generation"
    )
    local pi_summary_buf = require("coact.buffers").ensure("pi:smoke-session")
    local pi_summary_render = require("coact.ui.render")
    pi_summary_render.render(pi_state_thread)
    local pi_summary_spinner = pi_state_thread.spinner_mark
    local pi_summary_spinner_extmark = pi_summary_spinner
        and pi_summary_spinner.extmark_id
        and vim.api.nvim_buf_get_extmark_by_id(
          pi_summary_buf,
          pi_summary_render.namespace(),
          pi_summary_spinner.extmark_id,
          { details = true }
        )
      or nil
    local pi_summary_spinner_text = pi_summary_spinner_extmark
        and pi_summary_spinner_extmark[3]
        and pi_summary_spinner_extmark[3].virt_text
        and pi_summary_spinner_extmark[3].virt_text[1]
        and pi_summary_spinner_extmark[3].virt_text[1][1]
      or nil
    assert(
      pi_summary_spinner_text and pi_summary_spinner_text:find("Coact summarizing...", 1, true),
      "Pi tree summary generation should render a Coact summarizing spinner"
    )
    assert(
      not (pi_state_thread.provider_ui and pi_state_thread.provider_ui.statuses["coact.nvim.tree-summary"]),
      "Pi tree summary lifecycle status should not leak into provider status chrome"
    )
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-tree-summary-end-smoke",
        method = "setStatus",
        statusKey = "coact.nvim.tree-summary",
        statusText = vim.NIL,
      }, pi_ui_rpc),
      "Pi provider should clear tree summary lifecycle updates"
    )
    pi_summary_render.render(pi_state_thread)
    assert(
      pi_state_thread.generation == "idle"
        and pi_state_thread.status_message == nil
        and pi_state_thread.spinner_mark == nil,
      "Pi tree summary completion should clear the summarizing spinner"
    )
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-status-smoke",
        method = "setStatus",
        statusKey = "model",
        statusText = "\27[36m🤖 gpt-4o\27[0m",
      }, pi_ui_rpc),
      "Pi provider should handle extension status updates"
    )
    assert(
      pi_provider.handle_raw_message({
        type = "extension_ui_request",
        id = "pi-widget-smoke",
        method = "setWidget",
        widgetKey = "plan",
        widgetLines = { "step 1", "step 2" },
        widgetPlacement = "belowEditor",
      }, pi_ui_rpc),
      "Pi provider should handle extension widget updates"
    )
    assert(
      pi_state_thread.provider_ui
        and pi_state_thread.provider_ui.title == "pi - smoke"
        and pi_state_thread.provider_ui.statuses.model
        and pi_state_thread.provider_ui.statuses.model:match("gpt%-4o")
        and pi_state_thread.provider_ui.widgets.belowEditor.plan.lines[1] == "step 1",
      "Pi extension UI state should be cached on the active thread"
    )
    pi_state_thread.token_usage = {
      input = 1000,
      output = 500,
      contextUsage = { percent = 82.5, contextWindow = 272000, tokens = 224400 },
      autoCompactionEnabled = true,
    }
    do
      local saved_active_thread_id = state.active_thread_id
      local saved_runtime_thread_id = pi_provider._runtime.current_thread_id
      local saved_runtime_ui = pi_provider._runtime.provider_ui
      pi_provider._runtime.provider_ui = nil
      pi_provider._runtime.current_thread_id = "pi:session"
      state.ensure_thread("pi:session").provider_ui = {
        statuses = { ["codex-fast-mode"] = "fast:on" },
        widgets = { aboveEditor = {}, belowEditor = {} },
      }
      pi_provider._remember_state({ sessionId = "migrated-status" })
      local migrated_status_thread = state.get_thread("pi:migrated-status")
      assert(
        migrated_status_thread
          and migrated_status_thread.provider_ui
          and migrated_status_thread.provider_ui.statuses["codex-fast-mode"] == "fast:on",
        "Pi extension statuses observed before concrete session state should migrate to the active session thread"
      )
      pi_provider._runtime.provider_ui = saved_runtime_ui
      pi_provider._runtime.current_thread_id = saved_runtime_thread_id
      state.active_thread_id = saved_active_thread_id
    end
    local pi_statusline = require("coact.ui.statusline")
    local empty_pi_status_lines =
      pi_statusline.above_lines(state.ensure_thread("pi:empty-statusline", { title = "Pi session" }))
    assert(
      vim.inspect(empty_pi_status_lines):match("Pi session") and vim.inspect(empty_pi_status_lines):match("state"),
      "Pi statusline helpers should show a non-empty fallback for sparse Pi thread state"
    )
    local pi_status_lines = pi_statusline.above_lines(pi_state_thread)
    assert(#pi_status_lines >= 3, "Pi statusline helpers should render title, summary, and extension status lines")
    local pi_status_text = vim.inspect(pi_status_lines)
    assert(
      pi_status_text:match("pi %- smoke") and pi_status_text:match("model") and pi_status_text:match("🤖 gpt%-4o"),
      "Pi statusline helpers should expose sanitized extension status text"
    )
    local pi_wrapped_status_lines = pi_statusline.above_lines(pi_state_thread, { width = 44 })
    assert(
      #pi_wrapped_status_lines >= 4 and vim.inspect(pi_wrapped_status_lines):match("state"),
      "Pi statusline helpers should wrap structured fields for narrow widths"
    )
    local pi_widget_lines = pi_statusline.below_lines(pi_state_thread)
    assert(
      vim.inspect(pi_widget_lines):match("step 1"),
      "Pi below-editor widgets should remain available to statusline helpers"
    )
    local function footer_text(winid)
      local footer = vim.api.nvim_win_get_config(winid).footer
      if type(footer) == "table" then
        local parts = {}
        for _, chunk in ipairs(footer) do
          table.insert(parts, type(chunk) == "table" and tostring(chunk[1] or "") or tostring(chunk or ""))
        end
        return table.concat(parts)
      end
      return tostring(footer or "")
    end
    local pi_status_footer = pi_statusline.footer_text(pi_state_thread, { role = "history", width = 80 })
    assert(
      pi_status_footer:find("Pi", 1, true)
        and pi_status_footer:find("model", 1, true)
        and pi_status_footer:find("82.5%/272k (auto)", 1, true),
      "Pi status footer should expose provider, model, and context usage: " .. vim.inspect(pi_status_footer)
    )
    local pi_buffers = require("coact.buffers")
    local pi_history_buf = pi_buffers.ensure("pi:smoke-session")
    state.upsert_item("pi:smoke-session", "pi-double-esc-turn", {
      id = "pi-double-esc-user",
      type = "userMessage",
      content = {
        {
          type = "text",
          text = "double escape tree prompt",
        },
      },
      treeEntryId = "entry-double-esc",
    })
    pi_buffers.render("pi:smoke-session")
    local pi_history_text = table.concat(vim.api.nvim_buf_get_lines(pi_history_buf, 0, -1, false), "\n")
    assert(
      not pi_history_text:find("Pi status", 1, true) and not pi_history_text:find("gS hide status", 1, true),
      "Pi status chrome should not be rendered as transcript buffer lines"
    )
    local opened_pi_history_buf, opened_pi_history_win = pi_buffers.open("pi:smoke-session")
    assert(type(vim.fn.maparg("g?", "n", false, true).callback) == "function", "history should bind g? help")
    assert(type(vim.fn.maparg("gs", "n", false, true).callback) == "function", "history should bind gs status detail")
    assert(type(vim.fn.maparg("gS", "n", false, true).callback) == "function", "history should bind gS status toggle")
    assert(type(vim.fn.maparg("gt", "n", false, true).callback) == "function", "history should bind gt Pi tree")
    assert(
      type(vim.fn.maparg("gT", "n", false, true).callback) == "function",
      "history should bind gT Pi tree at message"
    )
    assert(
      type(vim.fn.maparg("<Esc><Esc>", "n", false, true).callback) == "function",
      "history should bind double escape Pi tree"
    )
    assert(type(vim.fn.maparg("gc", "n", false, true).callback) == "function", "history should bind gc status")
    assert(type(vim.fn.maparg("gy", "n", false, true).callback) == "function", "history should bind gy copy")
    assert(type(vim.fn.maparg("gd", "n", false, true).callback) == "function", "history should bind gd diff")
    assert(type(vim.fn.maparg("gr", "n", false, true).callback) == "function", "history should bind gr refresh")
    assert(type(vim.fn.maparg("g]", "n", false, true).callback) == "function", "history should bind g] next message")
    assert(
      type(vim.fn.maparg("g[", "n", false, true).callback) == "function",
      "history should bind g[ previous message"
    )
    local double_esc_row = nil
    for row, line in ipairs(vim.api.nvim_buf_get_lines(opened_pi_history_buf, 0, -1, false)) do
      if line:find("double escape tree prompt", 1, true) then
        double_esc_row = row
        break
      end
    end
    assert(double_esc_row, "history should render a message with a Pi tree entry id for double escape smoke")
    local original_submit_text = require("coact").submit_text
    local double_esc_submit = nil
    require("coact").submit_text = function(text, thread_id)
      double_esc_submit = { text = text, thread_id = thread_id }
    end
    vim.api.nvim_set_current_win(opened_pi_history_win)
    vim.api.nvim_win_set_cursor(opened_pi_history_win, { double_esc_row, 0 })
    vim.fn.maparg("<Esc><Esc>", "n", false, true).callback()
    assert(
      double_esc_submit
        and double_esc_submit.text == "/tree entry-double-esc"
        and double_esc_submit.thread_id == "pi:smoke-session",
      "history double escape should open the Pi tree at the message under cursor"
    )
    pi_buffers.enter_compose("pi:smoke-session", { startinsert = false })
    vim.api.nvim_set_current_win(pi_state_thread.prompt_winid)
    double_esc_submit = nil
    local prompt_double_esc = vim.fn.maparg("<Esc><Esc>", "n", false, true).callback
    assert(type(prompt_double_esc) == "function", "composer should bind double escape Pi tree")
    prompt_double_esc()
    assert(
      double_esc_submit and double_esc_submit.text == "/tree" and double_esc_submit.thread_id == "pi:smoke-session",
      "composer double escape should open the Pi tree without an initial selection"
    )
    require("coact").submit_text = original_submit_text
    pi_buffers.enter_preview(pi_state_thread, { focus = true })
    local opened_pi_history_width = vim.api.nvim_win_get_width(opened_pi_history_win)
    local opened_footer = footer_text(opened_pi_history_win)
    assert(
      opened_footer:find("🤖 gpt-4o", 1, true)
        and opened_footer:find("82.5%/272k (auto)", 1, true)
        and vim.fn.strdisplaywidth(opened_footer) <= opened_pi_history_width,
      "opening history should render status in the window footer at the actual width"
    )
    local narrow_history_width = 24
    local win_config = vim.api.nvim_win_get_config(opened_pi_history_win)
    if win_config.relative and win_config.relative ~= "" then
      win_config.width = narrow_history_width
      pcall(vim.api.nvim_win_set_config, opened_pi_history_win, win_config)
    else
      pcall(vim.api.nvim_win_set_width, opened_pi_history_win, narrow_history_width)
    end
    pcall(vim.api.nvim_exec_autocmds, "WinResized", {})
    vim.wait(1000, function()
      local resized_footer = footer_text(opened_pi_history_win)
      return resized_footer:find("Pi", 1, true) ~= nil
        and vim.fn.strdisplaywidth(resized_footer) <= narrow_history_width
    end, 20)
    assert(
      vim.fn.strdisplaywidth(footer_text(opened_pi_history_win)) <= narrow_history_width,
      "WinResized should immediately re-render the status footer to the new window width"
    )
    pcall(vim.api.nvim_win_close, opened_pi_history_win, true)
    local status_detail_buf, status_detail_win = pi_statusline.toggle_detail(pi_state_thread)
    assert(
      status_detail_buf
        and status_detail_win
        and vim.api.nvim_buf_is_valid(status_detail_buf)
        and vim.api.nvim_win_is_valid(status_detail_win),
      "gs status detail should open a status detail page"
    )
    local status_detail_text = table.concat(vim.api.nvim_buf_get_lines(status_detail_buf, 0, -1, false), "\n")
    assert(
      status_detail_text:match("# Pi status")
        and status_detail_text:match("Provider UI")
        and status_detail_text:match("gpt%-4o"),
      "status detail should include structured Pi provider UI details"
    )
    pi_statusline.toggle_detail(pi_state_thread)
    state.active_thread_id = "pi:smoke-session"
    local pi_prompt_buf = pi_buffers.ensure_prompt("pi:smoke-session")
    require("coact.ui.render").apply_prompt_marks(pi_state_thread, pi_prompt_buf)
    local coact_ns = vim.api.nvim_get_namespaces()["coact.nvim"]
    local pi_prompt_marks = vim.api.nvim_buf_get_extmarks(pi_prompt_buf, coact_ns, 0, -1, { details = true })
    local saw_status_virt_lines = false
    for _, mark in ipairs(pi_prompt_marks) do
      if mark[4] and mark[4].virt_lines then
        saw_status_virt_lines = true
        break
      end
    end
    assert(not saw_status_virt_lines, "composer prompt marks should not render statusline virtual lines")
    require("coact").set_statusline_visible(false, "pi:smoke-session")
    assert(not pi_statusline.visible(pi_state_thread), "Coact statusline command should hide status chrome")
    _G.__coact_smoke_hidden_status_text = table.concat(vim.api.nvim_buf_get_lines(pi_history_buf, 0, -1, false), "\n")
    assert(
      not _G.__coact_smoke_hidden_status_text:find("Pi status", 1, true),
      "Coact statusline command should keep status chrome out of the transcript buffer"
    )
    require("coact").set_statusline_visible(true, "pi:smoke-session")
    assert(pi_statusline.visible(pi_state_thread), "Coact statusline command should show status chrome")
  end)()
  do
    local loading_id = "pi:smoke-loading-session"
    local loading_thread = state.ensure_thread(loading_id, {
      title = "Loading smoke session",
      status = "starting",
      lifecycle = "starting",
      sync = "starting",
      sync_message = "Starting Pi execution unit…",
    })
    local render_module = require("coact.ui.render")
    local original_render = render_module.render
    local render_calls = 0
    render_module.render = function(...)
      render_calls = render_calls + 1
      return original_render(...)
    end
    local loading_buf, loading_win = require("coact.buffers").open(loading_id)
    render_module.render = original_render
    assert(render_calls == 1, "opening a new session buffer should render its initial state only once")
    local loading_marks =
      vim.api.nvim_buf_get_extmarks(loading_buf, vim.api.nvim_get_namespaces()["coact.nvim"], 0, -1, { details = true })
    local loading_text = ""
    for _, mark in ipairs(loading_marks) do
      for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
        loading_text = loading_text .. tostring(chunk[1] or "")
      end
    end
    assert(
      loading_text:find("Starting Pi execution unit", 1, true),
      "session hydration should render a transient loading spinner inside the session buffer"
    )
    loading_thread.sync = "failed"
    loading_thread.sync_message = "Could not restore Pi session"
    loading_thread.last_error = "smoke failure"
    require("coact.buffers").render(loading_id)
    local failed_loading_text = ""
    for _, mark in
      ipairs(
        vim.api.nvim_buf_get_extmarks(
          loading_buf,
          vim.api.nvim_get_namespaces()["coact.nvim"],
          0,
          -1,
          { details = true }
        )
      )
    do
      for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
        failed_loading_text = failed_loading_text .. tostring(chunk[1] or "")
      end
    end
    assert(
      failed_loading_text:find("Could not restore Pi session", 1, true)
        and failed_loading_text:find("smoke failure", 1, true),
      "session hydration failures should remain visible without entering transcript content"
    )
    pcall(vim.api.nvim_win_close, loading_win, true)
  end
  local pi_cwd = require("coact.config").cwd()
  local pi_session_dir = vim.fs.joinpath(pi_temp, "sessions")
  vim.fn.mkdir(pi_session_dir, "p")
  local pi_old_session_file = vim.fs.joinpath(pi_session_dir, "2026-06-15T16-16-54-901Z_pi-old.jsonl")
  local pi_new_session_file = vim.fs.joinpath(pi_session_dir, "2026-06-15T16-47-53-744Z_pi-new.jsonl")
  local function write_pi_session(path, id, created, prompt, name, model_id, top_level_model, parent_session)
    local model_change = top_level_model
        and {
          type = "model_change",
          id = "event-" .. id,
          provider = "openai",
          modelId = model_id,
        }
      or {
        type = "model_change",
        model = { provider = "openai", id = model_id },
      }
    vim.fn.writefile({
      vim.json.encode({
        type = "session",
        version = 3,
        id = id,
        timestamp = created,
        cwd = pi_cwd,
        parentSession = parent_session,
      }),
      vim.json.encode(model_change),
      vim.json.encode({
        type = "thinking_level_change",
        level = "high",
      }),
      vim.json.encode({
        type = "message",
        timestamp = created,
        message = {
          role = "user",
          content = {
            {
              type = "text",
              text = prompt,
            },
          },
        },
      }),
      vim.json.encode({
        type = "session_info",
        name = name,
      }),
    }, path)
  end
  write_pi_session(pi_old_session_file, "pi-old", "2026-06-15T16:16:54.901Z", "old pi prompt", "Old Pi", "gpt-4o")
  write_pi_session(
    pi_new_session_file,
    "pi-new",
    "2026-06-15T16:47:53.744Z",
    "new pi prompt",
    "New Pi",
    "gpt-5",
    true,
    pi_old_session_file
  )
  local resolved_pi_session_dir, pi_filters_by_cwd = pi_provider._session_dir_for_cwd(pi_cwd)
  assert(resolved_pi_session_dir == pi_session_dir, "Pi provider should use configured session_dir for history")
  assert(pi_filters_by_cwd == true, "custom Pi session_dir should filter sessions by cwd")
  local local_pi_sessions = pi_provider._list_local_sessions(pi_cwd)
  assert(#local_pi_sessions == 2, "Pi provider should list local JSONL sessions for the workspace")
  assert(local_pi_sessions[1].id == "pi:pi-new", "Pi local sessions should be sorted by newest activity")
  assert(local_pi_sessions[1].sessionFile == pi_new_session_file, "Pi threads should retain the native session file")
  assert(
    local_pi_sessions[1].parentSessionPath == pi_old_session_file and local_pi_sessions[1].parentThreadId == "pi:pi-old",
    "Pi thread history should retain and resolve parentSession fork lineage"
  )
  assert(local_pi_sessions[1].preview:match("new pi prompt"), "Pi thread preview should use the first user message")
  assert(local_pi_sessions[1].model == "openai/gpt-5", "Pi thread history should retain model metadata")
  assert(local_pi_sessions[1].reasoningEffort == "high", "Pi thread history should retain thinking metadata")
  write_pi_session(
    pi_new_session_file,
    "pi-new",
    "2026-06-15T16:47:53.744Z",
    "new pi prompt",
    "Renamed Pi",
    "gpt-5",
    true,
    pi_old_session_file
  )
  local refreshed_pi_sessions = pi_provider._list_local_sessions(pi_cwd)
  assert(
    refreshed_pi_sessions[1].name == "Renamed Pi",
    "Pi session metadata cache should invalidate when a JSONL file changes"
  )
  assert(
    pi_provider._resolve_session_file(pi_cwd, "pi:pi-old") == pi_old_session_file,
    "Pi thread ids should resolve back to session files"
  )
  local pi_list_result = nil
  local pi_list_calls = {}
  local pi_list_handled = pi_provider.custom_request(
    {
      _request_message = function(method, params, callback)
        table.insert(pi_list_calls, { method = method, params = params })
        assert(method == "get_state", "Pi thread/list should only need get_state after local scan")
        callback(nil, { sessionId = "pi-new" })
      end,
    },
    "thread/list",
    { cwd = pi_cwd },
    function(err, result)
      assert(not err, "Pi thread/list should not fail in smoke")
      pi_list_result = result
    end
  )
  assert(pi_list_handled, "Pi provider should handle thread/list")
  assert(
    #pi_list_calls == 1 and pi_list_calls[1].method == "get_state",
    "Pi thread/list should query current state once"
  )
  assert(
    pi_list_result and #pi_list_result.data == 2 and pi_list_result.data[1].id == "pi:pi-new",
    "Pi thread/list should return local history instead of an empty current session"
  )
  assert(
    pi_list_result.data[1].name == "Renamed Pi",
    "Pi thread/list should not overwrite local history titles with generic current state"
  )
  local pi_clients_before_local_list = require("coact.providers.pi_rpc").client_count()
  local public_pi_threads
  require("coact").list_threads(function(threads)
    public_pi_threads = threads
  end)
  assert(public_pi_threads and #public_pi_threads == 2, "public Pi thread listing should use the local session index")
  assert(
    require("coact.providers.pi_rpc").client_count() == pi_clients_before_local_list,
    "opening the Pi thread picker should not start an RPC process before the picker is visible"
  )
  local pi_resume_result = nil
  local pi_resume_calls = {}
  local pi_resume_handled = pi_provider.custom_request(
    {
      _request_message = function(method, params, callback)
        table.insert(pi_resume_calls, { method = method, params = params })
        if method == "switch_session" then
          callback(nil, {})
        elseif method == "get_state" then
          callback(nil, {
            sessionId = "pi-old",
            sessionFile = pi_old_session_file,
            sessionName = "Old Pi",
            thinkingLevel = "high",
            model = { provider = "openai", id = "gpt-4o" },
          })
        elseif method == "get_session_stats" then
          callback(nil, {
            contextUsage = { percent = 12.5, contextWindow = 200000, tokens = 25000 },
            tokens = { input = 100, output = 50, total = 150 },
            autoCompactionEnabled = true,
          })
        elseif method == "prompt" then
          assert(params.message == "/coact-nvim-branch-snapshot", "Pi resume should request a branch snapshot")
          pi_provider._runtime.branch_snapshot = {
            entries = {
              { id = "entry-old-user", role = "user", text = "old pi prompt" },
            },
          }
          callback(nil, {})
        elseif method == "get_messages" then
          callback(nil, {
            messages = {
              {
                role = "user",
                content = {
                  {
                    type = "text",
                    text = "old pi prompt",
                  },
                },
              },
            },
          })
        else
          error("unexpected Pi smoke request: " .. tostring(method))
        end
      end,
    },
    "thread/resume",
    { cwd = pi_cwd, threadId = "pi:pi-old" },
    function(err, result)
      assert(not err, "Pi thread/resume should not fail in smoke")
      pi_resume_result = result
    end
  )
  assert(pi_resume_handled, "Pi provider should handle thread/resume")
  assert(
    #pi_resume_calls == 5
      and pi_resume_calls[1].method == "switch_session"
      and pi_resume_calls[1].params.sessionPath == pi_old_session_file
      and pi_resume_calls[2].method == "get_state"
      and pi_resume_calls[3].method == "get_session_stats"
      and pi_resume_calls[4].method == "prompt"
      and pi_resume_calls[5].method == "get_messages",
    "Pi resume should switch to the selected native session before reading messages"
  )
  assert(
    pi_resume_result
      and pi_resume_result.thread.id == "pi:pi-old"
      and pi_resume_result.thread.turns
      and #pi_resume_result.thread.turns == 1
      and pi_resume_result.thread.turns[1].items[1].treeEntryId == "entry-old-user"
      and pi_resume_result.thread.token_usage.contextUsage.percent == 12.5,
    "Pi resume should return the selected historical thread with session stats"
  );
  (function()
    local pi_tree_result = nil
    local pi_tree_calls = {}
    local pi_tree_handled = pi_provider.custom_request(
      {
        _request_message = function(method, params, callback)
          table.insert(pi_tree_calls, { method = method, params = params })
          if method == "prompt" then
            if params.message:find("/coact-nvim-tree", 1, true) == 1 then
              assert(params.message:find("entry-tree-user", 1, true), "Pi thread/tree should forward initialSelectedId")
              callback(nil, {})
            elseif params.message == "/coact-nvim-branch-snapshot" then
              pi_provider._runtime.branch_snapshot = {
                entries = {
                  { id = "entry-tree-user", role = "user", text = "tree-selected prompt" },
                },
              }
              callback(nil, {})
            else
              error("unexpected Pi tree prompt: " .. tostring(params.message))
            end
          elseif method == "get_state" then
            callback(nil, {
              sessionId = "pi-old",
              sessionFile = pi_old_session_file,
              sessionName = "Old Pi",
            })
          elseif method == "get_session_stats" then
            callback(nil, {
              contextUsage = { percent = 30, contextWindow = 200000, tokens = 60000 },
              tokens = { input = 100, output = 50, total = 150 },
            })
          elseif method == "get_messages" then
            callback(nil, {
              messages = {
                {
                  role = "user",
                  content = {
                    {
                      type = "text",
                      text = "tree-selected prompt",
                    },
                  },
                },
              },
            })
          else
            error("unexpected Pi tree smoke request: " .. tostring(method))
          end
        end,
      },
      "thread/tree",
      { cwd = pi_cwd, threadId = "pi:pi-old", initialSelectedId = "entry-tree-user" },
      function(err, result)
        assert(not err, "Pi thread/tree should not fail in smoke")
        pi_tree_result = result
      end
    )
    assert(pi_tree_handled, "Pi provider should handle thread/tree")
    assert(
      #pi_tree_calls == 5
        and pi_tree_calls[1].method == "prompt"
        and pi_tree_calls[1].params.message:find("entry-tree-user", 1, true)
        and pi_tree_calls[2].method == "get_state"
        and pi_tree_calls[3].method == "get_session_stats"
        and pi_tree_calls[4].method == "prompt"
        and pi_tree_calls[4].params.message == "/coact-nvim-branch-snapshot"
        and pi_tree_calls[5].method == "get_messages",
      "Pi thread/tree should navigate before refreshing current messages"
    )
    assert(
      pi_tree_result
        and pi_tree_result.thread.replaceTurns == true
        and pi_tree_result.thread.turns
        and pi_tree_result.thread.turns[1].items[1].content[1].text == "tree-selected prompt"
        and pi_tree_result.thread.turns[1].items[1].treeEntryId == "entry-tree-user",
      "Pi thread/tree should return a replacement branch snapshot"
    )
  end)();
  (function()
    local pi_tree_reveal_result = nil
    local pi_tree_reveal_calls = {}
    local pi_tree_reveal_handled = pi_provider.custom_request(
      {
        _request_message = function(method, params, callback)
          table.insert(pi_tree_reveal_calls, { method = method, params = params })
          assert(method == "prompt", "Pi local tree reveal should only send the tree prompt")
          pi_provider._runtime.last_tree_action = {
            __coactNvimPiTreeAction = true,
            action = "reveal",
            id = "entry-local-reveal",
          }
          callback(nil, {})
        end,
      },
      "thread/tree",
      { cwd = pi_cwd, threadId = "pi:pi-old", initialSelectedId = "entry-local-reveal" },
      function(err, result)
        assert(not err, "Pi thread/tree local reveal should not fail in smoke")
        pi_tree_reveal_result = result
      end
    )
    assert(pi_tree_reveal_handled, "Pi provider should handle thread/tree local reveal")
    assert(
      #pi_tree_reveal_calls == 1
        and pi_tree_reveal_result
        and pi_tree_reveal_result.treeAction
        and pi_tree_reveal_result.treeAction.action == "reveal"
        and pi_tree_reveal_result.treeAction.id == "entry-local-reveal",
      "Pi thread/tree local reveal should skip native branch refresh"
    )
  end)();
  (function()
    local tool_id = "history-order-tool"
    local history_order_turns = pi_provider._turns_from_messages({
      {
        role = "user",
        content = { { type = "text", text = "preserve history order" } },
      },
      {
        role = "assistant",
        content = {
          { type = "text", text = "commentary before tool" },
          { type = "toolCall", id = tool_id, name = "read", arguments = { path = "before.txt" } },
        },
      },
      {
        role = "toolResult",
        toolCallId = tool_id,
        toolName = "read",
        content = { { type = "text", text = "tool output" } },
        isError = false,
      },
      {
        role = "assistant",
        content = { { type = "text", text = "final answer after tool" } },
      },
    }, "pi:history-order")
    local history_order_items = history_order_turns[1].items
    assert(
      history_order_items[2].id ~= history_order_items[#history_order_items].id,
      "Pi history should give consecutive assistant messages distinct item ids"
    )
    local history_order_thread = state.update_thread_from_payload({
      id = "pi:history-order",
      replaceTurns = true,
      turns = history_order_turns,
    })
    local history_order_blocks = require("coact.ui.render").select_render_tree(history_order_thread)
    local commentary_index = nil
    local tool_index = nil
    local final_index = nil
    for index, block in ipairs(history_order_blocks) do
      if block.type == "AssistantBlock" and block.text == "commentary before tool" then
        commentary_index = index
      elseif block.type == "ActivitySummaryBlock" then
        for _, child in ipairs(block.children or {}) do
          if child.item_id == tool_id then
            tool_index = index
          end
        end
      elseif block.type == "AssistantBlock" and block.text == "final answer after tool" then
        final_index = index
      end
    end
    assert(
      commentary_index and tool_index and final_index and commentary_index < tool_index and tool_index < final_index,
      "Pi history rendering should preserve commentary, tool, and final-answer order from JSONL"
    )
  end)();
  (function()
    local summary_messages = {
      {
        role = "compactionSummary",
        summary = "## Goal\nPreserve compacted work",
        tokensBefore = 120000,
        timestamp = 1000,
      },
      {
        role = "user",
        content = { { type = "text", text = "kept prompt" } },
      },
      {
        role = "assistant",
        content = { { type = "text", text = "kept answer" } },
      },
      {
        role = "branchSummary",
        summary = table.concat({
          "The user explored a different conversation branch before returning here.",
          "",
          "## Goal",
          "Explore the sibling branch",
        }, "\n"),
        fromId = "entry-kept-answer",
        timestamp = 2000,
      },
    }
    local summary_snapshot = {
      entries = {
        {
          id = "entry-compaction",
          parentId = "entry-old-leaf",
          role = "compactionSummary",
          text = summary_messages[1].summary,
          tokensBefore = 120000,
          timestamp = "1970-01-01T00:00:01.000Z",
        },
        { id = "entry-kept-user", role = "user", text = "kept prompt" },
        { id = "entry-kept-answer", role = "assistant", text = "kept answer" },
        {
          id = "entry-branch-summary",
          parentId = "entry-kept-answer",
          role = "branchSummary",
          text = summary_messages[4].summary,
          fromId = "entry-kept-answer",
          timestamp = "1970-01-01T00:00:02.000Z",
        },
      },
    }
    local summary_turns = pi_provider._turns_from_messages(summary_messages, "pi:summary-blocks", summary_snapshot)
    local null_summary_turns = pi_provider._turns_from_messages({
      {
        role = "compactionSummary",
        summary = vim.NIL,
        tokensBefore = vim.NIL,
        timestamp = vim.NIL,
      },
    }, "pi:null-summary")
    assert(
      null_summary_turns[1].items[1].text == "" and null_summary_turns[1].items[1].tokensBefore == nil,
      "Pi summary normalization should treat RPC null fields as absent"
    )
    assert(
      #summary_turns == 2
        and summary_turns[1].items[1].type == "compactionSummary"
        and summary_turns[1].items[1].treeEntryId == "entry-compaction"
        and summary_turns[2].items[1].type == "userMessage"
        and summary_turns[2].items[#summary_turns[2].items].type == "branchSummary"
        and summary_turns[2].items[#summary_turns[2].items].treeEntryId == "entry-branch-summary",
      "Pi history normalization should retain compaction and branch summaries with native tree ids"
    )

    local summary_thread = state.update_thread_from_payload({
      id = "pi:summary-blocks",
      replaceTurns = true,
      turns = summary_turns,
    })
    local summary_render = require("coact.ui.render")
    local summary_blocks = summary_render.select_render_tree(summary_thread)
    assert(
      #summary_blocks == 4
        and summary_blocks[1].type == "CompactionSummaryBlock"
        and summary_blocks[2].type == "UserBlock"
        and summary_blocks[3].type == "AssistantBlock"
        and summary_blocks[4].type == "BranchSummaryBlock",
      "Pi compaction summaries should precede retained context while branch summaries follow their navigation anchor"
    )
    local summary_buf = vim.api.nvim_create_buf(false, true)
    state.bind_buffer(summary_thread, summary_buf)
    summary_render.render(summary_thread)
    assert(
      #summary_thread.placeholder_marks == 2
        and summary_thread.placeholder_marks[1].title == "Context compacted"
        and summary_thread.placeholder_marks[2].title == "Branch summary",
      "Pi summaries should render as distinct collapsed placeholder blocks"
    )
    local collapsed_summary_marks = vim.inspect(vim.tbl_map(function(mark)
      return vim.api.nvim_buf_get_extmark_by_id(
        summary_buf,
        summary_render.namespace(),
        mark.extmark_id,
        { details = true }
      )
    end, summary_thread.placeholder_marks))
    assert(
      collapsed_summary_marks:match("120000 tokens before")
        and collapsed_summary_marks:match("Preserve compacted work")
        and collapsed_summary_marks:match("Explore the sibling branch"),
      "collapsed Pi summary rows should expose token and goal previews"
    )
    for _, mark in ipairs(summary_thread.placeholder_marks) do
      summary_thread.expanded_blocks[mark.key] = true
    end
    summary_render.render(summary_thread)
    local expanded_summary_marks = vim.inspect(vim.tbl_map(function(mark)
      return vim.api.nvim_buf_get_extmark_by_id(
        summary_buf,
        summary_render.namespace(),
        mark.extmark_id,
        { details = true }
      )
    end, summary_thread.placeholder_marks))
    assert(
      expanded_summary_marks:match("Compacted from 120000 tokens")
        and expanded_summary_marks:match("Preserve compacted work")
        and expanded_summary_marks:match("Explore the sibling branch"),
      "expanded Pi summary rows should expose their full summary bodies"
    )
    local summary_detail = require("coact.ui.detail")
    local compaction_detail = table.concat(summary_detail.lines_for(summary_blocks[1]), "\n")
    local branch_detail = table.concat(summary_detail.lines_for(summary_blocks[4]), "\n")
    assert(
      compaction_detail:match("# Context compacted")
        and compaction_detail:match("tokens%-before: 120000")
        and branch_detail:match("# Branch summary")
        and branch_detail:match("from%-id: entry%-kept%-answer"),
      "Pi summary detail pages should preserve their distinct semantics"
    )

    local root_summary_turns = pi_provider._turns_from_messages({
      { role = "branchSummary", summary = "root branch summary", timestamp = 3000 },
    }, "pi:root-summary")
    local root_summary_thread = state.update_thread_from_payload({
      id = "pi:root-summary",
      replaceTurns = true,
      turns = root_summary_turns,
    })
    local root_summary_blocks = summary_render.select_render_tree(root_summary_thread)
    assert(
      #root_summary_blocks == 1 and root_summary_blocks[1].type == "BranchSummaryBlock",
      "a root-navigation branch summary should become the first transcript block while the prompt returns to the composer"
    )

    pi_provider._runtime.current_thread_id = "pi:summary-lifecycle"
    local compaction_notification = pi_provider.decode_notification({
      type = "compaction_end",
      reason = "manual",
      result = {
        summary = "refreshed compacted context",
        tokensBefore = 64000,
      },
      aborted = false,
      willRetry = false,
    })
    assert(
      compaction_notification
        and compaction_notification.message.method == "pi/compaction_end"
        and compaction_notification.message.params.result.summary == "refreshed compacted context",
      "Pi compaction completion should retain its summary for a durable history refresh"
    )
    local original_compaction_hook = pi_provider.on_compaction_completed
    local observed_compaction = nil
    pi_provider.on_compaction_completed = function(params)
      observed_compaction = params
    end
    local compaction_lifecycle_thread = state.ensure_thread("pi:summary-lifecycle")
    compaction_lifecycle_thread.pi_agent_active = false
    state.clear_thread_pending_requests(compaction_lifecycle_thread)
    require("coact.core").handle_notification({
      method = "pi/compaction_start",
      params = { threadId = "pi:summary-lifecycle", reason = "manual" },
    })
    assert(
      compaction_lifecycle_thread.generation == "summarizing"
        and compaction_lifecycle_thread.status_message == "Pi is compacting context...",
      "Pi compaction should use the observable summarizing lifecycle"
    )
    require("coact.core").handle_notification(compaction_notification.message)
    local immediate_compaction = observed_compaction
    observed_compaction = nil
    compaction_lifecycle_thread.pi_agent_active = true
    require("coact.core").handle_notification({
      method = "pi/compaction_end",
      params = {
        threadId = "pi:summary-lifecycle",
        reason = "overflow",
        result = { summary = "deferred compacted context", tokensBefore = 128000 },
        willRetry = true,
      },
    })
    assert(
      observed_compaction == nil and compaction_lifecycle_thread.pi_compaction_refresh,
      "active Pi compaction should defer replacement until retry and queued continuation events settle"
    )
    require("coact.core").handle_notification({
      method = "pi/agent_settled",
      params = { threadId = "pi:summary-lifecycle" },
    })
    local deferred_compaction = observed_compaction
    pi_provider.on_compaction_completed = original_compaction_hook
    assert(
      immediate_compaction
        and immediate_compaction.result.summary == "refreshed compacted context"
        and deferred_compaction
        and deferred_compaction.result.summary == "deferred compacted context"
        and compaction_lifecycle_thread.generation == "idle",
      "successful Pi compaction should trigger branch replacement instead of a generic timeline row"
    )

    local refresh_thread = state.ensure_thread("pi:summary-refresh")
    state.upsert_item("pi:summary-refresh", "old-turn", {
      id = "stale-pre-compaction-item",
      type = "agentMessage",
      text = "stale pre-compaction history",
    })
    local refresh_calls = {}
    local refreshed_thread = nil
    pi_provider._refresh_current_thread({
      _request_message = function(method, params, callback)
        table.insert(refresh_calls, method)
        if method == "get_state" then
          callback(nil, { sessionId = "summary-refresh", sessionName = "Summary refresh" })
        elseif method == "get_session_stats" then
          callback(nil, { tokens = { total = 42 } })
        elseif method == "prompt" then
          assert(params.message == "/coact-nvim-branch-snapshot")
          pi_provider._runtime.branch_snapshot = {
            entries = {
              {
                id = "refresh-compaction-entry",
                role = "compactionSummary",
                text = "refreshed compacted context",
                tokensBefore = 64000,
              },
            },
          }
          callback(nil, {})
        elseif method == "get_messages" then
          callback(nil, {
            messages = {
              {
                role = "compactionSummary",
                summary = "refreshed compacted context",
                tokensBefore = 64000,
              },
            },
          })
        else
          error("unexpected Pi compaction refresh request: " .. tostring(method))
        end
      end,
    }, { threadId = "pi:summary-refresh" }, function(err, thread)
      assert(not err, "Pi compaction refresh should succeed")
      refreshed_thread = thread
    end)
    assert(
      refreshed_thread
        and refreshed_thread.items["stale-pre-compaction-item"] == nil
        and refreshed_thread.items[refreshed_thread.item_order[1]].type == "compactionSummary"
        and vim.deep_equal(refresh_calls, { "get_state", "get_session_stats", "prompt", "get_messages" }),
      "Pi compaction refresh should replace stale turns with the compaction-aware active context"
    )
    assert(
      refresh_thread.sync == "clean" and refresh_thread.sync_message == nil,
      "Pi history refresh should settle its hydration state after replacing the active context"
    )

    local overlapping_thread = state.ensure_thread("pi:overlapping-refresh", { sync = "clean" })
    local held_state_callbacks = {}
    local overlapping_results = 0
    local function overlapping_client()
      return {
        _request_message = function(method, _, callback)
          if method == "get_state" then
            table.insert(held_state_callbacks, callback)
          elseif method == "get_session_stats" then
            callback(nil, { tokens = { total = 1 } })
          elseif method == "prompt" then
            callback(nil, {})
          elseif method == "get_messages" then
            callback(nil, { messages = {} })
          else
            error("unexpected overlapping Pi refresh request: " .. tostring(method))
          end
        end,
      }
    end
    pi_provider._refresh_current_thread(overlapping_client(), { threadId = overlapping_thread.id }, function(err)
      assert(not err, "first overlapping Pi refresh should succeed")
      overlapping_results = overlapping_results + 1
    end)
    pi_provider._refresh_current_thread(overlapping_client(), { threadId = overlapping_thread.id }, function(err)
      assert(not err, "second overlapping Pi refresh should succeed")
      overlapping_results = overlapping_results + 1
    end)
    assert(
      #held_state_callbacks == 2 and overlapping_thread.sync == "hydrating",
      "overlapping Pi refreshes should share one observable hydration phase"
    )
    held_state_callbacks[1](nil, { sessionId = "overlapping-refresh", sessionName = "Older refresh" })
    assert(
      overlapping_results == 1 and overlapping_thread.sync == "hydrating",
      "a stale Pi refresh completion must not clear a newer hydration operation"
    )
    held_state_callbacks[2](nil, { sessionId = "overlapping-refresh", sessionName = "Newer refresh" })
    assert(
      overlapping_results == 2 and overlapping_thread.sync == "clean" and overlapping_thread.sync_message == nil,
      "the newest Pi refresh completion should settle the hydration state"
    )

    local failed_refresh_thread = state.ensure_thread("pi:failed-refresh", { sync = "clean" })
    local failed_refresh_error
    pi_provider._refresh_current_thread({
      _request_message = function(method, _, callback)
        assert(method == "get_state", "failed Pi refresh should stop at get_state")
        callback({ message = "refresh failed" }, nil)
      end,
    }, { threadId = failed_refresh_thread.id }, function(err)
      failed_refresh_error = err
    end)
    assert(
      failed_refresh_error and failed_refresh_thread.sync == "clean" and failed_refresh_thread.sync_message == nil,
      "failed Pi history refresh should also settle its transient hydration state"
    )
    vim.api.nvim_buf_delete(summary_buf, { force = true })
  end)();
  (function()
    pi_provider._runtime.current_thread_id = "pi:smoke-session"
    pi_provider._runtime.active_turn_id = "pi-turn-active"
    pi_provider._runtime.last_turn_id = "pi-turn-active"
    pi_provider._runtime.queued_turns = {}
    local queued_result = nil
    local prompt_params = nil
    local handled = pi_provider.custom_request(
      {
        _request_message = function(method, params, callback)
          assert(method == "prompt", "Pi queued turn/start should still use prompt RPC")
          assert(
            pi_provider._runtime.queued_turns[1] and pi_provider._runtime.queued_turns[1].message == "queued follow-up",
            "Pi should reserve queued turn state before sending the prompt RPC"
          )
          prompt_params = params
          callback(nil, {})
        end,
      },
      "turn/start",
      {
        threadId = "pi:smoke-session",
        input = { { type = "text", text = "queued follow-up" } },
        streamingBehavior = "followUp",
      },
      function(err, result)
        assert(not err, "Pi queued turn/start should be accepted")
        queued_result = result
      end
    )
    assert(handled, "Pi provider should handle queued turn/start")
    assert(prompt_params and prompt_params.streamingBehavior == "followUp", "Pi queued submit should forward followUp")
    assert(
      pi_provider._runtime.active_turn_id == "pi-turn-active",
      "Pi queued submit should not steal the active streaming turn id"
    )
    assert(
      queued_result and queued_result.queued == true and queued_result.turn and #(queued_result.turn.items or {}) == 0,
      "Pi queued submit should return an empty optimistic turn until Pi starts it"
    )
    assert(
      pi_provider._runtime.queued_turns[1] and pi_provider._runtime.queued_turns[1].id == queued_result.turn.id,
      "Pi queued submit should remember the queued turn id for later streaming events"
    )
    local active_end =
      pi_provider.decode_notification({ type = "turn_end", message = { role = "assistant", content = {} } })
    assert(active_end, "Pi active turn_end should decode before queued follow-up starts")
    assert(pi_provider._runtime.active_turn_id == nil, "Pi active turn_end should clear the active turn")
    local agent_end = pi_provider.decode_notification({ type = "agent_end", messages = {} })
    local queue_update = pi_provider.decode_notification({ type = "queue_update", steering = {}, followUp = {} })
    local agent_start = pi_provider.decode_notification({ type = "agent_start" })
    assert(
      agent_end and queue_update and agent_start and pi_provider._runtime.active_turn_id == nil,
      "Pi thread-level lifecycle and queue events should not allocate phantom turns"
    )
    local queued_start = pi_provider.decode_notification({ type = "turn_start" })
    assert(
      queued_start == nil and pi_provider._runtime.active_turn_id == nil,
      "Pi turn_start should wait for the first message before choosing a queued turn"
    )
    local queued_message_start = pi_provider.decode_notification({
      type = "message_start",
      message = {
        role = "user",
        content = { { type = "text", text = "queued follow-up" } },
      },
    })
    assert(
      queued_message_start
        and queued_message_start[1].message.method == "turn/started"
        and queued_message_start[1].message.params.turn.id == queued_result.turn.id
        and queued_message_start[3].message.params.item.id == queued_result.turn.id .. ":user",
      "Pi queued user message should consume the queued id and emit the user item in that turn"
    )
    assert(
      pi_provider._runtime.active_turn_id == queued_result.turn.id,
      "Pi queued user message should become the active turn for subsequent deltas"
    )

    pi_provider._runtime.active_turn_id = "pi-turn-tool-active"
    pi_provider._runtime.last_turn_id = "pi-turn-tool-active"
    pi_provider._runtime.queued_turns = {
      {
        id = "pi-turn-after-tools",
        message = "after tools",
        input = { { type = "text", text = "after tools" } },
        streamingBehavior = "followUp",
      },
    }
    pi_provider.decode_notification({ type = "turn_end", message = { role = "assistant", content = {} } })
    pi_provider.decode_notification({ type = "turn_start" })
    local tool_continuation = pi_provider.decode_notification({
      type = "message_start",
      message = { role = "assistant", content = {} },
    })
    assert(
      tool_continuation
        and tool_continuation[1].message.params.turn.id ~= "pi-turn-after-tools"
        and pi_provider._runtime.queued_turns[1].id == "pi-turn-after-tools",
      "Pi assistant tool continuations should not consume queued follow-up turns"
    )
    pi_provider.decode_notification({ type = "turn_end", message = { role = "assistant", content = {} } })
    pi_provider.decode_notification({ type = "turn_start" })
    local after_tools_start = pi_provider.decode_notification({
      type = "message_start",
      message = { role = "user", content = { { type = "text", text = "after tools" } } },
    })
    assert(
      after_tools_start and after_tools_start[1].message.params.turn.id == "pi-turn-after-tools",
      "Pi should consume a follow-up only when its queued user message starts"
    )
    local settled = pi_provider.decode_notification({ type = "agent_settled" })
    assert(
      settled
        and settled.message.method == "pi/agent_settled"
        and pi_provider._runtime.active_turn_id == nil
        and #pi_provider._runtime.queued_turns == 0,
      "Pi agent_settled should clear transient turn and queue state"
    )
    pi_provider._runtime.last_turn_id = nil
  end)()
  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        edit_bridge = {
          enabled = false,
        },
      },
    },
  })
  assert(not pi_bridge.enabled(), "Pi edit bridge should respect the provider disable switch")
  assert(pi_nvim_bridge.enabled(), "Pi Neovim bridge should remain independent from pair edit review")
  local nvim_only_command, nvim_only_env = pi_provider.prepare_command({ "pi", "--mode", "rpc" }, {})
  local nvim_only_extension_count = 0
  for _, part in ipairs(nvim_only_command) do
    if part == "--extension" then
      nvim_only_extension_count = nvim_only_extension_count + 1
    end
  end
  assert(
    nvim_only_extension_count == 1
      and nvim_only_env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE
      and not nvim_only_env.COACT_NVIM_PI_EDIT_BRIDGE_ADDR,
    "Pi should inject nvim_exec_lua without enabling the edit-review bridge"
  )
  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        edit_bridge = {
          enabled = false,
        },
        nvim_tools = {
          enabled = false,
        },
      },
    },
  })
  assert(not pi_bridge.enabled(), "Pi edit bridge should stay disabled")
  assert(not pi_nvim_bridge.enabled(), "Pi Neovim bridge should respect the provider disable switch")
  local disabled_command = pi_provider.prepare_command({ "pi", "--mode", "rpc" }, {})
  assert(
    not vim.tbl_contains(disabled_command, "--extension"),
    "disabled Pi process-local bridges should not inject extensions"
  )

  local fake_pi_rpc_path = vim.fn.tempname() .. "-coact-fake-pi-rpc.mjs"
  local fake_pi_session_dir = vim.fn.tempname() .. "-coact-fake-pi-sessions"
  vim.fn.mkdir(fake_pi_session_dir, "p")
  local fake_resume_file = vim.fs.joinpath(fake_pi_session_dir, "resume-route.jsonl")
  vim.fn.writefile({
    vim.json.encode({
      type = "session",
      version = 3,
      id = "resume-route",
      timestamp = "2026-08-07T00:00:00.000Z",
      cwd = vim.fn.getcwd(),
    }),
  }, fake_resume_file)
  vim.fn.writefile(
    vim.split(
      [[
import { readFileSync } from "node:fs";
let input = "";
const client = process.env.COACT_NVIM_PI_CLIENT_ID || "unknown";
const sessionIdIndex = process.argv.indexOf("--session-id");
let sessionId = sessionIdIndex >= 0 ? process.argv[sessionIdIndex + 1] : client;
let sessionFile = `/tmp/${sessionId}.jsonl`;
let model = { provider: "fake", id: "default" };
const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const respond = (command, data = {}) => send({
  id: command.id,
  type: "response",
  command: command.type,
  success: true,
  data,
});
const state = () => ({
  sessionId,
  sessionFile,
  model,
  thinkingLevel: "low",
  isStreaming: false,
});
function prompt(command) {
  respond(command);
  if (command.message.startsWith("/coact-nvim-")) return;
  const text = command.message;
  const delay = client.endsWith("1") ? 25 : 5;
  setTimeout(() => {
    send({
      type: "extension_ui_request",
      id: `status-${client}`,
      method: "setStatus",
      statusKey: "route",
      statusText: client,
    });
    send({ type: "agent_start" });
    send({ type: "turn_start" });
    send({ type: "message_start", message: { role: "user", content: [{ type: "text", text }] } });
    send({ type: "message_start", message: { role: "assistant", content: [] } });
    const reply = `reply:${client}:${text}`;
    send({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: reply },
    });
    const message = { role: "assistant", content: [{ type: "text", text: reply }] };
    send({ type: "message_end", message });
    send({ type: "turn_end", message, toolResults: [] });
    send({ type: "agent_end", messages: [message], willRetry: false });
    send({ type: "agent_settled" });
  }, delay);
}
function handle(command) {
  if (command.type === "get_state") return respond(command, state());
  if (command.type === "get_session_stats") {
    return respond(command, {
      sessionId,
      sessionFile,
      tokens: { input: 0, output: 0, total: 0 },
    });
  }
  if (command.type === "new_session") return respond(command, { cancelled: false });
  if (command.type === "switch_session") {
    const header = JSON.parse(readFileSync(command.sessionPath, "utf8").split("\n")[0]);
    sessionId = header.id;
    sessionFile = command.sessionPath;
    return respond(command, { cancelled: false });
  }
  if (command.type === "prompt") return prompt(command);
  if (command.type === "set_model") {
    model = { provider: command.provider, id: command.modelId };
    return respond(command, model);
  }
  if (command.type === "get_available_models") return respond(command, { models: [model] });
  if (command.type === "get_available_thinking_levels") return respond(command, { levels: ["off", "low"] });
  if (command.type === "get_messages") return respond(command, { messages: [] });
  if (command.type === "compact" || command.type === "abort") {
    return respond(command, { client, command: command.type });
  }
  return respond(command);
}
process.stdin.on("data", (chunk) => {
  input += chunk.toString();
  for (;;) {
    const newline = input.indexOf("\n");
    if (newline < 0) break;
    const line = input.slice(0, newline);
    input = input.slice(newline + 1);
    if (line.trim()) handle(JSON.parse(line));
  }
});
]],
      "\n",
      { plain = true }
    ),
    fake_pi_rpc_path
  )

  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        command = { "node", fake_pi_rpc_path },
        session_dir = fake_pi_session_dir,
        no_extensions = true,
        no_skills = true,
        no_context_files = true,
        edit_bridge = { enabled = false },
        nvim_tools = { enabled = false },
      },
    },
  })
  local rpc = require("coact.rpc")
  local pi_rpc = require("coact.providers.pi_rpc")
  pi_rpc.stop()
  local routed_threads = {}
  local prewarmed_client = pi_rpc.prewarm(function(err)
    assert(not err, err and err.message or "Pi picker prewarm should initialize")
  end)
  rpc.request("thread/start", { cwd = vim.fn.getcwd() }, function(err, result)
    assert(not err, err and err.message or "first Pi execution unit should start")
    routed_threads[1] = result.thread.id
    state.update_thread_from_payload(result.thread)
  end)
  rpc.request("thread/start", { cwd = vim.fn.getcwd() }, function(err, result)
    assert(not err, err and err.message or "second Pi execution unit should start")
    routed_threads[2] = result.thread.id
    state.update_thread_from_payload(result.thread)
  end)
  assert(
    vim.wait(5000, function()
      return routed_threads[1] ~= nil and routed_threads[2] ~= nil
    end, 10),
    "independent Pi execution units should initialize"
  )
  assert(routed_threads[1] ~= routed_threads[2], "Pi execution units should own distinct sessions")
  assert(
    pi_rpc.client_for_thread(routed_threads[1]) == prewarmed_client,
    "a thread selected while picker prewarm is starting should claim that same RPC client"
  )
  assert(
    pi_rpc.client_for_thread(routed_threads[1]) ~= pi_rpc.client_for_thread(routed_threads[2]),
    "each Pi thread should own a distinct RPC client"
  )
  assert(
    state.get_thread(routed_threads[1]).provider_client_id == pi_rpc.client_for_thread(routed_threads[1]).id
      and state.get_thread(routed_threads[2]).provider_client_id == pi_rpc.client_for_thread(routed_threads[2]).id,
    "Pi thread state should retain its execution-unit identity"
  )
  local targeted_thread
  rpc.request("thread/start", {
    cwd = vim.fn.getcwd(),
    sessionId = "smoke-targeted-session",
  }, function(err, result)
    assert(not err, err and err.message or "targeted Pi execution unit should start")
    targeted_thread = result.thread
  end)
  assert(
    vim.wait(5000, function()
      return targeted_thread ~= nil
    end, 10) and targeted_thread.id == "pi:smoke-targeted-session",
    "new Pi sessions should retain the id assigned before their loading buffer opens"
  )
  pi_rpc.stop(targeted_thread.id)

  local accepted_turns = 0
  rpc.request("turn/start", {
    threadId = routed_threads[1],
    input = { { type = "text", text = "alpha" } },
  }, function(err)
    assert(not err, err and err.message or "first interleaved Pi turn should be accepted")
    accepted_turns = accepted_turns + 1
  end)
  rpc.request("turn/start", {
    threadId = routed_threads[2],
    input = { { type = "text", text = "beta" } },
  }, function(err)
    assert(not err, err and err.message or "second interleaved Pi turn should be accepted")
    accepted_turns = accepted_turns + 1
  end)
  assert(
    vim.wait(5000, function()
      local first = state.get_thread(routed_threads[1])
      local second = state.get_thread(routed_threads[2])
      return accepted_turns == 2
        and first
        and second
        and not first.pi_agent_active
        and not second.pi_agent_active
        and #first.item_order >= 2
        and #second.item_order >= 2
    end, 10),
    "interleaved Pi sessions should settle independently"
  )
  local function routed_agent_text(thread_id)
    local thread = state.get_thread(thread_id)
    local texts = {}
    for _, item_id in ipairs(thread.item_order or {}) do
      local item = thread.items[item_id]
      if item and item.type == "agentMessage" then
        table.insert(texts, tostring(item.text or ""))
      end
    end
    return table.concat(texts, "\n")
  end
  local first_text = routed_agent_text(routed_threads[1])
  local second_text = routed_agent_text(routed_threads[2])
  assert(
    state.get_thread(routed_threads[1]).token_usage.sessionId == pi_rpc.client_for_thread(routed_threads[1]).id
      and state.get_thread(routed_threads[2]).token_usage.sessionId == pi_rpc.client_for_thread(routed_threads[2]).id,
    "Pi session statistics should update only their owning threads"
  )
  assert(
    first_text:find("alpha", 1, true) and not first_text:find("beta", 1, true),
    "first Pi session should receive only its own interleaved events"
  )
  assert(
    second_text:find("beta", 1, true) and not second_text:find("alpha", 1, true),
    "second Pi session should receive only its own interleaved events"
  )
  local first_ui = state.get_thread(routed_threads[1]).provider_ui
  local second_ui = state.get_thread(routed_threads[2]).provider_ui
  assert(
    first_ui
      and second_ui
      and first_ui.statuses.route == pi_rpc.client_for_thread(routed_threads[1]).id
      and second_ui.statuses.route == pi_rpc.client_for_thread(routed_threads[2]).id,
    "Pi extension UI state should stay isolated by execution unit"
  )

  local setting_updates = 0
  rpc.request("thread/settings/update", { threadId = routed_threads[1], model = "fake/model-alpha" }, function(err)
    assert(not err, err and err.message or "first Pi settings update should route")
    setting_updates = setting_updates + 1
  end)
  rpc.request("thread/settings/update", { threadId = routed_threads[2], model = "fake/model-beta" }, function(err)
    assert(not err, err and err.message or "second Pi settings update should route")
    setting_updates = setting_updates + 1
  end)
  local routed_configs = {}
  assert(
    vim.wait(5000, function()
      return setting_updates == 2
    end, 10),
    "per-thread Pi settings updates should complete"
  )
  rpc.request("config/read", { threadId = routed_threads[1] }, function(err, result)
    assert(not err, err and err.message or "first Pi config should read")
    routed_configs[1] = result.config.model
  end)
  rpc.request("config/read", { threadId = routed_threads[2] }, function(err, result)
    assert(not err, err and err.message or "second Pi config should read")
    routed_configs[2] = result.config.model
  end)
  assert(
    vim.wait(5000, function()
      return routed_configs[1] ~= nil and routed_configs[2] ~= nil
    end, 10),
    "per-thread Pi configs should return"
  )
  assert(
    routed_configs[1] == "fake/model-alpha" and routed_configs[2] == "fake/model-beta",
    "Pi model updates should remain isolated by execution unit"
  )
  assert(pi_bridge._payload_thread_id({
    __coactClientId = pi_rpc.client_for_thread(routed_threads[2]).id,
  }) == routed_threads[2], "Pi edit bridge payloads should route through their owning execution unit")
  local lifecycle_routes = {}
  rpc.request("thread/compact/start", { threadId = routed_threads[1] }, function(err, result)
    assert(not err, err and err.message or "Pi compact should route")
    lifecycle_routes.compact = result.client
  end)
  rpc.request("turn/interrupt", { threadId = routed_threads[2], turnId = "fake-turn" }, function(err, result)
    assert(not err, err and err.message or "Pi interrupt should route")
    lifecycle_routes.abort = result.client
  end)
  assert(
    vim.wait(5000, function()
      return lifecycle_routes.compact ~= nil and lifecycle_routes.abort ~= nil
    end, 10),
    "Pi lifecycle commands should complete on their owning execution units"
  )
  assert(
    lifecycle_routes.compact == pi_rpc.client_for_thread(routed_threads[1]).id
      and lifecycle_routes.abort == pi_rpc.client_for_thread(routed_threads[2]).id,
    "Pi compact and interrupt commands should not cross session routes"
  )
  local tree_routes = {}
  rpc.request("thread/tree", { threadId = routed_threads[1] }, function(err, result)
    assert(not err, err and err.message or "first Pi tree request should route")
    tree_routes[1] = result.thread.id
  end)
  rpc.request("thread/tree", { threadId = routed_threads[2] }, function(err, result)
    assert(not err, err and err.message or "second Pi tree request should route")
    tree_routes[2] = result.thread.id
  end)
  assert(
    vim.wait(5000, function()
      return tree_routes[1] ~= nil and tree_routes[2] ~= nil
    end, 10),
    "Pi tree requests should complete independently"
  )
  assert(
    tree_routes[1] == routed_threads[1] and tree_routes[2] == routed_threads[2],
    "Pi tree refreshes should remain on their requested sessions"
  )

  local stopped_client = pi_rpc.client_for_thread(routed_threads[2])
  local stopped_text = routed_agent_text(routed_threads[2])
  pi_rpc.stop(routed_threads[2])
  assert(rpc.is_running(routed_threads[1]), "stopping one Pi session should not stop another")
  assert(not rpc.is_running(routed_threads[2]), "the selected Pi session should stop independently")
  assert(
    pi_bridge._payload_thread_id({ __coactClientId = stopped_client.id }) == nil,
    "stale Pi edit bridge clients should not fall back to another active thread"
  )
  pi_rpc._dispatch(stopped_client, {
    type = "message_update",
    assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "stale" },
  })
  vim.wait(50)
  assert(
    routed_agent_text(routed_threads[2]) == stopped_text,
    "events from a stopped Pi execution unit should not update its former thread"
  )

  local resumed_route = nil
  rpc.request("thread/resume", {
    threadId = "pi:resume-route",
    cwd = vim.fn.getcwd(),
  }, function(err, result)
    assert(not err, err and err.message or "Pi session should lazily resume in its own execution unit")
    resumed_route = result.thread
    state.update_thread_from_payload(result.thread)
  end)
  assert(
    vim.wait(5000, function()
      return resumed_route ~= nil
    end, 10),
    "Pi session resume should initialize a dedicated execution unit"
  )
  assert(
    resumed_route.id == "pi:resume-route"
      and pi_rpc.client_for_thread("pi:resume-route")
      and pi_rpc.client_for_thread("pi:resume-route") ~= pi_rpc.client_for_thread(routed_threads[1]),
    "resumed Pi sessions should bind only to their own RPC clients"
  )
  local resumed_turn = false
  rpc.request("turn/start", {
    threadId = "pi:resume-route",
    input = { { type = "text", text = "resumed" } },
  }, function(err)
    assert(not err, err and err.message or "resumed Pi turn should route")
    resumed_turn = true
  end)
  assert(
    vim.wait(5000, function()
      return resumed_turn and routed_agent_text("pi:resume-route"):find("resumed", 1, true) ~= nil
    end, 10),
    "resumed Pi session events should stay on the resumed thread"
  )
  local routed_list = nil
  rpc.request("thread/list", { cwd = vim.fn.getcwd() }, function(err, result)
    assert(not err, err and err.message or "Pi thread list should include active execution units")
    routed_list = result.data
  end)
  assert(routed_list, "Pi thread list should be available without selecting one session process")
  local listed_ids = {}
  for _, listed in ipairs(routed_list) do
    listed_ids[listed.id] = true
  end
  assert(
    listed_ids[routed_threads[1]] and listed_ids["pi:resume-route"],
    "Pi thread list should merge every active execution unit with persisted sessions"
  )

  rpc.stop()
  vim.fn.delete(fake_pi_rpc_path)
  vim.fn.delete(fake_pi_session_dir, "rf")
  coact.setup()
end

local parser = require("coact.parser")
local parsed = parser.parse("hello\n>diagnostics")
assert(#parsed >= 1, "parser should produce user input")

local state = require("coact.state");
(function()
  local replace_turns_thread = state.update_thread_from_payload({
    id = "smoke-replace-turns",
    turns = {
      {
        id = "old-turn",
        items = {
          { id = "old-item", type = "agentMessage", text = "old" },
        },
      },
    },
  })
  state.update_thread_from_payload({
    id = "smoke-replace-turns",
    replaceTurns = true,
    turns = {
      {
        id = "new-turn",
        items = {
          { id = "new-item", type = "agentMessage", text = "new" },
        },
      },
    },
  })
  assert(
    replace_turns_thread.items["new-item"] and not replace_turns_thread.items["old-item"],
    "thread replacement payloads should clear stale items"
  )
end)()
local status_thread = state.update_thread_from_payload({
  id = "smoke-status-object",
  status = { type = "active", activeFlags = {} },
})
assert(status_thread.status == "active", "thread payload status objects should normalize to labels")
local metadata = require("coact.ui.metadata")
local status_labels = metadata.composer_labels({ config = {}, status = { type = "active", activeFlags = {} } })
assert(#status_labels == 1 and status_labels[1] == "active", "composer metadata should not stringify tables")
coact.setup({ thread = { model = "gpt-5", service_tier = "fast", reasoning_effort = "high" } })
local configured_composer_labels = metadata.composer_labels({ config = {}, status = "active" })
assert(
  vim.deep_equal(configured_composer_labels, { "gpt-5", "fast", "effort high", "active" }),
  "composer metadata should include configured model, fast tier, and reasoning effort"
)
coact.setup({ thread = { model = "gpt-5", reasoning_effort = "high" } })
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
local effective_turn_params = coact._turn_start_params("smoke-thread-settings-header", {})
assert(effective_turn_params.effort == "medium", "turn/start should use updated thread reasoning effort")
assert(effective_turn_params.serviceTier == "fast", "turn/start should use updated thread service tier");
(function()
  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        edit_bridge = {
          enabled = false,
        },
      },
    },
  })
  local busy_pi_submit_thread = state.ensure_thread("pi:smoke-busy-submit", {
    generation = "streaming",
    active_turn_id = "pi-turn-active",
  })
  local rpc_for_busy_submit = require("coact.rpc")
  local original_rpc_start_for_busy_submit = rpc_for_busy_submit.start
  local original_rpc_request_for_busy_submit = rpc_for_busy_submit.request
  local busy_submit_params = nil
  rpc_for_busy_submit.start = function(callback)
    callback(nil, true)
  end
  rpc_for_busy_submit.request = function(method, params, callback)
    assert(method == "turn/start", "busy Pi submit should start a turn")
    busy_submit_params = params
    callback(nil, { turn = { id = "pi-queued-submit", items = {} } })
  end
  coact.submit_text("queued while busy", "pi:smoke-busy-submit")
  rpc_for_busy_submit.request = original_rpc_request_for_busy_submit
  rpc_for_busy_submit.start = original_rpc_start_for_busy_submit
  assert(busy_submit_params.streamingBehavior == "followUp", "busy Pi submit should queue as followUp")
  assert(
    busy_pi_submit_thread.pending_request and busy_pi_submit_thread.pending_request.streaming_behavior == "followUp",
    "busy Pi submit should remember queued pending request behavior"
  )
  coact.setup()
end)()
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
coact.setup()
local object_tier_thread = state.ensure_thread("smoke-object-service-tier", {
  config = { service_tier = { id = "fast", name = "Fast" } },
  status = "active",
})
assert(
  vim.deep_equal(metadata.composer_labels(object_tier_thread), { "fast", "active" }),
  "composer metadata should detect fast service tiers returned as objects"
)
require("coact.core").handle_notification({
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
require("coact.core").handle_notification({
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
local catalog = require("coact.catalog")
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
assert(
  not require("coact.context").display_path(text_asset):match("^/"),
  "displayed context paths should prefer workspace-relative paths"
)
local official_file_parsed = parser.parse("@" .. require("coact.context").display_path(text_asset))
assert(
  official_file_parsed[1]
    and official_file_parsed[1].type == "text"
    and official_file_parsed[1].text:match("^@")
    and not official_file_parsed[1].text:match("text asset with spaces"),
  "direct @path mentions should stay compact instead of expanding file contents"
)
local image_asset_parsed = parser.parse("@image:`" .. image_asset .. "`")
assert(image_asset_parsed[1] and image_asset_parsed[1].type == "localImage", "@image should attach local images")
assert(image_asset_parsed[1].path == vim.fs.normalize(image_asset), "@image should normalize local image paths")
local remote_image_parsed = parser.parse("@image:https://example.com/smoke.png")
assert(remote_image_parsed[1] and remote_image_parsed[1].type == "image", "@image should attach image URLs")

parsed = { behavior = require("coact.behavior"), original_cwd = vim.fn.getcwd(), dir = vim.fn.tempname() }
vim.fn.mkdir(parsed.dir, "p")
vim.cmd("cd " .. vim.fn.fnameescape(parsed.dir))
parsed.file = vim.fs.joinpath(parsed.dir, "behavior-smoke.txt")
vim.fn.writefile({ "before" }, parsed.file)
vim.cmd("edit " .. vim.fn.fnameescape(parsed.file))
parsed.buf = vim.api.nvim_get_current_buf()
parsed.thread = state.ensure_thread("smoke-behavior")
parsed.behavior.anchor(parsed.thread)
vim.api.nvim_buf_set_lines(parsed.buf, 0, -1, false, { "before", "after" })
parsed.context = parser.parse("@behavior", { thread = parsed.thread })
parsed.text = parsed.context[1] and parsed.context[1].text or ""
assert(
  parsed.text:match("Neovim editor behavior since previous agent turn"),
  "@behavior should expand editor diff context"
)
assert(parsed.text:match("files changed: 1"), "@behavior should report changed buffers")
assert(parsed.text:match("includes unsaved buffers: true"), "@behavior should include unsaved buffer state")
assert(parsed.text:match("%+after"), "@behavior should include unsaved editor diff lines")
assert(parsed.text:match("behavior%-smoke%.txt"), "@behavior should include changed file labels")
parsed.behavior.reset(parsed.thread)
assert(
  parsed.behavior.status_text(parsed.thread):match("changed buffers: 0"),
  "behavior reset should refresh the diff anchor"
)
vim.bo[parsed.buf].modified = false
vim.cmd("enew")
parsed.new_buf = vim.api.nvim_get_current_buf()
parsed.new_file = vim.fs.joinpath(parsed.dir, "behavior-new.txt")
parsed.behavior.reset(parsed.thread)
vim.api.nvim_buf_set_lines(parsed.new_buf, 0, -1, false, { "created after anchor" })
vim.api.nvim_buf_set_name(parsed.new_buf, parsed.new_file)
parsed.context = parser.parse("@behavior", { thread = parsed.thread })
parsed.text = parsed.context[1] and parsed.context[1].text or ""
assert(parsed.text:match("behavior%-new%.txt"), "@behavior should track unnamed buffers after they receive a path")
assert(parsed.text:match("%+created after anchor"), "@behavior should diff unnamed buffer edits after naming")
vim.bo[parsed.new_buf].modified = false
vim.cmd("bwipeout! " .. parsed.new_buf)
vim.cmd("bwipeout! " .. parsed.buf)
vim.cmd("cd " .. vim.fn.fnameescape(parsed.original_cwd))

local buffers = require("coact.buffers")
local buffer_opened_events = {}
local attached_buffers = {}
local buffer_attached_events = {}
coact.on("buffer_attached", function(payload)
  table.insert(buffer_attached_events, payload)
end)
coact.setup({
  buffer = {
    on_attach = function(bufnr, payload)
      attached_buffers[bufnr] = payload.thread_id
    end,
  },
})
vim.api.nvim_create_autocmd("User", {
  pattern = "CoactBufferOpened",
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
vim.tbl_map(function(index)
  state.upsert_item("smoke-context", "smoke-open-turn", {
    id = "smoke-open-user-" .. index,
    type = "userMessage",
    content = {
      {
        type = "text",
        text = ("opening preview history line %02d"):format(index),
      },
    },
  })
end, vim.fn.range(1, 24))
local context_thread_buf = buffers.open("smoke-context")
local context_thread = state.get_thread("smoke-context")
function _G.__coact_smoke_composer_text_area_height(winid)
  local info = vim.fn.getwininfo(winid)[1]
  return info and info.height or vim.api.nvim_win_get_height(winid)
end

function _G.__coact_smoke_count_thread_history_buffers(thread_id)
  local total = 0
  local name = "coact://thread/" .. tostring(thread_id)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      total = total + 1
    end
  end
  return total
end

assert(context_thread.prompt_bufnr, "opening a Coact thread should create a composer buffer")
assert(
  vim.api.nvim_get_current_buf() == context_thread_buf,
  "opening a Coact thread should focus its history buffer in preview state"
)
assert(context_thread.ui_state == "preview", "opening a Coact thread should start in preview state")
assert(context_thread.prompt_winid == nil, "preview state should not show the composer window")
assert(
  vim.api.nvim_buf_get_name(context_thread.prompt_bufnr) == "",
  "composer buffer should remain unnamed so path completions see a normal editing buffer"
)
assert(vim.bo[context_thread_buf].filetype == "coact-history", "history buffer should use coact-history filetype")
assert(vim.bo[context_thread.prompt_bufnr].filetype == "coact-input", "composer should use coact-input filetype")
assert(not vim.bo[context_thread_buf].modifiable, "Coact history buffer should be read-only")
vim.api.nvim_set_current_win(context_thread.winid)
vim.api.nvim_win_set_cursor(context_thread.winid, { 1, 0 })
_G.__coact_smoke_next_message_callback = vim.fn.maparg("g]", "n", false, true).callback
assert(type(_G.__coact_smoke_next_message_callback) == "function", "history should expose next message callback")
_G.__coact_smoke_next_message_callback()
_G.__coact_smoke_next_message_line = vim.api.nvim_win_get_cursor(context_thread.winid)[1]
assert(_G.__coact_smoke_next_message_line > 1, "g] should jump to the next rendered message block")
vim.api.nvim_win_set_cursor(context_thread.winid, { vim.api.nvim_buf_line_count(context_thread_buf), 0 })
_G.__coact_smoke_prev_message_callback = vim.fn.maparg("g[", "n", false, true).callback
assert(type(_G.__coact_smoke_prev_message_callback) == "function", "history should expose previous message callback")
_G.__coact_smoke_prev_message_callback()
assert(
  vim.api.nvim_win_get_cursor(context_thread.winid)[1] < vim.api.nvim_buf_line_count(context_thread_buf),
  "g[ should jump to the previous rendered message block"
)
context_thread.bufnr = nil
_G.__coact_smoke_rebound_context_buf = buffers.ensure("smoke-context")
assert(
  _G.__coact_smoke_rebound_context_buf == context_thread_buf,
  "thread ensure should rebind an existing named history buffer"
)
assert(
  _G.__coact_smoke_count_thread_history_buffers("smoke-context") == 1,
  "thread ensure should not duplicate existing history buffers"
)
_G.__coact_smoke_rpc_for_resume = require("coact.rpc")
_G.__coact_smoke_original_rpc_start_for_resume = _G.__coact_smoke_rpc_for_resume.start
_G.__coact_smoke_resume_started_rpc = false
_G.__coact_smoke_rpc_for_resume.start = function()
  _G.__coact_smoke_resume_started_rpc = true
  error("resume should reuse the existing Neovim thread buffer")
end
coact.resume("smoke-context")
_G.__coact_smoke_rpc_for_resume.start = _G.__coact_smoke_original_rpc_start_for_resume
assert(
  not _G.__coact_smoke_resume_started_rpc,
  "resume should not call app-server when the thread buffer is already open"
)
assert(
  state.get_thread("smoke-context").bufnr == context_thread_buf,
  "resume should keep using the existing thread buffer"
)
_G.__coact_smoke_view = {
  lines = vim.api.nvim_buf_line_count(context_thread_buf),
  info = vim.fn.getwininfo(context_thread.winid)[1],
}
assert(
  _G.__coact_smoke_view.info and _G.__coact_smoke_view.info.botline == _G.__coact_smoke_view.lines,
  "opening preview should show the latest transcript lines"
)
_G.__coact_smoke_idle_refresh_cursor = vim.api.nvim_win_get_cursor(context_thread.winid)
state.upsert_item("smoke-context", "smoke-open-turn", {
  id = "smoke-open-latest",
  type = "agentMessage",
  text = "latest idle refresh line",
})
buffers.render("smoke-context")
_G.__coact_smoke_view = {
  lines = vim.api.nvim_buf_line_count(context_thread_buf),
  info = vim.fn.getwininfo(context_thread.winid)[1],
}
assert(
  vim.deep_equal(vim.api.nvim_win_get_cursor(context_thread.winid), _G.__coact_smoke_idle_refresh_cursor),
  "idle preview refresh should preserve the transcript cursor"
)
_G.__coact_smoke_scrolloff = vim.o.scrolloff
vim.o.scrolloff = 5
vim.api.nvim_set_current_win(context_thread.winid)
vim.api.nvim_feedkeys("i", "x", false)
vim.wait(1000, function()
  return context_thread.ui_state == "compose"
    and context_thread.prompt_winid
    and vim.api.nvim_get_current_buf() == context_thread.prompt_bufnr
end, 20)
vim.cmd("stopinsert")
assert(context_thread.ui_state == "compose", "entering compose should update the UI state")
assert(vim.api.nvim_get_current_buf() == context_thread.prompt_bufnr, "compose state should focus the composer")
assert(
  vim.wo[context_thread.prompt_winid].winbar:match("Coact input"),
  "composer window should render input metadata in its winbar"
)
assert(
  vim.wo[context_thread.prompt_winid].scrolloff == 0,
  "composer should clear inherited scrolloff for virtual status lines"
)
vim.o.scrolloff = _G.__coact_smoke_scrolloff
local initial_composer_height = _G.__coact_smoke_composer_text_area_height(context_thread.prompt_winid)
vim.api.nvim_buf_set_lines(context_thread.prompt_bufnr, 0, -1, false, {
  "semantic first line",
  "composer content line 2",
  "composer content line 3",
  "composer content line 4",
  "composer content line 5",
})
vim.api.nvim_win_set_cursor(context_thread.prompt_winid, { 5, 0 })
buffers.refresh_composer(context_thread)
_G.__coact_smoke_composer_view = vim.fn.getwininfo(context_thread.prompt_winid)[1]
assert(
  _G.__coact_smoke_composer_view and _G.__coact_smoke_composer_view.height >= 5,
  "composer text area should include all prompt rows below the configured cap"
)
assert(
  _G.__coact_smoke_composer_view.topline == 1,
  "composer growth should keep the first prompt line visible below the cap"
)
vim.api.nvim_buf_set_lines(context_thread.prompt_bufnr, 0, -1, false, { string.rep("wrapped input ", 40) })
buffers.refresh_composer(context_thread)
local grown_composer_height = _G.__coact_smoke_composer_text_area_height(context_thread.prompt_winid)
assert(grown_composer_height > initial_composer_height, "composer should grow for wrapped input")
assert(
  grown_composer_height <= math.max(2, math.floor(vim.o.lines * 0.33)),
  "composer growth should respect the configured cap"
)
buffers.enter_preview(context_thread, { source = "smoke", focus = true })
assert(context_thread.ui_state == "preview", "leaving compose should restore preview state")
assert(context_thread.prompt_winid == nil, "preview state should close the composer window")
assert(vim.api.nvim_get_current_buf() == context_thread_buf, "preview state should focus history")
assert(buffers.collect_prompt(context_thread_buf):match("wrapped input"), "preview should preserve the draft prompt")
buffers.enter_compose("smoke-context", { source = "smoke", startinsert = false })
assert(
  buffers.collect_prompt(context_thread.prompt_bufnr):match("wrapped input"),
  "compose should restore saved draft text"
)
_G.__coact_smoke_refresh_composer = buffers.refresh_composer
_G.__coact_smoke_refresh_count = 0
buffers.refresh_composer = function(...)
  _G.__coact_smoke_refresh_count = _G.__coact_smoke_refresh_count + 1
  return _G.__coact_smoke_refresh_composer(...)
end
vim.api.nvim_buf_set_lines(context_thread.prompt_bufnr, 0, -1, false, { "" })
for index = 1, 30 do
  vim.api.nvim_buf_set_text(context_thread.prompt_bufnr, 0, index - 1, 0, index - 1, { "x" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = context_thread.prompt_bufnr })
end
vim.wait(1000, function()
  return context_thread.draft_lines and #(context_thread.draft_lines[1] or "") >= 30
end, 20)
buffers.refresh_composer = _G.__coact_smoke_refresh_composer
assert(_G.__coact_smoke_refresh_count <= 2, "composer input refresh should coalesce TextChangedI bursts")
buffers.clear_prompt(context_thread_buf)
buffers.enter_preview(context_thread, { source = "smoke", focus = true })
assert(attached_buffers[context_thread_buf] == "smoke-context", "buffer.on_attach should run for Coact buffers")
assert(
  buffer_attached_events[1] and buffer_attached_events[1].bufnr == context_thread_buf,
  "opening a Coact thread should emit buffer_attached hooks"
)
attached_buffers[context_thread_buf] = nil
assert(coact.attach_buffer(context_thread_buf), "attach_buffer should attach a Coact buffer")
assert(attached_buffers[context_thread_buf] == "smoke-context", "attach_buffer should rerun buffer.on_attach")
assert(coact.attach_all_buffers() >= 1, "attach_all_buffers should find existing Coact buffers")
assert(
  vim.tbl_contains(
    coact.complete_command(tostring(context_thread_buf), "Coact attach " .. context_thread_buf),
    tostring(context_thread_buf)
  ),
  "attach completion should include Coact buffer numbers"
)
assert(
  vim.tbl_contains(coact.complete_command("smoke", "Coact resume smoke"), "smoke-context"),
  "resume completion should include loaded thread ids"
)
assert(
  buffer_opened_events[1] and buffer_opened_events[1].bufnr == context_thread_buf,
  "opening a Coact thread should emit CoactBufferOpened"
)
assert(
  buffer_opened_events[1] and buffer_opened_events[1].thread_id == "smoke-context",
  "CoactBufferOpened should include the thread id"
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
do
  (function()
    local visual_context = require("coact.context")
    local visual_selection_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(visual_selection_buf, "/tmp/coact-visual-selection-smoke.txt")
    vim.api.nvim_buf_set_lines(visual_selection_buf, 0, -1, false, { "abcdef", "uvwxyz" })
    vim.bo[visual_selection_buf].filetype = "text"
    vim.api.nvim_set_current_buf(visual_selection_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    vim.cmd("normal! v2l\027")
    vim.wait(1000, function()
      local latest = visual_context._latest_selection()
      return latest and latest.bufnr == visual_selection_buf and latest.content == "bcd"
    end, 20)
    local charwise_selection = visual_context.selection_for_buffer(visual_selection_buf)
    assert(
      charwise_selection and charwise_selection.mode == "v" and charwise_selection.content == "bcd",
      "selection tracker should capture precise charwise visual text"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! Vj\027")
    vim.wait(1000, function()
      local latest = visual_context._latest_selection()
      return latest and latest.bufnr == visual_selection_buf and latest.mode == "V"
    end, 20)
    local linewise_selection = visual_context.selection_for_buffer(visual_selection_buf)
    assert(
      linewise_selection and linewise_selection.content == "abcdef\nuvwxyz",
      "selection tracker should capture linewise visual text"
    )
    local blockwise_mode = vim.api.nvim_replace_termcodes("<C-v>", true, false, true)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! 0" .. blockwise_mode .. "j2l\027")
    vim.wait(1000, function()
      local latest = visual_context._latest_selection()
      return latest and latest.bufnr == visual_selection_buf and latest.mode == blockwise_mode
    end, 20)
    local blockwise_selection = visual_context.selection_for_buffer(visual_selection_buf)
    assert(
      blockwise_selection and blockwise_selection.content == "abc\nuvw",
      "selection tracker should capture blockwise visual text"
    )
    local coact_input_selection_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(coact_input_selection_buf, 0, -1, false, { "prompt selection should be ignored" })
    vim.bo[coact_input_selection_buf].filetype = "coact-input"
    vim.api.nvim_set_current_buf(coact_input_selection_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v5l\027")
    vim.wait(50)
    local latest_selection_after_coact_input = visual_context._latest_selection()
    assert(
      latest_selection_after_coact_input and latest_selection_after_coact_input.bufnr == visual_selection_buf,
      "selection tracker should ignore Coact input visual selections"
    )
    assert(
      visual_context.selection_for_buffer(coact_input_selection_buf) == nil,
      "Coact input selections should not become context"
    )
  end)()
end

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
      assert(opts.title == "Coact File Context", "file context hook should use snacks file picker title")
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
assert(require("coact.context").trigger_hook(), "@file: should trigger context hook")
vim.wait(1000, function()
  return vim.api.nvim_buf_get_lines(hook_buf, 0, 1, false)[1] == "@README.md"
end, 20)
vim.ui.select = original_ui_select_for_context
package.loaded["snacks"] = original_snacks_for_context
package.loaded["snacks.picker.util"] = nil
assert(snacks_file_picker_called, "@file: hook should reuse snacks file picker when available")
assert(
  vim.api.nvim_buf_get_lines(hook_buf, 0, 1, false)[1] == "@README.md",
  "@file: hook should replace provider syntax with compact @path mention syntax"
)
vim.api.nvim_set_current_buf(source_buf)
coact.add_current_buffer()
local added_context_prompt = buffers.collect_prompt(context_thread_buf)
assert(
  added_context_prompt:match("@.*codex%-context%-smoke%.lua"),
  "Coact add-buffer should append the current source buffer path to the chat prompt"
)
buffers.clear_prompt(context_thread_buf)

local patch_review = require("coact.patch_review")
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
  vim.b[review_buf].coact_patch_review_anchors[1].path == "codex-context-smoke.lua",
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
local original_rpc_respond_for_failed_review = require("coact.rpc").respond
local failed_review_response = nil
require("coact.rpc").respond = function(id, result)
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
require("coact.rpc").respond = original_rpc_respond_for_failed_review
assert(failed_review_buf == nil, "failed patch review should not return a buffer")
assert(
  failed_review_response
    and failed_review_response.id == "smoke-failed-approval"
    and failed_review_response.result.decision == "cancel",
  "failed patch review should cancel the app-server approval"
)
assert(not state.pop_pending_request("smoke-failed-approval"), "failed patch review should not leave a pending request")
local dynamic_tools = require("coact.dynamic_tools")
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
require("coact.patch_session").open({
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
require("coact.patch_session").open({
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
local patch_session = require("coact.patch_session")
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
local diff_ns = vim.api.nvim_get_namespaces()["coact.patch_session.diff"]
local session_hunk = session.hunks[1]
local session_block = session.blocks[1]
assert(
  #session_hunk.changed_blocks == 1
    and #session_hunk.changed_blocks[1].old_lines == 1
    and #session_hunk.changed_blocks[1].new_lines == 1,
  "patch session should distinguish changed lines from hunk context"
)
do
  local configured_review_keys = patch_session._configured_keymaps()
  assert(
    configured_review_keys.accept == "."
      and configured_review_keys.reject == ","
      and configured_review_keys.next == "n"
      and configured_review_keys.prev == "p"
      and configured_review_keys.accept_all == "ga"
      and configured_review_keys.reject_all == "gr"
      and configured_review_keys.cancel == "q"
      and configured_review_keys.help == "?",
    "patch session should default to short review keys"
  )
  local review_keymaps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(session_hunk.bufnr, "n")) do
    review_keymaps[map.lhs] = true
  end
  assert(
    review_keymaps["."]
      and review_keymaps[","]
      and review_keymaps.n
      and review_keymaps.p
      and review_keymaps.ga
      and review_keymaps.gr
      and review_keymaps.q
      and review_keymaps["?"],
    "patch session should register short buffer-local review keys"
  )
  assert(
    not review_keymaps["<leader>ca"] and not review_keymaps["\\ca"] and not review_keymaps["<leader>cr"],
    "patch session should not register legacy leader+c review keys"
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
  local session_marks = vim.api.nvim_buf_get_extmarks(session_hunk.bufnr, diff_ns, 0, -1, { details = true })
  local has_after_char_mark = false
  for _, mark in ipairs(session_marks) do
    if
      mark[4]
      and mark[4].hl_group == "CoactPatchReviewAfterChar"
      and mark[4].end_col
      and mark[4].end_col > mark[3]
    then
      has_after_char_mark = true
    end
  end
  assert(has_after_char_mark, "patch session should add character-level highlights to replacement text")
  local session_old_mark =
    vim.api.nvim_buf_get_extmark_by_id(session_hunk.bufnr, diff_ns, session_hunk.old_extmark_ids[1], { details = true })
  local session_old_virtual = vim.inspect(session_old_mark[3].virt_lines)
  assert(
    session_old_virtual:match("CoactPatchReviewBefore")
      and not session_old_virtual:match("alpha")
      and not session_old_virtual:match("gamma")
      and session_old_virtual:match("CoactPatchReviewBeforeChar"),
    "patch session should show only deleted lines as old virtual diff content with character highlights"
  )
  local hint_ns = vim.api.nvim_get_namespaces()["coact.patch_session.hint"]
  local hint_mark = vim.api.nvim_buf_get_extmarks(session_hunk.bufnr, hint_ns, 0, -1, { details = true })[1]
  local hint_text = hint_mark and vim.inspect(hint_mark[4].virt_lines) or ""
  assert(
    hint_text:match('"%."')
      and hint_text:match('","')
      and hint_text:match('"n"')
      and hint_text:match('"p"')
      and hint_text:match("approve")
      and hint_text:match("reject")
      and hint_text:match("next")
      and hint_text:match("prev")
      and not hint_text:match("<leader>"),
    "patch session should show visible short-key hints"
  )
end
patch_session._reject_block(session, session_block, "keep beta")
vim.wait(1000, function()
  return session_done
end, 20)
assert(vim.fn.readfile(session_file)[2] == "beta", "rejected patch block should restore original file content")
do
  local approve_comment_file = vim.fs.joinpath(session_dir, "approve-comment.txt")
  vim.fn.writefile({ "old" }, approve_comment_file)
  local approve_comment_patch = table.concat({
    "diff --git a/approve-comment.txt b/approve-comment.txt",
    "--- a/approve-comment.txt",
    "+++ b/approve-comment.txt",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n")
  local approve_comment_summary = nil
  local approve_comment_session = patch_session.open({
    cwd = session_dir,
    changes = dynamic_tools._changes_from_unified_patch(approve_comment_patch),
    on_complete = function(summary, success)
      assert(success, summary)
      approve_comment_summary = summary
    end,
  })
  assert(approve_comment_session and approve_comment_session.blocks[1], "approval comment smoke should open review")
  local approve_comment_prompted = false
  local original_input = vim.ui.input
  vim.ui.input = function(opts, callback)
    approve_comment_prompted = true
    assert(opts.prompt and opts.prompt:match("Approval comment"), "accept key should prompt for an approval comment")
    callback("looks good to me")
  end
  local accept_mapping = vim.fn.maparg(".", "n", false, true)
  assert(type(accept_mapping.callback) == "function", "accept key should be a Lua callback")
  local accept_ok, accept_err = pcall(accept_mapping.callback)
  vim.ui.input = original_input
  assert(accept_ok, accept_err)
  vim.wait(1000, function()
    return approve_comment_summary ~= nil
  end, 20)
  assert(approve_comment_prompted, "accept key should prompt before approving a patch block")
  assert(
    approve_comment_summary
      and approve_comment_summary:match("USER APPROVAL COMMENTS")
      and approve_comment_summary:match("looks good to me"),
    "approved patch summary should include the user's approval comment"
  )
  assert(vim.fn.readfile(approve_comment_file)[1] == "new", "commented approval should still write accepted edit")
end
do
  local cancelled_input_file = vim.fs.joinpath(session_dir, "cancelled-review-input.txt")
  vim.fn.writefile({ "old" }, cancelled_input_file)
  local cancelled_input_patch = table.concat({
    "diff --git a/cancelled-review-input.txt b/cancelled-review-input.txt",
    "--- a/cancelled-review-input.txt",
    "+++ b/cancelled-review-input.txt",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n")
  local cancelled_input_session = patch_session.open({
    cwd = session_dir,
    changes = dynamic_tools._changes_from_unified_patch(cancelled_input_patch),
  })
  local cancelled_input_block = cancelled_input_session.blocks[1]
  local cancelled_prompts = {}
  local original_input = vim.ui.input
  vim.ui.input = function(opts, callback)
    table.insert(cancelled_prompts, opts.prompt)
    callback(nil)
  end
  for _, lhs in ipairs({ ".", ",", "ga", "gr", "q" }) do
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    assert(type(mapping.callback) == "function", lhs .. " review key should be a Lua callback")
    local callback_ok, callback_err = pcall(mapping.callback)
    assert(callback_ok, callback_err)
    assert(
      not cancelled_input_session.completed and cancelled_input_block.status == nil,
      "cancelling a review input should leave the current patch block pending"
    )
  end
  vim.ui.input = original_input
  assert(#cancelled_prompts == 5, "review actions that need text should all prompt for input")
  patch_session._accept_block(cancelled_input_session, cancelled_input_block)
  assert(
    vim.fn.readfile(cancelled_input_file)[1] == "new",
    "cancelled review inputs should leave the patch review usable"
  )
end
do
  local previous_active_thread_id = require("coact.state").active_thread_id
  vim.cmd("tabnew")
  local codex_review_win = vim.api.nvim_get_current_win()
  local codex_review_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(codex_review_buf, "coact://thread/smoke-patch-window")
  vim.bo[codex_review_buf].buftype = "nofile"
  vim.bo[codex_review_buf].filetype = "codex"
  vim.b[codex_review_buf].coact_thread_id = "smoke-patch-window"
  vim.api.nvim_win_set_buf(codex_review_win, codex_review_buf)
  local smoke_window_state = require("coact.state")
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
    "patch session should not replace the Coact chat window with the review file buffer"
  )
  assert(
    vim.api.nvim_get_current_win() ~= codex_review_win and patch_session._active_session(0) == preserve_chat_session,
    "patch session should open a separate review window when launched from a Coact chat buffer"
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
    and delete_only_mark[3].virt_text[1][1]:match("%[%-%sdeleted 1 line%]")
    and delete_only_virtual:match("remove this")
    and not delete_only_virtual:match("left context")
    and not delete_only_virtual:match("right context"),
  "patch session should render deletion-only blocks without context lines"
)
patch_session._accept_block(delete_only_session, delete_only_session.blocks[1])
do
  local long_diff_file = vim.fs.joinpath(session_dir, "long-diff.txt")
  local long_before_line = string.rep("before-", 28) .. "old-tail"
  local long_after_line = string.rep("before-", 28) .. "new-tail"
  vim.fn.writefile({ "top", long_before_line, "bottom" }, long_diff_file)
  local long_diff_patch = table.concat({
    "diff --git a/long-diff.txt b/long-diff.txt",
    "--- a/long-diff.txt",
    "+++ b/long-diff.txt",
    "@@ -1,3 +1,3 @@",
    " top",
    "-" .. long_before_line,
    "+" .. long_after_line,
    " bottom",
  }, "\n")
  local long_diff_session = patch_session.open({
    cwd = session_dir,
    changes = dynamic_tools._changes_from_unified_patch(long_diff_patch),
  })
  local long_diff_hunk = long_diff_session.hunks[1]
  local long_diff_old_mark = vim.api.nvim_buf_get_extmark_by_id(
    long_diff_hunk.bufnr,
    diff_ns,
    long_diff_hunk.old_extmark_ids[1],
    { details = true }
  )
  assert(
    #(long_diff_old_mark[3].virt_lines or {}) >= 3,
    "patch session should split long before lines into visible virtual lines"
  )
  patch_session._accept_block(long_diff_session, long_diff_session.blocks[1])
end
do
  local budget_file = vim.fs.joinpath(session_dir, "char-budget.txt")
  local budget_original = {}
  local budget_patch = {
    "diff --git a/char-budget.txt b/char-budget.txt",
    "--- a/char-budget.txt",
    "+++ b/char-budget.txt",
    "@@ -1,130 +1,130 @@",
  }
  for index = 1, 130 do
    local old = ("budget-%03d-old"):format(index)
    local new = ("budget-%03d-new"):format(index)
    table.insert(budget_original, old)
    table.insert(budget_patch, "-" .. old)
    table.insert(budget_patch, "+" .. new)
  end
  vim.fn.writefile(budget_original, budget_file)
  local budget_session = patch_session.open({
    cwd = session_dir,
    changes = dynamic_tools._changes_from_unified_patch(table.concat(budget_patch, "\n")),
  })
  local budget_marks = vim.api.nvim_buf_get_extmarks(budget_session.hunks[1].bufnr, diff_ns, 0, -1, { details = true })
  local has_budget_char_mark = false
  for _, mark in ipairs(budget_marks) do
    if mark[4] and mark[4].hl_group == "CoactPatchReviewAfterChar" then
      has_budget_char_mark = true
      break
    end
  end
  assert(not has_budget_char_mark, "patch session should skip character extmarks over the review budget")
  patch_session._accept_block(budget_session, budget_session.blocks[1])
end
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
end)();
(function()
  local pi_bridge = require("coact.providers.pi_edit_bridge")
  coact.setup({ provider = "pi" })
  local default_direct_file = vim.fs.joinpath(session_dir, "pi-default-direct-write.txt")
  local default_direct_result = nil
  local current_before_default_direct = vim.api.nvim_get_current_buf()
  pi_bridge.review_payload_async({
    toolName = "write",
    toolCallId = "pi-default-direct-write-smoke",
    cwd = session_dir,
    path = default_direct_file,
    oldContent = "",
    newContent = "default temporary write\n",
    kind = "add",
  }, function(result)
    default_direct_result = result
  end)
  vim.wait(1000, function()
    return default_direct_result ~= nil
  end, 20)
  assert(
    default_direct_result
      and default_direct_result.success
      and default_direct_result.acceptedBlocks == 1
      and vim.api.nvim_get_current_buf() == current_before_default_direct,
    "Pi edit bridge should directly apply default system-temp writes without opening an interactive window"
  )

  coact.setup({ provider = "pi", providers = { pi = { edit_bridge = { direct_write = false } } } })
  local disabled_direct_file = vim.fs.joinpath(session_dir, "pi-disabled-direct-write.txt")
  vim.fn.writefile({ "before" }, disabled_direct_file)
  local disabled_direct_result = nil
  pi_bridge.review_payload_async({
    toolName = "edit",
    toolCallId = "pi-disabled-direct-write-smoke",
    cwd = session_dir,
    path = disabled_direct_file,
    oldContent = "before\n",
    newContent = "after\n",
    kind = "update",
  }, function(result)
    disabled_direct_result = result
  end)
  local disabled_direct_session = nil
  vim.wait(1000, function()
    disabled_direct_session = patch_session._active_session(0)
    return disabled_direct_session and disabled_direct_session.blocks[1]
  end, 20)
  assert(
    disabled_direct_session and disabled_direct_session.blocks[1],
    "Pi edit bridge should allow disabling the default temp-directory direct-write policy"
  )
  patch_session._accept_block(disabled_direct_session, disabled_direct_session.blocks[1])
  vim.wait(1000, function()
    return disabled_direct_result ~= nil
  end, 20)
  assert(disabled_direct_result and disabled_direct_result.success, "disabled direct-write review should complete")

  local direct_dir = vim.fs.joinpath(session_dir, "pi-direct-write")
  vim.fn.mkdir(direct_dir, "p")
  local escape_link = nil
  local dangling_escape_link = nil
  if vim.fn.has("win32") == 0 then
    escape_link = vim.fs.joinpath(direct_dir, "escape")
    local linked = vim.uv.fs_symlink(session_dir, escape_link)
    assert(linked, "Pi direct-write smoke should create a symlink escape probe")
    dangling_escape_link = vim.fs.joinpath(direct_dir, "dangling-escape")
    linked = vim.uv.fs_symlink(vim.fs.joinpath(session_dir, "missing-outside.txt"), dangling_escape_link)
    assert(linked, "Pi direct-write smoke should create a dangling symlink escape probe")
  end
  local callback_saw_defaults = false
  local callback_matching_is_safe = false
  coact.setup({
    provider = "pi",
    providers = {
      pi = {
        edit_bridge = {
          direct_write = function(allowlist, context)
            callback_saw_defaults = #allowlist:paths() > 0
              and (not context.os_tmpdir or allowlist:contains(context.os_tmpdir))
            allowlist:clear()
            allowlist:add(direct_dir)
            callback_matching_is_safe = allowlist:contains(vim.fs.joinpath(direct_dir, "nested", "file.txt"))
              and not allowlist:contains(direct_dir .. "-sibling/file.txt")
              and (not escape_link or not allowlist:contains(vim.fs.joinpath(escape_link, "outside.txt")))
              and (not dangling_escape_link or not allowlist:contains(dangling_escape_link))
          end,
        },
      },
    },
  })
  assert(callback_saw_defaults, "Pi direct-write configuration should run after the OS temp defaults")
  assert(
    callback_matching_is_safe,
    "Pi direct-write matching should reject prefix siblings and paths that escape through symlinks"
  )
  if escape_link then
    vim.uv.fs_unlink(escape_link)
    vim.uv.fs_unlink(dangling_escape_link)
  end

  local direct_file = vim.fs.joinpath(direct_dir, "write.txt")
  local direct_result = nil
  local current_before_direct_write = vim.api.nvim_get_current_buf()
  pi_bridge.review_payload_async({
    toolName = "write",
    toolCallId = "pi-write-direct-smoke",
    cwd = session_dir,
    path = direct_file,
    oldContent = "",
    newContent = "written without an interactive window\n",
    kind = "add",
  }, function(result)
    direct_result = result
  end)
  vim.wait(1000, function()
    return direct_result ~= nil
  end, 20)
  assert(
    direct_result
      and direct_result.success
      and direct_result.acceptedBlocks == 1
      and not direct_result.summary:match("USER APPROVAL COMMENTS")
      and direct_result.directWrite == nil
      and direct_result.bypassed == nil,
    "allowlisted Pi writes should look like uncommented full human approval in tool feedback"
  )
  assert(
    vim.api.nvim_get_current_buf() == current_before_direct_write
      and vim.fn.readfile(direct_file)[1] == "written without an interactive window",
    "allowlisted Pi writes should apply in the background without changing the active buffer"
  )

  local bridge_file = vim.fs.joinpath(session_dir, "pi-bridge.txt")
  vim.fn.writefile({ "red", "green", "blue" }, bridge_file)
  local bridge_result = nil
  pi_bridge.review_payload_async({
    toolName = "edit",
    toolCallId = "pi-edit-bridge-smoke",
    cwd = session_dir,
    path = "pi-bridge.txt",
    oldContent = "red\ngreen\nblue\n",
    newContent = "red\nemerald\nblue\n",
    kind = "update",
  }, function(result)
    bridge_result = result
  end)
  local bridge_session = nil
  vim.wait(1000, function()
    bridge_session = patch_session._active_session(0)
    return bridge_session and bridge_session.blocks[1]
  end, 20)
  assert(bridge_session and bridge_session.blocks[1], "Pi edit bridge should open an in-buffer patch session")
  patch_session._accept_block(bridge_session, bridge_session.blocks[1])
  vim.wait(1000, function()
    return bridge_result ~= nil
  end, 20)
  assert(bridge_result and bridge_result.success, "accepted Pi edit bridge review should report success")
  assert(
    table.concat(vim.fn.readfile(bridge_file), "\n") == "red\nemerald\nblue",
    "accepted Pi edit bridge review should write the accepted file state"
  )
  assert(
    bridge_result.patch and bridge_result.patch:match("pi%-bridge%.txt") and bridge_result.firstChangedLine == 2,
    "Pi edit bridge result should include patch details for Pi"
  )
end)()
coact.setup({ dynamic_tools = { prefer_nvim_apply_patch = true } })
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
local rpc = require("coact.rpc")
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
coact.setup()

local done = false
local source = require("coact.completion.blink").new()
source:get_completions({
  line = "@dia",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "@diagnostics", "completion should return @diagnostics")
  source:resolve(result.items[1], function(item)
    assert(
      item.documentation
        and item.documentation:match("Target buffer diagnostics")
        and not item.documentation:match("Context preview for @diagnostics")
        and not item.documentation:match("This is what coact%.nvim will inject"),
      "@diagnostics completion documentation should fall back to the context prompt"
    )
    done = true
  end)
end)
assert(done, "completion callback should run synchronously for Neovim context items")

do
  (function()
    local cursor_completion_done = false
    source:get_completions({
      bufnr = context_thread_buf,
      line = "@cur",
      cursor = { 1, 4 },
    }, function(result)
      local cursor_item = nil
      for _, item in ipairs(result.items or {}) do
        if item.label == "@cursor" then
          cursor_item = item
          break
        end
      end
      assert(cursor_item, "completion should return @cursor")
      source:resolve(cursor_item, function(item)
        assert(
          item.documentation
            and item.documentation:match("^```lua")
            and item.documentation:match("> +%d+  .+codex_context_smoke")
            and item.documentation:match("```$")
            and not item.documentation:match("Neovim context: cursor")
            and not item.documentation:match("Reference context, not instructions"),
          "@cursor completion documentation should show only the cursor fenced block"
        )
        cursor_completion_done = true
      end)
    end)
    assert(cursor_completion_done, "cursor completion callback should run synchronously")
  end)()
end

local selection_completion_done = false
source:get_completions({
  bufnr = context_thread_buf,
  line = "@sel",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1 and result.items[1].label == "@selection", "completion should return @selection")
  source:resolve(result.items[1], function(item)
    assert(item.documentation == table.concat({
      "```lua",
      "local codex_context_smoke = true",
      "return codex_context_smoke",
      "```",
    }, "\n"), "@selection completion should preview only the selected text fenced with filetype")
    selection_completion_done = true
  end)
end)
assert(selection_completion_done, "selection completion callback should run synchronously")
do
  (function()
    local hover_prompt_buf = buffers.ensure_prompt("smoke-context")
    vim.api.nvim_set_current_buf(hover_prompt_buf)
    vim.api.nvim_buf_set_lines(hover_prompt_buf, 0, -1, false, { "@selection" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local hover_map = vim.fn.maparg("K", "n", false, true)
    assert(hover_map and hover_map.desc == "Hover Coact context token", "composer K should map to context hover")
    local context_docs = require("coact.context_docs")
    assert(context_docs.token_under_cursor(0) == "@selection", "context hover should detect token under cursor")
    assert(context_docs.hover({ bufnr = hover_prompt_buf }), "context hover should open for @selection")
    local hover_win = vim.b[hover_prompt_buf].lsp_floating_preview
    assert(hover_win and vim.api.nvim_win_is_valid(hover_win), "context hover should use LSP floating preview")
    assert(vim.w[hover_win]["textDocument/hover"] == hover_prompt_buf, "context hover should use LSP hover focus id")
    local hover_lines =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(hover_win), 0, -1, false), "\n")
    assert(
      hover_lines:match("```lua")
        and hover_lines:match("local codex_context_smoke")
        and not hover_lines:match("Reference context, not instructions")
        and not hover_lines:match("Neovim context: selection"),
      "context hover should show the same compact documentation as completion"
    )
    pcall(vim.api.nvim_win_close, hover_win, true)
  end)()
end
pcall(vim.api.nvim_buf_del_mark, source_buf, "<")
pcall(vim.api.nvim_buf_del_mark, source_buf, ">")

local path_done = false
local file_completion_line = "@file:`" .. asset_dir .. "/space"
source:get_completions({
  line = file_completion_line,
  cursor = { 1, #file_completion_line },
}, function(result)
  assert(#result.items == 0, "file path completion should be handled by the picker hook, not blink")
  path_done = true
end)
assert(path_done, "path completion suppression callback should run synchronously")

local image_path_done = false
local image_completion_line = "@image:`" .. asset_dir .. "/sample"
source:get_completions({
  line = image_completion_line,
  cursor = { 1, #image_completion_line },
}, function(result)
  assert(#result.items == 0, "image path completion should be handled by the picker hook, not blink")
  image_path_done = true
end)
assert(image_path_done, "image path completion suppression callback should run synchronously")

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

local slash = require("coact.slash")
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
local rpc = require("coact.rpc")
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
local util = require("coact.util")
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
coact.setup();
(function()
  local codex_slash_labels = vim.tbl_map(function(item)
    return item.label
  end, slash.items(""))
  assert(not vim.tbl_contains(codex_slash_labels, "/tree"), "Codex slash completion should hide Pi-only commands")
end)()

do
  local function smoke_pi_slash_provider()
    coact.setup({ provider = "pi" })
    local pi_slash_labels = vim.tbl_map(function(item)
      return item.label
    end, slash.items(""))
    assert(
      vim.tbl_contains(pi_slash_labels, "/model"),
      "Pi slash completion should include provider-supported model command"
    )
    assert(vim.tbl_contains(pi_slash_labels, "/reasoning"), "Pi slash completion should include thinking command")
    assert(vim.tbl_contains(pi_slash_labels, "/tree"), "Pi slash completion should include tree navigation")
    assert(not vim.tbl_contains(pi_slash_labels, "/permissions"), "Pi slash completion should hide Codex permissions")
    assert(not vim.tbl_contains(pi_slash_labels, "/fast"), "Pi slash completion should hide Codex service tiers")
    assert(not vim.tbl_contains(pi_slash_labels, "/goal"), "Pi slash completion should hide Codex goals")
    local pi_copy_item = vim.tbl_filter(function(item)
      return item.label == "/copy"
    end, slash.items(""))[1]
    assert(
      pi_copy_item and pi_copy_item.detail:match("Pi output"),
      "Pi slash detail should use the active provider title"
    )
    assert(not vim.tbl_contains(slash.command_names(), "permissions"), "Pi command names should be provider-filtered")

    local pi_unavailable_notice = nil
    util.notify = function(message)
      pi_unavailable_notice = message
    end
    slash.dispatch("/permissions", nil, {})
    util.notify = original_notify
    assert(
      pi_unavailable_notice and pi_unavailable_notice:match("unavailable for the Pi provider"),
      "Pi dispatch should reject hidden Codex-only slash commands"
    )

    local pi_reasoning_prompts = {}
    local pi_reasoning_choices = nil
    local pi_reasoning_requests = {}
    local pi_reasoning_update = nil
    vim.ui.select = function(items, opts, callback)
      table.insert(pi_reasoning_prompts, opts.prompt)
      pi_reasoning_choices = vim.tbl_map(function(item)
        return item.label
      end, items)
      for _, item in ipairs(items) do
        if item.label == "max" then
          callback(item)
          return
        end
      end
      callback(nil)
    end
    rpc.request = function(method, params, callback)
      table.insert(pi_reasoning_requests, method)
      if method == "get_available_thinking_levels" then
        callback(nil, { levels = { "off", "low", "medium", "high", "xhigh", "max" } })
        return
      end
      assert(method == "thread/settings/update", "Pi /reasoning should update thread settings")
      pi_reasoning_update = params
      callback(nil, {})
    end
    slash.dispatch("/reasoning", "pi-thread-reasoning", {
      ensure_server = function(callback)
        callback()
      end,
    })
    rpc.request = original_rpc_request
    vim.ui.select = original_ui_select
    assert(
      vim.deep_equal(pi_reasoning_prompts, { "Pi thinking level" }),
      "Pi /reasoning should prompt for thinking only"
    )
    assert(
      vim.deep_equal(pi_reasoning_requests, { "get_available_thinking_levels", "thread/settings/update" }),
      "Pi /reasoning should discover current-model thinking levels before updating settings"
    )
    assert(
      vim.deep_equal(pi_reasoning_choices, { "off", "low", "medium", "high", "xhigh", "max" }),
      "Pi /reasoning should use Pi's dynamic current-model thinking levels"
    )
    assert(pi_reasoning_update.threadId == "pi-thread-reasoning", "Pi /reasoning should target the active thread")
    assert(pi_reasoning_update.effort == "max", "Pi /reasoning should send the selected max thinking level")
    assert(pi_reasoning_update.summary == nil, "Pi /reasoning should not send Codex reasoning summary")

    local pi_tree_request = nil
    local pi_tree_notice = nil
    util.notify = function(message)
      pi_tree_notice = message
    end
    rpc.request = function(method, params, callback)
      assert(method == "thread/tree", "Pi /tree should request thread/tree")
      pi_tree_request = params
      callback(nil, {
        thread = {
          id = "pi-thread-tree",
          replaceTurns = true,
          turns = {
            {
              id = "tree-turn",
              items = {
                { id = "tree-item", type = "agentMessage", text = "tree" },
              },
            },
          },
        },
      })
    end
    slash.dispatch("/tree entry-target", "pi-thread-tree", {
      ensure_server = function(callback)
        callback()
      end,
    })
    rpc.request = original_rpc_request
    util.notify = original_notify
    assert(pi_tree_request.threadId == "pi-thread-tree", "Pi /tree should target the active thread")
    assert(pi_tree_request.initialSelectedId == "entry-target", "Pi /tree should pass an initial selected entry id")
    assert(pi_tree_notice == "Pi tree updated", "Pi /tree should notify after refreshing the thread")
    assert(state.get_thread("pi-thread-tree").items["tree-item"], "Pi /tree should update thread state from result")

    pi_tree_notice = nil
    rpc.request = function(method, params, callback)
      assert(method == "thread/tree", "Pi /tree local reveal should request thread/tree")
      callback(nil, {
        treeAction = {
          __coactNvimPiTreeAction = true,
          action = "reveal",
          id = "entry-target",
        },
      })
    end
    util.notify = function(message)
      pi_tree_notice = message
    end
    slash.dispatch("/tree entry-target", "pi-thread-tree", {
      ensure_server = function(callback)
        callback()
      end,
    })
    rpc.request = original_rpc_request
    util.notify = original_notify
    assert(pi_tree_notice == "Pi tree entry revealed", "Pi /tree should notify after a local reveal")
    coact.setup()
  end

  smoke_pi_slash_provider()
end

local original_submit_text = coact.submit_text
local executed_slash = nil
local execute_default_new_text = nil
local execute_done = false
coact.submit_text = function(text)
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
    source = "coact.nvim.slash",
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
coact.submit_text = original_submit_text
assert(execute_default_new_text == "", "accepting slash completion should remove the typed slash prefix")
assert(executed_slash == "/model", "accepting slash completion should execute the slash command")
assert(execute_done, "slash completion execute should call blink callback")

do
  local untitled_label = require("coact.pickers")._label({ id = "thread-1", name = vim.NIL, preview = vim.NIL })
  assert(untitled_label:match("%[untitled%]"), "thread picker label should fall back to untitled")
  assert(not untitled_label:match("thread%-1"), "thread picker selection label should not expose raw ids")
end
do
  local pickers = require("coact.pickers")
  local original_snacks = package.loaded["snacks"]
  local original_list_threads = coact.list_threads
  local original_resume = coact.resume
  local picked_opts = nil
  local resumed_thread_id = nil
  coact.setup({ provider = "pi" })
  coact.list_threads = function(callback)
    callback({
      {
        id = "pi:picker-fork",
        name = "Forked Pi",
        cwd = "/tmp/pi-picker",
        model = "openai/gpt-5",
        modelProvider = "openai",
        sessionFile = "/tmp/pi-picker/fork.jsonl",
        parentSessionPath = "/tmp/pi-picker/session.jsonl",
        parentThreadId = "pi:picker-session",
        preview = "fork continuation",
        messageCount = 5,
        updated_at = "2026-07-03T11:20:00Z",
      },
      {
        id = "pi:picker-session",
        name = "Picker Pi",
        cwd = "/tmp/pi-picker",
        model = "openai/gpt-5",
        modelProvider = "openai",
        sessionFile = "/tmp/pi-picker/session.jsonl",
        preview = "first picker prompt",
        messageCount = 3,
        updated_at = "2026-07-03T11:14:38Z",
      },
    })
  end
  coact.resume = function(thread_id)
    resumed_thread_id = thread_id
  end
  package.loaded["snacks"] = {
    picker = {
      pick = function(opts)
        picked_opts = opts
        opts.confirm({ close = function() end }, opts.items[2])
      end,
    },
  }
  pickers.threads()
  package.loaded["snacks"] = original_snacks
  coact.list_threads = original_list_threads
  coact.resume = original_resume
  coact.setup()
  assert(picked_opts and picked_opts.title == "Pi Threads", "thread picker title should use the active provider")
  assert(picked_opts.preview == "preview", "thread picker should use item preview data for Snacks")
  assert(
    picked_opts.matcher
      and picked_opts.matcher.sort_empty == false
      and vim.deep_equal(picked_opts.sort.fields, { "score:desc", "idx" }),
    "thread picker should preserve threaded order until the user searches"
  )
  assert(
    picked_opts.items[1]
      and picked_opts.items[1].thread.id == "pi:picker-session"
      and picked_opts.items[2]
      and picked_opts.items[2].thread.id == "pi:picker-fork",
    "thread picker should group a newer fork beneath its parent session"
  )
  assert(
    picked_opts.items[1].text
      and not picked_opts.items[1].text:match("pi:picker%-session")
      and picked_opts.items[2].text:find("   └─ ", 1, true) == 1,
    "thread picker selection text should hide raw provider ids and show fork connectors"
  )
  local formatted = picked_opts.format(picked_opts.items[1])
  local formatted_text = table.concat(
    vim.tbl_map(function(chunk)
      return chunk[1] or ""
    end, formatted),
    ""
  )
  assert(
    formatted_text:match("Picker Pi")
      and formatted_text:match("first picker prompt")
      and formatted_text:match("3 msgs")
      and not formatted_text:match("pi:picker%-session"),
    "thread picker should render modern summary rows without raw ids"
  )
  assert(formatted[2] and formatted[2][2] == "CoactPickerTitle", "thread picker rows should carry Coact highlights")
  local fork_formatted = picked_opts.format(picked_opts.items[2])
  assert(
    fork_formatted[1]
      and fork_formatted[1][1] == "   └─ "
      and fork_formatted[1][2] == "CoactPickerTree"
      and fork_formatted[3]
      and fork_formatted[3][2] == "CoactPickerTitle",
    "forked thread rows should render tree connectors before their status and title"
  )
  assert(
    picked_opts.items[1]
      and picked_opts.items[1].preview
      and picked_opts.items[1].preview.ft == "markdown"
      and picked_opts.items[1].preview.text:match("%*%*Session%*%* `/tmp/pi%-picker/session%.jsonl`")
      and picked_opts.items[1].preview.text:match("first picker prompt"),
    "thread picker items should expose styled textual previews instead of requiring a file"
  )
  assert(
    picked_opts.items[2].preview.text:match("%*%*Forked from%*%* `/tmp/pi%-picker/session%.jsonl`"),
    "forked thread previews should identify their parent session"
  )
  assert(resumed_thread_id == "pi:picker-fork", "thread picker should resume a selected forked session")
end

local rpc = require("coact.rpc")
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
local running_status = coact.status()
assert(running_status.server_running == true, "status should report running server after startup")
assert(running_status.server_initialized == true, "status should report initialized server after startup")

local thread_done = false
coact.new_thread()
vim.wait(3000, function()
  thread_done = require("coact.state").active_thread_id ~= nil
  return thread_done
end, 20)
assert(thread_done, "thread/start timed out")
assert(coact.status().active_thread_id ~= nil, "status should expose the active thread")

local thread = state.ensure_thread("smoke-extmarks", {
  title = "Smoke extmarks",
  cwd = vim.fn.getcwd(),
  generation = "tool_running",
})
local events = require("coact.events")
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
_G.__coact_smoke_dynamic_content_block = events.block_for_item({
  id = "dynamic-content",
  type = "dynamicToolCall",
  namespace = "nvim",
  tool = "lookup",
  arguments = { key = "smoke" },
  status = "completed",
  contentItems = {
    { type = "inputText", text = "dynamic tool output" },
  },
  success = true,
}, "turn-dynamic")
assert(
  _G.__coact_smoke_dynamic_content_block.output == "dynamic tool output"
    and _G.__coact_smoke_dynamic_content_block.text == "dynamic tool output",
  "dynamic tool call blocks should render completed Codex contentItems"
)
_G.__coact_smoke_user_block = events.block_for_item({
  id = "user-reference-separate",
  type = "userMessage",
  content = {
    {
      type = "text",
      text = parser._reference_context_text("Neovim context: listed buffers:\n- #1 README.md ft=markdown"),
      text_elements = {},
    },
    { type = "text", text = "actual prompt", text_elements = {} },
  },
}, "turn-reference-separate")
assert(
  _G.__coact_smoke_user_block.text == "actual prompt",
  "userMessage rendering should hide separate reference context inputs"
)
_G.__coact_smoke_user_block = events.block_for_item({
  id = "user-reference-flattened",
  type = "userMessage",
  content = {
    {
      type = "text",
      text = parser._reference_context_text(
        "Neovim context: selection\n- file: smoke.typ\n- range: L1-L1\n\n```typst\nx\n```\n\nDiagnostics in selection:\n- ERROR L1:C1 bad"
      ) .. "actual flattened prompt",
      text_elements = {},
    },
  },
}, "turn-reference-flattened")
assert(
  _G.__coact_smoke_user_block.text == "actual flattened prompt",
  "userMessage rendering should hide flattened reference context prefixes"
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
);
(function()
  state.clear_thread_pending_requests(thread)
  state.add_thread_pending_request(thread, {
    prompt = "first queued prompt",
    turn_id = "queued-first",
    streaming_behavior = "followUp",
  })
  local second_queued_request = {
    prompt = "second queued prompt",
    turn_id = "queued-second",
    streaming_behavior = "followUp",
  }
  state.add_thread_pending_request(thread, second_queued_request)
  state.add_thread_pending_request(thread, vim.deepcopy(second_queued_request))
  local queued_pending_blocks = events.pending_blocks(thread)
  assert(
    #queued_pending_blocks == 2
      and #state.get_thread_pending_requests(thread) == 2
      and queued_pending_blocks[1].type == "QueuedUserBlock"
      and queued_pending_blocks[1].state == "queued"
      and queued_pending_blocks[1].queue_position == 1
      and queued_pending_blocks[1].queue_count == 2
      and queued_pending_blocks[1].text == "first queued prompt"
      and queued_pending_blocks[2].type == "QueuedUserBlock"
      and queued_pending_blocks[2].queue_position == 2
      and queued_pending_blocks[2].text == "second queued prompt",
    "pending Pi follow-ups should render once in FIFO order with explicit queue state"
  )
end)()
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
local render = require("coact.ui.render")
do
  local queued_render_thread = state.ensure_thread("smoke-queued-render", {
    title = "Smoke queued render",
    cwd = vim.fn.getcwd(),
  })
  state.add_thread_pending_request(queued_render_thread, {
    prompt = "visibly queued prompt",
    turn_id = "visibly-queued-turn",
    streaming_behavior = "followUp",
  })
  local queued_render_buf = buffers.ensure("smoke-queued-render")
  render.render(queued_render_thread)
  local queued_render_lines = vim.api.nvim_buf_get_lines(queued_render_buf, 0, -1, false)
  local queued_header_count = 0
  local user_header_count = 0
  for _, line in ipairs(queued_render_lines) do
    queued_header_count = queued_header_count + (line == "## Queued request" and 1 or 0)
    user_header_count = user_header_count + (line == "## You" and 1 or 0)
  end
  assert(
    queued_header_count == 1 and user_header_count == 0,
    "queued requests should use a distinct queued header instead of duplicating the active user request frame"
  )
  assert(
    queued_render_thread.header_marks[#queued_render_thread.header_marks].kind == "queued"
      and queued_render_thread.header_marks[#queued_render_thread.header_marks].meta[1] == "queued",
    "queued request headers should expose their queue state"
  )
end

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
    "coact markdown rendering should keep native buffer-wide Tree-sitter highlighting"
  )

  local markdown_guard_item = markdown_guard_thread.items["assistant-markdown-guard"]
  markdown_guard_item.text = markdown_guard_item.text .. "\nmore streamed diff"
  assert(
    render.try_stream_delta(markdown_guard_thread, markdown_guard_item.id, "\nmore streamed diff"),
    "an unclosed non-tail fence should update through its render atom"
  )
  assert(
    vim.wait(1000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(markdown_guard_buf, 0, -1, false), "\n")
      return text:find("more streamed diff", 1, true) ~= nil
    end, 5),
    "streaming should replace and re-guard an anchored unclosed fence"
  )
  assert(
    #markdown_guard_thread.auto_closed_fence_lines == 1,
    "streaming an open fence should retain one render-only closing line"
  )

  markdown_guard_item.text = markdown_guard_item.text .. "\n```"
  assert(
    render.try_stream_delta(markdown_guard_thread, markdown_guard_item.id, "\n```"),
    "a closing fence should update the same non-tail render atom"
  )
  assert(
    vim.wait(1000, function()
      return #markdown_guard_thread.auto_closed_fence_lines == 0
    end, 5),
    "a provider closing fence should remove the render-only fence"
  )
  markdown_guard_lines = vim.api.nvim_buf_get_lines(markdown_guard_buf, 0, -1, false)
  assert(
    table.concat(markdown_guard_lines, "\n"):find("after the fence", 1, true),
    "non-tail fence streaming should preserve the following user block"
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
coact.setup({ render = { virtual_blocks = { default_expanded = true } } })
render.render(cleared_event_thread)
local cleared_event_lines = vim.api.nvim_buf_get_lines(cleared_event_buf, 0, -1, false)
assert(not vim.tbl_contains(cleared_event_lines, "## Coact"), "cleared agent events should not open a Coact group")
assert(
  cleared_event_thread.placeholder_marks[1] and cleared_event_thread.placeholder_marks[1].expanded == false,
  "cleared agent events should default to collapsed"
)
coact.setup();
(function()
  local function count_line(lines, expected)
    local count = 0
    for _, line in ipairs(lines or {}) do
      if line == expected then
        count = count + 1
      end
    end
    return count
  end

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
  local final_summaries = {}
  local final_summary_indexes = {}
  local standalone_activity = 0
  local commentary_index = nil
  local final_index = nil
  for index, block in ipairs(final_blocks) do
    if block.type == "ActivitySummaryBlock" then
      table.insert(final_summaries, block)
      table.insert(final_summary_indexes, index)
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
      final_index = index
    end
  end
  assert(#final_summaries == 2, "each completed output segment should receive its own activity summary")
  assert(commentary_index ~= nil, "activity compaction should keep commentary visible")
  assert(final_index ~= nil, "activity compaction should keep the final assistant answer visible")
  assert(
    final_summary_indexes[1] < commentary_index
      and commentary_index < final_summary_indexes[2]
      and final_summary_indexes[2] < final_index,
    "completed activity summaries should preserve folded/output/folded/output chronology"
  )
  assert(standalone_activity == 0, "completed activity compaction should hide standalone reasoning/tool/agent rows")
  assert(
    #final_summaries[1].children == 2 and #final_summaries[2].children == 1,
    "completed output segments should retain their own reasoning, tool, and timeline children"
  )
  assert(
    final_summaries[1].text == nil and final_summaries[2].text == nil,
    "activity summaries should lazily render child details"
  )
  local final_compact_buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(final_compact_thread, final_compact_buf)
  render.render(final_compact_thread)
  local final_compact_lines = vim.api.nvim_buf_get_lines(final_compact_buf, 0, -1, false)
  assert(vim.tbl_contains(final_compact_lines, "final answer"), "completed activity render should show final answer")
  assert(
    count_line(final_compact_lines, "## Coact") == 1,
    "segmented activity and outputs should render inside one assistant response frame"
  )
  assert(
    #final_compact_thread.placeholder_marks == 2
      and final_compact_thread.placeholder_marks[1].block.type == "ActivitySummaryBlock"
      and final_compact_thread.placeholder_marks[2].block.type == "ActivitySummaryBlock"
      and final_compact_thread.placeholder_marks[1].title == "Thinking finished"
      and final_compact_thread.placeholder_marks[2].title == "Thinking finished",
    "completed output segments should render as collapsed thinking-finished rows"
  )
  local first_final_detail = table.concat(require("coact.ui.detail").lines_for(final_summaries[1]), "\n")
  local second_final_detail = table.concat(require("coact.ui.detail").lines_for(final_summaries[2]), "\n")
  assert(
    first_final_detail:match("# Thinking finished")
      and first_final_detail:match("### Reasoning")
      and first_final_detail:match("echo done"),
    "the first activity summary should preserve reasoning and tool details"
  )
  assert(
    second_final_detail:match("# Thinking finished") and second_final_detail:match("Agent: Model rerouted"),
    "the second activity summary should preserve late timeline details"
  )

  local split_activity_thread = state.ensure_thread("smoke-split-activity", {
    title = "Smoke split activity",
    cwd = vim.fn.getcwd(),
    generation = "idle",
  })
  state.upsert_item("smoke-split-activity", "turn-split-1", {
    id = "split-user",
    type = "userMessage",
    content = { { type = "text", text = "inspect the project" } },
    status = "completed",
  })
  state.upsert_item("smoke-split-activity", "turn-split-1", {
    id = "split-reasoning-1",
    type = "reasoning",
    content = { "inspect before using tools" },
    status = "completed",
  })
  state.upsert_item("smoke-split-activity", "turn-split-1", {
    id = "split-progress",
    type = "agentMessage",
    text = "I found the relevant files.",
    status = "completed",
  })
  state.upsert_item("smoke-split-activity", "turn-split-1", {
    id = "split-tool",
    type = "commandExecution",
    command = "rg activity",
    cwd = vim.fn.getcwd(),
    status = "completed",
    aggregatedOutput = "activity match",
    exitCode = 0,
  })
  state.upsert_item("smoke-split-activity", "turn-split-2", {
    id = "split-reasoning-2",
    type = "reasoning",
    content = { "compose the final answer" },
    status = "completed",
  })
  state.upsert_item("smoke-split-activity", "turn-split-2", {
    id = "split-final",
    type = "agentMessage",
    text = "split final answer",
    status = "completed",
  })
  local split_blocks = render.select_render_tree(split_activity_thread)
  local split_summaries = {}
  local split_summary_indexes = {}
  local split_progress_index = nil
  local split_final_index = nil
  local split_standalone_activity = 0
  for index, block in ipairs(split_blocks) do
    if block.type == "ActivitySummaryBlock" then
      table.insert(split_summaries, block)
      table.insert(split_summary_indexes, index)
    elseif block.type == "ReasoningBlock" or block.type == "ToolCallBlock" then
      split_standalone_activity = split_standalone_activity + 1
    elseif block.type == "AssistantBlock" and block.text == "I found the relevant files." then
      split_progress_index = index
    elseif block.type == "AssistantBlock" and block.text == "split final answer" then
      split_final_index = index
    end
  end
  assert(#split_summaries == 2, "activity split across provider turns should preserve both output segments")
  assert(
    #split_summaries[1].children == 1 and #split_summaries[2].children == 2,
    "each split output should own only the activity that preceded it"
  )
  assert(split_standalone_activity == 0, "completed split activity should not leave standalone placeholders")
  assert(
    split_summary_indexes[1] < split_progress_index
      and split_progress_index < split_summary_indexes[2]
      and split_summary_indexes[2] < split_final_index,
    "split activity should preserve folded/output/folded/output chronology across provider turn ids"
  )
  local split_activity_buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(split_activity_thread, split_activity_buf)
  render.render(split_activity_thread)
  local split_activity_lines = vim.api.nvim_buf_get_lines(split_activity_buf, 0, -1, false)
  assert(
    #split_activity_thread.placeholder_marks == 2
      and split_activity_thread.placeholder_marks[1].block.type == "ActivitySummaryBlock"
      and split_activity_thread.placeholder_marks[2].block.type == "ActivitySummaryBlock",
    "completed split activity should render as two chronological summary rows"
  )
  assert(
    count_line(split_activity_lines, "## Coact") == 1,
    "provider turn splits should still render one assistant response frame"
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
  state.upsert_item("smoke-busy-activity", "turn-busy", {
    id = "busy-tool-1",
    type = "commandExecution",
    command = "echo one",
    cwd = vim.fn.getcwd(),
    status = "completed",
    aggregatedOutput = "one",
    exitCode = 0,
  })
  state.upsert_item("smoke-busy-activity", "turn-busy", {
    id = "busy-tool-2",
    type = "commandExecution",
    command = "echo two",
    cwd = vim.fn.getcwd(),
    status = "inProgress",
    aggregatedOutput = "two",
  })
  local busy_blocks = render.select_render_tree(busy_activity_thread)
  local busy_summary = nil
  local busy_summary_index = nil
  local busy_commentary_index = nil
  local busy_tool_indexes = {}
  for index, block in ipairs(busy_blocks) do
    if block.type == "ActivitySummaryBlock" then
      busy_summary = block
      busy_summary_index = index
    elseif block.type == "AssistantBlock" and block.state == "commentary" then
      busy_commentary_index = index
    elseif block.type == "ToolCallBlock" then
      table.insert(busy_tool_indexes, index)
    end
  end
  assert(
    busy_summary and #busy_summary.children == 1,
    "busy activity should fold only the work completed before partial output"
  )
  assert(
    #busy_tool_indexes == 2
      and busy_summary_index < busy_commentary_index
      and busy_commentary_index < busy_tool_indexes[1]
      and busy_tool_indexes[1] < busy_tool_indexes[2],
    "busy activity should preserve folded/partial-output/tool process chronology"
  )
  local busy_activity_buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(busy_activity_thread, busy_activity_buf)
  render.render(busy_activity_thread)
  local busy_activity_lines = vim.api.nvim_buf_get_lines(busy_activity_buf, 0, -1, false)
  assert(
    #busy_activity_thread.placeholder_marks == 3,
    "busy output should keep its folded prefix plus subsequent tools inspectable"
  )
  assert(count_line(busy_activity_lines, "## Coact") == 1, "busy output and tools should share one response frame")

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
  local streaming_summary_indexes = {}
  local streaming_summaries = {}
  local streaming_commentary_index = nil
  local streaming_final_index = nil
  local streaming_standalone_activity = 0
  for index, block in ipairs(streaming_blocks) do
    if block.type == "ActivitySummaryBlock" then
      table.insert(streaming_summaries, block)
      table.insert(streaming_summary_indexes, index)
    elseif block.type == "ReasoningBlock" or block.type == "ToolCallBlock" then
      streaming_standalone_activity = streaming_standalone_activity + 1
    elseif block.type == "AssistantBlock" and block.state == "commentary" then
      streaming_commentary_index = index
    elseif block.type == "AssistantBlock" and block.text == "partial final answer" then
      streaming_final_index = index
    end
  end
  assert(#streaming_summaries == 2, "streaming output should compact each finished activity segment")
  assert(
    #streaming_summaries[1].children == 1 and #streaming_summaries[2].children == 1,
    "streaming summaries should preserve their separate reasoning and tool children"
  )
  assert(streaming_standalone_activity == 0, "streaming final output should hide completed standalone activity")
  assert(
    streaming_summary_indexes[1] < streaming_commentary_index
      and streaming_commentary_index < streaming_summary_indexes[2]
      and streaming_summary_indexes[2] < streaming_final_index,
    "streaming output should preserve folded/output/folded/output chronology"
  )
  local streaming_final_buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(streaming_final_thread, streaming_final_buf)
  render.render(streaming_final_thread)
  local streaming_final_lines = vim.api.nvim_buf_get_lines(streaming_final_buf, 0, -1, false)
  assert(
    #streaming_final_thread.placeholder_marks == 2,
    "streaming final output should render both completed activity segments as summaries"
  )
  assert(
    count_line(streaming_final_lines, "## Coact") == 1,
    "streaming partial and final output should share one assistant response frame"
  )
end)()
local core_pending_thread = state.ensure_thread("smoke-core-pending", {
  title = "Smoke core pending",
  cwd = vim.fn.getcwd(),
})
core_pending_thread.pending_request = { prompt = "core pending", created_at = vim.uv.now() }
local core = require("coact.core")
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
core.handle_notification({
  method = "item/completed",
  params = {
    threadId = "smoke-core-pending",
    turnId = "turn-core",
    item = {
      id = "turn-core:user",
      type = "userMessage",
      status = "completed",
      content = { { type = "text", text = "core pending" } },
    },
  },
})
assert(
  core_pending_thread.pending_request == nil,
  "a server userMessage echo should replace pending UI state instead of rendering a duplicate request"
);
(function()
  local core_queued_pending_thread = state.ensure_thread("smoke-core-queued-pending", {
    title = "Smoke queued pending",
    cwd = vim.fn.getcwd(),
  })
  core_queued_pending_thread.pending_request = {
    prompt = "queued pending",
    turn_id = "queued-turn",
    streaming_behavior = "followUp",
    created_at = vim.uv.now(),
  }
  core.handle_notification({
    method = "turn/completed",
    params = {
      threadId = "smoke-core-queued-pending",
      turn = { id = "active-turn", items = {} },
    },
  })
  assert(
    core_queued_pending_thread.pending_request ~= nil,
    "turn/completed for the active turn should preserve a queued Pi follow-up pending request"
  )
  core.handle_notification({
    method = "turn/completed",
    params = {
      threadId = "smoke-core-queued-pending",
      turn = { id = "queued-turn", items = {} },
    },
  })
  assert(
    core_queued_pending_thread.pending_request == nil,
    "turn/completed for the queued turn should clear the queued pending request"
  )
  local timeline_count = #core_queued_pending_thread.timeline_blocks
  core.handle_notification({
    method = "pi/queue_update",
    params = {
      threadId = "smoke-core-queued-pending",
      steering = {},
      followUp = { "queued without transcript noise" },
    },
  })
  assert(
    #core_queued_pending_thread.timeline_blocks == timeline_count
      and core_queued_pending_thread.pi_queue.follow_up[1] == "queued without transcript noise",
    "Pi queue updates should refresh queue cache without adding timeline blocks"
  )
  local raw_count = #core_queued_pending_thread.raw_blocks
  core.handle_notification({
    method = "pi/auto_retry_start",
    params = {
      threadId = "smoke-core-queued-pending",
      attempt = 1,
      maxAttempts = 3,
      delayMs = 2000,
      errorMessage = "temporary overload",
    },
  })
  core.handle_notification({
    method = "pi/auto_retry_end",
    params = {
      threadId = "smoke-core-queued-pending",
      success = true,
      attempt = 1,
    },
  })
  assert(
    #core_queued_pending_thread.timeline_blocks == timeline_count
      and #core_queued_pending_thread.raw_blocks == raw_count,
    "Pi auto-retry status should stay transient instead of leaving transcript blocks"
  )
  state.add_thread_pending_request(core_queued_pending_thread, {
    prompt = "stale queued pending",
    turn_id = "stale-queued-turn",
    streaming_behavior = "followUp",
  })
  core_queued_pending_thread.generation = "submitted"
  core.handle_notification({
    method = "pi/agent_settled",
    params = { threadId = "smoke-core-queued-pending" },
  })
  assert(
    core_queued_pending_thread.generation == "idle"
      and core_queued_pending_thread.pending_request == nil
      and #state.get_thread_pending_requests(core_queued_pending_thread) == 0,
    "Pi agent_settled should clear stale queued UI state"
  )
end)();
(function()
  local pi_rollout_thread = state.ensure_thread("smoke-pi-rollout-busy", {
    title = "Smoke Pi rollout busy",
    cwd = vim.fn.getcwd(),
  })
  core.handle_notification({
    method = "pi/agent_start",
    params = { threadId = pi_rollout_thread.id, turnId = "pi-rollout-turn" },
  })
  core.handle_notification({
    method = "item/started",
    params = {
      threadId = pi_rollout_thread.id,
      turnId = "pi-rollout-turn",
      item = {
        id = "pi-read-call",
        type = "dynamicToolCall",
        namespace = "pi",
        tool = "read",
        status = "running",
      },
    },
  })
  core.handle_notification({
    method = "item/completed",
    params = {
      threadId = pi_rollout_thread.id,
      turnId = "pi-rollout-turn",
      item = {
        id = "pi-read-call",
        type = "dynamicToolCall",
        namespace = "pi",
        tool = "read",
        status = "completed",
      },
    },
  })
  core.handle_notification({
    method = "turn/completed",
    params = {
      threadId = pi_rollout_thread.id,
      turn = { id = "pi-rollout-turn", items = {} },
    },
  })
  local pi_rollout_buf = buffers.ensure(pi_rollout_thread.id)
  render.render(pi_rollout_thread)
  assert(
    pi_rollout_thread.pi_agent_active
      and pi_rollout_thread.generation == "submitted"
      and pi_rollout_thread.spinner_mark ~= nil,
    "a completed Pi tool turn should keep the rollout spinner active"
  )
  core.handle_notification({
    method = "pi/agent_end",
    params = { threadId = pi_rollout_thread.id, willRetry = false },
  })
  render.render(pi_rollout_thread)
  assert(
    pi_rollout_thread.pi_agent_active
      and pi_rollout_thread.generation == "waiting_backend"
      and pi_rollout_thread.spinner_mark ~= nil,
    "Pi agent_end should keep spinning until agent_settled"
  )
  core.handle_notification({
    method = "pi/agent_settled",
    params = { threadId = pi_rollout_thread.id },
  })
  render.render(pi_rollout_thread)
  assert(
    vim.api.nvim_buf_is_valid(pi_rollout_buf)
      and not pi_rollout_thread.pi_agent_active
      and pi_rollout_thread.generation == "idle"
      and pi_rollout_thread.spinner_mark == nil,
    "Pi agent_settled should stop the rollout spinner"
  )
end)();
(function()
  local pi = require("coact.providers.pi")
  local queue_thread_id = "pi:smoke-queue-order"
  local queue_thread = state.ensure_thread(queue_thread_id, {
    generation = "streaming",
    active_turn_id = "queue-active-turn",
  })
  state.upsert_item(queue_thread_id, "queue-active-turn", {
    id = "queue-active-output",
    type = "agentMessage",
    status = "completed",
    text = "active answer",
  })
  state.add_thread_pending_request(queue_thread, {
    prompt = "queued question",
    input = { { type = "text", text = "queued question" } },
    turn_id = "queue-follow-up-turn",
    streaming_behavior = "followUp",
  })
  pi._runtime.current_thread_id = queue_thread_id
  pi._runtime.active_turn_id = "queue-active-turn"
  pi._runtime.last_turn_id = "queue-active-turn"
  pi._runtime.reserved_turn = nil
  pi._runtime.queued_turns = {
    {
      id = "queue-follow-up-turn",
      message = "queued question",
      input = { { type = "text", text = "queued question" } },
      streamingBehavior = "followUp",
    },
  }
  local function dispatch_pi(raw)
    local decoded = pi.decode_notification(raw)
    for _, entry in ipairs(decoded and (vim.islist(decoded) and decoded or { decoded }) or {}) do
      core.handle_notification(entry.message)
    end
  end
  local queued_before_delivery = 0
  for _, block in ipairs(render.select_render_tree(queue_thread)) do
    if block.type == "QueuedUserBlock" and events.block_text(block) == "queued question" then
      queued_before_delivery = queued_before_delivery + 1
    end
  end
  assert(queued_before_delivery == 1, "a waiting Pi follow-up should render exactly once with queued state")
  dispatch_pi({ type = "turn_end", message = { role = "assistant", content = {} } })
  dispatch_pi({ type = "turn_start" })
  dispatch_pi({ type = "queue_update", steering = {}, followUp = {} })
  dispatch_pi({
    type = "message_start",
    message = { role = "user", content = { { type = "text", text = "queued question" } } },
  })
  assert(
    #state.get_thread_pending_requests(queue_thread) == 0,
    "Pi should remove queued UI state as soon as the delivered user message replaces it"
  )
  local delivered_user_count = 0
  local stale_queue_count = 0
  for _, block in ipairs(render.select_render_tree(queue_thread)) do
    if events.block_text(block) == "queued question" then
      delivered_user_count = delivered_user_count + (block.type == "UserBlock" and 1 or 0)
      stale_queue_count = stale_queue_count + (block.type == "QueuedUserBlock" and 1 or 0)
    end
  end
  assert(
    delivered_user_count == 1 and stale_queue_count == 0,
    "a delivered Pi follow-up should replace rather than duplicate its queued request block"
  )
  dispatch_pi({ type = "message_start", message = { role = "assistant", content = {} } })
  dispatch_pi({
    type = "message_update",
    assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "queued answer" },
  })
  dispatch_pi({
    type = "message_end",
    message = { role = "assistant", content = { { type = "text", text = "queued answer" } } },
  })
  dispatch_pi({
    type = "turn_end",
    message = { role = "assistant", content = { { type = "text", text = "queued answer" } } },
  })
  dispatch_pi({ type = "agent_settled" })
  local user_index
  local answer_index
  for index, block in ipairs(require("coact.ui.render").select_render_tree(queue_thread)) do
    local text = require("coact.events").block_text(block)
    if block.type == "UserBlock" and text == "queued question" then
      user_index = index
    elseif block.type == "AssistantBlock" and text == "queued answer" then
      answer_index = index
    end
  end
  assert(
    user_index and answer_index and user_index < answer_index,
    "Pi queued user messages should render before their streamed assistant response"
  )
  assert(
    queue_thread.generation == "idle"
      and #state.get_thread_pending_requests(queue_thread) == 0
      and #queue_thread.timeline_blocks == 0,
    "Pi queue completion should settle without pending state or queue timeline blocks"
  )
end)()
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
  "coact buffers should use native buffer-wide Markdown Tree-sitter"
)
vim.api.nvim_set_current_buf(thread.bufnr)
buffers.apply_window_options(vim.api.nvim_get_current_win(), thread.bufnr)
local extmarks =
  vim.api.nvim_buf_get_extmarks(thread.bufnr, require("coact.ui.render").namespace(), 0, -1, { details = true })
assert(#extmarks > 0, "render should create extmarks");
(function()
  local user_header_line = vim.api.nvim_buf_get_lines(thread.bufnr, 2, 3, false)[1] or ""
  local saw_full_header_conceal = false
  for _, mark in ipairs(extmarks) do
    local details = mark[4] or {}
    if mark[2] == 2 and details.priority == 2000 and details.conceal == "" then
      saw_full_header_conceal = details.end_col == #user_header_line
      break
    end
  end
  assert(saw_full_header_conceal, "header overlays should conceal the full markdown heading line")
end)()
assert(#(thread.placeholder_marks or {}) >= 2, "reasoning and tool blocks should be placeholders")
assert(thread.spinner_mark ~= nil, "busy thread should render a spinner mark")
assert(thread.folds and thread.folds[1] and thread.folds[1].start == 3, "render should record user block folds")
assert(vim.wo.foldmethod == "manual", "history windows should use manual folds")
assert(vim.fn.foldlevel(3) == 1, "render should create manual folds for user blocks")
assert(vim.fn.foldclosed(3) == -1, "manual folds should remain open after render")
local detail_lines = require("coact.ui.detail").lines_for(thread.placeholder_marks[1].block)
assert(table.concat(detail_lines, "\n"):match("# Reasoning"), "detail should render block title")

local render = require("coact.ui.render")
local win = vim.api.nvim_get_current_win()
render.prepare_submit_follow(thread, win)
assert(thread.view_state and thread.view_state[win], "prepare_submit_follow should store per-window state")
render.on_user_view_changed(thread, win, "cursor")

local core = require("coact.core")

local function assert_handles_notification(message, label)
  local ok, err = pcall(core.handle_notification, message)
  assert(ok, label .. ": " .. tostring(err))
end

(function()
  local smoke_config = require("coact.config")
  local fast_thread = state.ensure_thread("smoke-stream-fast-path", {
    title = "Smoke stream fast path",
    cwd = vim.fn.getcwd(),
    generation = "streaming",
  })
  state.upsert_item("smoke-stream-fast-path", "turn-fast", {
    id = "fast-user",
    type = "userMessage",
    content = { { type = "text", text = "hello?" } },
    status = "completed",
  })
  state.upsert_item("smoke-stream-fast-path", "turn-fast", {
    id = "fast-assistant",
    type = "agentMessage",
    text = "hello",
    status = "inProgress",
  })
  state.upsert_item("smoke-stream-fast-path", "turn-fast", {
    id = "fast-reasoning",
    type = "reasoning",
    summary = { "between outputs" },
    content = { "anchored activity" },
    status = "completed",
  })
  state.upsert_item("smoke-stream-fast-path", "turn-fast", {
    id = "fast-assistant-tail",
    type = "agentMessage",
    text = "tail",
    status = "inProgress",
  })
  buffers.ensure("smoke-stream-fast-path")
  vim.api.nvim_set_current_buf(fast_thread.bufnr)
  local fast_win = vim.api.nvim_get_current_win()
  local fast_atom = fast_thread.stream_atoms_by_item_id and fast_thread.stream_atoms_by_item_id["fast-assistant"]
  assert(fast_atom and fast_atom.text_start, "stream fixture should expose the first assistant text atom")
  vim.api.nvim_win_set_cursor(fast_win, { fast_atom.text_start, 0 })
  local fast_cursor = vim.api.nvim_win_get_cursor(fast_win)
  local shifted_placeholder = fast_thread.placeholder_marks and fast_thread.placeholder_marks[1]
  local shifted_placeholder_line = shifted_placeholder and shifted_placeholder.line
  assert(shifted_placeholder_line, "multi-position stream fixture should include an anchored placeholder")

  local original_render = render.render
  local render_count = 0
  render.render = function(render_thread)
    if render_thread == fast_thread then
      render_count = render_count + 1
    end
    return original_render(render_thread)
  end
  local ok, err = pcall(function()
    assert_handles_notification({
      method = "item/agentMessage/delta",
      params = {
        threadId = "smoke-stream-fast-path",
        turnId = "turn-fast",
        itemId = "fast-assistant",
        delta = " world",
      },
    }, "assistant text delta should use stream fast path")
    assert_handles_notification({
      method = "item/agentMessage/delta",
      params = {
        threadId = "smoke-stream-fast-path",
        turnId = "turn-fast",
        itemId = "fast-assistant-tail",
        delta = " end",
      },
    }, "a second assistant position should share the stream flush")
    assert_handles_notification({
      method = "item/agentMessage/delta",
      params = {
        threadId = "smoke-stream-fast-path",
        turnId = "turn-fast",
        itemId = "fast-assistant",
        delta = "!",
      },
    }, "assistant text delta should coalesce stream atom writes")
    local lines = vim.api.nvim_buf_get_lines(fast_thread.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert(
      not text:match("hello world!") and not text:match("tail end"),
      "assistant deltas should wait for the coalesced buffer flush"
    )
    assert(
      vim.wait(1000, function()
        lines = vim.api.nvim_buf_get_lines(fast_thread.bufnr, 0, -1, false)
        text = table.concat(lines, "\n")
        return text:match("hello world!") ~= nil and text:match("tail end") ~= nil
      end, 5),
      "one flush should update multiple anchored assistant positions"
    )
    vim.wait(smoke_config.get().ui.render_delay_ms + 25, function()
      return false
    end, 5)
    assert(render_count == 0, "assistant text delta fast path should not schedule a full render")
    assert(
      vim.deep_equal(vim.api.nvim_win_get_cursor(fast_win), fast_cursor),
      "assistant text streaming should preserve the transcript cursor"
    )

    local line_count = vim.api.nvim_buf_line_count(fast_thread.bufnr)
    assert_handles_notification({
      method = "item/agentMessage/delta",
      params = {
        threadId = "smoke-stream-fast-path",
        turnId = "turn-fast",
        itemId = "fast-assistant",
        delta = "\nnext line",
      },
    }, "assistant newline delta should use stream fast path")
    assert(
      vim.wait(1000, function()
        lines = vim.api.nvim_buf_get_lines(fast_thread.bufnr, 0, -1, false)
        return table.concat(lines, "\n"):match("next line") ~= nil
      end, 5),
      "assistant newline delta should update visible text on the coalesced flush"
    )
    assert(vim.api.nvim_buf_line_count(fast_thread.bufnr) == line_count + 1, "newline delta should append one line")
    assert(
      vim.deep_equal(vim.api.nvim_win_get_cursor(fast_win), fast_cursor),
      "multiline assistant streaming should preserve the transcript cursor"
    )
    lines = vim.api.nvim_buf_get_lines(fast_thread.bufnr, 0, -1, false)
    text = table.concat(lines, "\n")
    assert(
      text:find("hello world!\nnext line", 1, true) and text:find("tail end", 1, true),
      "a non-tail stream edit should preserve later render atoms"
    )
    assert(
      shifted_placeholder.line == shifted_placeholder_line + 1
        and fast_thread.placeholder_index[shifted_placeholder.line] == shifted_placeholder,
      "placeholder indexes should resolve from extmarks after an earlier stream atom grows"
    )
    assert(
      fast_thread.spinner_mark
        and fast_thread.spinner_mark.extmark_id
        and fast_thread.spinner_mark.line == vim.api.nvim_buf_line_count(fast_thread.bufnr) - 1,
      "the spinner anchor should follow multi-position stream edits"
    )
    vim.wait(smoke_config.get().ui.render_delay_ms + 25, function()
      return false
    end, 5)
    assert(render_count == 0, "assistant newline delta fast path should not schedule a full render")
  end)
  render.render = original_render
  assert(ok, err)
end)()

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
assert(thread.items["tool-1"].aggregatedOutput == command_before, "null command delta should not alter output");
(function()
  local smoke_config = require("coact.config")
  local original_render = render.render
  local render_count = 0
  render.render = function(render_thread)
    if render_thread == thread then
      render_count = render_count + 1
    end
    return original_render(render_thread)
  end
  local ok, err = pcall(function()
    assert_handles_notification({
      method = "item/commandExecution/outputDelta",
      params = {
        threadId = "smoke-extmarks",
        turnId = "turn-1",
        itemId = "tool-1",
        delta = "\nmore hidden output",
      },
    }, "command output delta should use placeholder fast path")
    assert(
      thread.items["tool-1"].aggregatedOutput:match("more hidden output"),
      "command output delta should still update item state"
    )
    vim.wait(smoke_config.get().ui.render_delay_ms + 25, function()
      return false
    end, 5)
    assert(render_count == 0, "hidden command output delta should not schedule a full render")

    local function mark_body_contains(mark, needle)
      for _, line in ipairs(mark.body_lines or {}) do
        if tostring(line):find(needle, 1, true) then
          return true
        end
      end
      return false
    end

    local mark = thread.placeholder_by_item_id and thread.placeholder_by_item_id["tool-1"]
    assert(mark, "tool placeholder should remain indexed by item id")
    mark.expanded = true
    assert_handles_notification({
      method = "item/commandExecution/outputDelta",
      params = {
        threadId = "smoke-extmarks",
        turnId = "turn-1",
        itemId = "tool-1",
        delta = "\nvisible output",
      },
    }, "expanded command output delta should update placeholder virtual lines")
    vim.wait(smoke_config.get().ui.render_delay_ms + 25, function()
      return false
    end, 5)
    assert(render_count == 0, "expanded command output delta should not schedule a full render")
    assert(mark_body_contains(mark, "visible output"), "expanded command output should refresh placeholder body lines")

    local reasoning_mark = thread.placeholder_by_item_id and thread.placeholder_by_item_id["reasoning-1"]
    assert(reasoning_mark, "reasoning placeholder should remain indexed by item id")
    reasoning_mark.expanded = true
    assert_handles_notification({
      method = "item/reasoning/textDelta",
      params = {
        threadId = "smoke-extmarks",
        turnId = "turn-1",
        itemId = "reasoning-1",
        contentIndex = 0,
        delta = " streamed thought",
      },
    }, "expanded reasoning delta should update placeholder virtual lines")
    vim.wait(smoke_config.get().ui.render_delay_ms + 25, function()
      return false
    end, 5)
    assert(render_count == 0, "expanded reasoning delta should not schedule a full render")
    assert(
      mark_body_contains(reasoning_mark, "streamed thought"),
      "expanded reasoning should refresh placeholder body lines"
    )
  end)
  render.render = original_render
  assert(ok, err)
end)()
state.upsert_item("smoke-extmarks", "turn-1", {
  id = "tool-ansi",
  type = "commandExecution",
  command = "apply_patch",
  cwd = vim.fn.getcwd(),
  status = "inProgress",
})
assert_handles_notification({
  method = "item/commandExecution/outputDelta",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "tool-ansi",
    delta = table.concat({
      "\27[2m2026-06-09T19:06:55Z\27[0m \27[31mERROR\27[0m codex_core::tools::router:",
      "Command blocked by PreToolUse hook: User rejected Codex native apply_patch in Neovim.",
      "Command: *** Begin Patch",
      "*** Update File: sample.txt",
      "*** End Patch",
    }, " "),
  },
}, "command output should sanitize PreToolUse blocked output")
_G.__coact_smoke_sanitized_ansi_output = thread.items["tool-ansi"].aggregatedOutput
assert(not _G.__coact_smoke_sanitized_ansi_output:match("\27"), "command output should strip ANSI escape sequences")
assert(
  _G.__coact_smoke_sanitized_ansi_output
    == "Command blocked by PreToolUse hook: User rejected Codex native apply_patch in Neovim.",
  "command output should hide the rejected native apply_patch command body"
)
assert(
  util.strip_ansi("\226\144\155[2m2026-06-10T13:18:18Z\226\144\155[0m \226\144\155[31mERROR\226\144\155[0m")
    == "2026-06-10T13:18:18Z ERROR",
  "ANSI stripping should remove visible escape markers from app-server logs"
)
assert(
  util.strip_ansi("\27\n[31mERROR\27[0m") == "\nERROR",
  "ANSI stripping should remove stream-split SGR fragments from app-server logs"
)
assert(util.strip_ansi("pattern ^[a-z]") == "pattern ^[a-z]", "ANSI stripping should preserve non-ANSI caret text")
assert(util.clean_tool_output(table.concat({
  "\226\144\155[2m2026-06-10T13:18:18Z\226\144\155[0m \226\144\155[31mERROR\226\144\155[0m codex_core::tools::router:",
  "error=Command blocked by PreToolUse hook: Codex native apply_patch did not validate before Neovim review:",
  "Failed to find expected lines in sample.txt:",
  "Command: *** Begin Patch",
  "*** Update File: sample.txt",
  "*** End Patch",
}, " ")) == table.concat({
  "Command blocked by PreToolUse hook: Codex native apply_patch did not validate before Neovim review:",
  "Failed to find expected lines in sample.txt:",
}, " "), "app-server hook errors should drop visible ANSI escapes and native patch bodies")

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
  method = "item/reasoning/summaryPartAdded",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "reasoning-1",
    summaryIndex = 1,
  },
}, "Codex reasoning summary part boundary should accept summaryIndex without text")
assert(thread.items["reasoning-1"].summary[2] == "", "summaryPartAdded should initialize indexed summary slots")
assert_handles_notification({
  method = "item/reasoning/summaryTextDelta",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "reasoning-1",
    summaryIndex = 1,
    delta = "second summary",
  },
}, "Codex reasoning summary delta should use summaryIndex")
assert(thread.items["reasoning-1"].summary[2] == "second summary", "summary delta should update indexed summary slots")

state.upsert_item("smoke-extmarks", "turn-1", {
  id = "mcp-progress",
  type = "mcpToolCall",
  server = "smoke",
  tool = "lookup",
  status = "inProgress",
  arguments = { query = "stream" },
})
assert_handles_notification({
  method = "item/mcpToolCall/progress",
  params = {
    threadId = "smoke-extmarks",
    turnId = "turn-1",
    itemId = "mcp-progress",
    message = "fetching page 1",
  },
}, "Codex MCP progress message should stream as readable tool output")
_G.__coact_smoke_mcp_progress_block = events.block_for_item(thread.items["mcp-progress"], "turn-1")
assert(
  thread.items["mcp-progress"].progressText == "fetching page 1"
    and _G.__coact_smoke_mcp_progress_block.text == "fetching page 1"
    and _G.__coact_smoke_mcp_progress_block.output == "fetching page 1",
  "MCP progress message should render as tool progress text instead of raw notification JSON"
)

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
        command = "coact-nvim-apply-patch-hook",
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
        command = "coact-nvim-apply-patch-hook",
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
        command = "coact-nvim-apply-patch-hook",
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
        command = "coact-nvim-apply-patch-hook",
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
  local legacy_hook_blocks = require("coact.ui.render").select_render_tree(legacy_hook_thread)
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

require("coact.rpc").stop()
