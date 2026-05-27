local config = require("codex.config")
local context = require("codex.context")
local catalog = require("codex.catalog")

local M = {}

local context_handlers = {}

local function project_root()
  local cwd = vim.fn.getcwd()
  local ok, root = pcall(vim.fs.root, cwd, { ".git" })
  return ok and root or nil
end

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
  local thread = require("codex.state").thread_for_buf(0)
  local bufnr = context.target_buffer(thread)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor = context.cursor_for_buffer(bufnr, thread)
  return table.concat({
    "Neovim context: target buffer",
    ("- bufnr: %d"):format(bufnr),
    ("- name: %s"):format(context.buffer_label(bufnr)),
    ("- filetype: %s"):format(vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "none"),
    ("- line_count: %d"):format(vim.api.nvim_buf_line_count(bufnr)),
    ("- cursor: L%d:C%d"):format(cursor[1], cursor[2] + 1),
    ("- modified: %s"):format(vim.bo[bufnr].modified and "true" or "false"),
    "",
    "```" .. vim.bo[bufnr].filetype,
    table.concat(lines, "\n"),
    "```",
  }, "\n")
end

context_handlers.selection = function()
  local selected = current_selection()
  if not selected or selected == "" then
    return nil
  end
  return "Current selection:\n\n```\n" .. selected .. "\n```"
end

context_handlers.cursor = function()
  local thread = require("codex.state").thread_for_buf(0)
  local bufnr = context.target_buffer(thread)
  local cursor = context.cursor_for_buffer(bufnr, thread)
  local start_line = math.max(1, cursor[1] - 20)
  local end_line = math.min(vim.api.nvim_buf_line_count(bufnr), cursor[1] + 20)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local out = {
    "Neovim context: cursor",
    ("- buffer: %s"):format(context.buffer_label(bufnr)),
    ("- cursor: L%d:C%d"):format(cursor[1], cursor[2] + 1),
    ("- range: L%d-L%d"):format(start_line, end_line),
    "",
    "```" .. vim.bo[bufnr].filetype,
  }
  for offset, line in ipairs(lines) do
    local lnum = start_line + offset - 1
    table.insert(out, ("%s%5d  %s"):format(lnum == cursor[1] and ">" or " ", lnum, line))
  end
  table.insert(out, "```")
  return table.concat(out, "\n")
end

context_handlers.diagnostics = function()
  local bufnr = context.target_buffer(require("codex.state").thread_for_buf(0))
  local diagnostics = vim.diagnostic.get(bufnr)
  if vim.tbl_isempty(diagnostics) then
    return "Target buffer diagnostics: none"
  end
  local lines = { "Target buffer diagnostics:" }
  for _, diagnostic in ipairs(diagnostics) do
    local severity = vim.diagnostic.severity[diagnostic.severity] or "UNKNOWN"
    table.insert(
      lines,
      ("- %s L%d:C%d %s"):format(severity, diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message)
    )
  end
  return table.concat(lines, "\n")
end

context_handlers.quickfix = function()
  local items = vim.fn.getqflist()
  if #items == 0 then
    return "Quickfix list: empty"
  end
  local lines = { "Quickfix list:" }
  for _, item in ipairs(items) do
    local name = item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) and vim.api.nvim_buf_get_name(item.bufnr) or ""
    table.insert(lines, ("- %s:%d:%d %s"):format(name, item.lnum or 0, item.col or 0, item.text or ""))
  end
  return table.concat(lines, "\n")
end

context_handlers.buffers = function()
  local lines = { "Neovim context: listed buffers:" }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      table.insert(
        lines,
        ("- #%d %s ft=%s modified=%s"):format(
          bufnr,
          context.buffer_label(bufnr),
          vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "none",
          vim.bo[bufnr].modified and "true" or "false"
        )
      )
    end
  end
  return table.concat(lines, "\n")
end

context_handlers.cwd = function()
  return table.concat({
    "Neovim context: workspace",
    "- cwd: " .. vim.fn.getcwd(),
    "- root: " .. (project_root() or "none"),
  }, "\n")
end

local function file_context(path)
  path = vim.fn.expand(path or "")
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  return table.concat({
    "Neovim context: file",
    "- path: " .. path,
    ("- line_count: %d"):format(#lines),
    "",
    "```",
    table.concat(lines, "\n"),
    "```",
  }, "\n")
end

local function expand_context_token(token)
  if vim.startswith(token, "@file:") then
    return file_context(token:sub(7))
  end
  local name = token:sub(2)
  local handler = context_handlers[name]
  if not handler then
    return nil
  end
  local ok, value = pcall(handler)
  if ok and value and value ~= "" then
    return value
  end
  return nil
end

function M.parse(text)
  local inputs = {}
  local body = {}
  local opts = config.get()

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local token = line:match("^%s*(@file:.+)%s*$") or line:match("^%s*([%$>@][%w_./:~%-]+)%s*$")
    if token and (token:sub(1, 1) == "@" or token:sub(1, 1) == ">") then
      local context_token = token:sub(1, 1) == ">" and ("@" .. token:sub(2)) or token
      local value = expand_context_token(context_token)
      if value and value ~= "" then
        table.insert(inputs, { type = "text", text = value, text_elements = {} })
      else
        table.insert(body, line)
      end
    elseif token and vim.startswith(token, "$skill:") and opts.completion.enabled then
      local name = token:sub(8)
      local skill = catalog.find_skill(name)
      if skill and skill.path then
        table.insert(inputs, { type = "skill", name = skill.name, path = skill.path })
      else
        table.insert(body, line)
      end
    elseif token and token:sub(1, 1) == "$" and opts.completion.enabled then
      local skill = catalog.find_skill(token:sub(2))
      if skill and skill.path then
        table.insert(inputs, { type = "skill", name = skill.name, path = skill.path })
      else
        table.insert(body, line)
      end
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
