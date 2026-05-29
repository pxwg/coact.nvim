local config = require("codex.config")
local util = require("codex.util")

local M = {}

local reviewed_items = {}
local nonce = nil
local server_address = nil
local nvim_bin = nil
local cleanup_augroup = nil
local noop_marker_prefix = ".codex-nvim-apply-patch-noop-"

local function trim_trailing_slash(path)
  path = tostring(path or "")
  path = path:gsub("/+$", "")
  if path == "" then
    return "/tmp"
  end
  return path
end

local function edit_opts()
  local edit = config.get().edit or {}
  return edit.native_apply_patch_hook or {}
end

local function enabled()
  local opts = edit_opts()
  return config.edit_mode() == "pair" and opts.enabled ~= false
end

local function toml_quote(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. value .. '"'
end

local function shell_quote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function hook_script_path()
  return vim.fs.joinpath(plugin_root(), "scripts", "codex-nvim-apply-patch-hook")
end

local function debug_log_path()
  local from_global = vim.g.codex_native_apply_patch_debug_log
  if type(from_global) == "string" and from_global ~= "" then
    return from_global
  end
  local from_env = vim.env.CODEX_NVIM_APPLY_PATCH_DEBUG_LOG
  if type(from_env) == "string" and from_env ~= "" then
    return from_env
  end
  local opts = edit_opts()
  if type(opts.debug_log_path) == "string" and opts.debug_log_path ~= "" then
    return opts.debug_log_path
  end
  if opts.debug == true then
    return vim.fs.joinpath(trim_trailing_slash(vim.env.TMPDIR or "/tmp"), "codex-nvim-apply-patch-debug.log")
  end
  return nil
end

local function encode_log_entry(entry)
  local ok, encoded = pcall(vim.json.encode, entry)
  if ok then
    return encoded
  end
  return vim.json.encode({
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = "debug_log_encode_failed",
    error = tostring(encoded),
  })
end

function M.debug_log(event, data)
  local path = debug_log_path()
  if not path then
    return
  end
  local entry = {
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = event,
    pid = vim.fn.getpid(),
    server = vim.v.servername,
    data = data or vim.empty_dict(),
  }
  pcall(vim.fn.writefile, { encode_log_entry(entry) }, path, "a")
end

function M.enable_debug(path)
  if type(path) ~= "string" or path == "" then
    path = vim.fs.joinpath(trim_trailing_slash(vim.env.TMPDIR or "/tmp"), "codex-nvim-apply-patch-debug.log")
  end
  vim.g.codex_native_apply_patch_debug_log = path
  M.debug_log("debug_enabled", { path = path })
  return path
end

local function hook_command()
  local opts = edit_opts()
  if opts.command and opts.command ~= "" then
    return opts.command
  end
  return table.concat({ "/bin/sh", shell_quote(hook_script_path()) }, " ")
end

local function ensure_server_address()
  if server_address and server_address ~= "" then
    return server_address
  end
  if vim.v.servername and vim.v.servername ~= "" then
    server_address = vim.v.servername
    return server_address
  end
  local root = vim.fn.tempname()
  local ok, address = pcall(vim.fn.serverstart, root .. ".sock")
  if ok and address and address ~= "" then
    server_address = address
    return server_address
  end
  return nil, address
end

local function ensure_nonce()
  if nonce then
    return nonce
  end
  nonce = vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. tostring(math.random()))
  return nonce
end

local function ensure_nvim_bin()
  if nvim_bin and nvim_bin ~= "" then
    return nvim_bin
  end
  local progpath = vim.v.progpath or "nvim"
  local resolved = vim.fn.exepath(progpath)
  nvim_bin = resolved ~= "" and resolved or progpath
  return nvim_bin
end

local function noop_marker_min_age_sec()
  local opts = edit_opts()
  local value = tonumber(opts.marker_cleanup_min_age_sec or opts.noop_marker_cleanup_min_age_sec)
  if value == nil then
    return 300
  end
  return math.max(0, value)
end

