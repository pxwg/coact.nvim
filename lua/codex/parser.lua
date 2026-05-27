local config = require("codex.config")

local M = {}

local context_handlers = {}

local function current_selection()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    return nil
  end
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_line = math.min(start_pos[2], end_pos[2])
  local end_line = math.max(start_pos[2], end_pos[2])
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

context_handlers.buffer = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return ("Current buffer: %s\n\n```%s\n%s\n```"):format(
    name ~= "" and name or "[No Name]",
    vim.bo[bufnr].filetype,
    table.concat(lines, "\n")
  )
end

context_handlers.selection = function()
  local selected = current_selection()
  if not selected or selected == "" then
    return nil
  end
  return "Current selection:\n\n```\n" .. selected .. "\n```"
end

context_handlers.diagnostics = function()
  local diagnostics = vim.diagnostic.get(0)
  if vim.tbl_isempty(diagnostics) then
    return "Current buffer diagnostics: none"
  end
  local lines = { "Current buffer diagnostics:" }
  for _, diagnostic in ipairs(diagnostics) do
    table.insert(
      lines,
      ("- L%d:C%d %s"):format(diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message)
    )
  end
  return table.concat(lines, "\n")
end

function M.parse(text)
  local inputs = {}
  local body = {}
  local opts = config.get()

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local token = line:match("^%s*([%$>][%w_./:-]+)%s*$")
    if token and token:sub(1, 1) == ">" then
      local name = token:sub(2)
      local handler = context_handlers[name]
      if handler then
        local ok, value = pcall(handler)
        if ok and value and value ~= "" then
          table.insert(inputs, { type = "text", text = value, text_elements = {} })
        end
      else
        table.insert(body, line)
      end
    elseif token and token:sub(1, 1) == "$" and opts.completion.enabled then
      table.insert(body, line)
    else
      table.insert(body, line)
    end
  end

  local text_input = table.concat(body, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if text_input ~= "" then
    table.insert(inputs, 1, { type = "text", text = text_input, text_elements = {} })
  end
  return inputs
end

return M
