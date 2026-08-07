local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local utils = require("indentinator.utils")
local scope = require("indentinator.scope")

local M = {}

M.NS = vim.api.nvim_create_namespace("indentinator")

--- Builds the virtual text chunks for a single line overlay.
---@param display_col number The indentation display width of the line
---@param width number The indentation width
---@param active_col number|nil The active guide column index (if any)
---@param show_current boolean|string The show_current_indent option value
---@param show_first boolean The show_first_indent_level option value
---@param char string The guide character
---@param current_char string|nil The active scope guide character
---@param is_scope_start boolean Whether this line is the scope top boundary
---@param is_scope_end boolean Whether this line is the scope bottom boundary
---@param underline_enabled boolean Whether scope.underline is enabled
---@param underline_end_enabled boolean Whether scope.underline_end is enabled
---@param use_corner boolean Whether to draw corners
---@param corner_top string|nil Top corner character (defaults to ┏)
---@param corner_bottom string|nil Bottom corner character (defaults to ┗)
---@param underline_char string|nil Horizontal character for scope top/bottom (defaults to ━)
---@param char_hl string The standard guide highlight group
---@param current_hl string The current guide highlight group
---@param underline_hl string The scope underline highlight group
---@param gap_hl string The gap highlight group
---@param draw_gap_hl boolean Whether gap highlight is enabled
---@return table[] Array of chunks in format { { text, hl }, ... }
function M.build_virt_text(
  display_col,
  width,
  active_col,
  show_current,
  show_first,
  char,
  current_char,
  is_scope_start,
  is_scope_end,
  underline_enabled,
  underline_end_enabled,
  use_corner,
  corner_top,
  corner_bottom,
  underline_char,
  char_hl,
  current_hl,
  underline_hl,
  gap_hl,
  draw_gap_hl
)
  local chunks = {}
  local u_char = (underline_char and underline_char ~= "") and underline_char or "━"
  local c_top = (corner_top and corner_top ~= "") and corner_top or "┏"
  local c_bot = (corner_bottom and corner_bottom ~= "") and corner_bottom or "┗"

  local step = (width and width > 0) and width or 2

  local col = 0
  while col < display_col do
    local is_guide_pos = (col % step == 0) or (active_col and col == active_col)
    if col == 0 and not show_first then
      is_guide_pos = false
    end

    local is_current = (active_col and col == active_col)
    if show_current == "only" and not is_current then
      is_guide_pos = false
    end

    if is_guide_pos then
      local hl = is_current and current_hl or char_hl
      local guide_c = char
      if is_current then
        if is_scope_start and (underline_enabled or use_corner) then
          guide_c = use_corner and c_top or u_char
          hl = underline_hl or current_hl
        elseif is_scope_end and (underline_end_enabled or use_corner) then
          guide_c = use_corner and c_bot or u_char
          hl = underline_hl or current_hl
        else
          guide_c = current_char or char
        end
      end
      table.insert(chunks, { guide_c, hl })
    else
      local fill_char = " "
      local g_hl = draw_gap_hl and gap_hl or nil
      if active_col and (col > active_col) and (is_scope_start or is_scope_end) then
        if (is_scope_start and (underline_enabled or use_corner)) or (is_scope_end and (underline_end_enabled or use_corner)) then
          fill_char = u_char
          g_hl = underline_hl or current_hl
        end
      end
      table.insert(chunks, { fill_char, g_hl })
    end
    col = col + 1
  end
  return chunks
end

--- Clears the indentation guide extmarks from a specific window viewport.
---@param buf number The buffer handle
---@param win number The window handle
function M.clear_window(buf, win)
  local ranges = state.windows[buf]
  if not ranges then return end
  local r = ranges[win]
  if r then
    local start_line = math.max(0, r[1] - 1)
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.NS, start_line, r[2] + 1)
    ranges[win] = nil
  end
end

--- Clears all indentation guide extmarks from all tracked windows for a buffer.
---@param buf number The buffer handle
function M.clear_window_all(buf)
  if state.windows[buf] then
    state.windows[buf] = nil
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, M.NS, 0, -1)
end

