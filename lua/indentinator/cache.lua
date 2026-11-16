--- Per-window scope memoization, dirty state, viewport ranges, and debounce timers.
--- The steady-state cursor fast path allocates nothing; allocations only occur
--- when the active scope actually changes.
---@class indentinator.cache
local M = {}

local uv = vim.uv

---@class indentinator.ScopeInfo
---@field scope_start integer 1-indexed start row of scope
---@field scope_end integer 1-indexed end row of scope
---@field active_col integer 0-indexed display column of active guide
---@field s_row integer 0-indexed start row of enclosing AST/indent construct
---@field s_col integer 0-indexed start col of enclosing AST/indent construct
---@field e_row integer 0-indexed end row of enclosing AST/indent construct
---@field e_col integer 0-indexed end col of enclosing AST/indent construct
---@field node table|userdata|nil TSNode reference
---@field is_ts boolean Whether scope was derived from Treesitter
---@field child_ranges integer[][] Array of {s_row, e_row} ranges for direct child scopes
---@field first_body_line integer|nil 1-indexed first line of inner scope body
---@field last_body_line integer|nil 1-indexed last line of inner scope body
---@field delimiter_spans table[] Array of {row, s_col, e_col, hl_group} for boundary tokens

---@class indentinator.WinCacheEntry
---@field buf integer Buffer handle
---@field tick integer Buffer changedtick at calculation time
---@field scope indentinator.ScopeInfo|nil Cached scope info

--- Per-window active scope cache.
---@type table<integer, indentinator.WinCacheEntry>
M.win_cache = {}

--- Buffers whose tree may be stale after an edit.
---@type table<integer, boolean>
M.buf_dirty = {}

--- Buffers with an active `nvim_buf_attach` listener.
---@type table<integer, boolean>
M.buf_attached = {}

--- Debounce timers keyed by window.
---@type table<integer, userdata>
M.timers = {}

--- Viewport ranges last painted in each window.
---@type table<integer, { buf: integer, start_line: integer, end_line: integer }>
M.rendered = {}

--- Checks whether a buffer has an attach listener.
---@param buf integer Buffer handle
---@return boolean
function M.is_attached(buf)
  return M.buf_attached[buf] == true
end

--- Marks a buffer as attached.
---@param buf integer Buffer handle
function M.mark_attached(buf)
  M.buf_attached[buf] = true
end

--- Records the viewport range most recently painted in a window.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param start_line integer 1-indexed first painted line
---@param end_line integer 1-indexed last painted line
function M.set_rendered(win, buf, start_line, end_line)
  M.rendered[win] = { buf = buf, start_line = start_line, end_line = end_line }
end

--- Returns the previously painted viewport range for a window/buffer pair.
---@param win integer Window handle
---@param buf integer Buffer handle
---@return integer|nil start_line 1-indexed first painted line
---@return integer|nil end_line 1-indexed last painted line
function M.get_rendered(win, buf)
  local entry = M.rendered[win]
  if entry and entry.buf == buf then
    return entry.start_line, entry.end_line
  end
  return nil, nil
end

--- Drops painted-range bookkeeping for every window showing a buffer.
---@param buf integer Buffer handle
function M.clear_rendered_buf(buf)
  for win, entry in pairs(M.rendered) do
    if entry.buf == buf then
      M.rendered[win] = nil
    end
  end
end

--- Checks whether the cursor is still within the cached scope node bounds
--- without having entered any nested child scope.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param cursor_row integer 1-indexed cursor row
---@param _cursor_col integer 0-indexed cursor column (unused; kept for call-site stability)
---@return boolean in_scope True if cursor remains inside the active scope node
function M.is_cursor_in_scope(win, buf, cursor_row, _cursor_col)
  local entry = M.win_cache[win]
  if not entry or entry.buf ~= buf then
    return false
  end

  local s = entry.scope
  if not s then
    return false
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if entry.tick ~= tick or M.buf_dirty[buf] then
    return false
  end

  local r = cursor_row - 1
  if r < s.s_row or r > s.e_row then
    return false
  end

  local children = s.child_ranges
  if children then
    for i = 1, #children do
      local cr = children[i]
      if r >= cr[1] and r <= cr[2] then
        return false
      end
    end
  end

  return true
end

--- Retrieves the cached scope info for a window if still valid.
---@param win integer Window handle
---@param buf integer Buffer handle
---@return indentinator.ScopeInfo|nil
function M.get_win_scope(win, buf)
  local entry = M.win_cache[win]
  if entry and entry.buf == buf and not M.buf_dirty[buf] then
    if entry.tick == vim.api.nvim_buf_get_changedtick(buf) then
      return entry.scope
    end
  end
  return nil
end

--- Stores the active scope info in the per-window cache.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param scope indentinator.ScopeInfo|nil
function M.set_win_scope(win, buf, scope)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = M.win_cache[win]
  if entry then
    entry.buf = buf
    entry.tick = tick
    entry.scope = scope
  else
    M.win_cache[win] = { buf = buf, tick = tick, scope = scope }
  end
end

--- Marks a buffer as dirty after a buffer modification event.
---@param buf integer Buffer handle
function M.mark_dirty(buf)
  M.buf_dirty[buf] = true
end

--- Checks whether a buffer is marked as dirty.
---@param buf integer Buffer handle
---@return boolean
function M.is_dirty(buf)
  return M.buf_dirty[buf] == true
end

--- Clears the dirty flag once the buffer has been parsed.
---@param buf integer Buffer handle
function M.mark_clean(buf)
  M.buf_dirty[buf] = nil
end

--- Starts or restarts the debounce timer for a window.
---@param win integer Window handle
---@param delay integer Delay in milliseconds
---@param fn fun() Callback, scheduled on the main loop
function M.debounce(win, delay, fn)
  local timer = M.timers[win]
  if timer then
    pcall(timer.stop, timer)
  else
    timer = uv.new_timer()
    M.timers[win] = timer
  end
  timer:start(delay, 0, vim.schedule_wrap(fn))
end

--- Stops and closes a window's debounce timer.
---@param win integer Window handle
function M.stop_timer(win)
  local timer = M.timers[win]
  if not timer then
    return
  end
  M.timers[win] = nil
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
end

--- Cleans tracking state and cached scopes associated with a buffer.
---@param buf integer Buffer handle
function M.clear_buf(buf)
  M.buf_dirty[buf] = nil
  M.buf_attached[buf] = nil

  for win, entry in pairs(M.win_cache) do
    if entry.buf == buf then
      M.win_cache[win] = nil
    end
  end

  M.clear_rendered_buf(buf)
end

--- Cleans tracking state and the debounce timer associated with a window.
---@param win integer Window handle
function M.clear_win(win)
  M.win_cache[win] = nil
  M.rendered[win] = nil
  M.stop_timer(win)
end

--- Invalidates all memoized scopes and dirty markers.
function M.clear()
  M.win_cache = {}
  M.buf_dirty = {}
end

return M
