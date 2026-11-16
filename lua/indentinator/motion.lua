--- Navigation motions and scope text objects for indentinator.nvim.
---@class indentinator.motion
local M = {}

local treesitter = require("indentinator.treesitter")
local config = require("indentinator.config")
local utils = require("indentinator.utils")

local api = vim.api

--- Retrieves target window and buffer handles.
---@param win integer|nil Window handle
---@return integer win Valid window handle
---@return integer buf Valid buffer handle
local function resolve_target(win)
  win = win or api.nvim_get_current_win()
  return win, api.nvim_win_get_buf(win)
end

--- Converts a display-column target into a byte column on a 1-indexed line.
--- Scope resolution reports tab-expanded display columns, but
--- `nvim_win_set_cursor` expects byte columns.
---@param buf integer Buffer handle
---@param line integer 1-indexed line number
---@param display_col integer|nil 0-indexed display column
---@return integer byte_col 0-indexed byte column
local function resolve_byte_col(buf, line, display_col)
  if not display_col or display_col <= 0 then
    return 0
  end
  local ok, lines = pcall(api.nvim_buf_get_lines, buf, line - 1, line, false)
  local text = (ok and lines and lines[1]) or ""
  return utils.display_to_byte_col(text, display_col, utils.buffer_tabstop(buf))
end

--- Jumps to a scope boundary, climbing to the parent scope when already there.
---@param win integer|nil Window handle
---@param boundary "start"|"end"
---@return boolean Success status
local function jump_to_boundary(win, boundary)
  local target_win, buf = resolve_target(win)
  local use_treesitter = config.get(buf).scope.treesitter
  local scope_start, scope_end, active_col, scope_node = treesitter.get_scope(buf, target_win, use_treesitter)

  local target_line = boundary == "start" and scope_start or scope_end
  if not target_line then
    return false
  end

  local cursor_line = api.nvim_win_get_cursor(target_win)[1]
  if cursor_line == target_line and scope_start then
    local p_start, p_end, p_col = treesitter.get_parent_scope(buf, target_win, scope_start, scope_node, use_treesitter)
    local parent_line = boundary == "start" and p_start or p_end
    local is_outer = parent_line
      and ((boundary == "start" and parent_line < target_line) or (boundary == "end" and parent_line > target_line))
    if is_outer then
      target_line = parent_line
      active_col = p_col
    end
  end

  -- Record the previous position for the jump list (<C-o>).
  vim.cmd("normal! m'")
  pcall(api.nvim_win_set_cursor, target_win, { target_line, resolve_byte_col(buf, target_line, active_col) })
  return true
end

--- Jumps cursor to the top boundary line of the active scope.
--- If already on the scope start line, jumps to the parent scope start.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_start(win)
  return jump_to_boundary(win, "start")
end

--- Jumps cursor to the bottom boundary line of the active scope.
--- If already on the scope end line, jumps to the parent scope end.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_end(win)
  return jump_to_boundary(win, "end")
end

--- Selects the active scope block in Visual Line mode (`V`).
--- Works from normal mode, visual mode, and operator-pending mode.
---@param inner boolean|nil If true, excludes scope header and footer boundary lines
---@param win integer|nil Window handle
---@return boolean Success status
function M.select_scope(inner, win)
  local target_win, buf = resolve_target(win)
  local use_treesitter = config.get(buf).scope.treesitter
  local scope_start, scope_end = treesitter.get_scope(buf, target_win, use_treesitter)
  if not scope_start or not scope_end then
    return false
  end

  local s_line = scope_start
  local e_line = scope_end
  if inner and (e_line - s_line >= 2) then
    s_line = s_line + 1
    e_line = e_line - 1
  end

  if api.nvim_get_mode().mode:sub(1, 1) == "V" then
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