--- Renders indentation guides for the visible lines of a buffer in a specific window.
---@param buf number The buffer handle
---@param win number The window handle
function M.render(buf, win)
  if not buf or not win or not vim.api.nvim_buf_is_loaded(buf) then return end
  if not config.is_enabled(buf, state) then
    M.clear_window(buf, win)
    return
  end

  local ok_r, r0 = pcall(vim.fn.line, "w0", win)
  if not ok_r then return end
  local ok_s, r1 = pcall(vim.fn.line, "w$", win)
  if not ok_s then return end
  if type(r0) ~= "number" or type(r1) ~= "number" or r1 < r0 or r0 <= 0 then return end

  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, r0 - 1, r1, false)
  if not ok_l or #lines == 0 then
    M.clear_window(buf, win)
    return
  end

  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  ft = (ok_ft and ft) or ""

  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)
  local show_first = config.resolve_config(buf, "show_first_indent_level", ft)

  local active_col = nil
  local scope_start, scope_end = nil, nil
  local scope_cfg = config.resolve_scope(buf, ft)
  local show_current = scope_cfg.enabled
  if show_current then
    if scope_cfg.treesitter then
      local ts_start, ts_end, ts_col = scope.get_treesitter_scope_range(buf, win, width, tabstop)
      if ts_start and ts_end and ts_col then
        scope_start = ts_start
        scope_end = ts_end
        active_col = ts_col
      end
    end

    if active_col == nil then
      active_col = utils.get_current_indent_col(buf, win)
      if active_col and scope_cfg.range == "block" then
        local cursor = vim.api.nvim_win_get_cursor(win)
        scope_start, scope_end = scope.get_scope_range(buf, cursor[1], active_col, width, tabstop)
      end
    end

    state.current_indent = state.current_indent or {}
    state.current_indent[win] = active_col
  end

  local results = {}
  local line_widths = {}
  for k, text in ipairs(lines) do
    local lead = text:match("^%s*")
    if text ~= "" and lead ~= text then
      local disp = utils.lead_display_width(lead, tabstop)
      if disp <= 1000 then
        results[k] = disp
        if lead:byte(1) == 9 then
          line_widths[k] = tabstop
        end
      end
    end
  end

  local is_smart = config.resolve_config(buf, "smart", ft)
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

        local above_val
        local above_width = nil
        if b_start > 1 then
          above_val = results[b_start - 1] or 0
          above_width = line_widths[b_start - 1]
        else
          above_val = utils.find_indent_above(buf, r0 + b_start - 2, tabstop)
        end

        local below_val
        local below_width = nil
        if b_end < nlines then
          below_val = results[b_end + 1] or 0
          below_width = line_widths[b_end + 1]
        else
          below_val = utils.find_indent_below(buf, r0 + b_end, line_count, tabstop)
        end

        local fill_val = math.max(above_val, below_val)
        local fill_width = (fill_val == above_val) and above_width or below_width
        if fill_val > 0 then
          for b = b_start, b_end do
            results[b] = fill_val
            if fill_width then line_widths[b] = fill_width end
          end
        end
      else
        k = k + 1
      end
    end
  end

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

  M.clear_window(buf, win)

  local char = config.resolve_config(buf, "char", ft)
  local current_char = config.resolve_config(buf, "current_char", ft) or char
  local char_hl = config.resolve_config(buf, "char_hl", ft)
  local current_hl = config.resolve_config(buf, "current_char_hl", ft)
  local gap_hl = config.resolve_config(buf, "gap_hl", ft)
  local draw_gap_hl = config.resolve_config(buf, "draw_gap_hl", ft)
  local priority = config.resolve_config(buf, "priority", ft)
  local underline_enabled = scope_cfg.underline == true
  local underline_end_enabled = scope_cfg.underline_end == true
  local underline_hl = config.resolve_config(buf, "scope_underline_hl", ft)
  local text_highlight_enabled = scope_cfg.text_highlight ~= false
  local text_hl = config.resolve_config(buf, "scope_text_hl", ft)

  local use_corner = scope_cfg.corner ~= false
  local corner_top = scope_cfg.corner_top
  local corner_bottom = scope_cfg.corner_bottom
  local underline_char = scope_cfg.underline_char

  local fold_enabled = false
  local ok_fe, fe = pcall(function() return vim.wo[win].foldenable end)
  if ok_fe and fe == true then
    fold_enabled = true
  end

  local k = 1
  local nlines = #lines
  while k <= nlines do
    local disp_col = results[k]
    local abs_line = r0 - 1 + k
    local line_idx = r0 - 2 + k
    local is_hidden_fold = false

    if fold_enabled then
      local fc = vim.fn.foldclosed(abs_line)
      if fc > 0 and fc ~= abs_line then
        is_hidden_fold = true
        local fend = vim.fn.foldclosedend(abs_line)
        if fend > abs_line then
          k = k + (fend - abs_line + 1)
        else
          k = k + 1
        end
      end
    end

    if not is_hidden_fold then
      local is_this_scope_start = (scope_start ~= nil and abs_line == scope_start)
      local is_this_scope_end = (scope_end ~= nil and abs_line == scope_end and scope_end > (scope_start or 0))

      if is_this_scope_start and (underline_enabled or text_highlight_enabled) and not occupied[abs_line] then
        local scope_line_text = lines[k]
        local text_len = #scope_line_text
        local lead_len = #(scope_line_text:match("^%s*"))
        local start_byte = lead_len
        if active_col and active_col > 0 then
          local dcol = 0
          local i = 1
          while i <= text_len and dcol < active_col do
            local b = scope_line_text:byte(i)
            dcol = dcol + (b == 9 and (tabstop - (dcol % tabstop)) or 1)
            if dcol <= active_col then start_byte = i end
            i = i + 1
          end
          start_byte = math.max(start_byte, lead_len)
        end
        if text_len > start_byte then
          if underline_enabled then
            pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, line_idx, start_byte, {
              end_row = line_idx,
              end_col = text_len,
              hl_group = underline_hl,
              hl_eol = false,
              hl_mode = "combine",
              priority = priority + 1,
            })
          end
          if text_highlight_enabled then
            if text_len > lead_len then
              pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, line_idx, lead_len, {
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

      if is_this_scope_end and underline_end_enabled and not occupied[abs_line] then
        local scope_end_text = lines[k]
        local text_len = #scope_end_text
        local lead_len = #(scope_end_text:match("^%s*"))
        local start_byte = lead_len
        if active_col and active_col > 0 then
          local dcol = 0
          local i = 1
          while i <= text_len and dcol < active_col do
            local b = scope_end_text:byte(i)
            dcol = dcol + (b == 9 and (tabstop - (dcol % tabstop)) or 1)
            if dcol <= active_col then start_byte = i end
            i = i + 1
          end
          start_byte = math.max(start_byte, lead_len)
        end
        if text_len > start_byte then
          pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, line_idx, start_byte, {
            end_row = line_idx,
            end_col = text_len,
            hl_group = underline_hl,
            hl_eol = false,
            hl_mode = "combine",
            priority = priority + 1,
          })
        end
      end

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

      if disp_col and disp_col > 0 and not occupied[abs_line] then
        local step_width = line_widths[k] or width
        local chunks = M.build_virt_text(
          disp_col,
          step_width,
          line_active_col,
          show_current,
          show_first,
          char,
          current_char,
          is_this_scope_start,
          is_this_scope_end,
          underline_enabled,
          underline_end_enabled,
          use_corner,
          corner_top,
          corner_bottom,
          underline_char,
          char_hl,
          current_hl,
          underline_hl,
          gap_hl,
          draw_gap_hl
        )

        if #chunks > 0 then
          local has_visible = false
          for _, chunk in ipairs(chunks) do
            local text_val, hl = chunk[1], chunk[2]
            if hl and (text_val:find("[^ ]") or draw_gap_hl) then
              has_visible = true
              break
            end
          end

          if has_visible then
            pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
              virt_text = chunks,
              virt_text_pos = "overlay",
              hl_mode = "combine",
              priority = priority,
            })
          end
        end
      end

      k = k + 1
    end
  end

  state.windows[buf] = state.windows[buf] or {}
  state.windows[buf][win] = { r0, r1 }
