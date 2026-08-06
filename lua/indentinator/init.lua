---@class IndentinatorScopeConfig
---@field enabled boolean Whether to highlight the active scope guide
---@field range string Scope range: "block" (current block) or "global" (full column)
---@field underline boolean Whether to underline the top line of the active scope
---@field text_highlight boolean Whether to colour the text on the scope-start line

---@class IndentinatorConfig
---@field enabled boolean Whether the plugin is enabled globally or per-buffer
---@field smart boolean Whether blank lines inherit the indentation guides of neighbouring lines
---@field char string The character used for drawing the indentation guides
---@field char_hl string The highlight group for standard guides
---@field gap_hl string The highlight group for gaps
---@field draw_gap_hl boolean Whether gaps should be highlighted
---@field show_first_indent_level boolean Whether the first indentation level (column 0) should be drawn
---@field indent_width number|nil Custom indentation width override (if nil, uses shiftwidth/tabstop)
---@field exclude string[] Filetypes to exclude from drawing guides
---@field exclude_buftypes string[] Buftypes to exclude from drawing guides
---@field priority number The priority level of the extmarks used for the guides
---@field scope IndentinatorScopeConfig Active scope highlighting configuration
---@field current_char_hl string The highlight group for the active guide
---@field scope_underline_hl string The highlight group for the scope underline
---@field scope_text_hl string The highlight group for the scope-start line text
---@field exclude_fn (fun(buf: number): boolean)|nil Custom callback to exclude buffers
---@field filetypes table<string, table> Per-filetype configuration overrides

---@class IndentinatorState
---@field enabled table<number, boolean> Enablement status per buffer
---@field windows table<number, table<number, number[]>> Line range viewport limits tracked per buffer and window
---@field attached table<number, boolean|number> Attachment status for buffer listeners
---@field current_indent table<number, number|nil> Active column index tracked per window
---@field last_cursor_row table<number, number|nil> Last cursor line tracked per window
---@field timers table<number, uv_timer_t|nil> Per-buffer debounce timers for on_bytes renders

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
  scope = {
    enabled = false,        -- highlight the active scope guide
    range = "block",        -- "block" (current block only) or "global" (entire column)
    underline = false,      -- underline the top line of the active scope block
    text_highlight = true,  -- colour the text on the scope-start line
  },
  current_char_hl = "IndentinatorCurrentGuide",
  scope_underline_hl = "IndentinatorScopeUnderline",
  scope_text_hl = "IndentinatorScopeText",
  exclude_fn = nil,
  filetypes = {},
}

---@type IndentinatorState
local state = {
  enabled = {},
  windows = {},
  attached = {},
  current_indent = {},
  last_cursor_row = {},
  -- Per-buffer uv timers used to debounce on_bytes renders
  timers = {},
}

--- Resolves the merged scope config for a buffer, respecting filetype overrides.
---@param buf number The buffer handle
---@return IndentinatorScopeConfig The resolved scope configuration
local function resolve_scope(buf)
  local base = M.config.scope or {}
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  if ok_ft and ft and M.config.filetypes and M.config.filetypes[ft] then
    local ft_scope = M.config.filetypes[ft].scope
    if type(ft_scope) == "table" then
      return vim.tbl_extend("force", base, ft_scope)
    end
  end
  return base
end

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

  -- Exclude by custom function callback
  local exclude_fn = resolve_config(buf, "exclude_fn")
  if type(exclude_fn) == "function" then
    local ok, res = pcall(exclude_fn, buf)
    if ok and res then return false end
  end

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

--- Finds the first non-blank line scanning upwards from start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@return string|nil The text content of the line
---@return string|nil The leading whitespace of the line
---@return number|nil The line index (1-indexed)
local function find_non_blank_up(buf, start_row)
  local chunk_size = 100
  local current = start_row
  while current > 0 do
    local chunk_start = math.max(1, current - chunk_size + 1)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, chunk_start - 1, current, false)
    if not ok or #lines == 0 then break end
    for i = #lines, 1, -1 do
      local t = lines[i]
      local l = t:match("^%s*")
      if t ~= "" and l ~= t then
        return t, l, chunk_start + i - 1
      end
    end
    current = chunk_start - 1
  end
  return nil
