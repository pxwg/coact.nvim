local M = {}
local util = require("coact.util")

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

local setting_keys = {
  "model",
  "model_provider",
  "service_tier",
  "reasoning_effort",
  "reasoning_summary",
  "personality",
}

local function first_present(...)
  for index = 1, select("#", ...) do
    local raw = select(index, ...)
    if raw ~= nil and raw ~= "" then
      return util.value(raw), true
    end
  end
  return nil, false
end

local function setting_value(settings, key)
  if type(settings) ~= "table" then
    return nil, false
  end
  local reasoning = type(settings.reasoning) == "table" and settings.reasoning or {}
  if key == "model" then
    return first_present(settings.model, settings.modelId, settings.modelName)
  end
  if key == "model_provider" then
    return first_present(settings.model_provider, settings.modelProvider)
  end
  if key == "service_tier" then
    return first_present(settings.service_tier, settings.serviceTier)
  end
  if key == "reasoning_effort" then
    return first_present(settings.reasoning_effort, settings.reasoningEffort, settings.effort, reasoning.effort)
  end
  if key == "reasoning_summary" then
    return first_present(settings.reasoning_summary, settings.reasoningSummary, settings.summary, reasoning.summary)
  end
  if key == "personality" then
    return first_present(settings.personality)
  end
  return nil, false
end

local function normalize_settings(settings)
  local normalized = {}
  local present = {}
  local any = false
  for _, key in ipairs(setting_keys) do
    local value, has_value = setting_value(settings, key)
    if has_value then
      normalized[key] = value
      present[key] = true
      any = true
    end
  end
  if not any then
    return nil, nil
  end
  return normalized, present
end

local function normalize_turn_settings(settings)
  local settings_values, present = normalize_settings(settings)
  if not settings_values or not present then
    return nil
  end
  local normalized = {}
  if present.model and settings_values.model then
    normalized.model = settings_values.model
  end
  if present.service_tier and settings_values.service_tier then
    normalized.service_tier = settings_values.service_tier
  end
  if present.reasoning_effort and settings_values.reasoning_effort then
    normalized.reasoning_effort = settings_values.reasoning_effort
  end
  if not normalized.model and not normalized.service_tier and not normalized.reasoning_effort then
    return nil
  end
  return normalized
end

local function merge_turn_settings(thread, turn_id, settings)
  local normalized = normalize_turn_settings(settings)
  if not normalized or not turn_id then
    return nil
  end
  thread.turn_settings = thread.turn_settings or {}
  local existing = thread.turn_settings[turn_id] or {}
  for key, value in pairs(normalized) do
    existing[key] = value
  end
  thread.turn_settings[turn_id] = existing
  return existing
end

function M.get_thread(thread_id)
  return thread_id and M.threads[thread_id] or nil
end

