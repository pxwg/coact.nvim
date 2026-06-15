local events = require("codex.events")
local activity_summary = require("codex.ui.activity_summary")
local state = require("codex.state")
local tool_renderers = require("codex.ui.tool_renderers")
local util = require("codex.util")

local M = {}

local function add(lines, value)
  local parts = util.split_lines(value)
  if #parts == 0 then
    table.insert(lines, "")
    return
  end
  for _, line in ipairs(parts) do
    table.insert(lines, line)
  end
end

local function code_block(lines, lang, value)
  table.insert(lines, "```" .. (lang or ""))
  add(lines, value)
  table.insert(lines, "```")
end

local function encode(value)
  if value == nil or value == vim.NIL then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or vim.inspect(value)
end

local function block_title(block)
  if not block then
    return "Codex Detail"
  end
  if block.type == "ToolCallBlock" or block.type == "PatchBlock" then
    return tostring(block.tool or "tool")
  end
  if block.type == "ActivitySummaryBlock" then
    return "Thinking finished"
  end
  if block.type == "AgentTimelineBlock" then
    return "Agent: " .. tostring(block.title or "event")
  end
  if block.type == "ReasoningBlock" then
    return "Reasoning"
  end
  if block.type == "PlanBlock" then
    return "Plan"
  end
  return tostring(block.type or "Block")
end

function M.lines_for(block)
  local lines = {
    "# " .. block_title(block),
    "",
    "type: " .. tostring(block and block.type or "unknown"),
  }
  if block and block.item_id then
    table.insert(lines, "item: " .. tostring(block.item_id))
  end
  if block and block.message_id then
    table.insert(lines, "turn: " .. tostring(block.message_id))
  end
  if block and block.state then
    table.insert(lines, "state: " .. tostring(block.state))
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  if block and block.type == "ActivitySummaryBlock" then
    vim.list_extend(lines, activity_summary.lines(block.children))
  elseif block and (block.type == "ToolCallBlock" or block.type == "PatchBlock") then
    for _, line in ipairs(tool_renderers.render(block)) do
      table.insert(lines, line)
    end
  elseif block and events.block_text(block) ~= "" then
    add(lines, events.block_text(block))
  else
    table.insert(lines, "(no rendered content)")
  end

  if block and block.raw then
    table.insert(lines, "")
    table.insert(lines, "## Raw")
    table.insert(lines, "")
    code_block(lines, "json", encode(block.raw))
  end

  return lines
end

function M.block_under_cursor()
  local thread = state.thread_for_buf(0)
  if not thread then
    return nil, "Current buffer is not a Codex thread buffer"
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local placeholder = thread.placeholder_index and thread.placeholder_index[lnum]
  if placeholder and placeholder.block then
    return placeholder.block, nil
  end
  local block = thread.render_index and thread.render_index[lnum]
  if block then
    return block, nil
  end
  return nil, "No Codex block under cursor"
end

function M.open(block)
  block = block or M.block_under_cursor()
  if not block then
    local _, err = M.block_under_cursor()
    util.notify(err or "No Codex block under cursor", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "codex://detail/" .. block_title(block))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.lines_for(block))
  vim.bo[bufnr].modifiable = false
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(0, true)
  end, { buffer = bufnr, silent = true, desc = "Close Codex detail" })
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_height(0, math.max(12, math.floor(vim.o.lines * 0.35)))
  return bufnr
end

return M
