-- Coact mode: converse with an agent through a Zettelkasten of Org cards.
-- The pinned main card is the conversation; see :help coact-mode.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")
local run = require("coact.mode.run")
local ui = require("coact.mode.ui")
local workspace = require("coact.mode.workspace")

local M = {}

local function notify(message, level)
  vim.notify("Coact mode: " .. message, level or vim.log.levels.INFO)
end

local function current()
  return vim.api.nvim_get_current_buf()
end

local function in_workspace(bufnr)
  if workspace.root(bufnr) then
    return true
  end
  notify("this buffer is not in a chat workspace; :CoactMode init creates one", vim.log.levels.WARN)
  return false
end

local function apply(result, message)
  local ok, err = lsp.apply(result.edits)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  if message then
    notify(message)
  end
  ui.decorate(current())
  return true
end

local function card_body(bufnr, id)
  lsp.locate(bufnr, id, function(err, target, row)
    if err then
      return
    end
    if vim.api.nvim_get_current_buf() ~= target then
      vim.api.nvim_set_current_buf(target)
    end
    -- Heading, then a drawer of :PROPERTIES:, :ID: and :END:.
    local last = vim.api.nvim_buf_line_count(target)
    vim.api.nvim_win_set_cursor(0, { math.min(row + 4, last), 0 })
  end)
end

--- Create a chat workspace and open its first card file.
function M.init(dir)
  local root, file = workspace.init(dir)
  vim.cmd.edit(vim.fn.fnameescape(file))
  notify("workspace " .. vim.fn.fnamemodify(root, ":~"))
  return root
end

local function selection_range(bufnr, range)
  if not range then
    return nil
  end
  return lsp.range(bufnr, range[1], range[2])
end

-- Create a card from the selection: callback(result) after it exists.
local function create(bufnr, opts, new_file, callback)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = selection_range(bufnr, opts.range),
    title = opts.title,
    newFile = new_file,
    labels = config.get().labels,
  }
  lsp.request(bufnr, "coact/new", params, function(err, result)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    if apply(result) then
      callback(result)
    end
  end)
end

--- A new card at the end of the file; a selection is quoted and linked.
function M.new(opts)
  opts = opts or {}
  local bufnr = current()
  if in_workspace(bufnr) then
    create(bufnr, opts, false, function(result)
      card_body(bufnr, result.id)
    end)
  end
end

--- Pin the card at the cursor (or at pos) as the chat entry.
function M.pin(pos, callback)
  local bufnr = current()
  if not in_workspace(bufnr) then
    return
  end
  if run.busy() then
    return notify("wait for the running call, or stop it first", vim.log.levels.WARN)
  end
  local params = lsp.position(bufnr, pos)
  params.thread = workspace.new_thread()
  lsp.request(bufnr, "coact/pin", params, function(err, result)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    if apply(result, "pinned; thread " .. result.thread) then
      run.thread_changed(result.thread)
      if callback then
        callback(result)
      end
    end
  end)
end

function M.unpin()
  local bufnr = current()
  if not in_workspace(bufnr) then
    return
  end
  lsp.request(bufnr, "coact/unpin", lsp.position(bufnr), function(err, result)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    apply(result, "unpinned; the thread is kept")
  end)
end

--- New card (from the selection) and pin it: a side discussion entry.
local function open(path)
  local how = config.get().ask.open
  if type(how) == "function" then
    how(path)
  else
    vim.cmd(how .. " " .. vim.fn.fnameescape(path))
  end
end

--- A side discussion: a new card in its own file, quoting the selection,
--- opened per ask.open (default: a vertical split) and pinned.
function M.ask(opts)
  opts = opts or {}
  local bufnr = current()
  if not in_workspace(bufnr) then
    return
  end
  if run.busy() then
    return notify("wait for the running call, or stop it first", vim.log.levels.WARN)
  end
  create(bufnr, opts, true, function(result)
    open(vim.uri_to_fname(result.uri))
    local target = current()
    M.attach(target)
    lsp.locate(target, result.id, function(err, _, row)
      if err then
        return notify(err, vim.log.levels.ERROR)
      end
      M.pin({ row, 0 }, function()
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(target), 0 })
        notify("write your question in this card, then submit")
      end)
    end)
  end)
end

