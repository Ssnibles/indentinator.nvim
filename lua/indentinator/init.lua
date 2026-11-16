--- Main entry point and facade for indentinator.nvim.
--- Handles plugin lifecycle, configuration, debounced event listeners, and scope navigation API.
--- Targets Neovim 0.10+ with viewport-scoped extmark rendering and memoized scope resolution.
---@class indentinator
local M = {}

local config = require("indentinator.config")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")
local render = require("indentinator.render")
local motion = require("indentinator.motion")
local hooks = require("indentinator.hooks")

local api = vim.api
local nvim_get_current_win = api.nvim_get_current_win
local nvim_get_current_buf = api.nvim_get_current_buf
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_list_wins = api.nvim_list_wins

local AUGROUP = "Indentinator"

--- Active plugin configuration reference.
---@type indentinator.Config
M.config = config.values

--- Available hook type names for `register_hook`.
M.hook_types = hooks.type

--- Runs `fn(buf, win)` for every valid window showing a loaded buffer.
---@param fn fun(win: integer, buf: integer)
local function for_each_window(fn)
  for _, win in ipairs(nvim_list_wins()) do
    if nvim_win_is_valid(win) then
      local ok, buf = pcall(nvim_win_get_buf, win)
      if ok and buf and nvim_buf_is_loaded(buf) then
        fn(win, buf)
      end
    end
  end
end

--- Runs `fn(buf, win)` for the current window when guides are enabled for its buffer.
---@param fn fun(buf: integer, win: integer)
local function with_current_buffer(fn)
  local win = nvim_get_current_win()
  if not nvim_win_is_valid(win) then
    return
  end
  local ok, buf = pcall(nvim_win_get_buf, win)
  if ok and buf and config.is_enabled(buf) then
    fn(buf, win)
  end
end

--- Attaches Treesitter and repaints every window showing a buffer, or clears it
--- when rendering is disabled. Used by FileType and OptionSet autocmds.
---@param buf integer|nil Buffer handle
local function refresh_buf(buf)
  if not buf or not nvim_buf_is_loaded(buf) then
    return
  end
  if config.is_enabled(buf) then
    treesitter.attach_buffer(buf)
    render.render_all(buf)
  else
    render.clear(buf)
  end
end

--- Repaints the buffer in `win` unless the cursor is still inside the active scope.
---@param buf integer Buffer handle
---@param win integer Window handle
local function render_after_cursor_move(buf, win)
  if not nvim_win_is_valid(win) or not nvim_buf_is_loaded(buf) then
    return
  end
  local ok, win_buf = pcall(nvim_win_get_buf, win)
  if not ok or win_buf ~= buf then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  if not cache.is_cursor_in_scope(win, buf, cursor[1], cursor[2]) then
    render.render(buf, win)
  end
end

--- Debounces a repaint when the cursor leaves the cached active scope.
---@param buf integer Buffer handle
---@param win integer Window handle
local function on_cursor_moved(buf, win)
  if not nvim_win_is_valid(win) or not nvim_buf_is_loaded(buf) then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  if cache.is_cursor_in_scope(win, buf, cursor[1], cursor[2]) then
    return
  end

  local delay = config.get(buf).debounce_ms or 0
  if delay <= 0 then
    render.render(buf, win)
  else
    cache.debounce(win, delay, function()
      render_after_cursor_move(buf, win)
    end)
  end
end

--- Registers autocommands for cursor movements, buffer lifecycle, and window resizes.
local function setup_autocmds()
  api.nvim_create_augroup(AUGROUP, { clear = true })

  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      with_current_buffer(on_cursor_moved)
    end,
  })

  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = AUGROUP,
    callback = function()
      with_current_buffer(function(buf, win)
        treesitter.attach_buffer(buf)
        render.render(buf, win)
      end)
    end,
  })

  api.nvim_create_autocmd("FileType", {
    group = AUGROUP,
    callback = function(e)
      refresh_buf(e.buf)
    end,
  })

  api.nvim_create_autocmd("OptionSet", {
    group = AUGROUP,
    pattern = { "shiftwidth", "tabstop", "expandtab", "list", "listchars" },
    callback = function(e)
      refresh_buf((e.buf and e.buf ~= 0) and e.buf or nvim_get_current_buf())
    end,
  })

  api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = AUGROUP,
    callback = function()
      with_current_buffer(render.render)
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(e)
      local win = tonumber(e.match)
      if win then
        cache.clear_win(win)
        render.clear_win(win)
      end
    end,
  })

  api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
    group = AUGROUP,
    callback = function(e)
      if e.buf then
        cache.clear_buf(e.buf)
        config.clear_buffer(e.buf)
        render.clear(e.buf)
      end
    end,
  })

  api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      render.set_hl()
      render.clear_virt_text_cache()
      for_each_window(function(win, buf)
        render.render(buf, win)
      end)
    end,
  })
