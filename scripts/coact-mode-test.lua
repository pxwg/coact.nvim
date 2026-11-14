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

-- A skill for /skill:coact-test.
vim.fn.mkdir(tmp .. "/skills/coact-test", "p")
vim.fn.writefile({
  "---",
  "name: coact-test",
  "description: A skill for the Coact mode test",
  "---",
  "SKILL BODY: answer in haiku.",
}, tmp .. "/skills/coact-test/SKILL.md")

local mode = require("coact.mode")
local run = require("coact.mode.run")
mode.setup({
  workspace_root = tmp .. "/workspaces",
  keymaps = false,
  -- Section 11 turns semantic titles on; earlier sections find cards by title.
  titles = { enabled = false },
  compact = { keep_recent_tokens = 20 },
  pi = {
    model = "coact-test/echo",
    args = {
      "--no-extensions",
      "--extension",
      plugin .. "/scripts/coact-mode-test-provider.ts",
      "--no-skills",
      "--skill",
      tmp .. "/skills/coact-test",
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
  -- Where Coact mode puts the cursor: below the drawer and its blank line.
  local body = require("coact.mode.lsp").body_row(buf, heading)
  vim.api.nvim_buf_set_lines(buf, body - 1, body, false, { question })
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
check(
  body:find(":CONTEXT_KIND: user\n:AUTO_TITLE: What is a monad?\n:END:\n\nWhat is a monad?", 1, true) ~= nil,
  "the question became a user card"
)
check(body:find("Echo: What is a monad?", 1, true) ~= nil, "the answer was written into its card")
check(body:find("%[%[id:[^%]]+%]%[Trace%]%]") ~= nil, "the answer links its trace")
check(vim.bo[buf].modifiable, "the card is editable again")
check(
  body:find(":CONTEXT_KIND: assistant\n:END:\n\n[[id:", 1, true) ~= nil
    and body:find("\n\n** Question\n", 1, true) ~= nil,
  "generated cards are set apart by blank lines"
)
local function waiting_line()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_buf_get_lines(buf, cursor - 2, cursor - 1, false)[1] == ""
    and vim.api.nvim_buf_get_lines(buf, cursor - 3, cursor - 2, false)[1] == ":END:"
end
check(vim.wait(3000, waiting_line, 20), "the cursor waits below the next question's drawer and blank line")
check(not vim.bo[buf].modified, "the card file is saved")
local traces = vim.fn.glob(root .. "/trace/*.org", false, true)
check(#traces == 1, "a trace file was written")
local first = joined(last_request())
check(
  first:find("user: What is a monad?", 1, true) ~= nil and select(2, first:gsub("user: What is a monad%?", "")) == 1,
  "the model saw the question once"
)
check(first:find("This conversation lives in Org cards", 1, true) ~= nil, "the Coact system prompt section was sent")

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
local mode_ui = require("coact.mode.ui")
local edited_row = decorations.edited[1].start.line
mode_ui.decorate(buf)
wait(3000, function()
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    mode_ui.ns,
    { edited_row, 0 },
    { edited_row, -1 },
    { details = true }
  )
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.sign_text and details.sign_hl_group == "CoactModeRevised" and not details.hl_group then
      return true
    end
  end
  return false
end, "the edited line carries a sign-column mark instead of an underline")

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

-- Directives: /skill and @context complete, expand once, and are traced.
local code = tmp .. "/project/code.lua"
vim.fn.mkdir(tmp .. "/project", "p")
vim.fn.writefile({ "local answer = 42" }, code)
vim.cmd("split " .. vim.fn.fnameescape(code))
vim.cmd("wincmd p")
check(vim.api.nvim_get_current_buf() == buf, "back in the card buffer")
wait(15000, function()
  local cache = vim.fn.glob(tmp .. "/workspaces/commands.json")
  return cache ~= "" and table.concat(vim.fn.readfile(cache), ""):find("skill:coact-test", 1, true) ~= nil
end, "command registry")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local question_row
for i, l in ipairs(lines) do
  if l == "** Question" then
    question_row = i
  end
end
while lines[question_row] ~= ":END:" do
  question_row = question_row + 1
end
vim.api.nvim_buf_set_lines(buf, question_row, question_row + 1, false, { "/sk" })
local slash = request_sync("textDocument/completion", lsp_mod.position(buf, { question_row + 1, 3 }))
check(#vim.tbl_filter(function(item)
  return item.label == "/skill:coact-test"
end, slash) == 1, "/ completes Pi skills at the start of a line")
vim.api.nvim_buf_set_lines(buf, question_row, question_row + 1, false, { "see @buf" })
local at = request_sync("textDocument/completion", lsp_mod.position(buf, { question_row + 1, 8 }))
check(#vim.tbl_filter(function(item)
  return item.label == "@buffer"
end, at) == 1, "@ completes Neovim contexts")
vim.api.nvim_buf_set_lines(
  buf,
  question_row,
  question_row + 1,
  false,
  { "/skill:coact-test briefly", "What does @buffer say?" }
)
submit("directive turn")
local directive_request = joined(last_request())
check(directive_request:find("SKILL BODY: answer in haiku.", 1, true) ~= nil, "the skill was expanded for this turn")
check(directive_request:find("local answer = 42", 1, true) ~= nil, "@buffer read the code window used last")
local decorated = request_sync("coact/decorations", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
check(#decorated.directives >= 2, "directives are highlighted in the question card")
local traced = table.concat(vim.fn.readfile(vim.fn.glob(root .. "/trace/*.org", false, true)[1]), "\n")
check(
  traced:find("coact.command", 1, true) ~= nil and traced:find("coact.context", 1, true) ~= nil,
  "the expansions are kept in the trace"
)
ask("And now?")
submit("after directive turn")
local after = joined(last_request())
check(
  after:find("SKILL BODY", 1, true) == nil and after:find("local answer = 42", 1, true) == nil,
  "directives take effect only once"
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

-- 4. cards change through the card tools; other new files go to disk
local created = root .. "/agent-card.org"
ask("please create " .. created)
submit("card write turn")
check(vim.uv.fs_stat(created) == nil and text():find("card tools", 1, true) ~= nil, "writing a card file is refused")
local plain = root .. "/notes2.txt"
ask("please create " .. plain)
submit("plain write turn")
check(vim.uv.fs_stat(plain) ~= nil, "other new files in the workspace are written directly")
ask("please outline")
submit("outline turn")
check(text():find('"kind": "assistant"', 1, true) ~= nil, "thread_view outlines the current thread")
ask("please note Free monads")
submit("create turn")
local function cards_titled(title)
  return vim.tbl_filter(function(path)
    return vim.tbl_contains(vim.fn.readfile(path), "* " .. title)
  end, vim.fn.glob(root .. "/*.org", false, true))
end
check(#cards_titled("Free monads") == 1, "card_create writes a new card file directly")

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

local function card_review(decision)
  wait(30000, function()
    return patch_session._active_session(buf) ~= nil
  end, "card review")
  vim.api.nvim_buf_call(buf, function()
    vim.fn.maparg(decision, "n", false, true).callback()
  end)
end
local answer_row = find_line("^A monoid in the category of endofunctors%.$")
local answer_id
for row = answer_row, 1, -1 do
  answer_id = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]:match("^:ID: (%S+)")
  if answer_id then
    break
  end
end
ask("please fix " .. answer_id .. " monoid MONOID")
mode.submit()
card_review("ga")
settle("card edit")
check(text():find("A MONOID in the category", 1, true) ~= nil, "card_edit changes the card after review")
check(text():find("Accepted 1 change", 1, true) ~= nil, "the agent hears what was accepted")

-- 6. manual compaction, reviewed as hunks; a reason redoes the summary
local function synthesis_files()
  return cards_titled("Summary")
end
local requests_before = #requests()
mode.compact()
wait(30000, function()
  return patch_session._active_session(buf) ~= nil
end, "compaction review")
vim.ui.input = function(_, on_confirm)
  on_confirm("shorter please")
end
card_review("gr")
wait(30000, function()
  local all = requests()
  return #all > requests_before + 1 and joined(all[#all]):find("shorter please", 1, true) ~= nil
end, "redone summary")
check(true, "rejecting with a reason redoes the summary with it")
vim.ui.input = function(_, on_confirm)
  on_confirm("")
end
card_review("ga")
settle("compaction")
body = text()
local synthesis = synthesis_files()
check(#synthesis == 1, "a synthesis card was created in its own file")
check(
  table.concat(vim.fn.readfile(synthesis[1]), "\n"):find("Sources: [[id:", 1, true) ~= nil,
  "the synthesis card links its sources"
)
check(body:find("#+zk_include: :target", 1, true) ~= nil, "the synthesis card is transcluded into the thread")
check(body:find("Echo: Why endofunctors?", 1, true) ~= nil, "summarized cards are kept, not deleted")

-- 7. filling the context window compacts during the run, with review
ask("fill the context")
mode.submit()
wait(30000, function()
  return patch_session._active_session(buf) ~= nil
end, "threshold compaction review")
check(run.phase() == "running", "threshold compaction asks for review during the run")
card_review("ga")
settle("threshold compaction")
check(#synthesis_files() == 2, "the run's compaction produced a second synthesis card")
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
  resumed:find("Synthesis card", 1, true) ~= nil and resumed:find("SUMMARY", 1, true) ~= nil,
  "the compacted thread sends the synthesis card"
)
local sessions = vim.fn.glob(root .. "/.coact/sessions/*.jsonl", false, true)
check(#sessions == 1, "one Pi session file holds the thread")

-- 9. ask about a selection: a new pinned card in its own file, in a split
vim.api.nvim_set_current_buf(buf)
local wins = #vim.api.nvim_list_wins()
local row = find_line("^Echo: After the restart%?$")
-- Ask at once: the question goes into the new card and is sent.
vim.ui.input = function(_, on_confirm)
  on_confirm("What does after mean here?")
end
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
check(side_text:find("\n* New card\n", 1, true) ~= nil, "the asked card starts with a placeholder title")
check(
  text():find("Echo: After the restart?", 1, true) ~= nil and text():find(":PIN: false", 1, true) ~= nil,
  "asking leaves the passage as it was and unpins the old card"
)
vim.ui.input = function(_, on_confirm)
  on_confirm("")
end
wait(5000, function()
  return run.busy()
end, "side submission")
settle("side turn")
local side_id = side_text:match(":ID: (%S+)")
wait(10000, function()
  return text():find("Echo: [[id:" .. side_id .. "][After]] the restart?", 1, true) ~= nil
end, "link back")
check(true, "after the first answer, a phrase of the passage links to the thread, words unchanged")
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
local chosen
vim.ui.select = function(items, _, choose)
  offered = items
  for _, entry in ipairs(items) do
    if entry.text:find("After the restart?", 1, true) then
      chosen = entry
      return choose(entry)
    end
  end
end
mode.search()
wait(10000, function()
  return offered ~= nil and vim.api.nvim_buf_get_name(0) == vim.api.nvim_buf_get_name(buf)
end, "search")
check(
  chosen.card.title == "Monads" and vim.api.nvim_get_current_line() == "* Monads",
  "search finds a thread by text in its subtree"
)
check(#vim.tbl_filter(function(entry)
  return entry.card.kind == "user" or entry.card.kind == "assistant" or entry.card.kind == "trace" or not entry.card.top
end, offered) == 0, "search lists only top-level thread, note and synthesis cards")

-- 11. semantic titles: cards are named in the background, never over a hand
require("coact.mode.config").get().titles.enabled = true
vim.api.nvim_set_current_buf(side)
local function side_text()
  return table.concat(vim.api.nvim_buf_get_lines(side, 0, -1, false), "\n")
end
local function count(pattern)
  return select(2, side_text():gsub(pattern, ""))
end
mode.retitle()
wait(20000, function()
  return count("\n%*%* Titled user\n") == 1 and count("\n%*%* Titled assistant\n") == 1
end, "retitle")
check(true, "retitle names the thread's question and answer by meaning")
check(side_text():find(":AUTO_TITLE: Titled assistant", 1, true) ~= nil, "an automatic title is marked in the drawer")
local side_lines = vim.api.nvim_buf_get_lines(side, 0, -1, false)
for i, line in ipairs(side_lines) do
  if line == "** Titled assistant" then
    vim.api.nvim_buf_set_lines(side, i - 1, i, false, { "** My own title" })
  end
end
local draft_heading
for i, line in ipairs(vim.api.nvim_buf_get_lines(side, 0, -1, false)) do
  if line == "** Question" then
    draft_heading = i
  end
end
local draft_body = require("coact.mode.lsp").body_row(side, draft_heading)
vim.api.nvim_buf_set_lines(side, draft_body - 1, draft_body, false, { "And before?" })
mode.submit()
wait(5000, function()
  return run.busy()
end, "titled turn")
settle("titled turn")
wait(20000, function()
  return count("\n%*%* Titled user\n") == 2 and count("\n%*%* Titled assistant\n") == 1
end, "background titles after a turn")
check(true, "a finished turn's question and answer are named in the background")
check(side_text():find("\n** My own title\n", 1, true) ~= nil, "a title set by hand is kept")
check(side_text():find("Echo: And before?", 1, true) ~= nil, "naming does not disturb the conversation")

-- 12. /model and /thinking: chosen per thread, shown on each answer, kept on resume
local function side_body_row()
  local heading
  for i, line in ipairs(vim.api.nvim_buf_get_lines(side, 0, -1, false)) do
    if line == "** Question" then
      heading = i
    end
  end
  return require("coact.mode.lsp").body_row(side, heading)
end
local row12 = side_body_row()
vim.api.nvim_buf_set_lines(side, row12 - 1, row12, false, { "/mo" })
local function side_request(method, params)
  local result
  lsp_mod.request(side, method, params, function(err, value)
    result = err and { error = err } or (value or vim.NIL)
  end)
  wait(5000, function()
    return result ~= nil
  end, method)
  return result
end
local controls = side_request("textDocument/completion", lsp_mod.position(side, { row12, 3 }))
local model_item = vim.tbl_filter(function(item)
  return item.label == "/model"
end, controls)[1]
check(
  model_item ~= nil and model_item.command.command == "coact.control" and model_item.textEdit.newText == "",
  "/model completes as a command that leaves no text"
)
vim.api.nvim_buf_set_lines(side, row12 - 1, row12, false, { "" })
local picked
vim.ui.select = function(items, opts, choose)
  picked = vim.tbl_map(opts.format_item, items)
  for _, item in ipairs(items) do
    if (type(item) == "table" and item.id == "echo-2") or item == "high" then
      return choose(item)
    end
  end
  choose(nil)
end
vim.lsp.commands["coact.control"]({ arguments = { "model" } }, { bufnr = side })
wait(10000, function()
  return picked ~= nil and #picked >= 2
end, "model picker")
check(#vim.tbl_filter(function(label)
  return label:find("● coact-test/echo", 1, true) == 1 and not label:find("echo-2", 1, true)
end, picked) == 1, "the picker marks the thread's current model")
vim.wait(500)
picked = nil
vim.lsp.commands["coact.control"]({ arguments = { "thinking" } }, { bufnr = side })
wait(10000, function()
  return picked ~= nil
end, "thinking picker")
vim.wait(500)
row12 = side_body_row()
vim.api.nvim_buf_set_lines(side, row12 - 1, row12, false, { "Which model now?" })
mode.submit()
wait(5000, function()
  return run.busy()
end, "model turn")
settle("model turn")
check(last_request().model == "echo-2", "the next turn uses the chosen model")
local function answers()
  local result = side_request("coact/decorations", { textDocument = { uri = vim.uri_from_bufnr(side) } })
  return vim.tbl_filter(function(card)
    return card.kind == "assistant"
  end, result.cards)
end
local shown = answers()
check(
  shown[1].model == "echo" and shown[#shown].model == "echo-2" and shown[#shown].thinking == "high",
  "each answer shows the model and thinking level it was written with"
)
run.shutdown()
row12 = side_body_row()
vim.api.nvim_buf_set_lines(side, row12 - 1, row12, false, { "And after a restart?" })
mode.submit()
wait(5000, function()
  return run.busy()
end, "resumed model turn")
settle("resumed model turn")
check(last_request().model == "echo-2", "a resumed thread keeps its model")

run.shutdown()
server:kill("sigterm")
print("coact-mode end-to-end: all checks passed")
vim.cmd("qa!")
