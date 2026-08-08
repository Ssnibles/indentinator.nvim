--- Utility functions for indentinator.nvim.
--- Handles buffer option retrieval, leading whitespace display width, and blank line searches.

local config = require("indentinator.config")

local api = vim.api
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_get_option_value = api.nvim_get_option_value
local nvim_win_get_cursor = api.nvim_win_get_cursor
local nvim_buf_line_count = api.nvim_buf_line_count

--- Maximum lines to scan upwards/downwards when searching across blank line gaps.
local MAX_SEARCH_DEPTH = 2000

local M = {}

--- Safely retrieves a positive numeric option value from a buffer.
---@param buf integer The buffer handle
---@param opt string Option name (e.g. "shiftwidth", "tabstop")
---@return integer|nil The numeric option value or nil if invalid
function M.get_buf_opt(buf, opt)
  local ok, val = pcall(nvim_get_option_value, opt, { buf = buf })
  if ok and type(val) == "number" and val > 0 then
    return val
  end
  return nil
end

--- Computes the effective indentation step width for a buffer.
---@param buf integer The buffer handle
---@param ft string|nil Optional pre-fetched filetype string
---@return integer The resolved indentation width in display columns
function M.indent_width(buf, ft)
  local custom_width = config.resolve_config(buf, "indent_width", ft)
  if custom_width then
    return custom_width
  end
  return M.get_buf_opt(buf, "shiftwidth") or M.get_buf_opt(buf, "tabstop") or 8
end

--- Retrieves the tabstop size setting of a buffer.
---@param buf integer The buffer handle
---@return integer Tabstop width (defaults to 8)
function M.buffer_tabstop(buf)
  return M.get_buf_opt(buf, "tabstop") or 8
end

--- Computes the visual display column width of leading whitespace characters.
--- Fast path for space-only indent; handles tabstop expansions for tabs.
---@param lead string Leading whitespace substring
---@param tabstop integer Buffer tabstop setting
---@return integer Visual display column width
function M.lead_display_width(lead, tabstop)
  if not lead or lead == "" then
    return 0
  end

  -- Fast path for space-only indentation
  if not lead:find("\t", 1, true) then
    return #lead
  end

  local display_col = 0
  local len = #lead
  for i = 1, len do
    if lead:byte(i) == 9 then -- Tab character ASCII byte
      display_col = display_col + (tabstop - (display_col % tabstop))
    else
      display_col = display_col + 1
    end
  end
  return display_col
end

--- Scans upwards from start_row to find the nearest non-blank line.
---@param buf integer The buffer handle
---@param start_row integer Starting line row (1-indexed)
---@return string|nil text Line text
---@return string|nil lead Leading whitespace string
---@return integer|nil row Line row index (1-indexed)
function M.find_non_blank_up(buf, start_row)
  local chunk_size = 100
  local current = start_row
  local min_allowed = math.max(1, start_row - MAX_SEARCH_DEPTH)

  while current >= min_allowed do
    local chunk_start = math.max(min_allowed, current - chunk_size + 1)
    local ok, lines = pcall(nvim_buf_get_lines, buf, chunk_start - 1, current, false)
    if not ok or #lines == 0 then
      break
    end

    for i = #lines, 1, -1 do
      local line_text = lines[i]
      local lead = line_text:match("^%s*")
      if line_text ~= "" and lead ~= line_text then
        return line_text, lead, chunk_start + i - 1
      end
    end
    current = chunk_start - 1
  end

  return nil
end

--- Scans downwards from start_row to find the nearest non-blank line.
---@param buf integer The buffer handle
---@param start_row integer Starting line row (1-indexed)
---@param line_count integer Total line count in buffer
---@return string|nil text Line text
---@return string|nil lead Leading whitespace string
---@return integer|nil row Line row index (1-indexed)
function M.find_non_blank_down(buf, start_row, line_count)
  local chunk_size = 100
  local current = start_row
  local max_allowed = math.min(line_count, start_row + MAX_SEARCH_DEPTH)

  while current <= max_allowed do
    local chunk_end = math.min(max_allowed, current + chunk_size - 1)
    local ok, lines = pcall(nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then
      break
    end

    for i = 1, #lines do
      local line_text = lines[i]
      local lead = line_text:match("^%s*")
      if line_text ~= "" and lead ~= line_text then
        return line_text, lead, current + i - 1
      end
    end
    current = chunk_end + 1
  end

  return nil
end

--- Finds the indentation display width of the nearest non-blank line above start_row.
---@param buf integer Buffer handle
---@param start_row integer Starting line row (1-indexed)
---@param tabstop integer Tabstop setting
---@return integer Display width (0 if none found)
function M.find_indent_above(buf, start_row, tabstop)
  local text, lead = M.find_non_blank_up(buf, start_row)
  if text and lead then
    return M.lead_display_width(lead, tabstop)
  end
  return 0
end

--- Finds the indentation display width of the nearest non-blank line below start_row.
---@param buf integer Buffer handle
---@param start_row integer Starting line row (1-indexed)
---@param line_count integer Total line count in buffer
---@param tabstop integer Tabstop setting
---@return integer Display width (0 if none found)
function M.find_indent_below(buf, start_row, line_count, tabstop)
  local text, lead = M.find_non_blank_down(buf, start_row, line_count)
  if text and lead then
    return M.lead_display_width(lead, tabstop)
  end
  return 0
end

--- Calculates the active indentation guide column based on current cursor position.
---@param buf integer The buffer handle
---@param win integer The window handle
---@return integer|nil Active guide column index, or nil if inactive
function M.get_current_indent_col(buf, win)
  local line_count = nvim_buf_line_count(buf)
  if line_count == 0 then
    return nil
  end

  local cursor = nvim_win_get_cursor(win)
  local target_row = cursor[1]

  local ok_lines, lines = pcall(nvim_buf_get_lines, buf, target_row - 1, target_row, false)
  if not ok_lines or #lines == 0 then
    return nil
  end

  local text = lines[1] or ""
  local lead = text:match("^%s*")

  -- If target line is blank, traverse surrounding lines to infer active context
  if text == "" or lead == text then
    local up_text, up_lead, up_row = M.find_non_blank_up(buf, target_row - 1)
    if up_text and up_lead then
      text = up_text
      lead = up_lead
      target_row = up_row
    else
      local down_text, down_lead, down_row = M.find_non_blank_down(buf, target_row + 1, line_count)
      if down_text and down_lead then
        text = down_text
        lead = down_lead
        target_row = down_row
      end
    end
  end

  if text == "" or lead == text then
    return nil
  end

  local width = M.indent_width(buf)
  local tabstop = M.buffer_tabstop(buf)

  local display_col = M.lead_display_width(lead, tabstop)
  local aligned_current = math.floor(display_col / width) * width

  -- Look ahead for next non-blank line to detect if current line is a block header
  local next_aligned = nil
  local next_text, next_lead = M.find_non_blank_down(buf, target_row + 1, line_count)
  if next_text and next_lead then
    local next_display_col = M.lead_display_width(next_lead, tabstop)
    next_aligned = math.floor(next_display_col / width) * width
  end

  local active_col
  if next_aligned and next_aligned > aligned_current then
    -- Current line starts a deeper scope (e.g. function/if block header)
    active_col = aligned_current
  else
    -- Current line is inside or closing a scope block
    active_col = aligned_current - width
  end

  if active_col < 0 then
    return nil
  end

  local show_first = config.resolve_config(buf, "show_first_indent_level")
  if active_col == 0 and not show_first then
    return nil
  end

  return active_col
end

return M
