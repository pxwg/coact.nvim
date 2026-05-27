local config = require("codex.config")
local context = require("codex.context")
local util = require("codex.util")

local M = {}
local async_response = {}

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
    description = "Return the target Neovim buffer path, filetype, and text.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = vim.empty_dict(),
      additionalProperties = false,
    },
  },
  {
    namespace = "nvim",
    name = "diagnostics",
    description = "Return diagnostics for the target Neovim buffer.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = vim.empty_dict(),
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
      properties = vim.empty_dict(),
      additionalProperties = false,
    },
  },
  {
    namespace = "nvim",
    name = "apply_patch",
    description = "Review a unified diff in Neovim and apply it only after user approval.",
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = {
        patch = {
          type = "string",
          description = "Unified diff to review and apply.",
        },
        cwd = {
          type = "string",
          description = "Working directory for relative patch paths.",
        },
        reason = {
          type = "string",
          description = "Short reason shown in the Neovim patch review buffer.",
        },
      },
      required = { "patch" },
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

handlers.current_buffer = function(_, thread)
  local bufnr = context.target_buffer(thread)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  return text_response(("path: %s\nfiletype: %s\n\n%s"):format(name, vim.bo[bufnr].filetype, text))
end

handlers.diagnostics = function(_, thread)
  local bufnr = context.target_buffer(thread)
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return text_response("No diagnostics in the target buffer.")
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

local function normalize_arguments(arguments)
  if type(arguments) == "string" then
    local ok, decoded = pcall(vim.json.decode, arguments)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return type(arguments) == "table" and arguments or {}
end

local function clean_patch_path(path)
  path = tostring(path or "")
  if path == "" or path == "/dev/null" then
    return nil
  end
  return (path:gsub("^[ab]/", ""))
end

local function infer_kind(old_path, new_path)
  if old_path == "/dev/null" then
    return "add"
  end
  if new_path == "/dev/null" then
    return "delete"
  end
  return "update"
end

local function changes_from_unified_patch(patch)
  local changes = {}
  local current = nil

  local function flush()
    if current and #current.lines > 0 then
      table.insert(changes, {
        kind = current.kind or "update",
        path = current.path or "",
        diff = table.concat(current.lines, "\n"),
      })
    end
    current = nil
  end

  for _, line in ipairs(util.split_lines(patch)) do
    local git_old, git_new = line:match("^diff %-%-git%s+(.+)%s+(.+)$")
    if git_old and git_new then
      flush()
      current = {
        kind = infer_kind(git_old, git_new),
        path = clean_patch_path(git_new) or clean_patch_path(git_old) or "",
        lines = { line },
      }
    else
      current = current or { kind = "update", path = "", lines = {} }
      table.insert(current.lines, line)

      local old_path = line:match("^%-%-%-%s+(.+)$")
      if old_path then
        current.old_path = old_path
        current.kind = infer_kind(old_path, current.new_path)
        current.path = current.path ~= "" and current.path or clean_patch_path(old_path) or ""
      end

      local new_path = line:match("^%+%+%+%s+(.+)$")
      if new_path then
        current.new_path = new_path
        current.kind = infer_kind(current.old_path, new_path)
        current.path = clean_patch_path(new_path) or current.path
      end
    end
  end
  flush()

  if #changes == 0 and util.trim(patch) ~= "" then
    table.insert(changes, { kind = "update", path = "", diff = patch })
  end
  return changes
end

local function absolute_change_path(cwd, path)
  path = util.value(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fn.expand(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(cwd, path))
end

local function modified_buffer_conflicts(cwd, changes)
  local paths = {}
  for _, change in ipairs(changes or {}) do
    local path = absolute_change_path(cwd, change.path)
    if path then
      paths[path] = true
    end
  end
  if vim.tbl_isempty(paths) then
    return {}
  end

  local conflicts = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and paths[vim.fs.normalize(name)] then
        table.insert(conflicts, name)
      end
    end
  end
  table.sort(conflicts)
  return conflicts
end

local function system_result(args)
  local ok, result = pcall(function()
    return vim.system(args, { text = true }):wait()
  end)
  if not ok then
    return { code = 1, stderr = tostring(result), stdout = "" }
  end
  return result
end

local function apply_unified_patch(cwd, patch, changes)
  patch = tostring(patch or "")
  if util.trim(patch) == "" then
    return false, "nvim.apply_patch requires a non-empty unified diff."
  end

  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  if vim.fn.isdirectory(cwd) ~= 1 then
    return false, "Patch cwd is not a directory: " .. cwd
  end

  local conflicts = modified_buffer_conflicts(cwd, changes)
  if #conflicts > 0 then
    return false, "Refusing to apply patch over modified loaded buffers:\n" .. table.concat(conflicts, "\n")
  end

  local patch_file = vim.fn.tempname()
  vim.fn.writefile(vim.split(patch, "\n", { plain = true }), patch_file)
  local check = system_result({ "git", "-C", cwd, "apply", "--check", patch_file })
  if check.code ~= 0 then
    vim.fn.delete(patch_file)
    return false, util.trim(check.stderr ~= "" and check.stderr or check.stdout)
  end

  local apply = system_result({ "git", "-C", cwd, "apply", "--whitespace=nowarn", patch_file })
  vim.fn.delete(patch_file)
  if apply.code ~= 0 then
    return false, util.trim(apply.stderr ~= "" and apply.stderr or apply.stdout)
  end

  vim.cmd("checktime")
  return true, "Patch applied by Neovim."
end

handlers.apply_patch = function(arguments, thread, message)
  arguments = normalize_arguments(arguments)
  local patch = arguments.patch or arguments.diff or arguments.unified_diff
  if type(patch) ~= "string" or util.trim(patch) == "" then
    return text_response("nvim.apply_patch requires a unified diff in arguments.patch.", false)
  end

  local params = message.params or {}
  local rpc = require("codex.rpc")
  local cwd = vim.fs.normalize(vim.fn.expand(arguments.cwd or (thread and thread.cwd) or config.cwd()))
  local changes = changes_from_unified_patch(patch)
  local responded = false

  local function respond(text, success)
    if responded then
      return
    end
    responded = true
    rpc.respond(message.id, text_response(text, success))
  end

  require("codex.patch_review").open({
    protocol = "local",
    source = "nvim_apply_patch",
    request_id = message.id,
    thread_id = params.threadId or params.thread_id or (thread and thread.id),
    cwd = cwd,
    reason = arguments.reason,
    changes = changes,
    on_decision = function(action)
      if action == "accept" or action == "accept_session" then
        local ok, result = apply_unified_patch(cwd, patch, changes)
        respond(result, ok)
      else
        respond("Patch " .. action .. " by user.", false)
      end
    end,
    on_close = function()
      respond("Patch review closed without approval.", false)
    end,
  })

  return async_response
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
  local thread_id = params.threadId or params.thread_id
  local thread = thread_id and require("codex.state").get_thread(thread_id) or nil
  local ok, result = pcall(handler, params.arguments or {}, thread, message)
  if ok and result ~= async_response then
    rpc.respond(message.id, result)
  elseif not ok then
    rpc.respond(message.id, text_response(tostring(result), false))
  end
end

M._apply_unified_patch = apply_unified_patch
M._changes_from_unified_patch = changes_from_unified_patch
M._text_response = text_response

return M
