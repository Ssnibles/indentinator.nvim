--- Extmark rendering engine for indentinator.nvim.
--- Handles virtual text construction, scope extmark rendering, buffer listeners, and highlight groups.

local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local utils = require("indentinator.utils")
local scope = require("indentinator.scope")

local api = vim.api
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_get_option_value = api.nvim_get_option_value
local nvim_buf_set_extmark = api.nvim_buf_set_extmark
local nvim_buf_clear_namespace = api.nvim_buf_clear_namespace
local nvim_win_get_cursor = api.nvim_win_get_cursor
local nvim_buf_line_count = api.nvim_buf_line_count
local nvim_list_wins = api.nvim_list_wins
local nvim_win_get_buf = api.nvim_win_get_buf

local M = {}

--- Unique namespace for indentinator extmarks
M.NS = api.nvim_create_namespace("indentinator")

--- Default highlight group names for rainbow delimiters.
M.DEFAULT_RAINBOW_HLS = {
  "IndentinatorRainbow1",
  "IndentinatorRainbow2",
  "IndentinatorRainbow3",
  "IndentinatorRainbow4",
  "IndentinatorRainbow5",
  "IndentinatorRainbow6",
  "IndentinatorRainbow7",
}

--- Builds virtual text chunks for a single line overlay.
---@param display_col integer Indentation display column width of line
---@param width integer Indentation step width
---@param active_col integer|nil Active guide column index
---@param show_current boolean|string Show current indent option
---@param show_first boolean Show first indent level option
---@param char string Standard guide character
---@param current_char string|nil Active scope guide character
---@param is_scope_start boolean Whether line is scope top boundary
---@param is_scope_end boolean Whether line is scope bottom boundary
---@param use_corner boolean Whether to draw corners
---@param corner_top string|nil Custom top corner character
---@param corner_bottom string|nil Custom bottom corner character
---@param underline_char string|nil Custom horizontal connector line character
---@param char_hl string Standard guide highlight group
---@param current_hl string Current guide highlight group
---@param gap_hl string Gap highlight group
---@param draw_gap_hl boolean Whether gap highlight is enabled
---@param start_col integer|nil Horizontal scroll start column (leftcol)
---@param active_scope_col integer|nil Active scope column for view
---@param only_scope boolean|nil Whether to suppress active guide column outside scope
---@return table[] Array of virtual text chunks `{ { text, hl }, ... }`
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
  use_corner,
  corner_top,
  corner_bottom,
  underline_char,
  char_hl,
  current_hl,
  gap_hl,
  draw_gap_hl,
  start_col,
  _active_scope_col,
  _only_scope
)
  local chunks = {}
  local u_char = (underline_char and underline_char ~= "") and underline_char or "━"
  local c_top = (corner_top and corner_top ~= "") and corner_top or "┏"
  local c_bot = (corner_bottom and corner_bottom ~= "") and corner_bottom or "┗"

  local step = (width and width > 0) and width or 2
  start_col = start_col or 0

  local col = start_col
  while col < display_col do
    local is_guide_pos = (col % step == 0) or (active_col and col == active_col)
    if col == 0 and not show_first then
      is_guide_pos = false
    end

    local is_current = (active_col and col == active_col)
    if show_current == "only" and not is_current then
      is_guide_pos = false
    end

    local effective_use_corner = use_corner
    if use_corner and (not active_col or active_col == 0 or display_col <= active_col + 1) then
      effective_use_corner = false
    end

    if is_guide_pos then
      local hl = is_current and current_hl or char_hl
      local guide_c = char
      if is_current then
        if is_scope_start and effective_use_corner then
          guide_c = c_top
          hl = current_hl
        elseif is_scope_end and effective_use_corner then
          guide_c = c_bot
          hl = current_hl
        else
          guide_c = current_char or char
        end
      end
      chunks[#chunks + 1] = { guide_c, hl }
    else
      local fill_char = " "
      local g_hl = draw_gap_hl and gap_hl or nil
      local is_corner_gap = active_col
        and (col > active_col)
        and (col < active_col + step)
        and (is_scope_start or is_scope_end)
        and effective_use_corner
      if is_corner_gap then
        fill_char = u_char
        g_hl = current_hl
      end
      chunks[#chunks + 1] = { fill_char, g_hl }
    end
    col = col + 1
  end
  return chunks
end

--- Clears extmarks from a specific window viewport.
---@param buf integer Buffer handle
---@param win integer Window handle
function M.clear_window(buf, win)
  local ranges = state.windows[buf]
  if not ranges then return end
  local r = ranges[win]
  if r then
    local start_line = math.max(0, r[1] - 1)
    local line_count = nvim_buf_line_count(buf)
    local end_line = math.min(line_count, r[2] + 1)
    pcall(nvim_buf_clear_namespace, buf, M.NS, start_line, end_line)
    ranges[win] = nil
  end
end

--- Clears all extmarks from all tracked windows for a buffer.
---@param buf integer Buffer handle
function M.clear_window_all(buf)
  if state.windows[buf] then
    state.windows[buf] = nil
  end
  pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
end

--- Applies scope block background highlight extmark.
---@param buf integer Buffer handle
---@param line_idx integer 0-indexed line row
---@param bg_hl string Highlight group
---@param priority integer Priority level
local function render_scope_bg(buf, line_idx, bg_hl, priority)
  pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
    end_row = line_idx,
    end_col = 0,
    line_hl_group = bg_hl,
    priority = priority + 2,
  })
