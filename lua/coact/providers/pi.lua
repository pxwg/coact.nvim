local config = require("coact.config")
local util = require("coact.util")

local M = {
  name = "pi",
  title = "Pi",
  agent_label = "Pi",
  protocol = "pi-rpc",
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
      stop = true,
      tree = true,
    },
    reasoning_label = "thinking",
    reasoning_effort_title = "thinking level",
    reasoning_efforts = {
      { label = "default", value = vim.NIL },
      { label = "off", value = "off" },
      { label = "minimal", value = "minimal" },
      { label = "low", value = "low" },
      { label = "medium", value = "medium" },
      { label = "high", value = "high" },
      { label = "xhigh", value = "xhigh" },
    },
    reasoning_summaries = false,
    return_forms = {
      reasoning = "select(Pi thinking level) -> notify(set_thinking_level)",
      skills = "select(get_commands source=skill) -> insert($skill:<name>)",
      status = "page(get_state + get_session_stats + local thread status)",
      tree = "select(Pi session tree) -> notify(thread/tree) -> refresh thread",
    },
  },
}

local runtime = {
  session_id = nil,
  session_file = nil,
  session_name = nil,
  current_thread_id = nil,
  active_turn_id = nil,
  last_turn_id = nil,
  turn_seq = 0,
  tool_output = {},
  tool_args = {},
  tool_calls = {},
}

local thinking_levels = {
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
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

function M.command(opts)
  opts = opts or config.get()
  local pi = provider_opts(opts)
  local command = pi.command or { "pi", "--mode", "rpc" }
  local args = {}
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

function M.prepare_command(command, env)
  return require("coact.providers.pi_edit_bridge").prepare_command(command, env)
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

function M._remember_state(state)
  if type(state) ~= "table" then
    return nil
  end
  runtime.session_id = util.value(state.sessionId) or runtime.session_id
  runtime.session_file = util.value(state.sessionFile) or runtime.session_file
  runtime.session_name = util.value(state.sessionName) or runtime.session_name
  runtime.current_thread_id = state_thread_id(state)
  return runtime.current_thread_id
end

local function current_thread_id()
  local ok, state = pcall(require, "coact.state")
  if ok and state.active_thread_id then
    return runtime.current_thread_id or state.active_thread_id
  end
  return runtime.current_thread_id or "pi:session"
end

local function current_turn_id()
  if runtime.active_turn_id then
    return runtime.active_turn_id
  end
  runtime.active_turn_id = next_turn_id()
  runtime.last_turn_id = runtime.active_turn_id
  return runtime.active_turn_id
end

local function event_turn_id()
  return runtime.active_turn_id or runtime.last_turn_id or current_turn_id()
end

local function model_id(model)
  if type(model) ~= "table" then
    return nil
  end
  local provider = util.value(model.provider)
  local id = util.value(model.id) or util.value(model.model)
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

local function read_session_info(path, cwd_filter)
  if not readable_file(path) then
    return nil
  end
  local lines = vim.fn.readfile(path)
  local header = json_decode(lines[1])
  if type(header) ~= "table" or header.type ~= "session" or not util.value(header.id) then
    return nil
  end
  local cwd = normalize_path(util.value(header.cwd)) or normalize_cwd()
  if cwd_filter and normalize_cwd(cwd_filter) ~= cwd then
    return nil
  end

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
    messageCount = message_count,
    model = model,
    modelProvider = model_provider,
    reasoningEffort = thinking,
    updated_at = updated_at,
    updatedAt = updated_at,
    _sort = modified,
  }
end

local function list_local_sessions(cwd, opts)
  cwd = normalize_cwd(cwd)
  local dir, filter_by_cwd = configured_session_dir(cwd, opts)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return {}
  end
  local sessions = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:match("%.jsonl$") then
      local info = read_session_info(vim.fs.joinpath(dir, name), filter_by_cwd and cwd or nil)
      if info then
        table.insert(sessions, info)
      end
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

local function user_item(turn_id, text, input)
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
    id = turn_id .. ":user",
    type = "userMessage",
    status = "submitted",
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

