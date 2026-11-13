-- One active thread at a time: submit a turn, stream it, write the answer
-- and trace back into the cards, and serve the extension's requests.
local config = require("coact.mode.config")
local lsp = require("coact.mode.lsp")
local pi = require("coact.mode.pi")
local review = require("coact.mode.review")
local ui = require("coact.mode.ui")
local workspace = require("coact.mode.workspace")

local M = {}

local state = {
  pi = nil, -- Pi client of the active thread
  thread = nil,
  root = nil,
  phase = "idle", -- idle | running | finishing | compacting
  card_buf = nil, -- the pinned card's buffer of the last call
  turn = nil, -- { submit_id, main, answer, bufnr, row, text, status }
  locked = {},
}

M._state = state

local function notify(message, level)
  vim.notify("Coact mode: " .. message, level or vim.log.levels.INFO)
end

local function labels()
  return config.get().labels
end

-- ---- call-time read-only cards ----

local function lock(bufnr)
  if not state.locked[bufnr] then
    state.locked[bufnr] = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = false
  end
end

local function unlock_all()
  for bufnr, was in pairs(state.locked) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modifiable = was
    end
  end
  state.locked = {}
end

local function idle()
  if state.turn then
    ui.clear_stream(state.turn.bufnr)
  end
  unlock_all()
  state.phase = "idle"
  state.turn = nil
  vim.cmd("redrawstatus")
end

function M.phase()
  return state.phase
end

function M.busy()
  return state.phase ~= "idle"
end

-- ---- helpers ----

local function format_diagnostics(diagnostics)
  local lines = {}
  for _, d in ipairs(diagnostics or {}) do
    if d.severity == 1 then
      table.insert(
        lines,
        ("%s:%d: %s"):format(vim.fn.fnamemodify(vim.uri_to_fname(d.uri), ":~:."), d.range.start.line + 1, d.message)
      )
    end
  end
  return #lines > 0 and table.concat(lines, "\n") or "the cards have errors"
end

--- The pinned thread card: callback(err, card) with card.bufnr loaded.
function M.pinned(bufnr, callback)
  lsp.request(bufnr, "coact/threads", {}, function(err, threads)
    if err then
      return callback(err)
    end
    local pinned = vim.tbl_filter(function(t)
      return t.pin == true
    end, threads or {})
    if #pinned == 0 then
      return callback("no card is pinned; pin one with :CoactMode pin")
    end
    if #pinned > 1 then
      return callback("more than one card is pinned")
    end
    local card = pinned[1]
    if type(card.thread) ~= "string" or not workspace.session_id(card.thread) then
      return callback("the pinned card has no valid THREAD_ID; pin it again")
    end
    card.bufnr = vim.fn.bufadd(vim.uri_to_fname(card.uri))
    vim.fn.bufload(card.bufnr)
    callback(nil, card)
  end)
end

local function save_baseline(bufnr, main, thread)
  lsp.request(bufnr, "coact/artifact", { main = main, requireQuestion = false }, function(err, result)
    if not err and result and result.ok and state.root then
      workspace.save_baseline(state.root, thread, result.cards)
    end
  end)
end

local function focus_card(bufnr, id)
  lsp.locate(bufnr, id, function(err, target, row)
    if err then
      return
    end
    local win = vim.fn.bufwinid(target)
    if win == -1 then
      return
    end
    -- Heading, drawer of three lines, then the body.
    local body = math.min(row + 5, vim.api.nvim_buf_line_count(target))
    vim.api.nvim_win_set_cursor(win, { body, 0 })
  end)
end

-- ---- extension requests ----

local handlers = {}

function handlers.error(request, reply)
  reply({})
  notify(("%s failed: %s"):format(request.stage or "request", request.message or "unknown error"), vim.log.levels.ERROR)
  if request.stage ~= "compact" or state.phase == "compacting" then
    idle()
  end
end

function handlers.finish(request, reply)
  local turn = state.turn
  if not turn or request.submitId ~= turn.submit_id then
    return reply({ error = "no matching Coact turn is waiting" })
  end
  lsp.request(turn.bufnr, "coact/answer", {
    answer = request.answer,
    text = request.text or "",
    entriesJson = request.entriesJson or "[]",
    labels = labels(),
  }, function(err, result)
    local ok, apply_err = false, err
    if not err then
      ui.clear_stream(turn.bufnr)
      ok, apply_err = lsp.apply(result.edits)
    end
    reply(ok and { ok = true } or { error = apply_err })
    idle()
    if not ok then
      return notify("could not write the answer: " .. tostring(apply_err), vim.log.levels.ERROR)
    end
    if request.stopReason == "error" then
      notify("the model failed: " .. tostring(request.errorMessage or "unknown error"), vim.log.levels.ERROR)
    elseif result.removed then
      notify("no answer was produced", vim.log.levels.WARN)
    end
    save_baseline(turn.bufnr, turn.main, state.thread)
    if result.draft and result.draft ~= vim.NIL then
      focus_card(turn.bufnr, result.draft)
    end
    ui.decorate(turn.bufnr)
  end)
