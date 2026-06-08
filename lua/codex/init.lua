local M = {}

local buffers = require("codex.buffers")
local config = require("codex.config")
local context = require("codex.context")
local core = require("codex.core")
local hooks = require("codex.hooks")
local parser = require("codex.parser")
local rpc = require("codex.rpc")
local state = require("codex.state")
local util = require("codex.util")

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
    group = vim.api.nvim_create_augroup("CodexNvimLifecycle", { clear = true }),
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
    require("codex.native_apply_patch_hook").setup()
    require("codex.behavior").setup()
    did_setup = true
  end
  setup_lifecycle()
end

local function ensure_server(callback)
  setup_once()
  rpc.start(function(err, result)
    if err then
      util.notify("codex app-server failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    callback(result)
  end)
end

local function edit_tool_instruction()
  local mode = config.edit_mode()
  if mode == "yolo" then
    return table.concat({
      "codex.nvim edit mode is yolo.",
      "The nvim.apply_patch review tool is disabled and is not exposed in this mode.",
      "For workspace file edits, use the native apply_patch tool directly.",
      "Do not call nvim.apply_patch in yolo mode.",
    }, " ")
  end
  return table.concat({
    "codex.nvim edit mode is pair.",
    "When changing workspace files from codex.nvim, use the native apply_patch tool.",
    "codex.nvim registers a PreToolUse hook for native apply_patch that previews the patch in the affected Neovim file buffers before the native tool completes.",
    "The Neovim review applies accepted changed blocks through the same file-buffer write path as nvim.apply_patch, then lets native apply_patch complete with a no-op updatedInput.command.",
    "The Neovim review can approve the patch, apply a user-edited buffer state, partially apply accepted changed blocks, or reject it with a reason.",
    "Do not request dangerous approval or sandbox bypasses for file edits; codex.nvim approves apply_patch permission and file-change requests after Neovim review.",
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
    dynamicTools = require("codex.dynamic_tools").specs(),
    experimentalRawEvents = false,
    persistExtendedHistory = false,
  }
  local hook_config = require("codex.native_apply_patch_hook").runtime_config()
  if hook_config then
    params.config = hook_config
  end
  return params
end

local function sandbox_policy(mode)
  return require("codex.slash")._sandbox_policy(mode)
end

local function turn_start_params(thread_id, input)
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
  if cfg.permissions then
    params.permissions = cfg.permissions
  else
    params.sandboxPolicy = sandbox_policy(cfg.sandbox)
  end
  local hook_config = require("codex.native_apply_patch_hook").runtime_config()
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

function M.setup(opts)
  config.setup(opts)
  core.setup()
  require("codex.native_apply_patch_hook").setup()
  require("codex.behavior").setup()
  setup_lifecycle()
  did_setup = true
end

function M.new_thread(opts)
  opts = opts or {}
  ensure_server(function()
    rpc.request("thread/start", thread_start_params(opts), function(err, result)
      if err then
        util.notify("thread/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local thread = state.update_thread_from_payload(result.thread)
      buffers.open(thread.id)
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
  if existing then
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

function M.resume(thread_id)
  if not thread_id or thread_id == "" then
    return util.notify("usage: :Codex resume <thread-id>", vim.log.levels.WARN)
  end
  ensure_server(function()
    rpc.request(
      "thread/resume",
      { threadId = thread_id, excludeTurns = false, persistExtendedHistory = false },
      function(err, result)
        if err then
          util.notify("thread/resume failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          return
        end
        local thread = state.update_thread_from_payload(result.thread)
        buffers.open(thread.id)
      end
    )
  end)
end

function M.submit_text(text, thread_id)
  if
    require("codex.slash").dispatch(text, thread_id, {
      ensure_server = ensure_server,
      new_thread = M.new_thread,
      resume = M.resume,
      pick_thread = M.pick_thread,
      show_status = M.show_status,
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
    require("codex.behavior").anchor(thread_id, { reason = "submit" })
  end
  ensure_server(function()
    if not thread_id then
      M.new_thread({ prompt = text })
      return
    end
    thread = state.get_thread(thread_id)
    local params = turn_start_params(thread_id, input)
    if thread then
      local settings = turn_settings_from_params(params, thread)
      thread.pending_request = {
        prompt = text,
        input = input,
        created_at = util.now_ms(),
        settings = settings,
      }
      thread.generation = "submitted"
      thread.status_message = "Codex is thinking..."
      buffers.schedule_render(thread_id)
    end
    rpc.request("turn/start", params, function(err, result)
      if err then
        local failed_thread = state.get_thread(thread_id)
        if failed_thread then
          failed_thread.last_error = tostring(err.message or err)
          failed_thread.pending_request = nil
          failed_thread.generation = "idle"
          buffers.schedule_render(thread_id)
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
      if submitted_thread and submitted_thread.pending_request and turn.id then
        submitted_thread.pending_request.turn_id = turn.id
        state.set_turn_settings(thread_id, turn.id, submitted_thread.pending_request.settings)
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
    require("codex.ui.render").prepare_submit_follow(thread, vim.api.nvim_get_current_win())
  end
  buffers.clear_prompt(bufnr)
  M.submit_text(text, thread_id)
end

function M.stop()
  local thread_id = buffers.get_thread_id() or state.active_thread_id
  local thread = state.get_thread(thread_id)
  if not thread or not thread.active_turn_id then
    return util.notify("no running Codex turn", vim.log.levels.WARN)
  end
  rpc.request("turn/interrupt", { threadId = thread_id, turnId = thread.active_turn_id }, function(err)
    if err then
      util.notify("turn/interrupt failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
    end
  end)
end

function M.list_threads(callback)
  ensure_server(function()
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
  end)
end

function M.pick_thread()
  require("codex.pickers").threads()
end

function M.health()
  ensure_server(function()
    util.notify("codex app-server is running")
  end)
end

function M.status()
  setup_once()
  local current_thread = state.thread_for_buf(0)
  local active_thread = state.get_thread(state.active_thread_id)
  local thread = current_thread or active_thread
  return {
    server_running = rpc.is_running(),
    server_initialized = rpc.initialized,
    pending_rpc_requests = count(rpc.pending),
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
    status_message = thread and thread.status_message or nil,
    last_error = thread and thread.last_error or nil,
  }
end

function M.show_status()
  local status = M.status()
  local lines = {
    "server: " .. (status.server_running and "running" or "stopped"),
    "initialized: " .. tostring(status.server_initialized),
    "pending rpc: " .. tostring(status.pending_rpc_requests),
    "pending approvals: " .. tostring(status.pending_server_requests),
    "active thread: " .. tostring(status.active_thread_id or "none"),
  }
  if status.current_thread_id then
    table.insert(lines, "current thread: " .. tostring(status.current_thread_id))
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
    util.notify("open a Codex thread before adding context", vim.log.levels.WARN)
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
    return util.notify("no visual selection found in the source buffer", vim.log.levels.WARN)
  end
  append_prompt_context("@selection")
end

local commands = {
  new = function(args)
    M.new_thread({ prompt = table.concat(args, " ") })
  end,
  open = function(args)
    M.open(args[1])
  end,
  resume = function(args)
    M.resume(args[1])
  end,
  pick = function()
    M.pick_thread()
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
    require("codex.ui.detail").open()
  end,
  health = function()
    M.health()
  end,
  status = function()
    M.show_status()
  end,
  restart = function()
    M.restart()
  end,
  attach = function(args)
    local target = args[1]
    if target == "all" then
      local count = M.attach_all_buffers()
      util.notify(("attached %d Codex buffer%s"):format(count, count == 1 and "" or "s"))
      return
    end
    local bufnr = tonumber(target) or vim.api.nvim_get_current_buf()
    if not M.attach_buffer(bufnr) then
      util.notify("current buffer is not a Codex thread buffer", vim.log.levels.WARN)
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
  local name = table.remove(args, 1) or "open"
  local command = commands[name]
  if not command then
    util.notify("unknown Codex command: " .. name, vim.log.levels.ERROR)
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

local function codex_buffer_ids()
  local ids = { "all" }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[bufnr].codex_thread_id ~= nil then
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
    return filtered(codex_buffer_ids(), value_prefix)
  end
  if (command == "open" or command == "resume") and #args <= 2 then
    return filtered(loaded_thread_ids(), value_prefix)
  end
  return {}
end

M._thread_start_params = thread_start_params
M._turn_start_params = turn_start_params
M._compose_developer_instructions = compose_developer_instructions

return M
