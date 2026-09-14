local M = {}
function M.run()
  local state = require("coact.state")
  local render = require("coact.ui.render")
  local id = "pi:native-summary-folds"
  local items = {
    {
      id = "old-user",
      type = "userMessage",
      content = { { type = "text", text = "OLD_HISTORY_MUST_REMAIN_IN_STATE" } },
      status = "completed",
    },
    { id = "old-compact", type = "compactionSummary", text = "OLDER_CHECKPOINT", status = "completed" },
    { id = "old-answer", type = "agentMessage", text = "OLDER_ANSWER", status = "completed" },
    {
      id = "compact",
      type = "compactionSummary",
      text = "## Goal\nSUMMARY_BODY_TOKEN\n\nLast summary line",
      tokensBefore = 50000,
      status = "completed",
    },
    { id = "answer", type = "agentMessage", text = "AFTER_COMPACT_BEFORE_BRANCH", status = "completed" },
    { id = "branch", type = "branchSummary", text = "BRANCH_BODY_TOKEN\nBranch second line", status = "completed" },
  }
  local thread =
    state.update_thread_from_payload({ id = id, replaceTurns = true, turns = { { id = "turn", items = items } } })
  thread.generation = "idle"
  local original_items, original_order = vim.deepcopy(thread.items), vim.deepcopy(thread.item_order)
  local buf = vim.api.nvim_create_buf(false, true)
  state.bind_buffer(thread, buf)
  local previous_win = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(
    buf,
    true,
    { relative = "editor", row = 1, col = 1, width = 60, height = 12, style = "minimal" }
  )
  render.render(thread)
  local blocks = render.select_render_tree(thread)
  assert(
    #blocks == 3 and blocks[1].item_id == "compact" and blocks[2].item_id == "answer" and blocks[3].item_id == "branch"
  )
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(not text:find("OLDER_CHECKPOINT", 1, true) and not text:find("OLD_HISTORY_MUST", 1, true))
  assert(text:find("SUMMARY_BODY_TOKEN", 1, true) and text:find("BRANCH_BODY_TOKEN", 1, true))
  assert(text:find("AFTER_COMPACT_BEFORE_BRANCH", 1, true), "branch summary must not prune its prefix")
  assert(#thread.placeholder_marks == 0, "summary body must not be rendered as virtual lines")
  local folds = vim.tbl_filter(function(fold)
    return fold.summary_id ~= nil
  end, thread.folds)
  assert(#folds == 2)
  for _, fold in ipairs(folds) do
    assert(vim.fn.foldclosed(fold.start) == fold.start, "summaries default to native closed folds")
  end
  local caption = vim.fn.foldtextresult(folds[1].start)
  assert(
    caption:find("Context compacted", 1, true)
      and caption:find("50000 tokens", 1, true)
      and caption:find("za expand", 1, true),
    "native folds should use the original styled summary caption"
  )
  assert(vim.fn.foldtextresult(folds[2].start):find("Branch summary", 1, true))
  vim.api.nvim_win_set_width(win, 25)
  assert(vim.fn.strdisplaywidth(vim.fn.foldtextresult(folds[1].start)) <= 25, "fold captions must fit narrow windows")
  vim.api.nvim_win_set_width(win, 60)
  local gutters = {}
  local headers = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.namespace(), 0, -1, { details = true })) do
    local detail = mark[4]
    if detail.virt_text and detail.virt_text[1] then
      if detail.virt_text_pos == "inline" then
        gutters[mark[2] + 1] = detail.virt_text[1][1]
      end
      if detail.virt_text_pos == "overlay" then
        headers[mark[2] + 1] = detail.virt_text[1][1]
      end
    end
  end
  assert(
    headers[folds[1].start] == "◇ ▾ " and headers[folds[2].start] == "↳ ▾ ",
    "summary icons belong on the expanded headers"
  )
  for _, fold in ipairs(folds) do
    for row = fold.start + 1, fold.finish do
      assert(
        gutters[row] == "  │ ",
        "expanded summary should use the tool-block gutter on every line, including blank and final lines"
      )
    end
  end
  vim.api.nvim_win_set_cursor(win, { folds[1].start, 0 })
  render.toggle_under_cursor()
  assert(vim.fn.foldclosed(folds[1].start) == -1, "za must open the native fold")
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "SUMMARY_BODY_TOKEN" then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.cmd('normal! "zyiw')
      assert(vim.fn.getreg("z") == "SUMMARY_BODY_TOKEN", "summary text must be directly selectable/yankable")
    end
  end
  render.render(thread)
  assert(
    vim.fn.foldclosed(folds[1].start) == -1 and vim.fn.foldclosed(folds[2].start) == folds[2].start,
    "rerender must preserve independent native fold states"
  )
  vim.api.nvim_win_set_cursor(win, { folds[1].start, 0 })
  vim.cmd("normal! zc")
  render.render(thread)
  assert(vim.fn.foldclosed(folds[1].start) == folds[1].start, "native zc state must survive rerender")
  assert(
    vim.deep_equal(original_items, thread.items) and vim.deep_equal(original_order, thread.item_order),
    "compact pruning must be strictly render-only"
  )
  assert(#require("coact.events").normalize_thread(thread) == #items, "the full history remains available")
  vim.api.nvim_win_close(win, true)
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
  return thread
end
return M
