-- Card decorations, streaming display and the busy indicator.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")

local M = {}

M.ns = vim.api.nvim_create_namespace("coact_mode")
local stream_ns = vim.api.nvim_create_namespace("coact_mode_stream")

function M.highlights()
  local links = {
    CoactModeUser = "DiagnosticInfo",
    CoactModeAssistant = "DiagnosticHint",
    CoactModeSynthesis = "DiagnosticOk",
    CoactModeTrace = "Comment",
    CoactModeNote = "Comment",
    CoactModePin = "DiagnosticWarn",
    CoactModeStream = "Comment",
    CoactModeBusy = "DiagnosticWarn",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, "CoactModeRevised", { underdotted = true, default = true })
end

local kinds = {
  user = "CoactModeUser",
  assistant = "CoactModeAssistant",
  synthesis = "CoactModeSynthesis",
  trace = "CoactModeTrace",
}

local pending = {}

--- Refresh kind icons, pin marks and revised spans from the server.
function M.decorate(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not lsp.client(bufnr) then
    return
  end
  lsp.request(bufnr, "coact/decorations", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, function(err, result)
    if err or not result or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local icons = config.get().icons
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    local count = vim.api.nvim_buf_line_count(bufnr)
    for _, card in ipairs(result.cards or {}) do
      if card.line < count then
        local chunks = {}
        if card.pin then
          table.insert(chunks, { icons.pin .. " ", "CoactModePin" })
        end
        local kind = card.kind ~= vim.NIL and card.kind or nil
        local icon = kind and icons[kind] or icons.note
        table.insert(chunks, { icon .. " " .. (kind or "card"), kinds[kind] or "CoactModeNote" })
        if card.origin == "agent+user" then
          table.insert(chunks, { " " .. icons.revised, "CoactModeRevised" })
        end
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, card.line, 0, {
          virt_text = chunks,
          virt_text_pos = "eol",
          hl_mode = "combine",
          priority = 50,
        })
      end
    end
    for _, range in ipairs(result.edited or {}) do
      local line = range.start.line
      if line < count then
        local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
          end_col = #text,
          hl_group = "CoactModeRevised",
          priority = 60,
        })
      end
    end
  end)
end

--- Debounced decoration refresh.
function M.schedule(bufnr)
  if pending[bufnr] then
    return
  end
  pending[bufnr] = true
  vim.defer_fn(function()
    pending[bufnr] = nil
    M.decorate(bufnr)
  end, 150)
end

--- Show a run under the answer heading: status text and streamed lines.
function M.stream(bufnr, row, status, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, stream_ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(bufnr)
  row = math.max(1, math.min(row, count))
  local lines = {}
  if text and text ~= "" then
    local all = vim.split(text, "\n", { plain = true })
    local max = config.get().stream.max_lines
    local first = math.max(1, #all - max + 1)
    if first > 1 then
      table.insert(lines, { { "  …", "CoactModeStream" } })
    end
    for i = first, #all do
      table.insert(lines, { { "  " .. all[i], "CoactModeStream" } })
    end
  end
  vim.api.nvim_buf_set_extmark(bufnr, stream_ns, row - 1, 0, {
    virt_text = { { config.get().icons.busy .. " " .. status, "CoactModeBusy" } },
    virt_text_pos = "eol",
    virt_lines = #lines > 0 and lines or nil,
    priority = 100,
  })
end

function M.clear_stream(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, stream_ns, 0, -1)
  end
end

--- A float listing lines, closed with q.
function M.float(title, lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype or "markdown"
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.min(#lines, math.floor(vim.o.lines * 0.6)),
    row = math.floor(vim.o.lines * 0.15),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return buf, win
end

return M
