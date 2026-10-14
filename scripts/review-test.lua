-- Review core tests: model properties under random edits, then live-buffer
-- session behavior (edits, cursor targeting, undo/write guards, notes).
vim.opt.runtimepath:append(".")
require("coact").setup()

local model = require("coact.review.model")
local patch_session = require("coact.patch_session")
local review_notes = require("coact.review.notes")

math.randomseed(tonumber(os.getenv("COACT_REVIEW_SEED") or "") or 20261014)

local alphabet = { "a", "b", "c", "d", "e" }
local function random_lines(max)
  local out = {}
  for _ = 1, math.random(0, max) do
    out[#out + 1] = alphabet[math.random(#alphabet)]
  end
  return out
end

local unique = 0
local function mutate(lines, steps)
  local out = vim.deepcopy(lines)
  for _ = 1, steps do
    local op = math.random(3)
    if op == 1 or #out == 0 then
      unique = unique + 1
      table.insert(
        out,
        math.random(#out + 1),
        math.random(2) == 1 and alphabet[math.random(#alphabet)] or ("u" .. unique)
      )
    elseif op == 2 then
      table.remove(out, math.random(#out))
    else
      out[math.random(#out)] = alphabet[math.random(#alphabet)]
    end
  end
  return out
end

local function text(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

local function size(hunks)
  local total = 0
  for _, hunk in ipairs(hunks) do
    total = total + hunk.a_count + hunk.b_count
  end
  return total
end

local function show(lines)
  return "[" .. table.concat(lines, ",") .. "]"
end

-- P1: approving or rejecting any hunk shrinks the diff by at least its size,
-- so every review terminates and leaves A == W.
for _ = 1, 400 do
  local a = random_lines(12)
  local w = mutate(a, math.random(0, 6))
  local hunks = model.hunks(a, w)
  local before = size(hunks)
  for _, hunk in ipairs(hunks) do
    local approved = model.approve(a, hunk)
    assert(
      size(model.hunks(approved, w)) <= before - hunk.a_count - hunk.b_count,
      "approve must shrink diff: " .. show(a) .. " -> " .. show(w)
    )
    local rejected = model.reject(w, hunk)
    assert(
      size(model.hunks(a, rejected)) <= before - hunk.a_count - hunk.b_count,
      "reject must shrink diff: " .. show(a) .. " -> " .. show(w)
    )
  end
end

-- P2: decisions in random order, resolved by content, always converge.
for _ = 1, 300 do
  local a = random_lines(12)
  local w = mutate(a, math.random(0, 6))
  local guard = 0
  while true do
    local hunks = model.hunks(a, w)
    if #hunks == 0 then
      break
    end
    guard = guard + 1
    assert(guard <= 64, "review must terminate")
    local pick = hunks[math.random(#hunks)]
    local fresh = model.resolve(model.hunks(a, w), pick)
    assert(fresh, "a hunk must resolve against its own diff")
    if math.random(2) == 1 then
      a = model.approve(a, fresh)
    else
      w = model.reject(w, fresh)
    end
  end
  assert(model.same_lines(a, w), "converged review must leave A == W")
end

-- P3: line_map is an increasing partial map that preserves content.
for _ = 1, 300 do
  local a = random_lines(12)
  local b = mutate(a, math.random(0, 6))
  local map = model.line_map(a, b)
  local last = 0
  for index = 1, #a do
    if map[index] then
      assert(map[index] > last and b[map[index]] == a[index], "line_map must preserve order and content")
      last = map[index]
    end
  end
end

-- P4: nearest is a true minimum of the half-line distance.
for _ = 1, 300 do
  local a = random_lines(14)
  local w = mutate(a, math.random(1, 6))
  local hunks = model.hunks(a, w)
  if #hunks > 0 then
    local line = math.random(1, math.max(1, #w))
    local best = model.nearest(hunks, line)
    for _, hunk in ipairs(hunks) do
      assert(model.distance(best, line) <= model.distance(hunk, line), "nearest must minimize distance")
    end
  end
end

-- P5: unified patches with header drift reapply to the same proposal.
for _ = 1, 200 do
  local base = {}
  for index = 1, math.random(1, 20) do
    base[index] = "line-" .. index
  end
  local proposed = mutate(base, math.random(1, 5))
  local diff = vim.diff(text(base), text(proposed), { ctxlen = 2 })
  local hunks = patch_session._parse_change_hunks({ diff = diff })
  for _, hunk in ipairs(hunks) do
    hunk.old_start = math.max(1, hunk.old_start + math.random(-3, 3))
  end
  local applied = model.apply_hunks(base, hunks)
  assert(applied and model.same_lines(applied, proposed), "drifted headers must still apply exactly")
end
assert(
  select(2, model.find_nearest({ "x", "y", "x" }, { "x" }, 1)) == "ambiguous",
  "equidistant matches must be ambiguous"
)

-- P6: a unique line inserted by the user away from agent changes is a user hunk,
-- and with no user edits every hunk is the agent's.
for _ = 1, 200 do
  local base = {}
  for index = 1, math.random(4, 16) do
    base[index] = "base-" .. index
  end
  local proposed = mutate(base, math.random(1, 4))
  local marks = model.agent_marks(base, proposed)
  for _, hunk in ipairs(model.hunks(base, proposed)) do
    assert(
      model.is_agent(model.project_marks(marks, proposed, proposed), hunk),
      "unedited proposal hunks must be agent hunks"
    )
  end
  local working = vim.deepcopy(proposed)
  table.insert(working, math.random(#working + 1), "USER-ONLY")
  local projected = model.project_marks(marks, proposed, working)
  for _, hunk in ipairs(model.hunks(base, working)) do
    if #hunk.new_lines == 1 and hunk.new_lines[1] == "USER-ONLY" and hunk.a_count == 0 then
      assert(not model.is_agent(projected, hunk), "isolated user insertions must be user hunks")
    end
  end
end

-- Session tests ----------------------------------------------------------

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function unified(name, base, proposed)
  local body = vim.diff(text(base), text(proposed), { ctxlen = 1 })
  return table.concat({ "--- a/" .. name, "+++ b/" .. name, body }, "\n")
end

local function open(name, base, proposed, extra)
  local path = vim.fs.joinpath(dir, name)
  vim.fn.writefile(base, path)
  local done = {}
  local change =
    vim.tbl_extend("force", { path = path, kind = "update", diff = unified(name, base, proposed) }, extra or {})
  local session = assert(patch_session.open({
    cwd = dir,
    changes = { change },
    on_complete = function(summary, success, result)
      done.summary, done.success, done.result = summary, success, result
    end,
  }))
  return session, done, path, session.file_order[1].bufnr
end

local function with_input(value, fn)
  local original = vim.ui.input
  vim.ui.input = function(_, callback)
    callback(value)
  end
  local ok, err = pcall(fn)
  vim.ui.input = original
  assert(ok, err)
end

local function press(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(type(mapping.callback) == "function", lhs .. " should be mapped")
  mapping.callback()
end

-- Edits above and inside hunks do not break positions or decisions.
do
  local base = { "one", "two", "three", "four", "five" }
  local proposed = { "one", "TWO", "TWO-b", "three", "four", "FIVE" }
  local session, done, path, bufnr = open("edit-robust.txt", base, proposed)
  assert(#session.blocks == 2, "two agent hunks expected")
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "user-a", "user-b" })
  vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "TWO-b!" })
  local blocks = session.blocks
  assert(
    #blocks == 2 and blocks[1].b_start == 4 and blocks[1].new_lines[2] == "TWO-b!" and blocks[2].b_start == 8,
    "hunks must follow buffer edits, and partly edited agent hunks stay agent hunks"
  )
  patch_session._reject_block(session, blocks[1], "keep two")
  assert(vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1] == "two", "reject must restore at the moved position")
  patch_session._accept_block(session, session.blocks[1])
  assert(done.summary, "review should complete")
  assert(
    table.concat(vim.fn.readfile(path), ",") == "user-a,user-b,one,two,three,four,FIVE",
    "final file must keep user edits and decisions: " .. table.concat(vim.fn.readfile(path), ",")
  )
  assert(done.result.user_blocks == 1, "the user's own insertion is auto-accepted as a user edit")
  assert(done.summary:match("user_edit_blocks: 1") and done.summary:match("keep two"), done.summary)
end

-- '.' approves the hunk nearest the cursor, not the first pending one.
do
  local base = { "a1", "a2", "a3", "a4", "a5", "a6", "a7" }
  local proposed = { "A1", "a2", "a3", "a4", "a5", "a6", "A7" }
  local session, done, _, bufnr = open("cursor.txt", base, proposed)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  assert(patch_session._target(session).b_start == 7, "nearest hunk should be the lower one")
  with_input("", function()
    press(".")
  end)
  local remaining = session.blocks
  assert(#remaining == 1 and remaining[1].b_start == 1, "the cursor-nearest hunk should be the one approved")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  with_input("nope", function()
    press(",")
  end)
  assert(done.summary and not done.success, "review completes after the last decision")
  assert(done.result.accepted_blocks == 1 and done.result.rejected_blocks == 1)
end

-- Undo cannot cross the proposal; undoing a rejection reopens its hunk; :write is blocked.
do
  local base = { "x", "y", "z" }
  local proposed = { "x", "Y", "z" }
  local session, done, path, bufnr = open("undo.txt", base, proposed)
  vim.api.nvim_win_set_buf(0, bufnr)
  local notify = vim.notify
  vim.notify = function() end
  vim.cmd("silent! undo")
  assert(#session.blocks == 1, "undo past the proposal must be restored")
  assert(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == "Y", "proposal must be back in the buffer")
  vim.cmd("silent! write")
  assert(vim.fn.readfile(path)[2] == "y", "write must be blocked during review")
  vim.notify = notify
  patch_session._reject_block(session, session.blocks[1], "no")
  assert(done.summary, "single rejection completes the review")
end
do
  local base = { "p", "q", "r", "s", "t" }
  local proposed = { "P", "q", "r", "s", "T" }
  local session, _, _, bufnr = open("undo-reject.txt", base, proposed)
  vim.api.nvim_win_set_buf(0, bufnr)
  patch_session._reject_block(session, session.blocks[1], "no")
  assert(#session.blocks == 1, "one hunk left after reject")
  vim.cmd("silent undo")
  assert(#session.blocks == 2, "undoing a rejection reopens the hunk")
  patch_session._accept_block(session, session.blocks[1])
  patch_session._accept_block(session, session.blocks[1])
  assert(session.completed and session.rejected_blocks == 0 and session.accepted_blocks == 2)
end

-- Approvals are native undo steps: undo reopens, redo re-approves, and a new
-- branch drops the abandoned approval.
do
  local session, done, _, bufnr = open("undo-approve.txt", { "m", "n", "o", "p", "q" }, { "M", "n", "o", "p", "Q" })
  vim.api.nvim_win_set_buf(0, bufnr)
  patch_session._accept_block(session, session.blocks[1])
  assert(#session.blocks == 1, "approval leaves one pending hunk")
  vim.cmd("silent undo")
  assert(#session.blocks == 2, "undoing an approval reopens its hunk")
  vim.cmd("silent redo")
  assert(#session.blocks == 1, "redo re-applies the approval")
  vim.cmd("silent undo")
  patch_session._reject_block(session, session.blocks[2], "no")
  local remaining = session.blocks
  assert(#remaining == 1 and remaining[1].b_start == 1, "a new undo branch drops the abandoned approval")
  patch_session._accept_block(session, remaining[1])
  assert(done.result.accepted_blocks == 1 and done.result.rejected_blocks == 1, done.summary)
end

-- Full-content proposals are refused when the file no longer matches their base.
do
  local path = vim.fs.joinpath(dir, "stale.txt")
  vim.fn.writefile({ "current" }, path)
  local session, err = patch_session.open({
    cwd = dir,
    changes = { { path = path, kind = "update", diff = "", new_content = "next\n", old_content = "older\n" } },
  })
  assert(not session and tostring(err):match("changed since the proposal"), tostring(err))
  assert(vim.fn.readfile(path)[1] == "current", "a refused proposal must leave the file untouched")
end

-- Rewriting an agent line keeps it in the agent footprint: it still needs
-- approval, marked as edited; isolated user lines remain user edits.
do
  local session, done, path, bufnr = open("rewrite.txt", { "k", "old", "x", "y", "z" }, { "k", "agent", "x", "y", "z" })
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "mine" })
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "note-to-self" })
  local blocks = session.blocks
  assert(
    #blocks == 1 and blocks[1].edited and blocks[1].new_lines[1] == "mine",
    "rewritten agent hunk stays reviewable"
  )
  with_input("", function()
    press(".")
  end)
  assert(done.success and vim.fn.readfile(path)[2] == "mine", "approving keeps the user's rewrite")
  assert(done.result.user_blocks == 1 and done.summary:match("user%-edited"), done.summary)
end
do
  local session, done, path, bufnr = open("only-user.txt", { "k", "old", "x", "y", "z" }, { "k", "new", "x", "y", "z" })
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "old" })
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "mine" })
  assert(#session.blocks == 0, "reverting the agent change by hand leaves only user edits")
  with_input("", function()
    press(".")
  end)
  assert(done.success and vim.fn.readfile(path)[5] == "mine", "'.' finishes when only user edits remain")
end

-- Notes: inline change notes and the annotate_change store render on hunks.
do
  local hint_ns = vim.api.nvim_get_namespaces()["coact.patch_session.hint"]
  local diff_ns = vim.api.nvim_get_namespaces()["coact.patch_session.diff"]
  local path = vim.fs.joinpath(dir, "notes.txt")
  review_notes.add(path, { { anchor = "gamma2", note = "stored rationale" } })
  local session, _, _, bufnr = open(
    "notes.txt",
    { "alpha", "beta", "gamma", "delta", "eps" },
    { "alpha", "beta2", "gamma", "delta", "gamma2" },
    { notes = { { anchor = "beta2", note = "inline rationale" } } }
  )
  vim.api.nvim_win_set_buf(0, bufnr)
  local blocks = session.blocks
  assert(blocks[1].notes[1] == "inline rationale" and blocks[2].notes[1] == "stored rationale", vim.inspect(blocks))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  patch_session._render(session, true)
  local hint = vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, hint_ns, 0, -1, { details = true }))
  local diff = vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, diff_ns, 0, -1, { details = true }))
  assert(hint:match("inline rationale") and diff:match("stored rationale"), "notes should render on their hunks")
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "shift" })
  assert(session.blocks[1].notes[1] == "inline rationale", "notes follow hunks through edits")
  patch_session.cancel(session)
end

print("review-test: ok")
vim.cmd("qa!")