end

--- Applies text highlight on scope start header line.
---@param buf integer Buffer handle
---@param line_idx integer 0-indexed line row
---@param line_text string Full line string
---@param text_hl string Highlight group
---@param priority integer Priority level
local function render_scope_text_hl(buf, line_idx, line_text, text_hl, priority)
  local text_len = #line_text
  local lead_len = #(line_text:match("^%s*") or "")
  if text_len > lead_len then
    pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, lead_len, {
      end_row = line_idx,
      end_col = text_len,
      hl_group = text_hl,
      hl_eol = false,
      hl_mode = "combine",
      priority = priority + 101,
    })
  end
end

--- Resolves effective highlight group for delimiter token, stripping underline if disabled.
---@param base_hl string Base highlight group name
---@param underline boolean Whether underline decoration is enabled
---@return string Effective highlight group name
local function get_effective_delim_hl(base_hl, underline)
  if underline then
    return base_hl
  end

  if base_hl == "IndentinatorScopeDelimiter" then
    return "IndentinatorScopeDelimiterNoUnderline"
  end

  if base_hl:sub(-11) == "NoUnderline" then
    return base_hl
  end

  local no_ul_hl = base_hl .. "NoUnderline"
  local ok, hl_def = pcall(api.nvim_get_hl, 0, { name = base_hl, link = false })
  if ok and hl_def then
    local new_def = vim.deepcopy(hl_def)
    new_def.underline = false
    new_def.sp = nil
    pcall(api.nvim_set_hl, 0, no_ul_hl, new_def)
    return no_ul_hl
  end

  return base_hl
end

--- Applies delimiter highlight extmarks on scope boundary line.
---@param buf integer Buffer handle
---@param line_idx integer 0-indexed line row
---@param delims integer[][] List of { s_col, e_col } byte ranges
---@param delim_hl string Highlight group
---@param priority integer Priority level
---@param underline boolean|nil Whether to apply underline decoration to delimiters
local function render_delimiters(buf, line_idx, delims, delim_hl, priority, underline)
  local effective_hl = get_effective_delim_hl(delim_hl, underline ~= false)
  for _, range in ipairs(delims) do
    pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, range[1], {
      end_row = line_idx,
      end_col = range[2],
      hl_group = effective_hl,
      hl_eol = false,
      hl_mode = "combine",
      priority = priority + 105,
    })
  end
end

local uv = vim.uv or vim.loop

