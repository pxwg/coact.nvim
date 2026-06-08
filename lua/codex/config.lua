local M = {}

local defaults = {
  app_server = {
    command = { "codex", "app-server", "--listen", "stdio://" },
    initialize_timeout_ms = 10000,
    sanitize_malloc_env = true,
  },
  thread = {
    model = nil,
    model_provider = nil,
    service_tier = nil,
    approval_policy = "on-request",
    approvals_reviewer = "user",
    sandbox = "workspace-write",
    permissions = nil,
    reasoning_effort = nil,
    reasoning_summary = nil,
    developer_instructions = nil,
    base_instructions = nil,
    personality = nil,
    ephemeral = false,
  },
  buffer = {
    on_attach = nil,
  },
  ui = {
    layout = "float",
    width = 0.82,
    height = 0.82,
    sidebar_width = 0.42,
    render_delay_ms = 35,
    auto_scroll = true,
  },
  render = {
    prompt_marker = "## Prompt",
    separator = "───",
    show_raw_events = false,
    virtual_blocks = {
      default_expanded = false,
      max_lines = 80,
      max_width = 180,
    },
    tool_outputs = {
      mode = "smart",
      fallback = "raw",
      renderers = {},
    },
  },
  completion = {
    enabled = true,
    ttl_ms = 30000,
  },
  edit = {
    mode = "pair",
    diagnostics_settle_ms = 200,
    stale_context_lines = 80,
    review = {
      char_diff_max_lines = 120,
      char_diff_max_line_bytes = 1000,
      char_diff_max_total_bytes = 20000,
      keymaps = {
        accept = ".",
        reject = ",",
        accept_all = "ga",
        reject_all = "gr",
        auto_apply = "gA",
        cancel = "q",
        next = "n",
        prev = "p",
        help = "?",
      },
    },
    native_apply_patch_hook = {
      enabled = true,
      timeout_sec = 600,
      status_message = "Reviewing patch in Neovim",
      marker_cleanup_min_age_sec = 300,
      debug = false,
      debug_log_path = nil,
    },
  },
  dynamic_tools = {
    enabled = true,
    prefer_nvim_apply_patch = false,
  },
}

local options = vim.deepcopy(defaults)
local edit_modes = {
  pair = true,
  yolo = true,
}

local function merge(dst, src)
  if type(src) ~= "table" then
    return dst
  end
  for key, value in pairs(src) do
    if type(value) == "table" and type(dst[key]) == "table" and not vim.islist(value) then
      merge(dst[key], value)
    else
      dst[key] = value
    end
  end
  return dst
end

local function normalize_edit_mode(resolved, user_options)
  resolved.edit = resolved.edit or {}
  local dynamic = resolved.dynamic_tools or {}
  local user_dynamic = type(user_options) == "table" and user_options.dynamic_tools or nil
  local user_edit = type(user_options) == "table" and user_options.edit or nil

  if type(user_dynamic) == "table" and (user_edit == nil or user_edit.mode == nil) then
    if type(user_dynamic.mode) == "string" then
      resolved.edit.mode = user_dynamic.mode
    elseif type(user_dynamic.edit_mode) == "string" then
      resolved.edit.mode = user_dynamic.edit_mode
    elseif user_dynamic.prefer_nvim_apply_patch == false then
      resolved.edit.mode = "yolo"
    end
  end

  if not edit_modes[resolved.edit.mode] then
    resolved.edit.mode = "pair"
  end

  dynamic.prefer_nvim_apply_patch = type(user_dynamic) == "table" and user_dynamic.prefer_nvim_apply_patch == true
end

function M.setup(user_options)
  options = merge(vim.deepcopy(defaults), user_options or {})
  normalize_edit_mode(options, user_options or {})
  return options
end

function M.get()
  return options
end

function M.edit_mode()
  local edit = options.edit or {}
  return edit_modes[edit.mode] and edit.mode or "pair"
end

function M.cwd()
  local cwd = vim.fn.getcwd()
  local ok, root = pcall(vim.fs.root, cwd, { ".git" })
  if ok and root and root ~= "" then
    return root
  end
  return cwd
end

return M