end

function handlers.review(request, reply)
  review.edit(request, reply)
end

function handlers.compact(request, reply)
  local bufnr = state.turn and state.turn.bufnr or state.card_buf
  review.compact(request, function(decision)
    if decision.decision ~= "accept" then
      return reply(decision)
    end
    lsp.request(bufnr, "coact/compact", {
      main = request.main,
      count = request.count,
      summary = decision.summary,
      labels = labels(),
    }, function(err, result)
      if err then
        return reply({ error = err })
      end
      local ok, apply_err = lsp.apply(result.edits)
      if not ok then
        return reply({ error = apply_err })
      end
      local running = state.phase == "running"
      lsp.request(bufnr, "coact/artifact", { main = request.main, requireQuestion = running }, function(e, exported)
        if e or not exported.ok then
          return reply({ error = e or format_diagnostics(exported.diagnostics) })
        end
        workspace.save_baseline(state.root, state.thread, exported.cards)
        ui.decorate(bufnr)
        reply({ decision = "accept", artifactJson = exported.artifactJson })
      end)
    end)
  end)
end

function handlers.compacted(request, reply)
  reply({})
  idle()
  notify(request.accepted and "compacted into a synthesis card" or "compaction cancelled")
end

local function on_ui(message, respond)
  local method = message.method
  if method == "editor" and message.title == "coact-mode" then
    local ok, request = pcall(vim.json.decode, message.prefill or "", { luanil = { object = true, array = true } })
    local handler = ok and type(request) == "table" and handlers[request.op]
    if not handler then
      return respond({ value = vim.json.encode({ error = "unknown Coact request" }) })
    end
    local ok_call, call_err = pcall(handler, request, function(answer)
      respond({ value = vim.json.encode(answer or {}) })
    end)
    if not ok_call then
      respond({ value = vim.json.encode({ error = tostring(call_err) }) })
    end
  elseif method == "notify" then
    local levels = { error = vim.log.levels.ERROR, warning = vim.log.levels.WARN }
    vim.notify("Pi: " .. tostring(message.message), levels[message.notifyType] or vim.log.levels.INFO)
  elseif method == "confirm" then
    vim.ui.select(
      { "Yes", "No" },
      { prompt = (message.title or "") .. " " .. (message.message or "") },
      function(choice)
        respond({ confirmed = choice == "Yes" })
      end
    )
  elseif method == "select" then
    vim.ui.select(message.options or {}, { prompt = message.title }, function(choice)
      respond(choice and { value = choice } or { cancelled = true })
    end)
  elseif method == "input" or method == "editor" then
    vim.ui.input({ prompt = (message.title or "") .. ": ", default = message.prefill }, function(value)
      respond(value and { value = value } or { cancelled = true })
    end)
  end
end

-- ---- events ----

local function show(status)
  local turn = state.turn
  if turn then
    turn.status = status or turn.status
    ui.stream(turn.bufnr, turn.row, turn.status, turn.text)
  end
end

local function on_event(event)
  local turn = state.turn
  if not turn then
    return
  end
  local kind = event.type
  if kind == "message_start" and event.message and event.message.role == "assistant" then
    turn.text = ""
    show("thinking")
  elseif kind == "message_update" then
    local delta = event.assistantMessageEvent or {}
    if delta.type == "text_delta" then
      turn.text = (turn.text or "") .. (delta.delta or "")
      show("writing")
    elseif delta.type == "thinking_delta" then
      show("thinking")
    end
  elseif kind == "tool_execution_start" then
    show("running " .. tostring(event.toolName))
  elseif kind == "compaction_start" then
    show("compacting")
  elseif kind == "auto_retry_start" then
    show("retrying")
  elseif kind == "agent_settled" and state.phase == "running" then
    state.phase = "finishing"
    show("writing the answer")
    state.pi:prompt("/coact-finish", function(err)
      if err then
        notify("could not finish the turn: " .. err, vim.log.levels.ERROR)
        idle()
      end
    end)
  end
end

local function on_exit(code, stderr)
  local was = state.phase
  state.pi = nil
  state.thread = nil
  if was ~= "idle" then
    idle()
    local tail = vim.trim(stderr or ""):sub(-600)
    notify(("Pi exited (%s)%s"):format(tostring(code), tail ~= "" and (":\n" .. tail) or ""), vim.log.levels.ERROR)
  end
end

--- Pi for the thread, started or reused. Returns the client or nil, err.
local function ensure_pi(root, thread)
  if state.pi and state.pi:is_running() and state.thread == thread and state.root == root then
    return state.pi
  end
  if state.pi then
    state.pi:stop()
    state.pi = nil
  end
  local client, err
  client, err = pi.start({
    cwd = workspace.thread_cwd(root, thread),
    root = root,
    session_dir = workspace.sessions(root),
    session_id = workspace.session_id(thread),
    on_event = function(event)
      if state.pi == client then
        on_event(event)
      end
    end,
    on_ui = on_ui,
    on_exit = function(code, stderr)
      -- A replaced thread's process exiting must not touch the current one.
      if state.pi == client then
        on_exit(code, stderr)
      end
    end,
  })
  if not client then
    return nil, err
  end
  state.pi, state.thread, state.root = client, thread, root
  return client
