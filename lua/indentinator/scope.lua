local utils = require("indentinator.utils")

local M = {}

M.IGNORE_AST_TYPES = {
  string = true,
  string_content = true,
  string_literal = true,
  raw_string_literal = true,
  template_string = true,
  comment = true,
  line_comment = true,
  block_comment = true,
  doc_comment = true,
  regex = true,
}

M.ROOT_AST_TYPES = {
  translation_unit = true,
  program = true,
  source_file = true,
  chunk = true,
  module = true,
  script = true,
  document = true,
  compilation_unit = true,
}

M.BODY_CONTAINER_TYPES = {
  block = true,
  statement_block = true,
  compound_statement = true,
  body = true,
  class_body = true,
  interface_body = true,
  enum_body = true,
  body_statement = true,
  do_block = true,
  do_group = true,
  switch_block = true,
  block_statement = true,
  communication_case = true,
  table_constructor = true,
  dictionary = true,
  object = true,
  array = true,
}

--- Determines the start and end rows of the active block scope.
---@param buf number The buffer handle
---@param cursor_row number The cursor line (1-indexed)
---@param active_col number The active guide column index
---@param width number The indentation width
---@param tabstop number The tabstop size
---@return number|nil The start row (1-indexed), or nil
---@return number|nil The end row (1-indexed), or nil
function M.get_scope_range(buf, cursor_row, active_col, width, tabstop)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 or not active_col then return nil, nil end

  local limit = active_col + width
  local scope_start = cursor_row
  local scope_end = cursor_row

  -- If the cursor line is non-blank and its own indent equals active_col, it IS
  -- the scope-opener: no upward walk needed.
  local ok_cur, cur_lines = pcall(vim.api.nvim_buf_get_lines, buf, cursor_row - 1, cursor_row, false)
  local cursor_is_opener = false
  if ok_cur and cur_lines and cur_lines[1] then
    local cl = cur_lines[1]
    local cl_lead = cl:match("^%s*")
    if cl ~= "" and cl_lead ~= cl then
      cursor_is_opener = (utils.lead_display_width(cl_lead, tabstop) == active_col)
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
          local disp = utils.lead_display_width(lead, tabstop)
          if disp < limit then
            if not crossed_blank then
              if disp == active_col then
                scope_start = idx
              else
                scope_start = idx + 1
              end
            end
            stopped = true
            break
          end
          crossed_blank = false
        end
      end
      if stopped then break end
      scope_start = chunk_start
      current = chunk_start - 1
    end
  end

  -- Search downwards
  local current = cursor_row + 1
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
        local disp = utils.lead_display_width(lead, tabstop)
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

  -- Trim trailing blank lines from scope_end so highlight does not bleed
  if scope_end > scope_start then
    local pre_trim_end = scope_end
    local check_count = math.min(50, scope_end - scope_start)
    local check_start = scope_end - check_count + 1
    local ok_b, trim_lines = pcall(vim.api.nvim_buf_get_lines, buf, check_start - 1, scope_end, false)
    if ok_b and trim_lines and #trim_lines > 0 then
      for idx = #trim_lines, 1, -1 do
        local t = trim_lines[idx]
        if t == "" or t:match("^%s*$") then
          scope_end = scope_end - 1
        else
          break
        end
        if scope_end <= scope_start then break end
      end
    end
    if scope_end < cursor_row and cursor_row <= pre_trim_end then
      scope_end = cursor_row
    end
  end

  return scope_start, scope_end
end

--- Determines scope range and active guide column using Treesitter AST if available.
---@param buf number The buffer handle
---@param win number The window handle
---@param width number The default indentation width
---@param tabstop number The tabstop size
---@return number|nil scope_start (1-indexed)
---@return number|nil scope_end (1-indexed)
---@return number|nil active_col
function M.get_treesitter_scope_range(buf, win, _width, tabstop)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil, nil, nil
  end

  local ok_p, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_p or not parser then return nil, nil, nil end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local cursor_row = cursor[1] - 1
  local cursor_col = cursor[2]

  local node = nil
  if vim.treesitter.get_node then
    local ok_n, n = pcall(vim.treesitter.get_node, { buf = buf, pos = { cursor_row, cursor_col } })
    if ok_n then node = n end
  end

  if not node then
    local ok_tree, trees = pcall(function() return parser:parse() end)
    if ok_tree and trees and trees[1] then
      local root = trees[1]:root()
      if root then
        node = root:named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
      end
    end
  end

  if not node then return nil, nil, nil end

  -- Traverse upward through ancestor AST nodes to locate a multi-line scope container
  local scope_node = nil
  local curr = node
  while curr do
    local type_name = curr:type()
    if not M.IGNORE_AST_TYPES[type_name] then
      local s_row, _, e_row, _ = curr:range()
      if s_row < e_row then
        if not M.ROOT_AST_TYPES[type_name] then
          if M.BODY_CONTAINER_TYPES[type_name] then
            local parent = curr:parent()
            if parent then
              local p_type = parent:type()
              if not M.ROOT_AST_TYPES[p_type] and not M.IGNORE_AST_TYPES[p_type] then
                local p_s_row, _, p_e_row, _ = parent:range()
                if p_s_row < p_e_row then
                  scope_node = parent
                  break
                end
              end
            end
          end
          scope_node = curr
          break
        end
      end
    end
    curr = curr:parent()
  end

  if not scope_node then return nil, nil, nil end

  local start_row, _, end_row, _ = scope_node:range()
  local scope_start = start_row + 1
  local scope_end = end_row + 1

  -- Calculate active guide column from the indentation of the scope start line
  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_row, start_row + 1, false)
  local active_col = 0
  if ok_l and lines and lines[1] then
    local lead = lines[1]:match("^%s*")
    active_col = utils.lead_display_width(lead or "", tabstop)
  end

  return scope_start, scope_end, active_col, scope_node
