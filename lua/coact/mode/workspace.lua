-- Chat workspaces: a directory marked by .coact-zk, with Coact state in .coact/.
local config = require("coact.mode.config")

local M = {}

M.marker = ".coact-zk"

local function path_of(target)
  if type(target) == "number" then
    local name = vim.api.nvim_buf_get_name(target)
    return name ~= "" and name or nil
  end
  return target
end

--- The workspace containing a buffer or path, if any.
function M.root(target)
  local path = path_of(target)
  if not path then
    return nil
  end
  local root = vim.fs.root(path, M.marker)
  return root and vim.fs.normalize(root) or nil
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file, err = io.open(path, "wb")
  if not file then
    return nil, err
  end
  file:write(text)
  file:close()
  return true
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

M.write_file = write_file
M.read_file = read_file

--- Create a workspace (default: a timestamped directory under
--- workspace_root) and return its root and first card file.
function M.init(dir)
  dir = dir and dir ~= "" and vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(dir), ":p"))
    or vim.fs.joinpath(config.get().workspace_root, os.date("%Y%m%d-%H%M%S"))
  dir = dir:gsub("/$", "")
  vim.fn.mkdir(dir, "p")
  local marker = vim.fs.joinpath(dir, M.marker)
  if vim.uv.fs_stat(marker) == nil then
    assert(write_file(marker, "# Coact mode chat workspace\n"))
  end
  local main = vim.fs.joinpath(dir, "chat.org")
  if vim.uv.fs_stat(main) == nil then
    assert(write_file(main, "#+title: Chat\n"))
  end
  M.remember(dir)
  return dir, main
end

-- ---- known workspaces ----

local function registry_path()
  return vim.fs.joinpath(config.get().workspace_root, "workspaces.json")
end

local function registered()
  local ok, list = pcall(vim.json.decode, read_file(registry_path()) or "[]")
  return ok and type(list) == "table" and list or {}
end

--- Record a workspace so it can be found again from anywhere.
-- One spelling per directory: symlinked paths (/var, /private/var) collapse.
local function canonical(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

function M.remember(root)
  root = canonical(root)
  local list, present = {}, false
  for _, known in ipairs(registered()) do
    if vim.uv.fs_stat(vim.fs.joinpath(known, M.marker)) then
      table.insert(list, known)
      present = present or known == root
    end
  end
  if not present then
    table.insert(list, root)
    write_file(registry_path(), vim.json.encode(list))
  end
end

--- Every workspace that still exists: registered ones and those under
--- workspace_root.
function M.known()
  local seen, out = {}, {}
  local function add(root)
    root = canonical(root)
    if not seen[root] and vim.uv.fs_stat(vim.fs.joinpath(root, M.marker)) then
      seen[root] = true
      table.insert(out, root)
    end
  end
  for _, root in ipairs(registered()) do
    add(root)
  end
  local base = config.get().workspace_root
  for name, type in vim.fs.dir(base) do
    if type == "directory" then
      add(vim.fs.joinpath(base, name))
    end
  end
  return out
end

--- Last activity of a thread: its Pi session file, if any.
function M.activity(root, thread)
  local id = M.session_id(thread)
  if not id then
    return nil
  end
  local newest
  for _, file in ipairs(vim.fn.glob(vim.fs.joinpath(M.sessions(root), "*_" .. id .. ".jsonl"), false, true)) do
    local stat = vim.uv.fs_stat(file)
    if stat and (not newest or stat.mtime.sec > newest) then
      newest = stat.mtime.sec
    end
  end
  return newest
end

function M.state_path(root, ...)
  return vim.fs.joinpath(root, ".coact", ...)
end

function M.sessions(root)
  return M.state_path(root, "sessions")
end

local function thread_file(thread)
  return (thread:gsub("[^%w%-_.]", "_")) .. ".json"
end

--- Card texts of the last finished turn, for revision notes.
function M.baseline(root, thread)
  local text = read_file(M.state_path(root, "baselines", thread_file(thread)))
  if not text then
    return nil
  end
  local ok, value = pcall(vim.json.decode, text)
  return ok and value or nil
end

function M.save_baseline(root, thread, cards)
  return write_file(M.state_path(root, "baselines", thread_file(thread)), vim.json.encode(cards))
end

--- The working directory a thread's Pi session was created in. Pi finds a
--- session by id only within its original directory, so a thread always
--- runs there; the first call records the current directory.
function M.thread_cwd(root, thread)
  local path = M.state_path(root, "threads", thread_file(thread))
  local text = read_file(path)
  local ok, value = pcall(vim.json.decode, text or "")
  if ok and type(value) == "table" and type(value.cwd) == "string" and vim.uv.fs_stat(value.cwd) then
    return value.cwd
  end
  local cwd = vim.fn.getcwd()
  assert(write_file(path, vim.json.encode({ thread = thread, cwd = cwd })))
  return cwd
end

--- Write a request for the Pi extension and return its path. The artifact
--- is spliced in as the server's JSON text, unparsed.
function M.request_file(root, name, artifact_json, fields)
  local path = M.state_path(root, "requests", name .. ".json")
  local placeholder = '"__coact_artifact__"'
  local encoded = vim.json.encode(vim.tbl_extend("force", fields or {}, { artifact = "__coact_artifact__" }))
  local s, e = encoded:find(placeholder, 1, true)
  assert(write_file(path, encoded:sub(1, s - 1) .. artifact_json .. encoded:sub(e + 1)))
  return path
end

--- "pi:<session-id>" thread identities name Pi sessions.
function M.session_id(thread)
  local id = type(thread) == "string" and thread:match("^pi:(.+)$")
  if id and id:match("^[%w][%w._-]*[%w]$") then
    return id
  end
  return nil
end

function M.new_thread()
  local bytes = vim.uv.random(16)
  local hex = bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)
  return ("pi:%s-%s-%s-%s-%s"):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21, 32))
end

return M
