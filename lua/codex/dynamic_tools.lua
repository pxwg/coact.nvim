local config = require("codex.config")

local M = {}

local function text_response(text, success)
  return {
    success = success ~= false,
    contentItems = {
      { type = "inputText", text = text or "" },
    },
  }
end

local specs = {
  {
    namespace = "nvim",
    name = "current_buffer",
    description = "Return the current Neovim buffer path, filetype, and text.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = {},
      additionalProperties = false,
    },
  },
  {
    namespace = "nvim",
    name = "diagnostics",
    description = "Return diagnostics for the current Neovim buffer.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = {},
      additionalProperties = false,
    },
  },
  {
    namespace = "nvim",
    name = "quickfix",
    description = "Return the current Neovim quickfix list.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = {},
      additionalProperties = false,
    },
  },
}

function M.specs()
  if not config.get().dynamic_tools.enabled then
    return nil
  end
  return specs
end

local handlers = {}

handlers.current_buffer = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  return text_response(("path: %s\nfiletype: %s\n\n%s"):format(name, vim.bo[bufnr].filetype, text))
end

handlers.diagnostics = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return text_response("No diagnostics in the current buffer.")
  end
  local lines = {}
  for _, diagnostic in ipairs(diagnostics) do
    table.insert(lines, ("L%d:C%d %s"):format(diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message))
  end
  return text_response(table.concat(lines, "\n"))
end

handlers.quickfix = function()
  local items = vim.fn.getqflist()
  if #items == 0 then
    return text_response("Quickfix list is empty.")
  end
  local lines = {}
  for _, item in ipairs(items) do
    local name = item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) and vim.api.nvim_buf_get_name(item.bufnr) or ""
    table.insert(lines, ("%s:%d:%d: %s"):format(name, item.lnum or 0, item.col or 0, item.text or ""))
  end
  return text_response(table.concat(lines, "\n"))
end

function M.handle_call(message)
  local params = message.params or {}
  local rpc = require("codex.rpc")
  if params.namespace ~= "nvim" then
    rpc.respond(message.id, text_response("Unsupported dynamic tool namespace: " .. tostring(params.namespace), false))
    return
  end
  local handler = handlers[params.tool]
  if not handler then
    rpc.respond(message.id, text_response("Unsupported Neovim tool: " .. tostring(params.tool), false))
    return
  end
  local ok, result = pcall(handler, params.arguments or {})
  if ok then
    rpc.respond(message.id, result)
  else
    rpc.respond(message.id, text_response(tostring(result), false))
  end
end

return M
