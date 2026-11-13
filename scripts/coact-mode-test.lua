-- Coact mode end to end: real Pi with the Coact extension, the coact-zk
-- language server, and a scripted model server. Run from the plugin root:
--   nvim --headless -u NONE -c 'set rtp+=.' -l scripts/coact-mode-test.lua
local plugin = vim.fn.getcwd()
-- Absolute, so modules still load after the test changes directory.
vim.opt.rtp:prepend(plugin)
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local log = tmp .. "/model.log"

local function fail(message)
  io.stderr:write("FAIL: " .. message .. "\n")
  local ok, run = pcall(require, "coact.mode.run")
  if ok then
    local s = run._state
    io.stderr:write(("phase=%s status=%s\n"):format(s.phase, s.turn and s.turn.status or "-"))
    if s.pi then
      io.stderr:write("pi stderr: " .. table.concat(s.pi.stderr):sub(-2000) .. "\n")
    end
  end
  if vim.uv.fs_stat(log) then
    local lines = vim.fn.readfile(log)
    io.stderr:write("last model request: " .. (lines[#lines] or ""):sub(-1500) .. "\n")
  end
  os.exit(1)
end

local function check(cond, message)
  if not cond then
    fail(message)
  end
  print("ok - " .. message)
end

local function wait(ms, predicate, message)
  if not vim.wait(ms, predicate, 20) then
    fail("timed out: " .. message)
  end
end

local url
local server = vim.system({ "node", plugin .. "/scripts/coact-mode-model-server.mjs" }, {
  env = { COACT_TEST_LOG = log },
  stdout = function(_, data)
    if data and not url then
      url = vim.trim(data)
    end
  end,
})
wait(5000, function()
  return url ~= nil
end, "model server")

local mode = require("coact.mode")
local run = require("coact.mode.run")
mode.setup({
  workspace_root = tmp .. "/workspaces",
  keymaps = false,
  compact = { keep_recent_tokens = 20 },
  pi = {
    model = "coact-test/echo",
    args = {
      "--no-extensions",
      "--extension",
      plugin .. "/scripts/coact-mode-test-provider.ts",
      "--no-skills",
      "--no-context-files",
      "--no-prompt-templates",
    },
    env = { COACT_TEST_BASE_URL = url },
  },
})

local root = mode.init(tmp .. "/ws")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "* Monads", "What is a monad?" })
vim.cmd("silent write")
mode.attach(buf)
wait(5000, function()
  return require("coact.mode.lsp").client(buf) ~= nil and require("coact.mode.lsp").client(buf).initialized
end, "language server")

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function requests()
  local out = {}
  for line in io.lines(log) do
    table.insert(out, vim.json.decode(line))
  end
  return out
end

local function last_request()
  local all = requests()
  return all[#all]
end

local function contents(request)
  local out = {}
  for _, m in ipairs(request.messages) do
    local c = m.content
    if type(c) == "table" then
      local parts = {}
      for _, p in ipairs(c) do
        table.insert(parts, p.text or "")
      end
      c = table.concat(parts)
    end
    local calls = {}
    for _, call in ipairs(m.tool_calls or {}) do
      table.insert(calls, call["function"].name)
    end
    table.insert(
      out,
      m.role
        .. ": "
        .. tostring(c == vim.NIL and "" or c)
        .. (#calls > 0 and (" [" .. table.concat(calls, ",") .. "]") or "")
    )
  end
  return out
end

local function joined(request)
  return table.concat(contents(request), "\n")
end

local function settle(message)
  wait(30000, function()
    return not run.busy()
  end, message)
end

local function submit(message)
  mode.submit()
  wait(5000, function()
    return run.busy()
  end, "submission of " .. message)
  settle(message)
end

-- Write into the empty line of the last question card.
local function ask(question)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local heading
  for i, line in ipairs(lines) do
    if line == "** Question" then
      heading = i
    end
  end
  if not heading then
    fail("no question card to write in")
  end
  local row = heading
  while lines[row] ~= ":END:" do
    row = row + 1
  end
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { question })
end

-- 1. pin the card, then send its text as the first question
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mode.pin()
wait(5000, function()
  return text():find(":PIN: true", 1, true) ~= nil
end, "pin")
local thread = text():match(":THREAD_ID: (pi:[%w-]+)")
check(thread ~= nil, "pin binds a thread id")
submit("first turn")
local body = text()
check(body:find(":CONTEXT_KIND: user\n:END:\nWhat is a monad?", 1, true) ~= nil, "the question became a user card")
check(body:find("Echo: What is a monad?", 1, true) ~= nil, "the answer was written into its card")
check(body:find("%[%[id:[^%]]+%]%[Trace%]%]") ~= nil, "the answer links its trace")
check(vim.bo[buf].modifiable, "the card is editable again")
check(not vim.bo[buf].modified, "the card file is saved")
local traces = vim.fn.glob(root .. "/trace/*.org", false, true)
check(#traces == 1, "a trace file was written")
local first = joined(last_request())
check(
  first:find("user: What is a monad?", 1, true) ~= nil and select(2, first:gsub("user: What is a monad%?", "")) == 1,
  "the model saw the question once"
)
check(first:find("Coact mode", 1, true) ~= nil, "the Coact system prompt section was sent")

-- Language features over the cards.
local lsp_mod = require("coact.mode.lsp")
local function request_sync(method, params)
  local result
  lsp_mod.request(buf, method, params, function(err, value)
    result = err and { error = err } or (value or vim.NIL)
  end)
  wait(5000, function()
    return result ~= nil
  end, method)
  return result
end
local function find_line(pattern)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(pattern) then
      return i
    end
  end
end
local trace_row = find_line("^%[%[id:.*%]%[Trace%]%]$")
local hover = request_sync("textDocument/hover", lsp_mod.position(buf, { trace_row, 4 }))
check(hover ~= vim.NIL and hover.contents.value:find("trace", 1, true) ~= nil, "hovering a trace link shows the record")
local defn = request_sync("textDocument/definition", lsp_mod.position(buf, { trace_row, 4 }))
check(defn ~= vim.NIL and defn.uri:find("/trace/", 1, true) ~= nil, "a trace link goes to its card")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "[[id:" })
local completion =
  request_sync("textDocument/completion", lsp_mod.position(buf, { vim.api.nvim_buf_line_count(buf), 5 }))
check(type(completion) == "table" and #completion > 3, "[[id: completes card identities")
vim.api.nvim_buf_set_lines(buf, -2, -1, false, {})

-- 2. revise the answer, then ask a follow-up
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, line in ipairs(lines) do
  if line == "Echo: What is a monad?" then
    vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "A monoid in the category of endofunctors." })
  end
