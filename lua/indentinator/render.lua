--- Viewport renderer module for indentinator.nvim.
--- Handles extmark drawing for standard indent guides, rainbow colors, scope corners,
--- and boundary highlights. Uses viewport-scoped persistent extmarks and reuses
--- option tables to minimise allocations in hot redraw loops.
---@class indentinator.render
local M = {}

local config = require("indentinator.config")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")
local hooks = require("indentinator.hooks")
local utils = require("indentinator.utils")

local api = vim.api
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_clear_namespace = api.nvim_buf_clear_namespace
local nvim_list_wins = api.nvim_list_wins
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_buf_line_count = api.nvim_buf_line_count

--- Extmark namespace handle for indentinator
M.NS = api.nvim_create_namespace("indentinator")

--- Cached VirtText tuples to prevent table allocations during rendering.
--- Structure: VIRT_TEXT_CACHE[char][hl_group] -> { { char, hl_group } }
local VIRT_TEXT_CACHE = {}

--- Clears the VirtText cache (e.g. after colorscheme change).
function M.clear_virt_text_cache()
  VIRT_TEXT_CACHE = {}
end

--- Retrieves or creates a memoized VirtText tuple.
---@param char string
---@param hl string
---@return table
local function get_virt_text(char, hl)
  local sub = VIRT_TEXT_CACHE[char]
  if not sub then
    sub = {}
    VIRT_TEXT_CACHE[char] = sub
  end
  local vt = sub[hl]
  if not vt then
    vt = { { char, hl } }
    sub[hl] = vt
  end
  return vt
end

--- Reusable option tables for nvim_buf_set_extmark to reduce allocations.
local EXTMARK_OPTS = {
  virt_text = nil,
  virt_text_win_col = 0,
  hl_mode = "combine",
  priority = 100,
}

local HEADER_OPTS = {
  line_hl_group = nil,
  priority = 99,
}

local DELIM_OPTS = {
  end_col = 0,
  hl_group = nil,
  priority = 115,
}

--- Distinct extmark failures already reported, so a persistent error is logged
--- once instead of on every line of every redraw.
local reported_extmark_errors = {}

--- Sets an extmark, surfacing the first occurrence of each distinct failure via
--- `vim.notify`. Errors are reported but never abort the render loop, since an
--- extmark can legitimately fail if the buffer/window changed mid-render.
---@param buf integer Buffer handle
---@param row integer 0-indexed row
---@param col integer 0-indexed column
---@param opts table Extmark options
---@return boolean ok
local function set_extmark(buf, row, col, opts)
  local ok, err = pcall(api.nvim_buf_set_extmark, buf, M.NS, row, col, opts)
  if not ok then
    local msg = tostring(err)
    if not reported_extmark_errors[msg] then
      reported_extmark_errors[msg] = true
      vim.notify("indentinator: failed to set extmark: " .. msg, vim.log.levels.WARN)
    end
  end
  return ok
end

---@class indentinator.WinRenderContext
---@field buf integer Buffer handle
---@field win integer Window handle
---@field toprow integer 0-indexed top line
---@field botrow integer 0-indexed bottom line
---@field indent_width integer Display width of one indent level
---@field tabstop integer Buffer tabstop
---@field leftcol integer Horizontal scroll offset
---@field scope indentinator.ScopeInfo|nil
---@field scope_enabled boolean
---@field indent_enabled boolean
---@field rainbow_enabled boolean
---@field delimiters_enabled boolean
---@field scope_cfg table
---@field indent_cfg table
---@field delims_cfg table
---@field rainbow_count integer
---@field priority integer
---@field widths integer[] Reused array of target visual indent widths
---@field is_blank boolean[] Reused array of blank line flags

--- Per-window rendering contexts
---@type table<integer, indentinator.WinRenderContext>
local WIN_CTX = {}