local function cleanup_stale_noop_markers(cwd, min_age_sec)
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  if vim.fn.isdirectory(cwd) ~= 1 then
    return { removed = {}, skipped = {}, errors = { "not a directory: " .. cwd } }
  end
  min_age_sec = tonumber(min_age_sec)
  if min_age_sec == nil then
    min_age_sec = noop_marker_min_age_sec()
  end
  min_age_sec = math.max(0, min_age_sec)

  local now = os.time()
  local removed = {}
  local skipped = {}
  local errors = {}
  local pattern = noop_marker_prefix .. "*"
  for _, path in ipairs(vim.fn.globpath(cwd, pattern, false, true) or {}) do
    local name = vim.fn.fnamemodify(path, ":t")
    if name:sub(1, #noop_marker_prefix) == noop_marker_prefix then
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "file" then
        local mtime = stat.mtime and stat.mtime.sec or vim.fn.getftime(path)
        local age = now - (tonumber(mtime) or now)
        if age >= min_age_sec then
          local ok, err = pcall(vim.fn.delete, path)
          if ok and (err == 0 or err == nil) then
            table.insert(removed, name)
          else
            table.insert(errors, ("%s: %s"):format(name, tostring(err)))
          end
        else
          table.insert(skipped, name)
        end
      end
    end
  end

  local result = {
    cwd = cwd,
    min_age_sec = min_age_sec,
    removed = removed,
    skipped = skipped,
    errors = errors,
  }
  M.debug_log("cleanup_noop_markers", result)
  return result
end

local function setup_cleanup_autocmd()
  cleanup_augroup = vim.api.nvim_create_augroup("CodexNvimNativeApplyPatchHook", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = cleanup_augroup,
    callback = function()
      cleanup_stale_noop_markers(config.cwd())
    end,
  })
end

function M.setup()
  if not enabled() then
    M.debug_log("setup_skipped", { edit_mode = config.edit_mode() })
    return true
  end
  local address, err = ensure_server_address()
  if not address then
    M.debug_log("setup_failed", { error = err })
    return nil, "failed to start Neovim RPC server for apply_patch hook: " .. tostring(err)
  end
  ensure_nonce()
  ensure_nvim_bin()
  cleanup_stale_noop_markers(config.cwd())
  setup_cleanup_autocmd()
  M.debug_log("setup_ready", {
    address = server_address,
    nvim_bin = nvim_bin,
    nonce_len = nonce and #nonce or 0,
  })
  return true
end

local function hook_config_arg()
  local opts = edit_opts()
  local timeout = tonumber(opts.timeout_sec or opts.timeout or 600) or 600
  local status = opts.status_message or "Reviewing patch in Neovim"
  return table.concat({
    "hooks.PreToolUse=[{matcher=",
    toml_quote("^apply_patch$"),
    ",hooks=[{type=",
    toml_quote("command"),
    ",command=",
    toml_quote(hook_command()),
    ",timeout=",
    tostring(timeout),
    ",statusMessage=",
    toml_quote(status),
    "}]}]",
  })
end

local function command_with_hook(command)
  local hook_arg = hook_config_arg()
  if type(command) == "string" then
    return command .. " -c " .. shell_quote(hook_arg)
  end
  local out = {}
  local inserted = false
  for index, part in ipairs(command or {}) do
    table.insert(out, part)
    if not inserted and index >= 2 and part == "app-server" then
      table.insert(out, "-c")
      table.insert(out, hook_arg)
      inserted = true
    end
  end
  if not inserted then
    table.insert(out, "-c")
    table.insert(out, hook_arg)
  end
  return out
end

local function quoted_key_path_segment(value)
  return toml_quote(value)
end

local function native_hook_matches(hook)
  return type(hook) == "table"
    and hook.enabled ~= false
    and hook.handlerType == "command"
    and hook.eventName == "preToolUse"
    and hook.matcher == "^apply_patch$"
    and hook.command == hook_command()
    and type(hook.key) == "string"
    and hook.key ~= ""
    and type(hook.currentHash) == "string"
    and hook.currentHash ~= ""
