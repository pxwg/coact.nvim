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
  return dir, main
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
