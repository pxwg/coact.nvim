local config = require("coact.config")
local statusline = require("coact.ui.statusline")
local side = require("coact.ui.side")

local M = {}

local function composer_height(value)
  return math.max(1, math.floor(tonumber(value) or 1))
end

local function base_geometry()
  local opts = config.get().ui
  local width = math.min(math.max(48, math.floor(vim.o.columns * opts.width)), math.max(20, vim.o.columns - 4))
  local available_height = math.max(8, vim.o.lines - vim.o.cmdheight - 2)
  local total_height = math.min(math.max(10, math.floor(available_height * opts.height)), available_height)
  local row = math.max(0, math.floor((available_height - total_height) / 2))
  local col = math.floor((vim.o.columns - width) / 2)
  return {
    width = width,
    height = total_height,
    available_height = available_height,
    row = row,
    col = col,
  }
end

local function float_geometry(prompt_height)
  local base = base_geometry()
  local total_height = base.height
  prompt_height = composer_height(prompt_height)
  prompt_height = math.min(prompt_height, math.max(1, total_height - 7))
  local history_height = math.max(3, total_height - prompt_height - 4)
  local occupied_height = history_height + prompt_height + 4
  if occupied_height > base.available_height then
    history_height = math.max(1, base.available_height - prompt_height - 4)
    occupied_height = history_height + prompt_height + 4
  end
  local row = math.max(0, math.floor((base.available_height - occupied_height) / 2))
  return {
    width = base.width,
    row = row,
    col = base.col,
    history_height = history_height,
    prompt_height = prompt_height,
    prompt_row = row + history_height + 2,
  }
end

local function status_footer(thread, role, width)
  local text = statusline.footer_text(thread, {
    role = role,
    width = math.max(20, (tonumber(width) or 80) - 4),
  })
  if text == "" then
    return ""
  end
  return " " .. text .. " "
end

local function add_status_footer(win_config, thread, role)
  win_config.footer = status_footer(thread, role, win_config.width)
  win_config.footer_pos = "center"
  return win_config
end

local function set_float_config(winid, win_config)
  local ok, err = pcall(vim.api.nvim_win_set_config, winid, win_config)
  if ok then
    return
  end
  win_config = vim.deepcopy(win_config)
  win_config.footer = nil
  win_config.footer_pos = nil
  local fallback_ok, fallback_err = pcall(vim.api.nvim_win_set_config, winid, win_config)
  if not fallback_ok then
    error(fallback_err or err)
  end
end

local function open_float(bufnr, enter, win_config)
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, win_config)
  if ok then
    return winid
  end
  win_config = vim.deepcopy(win_config)
  win_config.footer = nil
  win_config.footer_pos = nil
  return vim.api.nvim_open_win(bufnr, enter, win_config)
end

function M.apply_history_layout(history_winid, thread)
  if side.is(thread) then
    return side.layout(thread, nil)
  end
  if not history_winid or not vim.api.nvim_win_is_valid(history_winid) then
    return
  end
  local opts = config.get().ui
  if opts.layout == "sidebar" then
    vim.api.nvim_win_set_width(history_winid, math.max(32, math.floor(vim.o.columns * opts.sidebar_width)))
    return
  end

  local geometry = base_geometry()
  set_float_config(
    history_winid,
    add_status_footer({
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = geometry.width,
      height = geometry.height,
      row = geometry.row,
      col = geometry.col,
      title = " Coact ",
      title_pos = "center",
    }, thread, "history")
  )
end

