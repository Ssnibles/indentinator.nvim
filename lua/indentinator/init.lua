--- Main entry point and facade for indentinator.nvim.
--- Handles plugin setup, scope navigation API, debounced rendering, and event listeners.

local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local render = require("indentinator.render")
local scope = require("indentinator.scope")

local api = vim.api
local nvim_get_current_win = api.nvim_get_current_win
local nvim_get_current_buf = api.nvim_get_current_buf
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_list_wins = api.nvim_list_wins

local M = {}

local AUGROUP = "Indentinator"
local uv = vim.uv or vim.loop
local render_timer = nil

--- Active plugin configuration reference
M.config = config.values

--- Helper function to iterate active valid windows
---@param fn fun(win: integer, buf: integer)
local function for_each_active_win(fn)
  for _, win in ipairs(nvim_list_wins()) do
    if nvim_win_is_valid(win) then
      local ok_b, buf = pcall(nvim_win_get_buf, win)
      if ok_b and buf and nvim_buf_is_loaded(buf) then
        fn(win, buf)
      end
    end
  end
end

--- Debounced render trigger for frequent events (CursorMoved, WinScrolled)
---@param buf integer Buffer handle
---@param win integer Window handle
local function debounced_render(buf, win)
  local delay = config.values.debounce_ms or 0
  if delay <= 0 then
    render.render(buf, win)
    return
  end

  if render_timer then
    pcall(function() render_timer:stop() end)
  else
    render_timer = uv.new_timer()
  end

  render_timer:start(delay, 0, vim.schedule_wrap(function()
    if nvim_win_is_valid(win) then
      render.render(buf, win)
    end
  end))
end

--- Registers autocommands for cursor movements, buffer lifecycle, and window resizes.
local function setup_autocmds()
  api.nvim_create_augroup(AUGROUP, { clear = true })

  -- Cursor movement updates active scope guide (debounced)
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, buf = pcall(nvim_win_get_buf, win)
        if ok_b and buf then
          debounced_render(buf, win)
        end
      end
    end,
  })

  -- Window focus and view changes
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinScrolled", "WinResized", "VimResized" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, buf = pcall(nvim_win_get_buf, win)
        if ok_b and buf then
          debounced_render(buf, win)
        end
      end
    end,
  })

  -- Clean up state when window closes
  api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(e)
      local win = tonumber(e.match)
      if win then
        state_mod.clear_win_state(win)
      end
    end,
  })

  -- Clean up state when buffer unloads/deletes
  api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
    group = AUGROUP,
    callback = function(e)
      if e.buf then
        state_mod.clear_buf_state(e.buf)
        render.clear(e.buf)
      end
    end,
  })

  -- Re-initialise highlights on colorscheme change
  api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      render.set_hl()
      for_each_active_win(function(win, buf)
        render.render(buf, win)
      end)
    end,
  })
end

--- Configures and initialises indentinator.nvim.
---@param opts table|nil User options
function M.setup(opts)
  config.setup(opts)
  render.set_hl()

  if not M._setup_done then
    M._setup_done = true
    setup_autocmds()
  end

  for_each_active_win(function(win, buf)
    render.render(buf, win)
  end)
end

--- Enables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.enable(buf)
  buf = buf or nvim_get_current_buf()
  state.enabled[buf] = true
  render.render_all(buf)
end

--- Disables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.disable(buf)
  buf = buf or nvim_get_current_buf()
  state.enabled[buf] = false
  render.clear(buf)
end

--- Toggles scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.toggle(buf)
  buf = buf or nvim_get_current_buf()
  if M.is_enabled(buf) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Checks if scope guide rendering is enabled for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
---@return boolean True if enabled
function M.is_enabled(buf)
  buf = buf or nvim_get_current_buf()
  return config.is_enabled(buf, state.enabled[buf])
end

local motion = require("indentinator.motion")

--- Forces a update across active windows.
function M.force_update()
  state_mod.clear_scope_cache()
  for_each_active_win(function(win, buf)
    render.render(buf, win)
  end)
end

--- Retrieves active scope info for a buffer and window.
---@param buf integer|nil Buffer handle
---@param win integer|nil Window handle
---@return table|nil Scope info `{ scope_start, scope_end, active_col }` or nil
function M.get_current_scope(buf, win)
  win = win or nvim_get_current_win()
  if not win or not nvim_win_is_valid(win) then
    return nil
  end
  if not buf then
    local ok_b, b = pcall(nvim_win_get_buf, win)
    buf = ok_b and b or nil
  end
  if not buf or not api.nvim_buf_is_valid(buf) or not nvim_buf_is_loaded(buf) then
    return nil
  end

  local start_row, end_row, active_col = scope.get_scope(buf, win, config.values.scope and config.values.scope.treesitter)
  if start_row and end_row then
    return {
      scope_start = start_row,
      scope_end = end_row,
      active_col = active_col,
    }
  end
  return nil
end

--- Jumps cursor to top boundary of active scope.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_start(win)
  return motion.jump_to_scope_start(win)
end

--- Jumps cursor to bottom boundary of active scope.
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_end(win)
  return motion.jump_to_scope_end(win)
end

--- Selects active scope block in Visual Line mode (`V`).
---@param inner boolean|nil If true, excludes scope header and footer boundary lines
---@param win integer|nil Window handle
---@return boolean Success status
function M.select_scope(inner, win)
  return motion.select_scope(inner, win)
end

return M
