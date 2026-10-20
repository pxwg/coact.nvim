-- Side discussions ("btw" questions) on Pi threads.
--
-- A side discussion is a branch in the main thread's own Pi session tree: once
-- the main thread is idle we navigate its leaf to the end of the selected turn,
-- route the shared execution unit's events to a separate side thread, and
-- navigate back to the original main leaf when the discussion closes. The
-- side branch stays in the session tree afterwards.
local config = require("coact.config")
local state = require("coact.state")
local source_map = require("coact.source_map")
local util = require("coact.util")

local M = {}

local by_main = {} -- main thread id -> side thread id
local waiters = {} -- main thread id -> pending open
local next_side = 0

local busy_generations = {
  submitted = true,
  waiting_backend = true,
  streaming = true,
  summarizing = true,
  tool_running = true,
  patch_review = true,
  reconciling = true,
  cancelling = true,
}

local context_open = "<coact-side-context>"
local context_close = "</coact-side-context>"

local function side_opts()
  local ui = config.get().ui or {}
  return ui.side or {}
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

function M.is_side(thread)
  return type(thread) == "table" and type(thread.side) == "table"
end

function M.get(side_id)
  local thread = side_id and state.get_thread(side_id) or nil
  return M.is_side(thread) and thread or nil
end

function M.for_main(main_id)
  return main_id and M.get(by_main[main_id]) or nil
end

-- A thread is locked while a side discussion owns its execution unit, and a
-- side thread only accepts prompts while its branch is open.
function M.lock_message(thread)
  if not thread then
    return nil
  end
  if M.is_side(thread) then
    if thread.side.status ~= "open" then
      return "the side discussion is " .. tostring(thread.side.status) .. "; wait before asking"
    end
    return nil
  end
  if thread.side_lock then
    return "A side discussion is open on this thread; finish it with Q in the side window or :Coact side-close"
  end
  return nil
end

local function restore_active(thread_id)
  if thread_id and state.get_thread(thread_id) then
    state.active_thread_id = thread_id
  end
end

local function idle(thread)
  if not thread then
    return false
  end
  if thread.active_turn_id or busy_generations[thread.generation] or thread.pi_agent_active then
    return false
  end
  if thread.lifecycle == "starting" or thread.sync == "hydrating" or thread.sync == "starting" then
    return false
  end
  if #state.get_thread_pending_requests(thread) > 0 then
    return false
  end
  local rpc = require("coact.rpc")
  return (rpc.pending_count(thread.id) or 0) == 0
end

M._idle = idle

local function pi_ready(main)
  if not require("coact.providers").is("pi") then
    return nil, "side discussions are only available for the Pi adapter"
  end
  if not main or not tostring(main.id):match("^pi:") then
    return nil, "side discussions need a Pi chat thread"
  end
  local bridge = require("coact.providers.pi_edit_bridge")
  if not bridge.enabled() then
    return nil, "side discussions need the coact.nvim Pi extension (pair edit mode)"
  end
  if not require("coact.rpc").is_running(main.id) then
    return nil, "the Pi execution unit for this thread is not running"
  end
  return true
end

-- Anchor capture ----------------------------------------------------------

local function ordered_marks(bufnr)
  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
  if start_mark[1] == 0 or end_mark[1] == 0 then
    return nil
  end
  if start_mark[1] > end_mark[1] or (start_mark[1] == end_mark[1] and start_mark[2] > end_mark[2]) then
    start_mark, end_mark = end_mark, start_mark
  end
  return start_mark, end_mark
end

-- The assistant text atom containing rows first..last, with its source lines.
local function text_atom(thread, first, last)
  for _, atom in ipairs(thread.render_atoms or {}) do
    local block = atom.block
    if block and block.type == "AssistantBlock" and atom.text_start then
      local lines = util.split_lines(block.text or "")
      local text_last = atom.text_start + #lines - 1
      if first >= atom.text_start and last <= text_last then
        return atom, lines
      end
    end
  end
  return nil
end

