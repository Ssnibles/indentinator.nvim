--- State management for indentinator.nvim.
--- Tracks per-buffer enablement states and window viewport ranges.

local M = {}

--- Internal state data tables.
M.state = {
  enabled = {},
  windows = {},
}

--- Purges internal tracking state associated with a buffer.
---@param buf integer|nil Buffer handle
function M.clear_buf_state(buf)
  if not buf then
    return
  end
  M.state.enabled[buf] = nil
  M.state.windows[buf] = nil
end

--- Purges tracking state associated with a window.
---@param win integer|nil Window handle
function M.clear_win_state(win)
  if not win then
    return
  end
  for _, ranges in pairs(M.state.windows) do
    ranges[win] = nil
  end
end

return M
