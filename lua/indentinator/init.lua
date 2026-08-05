---@class IndentinatorConfig
---@field enabled boolean Whether the plugin is enabled globally or per-buffer
---@field smart boolean Whether blank lines inherit the indentation guides of neighbouring lines
---@field char string The character used for drawing the indentation guides
---@field char_hl string The highlight group for standard guides
---@field gap_hl string The highlight group for gaps (currently unused but reserved)
---@field draw_gap_hl boolean Whether gaps should be highlighted
---@field show_first_indent_level boolean Whether the first indentation level (column 0) should be drawn
---@field indent_width number|nil Custom indentation width override (if nil, uses shiftwidth/tabstop)
---@field exclude string[] Filetypes to exclude from drawing guides
---@field exclude_buftypes string[] Buftypes to exclude from drawing guides
---@field priority number The priority level of the extmarks used for the guides
---@field show_current_indent boolean|string Whether to highlight the current scope guide ('only' or boolean)
---@field current_char_hl string The highlight group for the active guide
---@field filetypes table<string, table> Per-filetype configuration overrides

---@class IndentinatorState
---@field enabled table<number, boolean> Enablement status per buffer
---@field windows table<number, table<number, number[]>> Line range viewport limits tracked per buffer and window
---@field attached table<number, boolean|number> Attachment status for buffer listeners
---@field current_indent table<number, number|nil> Active column index tracked per window

-- Minimal event-driven indentation guides for Neovim
local M = {}

local NS = vim.api.nvim_create_namespace("indentinator")
local AUGROUP = "Indentinator"

---@type IndentinatorConfig
M.config = {
  enabled = true,
  smart = false,
  char = "│",
  char_hl = "IndentinatorGuide",
  gap_hl = "IndentinatorGap",
  draw_gap_hl = false,
  show_first_indent_level = true,
  indent_width = nil,
  exclude = {},
  exclude_buftypes = { "terminal", "nofile", "quickfix", "prompt" },
  priority = 100,
  show_current_indent = false,
  current_char_hl = "IndentinatorCurrentGuide",
  filetypes = {},
}

---@type IndentinatorState
local state = {
  enabled = {},
  windows = {},
  attached = {},
  current_indent = {},
}

--- Resolves a configuration option, taking into account filetype-specific overrides.
---@param buf number The buffer handle
---@param opt string The configuration key to resolve
---@return any The resolved configuration value
local function resolve_config(buf, opt)
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  if ok_ft and ft and M.config.filetypes and M.config.filetypes[ft] then
    local ft_cfg = M.config.filetypes[ft]
    if ft_cfg[opt] ~= nil then
      return ft_cfg[opt]
    end
  end
  return M.config[opt]
end

--- Checks if indentation guides are enabled for the specified buffer.
---@param buf number The buffer handle
---@return boolean True if enabled, false otherwise
local function is_enabled(buf)
  local v = state.enabled[buf]
  if v ~= nil then return v end

  -- Exclude by filetype
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  if not ok_ft or not ft then ft = "" end
  local exclude_fts = resolve_config(buf, "exclude") or {}
  for _, e in ipairs(exclude_fts) do
    if ft == e then return false end
  end

  -- Exclude by buftype
  local ok_bt, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
  if not ok_bt or not bt then bt = "" end
  local exclude_bts = resolve_config(buf, "exclude_buftypes") or {}
  for _, e in ipairs(exclude_bts) do
    if bt == e then return false end
  end

  return resolve_config(buf, "enabled")
end

--- Safely gets a numeric option value from a buffer.
---@param buf number The buffer handle
---@param opt string The option name
---@return number|nil The option value if valid, or nil
local function get_buf_opt(buf, opt)
  local ok, val = pcall(vim.api.nvim_get_option_value, opt, { buf = buf })
  if ok and type(val) == "number" and val > 0 then return val end
  return nil
end

--- Computes the indentation width for a given buffer.
---@param buf number The buffer handle
---@return number The resolved indentation step width
local function indent_width(buf)
  local custom_width = resolve_config(buf, "indent_width")
  if custom_width then return custom_width end
  return get_buf_opt(buf, "shiftwidth") or get_buf_opt(buf, "tabstop") or 8
