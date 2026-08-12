--- Main entry point and public facade for indentinator.nvim.
--- Handles plugin setup, autocmd event listeners, statusline, and scope navigation APIs.

local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local utils = require("indentinator.utils")
local render = require("indentinator.render")
local scope = require("indentinator.scope")

local api = vim.api
local nvim_get_current_win = api.nvim_get_current_win
local nvim_get_current_buf = api.nvim_get_current_buf
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_list_wins = api.nvim_list_wins

local M = {}

local AUGROUP = "Indentinator"

--- Active plugin configuration reference
---@type IndentinatorConfig
M.config = config.values

--- Helper function to iterate active, valid windows and execute callback.
---@param fn fun(win: integer, buf: integer) Callback function
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

--- Registers autocommands for buffer lifecycle, viewport scroll, cursor movement, and options.
local function setup_autocmds()
  api.nvim_create_augroup(AUGROUP, { clear = true })

  -- Attach listeners and render guides when buffer enters window
  api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    callback = function(e)
      if e.buf and nvim_buf_is_valid(e.buf) and nvim_buf_is_loaded(e.buf) then
        render.attach(e.buf)
        render.render_all(e.buf)
      end
    end,
  })

  -- Handle viewport scrolling and window resizing events
  api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = AUGROUP,
    callback = function(ev)
      vim.schedule(function()
        if ev.event == "VimResized" then
          M.force_update()
          return
        end

        local event_wins = vim.v.event and vim.v.event.all
        if event_wins and next(event_wins) then
          for win_id_str, _ in pairs(event_wins) do
            local win = tonumber(win_id_str)
            if win and nvim_win_is_valid(win) then
              local ok_b, wb = pcall(nvim_win_get_buf, win)
              if ok_b and wb then
                render.render(wb, win)
              end
            end
          end
          return
        end

        local win = tonumber(ev.match) or nvim_get_current_win()
        if win and nvim_win_is_valid(win) then
          local ok_b, wb = pcall(nvim_win_get_buf, win)
          if ok_b and wb then
            render.render(wb, win)
          end
        end
      end)
    end,
  })

  -- Handle window focus changes
  api.nvim_create_autocmd("WinEnter", {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      if nvim_win_is_valid(win) then
        local ok_b, wb = pcall(nvim_win_get_buf, win)
        if ok_b and wb then
          render.render(wb, win)
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

  -- Clean up state when buffer is deleted/unloaded/wiped
  api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
    group = AUGROUP,
    callback = function(e)
      if e.buf then
        state_mod.clear_buf_state(e.buf)
      end
    end,
  })

  -- Cursor movement position tracking for active scope updates
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      local win = nvim_get_current_win()
      local ok_b, buf = pcall(nvim_win_get_buf, win)
      if not ok_b or not buf or not config.is_enabled(buf, state) then
        return
      end

      local scope_cfg = config.resolve_scope(buf)
      local cursor = api.nvim_win_get_cursor(win)
      local row, col = cursor[1], cursor[2]

      state.last_cursor_row = state.last_cursor_row or {}
      state.last_cursor_col = state.last_cursor_col or {}
      state.last_leftcol = state.last_leftcol or {}

      local ok_view, view = pcall(vim.fn.winsaveview)
      local leftcol = (ok_view and type(view) == "table" and type(view.leftcol) == "number") and view.leftcol or 0

      local row_changed = state.last_cursor_row[win] ~= row
      local col_changed = state.last_cursor_col[win] ~= col
      local leftcol_changed = state.last_leftcol[win] ~= leftcol

      state.last_cursor_row[win] = row
      state.last_cursor_col[win] = col
      state.last_leftcol[win] = leftcol

      if not scope_cfg.enabled and not leftcol_changed then
        return
      end

      if not scope_cfg.treesitter and not row_changed and not leftcol_changed then
        return
      end

      if scope_cfg.treesitter and not row_changed and not col_changed and not leftcol_changed then
        return
      end

      render.render(buf, win)
    end,
  })

  -- Re-render on indentation or fold option changes
  api.nvim_create_autocmd("OptionSet", {
    group = AUGROUP,
    pattern = {
      "shiftwidth",
      "tabstop",
      "expandtab",
      "softtabstop",
      "foldenable",
      "foldlevel",
      "foldmethod",
      "foldexpr",
      "foldcolumn",
      "foldignore",
      "foldmarker",
    },
    callback = function(e)
      local buf = e.buf
      if not buf or buf == 0 or not nvim_buf_is_valid(buf) then
        buf = nvim_get_current_buf()
      end
      if buf and nvim_buf_is_loaded(buf) then
        render.render_all(buf)
      end
    end,
  })

  -- Listen for fold keypresses in normal mode
  local on_key_ns = api.nvim_create_namespace("indentinator_on_key")
  vim.on_key(function(_, key)
    if not key or key == "" then
      return
    end
    local mode = api.nvim_get_mode().mode
    if mode == "n" or mode == "no" or mode == "nov" or mode == "noV" then
      local win = nvim_get_current_win()
      local ok_fe, fe = pcall(function() return vim.wo[win].foldenable end)
      if ok_fe and fe == true then
        vim.schedule(function()
          local ok_b, buf = pcall(nvim_win_get_buf, win)
          if ok_b and buf and config.is_enabled(buf, state) then
            render.render(buf, win)
          end
        end)
      end
    end
  end, on_key_ns)

  -- Re-initialize highlights on colorscheme change
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

