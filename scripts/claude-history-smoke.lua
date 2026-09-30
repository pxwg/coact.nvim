return function()
  local config = require("coact.config")
  local old = vim.deepcopy(config.get())
  local root = vim.fn.tempname()
  config.setup({ provider = "claude", providers = { claude = { config_dir = root } } })
  local h = require("coact.providers.claude_history")
  local function id(n)
    return string.format("10000000-1111-4111-8111-%012d", n)
  end
  local session, child = id(1), id(2)
  local cwd = root .. "/workspace"
  local dir = root .. "/projects/test-project"
  vim.fn.mkdir(cwd, "p")
  vim.fn.mkdir(dir, "p")
  local function record(n, parent, kind, content, extra)
    return vim.tbl_extend("force", {
      uuid = id(n),
      parentUuid = parent and id(parent) or vim.NIL,
      type = kind,
      cwd = cwd,
      sessionId = session,
      message = { role = kind, content = content },
    }, extra or {})
  end
  local records = {
    record(10, nil, "user", "first prompt"),
    record(11, 10, "assistant", { { type = "text", text = "FIRST" } }),
    record(12, 11, "progress", vim.NIL),
    record(13, 12, "user", "second prompt"),
    record(14, 13, "assistant", { { type = "thinking", thinking = "reason" } }),
    record(15, 14, "assistant", { { type = "text", text = "SECOND" }, vim.NIL }),
    record(16, 11, "assistant", { { type = "text", text = "hidden agent" } }, { isSidechain = true }),
    { type = "custom-title", customTitle = "Saved history" },
  }
  local path = dir .. "/" .. session .. ".jsonl"
  local function write(extra_tail)
    local lines = {}
    for _, r in ipairs(records) do
      lines[#lines + 1] = vim.json.encode(r)
    end
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(lines, "\n") .. "\n" .. (extra_tail or ""))
    f:close()
  end
  write('{"type":')
  local snap = assert(h.read("claude:" .. session))
  assert(snap.partial_tail and snap.leaf == id(15) and #snap.chain == 6)
  local thread = h.thread(snap)
  assert(#thread.turns == 2 and #thread.turns[2].items == 3)
  assert(thread.turns[2].items[2].type == "reasoning" and thread.turns[2].items[3].text == "SECOND")
  assert(thread.turns[1].items[1].treeEntryId == id(10))
  assert(h.list(cwd)[1].name == "Saved history")
  assert(#h.list(root .. "/unrelated") == 0 and not h.locate("../bad"))
  local cp = assert(h.checkpoint(snap, id(13)))
  assert(cp.at == id(11) and cp.draft == "second prompt" and #cp.chain == 2)
  assert(h.checkpoint(snap, id(10)).at == nil)
  h.save_branch(child, session, id(11))
  local pending = assert(h.read(child))
  assert(pending.pending_fork and #pending.chain == 2 and h.native_source(child) == session)
  assert(h.thread(pending).parentThreadId == "claude:" .. session)
  local tree, owners = h.tree(pending)
  assert(tree.leafId == id(11) and #tree.nodes >= 5 and owners[id(15)] == session)
  assert(#h.list(cwd) == 2, "forks not materialized by CLI must survive restart")
  records[#records + 1] =
    record(20, nil, "system", vim.NIL, { subtype = "compact_boundary", logicalParentUuid = id(15) })
  records[#records + 1] = record(21, 20, "user", "compact summary", { isCompactSummary = true })
  records[#records + 1] = record(22, 21, "assistant", { { type = "text", text = "AFTER COMPACT" } })
  write()
  local compacted = assert(h.read(session))
  assert(#compacted.chain == 3, "compaction logical parent must not duplicate old context")
  assert(not h.native_source(session, id(11)), "native resume cannot target an archived pre-compaction UUID")
  assert(not h.chain(compacted, id(999)), "missing checkpoints must not silently produce an empty conversation")
  assert(h.thread(compacted).turns[1].items[1].type == "compactionSummary")
  assert(h.checkpoint(compacted, id(13)).at == id(11), "old checkpoints remain navigable in archived history")
  local cyclic = assert(
    h.parse(
      vim.json.encode(record(30, 31, "user", "cycle")) .. "\n" .. vim.json.encode(record(31, 30, "assistant", {})),
      session,
      path
    )
  )
  assert(not h.chain(cyclic, id(30)), "cycles must fail closed")
  assert(not h.parse("bad\n{}\n", session, path), "invalid complete records must not silently disappear")
  local missing = assert(h.parse(vim.json.encode(record(32, 999, "user", "missing")), session, path))
  assert(not h.chain(missing, id(32)))
  config.get().providers.claude.max_history_bytes = 10
  assert(not h.read(session), "oversized histories must fail explicitly")
  config.get().providers.claude.max_history_bytes = 64 * 1024 * 1024
  local tool_chain = assert(h.parse(
    table.concat({
      vim.json.encode(record(40, nil, "user", "tool prompt")),
      vim.json.encode(
        record(
          41,
          40,
          "assistant",
          { { type = "text", text = "Starting" }, { type = "tool_use", id = "call", name = "Bash", input = vim.NIL } }
        )
      ),
    }, "\n"),
    session,
    path
  ))
  assert(not h.checkpoint(tool_chain, id(41)), "never rewind into an unresolved tool exchange")
  vim.fn.delete(root, "rf")
  config.setup(old)
end
