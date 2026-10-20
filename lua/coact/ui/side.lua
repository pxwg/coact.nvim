-- Side discussion floats: pinned selection on top, side history in the
-- middle, composer below. The main chat stays visible underneath.
local config = require("coact.config")

local M = {}

local group = vim.api.nvim_create_augroup("coact.nvim.side_ui", { clear = true })

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

function M.is(thread)
  return type(thread) == "table" and type(thread.side) == "table"
end

local function opts()
  local ui = config.get().ui or {}
  return ui.side or {}
end

local function border()
  return opts().border or "rounded"
end

local function ui_state(thread)
  thread.side_ui = thread.side_ui or {}
  return thread.side_ui
end

local function quote_lines(thread)
  local anchor = thread.side and thread.side.anchor or {}
  return vim.split(tostring(anchor.quote or "(selection unavailable)"), "\n", { plain = true })
end

local function quote_label(thread)
  local anchor = thread.side and thread.side.anchor or {}
  if anchor.kind == "file" then
    return (" Selected · %s L%d-L%d · gQ full "):format(
      tostring(anchor.filename or "file"),
      anchor.start_line or 0,
      anchor.end_line or 0
    )
  end
  return " Selected from chat · gQ full "
end

local function status_label(thread)
  local status = thread.side and thread.side.status or "open"
  if status == "open" then
    return " Side discussion · A annotate · Q close · q hide "
  end
  return (" Side discussion · %s "):format(status)
end

local function quote_buf(thread)
  local ui = ui_state(thread)
  if valid_buf(ui.quote_buf) then
    return ui.quote_buf
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  ui.quote_buf = bufnr
  pcall(vim.api.nvim_buf_set_name, bufnr, "coact://side/" .. tostring(thread.id) .. "/selection")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].coact_role = "selection"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, quote_lines(thread))
  vim.bo[bufnr].modifiable = false
  local anchor = thread.side and thread.side.anchor or {}
  vim.bo[bufnr].filetype = anchor.kind == "file" and (anchor.filetype or "") or "markdown"
  vim.keymap.set("n", "q", function()
    local ui_now = ui_state(thread)
    if valid_win(ui_now.full_win) and vim.api.nvim_get_current_win() == ui_now.full_win then
      vim.api.nvim_win_close(ui_now.full_win, true)
      if valid_win(thread.prompt_winid or thread.winid) then
        vim.api.nvim_set_current_win(thread.prompt_winid or thread.winid)
      end
    else
      M.hide(thread)
    end
  end, { buffer = bufnr, desc = "Back to the side discussion" })
  vim.keymap.set("n", "gQ", function()
    M.quote(thread)
  end, { buffer = bufnr, desc = "Full selected text" })
  vim.keymap.set("n", "<Tab>", function()
    if valid_win(thread.prompt_winid or thread.winid) then
      vim.api.nvim_set_current_win(thread.prompt_winid or thread.winid)
    end
  end, { buffer = bufnr, desc = "Focus the side discussion" })
  return bufnr
end

