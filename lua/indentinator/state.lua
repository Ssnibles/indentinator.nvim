---@class IndentinatorState
---@field enabled table<number, boolean> Enablement status per buffer
---@field windows table<number, table<number, number[]>> Line range viewport limits tracked per buffer and window
---@field attached table<number, boolean|number> Attachment status for buffer listeners
---@field current_indent table<number, number|nil> Active column index tracked per window
---@field last_cursor_row table<number, number|nil> Last cursor line tracked per window
---@field last_cursor_col table<number, number|nil> Last cursor column tracked per window
---@field timers table<number, uv_timer_t|nil> Per-buffer debounce timers for on_bytes renders

local M = {}

---@type IndentinatorState
M.state = {
  enabled = {},
  windows = {},
  attached = {},
  current_indent = {},
  last_cursor_row = {},
  last_cursor_col = {},
  timers = {},
}

--- Safely stops and closes a libuv timer handle if valid and not already closing.
---@param t uv_timer_t|nil The timer handle to close
function M.safe_close_timer(t)
  if t and not t:is_closing() then
    pcall(function()
      t:stop()
      t:close()
    end)
  end
end

--- Clears and closes any active timer handle associated with a buffer.
---@param buf number The buffer handle
function M.clear_timer(buf)
  local t = M.state.timers[buf]
  if t then
    M.safe_close_timer(t)
    M.state.timers[buf] = nil
  end
end

--- Purges all internal tracking state for a specified buffer.
---@param buf number The buffer handle
function M.clear_buf_state(buf)
  if not buf then return end
  M.clear_timer(buf)
  M.state.windows[buf] = nil
  M.state.enabled[buf] = nil
  M.state.attached[buf] = nil
end

--- Purges tracking state for a specified window across all buffers.
---@param win number The window handle
function M.clear_win_state(win)
  if not win then return end
  for _, ranges in pairs(M.state.windows) do
    ranges[win] = nil
  end
  if M.state.current_indent then M.state.current_indent[win] = nil end
  if M.state.last_cursor_row then M.state.last_cursor_row[win] = nil end
  if M.state.last_cursor_col then M.state.last_cursor_col[win] = nil end
end

return M
