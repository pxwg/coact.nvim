local config = require("coact.config")
local context = require("coact.context")
local util = require("coact.util")

local M = {}
local async_response = {}
local nvim_apply_patch_auto_apply_by_thread = {}
local nvim_apply_patch_auto_apply_by_turn = {}
local system_result

local function apply_patch_protocol_text()
  return table.concat({
    "Use nvim.apply_patch as the Neovim-backed equivalent of Codex's native apply_patch tool in pair mode.",
    "Put the patch text directly in arguments.patch; do not include shell commands, prose, or markdown fences.",
    "Patch syntax must match the native Codex apply_patch format:",
    "*** Begin Patch",
    "*** Add File: <relative/path>",
    "+<new file line>",
    "*** Update File: <relative/path>",
    "*** Move to: <relative/new/path>",
    "@@",
    " <context line>",
    "-<removed line>",
    "+<added line>",
    "*** Delete File: <relative/path>",
    "*** End Patch",
    "For Add File, prefix every file content line with +. For Update File, use enough space-prefixed context lines plus - removed and + added lines to apply cleanly. For renames, put Move to immediately after Update File.",
    "Use paths relative to arguments.cwd or the thread working directory; never use absolute paths or paths that escape the working directory.",
    "Prefer small, focused patches with one logical edit per call; include multiple file operations only when they belong to the same change.",
    "Before patching, read the current buffer or relevant current file content and build the patch from that exact content.",
    "If a patch fails, re-read the current buffer or file before trying again. Do not repeatedly retry failed patches against stale context.",
    "nvim.apply_patch preserves coact.nvim pair features: it verifies native patches in a temporary copy, opens Neovim hunk review, returns user hunk feedback and nvim.diagnostics, and writes only through Neovim.",
    "Treat returned nvim.diagnostics, user hunk feedback, and stale-context retry guidance as pair-coding feedback for the next edit.",
    "Continue by fixing reported diagnostics, incorporating rejection feedback, or re-reading current content before retrying stale patches; handle errors and warnings before reporting completion, address hints when practical, and explain intentional or false-positive leftovers.",
    "If this tool reports that Neovim auto-apply is enabled for the current session, keep using nvim.apply_patch; it will skip interactive hunk review and apply through Neovim.",
    "Legacy unified diffs are accepted when git is available, but native apply_patch syntax is preferred.",
  }, "\n")
end

local function stale_patch_retry_message()
  return table.concat({
    "Do not retry this patch against stale context.",
    "Re-read the current buffer or relevant file content before producing another diff.",
  }, " ")