--- Configures and initialises the plugin with user options.
---@param opts table|nil User configuration table
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if v ~= nil then
      if k == "scope" and type(v) == "table" then
        M.config.scope = vim.tbl_extend("force", M.config.scope, v)
      elseif k == "filetypes" and type(v) == "table" and type(M.config.filetypes) == "table" then
        for ft, ft_cfg in pairs(v) do
          M.config.filetypes[ft] = vim.tbl_extend("force", M.config.filetypes[ft] or {}, ft_cfg)
        end
      else
        M.config[k] = v
      end
    end
  end

  if M._setup_done then
    render.set_hl()
    M.force_update()
    return
  end
  M._setup_done = true

  -- Validate standard guide character display width
  local resolved_char = config.resolve_config(0, "char")
  local char_width = vim.fn.strdisplaywidth(resolved_char)
  if char_width ~= 1 then
    vim.notify(
      ("indentinator: char %q has display width %d (expected 1), falling back to '│'"):format(
        resolved_char,
        char_width
      ),
      vim.log.levels.WARN
    )
    M.config.char = "│"
  end

  render.set_hl()
  setup_autocmds()

  vim.schedule(function()
    for_each_active_win(function(win, buf)
      render.attach(buf)
      if config.is_enabled(buf, state) then
        render.render(buf, win)
      end
    end)
  end)
end

--- Enables indentation guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.enable(buf)
  buf = buf or nvim_get_current_buf()
  state.enabled[buf] = true
  render.render_all(buf)
end

--- Disables indentation guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.disable(buf)
  buf = buf or nvim_get_current_buf()
  state.enabled[buf] = false
  render.clear_window_all(buf)
end

--- Toggles indentation guide rendering for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
function M.toggle(buf)
  buf = buf or nvim_get_current_buf()
  if config.is_enabled(buf, state) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Checks if indentation guides are enabled for a buffer.
---@param buf integer|nil Buffer handle (defaults to current buffer)
---@return boolean True if enabled, false otherwise
function M.is_enabled(buf)
  return config.is_enabled(buf or nvim_get_current_buf(), state)
end

--- Forces a full redraw of guides across all active windows.
function M.force_update()
  for_each_active_win(function(win, buf)
    render.render(buf, win)
  end)
end

