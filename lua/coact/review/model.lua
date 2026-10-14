-- Pure review model for in-buffer patch review.
--
-- A review keeps three immutable-or-derived texts per file:
--   B  original lines, P  proposed lines, A  accepted base, W  live buffer.
-- Pending hunks are always diff(A, W); nothing here stores buffer positions,
-- so user edits cannot make review state drift. Line lists only: no buffer API.
local M = {}

local function text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function slice(lines, start, count)
  local out = {}
  for index = start, start + count - 1 do
    out[#out + 1] = lines[index]
  end
  return out
end

local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for index = 1, #a do
    if a[index] ~= b[index] then
      return false
    end
  end
  return true
end

M.same_lines = same_lines

-- Common prefix/suffix fallback when vim.diff is unavailable or fails.
local function fallback_indices(a, b)
  local prefix = 0
  while prefix < #a and prefix < #b and a[prefix + 1] == b[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix == #a and prefix == #b then
    return {}
  end
  local suffix = 0
  while suffix < #a - prefix and suffix < #b - prefix and a[#a - suffix] == b[#b - suffix] do
    suffix = suffix + 1
  end
  local a_count = #a - prefix - suffix
  local b_count = #b - prefix - suffix
  return {
    {
      a_count > 0 and prefix + 1 or prefix,
      a_count,
      b_count > 0 and prefix + 1 or prefix,
      b_count,
    },
  }
end

-- Diff ranges in vim.diff "indices" form: { a_start, a_count, b_start, b_count }.
-- A zero count means "after line start". With ctxlen 0 hunks are separated by
-- at least one common line, which keeps decisions on one hunk independent.
function M.indices(a, b, algorithm)
  if same_lines(a, b) then
    return {}
  end
  local ok, result = pcall(vim.diff, text(a), text(b), {
    result_type = "indices",
    algorithm = algorithm or "minimal",
  })
  if not ok or type(result) ~= "table" then
    return fallback_indices(a, b)
  end
  return result
end

-- Spans use doubled coordinates: line l is point 2l-1, the gap after line k is
-- point 2k. A changed line range also covers its surrounding gaps.
function M.span(start, count)
  if count > 0 then
    return 2 * start - 2, 2 * (start + count - 1)
  end
  return 2 * start, 2 * start
end

function M.hunks(a, b, algorithm)
  local out = {}
  for _, range in ipairs(M.indices(a, b, algorithm)) do
    local a_start, a_count, b_start, b_count = range[1], range[2], range[3], range[4]
    local lo, hi = M.span(b_start, b_count)
    out[#out + 1] = {
      a_start = a_start,
      a_count = a_count,
      b_start = b_start,
      b_count = b_count,
      old_lines = slice(a, a_start, a_count),
      new_lines = slice(b, b_start, b_count),
      lo = lo,
      hi = hi,
    }
  end
  return out
end

-- Replace count lines at start (count 0: insert after start).
function M.splice(lines, start, count, replacement)
  local out = {}
  local first = count > 0 and start or start + 1
  for index = 1, first - 1 do
    out[#out + 1] = lines[index]
  end
  for _, line in ipairs(replacement) do
    out[#out + 1] = line
  end
  for index = first + count, #lines do
    out[#out + 1] = lines[index]
  end
  return out
end

-- Approving moves the hunk into the accepted base.
function M.approve(accepted, hunk)
  return M.splice(accepted, hunk.a_start, hunk.a_count, hunk.new_lines)
end

-- Rejecting restores the accepted base text inside the working text.
function M.reject(working, hunk)
  return M.splice(working, hunk.b_start, hunk.b_count, hunk.old_lines)
end

-- 0-based end-exclusive buffer rows replaced by a rejection.
function M.buffer_range(hunk)
  if hunk.b_count > 0 then
    return hunk.b_start - 1, hunk.b_start - 1 + hunk.b_count
  end
  return hunk.b_start, hunk.b_start
end

-- Map every unchanged line of a to its line in b.
function M.line_map(a, b, algorithm)
  local map = {}
  local a_line, b_line = 1, 1
  for _, range in ipairs(M.indices(a, b, algorithm)) do
    local a_start, a_count, b_start, b_count = range[1], range[2], range[3], range[4]
    local a_first = a_count > 0 and a_start or a_start + 1
    local b_first = b_count > 0 and b_start or b_start + 1
    while a_line < a_first do
      map[a_line] = b_line
      a_line = a_line + 1
      b_line = b_line + 1
    end
    a_line = a_first + a_count
    b_line = b_first + b_count
  end
  while a_line <= #a do
    map[a_line] = b_line
    a_line = a_line + 1
    b_line = b_line + 1
  end
  return map
end

local function map_gap(map, gap)
  if gap == 0 then
    return 0
  end
  if map[gap] then
    return map[gap]
  end
  if map[gap + 1] then
    return map[gap + 1] - 1
  end
  return nil
end

-- Agent provenance in proposal coordinates: inserted lines and the gaps of
-- pure deletions.
function M.agent_marks(base, proposed, algorithm)
  local marks = { lines = {}, gaps = {} }
  for _, range in ipairs(M.indices(base, proposed, algorithm)) do
    local p_start, p_count = range[3], range[4]
    if p_count > 0 then
      for line = p_start, p_start + p_count - 1 do
        marks.lines[#marks.lines + 1] = line
      end
    end
    if p_count == 0 then
      marks.gaps[#marks.gaps + 1] = p_start
    end
  end
  return marks
end

-- Project agent marks onto working text as intervals (the agent footprint).
-- Unchanged lines map exactly; agent lines the user rewrote or deleted map to
-- the whole region of that user edit and are flagged as edited.
function M.project_marks(marks, proposed, working, algorithm)
  local ranges = M.indices(proposed, working, algorithm)
  local map = M.line_map(proposed, working, algorithm)
  local function edited_span(p_line)
    for _, range in ipairs(ranges) do
      local first = range[2] > 0 and range[1] or range[1] + 1
      if p_line >= first and p_line < first + range[2] then
        if range[4] > 0 then
          return 2 * range[3] - 1, 2 * (range[3] + range[4] - 1) - 1
        end
        return 2 * range[3], 2 * range[3]
      end
    end
    return nil
  end
  local projected = { lines = {}, gaps = {} }
  for _, line in ipairs(marks.lines or {}) do
    if map[line] then
      table.insert(projected.lines, { lo = 2 * map[line] - 1, hi = 2 * map[line] - 1 })
    else
      local lo, hi = edited_span(line)
      if lo then
        table.insert(projected.lines, { lo = lo, hi = hi, edited = true })
      end
    end
  end
  for _, gap in ipairs(marks.gaps or {}) do
    local mapped = map_gap(map, gap)
    if mapped then
      table.insert(projected.gaps, { lo = 2 * mapped, hi = 2 * mapped })
    else
      local lo, hi = edited_span(gap)
      if lo then
        table.insert(projected.gaps, { lo = lo, hi = hi, edited = true })
      end
    end
  end
  local authored = {}
  for _, line in pairs(map) do
    authored[line] = true
  end
  projected.from_proposal = authored
  return projected
end

local function overlaps(item, hunk)
  return item.lo <= hunk.hi and item.hi >= hunk.lo
end

-- A hunk is the agent's when it meets the agent footprint: an agent line, or
-- an agent deletion where base lines are removed. Returns is_agent, edited;
-- edited means the user changed lines inside it.
function M.classify(projected, hunk)
  local agent, edited = false, false
  for _, item in ipairs(projected.lines or {}) do
    if overlaps(item, hunk) then
      agent = true
      edited = edited or item.edited == true
    end
  end
  if hunk.a_count > 0 then
    for _, item in ipairs(projected.gaps or {}) do
      if overlaps(item, hunk) then
        agent = true
        edited = edited or item.edited == true
      end
    end
  end
  if agent and projected.from_proposal then
    for line = hunk.b_start, hunk.b_start + hunk.b_count - 1 do
      if hunk.b_count > 0 and not projected.from_proposal[line] then
        edited = true
      end
    end
  end
  return agent, agent and edited
end

function M.is_agent(projected, hunk)
  return (M.classify(projected, hunk))
end

-- Distance from a 1-based cursor line, in half lines.
function M.distance(hunk, line)
  local point = 2 * line - 1
  if point < hunk.lo then
    return hunk.lo - point
  elseif point > hunk.hi then
    return point - hunk.hi
  end
  return 0
end

-- Closest hunk to the cursor; ties prefer the hunk below the cursor.
function M.nearest(hunks, line)
  local point = 2 * line - 1
  local best, best_key
  for _, hunk in ipairs(hunks or {}) do
    local key = { M.distance(hunk, line), hunk.lo >= point and 0 or 1 }
    if not best or key[1] < best_key[1] or (key[1] == best_key[1] and key[2] < best_key[2]) then
      best, best_key = hunk, key
    end
  end
  return best
end

-- Find the fresh hunk with the snapshot's content, nearest its old position.
function M.resolve(hunks, snapshot)
  if not snapshot then
    return nil
  end
  local best, best_distance
  for _, hunk in ipairs(hunks or {}) do
    if
      same_lines(hunk.old_lines, snapshot.old_lines or {}) and same_lines(hunk.new_lines, snapshot.new_lines or {})
    then
      local distance = math.abs((hunk.lo or 0) - (snapshot.lo or 0))
      if not best or distance < best_distance then
        best, best_distance = hunk, distance
      end
    end
  end
  return best
end

-- Find needle at the start row nearest expected (0-based), not before floor.
-- Equidistant distinct matches are ambiguous.
function M.find_nearest(lines, needle, expected, floor)
  floor = floor or 0
  if #needle == 0 then
    return math.max(floor, math.min(expected, #lines))
  end
  local best, best_distance, tie
  for start = floor, #lines - #needle do
    local ok = true
    for index = 1, #needle do
      if lines[start + index] ~= needle[index] then
        ok = false
        break
      end
    end
    if ok then
      local distance = math.abs(start - expected)
      if not best or distance < best_distance then
        best, best_distance, tie = start, distance, false
      elseif distance == best_distance then
        tie = true
      end
    end
  end
  if best and tie then
    return nil, "ambiguous"
  end
  return best, best and nil or "missing"
end

-- Apply parsed unified hunks ({ old_start, old_lines, new_lines, header }) to
-- lines, locating each hunk nearest its header position.
function M.apply_hunks(lines, hunks)
  local out = vim.deepcopy(lines)
  local offset = 0
  local floor = 0
  for _, hunk in ipairs(hunks or {}) do
    local old_lines = hunk.old_lines or {}
    local new_lines = hunk.new_lines or {}
    local declared = #old_lines == 0 and (hunk.old_start or 0) or (hunk.old_start or 1) - 1
    local start, err = M.find_nearest(out, old_lines, declared + offset, floor)
    if not start then
      return nil, err, hunk
    end
    local replaced = {}
    for index = 1, start do
      replaced[#replaced + 1] = out[index]
    end
    for _, line in ipairs(new_lines) do
      replaced[#replaced + 1] = line
    end
    for index = start + #old_lines + 1, #out do
      replaced[#replaced + 1] = out[index]
    end
    out = replaced
    offset = start - declared + #new_lines - #old_lines
    floor = start + #new_lines
  end
  return out
end

-- Find anchor text in lines and return its 1-based line range. Prefer an
-- occurrence intersecting a preferred line set.
function M.locate(lines, anchor, preferred)
  anchor = tostring(anchor or ""):gsub("^\n+", ""):gsub("\n+$", "")
  if anchor == "" or #lines == 0 then
    return nil
  end
  local joined = table.concat(lines, "\n")
  local starts = { 1 }
  for index = 1, #lines - 1 do
    starts[index + 1] = starts[index] + #lines[index] + 1
  end
  local function line_of(offset)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= offset then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo
  end
  local first_match
  local init = 1
  for _ = 1, 200 do
    local first, last = joined:find(anchor, init, true)
    if not first then
      break
    end
    local range = { line_of(first), line_of(last) }
    first_match = first_match or range
    for line = range[1], range[2] do
      if preferred and preferred[line] then
        return range[1], range[2]
      end
    end
    init = first + 1
  end
  if first_match then
    return first_match[1], first_match[2]
  end
  return nil
end

-- Anchor model notes in proposal coordinates. Anchors match proposed text, or
-- removed base text for deletions; missing anchors attach to the first change.
function M.anchor_notes(notes, base, proposed, algorithm)
  local ranges = M.indices(base, proposed, algorithm)
  local agent_lines, base_lines = {}, {}
  for _, range in ipairs(ranges) do
    for line = range[3], range[3] + range[4] - 1 do
      agent_lines[line] = true
    end
    for line = range[1], range[1] + range[2] - 1 do
      base_lines[line] = range
    end
  end
  local function proposal_range(range)
    if range[4] > 0 then
      return { first = range[3], last = range[3] + range[4] - 1 }
    end
    return { gap = range[3] }
  end
  local anchored = {}
  for _, item in ipairs(notes or {}) do
    local note = type(item) == "table" and vim.trim(tostring(item.note or "")) or ""
    if note ~= "" then
      local anchor = type(item.anchor) == "string" and item.anchor or ""
      local target
      if vim.trim(anchor) == "" then
        target = ranges[1] and proposal_range(ranges[1]) or nil
      else
        local first, last = M.locate(proposed, anchor, agent_lines)
        if first then
          target = { first = first, last = last }
        else
          local base_first = M.locate(base, anchor, base_lines)
          local range = base_first and base_lines[base_first] or nil
          target = range and proposal_range(range) or nil
        end
      end
      if target then
        target.note = note
        anchored[#anchored + 1] = target
      end
    end
  end
  return anchored
end

-- Project anchored notes onto working text spans; rewritten anchors vanish.
function M.project_notes(anchored, map)
  local out = {}
  for _, item in ipairs(anchored or {}) do
    if item.gap then
      local mapped = map_gap(map, item.gap)
      if mapped then
        out[#out + 1] = { lo = 2 * mapped, hi = 2 * mapped, note = item.note }
      end
    else
      local first, last
      for line = item.first, item.last do
        local mapped = map[line]
        if mapped then
          first = first and math.min(first, mapped) or mapped
          last = last and math.max(last, mapped) or mapped
        end
      end
      if first then
        out[#out + 1] = { lo = 2 * first - 1, hi = 2 * last - 1, note = item.note }
      end
    end
  end
  return out
end

function M.notes_for(projected, hunk)
  local out = {}
  for _, item in ipairs(projected or {}) do
    if item.lo <= hunk.hi and item.hi >= hunk.lo then
      out[#out + 1] = item.note
    end
  end
  return out
end

return M
