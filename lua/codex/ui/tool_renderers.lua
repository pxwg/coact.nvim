local config = require("codex.config")
local util = require("codex.util")

local M = {}

local function stringify(value)
  if value == nil or value == vim.NIL then
    return ""
  end
  if type(value) == "string" then
    return util.clean_tool_output(value)
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or vim.inspect(value)
end

local function split_lines(value)
  local lines = util.split_lines(value)
  return #lines > 0 and lines or { "" }
end

local function first_line(value)
  return util.trim((util.clean_tool_output(value):gsub("\r\n", "\n"):gsub("\r", "\n"):match("^[^\n]+") or ""))
end

local function truncate(value, limit)
  value = util.clean_tool_output(value)
  limit = limit or 96
  if #value <= limit then
    return value
  end
  return value:sub(1, limit - 1) .. "..."
end

local function code_block(lines, lang, value)
  table.insert(lines, "```" .. (lang or ""))
  vim.list_extend(lines, split_lines(value))
  table.insert(lines, "```")
end

local function add_value(lines, label, value, lang)
  if value == nil or value == vim.NIL then
    return false
  end
  table.insert(lines, label .. ":")
  code_block(lines, lang or "json", stringify(value))
  return true
end

local function render_bash(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local lines = {}
  if input.cwd then
    table.insert(lines, "cwd: " .. tostring(input.cwd))
  end
  if input.command then
    table.insert(lines, "command:")
    code_block(lines, "bash", input.command)
  end
  if output.stdout and output.stdout ~= "" then
    table.insert(lines, "output:")
    code_block(lines, "text", output.stdout)
  end
  if output.exitCode ~= nil then
    table.insert(lines, "exit: " .. tostring(output.exitCode))
  end
  return #lines > 0 and lines or { "(no command details)" }
end

local function render_patch(block)
  local output = type(block.output) == "table" and block.output or {}
  local changes = output.changes or block.input and block.input.changes or {}
  local lines = {}
  for _, change in ipairs(changes) do
    table.insert(lines, ("%s %s"):format(change.kind or "update", change.path or ""))
    if change.diff and change.diff ~= "" then
      code_block(lines, "diff", change.diff)
    end
  end
  if output.output and output.output ~= "" then
    add_value(lines, "output", output.output, "text")
  end
  return #lines > 0 and lines or { "(patch details pending)" }
end

local function render_raw(block)
  local lines = {}
  add_value(lines, "input", block.input)
  add_value(lines, "output", block.output)
  if #lines == 0 and block.text and block.text ~= "" then
    add_value(lines, "text", block.text, "text")
  end
  return #lines > 0 and lines or { "(no details)" }
end

local function renderer_for(block)
  local opts = config.get().render and config.get().render.tool_outputs or {}
  if opts.renderers and type(opts.renderers[block.tool]) == "function" then
    return opts.renderers[block.tool]
  end
  if block.type == "PatchBlock" or block.tool == "apply_patch" then
    return render_patch
  end
  if block.tool == "Bash" then
    return render_bash
  end
  return render_raw
end

function M.summary(block)
  if not block then
    return ""
  end
  if block.type == "PatchBlock" then
    local changes = block.output and block.output.changes or block.input and block.input.changes or {}
    return truncate(tostring(#changes) .. " file change" .. (#changes == 1 and "" or "s"), 110)
  end
  if block.tool == "Bash" and block.input and block.input.command then
    return truncate(first_line(block.input.command), 110)
  end
  if block.tool then
    return truncate(first_line(block.text ~= "" and block.text or stringify(block.input)), 110)
  end
  return ""
end

function M.status(block)
  if not block then
    return nil
  end
  local out = block.output
  local parts = {}
  if type(out) == "table" then
    if out.exitCode ~= nil then
      table.insert(parts, "exit " .. tostring(out.exitCode))
    end
    if out.durationMs ~= nil then
      table.insert(parts, tostring(out.durationMs) .. "ms")
    end
  end
  if block.state and block.state ~= "" then
    table.insert(parts, tostring(block.state))
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

function M.render(block)
  local renderer = renderer_for(block or {})
  local ok, rendered = pcall(renderer, block or {})
  if ok and type(rendered) == "table" then
    return rendered
  end
  if config.get().render.tool_outputs.fallback == "none" then
    return { "Tool renderer failed: " .. tostring(rendered) }
  end
  return render_raw(block or {})
end

return M
