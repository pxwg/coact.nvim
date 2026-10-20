-- Offsets into verbatim message text. Neovim works in UTF-8 bytes; Pi
-- extensions index JavaScript strings, i.e. UTF-16 code units.
local M = {}

local function char_len(byte)
  if not byte or byte < 0x80 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  end
  return 4
end

M.char_len = char_len

-- UTF-16 units in text:sub(1, bytes). Errors when bytes splits a character.
function M.utf16(text, bytes)
  local index, units = 1, 0
  while index <= bytes do
    local width = char_len(text:byte(index))
    assert(index + width - 1 <= bytes, "offset splits a UTF-8 character")
    units = units + (width == 4 and 2 or 1)
    index = index + width
  end
  return units
end

-- Byte length of the prefix holding the given UTF-16 units, or nil.
function M.bytes(text, units)
  local index, count = 1, 0
  while count < units and index <= #text do
    local width = char_len(text:byte(index))
    count = count + (width == 4 and 2 or 1)
    index = index + width
  end
  return count == units and index - 1 or nil
end

-- Zero-based {row, byte col} of a byte offset within text starting at first_row.
function M.position(text, first_row, offset)
  local row, col = first_row, 0
  for index = 1, offset do
    if text:byte(index) == 10 then
      row, col = row + 1, 0
    else
      col = col + 1
    end
  end
  return row, col
end

-- Byte offset of the start of each line in text.
function M.line_offsets(lines)
  local offsets, offset = {}, 0
  for index, line in ipairs(lines) do
    offsets[index] = offset
    offset = offset + #line + 1
  end
  return offsets
end

return M
