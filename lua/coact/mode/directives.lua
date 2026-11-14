-- Turn directives in user cards: /command runs a Pi skill or prompt
-- template, @context adds Neovim context. The server recognizes them from
-- the registry sent here; they are expanded once, when their card is sent.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")
local workspace = require("coact.mode.workspace")

local M = {}

--- Neovim contexts, resolved in the code window used last.
M.contexts = {
  { name = "buffer", description = "The whole buffer of the code window used last" },
  { name = "selection", description = "The last visual selection there" },
  { name = "cursor", description = "Forty lines around its cursor" },
  { name = "diagnostics", description = "Its diagnostics" },
  { name = "quickfix", description = "The quickfix list" },
  { name = "buffers", description = "The listed buffers" },
  { name = "cwd", description = "The working directory" },
}

local source = nil -- { buf, win } of the code window used last

--- Remember a window as the context source unless it shows a card.
function M.track(bufnr, winid)
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" or workspace.root(bufnr) then
    return
  end
  source = { buf = bufnr, win = winid }
end

function M.source()
  if source and vim.api.nvim_buf_is_valid(source.buf) then
    return source
  end
  return nil
end

--- Resolve @name in the source window: its text, or nil, err.
function M.resolve_context(name)
  local src = M.source()
  if not src and name ~= "quickfix" and name ~= "buffers" and name ~= "cwd" then
    return nil, "@" .. name .. " needs a code window; visit one before sending"
  end
  local payload
  local function resolve()
    payload = require("coact.parser")._resolve_context_payload("@" .. name, {})
  end
  if src and vim.api.nvim_win_is_valid(src.win) and vim.api.nvim_win_get_buf(src.win) == src.buf then
    vim.api.nvim_win_call(src.win, resolve)
  elseif src then
    vim.api.nvim_buf_call(src.buf, resolve)
  else
    resolve()
  end
  local parts = {}
  for _, input in ipairs(payload and payload.inputs or {}) do
    if input.type == "text" and input.text then
      table.insert(parts, input.text)
    end
  end
  if #parts == 0 then
    return nil, "@" .. name .. " has nothing to add"
  end
  return table.concat(parts, "\n")
end

-- ---- the command registry: Pi's skills and prompt templates ----

local function cache_path()
  return vim.fs.joinpath(config.get().workspace_root, "commands.json")
end

local commands = nil

local function load_cache()
  if commands then
    return commands
  end
  local ok, value = pcall(vim.json.decode, workspace.read_file(cache_path()) or "[]")
  commands = ok and type(value) == "table" and value or {}
  return commands
end

--- Push the registry to every attached server.
function M.push(bufnr)
  local params = { commands = load_cache(), contexts = M.contexts, controls = require("coact.mode.controls").list }
  local clients = bufnr and { lsp.client(bufnr) } or vim.lsp.get_clients({ name = lsp.name })
  for _, client in ipairs(clients) do
    client:notify("coact/registry", params)
  end
end

--- Store Pi's get_commands result: only skills and prompt templates expand
--- in cards.
function M.set_commands(list)
  local out = {}
  for _, command in ipairs(list or {}) do
    if (command.source == "skill" or command.source == "prompt") and type(command.name) == "string" then
      table.insert(out, { name = command.name, description = command.description or "" })
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  commands = out
  workspace.write_file(cache_path(), vim.json.encode(out))
  M.push()
end

local refreshed = false

--- Ask a short-lived Pi for its commands, once per Neovim session.
function M.refresh(cwd)
  if refreshed then
    return
  end
  refreshed = true
  local pi = config.get().pi
  local cmd = vim.deepcopy(pi.command)
  vim.list_extend(cmd, { "--no-session" })
  vim.list_extend(cmd, pi.args or {})
  local ok = pcall(vim.system, cmd, {
    cwd = cwd,
    env = pi.env,
    stdin = '{"id":"commands","type":"get_commands"}\n',
    text = true,
  }, function(result)
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      local decoded_ok, message = pcall(vim.json.decode, line)
      if decoded_ok and type(message) == "table" and message.id == "commands" and message.success then
        vim.schedule(function()
          M.set_commands(message.data and message.data.commands)
        end)
      end
    end
  end)
  if not ok then
    refreshed = false
  end
end

return M