end

--- Finds the first non-blank line scanning downwards from start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param line_count number The total line count in the buffer
---@return string|nil The text content of the line
---@return string|nil The leading whitespace of the line
---@return number|nil The line index (1-indexed)
local function find_non_blank_down(buf, start_row, line_count)
  local chunk_size = 100
  local current = start_row
  while current <= line_count do
    local chunk_end = math.min(line_count, current + chunk_size - 1)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then break end
    for i = 1, #lines do
      local t = lines[i]
      local l = t:match("^%s*")
      if t ~= "" and l ~= t then
        return t, l, current + i - 1
      end
    end
    current = chunk_end + 1
  end
  return nil
end

--- Find the indentation display width of the first non-blank line above start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param tabstop number The tabstop setting
---@return number The indentation display width (or 0 if none found)
local function find_indent_above(buf, start_row, tabstop)
  local t, l = find_non_blank_up(buf, start_row)
  if t and l then
    return lead_display_width(l, tabstop)
  end
  return 0
end

--- Find the indentation display width of the first non-blank line below start_row.
---@param buf number The buffer handle
---@param start_row number The starting row (1-indexed)
---@param line_count number The total line count in the buffer
---@param tabstop number The tabstop setting
---@return number The indentation display width (or 0 if none found)
local function find_indent_below(buf, start_row, line_count, tabstop)
  local t, l = find_non_blank_down(buf, start_row, line_count)
  if t and l then
    return lead_display_width(l, tabstop)
  end
  return 0
end

--- Determines the start and end rows of the active block scope.
---@param buf number The buffer handle
---@param cursor_row number The cursor line (1-indexed)
---@param active_col number The active guide column index
---@param width number The indentation width
---@param tabstop number The tabstop size
---@return number|nil The start row (1-indexed), or nil
---@return number|nil The end row (1-indexed), or nil
local function get_scope_range(buf, cursor_row, active_col, width, tabstop)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 or not active_col then return nil, nil end

  local limit = active_col + width
  local scope_start = cursor_row
  local scope_end = cursor_row

  -- If the cursor line is non-blank and its own indent equals active_col, it IS
  -- the scope-opener: no upward walk needed (avoids landing on a sibling line
  -- at the same indent level above a blank-line separator).
  local ok_cur, cur_lines = pcall(vim.api.nvim_buf_get_lines, buf, cursor_row - 1, cursor_row, false)
  local cursor_is_opener = false
  if ok_cur and cur_lines and cur_lines[1] then
    local cl = cur_lines[1]
    local cl_lead = cl:match("^%s*")
    if cl ~= "" and cl_lead ~= cl then
      cursor_is_opener = (lead_display_width(cl_lead, tabstop) == active_col)
    end
  end

  if not cursor_is_opener then
    -- Search upwards; stop early if a blank line is crossed (separate block above)
    local current = cursor_row - 1
    local crossed_blank = false
    while current > 0 do
      local chunk_start = math.max(1, current - 50 + 1)
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, chunk_start - 1, current, false)
      if not ok or #lines == 0 then break end

      local stopped = false
      for i = #lines, 1, -1 do
        local idx = chunk_start + i - 1
        local text = lines[i]
        local lead = text:match("^%s*")
        if text == "" or lead == text then
          crossed_blank = true
        else
          local disp = lead_display_width(lead, tabstop)
          if disp < limit then
            if not crossed_blank then
              if disp == active_col then
                scope_start = idx
              else
                scope_start = idx + 1
              end
            end
            -- If crossed_blank: a separate block lives above; scope_start stays
            -- at cursor_row (already the default).
            stopped = true
            break
          end
          -- Non-blank line still inside the scope body: a blank above it is
          -- within the same block, so reset the sentinel.
          crossed_blank = false
        end
      end
      if stopped then break end
      scope_start = chunk_start
      current = chunk_start - 1
    end
  end

  -- Search downwards
  current = cursor_row + 1
  while current <= line_count do
    local chunk_end = math.min(line_count, current + 50 - 1)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then break end

    local stopped = false
    for i = 1, #lines do
      local idx = current + i - 1
      local text = lines[i]
      local lead = text:match("^%s*")
      if text ~= "" and lead ~= text then
        local disp = lead_display_width(lead, tabstop)
        if disp < limit then
          scope_end = idx - 1
          stopped = true
          break
        end
      end
    end
    if stopped then break end
    scope_end = chunk_end
    current = chunk_end + 1
  end

  -- Fix #5: trim trailing blank lines from scope_end so the highlight does
  -- not bleed over blank lines at the bottom of a block.
  if scope_end > scope_start then
    while scope_end > scope_start do
      local ok_b, bl = pcall(vim.api.nvim_buf_get_lines, buf, scope_end - 1, scope_end, false)
      if ok_b and bl and bl[1] ~= nil then
        local t = bl[1]
        if t == "" or t:match("^%s*$") then
          scope_end = scope_end - 1
        else
          break
        end
      else
        break
      end
    end
  end

  return scope_start, scope_end
