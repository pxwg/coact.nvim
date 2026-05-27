local M = {}

local defaults = {
  app_server = {
    command = { "codex", "app-server", "--listen", "stdio://" },
    initialize_timeout_ms = 10000,
  },
  thread = {
    model = nil,
    model_provider = nil,
    service_tier = nil,
    approval_policy = "on-request",
    approvals_reviewer = "user",
    sandbox = "workspace-write",
    permissions = nil,
    developer_instructions = nil,
    base_instructions = nil,
    personality = nil,
    ephemeral = false,
  },
  ui = {
    layout = "float",
    width = 0.82,
    height = 0.82,
    sidebar_width = 0.42,
    render_delay_ms = 35,
    auto_scroll = true,
  },
  completion = {
    enabled = true,
    ttl_ms = 30000,
  },
  dynamic_tools = {
    enabled = true,
  },
}

local options = vim.deepcopy(defaults)

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

function M.setup(user_options)
  options = merge(vim.deepcopy(defaults), user_options or {})
  return options
end

function M.get()
  return options
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
