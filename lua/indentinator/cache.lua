--- Scope memoization, cursor position tracking, and buffer dirty state management.
--- Optimised for minimal GC pressure with zero table allocations during steady-state cursor navigation.
---@class indentinator.cache
local M = {}

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
---@field cursor_row integer 1-indexed cursor row
---@field cursor_col integer 0-indexed cursor column
---@field scope indentinator.ScopeInfo|nil Cached scope info

--- Per-window active scope cache
---@type table<integer, indentinator.WinCacheEntry>
M.win_cache = {}

--- Per-buffer memoization cache (tick -> key -> result)
---@type table<integer, table>
M.buf_cache = {}

--- Dirty buffers tracking (marked true on on_bytes)
---@type table<integer, boolean>
M.buf_dirty = {}

--- Attached buffers tracking
---@type table<integer, boolean>
M.buf_attached = {}

--- Checks whether a buffer is attached.
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

--- Compatibility state table for backwards compatibility
M.state = {
  enabled = {},
  cache = M.buf_cache,
  timers = {},
  rendered = {},
}

--- Checks whether the cursor is still within the cached scope node bounds
--- without having entered any nested child scope.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param cursor_row integer 1-indexed cursor row
---@param cursor_col integer 0-indexed cursor column
---@return boolean in_scope True if cursor remains inside the active scope node
function M.is_cursor_in_scope(win, buf, cursor_row, cursor_col)
  local entry = M.win_cache[win]
  if not entry or entry.buf ~= buf then
    return false
  end

  local s = entry.scope
  if not s then
    return false
  end

  -- Invalidate if buffer changed
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if entry.tick ~= tick or M.buf_dirty[buf] then
    return false
  end

  local r = cursor_row - 1
  -- Check if cursor exited the active node bounds
  if r < s.s_row or r > s.e_row then
    return false
  end

  -- Check if cursor entered any child scope
  local children = s.child_ranges
  if children and #children > 0 then
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
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if entry.tick == tick then
      return entry.scope
    end
  end
  return nil
end

--- Stores the active scope info in the per-window cache.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param cursor_row integer 1-indexed cursor row
---@param cursor_col integer 0-indexed cursor col
---@param scope indentinator.ScopeInfo|nil
function M.set_win_scope(win, buf, cursor_row, cursor_col, scope)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local entry = M.win_cache[win]
  if not entry then
    entry = {
      buf = buf,
      tick = tick,
      cursor_row = cursor_row,
      cursor_col = cursor_col,
      scope = scope,
    }
    M.win_cache[win] = entry
  else
    entry.buf = buf
    entry.tick = tick
    entry.cursor_row = cursor_row
    entry.cursor_col = cursor_col
    entry.scope = scope
  end

  -- Also populate buf_cache for backward compatibility
  local bc = M.buf_cache[buf]
  if not bc or bc._tick ~= tick then
    bc = { _tick = tick }
    M.buf_cache[buf] = bc
    M.state.cache[buf] = bc
  end
  local ts_flag = (scope and scope.is_ts) and 1 or 0
  local key = string.format("%d:%d:%d:%d", win, cursor_row, cursor_col, ts_flag)
  if scope then
    bc[key] = { scope.scope_start, scope.scope_end, scope.active_col, scope.node }
  else
    bc[key] = false
  end
end

--- Marks a buffer as dirty after a buffer modification event.
---@param buf integer Buffer handle
function M.mark_dirty(buf)
  M.buf_dirty[buf] = true
  M.buf_cache[buf] = nil
  M.state.cache[buf] = nil
end

--- Checks whether a buffer is marked as dirty.
---@param buf integer Buffer handle
---@return boolean
function M.is_dirty(buf)
  return M.buf_dirty[buf] == true
end

--- Clears dirty flag once buffer has been parsed and processed.
---@param buf integer Buffer handle
function M.mark_clean(buf)
  M.buf_dirty[buf] = nil
end

--- Cleans tracking state and cached scopes associated with a buffer.
---@param buf integer|nil Buffer handle (nil cleans all)
function M.clear_buf(buf)
  if not buf then
    M.buf_cache = {}
    M.state.cache = {}
    M.buf_dirty = {}
    M.buf_attached = {}
    M.win_cache = {}
    return
  end

  M.buf_cache[buf] = nil
  M.state.cache[buf] = nil
  M.buf_dirty[buf] = nil
  M.buf_attached[buf] = nil

  for win, entry in pairs(M.win_cache) do
    if entry.buf == buf then
      M.win_cache[win] = nil
    end
  end
end

--- Cleans tracking state and timer associated with a window.
---@param win integer Window handle
function M.clear_win(win)
  M.win_cache[win] = nil
  local timer = M.state.timers[win]
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    M.state.timers[win] = nil
  end
end

--- Clears all scope caches across all buffers and windows.
function M.clear()
  M.buf_cache = {}
  M.state.cache = {}
  M.win_cache = {}
  M.buf_dirty = {}
end

return M
