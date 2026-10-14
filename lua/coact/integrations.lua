-- Agent-client integrations shipped with coact.nvim.
--
-- Each integration links a file from this plugin into an agent client's
-- configuration so the client can hand its session to coact.nvim. Links keep
-- the installed copy in step with plugin updates.
local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(source, ":p")))))
end

local function expand(path)
  return vim.fs.normalize(vim.fn.expand(path))
end

local function pi_agent_dir()
  local dir = vim.env.PI_CODING_AGENT_DIR
  return expand(dir and dir ~= "" and dir or "~/.pi/agent")
end

local specs = {
  pi = function()
    return {
      name = "pi",
      title = "Pi /nvim extension",
      executable = "pi",
      source = vim.fs.joinpath(plugin_root(), "extensions", "pi", "coact-nvim.ts"),
      target = vim.fs.joinpath(pi_agent_dir(), "extensions", "coact-nvim.ts"),
    }
  end,
}

function M.names()
  local names = vim.tbl_keys(specs)
  table.sort(names)
  return names
end

function M.spec(name)
  local factory = specs[name]
  if not factory then
    return nil, "unknown integration " .. tostring(name)
  end
  return factory()
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

--- Returns the install state and spec of an integration.
--- States: "installed" (links to this plugin), "missing", "stale" (a link to
--- another location, such as an old plugin checkout, or a dangling link),
--- "copy" (a regular file identical to the shipped one), and "foreign"
--- (a regular file with other content).
function M.status(name)
  local spec, err = M.spec(name)
  if not spec then
    return nil, err
  end
  local stat = vim.uv.fs_lstat(spec.target)
  if not stat then
    return "missing", spec
  end
  if stat.type == "link" then
    local real = vim.uv.fs_realpath(spec.target)
    return (real and real == vim.uv.fs_realpath(spec.source)) and "installed" or "stale", spec
  end
  local content = read_file(spec.target)
  return (content and content == read_file(spec.source)) and "copy" or "foreign", spec
end

local function result(name, ok, message, spec)
  return { name = name, ok = ok, message = message, target = spec and spec.target }
end

local function install_one(name, force)
  local state, spec = M.status(name)
  if not state then
    return result(name, false, spec)
  end
  if state == "installed" then
    return result(name, true, "already installed at " .. spec.target, spec)
  end
  if state == "foreign" and not force then
    return result(
      name,
      false,
      spec.target .. " is not managed by coact.nvim; use :Coact! extension-install to replace it",
      spec
    )
  end
  if vim.fn.filereadable(spec.source) ~= 1 then
    return result(name, false, "missing shipped file " .. spec.source, spec)
  end
  vim.fn.mkdir(vim.fs.dirname(spec.target), "p")
  if state ~= "missing" then
    local ok, err = vim.uv.fs_unlink(spec.target)
    if not ok then
      return result(name, false, "could not remove " .. spec.target .. ": " .. tostring(err), spec)
    end
  end
  local ok, err = vim.uv.fs_symlink(spec.source, spec.target)
  if not ok then
    return result(name, false, "could not link " .. spec.target .. ": " .. tostring(err), spec)
  end
  return result(name, true, "installed " .. spec.target .. " -> " .. spec.source, spec)
end

local function uninstall_one(name, force)
  local state, spec = M.status(name)
  if not state then
    return result(name, false, spec)
  end
  if state == "missing" then
    return result(name, true, "not installed", spec)
  end
  if state == "foreign" and not force then
    return result(
      name,
      false,
      spec.target .. " is not managed by coact.nvim; use :Coact! extension-uninstall to remove it",
      spec
    )
  end
  local ok, err = vim.uv.fs_unlink(spec.target)
  if not ok then
    return result(name, false, "could not remove " .. spec.target .. ": " .. tostring(err), spec)
  end
  return result(name, true, "removed " .. spec.target, spec)
end

local function run(operation, names, opts)
  opts = opts or {}
  if type(names) == "string" then
    names = { names }
  end
  if not names or #names == 0 then
    names = M.names()
  end
  local results = {}
  for _, name in ipairs(names) do
    local item = operation(name, opts.force)
    table.insert(results, item)
    if opts.notify ~= false then
      vim.notify(
        ("coact.nvim %s: %s"):format(item.name, item.message),
        item.ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end
  end
  return results
end

--- Install integrations. Suitable for plugin-manager build hooks.
--- @param names? string|string[] integration names; defaults to all
--- @param opts? { force?: boolean, notify?: boolean }
function M.install(names, opts)
  return run(install_one, names, opts)
end

--- @param names? string|string[] integration names; defaults to all
--- @param opts? { force?: boolean, notify?: boolean }
function M.uninstall(names, opts)
  return run(uninstall_one, names, opts)
end

local advice = {
  missing = "not installed; run :Coact extension-install %s",
  stale = "%s links elsewhere; run :Coact extension-install %s to relink it",
  copy = "%s is a copy that will not follow plugin updates; run :Coact extension-install %s to link it",
  foreign = "%s is not managed by coact.nvim; run :Coact! extension-install %s to replace it",
}

function M.health(report)
  for _, name in ipairs(M.names()) do
    local state, spec = M.status(name)
    if state ~= "installed" and vim.fn.executable(spec.executable) ~= 1 then
      report.info(("%s skipped: %s is not on $PATH"):format(spec.title, spec.executable))
    elseif state == "installed" then
      report.ok(("%s installed: %s"):format(spec.title, spec.target))
    elseif state == "missing" then
      report.warn(("%s %s"):format(spec.title, advice.missing:format(name)))
    else
      report.warn(("%s: " .. advice[state]):format(spec.title, spec.target, name))
    end
  end
end

M._plugin_root = plugin_root

return M
