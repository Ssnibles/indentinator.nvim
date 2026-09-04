--- Extmark renderer module for indentinator.nvim.
--- Handles extmark drawing for standard indent guides, rainbow colors, scope corners,
--- and boundary highlights. Optimised for minimal allocations and linear viewport passes.

local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local scope = require("indentinator.scope")
local utils = require("indentinator.utils")

local api = vim.api
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_set_extmark = api.nvim_buf_set_extmark
local nvim_buf_clear_namespace = api.nvim_buf_clear_namespace
local nvim_list_wins = api.nvim_list_wins
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_buf_line_count = api.nvim_buf_line_count

local fn_foldclosed = vim.fn.foldclosed
local byte = string.byte

local M = {}

--- Extmark namespace handle for indentinator
M.NS = api.nvim_create_namespace("indentinator")

--- Byte lookup table for ASCII delimiter characters: {}()[]
local DELIM_BYTES = {}
DELIM_BYTES[byte("{")] = true
DELIM_BYTES[byte("}")] = true
DELIM_BYTES[byte("(")] = true
DELIM_BYTES[byte(")")] = true
DELIM_BYTES[byte("[")] = true
DELIM_BYTES[byte("]")] = true

--- Keyword lookup table for scope boundary tokens
local KEYWORD_SET = {
  ["if"] = true,
  ["then"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["elif"] = true,
  ["end"] = true,
  ["fi"] = true,
  ["done"] = true,
  ["esac"] = true,
  ["function"] = true,
  ["fn"] = true,
  ["fun"] = true,
  ["func"] = true,
  ["def"] = true,
  ["while"] = true,
  ["do"] = true,
  ["for"] = true,
  ["repeat"] = true,
  ["until"] = true,
  ["loop"] = true,
  ["switch"] = true,
  ["case"] = true,
  ["class"] = true,
  ["struct"] = true,
  ["interface"] = true,
  ["impl"] = true,
  ["trait"] = true,
  ["enum"] = true,
  ["try"] = true,
  ["catch"] = true,
  ["except"] = true,
  ["finally"] = true,
  ["with"] = true,
  ["begin"] = true,
  ["rescue"] = true,
  ["ensure"] = true,
  ["unless"] = true,
  ["select"] = true,
  ["where"] = true,
  ["match"] = true,
}

--- Initialises default highlight groups for standard indent, scope, and rainbow guides.
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

--- Clears all extmarks for a buffer.
---@param buf integer Buffer handle
function M.clear(buf)
  if buf and nvim_buf_is_valid(buf) then
    pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
    if state.rendered then
      state.rendered[buf] = nil
    end
  end
end

--- Checks if a character column is within a comment or string node in Treesitter.
---@param scope_node table|nil
---@param line_idx integer 0-indexed row
---@param col integer 0-indexed byte column
---@return boolean
local function is_comment_or_string(scope_node, line_idx, col)
  if not scope_node then
    return false
  end
  local ok, desc = pcall(function()
    return scope_node:descendant_for_range(line_idx, col, line_idx, col + 1)
  end)
  if ok and desc then
    local t = desc:type()
    if t:find("comment") or t:find("string") then
      return true
    end
    local parent = desc:parent()
    if parent then
      local pt = parent:type()
      if pt:find("comment") or pt:find("string") then
        return true
      end
    end
  end
  return false
end

--- Recursively collects Treesitter AST keyword node column spans on line_idx.
---@param node table TSNode
---@param line_idx integer 0-indexed row
---@param bufnr integer Buffer handle
---@param spans table Array of { s_col, e_col }
local function collect_ts_keyword_spans(node, line_idx, bufnr, spans)
  if not node then return end
  local s_row, s_col, e_row, e_col = node:range()
  if s_row > line_idx or e_row < line_idx then
    return
  end

  local t_name = node:type()
  if t_name:find("comment") or t_name:find("string") then
    return
  end

  if s_row == line_idx and e_row == line_idx then
    local ok_txt, txt = pcall(vim.treesitter.get_node_text, node, bufnr)
    if ok_txt and txt and txt:match("^[%a_][%w_]*$") then
      if KEYWORD_SET[txt] or KEYWORD_SET[t_name] then
        spans[#spans + 1] = { s_col, e_col }
        return
      end
    end
  end

  local child_count = node:child_count()
  for i = 0, child_count - 1 do
    local child = node:child(i)
    collect_ts_keyword_spans(child, line_idx, bufnr, spans)
  end
end

--- Renders delimiter extmarks (brackets and keywords) for a scope boundary line.
---@param buf integer Buffer handle
---@param line_idx integer 0-indexed line index
---@param text string Line text content
---@param scope_node table|nil TSNode for the scope
---@param delimiter_hl string Highlight group for delimiters
---@param delims_cfg table Delimiters configuration
---@param priority integer Base extmark priority
local function render_delimiters(buf, line_idx, text, scope_node, delimiter_hl, delims_cfg, priority)
  local delim_min_col = 0
  local delim_max_col = #text - 1
  if scope_node then
    local sn_s_row, sn_s_col, sn_e_row, sn_e_col = scope_node:range()
    if line_idx == sn_s_row then
      delim_min_col = sn_s_col
    end
    if line_idx == sn_e_row then
      delim_max_col = sn_e_col - 1
    end
  end

  -- Scan for bracket delimiters using byte lookup table
  for i = 1, #text do
    local c_idx = i - 1
    if c_idx >= delim_min_col and c_idx <= delim_max_col then
      if DELIM_BYTES[byte(text, i)] then
        if not is_comment_or_string(scope_node, line_idx, c_idx) then
          pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, c_idx, {
            end_col = i,
            hl_group = delimiter_hl,
            priority = priority + 15,
          })
        end
      end
    end
  end

  -- Highlight Treesitter keyword spans
  if delims_cfg.keywords ~= false and scope_node then
    local spans = {}
    collect_ts_keyword_spans(scope_node, line_idx, buf, spans)

    for _, span in ipairs(spans) do
      if span[1] >= delim_min_col and span[2] - 1 <= delim_max_col then
        pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, span[1], {
          end_col = span[2],
          hl_group = delimiter_hl,
          priority = priority + 15,
        })
      end
    end
  end
