--- Main entry point and facade for indentinator.nvim.
--- Handles plugin lifecycle, configuration, debounced event listeners, and scope navigation API.
--- Modernized for Neovim 0.10+ with atomic zero-allocation viewport rendering.
---@class indentinator
local M = {}

local config = require("indentinator.config")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")
local renderer = require("indentinator.renderer")
local motion = require("indentinator.motion")

local api = vim.api
local nvim_get_current_win = api.nvim_get_current_win
local nvim_get_current_buf = api.nvim_get_current_buf
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_list_wins = api.nvim_list_wins
local uv = vim.uv or vim.loop

local AUGROUP = "Indentinator"

--- Active plugin configuration reference
---@type indentinator.Config
M.config = config.values

--- Helper function to iterate active valid windows using vim.iter.
---@param fn fun(win: integer, buf: integer)
local function for_each_active_win(fn)
  vim.iter(nvim_list_wins())
    :filter(nvim_win_is_valid)
    :each(function(win)
      local ok_b, buf = pcall(nvim_win_get_buf, win)
      if ok_b and buf and nvim_buf_is_loaded(buf) then
        fn(win, buf)
      end
    end)
end

--- Per-window debounced scope update and viewport render.
--- Checks cache first: if the cursor is still within the active scope node, avoids all work.
---@param buf integer Buffer handle
---@param win integer Window handle
local function debounced_cursor_moved(buf, win)
  if not nvim_win_is_valid(win) or not nvim_buf_is_loaded(buf) then
    return
  end

  local cursor = api.nvim_win_get_cursor(win)
  -- Zero overhead fast path: if cursor didn't leave scope node, do nothing
  if cache.is_cursor_in_scope(win, buf, cursor[1], cursor[2]) then
    return
  end

  local delay = config.values.debounce_ms or 0
  if delay <= 0 then
    renderer.render(buf, win)
    return
  end

  local timer = cache.state.timers[win]
  if timer then
    pcall(function() timer:stop() end)
  else
    timer = uv.new_timer()
    cache.state.timers[win] = timer
  end

  timer:start(delay, 0, vim.schedule_wrap(function()
    if nvim_win_is_valid(win) and nvim_buf_is_loaded(buf) then
      local c = api.nvim_win_get_cursor(win)
      if not cache.is_cursor_in_scope(win, buf, c[1], c[2]) then
        renderer.render(buf, win)
      end
    end
  end))
end

--- Registers autocommands for cursor movements, buffer lifecycle, and window resizes.
local function setup_autocmds()
  api.nvim_create_augroup(AUGROUP, { clear = true })

  -- Cursor movement updates active scope guide (fast debounced check)
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, buf = pcall(nvim_win_get_buf, win)
        if ok_b and buf and config.is_enabled(buf, cache.state.enabled[buf]) then
          debounced_cursor_moved(buf, win)
        end
      end
    end,
  })

  -- Window focus, buffer attach, and view changes
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, buf = pcall(nvim_win_get_buf, win)
        if ok_b and buf and config.is_enabled(buf, cache.state.enabled[buf]) then
          treesitter.attach_buffer(buf)
          renderer.render(buf, win)
        end
      end
    end,
  })

  -- Window scrolling or resizing
  api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, buf = pcall(nvim_win_get_buf, win)
        if ok_b and buf and config.is_enabled(buf, cache.state.enabled[buf]) then
          renderer.render(buf, win)
        end
      end
    end,
  })

  -- Clean up state and timer when window closes
  api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(e)
      local win = tonumber(e.match)
      if win then
        cache.clear_win(win)
      end
    end,
  })

  -- Clean up state when buffer unloads/deletes
  api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
    group = AUGROUP,
    callback = function(e)
      if e.buf then
        cache.clear_buf(e.buf)
        cache.state.enabled[e.buf] = nil
        renderer.clear(e.buf)
      end
    end,
  })

  -- Re-initialise highlights on colorscheme change
  api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      renderer.set_hl()
      renderer.clear_virt_text_cache()
      for_each_active_win(function(win, buf)
        renderer.render(buf, win)
      end)
    end,
  })
end

--- Configures and initialises indentinator.nvim.
---@param opts indentinator.Config|table|nil User options
function M.setup(opts)
  config.setup(opts)
  M.config = config.values
  renderer.set_hl()
  renderer.setup_decoration_provider()

  if not M._setup_done then
    M._setup_done = true
    setup_autocmds()
  end

  for_each_active_win(function(win, buf)
    treesitter.attach_buffer(buf)
    renderer.render(buf, win)
  end)
end

--- Enables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.enable(buf)
  buf = buf or nvim_get_current_buf()
  cache.state.enabled[buf] = true
  treesitter.attach_buffer(buf)
  renderer.render_all(buf)
end

--- Disables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.disable(buf)
  buf = buf or nvim_get_current_buf()
  cache.state.enabled[buf] = false
  renderer.clear(buf)
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
  return config.is_enabled(buf, cache.state.enabled[buf])
end

--- Forces an update across active windows.
function M.force_update()
  cache.clear()
  for_each_active_win(function(win, buf)
    renderer.render(buf, win)
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

  local use_ts = config.values.scope and config.values.scope.treesitter
  local start_row, end_row, active_col = treesitter.get_scope(buf, win, use_ts)
  if start_row and end_row then
    return {
      scope_start = start_row,
      scope_end = end_row,
      active_col = active_col,
    }
  end
  return nil
end

--- Jumps cursor to top boundary of active scope (or parent scope if already at top).
---@param win integer|nil Window handle
---@return boolean Success status
function M.jump_to_scope_start(win)
  return motion.jump_to_scope_start(win)
end

--- Jumps cursor to bottom boundary of active scope (or parent scope if already at bottom).
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