end

local function trust_edit_for_hook(hook)
  return {
    keyPath = "hooks.state." .. quoted_key_path_segment(hook.key) .. ".trusted_hash",
    mergeStrategy = "upsert",
    value = hook.currentHash,
  }
end

function M.prepare_app_server(command, env)
  if not enabled() then
    return command, env
  end
  local ok, err = M.setup()
  if not ok then
    return nil, nil, err
  end
  local address = ensure_server_address()
  local command_nonce = ensure_nonce()
  local command_nvim_bin = ensure_nvim_bin()
  if not address then
    return nil, nil, "failed to start Neovim RPC server for apply_patch hook: " .. tostring(err)
  end
  env = env or {}
  env.CODEX_NVIM_LISTEN_ADDRESS = address
  env.CODEX_NVIM_HOOK_NONCE = command_nonce
  env.CODEX_NVIM_BIN = command_nvim_bin
  local debug_path = debug_log_path()
  if debug_path then
    env.CODEX_NVIM_APPLY_PATCH_DEBUG_LOG = debug_path
  end
  local prepared = command_with_hook(command)
  M.debug_log("prepare_app_server", {
    command = prepared,
    address = address,
    nvim_bin = command_nvim_bin,
    nonce_len = command_nonce and #command_nonce or 0,
    debug_log_path = debug_path,
  })
  return prepared, env
end

function M.enabled()
  return enabled()
end

function M.runtime_config()
  return nil
end

function M.hooks_list_params()
  return { cwds = { config.cwd() } }
end

function M.trust_edits_from_hooks_response(response)
  if not enabled() then
    return {}
  end
  local edits = {}
  local entries = type(response) == "table" and response.data or nil
  for _, entry in ipairs(entries or {}) do
    for _, hook in ipairs(type(entry) == "table" and entry.hooks or {}) do
      if native_hook_matches(hook) and hook.trustStatus ~= "trusted" and hook.trustStatus ~= "managed" then
        table.insert(edits, trust_edit_for_hook(hook))
      end
    end
  end
  return edits
end

function M.has_matching_hook(response)
  local entries = type(response) == "table" and response.data or nil
  for _, entry in ipairs(entries or {}) do
    for _, hook in ipairs(type(entry) == "table" and entry.hooks or {}) do
      if native_hook_matches(hook) then
        return true
      end
    end
  end
  return false
end

