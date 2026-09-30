-- IDE tool contracts follow coder/claudecode.nvim's PROTOCOL.md. The SDK
-- tunnels JSON-RPC over stream-json control requests rather than a WS listener.
local M = {}
local function object(value)
  return type(value) == "table" and value or {}
end
local function text(value)
  return type(value) == "string" and value or ""
end
local function content(value, failed)
  return {
    content = { { type = "text", text = type(value) == "string" and value or vim.json.encode(value) } },
    isError = failed or nil,
  }
end
local tools = {
  {
    name = "getCurrentSelection",
    description = "Get the source buffer and cursor that opened this Coact thread.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
  },
  {
    name = "getDiagnostics",
    description = "Get diagnostics from the source buffer for this Coact thread.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
  },
  {
    name = "edit",
    description = "Make precise text replacements, then review and write through Neovim. Each oldText must match exactly once in the ORIGINAL file; edits must not overlap. Send only changed snippets, not the whole file. Absolute and workspace-relative paths are supported.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        edits = {
          type = "array",
          minItems = 1,
          items = {
            type = "object",
            properties = { oldText = { type = "string", minLength = 1 }, newText = { type = "string" } },
            required = { "oldText", "newText" },
            additionalProperties = false,
          },
        },
      },
      required = { "path", "edits" },
      additionalProperties = false,
    },
  },
  {
    name = "openDiff",
    description = "Propose complete new file contents for Neovim review. Writes accepted changes and returns FILE_SAVED or DIFF_REJECTED. Use for new files and full rewrites; use edit for incremental changes. Paths may be outside the workspace.",
    inputSchema = {
      type = "object",
      properties = {
        old_file_path = { type = "string" },
        new_file_path = { type = "string" },
        new_file_contents = { type = "string" },
        tab_name = { type = "string" },
      },
      required = { "new_file_path", "new_file_contents" },
    },
  },
}

local function source(client)
  local thread = require("coact.state").get_thread(client.id)
  local buf = thread and thread.context_bufnr
  local cursor = buf and vim.api.nvim_buf_is_valid(buf) and require("coact.context").cursor_for_buffer(buf, thread)
    or nil
  return { bufnr = buf, cursor = cursor }
end