local function geometry(thread, prompt_height)
  local o = opts()
  local ui_opts = config.get().ui or {}
  local width_ratio = tonumber(o.width) or ui_opts.width or 0.82
  local height_ratio = tonumber(o.height) or ui_opts.height or 0.82
  local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * width_ratio)))
  local available = math.max(6, vim.o.lines - vim.o.cmdheight - 2)
  local total = math.min(available, math.max(12, math.floor(available * height_ratio)))
  local edge = (border() == "none" or border() == "") and 0 or 2
  local has_prompt = prompt_height ~= nil and prompt_height > 0
  local panes = has_prompt and 3 or 2
  local inner = math.max(panes, total - panes * edge)
  local qh = math.max(1, math.min(tonumber(o.selection_height) or 4, #quote_lines(thread), inner - panes))
  local ph = has_prompt and math.max(1, math.min(prompt_height, inner - qh - 1)) or 0
  local hh = math.max(1, inner - qh - ph)
  local row = math.max(0, math.floor((available - total) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return {
    width = width,
    col = col,
    quote = { row = row, height = qh },
    history = { row = row + qh + edge, height = hh },
    prompt = has_prompt and { row = row + qh + edge + hh + edge, height = ph } or nil,
  }
end

local function float(width, height, row, col, title, zindex)
  return {
    relative = "editor",
    style = "minimal",
    border = border(),
    width = width,
    height = height,
    row = row,
    col = col,
    title = title,
    title_pos = "center",
    zindex = zindex,
  }
end

local function set_config(win, cfg)
  if valid_win(win) then
    pcall(vim.api.nvim_win_set_config, win, cfg)
  end
end

local function full_config()
  local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.8)))
  local height = math.max(3, math.min(vim.o.lines - vim.o.cmdheight - 4, math.floor(vim.o.lines * 0.65)))
  return float(
    width,
    height,
    1,
    math.max(0, math.floor((vim.o.columns - width) / 2)),
    " Selected text · q back · Tab side ",
    70
  )
end

function M.layout(thread, prompt_height)
  if not valid_win(thread.winid) then
    return
  end
  local ui = ui_state(thread)
  if prompt_height == nil and valid_win(thread.prompt_winid) then
    prompt_height = vim.api.nvim_win_get_height(thread.prompt_winid)
  end
  local g = geometry(thread, valid_win(thread.prompt_winid) and prompt_height or nil)
  local quote_cfg = float(g.width, g.quote.height, g.quote.row, g.col, quote_label(thread), 61)
  if valid_win(ui.quote_win) then
    set_config(ui.quote_win, quote_cfg)
  else
    ui.quote_win = vim.api.nvim_open_win(quote_buf(thread), false, quote_cfg)
    vim.wo[ui.quote_win].wrap = true
    vim.wo[ui.quote_win].linebreak = true
    vim.wo[ui.quote_win].conceallevel = 0
  end
  set_config(thread.winid, float(g.width, g.history.height, g.history.row, g.col, status_label(thread), 60))
  if g.prompt then
    set_config(thread.prompt_winid, float(g.width, g.prompt.height, g.prompt.row, g.col, " Ask ", 60))
  end
  if valid_win(ui.full_win) then
    set_config(ui.full_win, full_config())
  end
end

local function set_keymaps(thread, bufnr)
  if not valid_buf(bufnr) or vim.b[bufnr].coact_side_keymaps then
    return
  end
  vim.b[bufnr].coact_side_keymaps = true
  vim.keymap.set("n", "Q", function()
    require("coact.side").close(thread)
  end, { buffer = bufnr, desc = "Close the side discussion and return to the main branch" })
  vim.keymap.set("n", "A", function()
    require("coact.side").annotate(thread)
  end, { buffer = bufnr, desc = "Record the side discussion as a note on the main branch" })
  vim.keymap.set("n", "gQ", function()
    M.quote(thread)
  end, { buffer = bufnr, desc = "Full selected text" })
  vim.keymap.set("n", "gq", function()
    M.focus_quote(thread)
  end, { buffer = bufnr, desc = "Focus the selected text" })
end

local function watch_history(thread, win)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if thread.winid == win or not valid_win(thread.winid) then
          M.hide(thread)
        end
      end)
    end,
  })
end

function M.open_history(bufnr, thread)
  local ui = ui_state(thread)
  ui.return_win = ui.return_win or vim.api.nvim_get_current_win()
  local g = geometry(thread, nil)
  local win =
    vim.api.nvim_open_win(bufnr, true, float(g.width, g.history.height, g.history.row, g.col, status_label(thread), 60))
  thread.winid = win
  set_keymaps(thread, bufnr)
  watch_history(thread, win)
  M.layout(thread, nil)
  return win
end

function M.open_composer(_, prompt_bufnr, prompt_height, thread)
  local g = geometry(thread, prompt_height)
  local win =
    vim.api.nvim_open_win(prompt_bufnr, true, float(g.width, g.prompt.height, g.prompt.row, g.col, " Ask ", 60))
  thread.prompt_winid = win
  set_keymaps(thread, prompt_bufnr)
  M.layout(thread, prompt_height)
  return win
end

function M.focus_quote(thread)
  local ui = ui_state(thread)
  if valid_win(ui.quote_win) then
    vim.api.nvim_set_current_win(ui.quote_win)
  else
    M.quote(thread)
  end
end

function M.quote(thread)
  local ui = ui_state(thread)
  if valid_win(ui.full_win) then
    vim.api.nvim_set_current_win(ui.full_win)
    return ui.full_win
  end
  ui.full_win = vim.api.nvim_open_win(quote_buf(thread), true, full_config())
  vim.wo[ui.full_win].wrap = true
  vim.wo[ui.full_win].linebreak = true
  vim.wo[ui.full_win].conceallevel = 0
  return ui.full_win
end

function M.refresh(thread)
  if M.is(thread) and valid_win(thread.winid) then
    M.layout(thread, nil)
  end
end

-- Hide every side window; the discussion and its draft stay alive.
function M.hide(thread)
  local ui = ui_state(thread)
  local current = vim.api.nvim_get_current_win()
  local wins = { ui.full_win, ui.quote_win, thread.prompt_winid, thread.winid }
  local focused = false
  for _, win in ipairs(wins) do
    if win == current then
      focused = true
    end
  end
  for _, win in ipairs(wins) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  ui.full_win, ui.quote_win = nil, nil
  if focused and valid_win(ui.return_win) then
    pcall(vim.api.nvim_set_current_win, ui.return_win)
  end
  ui.return_win = nil
end

-- Hide and drop the selection buffer for a finished discussion.
function M.close(thread)
  M.hide(thread)
  local ui = ui_state(thread)
  if valid_buf(ui.quote_buf) then
    pcall(vim.api.nvim_buf_delete, ui.quote_buf, { force = true })
  end
  ui.quote_buf = nil
end

return M
