--- Scope resolution engine for indentinator.nvim.
--- Provides Treesitter AST scope analysis with pure indentation fallback algorithms.

local utils = require("indentinator.utils")

local api = vim.api
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_win_get_cursor = api.nvim_win_get_cursor
local nvim_buf_line_count = api.nvim_buf_line_count

local M = {}

--- Root AST node types that represent full document root level across languages
local ROOT_AST_TYPES = {
  translation_unit = true,
  program = true,
  source_file = true,
  chunk = true,
  module = true,
  script = true,
  document = true,
  compilation_unit = true,
  file = true,
  root = true,
}

--- Resolves scope boundaries using Treesitter AST traversal.
---@param buf integer Buffer handle
---@param win integer Window handle
---@return integer|nil scope_start 1-indexed row
---@return integer|nil scope_end 1-indexed row
---@return integer|nil active_col Indent column
function M.get_treesitter_scope(buf, win)
  if not buf or not win or not nvim_buf_is_valid(buf) or not nvim_win_is_valid(win) then
    return nil, nil, nil
  end

  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil, nil, nil
  end

  local ok_p, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_p or not parser then
    return nil, nil, nil
  end

  pcall(function() parser:parse() end)

  local cursor = nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]

  local node = nil
  if vim.treesitter.get_node then
    local ok_n, n = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
    if ok_n then
      node = n
    end
  end

  if not node then
    local ok_t, trees = pcall(function() return parser:trees() end)
    if ok_t and trees and trees[1] then
      local root = trees[1]:root()
      if root then
        pcall(function()
          node = root:named_descendant_for_range(row, col, row, col)
        end)
      end
    end
  end

  if not node then
    return nil, nil, nil
  end

  -- Traverse upward to find enclosing multi-line scope node
  local curr = node
  local scope_node = nil
  while curr do
    local type_name = curr:type()
    local s_row, _, e_row, _ = curr:range()
    local parent = curr:parent()

    -- Only consider multi-line nodes that are nested inside non-root parents
    if s_row < e_row and not ROOT_AST_TYPES[type_name] then
      if parent and not ROOT_AST_TYPES[parent:type()] then
        scope_node = curr
        break
      end
    end
    curr = parent
  end

  if not scope_node then
    return nil, nil, nil
  end

  -- Check if parent of scope_node (e.g. if_statement, function_declaration) extends to header construct
  local parent = scope_node:parent()
  if parent and not ROOT_AST_TYPES[parent:type()] then
    local p_s_row, _, p_e_row, _ = parent:range()
    if p_s_row < p_e_row then
      local grandparent = parent:parent()
      if grandparent and not ROOT_AST_TYPES[grandparent:type()] then
        scope_node = parent
      end
    end
  end

  local s_row, _, e_row, _ = scope_node:range()
  local scope_start = s_row + 1
  local scope_end = e_row + 1

  -- Calculate indentation column of scope start line
  local tabstop = utils.buffer_tabstop(buf)
  local active_col = 0
  local ok_l, lines = pcall(nvim_buf_get_lines, buf, s_row, s_row + 1, false)
  if ok_l and lines and lines[1] then
    local lead = lines[1]:match("^%s*") or ""
    active_col = utils.lead_display_width(lead, tabstop)
  end

  return scope_start, scope_end, active_col
end

