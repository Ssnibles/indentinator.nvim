--- Scope resolution engine for indentinator.nvim.
--- Provides Treesitter AST scope analysis with indentation fallback algorithms.

local utils = require("indentinator.utils")
local state_mod = require("indentinator.state")

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

--- Block/body container types that should promote to their parent construct
local BLOCK_TYPES = {
  block = true,
  statement_block = true,
  compound_statement = true,
  body = true,
  statement_list = true,
  consequence = true,
  alternative = true,
  declaration_list = true,
  field_declaration_list = true,
  class_body = true,
  switch_body = true,
  switch_block = true,
}

--- Closing delimiter patterns for indentation-based language scope boundaries
local CLOSING_DELIM_PATTERN = "^%s*([%}%)%]%w]+)"
local CLOSING_DELIM_WORDS = {
  ["}"] = true,
  [")"] = true,
  ["]"] = true,
  ["end"] = true,
  ["done"] = true,
  ["fi"] = true,
  ["esac"] = true,
  ["else"] = true,
  ["elif"] = true,
  ["elseif"] = true,
  ["except"] = true,
  ["finally"] = true,
  ["until"] = true,
  ["catch"] = true,
}

--- Checks if a line text starts with a known closing delimiter.
---@param text string
---@return boolean
local function is_closing_delimiter(text)
  local m = text:match(CLOSING_DELIM_PATTERN)
  if not m then
    return false
  end
  return CLOSING_DELIM_WORDS[m] == true
end

--- Promotes a body/block container node to its enclosing construct if appropriate.
---@param node table TSNode
---@return table TSNode
local function promote_block_node(node)
  if BLOCK_TYPES[node:type()] then
    local parent = node:parent()
    if parent and not ROOT_AST_TYPES[parent:type()] then
      local p_s_row, _, p_e_row, _ = parent:range()
      if p_s_row < p_e_row then
        return parent
      end
    end
  end
  return node
end

--- Resolves scope boundaries using Treesitter AST traversal.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param start_node table|nil Optional starting node for parent lookup
---@return integer|nil scope_start 1-indexed row
---@return integer|nil scope_end 1-indexed row
---@return integer|nil active_col Indent column
---@return table|nil scope_node TSNode
function M.get_treesitter_scope(buf, win, start_node)
  if not buf or not win or not nvim_buf_is_valid(buf) or not nvim_win_is_valid(win) then
    return nil, nil, nil, nil
  end

  local ok_p, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_p or not parser then
    return nil, nil, nil, nil
  end

  pcall(function() parser:parse() end)

  local node = start_node
  if not node then
    local cursor = nvim_win_get_cursor(win)
    local row = cursor[1] - 1
    local col = cursor[2]

    local ok_n, n = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
    node = ok_n and n or nil

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
  end

  if not node then
    return nil, nil, nil, nil
  end

  -- Traverse upward to find enclosing multi-line scope node (skipping comments & strings)
  local curr = node
  local scope_node = nil
  while curr do
    local type_name = curr:type()
    local s_row, _, e_row, _ = curr:range()

    local is_comment_or_str = type_name:find("comment") or type_name:find("string")
    if s_row < e_row and not ROOT_AST_TYPES[type_name] and not is_comment_or_str then
      scope_node = curr
      break
    end
    curr = curr:parent()
  end

  if not scope_node then
    return nil, nil, nil, nil
  end

  -- Promote block container to parent construct
  scope_node = promote_block_node(scope_node)

  local s_row, _, e_row, _ = scope_node:range()

  -- In Lua, else_statement child of if_statement ends at last statement;
  -- extend to the parent's 'end' keyword line if available
  if scope_node:type() == "else_statement" then
    local p = scope_node:parent()
    if p and p:type() == "if_statement" then
      local _, _, p_e_row, _ = p:range()
      if p_e_row > e_row then
        e_row = p_e_row
      end
    end
  end

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

  return scope_start, scope_end, active_col, scope_node
end

