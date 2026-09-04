local config = require("coact.config")
local util = require("coact.util")

local M = {
  name = "pi",
  title = "Pi",
  agent_label = "Pi",
  protocol = "pi-rpc",
  transport_scope = "thread",
  thread_list_requires_transport = false,
  slash = {
    commands = {
      behavior = true,
      clear = true,
      compact = true,
      copy = true,
      diff = true,
      help = true,
      model = true,
      new = true,
      raw = true,
      reasoning = true,
      settings = true,
      skills = true,
      status = true,
      statusline = true,
      stop = true,
      tree = true,
    },
    reasoning_label = "thinking",
    reasoning_effort_title = "thinking level",
    load_reasoning_efforts = function(rpc, callback, thread_id)
      rpc.request("get_available_thinking_levels", { threadId = thread_id }, function(err, result)
        if err then
          callback(err, nil)
          return
        end
        local choices = {}
        for _, level in ipairs(type(result) == "table" and result.levels or {}) do
          level = util.value(level)
          if type(level) == "string" and level ~= "" then
            table.insert(choices, { label = level, value = level })
          end
        end
        callback(nil, choices)
      end)
    end,
    reasoning_summaries = false,
    return_forms = {
      reasoning = "select(get_available_thinking_levels) -> notify(set_thinking_level)",
      skills = "select(get_commands source=skill) -> insert($skill:<name>)",
      status = "page(get_state + get_session_stats + local thread status)",
      tree = "select(Pi session tree) -> reveal locally or notify(thread/tree) -> refresh thread",
    },
  },
}

local request_session_stats
local tree_summary_status_key = "coact.nvim.tree-summary"

local function new_runtime()
  return {
    client_id = nil,
    bound_thread_id = nil,
    suppress_state_updates = false,
    session_id = nil,
    session_file = nil,
    session_name = nil,
    current_thread_id = nil,
    active_turn_id = nil,
    last_turn_id = nil,
    turn_seq = 0,
    provider_ui = nil,
    branch_snapshot = nil,
    last_tree_action = nil,
    reserved_turn = nil,
    turn_start_pending = false,
    queued_turns = {},
    user_item_seq = 0,
    tool_output = {},
    tool_args = {},
    tool_calls = {},
  }
end

local default_runtime = new_runtime()
local active_runtime = nil
local runtime = setmetatable({}, {
  __index = function(_, key)
    return (active_runtime or default_runtime)[key]
  end,
  __newindex = function(_, key, value)
    (active_runtime or default_runtime)[key] = value
  end,
})

local unpack_values = table.unpack or unpack

local function pack_values(...)
  return { n = select("#", ...), ... }
end

function M.new_runtime()
  return new_runtime()
end

function M.with_runtime(target, callback, ...)
  target = target or default_runtime
  local previous = active_runtime
  local args = pack_values(...)
  active_runtime = target
  local results = pack_values(pcall(function()
    return callback(unpack_values(args, 1, args.n))
  end))
  active_runtime = previous
  if not results[1] then
    error(results[2], 0)
  end
  return unpack_values(results, 2, results.n)
end

local function bind_runtime_callback(callback)
  local captured = active_runtime or default_runtime
  return function(...)
    return M.with_runtime(captured, callback, ...)
  end
end

local function schedule_with_runtime(callback)
  vim.schedule(bind_runtime_callback(callback))
end

local thinking_levels = {
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
}

local extended_thinking_levels = {
  xhigh = true,
  max = true,
}

local image_mime_by_ext = {
  bmp = "image/bmp",
  gif = "image/gif",
  heic = "image/heic",
  jpeg = "image/jpeg",
  jpg = "image/jpeg",
  png = "image/png",
  tif = "image/tiff",
  tiff = "image/tiff",
  webp = "image/webp",
}

local function provider_opts(opts)
  opts = opts or config.get()
  return (opts.providers and opts.providers.pi) or {}
end

function M.picker_prewarm_options(opts)
  local pi = provider_opts(opts)
  return {
    enabled = pi.picker_prewarm ~= false,
    delay_ms = math.max(0, tonumber(pi.prewarm_delay_ms) or 50),
  }
end