end

--- Calculates the active indentation guide column based on the cursor position.
---@param buf number The buffer handle
---@param win number The window handle
---@return number|nil The active column index, or nil if none
local function get_current_indent_col(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then return nil end

  local target_row = row
  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, target_row - 1, target_row, false)
  if not ok_l or #lines == 0 then return nil end

  local text = lines[1] or ""
  local lead = text:match("^%s*")

  -- If current line is blank, traverse surrounding lines to determine active context
  if text == "" or lead == text then
    local res_text, res_lead, res_row = find_non_blank_up(buf, target_row - 1)
    if res_text then
      text = res_text
      lead = res_lead
      target_row = res_row
    else
      res_text, res_lead, res_row = find_non_blank_down(buf, target_row + 1, line_count)
      if res_text then
        text = res_text
        lead = res_lead
        target_row = res_row
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
  local next_text, next_lead = find_non_blank_down(buf, target_row + 1, line_count)
  if next_text then
    local next_display_col = lead_display_width(next_lead, tabstop)
    next_aligned = math.floor(next_display_col / width) * width
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

--- Builds the virtual text chunks for a single line overlay.
---@param display_col number The indentation display width of the line
---@param width number The indentation width
---@param active_col number|nil The active guide column index (if any)
---@param show_current boolean|string The show_current_indent option value
---@param show_first boolean The show_first_indent_level option value
---@param char string The guide character
---@param char_hl string The standard guide highlight group
---@param current_hl string The current guide highlight group
---@param gap_hl string The gap highlight group
---@param draw_gap_hl boolean Whether gap highlight is enabled
---@return table[] Array of chunks in format { { text, hl }, ... }
local function build_virt_text(display_col, width, active_col, show_current, show_first, char, char_hl, current_hl, gap_hl, draw_gap_hl)
  local chunks = {}

  local col = 0
  while col < display_col do
    local is_guide = true
    if col == 0 and not show_first then
      is_guide = false
    end

    local is_current = (active_col and col == active_col)
    if show_current == "only" and not is_current then
      is_guide = false
    end

    if is_guide then
      local hl = is_current and current_hl or char_hl
      table.insert(chunks, { char, hl })
      local rem = display_col - col - 1
      if rem > 0 then
        local gap_size = math.min(width - 1, rem)
        local g_hl = draw_gap_hl and gap_hl or nil
        table.insert(chunks, { string.rep(" ", gap_size), g_hl })
        col = col + 1 + gap_size
      else
        col = col + 1
      end
    else
      local gap_size = math.min(width, display_col - col)
      local g_hl = draw_gap_hl and gap_hl or nil
      table.insert(chunks, { string.rep(" ", gap_size), g_hl })
      col = col + gap_size
    end
  end
  return chunks
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
    -- Fix #4: r[2] is the inclusive 1-indexed last visible line. The
    -- nvim_buf_clear_namespace end argument is exclusive (0-indexed), so we
    -- pass r[2] directly (== r[2]-1 converted to 0-indexed + 1 exclusive).
    -- Previously r[2] was passed as-is, which was one row short.
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, start_line, r[2] + 1)
    ranges[win] = nil
  end