end

--- Retrieves the tabstop configuration of a buffer.
---@param buf number The buffer handle
---@return number The tabstop size
local function buffer_tabstop(buf)
  return get_buf_opt(buf, "tabstop") or 8
end

--- Computes the display width in columns of a leading whitespace substring.
---@param lead string The leading whitespace characters
---@param tabstop number The tabstop setting of the buffer
---@return number The total display column width
local function lead_display_width(lead, tabstop)
  local display_col = 0
  local len = #lead
  local i = 1
  while i <= len do
    local byte = lead:byte(i)
    if byte == 9 then
      display_col = display_col + (tabstop - (display_col % tabstop))
    else
      display_col = display_col + 1
    end
    i = i + 1
  end
  return display_col
end

--- Calculates the active indentation guide column based on the cursor position.
---@param buf number The buffer handle
---@param win number The window handle
---@return number|nil The active column index, or nil if none
local function get_current_indent_col(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]

  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok_l or #lines == 0 then return nil end

  local target_row = row
  local text = lines[target_row] or ""
  local lead = text:match("^%s*")

  -- If current line is blank, traverse surrounding lines to determine active context
  if text == "" or lead == text then
    for r = target_row - 1, 1, -1 do
      local t = lines[r]
      local l = t:match("^%s*")
      if t ~= "" and l ~= t then
        text = t
        lead = l
        target_row = r
        break
      end
    end
    if text == "" or lead == text then
      for r = target_row + 1, #lines do
        local t = lines[r]
        local l = t:match("^%s*")
        if t ~= "" and l ~= t then
          text = t
          lead = l
          target_row = r
          break
        end
      end
    end
  end

  if text == "" or lead == text then return nil end

  local width = indent_width(buf)
  local tabstop = buffer_tabstop(buf)

  local display_col = lead_display_width(lead, tabstop)
  local aligned_current = math.floor(display_col / width) * width

  -- Look ahead for the next non-blank line to detect if current line starts a block
  local next_aligned = nil
  for r = target_row + 1, #lines do
    local t = lines[r]
    local l = t:match("^%s*")
    if t ~= "" and l ~= t then
      local next_display_col = lead_display_width(l, tabstop)
      next_aligned = math.floor(next_display_col / width) * width
      break
    end
  end

  local active_col
  if next_aligned and next_aligned > aligned_current then
    -- Current line starts a deeper scope (e.g. block header), highlight its own level
    active_col = aligned_current
  else
    -- Current line is inside or closing a scope, highlight parent scope level
    active_col = aligned_current - width
  end

  if active_col < 0 then return nil end
  local show_first = resolve_config(buf, "show_first_indent_level")
  if active_col == 0 and not show_first then return nil end
  return active_col
end

--- Computes guide positions for a line based on leading whitespace.
---@param lead string The leading whitespace
---@param width number The indentation width
---@param tabstop number The tabstop size
---@param show_first boolean Whether to show the first indent guide
---@return table[]|nil Array of guides with byte and display columns, or nil
local function guide_cols(lead, width, tabstop, show_first)
  if #lead == 0 then return nil end
  local cols = {}
  local display_col = 0
  local i = 1
  local len = #lead

  while i <= len do
    if display_col % width == 0 then
      if show_first or display_col > 0 then
        table.insert(cols, { byte_col = i - 1, display_col = display_col })
      end
    end

    local byte = lead:byte(i)
    if byte == 9 then
      display_col = display_col + (tabstop - (display_col % tabstop))
    else
      display_col = display_col + 1
    end
    i = i + 1
  end

  return #cols > 0 and cols or nil
end

--- Clears the indentation guide extmarks from a specific window viewport.
---@param buf number The buffer handle
---@param win number The window handle
local function clear_window(buf, win)
  local ranges = state.windows[buf]
  if not ranges then return end
  local r = ranges[win]
  if r then
    local start_line = math.max(0, r[1] - 1)
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, start_line, r[2])
    ranges[win] = nil
  end