--- Initialises highlight groups for indent guides, active scope, delimiters, and rainbow columns.
function M.set_hl()
  api.nvim_set_hl(0, "IndentinatorIndent", {
    fg = "#45475a",
    bg = "NONE",
    default = true,
  })
  api.nvim_set_hl(0, "IndentinatorScope", {
    fg = "#cdd6f4",
    bold = true,
    bg = "NONE",
    default = true,
  })

  local rainbow_cfg = config.values.indent and config.values.indent.rainbow
  local delims_cfg = config.values.delimiters or {}
  local bold_opt = delims_cfg.bold == true
  local italic_opt = delims_cfg.italic == true
  local underline_opt = delims_cfg.underline == true

  api.nvim_set_hl(0, "IndentinatorDelimiter", {
    link = delims_cfg.hl or "IndentinatorScope",
    bold = bold_opt,
    italic = italic_opt,
    underline = underline_opt,
  })

  local rainbow_colors = (rainbow_cfg and rainbow_cfg.colors) or config.defaults.indent.rainbow.colors
  if type(rainbow_colors) == "table" then
    for idx, hex in ipairs(rainbow_colors) do
      api.nvim_set_hl(0, "IndentinatorRainbow" .. idx, {
        fg = hex,
        bg = "NONE",
        default = true,
      })
      api.nvim_set_hl(0, "IndentinatorDelimiter" .. idx, {
        fg = hex,
        bold = bold_opt,
        italic = italic_opt,
        underline = underline_opt,
        bg = "NONE",
      })
    end
  end
end

--- Clears cached render context associated with a window.
---@param win integer Window handle
function M.clear_win(win)
  WIN_CTX[win] = nil
end

--- Clears all extmarks and cached render state for a buffer.
---@param buf integer Buffer handle
function M.clear(buf)
  if buf and nvim_buf_is_valid(buf) then
    pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
    cache.clear_rendered_buf(buf)
  end
end