end

--- Attaches Treesitter and renders every window with a loaded buffer.
local function render_all_windows()
  for_each_window(function(win, buf)
    treesitter.attach_buffer(buf)
    render.render(buf, win)
  end)
end

--- Configures and initialises indentinator.nvim.
---@param opts indentinator.Config|table|nil User options
function M.setup(opts)
  config.setup(opts)
  M.config = config.values
  render.set_hl()
  cache.clear()

  if not M._setup_done then
    M._setup_done = true
    setup_autocmds()
  end

  render_all_windows()
end

--- Registers a rendering hook and refreshes the display.
---@param type_name string One of `M.hook_types`
---@param fn function
function M.register_hook(type_name, fn)
  hooks.register(type_name, fn)
  M.force_update()
end

--- Clears rendering hooks (all types, or a single type) and refreshes the display.
---@param type_name string|nil One of `M.hook_types`
function M.clear_hooks(type_name)
  hooks.clear(type_name)
  M.force_update()
end

--- Updates global configuration by merging into the current values (no reset).
---@param opts indentinator.Config|table|nil User options
function M.update(opts)
  config.update(opts)
  M.config = config.values
  render.set_hl()
  M.force_update()
end

--- Sets per-buffer configuration overrides (same shape as `setup`).
---@param opts table|nil Overrides; nil clears them
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.set_buffer_config(opts, buf)
  buf = buf or nvim_get_current_buf()
  config.set_buffer(buf, opts)
  cache.clear_buf(buf)
  refresh_buf(buf)
end

--- Returns a deep copy of the resolved configuration for a buffer.
---
--- A copy is returned so callers can freely inspect or mutate it without
--- silently modifying the live global config (the internal `config.get` shares
--- the global table for buffers without overrides).
---@param buf integer|nil Buffer handle (defaults to current buffer)
---@return indentinator.Config
function M.get_config(buf)
  return vim.deepcopy(config.get(buf or nvim_get_current_buf()))
end

--- Enables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.enable(buf)
  buf = buf or nvim_get_current_buf()
  config.update_buffer(buf, { enabled = true })
  cache.clear_buf(buf)
  refresh_buf(buf)
end

--- Disables scope guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.disable(buf)
  buf = buf or nvim_get_current_buf()
  config.update_buffer(buf, { enabled = false })
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
  return config.is_enabled(buf)
end

--- Forces an update across active windows.
--- Invalidates memoized scope and per-buffer configuration so in-place global
--- mutations are picked up even by buffers that carry their own overrides.
function M.force_update()
  cache.clear()
  config.clear_resolved()
  render_all_windows()
end

--- Retrieves active scope info for a buffer and window.
---@param buf integer|nil Buffer handle
---@param win integer|nil Window handle
---@return table|nil Scope info `{ scope_start, scope_end, active_col }` or nil
function M.get_current_scope(buf, win)
  win = win or nvim_get_current_win()
  if not nvim_win_is_valid(win) then
    return nil
  end

  buf = buf or nvim_win_get_buf(win)
  if not buf or not nvim_buf_is_valid(buf) or not nvim_buf_is_loaded(buf) then
    return nil
  end

  local start_row, end_row, active_col = treesitter.get_scope(buf, win, config.get(buf).scope.treesitter)
  if not start_row or not end_row then
    return nil
  end

  return {
    scope_start = start_row,
    scope_end = end_row,
    active_col = active_col,
  }
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
