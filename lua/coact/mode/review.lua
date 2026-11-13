-- Agent changes reviewed with coact.nvim's hunk review, in the files'
-- own buffers: card plans from the server and plain file changes alike.
local M = {}

local cancelled = {
  ["no reason provided"] = true,
  ["patch review cancelled"] = true,
  ["provider review cancelled"] = true,
}

-- The text the server analyzed for path: the loaded buffer, else the file.
local function current_text(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if vim.bo[bufnr].eol or vim.bo[bufnr].fixeol then
      text = text .. "\n"
    end
    return text, bufnr
  end
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function version(bufnr)
  local versions = vim.lsp.util.buf_versions
  return versions and versions[bufnr] or vim.b[bufnr].changedtick
end

--- Turn a server plan ({path, version, exists, edits}[] with byte offsets,
--- plus {path, anchor, note}[] notes) into file changes, or nil, err.
function M.changes_of_plan(files, notes)
  local changes = {}
  for _, file in ipairs(files or {}) do
    local old, bufnr = "", nil
    if file.exists ~= false then
      old, bufnr = current_text(file.path)
      if not old then
        return nil, "cannot read " .. file.path
      end
      if bufnr and file.version ~= nil and file.version ~= vim.NIL and version(bufnr) ~= file.version then
        return nil, vim.fn.fnamemodify(file.path, ":~:.") .. " changed while the edit was planned; try again"
      end
    end
    local edits = vim.deepcopy(file.edits)
    table.sort(edits, function(a, b)
      return a.startByte > b.startByte
    end)
    local new = old
    for _, edit in ipairs(edits) do
      new = new:sub(1, edit.startByte) .. edit.newText .. new:sub(edit.stopByte + 1)
    end
    local file_notes = {}
    for _, note in ipairs(notes or {}) do
      if note.path == file.path then
        table.insert(file_notes, { anchor = note.anchor, note = note.note })
      end
    end
    table.insert(changes, {
      path = file.path,
      oldContent = old,
      newContent = new,
      kind = file.exists == false and "add" or "update",
      notes = file_notes,
    })
  end
  return changes
end

--- Review file changes ({path, oldContent, newContent, kind, notes}[]) in
--- one hunk review. done({ accepted, rejected, reasons, summary }) or
--- done({ error }). Buffers locked by a call are writable while reviewed.
function M.changes(changes, done)
  local ok_bridge, bridge = pcall(require, "coact.providers.pi_edit_bridge")
  local ok_session, patch_session = pcall(require, "coact.patch_session")
  if not ok_bridge or not ok_session then
    return done({ error = "coact.nvim's review is unavailable" })
  end
  local cwd = vim.fn.getcwd()
  local patches, locked = {}, {}
  for _, request in ipairs(changes) do
    local patch, change, err = bridge._build_patch(cwd, request)
    if not patch then
      return done({ error = err })
    end
    if patch ~= "" then
      table.insert(patches, change)
      local bufnr = vim.fn.bufnr(request.path)
      if bufnr ~= -1 and not vim.bo[bufnr].modifiable then
        vim.bo[bufnr].modifiable = true
        locked[bufnr] = true
      end
      if request.kind == "add" then
        vim.fn.mkdir(vim.fs.dirname(request.path), "p")
      end
    end
  end
  if #patches == 0 then
    return done({ accepted = 0, rejected = 0, reasons = {}, summary = "No changes." })
  end
  local function relock()
    for bufnr in pairs(locked) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modifiable = false
      end
    end
  end
  local session, open_err = patch_session.open({
    request_id = "coact-mode-" .. tostring(vim.uv.hrtime()),
    cwd = cwd,
    changes = patches,
    interactive = true,
    on_complete = function(summary, _, result)
      relock()
      result = result or {}
      local reasons = {}
      for _, decision in ipairs(result.decisions or {}) do
        if decision.status == "rejected" and decision.reason and not cancelled[decision.reason] then
          table.insert(reasons, decision.reason)
        end
      end
      if result.write_ok == false then
        return done({ error = "writing the reviewed files failed: " .. tostring(result.write_error) })
      end
      done({
        accepted = (result.accepted_hunks or 0) + (result.user_blocks or 0),
        rejected = result.rejected_hunks or 0,
        reasons = reasons,
        summary = summary,
      })
    end,
  })
  if not session then
    relock()
    done({ error = "Neovim review could not open: " .. tostring(open_err) })
  end
end

--- Review a plain file change from Pi's edit or write tool. request:
--- { path, oldContent, newContent, kind }. reply({ success, partial, summary }).
function M.edit(request, reply)
  M.changes({ request }, function(result)
    if result.error then
      return reply({ success = false, summary = result.error })
    end
    reply({
      success = result.accepted > 0 or (result.accepted == 0 and result.rejected == 0),
      partial = result.accepted > 0 and result.rejected > 0,
      summary = result.summary,
    })
  end)
end

return M