local function read_payload(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "failed to read hook payload: " .. tostring(lines)
  end
  local ok_decode, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(payload) ~= "table" then
    return nil, "failed to decode hook payload: " .. tostring(payload)
  end
  return payload
end

local function hook_output(decision)
  return vim.json.encode({
    hookSpecificOutput = vim.tbl_extend("force", {
      hookEventName = "PreToolUse",
    }, decision),
  })
end

local function allow_output(patch)
  local output = {
    permissionDecision = "allow",
    updatedInput = {
      command = patch,
    },
  }
  return hook_output(output)
end

local function allow_output_with_context(patch, additional_context)
  local output = {
    permissionDecision = "allow",
    updatedInput = {
      command = patch,
    },
  }
  if type(additional_context) == "string" and util.trim(additional_context) ~= "" then
    output.additionalContext = additional_context
  end
  return hook_output(output)
end

local function deny_output(reason)
  return hook_output({
    permissionDecision = "deny",
    permissionDecisionReason = reason or "Patch rejected in Neovim.",
  })
end

local function tool_item_id(payload)
  return util.value(payload.tool_use_id)
    or util.value(payload.toolUseId)
    or util.value(payload.tool_call_id)
    or util.value(payload.toolCallId)
    or util.value(payload.call_id)
    or util.value(payload.callId)
    or util.value(payload.id)
end

local function payload_thread_id(payload)
  local state = require("codex.state")
  for _, candidate in ipairs({
    util.value(payload.thread_id),
    util.value(payload.threadId),
    util.value(payload.conversation_id),
    util.value(payload.conversationId),
    util.value(payload.session_id),
    util.value(payload.sessionId),
  }) do
    if candidate and state.get_thread(candidate) then
      return candidate
    end
  end
  return state.active_thread_id
end

local function approval_item_id(params)
  params = type(params) == "table" and params or {}
  local item_id = util.value(params.itemId)
    or util.value(params.item_id)
    or util.value(params.toolUseId)
    or util.value(params.tool_use_id)
    or util.value(params.toolCallId)
    or util.value(params.tool_call_id)
    or util.value(params.callId)
    or util.value(params.call_id)
    or util.value(params.id)
  if item_id then
    return item_id
  end
  for _, key in ipairs({ "item", "tool", "toolUse", "tool_use", "toolCall", "tool_call", "request" }) do
    local nested = util.value(params[key])
    if type(nested) == "table" then
      item_id = util.value(nested.itemId)
        or util.value(nested.item_id)
        or util.value(nested.toolUseId)
        or util.value(nested.tool_use_id)
        or util.value(nested.toolCallId)
        or util.value(nested.tool_call_id)
        or util.value(nested.callId)
        or util.value(nested.call_id)
        or util.value(nested.id)
      if item_id then
        return item_id
      end
    end
  end
  return nil
end

local function reviewed_record(record)
  if type(record) == "table" then
    record.approvals = type(record.approvals) == "table" and record.approvals or {}
    return record
  end
  return {
    approvals = {},
    created_at = util.now_ms(),
  }
end

function M.mark_reviewed(item_id)
  item_id = util.value(item_id)
  if item_id and item_id ~= "" then
    reviewed_items[tostring(item_id)] = reviewed_record()
    M.debug_log("mark_reviewed", {
      item_id = tostring(item_id),
      reviewed_items = vim.tbl_keys(reviewed_items),
    })
  else
    M.debug_log("mark_reviewed_skipped", { item_id = item_id })
  end
end

function M.consume_reviewed_item(item_id, approval_kind)
  item_id = util.value(item_id)
  if not item_id or item_id == "" then
    M.debug_log("consume_reviewed_item_missing_id", {
      approval_kind = approval_kind,
      reviewed_items = vim.tbl_keys(reviewed_items),
    })
    return false
  end
  item_id = tostring(item_id)
  local record = reviewed_items[item_id]
  if record ~= true and type(record) ~= "table" then
    M.debug_log("consume_reviewed_item_miss", {
      item_id = item_id,
      approval_kind = approval_kind,
      reviewed_items = vim.tbl_keys(reviewed_items),
    })
    return false
  end
  approval_kind = tostring(util.value(approval_kind) or "file_change")
  record = reviewed_record(record)
  record.approvals[approval_kind] = true
  if approval_kind == "file_change" then
    reviewed_items[item_id] = nil
  else
    reviewed_items[item_id] = record
  end
  M.debug_log("consume_reviewed_item_hit", {
    item_id = item_id,
    approval_kind = approval_kind,
    approvals = record.approvals,
    reviewed_items = vim.tbl_keys(reviewed_items),
  })
  return true
end

function M.consume_reviewed_approval(params, approval_kind)
  params = params or {}
  local item_id = approval_item_id(params)
  M.debug_log("consume_reviewed_approval", {
    item_id = item_id,
    approval_kind = approval_kind,
    params = params,
  })
  return M.consume_reviewed_item(item_id, approval_kind)
end

local function patch_from_payload(payload)
  local tool_input = type(payload.tool_input) == "table" and payload.tool_input or {}
  local patch = tool_input.command or tool_input.patch or payload.command or payload.patch
  if type(patch) ~= "string" or util.trim(patch) == "" then
    return nil, "apply_patch hook payload did not include tool_input.command"
  end
  return patch
end

local function validate_patch(cwd, patch)
  local changes, err = require("codex.dynamic_tools")._changes_from_native_apply_patch(cwd, patch, {
    allow_absolute = true,
  })
  if not changes then
    return nil, err
  end
  return changes
end

local function stale_context_for_patch(cwd, patch)
  local ok, dynamic_tools = pcall(require, "codex.dynamic_tools")
  if not ok or type(dynamic_tools._stale_context_for_patch) ~= "function" then
    return ""
  end
  return "\n\n" .. dynamic_tools._stale_context_for_patch(cwd, patch, { allow_absolute = true })
end

local function stale_context_from_changes(cwd, changes)
  local ok, dynamic_tools = pcall(require, "codex.dynamic_tools")
  if not ok or type(dynamic_tools._stale_context_from_changes) ~= "function" then
    return ""
  end
  return "\n\n" .. dynamic_tools._stale_context_from_changes(cwd, changes, { allow_absolute = true })
end

local function noop_patch_path(cwd, item_id)
  local seed = vim.fn.sha256(tostring(item_id or vim.uv.hrtime())):sub(1, 12)
  for index = 0, 100 do
    local suffix = index == 0 and "" or ("-" .. tostring(index))
    local relative = noop_marker_prefix .. seed .. suffix
    local absolute = vim.fs.joinpath(cwd, relative)
    if vim.fn.filereadable(absolute) == 0 and vim.fn.isdirectory(absolute) == 0 then
      return relative
    end
  end
  return noop_marker_prefix .. tostring(vim.uv.hrtime())
end

local function noop_patch(cwd, item_id)
  local path = noop_patch_path(cwd, item_id)
  local absolute = vim.fs.joinpath(cwd, path)
  local ok, err = pcall(vim.fn.writefile, {
    "codex.nvim native apply_patch completion marker",
  }, absolute)
  if not ok then
    return nil, "failed to create native apply_patch completion marker " .. path .. ": " .. tostring(err)
  end
  return table.concat({
    "*** Begin Patch",
    "*** Delete File: " .. path,
    "*** End Patch",
  }, "\n")
end

local function review_context(summary, session_result)
  local lines = {
    "User reviewed Codex native apply_patch in Neovim.",
  }
  if session_result and (tonumber(session_result.rejected_hunks or 0) or 0) > 0 then
    table.insert(lines, "Some hunks were rejected; review the user rejection feedback before planning follow-up edits.")
  end
  if type(summary) == "string" and util.trim(summary) ~= "" then
    table.insert(lines, "")
    table.insert(lines, summary)
  end
  return table.concat(lines, "\n")
end

local function rejection_context(summary)
  local lines = {
    "User rejected Codex native apply_patch in Neovim.",
  }
  if type(summary) == "string" and util.trim(summary) ~= "" then
    table.insert(lines, "")
    table.insert(lines, summary)
  end
  return table.concat(lines, "\n")
end

local function finish_session_review(payload, patch, changes, done)
  local cwd = util.value(payload.cwd) or config.cwd()
  local item_id = tool_item_id(payload)
  cleanup_stale_noop_markers(cwd)
  local session, err = require("codex.patch_session").open({
    request_id = item_id or tostring(vim.uv.hrtime()),
    thread_id = payload_thread_id(payload),
    cwd = cwd,
    changes = changes,
    on_complete = function(summary, success, session_result)
      M.debug_log("patch_session_finished", {
        item_id = item_id,
        success = success,
        force_failure = session_result and session_result.force_failure,
        rejected_hunks = session_result and session_result.rejected_hunks,
        write_ok = session_result and session_result.write_ok,
        write_error = session_result and session_result.write_error,
      })
      local accepted_hunks = tonumber(session_result and session_result.accepted_hunks or 0) or 0
      local rejected_hunks = tonumber(session_result and session_result.rejected_hunks or 0) or 0
      if session_result and session_result.force_failure then
        done(deny_output(rejection_context(summary)))
        return
      end
      if session_result and session_result.write_ok == false then
        done(deny_output("Neovim apply_patch write failed.\n\n" .. tostring(summary or "")))
        return
      end
      if accepted_hunks == 0 and rejected_hunks > 0 then
        done(deny_output(rejection_context(summary)))
        return
      end

      local completion_patch, completion_err = noop_patch(cwd, item_id)
      if not completion_patch then
        done(
          deny_output("Neovim apply_patch completed, but completion marker setup failed: " .. tostring(completion_err))
        )
        return
      end
      local verified, verify_err = validate_patch(cwd, completion_patch)
      if not verified then
        done(
          deny_output(
            "Neovim apply_patch completed, but the native completion patch did not validate: " .. tostring(verify_err)
          )
        )
        return
      end

      M.debug_log("patch_session_allow", {
        item_id = item_id,
        patch_len = #completion_patch,
        patch_sha256 = vim.fn.sha256(completion_patch),
        changes = verified,
        partial = not success,
      })
      M.mark_reviewed(item_id)
      done(allow_output_with_context(completion_patch, review_context(summary, session_result)))
    end,
  })
  if not session then
    M.debug_log("patch_session_open_failed", {
      item_id = item_id,
      error = err,
      patch_len = #patch,
    })
    done(
      deny_output(
        "Neovim apply_patch review could not be opened: " .. tostring(err) .. stale_context_from_changes(cwd, changes)
      )
    )
  end
end

function M.review_payload(payload)
  local patch, err = patch_from_payload(payload)
  if not patch then
    M.debug_log("review_payload_missing_patch", { error = err, payload = payload })
    return deny_output(err)
  end
  M.debug_log("review_payload", {
    tool_name = util.value(payload.tool_name),
    item_id = tool_item_id(payload),
    tool_use_id = util.value(payload.tool_use_id),
    call_id = util.value(payload.call_id),
    id = util.value(payload.id),
    cwd = util.value(payload.cwd) or config.cwd(),
    patch_len = #patch,
    patch_sha256 = vim.fn.sha256(patch),
  })
  if util.value(payload.tool_name) ~= "apply_patch" then
    M.debug_log("review_payload_unsupported_tool", { tool_name = util.value(payload.tool_name) })
    return deny_output("codex.nvim native apply_patch hook received unsupported tool: " .. tostring(payload.tool_name))
  end
  local cwd = util.value(payload.cwd) or config.cwd()
  local changes
  changes, err = validate_patch(cwd, patch)
  M.debug_log("review_payload_validated", {
    item_id = tool_item_id(payload),
    changes = changes,
    validation_error = changes and nil or err,
  })
  if not changes then
    return deny_output(
      "Codex native apply_patch did not validate before Neovim review: "
        .. tostring(err)
        .. stale_context_for_patch(cwd, patch)
    )
  end

  local result = nil
  vim.schedule(function()
    finish_session_review(payload, patch, changes, function(output)
      result = output
    end)
  end)
  local timeout = (tonumber(edit_opts().timeout_sec or edit_opts().timeout or 600) or 600) * 1000
  local ok = vim.wait(timeout, function()
    return result ~= nil
  end, 50)
  if not ok then
    M.debug_log("review_timeout", {
      item_id = tool_item_id(payload),
      timeout_ms = timeout,
    })
    return deny_output("Timed out waiting for Neovim apply_patch review.")
  end
  return result
end

local function write_result(path, output)
  if type(path) ~= "string" or path == "" then
    M.debug_log("write_result_missing_path", { output = output })
    return false
  end
  local ok, err = pcall(vim.fn.writefile, { output }, path)
  if not ok then
    M.debug_log("write_result_failed", {
      path = path,
      error = err,
    })
    return false
  end
  M.debug_log("write_result_done", {
    path = path,
    bytes = #tostring(output or ""),
  })
  return true
end

function M.review_payload_async(payload, done)
  done = type(done) == "function" and done or function() end
  local patch, err = patch_from_payload(payload)
  if not patch then
    M.debug_log("review_payload_missing_patch", { error = err, payload = payload })
    done(deny_output(err))
    return
  end
  M.debug_log("review_payload_async", {
    tool_name = util.value(payload.tool_name),
    item_id = tool_item_id(payload),
    tool_use_id = util.value(payload.tool_use_id),
    call_id = util.value(payload.call_id),
    id = util.value(payload.id),
    cwd = util.value(payload.cwd) or config.cwd(),
    patch_len = #patch,
    patch_sha256 = vim.fn.sha256(patch),
  })
  if util.value(payload.tool_name) ~= "apply_patch" then
    M.debug_log("review_payload_unsupported_tool", { tool_name = util.value(payload.tool_name) })
    done(deny_output("codex.nvim native apply_patch hook received unsupported tool: " .. tostring(payload.tool_name)))
    return
  end
  local cwd = util.value(payload.cwd) or config.cwd()
  local changes
  changes, err = validate_patch(cwd, patch)
  M.debug_log("review_payload_async_validated", {
    item_id = tool_item_id(payload),
    changes = changes,
    validation_error = changes and nil or err,
  })
  if not changes then
    done(deny_output("Codex native apply_patch did not validate before Neovim review: " .. tostring(err)))
    return
  end
  vim.schedule(function()
    finish_session_review(payload, patch, changes, done)
  end)
end

function M.review_file_async(args)
  args = type(args) == "table" and args or { payload = args }
  local result_path = args.result
  M.debug_log("review_file_async", {
    payload_path = args.payload,
    result_path = result_path,
    nonce_len = args.nonce and #tostring(args.nonce) or 0,
    expected_nonce_len = nonce and #nonce or 0,
    nonce_matches = not nonce or args.nonce == nonce,
  })
  local function finish(output)
    write_result(result_path, output)
  end
  if nonce and args.nonce ~= nonce then
    M.debug_log("review_file_async_invalid_nonce", {
      payload_path = args.payload,
      nonce_len = args.nonce and #tostring(args.nonce) or 0,
      expected_nonce_len = #nonce,
    })
    finish(deny_output("Rejected apply_patch hook with invalid Neovim nonce."))
    return "queued"
  end
  local payload, err = read_payload(args.payload)
  if not payload then
    M.debug_log("review_file_async_read_failed", { payload_path = args.payload, error = err })
    finish(deny_output(err))
    return "queued"
  end
  local ok, async_err = pcall(M.review_payload_async, payload, finish)
  if not ok then
    M.debug_log("review_file_async_failed", { payload_path = args.payload, error = async_err })
    finish(deny_output("Neovim apply_patch review failed: " .. tostring(async_err)))
  end
  return "queued"
end

function M.review_file(args)
  args = type(args) == "table" and args or { payload = args }
  M.debug_log("review_file", {
    payload_path = args.payload,
    nonce_len = args.nonce and #tostring(args.nonce) or 0,
    expected_nonce_len = nonce and #nonce or 0,
    nonce_matches = not nonce or args.nonce == nonce,
  })
  if nonce and args.nonce ~= nonce then
    M.debug_log("review_file_invalid_nonce", {
      payload_path = args.payload,
      nonce_len = args.nonce and #tostring(args.nonce) or 0,
      expected_nonce_len = #nonce,
    })
    return deny_output("Rejected apply_patch hook with invalid Neovim nonce.")
  end
  local payload, err = read_payload(args.payload)
  if not payload then
    M.debug_log("review_file_read_failed", { payload_path = args.payload, error = err })
    return deny_output(err)
  end
  local ok, result = pcall(M.review_payload, payload)
  if not ok then
    M.debug_log("review_file_failed", { payload_path = args.payload, error = result })
    return deny_output("Neovim apply_patch review failed: " .. tostring(result))
  end
  M.debug_log("review_file_done", {
    payload_path = args.payload,
    result = result,
  })
  return result
end

function M._hook_config_arg()
  return hook_config_arg()
end

function M._command_with_hook(command)
  return command_with_hook(command)
end

function M._reviewed_items()
  return reviewed_items
end

M._allow_output = allow_output
M._deny_output = deny_output
M._tool_item_id = tool_item_id
M._approval_item_id = approval_item_id
M._patch_from_payload = patch_from_payload
M._hook_command = hook_command
M._trust_edit_for_hook = trust_edit_for_hook
M._noop_patch = noop_patch
M._cleanup_stale_noop_markers = cleanup_stale_noop_markers

return M