--- Retrieves active scope information for a buffer and window.
---@param buf integer|nil Buffer handle (defaults to window buffer)
---@param win integer|nil Window handle (defaults to current window)
---@return table|nil Scope details `{ scope_start, scope_end, active_col }` or nil
function M.get_current_scope(buf, win)
  win = win or nvim_get_current_win()
  if not win or not nvim_win_is_valid(win) then
    return nil
  end

  if not buf then
    local ok_b, b = pcall(nvim_win_get_buf, win)
    buf = ok_b and b or nil
  end

  if not buf or not nvim_buf_is_valid(buf) or not nvim_buf_is_loaded(buf) then
    return nil
  end

  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)
  local scope_cfg = config.resolve_scope(buf)

  local scope_start, scope_end, active_col = nil, nil, nil

  if scope_cfg.treesitter then
    local ts_start, ts_end, ts_col = scope.get_treesitter_scope_range(buf, win, width, tabstop)
    if ts_start and ts_end and ts_col then
      scope_start, scope_end, active_col = ts_start, ts_end, ts_col
    end
  end

  if scope_start == nil then
    active_col = utils.get_current_indent_col(buf, win)
    if active_col then
      local cursor = api.nvim_win_get_cursor(win)
      scope_start, scope_end = scope.get_scope_range(buf, cursor[1], active_col, width, tabstop)
    end
  end

  if scope_start and scope_end then
    return {
      scope_start = scope_start,
      scope_end = scope_end,
      active_col = active_col,
    }
  end
  return nil
end

--- Jumps cursor to start ("top") or end ("bottom") of active scope block.
---@param where "top"|"bottom"|"end"|nil Target boundary
function M.jump_to_scope(where)
  where = where or "top"
  local win = nvim_get_current_win()
  if not nvim_win_is_valid(win) then
    return
  end
  local scope_info = M.get_current_scope(nil, win)
  if not scope_info then
    return
  end

  local target_row = (where == "bottom" or where == "end") and scope_info.scope_end or scope_info.scope_start
  if target_row then
    local cursor = api.nvim_win_get_cursor(win)
    api.nvim_win_set_cursor(win, { target_row, cursor[2] })
  end
end

--- Formats statusline string displaying current active scope range.
---@return string Statusline string (e.g. "Scope: L10-L45") or empty string
function M.statusline()
  local scope_info = M.get_current_scope()
  if scope_info and scope_info.scope_start and scope_info.scope_end then
    return string.format("Scope: L%d-L%d", scope_info.scope_start, scope_info.scope_end)
  end
  return ""
end

--- Configures or toggles rainbow delimiter highlighting.
---@param opts table|boolean|integer|nil Options table, boolean enablement status, buffer handle, or nil to toggle
---@return boolean Current rainbow delimiters status
function M.rainbow_delimiters(opts)
  if type(opts) == "table" then
    if opts.enabled ~= nil then
      M.config.scope.rainbow_delimiters = opts.enabled
    else
      M.config.scope.rainbow_delimiters = true
    end
    if opts.rainbow_hls ~= nil then
      M.config.scope.rainbow_hls = opts.rainbow_hls
    end
    if opts.underline ~= nil then
      M.config.scope.underline_delimiters = opts.underline
    elseif opts.underline_delimiters ~= nil then
      M.config.scope.underline_delimiters = opts.underline_delimiters
    end
  elseif type(opts) == "boolean" then
    M.config.scope.rainbow_delimiters = opts
  elseif type(opts) == "number" then
    local buf = opts
    local current = config.resolve_scope(buf).rainbow_delimiters
    M.config.scope.rainbow_delimiters = not current
  else
    M.config.scope.rainbow_delimiters = not (M.config.scope.rainbow_delimiters == true)
  end

  M.force_update()
  return config.resolve_scope(0).rainbow_delimiters == true
end

--- Toggles rainbow delimiter highlighting for a buffer or globally.
---@param buf integer|nil Buffer handle (defaults to current buffer)
---@return boolean New rainbow delimiters enablement state
function M.toggle_rainbow_delimiters(buf)
  return M.rainbow_delimiters(buf)
end

return M
