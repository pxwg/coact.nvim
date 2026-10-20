-- Side discussions on a fake Pi session tree: safe open, exact anchors,
-- routing, lock, UI, annotation write-back, plain close and hints.
local root = vim.fn.getcwd()
vim.g.mapleader = " "
vim.o.columns = 140
vim.o.lines = 45

local coact = require("coact")
coact.setup({
  default_adapter = "pi",
  adapters = {
    pi = {
      command = { "node", root .. "/scripts/pi-side-rpc-fixture.mjs" },
      picker_prewarm = false,
      nvim_tools = { enabled = false },
    },
  },
})
local state = require("coact.state")
local side = require("coact.side")
local pi_rpc = require("coact.providers.pi_rpc")
local annotations = require("coact.annotations")

local function wait(label, predicate, timeout)
  assert(
    vim.wait(timeout or 5000, function()
      local ok, value = pcall(predicate)
      return ok and value
    end, 20),
    "timed out waiting for " .. label
  )
end

local function agent_texts(thread)
  local out = {}
  for _, id in ipairs(thread.item_order) do
    local item = thread.items[id]
    if item.type == "agentMessage" then
      table.insert(out, item.text or "")
    end
  end
  return out
end

local function fixture_state(thread_id)
  local result
  pi_rpc.request_raw("fixture_state", { threadId = thread_id }, function(err, data)
    assert(not err, vim.inspect(err))
    result = data
  end)
  wait("fixture state", function()
    return result ~= nil
  end)
  return result
end

local function find_line(bufnr, needle)
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return lnum, line
    end
  end
end

local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local answer = 42", "return answer" })