-- Map a chat selection to UTF-16 offsets in the verbatim text of one Pi
-- assistant text block. Transcript rows hold that text unchanged; anything
-- else (headers, folds, tool blocks, summaries) cannot anchor a discussion.
local function chat_anchor(bufnr, _, mode)
  local thread = state.thread_for_buf(bufnr)
  if not thread then
    return nil, "current buffer is not a Coact chat"
  end
  if M.is_side(thread) then
    return nil, "select text in the main chat, not in a side discussion"
  end
  if mode == "\022" then
    return nil, "blockwise selections cannot anchor a side discussion"
  end
  local start_mark, end_mark = ordered_marks(bufnr)
  if not start_mark then
    return nil, "no Visual selection found"
  end
  local atom, lines = text_atom(thread, start_mark[1], end_mark[1])
  if not atom then
    return nil, "select text within a single assistant reply"
  end
  local first_index = start_mark[1] - atom.text_start + 1
  local last_index = end_mark[1] - atom.text_start + 1
  local shown = vim.api.nvim_buf_get_lines(bufnr, start_mark[1] - 1, end_mark[1], false)
  for index, line in ipairs(shown) do
    if line ~= lines[first_index + index - 1] then
      return nil, "the reply is still changing; retry when it has finished"
    end
  end
  local start_col, end_col
  if mode == "V" then
    start_col, end_col = 0, #lines[last_index]
  else
    local last_line = lines[last_index]
    start_col = math.min(start_mark[2], #lines[first_index])
    end_col = end_mark[2] >= #last_line and #last_line
      or end_mark[2] + source_map.char_len(last_line:byte(end_mark[2] + 1))
  end
  local offsets = source_map.line_offsets(lines)
  local text = atom.block.text
  local first = offsets[first_index] + start_col
  local last = offsets[last_index] + end_col
  if last <= first then
    return nil, "the selection is empty"
  end
  local quote = text:sub(first + 1, last)
  if util.trim(quote) == "" then
    return nil, "the selection is empty"
  end
  local item = atom.block.raw or (thread.items and thread.items[tostring(atom.block.item_id)]) or {}
  local content_index = tonumber(util.value(item.piContentIndex))
  if not content_index then
    return nil, "this reply has no Pi content position"
  end
  return {
    kind = "chat",
    main_thread_id = thread.id,
    item_id = atom.block.item_id and tostring(atom.block.item_id) or nil,
    entry_id = require("coact.buffers").block_tree_entry_id(thread, atom.block),
    block = content_index,
    start = source_map.utf16(text, first),
    ["end"] = source_map.utf16(text, last),
    quote = quote,
    start_line = start_mark[1],
    end_line = end_mark[1],
  }
end

local function main_for_source()
  local active = state.get_thread(state.active_thread_id)
  if M.is_side(active) then
    active = state.get_thread(active.side.main_thread_id)
  end
  if active and tostring(active.id):match("^pi:") then
    return active
  end
  for _, thread in pairs(state.threads) do
    if tostring(thread.id):match("^pi:") and require("coact.rpc").is_running(thread.id) then
      return thread
    end
  end
  return nil
end

local function file_anchor(bufnr, winid, mode)
  local context = require("coact.context")
  local selected = context._capture_selection(bufnr, mode, winid)
  if not selected then
    return nil, "no Visual selection found"
  end
  local main = main_for_source()
  if not main then
    return nil, "open a Pi chat before asking a side question about a file"
  end
  return {
    kind = "file",
    main_thread_id = main.id,
    entry_id = nil,
    quote = selected.content,
    filename = context.display_path(selected.filename),
    filetype = selected.filetype,
    start_line = selected.start_line,
    end_line = selected.end_line,
    source_bufnr = bufnr,
    source_winid = winid,
  }
end

-- Must run after leaving Visual mode so the '< and '> marks are current.
function M.capture(bufnr, winid, mode)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  winid = winid or vim.api.nvim_get_current_win()
  mode = mode or vim.fn.visualmode()
  if vim.b[bufnr].coact_role == "history" then
    return chat_anchor(bufnr, winid, mode)
  end
  if require("coact.context").is_coact_buffer(bufnr) then
    return nil, "select text in the main chat history or in a source buffer"
  end
  return file_anchor(bufnr, winid, mode)
end

-- Input -------------------------------------------------------------------

local function fence_for(text)
  local longest = 2
  for run in tostring(text):gmatch("~+") do
    longest = math.max(longest, #run)
  end
  return string.rep("~", longest + 1)
end

function M.context_text(anchor)
  local quote = tostring(anchor.quote or ""):gsub(vim.pesc(context_close), "<\\/coact-side-context>")
  local lines = { context_open, "This is a side discussion branched from the conversation above." }
  if anchor.kind == "file" then
    table.insert(
      lines,
      ("The user selected this passage from %s (L%d-L%d):"):format(
        anchor.filename or "a file",
        anchor.start_line or 0,
        anchor.end_line or 0
      )
    )
  else
    table.insert(lines, "The user selected this passage from an earlier message in the conversation:")
  end
  local fence = fence_for(quote)
  vim.list_extend(lines, {
    fence .. (anchor.kind == "file" and (anchor.filetype or "") or "markdown"),
    quote,
    fence,
    "Answer the user's questions about this passage. Keep the main task in mind, but do not continue it and do not modify files unless the user explicitly asks.",
    context_close,
    "",
    "",
  })
  return table.concat(lines, "\n")
end

-- The passage travels with the first side prompt only; later prompts already
-- have it in the branch context.
function M.decorate_input(thread, input)
  if not M.is_side(thread) or thread.side.context_sent then
    return input
  end
  thread.side.context_sent = true
  local decorated = vim.deepcopy(input)
  table.insert(decorated, 1, { type = "text", text = M.context_text(thread.side.anchor), text_elements = {} })
  return decorated
end

function M.strip_context(text)
  text = tostring(text or "")
  if text:sub(1, #context_open) ~= context_open then
    return text
  end
  local _, close_end = text:find(context_close, 1, true)
  if not close_end then
    return text
  end
  return (text:sub(close_end + 1):gsub("^%s+", ""))
end

-- Lifecycle ----------------------------------------------------------------

local function render(thread)
  local buffers = require("coact.buffers")
  if thread and valid_buf(thread.bufnr) then
    buffers.schedule_render(thread.id)
    buffers.refresh_composer(thread)
  end
end

local function title_for(anchor)
  local first = vim.split(util.trim(anchor.quote or ""), "\n", { plain = true })[1] or ""
  first = first:gsub("%s+", " ")
  if vim.fn.strchars(first) > 48 then
    first = vim.fn.strcharpart(first, 0, 47) .. "…"
  end
  return "Side: " .. first
end

local function release(side, main)
  local main_id = side and side.side.main_thread_id or (main and main.id)
  if side then
    require("coact.providers.pi_rpc").unroute_side(side.id)
    if by_main[main_id] == side.id then
      by_main[main_id] = nil
    end
  end
  if main then
    main.side_lock = nil
    render(main)
  end
  restore_active(main_id)
end

local function discard_ui(side)
  require("coact.ui.side").close(side)
  for _, bufnr in ipairs({ side.prompt_bufnr, side.bufnr }) do
    if valid_buf(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  side.bufnr, side.prompt_bufnr, side.winid, side.prompt_winid = nil, nil, nil, nil
end

local function start(anchor, main)
  next_side = next_side + 1
  local session = tostring(main.id):gsub("^pi:", "")
  local side_id = ("pi-side:%s:%d"):format(session, next_side)
  main.side_lock = side_id
  by_main[main.id] = side_id
  local side = state.ensure_thread(side_id, {
    adapter_context = main.adapter_context,
    cwd = main.cwd,
    title = title_for(anchor),
    status = "starting",
    lifecycle = "starting",
    sync = "starting",
    sync_message = "Opening a side branch in the session tree…",
    token_usage = main.token_usage,
    thread = { id = side_id, name = title_for(anchor), cwd = main.cwd },
    side = {
      main_thread_id = main.id,
      anchor = anchor,
      status = "opening",
      context_sent = false,
    },
  })
  side.context_bufnr = anchor.source_bufnr or main.context_bufnr
  side.context_winid = anchor.source_winid or main.context_winid
  restore_active(side_id)
  local buffers = require("coact.buffers")
  buffers.open(side_id)
  buffers.enter_compose(side, { startinsert = false })
  M._resolve_entry(anchor, main, function(resolve_err)
    if resolve_err then
      side.side.status = "failed"
      release(side, main)
      discard_ui(side)
      util.notify("side discussion failed to open: " .. resolve_err, vim.log.levels.ERROR)
      return
    end
    M._open_branch(side, main)
  end)
  return side
end

-- Streamed replies learn their Pi entry id from a branch snapshot.
function M._resolve_entry(anchor, main, done)
  if anchor.kind ~= "chat" or anchor.entry_id then
    done(nil)
    return
  end
  require("coact.rpc").request("thread/treeSnapshot", { threadId = main.id }, function(err)
    local item = anchor.item_id and main.items and main.items[anchor.item_id] or nil
    anchor.entry_id = item and util.value(item.treeEntryId or item.tree_entry_id) or nil
    if anchor.entry_id then
      anchor.entry_id = tostring(anchor.entry_id)
      done(nil)
    else
      done(err and tostring(err.message or err) or "no saved Pi entry for the selected reply")
    end
  end)
end

local function open_params(anchor, main)
  local params = { threadId = main.id }
  if anchor.kind == "chat" then
    params.anchor = {
      entryId = anchor.entry_id,
      block = anchor.block,
      start = anchor.start,
      ["end"] = anchor["end"],
      quote = anchor.quote,
    }
  else
    params.source = {
      file = anchor.filename,
      startLine = anchor.start_line,
      endLine = anchor.end_line,
      quote = anchor.quote,
    }
  end
  return params
end

function M._open_branch(side, main)
  local side_id = side.id
  require("coact.rpc").request("thread/side/open", open_params(side.side.anchor, main), function(err, result)
    if err then
      side.side.status = "failed"
      release(side, main)
      discard_ui(side)
      util.notify("side discussion failed to open: " .. tostring(err.message or err), vim.log.levels.ERROR)
      return
    end
    local _, route_err = require("coact.providers.pi_rpc").route_side(side_id, main.id)
    if route_err then
      side.side.status = "failed"
      side.side.origin_leaf_id = result.originLeafId
      -- The leaf already moved; return it before giving up.
      M._close_branch(side, main)
      util.notify("side discussion failed to open: " .. route_err, vim.log.levels.ERROR)
      return
    end
    side.side.status = "open"
    side.side.origin_leaf_id = result.originLeafId
    side.side.branch_point_id = result.branchPointId
    side.side.anchor.prefix = result.prefix
    side.side.anchor.suffix = result.suffix
    side.lifecycle = "ready"
    side.sync = "clean"
    side.sync_message = nil
    side.status = "ready"
    render(side)
    if require("coact.buffers").is_prompt_buffer(vim.api.nvim_get_current_buf()) then
      vim.cmd("startinsert!")
    end
  end)
end

local function cancel_wait(main_id)
  local waiter = waiters[main_id]
  waiters[main_id] = nil
  if waiter and waiter.timer then
    waiter.timer:stop()
    waiter.timer:close()
  end
  return waiter ~= nil
end

M.cancel_wait = cancel_wait

local function wait_for_idle(main, callback)
  if idle(main) then
    callback()
    return
  end
  local timeout = tonumber(side_opts().wait_timeout_ms) or 0
  local started = vim.uv.now()
  local timer = vim.uv.new_timer()
  waiters[main.id] = { timer = timer }
  util.notify("side discussion will open when the main thread finishes its current work")
  timer:start(
    150,
    150,
    vim.schedule_wrap(function()
      if not waiters[main.id] or waiters[main.id].timer ~= timer then
        return
      end
      local current = state.get_thread(main.id)
      if current and idle(current) then
        cancel_wait(main.id)
        callback()
      elseif not current or (timeout > 0 and vim.uv.now() - started > timeout) then
        cancel_wait(main.id)
        util.notify("side discussion cancelled: the main thread did not become idle", vim.log.levels.WARN)
      end
    end)
  )
end

function M.open(anchor)
  if type(anchor) ~= "table" then
    return nil
  end
  local main = state.get_thread(anchor.main_thread_id)
  local ok, err = pi_ready(main)
  if not ok then
    util.notify(err, vim.log.levels.WARN)
    return nil
  end
  local existing = M.for_main(main.id)
  if existing then
    util.notify("a side discussion is already open on this thread; close it first (Q)", vim.log.levels.WARN)
    M.reveal(existing)
    return nil
  end
  if waiters[main.id] then
    util.notify("a side discussion is already waiting for this thread", vim.log.levels.WARN)
    return nil
  end
  wait_for_idle(main, function()
    local current = state.get_thread(main.id)
    local ready, ready_err = pi_ready(current)
    if not ready then
      util.notify("side discussion cancelled: " .. ready_err, vim.log.levels.WARN)
      return
    end
    if current.side_lock or not idle(current) then
      util.notify("side discussion cancelled: the main thread became busy", vim.log.levels.WARN)
      return
    end
    start(anchor, current)
  end)
  return true
end

-- Visual-mode entry point: leave Visual mode first so the marks are set.
function M.ask_visual()
  local mode = vim.fn.mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if mode:match("^[vV\022]") then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  else
    mode = vim.fn.visualmode()
  end
  local anchor, err = M.capture(bufnr, winid, mode:sub(1, 1))
  if not anchor then
    util.notify(err or "no selection for a side question", vim.log.levels.WARN)
    return nil
  end
  return M.open(anchor)
end

function M.reveal(side)
  side = M.get(type(side) == "table" and side.id or side)
  if not side then
    return false
  end
  local buffers = require("coact.buffers")
  if not (side.winid and vim.api.nvim_win_is_valid(side.winid)) then
    buffers.open(side.id)
  end
  buffers.enter_compose(side, { startinsert = false })
  return true
end

local function refresh_main(main)
  require("coact.rpc").request("thread/read", { threadId = main.id }, function(err, result)
    if err or not (result and result.thread) then
      return
    end
    local thread = state.update_thread_from_payload(result.thread)
    restore_active(main.id)
    if thread and valid_buf(thread.bufnr) then
      require("coact.buffers").schedule_render(thread.id)
    end
  end)
end

M._close_branch = function(side, main, callback, opts)
  callback = callback or function() end
  opts = opts or {}
  side.side.status = "closing"
  local pi_rpc = require("coact.providers.pi_rpc")
  pi_rpc.unroute_side(side.id)
  require("coact.rpc").request("thread/side/close", {
    threadId = main.id,
    originLeafId = side.side.origin_leaf_id,
    annotate = opts.annotate == true,
  }, function(err, result)
    if err and opts.annotate and tostring(err.message or err):find("did not submit", 1, true) then
      -- Nothing moved: keep the discussion open so the user can continue.
      pi_rpc.route_side(side.id, main.id)
      side.side.status = "open"
      require("coact.rpc").request("thread/side/disarm", { threadId = main.id }, function() end)
      render(side)
      callback(err)
      return
    end
    if err then
      -- Keep the main thread locked: its leaf may still be on the side branch.
      side.side.status = "close_failed"
      util.notify(
        "side discussion could not return to the main branch: "
          .. tostring(err.message or err)
          .. " (retry with :Coact side-close)",
        vim.log.levels.ERROR
      )
      callback(err)
      return
    end
    side.side.status = "closed"
    side.side.side_leaf_id = result and result.sideLeafId
    side.side.annotation_index = result and result.annotationIndex
    release(side, main)
    discard_ui(side)
    refresh_main(main)
    callback(nil, result)
  end)
end

local function has_answer(thread)
  for _, id in ipairs(thread.item_order or {}) do
    local item = thread.items[id]
    if item and item.type == "agentMessage" and util.trim(item.text or "") ~= "" then
      return true
    end
  end
  return false
end

local annotate_prompt = table.concat({
  "I'm satisfied with this side discussion.",
  "Call submit_annotation once now with my question, a brief answer, a short summary of what I learned,",
  "and the complete final explanation, written in the language I used. Then stop.",
}, " ")

-- Ask the model to record the discussion as an annotation, then close the
-- side branch and write the annotation into the main branch.
function M.annotate(side_or_id)
  local side = M.get(type(side_or_id) == "table" and side_or_id.id or side_or_id)
  if not side then
    local active = state.get_thread(state.active_thread_id)
    side = M.is_side(active) and active or M.for_main(active and active.id)
  end
  if not side then
    util.notify("no open side discussion", vim.log.levels.WARN)
    return false
  end
  local main = state.get_thread(side.side.main_thread_id)
  if side.side.status ~= "open" or not idle(side) or not main then
    util.notify("wait for the side discussion to finish before annotating", vim.log.levels.WARN)
    return false
  end
  if not has_answer(side) then
    util.notify("ask something in the side discussion before annotating", vim.log.levels.WARN)
    return false
  end
  local rpc = require("coact.rpc")
  side.side.status = "annotating"
  render(side)
  local aborted = false
  local function fail(message)
    aborted = true
    side.side.status = "open"
    render(side)
    rpc.request("thread/side/disarm", { threadId = main.id }, function() end)
    util.notify("annotation failed: " .. message, vim.log.levels.WARN)
  end
  rpc.request("thread/side/arm", { threadId = main.id }, function(err)
    if err then
      fail(tostring(err.message or err))
      return
    end
    side.side.status = "open"
    local turns_before = #(side.turn_order or {})
    require("coact").submit_text(annotate_prompt, side.id, {
      on_error = function(submit_err)
        fail(tostring(submit_err and submit_err.message or submit_err))
      end,
    })
    if side.side.status ~= "open" then
      return
    end
    side.side.status = "annotating"
    render(side)
    local started, begun = vim.uv.now(), false
    local timer = vim.uv.new_timer()
    timer:start(
      150,
      150,
      vim.schedule_wrap(function()
        begun = begun or not idle(side) or #(side.turn_order or {}) > turns_before
        local timed_out = vim.uv.now() - started > 600000
        if not ((begun and idle(side)) or timed_out or aborted) then
          return
        end
        timer:stop()
        timer:close()
        if aborted then
          return
        end
        if timed_out then
          fail("the model did not finish")
          return
        end
        side.side.status = "open"
        M._close_branch(side, main, function(close_err, result)
          if close_err then
            util.notify("annotation failed: " .. tostring(close_err.message or close_err), vim.log.levels.WARN)
          else
            util.notify(("side note [%s] added to the main branch"):format(tostring(result.annotationIndex or "?")))
          end
        end, { annotate = true })
      end)
    )
  end)
  return true
end

function M.close(side_or_id)
  local side = M.get(type(side_or_id) == "table" and side_or_id.id or side_or_id)
  if not side then
    local active = state.get_thread(state.active_thread_id)
    side = M.is_side(active) and active or M.for_main(active and active.id)
  end
  if not side then
    local active = state.active_thread_id
    if active and cancel_wait(active) then
      util.notify("pending side discussion cancelled")
      return true
    end
    util.notify("no open side discussion", vim.log.levels.WARN)
    return false
  end
  local main = state.get_thread(side.side.main_thread_id)
  if not main then
    release(side, nil)
    discard_ui(side)
    return true
  end
  if side.side.status == "opening" or side.side.status == "closing" or side.side.status == "annotating" then
    util.notify("the side discussion is still " .. side.side.status, vim.log.levels.WARN)
    return false
  end
  local function finish()
    M._close_branch(side, main, function(err)
      if not err then
        util.notify("side discussion closed; its branch stays in the session tree")
      end
    end)
  end
  if idle(side) then
    finish()
    return true
  end
  side.side.status = "stopping"
  if side.active_turn_id then
    require("coact.rpc").request("turn/interrupt", { threadId = side.id, turnId = side.active_turn_id }, function() end)
  end
  local timer = vim.uv.new_timer()
  local started = vim.uv.now()
  timer:start(
    150,
    150,
    vim.schedule_wrap(function()
      if idle(side) or vim.uv.now() - started > 30000 then
        timer:stop()
        timer:close()
        side.side.status = "open"
        finish()
      end
    end)
  )
  return true
end

-- Slash commands typed in a side composer. Returns true when handled.
function M.dispatch_slash(thread, text)
  if not M.is_side(thread) then
    return false
  end
  local name = tostring(text or ""):match("^%s*/(%S+)%s*$")
  if name == "close" or name == "done" then
    M.close(thread)
    return true
  end
  if name == "annotate" then
    M.annotate(thread)
    return true
  end
  if name == "quote" then
    require("coact.ui.side").quote(thread)
    return true
  end
  if tostring(text or ""):match("^%s*/") then
    util.notify("only /annotate, /quote and /close are available in a side discussion", vim.log.levels.WARN)
    return true
  end
  return false
end

function M._reset()
  for main_id in pairs(waiters) do
    cancel_wait(main_id)
  end
  by_main = {}
end

return M