local function list_copy(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  return {}
end

local function append_arg(args, name, value)
  if value == nil or value == vim.NIL or value == "" then
    return
  end
  table.insert(args, name)
  table.insert(args, tostring(value))
end

local function append_flag(args, name, enabled)
  if enabled == true then
    table.insert(args, name)
  end
end

local function append_command_args(command, args)
  if type(command) == "string" then
    if #args == 0 then
      return command
    end
    return command .. " " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  end
  local out = list_copy(command)
  vim.list_extend(out, args)
  return out
end

local function without_host_nvim_env(command)
  local unset_args = { "-u", "NVIM", "-u", "NVIM_LISTEN_ADDRESS" }
  if type(command) == "string" then
    return "env " .. table.concat(unset_args, " ") .. " " .. command
  end
  local out = { "env" }
  vim.list_extend(out, unset_args)
  vim.list_extend(out, list_copy(command))
  return out
end

local function effective_model(opts)
  local thread = opts.thread or {}
  local pi = provider_opts(opts)
  return pi.model or thread.model
end

local function effective_thinking(opts)
  local thread = opts.thread or {}
  local pi = provider_opts(opts)
  return pi.thinking or thread.reasoning_effort
end

function M.command(opts, launch)
  opts = opts or config.get()
  launch = launch or {}
  local pi = provider_opts(opts)
  local command = pi.command or { "pi", "--mode", "rpc" }
  local args = {}
  append_arg(args, "--session-id", launch.session_id)
  append_arg(args, "--session", launch.session_file)
  append_arg(args, "--provider", pi.provider or (opts.thread and opts.thread.model_provider))
  append_arg(args, "--model", effective_model(opts))
  append_arg(args, "--thinking", effective_thinking(opts))
  append_arg(args, "--session-dir", pi.session_dir)
  append_arg(args, "--tools", pi.tools)
  append_arg(args, "--exclude-tools", pi.exclude_tools)
  append_flag(args, "--no-session", pi.no_session)
  append_flag(args, "--no-extensions", pi.no_extensions)
  append_flag(args, "--no-skills", pi.no_skills)
  append_flag(args, "--no-context-files", pi.no_context_files)
  append_flag(args, "--offline", pi.offline)
  vim.list_extend(args, list_copy(pi.extra_args))
  return append_command_args(command, args)
end

function M.env(opts, env)
  opts = opts or config.get()
  local pi = provider_opts(opts)
  env = env or {}
  if type(pi.config_dir) == "string" and pi.config_dir ~= "" then
    env.PI_CODING_AGENT_DIR = pi.config_dir
  end
  if type(pi.session_dir) == "string" and pi.session_dir ~= "" then
    env.PI_CODING_AGENT_SESSION_DIR = pi.session_dir
  end
  if pi.offline == true then
    env.PI_OFFLINE = "1"
  end
  return env
end

function M.prepare_command(command, env, launch)
  local err
  command, env, err = require("coact.providers.pi_edit_bridge").prepare_command(command, env, launch)
  if not command then
    return nil, env, err
  end
  command, env, err = require("coact.providers.pi_nvim_bridge").prepare_command(command, env, launch)
  if command then
    command = without_host_nvim_env(command)
  end
  return command, env, err
end

function M.initialize(rpc, callback)
  rpc._request_message("get_state", {}, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    M._remember_state(result)
    callback(nil, result or true)
  end)
end

function M.request_message(method, params, id)
  local message = {
    type = method,
  }
  if id ~= nil then
    message.id = tostring(id)
  end
  if type(params) == "table" then
    for key, value in pairs(params) do
      if value ~= vim.NIL then
        message[key] = value
      end
    end
  end
  return message
end

function M.notify_message(method, params)
  return M.request_message(method, params, nil)
end

function M.decode_response(message)
  if type(message) ~= "table" or message.type ~= "response" or message.id == nil then
    return nil
  end
  local err
  if message.success == false then
    err = { message = message.error or ("Pi RPC command failed: " .. tostring(message.command or "unknown")) }
  end
  return {
    id = tostring(message.id),
    error = err,
    result = message.data or vim.empty_dict(),
  }
end

local function next_turn_id()
  runtime.turn_seq = runtime.turn_seq + 1
  return ("pi-turn-%d"):format(runtime.turn_seq)
end

local function state_thread_id(state)
  return state and state.sessionId and ("pi:" .. tostring(state.sessionId)) or runtime.current_thread_id or "pi:session"
end

local function empty_provider_ui(ui)
  if type(ui) ~= "table" then
    return true
  end
  local statuses = type(ui.statuses) == "table" and ui.statuses or {}
  local widgets = type(ui.widgets) == "table" and ui.widgets or {}
  return vim.tbl_isempty(statuses)
    and vim.tbl_isempty(type(widgets.aboveEditor) == "table" and widgets.aboveEditor or {})
    and vim.tbl_isempty(type(widgets.belowEditor) == "table" and widgets.belowEditor or {})
    and util.value(ui.title) == nil
end

local function provider_ui_store()
  runtime.provider_ui = runtime.provider_ui or {}
  runtime.provider_ui.statuses = runtime.provider_ui.statuses or {}
  runtime.provider_ui.widgets = runtime.provider_ui.widgets or {
    aboveEditor = {},
    belowEditor = {},
  }
  runtime.provider_ui.widgets.aboveEditor = runtime.provider_ui.widgets.aboveEditor or {}
  runtime.provider_ui.widgets.belowEditor = runtime.provider_ui.widgets.belowEditor or {}
  return runtime.provider_ui
end

local function import_thread_provider_ui(thread)
  if not thread or empty_provider_ui(runtime.provider_ui) and empty_provider_ui(thread.provider_ui) then
    return
  end
  if empty_provider_ui(runtime.provider_ui) and type(thread.provider_ui) == "table" then
    runtime.provider_ui = thread.provider_ui
    provider_ui_store()
  end
end

local function attach_provider_ui(thread_id)
  if runtime.suppress_state_updates or not thread_id or empty_provider_ui(runtime.provider_ui) then
    return
  end
  local ok, coact_state = pcall(require, "coact.state")
  if not ok then
    return
  end
  local thread = coact_state.ensure_thread(thread_id)
  import_thread_provider_ui(thread)
  thread.provider_ui = provider_ui_store()
end

local function normalize_session_stats(stats)
  if type(stats) ~= "table" then
    return nil
  end
  local tokens = type(stats.tokens) == "table" and stats.tokens or {}
  local context_usage = type(stats.contextUsage) == "table" and stats.contextUsage
    or type(stats.context_usage) == "table" and stats.context_usage
    or nil
  return {
    input = util.value(tokens.input),
    output = util.value(tokens.output),
    cacheRead = util.value(tokens.cacheRead or tokens.cache_read),
    cacheWrite = util.value(tokens.cacheWrite or tokens.cache_write),
    total = util.value(tokens.total),
    cost = util.value(stats.cost),
    contextUsage = context_usage,
    autoCompactionEnabled = util.value(stats.autoCompactionEnabled or stats.auto_compaction_enabled),
    sessionId = util.value(stats.sessionId),
    sessionFile = util.value(stats.sessionFile),
  }
end

local function remember_session_stats(stats, thread_id)
  local normalized = normalize_session_stats(stats)
  if not normalized then
    return nil
  end
  thread_id = thread_id or runtime.current_thread_id or "pi:session"
  local ok, coact_state = pcall(require, "coact.state")
  if ok and thread_id and not runtime.suppress_state_updates then
    local thread = coact_state.ensure_thread(thread_id)
    thread.token_usage = normalized
    if normalized.autoCompactionEnabled ~= nil then
      thread.auto_compaction_enabled = normalized.autoCompactionEnabled
    end
    local buffers_ok, buffers = pcall(require, "coact.buffers")
    if buffers_ok then
      if buffers.refresh_composer then
        buffers.refresh_composer(thread)
      end
      if buffers.refresh_chrome then
        buffers.refresh_chrome(thread)
      end
    end
  end
  return normalized
end

request_session_stats = function(rpc, thread_id, callback)
  rpc._request_message("get_session_stats", {}, function(err, result)
    if not err then
      remember_session_stats(result, thread_id)
    end
    if callback then
      callback(err, result)
    end
  end)
end

function M._remember_state(state)
  if type(state) ~= "table" then
    return nil
  end
  local previous_thread_id = runtime.current_thread_id
  runtime.session_id = util.value(state.sessionId) or runtime.session_id
  runtime.session_file = util.value(state.sessionFile) or runtime.session_file
  runtime.session_name = util.value(state.sessionName) or runtime.session_name
  runtime.current_thread_id = state_thread_id(state)
  if previous_thread_id and previous_thread_id ~= runtime.current_thread_id then
    local ok, coact_state = pcall(require, "coact.state")
    if ok then
      import_thread_provider_ui(coact_state.get_thread(previous_thread_id))
    end
    runtime.active_turn_id = nil
    runtime.last_turn_id = nil
    runtime.branch_snapshot = nil
    runtime.reserved_turn = nil
    runtime.turn_start_pending = false
    runtime.queued_turns = {}
    runtime.user_item_seq = 0
    runtime.tool_output = {}
    runtime.tool_args = {}
    runtime.tool_calls = {}
  end
  attach_provider_ui(runtime.current_thread_id)
  return runtime.current_thread_id
end

local function current_thread_id()
  if runtime.bound_thread_id then
    return runtime.bound_thread_id
  end
  local ok, state = pcall(require, "coact.state")
  if ok and state.active_thread_id then
    return runtime.current_thread_id or state.active_thread_id
  end
  return runtime.current_thread_id or "pi:session"
end

local function reset_turn_stream_state()
  runtime.user_item_seq = 0
  runtime.tool_output = {}
  runtime.tool_args = {}
  runtime.tool_calls = {}
end

local function begin_turn(turn_id)
  runtime.active_turn_id = turn_id or next_turn_id()
  runtime.last_turn_id = runtime.active_turn_id
  runtime.turn_start_pending = false
  reset_turn_stream_state()
  return runtime.active_turn_id
end

local function current_turn_id()
  if runtime.active_turn_id then
    return runtime.active_turn_id
  end
  return begin_turn(next_turn_id())
end

local function streaming_behavior(value)
  value = util.value(value)
  if value == "steer" or value == "followUp" then
    return value
  end
  return nil
end

local function reserve_turn(entry)
  runtime.reserved_turn = entry
end

local function remove_reserved_turn(turn_id)
  if runtime.reserved_turn and runtime.reserved_turn.id == turn_id then
    local entry = runtime.reserved_turn
    runtime.reserved_turn = nil
    return entry
  end
  return nil
end

local function enqueue_turn(entry)
  runtime.queued_turns = runtime.queued_turns or {}
  table.insert(runtime.queued_turns, entry)
end

local function remove_queued_turn(turn_id)
  for index, entry in ipairs(runtime.queued_turns or {}) do
    if entry.id == turn_id then
      table.remove(runtime.queued_turns, index)
      return entry
    end
  end
  return nil
end

local function take_queued_turn(message_text)
  if type(runtime.queued_turns) ~= "table" or #runtime.queued_turns == 0 then
    return nil
  end
  if message_text and message_text ~= "" then
    for index, entry in ipairs(runtime.queued_turns) do
      if entry.message == message_text then
        return table.remove(runtime.queued_turns, index)
      end
    end
  end
  return table.remove(runtime.queued_turns, 1)
end

local function take_user_turn(message_text)
  if runtime.reserved_turn then
    local reserved = runtime.reserved_turn
    runtime.reserved_turn = nil
    return reserved
  end
  return take_queued_turn(message_text)
end

local function begin_event_turn(entry)
  if runtime.active_turn_id then
    return runtime.active_turn_id
  end
  return begin_turn(entry and entry.id or next_turn_id())
end

local function event_turn_id()
  return runtime.active_turn_id or runtime.last_turn_id or current_turn_id()
end

local function model_id(model)
  if type(model) ~= "table" then
    return nil
  end
  local provider = util.value(model.provider)
  local id = util.value(model.modelId) or util.value(model.model_id) or util.value(model.id) or util.value(model.model)
  if provider and id and not tostring(id):find("/", 1, true) then
    return tostring(provider) .. "/" .. tostring(id)
  end
  return id and tostring(id) or nil
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.expand(path))
end

local function normalize_cwd(cwd)
  return normalize_path(cwd or config.cwd()) or config.cwd()
end

local function pi_agent_dir(opts)
  local pi = provider_opts(opts)
  return normalize_path(pi.config_dir)
    or normalize_path(vim.env.PI_CODING_AGENT_DIR)
    or vim.fs.joinpath(vim.fn.expand("~"), ".pi", "agent")
end

local function encoded_session_dir_name(cwd)
  cwd = normalize_cwd(cwd)
  local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:%z]", "-")
  return "--" .. encoded .. "--"
end

local function default_session_dir(cwd, opts)
  return vim.fs.joinpath(pi_agent_dir(opts), "sessions", encoded_session_dir_name(cwd))
end

local function configured_session_dir(cwd, opts)
  local pi = provider_opts(opts)
  local configured = normalize_path(pi.session_dir or vim.env.PI_CODING_AGENT_SESSION_DIR)
  if configured then
    return configured, configured ~= default_session_dir(cwd, opts)
  end
  return default_session_dir(cwd, opts), false
end

local function readable_file(path)
  return type(path) == "string" and vim.fn.filereadable(path) == 1
end

local function json_decode(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, line)
  return ok and decoded or nil
end

local function timestamp_value(value)
  if type(value) == "number" then
    if value > 1000000000000 then
      return value / 1000
    end
    return value
  end
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then
    return nil
  end
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
end