--- Prepares window rendering context and pre-computes display widths for viewport lines.
--- Reuses arrays to avoid garbage collection allocations.
---@param win integer Window handle
---@param buf integer Buffer handle
---@param toprow integer 0-indexed top row
---@param botrow integer 0-indexed bottom row
---@param total_lines integer Total line count in buffer
---@return boolean success
function M.prepare_win_context(win, buf, toprow, botrow, total_lines)
  local ctx = WIN_CTX[win]
  if not ctx then
    ctx = {
      buf = buf,
      win = win,
      toprow = toprow,
      botrow = botrow,
      indent_width = 2,
      tabstop = 8,
      leftcol = 0,
      scope = nil,
      lines = nil,
      scope_enabled = true,
      indent_enabled = true,
      rainbow_enabled = false,
      delimiters_enabled = false,
      scope_cfg = {},
      indent_cfg = {},
      delims_cfg = {},
      rainbow_count = 6,
      priority = 100,
      widths = {},
      is_blank = {},
    }
    WIN_CTX[win] = ctx
  else
    ctx.buf = buf
    ctx.win = win
    ctx.toprow = toprow
    ctx.botrow = botrow
  end

  local cfg = config.get(buf)
  local indent_cfg = cfg.indent or {}
  local scope_cfg = cfg.scope or {}
  local rainbow_cfg = indent_cfg.rainbow or {}
  local delims_cfg = cfg.delimiters or {}

  ctx.indent_cfg = indent_cfg
  ctx.scope_cfg = scope_cfg
  ctx.delims_cfg = delims_cfg
  ctx.indent_enabled = indent_cfg.enabled ~= false
  ctx.scope_enabled = scope_cfg.enabled ~= false
  ctx.rainbow_enabled = rainbow_cfg.enabled == true and type(rainbow_cfg.colors) == "table" and #rainbow_cfg.colors > 0
  ctx.delimiters_enabled = ctx.scope_enabled and delims_cfg.enabled ~= false
  ctx.priority = cfg.priority or 100
  ctx.indent_width = utils.indent_width(buf)
  ctx.tabstop = utils.buffer_tabstop(buf)

  local rainbow_colors = rainbow_cfg.colors or config.defaults.indent.rainbow.colors
  ctx.rainbow_count = #rainbow_colors

  -- Retrieve leftcol horizontal scrolling offset
  local ok_v, view = pcall(function()
    return api.nvim_win_call(win, function()
      return vim.fn.winsaveview().leftcol or 0
    end)
  end)
  ctx.leftcol = (ok_v and type(view) == "number" and view >= 0) and view or 0

  -- Resolve active scope for current cursor position
  if ctx.scope_enabled and hooks.is_scope_active(buf) then
    local cursor = api.nvim_win_get_cursor(win)
    if cache.is_cursor_in_scope(win, buf, cursor[1], cursor[2]) then
      ctx.scope = cache.get_win_scope(win, buf)
    else
      local s = nil
      if scope_cfg.treesitter ~= false then
        s = treesitter.resolve_treesitter_scope(buf, win, cursor[1], cursor[2])
      end
      if not s then
        s = treesitter.resolve_indent_scope(buf, win, cursor[1])
      end
      if s then
        cache.set_win_scope(win, buf, cursor[1], cursor[2], s)
        ctx.scope = s
      else
        cache.set_win_scope(win, buf, cursor[1], cursor[2], nil)
        ctx.scope = nil
      end
    end
  else
    ctx.scope = nil
  end

  -- Fetch visible viewport lines in a single batch
  local ok_lines, all_lines = pcall(nvim_buf_get_lines, buf, toprow, botrow, false)
  if not ok_lines or not all_lines or #all_lines == 0 then
    return false
  end
  ctx.lines = all_lines

  local n = #all_lines
  local widths = ctx.widths
  local is_blank = ctx.is_blank

  -- Clear any trailing items from previous larger batch
  for k = n + 1, #widths do
    widths[k] = nil
    is_blank[k] = nil
  end

  for i = 1, n do
    local text = all_lines[i]
    local lead = text:match("^%s*") or ""
    local is_b = (text == "" or #lead == #text)
    is_blank[i] = is_b
    if not is_b then
      widths[i] = utils.lead_display_width(lead, ctx.tabstop)
    end
  end

  -- Resolve display widths for blank lines using adjacent non-blank lines
  local i = 1
  while i <= n do
    if is_blank[i] then
      local run_start = i
      while i <= n and is_blank[i] do
        i = i + 1
      end
      local run_end = i - 1

      local up_w
      if run_start > 1 then
        up_w = widths[run_start - 1]
      else
        local _, up_lead = utils.find_non_blank_up(buf, toprow + run_start - 1, 100)
        up_w = up_lead and utils.lead_display_width(up_lead, ctx.tabstop) or 0
      end

      local down_w
      if run_end < n then
        down_w = widths[run_end + 1]
      else
        local _, down_lead = utils.find_non_blank_down(buf, toprow + run_end + 1, total_lines, 100)
        down_w = down_lead and utils.lead_display_width(down_lead, ctx.tabstop) or 0
      end

      local target = math.min(up_w, down_w)
      for k = run_start, run_end do
        widths[k] = target
      end
    else
      i = i + 1
    end
  end

  return true
end

--- Renders a single line's indent and scope guides.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param row integer 0-indexed line row
function M.render_line(buf, win, row)
  local ctx = WIN_CTX[win]
  if not ctx or ctx.buf ~= buf then
    return
  end

  local line_1based = row + 1
  local batch_idx = row - ctx.toprow + 1
  local is_blank = ctx.is_blank[batch_idx]
  local target_width = ctx.widths[batch_idx]

  if target_width == nil then
    return
  end

  if hooks.skip_line(buf, row, (ctx.lines and ctx.lines[batch_idx]) or "") then
    return
  end

  local scope = ctx.scope
  local in_scope_range = scope and (line_1based >= scope.scope_start and line_1based <= scope.scope_end)
  local active_col = scope and scope.active_col or nil
  local width = ctx.indent_width
  local max_col = target_width - (is_blank and 0 or width)

  -- Scope header line highlight
  if ctx.scope_enabled and in_scope_range and line_1based == scope.scope_start and ctx.scope_cfg.hl_header then
    HEADER_OPTS.line_hl_group = ctx.scope_cfg.hl_header
    HEADER_OPTS.priority = ctx.priority - 1
    set_extmark(buf, row, 0, HEADER_OPTS)
  end

  -- Scope boundary delimiters (brackets and keywords)
  if
    ctx.delimiters_enabled
    and in_scope_range
    and (line_1based == scope.scope_start or line_1based == scope.scope_end)
  then
    local act_level = math.max(1, math.floor((active_col or width) / width))
    local r_idx = (act_level - 1) % ctx.rainbow_count + 1
    local delimiter_hl = ctx.delims_cfg.rainbow and ("IndentinatorDelimiter" .. r_idx)
      or (ctx.delims_cfg.hl or "IndentinatorDelimiter")

    if scope.delimiter_spans and #scope.delimiter_spans > 0 then
      for _, span in ipairs(scope.delimiter_spans) do
        if span.row == row then
          DELIM_OPTS.end_col = span.e_col
          DELIM_OPTS.hl_group = delimiter_hl
          DELIM_OPTS.priority = ctx.priority + 15
          set_extmark(buf, row, span.s_col, DELIM_OPTS)
        end
      end
    end
  end

  -- Indent and scope guide columns.
  --
  -- Passive guides are batched into a single extmark per line: each chunk is a
  -- run of guide characters plus the spaces between them, so a line with N
  -- guides costs one API call instead of N. The active scope guide keeps its
  -- own extmark so it retains the higher priority and its distinct
  -- character/highlight.
  if max_col >= width then
    local passive_chunks = nil
    local passive_win_col = nil
    local passive_prev_col = nil
    local passive_text = nil
    local passive_hl = nil
    local active_win_col, active_char, active_hl = nil, nil, nil

    for col = width, max_col, width do
      local win_col = col - ctx.leftcol
      if win_col >= 0 then
        local is_active = in_scope_range and active_col and (col == active_col)
        local char, hl, active_guide = nil, nil, false

        if is_active and ctx.scope_enabled then
          if not is_blank or ctx.scope_cfg.show_empty ~= false then
            char = ctx.scope_cfg.char or "│"
            local has_corners = ctx.scope_cfg.corners and scope.first_body_line and scope.last_body_line
            if has_corners and scope.first_body_line < scope.last_body_line then
              if line_1based == scope.first_body_line and ctx.scope_cfg.char_top and ctx.scope_cfg.char_top ~= "" then
                char = ctx.scope_cfg.char_top
              elseif
                line_1based == scope.last_body_line
                and ctx.scope_cfg.char_bottom
                and ctx.scope_cfg.char_bottom ~= ""
              then
                char = ctx.scope_cfg.char_bottom
              end
            end

            local level = math.max(1, math.floor(col / width))
            local r_idx = (level - 1) % ctx.rainbow_count + 1
            local rainbow_hl = "IndentinatorRainbow" .. r_idx

            hl = ctx.scope_cfg.rainbow and rainbow_hl or (ctx.scope_cfg.hl or "IndentinatorScope")
            active_guide = true
          end
        elseif ctx.indent_enabled then
          if not is_blank or ctx.indent_cfg.show_empty ~= false then
            char = ctx.indent_cfg.char or "│"
            if ctx.rainbow_enabled then
              local level = math.max(1, math.floor(col / width))
              local r_idx = (level - 1) % ctx.rainbow_count + 1
              hl = "IndentinatorRainbow" .. r_idx
            else
              hl = ctx.indent_cfg.hl or "IndentinatorIndent"
            end
          end
        end

        if char and hl then
          if active_guide then
            active_win_col, active_char, active_hl = win_col, char, hl
          else
            local gap = passive_prev_col and (col - passive_prev_col - 1) or 0
            if passive_text and passive_hl == hl then
              passive_text = passive_text .. string.rep(" ", gap) .. char
            else
              if passive_text then
                passive_chunks = passive_chunks or {}
                passive_chunks[#passive_chunks + 1] = { passive_text, passive_hl }
              end
              passive_win_col = passive_win_col or win_col
              passive_text = string.rep(" ", gap) .. char
              passive_hl = hl
            end
            passive_prev_col = col
          end
        end
      end
    end

    if passive_text then
      passive_chunks = passive_chunks or {}
      passive_chunks[#passive_chunks + 1] = { passive_text, passive_hl }
    end
    if passive_chunks and passive_win_col then
      EXTMARK_OPTS.virt_text = passive_chunks
      EXTMARK_OPTS.virt_text_win_col = passive_win_col
      EXTMARK_OPTS.priority = ctx.priority
      set_extmark(buf, row, 0, EXTMARK_OPTS)
    end
    if active_win_col then
      EXTMARK_OPTS.virt_text = get_virt_text(active_char, active_hl)
      EXTMARK_OPTS.virt_text_win_col = active_win_col
      EXTMARK_OPTS.priority = ctx.priority + 10
      set_extmark(buf, row, 0, EXTMARK_OPTS)
    end
  end
end

--- Renders indent and scope guides for the visible lines of a window.
--- Clears the previous viewport namespace first to avoid ghost marks.
---@param buf integer Buffer handle
---@param win integer Window handle
function M.render(buf, win)
  if not buf or not win or not nvim_buf_is_loaded(buf) or not nvim_win_is_valid(win) then
    return
  end

  if not config.is_enabled(buf) or not hooks.is_active(buf) then
    M.clear(buf)
    return
  end

  local cfg = config.get(buf)
  local total_lines = nvim_buf_line_count(buf)
  if total_lines > cfg.max_file_lines then
    -- Clear any marks left from when the buffer was within the threshold,
    -- otherwise guides remain as stale ghost marks after the file grows.
    M.clear(buf)
    return
  end

  -- Off-screen render: the target window does not display this buffer, so its
  -- per-window viewport bookkeeping cannot be trusted. Clear the whole
  -- namespace so earlier marks for this buffer cannot linger as ghosts.
  local ok_wb, win_buf = pcall(nvim_win_get_buf, win)
  if not ok_wb or win_buf ~= buf then
    pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
    cache.clear_rendered_buf(buf)
  end

  local ok_v, view = pcall(function()
    return api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
  end)
  if not ok_v or type(view) ~= "table" then
    return
  end

  local w0, w1 = view[1], view[2]
  if type(w0) ~= "number" or type(w1) ~= "number" or w1 < w0 or w0 <= 0 then
    return
  end

  local start_line = math.max(1, w0 - cfg.viewport_buffer)
  local end_line = math.min(total_lines, w1 + cfg.viewport_buffer)

  -- Clear the union of this window's previously painted range and the new one
  -- to guarantee zero ghost marks. Ranges are tracked per window because the
  -- same buffer can be visible in several windows at different offsets.
  local prev_start, prev_end = cache.get_rendered(win, buf)
  local clear_start = prev_start and math.min(prev_start, start_line) or start_line
  local clear_end = prev_end and math.max(prev_end, end_line) or end_line
  pcall(nvim_buf_clear_namespace, buf, M.NS, clear_start - 1, clear_end)
  cache.set_rendered(win, buf, start_line, end_line)

  local toprow = start_line - 1
  local botrow = end_line
  local ok_prep = M.prepare_win_context(win, buf, toprow, botrow, total_lines)
  if not ok_prep then
    return
  end

  for line = start_line, end_line do
    M.render_line(buf, win, line - 1)
  end
end

--- Renders scope guides for all windows displaying a buffer.
---@param buf integer Buffer handle
function M.render_all(buf)
  if not buf or not nvim_buf_is_loaded(buf) then
    return
  end
  for _, win in ipairs(nvim_list_wins()) do
    local ok, wb = pcall(nvim_win_get_buf, win)
    if ok and wb == buf then
      M.render(buf, win)
    end
  end
end

return M
