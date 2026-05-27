local config = require("codex.config")

local M = {}

function M.open(bufnr)
  local opts = config.get().ui
  if opts.layout == "sidebar" then
    vim.cmd("botright vertical new")
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(winid, math.max(32, math.floor(vim.o.columns * opts.sidebar_width)))
    vim.api.nvim_win_set_buf(winid, bufnr)
    return winid
  end

  local width = math.max(48, math.floor(vim.o.columns * opts.width))
  local height = math.max(16, math.floor(vim.o.lines * opts.height))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  return vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = " Codex ",
    title_pos = "center",
  })
end

return M