function M.ensure_thread(thread_id, attrs)
  if not thread_id or thread_id == "" then
    error("coact.nvim: missing thread id")
  end
  local thread = M.threads[thread_id]
  if not thread then
    thread = {
      id = thread_id,
      thread = nil,
      bufnr = nil,
      winid = nil,
      prompt_bufnr = nil,
      prompt_winid = nil,
      prompt_height = nil,
      ui_state = "preview",
      draft_lines = nil,
      draft_cursor = nil,
      cwd = nil,
      status = "unknown",
      title = nil,
      config = {},
      setting_clears = {},
      turns = {},
      turn_settings = {},
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
      pending_request = nil,
      pending_requests = {},
      pi_agent_active = false,
      pi_queue = { steering = {}, follow_up = {} },
      provider_client_id = nil,
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

-- pending_request remains the latest-entry compatibility field; the ordered
-- list keeps every queued Pi follow-up visible until its user event arrives.
local function synced_thread_pending_requests(thread)
  if type(thread) ~= "table" then
    return {}
  end
  local requests = type(thread.pending_requests) == "table" and thread.pending_requests or {}
  local latest = thread.pending_request
  if latest == nil then
    requests = {}
  else
    local found = false
    for _, request in ipairs(requests) do
      if request == latest then
        found = true
        break
      end
    end
    if not found then
      requests = { latest }
    end
  end
  thread.pending_requests = requests
  return requests
end

function M.get_thread_pending_requests(thread_or_id)
  local thread = type(thread_or_id) == "table" and thread_or_id or M.get_thread(thread_or_id)
  return synced_thread_pending_requests(thread)
end

function M.add_thread_pending_request(thread_or_id, request)
  local thread = type(thread_or_id) == "table" and thread_or_id or M.ensure_thread(thread_or_id)
  local requests = synced_thread_pending_requests(thread)
  local turn_id = type(request) == "table" and request.turn_id or nil
  for _, candidate in ipairs(requests) do
    if candidate == request or (turn_id and candidate.turn_id == turn_id) then
      thread.pending_request = candidate
      return candidate
    end
  end
  table.insert(requests, request)
  thread.pending_request = request
  return request
end

function M.has_thread_pending_request(thread_or_id, request)
  for _, candidate in ipairs(M.get_thread_pending_requests(thread_or_id)) do
    if candidate == request then
      return true
    end
  end
  return false
end

function M.remove_thread_pending_request(thread_or_id, request)
  local thread = type(thread_or_id) == "table" and thread_or_id or M.get_thread(thread_or_id)
  if not thread then
    return nil
  end
  local requests = synced_thread_pending_requests(thread)
  for index, candidate in ipairs(requests) do
    if candidate == request then
      table.remove(requests, index)
      thread.pending_request = requests[#requests]
      return candidate
    end
  end
  return nil
end

function M.clear_thread_pending_requests(thread_or_id, predicate)
  local thread = type(thread_or_id) == "table" and thread_or_id or M.get_thread(thread_or_id)
  if not thread then
    return {}
  end
  local kept = {}
  local removed = {}
  for _, request in ipairs(synced_thread_pending_requests(thread)) do
    if not predicate or predicate(request) then
      table.insert(removed, request)
    else
      table.insert(kept, request)
    end
  end
  thread.pending_requests = kept
  thread.pending_request = kept[#kept]
  return removed
end

function M.normalize_settings(settings)
  return normalize_settings(settings)
end

function M.apply_thread_settings(thread_or_id, settings)
  local thread = type(thread_or_id) == "table" and thread_or_id or M.ensure_thread(thread_or_id)
  local normalized, present = normalize_settings(settings)
  if not normalized or not present then
    return nil
  end
  thread.config = thread.config or {}
  thread.setting_clears = thread.setting_clears or {}
  for key in pairs(present) do
    thread.config[key] = normalized[key]
    if normalized[key] == nil then
      thread.setting_clears[key] = true
    else
      thread.setting_clears[key] = nil
    end
  end
  return thread.config
end

function M.effective_thread_settings(thread, base)
  local effective = {}
  local function overlay(settings)
    local normalized, present = normalize_settings(settings)
    if not normalized or not present then
      return
    end
    for key in pairs(present) do
      effective[key] = normalized[key]
    end
  end

  overlay(base)
  if type(thread) == "table" then
    overlay(thread.config)
    if thread.setting_clears then
      for _, key in ipairs(setting_keys) do
        if thread.setting_clears[key] then
          effective[key] = nil
        end
      end
    end
    overlay(thread.settings)
  end
  return effective
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
    token_usage = payload.token_usage or payload.tokenUsage,
    auto_compaction_enabled = util.value(payload.autoCompactionEnabled or payload.auto_compaction_enabled),
    provider_client_id = util.value(payload.providerClientId or payload.provider_client_id),
  })
  if payload.replaceTurns == true or payload.replace_turns == true then
    thread.turns = {}
    thread.turn_order = {}
    thread.items = {}
    thread.item_order = {}
    thread.item_turns = {}
    thread.turn_settings = {}
    thread.render_index = {}
    thread.folds = {}
  end
  M.apply_thread_settings(thread, payload)
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
  merge_turn_settings(thread, turn.id, turn)
  merge_turn_settings(thread, turn.id, turn.settings)
  merge_turn_settings(thread, turn.id, turn.config)
  if turn.items then
    for _, item in ipairs(turn.items) do
      M.upsert_item(thread_id, turn.id, item)
    end
  end
  return turn
end

function M.set_turn_settings(thread_id, turn_id, settings)
  if not thread_id then
    return nil
  end
  local thread = M.ensure_thread(thread_id)
  return merge_turn_settings(thread, turn_id, settings)
end

function M.upsert_item(thread_id, turn_id, item)
  local thread = M.ensure_thread(thread_id)
  if not item.id then
    return nil
  end
  local existing = thread.items[item.id] or {}
  local placement_changed = item.piMessageId ~= nil
    and (existing.piMessageId ~= item.piMessageId or existing.piContentIndex ~= item.piContentIndex)
  for key, value in pairs(item) do
    existing[key] = value
  end
  existing.id = item.id
  existing.type = item.type or existing.type or "unknown"
  thread.items[item.id] = existing
  thread.item_turns[item.id] = turn_id
  append_unique(thread.item_order, item.id)
  if placement_changed and existing.piMessageId and type(existing.piContentIndex) == "number" then
    -- A late authoritative block occupies its message's content slot, not the
    -- time at which it happened to arrive (e.g. empty/redacted thinking).
    local positions, ids = {}, {}
    for index, id in ipairs(thread.item_order) do
      if thread.items[id].piMessageId == existing.piMessageId then
        table.insert(positions, index)
        table.insert(ids, id)
      end
    end
    table.sort(ids, function(a, b)
      return thread.items[a].piContentIndex < thread.items[b].piContentIndex
    end)
    for index = #positions, 1, -1 do
      table.remove(thread.item_order, positions[index])
    end
    for index, id in ipairs(ids) do
      table.insert(thread.item_order, positions[1] + index - 1, id)
    end
  end
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
  vim.b[bufnr].coact_thread_id = thread.id
end

function M.thread_for_buf(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local thread_id = vim.b[bufnr].coact_thread_id
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