end

--- Clears all indentation guide extmarks from all tracked windows for a buffer.
---@param buf number The buffer handle
local function clear_window_all(buf)
  if state.windows[buf] then
    for _, r in pairs(state.windows[buf]) do
      local start_line = math.max(0, r[1] - 1)
      -- Fix #4 (same): use r[2] + 1 for the exclusive end.
      pcall(vim.api.nvim_buf_clear_namespace, buf, NS, start_line, r[2] + 1)
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
  local scope_start, scope_end = nil, nil
  local scope_cfg = resolve_scope(buf)
  local show_current = scope_cfg.enabled
  if show_current then
    active_col = get_current_indent_col(buf, win)
    state.current_indent = state.current_indent or {}
    state.current_indent[win] = active_col
    if active_col and scope_cfg.range == "block" then
      local cursor = vim.api.nvim_win_get_cursor(win)
      scope_start, scope_end = get_scope_range(buf, cursor[1], active_col, width, tabstop)
    end
  end

  local results = {}
  for k, text in ipairs(lines) do
    local lead = text:match("^%s*")
    if text ~= "" and lead ~= text then
      -- Compute the display width in pure Lua (no Vimscript FFI). The 1000-
      -- column cap guards against degenerate tab-expanded whitespace that
      -- would produce thousands of guide characters.
      local disp = lead_display_width(lead, tabstop)
      if disp <= 1000 then
        results[k] = disp
      end
    end
  end

  -- Fill blank lines if smart mode is active (smart = false means we fill)
  local is_smart = resolve_config(buf, "smart")
  if not is_smart then
    local k = 1
    local nlines = #lines
    local line_count = vim.api.nvim_buf_line_count(buf)
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

        local above_val = 0
        if b_start > 1 then
          above_val = results[b_start - 1] or 0
        else
          -- Search past viewport top boundary
          above_val = find_indent_above(buf, r0 + b_start - 2, tabstop)
        end

        local below_val = 0
        if b_end < nlines then
          below_val = results[b_end + 1] or 0
        else
          -- Search past viewport bottom boundary
          below_val = find_indent_below(buf, r0 + b_end, line_count, tabstop)
        end

        local fill_val = math.max(above_val, below_val)
        if fill_val > 0 then
          for b = b_start, b_end do
            results[b] = fill_val
          end
        end
      else
        k = k + 1
      end
    end
  end

  -- Ensure we do not redraw lines occupied by other windows showing the same buffer.
  -- Use next() instead of vim.tbl_count() — we only need to know if there is
  -- *more than one* tracked window, not the exact count.
  local occupied = {}
  local wins_for_buf = state.windows[buf]
  if wins_for_buf and next(wins_for_buf) then
    local has_other = false
    for other, _ in pairs(wins_for_buf) do
      if other ~= win then has_other = true; break end
    end
    if has_other then
      for other, r in pairs(wins_for_buf) do
        if other ~= win then
          for ln = r[1], r[2] do occupied[ln] = true end
        end
      end
    end
  end

  clear_window(buf, win)

  local char = resolve_config(buf, "char")
  local char_hl = resolve_config(buf, "char_hl")
  local current_hl = resolve_config(buf, "current_char_hl")
  local gap_hl = resolve_config(buf, "gap_hl")
  local draw_gap_hl = resolve_config(buf, "draw_gap_hl")
  local priority = resolve_config(buf, "priority")
  local underline_enabled = scope_cfg.underline == true
  local underline_hl = resolve_config(buf, "scope_underline_hl")
  local text_highlight_enabled = underline_enabled and scope_cfg.text_highlight ~= false
  local text_hl = resolve_config(buf, "scope_text_hl")

  for k = 1, #lines do
    local disp_col = results[k]
    local abs_line = r0 - 1 + k
    local line_idx = r0 - 2 + k
    local is_this_scope_start = (scope_start ~= nil and abs_line == scope_start)

    -- Emit the underline extmark for the scope-start line. We cover only the
    -- byte-length of the actual text so the underline stops at the last
    -- character rather than stretching to the window edge.
    if is_this_scope_start and underline_enabled and not occupied[abs_line] then
      local scope_line_text = lines[k]
      local text_len = #scope_line_text
      -- Walk the leading whitespace to find the byte offset for active_col so
      -- the underline begins exactly where the │ guide sits, not one space to
      -- the right of it.
      local start_byte = 0
      if active_col and active_col > 0 then
        local dcol = 0
        local i = 1
        while i <= text_len and dcol < active_col do
          local b = scope_line_text:byte(i)
          dcol = dcol + (b == 9 and (tabstop - (dcol % tabstop)) or 1)
          if dcol <= active_col then start_byte = i end
          i = i + 1
        end
      end
      if text_len > start_byte then
        -- Fix #6: use priority + 1 for highlight extmarks so they always sit
        -- above the virt_text extmark (priority). This makes ordering
        -- deterministic and prevents the guide char from randomly disappearing
        -- on the scope-start line.
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, line_idx, start_byte, {
          end_row = line_idx,
          end_col = text_len,
          hl_group = underline_hl,
          hl_eol = false,
          hl_mode = "combine",
          priority = priority + 1,
        })
        -- Colour the text on the scope-start line to match the active guide.
        -- Priority must exceed treesitter's default (100) to win the fg race.
        if text_highlight_enabled then
          local lead_len = #(scope_line_text:match("^%s*"))
          if text_len > lead_len then
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, line_idx, lead_len, {
              end_row = line_idx,
              end_col = text_len,
              hl_group = text_hl,
              hl_eol = false,
              hl_mode = "combine",
              priority = priority + 101,
            })
          end
        end
      end
    end

    if disp_col and disp_col > 0 and not occupied[abs_line] then
      -- Determine if the current line has the active guide highlighted
      local line_active_col = nil
      if active_col then
        if scope_start and scope_end then
          if abs_line >= scope_start and abs_line <= scope_end then
            line_active_col = active_col
          end
        else
          line_active_col = active_col
        end
      end

      local chunks = build_virt_text(
        disp_col,
        width,
        line_active_col,
        show_current,
        show_first,
        char,
        char_hl,
        current_hl,
        gap_hl,
        draw_gap_hl
      )

      if #chunks > 0 then
        -- Optimisation: skip extmark if nothing will be visible
        local has_visible = false
        for _, chunk in ipairs(chunks) do
          local text, hl = chunk[1], chunk[2]
          if hl and (text:find("[^ ]") or draw_gap_hl) then
            has_visible = true
            break
          end
        end

        if has_visible then
          pcall(vim.api.nvim_buf_set_extmark, buf, NS, line_idx, 0, {
            virt_text = chunks,
            virt_text_pos = "overlay",
            hl_mode = "combine",
            priority = priority,
          })
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

  -- Fix #1: debounce on_bytes with a per-buffer uv timer.
  -- Rapid edits (fast typing) previously queued many scheduled renders that
  -- could race, leaving ghost extmark rows. Now only the last edit within a
  -- 15 ms window triggers a render.
  local function schedule_render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local existing = state.timers[buf]
    if existing then
      pcall(function() existing:stop() end)
    end
    local timer = vim.uv.new_timer()
    state.timers[buf] = timer
    timer:start(15, 0, vim.schedule_wrap(function()
      timer:stop()
      if state.timers[buf] == timer then
        state.timers[buf] = nil
      end
      if vim.api.nvim_buf_is_valid(buf) then
        render_all(buf)
      end
    end))
  end

  local ok, res = pcall(vim.api.nvim_buf_attach, buf, false, {
    on_bytes = schedule_render,
  })
  state.attached[buf] = ok and res or nil