end

-- ---- commands ----

--- Send the pinned thread's question. bufnr is any workspace buffer.
function M.submit(bufnr)
  if M.busy() then
    return notify("a call is already running; :CoactMode stop cancels it", vim.log.levels.WARN)
  end
  local root = workspace.root(bufnr)
  if not root then
    return notify("not in a Coact chat workspace", vim.log.levels.ERROR)
  end
  M.pinned(bufnr, function(err, card)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    lsp.request(card.bufnr, "coact/submit", { main = card.id, labels = labels() }, function(e, plan)
      if e then
        return notify(e, vim.log.levels.ERROR)
      end
      local ok, apply_err = lsp.apply(plan.edits)
      if not ok then
        return notify(apply_err, vim.log.levels.ERROR)
      end
      if plan.status == "draft" then
        focus_card(card.bufnr, plan.draft)
        return notify("write your question in the new question card, then submit")
      end
      local baseline = workspace.baseline(root, card.thread)
      lsp.request(
        card.bufnr,
        "coact/artifact",
        { main = card.id, requireQuestion = true, baseline = baseline },
        function(e2, exported)
          if e2 or not exported.ok then
            return notify("not sent: " .. (e2 or format_diagnostics(exported.diagnostics)), vim.log.levels.ERROR)
          end
          local client, start_err = ensure_pi(root, card.thread)
          if not client then
            return notify("could not start Pi: " .. tostring(start_err), vim.log.levels.ERROR)
          end
          local submit_id = tostring(os.time()) .. "-" .. tostring(vim.uv.hrtime() % 1000000)
          local request = workspace.request_file(root, submit_id, exported.artifactJson, {
            submitId = submit_id,
            answer = plan.answer,
          })
          lsp.locate(card.bufnr, plan.answer, function(_, _, row)
            state.phase = "running"
            state.card_buf = card.bufnr
            state.turn = {
              submit_id = submit_id,
              main = card.id,
              answer = plan.answer,
              bufnr = card.bufnr,
              row = row or 1,
              text = "",
              status = "sending",
            }
            lock(card.bufnr)
            show("sending")
            client:prompt("/coact-submit " .. request, function(prompt_err)
              if prompt_err then
                notify("Pi rejected the turn: " .. prompt_err, vim.log.levels.ERROR)
                idle()
              end
            end)
          end)
        end
      )
    end)
  end)
end

function M.stop()
  if state.phase ~= "running" or not state.pi then
    return notify("nothing is running")
  end
  show("stopping")
  state.pi:request("abort", {}, function(err)
    if err then
      notify("stop failed: " .. err, vim.log.levels.ERROR)
    end
  end)
end

--- Compact the pinned thread between turns.
function M.compact(bufnr, instructions)
  if M.busy() then
    return notify("compaction during a run happens automatically when the context fills up", vim.log.levels.WARN)
  end
  local root = workspace.root(bufnr)
  if not root then
    return notify("not in a Coact chat workspace", vim.log.levels.ERROR)
  end
  M.pinned(bufnr, function(err, card)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    lsp.request(card.bufnr, "coact/artifact", { main = card.id, requireQuestion = false }, function(e, exported)
      if e or not exported.ok then
        return notify("cannot compact: " .. (e or format_diagnostics(exported.diagnostics)), vim.log.levels.ERROR)
      end
      local client, start_err = ensure_pi(root, card.thread)
      if not client then
        return notify("could not start Pi: " .. tostring(start_err), vim.log.levels.ERROR)
      end
      local request = workspace.request_file(root, "compact-" .. tostring(os.time()), exported.artifactJson, {
        instructions = instructions,
      })
      state.phase = "compacting"
      state.card_buf = card.bufnr
      lock(card.bufnr)
      notify("summarizing…")
      client:prompt("/coact-compact " .. request, function(prompt_err)
        if prompt_err then
          notify("Pi rejected compaction: " .. prompt_err, vim.log.levels.ERROR)
          idle()
        end
      end)
    end)
  end)
end

--- Stop the thread's Pi process (pinning another card switches threads).
function M.shutdown()
  if state.pi then
    state.pi:stop()
    state.pi = nil
  end
  idle()
end

--- Called after a pin changes the thread: an idle Pi of another thread exits.
function M.thread_changed(thread)
  if state.pi and state.thread ~= thread and not M.busy() then
    state.pi:stop()
    state.pi = nil
    state.thread = nil
  end
end

--- The active thread's card buffer, for commands run from other buffers.
function M.card_buffer()
  local bufnr = state.card_buf
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

function M.status()
  local labels_by_phase = { running = "running", finishing = "writing", compacting = "compacting" }
  return labels_by_phase[state.phase]
end

return M