local function open_diff(client, args, done)
  if client.review and not client.review.completed then
    done(content("Another review is pending for this thread", true))
    return
  end
  local path = text(args.new_file_path)
  if path == "" or type(args.new_file_contents) ~= "string" or path:find("[%z\r\n\t]") then
    done(content("Invalid file path or contents", true))
    return
  end
  if #args.new_file_contents > 2 * 1024 * 1024 or args.new_file_contents:find("%z") then
    done(content("openDiff supports text files up to 2 MiB", true))
    return
  end
  if path:sub(1, 2) == "~/" then
    path = vim.fn.expand("~") .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(client.cwd, path)
  end
  path = vim.fs.normalize(path)
  -- Resolve symlinks, including parent directories of newly created files.
  local parent = vim.fs.dirname(path)
  local resolved = vim.uv.fs_realpath(path)
  local ancestor = parent
  while not resolved and ancestor do
    local real = vim.uv.fs_realpath(ancestor)
    if real then
      resolved = real .. path:sub(#ancestor + 1)
      break
    end
    ancestor = vim.fs.dirname(ancestor) ~= ancestor and vim.fs.dirname(ancestor) or nil
  end
  if not resolved then
    done(content("Could not resolve target path", true))
    return
  end
  path = resolved
  -- Review relative to the target's parent, not the thread workspace. The
  -- absolute target is retained in changes so cross-workspace edits stay clear.
  local root = vim.fs.dirname(path)
  if text(args.old_file_path) ~= "" then
    local old = args.old_file_path
    if old:sub(1, 2) == "~/" then
      old = vim.fn.expand("~") .. old:sub(2)
    end
    if old:sub(1, 1) ~= "/" then
      old = vim.fs.joinpath(client.cwd, old)
    end
    old = vim.uv.fs_realpath(old) or vim.fs.normalize(old)
    if old ~= path then
      done(content("Renames are not supported by openDiff", true))
      return
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and (vim.uv.fs_realpath(name) or name) == path and vim.bo[buf].modified then
      done(content("Refusing to apply patch over modified loaded buffers", true))
      return
    end
  end
  local stat = vim.uv.fs_stat(path)
  if stat and (stat.type ~= "file" or stat.size > 2 * 1024 * 1024) then
    done(content("Target is not a regular file", true))
    return
  end
  local old = ""
  if stat then
    local file = io.open(path, "rb")
    if not file then
      done(content("Could not read target file", true))
      return
    end
    old = file:read("*a")
    file:close()
  end
  if args._expected_old ~= nil and old ~= args._expected_old then
    done(content("File changed while preparing edit; read it again before retrying", true))
    return
  end
  if old:find("%z") or (not stat and args.new_file_contents == "") then
    done(content("Binary files and empty new files are not supported by openDiff", true))
    return
  end
  local hunks = vim.diff(old, args.new_file_contents, { result_type = "unified", ctxlen = 4 })
  if hunks == "" then
    done(content("FILE_SAVED"))
    return
  end
  local rel = vim.fs.basename(path)
  local patch = "diff --git a/"
    .. rel
    .. " b/"
    .. rel
    .. "\n--- "
    .. (stat and "a/" .. rel or "/dev/null")
    .. "\n+++ b/"
    .. rel
    .. "\n"
    .. hunks
  local session, err = require("coact.patch_session").open({
    thread_id = client.id,
    cwd = root,
    changes = { { path = path, kind = stat and "update" or "add", diff = patch } },
    interactive = true,
    on_complete = function(summary, success, result)
      client.review = nil
      local saved = success and result and result.write_ok and (result.rejected_blocks or 0) == 0
      done(content((saved and "FILE_SAVED" or "DIFF_REJECTED") .. "\n" .. text(summary)))
    end,
  })
  if not session then
    done(content("DIFF_REJECTED: " .. tostring(err), true))
  elseif not session.completed then
    client.review = session
  end
end

local function edit(client, args, done)
  local path = text(args.path)
  if
    path == ""
    or path:find("[%z\r\n\t]")
    or type(args.edits) ~= "table"
    or not vim.islist(args.edits)
    or #args.edits == 0
  then
    done(content("edit requires a path and a non-empty edits array", true))
    return
  end
  if path:sub(1, 2) == "~/" then
    path = vim.fn.expand("~") .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(client.cwd, path)
  end
  path = vim.fs.normalize(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > 2 * 1024 * 1024 then
    done(content("edit requires an existing text file up to 2 MiB", true))
    return
  end
  local file = io.open(path, "rb")
  if not file then
    done(content("Could not read target file", true))
    return
  end
  local old = file:read("*a")
  file:close()
  local ranges = {}
  for _, replacement in ipairs(args.edits) do
    if type(replacement) ~= "table" or text(replacement.oldText) == "" or type(replacement.newText) ~= "string" then
      done(content("Every edit requires non-empty oldText and string newText", true))
      return
    end
    local first, last = old:find(replacement.oldText, 1, true)
    if not first or old:find(replacement.oldText, first + 1, true) then
      done(content("oldText must match exactly once in the original file", true))
      return
    end
    table.insert(ranges, { first = first, last = last, text = replacement.newText })
  end
  table.sort(ranges, function(a, b)
    return a.first < b.first
  end)
  local parts, cursor = {}, 1
  for _, range in ipairs(ranges) do
    if range.first < cursor then
      done(content("Edits overlap in the original file", true))
      return
    end
    table.insert(parts, old:sub(cursor, range.first - 1))
    table.insert(parts, range.text)
    cursor = range.last + 1
  end
  table.insert(parts, old:sub(cursor))
  open_diff(client, { new_file_path = path, new_file_contents = table.concat(parts), _expected_old = old }, done)
end

function M.handle(client, message, done)
  message = object(message)
  local function reply(result, err)
    done({ jsonrpc = "2.0", id = message.id, result = result, error = err })
  end
  if message.method == "initialize" then
    reply({
      protocolVersion = "2024-11-05",
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = "coact", version = "0.1.0" },
    })
  elseif message.method == "notifications/initialized" then
    done({ jsonrpc = "2.0", result = vim.empty_dict() })
  elseif message.method == "ping" then
    reply(vim.empty_dict())
  elseif message.method == "tools/list" then
    reply({ tools = tools })
  elseif message.method == "tools/call" then
    local params = object(message.params)
    local ctx = source(client)
    local buf = ctx.bufnr
    if params.name == "openDiff" then
      local args = vim.deepcopy(object(params.arguments))
      args._expected_old = nil
      open_diff(client, args, reply)
    elseif params.name == "edit" then
      edit(client, object(params.arguments), reply)
    elseif params.name == "getCurrentSelection" then
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        reply(content("Source buffer is unavailable", true))
        return
      end
      reply(content({
        filePath = vim.api.nvim_buf_get_name(buf),
        cursor = ctx.cursor,
        text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      }))
    elseif params.name == "getDiagnostics" then
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        reply(content("Source buffer is unavailable", true))
        return
      end
      reply(content(vim.diagnostic.get(buf)))
    else
      reply(nil, { code = -32601, message = "Unknown Coact IDE tool" })
    end
  else
    reply(nil, { code = -32601, message = "Unsupported MCP method" })
  end
end

return M