end

--- Initialises the default highlight groups.
local function set_hl()
  vim.api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorGap", { fg = "#555b6e", bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorCurrentGuide", { fg = "#a6adc8", bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorScopeUnderline", { fg = "#a6adc8", bg = "NONE", underline = true, default = true })
  vim.api.nvim_set_hl(0, "IndentinatorScopeText", { fg = "#a6adc8", bg = "NONE", default = true })
end

--- Configures and initialises the plugin with user settings.
---@param opts table|nil User configuration options
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if v ~= nil then
      if k == "scope" and type(v) == "table" then
        -- Deep-merge the scope table so only specified keys are overridden
        M.config.scope = vim.tbl_extend("force", M.config.scope, v)
      elseif k == "filetypes" and type(v) == "table" and type(M.config.filetypes) == "table" then
        -- Deep-merge filetypes so per-filetype keys are additive
        for ft, ft_cfg in pairs(v) do
          M.config.filetypes[ft] = vim.tbl_extend("force", M.config.filetypes[ft] or {}, ft_cfg)
        end
      else
        M.config[k] = v
      end
    end
  end

  set_hl()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    callback = function(e)
      if e.buf and vim.api.nvim_buf_is_valid(e.buf) then
        attach(e.buf)
        -- Fix #2: render_all so every window showing this buffer gets guides,
        -- not just the current window (which may be a different split).
        render_all(e.buf)
      end
    end,
  })

  -- Fix #3: WinScrolled/WinResized always populate ev.match with the
  -- triggering window, so use that as the narrow fallback instead of
  -- iterating every open window.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = AUGROUP,
    callback = function(ev)
      local event_wins = vim.v.event and vim.v.event.all
      if event_wins and next(event_wins) then
        for win_id_str, _ in pairs(event_wins) do
          local win = tonumber(win_id_str)
          if win then
            local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
            if ok_b then render(wb, win) end
          end
        end
        return
      end
      -- Narrow fallback: render only the triggering window (ev.match is
      -- always set by WinScrolled/WinResized), avoiding a full-session sweep.
      local win = tonumber(ev.match)
      if win then
        local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
        if ok_b then render(wb, win) end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = AUGROUP,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
      if ok_b then render(wb, win) end
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
      if state.last_cursor_row and state.last_cursor_row[win] ~= nil then
        state.last_cursor_row[win] = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = AUGROUP,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local ok_b, buf = pcall(vim.api.nvim_win_get_buf, win)
      if not ok_b or not is_enabled(buf) then return end

      local scope_cfg = resolve_scope(buf)
      if not scope_cfg.enabled then return end

      local cursor = vim.api.nvim_win_get_cursor(win)
      local row = cursor[1]
      state.last_cursor_row = state.last_cursor_row or {}
      if state.last_cursor_row[win] == row then
        return
      end
      state.last_cursor_row[win] = row

      local active_col = get_current_indent_col(buf, win)
      state.current_indent = state.current_indent or {}
      if scope_cfg.range == "block" then
        state.current_indent[win] = active_col
        render(buf, win)
      else
        if state.current_indent[win] ~= active_col then
          state.current_indent[win] = active_col
          render(buf, win)
        end
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