end
ask("Why endofunctors?")
submit("revised turn")
local second = joined(last_request())
check(
  second:find("assistant: A monoid in the category of endofunctors.", 1, true) ~= nil,
  "the revised answer replaced Pi's history"
)
check(
  second:find("assistant: Echo: What is a monad?", 1, true) == nil,
  "the old answer was not sent as the assistant's turn"
)
check(second:find("revised the conversation cards", 1, true) ~= nil, "a revision note preceded the question")
check(text():find("Echo: Why endofunctors?", 1, true) ~= nil, "the follow-up was answered")
local decorations = request_sync("coact/decorations", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
local origins = {}
for _, card in ipairs(decorations.cards) do
  origins[card.origin] = (origins[card.origin] or 0) + 1
end
check(
  origins["agent+user"] == 1 and #decorations.edited == 1,
  "the revised answer is marked as agent+user with its edited line"
)

-- Stop a slow answer: the partial text is kept.
ask("please wait")
mode.submit()
wait(10000, function()
  local turn = run._state.turn
  return turn and (turn.text or ""):find("Waiting", 1, true) ~= nil
end, "streaming")
mode.stop()
settle("stopped turn")
check(
  text():find("Waiting", 1, true) ~= nil and text():find("one word after another", 1, true) == nil,
  "stopping keeps the partial answer"
)

-- 3. a tool call is recorded in the trace and replayed in later turns
local notes = root .. "/notes.txt"
vim.fn.writefile({ "forty-two" }, notes)
ask("please read " .. notes)
submit("tool turn")
check(text():find("Final answer: the file says forty-two", 1, true) ~= nil, "the tool turn's final answer was written")
ask("Thanks")
submit("replay turn")
local replay = contents(last_request())
local saw_call, saw_result = false, false
for _, line in ipairs(replay) do
  saw_call = saw_call or line:find("%[read%]") ~= nil
  saw_result = saw_result or (line:find("^tool: ") ~= nil and line:find("forty-two", 1, true) ~= nil)
end
check(saw_call and saw_result, "the recorded tool call and result were replayed from the trace")

-- 4. new files in the workspace are written without review
local created = root .. "/agent-card.org"
ask("please create " .. created)
submit("write turn")
check(vim.uv.fs_stat(created) ~= nil, "the agent created a card file in the workspace directly")

-- 5. changes to existing files go through coact.nvim's hunk review
local patch_session = require("coact.patch_session")
vim.ui.input = function(_, on_confirm)
  on_confirm("")
end
local outside = tmp .. "/project/code.txt"
vim.fn.mkdir(tmp .. "/project", "p")
vim.fn.writefile({ "alpha" }, outside)
local function review(decision)
  local session
  wait(30000, function()
    local target = vim.fn.bufnr(outside)
    session = target ~= -1 and patch_session._active_session(target) or nil
    return session ~= nil
  end, "edit review")
  check(not vim.bo[buf].modifiable, "the card stays read-only while the agent waits for review")
  local target = vim.fn.bufnr(outside)
  vim.api.nvim_buf_call(target, function()
    vim.fn.maparg(decision, "n", false, true).callback()
  end)
  settle("reviewed edit")
end
ask("please edit " .. outside .. " alpha beta")
mode.submit()
review("ga")
check(vim.fn.readfile(outside)[1] == "beta", "an accepted edit was written")
ask("please edit " .. outside .. " beta gamma")
mode.submit()
review("gr")
check(vim.fn.readfile(outside)[1] == "beta", "a rejected edit left the file unchanged")
check(text():find("Final answer: the file says .*rejected") ~= nil, "the agent learned the edit was rejected")

-- 6. manual compaction, reviewed and accepted
mode.compact()
local review_buf
wait(30000, function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo[b].filetype == "org" then
      review_buf = b
      return true
    end
  end
  return false
end, "compaction review")
local summary = table.concat(vim.api.nvim_buf_get_lines(review_buf, 0, -1, false), "\n")
check(summary:find("SUMMARY", 1, true) ~= nil, "the summary is offered for review")
vim.api.nvim_buf_call(review_buf, function()
  vim.fn.maparg("<C-s>", "n", false, true).callback()
end)
settle("compaction")
body = text()
check(body:find(":CONTEXT_KIND: synthesis", 1, true) ~= nil, "a synthesis card was created")
check(body:find("Sources: [[id:", 1, true) ~= nil, "the synthesis card links its sources")
check(body:find("Echo: Why endofunctors?", 1, true) ~= nil, "summarized cards are kept, not deleted")

-- 7. filling the context window compacts during the run, with review
ask("fill the context")
mode.submit()
local auto_review
wait(30000, function()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo[b].filetype == "org" then
      auto_review = b
      return true
    end
  end
  return false
end, "threshold compaction review")
check(
  vim.api.nvim_win_get_config(vim.fn.bufwinid(auto_review)).title[1][1]:find("threshold", 1, true) ~= nil,
  "threshold compaction asks for review during the run"
)
vim.api.nvim_buf_call(auto_review, function()
  vim.fn.maparg("<C-s>", "n", false, true).callback()
end)
settle("threshold compaction")
local _, synth = text():gsub(":CONTEXT_KIND: synthesis", "")
check(synth == 2, "the run's compaction produced a second synthesis card")
check(text():find("Echo: the context is full", 1, true) ~= nil, "the run finished after compacting")

-- 8. the thread survives a Pi restart through its session id
run.shutdown()
vim.fn.mkdir(tmp .. "/elsewhere", "p")
vim.cmd.cd(tmp .. "/elsewhere")
ask("After the restart?")
submit("resumed turn")
check(text():find("Echo: After the restart?", 1, true) ~= nil, "the thread continued after restarting Pi")
local resumed = joined(last_request())
check(
  resumed:find("synthesis", 1, true) ~= nil and resumed:find("SUMMARY", 1, true) ~= nil,
  "the compacted thread sends the synthesis card"
)
local sessions = vim.fn.glob(root .. "/.coact/sessions/*.jsonl", false, true)
check(#sessions == 1, "one Pi session file holds the thread")

-- 9. ask about a selection: a new pinned card in its own file, in a split
vim.api.nvim_set_current_buf(buf)
local wins = #vim.api.nvim_list_wins()
local row = find_line("^Echo: After the restart%?$")
mode.ask({ range = { { row, 6 }, { row, 10 } } })
local side
wait(10000, function()
  side = vim.api.nvim_get_current_buf()
  return side ~= buf
    and table.concat(vim.api.nvim_buf_get_lines(side, 0, -1, false), "\n"):find(":PIN: true", 1, true) ~= nil
end, "ask")
local side_text = table.concat(vim.api.nvim_buf_get_lines(side, 0, -1, false), "\n")
check(#vim.api.nvim_list_wins() == wins + 1, "ask opens the new card in a split")
check(
  vim.fs.dirname(vim.api.nvim_buf_get_name(side)) == vim.fs.normalize(vim.uv.fs_realpath(root) or root)
    or vim.api.nvim_buf_get_name(side):find("/ws/", 1, true) ~= nil,
  "the new card has its own file in the workspace"
)
check(side_text:find("#+begin_quote\nAfter\n#+end_quote", 1, true) ~= nil, "the card quotes the selection")
check(
  text():find("Echo: [[id:", 1, true) ~= nil and text():find(":PIN: false", 1, true) ~= nil,
  "the selection links to it and the old card is unpinned"
)
vim.api.nvim_buf_set_lines(side, -1, -1, false, { "What does after mean here?" })
mode.submit()
wait(5000, function()
  return run.busy()
end, "side submission")
settle("side turn")
side_text = table.concat(vim.api.nvim_buf_get_lines(side, 0, -1, false), "\n")
check(
  side_text:find("Echo: What does after mean here?", 1, true) ~= nil,
  "the side discussion is answered in its own file"
)

-- 10. threads and cards can be found again from outside the workspace
vim.cmd("only")
vim.cmd("enew")
local finder = require("coact.mode.finder")
local index
finder.index(function(cards)
  index = cards
end)
wait(10000, function()
  return index ~= nil
end, "index")
local threads = vim.tbl_filter(function(card)
  return card.thread ~= nil
end, index)
check(#threads == 2, "the index finds both threads of the workspace")
local offered
vim.ui.select = function(items, _, choose)
  offered = items
  choose(items[1])
end
mode.open()
wait(10000, function()
  return offered ~= nil and vim.api.nvim_buf_get_name(0) == vim.api.nvim_buf_get_name(side)
end, "open")
check(
  offered[1].card.pin and offered[1].label:find("What does after mean here?", 1, true) ~= nil,
  "the pinned thread is offered first, with its latest question"
)
offered = nil
vim.ui.select = function(items, _, choose)
  offered = items
  for _, entry in ipairs(items) do
    if entry.card.title == "What is a monad?" then
      return choose(entry)
    end
  end
end
mode.search()
wait(10000, function()
  return offered ~= nil and vim.api.nvim_buf_get_name(0) == vim.api.nvim_buf_get_name(buf)
end, "search")
check(
  vim.api.nvim_get_current_line() == "** What is a monad?" or vim.api.nvim_get_current_line() == "* What is a monad?",
  "search jumps to the card's heading"
)

run.shutdown()
server:kill("sigterm")
print("coact-mode end-to-end: all checks passed")
vim.cmd("qa!")
