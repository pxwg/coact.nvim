-- The coact-zk language server: attachment, requests and plan application.
local config = require("coact.mode.config")
local workspace = require("coact.mode.workspace")

local M = {}

M.name = "coact-zk"

-- Resolved once at load: a relative runtimepath entry must not follow :cd.
local root = (function()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  local file = vim.fs.normalize(vim.fn.fnamemodify(source, ":p"))
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(file))))
end)()

local function plugin_root()
  return root
end

M.plugin_root = plugin_root

--- The server command, or nil with a reason.
function M.cmd()
  local cmd = config.get().lsp.cmd
  if cmd then
    return type(cmd) == "string" and { cmd } or cmd
  end
  local built = vim.fs.joinpath(plugin_root(), "ocaml", "_build", "default", "bin", "coact_zk_lsp.exe")
  if vim.fn.executable(built) == 1 then
    return { built }
  end
  if vim.fn.executable("coact-zk-lsp") == 1 then
    return { "coact-zk-lsp" }
  end
  return nil, "coact-zk-lsp is not built; run :CoactMode build"
end

function M.client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = M.name })[1]
end

--- Attach the server to a workspace buffer. Returns the client or nil, err.
function M.attach(bufnr)
  bufnr = bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local existing = M.client(bufnr)
  if existing then
    return existing
  end
  local root = workspace.root(bufnr)
  if not root then
    return nil, "not in a Coact chat workspace (no " .. workspace.marker .. ")"
  end
  local cmd, err = M.cmd()
  if not cmd then
    return nil, err
  end
  local id = vim.lsp.start({
    name = M.name,
    cmd = cmd,
    root_dir = root,
    workspace_folders = { { uri = vim.uri_from_fname(root), name = vim.fs.basename(root) } },
    -- Plans are computed against the buffer text; send every change at once.
    flags = { debounce_text_changes = 0 },
  }, { bufnr = bufnr })
  return id and vim.lsp.get_client_by_id(id) or nil, id and nil or "failed to start " .. M.name
end

--- Request on the buffer's client: callback(err, result).
function M.request(bufnr, method, params, callback)
  local client, err = M.attach(bufnr)
  if not client then
    return callback(err)
  end
  client:request(method, params or vim.empty_dict(), function(request_err, result)
    if request_err then
      return callback(request_err.message or tostring(request_err))
    end
    callback(nil, result)
  end, bufnr)
end

--- Position params for the cursor (or a given {row, col}, 1-based row).
function M.position(bufnr, pos)
  bufnr = bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local win = vim.fn.bufwinid(bufnr)
  pos = pos or (win ~= -1 and vim.api.nvim_win_get_cursor(win)) or { 1, 0 }
  local line = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ""
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = pos[1] - 1, character = vim.str_utfindex(line, "utf-16", math.min(pos[2], #line), false) },
  }
end

function M.range(bufnr, first, last)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first[1] - 1, last[1], false)
  local tail = lines[#lines] or ""
  local stop = math.min(last[2] + 1, #tail)
  return {
    start = {
      line = first[1] - 1,
      character = vim.str_utfindex(lines[1] or "", "utf-16", math.min(first[2], #(lines[1] or "")), false),
    },
    ["end"] = { line = last[1] - 1, character = vim.str_utfindex(tail, "utf-16", stop, false) },
  }
end

local function version(bufnr)
  local versions = vim.lsp.util.buf_versions
  return versions and versions[bufnr] or vim.b[bufnr].changedtick
end

--- Run fn with the buffer modifiable, even while a call locks it.
function M.with_modifiable(bufnr, fn)
  local was = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[bufnr].modifiable = was
  if not ok then
    error(err, 0)
  end
end

local function save(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent keepalt write")
  end)
end

--- Apply plan edits ({uri, path, version, exists, edits}[]) and save the
--- touched workspace files. Refuses buffers that changed since planning.
--- Returns true or nil, err.
--- With opts.keep_unsaved, a buffer that had unsaved changes stays unsaved.
function M.apply(files, opts)
  local targets = {}
  for _, file in ipairs(files or {}) do
    local bufnr = vim.fn.bufadd(file.path)
    vim.fn.bufload(bufnr)
    if file.version ~= nil and file.version ~= vim.NIL and version(bufnr) ~= file.version then
      return nil, ("%s changed while the edit was planned; try again"):format(vim.fn.fnamemodify(file.path, ":~:."))
    end
    if vim.bo[bufnr].modified and (file.version == nil or file.version == vim.NIL) then
      return nil, ("%s has unsaved changes the server has not seen"):format(vim.fn.fnamemodify(file.path, ":~:."))
    end
    table.insert(targets, { bufnr = bufnr, file = file, modified = vim.bo[bufnr].modified })
  end
  for _, target in ipairs(targets) do
    local bufnr, file = target.bufnr, target.file
    if file.exists == false then
      vim.fn.mkdir(vim.fs.dirname(file.path), "p")
    end
    M.with_modifiable(bufnr, function()
      vim.lsp.util.apply_text_edits(file.edits, bufnr, "utf-16")
    end)
    if not (opts and opts.keep_unsaved and target.modified) then
      save(bufnr)
    end
  end
  return true
end

--- The first body line of the card whose heading is at row (1-based):
--- after its drawer, and after the blank line the layout puts there.
function M.body_row(bufnr, row)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, math.min(count, row + 40), false)
  local body = row + 1
  if (lines[1] or ""):match("^%s*:PROPERTIES:%s*$") then
    for i, line in ipairs(lines) do
      if line:match("^%s*:END:%s*$") then
        body = row + i + 1
        break
      end
    end
  end
  local next_line = vim.api.nvim_buf_get_lines(bufnr, body - 1, body, false)[1]
  if config.get().layout.blank_after_drawer and next_line == "" and body < count then
    body = body + 1
  end
  return math.min(body, count)
end

--- Locate a card: callback(err, bufnr, row) with a 1-based row.
function M.locate(bufnr, id, callback)
  M.request(bufnr, "coact/locate", { id = id }, function(err, location)
    if err or not location or location == vim.NIL then
      return callback(err or ("unknown card " .. tostring(id)))
    end
    local target = vim.fn.bufadd(vim.uri_to_fname(location.uri))
    vim.fn.bufload(target)
    callback(nil, target, location.range.start.line + 1)
  end)
end

return M
