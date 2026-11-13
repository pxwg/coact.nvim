-- :checkhealth coact.mode
local lsp = require("coact.mode.lsp")
local pi = require("coact.mode.pi")
local config = require("coact.mode.config")

local M = {}

function M.check()
  local health = vim.health
  health.start("Coact mode")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Coact mode needs Neovim 0.10 or newer")
  end

  local cmd, err = lsp.cmd()
  if cmd then
    health.ok("language server: " .. table.concat(cmd, " "))
  else
    health.error(err, { "Install OCaml 5 and dune, then run :CoactMode build" })
  end

  local pi_cmd = config.get().pi.command[1]
  if vim.fn.executable(pi_cmd) == 1 then
    local result = vim.system({ pi_cmd, "--help" }, { text = true }):wait(5000)
    local help = (result.stdout or "") .. (result.stderr or "")
    if help:find("--session-id", 1, true) and help:find("--session-dir", 1, true) then
      health.ok("Pi supports --session-id and --session-dir")
    else
      health.error("Pi lacks --session-id or --session-dir; update Pi")
    end
  else
    health.error(pi_cmd .. " is not executable")
  end

  if vim.uv.fs_stat(pi.extension_path()) then
    health.ok("Pi extension: " .. pi.extension_path())
  else
    health.error("missing Pi extension " .. pi.extension_path())
  end

  if pcall(require, "coact.patch_session") then
    health.ok("file changes are reviewed with coact.nvim's hunk review")
  else
    health.warn("coact.patch_session is unavailable; agent file changes will be rejected")
  end
end

return M
