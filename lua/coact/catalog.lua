local config = require("coact.config")
local state = require("coact.state")

local M = {}
local inflight = {}

local static = {
  ["@"] = {
    { label = "@buffer", detail = "Attach current buffer RPC metadata and text" },
    { label = "@selection", detail = "Attach the current visual selection" },
    { label = "@cursor", detail = "Attach lines around the cursor" },
    { label = "@diagnostics", detail = "Attach diagnostics for the current buffer" },
    { label = "@quickfix", detail = "Attach the quickfix list" },
    { label = "@buffers", detail = "Attach the open buffer list" },
    { label = "@cwd", detail = "Attach Neovim cwd and project root" },
    { label = "@behavior", detail = "Attach editor diff since the previous agent turn" },
    { label = "@file:", detail = "Attach a file by path" },
    { label = "@image:", detail = "Attach a local image by path or an image URL" },
  },
}

local path_contexts = {
  file = true,
  image = true,
}

local image_exts = {
  bmp = true,
  gif = true,
  heic = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_absolute_path(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil
end

local function path_arg_prefix(prefix)
  local name, raw = tostring(prefix or ""):match("^@([%w_.%-/]+):(.*)$")
  if not name or not path_contexts[name] then
    return nil
  end
  raw = raw or ""
  if vim.startswith(raw, "`") then
    raw = raw:sub(2)
    local close_index = raw:find("`", 1, true)
    if close_index then
      raw = raw:sub(1, close_index - 1)
    end
  end
  return name, raw
end

local function split_completion_path(raw)
  raw = trim(raw)
  local expanded = vim.fn.expand(raw)
  local dir_part = ""
  local leaf = ""

  if expanded == "" then
    dir_part = ""
  elseif expanded:sub(-1) == "/" then
    dir_part = expanded:gsub("/+$", "")
  else
    dir_part = vim.fn.fnamemodify(expanded, ":h")
    leaf = vim.fn.fnamemodify(expanded, ":t")
    if dir_part == "." then
      dir_part = ""
    end
  end

  local scan_dir = dir_part
  if scan_dir == "" then
    scan_dir = config.cwd()
  elseif not is_absolute_path(scan_dir) then
    scan_dir = vim.fs.joinpath(config.cwd(), scan_dir)
  end

  return vim.fs.normalize(scan_dir), leaf, dir_part
end

local function display_path(dir_part, name)
  if dir_part == "" or dir_part == "." then
    return name
  end
  return dir_part:gsub("/+$", "") .. "/" .. name
end

local function quote_path(path)
  return "`" .. path:gsub("`", "\\`") .. "`"
end

local function is_image_path(path)
  local ext = path:match("%.([^./\\]+)$")
  return ext and image_exts[ext:lower()] or false
end

local function scan_names(scan_dir)
  local ok, names = pcall(vim.fn.readdir, scan_dir)
  if not ok or type(names) ~= "table" then
    return {}
  end
  table.sort(names, function(a, b)
    return tostring(a):lower() < tostring(b):lower()
  end)
  return names
end

local function path_item(provider, path, is_dir)
  local label = "@" .. provider .. ":" .. quote_path(path)
  return {
    label = label,
    insertText = label,
    detail = is_dir and "Directory" or (provider == "image" and "Image asset" or "File context"),
    filterText = "@" .. provider .. ":" .. path,
    data = {
      source = "coact.nvim.context_path",
      provider = provider,
      path = path,
      directory = is_dir,
    },
  }
end

function M.path_items(prefix)
  local provider, raw = path_arg_prefix(prefix)
  if not provider then
    return nil
  end

  if raw:match("^https?://") then
    return {}
  end

  local scan_dir, leaf, dir_part = split_completion_path(raw)
  local items = {}
  for _, name in ipairs(scan_names(scan_dir)) do
    if leaf == "" or vim.startswith(name:lower(), leaf:lower()) then
      local absolute = vim.fs.joinpath(scan_dir, name)
      local is_dir = vim.fn.isdirectory(absolute) == 1
      local path = display_path(dir_part, name)
      if is_dir then
        path = path .. "/"
      end
      if is_dir or provider ~= "image" or is_image_path(path) then
        table.insert(items, path_item(provider, path, is_dir))
      end
      if #items >= 100 then
        break
      end
    end
  end
  return items
end

local function cache_key(kind)
  return "catalog:" .. kind
end

function M.cache_key(kind)
  return cache_key(kind)
end

local function normalize_skill(skill)
  if not skill.name then
    return nil
  end
  return {
    label = "$skill:" .. skill.name,
    detail = skill.shortDescription or skill.description or "Provider skill",
    documentation = skill.description,
    filterText = "$ " .. skill.name .. " " .. (skill.shortDescription or skill.description or ""),
    data = skill,
  }
end

local function normalize_mcp_tool(server, tool_name, tool)
  local name = tool.name or tool_name
  if not name or name == "" then
    return nil
  end
  local title = tool.title or name
  return {
    label = "/" .. server.name .. "/" .. name,
    detail = "MCP tool: " .. tostring(server.name) .. " · " .. tostring(title),
    documentation = tool.description,
    filterText = "/" .. name .. " " .. tostring(server.name) .. " " .. tostring(title) .. " " .. tostring(
      tool.description or ""
    ),
    data = {
      source = "mcpServerStatus/list",
      server = server.name,
      tool = tool,
    },
  }
end

local function normalize_app(app)
  if not app.id or app.id == "" then
    return nil
  end
  if app.isAccessible == false or app.isEnabled == false then
    return nil
  end
  return {
    label = "/app:" .. app.id,
    detail = "Provider app connector: " .. tostring(app.name or app.id),
    documentation = app.description,
    filterText = "/app " .. tostring(app.id) .. " " .. tostring(app.name or "") .. " " .. tostring(
      app.description or ""
    ),
    data = {
      source = "app/list",
      app = app,
    },
  }
end

local function normalize_dynamic_tool(spec)
  if type(spec) ~= "table" or not spec.namespace or not spec.name then
    return nil
  end
  local label = "/" .. tostring(spec.namespace) .. "/" .. tostring(spec.name)
  return {
    label = label,
    detail = "Neovim tool: " .. tostring(spec.namespace) .. "." .. tostring(spec.name),
    documentation = spec.description,
    filterText = label .. " " .. tostring(spec.namespace) .. " " .. tostring(spec.name) .. " " .. tostring(
      spec.description or ""
    ),
    data = {
      source = "coact.nvim.dynamic_tools",
      tool = spec,
    },
  }
end

local function dynamic_tool_items()
  local ok, dynamic_tools = pcall(require, "coact.dynamic_tools")
  if not ok then
    return {}
  end
  local specs = dynamic_tools.specs() or {}
  local items = {}
  for _, spec in ipairs(specs) do
    local item = normalize_dynamic_tool(spec)
    if item then
      table.insert(items, item)
    end
  end
  return items
end

function M.static_for_trigger(trigger)
  return vim.deepcopy(static[trigger] or {})
end

local function cached(kind)
  return state.get_cache(cache_key(kind), config.get().completion.ttl_ms or 30000)
end

function M.dynamic(kind)
  if not kind then
    return {}
  end
  if kind == "tools" then
    local tools = vim.deepcopy(cached(kind) or {})
    vim.list_extend(tools, dynamic_tool_items())
    table.sort(tools, function(a, b)
      return a.label < b.label
    end)
    return tools
  end
  return cached(kind) or {}
end

function M.invalidate(kind)
  state.cache[cache_key(kind)] = nil
end

local function with_server(callback)
  local rpc = require("coact.rpc")
  if rpc.is_running() then
    callback(nil)
    return
  end
  rpc.start(function(err)
    callback(err)
  end)
end

local function refresh_skills(callback)
  require("coact.rpc").request("skills/list", { cwds = { config.cwd() }, forceReload = false }, function(err, result)
    if err then
      callback({})
      return
    end
    local items = {}
    for _, entry in ipairs(result.data or {}) do
      for _, skill in ipairs(entry.skills or {}) do
        local item = normalize_skill(skill)
        if item then
          table.insert(items, item)
        end
      end
    end
    table.sort(items, function(a, b)
      return a.label < b.label
    end)
    state.set_cache(cache_key("skills"), items)
    callback(items)
  end)
end

local function refresh_mcp_tools(callback)
  require("coact.rpc").request(
    "mcpServerStatus/list",
    { limit = 200, detail = "toolsAndAuthOnly" },
    function(err, result)
      local items = {}
      if not err then
        for _, server in ipairs(result.data or {}) do
          for tool_name, tool in pairs(server.tools or {}) do
            local item = normalize_mcp_tool(server, tool_name, tool)
            if item then
              table.insert(items, item)
            end
          end
        end
      end
      callback(items)
    end
  )
end

local function refresh_app_tools(callback)
  require("coact.rpc").request("app/list", { limit = 200, forceRefetch = false }, function(err, result)
    local items = {}
    if not err then
      for _, app in ipairs(result.data or {}) do
        local item = normalize_app(app)
        if item then
          table.insert(items, item)
        end
      end
    end
    callback(items)
  end)
end

local function refresh_tools(callback)
  refresh_mcp_tools(function(mcp_items)
    refresh_app_tools(function(app_items)
      local items = {}
      vim.list_extend(items, mcp_items or {})
      vim.list_extend(items, app_items or {})
      table.sort(items, function(a, b)
        return a.label < b.label
      end)
      state.set_cache(cache_key("tools"), items)
      callback(M.dynamic("tools"))
    end)
  end)
end

function M.refresh(kind, callback)
  callback = callback or function() end
  if inflight[kind] then
    table.insert(inflight[kind], callback)
    return
  end
  inflight[kind] = { callback }
  local done = function(items)
    local callbacks = inflight[kind] or {}
    inflight[kind] = nil
    for _, waiting in ipairs(callbacks) do
      waiting(items or {})
    end
  end
  with_server(function(err)
    if err then
      done(kind == "tools" and dynamic_tool_items() or {})
      return
    end
    if kind == "skills" then
      refresh_skills(done)
    elseif kind == "tools" then
      refresh_tools(done)
    else
      done({})
    end
  end)
end

function M.ensure_refresh(kind)
  if not kind or cached(kind) then
    return
  end
  M.refresh(kind)
end

function M.kind_for_trigger(trigger, prefix)
  if trigger == "$" then
    return "skills"
  end
  return nil
end

function M.items_for_trigger(trigger, prefix, callback)
  if trigger == "/" then
    callback(require("coact.slash").items(prefix))
    return
  end
  local kind = M.kind_for_trigger(trigger, prefix)
  if not kind then
    if trigger == "@" then
      local path_items = M.path_items(prefix)
      if path_items then
        callback(path_items)
        return
      end
    end
    callback(M.static_for_trigger(trigger))
    return
  end
  local current = cached(kind)
  if current then
    callback(M.dynamic(kind))
    return
  end
  M.refresh(kind, callback)
end

function M.find_skill(name)
  if vim.startswith(name, "skill:") then
    name = name:sub(7)
  end
  for _, item in ipairs(M.dynamic("skills")) do
    if item.data and item.data.name == name then
      return item.data
    end
  end
  return nil
end

M._dynamic_tool_items = dynamic_tool_items

return M