--- Resolves scope boundaries using indentation level scanning.
---@param buf integer Buffer handle
---@param win integer Window handle
---@return integer|nil scope_start 1-indexed row
---@return integer|nil scope_end 1-indexed row
---@return integer|nil active_col Indent column
function M.get_indent_scope(buf, win)
  if not buf or not win or not nvim_buf_is_valid(buf) or not nvim_win_is_valid(win) then
    return nil, nil, nil
  end

  local line_count = nvim_buf_line_count(buf)
  if line_count == 0 then
    return nil, nil, nil
  end

  local cursor = nvim_win_get_cursor(win)
  local cursor_row = math.min(math.max(1, cursor[1]), line_count)

  local ok_l, lines = pcall(nvim_buf_get_lines, buf, cursor_row - 1, cursor_row, false)
  if not ok_l or not lines or not lines[1] then
    return nil, nil, nil
  end

  local text = lines[1]
  local lead = text:match("^%s*")
  local target_row = cursor_row

  -- If current line is blank, find nearest non-blank line
  if text == "" or lead == text then
    local up_text, up_lead, up_row = utils.find_non_blank_up(buf, cursor_row - 1)
    if up_text and up_lead then
      text = up_text
      lead = up_lead
      target_row = up_row
    else
      local down_text, down_lead, down_row = utils.find_non_blank_down(buf, cursor_row + 1, line_count)
      if down_text and down_lead then
        text = down_text
        lead = down_lead
        target_row = down_row
      end
    end
  end

  if text == "" or lead == text then
    return nil, nil, nil
  end

  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)
  local display_col = utils.lead_display_width(lead, tabstop)
  local aligned = math.floor(display_col / width) * width

  -- Determine active column based on block header vs inner body
  local next_aligned = nil
  local next_text, next_lead = utils.find_non_blank_down(buf, target_row + 1, line_count)
  if next_text and next_lead then
    local next_disp = utils.lead_display_width(next_lead, tabstop)
    next_aligned = math.floor(next_disp / width) * width
  end

  local active_col = aligned
  if not (next_aligned and next_aligned > aligned) then
    active_col = math.max(0, aligned - width)
  end

  local limit = active_col + width

  -- Scan upward for scope start
  local scope_start = target_row
  local curr_up = target_row - 1
  while curr_up > 0 do
    local ok_u, u_lines = pcall(nvim_buf_get_lines, buf, curr_up - 1, curr_up, false)
    if not ok_u or not u_lines or not u_lines[1] then break end
    local u_text = u_lines[1]
    local u_lead = u_text:match("^%s*")
    if u_text ~= "" and u_lead ~= u_text then
      local u_disp = utils.lead_display_width(u_lead, tabstop)
      if u_disp < limit then
        scope_start = (u_disp == active_col) and curr_up or (curr_up + 1)
        break
      end
    end
    scope_start = curr_up
    curr_up = curr_up - 1
  end

  -- Scan downward for scope end
  local scope_end = target_row
  local curr_down = target_row + 1
  while curr_down <= line_count do
    local ok_d, d_lines = pcall(nvim_buf_get_lines, buf, curr_down - 1, curr_down, false)
    if not ok_d or not d_lines or not d_lines[1] then break end
    local d_text = d_lines[1]
    local d_lead = d_text:match("^%s*")
    if d_text ~= "" and d_lead ~= d_text then
      local d_disp = utils.lead_display_width(d_lead, tabstop)
      if d_disp < limit then
        scope_end = (d_disp == active_col) and curr_down or (curr_down - 1)
        break
      end
    end
    scope_end = curr_down
    curr_down = curr_down + 1
  end

  -- Trim trailing blank lines from scope end
  while scope_end > scope_start do
    local ok_t, t_lines = pcall(nvim_buf_get_lines, buf, scope_end - 1, scope_end, false)
    if ok_t and t_lines and t_lines[1] and t_lines[1]:match("^%s*$") then
      scope_end = scope_end - 1
    else
      break
    end
  end

  return scope_start, scope_end, active_col
end

--- Primary scope resolution dispatcher.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param use_treesitter boolean Whether Treesitter scope is enabled
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
function M.get_scope(buf, win, use_treesitter)
  local start_row, end_row, active_col
  if use_treesitter ~= false then
    start_row, end_row, active_col = M.get_treesitter_scope(buf, win)
  end

  if not start_row or not end_row or not active_col then
    start_row, end_row, active_col = M.get_indent_scope(buf, win)
  end

  if start_row and end_row and active_col and active_col > 0 then
    return start_row, end_row, active_col
  end

  return nil, nil, nil
end

return M
