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
local pending, pending_buf, scheduled = {}, nil, false
local last_buf = nil
local sequence = 0

local function warn(message)
  vim.notify("Coact mode: naming cards failed: " .. tostring(message), vim.log.levels.WARN)
end

--- Ask Pi to name cards ({ id, kind, text, revision }[]), in batches.
function M.send(bufnr, cards, client)
  local root = workspace.root(bufnr)
  if not root or not client then
    return
  end
  last_buf = bufnr
  for first = 1, #cards, batch_size do
    sequence = sequence + 1
    local path = workspace.state_path(root, "requests", ("titles-%d-%d.json"):format(os.time(), sequence))
    workspace.write_file(path, vim.json.encode({ cards = vim.list_slice(cards, first, first + batch_size - 1) }))
    client:prompt("/coact-title " .. path, function(err)
      if err then
        warn(err)
      end
    end)
  end
end

local function flush()
  local bufnr, ids = pending_buf, vim.tbl_keys(pending)
  pending, pending_buf, scheduled = {}, nil, false
  local client = require("coact.mode.run").client()
  if not client or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or #ids == 0 then
    return
  end
  lsp.request(bufnr, "coact/title_candidates", { ids = ids, labels = config.labels() }, function(err, cards)
    if not err and type(cards) == "table" and #cards > 0 then
      M.send(bufnr, cards, client)
    end
  end)
end

--- Queue cards to be named; a short delay gathers a turn's cards into one call.
function M.queue(bufnr, ids)
  if not config.get().titles.enabled then
    return
  end
  for _, id in pairs(ids) do
    if type(id) == "string" then
      pending[id] = true
    end
  end
  pending_buf = bufnr
  if not scheduled then
    scheduled = true
    vim.defer_fn(flush, 50)
  end
end

--- The extension's titles: apply those whose cards still qualify.
function M.apply(request, reply)
  reply({})
  if request.error then
    return warn(request.error)
  end
  local bufnr = last_buf and vim.api.nvim_buf_is_valid(last_buf) and last_buf or require("coact.mode.run").card_buffer()
  if #(request.titles or {}) == 0 or not bufnr then
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
