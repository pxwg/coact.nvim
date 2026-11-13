-- Reviews requested by the agent: compaction summaries and file changes.
local M = {}

local function close(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

--- Review a compaction summary in an editable float.
--- request: { reason, count, items = {{title, kind}}, summary }.
--- decide({ decision = "accept", summary } | { decision = "retry", prompt } | { decision = "cancel" }).
function M.compact(request, decide)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "org"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(request.summary or "", "\n", { plain = true }))
  local titles = {}
  for _, item in ipairs(request.items or {}) do
    table.insert(titles, item.title)
  end
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(math.max(8, vim.api.nvim_buf_line_count(buf) + 2), math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = (" Compact %d card%s (%s) "):format(
      request.count,
      request.count == 1 and "" or "s",
      request.reason or "manual"
    ),
    title_pos = "center",
    footer = " <C-s> accept · gr retry with a prompt · q cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace("coact_mode_review"), 0, 0, {
    virt_lines = { { { "Summarizes: " .. table.concat(titles, " · "), "Comment" } } },
    virt_lines_above = true,
  })
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  local decided = false
  local function finish(answer)
    if decided then
      return
    end
    decided = true
    close(win, buf)
    decide(answer)
  end
  local function accept()
    local summary = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(summary) == "" then
      vim.notify("Coact mode: the summary is empty", vim.log.levels.WARN)
      return
    end
    finish({ decision = "accept", summary = summary })
  end
  local function retry()
    vim.ui.input({ prompt = "Redo the summary with: " }, function(prompt)
      if prompt and vim.trim(prompt) ~= "" then
        finish({ decision = "retry", prompt = prompt })
      end
    end)
  end
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", accept, opts)
  vim.keymap.set("n", "gr", retry, opts)
  vim.keymap.set("n", "q", function()
    finish({ decision = "cancel" })
  end, opts)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish({ decision = "cancel" })
      end)
    end,
  })
end

--- Review a file change with coact.nvim's hunk review. request: { path,
--- oldContent, newContent, kind }. reply({ success, partial, summary }).
function M.edit(request, reply)
  local ok_bridge, bridge = pcall(require, "coact.providers.pi_edit_bridge")
  local ok_session, patch_session = pcall(require, "coact.patch_session")
  if not ok_bridge or not ok_session then
    return reply({ success = false, summary = "coact.nvim's review is unavailable" })
  end
  local cwd = vim.fn.getcwd()
  local patch, change, err = bridge._build_patch(cwd, request)
  if not patch then
    return reply({ success = false, summary = err })
  end
  if patch == "" then
    return reply({ success = true, summary = "No changes." })
  end
  local locked = {}
  local target = vim.fn.bufnr(request.path)
  if target ~= -1 and not vim.bo[target].modifiable then
    -- Reviewing is the interaction the call waits for; let it touch the file.
    vim.bo[target].modifiable = true
    locked[target] = true
  end
  if request.kind == "add" then
    vim.fn.mkdir(vim.fs.dirname(request.path), "p")
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
    changes = { change },
    interactive = true,
    on_complete = function(summary, success, result)
      relock()
      result = result or {}
      local accepted, rejected = result.accepted_hunks or 0, result.rejected_hunks or 0
      reply({
        success = success and result.write_ok ~= false and accepted > 0,
        partial = accepted > 0 and rejected > 0,
        summary = summary,
      })
    end,
  })
  if not session then
    relock()
    reply({ success = false, summary = "Neovim review could not open: " .. tostring(open_err) })
  end
end

return M