end

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
    description = apply_patch_protocol_text(),
    deferLoading = true,
    inputSchema = {
      type = "object",
      properties = {
        patch = {
          type = "string",
          description = "Native Codex apply_patch text to review and apply through Neovim. Start with *** Begin Patch and end with *** End Patch; legacy unified diffs are still accepted.",
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

local function nvim_apply_patch_enabled()
  local opts = config.get()
  return opts.dynamic_tools.enabled ~= false
    and config.edit_mode() == "pair"
    and opts.dynamic_tools.prefer_nvim_apply_patch == true
end

function M.specs()
  if not config.get().dynamic_tools.enabled then
    return nil
  end
  local out = {}
  for _, spec in ipairs(specs) do
    if spec.name ~= "apply_patch" or nvim_apply_patch_enabled() then
      table.insert(out, spec)
    end
  end
  return out
end

local handlers = {}

handlers.current_buffer = function(_, thread)
  local bufnr = context.target_buffer(thread)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  return text_response(("path: %s\nfiletype: %s\n\n%s"):format(name, vim.bo[bufnr].filetype, text))
end

local function diagnostics_text(thread)
  local bufnr = context.target_buffer(thread)
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return "No diagnostics in the target buffer."
  end
  local lines = {}
  for _, diagnostic in ipairs(diagnostics) do
    table.insert(lines, ("L%d:C%d %s"):format(diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message))
  end
  return table.concat(lines, "\n")
end

local function diagnostics_section(thread)
  local ok, text = pcall(diagnostics_text, thread)
  if not ok then
    text = "Diagnostics unavailable: " .. tostring(text)
  end
  return "## nvim.diagnostics\n" .. text
end

local function with_diagnostics(text, thread)
  return tostring(text or "") .. "\n\n" .. diagnostics_section(thread)
end

handlers.diagnostics = function(_, thread)
  return text_response(diagnostics_text(thread))
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
    local move_path = absolute_change_path(cwd, change.move_path)
    if move_path then
      paths[move_path] = true
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

local function lines_to_text(lines)
  if not lines or #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function is_native_apply_patch(patch)
  patch = util.trim(patch or "")
  if patch:match("^<<['\"]?EOF['\"]?") then
    return true
  end
  return patch:match("^%*%*%* Begin Patch") ~= nil
end

local function native_patch_body_lines(patch)
  local lines = util.split_lines(util.trim(patch or ""))
  if #lines >= 4 and (lines[1] == "<<EOF" or lines[1] == "<<'EOF'" or lines[1] == '<<"EOF"') then
    if not tostring(lines[#lines]):match("EOF$") then
      return nil, "Invalid Codex apply_patch heredoc wrapper."
    end
    table.remove(lines, #lines)
    table.remove(lines, 1)
  end

  if util.trim(lines[1]) ~= "*** Begin Patch" then
    return nil, "The first line of the patch must be '*** Begin Patch'."
  end
  if util.trim(lines[#lines]) ~= "*** End Patch" then
    return nil, "The last line of the patch must be '*** End Patch'."
  end
  return vim.list_slice(lines, 2, #lines - 1)
end

local function parse_native_apply_patch_ops(patch)
  local body, err = native_patch_body_lines(patch)
  if not body then
    return nil, err
  end

  local ops = {}
  local current = nil
  for _, line in ipairs(body) do
    local environment_id = line:match("^%*%*%* Environment ID:%s*(.+)$")
    if environment_id then
      if util.trim(environment_id) ~= "" then
        return nil, "nvim.apply_patch does not support Codex apply_patch environment selection."
      end
    end

    local add_path = line:match("^%*%*%* Add File:%s*(.+)$")
    local delete_path = line:match("^%*%*%* Delete File:%s*(.+)$")
    local update_path = line:match("^%*%*%* Update File:%s*(.+)$")
    local move_path = line:match("^%*%*%* Move to:%s*(.+)$")
    if add_path then
      current = { kind = "add", path = util.trim(add_path) }
      table.insert(ops, current)
    elseif delete_path then
      current = { kind = "delete", path = util.trim(delete_path) }
      table.insert(ops, current)
    elseif update_path then
      current = { kind = "update", path = util.trim(update_path) }
      table.insert(ops, current)
    elseif move_path and current and current.kind == "update" then
      current.move_path = util.trim(move_path)
    end
  end

  if #ops == 0 then
    return nil, "Codex apply_patch contains no file operations."
  end
  return ops
end

local function native_path_is_absolute(path)
  path = tostring(path or "")
  return path:match("^/") or path:match("^%a:[/\\]")
end

local function temp_relative_for_native_path(path, index)
  local cleaned = tostring(path or ""):gsub("\\", "/")
  cleaned = cleaned:gsub("^%a:", function(drive)
    return drive:sub(1, 1)
  end)
  cleaned = cleaned:gsub("^/+", ""):gsub("^%./+", "")
  local parts = {}
  for part in cleaned:gmatch("[^/]+") do
    if part ~= "" and part ~= "." and part ~= ".." then
      table.insert(parts, (part:gsub("[^%w%._%-]", "_")))
    end
  end
  if #parts == 0 then
    parts = { "path" }
  end
  return vim.fs.joinpath(".coact-nvim-apply-patch", tostring(index), table.concat(parts, "/"))
end

local function resolve_native_patch_path(cwd, path, index, opts)
  opts = opts or {}
  path = util.trim(path or "")
  if path == "" then
    return nil, nil, nil, "Codex apply_patch file path is empty."
  end

  local cwd_normalized = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  if native_path_is_absolute(path) then
    if opts.allow_absolute ~= true then
      return nil, nil, nil, "Codex apply_patch file paths must be relative: " .. path
    end
    local absolute = vim.fs.normalize(path)
    return absolute, absolute, temp_relative_for_native_path(absolute, index)
  end

  local absolute = vim.fs.normalize(vim.fs.joinpath(cwd_normalized, path))
  local relative = vim.fs.relpath(cwd_normalized, absolute)
  if not relative or relative == "" or relative == "." or relative:match("^%.%.[/\\]") or relative == ".." then
    if opts.allow_absolute ~= true then
      return nil, nil, nil, "Codex apply_patch path escapes the working directory: " .. path
    end
    return absolute, absolute, temp_relative_for_native_path(path, index)
  end
  return absolute, relative, relative
end

local function rewrite_native_patch_paths_for_temp(patch, resolved)
  local lines = util.split_lines(patch)
  local op_index = 0
  local current = nil
  for index, line in ipairs(lines) do
    local add_prefix = line:match("^(%*%*%* Add File:%s*).+$")
    local delete_prefix = line:match("^(%*%*%* Delete File:%s*).+$")
    local update_prefix = line:match("^(%*%*%* Update File:%s*).+$")
    local move_prefix = line:match("^(%*%*%* Move to:%s*).+$")
    local op_prefix = add_prefix or delete_prefix or update_prefix
    if op_prefix then
      op_index = op_index + 1
      current = resolved[op_index]
      if current then
        lines[index] = op_prefix .. current.temp_relative_path
      end
    elseif move_prefix and current and current.move_temp_relative_path then
      lines[index] = move_prefix .. current.move_temp_relative_path
    end
  end
  return table.concat(lines, "\n")
end

local function read_file_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "Failed to read file " .. path .. ": " .. tostring(lines)
  end
  return lines
end

local function stale_context_line_limit()
  local edit = config.get().edit or {}
  return math.max(1, tonumber(edit.stale_context_lines) or 80)
end

local function first_hunk_old_start(diff)
  for _, line in ipairs(util.split_lines(diff or "")) do
    local start = line:match("^@@ %-(%d+)")
    if start then
      return tonumber(start)
    end
  end
  return nil
end

local function numbered_excerpt(lines, start_lnum, max_lines)
  max_lines = max_lines or stale_context_line_limit()
  local total = #lines
  if total == 0 then
    return "(empty file)"
  end
  start_lnum = math.max(1, tonumber(start_lnum) or 1)
  local finish_lnum = math.min(total, start_lnum + max_lines - 1)
  local out = {}
  if start_lnum > 1 then
    table.insert(out, ("... %d earlier line%s omitted ..."):format(start_lnum - 1, start_lnum == 2 and "" or "s"))
  end
  for lnum = start_lnum, finish_lnum do
    table.insert(out, ("%4d | %s"):format(lnum, lines[lnum] or ""))
  end
  if finish_lnum < total then
    table.insert(
      out,
      ("... %d later line%s omitted ..."):format(total - finish_lnum, total - finish_lnum == 1 and "" or "s")
    )
  end
  return table.concat(out, "\n")
end

local function stale_context_from_changes(cwd, changes, opts)
  opts = opts or {}
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  local max_files = math.max(1, tonumber(opts.max_files) or 4)
  local max_lines = math.max(1, tonumber(opts.max_lines) or stale_context_line_limit())
  local sections = {
    "## STALE CONTEXT RECOVERY",
    "The patch did not match the current file content. Re-read these current excerpts before producing the next patch.",
  }
  local seen = {}
  local count = 0
  for _, change in ipairs(changes or {}) do
    if count >= max_files then
      table.insert(
        sections,
        ("... %d additional file%s omitted ..."):format(#changes - count, #changes - count == 1 and "" or "s")
      )
      break
    end
    local path = absolute_change_path(cwd, change.path)
    if path and not seen[path] then
      seen[path] = true
      count = count + 1
      local label = vim.fn.fnamemodify(path, ":.")
      table.insert(sections, "")
      table.insert(sections, "### " .. label)
      local lines, read_err = read_file_lines(path)
      if not lines then
        table.insert(sections, "Could not read current file content: " .. tostring(read_err))
      elseif vim.fn.filereadable(path) ~= 1 then
        table.insert(sections, "File does not exist in the current workspace.")
      else
        local hunk_start = first_hunk_old_start(change.diff)
        local start_lnum = hunk_start and math.max(1, hunk_start - 8) or 1
        table.insert(sections, "```text")
        table.insert(sections, numbered_excerpt(lines, start_lnum, max_lines))
        table.insert(sections, "```")
      end
    end
  end
  if count == 0 then
    table.insert(sections, "")
    table.insert(sections, "No patch file paths could be resolved.")
  end
  return table.concat(sections, "\n")
end

local function stale_context_for_patch(cwd, patch, opts)
  opts = opts or {}
  if is_native_apply_patch(patch) then
    local ops, err = parse_native_apply_patch_ops(patch)
    if not ops then
      return "## STALE CONTEXT RECOVERY\nCould not parse patch paths: " .. tostring(err)
    end
    local changes = {}
    for index, op in ipairs(ops) do
      local _, display_path, _, path_err = resolve_native_patch_path(cwd, op.path, index, opts)
      if display_path then
        table.insert(changes, {
          kind = op.kind,
          path = display_path,
        })
      elseif path_err then
        table.insert(changes, {
          kind = op.kind,
          path = op.path,
          diff = path_err,
        })
      end
    end
    return stale_context_from_changes(cwd, changes, opts)
  end
  return stale_context_from_changes(cwd, changes_from_unified_patch(patch), opts)
end

local function copy_file_to_temp(src, temp_root, relative)
  if vim.fn.filereadable(src) ~= 1 then
    return true
  end
  local dst = vim.fs.joinpath(temp_root, relative)
  local parent = vim.fn.fnamemodify(dst, ":h")
  if parent ~= "" and vim.fn.isdirectory(parent) == 0 then
    vim.fn.mkdir(parent, "p")
  end
  local ok, lines = pcall(vim.fn.readfile, src, "b")
  if not ok then
    return nil, "Failed to read file " .. src .. ": " .. tostring(lines)
  end
  ok, lines = pcall(vim.fn.writefile, lines, dst, "b")
  if not ok then
    return nil, "Failed to copy file " .. src .. ": " .. tostring(lines)
  end
  return true
end

local function apply_patch_runtime_args(patch)
  local apply_patch = vim.fn.exepath("apply_patch")
  if apply_patch ~= "" then
    return { apply_patch }, { stdin = patch }
  end

  local app_command = config.get().app_server and config.get().app_server.command or nil
  local codex = type(app_command) == "table" and app_command[1] or "codex"
  if vim.fn.executable(codex) ~= 1 and vim.fn.exepath(codex) == "" then
    return nil, nil, "Codex executable is required to verify native apply_patch patches: " .. tostring(codex)
  end
  return { codex, "--codex-run-as-apply-patch", patch }, {}
end

local function apply_native_patch_in_temp(temp_root, patch)
  local args, opts, err = apply_patch_runtime_args(patch)
  if not args then
    return nil, err
  end
  opts = vim.tbl_extend("force", opts or {}, { cwd = temp_root, text = true })
  local result = system_result(args, opts)
  if result.code ~= 0 then
    return nil, util.trim(result.stderr ~= "" and result.stderr or result.stdout)
  end
  return true
end

local function changes_from_native_apply_patch(cwd, patch, opts)
  opts = opts or {}
  cwd = vim.fs.normalize(vim.fn.expand(cwd or config.cwd()))
  if vim.fn.isdirectory(cwd) ~= 1 then
    return nil, "Patch cwd is not a directory: " .. cwd
  end
  local ops, err = parse_native_apply_patch_ops(patch)
  if not ops then
    return nil, err
  end

  local changes = {}
  local resolved = {}
  for _, op in ipairs(ops) do
    local absolute, display_path, temp_relative
    absolute, display_path, temp_relative, err = resolve_native_patch_path(cwd, op.path, #resolved + 1, opts)
    if not absolute then
      return nil, err
    end
    op.absolute_path = absolute
    op.display_path = display_path
    op.temp_relative_path = temp_relative
    table.insert(changes, {
      kind = op.kind,
      path = display_path,
      move_path = op.move_path,
    })

    if op.move_path then
      local move_absolute, move_display_path, move_temp_relative
      move_absolute, move_display_path, move_temp_relative, err =
        resolve_native_patch_path(cwd, op.move_path, tostring(#resolved + 1) .. "-move", opts)
      if not move_absolute then
        return nil, err
      end
      op.move_absolute_path = move_absolute
      op.move_display_path = move_display_path
      op.move_temp_relative_path = move_temp_relative
      changes[#changes].move_path = move_display_path
    end
    table.insert(resolved, op)
  end

  local conflicts = modified_buffer_conflicts(cwd, changes)
  if #conflicts > 0 then
    return nil, "Refusing to apply patch over modified loaded buffers:\n" .. table.concat(conflicts, "\n")
  end

  local temp_root = vim.fn.tempname()
  vim.fn.mkdir(temp_root, "p")
  local ok, result, result_err = pcall(function()
    for _, op in ipairs(resolved) do
      local copy_ok, copy_err = copy_file_to_temp(op.absolute_path, temp_root, op.temp_relative_path)
      if not copy_ok then
        return nil, copy_err
      end
      if op.move_absolute_path then
        copy_ok, copy_err = copy_file_to_temp(op.move_absolute_path, temp_root, op.move_temp_relative_path)
        if not copy_ok then
          return nil, copy_err
        end
      end
    end

    local temp_patch = rewrite_native_patch_paths_for_temp(patch, resolved)
    local apply_ok, apply_err = apply_native_patch_in_temp(temp_root, temp_patch)
    if not apply_ok then
      return nil, apply_err
    end

    local out = {}
    for _, op in ipairs(resolved) do
      local old_lines, read_err = read_file_lines(op.absolute_path)
      if not old_lines then
        return nil, read_err
      end
      local final_relative = op.move_temp_relative_path or op.temp_relative_path
      local final_path = vim.fs.joinpath(temp_root, final_relative)
      local new_lines
      if op.kind == "delete" and not op.move_temp_relative_path then
        new_lines = {}
      else
        new_lines, read_err = read_file_lines(final_path)
        if not new_lines then
          return nil, read_err
        end
      end

      local diff = vim.diff(lines_to_text(old_lines), lines_to_text(new_lines), {
        result_type = "unified",
        ctxlen = 3,
      })
      diff = util.trim(diff or "")
      table.insert(out, {
        kind = op.kind,
        path = op.display_path,
        move_path = op.move_display_path,
        diff = diff,
      })
    end
    return out
  end)
  vim.fn.delete(temp_root, "rf")

  if not ok then
    return nil, tostring(result)
  end
  if not result then
    return nil, result_err or "Native apply_patch conversion failed."
  end
  return result
end

system_result = function(args, opts)
  local ok, result = pcall(function()
    return vim.system(args, opts or { text = true }):wait()
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

local function validate_unified_patch(cwd, patch, changes)
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
  vim.fn.delete(patch_file)
  if check.code ~= 0 then
    return false, util.trim(check.stderr ~= "" and check.stderr or check.stdout)
  end
  return true, "Patch can be applied."
end

local function turn_id_for(params, thread)
  return params.turnId or params.turn_id or (thread and thread.active_turn_id)
end

local function thread_state_key(params, thread)
  local thread_id = params.threadId or params.thread_id or (thread and thread.id)
  return thread_id and tostring(thread_id) or nil
end

local function turn_state_key(params, thread)
  local thread_id = thread_state_key(params, thread)
  local turn_id = turn_id_for(params, thread)
  if not thread_id or not turn_id then
    return nil
  end
  return thread_id .. ":" .. tostring(turn_id)
end

local function mark_nvim_apply_patch_auto_apply(params, thread, scope)
  local key
  if scope == "turn" then
    key = turn_state_key(params or {}, thread)
    if key then
      nvim_apply_patch_auto_apply_by_turn[key] = true
    end
    return key
  end

  key = thread_state_key(params or {}, thread)
  if key then
    nvim_apply_patch_auto_apply_by_thread[key] = true
  end
  return key
end

local function nvim_apply_patch_auto_apply_active(params, thread)
  local thread_key = thread_state_key(params or {}, thread)
  if thread_key and nvim_apply_patch_auto_apply_by_thread[thread_key] == true then
    return true
  end
  local turn_key = turn_state_key(params or {}, thread)
  return turn_key and nvim_apply_patch_auto_apply_by_turn[turn_key] == true
end

local function nvim_apply_patch_auto_apply_message()
  return table.concat({
    "User enabled Neovim auto-apply for this session.",
    "This patch was applied through `nvim.apply_patch` after Neovim verification.",
    "For this session, keep using `nvim.apply_patch` for remaining edits; it will skip interactive hunk review and apply through Neovim.",
    "Do not use the native `apply_patch` tool in pair mode.",
  }, " ")
end

handlers.apply_patch = function(arguments, thread, message)
  arguments = normalize_arguments(arguments)
  local patch = arguments.patch or arguments.diff or arguments.unified_diff
  if type(patch) ~= "string" or util.trim(patch) == "" then
    return text_response(
      with_diagnostics("nvim.apply_patch requires Codex apply_patch text in arguments.patch.", thread),
      false
    )
  end

  local params = message.params or {}
  local rpc = require("coact.rpc")
  local cwd = vim.fs.normalize(vim.fn.expand(arguments.cwd or (thread and thread.cwd) or config.cwd()))
  local changes
  local responded = false

  local function respond(text, success)
    if responded then
      return
    end
    responded = true
    rpc.respond(message.id, text_response(with_diagnostics(text, thread), success))
  end

  if is_native_apply_patch(patch) then
    local err
    changes, err = changes_from_native_apply_patch(cwd, patch)
    if not changes then
      respond(err .. "\n\n" .. stale_patch_retry_message() .. "\n\n" .. stale_context_for_patch(cwd, patch), false)
      return async_response
    end
  else
    changes = changes_from_unified_patch(patch)
    local valid, validation_message = validate_unified_patch(cwd, patch, changes)
    if not valid then
      respond(
        validation_message
          .. "\n\n"
          .. stale_patch_retry_message()
          .. "\n\n"
          .. stale_context_from_changes(cwd, changes),
        false
      )
      return async_response
    end
  end

  local session, err = require("coact.patch_session").open({
    request_id = message.id,
    thread_id = params.threadId or params.thread_id or (thread and thread.id),
    cwd = cwd,
    reason = arguments.reason,
    changes = changes,
    interactive = not nvim_apply_patch_auto_apply_active(params, thread),
    on_complete = function(summary, success)
      if nvim_apply_patch_auto_apply_active(params, thread) then
        summary = nvim_apply_patch_auto_apply_message() .. "\n\n" .. tostring(summary or "")
      end
      respond(summary, success)
    end,
    on_auto_apply = function()
      mark_nvim_apply_patch_auto_apply(params, thread)
    end,
  })
  if not session then
    respond((err or "Patch review could not be opened.") .. "\n\n" .. stale_context_from_changes(cwd, changes), false)
  end

  return async_response
end

function M.handle_call(message)
  local params = message.params or {}
  local rpc = require("coact.rpc")
  if params.namespace ~= "nvim" then
    rpc.respond(message.id, text_response("Unsupported dynamic tool namespace: " .. tostring(params.namespace), false))
    return
  end
  if params.tool == "apply_patch" and not nvim_apply_patch_enabled() then
    rpc.respond(
      message.id,
      text_response(
        "nvim.apply_patch is not exposed in the current coact.nvim edit mode. Use native apply_patch directly.",
        false
      )
    )
    return
  end
  local handler = handlers[params.tool]
  if not handler then
    rpc.respond(message.id, text_response("Unsupported Neovim tool: " .. tostring(params.tool), false))
    return
  end
  local thread_id = params.threadId or params.thread_id
  local thread = thread_id and require("coact.state").get_thread(thread_id) or nil
  local ok, result = pcall(handler, params.arguments or {}, thread, message)
  if ok and result ~= async_response then
    rpc.respond(message.id, result)
  elseif not ok then
    rpc.respond(message.id, text_response(tostring(result), false))
  end
end

function M.clear_turn_state(thread_id, turn_id)
  if not thread_id or not turn_id then
    return
  end
  nvim_apply_patch_auto_apply_by_turn[tostring(thread_id) .. ":" .. tostring(turn_id)] = nil
end

function M.clear_thread_state(thread_id)
  if not thread_id then
    return
  end
  thread_id = tostring(thread_id)
  nvim_apply_patch_auto_apply_by_thread[thread_id] = nil
  local prefix = thread_id .. ":"
  for key in pairs(nvim_apply_patch_auto_apply_by_turn) do
    if key:sub(1, #prefix) == prefix then
      nvim_apply_patch_auto_apply_by_turn[key] = nil
    end
  end
end

M._apply_unified_patch = apply_unified_patch
M._changes_from_unified_patch = changes_from_unified_patch
M._changes_from_native_apply_patch = changes_from_native_apply_patch
M._validate_unified_patch = validate_unified_patch
M._mark_nvim_apply_patch_auto_apply = mark_nvim_apply_patch_auto_apply
M._nvim_apply_patch_auto_apply_active = nvim_apply_patch_auto_apply_active
M._nvim_apply_patch_auto_apply_message = nvim_apply_patch_auto_apply_message
M._nvim_apply_patch_enabled = nvim_apply_patch_enabled
M._apply_patch_protocol_text = apply_patch_protocol_text
M._stale_patch_retry_message = stale_patch_retry_message
M._stale_context_for_patch = stale_context_for_patch
M._stale_context_from_changes = stale_context_from_changes
M._diagnostics_text = diagnostics_text
M._with_diagnostics = with_diagnostics
M._text_response = text_response

return M
