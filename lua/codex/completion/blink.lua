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
  return { "/", "@", "$", ":" }
end

local function prefix_at_cursor(ctx)
  local line = ctx.line or ""
  local cursor_col = ctx.cursor and ctx.cursor[2] or vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, cursor_col)
  return before:match("([/@$][%w%-%._:%/%~]*)$")
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
    filterText = item.filterText,
    data = item.data,
  }
end

local function item_matches(item, prefix)
  local label = tostring(item.label or "")
  local lower = prefix:lower()
  if vim.startswith(label:lower(), lower) then
    return true
  end
  local query = lower:sub(2)
  if query == "" then
    return true
  end
  local haystack = table
    .concat({
      label,
      item.filterText or "",
      item.detail or "",
      item.documentation or "",
    }, " ")
    :lower()
  return haystack:find(vim.pesc(query)) ~= nil
end

function Source:get_completions(ctx, callback)
  local prefix = prefix_at_cursor(ctx)
  if not prefix or prefix == "" then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local trigger = prefix:sub(1, 1)
  catalog.items_for_trigger(trigger, prefix, function(candidates)
    local out = {}
    for _, item in ipairs(candidates or {}) do
      if item.label and item_matches(item, prefix) then
        table.insert(out, to_item(item))
      end
    end

    callback({
      items = out,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
    })
  end)
end

function M.new(opts)
  return Source.new(opts)
end

return M
