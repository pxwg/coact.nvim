local M = {}

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "codex.nvim" })
  end)
end

function M.tbl_get(tbl, ...)
  local value = tbl
  for _, key in ipairs({ ... }) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

function M.truncate(text, max)
  text = tostring(text or "")
  max = max or 80
  if #text <= max then
    return text
  end
  return text:sub(1, max - 1) .. "..."
end

function M.split_lines(text)
  text = tostring(text or "")
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.path_label(path)
  if not path or path == "" then
    return ""
  end
  local cwd = vim.fn.getcwd()
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel ~= path then
    return rel
  end
  return path:gsub("^" .. vim.pesc(cwd) .. "/", "")
end

return M
