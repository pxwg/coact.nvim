local M = {}

local buffers = require("codex.buffers")
local config = require("codex.config")
local core = require("codex.core")
local parser = require("codex.parser")
local rpc = require("codex.rpc")
local state = require("codex.state")
local util = require("codex.util")

local did_setup = false

local function setup_once()
  if not did_setup then
    config.setup()
    core.setup()
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("CodexNvimLifecycle", { clear = true }),
      callback = function()
        rpc.stop()
      end,
    })
    did_setup = true
  end
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
          print(("%s  %s"):format(thread.id, thread.name or thread.preview or ""))
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
  return vim.tbl_keys(commands)
end

return M