--- Calculates blank line display column values for empty line blocks.
---@param lines string[] Array of visible line texts
---@param results table<integer, integer> Map of line index to display col
---@param line_widths table<integer, integer> Map of line index to step width
---@param buf integer Buffer handle
---@param r0 integer Top visible line row (1-indexed)
---@param tabstop integer Buffer tabstop width
local function process_blank_lines(lines, results, line_widths, buf, r0, tabstop)
  if not buf or not nvim_buf_is_valid(buf) then
    return
  end

  local k = 1
  local nlines = #lines
  local line_count = nvim_buf_line_count(buf)

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

      local above_val = (b_start > 1) and (results[b_start - 1] or 0)
        or utils.find_indent_above(buf, r0 + b_start - 2, tabstop)
      local above_width = (b_start > 1) and line_widths[b_start - 1] or nil

      local below_val = (b_end < nlines) and (results[b_end + 1] or 0)
        or utils.find_indent_below(buf, r0 + b_end, line_count, tabstop)
      local below_width = (b_end < nlines) and line_widths[b_end + 1] or nil

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

--- Renders indentation guides for visible lines in a specific window.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param skip_clear boolean|nil Whether to skip clearing prior extmarks
function M.render(buf, win, skip_clear)
  if not buf or not win or not nvim_win_is_valid(win) or not nvim_buf_is_loaded(buf) then
    return
  end
  if not config.is_enabled(buf, state) then
    M.clear_window(buf, win)
    return
  end

  if not skip_clear then
    M.clear_window(buf, win)
  end

  local ok_view, view = pcall(function()
    return api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$"), vim.fn.winsaveview().leftcol }
    end)
  end)
  if not ok_view or type(view) ~= "table" then return end
  local r0, r1 = view[1], view[2]
  if type(r0) ~= "number" or type(r1) ~= "number" or r1 < r0 or r0 <= 0 then return end
  local leftcol = (type(view[3]) == "number" and view[3] >= 0) and view[3] or 0

  local ok_l, lines = pcall(nvim_buf_get_lines, buf, r0 - 1, r1, false)
  if not ok_l or #lines == 0 then
    if not skip_clear then M.clear_window(buf, win) end
    return
  end

  local ok_ft, ft = pcall(nvim_get_option_value, "filetype", { buf = buf })
  ft = (ok_ft and type(ft) == "string") and ft or ""

  local width = utils.indent_width(buf, ft)
  local tabstop = utils.buffer_tabstop(buf)
  local show_first = config.resolve_config(buf, "show_first_indent_level", ft)

  local scope_start, scope_end, active_col, scope_node = nil, nil, nil, nil
  local scope_cfg = config.resolve_scope(buf, ft)
  local show_current = scope_cfg.enabled

  if show_current then
    if scope_cfg.treesitter then
      scope_start, scope_end, active_col, scope_node = scope.get_treesitter_scope_range(buf, win, width, tabstop)
    end
    if scope_start == nil then
      active_col = utils.get_current_indent_col(buf, win)
      if active_col and scope_cfg.range == "block" then
        local cursor = nvim_win_get_cursor(win)
        scope_start, scope_end = scope.get_scope_range(buf, cursor[1], active_col, width, tabstop)
      end
    end

    state.current_indent = state.current_indent or {}
    state.current_indent[win] = active_col
  end

  local body_start = scope_start
  if show_current and scope_start ~= nil and scope_end ~= nil then
    if scope_node then
      local ok_r, s_r = pcall(function()
        local type_name = scope_node:type()
        if scope.BODY_CONTAINER_TYPES[type_name] then
          return scope_node:range()
        end
        for child in scope_node:iter_children() do
          if scope.BODY_CONTAINER_TYPES[child:type()] then
            local cs_r = child:range()
            return cs_r
          end
        end
        return scope_node:range()
      end)
      if ok_r and s_r then
        body_start = math.max(scope_start, math.min(scope_end, s_r + 1))
      end
    else
      local ok_l, scope_lines = pcall(nvim_buf_get_lines, buf, scope_start - 1, scope_end, false)
      if ok_l and scope_lines and #scope_lines > 0 then
        local hdr_lead = scope_lines[1]:match("^%s*") or ""
        local hdr_indent = utils.lead_display_width(hdr_lead, tabstop)
        for i = 2, #scope_lines do
          local line_t = scope_lines[i]
          local lead_t = line_t:match("^%s*")
          if line_t ~= "" and lead_t ~= line_t then
            local disp_t = utils.lead_display_width(lead_t, tabstop)
            if disp_t > hdr_indent then
              body_start = scope_start + i - 2
              break
            end
          end
        end
      end
    end
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
    process_blank_lines(lines, results, line_widths, buf, r0, tabstop)
  end

  local char = config.resolve_config(buf, "char", ft)
  local current_char = config.resolve_config(buf, "current_char", ft) or char
  local char_hl = config.resolve_config(buf, "char_hl", ft)
  local current_hl = config.resolve_config(buf, "current_char_hl", ft)
  local gap_hl = config.resolve_config(buf, "gap_hl", ft)
  local draw_gap_hl = config.resolve_config(buf, "draw_gap_hl", ft)
  local priority = config.resolve_config(buf, "priority", ft)
  local bg_opt = scope_cfg.background
  local bg_enabled = bg_opt == true or bg_opt == "block" or bg_opt == "boundaries"
  local bg_full_block = bg_opt == true or bg_opt == "block"
  local bg_hl = config.resolve_config(buf, "scope_bg_hl", ft)
  local text_highlight_enabled = scope_cfg.text_highlight ~= false
  local text_hl = config.resolve_config(buf, "scope_text_hl", ft)
  local rainbow_enabled = scope_cfg.rainbow_delimiters == true
  local delimiters_enabled = scope_cfg.delimiters == true or rainbow_enabled
  local delim_hl = config.resolve_config(buf, "scope_delimiter_hl", ft)

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
      local is_in_scope = (scope_start ~= nil and scope_end ~= nil
        and abs_line >= scope_start and abs_line <= scope_end)
      local is_in_header_range = (scope_start ~= nil and body_start ~= nil
        and abs_line >= scope_start and abs_line <= body_start)

      if is_in_scope and bg_enabled then
        if bg_full_block or is_this_scope_start or is_this_scope_end then
          render_scope_bg(buf, line_idx, bg_hl, priority)
        end
      end

      if is_this_scope_start and text_highlight_enabled then
        render_scope_text_hl(buf, line_idx, lines[k], text_hl, priority)
      end

      if delimiters_enabled then
        local delims = {}
        local seen_keys = {}
        if is_in_header_range then
          local open_delims = nil
          if scope_node then
            open_delims = scope.get_treesitter_delimiters(scope_node, line_idx, true)
          end
          if not open_delims or #open_delims == 0 then
            open_delims = scope.find_delimiters(lines[k], true, ft)
          end
          for _, d in ipairs(open_delims) do
            local key = d[1] .. ":" .. d[2]
            if not seen_keys[key] then
              seen_keys[key] = true
              table.insert(delims, d)
            end
          end
        end
        if is_this_scope_end then
          local close_delims = nil
          if scope_node then
            close_delims = scope.get_treesitter_delimiters(scope_node, line_idx, false)
          end
          if not close_delims or #close_delims == 0 then
            close_delims = scope.find_delimiters(lines[k], false, ft)
          end
          for _, d in ipairs(close_delims) do
            local key = d[1] .. ":" .. d[2]
            if not seen_keys[key] then
              seen_keys[key] = true
              table.insert(delims, d)
            end
          end
        end
        if #delims > 0 then
          local active_delim_hl = delim_hl
          if rainbow_enabled or scope_cfg.rainbow_hls then
            local step_w = (line_widths[k] or width)
            step_w = (step_w and step_w > 0) and step_w or 2
            local depth = math.max(1, math.floor((active_col or 0) / step_w) + 1)
            local rainbow_hls = scope_cfg.rainbow_hls or M.DEFAULT_RAINBOW_HLS
            if #rainbow_hls > 0 then
              active_delim_hl = rainbow_hls[(depth - 1) % #rainbow_hls + 1]
            end
          end
          local underline_delims = scope_cfg.underline_delimiters ~= false
          render_delimiters(buf, line_idx, delims, active_delim_hl, priority, underline_delims)
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

      local render_col = disp_col or 0
      local is_scope_blank = render_col == 0 and line_active_col and scope_start and scope_end
        and abs_line >= scope_start and abs_line <= scope_end
      if is_scope_blank then
        if lines[k] == "" then
          render_col = line_active_col + (line_widths[k] or width)
        end
      end

      if render_col > leftcol then
        local step_width = line_widths[k] or width
        local chunks = M.build_virt_text(
          render_col,
          step_width,
          line_active_col,
          show_current,
          show_first,
          char,
          current_char,
          is_this_scope_start,
          is_this_scope_end,
          use_corner,
          corner_top,
          corner_bottom,
          underline_char,
          char_hl,
          current_hl,
          gap_hl,
          draw_gap_hl,
          leftcol,
          active_col,
          scope_cfg.only_scope
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
            pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
              virt_text = chunks,
              virt_text_win_col = 0,
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

--- Triggers rendering on all valid windows displaying buffer.
---@param buf integer Buffer handle
function M.render_all(buf)
  if not buf or not nvim_buf_is_valid(buf) or not nvim_buf_is_loaded(buf) then
    return
  end

  local cur_win = pcall(api.nvim_get_current_win) and api.nvim_get_current_win() or nil
  local wins = {}

  for _, win in ipairs(nvim_list_wins()) do
    local ok_b, wb = pcall(nvim_win_get_buf, win)
    if ok_b and wb == buf then
      if win == cur_win then
        wins[#wins + 1] = win
      else
        table.insert(wins, 1, win)
      end
    end
  end

  if #wins > 0 then
    pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
    if state.windows[buf] then state.windows[buf] = {} end
    for _, win in ipairs(wins) do
      M.render(buf, win, true)
    end
  end
end

--- Attaches buffer-change listeners to buffer.
---@param buf integer Buffer handle
function M.attach(buf)
  if state.attached[buf] and nvim_buf_is_loaded(buf) then
    return
  end
  if not nvim_buf_is_loaded(buf) then
    state.attached[buf] = nil
    return
  end

  local function schedule_render()
    if not nvim_buf_is_valid(buf) then return end

    local timer = state.timers[buf]
    if timer and not timer:is_closing() then
      timer:stop()
    else
      timer = uv.new_timer()
      state.timers[buf] = timer
    end

    timer:start(15, 0, vim.schedule_wrap(function()
      if nvim_buf_is_valid(buf) then
        M.render_all(buf)
      end
    end))
  end

  local ok, res = pcall(api.nvim_buf_attach, buf, false, {
    on_bytes = function(...)
      if not nvim_buf_is_valid(buf) or not nvim_buf_is_loaded(buf) then
        state.attached[buf] = nil
        state_mod.clear_timer(buf)
        return true
      end
      schedule_render(...)
    end,
  })
  state.attached[buf] = ok and res or nil
end

--- Initialises default highlight groups for indentinator.
function M.set_hl()
  api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE", default = true })
  api.nvim_set_hl(0, "IndentinatorGap", { fg = "#555b6e", bg = "NONE", default = true })
  api.nvim_set_hl(0, "IndentinatorCurrentGuide", { fg = "#cdd6f4", bold = true, bg = "NONE", default = true })
  api.nvim_set_hl(0, "IndentinatorScopeText", { fg = "#cdd6f4", bold = true, bg = "NONE", default = true })
  api.nvim_set_hl(0, "IndentinatorScopeBg", { bg = "#1c1e2a", default = true })
  api.nvim_set_hl(0, "IndentinatorScopeDelimiter", {
    fg = "#cdd6f4",
    bold = true,
    italic = true,
    underline = true,
    sp = "#cdd6f4",
    default = true,
  })
  api.nvim_set_hl(0, "IndentinatorScopeDelimiterNoUnderline", {
    fg = "#cdd6f4",
    bold = true,
    italic = true,
    underline = false,
    default = true,
  })

  local rainbow_colors = {
    IndentinatorRainbow1 = "#e06c75",
    IndentinatorRainbow2 = "#e5c07b",
    IndentinatorRainbow3 = "#98c379",
    IndentinatorRainbow4 = "#56b6c2",
    IndentinatorRainbow5 = "#61afef",
    IndentinatorRainbow6 = "#c678dd",
    IndentinatorRainbow7 = "#d19a66",
  }
  for name, hex in pairs(rainbow_colors) do
    api.nvim_set_hl(0, name, {
      fg = hex,
      bold = true,
      italic = true,
      underline = true,
      sp = hex,
      default = true,
    })
    api.nvim_set_hl(0, name .. "NoUnderline", {
      fg = hex,
      bold = true,
      italic = true,
      underline = false,
      default = true,
    })
  end
end

return M
