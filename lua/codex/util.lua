local M = {}

local function strip_ansi_text(text)
  text = tostring(text or "")
  text = text:gsub("\226\144\155", "\27")
  text = text:gsub("%^%[([0-9;:]*)m", "\27[%1m")
  text = text:gsub("\27%][^\7]*\7", "")
  text = text:gsub("\27%][^\27]*\27\\", "")
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%[[0-?]*[ -/]*$", "")
  text = text:gsub("\27%][^\7\27]*$", "")
  text = text:gsub("\27[@-_]", "")
  text = text:gsub("\27\n", "\n")
  text = text:gsub("\27$", "")
  text = text:gsub("^%[[0-9;:]*m", "")
  text = text:gsub("\n%[[0-9;:]*m", "\n")
  return text
end

function M.strip_ansi(text)
  return strip_ansi_text(text)
end

function M.clean_tool_output(text)
  text = strip_ansi_text(text)
  local reason = text:match("Command blocked by PreToolUse hook:%s*(.-)%s*Command:%s*%*%*%* Begin Patch")
  if reason and reason ~= "" then
    reason = reason:match("^(.-)\n\n# NVIM APPLY PATCH REVIEW") or reason
    return "Command blocked by PreToolUse hook: " .. M.trim(reason)
  end
  return text
end

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(strip_ansi_text(message), level or vim.log.levels.INFO, { title = "codex.nvim" })
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

function M.label(value)
  if not M.present(value) or value == "" then
    return nil
  end
  if type(value) == "table" then
    return M.label(
      value.text or value.label or value.name or value.title or value.status or value.state or value.phase or value.type
    )
  end
  return tostring(value)
end

function M.status_label(value)
  local label = M.label(value)
  if not label then
    return nil
  end
  if type(value) ~= "table" then
    return label
  end
  local flags = value.activeFlags or value.active_flags
  if type(flags) ~= "table" then
    return label
  end
  local flag_labels = {}
  for key, flag in pairs(flags) do
    if type(key) == "number" then
      local flag_label = M.label(flag)
      if flag_label then
        table.insert(flag_labels, flag_label)
      end
    elseif flag == true then
      table.insert(flag_labels, tostring(key))
    end
  end
  table.sort(flag_labels)
  if #flag_labels == 0 then
    return label
  end
  return label .. " (" .. table.concat(flag_labels, ", ") .. ")"
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
