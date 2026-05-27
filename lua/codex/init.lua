local M = {}

local buffers = require("codex.buffers")
local config = require("codex.config")
local core = require("codex.core")
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

local function thread_start_params(opts)
  opts = opts or {}
  local cfg = config.get().thread
  local cwd = opts.cwd or config.cwd()
  return {
    model = opts.model or cfg.model,
    modelProvider = opts.model_provider or cfg.model_provider,
    serviceTier = opts.service_tier or cfg.service_tier,
    cwd = cwd,
    runtimeWorkspaceRoots = { cwd },
    approvalPolicy = opts.approval_policy or cfg.approval_policy,
    approvalsReviewer = opts.approvals_reviewer or cfg.approvals_reviewer,
    sandbox = opts.sandbox or cfg.sandbox,
    permissions = opts.permissions or cfg.permissions,
    baseInstructions = opts.base_instructions or cfg.base_instructions,
    developerInstructions = opts.developer_instructions or cfg.developer_instructions,
    personality = opts.personality or cfg.personality,
    ephemeral = opts.ephemeral ~= nil and opts.ephemeral or cfg.ephemeral,
    sessionStartSource = "startup",
    threadSource = "user",
    dynamicTools = require("codex.dynamic_tools").specs(),
    experimentalRawEvents = false,
    persistExtendedHistory = false,
  }
end

local function turn_start_params(thread_id, input)
  local cfg = config.get().thread
  return {
    threadId = thread_id,
    input = input,
    cwd = config.cwd(),
    runtimeWorkspaceRoots = { config.cwd() },
    approvalPolicy = cfg.approval_policy,
    approvalsReviewer = cfg.approvals_reviewer,
    model = cfg.model,
    serviceTier = cfg.service_tier,
  }
end

function M.setup(opts)
  config.setup(opts)
  core.setup()
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
  local input = parser.parse(text)
  if #input == 0 then
    return util.notify("prompt is empty", vim.log.levels.WARN)
  end
  ensure_server(function()
    thread_id = thread_id or state.active_thread_id
    if not thread_id then
      M.new_thread({ prompt = text })
      return
    end
    local thread = state.get_thread(thread_id)
    if thread then
      thread.pending_request = {
        prompt = text,
        input = input,
        created_at = util.now_ms(),
      }
      thread.generation = "submitted"
      thread.status_message = "Codex is thinking..."
      buffers.schedule_render(thread_id)
    end
    rpc.request("turn/start", turn_start_params(thread_id, input), function(err, result)
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
      state.add_turn(thread_id, result.turn)
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

function M.complete_command()
  local names = vim.tbl_keys(commands)
  table.sort(names)
  return names
end

return M
