local config = require("codex.config")
local rpc = require("codex.rpc")
local state = require("codex.state")
local util = require("codex.util")

local M = {}

local commands = {
  { name = "permissions", detail = "Set what Codex can do without asking first", category = "settings" },
  { name = "sandbox", detail = "Choose the active sandbox policy", category = "settings" },
  { name = "ide", detail = "Include IDE context in a prompt", category = "context" },
  { name = "keymap", detail = "Configure CLI keybindings", category = "cli" },
  { name = "vim", detail = "Toggle CLI composer Vim mode", category = "cli" },
  {
    name = "sandbox-add-read-dir",
    detail = "Grant sandbox read access to an extra directory",
    category = "settings",
  },
  { name = "agent", detail = "Switch the active agent thread", category = "threads" },
  { name = "apps", detail = "Browse apps and insert app mentions", category = "context" },
  { name = "plugins", detail = "Browse plugins", category = "context" },
  { name = "hooks", detail = "Review lifecycle hooks", category = "settings" },
  { name = "clear", detail = "Clear the UI and start a fresh chat", category = "threads" },
  { name = "compact", detail = "Summarize the conversation to free tokens", category = "threads" },
  { name = "copy", detail = "Copy the latest completed Codex output", category = "ui" },
  { name = "diff", detail = "Show the Git diff, including untracked files", category = "workspace" },
  { name = "exit", detail = "Exit the CLI", category = "cli", aliases = { "quit" } },
  { name = "quit", detail = "Exit the CLI", category = "cli", aliases = { "exit" } },
  { name = "experimental", detail = "Toggle experimental features", category = "settings" },
  { name = "approve", detail = "Approve one retry of a recent auto-review denial", category = "approvals" },
  { name = "memories", detail = "Configure memory use", category = "settings" },
  { name = "skills", detail = "Browse and use skills", category = "context" },
  { name = "feedback", detail = "Send diagnostics to Codex maintainers", category = "support" },
  { name = "init", detail = "Generate an AGENTS.md scaffold", category = "workspace" },
  { name = "logout", detail = "Sign out of Codex", category = "account" },
  { name = "mcp", detail = "List configured MCP tools", category = "tools" },
  { name = "mention", detail = "Attach a file to the conversation", category = "context" },
  { name = "model", detail = "Choose the active model and thinking effort", category = "settings" },
  { name = "fast", detail = "Toggle the current model's Fast tier", category = "settings" },
  { name = "reasoning", detail = "Choose reasoning effort and summary", category = "settings" },
  { name = "plan", detail = "Switch to plan mode and optionally send a prompt", category = "mode" },
  { name = "goal", detail = "Set, view, pause, resume, or clear a task goal", category = "threads" },
  { name = "personality", detail = "Choose a communication style", category = "settings" },
  { name = "ps", detail = "Show experimental background terminals", category = "tools" },
  { name = "stop", detail = "Stop the current turn or background terminals", category = "threads" },
  { name = "fork", detail = "Fork the current conversation into a new thread", category = "threads" },
  { name = "side", detail = "Start an ephemeral side conversation", category = "threads" },
  { name = "raw", detail = "Toggle raw event scrollback", category = "ui" },
  { name = "resume", detail = "Resume a saved conversation", category = "threads" },
  { name = "new", detail = "Start a new conversation", category = "threads" },
  { name = "review", detail = "Ask Codex to review the working tree", category = "workspace" },
  { name = "status", detail = "Display session configuration and token usage", category = "status" },
  { name = "debug-config", detail = "Print config layer and requirements diagnostics", category = "status" },
  { name = "statusline", detail = "Configure CLI status-line fields", category = "cli" },
  { name = "title", detail = "Configure CLI terminal title fields", category = "cli" },
  { name = "theme", detail = "Choose a syntax-highlighting theme", category = "ui" },
  { name = "settings", detail = "Open codex.nvim settings", category = "settings" },
  { name = "help", detail = "Show slash command help", category = "status" },
}

local return_forms = {
  permissions = "select(local presets + permissionProfile/list) -> notify(thread/settings/update)",
  sandbox = "select(local sandbox policies) -> notify(thread/settings/update)",
  ide = "notify(unsupported in codex.nvim)",
  keymap = "notify(unsupported in codex.nvim)",
  vim = "notify(unsupported in codex.nvim)",
  ["sandbox-add-read-dir"] = "notify(unsupported in codex.nvim)",
  agent = "notify(unsupported in codex.nvim)",
  apps = "notify(unsupported in codex.nvim)",
  plugins = "notify(unsupported in codex.nvim)",
  hooks = "page(hooks/list)",
  clear = "action(thread/start)",
  compact = "notify(thread/compact/start)",
  copy = "action(register write) -> notify",
  diff = "page(git status + git diff)",
  exit = "notify(unsupported in codex.nvim)",
  quit = "notify(unsupported in codex.nvim)",
  experimental = "select(experimentalFeature/list) -> notify(experimentalFeature/enablement/set)",
  approve = "notify(unsupported in codex.nvim)",
  memories = "select(local modes) -> notify(thread/memoryMode/set)",
  skills = "select(skills/list) -> insert($skill:<name>)",
  feedback = "notify(unsupported in codex.nvim)",
  init = "notify(unsupported in codex.nvim)",
  logout = "notify(account/logout)",
  mcp = "page(mcpServerStatus/list)",
  mention = "notify(use @file:/@image:)",
  model = "select(model/list) -> select(supported thinking effort) -> notify(thread/settings/update)",
  fast = "select(model/list service tiers) -> notify(thread/settings/update)",
  reasoning = "select(local reasoning effort + summary) -> notify(thread/settings/update)",
  plan = "notify(unsupported in codex.nvim)",
  goal = "page/action(thread/goal/get|set|clear)",
  personality = "select(local personalities) -> notify(thread/settings/update)",
  ps = "notify(unsupported in codex.nvim)",
  stop = "action(turn/interrupt)",
  fork = "action(thread/fork)",
  side = "action(thread/fork ephemeral)",
  raw = "action(local render toggle) -> notify",
  resume = "action(thread/resume or picker)",
  new = "action(thread/start)",
  review = "notify(review/start)",
  status = "page(config/read + account/rateLimits/read + local thread status)",
  ["debug-config"] = "page(config/read + configRequirements/read)",
  statusline = "notify(unsupported in codex.nvim)",
  title = "notify(unsupported in codex.nvim)",
  theme = "notify(Neovim colorscheme-owned)",
  settings = "select(local settings menu)",
  help = "page(static slash catalog)",
}