local function message_time(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local message = type(entry.message) == "table" and entry.message or {}
  return timestamp_value(message.timestamp) or timestamp_value(entry.timestamp)
end

local function file_modified_time(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end
  return stat.mtime.sec or stat.mtime.tv_sec
end

local function thread_from_state(state, attrs)
  state = state or {}
  attrs = attrs or {}
  local thread_id = M._remember_state(state) or runtime.current_thread_id or "pi:session"
  local model = type(state.model) == "table" and state.model or {}
  return {
    id = thread_id,
    cwd = config.cwd(),
    status = state.isStreaming and "active" or "ready",
    name = util.value(state.sessionName) or attrs.name or "Pi session",
    preview = util.value(state.sessionFile) or util.value(state.sessionId) or "Pi session",
    sessionFile = util.value(state.sessionFile),
    sessionId = util.value(state.sessionId),
    model = model_id(model),
    modelProvider = util.value(model.provider),
    reasoningEffort = util.value(state.thinkingLevel),
    autoCompactionEnabled = util.value(state.autoCompactionEnabled),
    token_usage = normalize_session_stats(attrs.stats or attrs.sessionStats),
    provider_ui = not empty_provider_ui(runtime.provider_ui) and provider_ui_store() or nil,
  }
end

local function text_content(content)
  if type(content) == "string" then
    return content
  end
  local lines = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" then
      if block.type == "text" and block.text then
        table.insert(lines, tostring(block.text))
      elseif block.type == "thinking" and block.thinking then
        table.insert(lines, tostring(block.thinking))
      elseif block.type == "image" then
        table.insert(lines, "[image]")
      elseif block.type == "toolCall" then
        table.insert(lines, ("[%s tool call]"):format(tostring(block.name or "tool")))
      end
    end
  end
  return table.concat(lines, "\n")
end

local snapshot_roles = {
  user = true,
  assistant = true,
  branchSummary = true,
  compactionSummary = true,
}

local function normalize_branch_snapshot(payload)
  if type(payload) ~= "table" then
    return nil
  end
  local entries = {}
  for _, entry in ipairs(type(payload.entries) == "table" and payload.entries or {}) do
    local role = util.value(entry.role)
    local id = util.value(entry.id)
    if id and snapshot_roles[role] then
      table.insert(entries, {
        id = tostring(id),
        parentId = util.value(entry.parentId or entry.parent_id),
        role = role,
        text = tostring(util.value(entry.text) or ""),
        timestamp = util.value(entry.timestamp),
        fromId = util.value(entry.fromId or entry.from_id),
        tokensBefore = util.value(entry.tokensBefore or entry.tokens_before),
      })
    end
  end
  return {
    leafId = util.value(payload.leafId or payload.leaf_id),
    entries = entries,
  }
end

local function normalize_tree_action(payload)
  if type(payload) ~= "table" then
    return nil
  end
  local nested = payload.treeAction or payload.tree_action
  if type(nested) == "table" then
    return normalize_tree_action(nested)
  end
  if payload.__coactNvimPiTreeAction ~= true then
    return nil
  end
  local action = util.value(payload.action)
  if action ~= "reveal" and action ~= "navigateTree" and action ~= "cancel" and action ~= "noop" then
    return nil
  end
  local id = util.value(payload.id or payload.entryId or payload.entry_id)
  return {
    __coactNvimPiTreeAction = true,
    action = action,
    id = id ~= nil and tostring(id) or nil,
    fallbackReason = util.value(payload.fallbackReason or payload.fallback_reason),
  }
end

local function compact_snapshot_text(value)
  return util.trim(tostring(value or ""):gsub("%s+", " "))
end

local function snapshot_text_matches(entry, text)
  local entry_text = compact_snapshot_text(entry and entry.text)
  local item_text = compact_snapshot_text(text)
  if entry_text == "" or item_text == "" then
    return true
  end
  return entry_text == item_text
    or entry_text:find(item_text, 1, true) ~= nil
    or item_text:find(entry_text, 1, true) ~= nil
end

local function snapshot_cursor(snapshot)
  snapshot = normalize_branch_snapshot(snapshot)
  local cursor = {
    user = {},
    assistant = {},
    branchSummary = {},
    compactionSummary = {},
    indices = {
      user = 1,
      assistant = 1,
      branchSummary = 1,
      compactionSummary = 1,
    },
  }
  for _, entry in ipairs(snapshot and snapshot.entries or {}) do
    if snapshot_roles[entry.role] then
      table.insert(cursor[entry.role], entry)
    end
  end
  return cursor
end

local function next_snapshot_entry(cursor, role, text)
  if type(cursor) ~= "table" or not snapshot_roles[role] then
    return nil
  end
  local entries = cursor[role] or {}
  local index = cursor.indices and cursor.indices[role] or 1
  for candidate_index = index, #entries do
    local entry = entries[candidate_index]
    if snapshot_text_matches(entry, text) then
      if cursor.indices then
        cursor.indices[role] = candidate_index + 1
      end
      return entry
    end
  end
  local entry = entries[index]
  if cursor.indices then
    cursor.indices[role] = index + 1
  end
  return entry
end

local function role_for_item(item)
  if type(item) ~= "table" then
    return nil
  end
  if item.type == "userMessage" then
    return "user"
  end
  if item.type == "agentMessage" then
    return "assistant"
  end
  if item.type == "branchSummary" or item.type == "compactionSummary" then
    return item.type
  end
  return nil
end

local function item_snapshot_text(item)
  if type(item) ~= "table" then
    return ""
  end
  if item.type == "userMessage" then
    return text_content(item.content)
  end
  if item.type == "agentMessage" or item.type == "branchSummary" or item.type == "compactionSummary" then
    return tostring(item.text or "")
  end
  return ""
end

local function annotate_thread_tree_entry_ids(thread, snapshot)
  snapshot = normalize_branch_snapshot(snapshot)
  if not (thread and snapshot and type(snapshot.entries) == "table") then
    return false
  end
  local cursor = snapshot_cursor(snapshot)
  local changed = false
  for _, item_id in ipairs(thread.item_order or {}) do
    local item = thread.items and thread.items[item_id]
    local role = role_for_item(item)
    if role then
      local entry = next_snapshot_entry(cursor, role, item_snapshot_text(item))
      if entry and item.treeEntryId ~= entry.id then
        item.treeEntryId = entry.id
        item.treeParentId = entry.parentId
        changed = true
      end
    end
  end
  return changed
end

local function annotate_current_thread_tree_entry_ids(thread_id, snapshot)
  local ok, coact_state = pcall(require, "coact.state")
  if not ok then
    return false
  end
  local thread = coact_state.get_thread(thread_id or runtime.current_thread_id or current_thread_id())
  return annotate_thread_tree_entry_ids(thread, snapshot)
end

local session_info_cache = {}

local function read_session_info_uncached(path)
  local lines = vim.fn.readfile(path)
  local header = json_decode(lines[1])
  if type(header) ~= "table" or header.type ~= "session" or not util.value(header.id) then
    return nil
  end
  local cwd = normalize_path(util.value(header.cwd)) or normalize_cwd()
  local parent_session_path = normalize_path(util.value(header.parentSession))

  local first_message
  local name
  local model
  local model_provider
  local thinking
  local message_count = 0
  local modified = timestamp_value(header.timestamp) or file_modified_time(path) or 0

  for index = 2, #lines do
    local entry = json_decode(lines[index])
    if type(entry) == "table" then
      if entry.type == "session_info" and util.value(entry.name) then
        name = tostring(util.value(entry.name))
      elseif entry.type == "model_change" then
        local entry_model = type(entry.model) == "table" and entry.model or entry
        model = model_id(entry_model) or util.value(entry.modelId) or util.value(entry.model)
        model_provider = util.value(entry_model.provider) or util.value(entry.provider)
      elseif entry.type == "thinking_level_change" then
        thinking = util.value(entry.level) or util.value(entry.thinkingLevel) or util.value(entry.thinking)
      elseif entry.type == "message" and type(entry.message) == "table" then
        message_count = message_count + 1
        if not first_message and entry.message.role == "user" then
          first_message = util.trim(text_content(entry.message.content))
        end
        modified = math.max(modified, message_time(entry) or 0)
      end
    end
  end

  local id = tostring(util.value(header.id))
  local title = util.value(name) or (first_message and first_message ~= "" and first_message) or "Pi session"
  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", modified)
  return {
    id = "pi:" .. id,
    cwd = cwd,
    status = "ready",
    name = title,
    preview = first_message or title,
    sessionFile = path,
    sessionId = id,
    parentSessionPath = parent_session_path,
    messageCount = message_count,
    model = model,
    modelProvider = model_provider,
    reasoningEffort = thinking,
    updated_at = updated_at,
    updatedAt = updated_at,
    _sort = modified,
  }
end

local function read_session_info(path, cwd_filter)
  if not readable_file(path) then
    session_info_cache[path] = nil
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  local cached = session_info_cache[path]
  local mtime = stat and stat.mtime and (stat.mtime.sec or stat.mtime.tv_sec) or 0
  local mtime_nsec = stat and stat.mtime and (stat.mtime.nsec or stat.mtime.tv_nsec) or 0
  local size = stat and stat.size or 0
  if not cached or cached.mtime ~= mtime or cached.mtime_nsec ~= mtime_nsec or cached.size ~= size then
    local info = read_session_info_uncached(path)
    cached = {
      mtime = mtime,
      mtime_nsec = mtime_nsec,
      size = size,
      info = info,
    }
    session_info_cache[path] = cached
  end
  local info = cached.info and vim.deepcopy(cached.info) or nil
  if info and cwd_filter and normalize_cwd(cwd_filter) ~= info.cwd then
    return nil
  end
  return info
end

local function list_local_sessions(cwd, opts)
  cwd = normalize_cwd(cwd)
  local dir, filter_by_cwd = configured_session_dir(cwd, opts)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return {}
  end
  local sessions = {}
  local seen_paths = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:match("%.jsonl$") then
      local path = vim.fs.joinpath(dir, name)
      seen_paths[path] = true
      local info = read_session_info(path, filter_by_cwd and cwd or nil)
      if info then
        table.insert(sessions, info)
      end
    end
  end
  for path in pairs(session_info_cache) do
    if vim.fs.dirname(path) == dir and not seen_paths[path] then
      session_info_cache[path] = nil
    end
  end
  local by_path = {}
  local function path_key(path)
    path = normalize_path(path)
    return path and (vim.uv.fs_realpath(path) or path) or nil
  end
  for _, session in ipairs(sessions) do
    local key = path_key(session.sessionFile)
    if key then
      by_path[key] = session
    end
  end
  for _, session in ipairs(sessions) do
    local parent_key = path_key(session.parentSessionPath)
    local parent = parent_key and by_path[parent_key] or nil
    if parent and parent ~= session then
      session.parentThreadId = parent.id
    end
  end
  table.sort(sessions, function(a, b)
    if (a._sort or 0) == (b._sort or 0) then
      return tostring(a.sessionId or "") > tostring(b.sessionId or "")
    end
    return (a._sort or 0) > (b._sort or 0)
  end)
  for _, session in ipairs(sessions) do
    session._sort = nil
  end
  return sessions
end

local function strip_pi_thread_prefix(thread_id)
  if type(thread_id) ~= "string" then
    return nil
  end
  return thread_id:gsub("^pi:", "")
end

local function resolve_session_file(cwd, thread_id, opts)
  local candidate = util.value(thread_id)
  if type(candidate) == "string" and readable_file(candidate) then
    return normalize_path(candidate)
  end
  local wanted = strip_pi_thread_prefix(candidate)
  if not wanted or wanted == "" or wanted == "session" then
    return nil
  end
  for _, session in ipairs(list_local_sessions(cwd, opts)) do
    if session.sessionId == wanted or session.id == candidate then
      return session.sessionFile
    end
  end
  return nil
end

local function merge_current_thread(threads, state_result, attrs)
  local current = thread_from_state(state_result, attrs)
  if not current.sessionId then
    return #threads > 0 and threads or { current }
  end
  for index, thread in ipairs(threads) do
    if thread.sessionId == current.sessionId then
      local current_name = util.value(current.name)
      if current_name == "Pi session" then
        current_name = nil
      end
      threads[index] = vim.tbl_extend("force", thread, current, {
        name = current_name or thread.name,
        preview = util.value(thread.preview) or current.preview,
        sessionFile = util.value(thread.sessionFile) or current.sessionFile,
      })
      return threads
    end
  end
  if current.sessionFile or #threads == 0 then
    table.insert(threads, 1, current)
  end
  return threads
end

local function byte_at(value, index)
  return string.byte(value or "", index) or -1
end

local function detect_image_mime(bytes)
  if byte_at(bytes, 1) == 0xff and byte_at(bytes, 2) == 0xd8 and byte_at(bytes, 3) == 0xff then
    return "image/jpeg"
  end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "image/png"
  end
  if bytes:sub(1, 3) == "GIF" then
    return "image/gif"
  end
  if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
    return "image/webp"
  end
  return nil
end

local function image_mime(path, bytes)
  local detected = detect_image_mime(bytes or "")
  if detected then
    return detected
  end
  local ext = tostring(path or ""):match("%.([^./\\]+)$")
  return ext and image_mime_by_ext[ext:lower()] or "application/octet-stream"
end

local function read_local_image(path)
  path = vim.fs.normalize(vim.fn.expand(tostring(path or "")))
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat or not stat.size then
    vim.uv.fs_close(fd)
    return nil
  end
  local bytes = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not bytes then
    return nil
  end
  return {
    type = "image",
    data = vim.base64.encode(bytes),
    mimeType = image_mime(path, bytes),
  }
end

local function prompt_from_input(input)
  local parts = {}
  local image_notes = {}
  local images = {}
  for _, item in ipairs(input or {}) do
    if item.type == "text" then
      table.insert(parts, tostring(item.text or ""))
    elseif item.type == "localImage" then
      local image = read_local_image(item.path)
      if image then
        table.insert(images, image)
        table.insert(image_notes, "[local image] " .. tostring(item.path or ""))
      else
        table.insert(parts, "[local image unavailable] " .. tostring(item.path or ""))
      end
    elseif item.type == "image" then
      table.insert(parts, "[image] " .. tostring(item.url or ""))
    elseif item.type == "skill" then
      table.insert(parts, "/skill:" .. tostring(item.name or item.path or ""))
    elseif item.type == "mention" then
      table.insert(parts, "@" .. tostring(item.name or item.path or ""))
    else
      table.insert(parts, vim.inspect(item))
    end
  end
  if #parts == 0 then
    vim.list_extend(parts, image_notes)
  end
  return util.trim(table.concat(parts, "\n\n")), images
end

local function next_user_item_id(turn_id)
  runtime.user_item_seq = (runtime.user_item_seq or 0) + 1
  if runtime.user_item_seq == 1 then
    return turn_id .. ":user"
  end
  return turn_id .. ":user:" .. tostring(runtime.user_item_seq)
end

local function user_item(turn_id, text, input, item_id, status)
  local content = {}
  for _, item in ipairs(type(input) == "table" and input or {}) do
    if
      item.type == "text"
      or item.type == "localImage"
      or item.type == "image"
      or item.type == "skill"
      or item.type == "mention"
    then
      table.insert(content, vim.deepcopy(item))
    end
  end
  if #content == 0 then
    content = {
      {
        type = "text",
        text = text,
      },
    }
  end
  return {
    id = item_id or (turn_id .. ":user"),
    type = "userMessage",
    status = status or "submitted",
    content = content,
  }
end

local function chain(commands, done)
  local index = 0
  local last_result
  local function step()
    index = index + 1
    local command = commands[index]
    if not command then
      done(nil, last_result)
      return
    end
    command(function(err, result)
      if err then
        done(err, nil)
        return
      end
      last_result = result
      step()
    end)
  end
  step()
end

local function parse_model(value)
  value = util.value(value)
  if type(value) ~= "string" or value == "" then
    return nil, nil
  end
  local provider, model = value:match("^([^/]+)/(.+)$")
  if provider and model then
    return provider, model
  end
  local cfg_provider = provider_opts().provider or config.get().thread.model_provider
  return cfg_provider, value
end

local function supported_thinking_efforts(model)
  local supported = {}
  if model.reasoning ~= true then
    return supported
  end
  local level_map = type(model.thinkingLevelMap) == "table" and model.thinkingLevelMap or {}
  for _, level in ipairs(thinking_levels) do
    local mapped = level_map[level]
    local available = mapped ~= vim.NIL and (not extended_thinking_levels[level] or mapped ~= nil)
    if available then
      table.insert(supported, { effort = level })
    end
  end
  return supported
end

local function normalize_model(model)
  model = type(model) == "table" and model or {}
  local id = model_id(model) or util.value(model.id) or util.value(model.model)
  if not id then
    return nil
  end
  return {
    id = id,
    model = id,
    provider = util.value(model.provider),
    displayName = util.value(model.name) or id,
    description = util.value(model.description),
    contextWindow = util.value(model.contextWindow),
    supportedReasoningEfforts = supported_thinking_efforts(model),
    defaultReasoningEffort = util.value(model.defaultReasoningEffort),
    serviceTiers = {},
  }
end

local function normalize_commands_as_skills(commands)
  local skills = {}
  for _, command in ipairs(type(commands) == "table" and commands or {}) do
    if command.source == "skill" then
      local name = tostring(command.name or ""):gsub("^skill:", "")
      if name ~= "" then
        table.insert(skills, {
          name = name,
          description = command.description,
          shortDescription = command.description,
          path = command.sourceInfo and (command.sourceInfo.path or command.sourceInfo.file),
        })
      end
    end
  end
  return {
    data = {
      {
        cwd = config.cwd(),
        skills = skills,
      },
    },
  }
end

local function branch_snapshot_command_message()
  return "/coact-nvim-branch-snapshot"
end

local function request_branch_snapshot(rpc, params, callback)
  callback = callback or function() end
  local ok, bridge = pcall(require, "coact.providers.pi_edit_bridge")
  if not (ok and bridge.enabled and bridge.enabled()) then
    callback(nil, nil)
    return nil
  end
  runtime.branch_snapshot = nil
  rpc._request_message("prompt", { message = branch_snapshot_command_message() }, function(err)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, runtime.branch_snapshot)
  end)
end

local function tree_command_message(params)
  local initial = params and (util.value(params.initialSelectedId) or util.value(params.initial_selected_id))
  if initial == nil or initial == "" then
    return "/coact-nvim-tree"
  end
  local ok, encoded = pcall(vim.json.encode, { initialSelectedId = tostring(initial) })
  return "/coact-nvim-tree " .. (ok and encoded or tostring(initial))
end

local function sync_thread(params)
  local thread_id = util.value(params and (params.threadId or params.thread_id or params.conversationId))
  if not thread_id then
    return nil
  end
  local ok, coact_state = pcall(require, "coact.state")
  return ok and coact_state.ensure_thread(thread_id) or nil
end

local function render_sync_state(thread)
  local buffers_ok, buffers = pcall(require, "coact.buffers")
  if buffers_ok and thread and thread.bufnr then
    buffers.schedule_render(thread.id)
  end
end

local function begin_open_sync(params)
  local thread = sync_thread(params)
  if not thread then
    return nil
  end
  thread.sync_revision = (tonumber(thread.sync_revision) or 0) + 1
  thread.sync = "hydrating"
  thread.sync_message = "Loading conversation history…"
  render_sync_state(thread)
  return {
    thread = thread,
    revision = thread.sync_revision,
  }
end

local function finish_open_sync(operation)
  local thread = operation and operation.thread or nil
  if not thread or thread.sync_revision ~= operation.revision then
    return
  end
  thread.sync = "clean"
  thread.sync_message = nil
  render_sync_state(thread)
end

local function read_current_thread(rpc, params, callback, opts)
  opts = opts or {}
  local sync_operation = begin_open_sync(params)
  local completed = false
  local function finish(err, result)
    if completed then
      return
    end
    completed = true
    finish_open_sync(sync_operation)
    callback(err, result)
  end
  rpc._request_message("get_state", {}, function(err, state_result)
    if err then
      finish(err, nil)
      return
    end
    local thread = thread_from_state(state_result, params)
    if opts.replace_turns == true then
      thread.replaceTurns = true
    end
    request_session_stats(rpc, thread.id, function(_, stats_result)
      thread.token_usage = normalize_session_stats(stats_result) or thread.token_usage
      request_branch_snapshot(rpc, params, function(_, branch_snapshot)
        rpc._request_message("get_messages", {}, function(messages_err, messages_result)
          if messages_err then
            if opts.require_messages == true then
              finish(messages_err, nil)
            else
              finish(nil, { thread = thread })
            end
            return
          end
          thread.turns =
            M._turns_from_messages(messages_result and messages_result.messages, thread.id, branch_snapshot)
          finish(nil, { thread = thread })
        end)
      end)
    end)
  end)
end

function M.custom_request(rpc, method, params, callback)
  params = params or {}
  local requested_thread_id = util.value(params.threadId or params.thread_id or params.conversationId)
  if runtime.bound_thread_id and requested_thread_id and requested_thread_id ~= runtime.bound_thread_id then
    callback({
      message = ("Pi execution unit %s cannot handle request for %s"):format(
        tostring(runtime.bound_thread_id),
        tostring(requested_thread_id)
      ),
    }, nil)
    return true
  end
  if method == "thread/start" then
    local function finish_from_current_state()
      rpc._request_message("get_state", {}, function(state_err, state_result)
        if state_err then
          callback(state_err, nil)
          return
        end
        local thread = thread_from_state(state_result, params)
        request_session_stats(rpc, thread.id, function(_, stats_result)
          thread.token_usage = normalize_session_stats(stats_result) or thread.token_usage
          callback(nil, { thread = thread })
        end)
      end)
    end
    if params._coactUseInitialSession == true then
      finish_from_current_state()
      return true
    end
    rpc._request_message("new_session", {}, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      if result and result.cancelled then
        callback({ message = "Pi new_session was cancelled" }, nil)
        return
      end
      finish_from_current_state()
    end)
    return true
  end

  if method == "thread/read" or method == "thread/resume" then
    if params._coactClientBound == true then
      read_current_thread(rpc, params, callback)
      return true
    end
    local session_file = util.value(params.sessionFile or params.session_file)
      or resolve_session_file(params.cwd or config.cwd(), params.threadId)
    if session_file then
      rpc._request_message("switch_session", { sessionPath = session_file }, function(err, result)
        if err then
          callback(err, nil)
          return
        end
        if result and result.cancelled then
          callback({ message = "Pi switch_session was cancelled" }, nil)
          return
        end
        read_current_thread(rpc, params, callback)
      end)
    else
      callback({ message = "Pi session file was not found for thread " .. tostring(params.threadId) }, nil)
    end
    return true
  end

  if method == "thread/tree" then
    runtime.current_thread_id = params.threadId or current_thread_id()
    runtime.last_tree_action = nil
    rpc._request_message("prompt", { message = tree_command_message(params) }, function(err, result)
      local tree_action = normalize_tree_action(result) or normalize_tree_action(runtime.last_tree_action)
      runtime.last_tree_action = nil
      if err then
        callback(err, nil)
        return
      end
      if result and result.cancelled then
        callback({ message = "Pi tree navigation was cancelled" }, nil)
        return
      end
      if
        tree_action
        and (tree_action.action == "reveal" or tree_action.action == "cancel" or tree_action.action == "noop")
      then
        callback(nil, { treeAction = tree_action })
        return
      end
      read_current_thread(rpc, params, callback, { replace_turns = true })
    end)
    return true
  end

  if method == "thread/treeSnapshot" then
    runtime.current_thread_id = params.threadId or current_thread_id()
    request_branch_snapshot(rpc, params, function(err, snapshot)
      if snapshot then
        annotate_current_thread_tree_entry_ids(params.threadId or runtime.current_thread_id, snapshot)
      end
      callback(err, { snapshot = snapshot })
    end)
    return true
  end

  if method == "thread/list" then
    local threads = list_local_sessions(params.cwd or config.cwd())
    rpc._request_message("get_state", {}, function(err, state_result)
      if err then
        callback(err, nil)
        return
      end
      callback(nil, { data = merge_current_thread(threads, state_result, params) })
    end)
    return true
  end

  if method == "turn/start" then
    local turn_id = next_turn_id()
    runtime.current_thread_id = params.threadId or current_thread_id()
    local behavior = streaming_behavior(params.streamingBehavior)
    local queued = behavior ~= nil
    local message, images = prompt_from_input(params.input)
    if message == "" and #images == 0 then
      callback({ message = "Pi prompt is empty" }, nil)
      return true
    end
    local entry = {
      id = turn_id,
      message = message,
      input = vim.deepcopy(params.input),
      streamingBehavior = behavior,
    }
    -- Reserve before writing RPC: Pi can stream events before Neovim runs the
    -- scheduled response callback.
    if queued then
      enqueue_turn(entry)
    else
      reserve_turn(entry)
    end
    rpc._request_message("prompt", {
      message = message,
      images = #images > 0 and images or nil,
      streamingBehavior = behavior,
    }, function(err)
      if err then
        if queued then
          remove_queued_turn(turn_id)
        else
          remove_reserved_turn(turn_id)
        end
        callback(err, nil)
        return
      end
      if queued then
        callback(nil, {
          queued = true,
          streamingBehavior = behavior,
          turn = {
            id = turn_id,
            items = {},
          },
        })
        return
      end
      callback(nil, {
        turn = {
          id = turn_id,
          items = { user_item(turn_id, message, params.input) },
        },
      })
    end)
    return true
  end

  if method == "turn/interrupt" then
    rpc._request_message("abort", {}, callback)
    return true
  end

  if method == "model/list" then
    rpc._request_message("get_available_models", {}, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      local models = {}
      for _, model in ipairs(type(result) == "table" and result.models or {}) do
        local normalized = normalize_model(model)
        if normalized then
          table.insert(models, normalized)
        end
      end
      callback(nil, { data = models })
    end)
    return true
  end

  if method == "thread/settings/update" then
    local commands = {}
    local provider, model = parse_model(params.model)
    if provider and model then
      table.insert(commands, function(done)
        rpc._request_message("set_model", { provider = provider, modelId = model }, done)
      end)
    end
    local effort = util.value(params.effort or params.reasoningEffort)
    if effort then
      table.insert(commands, function(done)
        rpc._request_message("set_thinking_level", { level = tostring(effort) }, done)
      end)
    end
    if #commands == 0 then
      local unsupported = {}
      for key, value in pairs(params) do
        if key ~= "threadId" and value ~= nil and value ~= vim.NIL then
          table.insert(unsupported, key)
        end
      end
      if #unsupported > 0 then
        table.sort(unsupported)
        callback({
          message = "Pi provider does not support updating these thread settings over RPC: "
            .. table.concat(unsupported, ", "),
        }, nil)
      else
        callback(nil, vim.empty_dict())
      end
    else
      chain(commands, callback)
    end
    return true
  end

  if method == "skills/list" then
    rpc._request_message("get_commands", {}, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      callback(nil, normalize_commands_as_skills(result and result.commands))
    end)
    return true
  end

  if method == "mcpServerStatus/list" or method == "app/list" or method == "permissionProfile/list" then
    callback(nil, { data = {} })
    return true
  end

  if method == "config/read" then
    rpc._request_message("get_state", {}, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      local model = type(result) == "table" and result.model or {}
      callback(nil, {
        config = {
          model = model_id(model),
          model_provider = model.provider,
          model_reasoning_effort = result and result.thinkingLevel,
        },
      })
    end)
    return true
  end

  if method == "account/rateLimits/read" then
    request_session_stats(rpc, params.threadId or params.thread_id or current_thread_id(), callback)
    return true
  end

  if method == "thread/compact/start" then
    rpc._request_message("compact", {}, callback)
    return true
  end

  return false
end

local function refresh_current_thread(rpc, params, callback)
  params = params or {}
  callback = callback or function() end
  read_current_thread(rpc, params, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    local payload = result and result.thread
    if not payload then
      callback({ message = "Pi compaction refresh returned no thread" }, nil)
      return
    end
    local ok, coact_state = pcall(require, "coact.state")
    if not ok then
      callback({ message = "coact state is unavailable after Pi compaction" }, nil)
      return
    end
    local thread = coact_state.update_thread_from_payload(payload)
    local buffers_ok, buffers = pcall(require, "coact.buffers")
    if buffers_ok and thread and thread.bufnr then
      buffers.schedule_render(thread.id)
    end
    callback(nil, thread)
  end, { replace_turns = true, require_messages = true })
end

function M.on_compaction_completed(params)
  if not (params and type(params.result) == "table" and params.threadId) then
    return
  end
  local ok, pi_rpc = pcall(require, "coact.providers.pi_rpc")
  if not ok then
    return
  end
  pi_rpc.with_client(params.threadId, function(client_err, client)
    if client_err or not client then
      return
    end
    M.with_runtime(client.runtime, function()
      refresh_current_thread(client, { threadId = params.threadId }, function(err)
        if err then
          util.notify("Pi compaction history refresh failed: " .. tostring(err.message or err), vim.log.levels.WARN)
        end
      end)
    end)
  end)
end

function M.on_generation_completed(payload)
  local thread = payload and payload.thread or nil
  local thread_id = thread and thread.id or nil
  if not thread_id then
    return
  end
  local ok, rpc = pcall(require, "coact.rpc")
  if not (ok and rpc.is_running and rpc.is_running(thread_id)) then
    return
  end
  rpc.request("thread/treeSnapshot", { threadId = thread_id }, function() end)
end

local function message_item_id(kind, index, scope)
  local scoped_index = scope and (tostring(scope) .. ":" .. tostring(index or 0)) or tostring(index or 0)
  return current_turn_id() .. ":" .. kind .. ":" .. scoped_index
end

local function assistant_item_id(index, scope)
  return message_item_id("assistant", index, scope)
end

local function reasoning_item_id(index, scope)
  return message_item_id("reasoning", index, scope)
end

local function tool_item_type(tool_name)
  return tool_name == "bash" and "commandExecution" or "dynamicToolCall"
end

local function tool_result_text(result)
  if type(result) == "string" then
    return result
  end
  if type(result) ~= "table" then
    return ""
  end
  if result.content ~= nil then
    return text_content(result.content)
  end
  return text_content(result)
end

local function tool_item(tool_call_id, tool_name, args, state_value, result)
  local key = util.value(tool_call_id)
  if key == nil or key == "" then
    return nil
  end
  key = tostring(key)
  local remembered = runtime.tool_calls[key] or {}
  local name = util.value(tool_name) or remembered.name
  args = args or runtime.tool_args[key]
  local output_text = result and tool_result_text(result) or runtime.tool_output[key]
  local item = {
    id = key,
    type = tool_item_type(name),
    status = state_value,
    tool = name,
    arguments = args,
    input = args,
    result = result,
  }
  if item.type == "commandExecution" then
    item.command = args and args.command
    item.aggregatedOutput = output_text
  else
    item.namespace = "pi"
    if output_text and output_text ~= "" then
      item.output = output_text
    end
  end
  return item
end

local function assistant_content_block(partial, index)
  if type(partial) ~= "table" then
    return nil
  end
  local content = type(partial.content) == "table" and partial.content or {}
  local block = content[(tonumber(index) or 0) + 1]
  return type(block) == "table" and block or nil
end

local function tool_call_from_event(event, index)
  if type(event) ~= "table" then
    return nil
  end
  if type(event.toolCall) == "table" then
    return event.toolCall
  end
  local block = assistant_content_block(event.partial, index)
  if block and block.type == "toolCall" then
    return block
  end
  if type(event.partial) == "table" and event.partial.type == "toolCall" then
    return event.partial
  end
  return nil
end

local function tool_item_from_call(tool, state_value)
  if type(tool) ~= "table" then
    return nil
  end
  local key = util.value(tool.id)
  if key == nil or key == "" then
    return nil
  end
  key = tostring(key)
  local remembered = runtime.tool_calls[key] or {}
  local name = util.value(tool.name) or remembered.name
  if name == nil or name == "" then
    return nil
  end
  local args = util.value(tool.arguments) or runtime.tool_args[key] or {}
  runtime.tool_args[key] = args
  local partial_json = util.value(tool.partialJson) or util.value(tool.partialArgs)
  runtime.tool_calls[key] = vim.tbl_extend("force", runtime.tool_calls[key] or {}, {
    name = name,
    partialJson = partial_json,
  })
  local item = tool_item(key, name, args, state_value)
  if not item then
    return nil
  end
  if partial_json and partial_json ~= "" then
    item.partialJson = partial_json
    if type(item.input) ~= "table" or vim.tbl_isempty(item.input) then
      item.input = { partialJson = partial_json }
    end
  end
  return item
end

local function tool_update_delta(tool_call_id, result)
  local key = tostring(tool_call_id)
  local text = tool_result_text(result)
  local previous = runtime.tool_output[key] or ""
  if text ~= "" then
    runtime.tool_output[key] = text
  end
  if text:sub(1, #previous) == previous then
    return text:sub(#previous + 1)
  end
  return text
end

local function message_items(message, status, tree_entry, id_scope)
  local items = {}
  if type(message) ~= "table" or message.role ~= "assistant" then
    return items
  end
  for index, block in ipairs(type(message.content) == "table" and message.content or {}) do
    local zero_index = index - 1
    if block.type == "text" then
      table.insert(items, {
        id = assistant_item_id(zero_index, id_scope),
        type = "agentMessage",
        status = status,
        text = tostring(block.text or ""),
        treeEntryId = tree_entry and tree_entry.id or nil,
        treeParentId = tree_entry and tree_entry.parentId or nil,
      })
    elseif block.type == "thinking" then
      table.insert(items, {
        id = reasoning_item_id(zero_index, id_scope),
        type = "reasoning",
        status = status,
        content = { tostring(block.thinking or "") },
      })
    elseif block.type == "toolCall" then
      local item = tool_item_from_call(block, status)
      if item then
        table.insert(items, item)
      end
    end
  end
  if #items == 0 and message.errorMessage then
    table.insert(items, {
      id = assistant_item_id(0, id_scope),
      type = "agentMessage",
      status = "error",
      text = tostring(message.errorMessage),
    })
  end
  return items
end

local function notification(method, params)
  return {
    kind = "notification",
    message = {
      method = method,
      params = params or {},
    },
  }
end

local function notifications(entries)
  local out = {}
  for _, entry in ipairs(entries) do
    table.insert(out, entry)
  end
  return out
end

local function ensure_history_turn(turns, turn_index)
  local turn = turns[#turns]
  if turn then
    return turn, turn_index
  end
  turn_index = turn_index + 1
  turn = { id = ("pi-history-%d"):format(turn_index), items = {} }
  table.insert(turns, turn)
  return turn, turn_index
end

local function history_summary_item(message, role, summary_index, tree_entry)
  local summary = tostring(util.value(message.summary) or "")
  local identity = tree_entry and tree_entry.id
    or table.concat({ role, tostring(util.value(message.timestamp) or "unknown"), tostring(summary_index) }, ":")
  return {
    id = "pi-history-summary:" .. tostring(identity),
    type = role,
    status = "completed",
    text = summary,
    fromId = util.value(message.fromId or message.from_id) or (tree_entry and tree_entry.fromId),
    tokensBefore = util.value(message.tokensBefore or message.tokens_before)
      or (tree_entry and tree_entry.tokensBefore),
    timestamp = util.value(message.timestamp) or (tree_entry and tree_entry.timestamp),
    treeEntryId = tree_entry and tree_entry.id or nil,
    treeParentId = tree_entry and tree_entry.parentId or nil,
  }
end

function M._turns_from_messages(messages, thread_id, branch_snapshot)
  local turns = {}
  local turn_index = 0
  local summary_index = 0
  local history_assistant_index = 0
  local tree_cursor = snapshot_cursor(branch_snapshot)
  for _, message in ipairs(type(messages) == "table" and messages or {}) do
    if message.role == "user" then
      history_assistant_index = 0
      local message_text = text_content(message.content)
      local tree_entry = next_snapshot_entry(tree_cursor, "user", message_text)
      turn_index = turn_index + 1
      table.insert(turns, {
        id = ("pi-history-%d"):format(turn_index),
        items = {
          {
            id = ("pi-history-%d:user"):format(turn_index),
            type = "userMessage",
            status = "completed",
            content = {
              {
                type = "text",
                text = message_text,
              },
            },
            treeEntryId = tree_entry and tree_entry.id or nil,
            treeParentId = tree_entry and tree_entry.parentId or nil,
          },
        },
      })
    elseif message.role == "assistant" then
      history_assistant_index = history_assistant_index + 1
      local tree_entry = next_snapshot_entry(tree_cursor, "assistant", text_content(message.content))
      local turn
      turn, turn_index = ensure_history_turn(turns, turn_index)
      local old_turn = runtime.active_turn_id
      runtime.active_turn_id = turn.id
      vim.list_extend(
        turn.items,
        message_items(message, "completed", tree_entry, ("history-%d"):format(history_assistant_index))
      )
      runtime.active_turn_id = old_turn
    elseif message.role == "toolResult" then
      local turn = turns[#turns]
      if turn then
        table.insert(turn.items, tool_item(message.toolCallId, message.toolName, {}, "completed", message))
      end
    elseif message.role == "branchSummary" or message.role == "compactionSummary" then
      summary_index = summary_index + 1
      local summary = tostring(util.value(message.summary) or "")
      local tree_entry = next_snapshot_entry(tree_cursor, message.role, summary)
      local turn
      turn, turn_index = ensure_history_turn(turns, turn_index)
      table.insert(turn.items, history_summary_item(message, message.role, summary_index, tree_entry))
    end
  end
  return turns
end

local turn_scoped_events = {
  message_end = true,
  message_update = true,
  tool_execution_end = true,
  tool_execution_start = true,
  tool_execution_update = true,
  turn_end = true,
}

local function message_start_notifications(message, thread_id)
  local role = type(message) == "table" and message.role or nil
  local message_text = role == "user" and text_content(message.content) or nil
  local entry = role == "user" and take_user_turn(message_text) or nil
  local started = runtime.active_turn_id == nil
  local turn_id = begin_event_turn(entry)
  local out = {}
  if started then
    table.insert(
      out,
      notification("turn/started", {
        threadId = thread_id,
        turn = { id = turn_id },
      })
    )
  end
  if role == "user" then
    if entry and entry.streamingBehavior then
      table.insert(
        out,
        notification("pi/queued_turn_started", {
          threadId = thread_id,
          turnId = turn_id,
          queuedTurnId = entry.id,
        })
      )
    end
    local item = user_item(
      turn_id,
      entry and entry.message or message_text,
      entry and entry.input or nil,
      next_user_item_id(turn_id),
      "completed"
    )
    table.insert(
      out,
      notification("item/completed", {
        threadId = thread_id,
        turnId = turn_id,
        item = item,
      })
    )
  else
    for _, item in ipairs(message_items(message, "running")) do
      table.insert(
        out,
        notification("item/started", {
          threadId = thread_id,
          turnId = turn_id,
          item = item,
        })
      )
    end
  end
  return #out > 0 and notifications(out) or nil
end

function M.decode_notification(message)
  if type(message) ~= "table" or message.type == "response" then
    return nil
  end
  local thread_id = current_thread_id()

  if message.type == "turn_start" then
    -- A Pi turn may be an automatic tool continuation. Wait for message_start
    -- before deciding whether this turn owns a queued user prompt.
    if runtime.active_turn_id then
      runtime.last_turn_id = runtime.active_turn_id
      runtime.active_turn_id = nil
    end
    runtime.turn_start_pending = true
    return nil
  end

  if message.type == "agent_start" then
    return notification("pi/agent_start", { threadId = thread_id, turnId = runtime.active_turn_id })
  end

  if message.type == "agent_end" then
    return notification("pi/agent_end", {
      threadId = thread_id,
      turnId = runtime.active_turn_id or runtime.last_turn_id,
      messages = message.messages,
      willRetry = message.willRetry,
    })
  end

  if message.type == "agent_settled" then
    runtime.active_turn_id = nil
    runtime.reserved_turn = nil
    runtime.turn_start_pending = false
    runtime.queued_turns = {}
    reset_turn_stream_state()
    return notification("pi/agent_settled", { threadId = thread_id })
  end

  if message.type == "queue_update" then
    return notification("pi/queue_update", {
      threadId = thread_id,
      steering = message.steering,
      followUp = message.followUp,
    })
  end

  if message.type == "compaction_start" then
    return notification("pi/compaction_start", {
      threadId = thread_id,
      reason = message.reason,
    })
  end

  if message.type == "compaction_end" then
    return notification("pi/compaction_end", {
      threadId = thread_id,
      result = message.result,
      reason = message.reason,
      aborted = message.aborted,
      willRetry = message.willRetry,
      errorMessage = message.errorMessage,
    })
  end

  if message.type == "auto_retry_start" or message.type == "auto_retry_end" or message.type == "extension_error" then
    return notification("pi/" .. message.type, vim.tbl_extend("force", { threadId = thread_id }, message))
  end

  if message.type == "message_start" then
    return message_start_notifications(message.message, thread_id)
  end

  if not turn_scoped_events[message.type] then
    return notification(
      "pi/" .. tostring(message.type or "event"),
      vim.tbl_extend("force", { threadId = thread_id }, message)
    )
  end

  local turn_id = event_turn_id()

  if message.type == "turn_end" then
    local out = {}
    for _, item in ipairs(message_items(message.message, "completed")) do
      table.insert(
        out,
        notification("item/completed", {
          threadId = thread_id,
          turnId = turn_id,
          item = item,
        })
      )
    end
    table.insert(
      out,
      notification("turn/completed", {
        threadId = thread_id,
        turn = { id = turn_id },
      })
    )
    runtime.last_turn_id = turn_id
    runtime.active_turn_id = nil
    return notifications(out)
  end

  if message.type == "message_update" then
    local event = type(message.assistantMessageEvent) == "table" and message.assistantMessageEvent or {}
    local index = tonumber(event.contentIndex) or 0
    if event.type == "text_delta" then
      return notification("item/agentMessage/delta", {
        threadId = thread_id,
        turnId = turn_id,
        itemId = assistant_item_id(index),
        delta = event.delta,
      })
    end
    if event.type == "thinking_delta" then
      return notification("item/reasoning/textDelta", {
        threadId = thread_id,
        turnId = turn_id,
        itemId = reasoning_item_id(index),
        contentIndex = 0,
        delta = event.delta,
      })
    end
    if event.type == "toolcall_start" or event.type == "toolcall_delta" then
      local item = tool_item_from_call(tool_call_from_event(event, index), "running")
      if not item then
        return nil
      end
      return notification("item/started", {
        threadId = thread_id,
        turnId = turn_id,
        item = item,
      })
    end
    if event.type == "toolcall_end" then
      local item = tool_item_from_call(tool_call_from_event(event, index), "completed")
      if not item then
        return nil
      end
      return notification("item/completed", {
        threadId = thread_id,
        turnId = turn_id,
        item = item,
      })
    end
    return nil
  end

  if message.type == "message_end" then
    local out = {}
    for _, item in ipairs(message_items(message.message, "completed")) do
      table.insert(
        out,
        notification("item/completed", {
          threadId = thread_id,
          turnId = turn_id,
          item = item,
        })
      )
    end
    return #out > 0 and notifications(out) or nil
  end

  if message.type == "tool_execution_start" then
    runtime.tool_args[tostring(message.toolCallId)] = message.args
    local item = tool_item(message.toolCallId, message.toolName, message.args, "running")
    if not item then
      return nil
    end
    return notification("item/started", {
      threadId = thread_id,
      turnId = turn_id,
      item = item,
    })
  end

  if message.type == "tool_execution_update" then
    runtime.tool_args[tostring(message.toolCallId)] = message.args or runtime.tool_args[tostring(message.toolCallId)]
    local item_type = tool_item_type(message.toolName)
    if item_type == "commandExecution" then
      return notification("item/commandExecution/outputDelta", {
        threadId = thread_id,
        turnId = turn_id,
        itemId = tostring(message.toolCallId),
        delta = tool_update_delta(message.toolCallId, message.partialResult),
      })
    end
    return notification("item/mcpToolCall/progress", {
      threadId = thread_id,
      turnId = turn_id,
      itemId = tostring(message.toolCallId),
      toolName = message.toolName,
      args = runtime.tool_args[tostring(message.toolCallId)],
      delta = tool_update_delta(message.toolCallId, message.partialResult),
      progress = message.partialResult,
    })
  end

  if message.type == "tool_execution_end" then
    local item = tool_item(
      message.toolCallId,
      message.toolName,
      message.args,
      message.isError and "error" or "completed",
      message.result
    )
    if not item then
      return nil
    end
    return notification("item/completed", {
      threadId = thread_id,
      turnId = turn_id,
      item = item,
    })
  end

  return nil
end

local function extension_response(rpc, message, payload)
  if not (rpc and rpc.send and message and message.id) then
    return
  end
  payload = payload or {}
  payload.type = "extension_ui_response"
  payload.id = message.id
  rpc.send(payload)
end

local function extension_prompt(message, fallback)
  return util.value(message.title) or util.value(message.message) or fallback
end

local function branch_snapshot_request(message)
  local options = type(message) == "table" and type(message.options) == "table" and message.options or {}
  return type(options[1]) == "table" and options[1].__coactNvimPiBranchSnapshot == true
end

local function handle_branch_snapshot_request(message, rpc)
  local options = type(message.options) == "table" and message.options or {}
  runtime.branch_snapshot = normalize_branch_snapshot(options[1])
  annotate_current_thread_tree_entry_ids(runtime.current_thread_id or current_thread_id(), runtime.branch_snapshot)
  extension_response(rpc, message, { value = "ok" })
end

local function provider_ui_thread()
  if runtime.suppress_state_updates then
    return nil
  end
  local ok, coact_state = pcall(require, "coact.state")
  if not ok then
    return nil
  end
  return coact_state.ensure_thread(current_thread_id())
end

local function refresh_provider_ui(thread, render_history)
  if not thread then
    return
  end
  local ok, buffers = pcall(require, "coact.buffers")
  if ok then
    if buffers.refresh_composer then
      buffers.refresh_composer(thread)
    end
    if buffers.refresh_chrome then
      buffers.refresh_chrome(thread)
    end
    if render_history and buffers.schedule_render then
      buffers.schedule_render(thread.id)
    end
  end
end

local function ensure_provider_ui(thread)
  local ui = provider_ui_store()
  if thread then
    thread.provider_ui = ui
  end
  return ui
end

local function handle_set_status(message)
  local key = util.value(message.statusKey) or "status"
  key = tostring(key)
  if key == "" then
    key = "status"
  end
  local thread = provider_ui_thread()
  if not thread then
    return true
  end
  local text = util.value(message.statusText)
  if key == tree_summary_status_key then
    if text == nil or text == "" then
      if thread.generation == "summarizing" then
        local queued = false
        local ok, coact_state = pcall(require, "coact.state")
        if ok then
          for _, pending in ipairs(coact_state.get_thread_pending_requests(thread)) do
            if type(pending) == "table" and (pending.streaming_behavior or pending.streamingBehavior) then
              queued = true
              break
            end
          end
        end
        if queued then
          thread.generation = "submitted"
          thread.status_message = "Pi has a queued follow-up..."
        else
          thread.generation = "idle"
          thread.status_message = nil
        end
      end
    else
      thread.generation = "summarizing"
      thread.status_message = "Pi is summarizing a branch..."
    end
    refresh_provider_ui(thread, true)
    return true
  end
  local ui = ensure_provider_ui(thread)
  if text == nil or text == "" then
    ui.statuses[key] = nil
  else
    ui.statuses[key] = tostring(text)
  end
  refresh_provider_ui(thread)
  return true
end

local function handle_set_widget(message)
  local key = util.value(message.widgetKey) or "widget"
  key = tostring(key)
  if key == "" then
    key = "widget"
  end
  local placement = util.value(message.widgetPlacement) == "belowEditor" and "belowEditor" or "aboveEditor"
  local thread = provider_ui_thread()
  if not thread then
    return true
  end
  local ui = ensure_provider_ui(thread)
  local lines = message.widgetLines
  if type(lines) ~= "table" or #lines == 0 then
    ui.widgets.aboveEditor[key] = nil
    ui.widgets.belowEditor[key] = nil
  else
    local normalized = {}
    for _, line in ipairs(lines) do
      table.insert(normalized, tostring(line))
    end
    ui.widgets.aboveEditor[key] = nil
    ui.widgets.belowEditor[key] = nil
    ui.widgets[placement][key] = { lines = normalized }
  end
  refresh_provider_ui(thread)
  return true
end

local function handle_set_title(message)
  local thread = provider_ui_thread()
  if not thread then
    return true
  end
  local ui = ensure_provider_ui(thread)
  ui.title = util.value(message.title)
  refresh_provider_ui(thread)
  return true
end

function M.handle_raw_message(message, rpc)
  if type(message) ~= "table" or message.type ~= "extension_ui_request" then
    return false
  end
  if message.method == "notify" then
    local level = message.notifyType == "error" and vim.log.levels.ERROR
      or message.notifyType == "warning" and vim.log.levels.WARN
      or vim.log.levels.INFO
    util.notify(message.message or "Pi notification", level)
    return true
  end
  if message.method == "select" then
    local bridge_ok, nvim_bridge = pcall(require, "coact.providers.pi_nvim_bridge")
    if bridge_ok and nvim_bridge.is_request(message) then
      schedule_with_runtime(function()
        local result = nvim_bridge.handle_request(message, {
          thread_id = current_thread_id(),
        })
        extension_response(rpc, message, { value = result })
      end)
      return true
    end
    if branch_snapshot_request(message) then
      handle_branch_snapshot_request(message, rpc)
      return true
    end
    local ok, pi_tree = pcall(require, "coact.providers.pi_tree")
    if ok and pi_tree.is_request(message) then
      schedule_with_runtime(function()
        pi_tree.select(
          message,
          bind_runtime_callback(function(choice)
            local tree_action = normalize_tree_action(choice)
            if choice == nil then
              runtime.last_tree_action = { __coactNvimPiTreeAction = true, action = "cancel" }
              extension_response(rpc, message, { cancelled = true })
            else
              if tree_action then
                runtime.last_tree_action = tree_action
              end
              extension_response(rpc, message, { value = choice })
            end
          end),
          { thread_id = current_thread_id() }
        )
      end)
      return true
    end
    schedule_with_runtime(function()
      local options = type(message.options) == "table" and message.options or {}
      vim.ui.select(options, { prompt = extension_prompt(message, "Pi select") }, function(choice)
        if choice == nil then
          extension_response(rpc, message, { cancelled = true })
        else
          extension_response(rpc, message, { value = choice })
        end
      end)
    end)
    return true
  end
  if message.method == "confirm" then
    schedule_with_runtime(function()
      local prompt = extension_prompt(message, "Pi confirm")
      vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
        if choice == nil then
          extension_response(rpc, message, { cancelled = true })
        else
          extension_response(rpc, message, { confirmed = choice == "Yes" })
        end
      end)
    end)
    return true
  end
  if message.method == "input" or message.method == "editor" then
    schedule_with_runtime(function()
      vim.ui.input({
        prompt = extension_prompt(message, message.method == "editor" and "Pi editor" or "Pi input") .. ": ",
        default = util.value(message.prefill) or "",
      }, function(value)
        if value == nil then
          extension_response(rpc, message, { cancelled = true })
        else
          extension_response(rpc, message, { value = value })
        end
      end)
    end)
    return true
  end
  if message.method == "set_editor_text" then
    local ok, buffers = pcall(require, "coact.buffers")
    if ok and buffers.set_prompt_text then
      buffers.set_prompt_text(current_thread_id(), util.value(message.text) or "")
    end
    return true
  end
  if message.method == "setStatus" then
    return handle_set_status(message)
  end
  if message.method == "setWidget" then
    return handle_set_widget(message)
  end
  if message.method == "setTitle" then
    return handle_set_title(message)
  end
  extension_response(rpc, message, { cancelled = true })
  return true
end

function M.command_label()
  return "Pi RPC"
end

function M.executable(opts)
  local command = M.command(opts or config.get())
  if type(command) == "table" then
    return command[1]
  end
  if type(command) == "string" then
    return vim.split(command, "%s+", { trimempty = true })[1]
  end
  return nil
end

function M.health(opts, health)
  opts = opts or config.get()
  health.info("active provider: pi")
  local command = M.command(opts)
  local executable = M.executable(opts)
  if executable and vim.fn.executable(executable) == 1 then
    health.ok(("Pi executable found: %s"):format(executable))
    local version, err = health.system_text({ executable, "--version" }, 5000)
    if version and version ~= "" then
      health.info(version)
    elseif err and err ~= "" then
      health.info(("Could not read Pi version without startup warnings: %s"):format(vim.trim(err)))
    end
    local help_text, help_err = health.system_text({ executable, "--help" }, 5000)
    if help_text and help_text:match("%-%-mode <mode>") and help_text:match("rpc") then
      health.ok("Pi executable supports RPC mode")
    else
      health.error(("Pi executable does not appear to support RPC mode: %s"):format(vim.trim(help_err or "")))
    end
    if help_text and help_text:match("%-%-session%-id") then
      health.ok("Pi executable supports preassigned session ids")
    else
      health.error("Pi executable does not support --session-id, which Coact uses for immediate new-session buffers")
    end
  else
    health.error(("Pi executable is not available: %s"):format(executable or health.command_label(command)))
  end
  health.ok(("Pi command configured: %s"):format(health.command_label(command)))
end

M._runtime = default_runtime
M._prompt_from_input = prompt_from_input
M._thread_from_state = thread_from_state
M._session_dir_for_cwd = configured_session_dir
M._list_local_sessions = list_local_sessions
M._clear_session_info_cache = function()
  session_info_cache = {}
end
M._resolve_session_file = resolve_session_file
M._normalize_model = normalize_model
M._message_items = message_items
M._tool_update_delta = tool_update_delta
M._normalize_branch_snapshot = normalize_branch_snapshot
M._refresh_current_thread = refresh_current_thread

return M
