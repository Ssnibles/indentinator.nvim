--- State management for indentinator.nvim.
--- Tracks per-buffer enablement states, cache, rendered viewport ranges, and debounce timers.

local M = {}

M.state = {
  enabled = {},
  cache = {},
  timers = {},
  rendered = {},
}

--- Purges scope calculation cache for a buffer or all buffers.
---@param buf integer|nil Buffer handle (nil clears all cache)
function M.clear_scope_cache(buf)
  if buf then
    M.state.cache[buf] = nil
  else
    M.state.cache = {}
  end
end

--- Purges internal tracking state associated with a buffer.
---@param buf integer|nil Buffer handle
function M.clear_buf_state(buf)
  if not buf then
    return
  end
  M.state.enabled[buf] = nil
  M.state.cache[buf] = nil
  M.state.rendered[buf] = nil
end

--- Stops and closes the debounce timer for a window.
---@param win integer Window handle
function M.clear_timer(win)
  local timer = M.state.timers[win]
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    M.state.timers[win] = nil
  end
end

--- Purges tracking state associated with a window.
---@param win integer|nil Window handle
function M.clear_win_state(win)
  if not win then
    return
  end
  M.clear_timer(win)
end

return M
