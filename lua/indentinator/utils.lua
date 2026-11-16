--- Buffer indentation, whitespace width, and line-scanning helpers.
---@class indentinator.utils
local M = {}

local api = vim.api

local SCAN_CHUNK = 64

--- Safely retrieves a positive numeric option value from a buffer.
---@param buf integer Buffer handle
---@param opt string Option name ("shiftwidth", "tabstop")
---@return integer|nil Option value or nil if invalid
function M.get_buf_opt(buf, opt)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, val = pcall(api.nvim_get_option_value, opt, { buf = buf })
  if ok and type(val) == "number" and val > 0 then
    return val
  end
  return nil
end

--- Computes the effective indentation step width for a buffer.
---@param buf integer Buffer handle
---@return integer Indentation width in display columns
function M.indent_width(buf)
  return M.get_buf_opt(buf, "shiftwidth") or M.get_buf_opt(buf, "tabstop") or 2
end

--- Retrieves the tabstop size setting of a buffer.
---@param buf integer Buffer handle
---@return integer Tabstop width (defaults to 8)
function M.buffer_tabstop(buf)
  return M.get_buf_opt(buf, "tabstop") or 8
end

--- Computes visual display column width of leading whitespace.
--- Fast path for space-only indent; handles tab expansion for tabs.
---@param lead string Leading whitespace substring
---@param tabstop integer Buffer tabstop setting
---@return integer Visual display column width
function M.lead_display_width(lead, tabstop)
  if not lead or lead == "" then
    return 0
  end

  if not lead:find("\t", 1, true) then
    return #lead
  end

  local display_col = 0
  for i = 1, #lead do
    if lead:byte(i) == 9 then
      display_col = display_col + (tabstop - (display_col % tabstop))
    else
      display_col = display_col + 1
    end
  end
  return display_col
end

--- Scans in chunks for the nearest non-blank line in one direction.
--- Chunking keeps the scan cheap on large files without one API call per line.
---@param buf integer Buffer handle
---@param start_row integer 1-indexed starting row
---@param first_row integer 1-indexed lowest row to visit
---@param last_row integer 1-indexed highest row to visit
---@param step integer 1 to scan down, -1 to scan up
---@return string|nil text Line text
---@return string|nil lead Leading whitespace string
---@return integer|nil row Line row index (1-indexed)
local function find_non_blank(buf, start_row, first_row, last_row, step)
  local current = start_row
  while current >= first_row and current <= last_row do
    local chunk_first, chunk_last
    if step > 0 then
      chunk_first = current
      chunk_last = math.min(last_row, current + SCAN_CHUNK - 1)
    else
      chunk_first = math.max(first_row, current - SCAN_CHUNK + 1)
      chunk_last = current
    end

    local ok, lines = pcall(api.nvim_buf_get_lines, buf, chunk_first - 1, chunk_last, false)
    if not ok or #lines == 0 then
      break
    end

    local from, to, delta = 1, #lines, 1
    if step < 0 then
      from, to, delta = #lines, 1, -1
    end
    for i = from, to, delta do
      local text = lines[i]
      local lead = text:match("^%s*")
      if text ~= "" and lead ~= text then
        return text, lead, chunk_first + i - 1
      end
    end

    current = step > 0 and (chunk_last + 1) or (chunk_first - 1)
  end
end

--- Scans upwards from start_row to find the nearest non-blank line.
---@param buf integer Buffer handle
---@param start_row integer Starting line row (1-indexed)
---@param max_depth integer|nil Maximum lines to search upward
---@return string|nil text Line text
---@return string|nil lead Leading whitespace string
---@return integer|nil row Line row index (1-indexed)
function M.find_non_blank_up(buf, start_row, max_depth)
  if not buf or not api.nvim_buf_is_valid(buf) or start_row < 1 then
    return nil
  end
  max_depth = max_depth or 1000
  return find_non_blank(buf, start_row, math.max(1, start_row - max_depth), start_row, -1)
end

--- Scans downwards from start_row to find the nearest non-blank line.
---@param buf integer Buffer handle
---@param start_row integer Starting line row (1-indexed)
---@param line_count integer Total line count in buffer
---@param max_depth integer|nil Maximum lines to search downward
---@return string|nil text Line text
---@return string|nil lead Leading whitespace string
---@return integer|nil row Line row index (1-indexed)
function M.find_non_blank_down(buf, start_row, line_count, max_depth)
  if not buf or not api.nvim_buf_is_valid(buf) or start_row > line_count then
    return nil
  end
  max_depth = max_depth or 1000
  return find_non_blank(buf, start_row, start_row, math.min(line_count, start_row + max_depth), 1)
end

--- Maps a display column to the byte offset of the first byte at or after it.
--- Unlike `lead_display_width`, this is the inverse direction and accounts for
--- tabs, whose display width differs from their one-byte length. Used when
--- placing the cursor (which expects a byte column) at a display-column target.
---@param line string Line text
---@param display_col integer 0-indexed target display column
---@param tabstop integer|nil Buffer tabstop (defaults to 8)
---@return integer byte_col 0-indexed byte offset
function M.display_to_byte_col(line, display_col, tabstop)
  if not line or line == "" or not display_col or display_col <= 0 then
    return 0
  end
  tabstop = tabstop or 8
  local col = 0
  local i = 1
  local len = #line
  while i <= len and col < display_col do
    if line:byte(i) == 9 then
      col = col + (tabstop - (col % tabstop))
    else
      col = col + 1
    end
    i = i + 1
  end
  return i - 1
end

return M
