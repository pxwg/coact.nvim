-- Integration install/uninstall/health behavior against a temporary Pi agent dir.
local root = vim.fn.tempname()
vim.env.PI_CODING_AGENT_DIR = root .. "/agent"
vim.cmd("runtime plugin/coact.lua")

local integrations = require("coact.integrations")
local spec = assert(integrations.spec("pi"))
local quiet = { notify = false }

local function state()
  return (integrations.status("pi"))
end

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

assert(spec.target == vim.fs.normalize(root .. "/agent/extensions/coact-nvim.ts"), spec.target)
assert(vim.fn.filereadable(spec.source) == 1, "shipped Pi extension should exist: " .. spec.source)
assert(state() == "missing", state())

assert(integrations.install("pi", quiet)[1].ok, "install should succeed")
assert(state() == "installed", state())
assert(vim.uv.fs_lstat(spec.target).type == "link", "install should link, not copy")
assert(integrations.install(nil, quiet)[1].ok, "reinstall should be idempotent")

vim.uv.fs_unlink(spec.target)
vim.uv.fs_symlink(root .. "/old-checkout/coact-nvim.ts", spec.target)
assert(state() == "stale", state())
assert(integrations.install("pi", quiet)[1].ok and state() == "installed", "stale links should be relinked")

vim.uv.fs_unlink(spec.target)
write(spec.target, read(spec.source))
assert(state() == "copy", state())
assert(integrations.install("pi", quiet)[1].ok and state() == "installed", "identical copies should be relinked")

vim.uv.fs_unlink(spec.target)
write(spec.target, "// user extension")
assert(state() == "foreign", state())
assert(not integrations.install("pi", quiet)[1].ok, "foreign files need force")
assert(not integrations.uninstall("pi", quiet)[1].ok, "foreign files need force to uninstall")
assert(read(spec.target) == "// user extension", "refused operations must not touch foreign files")

local reports = {}
local function reporter(kind)
  return function(message)
    table.insert(reports, { kind, message })
  end
end
local report = { ok = reporter("ok"), warn = reporter("warn"), info = reporter("info"), error = reporter("error") }
integrations.health(report)
local pi_available = vim.fn.executable("pi") == 1
assert(
  reports[1][1] == (pi_available and "warn" or "info"),
  "health should flag foreign files when pi is available: " .. vim.inspect(reports)
)

vim.cmd("silent Coact! extension-install pi")
assert(state() == "installed", ":Coact! extension-install should replace foreign files")
reports = {}
integrations.health(report)
assert(reports[1][1] == "ok", vim.inspect(reports))

assert(vim.tbl_contains(require("coact").complete_command("", "Coact extension-install "), "pi"), "install completion")
vim.cmd("silent Coact extension-uninstall pi")
assert(state() == "missing", ":Coact extension-uninstall should remove the link")
assert(vim.uv.fs_stat(spec.source), "uninstall must not touch the shipped file")

vim.fn.delete(root, "rf")
print("integrations test passed")
