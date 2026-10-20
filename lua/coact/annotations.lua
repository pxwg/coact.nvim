-- Side-discussion annotations live in the main branch as Pi branch summaries
-- whose Markdown starts with a coact-anchor comment.
local source_map = require("coact.source_map")
local util = require("coact.util")

local M = {}

local ns = vim.api.nvim_create_namespace("coact.nvim.annotations")

function M.parse(text)
  local json, body = tostring(text or ""):match("^<!%-%- coact%-anchor (.-) %-%->\n?(.*)$")
  if not json then
    return nil
  end
  local ok, data = pcall(vim.json.decode, json)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return { index = tonumber(data.index), anchor = data, body = body }
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "CoactSideNoteMarker", { link = "Special", default = true })
end

-- Footnote markers after anchored text in the assistant replies of a thread.
function M.apply(thread, bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local notes = {}
  for _, id in ipairs(thread.item_order or {}) do
    local item = thread.items[id]
    if item and item.type == "branchSummary" then
      local note = M.parse(item.text or item.summary)
      local anchor = note and note.anchor
      if anchor and anchor.entryId and tonumber(anchor["end"]) then
        notes[tostring(anchor.entryId) .. ":" .. tostring(anchor.block)] = notes[tostring(anchor.entryId) .. ":" .. tostring(
          anchor.block
        )] or {}
        table.insert(notes[tostring(anchor.entryId) .. ":" .. tostring(anchor.block)], note)
      end
    end
  end
  if vim.tbl_isempty(notes) then
    return
  end
  setup_highlights()
  local inline = vim.fn.has("nvim-0.10") == 1
  for _, atom in ipairs(thread.render_atoms or {}) do
    local block = atom.block
    local raw = block and block.raw or {}
    if block and block.type == "AssistantBlock" and atom.text_start then
      local key = tostring(util.value(raw.treeEntryId)) .. ":" .. tostring(util.value(raw.piContentIndex))
      for _, note in ipairs(notes[key] or {}) do
        local text = block.text or ""
        local offset = source_map.bytes(text, tonumber(note.anchor["end"]))
        if offset then
          local row, col = source_map.position(text, atom.text_start - 1, offset)
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
            virt_text = { { "[" .. tostring(note.index or "?") .. "]", "CoactSideNoteMarker" } },
            virt_text_pos = inline and "inline" or "eol",
            strict = false,
          })
        end
      end
    end
  end
end

M._namespace = ns

return M
