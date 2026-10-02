local config = require("coact.config")
local util = require("coact.util")

local M = {}

local REQUEST_MARKER = "__coactNvimExecLua"
local RESULT_MARKER = "__coactNvimExecLuaResult"
local extension_path = nil
local nonce = nil

local function bridge_opts()
  local opts = config.get()
  local pi = opts.adapter or {}
  return pi.nvim_tools or {}
end

local function enabled()
  local opts = bridge_opts()
  local ok, providers = pcall(require, "coact.providers")
  return ok and providers.is("pi") and opts.enabled ~= false
end

local function list_copy(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  return {}
end

local function append_command_args(command, args)
  if type(command) == "string" then
    if #args == 0 then
      return command
    end
    return command .. " " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  end
  local out = list_copy(command)
  vim.list_extend(out, args)
  return out
end

local function ensure_nonce()
  if nonce then
    return nonce
  end
  nonce = vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. tostring(math.random()))
  return nonce
end

local function extension_source()
  return [=[
import { Type } from "typebox";

const execLuaSchema = Type.Object({
  code: Type.String({
    description:
      "Lua statements to execute in the Neovim instance hosting this Pi session. Start with `local ctx, args = ...` when target context or structured arguments are needed, and return one JSON-serializable value.",
  }),
  args: Type.Optional(Type.Unknown({
    description: "Optional JSON-serializable value passed to the Lua chunk as its second argument.",
  })),
}, { additionalProperties: false });

function bridgeNonce() {
  const nonce = process.env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE;
  if (!nonce) {
    throw new Error("coact.nvim nvim_exec_lua is not connected to its Neovim host.");
  }
  return nonce;
}

export default function (pi) {
  pi.registerTool({
    name: "nvim_exec_lua",
    label: "nvim_exec_lua",
    description:
      "Execute Lua in the live Neovim instance hosting this Pi session. The chunk runs with the Coact thread's source window or buffer temporarily current, receives `ctx, args = ...`, may use vim.cmd, vim.api, vim.fn, and require(), and should return one JSON-serializable value. This is a full-trust escape hatch over live editor state; ordinary workspace file edits should continue to use edit/write review. Results are limited to 50KB or 2000 lines, with oversized JSON saved to a temporary file.",
    promptSnippet: "Execute Lua against the live Neovim instance hosting this Pi session",
    promptGuidelines: [
      "Use nvim_exec_lua when the task requires inspecting or operating the user's live Neovim state, editor windows, buffers, LSP clients, or plugin APIs.",
      "In nvim_exec_lua code, use `local ctx, args = ...`; the source context includes thread_id, bufnr, winid, tabpage, cwd, cursor, buffer_name, filetype, modified, changedtick, and line_count.",
      "Keep nvim_exec_lua calls short and non-blocking, and return one JSON-serializable value so the result can be reported reliably.",
      "Do not use nvim_exec_lua to bypass coact.nvim edit/write review for ordinary workspace file-content changes, or to close the user's Neovim instance unless explicitly requested.",
    ],
    parameters: execLuaSchema,
    executionMode: "sequential",

    async execute(toolCallId, { code, args }, signal, _onUpdate, ctx) {
      const response = await ctx.ui.select(
        "coact.nvim nvim_exec_lua",
        [{
          __coactNvimExecLua: true,
          version: 1,
          nonce: bridgeNonce(),
          toolCallId,
          cwd: ctx.cwd,
          code,
          args,
        }],
        { signal },
      );

      if (!response || typeof response !== "object" || response.__coactNvimExecLuaResult !== true) {
        throw new Error("coact.nvim did not return a valid nvim_exec_lua result.");
      }
      if (!response.ok) {
        throw new Error(response.error || "nvim_exec_lua failed in Neovim.");
      }

      return {
        content: [{
          type: "text",
          text: typeof response.text === "string" && response.text.length > 0
            ? response.text
            : "Neovim Lua executed successfully.",
        }],
        details: {
          value: response.value,
          target: response.target,
          elapsedMs: response.elapsedMs,
          truncated: response.truncated,
          fullOutputPath: response.fullOutputPath,
        },
      };
    },
  });
}
]=]
end

