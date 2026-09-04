--- Navigation motions and scope text objects for indentinator.nvim.

local scope = require("indentinator.scope")
local config = require("indentinator.config")

local api = vim.api

local M = {}

--- Helper to retrieve target window and buffer handles.
---@param win integer|nil Window handle
---@return integer win Valid window handle
---@return integer buf Valid buffer handle
local function resolve_target(win)
  win = win or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  return win, buf
end

--- Jumps cursor to the top boundary line of the active scope.
--- If already on the scope start line, jumps to the parent scope start.
--- Sets a jump mark so `<C-o>` can return to previous position.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_start(win)
  local target_win, buf = resolve_target(win)
  local ts = config.values.scope and config.values.scope.treesitter
  local scope_start, _, active_col, scope_node = scope.get_scope(buf, target_win, ts)
  if not scope_start then
    return false
  end

  local cursor = api.nvim_win_get_cursor(target_win)
  local cursor_line = cursor[1]

  -- If cursor is already at scope_start, navigate to parent scope start
  local target_line = scope_start
  local target_col = active_col or 0

  if cursor_line == scope_start then
    local p_start, _, p_col = scope.get_parent_scope(buf, target_win, scope_start, scope_node, ts)
    if p_start and p_start < scope_start then
      target_line = p_start
      target_col = p_col or 0
    end
  end

  -- Record jump position for jump list (<C-o>)
  vim.cmd("normal! m'")
  pcall(api.nvim_win_set_cursor, target_win, { target_line, target_col })
  return true
end

--- Jumps cursor to the bottom boundary line of the active scope.
--- If already on the scope end line, jumps to the parent scope end.
--- Sets a jump mark so `<C-o>` can return to previous position.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_end(win)
  local target_win, buf = resolve_target(win)
  local ts = config.values.scope and config.values.scope.treesitter
  local scope_start, scope_end, active_col, scope_node = scope.get_scope(buf, target_win, ts)
  if not scope_end then
    return false
  end

  local cursor = api.nvim_win_get_cursor(target_win)
  local cursor_line = cursor[1]

  -- If cursor is already at scope_end, navigate to parent scope end
  local target_line = scope_end
  local target_col = active_col or 0

  if cursor_line == scope_end and scope_start then
    local _, p_end, p_col = scope.get_parent_scope(buf, target_win, scope_start, scope_node, ts)
    if p_end and p_end > scope_end then
      target_line = p_end
      target_col = p_col or 0
    end
  end

  -- Record jump position for jump list (<C-o>)
  vim.cmd("normal! m'")
  pcall(api.nvim_win_set_cursor, target_win, { target_line, target_col })
  return true
end

--- Selects the active scope block in Visual Line mode (`V`).
--- Works seamlessly from normal mode, visual mode, and operator-pending mode.
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

  local mode = api.nvim_get_mode().mode
  if mode:sub(1, 1) == "V" then
    -- Already in visual line mode; update selection endpoints
    api.nvim_win_set_cursor(target_win, { s_line, 0 })
    vim.cmd("normal! o")
    api.nvim_win_set_cursor(target_win, { e_line, 0 })
  else
    api.nvim_win_set_cursor(target_win, { s_line, 0 })
    vim.cmd("normal! V")
    api.nvim_win_set_cursor(target_win, { e_line, 0 })
  end

  return true
end

return M
