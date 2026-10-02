local M = {}

local buffers = require("coact.buffers")
local config = require("coact.config")
local context = require("coact.context")
local core = require("coact.core")
local hooks = require("coact.hooks")
local parser = require("coact.parser")
local providers = require("coact.providers")
local rpc = require("coact.rpc")
local state = require("coact.state")
local util = require("coact.util")

local did_setup = false
local did_setup_lifecycle = false

local function count(tbl)
  local total = 0
  for _ in pairs(tbl or {}) do
    total = total + 1
  end
  return total
end

local function setup_lifecycle()
  if did_setup_lifecycle then
    return
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CoactNvimLifecycle", { clear = true }),
    callback = function()
      rpc.stop()
    end,
  })
  did_setup_lifecycle = true
end

local function setup_once()
  if not did_setup then
    config.setup()
    core.setup()
    context.setup()
    require("coact.native_apply_patch_hook").setup()
    require("coact.providers.pi_edit_bridge").setup()
    require("coact.behavior").setup()
    did_setup = true
  end
  setup_lifecycle()
end

local function ensure_server(callback)
  setup_once()
  rpc.start(config.bind(function(err, result)
    if err then
      util.notify(providers.title() .. " provider failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    callback(result)
  end))
end

local function edit_tool_instruction()
  if not providers.is("codex") then
    return table.concat({
      "coact.nvim is connected through the " .. providers.title() .. " provider.",
      "Use the tools exposed by that provider runtime for workspace inspection and edits.",
      "coact.nvim will render provider events through its normalized thread, turn, message, and tool abstractions.",
    }, " ")
  end
  local mode = config.edit_mode()
  if mode == "yolo" then
    return table.concat({
      "coact.nvim edit mode is yolo.",
      "The nvim.apply_patch review tool is disabled and is not exposed in this mode.",
      "For workspace file edits, use the native apply_patch tool directly.",
      "Do not call nvim.apply_patch in yolo mode.",
    }, " ")
  end
  return table.concat({
    "coact.nvim edit mode is pair.",
    "When changing workspace files from coact.nvim, use the native apply_patch tool.",
    "coact.nvim registers a PreToolUse hook for native apply_patch that previews the patch in the affected Neovim file buffers before the native tool completes.",
    "The Neovim review applies accepted changed blocks through the same file-buffer write path as nvim.apply_patch, then lets native apply_patch complete with a no-op updatedInput.command.",
    "The Neovim review can approve the patch, apply a user-edited buffer state, partially apply accepted changed blocks, or reject it with a reason.",
    "Do not request dangerous approval or sandbox bypasses for file edits; coact.nvim approves apply_patch permission and file-change requests after Neovim review.",
    "Do not call nvim.apply_patch in pair mode; it is not exposed.",
  }, " ")
end

local function compose_developer_instructions(value)
  local instruction = edit_tool_instruction()
  if not instruction then
    return value
  end
  if value == nil or value == vim.NIL or value == "" then
    return instruction
  end
  if type(value) == "table" then
    return table.concat(value, "\n\n") .. "\n\n" .. instruction
  end
  return tostring(value) .. "\n\n" .. instruction
end

local function uuid_v4()
  local bytes = { string.byte(vim.uv.random(16), 1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  return table.concat({
    string.format("%02x%02x%02x%02x", unpack(bytes, 1, 4)),
    string.format("%02x%02x", unpack(bytes, 5, 6)),
    string.format("%02x%02x", unpack(bytes, 7, 8)),
    string.format("%02x%02x", unpack(bytes, 9, 10)),
    string.format("%02x%02x%02x%02x%02x%02x", unpack(bytes, 11, 16)),
  }, "-")
end

local function thread_start_params(opts)
  opts = opts or {}
  local cfg = config.get().thread
  local cwd = opts.cwd or config.cwd()
  local permissions = opts.permissions or cfg.permissions
  local params = {
    model = opts.model or cfg.model,
    modelProvider = opts.model_provider or cfg.model_provider,
    serviceTier = opts.service_tier or cfg.service_tier,
    cwd = cwd,
    runtimeWorkspaceRoots = { cwd },
    approvalPolicy = opts.approval_policy or cfg.approval_policy,
    approvalsReviewer = opts.approvals_reviewer or cfg.approvals_reviewer,
    sandbox = permissions and nil or (opts.sandbox or cfg.sandbox),
    permissions = permissions,
    baseInstructions = opts.base_instructions or cfg.base_instructions,
    developerInstructions = compose_developer_instructions(opts.developer_instructions or cfg.developer_instructions),
    personality = opts.personality or cfg.personality,
    ephemeral = opts.ephemeral ~= nil and opts.ephemeral or cfg.ephemeral,
    sessionStartSource = opts.session_start_source or "startup",
    threadSource = "user",
    dynamicTools = require("coact.dynamic_tools").specs(),
    experimentalRawEvents = false,
    persistExtendedHistory = false,
  }
  if providers.is("pi") and opts.session_id then
    params.sessionId = opts.session_id
  end
  local hook_config = require("coact.native_apply_patch_hook").runtime_config()
  if hook_config then
    params.config = hook_config
  end
  return params
end

local function sandbox_policy(mode)
  return require("coact.slash")._sandbox_policy(mode)
end

local function turn_start_params(thread_id, input, opts)
  opts = opts or {}
  local cfg = config.get().thread
  local effective = state.effective_thread_settings(state.get_thread(thread_id), cfg)
  local params = {
    threadId = thread_id,
    input = input,
    cwd = config.cwd(),
    runtimeWorkspaceRoots = { config.cwd() },
    approvalPolicy = cfg.approval_policy,
    approvalsReviewer = cfg.approvals_reviewer,
    model = effective.model,
    serviceTier = effective.service_tier,
    effort = effective.reasoning_effort,
    summary = effective.reasoning_summary,
    personality = effective.personality,
  }
  local streaming_behavior = opts.streaming_behavior or opts.streamingBehavior
  if streaming_behavior == "steer" or streaming_behavior == "followUp" then
    params.streamingBehavior = streaming_behavior
  end
  if cfg.permissions then
    params.permissions = cfg.permissions
  else
    params.sandboxPolicy = sandbox_policy(cfg.sandbox)
  end
  local hook_config = require("coact.native_apply_patch_hook").runtime_config()
  if hook_config then
    params.config = hook_config
  end
  return params
end

local function turn_settings_from_params(params, thread)
  return {
    model = params.model or (thread and thread.config and thread.config.model),
    service_tier = params.serviceTier,
    reasoning_effort = params.effort,
  }
end

local busy_generations = {
  submitted = true,
  waiting_backend = true,
  streaming = true,
  summarizing = true,
  tool_running = true,
  patch_review = true,
  reconciling = true,
  cancelling = true,
}

local function submit_streaming_behavior(thread, opts)
  local requested = opts and (opts.streaming_behavior or opts.streamingBehavior)
  if requested == "steer" or requested == "followUp" then
    return requested
  end
  if not (providers.is("pi") or providers.current().supports_follow_up) or not thread then
    return nil
  end
  if thread.active_turn_id or busy_generations[thread.generation] then
    return "followUp"
  end
  for _, pending in ipairs(state.get_thread_pending_requests(thread)) do
    if type(pending) == "table" and (pending.streaming_behavior or pending.streamingBehavior) then
      return "followUp"
    end
  end
  return nil
end

function M.setup(opts)
  config.setup(opts)
  core.setup()
  context.setup()
  require("coact.native_apply_patch_hook").setup()
  require("coact.providers.pi_edit_bridge").setup()
  require("coact.behavior").setup()
  setup_lifecycle()
  did_setup = true
end

local function set_thread_open_state(thread, lifecycle, sync, message, err)
  if not thread then
    return
  end
  thread.lifecycle = lifecycle
  thread.sync = sync
  thread.sync_message = message
  thread.last_error = err and tostring(err.message or err) or nil
  if lifecycle == "starting" and sync == "starting" then
    thread.generation = "idle"
    thread.status_message = nil
    thread.active_turn_id = nil
  end
end

local function finish_open_thread(thread)
  set_thread_open_state(thread, "ready", "clean", nil, nil)
  if thread.winid and vim.api.nvim_win_is_valid(thread.winid) then
    buffers.render(thread.id)
    buffers.refresh_composer(thread)
  else
    buffers.open(thread.id)
  end
end

function M.new_thread(opts)
  opts = opts or {}
  setup_once()
  local current_buf = vim.api.nvim_get_current_buf()
  local source_bufnr = opts.source_bufnr
    or (context.is_coact_buffer(current_buf) and context.target_buffer() or current_buf)
  local source_winid = opts.source_winid or vim.api.nvim_get_current_win()
  if providers.is("pi") then
    setup_once()
    opts.session_id = opts.session_id or uuid_v4()
    local thread_id = "pi:" .. opts.session_id
    local thread = state.update_thread_from_payload({
      id = thread_id,
      cwd = opts.cwd or config.cwd(),
      status = "starting",
      name = "New Pi session",
      preview = "New Pi session",
      sessionId = opts.session_id,
    })
    set_thread_open_state(thread, "starting", "starting", "Starting Pi execution unit…")
    buffers.open(thread_id)
    context.capture_thread_buffer(thread, source_bufnr, source_winid)
    rpc.request("thread/start", thread_start_params(opts), function(err, result)
      if err then
        set_thread_open_state(thread, "failed", "failed", "Could not start Pi session", err)
        buffers.schedule_render(thread_id)
        util.notify("thread/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      thread = state.update_thread_from_payload(result.thread)
      finish_open_thread(thread)
      context.capture_thread_buffer(thread, source_bufnr, source_winid)
      if opts.prompt and opts.prompt ~= "" then
        M.submit_text(opts.prompt, thread.id)
      end
    end)
    return
  end
  ensure_server(function()
    rpc.request("thread/start", thread_start_params(opts), function(err, result)
      if err then
        util.notify("thread/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local thread = state.update_thread_from_payload(result.thread)
      buffers.open(thread.id)
      context.capture_thread_buffer(thread, source_bufnr, source_winid)
      if opts.prompt and opts.prompt ~= "" then
        M.submit_text(opts.prompt, thread.id)
      end
    end)
  end)
end

function M.open(thread_id)
  if not thread_id or thread_id == "" then
    thread_id = state.active_thread_id
  end
  if not thread_id then
    M.new_thread()
    return
  end
  local existing = state.get_thread(thread_id)
  if existing and (providers.current().transport_scope ~= "thread" or rpc.is_running(thread_id)) then
    buffers.open(thread_id)
    return
  end
  ensure_server(function()
    rpc.request("thread/read", { threadId = thread_id, includeTurns = true }, function(err, result)
      if err then
        util.notify("thread/read failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local thread = state.update_thread_from_payload(result.thread)
      buffers.open(thread.id)
    end)
  end)
end

function M.resume(thread_id, opts)
  opts = opts or {}
  local current_buf = vim.api.nvim_get_current_buf()
  local source_bufnr = opts.source_bufnr
    or (context.is_coact_buffer(current_buf) and context.target_buffer() or current_buf)
  local source_winid = opts.source_winid or vim.api.nvim_get_current_win()
  if not thread_id or thread_id == "" then
    return util.notify("usage: :Coact resume <thread-id>", vim.log.levels.WARN)
  end
  local existing = state.get_thread(thread_id)
  if
    existing
    and existing.bufnr
    and vim.api.nvim_buf_is_valid(existing.bufnr)
    and (providers.current().transport_scope ~= "thread" or rpc.is_running(thread_id))
  then
    buffers.open(thread_id)
    context.capture_thread_buffer(existing, source_bufnr, source_winid)
    return
  end
  local function request_resume()
    rpc.request(
      "thread/resume",
      { threadId = thread_id, excludeTurns = false, persistExtendedHistory = false },
      function(err, result)
        local thread = state.get_thread(thread_id)
        if err then
          set_thread_open_state(
            thread,
            "failed",
            "failed",
            "Could not restore " .. providers.title() .. " session",
            err
          )
          if thread and thread.bufnr then
            buffers.schedule_render(thread_id)
          end
          util.notify("thread/resume failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          return
        end
        thread = state.update_thread_from_payload(result.thread)
        finish_open_thread(thread)
        context.capture_thread_buffer(thread, source_bufnr, source_winid)
      end
    )
  end
  if providers.is("pi") then
    setup_once()
    local payload = type(opts.thread) == "table" and vim.deepcopy(opts.thread) or { id = thread_id }
    payload.id = thread_id
    payload.cwd = util.value(payload.cwd) or config.cwd()
    payload.status = "starting"
    local thread = state.update_thread_from_payload(payload)
    set_thread_open_state(thread, "starting", "starting", "Starting Pi execution unit…")
    buffers.open(thread_id)
    context.capture_thread_buffer(thread, source_bufnr, source_winid)
    request_resume()
    return
  end
  ensure_server(request_resume)
end

function M.submit_text(text, thread_id, opts)
  opts = opts or {}
  if
    require("coact.slash").dispatch(text, thread_id, {
      ensure_server = ensure_server,
      new_thread = M.new_thread,
      resume = M.resume,
      pick_thread = M.pick_thread,
      show_status = M.show_status,
      set_statusline_visible = M.set_statusline_visible,
      toggle_statusline = M.toggle_statusline,
      stop = M.stop,
    })
  then
    return
  end
  thread_id = thread_id or state.active_thread_id
  local thread = thread_id and state.get_thread(thread_id) or nil
  local input = parser.parse(text, { thread = thread })
  if #input == 0 then
    return util.notify("prompt is empty", vim.log.levels.WARN)
  end
  if thread_id then
    require("coact.behavior").anchor(thread_id, { reason = "submit" })
  end
  ensure_server(function()
    if not thread_id then
      M.new_thread({ prompt = text })
      return
    end
    thread = state.get_thread(thread_id)
    local streaming_behavior = submit_streaming_behavior(thread, opts)
    local params = turn_start_params(thread_id, input, { streaming_behavior = streaming_behavior })
    local pending_request
    if thread then
      local settings = turn_settings_from_params(params, thread)
      pending_request = {
        prompt = text,
        input = input,
        created_at = util.now_ms(),
        settings = settings,
        streaming_behavior = streaming_behavior,
        previous_generation = thread.generation,
        previous_status_message = thread.status_message,
      }
      state.add_thread_pending_request(thread, pending_request)
      if streaming_behavior then
        if not busy_generations[thread.generation] then
          thread.generation = "submitted"
        end
        thread.status_message = providers.agent_label() .. " queued a follow-up..."
      else
        thread.generation = "submitted"
        thread.status_message = providers.agent_label() .. " is thinking..."
      end
      buffers.schedule_render(thread_id)
    end
    rpc.request("turn/start", params, function(err, result)
      if err then
        local failed_thread = state.get_thread(thread_id)
        if failed_thread then
          failed_thread.last_error = tostring(err.message or err)
          if pending_request then
            state.remove_thread_pending_request(failed_thread, pending_request)
          end
          if #state.get_thread_pending_requests(failed_thread) == 0 then
            if streaming_behavior then
              local queued_status = providers.agent_label() .. " queued a follow-up..."
              if failed_thread.status_message == queued_status then
                failed_thread.generation = pending_request.previous_generation or failed_thread.generation
                failed_thread.status_message = pending_request.previous_status_message
              end
            elseif failed_thread.active_turn_id and pending_request then
              -- A backend may reject an overlapping submission while its
              -- existing turn (including compaction) is still running.
              failed_thread.generation = pending_request.previous_generation
              failed_thread.status_message = pending_request.previous_status_message
            else
              failed_thread.generation = "idle"
              failed_thread.status_message = nil
            end
          end
          buffers.schedule_render(thread_id)
        end
        if type(opts.on_error) == "function" then
          opts.on_error(err)
        end
        util.notify("turn/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local turn = type(result) == "table" and result.turn or nil
      if type(turn) ~= "table" then
        return util.notify("turn/start returned no turn", vim.log.levels.ERROR)
      end
      state.add_turn(thread_id, turn)
      local submitted_thread = state.get_thread(thread_id)
      if turn.id and pending_request then
        state.set_turn_settings(thread_id, turn.id, pending_request.settings)
      end
      if
        submitted_thread
        and turn.id
        and pending_request
        and state.has_thread_pending_request(submitted_thread, pending_request)
      then
        pending_request.turn_id = turn.id
      end
      if type(opts.on_success) == "function" then
        opts.on_success(turn)
      end
      buffers.schedule_render(thread_id)
    end)
  end)
end

function M.submit()
  local bufnr = vim.api.nvim_get_current_buf()
  local thread_id = buffers.get_thread_id(bufnr)
  local text = buffers.collect_prompt(bufnr)
  if text == "" then
    return util.notify("prompt is empty", vim.log.levels.WARN)
  end
  local thread = state.get_thread(thread_id)
  if thread then
    require("coact.ui.render").prepare_submit_follow(thread, thread.winid or vim.api.nvim_get_current_win())
  end
  local snapshot = buffers.snapshot_prompt(bufnr)
  buffers.clear_prompt(bufnr)
  if thread then
    buffers.enter_preview(thread, { focus = true, follow_latest = true })
  end
  M.submit_text(text, thread_id, {
    on_error = function()
      buffers.restore_prompt(bufnr, snapshot)
    end,
  })
end

function M.stop()
  local thread_id = buffers.get_thread_id() or state.active_thread_id
  local thread = state.get_thread(thread_id)
  if not thread or not thread.active_turn_id then
    return util.notify("no running " .. providers.title() .. " turn", vim.log.levels.WARN)
  end
  rpc.request("turn/interrupt", { threadId = thread_id, turnId = thread.active_turn_id }, function(err)
    if err then
      util.notify("turn/interrupt failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
    end
  end)
end

function M.list_threads(callback)
  local function request_list()
    rpc.request("thread/list", {
      limit = 50,
      sortKey = "updated_at",
      sortDirection = "desc",
      archived = false,
      cwd = config.cwd(),
    }, function(err, result)
      if err then
        util.notify("thread/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      if callback then
        callback(result.data or {})
      else
        for _, thread in ipairs(result.data or {}) do
          print(
            ("%s  %s"):format(
              tostring(util.value(thread.id) or ""),
              util.value(thread.name) or util.value(thread.preview) or ""
            )
          )
        end
      end
    end)
  end
  setup_once()
  if providers.current().thread_list_requires_transport == false then
    request_list()
  else
    ensure_server(request_list)
  end
end

function M.pick_thread()
  setup_once()
  require("coact.pickers").threads()
end

function M.pick_adapter(opts)
  setup_once()
  require("coact.pickers").adapters(opts)
end

function M.health()
  ensure_server(function()
    util.notify(providers.title() .. " provider is running")
  end)
end

function M.status()
  setup_once()
  local current_thread = state.thread_for_buf(0)
  local active_thread = state.get_thread(state.active_thread_id)
  local thread = current_thread or active_thread
  return {
    adapter = config.context().name,
    provider = providers.current_id(),
    provider_title = providers.title(),
    server_running = rpc.is_running(thread and thread.id or nil),
    server_initialized = rpc.is_initialized(thread and thread.id or nil),
    provider_clients = rpc.client_count(),
    pending_rpc_requests = rpc.pending_count(thread and thread.id or nil),
    pending_server_requests = count(state.pending_server_requests),
    current_thread_id = current_thread and current_thread.id or nil,
    active_thread_id = state.active_thread_id,
    thread_id = thread and thread.id or nil,
    title = thread and thread.title or nil,
    cwd = thread and thread.cwd or nil,
    status = thread and thread.status or nil,
    generation = thread and thread.generation or nil,
    lifecycle = thread and thread.lifecycle or nil,
    sync = thread and thread.sync or nil,
    active_turn_id = thread and thread.active_turn_id or nil,
    provider_client_id = thread and thread.provider_client_id or nil,
    status_message = thread and thread.status_message or nil,
    last_error = thread and thread.last_error or nil,
  }
end

function M.show_status()
  local status = M.status()
  local lines = {
    "adapter: " .. tostring(status.adapter),
    "provider: " .. tostring(status.provider),
    "server: " .. (status.server_running and "running" or "stopped"),
    "initialized: " .. tostring(status.server_initialized),
    "provider clients: " .. tostring(status.provider_clients or 0),
    "pending rpc: " .. tostring(status.pending_rpc_requests),
    "pending approvals: " .. tostring(status.pending_server_requests),
    "active thread: " .. tostring(status.active_thread_id or "none"),
  }
  if status.current_thread_id then
    table.insert(lines, "current thread: " .. tostring(status.current_thread_id))
  end
  if status.provider_client_id then
    table.insert(lines, "provider client: " .. tostring(status.provider_client_id))
  end
  if status.title then
    table.insert(lines, "title: " .. tostring(status.title))
  end
  if status.cwd then
    table.insert(lines, "cwd: " .. tostring(status.cwd))
  end
  if status.status then
    table.insert(lines, "status: " .. tostring(status.status))
  end
  if status.generation then
    table.insert(lines, "generation: " .. tostring(status.generation))
  end
  if status.status_message then
    table.insert(lines, "message: " .. tostring(status.status_message))
  end
  if status.last_error then
    table.insert(lines, "last error: " .. tostring(status.last_error))
  end
  util.notify(table.concat(lines, "\n"))
  return status
end

function M.set_statusline_visible(visible, thread_id)
  setup_once()
  local thread = state.get_thread(thread_id or buffers.get_thread_id() or state.active_thread_id)
  if not thread then
    util.notify("open a Coact thread before changing statusline visibility", vim.log.levels.WARN)
    return false
  end
  thread.composer_statusline_visible = visible == true
  buffers.render(thread.id)
  buffers.refresh_composer(thread)
  util.notify("Coact statusline " .. (thread.composer_statusline_visible and "shown" or "hidden"))
  return thread.composer_statusline_visible
end

function M.toggle_statusline(thread_id)
  setup_once()
  local thread = state.get_thread(thread_id or buffers.get_thread_id() or state.active_thread_id)
  if not thread then
    util.notify("open a Coact thread before changing statusline visibility", vim.log.levels.WARN)
    return false
  end
  local visible = require("coact.ui.statusline").visible(thread)
  return M.set_statusline_visible(not visible, thread.id)
end

function M.restart()
  rpc.stop()
  M.health()
end

function M.attach_buffer(bufnr)
  return buffers.attach(bufnr)
end

function M.attach_all_buffers()
  return buffers.attach_all()
end

function M.on(event, callback)
  return hooks.on(event, callback)
end

local function active_or_current_thread()
  return state.thread_for_buf(0) or state.get_thread(state.active_thread_id)
end

local function open_thread_for_prompt(thread)
  if not thread then
    util.notify("open a Coact thread before adding context", vim.log.levels.WARN)
    return nil
  end
  local bufnr = buffers.open(thread.id)
  return bufnr
end

local function append_prompt_context(line)
  local thread = active_or_current_thread()
  local bufnr = open_thread_for_prompt(thread)
  if not bufnr then
    return false
  end
  buffers.append_prompt_line(bufnr, line)
  return true
end

function M.add_current_buffer()
  setup_once()
  local thread = active_or_current_thread()
  local source_bufnr = state.thread_for_buf(0) and context.target_buffer(thread) or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(source_bufnr)
  if path == "" then
    return util.notify("current buffer has no file path", vim.log.levels.WARN)
  end
  append_prompt_context("@" .. context.display_path(path))
end

function M.add_selection()
  setup_once()
  local thread = active_or_current_thread()
  local source_bufnr = state.thread_for_buf(0) and context.target_buffer(thread) or vim.api.nvim_get_current_buf()
  if not context.selection_for_buffer(source_bufnr) then
    return util.notify("no remembered Visual selection found in the source buffer", vim.log.levels.WARN)
  end
  append_prompt_context("@selection")
end

local commands = {
  adapters = function()
    M.pick_adapter()
  end,
  new = function(args)
    M.pick_adapter({ action = "new", prompt = table.concat(args, " ") })
  end,
  open = function(args)
    M.open(args[1])
  end,
  resume = function(args)
    M.resume(args[1])
  end,
  pick = function()
    M.pick_adapter({ action = "pick" })
  end,
  list = function()
    M.list_threads()
  end,
  submit = function()
    M.submit()
  end,
  stop = function()
    M.stop()
  end,
  detail = function()
    require("coact.ui.detail").open()
  end,
  health = function()
    M.health()
  end,
  status = function()
    M.show_status()
  end,
  statusline = function(args)
    local action = args[1] or "toggle"
    if action == "show" or action == "on" then
      M.set_statusline_visible(true)
    elseif action == "hide" or action == "off" then
      M.set_statusline_visible(false)
    else
      M.toggle_statusline()
    end
  end,
  restart = function()
    M.restart()
  end,
  attach = function(args)
    local target = args[1]
    if target == "all" then
      local count = M.attach_all_buffers()
      util.notify(("attached %d Coact buffer%s"):format(count, count == 1 and "" or "s"))
      return
    end
    local bufnr = tonumber(target) or vim.api.nvim_get_current_buf()
    if not M.attach_buffer(bufnr) then
      util.notify("current buffer is not a Coact thread buffer", vim.log.levels.WARN)
    end
  end,
  ["add-buffer"] = function()
    M.add_current_buffer()
  end,
  ["add-selection"] = function()
    M.add_selection()
  end,
}

function M.command(opts)
  setup_once()
  local args = vim.split(opts.args or "", "%s+", { trimempty = true })
  local name = table.remove(args, 1) or "adapters"
  local command = commands[name]
  if not command then
    util.notify("unknown Coact command: " .. name, vim.log.levels.ERROR)
    return
  end
  command(args)
end

local function filtered(candidates, prefix)
  prefix = prefix or ""
  if prefix == "" then
    return candidates
  end
  local out = {}
  local lower = prefix:lower()
  for _, candidate in ipairs(candidates) do
    if tostring(candidate):lower():find("^" .. vim.pesc(lower)) then
      table.insert(out, candidate)
    end
  end
  return out
end

local function loaded_thread_ids()
  local ids = vim.tbl_keys(state.threads)
  table.sort(ids)
  return ids
end

local function coact_buffer_ids()
  local ids = { "all" }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[bufnr].coact_thread_id ~= nil then
      table.insert(ids, tostring(bufnr))
    end
  end
  table.sort(ids, function(a, b)
    if a == "all" then
      return true
    end
    if b == "all" then
      return false
    end
    return tonumber(a) < tonumber(b)
  end)
  return ids
end

local function command_args(line)
  local rest = (line or ""):gsub("^%s*%S+%s*", "", 1)
  return vim.split(rest, "%s+", { trimempty = true }), rest:match("%s$") ~= nil
end

function M.complete_command(arglead, line)
  if line == nil then
    line = arglead or ""
    arglead = nil
  end
  local args, trailing_space = command_args(line)
  local names = vim.tbl_keys(commands)
  table.sort(names)
  if #args == 0 or (#args == 1 and not trailing_space) then
    return filtered(names, arglead or args[1])
  end

  local command = args[1]
  local value_prefix = trailing_space and "" or (arglead or args[#args])
  if command == "attach" and #args <= 2 then
    return filtered(coact_buffer_ids(), value_prefix)
  end
  if command == "statusline" and #args <= 2 then
    return filtered({ "toggle", "show", "hide", "on", "off" }, value_prefix)
  end
  if (command == "open" or command == "resume") and #args <= 2 then
    return filtered(loaded_thread_ids(), value_prefix)
  end
  return {}
end

-- Public thread operations must keep their owner even when invoked from a
-- different buffer. RPC callbacks retain this scope across async boundaries.
for name, thread_arg in pairs({ open = 1, resume = 1, submit_text = 2 }) do
  local operation = M[name]
  M[name] = function(...)
    setup_once()
    local id = select(thread_arg, ...) or state.active_thread_id
    return config.with_context(config.thread_context(id) or config.context(), operation, ...)
  end
end
for _, name in ipairs({ "stop", "status", "health" }) do
  local operation = M[name]
  M[name] = function(...)
    setup_once()
    local id = buffers.get_thread_id() or state.active_thread_id
    return config.with_context(config.thread_context(id) or config.context(), operation, ...)
  end
end
local new_thread = M.new_thread
M.new_thread = function(opts)
  setup_once()
  local ctx = opts and opts.adapter and config.resolve_adapter(opts.adapter) or config.context()
  return config.with_context(ctx, new_thread, opts)
end

M._thread_start_params = thread_start_params
M._turn_start_params = turn_start_params
M._compose_developer_instructions = compose_developer_instructions

return M