local function ensure_extension_path()
  if extension_path and vim.fn.filereadable(extension_path) == 1 then
    return extension_path
  end
  local path = vim.fn.tempname() .. "-coact-nvim-pi-nvim-bridge.ts"
  local ok, err = pcall(vim.fn.writefile, vim.split(extension_source(), "\n", { plain = true }), path)
  if not ok or (err ~= 0 and err ~= nil) then
    return nil, "failed to write Pi Neovim tool extension: " .. tostring(err)
  end
  extension_path = path
  return extension_path
end

function M.prepare_command(command, env, launch)
  if not enabled() then
    return command, env
  end
  local path, path_err = ensure_extension_path()
  if not path then
    return nil, nil, path_err
  end
  env = env or {}
  env.COACT_NVIM_PI_CLIENT_ID = launch and launch.client_id or env.COACT_NVIM_PI_CLIENT_ID or "pi-legacy"
  env.COACT_NVIM_PI_NVIM_BRIDGE_NONCE = ensure_nonce()
  return append_command_args(command, { "--extension", path }), env
end

local function positive_integer(value, fallback, minimum)
  value = tonumber(value)
  if value == nil then
    value = fallback
  end
  return math.max(minimum or 1, math.floor(value))
end

local function result_limits()
  local opts = bridge_opts()
  return {
    max_bytes = positive_integer(opts.max_result_bytes, 50 * 1024, 1024),
    max_lines = positive_integer(opts.max_result_lines, 2000, 1),
    max_code_bytes = positive_integer(opts.max_code_bytes, 64 * 1024, 1024),
  }
end

local function request_from_message(message)
  local options = type(message) == "table" and type(message.options) == "table" and message.options or {}
  local request = options[1]
  if type(request) == "table" and request[REQUEST_MARKER] == true then
    return request
  end
  return nil
end

function M.is_request(message)
  return type(message) == "table" and message.method == "select" and request_from_message(message) ~= nil
end

local function source_target(thread_id)
  local state = require("coact.state")
  local context = require("coact.context")
  local thread = thread_id and state.get_thread(thread_id) or nil
  if not thread then
    return nil, "nvim_exec_lua could not resolve the active Coact thread."
  end
  local bufnr = tonumber(thread.context_bufnr)
  if not bufnr or not context.is_context_buffer(bufnr) then
    return nil, "nvim_exec_lua requires a valid loaded source buffer for the active Coact thread."
  end
  return {
    thread = thread,
    thread_id = thread_id,
    bufnr = bufnr,
    winid = context.window_for_buffer(bufnr, thread),
  }
end

local function target_snapshot(target)
  local bufnr = target and target.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return {
      valid = false,
      thread_id = target and target.thread_id or nil,
      bufnr = bufnr,
    }
  end
  local context = require("coact.context")
  local winid = target.winid
  if not (winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr) then
    winid = context.window_for_buffer(bufnr, target.thread)
  end
  local tabpage = winid and vim.api.nvim_win_get_tabpage(winid) or nil
  local cursor = context.cursor_for_buffer(bufnr, target.thread)
  return {
    valid = true,
    thread_id = target.thread_id,
    bufnr = bufnr,
    winid = winid,
    tabpage = tabpage,
    cwd = config.cwd(),
    cursor = cursor,
    buffer_name = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    modified = vim.bo[bufnr].modified,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    line_count = vim.api.nvim_buf_line_count(bufnr),
  }
end

local function elapsed_ms(started_at)
  return math.floor((vim.uv.hrtime() - started_at) / 1000000)
end

local function error_result(message, target, started_at)
  return {
    [RESULT_MARKER] = true,
    ok = false,
    error = tostring(message or "nvim_exec_lua failed in Neovim."),
    target = target,
    elapsedMs = elapsed_ms(started_at),
  }
end

local function compile_chunk(code)
  local compiler = loadstring or load
  return compiler(code, "@coact.nvim/pi/nvim_exec_lua")
end

local function execute_in_target(target, code, args, exec_context)
  local function run()
    local chunk, compile_err = compile_chunk(code)
    if not chunk then
      return {
        ok = false,
        error = "nvim_exec_lua could not compile the Lua chunk: " .. tostring(compile_err),
      }
    end
    local ok, value = xpcall(function()
      return chunk(exec_context, args)
    end, function(err)
      return debug.traceback(tostring(err), 2)
    end)
    if not ok then
      return {
        ok = false,
        error = value,
      }
    end
    return {
      ok = true,
      value = value,
    }
  end

  local ok, execution = pcall(function()
    if target.winid and vim.api.nvim_win_is_valid(target.winid) then
      return vim.api.nvim_win_call(target.winid, run)
    end
    return vim.api.nvim_buf_call(target.bufnr, run)
  end)
  if not ok then
    return {
      ok = false,
      error = debug.traceback(tostring(execution), 2),
    }
  end
  return execution
