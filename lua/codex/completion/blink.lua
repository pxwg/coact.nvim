local catalog = require("codex.catalog")

local M = {}
local Source = {}
Source.__index = Source

function Source.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.bo[bufnr].filetype == "codex" or vim.b[bufnr].codex_thread_id ~= nil
end

function Source:get_trigger_characters()
  return { "/", "@", "$", ">", ":" }
end

local function prefix_at_cursor(ctx)
  local line = ctx.line or ""
  local cursor_col = ctx.cursor and ctx.cursor[2] or vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, cursor_col)
  return before:match("([/@$>][%w%-%._:%/%~]*)$")
end

local function completion_kind()
  local ok, types = pcall(require, "blink.cmp.types")
  if not ok then
    return {}
  end
  return types.CompletionItemKind
end

local function to_item(item)
  local kinds = completion_kind()
  return {
    label = item.label,
    insertText = item.label,
    kind = item.kind or kinds.Keyword or 14,
    detail = item.detail,
    documentation = item.documentation,
    data = item.data,
  }
end

function Source:get_completions(ctx, callback)
  local prefix = prefix_at_cursor(ctx)
  if not prefix or prefix == "" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local trigger = prefix:sub(1, 1)
  local kind = catalog.kind_for_trigger(trigger, prefix)
  catalog.ensure_refresh(kind)

  local candidates = catalog.static_for_trigger(trigger)
  vim.list_extend(candidates, catalog.dynamic(kind))

  local out = {}
  local lower = prefix:lower()
  for _, item in ipairs(candidates) do
    if item.label and vim.startswith(item.label:lower(), lower) then
      table.insert(out, to_item(item))
    end
  end

  callback({
    items = out,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

function M.new(opts)
  return Source.new(opts)
end

return M