-- The current buffer, or the active thread's card buffer when the current
-- one is outside the workspace (e.g. after reviewing an agent's edit).
local function thread_buffer()
  local bufnr = current()
  if not workspace.root(bufnr) then
    bufnr = run.card_buffer() or bufnr
  end
  return in_workspace(bufnr) and bufnr or nil
end

function M.submit()
  local bufnr = thread_buffer()
  if bufnr then
    run.submit(bufnr)
  end
end

function M.stop()
  run.stop()
end

function M.compact(instructions)
  local bufnr = thread_buffer()
  if bufnr then
    run.compact(bufnr, instructions)
  end
end

--- Show the readable trace of the card or link under the cursor.
function M.trace()
  local bufnr = current()
  if not in_workspace(bufnr) then
    return
  end
  lsp.request(bufnr, "coact/trace", lsp.position(bufnr), function(err, result)
    if err then
      return notify(err, vim.log.levels.WARN)
    end
    ui.float(result.title, #result.lines > 0 and result.lines or { "(empty)" })
  end)
end

--- Build the language server with dune.
function M.build()
  local dir = vim.fs.joinpath(lsp.plugin_root(), "ocaml")
  if vim.fn.executable("dune") ~= 1 then
    return notify("dune is not on $PATH; install OCaml and dune (opam), then retry", vim.log.levels.ERROR)
  end
  notify("building coact-zk-lsp…")
  vim.system(
    { "dune", "build", "--root", dir, "--profile", "release", "./bin/coact_zk_lsp.exe" },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          notify("coact-zk-lsp built")
        else
          notify("build failed:\n" .. (result.stderr or ""), vim.log.levels.ERROR)
        end
      end)
    end
  )
end

--- Pick a thread from any workspace and open it.
function M.open()
  require("coact.mode.finder").threads()
end

--- Search every card of every workspace.
function M.search()
  require("coact.mode.finder").cards()
end

--- A short status for statuslines: nil when idle.
function M.status()
  local phase = run.status()
  return phase and (config.get().icons.busy .. " " .. phase) or nil
end

local subcommands = {
  init = function(args)
    M.init(args[1])
  end,
  new = function(args, opts)
    M.new({ title = #args > 0 and table.concat(args, " ") or nil, range = opts.range })
  end,
  ask = function(_, opts)
    M.ask({ range = opts.range })
  end,
  pin = function()
    M.pin()
  end,
  unpin = M.unpin,
  submit = M.submit,
  stop = M.stop,
  compact = function(args)
    M.compact(#args > 0 and table.concat(args, " ") or nil)
  end,
  trace = M.trace,
  open = M.open,
  search = M.search,
  build = M.build,
  status = function()
    notify(M.status() or "idle")
  end,
}

M.subcommands = subcommands

local function visual_range(opts)
  if opts.range and opts.range > 0 then
    local first = vim.api.nvim_buf_get_mark(0, "<")
    local last = vim.api.nvim_buf_get_mark(0, ">")
    if opts.line1 == first[1] and opts.line2 == last[1] then
      return { first, last }
    end
    local tail = vim.api.nvim_buf_get_lines(0, opts.line2 - 1, opts.line2, false)[1] or ""
    return { { opts.line1, 0 }, { opts.line2, math.max(#tail - 1, 0) } }
  end
  return nil
end

function M.command(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1) or "status"
  local handler = subcommands[name]
  if not handler then
    return notify("unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  handler(args, { range = visual_range(opts) })
end

function M.complete(arglead, line)
  if line:match("^%S+%s+%S+%s") then
    return {}
  end
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return vim.tbl_filter(function(name)
    return name:find(arglead, 1, true) == 1
  end, names)
end

local mapped = {}

local function keymaps(bufnr)
  local maps = config.get().keymaps
  if not maps or mapped[bufnr] then
    return
  end
  mapped[bufnr] = true
  local actions = {
    submit = { "n", "<Plug>(CoactModeSubmit)", "submit the question" },
    stop = { "n", "<Plug>(CoactModeStop)", "stop the call" },
    pin = { "n", "<Plug>(CoactModePin)", "pin this card" },
    unpin = { "n", "<Plug>(CoactModeUnpin)", "unpin" },
    new = { { "n", "x" }, "<Plug>(CoactModeNew)", "new card" },
    ask = { { "n", "x" }, "<Plug>(CoactModeAsk)", "ask in a new pinned card" },
    compact = { "n", "<Plug>(CoactModeCompact)", "compact the thread" },
    trace = { "n", "<Plug>(CoactModeTrace)", "show the trace" },
  }
  for name, lhs in pairs(maps) do
    local action = actions[name]
    if action and lhs then
      vim.keymap.set(action[1], lhs, action[2], { buffer = bufnr, remap = true, desc = "Coact mode: " .. action[3] })
    end
  end
end

--- Attach Coact mode to a workspace Org buffer.
function M.attach(bufnr)
  bufnr = bufnr or current()
  local root = workspace.root(bufnr)
  if not root then
    return
  end
  workspace.remember(root)
  local client, err = lsp.attach(bufnr)
  if not client then
    if not M._warned then
      M._warned = true
      notify(err, vim.log.levels.WARN)
    end
    return
  end
  keymaps(bufnr)
  ui.schedule(bufnr)
  require("coact.mode.directives").refresh(vim.fn.getcwd())
end

local augroup = vim.api.nvim_create_augroup("CoactMode", { clear = true })
local initialized = false

--- Configure Coact mode. Optional: defaults apply on first use.
function M.setup(opts)
  config.setup(opts)
  M.setup_once()
end

function M.setup_once()
  if initialized then
    return
  end
  initialized = true
  ui.highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = ui.highlights })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufEnter" }, {
    group = augroup,
    pattern = "*.org",
    callback = function(event)
      if lsp.client(event.buf) then
        ui.schedule(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = augroup,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == lsp.name then
        require("coact.mode.directives").push(event.buf)
        ui.schedule(event.buf)
      end
    end,
  })
  -- @contexts resolve in the code window used last.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = augroup,
    callback = function(event)
      require("coact.mode.directives").track(event.buf, vim.api.nvim_get_current_win())
    end,
  })
  require("coact.mode.directives").track(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
  vim.api.nvim_create_autocmd("VimLeavePre", { group = augroup, callback = run.shutdown })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "org" then
      M.attach(bufnr)
    end
  end
end

return M