end

local function line_count(text)
  local _, newlines = tostring(text or ""):gsub("\n", "\n")
  return newlines + 1
end

local function save_full_result(encoded)
  local path = vim.fn.tempname() .. "-coact-nvim-exec-lua.json"
  local ok, err = pcall(vim.fn.writefile, { encoded }, path, "b")
  if not ok or (err ~= 0 and err ~= nil) then
    return nil, tostring(err)
  end
  return path
end

local function prepare_value(value, limits)
  if value == nil then
    return {
      text = "Neovim Lua executed successfully (no return value).",
    }
  end

  local ok_encode, encoded = pcall(vim.json.encode, value)
  if not ok_encode then
    return nil, "nvim_exec_lua return value is not JSON-serializable: " .. tostring(encoded)
  end
  local ok_decode, normalized = pcall(vim.json.decode, encoded)
  if not ok_decode then
    return nil, "nvim_exec_lua return value could not be normalized as JSON: " .. tostring(normalized)
  end

  local text
  if type(normalized) == "string" then
    text = normalized ~= "" and normalized or '""'
  else
    text = vim.inspect(normalized)
  end

  if #text > limits.max_bytes or line_count(text) > limits.max_lines then
    local path, write_err = save_full_result(encoded)
    if not path then
      return nil, "nvim_exec_lua result exceeded output limits and could not be saved: " .. tostring(write_err)
    end
    return {
      text = ("Neovim Lua result exceeded %d bytes or %d lines. Full JSON result saved to: %s"):format(
        limits.max_bytes,
        limits.max_lines,
        path
      ),
      truncated = true,
      fullOutputPath = path,
    }
  end

  return {
    value = normalized,
    text = text,
  }
end

function M.execute_request(request, opts)
  local started_at = vim.uv.hrtime()
  opts = opts or {}
  request = type(request) == "table" and request or {}
  if request[REQUEST_MARKER] ~= true or request.version ~= 1 then
    return error_result("Rejected an unsupported nvim_exec_lua bridge request.", nil, started_at)
  end
  if not nonce or request.nonce ~= nonce then
    return error_result("Rejected nvim_exec_lua request with an invalid Neovim bridge nonce.", nil, started_at)
  end
  if type(request.code) ~= "string" or util.trim(request.code) == "" then
    return error_result("nvim_exec_lua requires a non-empty Lua chunk.", nil, started_at)
  end

  local limits = result_limits()
  if #request.code > limits.max_code_bytes then
    return error_result(
      ("nvim_exec_lua code exceeds the configured %d-byte limit."):format(limits.max_code_bytes),
      nil,
      started_at
    )
  end

  local target, target_err = source_target(opts.thread_id)
  if not target then
    return error_result(target_err, nil, started_at)
  end
  local before = target_snapshot(target)
  local execution = execute_in_target(target, request.code, request.args, vim.deepcopy(before))
  local after = target_snapshot(target)
  local target_result = {
    before = before,
    after = after,
  }
  if not execution or not execution.ok then
    return error_result(
      execution and execution.error or "nvim_exec_lua returned no execution result.",
      target_result,
      started_at
    )
  end

  local prepared, prepare_err = prepare_value(execution.value, limits)
  if not prepared then
    return error_result(prepare_err, target_result, started_at)
  end
  return {
    [RESULT_MARKER] = true,
    ok = true,
    value = prepared.value,
    text = prepared.text,
    truncated = prepared.truncated,
    fullOutputPath = prepared.fullOutputPath,
    target = target_result,
    elapsedMs = elapsed_ms(started_at),
  }
end

function M.handle_request(message, opts)
  local started_at = vim.uv.hrtime()
  local ok, result = xpcall(function()
    return M.execute_request(request_from_message(message), opts)
  end, function(err)
    return debug.traceback(tostring(err), 2)
  end)
  if ok then
    return result
  end
  return error_result(result, nil, started_at)
end

function M.enabled()
  return enabled()
end

function M.runtime_config()
  if not enabled() then
    return nil
  end
  return {
    extension_path = extension_path,
    nonce = nonce,
    limits = result_limits(),
  }
end

function M._extension_source()
  return extension_source()
end

function M._nonce()
  return nonce
end

return M
