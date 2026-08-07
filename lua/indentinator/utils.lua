local config = require("indentinator.config")

local M = {}

--- Safely gets a numeric option value from a buffer.
---@param buf number The buffer handle
---@param opt string The option name
---@return number|nil The option value if valid, or nil
function M.get_buf_opt(buf, opt)
  local ok, val = pcall(vim.api.nvim_get_option_value, opt, { buf = buf })
  if ok and type(val) == "number" and val > 0 then return val end
  return nil
end

--- Computes the indentation width for a given buffer.
---@param buf number The buffer handle
---@return number The resolved indentation step width
function M.indent_width(buf)
  local custom_width = config.resolve_config(buf, "indent_width")
  if custom_width then return custom_width end
  return M.get_buf_opt(buf, "shiftwidth") or M.get_buf_opt(buf, "tabstop") or 8
end

--- Retrieves the tabstop configuration of a buffer.
---@param buf number The buffer handle
---@return number The tabstop size
function M.buffer_tabstop(buf)
  return M.get_buf_opt(buf, "tabstop") or 8
end

--- Computes the display width in columns of a leading whitespace substring.
---@param lead string The leading whitespace characters
---@param tabstop number The tabstop setting of the buffer
---@return number The total display column width
function M.lead_display_width(lead, tabstop)
  if not lead:find("\t", 1, true) then
    return #lead
  end
  local display_col = 0
  local len = #lead
  local i = 1
  while i <= len do
    local byte = lead:byte(i)
    if byte == 9 then
      display_col = display_col + (tabstop - (display_col % tabstop))
    else
      display_col = display_col + 1
    end
    i = i + 1
  end
  return display_col
end

--- Finds the first non-blank line scanning upwards from start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@return string|nil The text content of the line
---@return string|nil The leading whitespace of the line
---@return number|nil The line index (1-indexed)
function M.find_non_blank_up(buf, start_row)
  local chunk_size = 100
  local current = start_row
  while current > 0 do
    local chunk_start = math.max(1, current - chunk_size + 1)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, chunk_start - 1, current, false)
    if not ok or #lines == 0 then break end
    for i = #lines, 1, -1 do
      local t = lines[i]
      local l = t:match("^%s*")
      if t ~= "" and l ~= t then
        return t, l, chunk_start + i - 1
      end
    end
    current = chunk_start - 1
  end
  return nil
end

--- Finds the first non-blank line scanning downwards from start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param line_count number The total line count in the buffer
---@return string|nil The text content of the line
---@return string|nil The leading whitespace of the line
---@return number|nil The line index (1-indexed)
function M.find_non_blank_down(buf, start_row, line_count)
  local chunk_size = 100
  local current = start_row
  while current <= line_count do
    local chunk_end = math.min(line_count, current + chunk_size - 1)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then break end
    for i = 1, #lines do
      local t = lines[i]
      local l = t:match("^%s*")
      if t ~= "" and l ~= t then
        return t, l, current + i - 1
      end
    end
    current = chunk_end + 1
  end
  return nil
end

--- Find the indentation display width of the first non-blank line above start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param tabstop number The tabstop setting
---@return number The indentation display width (or 0 if none found)
function M.find_indent_above(buf, start_row, tabstop)
  local t, l = M.find_non_blank_up(buf, start_row)
  if t and l then
    return M.lead_display_width(l, tabstop)
  end
  return 0
end

--- Find the indentation display width of the first non-blank line below start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param line_count number The total line count in the buffer
---@param tabstop number The tabstop setting
---@return number The indentation display width (or 0 if none found)
function M.find_indent_below(buf, start_row, line_count, tabstop)
  local t, l = M.find_non_blank_down(buf, start_row, line_count)
  if t and l then
    return M.lead_display_width(l, tabstop)
  end
  return 0
end

--- Calculates the active indentation guide column based on the cursor position.
---@param buf number The buffer handle
---@param win number The window handle
---@return number|nil The active column index, or nil if none
function M.get_current_indent_col(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then return nil end

  local target_row = row
  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, target_row - 1, target_row, false)
  if not ok_l or #lines == 0 then return nil end

  local text = lines[1] or ""
  local lead = text:match("^%s*")

  -- If current line is blank, traverse surrounding lines to determine active context
  if text == "" or lead == text then
    local res_text, res_lead, res_row = M.find_non_blank_up(buf, target_row - 1)
    if res_text then
      text = res_text
      lead = res_lead
      target_row = res_row
    else
      res_text, res_lead, res_row = M.find_non_blank_down(buf, target_row + 1, line_count)
      if res_text then
        text = res_text
        lead = res_lead
        target_row = res_row
      end
    end
  end

  if text == "" or lead == text then return nil end

  local width = M.indent_width(buf)
  local tabstop = M.buffer_tabstop(buf)

  local display_col = M.lead_display_width(lead, tabstop)
  local aligned_current = math.floor(display_col / width) * width

  -- Look ahead for the next non-blank line to detect if current line starts a block
  local next_aligned = nil
  local next_text, next_lead = M.find_non_blank_down(buf, target_row + 1, line_count)
  if next_text then
    local next_display_col = M.lead_display_width(next_lead, tabstop)
    next_aligned = math.floor(next_display_col / width) * width
  end

  local active_col
  if next_aligned and next_aligned > aligned_current then
    -- Current line starts a deeper scope (e.g. block header), highlight its own level
    active_col = aligned_current
  else
    -- Current line is inside or closing a scope, highlight parent scope level
    active_col = aligned_current - width
  end

  if active_col < 0 then return nil end
  local show_first = config.resolve_config(buf, "show_first_indent_level")
  if active_col == 0 and not show_first then return nil end
  return active_col
end

return M
