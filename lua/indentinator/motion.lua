--- Navigation motions and scope text objects for indentinator.nvim.

local scope = require("indentinator.scope")
local config = require("indentinator.config")

local api = vim.api

local M = {}

--- Helper to retrieve current active window and buffer.
---@param win integer|nil Window handle
---@return integer win Valid window handle
---@return integer buf Valid buffer handle
local function resolve_target(win)
  win = win or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  return win, buf
end

--- Jumps cursor to the top boundary line of the active scope.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_start(win)
  local target_win, buf = resolve_target(win)
  local ts = config.values.scope and config.values.scope.treesitter
  local scope_start, _, active_col = scope.get_scope(buf, target_win, ts)
  if scope_start then
    pcall(api.nvim_win_set_cursor, target_win, { scope_start, active_col or 0 })
    return true
  end
  return false
end

--- Jumps cursor to the bottom boundary line of the active scope.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_end(win)
  local target_win, buf = resolve_target(win)
  local ts = config.values.scope and config.values.scope.treesitter
  local _, scope_end, active_col = scope.get_scope(buf, target_win, ts)
  if scope_end then
    pcall(api.nvim_win_set_cursor, target_win, { scope_end, active_col or 0 })
    return true
  end
  return false
end

--- Selects the active scope block in Visual Line mode (`V`).
---@param inner boolean|nil If true, excludes scope header and footer boundary lines
---@param win integer|nil Window handle
---@return boolean Success status
function M.select_scope(inner, win)
  local target_win, buf = resolve_target(win)
  local ts = config.values.scope and config.values.scope.treesitter
  local scope_start, scope_end = scope.get_scope(buf, target_win, ts)
  if not scope_start or not scope_end then
    return false
  end

  local s_line = scope_start
  local e_line = scope_end
  if inner and (e_line - s_line >= 2) then
    s_line = s_line + 1
    e_line = e_line - 1
  end

  -- Enter Visual Line mode and set cursor boundaries
  api.nvim_win_set_cursor(target_win, { s_line, 0 })
  vim.cmd("normal! V")
  api.nvim_win_set_cursor(target_win, { e_line, 0 })
  return true
end

return M