end

--- Triggers rendering on all windows showing the specified buffer.
---@param buf number The buffer handle
function M.render_all(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
    if ok_b and wb == buf then M.render(buf, win) end
  end
end

--- Attaches buffer-change listeners to the specified buffer.
---@param buf number The buffer handle
function M.attach(buf)
  if state.attached[buf] and vim.api.nvim_buf_is_loaded(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then
    state.attached[buf] = nil
    return
  end

  local function schedule_render()
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local timer = state.timers[buf]
    if timer and not timer:is_closing() then
      timer:stop()
    else
      timer = vim.uv.new_timer()
      state.timers[buf] = timer
    end

    timer:start(15, 0, vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.render_all(buf)
      end
    end))
  end

  local ok, res = pcall(vim.api.nvim_buf_attach, buf, false, {
    on_bytes = function(...)
      if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
        state.attached[buf] = nil
        return true
      end
      schedule_render(...)
    end,
  })
  state.attached[buf] = ok and res or nil
end

--- Initialises the default highlight groups.
function M.set_hl()
  local scope_style = { fg = "#cdd6f4", bold = true, sp = "#cdd6f4", default = true }
  local style_opt = config.defaults and config.defaults.scope and config.defaults.scope.underline_style or "underdouble"
  if style_opt == "underdouble" then
    scope_style.underdouble = true
  elseif style_opt == "undercurl" then
    scope_style.undercurl = true
  elseif style_opt == "underdashed" then
    scope_style.underdashed = true
  elseif style_opt == "underdotted" then
    scope_style.underdotted = true
  else
    scope_style.underline = true
  end

  vim.api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorGap", { fg = "#555b6e", bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorCurrentGuide", { fg = "#cdd6f4", bold = true, bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "IndentinatorScopeUnderline", scope_style)
  vim.api.nvim_set_hl(0, "IndentinatorScopeText", { fg = "#cdd6f4", bold = true, bg = "NONE", default = true })
end

return M
