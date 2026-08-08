--- State management for indentinator.nvim.
--- Encapsulates runtime buffer/window tracking tables and UV timer lifecycle handling.

---@class IndentinatorStateData
---@field enabled table<integer, boolean> Buffer enablement mapping
---@field windows table<integer, table<integer, integer[]>> Viewport line ranges tracked per buffer and window
---@field attached table<integer, boolean|integer> Buffer listener attachment flags
---@field current_indent table<integer, integer|nil> Active indent column index tracked per window
---@field last_cursor_row table<integer, integer|nil> Last cursor line tracked per window
---@field last_cursor_col table<integer, integer|nil> Last cursor column tracked per window
---@field last_leftcol table<integer, integer|nil> Last leftcol scroll position tracked per window
---@field timers table<integer, uv_timer_t|nil> Per-buffer debounce timers for text editing events

local M = {}

--- Global runtime state singleton instance.
---@type IndentinatorStateData
M.state = {
  enabled = {},
  windows = {},
  attached = {},
  current_indent = {},
  last_cursor_row = {},
  last_cursor_col = {},
  last_leftcol = {},
  timers = {},
}

--- Safely stops and closes a libuv timer handle if valid and not closing.
---@param timer uv_timer_t|nil The timer handle to close
function M.safe_close_timer(timer)
  if not timer or timer:is_closing() then
    return
  end

  pcall(function()
    timer:stop()
    timer:close()
  end)
end

--- Clears and closes any active debounce timer associated with a buffer.
---@param buf integer The buffer handle
function M.clear_timer(buf)
  local timer = M.state.timers[buf]
  if not timer then
    return
  end

  M.safe_close_timer(timer)
  M.state.timers[buf] = nil
end

--- Purges all internal tracking state associated with a buffer.
---@param buf integer|nil The buffer handle
function M.clear_buf_state(buf)
  if not buf then
    return
  end

  M.clear_timer(buf)
  M.state.windows[buf] = nil
  M.state.enabled[buf] = nil
  M.state.attached[buf] = nil
end

--- Purges all tracking state associated with a window across all buffers.
---@param win integer|nil The window handle
function M.clear_win_state(win)
  if not win then
    return
  end

  for _, ranges in pairs(M.state.windows) do
    ranges[win] = nil
  end

  M.state.current_indent[win] = nil
  M.state.last_cursor_row[win] = nil
  M.state.last_cursor_col[win] = nil
  M.state.last_leftcol[win] = nil
end

return M