end

--- Clears all indentation guide extmarks from all tracked windows for a buffer.
---@param buf number The buffer handle
local function clear_window_all(buf)
  if state.windows[buf] then
    for win, r in pairs(state.windows[buf]) do
      local start_line = math.max(0, r[1] - 1)
      pcall(vim.api.nvim_buf_clear_namespace, buf, NS, start_line, r[2])
    end
    state.windows[buf] = nil
  end
end

--- Renders indentation guides for the visible lines of a buffer in a specific window.
---@param buf number The buffer handle
---@param win number The window handle
local function render(buf, win)
  if not buf or not win or not vim.api.nvim_buf_is_loaded(buf) then return end
  if not is_enabled(buf) then
    clear_window(buf, win)
    return
  end

  local ok_r, r0, r1 = pcall(vim.fn.line, "w0", win)
  if not ok_r then return end
  local ok_s, r1b = pcall(vim.fn.line, "w$", win)
  if not ok_s then return end
  r1 = r1b
  if type(r0) ~= "number" or type(r1) ~= "number" or r1 < r0 or r0 <= 0 then return end

  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, r0 - 1, r1, false)
  if not ok_l or #lines == 0 then
    clear_window(buf, win)
    return
  end

  local width = indent_width(buf)
  local tabstop = buffer_tabstop(buf)
  local show_first = resolve_config(buf, "show_first_indent_level")

  local active_col = nil
  local show_current = resolve_config(buf, "show_current_indent")
  if show_current then
    active_col = get_current_indent_col(buf, win)
    state.current_indent = state.current_indent or {}
    state.current_indent[win] = active_col
  end

  local results = {}
  for k, text in ipairs(lines) do
    local lead = text:match("^%s*")
    if text ~= "" and lead ~= text then
      local cells = vim.fn.strdisplaywidth(lead)
      if cells <= 1000 then
        results[k] = guide_cols(lead, width, tabstop, show_first)
      end
    end
  end

  -- Fill blank lines if smart mode is active
  local is_smart = resolve_config(buf, "smart")
  if not is_smart then
    local k = 1
    local nlines = #lines
    while k <= nlines do
      local text = lines[k]
      local lead = text:match("^%s*")
      if text == "" or lead == text then
        local b_start = k
        while k <= nlines do
          local t = lines[k]
          local l = t:match("^%s*")
          if t ~= "" and l ~= t then break end
          k = k + 1
        end
        local b_end = k - 1

        local above = b_start > 1 and results[b_start - 1] or nil
        local below = b_end < nlines and results[b_end + 1] or nil

        local fill = nil
        if above and below then
          fill = #above >= #below and above or below
        elseif above then
          fill = above
        elseif below then
          fill = below
        end

        if fill then
          local fill_blank = {}
          for _, item in ipairs(fill) do
            table.insert(fill_blank, {
              byte_col = item.display_col,
              display_col = item.display_col,
              is_blank = true,
            })
          end
          for b = b_start, b_end do
            results[b] = fill_blank
          end
        end
      else
        k = k + 1
      end
    end
  end

  -- Ensure we do not redraw lines occupied by other windows showing the same buffer
  local occupied = {}
  if vim.tbl_count(state.windows[buf] or {}) > 1 then
    for other, r in pairs(state.windows[buf]) do
      if other ~= win then
        for ln = r[1], r[2] do occupied[ln] = true end
      end
    end
  end

  clear_window(buf, win)

  local char = resolve_config(buf, "char")
  local char_hl = resolve_config(buf, "char_hl")
  local current_hl = resolve_config(buf, "current_char_hl")
  local priority = resolve_config(buf, "priority")

  for k = 1, #lines do
    local cols = results[k]
    if cols and not occupied[r0 - 1 + k] then
      local line_idx = r0 - 2 + k
      local line_text = lines[k]
      local line_len = #line_text

      for _, item in ipairs(cols) do
        local is_current = (active_col and item.display_col == active_col)
        if not (show_current == "only" and not is_current) then
          local hl = is_current and current_hl or char_hl

          local extmark_opts = {
            virt_text = { { char, hl } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = priority,
          }

          local target_col = item.byte_col
          if item.is_blank or target_col >= line_len then
            target_col = math.min(item.byte_col, line_len)
            if item.display_col > 0 then
              extmark_opts.virt_text_win_col = item.display_col
            end
          end

          pcall(vim.api.nvim_buf_set_extmark, buf, NS, line_idx, target_col, extmark_opts)
        end
      end
    end
  end

  state.windows[buf] = state.windows[buf] or {}
  state.windows[buf][win] = { r0, r1 }
end

--- Triggers rendering on all windows showing the specified buffer.
---@param buf number The buffer handle
local function render_all(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
    if ok_b and wb == buf then render(buf, win) end
  end
end

--- Attaches buffer-change listeners to the specified buffer.
---@param buf number The buffer handle
local function attach(buf)
  if state.attached[buf] and vim.api.nvim_buf_is_loaded(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then
    state.attached[buf] = nil
    return
  end
  local ok, res = pcall(vim.api.nvim_buf_attach, buf, false, {
    on_bytes = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          render_all(buf)
        end
      end)
    end,
  })
  state.attached[buf] = ok and res or nil
end

--- Initialises the default highlight groups.
local function set_hl()
  vim.api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE" })
  vim.api.nvim_set_hl(0, "IndentinatorGap", { fg = "#555b6e", bg = "NONE" })
  vim.api.nvim_set_hl(0, "IndentinatorCurrentGuide", { fg = "#a6adc8", bg = "NONE" })
end

--- Configures and initialises the plugin with user settings.
---@param opts table|nil User configuration options
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if v ~= nil then M.config[k] = v end
  end

  set_hl()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    callback = function(e)
      if e.buf and vim.api.nvim_buf_is_valid(e.buf) then
        attach(e.buf)
        render(e.buf, vim.api.nvim_get_current_win())
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = AUGROUP,
    callback = function(e)
      if e.buf and vim.api.nvim_buf_is_valid(e.buf) then render_all(e.buf) end
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinEnter", "WinResized" }, {
    group = AUGROUP,
    callback = function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
        if ok_b then render(wb, win) end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(e)
      local win = tonumber(e.match)
      for buf, ranges in pairs(state.windows) do
        if ranges[win] then ranges[win] = nil end
      end
      if state.current_indent and state.current_indent[win] ~= nil then
        state.current_indent[win] = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local ok_b, buf = pcall(vim.api.nvim_win_get_buf, win)
      if not ok_b or not is_enabled(buf) then return end

      if not resolve_config(buf, "show_current_indent") then return end

      local active_col = get_current_indent_col(buf, win)
      state.current_indent = state.current_indent or {}
      if state.current_indent[win] ~= active_col then
        state.current_indent[win] = active_col
        render(buf, win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = AUGROUP,
    pattern = { "shiftwidth", "tabstop", "expandtab", "softtabstop" },
    callback = function(e)
      local buf = e.buf
      if buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_get_current_buf()
      end
      render_all(buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      set_hl()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
        if ok_b then render(wb, win) end
      end
    end,
  })

  vim.schedule(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
      if ok_b then
        attach(wb)
        if is_enabled(wb) then render(wb, win) end
      end
    end
  end)
end

--- Explicitly enables guides for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state.enabled[buf] = true
  render_all(buf)
end

--- Explicitly disables guides for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state.enabled[buf] = false
  clear_window_all(buf)
end

--- Toggles guides on or off for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if is_enabled(buf) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Checks if guides are enabled for the specified buffer.
---@param buf number|nil The buffer handle (defaults to current)
---@return boolean True if enabled, false otherwise
function M.is_enabled(buf)
  return is_enabled(buf or vim.api.nvim_get_current_buf())
end

--- Forces a full redraw of guides in all active windows.
function M.force_update()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
    if ok_b then render(wb, win) end
  end
end

return M