local by_name = {}
for _, command in ipairs(commands) do
  by_name[command.name] = command
  for _, alias in ipairs(command.aliases or {}) do
    by_name[alias] = command
  end
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function first_line(value)
  return tostring(value or ""):match("^[^\n]*") or ""
end

local function notify(message, level)
  util.notify(message, level)
end

local function is_nil(value)
  return value == nil or value == vim.NIL
end

local function text(value, fallback)
  if is_nil(value) then
    return fallback or ""
  end
  return tostring(value)
end

local function text_or_nil(value)
  if is_nil(value) or value == "" then
    return nil
  end
  return tostring(value)
end

local function as_table(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function as_table_or_nil(value)
  if type(value) == "table" then
    return value
  end
  return nil
end

local function field(value, key)
  local object = as_table_or_nil(value)
  return object and object[key] or nil
end

local function ensure_server(actions, callback)
  actions = actions or {}
  if actions.ensure_server then
    actions.ensure_server(function()
      callback()
    end)
    return
  end
  if rpc.is_running() then
    callback()
    return
  end
  rpc.start(function(err)
    if err then
      notify("codex app-server failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    callback()
  end)
end

local function current_thread_id(thread_id)
  if thread_id and thread_id ~= "" then
    return thread_id
  end
  local current = state.thread_for_buf(0)
  if current then
    return current.id
  end
  return state.active_thread_id
end

local function need_thread(thread_id)
  local id = current_thread_id(thread_id)
  if not id then
    notify("no active Codex thread", vim.log.levels.WARN)
    return nil
  end
  return id
end

local function open_lines(title, lines)
  lines = as_table(lines)
  if #lines == 0 then
    lines = { "" }
  end
  local normalized = {}
  for _, line in ipairs(lines) do
    line = text(line)
    if line == "" then
      table.insert(normalized, "")
    else
      vim.list_extend(normalized, util.split_lines(line))
    end
  end
  lines = normalized
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codex-slash"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local max_width = 100
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line) + 4)
  end
  local width = math.min(math.max(60, math.floor(vim.o.columns * 0.72)), max_width, vim.o.columns - 4)
  local height = math.min(math.max(8, math.floor(vim.o.lines * 0.55)), #lines, vim.o.lines - 6)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local opts = {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = " " .. title .. " ",
    title_pos = "center",
  }
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, opts)
  if not ok then
    vim.cmd("botright split")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end, { buffer = bufnr, silent = true, desc = "Close Codex slash page" })
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end, { buffer = bufnr, silent = true, desc = "Close Codex slash page" })
end

local present_result

local function result(kind, attrs)
  attrs = attrs or {}
  attrs.kind = kind
  return attrs
end

local function page(title, lines, opts)
  opts = opts or {}
  return result("page", {
    title = title,
    lines = lines,
    source = opts.source,
  })
end

local function select_result(opts)
  opts = opts or {}
  opts.kind = "select"
  return opts
end

local function notify_result(message, level)
  return result("notify", {
    message = message,
    level = level,
  })
end

local function insert_result(insert_text)
  return result("insert", {
    text = insert_text,
  })
end

local function action_result(run)
  return result("action", {
    run = run,
  })
end

local function select_one(items, opts, callback)
  opts = opts or {}
  items = as_table(items)
  if #items == 0 then
    notify(opts.empty_message or "no choices available", vim.log.levels.WARN)
    return
  end
  local format_item = opts.format_item
    or function(item)
      if type(item) == "table" then
        return item.label or item.name or item.id or item
      end
      return item
    end
  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = function(item)
      return text(format_item(item))
    end,
  }, function(choice)
    if choice then
      present_result(callback(choice))
    end
  end)
end

