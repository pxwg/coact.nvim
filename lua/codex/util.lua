local M = {}

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "codex.nvim" })
  end)
end

function M.now_ms()
  return math.floor(vim.uv.hrtime() / 1000000)
end

function M.present(value)
  return value ~= nil and value ~= vim.NIL
end

function M.value(value)
  if M.present(value) then
    return value
  end
  return nil
end

function M.trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.is_blank(value)
  return M.trim(value) == ""
end

function M.list_extend(dst, src)
  if type(src) ~= "table" then
    return dst
  end
  for _, value in ipairs(src) do
    table.insert(dst, value)
  end
  return dst
end

function M.short_id(value)
  value = tostring(value or "")
  if #value <= 10 then
    return value
  end
  return value:sub(1, 6)
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