-- No keys are bound by the plugin; hints list the user's <Plug> mappings.
local hints = require("coact.ui.selection_hints")
assert(#hints.items(source) == 0, "no hints without user mappings")
vim.keymap.set("x", "<leader>as", "<Plug>(CoactSideAsk)")
vim.keymap.set("x", "<leader>aa", "<Plug>(CoactAddSelection)")

coact.new_thread({ session_id = "side-main", prompt = "first question" })
local main_id = "pi:side-main"
local main
wait("first main answer", function()
  main = state.get_thread(main_id)
  return main and #agent_texts(main) == 1 and side._idle(main)
end)
coact.submit_text("slow second", main_id)
wait("second main turn started", function()
  return not side._idle(main)
end)

-- Select inside the first answer, after a 4-byte emoji, while the main is busy.
require("coact.buffers").render(main_id)
local history = main.bufnr
local line, text = find_line(history, "Answer to: first question")
assert(line, "first answer must be rendered")
local s = text:find("first question", 1, true)
vim.api.nvim_set_current_win(main.winid)
vim.api.nvim_buf_set_mark(history, "<", line, s - 1, {})
vim.api.nvim_buf_set_mark(history, ">", line, s - 1 + #"first question" - 1, {})
local anchor, err = side.capture(history, main.winid, "v")
assert(anchor, err)
assert(anchor.quote == "first question" and anchor.entry_id == "e2" and anchor.block == 0, vim.inspect(anchor))
assert(anchor.start == 14 and anchor["end"] == 28, "UTF-16 offsets: " .. vim.inspect(anchor))
vim.api.nvim_buf_set_mark(history, "<", line - 2, 0, {})
assert(not side.capture(history, main.winid, "v"), "selections must stay inside one reply text")

local items = hints.items(history)
assert(#items == 1 and items[1].label == "side ask" and items[1].key == " as", vim.inspect(items))
assert(#hints.items(source) == 2)

vim.api.nvim_buf_set_mark(history, "<", line, s - 1, {})
assert(side.open(anchor))
vim.wait(100)
assert(not side.for_main(main_id), "side must wait for the main thread")
wait("side open", function()
  local current = side.for_main(main_id)
  return current and current.side.status == "open"
end)
local thread = side.for_main(main_id)
assert(#agent_texts(main) == 2, "main turn must finish before the side opens")
assert(fixture_state(main_id).leafId == "e2", "side must branch at the end of the selected turn")
assert(thread.side.origin_leaf_id == "e4")

local ui = thread.side_ui
assert(vim.api.nvim_win_is_valid(ui.quote_win) and vim.api.nvim_win_is_valid(thread.prompt_winid))
assert(table.concat(vim.api.nvim_buf_get_lines(ui.quote_buf, 0, -1, false), "\n") == "first question")
assert(vim.api.nvim_win_is_valid(main.winid), "main chat stays visible")

local main_items = #main.item_order
local restored = false
coact.submit_text("main while side", main_id, {
  on_error = function()
    restored = true
  end,
})
assert(restored and #main.item_order == main_items, "main thread is locked")

coact.submit_text("what does it mean?", thread.id)
wait("first side answer", function()
  return #agent_texts(thread) == 1 and side._idle(thread)
end)
assert(agent_texts(thread)[1]:find("what does it mean? ctx=yes", 1, true), agent_texts(thread)[1])
coact.submit_text("and then?", thread.id)
wait("second side answer", function()
  return #agent_texts(thread) == 2 and side._idle(thread)
end)
assert(agent_texts(thread)[2]:find("and then? ctx=no", 1, true))
assert(#main.item_order == main_items, "side events must not reach the main chat")

-- Annotation: the model submits, the side closes, the note joins the main branch.
assert(side.annotate(thread))
wait("annotated close", function()
  return thread.side.status == "closed"
end)
assert(thread.side.annotation_index == 1)
local fixture = fixture_state(main_id)
local note_entry = fixture.entries[#fixture.entries]
assert(note_entry.type == "branch_summary" and note_entry.parentId == "e4", vim.inspect(note_entry))
assert(fixture.leafId == note_entry.id)
assert(not main.side_lock and not pi_rpc.side_route(thread.id))
wait("main shows the side note", function()
  require("coact.buffers").render(main_id)
  return find_line(main.bufnr, "Side note [1]") ~= nil
end)
assert(not find_line(main.bufnr, "coact-anchor"), "anchor comment stays hidden")
local note = annotations.parse(note_entry.summary)
assert(note and note.index == 1 and note.anchor.start == 14 and note.anchor["end"] == 28)
line = find_line(main.bufnr, "Answer to: first question")
local marks = vim.api.nvim_buf_get_extmarks(main.bufnr, annotations._namespace, 0, -1, { details = true })
assert(#marks == 1, "one footnote marker")
assert(marks[1][2] == line - 1 and marks[1][3] == s - 1 + #"first question", vim.inspect(marks[1]))
assert(marks[1][4].virt_text[1][1] == "[1]")

-- A second side from a source-buffer selection, closed without a note.
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_mark(source, "<", 1, 6, {})
vim.api.nvim_buf_set_mark(source, ">", 1, 11, {})
local file_anchor = assert(side.capture(source, vim.api.nvim_get_current_win(), "v"))
assert(file_anchor.kind == "file" and file_anchor.quote == "answer")
assert(side.open(file_anchor))
wait("file side open", function()
  local current = side.for_main(main_id)
  return current and current.side.status == "open"
end)
local second = side.for_main(main_id)
local leaf_before = fixture.leafId
coact.submit_text("explain", second.id)
wait("file side answer", function()
  return #agent_texts(second) == 1 and side._idle(second)
end)
side.close(second)
wait("plain close", function()
  return second.side.status == "closed"
end)
fixture = fixture_state(main_id)
assert(fixture.leafId == leaf_before, "closing returns to the main leaf")

coact.submit_text("third question", main_id)
wait("main resumes", function()
  return #agent_texts(main) == 3 and side._idle(main)
end)
assert(fixture_state(main_id).branch[5] == note_entry.id, "main continues after the side note")

pi_rpc.stop()
print("pi side discussion: PASS")
vim.cmd("qa!")
