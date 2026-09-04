--- Utility functions for indentinator.nvim.
--- Handles buffer indentation calculations and leading whitespace display width.

local api = vim.api

local M = {}

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
  local sw = M.get_buf_opt(buf, "shiftwidth")
  if sw and sw > 0 then
    return sw
  end
  return M.get_buf_opt(buf, "tabstop") or 2
end

--- Retrieves the tabstop size setting of a buffer.
---@param buf integer Buffer handle
---@return integer Tabstop width (defaults to 8)
function M.buffer_tabstop(buf)
  return M.get_buf_opt(buf, "tabstop") or 8
end

--- Computes visual display column width of leading whitespace string.
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

--- Scans upwards from start_row to find nearest non-blank line.
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
  local min_allowed = math.max(1, start_row - max_depth)
  local current = start_row

  while current >= min_allowed do
    local chunk_start = math.max(min_allowed, current - 64 + 1)
    local ok, lines = pcall(api.nvim_buf_get_lines, buf, chunk_start - 1, current, false)
    if not ok or #lines == 0 then
      break
    end

    for i = #lines, 1, -1 do
      local text = lines[i]
      local lead = text:match("^%s*")
      if text ~= "" and lead ~= text then
        return text, lead, chunk_start + i - 1
      end
    end
    current = chunk_start - 1
  end

  return nil
end

--- Scans downwards from start_row to find nearest non-blank line.
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
  local max_allowed = math.min(line_count, start_row + max_depth)
  local current = start_row

  while current <= max_allowed do
    local chunk_end = math.min(max_allowed, current + 64 - 1)
    local ok, lines = pcall(api.nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then
      break
    end

    for i = 1, #lines do
      local text = lines[i]
      local lead = text:match("^%s*")
      if text ~= "" and lead ~= text then
        return text, lead, current + i - 1
      end
    end
    current = chunk_end + 1
  end

  return nil
end

return M
