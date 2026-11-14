-- Asynchronous semantic titles. After a turn, a background call names its
-- cards by what they discuss. The server renames only cards still titled by
-- default or automatically whose text is unchanged; a title set by hand
-- stays. Failures leave the default title and never hold up a turn.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")
local ui = require("coact.mode.ui")
local workspace = require("coact.mode.workspace")

local M = {}

local batch_size = 12
local pending, pending_buf, pending_main, scheduled = {}, nil, nil, false
local last_buf = nil
local sequence = 0

local function warn(message)
  vim.notify("Coact mode: naming cards failed: " .. tostring(message), vim.log.levels.WARN)
end

--- Ask Pi to name cards ({ id, kind, text, revision }[]), in batches; the
--- first batch also picks the phrase linking an asked passage back.
function M.send(bufnr, cards, client, link)
  local root = workspace.root(bufnr)
  if not root or not client then
    return
  end
  last_buf = bufnr
  for first = 1, math.max(#cards, 1), batch_size do
    sequence = sequence + 1
    local path = workspace.state_path(root, "requests", ("titles-%d-%d.json"):format(os.time(), sequence))
    workspace.write_file(
      path,
      vim.json.encode({
        cards = vim.list_slice(cards, first, first + batch_size - 1),
        link = first == 1 and link or nil,
      })
    )
    client:prompt("/coact-title " .. path, function(err)
      if err then
        warn(err)
      end
    end)
  end
end

local function flush()
  local bufnr, ids, main = pending_buf, vim.tbl_keys(pending), pending_main
  pending, pending_buf, pending_main, scheduled = {}, nil, nil, false
  local client = require("coact.mode.run").client()
  if not client or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local function with_link(callback)
    if not (main and config.get().ask.link) then
      return callback(nil)
    end
    lsp.request(bufnr, "coact/link_candidate", { main = main }, function(err, link)
      callback(not err and link ~= vim.NIL and link or nil)
    end)
  end
  local function with_cards(callback)
    if #ids == 0 then
      return callback({})
    end
    lsp.request(bufnr, "coact/title_candidates", { ids = ids, labels = config.labels() }, function(err, cards)
      callback(not err and type(cards) == "table" and cards or {})
    end)
  end
  with_link(function(link)
    with_cards(function(cards)
      if #cards > 0 or link then
        M.send(bufnr, cards, client, link)
      end
    end)
  end)
end

--- After a turn of thread main: queue its cards to be named (and its passage
--- linked back); a short delay gathers them into one call.
function M.queue(bufnr, ids, main)
  if not config.get().titles.enabled then
    ids = {}
  end
  if main then
    pending_main = main
  end
  for _, id in pairs(ids) do
    if type(id) == "string" then
      pending[id] = true
    end
  end
  pending_buf = bufnr
  if next(pending) == nil and not pending_main then
    return
  end
  if not scheduled then
    scheduled = true
    vim.defer_fn(flush, 50)
  end
end

-- Wrap the chosen phrase of the asked passage in a link to the thread.
local function link_back(bufnr, main, anchor)
  lsp.request(bufnr, "coact/link_back", { main = main, anchor = anchor }, function(err, result)
    if err then
      -- No unique phrase: the thread still links to its passage.
      return
    end
    if lsp.apply(result.edits, { keep_unsaved = true }) then
      for _, file in ipairs(result.edits) do
        local target = vim.fn.bufnr(file.path)
        if target ~= -1 then
          ui.decorate(target)
        end
      end
    end
  end)
end

--- The extension's titles: apply those whose cards still qualify.
function M.apply(request, reply)
  reply({})
  if request.error then
    return warn(request.error)
  end
  local bufnr = last_buf and vim.api.nvim_buf_is_valid(last_buf) and last_buf or require("coact.mode.run").card_buffer()
  if not bufnr then
    return
  end
  if type(request.anchor) == "string" and type(request.main) == "string" then
    link_back(bufnr, request.main, request.anchor)
  end
  if #(request.titles or {}) == 0 then
    return
  end
  lsp.request(bufnr, "coact/retitle", { titles = request.titles, labels = config.labels() }, function(err, result)
    if err then
      return warn(err)
    end
    -- A buffer that changed meanwhile is left alone; its titles stay default.
    if #(result.edits or {}) > 0 and lsp.apply(result.edits, { keep_unsaved = true }) then
      ui.decorate(bufnr)
    end
  end)
end

return M
