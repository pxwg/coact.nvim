-- Adaptive frame scheduler for streamed transcript edits.
--
-- Streaming flushes are throttled per key (leading edge, then at most one
-- flush per frame). The frame interval adapts to main-loop utilisation, which
-- is measured with libuv prepare/check handles: the loop is busy from the
-- moment it wakes up from poll (check) until it is about to block again
-- (prepare). That window includes the work Neovim performs in response to our
-- edits (treesitter reparsing, redraw, other plugins' on_lines/TextChanged
-- handlers), not just our own Lua, so large transcripts back off to longer
-- frames instead of saturating the UI thread.
local uv = vim.uv or vim.loop

local M = {}

local busy_high = 0.4
local busy_low = 0.2
local grow_factor = 1.5
local shrink_factor = 0.8
local idle_release_ms = 1000

local monitor = {
  users = 0,
  busy_ns = 0,
  awake_at = nil,
  prepare = nil,
  check = nil,
}

local streams = {}

local function monitor_start()
  monitor.users = monitor.users + 1
  if monitor.prepare then
    return
  end
  local prepare = uv.new_prepare()
  local check = uv.new_check()
  if not prepare or not check then
    if prepare then
      prepare:close()
    end
    if check then
      check:close()
    end
    return
  end
  monitor.prepare = prepare
  monitor.check = check
  monitor.awake_at = uv.hrtime()
  check:start(function()
    monitor.awake_at = uv.hrtime()
  end)
  prepare:start(function()
    local awake_at = monitor.awake_at
    if awake_at then
      monitor.busy_ns = monitor.busy_ns + (uv.hrtime() - awake_at)
      monitor.awake_at = nil
    end
  end)
end

local function monitor_stop()
  monitor.users = math.max(0, monitor.users - 1)
  if monitor.users > 0 or not monitor.prepare then
    return
  end
  monitor.prepare:stop()
  monitor.prepare:close()
  monitor.check:stop()
  monitor.check:close()
  monitor.prepare = nil
  monitor.check = nil
  monitor.awake_at = nil
end

local function busy_snapshot(now)
  local busy = monitor.busy_ns
  if monitor.awake_at then
    busy = busy + (now - monitor.awake_at)
  end
  return busy
end

local function bounds()
  local ui = require("coact.config").get().ui or {}
  local min_ms = math.max(1, tonumber(ui.stream_flush_ms) or 16)
  local max_ms = math.max(min_ms, tonumber(ui.stream_flush_max_ms) or 200)
  return min_ms, max_ms
end

local function adapt(stream, now)
  local busy = busy_snapshot(now)
  if stream.last_fire then
    local wall = now - stream.last_fire
    if wall > 0 then
      local utilisation = (busy - stream.last_busy) / wall
      local min_ms, max_ms = bounds()
      if utilisation > busy_high then
        stream.interval = math.min(max_ms, stream.interval * grow_factor)
      elseif utilisation < busy_low then
        stream.interval = math.max(min_ms, stream.interval * shrink_factor)
      end
      stream.utilisation = utilisation
    end
  end
  stream.last_fire = now
  stream.last_busy = busy
end

local function release(key, stream)
  if streams[key] ~= stream or stream.armed or not stream.timer then
    return
  end
  stream.timer:stop()
  stream.timer:close()
  stream.timer = nil
  monitor_stop()
end

local function fire(key, stream)
  if streams[key] ~= stream or not stream.armed then
    return
  end
  stream.armed = false
  local callback = stream.callback
  stream.callback = nil
  adapt(stream, uv.hrtime())
  local ok, err = pcall(callback)
  if not stream.armed and stream.timer then
    stream.timer:start(
      idle_release_ms,
      0,
      vim.schedule_wrap(function()
        release(key, stream)
      end)
    )
  end
  if not ok then
    error(err, 0)
  end
end

--- Request `callback` to run on the next frame for `key`. Requests made
--- before the frame fires are coalesced; the latest callback wins.
function M.request(key, callback)
  key = tostring(key)
  local stream = streams[key]
  if not stream then
    local min_ms = bounds()
    stream = { interval = min_ms }
    streams[key] = stream
  end
  stream.callback = callback
  if stream.armed then
    return
  end
  stream.armed = true
  if not stream.timer then
    stream.timer = uv.new_timer()
    monitor_start()
  end
  local min_ms, max_ms = bounds()
  stream.interval = math.max(min_ms, math.min(max_ms, stream.interval))
  local wait = stream.interval
  if stream.last_fire then
    wait = math.max(0, stream.interval - (uv.hrtime() - stream.last_fire) / 1e6)
  end
  stream.timer:stop()
  stream.timer:start(
    math.floor(wait),
    0,
    vim.schedule_wrap(function()
      fire(key, stream)
    end)
  )
end

--- Drop a pending frame and release its timer.
function M.cancel(key)
  key = tostring(key)
  local stream = streams[key]
  if not stream then
    return
  end
  stream.armed = false
  stream.callback = nil
  release(key, stream)
  streams[key] = nil
end

--- Introspection for tests and diagnostics.
function M.stats(key)
  local stream = streams[tostring(key)]
  if not stream then
    return nil
  end
  return {
    interval = stream.interval,
    utilisation = stream.utilisation,
    armed = stream.armed == true,
  }
end

return M