local function normalize_model(model)
  model = type(model) == "table" and model or {}
  local id = model_id(model) or util.value(model.id) or util.value(model.model)
  if not id then
    return nil
  end
  local supported = {}
  for _, level in ipairs(thinking_levels) do
    table.insert(supported, { effort = level })
  end
  return {
    id = id,
    model = id,
    provider = util.value(model.provider),
    displayName = util.value(model.name) or id,
    description = util.value(model.description),
    contextWindow = util.value(model.contextWindow),
    supportedReasoningEfforts = supported,
    defaultReasoningEffort = "medium",
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

local function read_current_thread(rpc, params, callback, opts)
  opts = opts or {}
  rpc._request_message("get_state", {}, function(err, state_result)
    if err then
      callback(err, nil)
      return
    end
    local thread = thread_from_state(state_result, params)
    if opts.replace_turns == true then
      thread.replaceTurns = true
    end
    rpc._request_message("get_messages", {}, function(messages_err, messages_result)
      if messages_err then
        callback(nil, { thread = thread })
        return
      end
      thread.turns = M._turns_from_messages(messages_result and messages_result.messages, thread.id)
      callback(nil, { thread = thread })
    end)
  end)
end

function M.custom_request(rpc, method, params, callback)
  params = params or {}
  if method == "thread/start" then
    rpc._request_message("new_session", {}, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      if result and result.cancelled then
        callback({ message = "Pi new_session was cancelled" }, nil)
        return
      end
      rpc._request_message("get_state", {}, function(state_err, state_result)
        if state_err then
          callback(state_err, nil)
          return
        end
        callback(nil, { thread = thread_from_state(state_result, params) })
      end)
    end)
    return true
  end

  if method == "thread/read" or method == "thread/resume" then
    local session_file = resolve_session_file(params.cwd or config.cwd(), params.threadId)
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
      read_current_thread(rpc, params, callback)
    end
    return true
  end

  if method == "thread/tree" then
    runtime.current_thread_id = params.threadId or current_thread_id()
    rpc._request_message("prompt", { message = "/coact-nvim-tree" }, function(err, result)
      if err then
        callback(err, nil)
        return
      end
      if result and result.cancelled then
        callback({ message = "Pi tree navigation was cancelled" }, nil)
        return
      end
      read_current_thread(rpc, params, callback, { replace_turns = true })
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
    runtime.active_turn_id = turn_id
    runtime.last_turn_id = turn_id
    runtime.tool_output = {}
    runtime.tool_args = {}
    runtime.tool_calls = {}
    local message, images = prompt_from_input(params.input)
    if message == "" and #images == 0 then
      callback({ message = "Pi prompt is empty" }, nil)
      return true
    end
    rpc._request_message("prompt", {
      message = message,
      images = #images > 0 and images or nil,
      streamingBehavior = params.streamingBehavior,
    }, function(err)
      if err then
        callback(err, nil)
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
    rpc._request_message("get_session_stats", {}, callback)
    return true
  end

  if method == "thread/compact/start" then
    rpc._request_message("compact", {}, callback)
    return true
  end

  return false
end

local function assistant_item_id(index)
  return current_turn_id() .. ":assistant:" .. tostring(index or 0)
end

local function reasoning_item_id(index)
  return current_turn_id() .. ":reasoning:" .. tostring(index or 0)
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

local function message_items(message, status)
  local items = {}
  if type(message) ~= "table" or message.role ~= "assistant" then
    return items
  end
  for index, block in ipairs(type(message.content) == "table" and message.content or {}) do
    local zero_index = index - 1
    if block.type == "text" then
      table.insert(items, {
        id = assistant_item_id(zero_index),
        type = "agentMessage",
        status = status,
        text = tostring(block.text or ""),
      })
    elseif block.type == "thinking" then
      table.insert(items, {
        id = reasoning_item_id(zero_index),
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
      id = assistant_item_id(0),
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

function M._turns_from_messages(messages, thread_id)
  local turns = {}
  local turn_index = 0
  for _, message in ipairs(type(messages) == "table" and messages or {}) do
    if message.role == "user" then
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
                text = text_content(message.content),
              },
            },
          },
        },
      })
    elseif message.role == "assistant" then
      local turn = turns[#turns]
      if not turn then
        turn_index = turn_index + 1
        turn = { id = ("pi-history-%d"):format(turn_index), items = {} }
        table.insert(turns, turn)
      end
      local old_turn = runtime.active_turn_id
      runtime.active_turn_id = turn.id
      vim.list_extend(turn.items, message_items(message, "completed"))
      runtime.active_turn_id = old_turn
    elseif message.role == "toolResult" then
      local turn = turns[#turns]
      if turn then
        table.insert(turn.items, tool_item(message.toolCallId, message.toolName, {}, "completed", message))
      end
    end
  end
  return turns
end

function M.decode_notification(message)
  if type(message) ~= "table" or message.type == "response" then
    return nil
  end
  local thread_id = current_thread_id()
  local turn_id = event_turn_id()

  if message.type == "turn_start" then
    return notification("turn/started", {
      threadId = thread_id,
      turn = { id = turn_id },
    })
  end

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

  if message.type == "agent_start" then
    return notification("pi/agent_start", { threadId = thread_id, turnId = turn_id })
  end

  if message.type == "agent_end" then
    return notification("pi/agent_end", { threadId = thread_id, turnId = turn_id, messages = message.messages })
  end

  if message.type == "message_start" then
    local items = message_items(message.message, "running")
    local out = {}
    for _, item in ipairs(items) do
      table.insert(
        out,
        notification("item/started", {
          threadId = thread_id,
          turnId = turn_id,
          item = item,
        })
      )
    end
    return #out > 0 and notifications(out) or nil
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
    return notification("thread/compacted", {
      threadId = thread_id,
      result = message.result,
      reason = message.reason,
    })
  end

  if message.type == "auto_retry_start" or message.type == "auto_retry_end" or message.type == "extension_error" then
    return notification("pi/" .. message.type, vim.tbl_extend("force", { threadId = thread_id }, message))
  end

  return notification(
    "pi/" .. tostring(message.type or "event"),
    vim.tbl_extend("force", { threadId = thread_id }, message)
  )
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
    local ok, pi_tree = pcall(require, "coact.providers.pi_tree")
    if ok and pi_tree.is_request(message) then
      vim.schedule(function()
        pi_tree.select(message, function(choice)
          if choice == nil then
            extension_response(rpc, message, { cancelled = true })
          else
            extension_response(rpc, message, { value = choice })
          end
        end)
      end)
      return true
    end
    vim.schedule(function()
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
    vim.schedule(function()
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
    vim.schedule(function()
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
  if message.method == "setTitle" or message.method == "setStatus" or message.method == "setWidget" then
    return true
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
  else
    health.error(("Pi executable is not available: %s"):format(executable or health.command_label(command)))
  end
  health.ok(("Pi command configured: %s"):format(health.command_label(command)))
end

M._runtime = runtime
M._prompt_from_input = prompt_from_input
M._thread_from_state = thread_from_state
M._session_dir_for_cwd = configured_session_dir
M._list_local_sessions = list_local_sessions
M._resolve_session_file = resolve_session_file
M._normalize_model = normalize_model
M._message_items = message_items
M._tool_update_delta = tool_update_delta

return M
