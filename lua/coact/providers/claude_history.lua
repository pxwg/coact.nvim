-- Read-only reconstruction of Claude's native JSONL sessions. Conversation
-- context follows parentUuid, never logicalParentUuid across compaction.
local M = {}
local function obj(v)
  return type(v) == "table" and v or {}
end
local function str(v)
  return type(v) == "string" and v or ""
end
local function value(v)
  return v ~= vim.NIL and v or nil
end
function M.uuid(id)
  id = str(id):gsub("^claude:", "")
  local a, b, c, d, e = id:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
  return a and #a == 8 and #b == 4 and #c == 4 and #d == 4 and #e == 12 and id:lower() or nil
end
function M.config_dir()
  local opts = require("coact.providers.claude").options()
  return vim.fs.normalize(
    vim.fn.expand(opts.config_dir or obj(opts.env).CLAUDE_CONFIG_DIR or vim.env.CLAUDE_CONFIG_DIR or "~/.claude")
  )
end
local function files(path)
  local out = {}
  local scan = vim.uv.fs_scandir(path)
  if scan then
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      out[#out + 1] = { name = name, kind = kind, path = vim.fs.joinpath(path, name) }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end
function M.locate(id)
  id = M.uuid(id)
  if not id then
    return nil
  end
  for _, dir in ipairs(files(M.config_dir() .. "/projects")) do
    if dir.kind == "directory" then
      local path = dir.path .. "/" .. id .. ".jsonl"
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "file" then
        return path
      end
    end
  end
end
local function branch_path(id)
  return M.config_dir() .. "/coact-branches/" .. id .. ".json"
end
function M.branch(id)
  id = M.uuid(id)
  if not id then
    return nil
  end
  local f = io.open(branch_path(id), "rb")
  if not f then
    return nil
  end
  local bytes = f:read(65536)
  f:close()
  local ok, data = pcall(vim.json.decode, bytes or "")
  if
    ok
    and type(data) == "table"
    and M.uuid(data.parent)
    and M.uuid(data.root)
    and (data.at == false or M.uuid(data.at))
  then
    return data
  end
  return nil
end
function M.save_branch(id, parent, at)
  id, parent = M.uuid(id), M.uuid(parent)
  assert(id and parent, "Invalid branch session id")
  local ancestor = M.branch(parent)
  local dir = M.config_dir() .. "/coact-branches"
  vim.fn.mkdir(dir, "p", 448)
  local path = branch_path(id)
  local tmp = path .. ".tmp"
  local data = { parent = parent, root = ancestor and ancestor.root or parent, at = at or false }
  assert(vim.fn.writefile({ vim.json.encode(data) }, tmp) == 0, "Could not save rewind branch")
  vim.uv.fs_chmod(tmp, 384)
  assert(vim.uv.fs_rename(tmp, path), "Could not publish rewind branch")
end
function M.native_source(id, checkpoint)
  id = M.uuid(id)
  local seen = {}
  while id and not seen[id] do
    seen[id] = true
    if M.locate(id) then
      if not checkpoint then
        return id
      end
      -- Native resume excludes the prefix before compaction even though those
      -- UUIDs remain in JSONL. A preserved ancestor may still expose it.
      local snapshot = M.read(id)
      for _, entry in ipairs(snapshot and snapshot.chain or {}) do
        if entry.uuid == checkpoint then
          return id
        end
      end
    end
    local branch = M.branch(id)
    id = branch and M.uuid(branch.parent) or nil
  end
  return nil
end

local function visible(e)
  return (e.type == "user" or e.type == "assistant")
    and e.isSidechain ~= true
    and not value(e.teamName)
    and e.isMeta ~= true
end
function M.text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, b in ipairs(obj(content)) do
    b = obj(b)
    if b.type == "text" then
      parts[#parts + 1] = str(b.text)
    end
  end
  return table.concat(parts, "\n")
end
function M.user(e)
  return e.type == "user" and visible(e) and e.isCompactSummary ~= true and M.text(obj(e.message).content) ~= ""
end
function M.parse(bytes, id, path)
  local snapshot = { id = "claude:" .. id, session_id = id, path = path, records = {}, by_id = {}, chain = {} }
  local lines = vim.split(bytes, "\n", { plain = true })
  local order = {}
  for index, line in ipairs(lines) do
    if line ~= "" then
      local ok, e = pcall(vim.json.decode, line)
      if not ok then
        if index < #lines then
          return nil, "Malformed Claude history record at line " .. index
        end
        snapshot.partial_tail = true -- a CLI write can be in flight
      elseif type(e) == "table" then
        if type(e.cwd) == "string" then
          snapshot.cwd = e.cwd
        end
        if type(e.customTitle) == "string" then
          snapshot.title = e.customTitle
        end
        if visible(e) and obj(e.message).model then
          snapshot.model = value(e.message.model)
        end
        if type(e.uuid) == "string" and e.isSidechain ~= true and not value(e.teamName) then
          if not snapshot.by_id[e.uuid] then
            order[#order + 1] = e.uuid
          end
          snapshot.by_id[e.uuid] = e
        end
      end
    end
  end
  for _, uuid in ipairs(order) do
    local e = snapshot.by_id[uuid]
    snapshot.records[#snapshot.records + 1] = e
    if visible(e) then
      snapshot.leaf = uuid
    end
    if not snapshot.preview and M.user(e) then
      snapshot.preview = M.text(e.message.content):gsub("\n", " "):sub(1, 180)
    end
  end
  return snapshot
end
function M.chain(snapshot, leaf)
  local chain, seen = {}, {}
  local e = leaf and snapshot.by_id[leaf]
  if leaf and not e then
    return nil, "Checkpoint is missing from Claude history"
  end
  while e do
    if seen[e.uuid] then
      return nil, "Cycle in Claude history"
    end
    seen[e.uuid] = true
    table.insert(chain, 1, e)
    local parent = value(e.parentUuid)
    if parent and not snapshot.by_id[parent] then
      return nil, "Missing parent in Claude history: " .. str(parent)
    end
    e = parent and snapshot.by_id[parent] or nil
  end
  return chain
end
function M.read(id, at, seen)
  id = M.uuid(id)
  if not id then
    return nil, "Invalid Claude session id"
  end
  seen = seen or {}
  if seen[id] then
    return nil, "Cycle in rewind branch metadata"
  end
  seen[id] = true
  local path = M.locate(id)
  local branch = M.branch(id)
  if not path then
    if not branch then
      return nil, "Claude session file not found"
    end
    local parent, err = M.read(branch.parent, nil, seen)
    if not parent then
      return nil, err
    end
    local cut = branch.at ~= false and value(branch.at) or nil
    local chain, chain_err = M.chain(parent, cut)
    if not chain then
      return nil, chain_err
    end
    local snap = {
      id = "claude:" .. id,
      session_id = id,
      cwd = parent.cwd,
      model = parent.model,
      title = parent.title,
      preview = parent.preview,
      records = chain,
      by_id = {},
      leaf = cut,
      branch = branch,
      pending_fork = true,
    }
    for _, e in ipairs(chain) do
      snap.by_id[e.uuid] = e
    end
    snap.chain = chain
    return snap
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, "Claude session file disappeared"
  end
  local limit = require("coact.providers.claude").options().max_history_bytes or 64 * 1024 * 1024
  if stat.size > limit then
    return nil, "Claude history exceeds max_history_bytes"
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, "Cannot read Claude session"
  end
  local bytes = f:read(limit + 1) or ""
  f:close()
  if #bytes > limit then
    return nil, "Claude history exceeds max_history_bytes"
  end
  local snap, err = M.parse(bytes, id, path)
  if not snap then
    return nil, err
  end
  snap.branch = branch
  snap.updatedAt = stat.mtime.sec
  snap.createdAt = stat.birthtime and stat.birthtime.sec or stat.mtime.sec
  if at and not snap.by_id[at] then
    return nil, "Checkpoint was not found in Claude history"
  end
  snap.chain, err = M.chain(snap, at or snap.leaf)
  if not snap.chain then
    return nil, err
  end
  return snap
end
local function blocks(content)
  return type(content) == "string" and { { type = "text", text = content } } or obj(content)
end
function M.thread(snapshot, id)
  local turns, turn, tools = {}, {}, {}
  local function ensure(e)
    if not turn.id then
      turn = { id = "claude-history-" .. e.uuid, items = {}, status = "completed" }
      turns[#turns + 1] = turn
    end
  end
  for _, e in ipairs(snapshot.chain or {}) do
    if visible(e) then
      local message = obj(e.message)
      if M.user(e) then
        turn = { id = "claude-history-" .. e.uuid, items = {}, status = "completed" }
        turns[#turns + 1] = turn
        turn.items[#turn.items + 1] =
          { id = e.uuid, type = "userMessage", treeEntryId = e.uuid, content = blocks(message.content) }
      elseif e.isCompactSummary == true then
        ensure(e)
        turn.items[#turn.items + 1] =
          { id = e.uuid, type = "compactionSummary", text = M.text(message.content), treeEntryId = e.uuid }
      else
        ensure(e)
        for i, b in ipairs(blocks(message.content)) do
          b = obj(b)
          local item = { id = e.uuid .. ":" .. i, treeEntryId = e.uuid }
          if e.type == "assistant" and b.type == "text" then
            item.type = "agentMessage"
            item.text = str(b.text)
          elseif b.type == "thinking" then
            item.type = "reasoning"
            item.content = { str(b.thinking) }
            item.summary = {}
          elseif b.type == "tool_use" and type(b.id) == "string" then
            item.id = b.id
            item.type = "dynamicToolCall"
            item.tool = str(b.name)
            item.arguments = obj(b.input)
            item.status = "inProgress"
            item.contentItems = {}
            tools[b.id] = item
          elseif b.type == "tool_result" then
            local tool = tools[b.tool_use_id]
            if tool then
              tool.status = b.is_error == true and "failed" or "completed"
              tool.success = b.is_error ~= true
              tool.contentItems = {
                {
                  type = "inputText",
                  text = type(b.content) == "string" and b.content or vim.json.encode(obj(b.content)),
                },
              }
            end
          end
          if item.type then
            turn.items[#turn.items + 1] = item
          end
        end
      end
    end
  end
  return {
    id = id or snapshot.id,
    cwd = snapshot.cwd,
    model = snapshot.model,
    name = snapshot.title or snapshot.preview or "Claude Code session",
    preview = snapshot.preview,
    turns = turns,
    replaceTurns = true,
    updatedAt = snapshot.updatedAt,
    createdAt = snapshot.createdAt,
    parentThreadId = snapshot.branch and ("claude:" .. snapshot.branch.parent) or nil,
  }
end
-- A list is intentionally metadata-only: full parsing is reserved for open/tree.
local function lite(path, id)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  local head = f:read(65536) or ""
  f:seek("set", math.max(0, stat.size - 65536))
  local tail = f:read(65536) or ""
  f:close()
  local result = {
    id = "claude:" .. id,
    updatedAt = stat.mtime.sec,
    createdAt = stat.birthtime and stat.birthtime.sec or stat.mtime.sec,
  }
  for _, chunk in ipairs({ head, tail }) do
    for line in chunk:gmatch("[^\n]+") do
      local ok, e = pcall(vim.json.decode, line)
      if ok and type(e) == "table" then
        result.cwd = type(e.cwd) == "string" and e.cwd or result.cwd
        if M.user(e) and not result.preview then
          result.preview = M.text(e.message.content):gsub("\n", " "):sub(1, 180)
        end
        if type(e.customTitle) == "string" then
          result.name = e.customTitle
        end
      end
    end
  end
  result.name = result.name or result.preview
  local branch = M.branch(id)
  if branch then
    result.parentThreadId = "claude:" .. branch.parent
  end
  return result.cwd and result.name and result or nil
end
function M.list(cwd)
  local out, seen = {}, {}
  local canonical = cwd and (vim.uv.fs_realpath(cwd) or vim.fs.normalize(cwd))
  for _, dir in ipairs(files(M.config_dir() .. "/projects")) do
    if dir.kind == "directory" then
      for _, file in ipairs(files(dir.path)) do
        local id = M.uuid(file.name:gsub("%.jsonl$", ""))
        if id and file.name:sub(-6) == ".jsonl" then
          local t = lite(file.path, id)
          if t and (not canonical or (vim.uv.fs_realpath(t.cwd) or vim.fs.normalize(t.cwd)) == canonical) then
            out[#out + 1] = t
            seen[id] = true
          end
        end
      end
    end
  end
  for _, file in ipairs(files(M.config_dir() .. "/coact-branches")) do
    local id = M.uuid(file.name:gsub("%.json$", ""))
    if id and not seen[id] then
      local snap = M.read(id)
      if snap and (not canonical or (vim.uv.fs_realpath(snap.cwd) or snap.cwd) == canonical) then
        local t = M.thread(snap)
        t.turns = nil
        out[#out + 1] = t
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.updatedAt or 0) > (b.updatedAt or 0)
  end)
  return out
end
function M.checkpoint(snapshot, uuid)
  local selected = snapshot.by_id[uuid]
  if not selected or not visible(selected) or selected.isCompactSummary == true then
    return nil, "Select a user or assistant message"
  end
  local target = selected
  local before = M.user(selected)
  if before then
    target = snapshot.by_id[value(selected.parentUuid)]
  end
  local seen = {}
  while target and not (target.type == "assistant" and M.text(obj(target.message).content) ~= "") do
    if seen[target.uuid] then
      return nil, "Cycle in history"
    end
    seen[target.uuid] = true
    target = snapshot.by_id[value(target.parentUuid)]
  end
  if not before and (not target or target.uuid ~= uuid) then
    return nil, "Select an assistant text response or a user message"
  end
  local chain, err = M.chain(snapshot, target and target.uuid)
  if not chain then
    return nil, err
  end
  local pending = {}
  for _, e in ipairs(chain) do
    for _, b in ipairs(blocks(obj(e.message).content)) do
      b = obj(b)
      if b.type == "tool_use" and type(b.id) == "string" then
        pending[b.id] = true
      elseif b.type == "tool_result" and type(b.tool_use_id) == "string" then
        pending[b.tool_use_id] = nil
      end
    end
  end
  if next(pending) then
    return nil, "Cannot rewind into an unfinished tool exchange; choose a completed response"
  end
  return {
    at = target and target.uuid or nil,
    chain = chain,
    draft = before and M.text(obj(selected.message).content) or nil,
  }
end
function M.tree(snapshot)
  local snapshots = { snapshot }
  local root = snapshot.branch and snapshot.branch.root or snapshot.session_id
  if root ~= snapshot.session_id then
    local s = M.read(root)
    if s then
      snapshots[#snapshots + 1] = s
    end
  end
  for _, file in ipairs(files(M.config_dir() .. "/coact-branches")) do
    local id = M.uuid(file.name:gsub("%.json$", ""))
    local meta = id and M.branch(id)
    if id ~= snapshot.session_id and meta and meta.root == root then
      local s = M.read(id)
      if s then
        snapshots[#snapshots + 1] = s
      end
    end
  end
  local nodes, by_id, owners = {}, {}, {}
  for _, s in ipairs(snapshots) do
    for _, e in ipairs(s.records) do
      if visible(e) and not by_id[e.uuid] then
        local parent = value(e.parentUuid)
        local seen = {}
        while parent and not visible(obj(s.by_id[parent])) do
          if seen[parent] then
            parent = nil
            break
          end
          seen[parent] = true
          parent = value(obj(s.by_id[parent]).parentUuid)
        end
        local msg = vim.deepcopy(obj(e.message))
        msg.role = e.type
        local node = { entry = { id = e.uuid, parentId = parent, type = "message", message = msg } }
        if e.uuid == s.leaf then
          node.label = s.id == snapshot.id and "current" or ("branch " .. s.session_id:sub(1, 8))
        end
        by_id[e.uuid] = node
        owners[e.uuid] = s.session_id
        nodes[#nodes + 1] = node
      end
    end
  end
  -- Parents must precede children for the shared tree's flat wire format.
  local sorted, added = {}, {}
  local function add(node, seen)
    if added[node.entry.id] then
      return
    end
    seen = seen or {}
    if seen[node.entry.id] then
      return
    end
    seen[node.entry.id] = true
    local parent = by_id[node.entry.parentId]
    if parent then
      add(parent, seen)
    end
    added[node.entry.id] = true
    sorted[#sorted + 1] = node
  end
  for _, node in ipairs(nodes) do
    add(node)
  end
  return { nodes = sorted, leafId = snapshot.leaf }, owners
end
return M
