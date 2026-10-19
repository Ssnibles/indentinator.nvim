--- Compatibility facade forwarding to indentinator.cache.
--- Preserves existing module exports for backward compatibility.
---@class indentinator.state
local cache = require("indentinator.cache")

local M = {}

M.state = cache.state

--- Purges scope calculation cache for a buffer or all buffers.
---@param buf integer|nil Buffer handle (nil clears all cache)
function M.clear_scope_cache(buf)
  if buf then
    cache.clear_buf(buf)
  else
    cache.clear()
  end
end

--- Purges internal tracking state associated with a buffer.
---@param buf integer|nil Buffer handle
function M.clear_buf_state(buf)
  if not buf then
    return
  end
  -- clear_buf already drops the buffer's extmarks bookkeeping and rendered ranges.
  cache.clear_buf(buf)
end

--- Stops and closes the debounce timer for a window.
---@param win integer Window handle
function M.clear_timer(win)
  cache.clear_win(win)
end

--- Purges tracking state associated with a window.
---@param win integer|nil Window handle
function M.clear_win_state(win)
  if not win then
    return
  end
  cache.clear_win(win)
end

return M