present_result = function(value)
  if is_nil(value) then
    return
  end
  if type(value) == "function" then
    value()
    return
  end
  if type(value) ~= "table" then
    notify(tostring(value))
    return
  end
  if value.kind == "page" then
    local lines = vim.deepcopy(as_table(value.lines))
    if text_or_nil(value.source) then
      local insert_at = (#lines > 0 and text(lines[1]):match("^#")) and 2 or 1
      table.insert(lines, insert_at, "source: " .. text(value.source))
      if lines[insert_at + 1] ~= "" then
        table.insert(lines, insert_at + 1, "")
      end
    end
    open_lines(value.title or "Codex", lines)
    return
  end
  if value.kind == "select" then
    select_one(as_table(value.items), {
      prompt = value.prompt or value.title,
      empty_message = value.empty_message,
      format_item = value.format_item,
    }, value.on_select or function() end)
    return
  end
  if value.kind == "notify" then
    notify(text(value.message), value.level)
    return
  end
  if value.kind == "insert" then
    vim.api.nvim_put({ text(value.text) }, "c", true, true)
    return
  end
  if value.kind == "action" then
    if value.run then
      value.run()
    end
    return
  end
  if value.kind == "sequence" then
    for _, child in ipairs(as_table(value.items)) do
      present_result(child)
    end
  end
end

local function setting_value(value)
  if is_nil(value) then
    return "default"
  end
  return tostring(value)
end

local function current_cfg()
  return config.get().thread
end

local function schedule_thread_render(thread_id)
  local ok, buffers = pcall(require, "codex.buffers")
  if ok and buffers.schedule_render then
    buffers.schedule_render(thread_id)
  end
end

local function sandbox_policy(mode)
  if mode == "danger-full-access" then
    return { type = "dangerFullAccess" }
  end
  if mode == "read-only" then
    return { type = "readOnly", networkAccess = false }
  end
  return {
    type = "workspaceWrite",
    writableRoots = { config.cwd() },
    networkAccess = false,
    excludeTmpdirEnvVar = false,
    excludeSlashTmp = false,
  }
end

local function apply_thread_settings(thread_id, params, message, actions)
  local id = current_thread_id(thread_id)
  if not id then
    present_result(notify_result(message .. " for future Codex turns"))
    return
  end
  params.threadId = id
  local thread = state.get_thread(id)
  local previous
  if thread then
    previous = {
      settings = vim.deepcopy(thread.settings),
      config = vim.deepcopy(thread.config),
      setting_clears = vim.deepcopy(thread.setting_clears),
    }
    thread.settings = params
    state.apply_thread_settings(thread, params)
    schedule_thread_render(id)
  end
  ensure_server(actions, function()
    rpc.request("thread/settings/update", params, function(err)
      if err then
        if thread and previous then
          thread.settings = previous.settings
          thread.config = previous.config or {}
          thread.setting_clears = previous.setting_clears or {}
          schedule_thread_render(id)
        end
        present_result(
          notify_result("thread/settings/update failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        )
        return
      end
      present_result(notify_result(message))
    end)
  end)
end

local function set_model_thread(model, actions, thread_id, effort_choice)
  local cfg = current_cfg()
  local model_name = model.model or model.id
  cfg.model = model_name
  cfg.service_tier = is_nil(model.defaultServiceTier) and nil or model.defaultServiceTier
  local params = { model = model_name, serviceTier = cfg.service_tier or vim.NIL }
  local message = "model set to " .. tostring(model_name)
  if effort_choice then
    cfg.reasoning_effort = is_nil(effort_choice.value) and nil or effort_choice.value
    params.effort = cfg.reasoning_effort or vim.NIL
    message = message .. " with effort " .. setting_value(cfg.reasoning_effort)
  end
  apply_thread_settings(thread_id, params, message, actions)
end

local function model_label(model)
  local label = text(model.displayName or model.model or model.id)
  local model_name = text(model.model or model.id)
  if model_name ~= "" and label ~= model_name then
    label = label .. " (" .. model_name .. ")"
  end
  local description = text_or_nil(model.description)
  if description then
    label = label .. " - " .. description
  end
  return label
end

local function request_models(actions, callback)
  ensure_server(actions, function()
    local all = {}
    local function page(cursor)
      rpc.request("model/list", { limit = 200, cursor = cursor, includeHidden = false }, function(err, result)
        if err then
          notify("model/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          callback({})
          return
        end
        for _, model in ipairs(as_table(field(result, "data"))) do
          if model.hidden ~= true then
            table.insert(all, model)
          end
        end
        local next_cursor = text_or_nil(field(result, "nextCursor"))
        if next_cursor then
          page(next_cursor)
        else
          table.sort(all, function(a, b)
            if a.isDefault ~= b.isDefault then
              return a.isDefault == true
            end
            return tostring(a.displayName or a.model or a.id) < tostring(b.displayName or b.model or b.id)
          end)
          callback(all)
        end
      end)
    end
    page(nil)
  end)
end

local function reasoning_effort_options(model)
  local supported = as_table(field(model, "supportedReasoningEfforts"))
  if #supported == 0 then
    return {}
  end
  local choices = {}
  local default_effort = text_or_nil(field(model, "defaultReasoningEffort"))
  table.insert(choices, {
    label = default_effort and ("default (" .. default_effort .. ")") or "default",
    value = vim.NIL,
    description = "Use the model default thinking effort",
  })
  local seen = {}
  for _, option in ipairs(supported) do
    local value = option.reasoningEffort or option.reasoning_effort or option.effort or option.value
    if not is_nil(value) then
      value = tostring(value)
      if not seen[value] then
        seen[value] = true
        table.insert(choices, {
          label = value,
          value = value,
          description = text_or_nil(option.description),
        })
      end
    end
  end
  return choices
end

local function reasoning_effort_label(choice)
  local label = text(choice.label)
  local description = text_or_nil(choice.description)
  if description then
    label = label .. " - " .. description
  end
  return label
end

local function open_model(actions, thread_id)
  request_models(actions, function(models)
    present_result(select_result({
      title = "Codex model",
      empty_message = "no Codex models available",
      items = models,
      format_item = model_label,
      on_select = function(model)
        local efforts = reasoning_effort_options(model)
        if #efforts == 0 then
          set_model_thread(model, actions, thread_id)
          return
        end
        return select_result({
          title = "Codex thinking effort",
          items = efforts,
          format_item = reasoning_effort_label,
          on_select = function(effort)
            set_model_thread(model, actions, thread_id, effort)
          end,
        })
      end,
    }))
  end)
end

local function set_service_tier(service_tier, actions, thread_id, label)
  current_cfg().service_tier = service_tier
  apply_thread_settings(thread_id, { serviceTier = service_tier or vim.NIL }, label, actions)
end

local function active_model_from_catalog(models)
  models = as_table(models)
  local cfg_model = current_cfg().model
  for _, model in ipairs(models) do
    if model.model == cfg_model or model.id == cfg_model or (not cfg_model and model.isDefault) then
      return model
    end
  end
  return models[1]
end

local function fast_tier(model)
  for _, tier in ipairs(as_table(field(model, "serviceTiers"))) do
    local haystack = (tostring(tier.id or "") .. " " .. tostring(tier.name or "")):lower()
    if haystack:find("fast", 1, true) then
      return tier
    end
  end
  return nil
end

local function open_fast(args, actions, thread_id)
  local arg = args[1] and args[1]:lower() or ""
  request_models(actions, function(models)
    local model = active_model_from_catalog(models)
    if not model then
      notify("no active model is available", vim.log.levels.WARN)
      return
    end
    local tier = fast_tier(model)
    if arg == "status" then
      local enabled = tier and current_cfg().service_tier == tier.id
      present_result(notify_result(("Fast tier: %s"):format(enabled and "on" or "off")))
      return
    end
    if arg == "on" then
      if not tier then
        present_result(notify_result("current model does not advertise a Fast service tier", vim.log.levels.WARN))
        return
      end
      set_service_tier(tier.id, actions, thread_id, "Fast tier enabled")
      return
    end
    if arg == "off" then
      set_service_tier(nil, actions, thread_id, "Fast tier disabled")
      return
    end
    local choices = {}
    table.insert(choices, { id = vim.NIL, label = "default", description = "Use model default service tier" })
    for _, service_tier in ipairs(as_table(field(model, "serviceTiers"))) do
      table.insert(choices, {
        id = service_tier.id,
        label = text(service_tier.name or service_tier.id),
        description = service_tier.description,
      })
    end
    present_result(select_result({
      title = "Codex service tier",
      items = choices,
      format_item = function(choice)
        local line = text(choice.label)
        local description = text_or_nil(choice.description)
        if description then
          line = line .. " - " .. description
        end
        return line
      end,
      on_select = function(choice)
        local value = is_nil(choice.id) and nil or choice.id
        set_service_tier(value, actions, thread_id, "service tier set to " .. setting_value(value))
      end,
    }))
  end)
end

local approval_choices = {
  {
    label = "ask before actions",
    approval_policy = "on-request",
    sandbox = "workspace-write",
    detail = "Workspace write; ask before elevated or risky actions",
  },
  {
    label = "auto within workspace",
    approval_policy = "on-failure",
    sandbox = "workspace-write",
    detail = "Workspace write; ask when commands fail under sandboxing",
  },
  {
    label = "read only",
    approval_policy = "on-request",
    sandbox = "read-only",
    detail = "No writes unless Codex asks for approval",
  },
  {
    label = "never ask",
    approval_policy = "never",
    sandbox = "workspace-write",
    detail = "Workspace write without approval prompts",
  },
  {
    label = "danger full access",
    approval_policy = "never",
    sandbox = "danger-full-access",
    detail = "No sandbox; use with care",
  },
}

local function apply_permission_choice(choice, actions, thread_id)
  local cfg = current_cfg()
  cfg.permissions = nil
  cfg.approval_policy = choice.approval_policy
  cfg.sandbox = choice.sandbox
  local params = {
    approvalPolicy = choice.approval_policy,
    sandboxPolicy = sandbox_policy(choice.sandbox),
  }
  apply_thread_settings(thread_id, params, "permissions set to " .. choice.label, actions)
end

local function apply_permission_profile(profile, actions, thread_id)
  local cfg = current_cfg()
  cfg.permissions = profile.id
  cfg.sandbox = nil
  local params = { permissions = profile.id }
  apply_thread_settings(thread_id, params, "permission profile set to " .. tostring(profile.id), actions)
end

local function open_permissions(actions, thread_id)
  ensure_server(actions, function()
    rpc.request("permissionProfile/list", { limit = 200, cwd = config.cwd() }, function(err, result)
      local choices = vim.deepcopy(approval_choices)
      if not err then
        for _, profile in ipairs(as_table(field(result, "data"))) do
          table.insert(choices, {
            label = "profile: " .. text(profile.id),
            profile = profile,
            detail = text_or_nil(profile.description) or "Codex permission profile",
          })
        end
      end
      present_result(select_result({
        title = "Codex permissions",
        items = choices,
        format_item = function(choice)
          local detail = text_or_nil(choice.detail)
          return text(choice.label) .. (detail and (" - " .. detail) or "")
        end,
        on_select = function(choice)
          if choice.profile then
            apply_permission_profile(choice.profile, actions, thread_id)
          else
            apply_permission_choice(choice, actions, thread_id)
          end
        end,
      }))
    end)
  end)
end

local function open_sandbox(actions, thread_id)
  local choices = {
    { label = "workspace-write", detail = "Allow writes in the current workspace" },
    { label = "read-only", detail = "No filesystem writes without approval" },
    { label = "danger-full-access", detail = "Disable sandboxing" },
  }
  return select_result({
    title = "Codex sandbox",
    items = choices,
    format_item = function(choice)
      return text(choice.label) .. " - " .. text(choice.detail)
    end,
    on_select = function(choice)
      local cfg = current_cfg()
      cfg.sandbox = choice.label
      cfg.permissions = nil
      apply_thread_settings(
        thread_id,
        { sandboxPolicy = sandbox_policy(choice.label) },
        "sandbox set to " .. choice.label,
        actions
      )
    end,
  })
end

local function open_reasoning(actions, thread_id)
  local efforts = {
    { label = "default", value = vim.NIL },
    { label = "none", value = "none" },
    { label = "minimal", value = "minimal" },
    { label = "low", value = "low" },
    { label = "medium", value = "medium" },
    { label = "high", value = "high" },
    { label = "xhigh", value = "xhigh" },
  }
  return select_result({
    title = "Codex reasoning effort",
    items = efforts,
    on_select = function(effort)
      local summaries = {
        { label = "default", value = vim.NIL },
        { label = "auto", value = "auto" },
        { label = "concise", value = "concise" },
        { label = "detailed", value = "detailed" },
        { label = "none", value = "none" },
      }
      return select_result({
        title = "Codex reasoning summary",
        items = summaries,
        on_select = function(summary)
          local cfg = current_cfg()
          cfg.reasoning_effort = is_nil(effort.value) and nil or effort.value
          cfg.reasoning_summary = is_nil(summary.value) and nil or summary.value
          apply_thread_settings(
            thread_id,
            {
              effort = cfg.reasoning_effort or vim.NIL,
              summary = cfg.reasoning_summary or vim.NIL,
            },
            ("reasoning set to effort=%s summary=%s"):format(
              setting_value(cfg.reasoning_effort),
              setting_value(cfg.reasoning_summary)
            ),
            actions
          )
        end,
      })
    end,
  })
end

local function open_personality(actions, thread_id)
  local choices = {
    { label = "none", value = "none", detail = "Disable personality instructions" },
    { label = "friendly", value = "friendly", detail = "Use a friendly communication style" },
    { label = "pragmatic", value = "pragmatic", detail = "Use a direct engineering style" },
    { label = "default", value = vim.NIL, detail = "Use the app-server default" },
  }
  return select_result({
    title = "Codex personality",
    items = choices,
    format_item = function(choice)
      return text(choice.label) .. " - " .. text(choice.detail)
    end,
    on_select = function(choice)
      current_cfg().personality = is_nil(choice.value) and nil or choice.value
      apply_thread_settings(
        thread_id,
        { personality = current_cfg().personality or vim.NIL },
        "personality set to " .. setting_value(current_cfg().personality),
        actions
      )
    end,
  })
end

local function open_experimental(actions, thread_id)
  ensure_server(actions, function()
    rpc.request(
      "experimentalFeature/list",
      { limit = 200, threadId = current_thread_id(thread_id) },
      function(err, result)
        if err then
          notify("experimentalFeature/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          return
        end
        local features = {}
        for _, feature in ipairs(as_table(field(result, "data"))) do
          if text_or_nil(feature.displayName) or text_or_nil(feature.description) then
            table.insert(features, feature)
          end
        end
        table.sort(features, function(a, b)
          return text(a.displayName or a.name) < text(b.displayName or b.name)
        end)
        present_result(select_result({
          title = "Codex experimental feature",
          empty_message = "no experimental features available",
          items = features,
          format_item = function(feature)
            local state_label = feature.enabled == true and "on" or "off"
            local label = text(feature.displayName or feature.name)
            local description = text_or_nil(feature.description)
            if description then
              label = label .. " - " .. description
            end
            return ("[%s] %s"):format(state_label, label)
          end,
          on_select = function(feature)
            local enablement = {}
            enablement[feature.name] = feature.enabled ~= true
            rpc.request("experimentalFeature/enablement/set", { enablement = enablement }, function(set_err)
              if set_err then
                present_result(
                  notify_result(
                    "experimentalFeature/enablement/set failed: " .. tostring(set_err.message or set_err),
                    vim.log.levels.ERROR
                  )
                )
                return
              end
              present_result(
                notify_result(("%s %s"):format(feature.name, feature.enabled == true and "disabled" or "enabled"))
              )
            end)
          end,
        }))
      end
    )
  end)
end

local function open_settings(actions, thread_id)
  local choices = {
    { label = "model", fn = open_model },
    { label = "permissions", fn = open_permissions },
    { label = "sandbox", fn = open_sandbox },
    { label = "reasoning", fn = open_reasoning },
    { label = "personality", fn = open_personality },
    {
      label = "fast",
      fn = function(a, t)
        open_fast({}, a, t)
      end,
    },
    { label = "experimental", fn = open_experimental },
  }
  return select_result({
    title = "Codex settings",
    items = choices,
    on_select = function(choice)
      return choice.fn(actions, thread_id)
    end,
  })
end

local function status_page(thread_id, codex_config, rate_limits, errors)
  codex_config = as_table_or_nil(codex_config)
  rate_limits = as_table_or_nil(rate_limits)
  errors = as_table(errors)
  local id = current_thread_id(thread_id)
  local thread = id and state.get_thread(id) or nil
  local cfg = current_cfg()
  local lines = {
    "# Codex Status",
    "",
    "server: " .. (rpc.is_running() and "running" or "stopped"),
    "initialized: " .. tostring(rpc.initialized),
    "cwd: " .. config.cwd(),
    "thread: " .. tostring(id or "none"),
  }
  if thread then
    table.insert(lines, "title: " .. tostring(thread.title or ""))
    table.insert(lines, "generation: " .. tostring(thread.generation or "idle"))
    table.insert(lines, "active turn: " .. tostring(thread.active_turn_id or "none"))
  end
  table.insert(lines, "")
  local effective = state.effective_thread_settings(thread, cfg)
  table.insert(lines, "model: " .. setting_value(effective.model))
  table.insert(lines, "service tier: " .. setting_value(effective.service_tier))
  table.insert(lines, "approval policy: " .. setting_value(cfg.approval_policy))
  table.insert(lines, "approvals reviewer: " .. setting_value(cfg.approvals_reviewer))
  table.insert(lines, "sandbox: " .. setting_value(cfg.sandbox))
  table.insert(lines, "permission profile: " .. setting_value(cfg.permissions))
  table.insert(lines, "reasoning effort: " .. setting_value(effective.reasoning_effort))
  table.insert(lines, "reasoning summary: " .. setting_value(effective.reasoning_summary))
  table.insert(lines, "personality: " .. setting_value(effective.personality))

  if codex_config then
    table.insert(lines, "")
    table.insert(lines, "## Codex Config")
    table.insert(lines, "model: " .. setting_value(codex_config.model))
    table.insert(lines, "service tier: " .. setting_value(codex_config.service_tier))
    table.insert(lines, "approval policy: " .. setting_value(codex_config.approval_policy))
    table.insert(lines, "approvals reviewer: " .. setting_value(codex_config.approvals_reviewer))
    table.insert(lines, "sandbox mode: " .. setting_value(codex_config.sandbox_mode))
    table.insert(lines, "reasoning effort: " .. setting_value(codex_config.model_reasoning_effort))
    table.insert(lines, "reasoning summary: " .. setting_value(codex_config.model_reasoning_summary))
  end

  if rate_limits then
    table.insert(lines, "")
    table.insert(lines, "## Rate Limits")
    table.insert(lines, vim.inspect(rate_limits))
  end

  if #errors > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Errors")
    vim.list_extend(lines, errors)
  end

  return page("Codex Status", lines, { source = return_forms.status })
end

local function show_status(actions, thread_id)
  ensure_server(actions, function()
    rpc.request("config/read", { includeLayers = false, cwd = config.cwd() }, function(config_err, config_result)
      local errors = {}
      if config_err then
        table.insert(errors, "config/read failed: " .. tostring(config_err.message or config_err))
      end
      rpc.request("account/rateLimits/read", nil, function(rate_err, rate_result)
        if rate_err then
          table.insert(errors, "account/rateLimits/read failed: " .. tostring(rate_err.message or rate_err))
        end
        present_result(status_page(thread_id, field(config_result, "config"), rate_result, errors))
      end)
    end)
  end)
end

local function show_help()
  local lines = {
    "# Codex Slash Commands",
    "",
    "Type / and filter the command list. Slash commands are handled by codex.nvim and are not sent as model tool calls.",
    "",
  }
  for _, command in ipairs(commands) do
    table.insert(lines, ("/%-22s %s"):format(command.name, command.detail))
    table.insert(lines, ("  returns: %s"):format(return_forms[command.name] or "notify(unsupported)"))
  end
  return page("Codex Slash Commands", lines, { source = return_forms.help })
end

local function show_mcp(args, actions)
  ensure_server(actions, function()
    local detail = args[1] == "verbose" and "full" or "toolsAndAuthOnly"
    rpc.request("mcpServerStatus/list", { limit = 200, detail = detail }, function(err, result)
      if err then
        notify("mcpServerStatus/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local lines = { "# Codex MCP", "" }
      for _, server in ipairs(as_table(field(result, "data"))) do
        table.insert(lines, "## " .. tostring(server.name))
        table.insert(lines, "auth: " .. vim.inspect(server.authStatus))
        local names = vim.tbl_keys(as_table(field(server, "tools")))
        table.sort(names)
        if #names == 0 then
          table.insert(lines, "tools: none")
        else
          table.insert(lines, "tools:")
          for _, name in ipairs(names) do
            table.insert(lines, "  - " .. tostring(name))
          end
        end
        table.insert(lines, "")
      end
      if #lines == 2 then
        table.insert(lines, "No MCP servers are configured.")
      end
      present_result(page("Codex MCP", lines, { source = return_forms.mcp }))
    end)
  end)
end

local function show_hooks(actions)
  ensure_server(actions, function()
    rpc.request("hooks/list", { cwds = { config.cwd() } }, function(err, result)
      if err then
        notify("hooks/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local lines = { "# Codex Hooks", "" }
      for _, entry in ipairs(as_table(field(result, "data"))) do
        table.insert(lines, "## " .. tostring(entry.cwd))
        local warnings = as_table(field(entry, "warnings"))
        local hook_errors = as_table(field(entry, "errors"))
        local hooks = as_table(field(entry, "hooks"))
        if #warnings > 0 then
          table.insert(lines, "warnings:")
          for _, warning in ipairs(warnings) do
            table.insert(lines, "  - " .. tostring(warning))
          end
        end
        if #hook_errors > 0 then
          table.insert(lines, "errors:")
          for _, hook_err in ipairs(hook_errors) do
            table.insert(lines, "  - " .. vim.inspect(hook_err))
          end
        end
        if #hooks == 0 then
          table.insert(lines, "hooks: none")
        else
          table.insert(lines, "hooks:")
          for _, hook in ipairs(hooks) do
            table.insert(lines, "  - " .. tostring(hook.event or hook.name or vim.inspect(hook)))
          end
        end
        table.insert(lines, "")
      end
      present_result(page("Codex Hooks", lines, { source = return_forms.hooks }))
    end)
  end)
end

local function show_diff()
  local cwd = config.cwd()
  local lines = { "# Codex Diff", "" }
  local status = vim.fn.systemlist({ "git", "-C", cwd, "status", "--short", "--untracked-files=all" })
  if vim.v.shell_error == 0 and #status > 0 then
    table.insert(lines, "## Status")
    vim.list_extend(lines, status)
    table.insert(lines, "")
  end
  local diff = vim.fn.systemlist({ "git", "-C", cwd, "diff", "--no-ext-diff", "--" })
  if vim.v.shell_error ~= 0 then
    table.insert(lines, "git diff failed")
  elseif #diff == 0 and #status == 0 then
    table.insert(lines, "Working tree is clean.")
  else
    table.insert(lines, "## Diff")
    vim.list_extend(lines, diff)
  end
  return page("Codex Diff", lines, { source = return_forms.diff })
end

local function show_debug_config(actions)
  ensure_server(actions, function()
    rpc.request("config/read", { includeLayers = true, cwd = config.cwd() }, function(err, result)
      if err then
        notify("config/read failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local result_table = as_table(result)
      local lines = {
        "# Codex Debug Config",
        "",
        "config:",
        vim.inspect(as_table(result_table.config)),
        "",
        "origins:",
        vim.inspect(as_table(result_table.origins)),
        "",
        "layers:",
        vim.inspect(as_table(result_table.layers)),
      }
      rpc.request("configRequirements/read", nil, function(req_err, req_result)
        if not req_err then
          table.insert(lines, "")
          table.insert(lines, "requirements:")
          table.insert(lines, vim.inspect(as_table(req_result)))
        end
        present_result(page("Codex Debug Config", lines, { source = return_forms["debug-config"] }))
      end)
    end)
  end)
end

local function start_compact(actions, thread_id)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  ensure_server(actions, function()
    rpc.request("thread/compact/start", { threadId = id }, function(err)
      if err then
        present_result(
          notify_result("thread/compact/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        )
        return
      end
      present_result(notify_result("Codex compaction started"))
    end)
  end)
end

local function start_review(actions, thread_id)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  ensure_server(actions, function()
    rpc.request(
      "review/start",
      { threadId = id, target = { type = "uncommittedChanges" }, delivery = "inline" },
      function(err, result)
        if err then
          present_result(notify_result("review/start failed: " .. tostring(err.message or err), vim.log.levels.ERROR))
          return
        end
        local turn = as_table_or_nil(field(result, "turn"))
        if turn then
          state.add_turn(id, turn)
          require("codex.buffers").schedule_render(id)
        end
        present_result(notify_result("Codex review started"))
      end
    )
  end)
end

local function fork_thread(actions, thread_id, ephemeral)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  ensure_server(actions, function()
    rpc.request("thread/fork", {
      threadId = id,
      cwd = config.cwd(),
      runtimeWorkspaceRoots = { config.cwd() },
      ephemeral = ephemeral or false,
      persistExtendedHistory = false,
    }, function(err, result)
      if err then
        present_result(notify_result("thread/fork failed: " .. tostring(err.message or err), vim.log.levels.ERROR))
        return
      end
      local thread_payload = as_table_or_nil(field(result, "thread"))
      if not thread_payload then
        present_result(notify_result("thread/fork returned no thread", vim.log.levels.ERROR))
        return
      end
      local thread = state.update_thread_from_payload(thread_payload)
      require("codex.buffers").open(thread.id)
    end)
  end)
end

local function open_goal(args, actions, thread_id)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  ensure_server(actions, function()
    local raw = trim(table.concat(args, " "))
    if raw == "" then
      rpc.request("thread/goal/get", { threadId = id }, function(err, result)
        if err then
          present_result(
            notify_result("thread/goal/get failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          )
          return
        end
        local goal = as_table_or_nil(field(result, "goal"))
        if not goal then
          present_result(notify_result("no active Codex goal"))
          return
        end
        present_result(page("Codex Goal", {
          "# Codex Goal",
          "",
          "status: " .. tostring(goal.status),
          "tokens: " .. tostring(goal.tokensUsed) .. "/" .. tostring(goal.tokenBudget or "unlimited"),
          "",
          tostring(goal.objective or ""),
        }, { source = return_forms.goal }))
      end)
      return
    end
    if raw == "clear" then
      rpc.request("thread/goal/clear", { threadId = id }, function(err)
        if err then
          present_result(
            notify_result("thread/goal/clear failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          )
          return
        end
        present_result(notify_result("Codex goal cleared"))
      end)
      return
    end
    if raw == "pause" or raw == "resume" then
      rpc.request("thread/goal/set", { threadId = id, status = raw == "pause" and "paused" or "active" }, function(err)
        if err then
          present_result(
            notify_result("thread/goal/set failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          )
          return
        end
        present_result(notify_result("Codex goal " .. (raw == "pause" and "paused" or "resumed")))
      end)
      return
    end
    if #raw > 4000 then
      present_result(notify_result("goal objective must be at most 4000 characters", vim.log.levels.WARN))
      return
    end
    rpc.request("thread/goal/set", { threadId = id, objective = raw, status = "active" }, function(err)
      if err then
        present_result(notify_result("thread/goal/set failed: " .. tostring(err.message or err), vim.log.levels.ERROR))
        return
      end
      present_result(notify_result("Codex goal set"))
    end)
  end)
end

local function open_memories(args, actions, thread_id)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  local raw = args[1] and args[1]:lower() or nil
  local choices = {
    { label = "enabled", value = "enabled" },
    { label = "disabled", value = "disabled" },
  }
  local function apply(mode)
    ensure_server(actions, function()
      rpc.request("thread/memoryMode/set", { threadId = id, mode = mode }, function(err)
        if err then
          present_result(
            notify_result("thread/memoryMode/set failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
          )
          return
        end
        present_result(notify_result("Codex memory mode set to " .. mode))
      end)
    end)
  end
  if raw == "enabled" or raw == "on" then
    apply("enabled")
    return
  end
  if raw == "disabled" or raw == "off" then
    apply("disabled")
    return
  end
  return select_result({
    title = "Codex memories",
    items = choices,
    on_select = function(choice)
      apply(choice.value)
    end,
  })
end

local function open_skills(actions)
  ensure_server(actions, function()
    rpc.request("skills/list", { cwds = { config.cwd() }, forceReload = false }, function(err, result)
      if err then
        notify("skills/list failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      local skills = {}
      for _, entry in ipairs(as_table(field(result, "data"))) do
        for _, skill in ipairs(as_table(field(entry, "skills"))) do
          table.insert(skills, skill)
        end
      end
      table.sort(skills, function(a, b)
        return tostring(a.name) < tostring(b.name)
      end)
      present_result(select_result({
        title = "Codex skill",
        empty_message = "no Codex skills available",
        items = skills,
        format_item = function(skill)
          local description = text_or_nil(skill.shortDescription)
          return text(skill.name) .. (description and (" - " .. description) or "")
        end,
        on_select = function(skill)
          return insert_result("$skill:" .. text(skill.name))
        end,
      }))
    end)
  end)
end

local function copy_latest_output(thread_id)
  local id = need_thread(thread_id)
  if not id then
    return
  end
  local thread = state.get_thread(id)
  if not thread then
    return notify_result("no active Codex thread", vim.log.levels.WARN)
  end
  local item_order = as_table(thread.item_order)
  for index = #item_order, 1, -1 do
    local item = as_table(thread.items)[item_order[index]]
    if item and (item.type == "agentMessage" or item.type == "assistantMessage") then
      local output = item.text or item.message or item.content
      if type(output) == "table" then
        output = vim.inspect(output)
      end
      output = text_or_nil(output)
      if output then
        vim.fn.setreg("+", output)
        vim.fn.setreg('"', output)
        return notify_result("latest Codex output copied")
      end
    end
  end
  return notify_result("no completed Codex output to copy", vim.log.levels.WARN)
end

local function raw_toggle()
  local render = config.get().render
  render.show_raw_events = not render.show_raw_events
  return notify_result("raw event rendering " .. (render.show_raw_events and "enabled" or "disabled"))
end

local function logout(actions)
  ensure_server(actions, function()
    rpc.request("account/logout", nil, function(err)
      if err then
        present_result(notify_result("account/logout failed: " .. tostring(err.message or err), vim.log.levels.ERROR))
        return
      end
      present_result(notify_result("Codex account logged out"))
    end)
  end)
end

local function not_supported(name, detail)
  return function()
    return notify_result(
      ("/%s is a Codex CLI command; %s"):format(name, detail or "codex.nvim does not implement this page yet"),
      vim.log.levels.WARN
    )
  end
end

local handlers = {
  permissions = function(args, actions, thread_id)
    open_permissions(actions, thread_id)
  end,
  sandbox = function(args, actions, thread_id)
    return open_sandbox(actions, thread_id)
  end,
  hooks = function(args, actions)
    show_hooks(actions)
  end,
  clear = function(args, actions)
    if actions.new_thread then
      actions.new_thread({ session_start_source = "clear" })
    end
  end,
  compact = function(args, actions, thread_id)
    start_compact(actions, thread_id)
  end,
  copy = function(args, actions, thread_id)
    return copy_latest_output(thread_id)
  end,
  diff = function()
    return show_diff()
  end,
  experimental = function(args, actions, thread_id)
    open_experimental(actions, thread_id)
  end,
  memories = function(args, actions, thread_id)
    return open_memories(args, actions, thread_id)
  end,
  skills = function(args, actions)
    open_skills(actions)
  end,
  logout = function(args, actions)
    logout(actions)
  end,
  mcp = function(args, actions)
    show_mcp(args, actions)
  end,
  mention = not_supported("mention", "use @file:`path` or @image:`path` in codex.nvim"),
  model = function(args, actions, thread_id)
    open_model(actions, thread_id)
  end,
  fast = function(args, actions, thread_id)
    open_fast(args, actions, thread_id)
  end,
  reasoning = function(args, actions, thread_id)
    return open_reasoning(actions, thread_id)
  end,
  goal = function(args, actions, thread_id)
    open_goal(args, actions, thread_id)
  end,
  personality = function(args, actions, thread_id)
    return open_personality(actions, thread_id)
  end,
  stop = function(args, actions)
    if actions.stop then
      actions.stop()
    end
  end,
  fork = function(args, actions, thread_id)
    fork_thread(actions, thread_id, false)
  end,
  side = function(args, actions, thread_id)
    fork_thread(actions, thread_id, true)
  end,
  raw = function()
    return raw_toggle()
  end,
  resume = function(args, actions)
    if args[1] and args[1] ~= "" and actions.resume then
      actions.resume(args[1])
    elseif actions.pick_thread then
      actions.pick_thread()
    end
  end,
  new = function(args, actions)
    if actions.new_thread then
      actions.new_thread({ prompt = table.concat(args, " "), session_start_source = "new" })
    end
  end,
  review = function(args, actions, thread_id)
    start_review(actions, thread_id)
  end,
  status = function(args, actions, thread_id)
    show_status(actions, thread_id)
  end,
  ["debug-config"] = function(args, actions)
    show_debug_config(actions)
  end,
  theme = not_supported("theme", "theme selection is owned by Neovim colorschemes"),
  settings = function(args, actions, thread_id)
    return open_settings(actions, thread_id)
  end,
  help = function()
    return show_help()
  end,
}

for _, name in ipairs({ "quit", "exit" }) do
  handlers[name] = not_supported(name, "use :q, :qa, or close the Codex window from Neovim")
end

for _, name in ipairs({
  "ide",
  "keymap",
  "vim",
  "sandbox-add-read-dir",
  "agent",
  "apps",
  "plugins",
  "approve",
  "feedback",
  "init",
  "plan",
  "ps",
  "statusline",
  "title",
}) do
  handlers[name] = handlers[name] or not_supported(name)
end

function M.items(prefix)
  prefix = tostring(prefix or "")
  local items = {}
  for _, command in ipairs(commands) do
    local label = "/" .. command.name
    table.insert(items, {
      label = label,
      insertText = label,
      detail = command.detail,
      filterText = label .. " " .. command.category .. " " .. command.detail,
      data = {
        source = "codex.nvim.slash",
        command = command.name,
        category = command.category,
      },
    })
  end
  return items
end

function M.parse(text)
  local line = first_line(trim(text))
  if line:sub(1, 1) ~= "/" then
    return nil
  end
  local name, rest = line:match("^/([%w][%w%-]*)(.*)$")
  if not name then
    return { name = "", args = {}, raw_args = "" }
  end
  rest = trim(rest or "")
  return {
    name = name:lower(),
    args = vim.split(rest, "%s+", { trimempty = true }),
    raw_args = rest,
  }
end

function M.dispatch(text, thread_id, actions)
  local parsed = M.parse(text)
  if not parsed then
    return false
  end
  if parsed.name == "" then
    present_result(show_help())
    return true
  end
  local command = by_name[parsed.name]
  if not command then
    notify("unknown Codex slash command: /" .. parsed.name, vim.log.levels.WARN)
    return true
  end
  local handler = handlers[parsed.name] or handlers[command.name]
  if handler then
    present_result(handler(parsed.args, actions or {}, thread_id, parsed))
  else
    notify("unsupported Codex slash command: /" .. parsed.name, vim.log.levels.WARN)
  end
  return true
end

function M.command_names()
  local names = {}
  for _, command in ipairs(commands) do
    table.insert(names, command.name)
  end
  table.sort(names)
  return names
end

M._commands = commands
M._return_forms = return_forms
M._present_result = present_result
M._sandbox_policy = sandbox_policy

return M
