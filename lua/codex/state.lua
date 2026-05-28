local M = {}
local util = require("codex.util")

M.threads = {}
M.active_thread_id = nil
M.pending_server_requests = {}
M.render_timers = {}
M.cache = {}

local function append_unique(list, value)
  for _, existing in ipairs(list) do
    if existing == value then
      return
    end
  end
  table.insert(list, value)
end

function M.get_thread(thread_id)
  return thread_id and M.threads[thread_id] or nil
end

function M.ensure_thread(thread_id, attrs)
  if not thread_id or thread_id == "" then
    error("codex.nvim: missing thread id")
  end
  local thread = M.threads[thread_id]
  if not thread then
    thread = {
      id = thread_id,
      thread = nil,
      bufnr = nil,
      winid = nil,
      cwd = nil,
      status = "unknown",
      title = nil,
      config = {},
      turns = {},
      turn_order = {},
      items = {},
      item_order = {},
      item_turns = {},
      pending_approvals = {},
      generation = "idle",
      sync = "clean",
      lifecycle = "ready",
      local_blocks = {},
      timeline_blocks = {},
      raw_blocks = {},
      expanded_blocks = {},
      render_index = {},
      view_state = {},
      folds = {},
      fold_levels = {},
      pending_request = nil,
      status_message = nil,
      last_error = nil,
    }
    M.threads[thread_id] = thread
  end
  if attrs then
    for key, value in pairs(attrs) do
      thread[key] = value
    end
  end
  M.active_thread_id = thread_id
  return thread
end

function M.update_thread_from_payload(payload)
  if not payload then
    return nil
  end
  local thread = M.ensure_thread(payload.id, {
    thread = payload,
    cwd = util.value(payload.cwd),
    status = util.status_label(payload.status),
    status_payload = util.value(payload.status),
    title = util.value(payload.name) or util.value(payload.preview),
  })
  thread.config.model = util.value(payload.model) or thread.config.model
  thread.config.model_provider = util.value(payload.modelProvider) or thread.config.model_provider
  if payload.turns then
    for _, turn in ipairs(payload.turns) do
      M.add_turn(payload.id, turn)
    end
  end
  return thread
end

function M.add_turn(thread_id, turn)
  local thread = M.ensure_thread(thread_id)
  thread.turns[turn.id] = turn
  append_unique(thread.turn_order, turn.id)
  if turn.items then
    for _, item in ipairs(turn.items) do
      M.upsert_item(thread_id, turn.id, item)
    end
  end
  return turn
end

function M.upsert_item(thread_id, turn_id, item)
  local thread = M.ensure_thread(thread_id)
  if not item.id then
    return nil
  end
  local existing = thread.items[item.id] or {}
  for key, value in pairs(item) do
    existing[key] = value
  end
  existing.id = item.id
  existing.type = item.type or existing.type or "unknown"
  thread.items[item.id] = existing
  thread.item_turns[item.id] = turn_id
  append_unique(thread.item_order, item.id)
  return existing
end

function M.ensure_item(thread_id, turn_id, item_id, item_type)
  local thread = M.ensure_thread(thread_id)
  local item = thread.items[item_id]
  if not item then
    item = { id = item_id, type = item_type or "unknown" }
    thread.items[item_id] = item
    thread.item_turns[item_id] = turn_id
    append_unique(thread.item_order, item_id)
  end
  if item_type and (item.type == "unknown" or not item.type) then
    item.type = item_type
  end
  return item
end

function M.set_buffer(thread_id, bufnr, winid)
  local thread = M.ensure_thread(thread_id)
  thread.bufnr = bufnr
  thread.winid = winid
  return thread
end

function M.bind_buffer(thread, bufnr)
  thread.bufnr = bufnr
  vim.b[bufnr].codex_thread_id = thread.id
end

function M.thread_for_buf(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local thread_id = vim.b[bufnr].codex_thread_id
  return thread_id and M.get_thread(thread_id) or nil
end

function M.set_pending_request(request_id, request)
  M.pending_server_requests[tostring(request_id)] = request
end

function M.pop_pending_request(request_id)
  local key = tostring(request_id)
  local request = M.pending_server_requests[key]
  M.pending_server_requests[key] = nil
  return request
end

function M.set_cache(key, value)
  M.cache[key] = {
    value = value,
    time = vim.uv.now(),
  }
end

function M.get_cache(key, ttl_ms)
  local entry = M.cache[key]
  if not entry then
    return nil
  end
  if ttl_ms and ttl_ms > 0 and vim.uv.now() - entry.time > ttl_ms then
    M.cache[key] = nil
    return nil
  end
  return entry.value
end

return M
