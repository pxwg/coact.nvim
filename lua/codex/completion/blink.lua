local catalog = require("codex.catalog")
local context = require("codex.context")
local state = require("codex.state")

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
  return before:match("(@[%w%-%._/]+:`[^`]*$)") or before:match("([/@$][%w%-%._:%/%~`]*)$")
end

local function completion_kind()
  local ok, types = pcall(require, "blink.cmp.types")
  if not ok then
    return {}
  end
  return types.CompletionItemKind
end

local function selection_documentation(ctx)
  local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
  local thread = bufnr and state.thread_for_buf(bufnr) or nil
  local target = context.target_buffer(thread)
  local selected = context.selection_for_buffer(target)
  if not selected then
    return "No visual selection found in the source buffer."
  end
  return table.concat({
    ("Current visual selection from %s, L%d-L%d:"):format(selected.filename, selected.start_line, selected.end_line),
    "",
    "```" .. (selected.filetype or ""),
    selected.content,
    "```",
  }, "\n")
end

local function item_documentation(item, ctx)
  if item.label == "@selection" then
    return selection_documentation(ctx)
  end
  return item.documentation
end

local function to_item(item, ctx)
  local kinds = completion_kind()
  return {
    label = item.label,
    insertText = item.insertText or item.label,
    kind = item.kind or kinds.Keyword or 14,
    detail = item.detail,
    documentation = item_documentation(item, ctx),
    filterText = item.filterText,
    data = item.data,
  }
end

local function slash_command(item)
  if not (item.data and item.data.source == "codex.nvim.slash") then
    return nil
  end
  return item.data.command or tostring(item.label or ""):gsub("^/", "")
end

local function empty_insert_item(item)
  local out = vim.deepcopy(item)
  if out.textEdit then
    out.textEdit.newText = ""
  end
  out.insertText = ""
  return out
end

local function item_matches(item, prefix)
  if item.data and item.data.source == "codex.nvim.context_path" then
    return true
  end
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

function Source:execute(ctx, item, callback, default_implementation)
  local command = slash_command(item)
  if not command or command == "" then
    default_implementation()
    callback()
    return
  end

  default_implementation(ctx, empty_insert_item(item))
  vim.schedule(function()
    local bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf()
    local thread_id = bufnr and vim.b[bufnr].codex_thread_id or nil
    local ok, codex = pcall(require, "codex")
    if ok and codex.submit_text then
      codex.submit_text("/" .. command, thread_id)
    else
      require("codex.slash").dispatch("/" .. command, thread_id)
    end
    callback()
  end)
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
        table.insert(out, to_item(item, ctx))
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