end

--- Extracts delimiter byte ranges directly from Treesitter AST node children on target_row.
---@param scope_node userdata|nil Treesitter TSNode
---@param target_row number 0-indexed line row
---@param is_start boolean True for scope start line, false for scope end line
---@return table[] List of { s_col, e_col }
function M.get_treesitter_delimiters(scope_node, target_row, is_start)
  if not scope_node then return {} end
  local matches = {}
  local child_count = scope_node:child_count()

  local open_types = {
    ["{"] = true, ["("] = true, ["["] = true, [":"] = true,
    ["do"] = true, ["then"] = true, ["begin"] = true, ["function"] = true,
    ["fn"] = true, ["def"] = true, ["class"] = true, ["struct"] = true,
    ["if"] = true, ["elseif"] = true, ["else"] = true, ["for"] = true,
    ["while"] = true, ["repeat"] = true, ["until"] = true, ["switch"] = true,
    ["case"] = true, ["try"] = true, ["catch"] = true, ["except"] = true,
    ["finally"] = true, ["select"] = true,
  }

  local close_types = {
    ["}"] = true, [")"] = true, ["]"] = true,
    ["end"] = true, ["done"] = true, ["fi"] = true, ["esac"] = true,
  }

  local valid_types = is_start and open_types or close_types

  for i = 0, child_count - 1 do
    local child = scope_node:child(i)
    if child then
      local s_row, s_col, e_row, e_col = child:range()
      if s_row == target_row and e_row == target_row then
        local t = child:type()
        if valid_types[t] then
          table.insert(matches, { s_col, e_col })
        end
      end
    end
  end

  return matches
end

--- Sanitizes line text by masking string literals and stripping single-line comments.
---@param line_text string
---@return string Sanitized line text with strings replaced by spaces and comments stripped
local function sanitize_line(line_text)
  if not line_text then return "" end
  local clean = line_text:gsub("%-%-.*$", ""):gsub("//.*$", ""):gsub("#.*$", "")
  clean = clean:gsub('"[^"]*"', function(m) return string.rep(" ", #m) end)
  clean = clean:gsub("'[^']*'", function(m) return string.rep(" ", #m) end)
  return clean
end

--- Finds delimiter byte ranges (0-indexed col start/end) on line_text for scope start (is_start=true)
--- or scope end (is_start=false).
---@param line_text string
---@param is_start boolean
---@return table[] List of { s_col, e_col }
function M.find_delimiters(line_text, is_start)
  if not line_text or line_text == "" then return {} end
  local clean_text = sanitize_line(line_text)
  local matches = {}

  if is_start then
    local open_keywords = {
      "for", "while", "if", "elseif", "else", "repeat", "until", "do", "then",
      "begin", "function", "fn", "def", "class", "struct", "switch", "case",
      "select", "try", "catch", "except", "finally"
    }
    for _, kw in ipairs(open_keywords) do
      local s, e = clean_text:find("%f[%a]" .. kw .. "%f[%A]")
      if s and e then
        table.insert(matches, { s - 1, e })
      end
    end

    for col = 1, #clean_text do
      local char = clean_text:sub(col, col)
      if char == "{" or char == "[" then
        table.insert(matches, { col - 1, col })
      end
    end
  else
    local close_keywords = { "end", "done", "fi", "esac" }
    for _, kw in ipairs(close_keywords) do
      local s, e = clean_text:find("%f[%a]" .. kw .. "%f[%A]")
      if s and e then
        table.insert(matches, { s - 1, e })
      end
    end

    for col = 1, #clean_text do
      local char = clean_text:sub(col, col)
      if char == "}" or char == "]" then
        table.insert(matches, { col - 1, col })
      end
    end
  end

  return matches
end

return M
