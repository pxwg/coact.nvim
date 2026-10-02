-- Shared synthetic regressions, included by scripts/smoke.lua.
return function()
  local config = require("coact.config")
  local rpc = require("coact.rpc")
  local saved, handlers = vim.deepcopy(config.root()), rpc.handlers
  local events = {}
  config.setup({ default_adapter = "claude" })
  rpc.set_handlers({
    notification = function(event)
      table.insert(events, event)
    end,
  })
  local provider = require("coact.providers.claude")
  local backend = require("coact.providers.claude_rpc")
  local command = provider.command(nil, { instructions = "custom instruction" })
  assert(vim.tbl_contains(command, "stream-json"))
  assert(vim.tbl_contains(command, "Read,Glob,Grep,Bash,Skill"), "pair mode must expose Bash and Skill")
  assert(not require("coact.native_apply_patch_hook").enabled())
  local prompts = 0
  for _, arg in ipairs(command) do
    if arg == "--append-system-prompt" then
      prompts = prompts + 1
    end
  end
  assert(prompts == 1, "append system instructions must not be overridden")
  local client =
    { id = "claude:smoke", pending = {}, cancelled = {}, blocks = {}, tail = "", turn = { id = "turn", items = {} } }
  local function dispatch(message)
    backend._dispatch(client, message)
  end
  dispatch({ type = "system", subtype = "status", status = vim.NIL })
  dispatch({ type = "stream_event", event = vim.NIL })
  dispatch({ type = "assistant", message = vim.NIL })
  dispatch({ type = "control_response", response = vim.NIL })
  assert(#events == 0, "status/null frames must not pollute chat")
  dispatch({ type = "stream_event", event = { type = "message_start", message = { id = "m" } } })
  dispatch({
    type = "stream_event",
    event = { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } },
  })
  dispatch({
    type = "stream_event",
    event = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "hello" } },
  })
  dispatch({ type = "assistant", message = { id = "m", content = { { type = "text", text = "hello" } } } })
  assert(#client.turn.items == 1 and client.turn.items[1].text == "hello", "final text must reconcile streaming")
  dispatch({
    type = "assistant",
    parent_tool_use_id = "parent",
    message = { id = "subagent", content = { { type = "text", text = "hidden" } } },
  })
  assert(#client.turn.items == 1, "subagent prose belongs to parent tool")
  dispatch({
    type = "assistant",
    message = { id = "tool-msg", content = { { type = "tool_use", id = "tool-1", name = "Read", input = vim.NIL } } },
  })
  dispatch({
    type = "user",
    message = { content = { { type = "tool_result", tool_use_id = "tool-1", content = "result" } } },
  })
  assert(client.turn.items[2].status == "completed")
  dispatch({ type = "result", subtype = "success", usage = vim.NIL })
  assert(not client.turn and events[#events].message == nil)
  assert(events[#events].method == "turn/completed")
  local sent, original_send = {}, vim.fn.chansend
  vim.fn.chansend = function(_, data)
    table.insert(sent, vim.json.decode(data))
    return #data
  end
  client.job = 123
  dispatch({
    type = "control_request",
    request_id = "deny",
    request = { subtype = "can_use_tool", tool_name = "Write", input = {} },
  })
  dispatch({
    type = "control_request",
    request_id = "allow",
    request = { subtype = "can_use_tool", tool_name = "mcp__coact__openDiff", input = {} },
  })
  dispatch({
    type = "control_request",
    request_id = "bash",
    request = { subtype = "can_use_tool", tool_name = "Bash", input = { command = "make test" } },
  })
  vim.fn.chansend = original_send
  client.job = nil
  assert(sent[1].response.response.behavior == "deny")
  assert(sent[2].response.response.behavior == "allow")
  assert(sent[3].response.response.behavior == "allow", "Bash must work in pair mode")
  dispatch({ type = "system", subtype = "compact_boundary", compact_metadata = vim.NIL })
  assert(events[#events].method == "thread/compacted")
  local catalogs = require("coact.providers.claude_catalog")
  client.init = {
    models = { vim.NIL, { value = "test-model" } },
    commands = { vim.NIL, { name = "test-skill" }, { name = "compact", builtin = true } },
  }
  client.metadata = { skills = vim.NIL }
  assert(#catalogs.models(client) == 1 and #catalogs.skills(client) == 1)
  assert(
    catalogs.prompt(client, { { type = "skill", name = "test-skill" }, { type = "text", text = "argument" } })
      == "/test-skill argument"
  )
  assert(not catalogs.prompt(client, { { type = "skill", name = "missing" } }))
  assert(
    not catalogs.prompt(client, { { type = "skill", name = "test-skill" }, { type = "skill", name = "test-skill" } })
  )

  local mcp = require("coact.providers.claude_mcp")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  client.cwd = root
  local original_buf = vim.api.nvim_get_current_buf()
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "SOURCE_MARKER" })
  local thread = require("coact.state").ensure_thread(client.id)
  thread.context_bufnr = source
  local function call(name, args, callback)
    local result
    mcp.handle(
      client,
      { jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = name, arguments = args or {} } },
      function(r)
        result = r
        if callback then
          callback(r)
        end
      end
    )
    return result
  end
  assert(
    call("getCurrentSelection").result.content[1].text:find("SOURCE_MARKER", 1, true),
    "MCP must use source, not current buffer"
  )
  local outside_path = vim.fn.tempname()
  local outside_result
  call("openDiff", { new_file_path = outside_path, new_file_contents = "outside\n" }, function(r)
    outside_result = r
  end)
  assert(client.review and not outside_result, "outside paths must enter review, not be rejected")
  local outside_buf = vim.api.nvim_get_current_buf()
  require("coact.patch_session")._accept_block(client.review, client.review.blocks[1])
  assert(outside_result.result.content[1].text:match("^FILE_SAVED") and vim.fn.readfile(outside_path)[1] == "outside")
  local path = root .. "/review.txt"
  vim.fn.writefile({ "before" }, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  assert(call("openDiff", { new_file_path = path, new_file_contents = "after\n" }).result.isError)
  assert(
    call("edit", { path = path, edits = { { oldText = "before", newText = "after" } } }).result.isError,
    "incremental edits must refuse dirty buffers"
  )
  vim.bo[buf].modified = false
  vim.cmd("edit!")
  local result
  call("openDiff", { new_file_path = path, new_file_contents = "after\n" }, function(r)
    result = r
  end)
  assert(client.review and not result, "review must block MCP response")
  require("coact.patch_session")._accept_block(client.review, client.review.blocks[1])
  assert(result.result.content[1].text:match("^FILE_SAVED"))
  assert(vim.fn.readfile(path)[1] == "after")
  result = nil
  call("openDiff", { new_file_path = path, new_file_contents = "rejected\n" }, function(r)
    result = r
  end)
  assert(client.review)
  local original_input = vim.ui.input
  vim.ui.input = function()
    error("transport cancellation must not prompt")
  end
  require("coact.patch_session").cancel(client.review)
  vim.ui.input = original_input
  assert(result.result.content[1].text:match("^DIFF_REJECTED"))
  assert(vim.fn.readfile(path)[1] == "after", "cancelled review must not write rejected changes")
  vim.fn.writefile({ "alpha", "beta" }, root .. "/incremental.txt")
  result = nil
  call("edit", {
    path = "incremental.txt",
    edits = { { oldText = "alpha", newText = "beta" }, { oldText = "beta", newText = "gamma" } },
  }, function(r)
    result = r
  end)
  assert(client.review and not result)
  local incremental_buf = vim.api.nvim_get_current_buf()
  local review = client.review
  for _, block in ipairs(review.blocks) do
    require("coact.patch_session")._accept_block(review, block)
  end
  assert(result.result.content[1].text:match("^FILE_SAVED"))
  assert(
    table.concat(vim.fn.readfile(root .. "/incremental.txt"), "\n") == "beta\ngamma",
    "replacements must match the original, not prior replacements"
  )
  assert(
    call("edit", { path = "incremental.txt", edits = { { oldText = "a", newText = "x" } } }).result.isError,
    "ambiguous edits must fail"
  )
  assert(call("edit", { path = "incremental.txt", edits = { { oldText = "missing", newText = "x" } } }).result.isError)
  assert(
    call("edit", {
      path = "incremental.txt",
      edits = { { oldText = "beta", newText = "x" }, { oldText = "beta\ngamma", newText = "y" } },
    }).result.isError,
    "overlapping edits must fail"
  )
  vim.api.nvim_buf_delete(incremental_buf, { force = true })
  vim.api.nvim_buf_delete(outside_buf, { force = true })
  vim.fn.delete(outside_path)
  if vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_set_current_buf(original_buf)
  else
    vim.cmd("enew")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, "rf")
  rpc.set_handlers(handlers)
  config.setup(saved)
end