--- Resolves scope boundaries using indentation level scanning.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param custom_row integer|nil Optional target row override
---@return integer|nil scope_start 1-indexed row
---@return integer|nil scope_end 1-indexed row
---@return integer|nil active_col Indent column
function M.get_indent_scope(buf, win, custom_row)
  if not buf or not win or not nvim_buf_is_valid(buf) or not nvim_win_is_valid(win) then
    return nil, nil, nil
  end

  local line_count = nvim_buf_line_count(buf)
  if line_count == 0 then
    return nil, nil, nil
  end

  local target_row
  if custom_row then
    target_row = math.min(math.max(1, custom_row), line_count)
  else
    local cursor = nvim_win_get_cursor(win)
    target_row = math.min(math.max(1, cursor[1]), line_count)
  end

  local ok_l, lines = pcall(nvim_buf_get_lines, buf, target_row - 1, target_row, false)
  if not ok_l or not lines or not lines[1] then
    return nil, nil, nil
  end

  local text = lines[1]
  local lead = text:match("^%s*")

  -- If target line is blank, find nearest non-blank line
  if text == "" or lead == text then
    local up_text, up_lead, up_row = utils.find_non_blank_up(buf, target_row - 1)
    if up_text and up_lead then
      text = up_text
      lead = up_lead
      target_row = up_row
    else
      local down_text, down_lead, down_row = utils.find_non_blank_down(buf, target_row + 1, line_count)
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
        -- Only include line at active_col if it's a closing delimiter
        if d_disp == active_col and is_closing_delimiter(d_text) then
          scope_end = curr_down
        else
          scope_end = curr_down - 1
        end
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

  return scope_start, scope_end, active_col, nil
end

--- Resolves the parent (enclosing) scope of the active scope.
--- Used for upward motion navigation when already at a scope boundary.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param current_scope_start integer Current scope start row
---@param current_node table|nil Current TSNode
---@param use_treesitter boolean
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
function M.get_parent_scope(buf, win, current_scope_start, current_node, use_treesitter)
  if use_treesitter ~= false and current_node then
    local parent = current_node:parent()
    if parent then
      local p_start, p_end, p_col, p_node = M.get_treesitter_scope(buf, win, parent)
      if p_start and p_end and p_start < current_scope_start then
        return p_start, p_end, p_col, p_node
      end
    end
  end

  -- Indentation-based parent lookup: scan above current_scope_start for outer indent
  local tabstop = utils.buffer_tabstop(buf)
  local curr_start_lead = ""
  local ok_l, lines = pcall(nvim_buf_get_lines, buf, current_scope_start - 1, current_scope_start, false)
  if ok_l and lines and lines[1] then
    curr_start_lead = lines[1]:match("^%s*") or ""
  end
  local curr_start_col = utils.lead_display_width(curr_start_lead, tabstop)

  local scan_row = current_scope_start - 1
  while scan_row > 0 do
    local text, lead, row = utils.find_non_blank_up(buf, scan_row, 500)
    if not text or not row then break end
    local disp = utils.lead_display_width(lead, tabstop)
    if disp < curr_start_col or (curr_start_col == 0 and row < current_scope_start) then
      return M.get_indent_scope(buf, win, row)
    end
    scan_row = row - 1
  end

  return nil, nil, nil
end

--- Primary scope resolution dispatcher with memoization caching.
--- Cache is invalidated per buffer changedtick to avoid memory leaks.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param use_treesitter boolean Whether Treesitter scope is enabled
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
---@return table|nil scope_node
function M.get_scope(buf, win, use_treesitter)
  if not buf or not win or not nvim_buf_is_valid(buf) or not nvim_win_is_valid(win) then
    return nil, nil, nil, nil
  end

  local ok_c, cursor = pcall(nvim_win_get_cursor, win)
  if not ok_c or not cursor then
    return nil, nil, nil, nil
  end

  local cursor_row = cursor[1]
  local cursor_col = cursor[2]
  local tick = api.nvim_buf_get_changedtick(buf)
  local ts_flag = use_treesitter ~= false and 1 or 0

  -- Clear buffer cache on content changes to prevent unbounded memory growth
  local buf_cache = state_mod.state.cache[buf]
  if not buf_cache or buf_cache._tick ~= tick then
    buf_cache = { _tick = tick }
    state_mod.state.cache[buf] = buf_cache
  end

  local key = string.format("%d:%d:%d:%d", win, cursor_row, cursor_col, ts_flag)
  local cached = buf_cache[key]
  if cached ~= nil then
    if cached == false then
      return nil, nil, nil, nil
    end
    return cached[1], cached[2], cached[3], cached[4]
  end

  local start_row, end_row, active_col, scope_node
  if use_treesitter ~= false then
    start_row, end_row, active_col, scope_node = M.get_treesitter_scope(buf, win)
  end

  if not start_row or not end_row or not active_col then
    start_row, end_row, active_col, scope_node = M.get_indent_scope(buf, win)
  end

  if start_row and end_row and active_col and active_col >= 0 then
    buf_cache[key] = { start_row, end_row, active_col, scope_node }
    return start_row, end_row, active_col, scope_node
  end

  buf_cache[key] = false
  return nil, nil, nil, nil
end

return M