end

--- Efficiently finds the first and last inner scope body lines.
--- Performs short boundary scans instead of iterating entire scopes.
---@param buf integer
---@param scope_start integer
---@param scope_end integer
---@param active_col integer
---@param tabstop integer
---@param all_lines table
---@param start_line integer
---@param end_line integer
---@return integer|nil first_scope_line
---@return integer|nil last_scope_line
local function find_first_last_scope_lines(buf, scope_start, scope_end, active_col, tabstop, all_lines, start_line, end_line)
  if scope_start >= scope_end then
    return nil, nil
  end

  local function get_line_width(line_num)
    local batch_idx = line_num - start_line + 1
    local line_text
    if batch_idx >= 1 and batch_idx <= #all_lines then
      line_text = all_lines[batch_idx]
    else
      local ok_l, fetched = pcall(nvim_buf_get_lines, buf, line_num - 1, line_num, false)
      if ok_l and fetched and fetched[1] then
        line_text = fetched[1]
      end
    end

    if not line_text then
      return nil
    end

    local lead = line_text:match("^%s*") or ""
    local is_blank = (line_text == "" or #lead == #line_text)
    return is_blank and 9999 or utils.lead_display_width(lead, tabstop)
  end

  -- Search downward from scope_start + 1 for first body line
  local first_scope_line = nil
  local scan_limit_down = math.min(scope_end, scope_start + 30)
  for l = scope_start + 1, scan_limit_down do
    local lw = get_line_width(l)
    if lw and active_col < lw then
      first_scope_line = l
      break
    end
  end

  -- Search upward from scope_end - 1 down to scope_start + 1 for last body line
  local last_scope_line = nil
  local scan_limit_up = math.max(scope_start + 1, scope_end - 30)
  -- Also check scope_end itself if it's an unclosed block body
  local lw_end = get_line_width(scope_end)
  if lw_end and active_col < lw_end then
    last_scope_line = scope_end
  else
    for l = scope_end - 1, scan_limit_up, -1 do
      local lw = get_line_width(l)
      if lw and active_col < lw then
        last_scope_line = l
        break
      end
    end
  end

  return first_scope_line, last_scope_line
end

--- Computes visual indent widths for all lines in the viewport batch.
--- Resolves blank lines with single-pass lookups avoiding repeated buffer RPCs.
---@param buf integer
---@param all_lines table Array of string lines in viewport
---@param start_line integer 1-indexed first line of batch
---@param total_lines integer Total line count in buffer
---@param tabstop integer
---@return integer[] target_widths Array of target display widths
local function compute_batch_widths(buf, all_lines, start_line, total_lines, tabstop)
  local n = #all_lines
  local widths = {}
  local is_blank_flags = {}

  for i = 1, n do
    local text = all_lines[i]
    local lead = text:match("^%s*") or ""
    local is_b = (text == "" or #lead == #text)
    is_blank_flags[i] = is_b
    if not is_b then
      widths[i] = utils.lead_display_width(lead, tabstop)
    end
  end

  -- Fill in blank lines by inspecting nearest non-blank neighbours
  local i = 1
  while i <= n do
    if is_blank_flags[i] then
      local run_start = i
      while i <= n and is_blank_flags[i] do
        i = i + 1
      end
      local run_end = i - 1

      -- Find preceding non-blank width
      local up_w = 0
      if run_start > 1 then
        up_w = widths[run_start - 1]
      else
        local _, up_lead = utils.find_non_blank_up(buf, start_line - 1, 100)
        up_w = up_lead and utils.lead_display_width(up_lead, tabstop) or 0
      end

      -- Find following non-blank width
      local down_w = 0
      if run_end < n then
        down_w = widths[run_end + 1]
      else
        local _, down_lead = utils.find_non_blank_down(buf, start_line + run_end, total_lines, 100)
        down_w = down_lead and utils.lead_display_width(down_lead, tabstop) or 0
      end

      local target = math.min(up_w, down_w)
      for k = run_start, run_end do
        widths[k] = target
      end
    else
      i = i + 1
    end
  end

  return widths, is_blank_flags
end

--- Renders indent and scope guides for visible lines in a window.
---@param buf integer Buffer handle
---@param win integer Window handle
function M.render(buf, win)
  if not buf or not win or not nvim_buf_is_loaded(buf) or not nvim_win_is_valid(win) then
    return
  end

  if not config.is_enabled(buf, state.enabled[buf]) then
    M.clear(buf)
    return
  end

  local total_lines = nvim_buf_line_count(buf)
  local max_lines = config.values.max_file_lines or 10000
  if total_lines > max_lines then
    return
  end

  local ok_v, view = pcall(function()
    return api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$"), vim.fn.winsaveview().leftcol }
    end)
  end)
  if not ok_v or type(view) ~= "table" then
    return
  end

  local w0, w1 = view[1], view[2]
  local leftcol = (type(view[3]) == "number" and view[3] >= 0) and view[3] or 0

  if type(w0) ~= "number" or type(w1) ~= "number" or w1 < w0 or w0 <= 0 then
    return
  end

  local indent_cfg = config.values.indent or {}
  local scope_cfg = config.values.scope or {}
  local rainbow_cfg = indent_cfg.rainbow or {}

  local indent_enabled = indent_cfg.enabled ~= false
  local scope_enabled = scope_cfg.enabled ~= false
  local rainbow_enabled = rainbow_cfg.enabled == true
    and type(rainbow_cfg.colors) == "table"
    and #rainbow_cfg.colors > 0

  if not indent_enabled and not scope_enabled then
    return
  end

  local priority = config.values.priority or 1
  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)

  local start_line = math.max(1, w0)
  local end_line = math.min(total_lines, w1)

  -- Clear previous and current viewport ranges to avoid ghost marks when scrolling
  local prev = state.rendered and state.rendered[buf] or nil
  local clear_start = prev and math.min(prev[1], start_line) or start_line
  local clear_end = prev and math.max(prev[2], end_line) or end_line
  pcall(nvim_buf_clear_namespace, buf, M.NS, clear_start - 1, clear_end)
  state.rendered = state.rendered or {}
  state.rendered[buf] = { start_line, end_line }

  -- Batch-fetch all visible lines
  local ok_lines, all_lines = pcall(nvim_buf_get_lines, buf, start_line - 1, end_line, false)
  if not ok_lines or not all_lines or #all_lines == 0 then
    return
  end

  -- Resolve active scope boundaries
  local scope_start, scope_end, active_col, scope_node
  if scope_enabled then
    scope_start, scope_end, active_col, scope_node = scope.get_scope(buf, win, scope_cfg.treesitter)
  end

  -- Pre-compute first/last scope body lines for corner rendering
  local first_scope_line, last_scope_line
  if scope_enabled and scope_start and scope_end and scope_start < scope_end then
    first_scope_line, last_scope_line = find_first_last_scope_lines(
      buf, scope_start, scope_end, active_col, tabstop, all_lines, start_line, end_line
    )
  end

  local delims_cfg = config.values.delimiters or {}
  local delimiters_enabled = scope_enabled and delims_cfg.enabled ~= false

  local rainbow_colors = (rainbow_cfg and rainbow_cfg.colors) or config.defaults.indent.rainbow.colors
  local rainbow_count = #rainbow_colors

  -- Pre-compute indent display widths for batch
  local target_widths, is_blank_flags = compute_batch_widths(buf, all_lines, start_line, total_lines, tabstop)

  for i = 1, #all_lines do
    local line = start_line + i - 1
    local line_idx = line - 1

    -- Skip lines inside closed folds
    local fold_start = fn_foldclosed(line)
    if fold_start ~= -1 and fold_start ~= line then
      goto continue
    end

    local text = all_lines[i]
    local is_blank = is_blank_flags[i]
    local target_width = target_widths[i]

    local in_scope_range = scope_start and scope_end and (line >= scope_start and line <= scope_end)
    local max_col = target_width - (is_blank and 0 or width)

    -- Scope header line highlight
    if scope_enabled and in_scope_range and line == scope_start and scope_cfg.hl_header then
      pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
        line_hl_group = scope_cfg.hl_header,
        priority = priority - 1,
      })
    end

    -- Scope boundary delimiter rendering (brackets and keywords)
    if delimiters_enabled and in_scope_range and (line == scope_start or line == scope_end) then
      local act_level = math.max(1, math.floor((active_col or width) / width))
      local r_idx = (act_level - 1) % rainbow_count + 1
      local delimiter_hl = delims_cfg.rainbow and ("IndentinatorDelimiter" .. r_idx)
        or (delims_cfg.hl or "IndentinatorDelimiter")

      render_delimiters(buf, line_idx, text, scope_node, delimiter_hl, delims_cfg, priority)
    end

    -- Indent and scope guide columns
    if max_col >= width then
      for col = width, max_col, width do
        local win_col = col - leftcol
        if win_col >= 0 then
          local is_active = in_scope_range and active_col and (col == active_col)
          local char, hl

          if is_active and scope_enabled then
            if not is_blank or scope_cfg.show_empty ~= false then
              char = scope_cfg.char or "│"
              local has_corners = scope_cfg.corners and first_scope_line and last_scope_line
              if has_corners and first_scope_line < last_scope_line then
                if line == first_scope_line and scope_cfg.char_top and scope_cfg.char_top ~= "" then
                  char = scope_cfg.char_top
                elseif line == last_scope_line
                    and scope_cfg.char_bottom and scope_cfg.char_bottom ~= "" then
                  char = scope_cfg.char_bottom
                end
              end

              local level = math.max(1, math.floor(col / width))
              local r_idx = (level - 1) % rainbow_count + 1
              local rainbow_hl = "IndentinatorRainbow" .. r_idx

              hl = scope_cfg.rainbow and rainbow_hl or (scope_cfg.hl or "IndentinatorScope")
            end
          elseif indent_enabled then
            if not is_blank or indent_cfg.show_empty ~= false then
              char = indent_cfg.char or "│"
              if rainbow_enabled then
                local level = math.max(1, math.floor(col / width))
                local r_idx = (level - 1) % #rainbow_cfg.colors + 1
                hl = "IndentinatorRainbow" .. r_idx
              else
                hl = indent_cfg.hl or "IndentinatorIndent"
              end
            end
          end

          if char and hl then
            pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
              virt_text = { { char, hl } },
              virt_text_win_col = win_col,
              hl_mode = "combine",
              priority = is_active and (priority + 10) or priority,
            })
          end
        end
      end
    end

    ::continue::
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
