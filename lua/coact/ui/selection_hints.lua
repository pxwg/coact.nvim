-- avante.nvim-style shortcut hints beside a Visual selection. The plugin
-- defines <Plug> targets only; hints list whatever keys the user maps to them.
local config = require("coact.config")

local M = {}

local ns = vim.api.nvim_create_namespace("coact.nvim.selection_hints")
local group = nil
local shown = nil -- { bufnr, id, row }

M.plugs = {
  { plug = "<Plug>(CoactSideAsk)", label = "side ask", action = "side_ask" },
  { plug = "<Plug>(CoactAddSelection)", label = "add @selection", action = "add_selection" },
}

local function opts()
  return config.get().selection or {}
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CoactSelectionHint", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CoactSelectionHintKey", { link = "Special", default = true })
end

local function display_key(lhs)
  local leader = vim.g.mapleader
  if leader == nil then
    leader = "\\"
  end
  lhs = tostring(lhs)
  if leader ~= "" and lhs:sub(1, #leader) == leader then
    lhs = "<leader>" .. lhs:sub(#leader + 1)
  end
  return lhs
end

-- Visual-mode lhs mapped to each <Plug> target (buffer-local first).
function M.keys(bufnr)
  local found = {}
  local function scan(maps)
    for _, map in ipairs(maps) do
      local rhs = map.rhs
      if rhs and not found[rhs] then
        found[rhs] = map.lhs
      end
    end
  end
  scan(vim.api.nvim_buf_get_keymap(bufnr, "x"))
  scan(vim.api.nvim_get_keymap("x"))
  return found
end

local function is_pi()
  local ok, providers = pcall(require, "coact.providers")
  return ok and providers.is("pi")
end

-- Hints that apply to the buffer: side ask for main chat history and source
-- buffers, @selection only for source buffers.
function M.items(bufnr)
  local items = {}
  local role = vim.b[bufnr].coact_role
  local side_thread = false
  if role == "history" then
    local thread = require("coact.state").thread_for_buf(bufnr)
    side_thread = thread ~= nil and type(thread.side) == "table"
  elseif require("coact.context").is_coact_buffer(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return items
  end
  local keys = M.keys(bufnr)
  for _, target in ipairs(M.plugs) do
    local key = keys[target.plug]
    local applies = target.action == "side_ask" and is_pi() and not side_thread
      or target.action == "add_selection" and role ~= "history"
    if key and applies then
      table.insert(items, { key = key, label = target.label })
    end
  end
  return items
end

local function chunks(items)
  local out = { { "  ", "CoactSelectionHint" } }
  for index, item in ipairs(items) do
    if index > 1 then
      table.insert(out, { "  ·  ", "CoactSelectionHint" })
    end
    table.insert(out, { display_key(item.key), "CoactSelectionHintKey" })
    table.insert(out, { " " .. item.label, "CoactSelectionHint" })
  end
  return out
end

function M.clear()
  if shown and vim.api.nvim_buf_is_valid(shown.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, shown.bufnr, ns, shown.id)
  end
  shown = nil
end

function M.show()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.fn.line(".") - 1
  if shown and shown.bufnr == bufnr and shown.row == row then
    return
  end
  M.clear()
  local items = M.items(bufnr)
  if #items == 0 then
    return
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    virt_text = chunks(items),
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = 200,
  })
  if ok then
    shown = { bufnr = bufnr, id = id, row = row }
  end
end

local function visual(mode)
  return tostring(mode or ""):match("^[vV\22]") ~= nil
end

function M.setup()
  setup_highlights()
  group = vim.api.nvim_create_augroup("coact.nvim.selection_hints", { clear = true })
  M.clear()
  if opts().hints == false then
    return
  end
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      local event = vim.v.event or {}
      if visual(event.new_mode) then
        M.show()
      elseif visual(event.old_mode) then
        M.clear()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      if visual(vim.fn.mode()) then
        M.show()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = setup_highlights })
end

M._namespace = ns

return M