function M.apply_thread_layout(history_winid, prompt_winid, prompt_height, thread)
  if side.is(thread) then
    return side.layout(thread, prompt_height)
  end
  if not prompt_winid or not vim.api.nvim_win_is_valid(prompt_winid) then
    return
  end
  prompt_height = composer_height(prompt_height)
  local opts = config.get().ui
  if opts.layout == "sidebar" then
    pcall(vim.api.nvim_win_set_height, prompt_winid, prompt_height)
    return
  end

  if not history_winid or not vim.api.nvim_win_is_valid(history_winid) then
    return
  end
  local geometry = float_geometry(prompt_height)
  set_float_config(
    history_winid,
    add_status_footer({
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = geometry.width,
      height = geometry.history_height,
      row = geometry.row,
      col = geometry.col,
      title = " Coact ",
      title_pos = "center",
    }, thread, "history")
  )
  set_float_config(
    prompt_winid,
    add_status_footer({
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = geometry.width,
      height = geometry.prompt_height,
      row = geometry.prompt_row,
      col = geometry.col,
      title = " Input ",
      title_pos = "center",
    }, thread, "composer")
  )
end

function M.open_history(history_bufnr, thread)
  if side.is(thread) then
    return side.open_history(history_bufnr, thread)
  end
  local opts = config.get().ui
  if opts.layout == "sidebar" then
    vim.cmd("botright vertical new")
    local history_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(history_winid, math.max(32, math.floor(vim.o.columns * opts.sidebar_width)))
    vim.api.nvim_win_set_buf(history_winid, history_bufnr)
    vim.wo[history_winid].winfixwidth = true
    return history_winid
  end

  local geometry = base_geometry()
  return open_float(
    history_bufnr,
    true,
    add_status_footer({
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = geometry.width,
      height = geometry.height,
      row = geometry.row,
      col = geometry.col,
      title = " Coact ",
      title_pos = "center",
    }, thread, "history")
  )
end

function M.open_composer(history_winid, prompt_bufnr, prompt_height, thread)
  if side.is(thread) then
    return side.open_composer(history_winid, prompt_bufnr, composer_height(prompt_height), thread)
  end
  prompt_height = composer_height(prompt_height)
  local opts = config.get().ui
  if opts.layout == "sidebar" then
    local prompt_winid
    vim.api.nvim_win_call(history_winid, function()
      vim.cmd(("belowright %dsplit"):format(prompt_height))
      prompt_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(prompt_winid, prompt_bufnr)
      vim.api.nvim_win_set_height(prompt_winid, prompt_height)
    end)
    if prompt_winid and vim.api.nvim_win_is_valid(prompt_winid) then
      vim.api.nvim_set_current_win(prompt_winid)
    end
    return prompt_winid
  end

  local geometry = float_geometry(prompt_height)
  if history_winid and vim.api.nvim_win_is_valid(history_winid) then
    set_float_config(
      history_winid,
      add_status_footer({
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = geometry.width,
        height = geometry.history_height,
        row = geometry.row,
        col = geometry.col,
        title = " Coact ",
        title_pos = "center",
      }, thread, "history")
    )
  end
  local prompt_winid = open_float(
    prompt_bufnr,
    true,
    add_status_footer({
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = geometry.width,
      height = geometry.prompt_height,
      row = geometry.prompt_row,
      col = geometry.col,
      title = " Input ",
      title_pos = "center",
    }, thread, "composer")
  )
  return prompt_winid
end

function M.apply_status_chrome(history_winid, prompt_winid, thread)
  if side.is(thread) then
    return side.refresh(thread)
  end
  if config.get().ui.layout == "sidebar" then
    return
  end
  if history_winid and vim.api.nvim_win_is_valid(history_winid) then
    local history_config = vim.api.nvim_win_get_config(history_winid)
    if history_config.relative and history_config.relative ~= "" then
      set_float_config(history_winid, add_status_footer(history_config, thread, "history"))
    end
  end
  if prompt_winid and vim.api.nvim_win_is_valid(prompt_winid) then
    local prompt_config = vim.api.nvim_win_get_config(prompt_winid)
    if prompt_config.relative and prompt_config.relative ~= "" then
      set_float_config(prompt_winid, add_status_footer(prompt_config, thread, "composer"))
    end
  end
end

return M
