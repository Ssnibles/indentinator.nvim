--- Scope resolution and delimiter extraction logic for indentinator.nvim.
--- Combines Treesitter AST analysis with pure indentation fallback algorithms.

local utils = require("indentinator.utils")

local api = vim.api
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_win_get_cursor = api.nvim_win_get_cursor
local nvim_buf_line_count = api.nvim_buf_line_count

local M = {}

--- AST node types that should be ignored during ancestor scope traversal
M.IGNORE_AST_TYPES = {
  string = true,
  string_content = true,
  string_literal = true,
  raw_string_literal = true,
  template_string = true,
  string_fragment = true,
  char_literal = true,
  character_literal = true,
  interpreted_string_literal = true,
  multiline_string = true,
  heredoc_body = true,
  heredoc_start = true,
  comment = true,
  line_comment = true,
  block_comment = true,
  doc_comment = true,
  comment_content = true,
  regex = true,
  regex_pattern = true,
  ternary_expression = true,
  conditional_expression = true,
  binary_expression = true,
  unary_expression = true,
  assignment_expression = true,
  assignment_statement = true,
  variable_declaration = true,
  local_declaration = true,
  expression_statement = true,
  return_statement = true,
  break_statement = true,
  goto_statement = true,
  declaration = true,
  field_declaration = true,
  lexical_declaration = true,
  variable_declarator = true,
  statement = true,
  simple_statement = true,
  clause = true,
  argument_list = true,
  parameter_list = true,
  arguments = true,
  parameters = true,
  tuple_expression = true,
  array_expression = true,
  vector_expression = true,
  macro_invocation = true,
  call_expression = true,
  member_expression = true,
  parenthesized_expression = true,
  field_expression = true,
  property_identifier = true,
  pair = true,
  property = true,
  binding = true,
}

--- AST root node types representing full files/units
M.ROOT_AST_TYPES = {
  translation_unit = true,
  program = true,
  source_file = true,
  chunk = true,
  module = true,
  script = true,
  document = true,
  compilation_unit = true,
  stylesheet = true,
  file = true,
  root = true,
}

--- AST container types representing distinct body blocks across languages
M.BODY_CONTAINER_TYPES = {
  block = true,
  statement_block = true,
  compound_statement = true,
  body = true,
  class_body = true,
  interface_body = true,
  enum_body = true,
  enum_body_declarations = true,
  body_statement = true,
  do_block = true,
  do_group = true,
  switch_block = true,
  switch_body = true,
  switch_section = true,
  block_statement = true,
  communication_case = true,
  expression_case = true,
  table_constructor = true,
  dictionary = true,
  object = true,
  array = true,
  list = true,
  tuple = true,
  set = true,
  declaration_list = true,
  field_declaration_list = true,
  enumerator_list = true,
  initializer_list = true,
  array_initializer = true,
  composite_literal = true,
  literal_value = true,
  match_block = true,
  match_arm = true,
  case_clause = true,
  case_item = true,
  elif_clause = true,
  elseif_clause = true,
  else_clause = true,
  except_clause = true,
  finally_clause = true,
  catch_clause = true,
  then_clause = true,
  subshell = true,
  rule_set = true,
  media_statement = true,
  keyframes_statement = true,
  element = true,
  script_element = true,
  style_element = true,
  template_element = true,
  block_mapping = true,
  block_sequence = true,
  container_decl = true,
  ui_object_definition = true,
  ui_object_initializer = true,
  object_definition = true,
  component = true,
}

--- AST clause container types
M.CLAUSE_CONTAINER_TYPES = {
  elif_clause = true,
  elseif_clause = true,
  else_clause = true,
  except_clause = true,
  finally_clause = true,
  catch_clause = true,
  case_clause = true,
  case_item = true,
  match_arm = true,
}

--- AST delimiter node types for scope openers
M.OPEN_DELIMITER_TYPES = {
  ["{"] = true, ["("] = true, ["["] = true, [":"] = true,
  [")"] = true, ["]"] = true, ["}"] = true,
  ["<"] = true, ["<?php"] = true, ["<?"] = true,
  ["do"] = true, ["then"] = true, ["begin"] = true, ["function"] = true,
  ["func"] = true, ["fn"] = true, ["fun"] = true, ["def"] = true, ["defp"] = true,
  ["defmodule"] = true, ["defmacro"] = true, ["defprotocol"] = true, ["defimpl"] = true,
  ["class"] = true, ["struct"] = true, ["enum"] = true, ["union"] = true,
  ["interface"] = true, ["trait"] = true, ["impl"] = true, ["module"] = true,
  ["namespace"] = true, ["package"] = true, ["type"] = true, ["import"] = true,
  ["export"] = true, ["default"] = true, ["static"] = true, ["constexpr"] = true,
  ["const"] = true, ["let"] = true, ["var"] = true,
  ["if"] = true, ["elseif"] = true, ["elif"] = true, ["elsif"] = true, ["else"] = true,
  ["for"] = true, ["foreach"] = true, ["while"] = true, ["repeat"] = true, ["until"] = true,
  ["loop"] = true, ["match"] = true, ["switch"] = true, ["case"] = true,
  ["select"] = true, ["try"] = true, ["catch"] = true, ["except"] = true,
  ["finally"] = true, ["rescue"] = true, ["ensure"] = true, ["unless"] = true,
  ["with"] = true, ["where"] = true, ["defer"] = true, ["go"] = true,
  ["pub"] = true, ["public"] = true, ["private"] = true, ["protected"] = true,
  ["async"] = true, ["unsafe"] = true, ["override"] = true,
  ["when"] = true, ["of"] = true, ["guard"] = true,
  ["proc"] = true, ["method"] = true, ["iterator"] = true, ["macro"] = true,
  ["template"] = true, ["concept"] = true, ["record"] = true, ["cond"] = true,
  ["receive"] = true, ["test"] = true, ["=>"] = true, ["->"] = true, [":="] = true,
  ["</"] = true, ["/>"] = true,
  ["function_keyword"] = true, ["def_keyword"] = true, ["class_keyword"] = true,
  ["if_keyword"] = true, ["for_keyword"] = true, ["while_keyword"] = true,
  ["try_keyword"] = true, ["catch_keyword"] = true, ["struct_keyword"] = true,
  ["enum_keyword"] = true, ["interface_keyword"] = true, ["trait_keyword"] = true,
  ["fn_keyword"] = true, ["type_keyword"] = true,
}

--- AST delimiter node types for scope closers
M.CLOSE_DELIMITER_TYPES = {
  ["}"] = true, [")"] = true, ["]"] = true, [">"] = true, ["?>"] = true,
  ["end"] = true, ["done"] = true, ["fi"] = true, ["esac"] = true,
  ["endfunction"] = true, ["endif"] = true, ["endfor"] = true, ["endforeach"] = true,
  ["endwhile"] = true, ["endswitch"] = true, ["enddeclare"] = true,
  ["rescue"] = true, ["ensure"] = true, ["catch"] = true, ["finally"] = true,
  ["except"] = true, ["else"] = true, ["elif"] = true, ["elseif"] = true,
  ["elsif"] = true, ["until"] = true, ["/>"] = true, ["</"] = true,
}

local OPEN_KEYWORDS = {
  "for", "foreach", "while", "if", "elseif", "elif", "elsif", "else", "repeat", "until",
  "do", "then", "begin", "function", "func", "fn", "fun", "def", "defp", "defmodule",
  "defmacro", "defprotocol", "defimpl", "class", "struct", "enum", "union", "interface",
  "trait", "impl", "module", "namespace", "package", "type", "switch", "case", "select",
  "try", "catch", "except", "finally", "rescue", "ensure", "unless", "with", "where",
  "loop", "match", "defer", "go", "pub", "public", "private", "protected", "static",
  "async", "unsafe", "override", "default", "when", "of", "guard", "proc", "method",
  "iterator", "macro", "template", "concept", "record", "cond", "receive", "test"
}

local CLOSE_KEYWORDS = {
  "end", "done", "fi", "esac", "rescue", "ensure", "until", "endif", "endfunction",
  "endfor", "endforeach", "endwhile", "endswitch", "enddeclare"
}

local OPEN_CHARS = { ["{"] = true, ["["] = true, ["("] = true, [")"] = true, ["]"] = true, ["}"] = true }
local CLOSE_CHARS = { ["}"] = true, ["]"] = true, [")"] = true }

--- Traverses upward from cursor row to find scope start row.
---@param buf integer Buffer handle
---@param cursor_row integer Cursor row (1-indexed)
---@param active_col integer Active guide column
---@param limit integer Active col limit threshold
---@param tabstop integer Tabstop width
---@return integer Scope start row (1-indexed)
local function search_scope_start(buf, cursor_row, active_col, limit, tabstop)
  local ok_cur, cur_lines = pcall(nvim_buf_get_lines, buf, cursor_row - 1, cursor_row, false)
  if ok_cur and cur_lines and cur_lines[1] then
    local cl = cur_lines[1]
    local cl_lead = cl:match("^%s*")
    if cl ~= "" and cl_lead ~= cl then
      if utils.lead_display_width(cl_lead, tabstop) == active_col then
        return cursor_row
      end
    end
  end

  local current = cursor_row - 1
  local scope_start = cursor_row
  local crossed_blank = false

  while current > 0 do
    local chunk_start = math.max(1, current - 50 + 1)
    local ok, lines = pcall(nvim_buf_get_lines, buf, chunk_start - 1, current, false)
    if not ok or #lines == 0 then
      break
    end

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
            scope_start = (disp == active_col) and idx or (idx + 1)
          end
          stopped = true
          break
        end
        crossed_blank = false
      end
    end
    if stopped then
      break
    end
    scope_start = chunk_start
    current = chunk_start - 1
  end

  return scope_start
end

--- Traverses downward from cursor row to find scope end row.
---@param buf integer Buffer handle
---@param cursor_row integer Cursor row (1-indexed)
---@param line_count integer Total line count in buffer
---@param limit integer Active col limit threshold
---@param tabstop integer Tabstop width
---@return integer Scope end row (1-indexed)
local function search_scope_end(buf, cursor_row, line_count, limit, tabstop)
  local current = cursor_row + 1
  local scope_end = cursor_row

  while current <= line_count do
    local chunk_end = math.min(line_count, current + 50 - 1)
    local ok, lines = pcall(nvim_buf_get_lines, buf, current - 1, chunk_end, false)
    if not ok or #lines == 0 then
      break
    end

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
    if stopped then
      break
    end
    scope_end = chunk_end
    current = chunk_end + 1
  end

  return scope_end
end

--- Trims trailing blank lines from scope end boundary.
---@param buf integer Buffer handle
---@param scope_start integer Scope start row (1-indexed)
---@param scope_end integer Scope end row (1-indexed)
---@param cursor_row integer Cursor row (1-indexed)
---@return integer Trimmed scope end row
local function trim_scope_end(buf, scope_start, scope_end, cursor_row)
  if scope_end <= scope_start then
    return scope_end
  end

  local pre_trim_end = scope_end
  local check_count = math.min(50, scope_end - scope_start)
  local check_start = scope_end - check_count + 1

  local ok_b, trim_lines = pcall(nvim_buf_get_lines, buf, check_start - 1, scope_end, false)
  if ok_b and trim_lines and #trim_lines > 0 then
    for idx = #trim_lines, 1, -1 do
      local t = trim_lines[idx]
      if t == "" or t:match("^%s*$") then
        scope_end = scope_end - 1
      else
        break
      end
      if scope_end <= scope_start then
        break
      end
    end
  end

  if scope_end < cursor_row and cursor_row <= pre_trim_end then
    scope_end = cursor_row
  end

  return scope_end
end

--- Determines start and end rows of active block scope using indentation analysis.
---@param buf integer Buffer handle
---@param cursor_row integer Cursor line row (1-indexed)
---@param active_col integer Active guide column index
---@param width integer Indentation width
---@param tabstop integer Tabstop size
---@return integer|nil scope_start (1-indexed)
---@return integer|nil scope_end (1-indexed)
function M.get_scope_range(buf, cursor_row, active_col, width, tabstop)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return nil, nil
  end

  local line_count = nvim_buf_line_count(buf)
  if line_count == 0 or not active_col then
    return nil, nil
  end

  cursor_row = math.min(math.max(1, cursor_row or 1), line_count)

  local limit = active_col + width
  local scope_start = search_scope_start(buf, cursor_row, active_col, limit, tabstop)
  local scope_end = search_scope_end(buf, cursor_row, line_count, limit, tabstop)
  scope_end = trim_scope_end(buf, scope_start, scope_end, cursor_row)

  return scope_start, scope_end
end

--- Resolves target Treesitter node at given cursor position.
---@param parser userdata Treesitter parser
---@param buf integer Buffer handle
---@param cursor_row integer 0-indexed row
---@param cursor_col integer 0-indexed col
---@return userdata|nil Treesitter node
local function resolve_ts_node(parser, buf, cursor_row, cursor_col)
  local node = nil

  -- Safely inspect injected language trees
  pcall(function()
    if parser.for_each_tree then
      parser:for_each_tree(function(tree, ltree)
        if tree and ltree then
          local root = tree:root()
          if root then
            local r_s, _, r_e, _ = root:range()
            if cursor_row >= r_s and cursor_row <= r_e then
              local n = root:named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
              if n then
                node = n
              end
            end
          end
        end
      end)
    end
  end)

  if not node and vim.treesitter.get_node then
    local ok_n, n = pcall(vim.treesitter.get_node, { bufnr = buf, buf = buf, pos = { cursor_row, cursor_col } })
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
          node = root:named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
        end)
      end
    end
  end

  return node
end

--- Determines scope range and active guide column using Treesitter AST.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param width integer Default indentation width
---@param tabstop integer Tabstop size
---@return integer|nil scope_start (1-indexed)
---@return integer|nil scope_end (1-indexed)
---@return integer|nil active_col
---@return userdata|nil scope_node
function M.get_treesitter_scope_range(buf, win, width, tabstop)
  if not buf or not win or not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then
    return nil, nil, nil, nil
  end

  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil, nil, nil, nil
  end

  local ok_p, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok_p or not parser then
    return nil, nil, nil, nil
  end

  pcall(function() parser:parse() end)

  local cursor = nvim_win_get_cursor(win)
  local cursor_row = cursor[1] - 1
  local cursor_col = cursor[2]

  local node = resolve_ts_node(parser, buf, cursor_row, cursor_col)
  if not node then
    return nil, nil, nil, nil
  end

  -- Traverse upward through ancestor nodes for multi-line scope container
  local scope_node = nil
  local curr = node
  while curr do
    local type_name = curr:type()
    if not M.IGNORE_AST_TYPES[type_name] then
      local s_row, _, e_row, _ = curr:range()
      if s_row < e_row and not M.ROOT_AST_TYPES[type_name] then
        scope_node = curr
        break
      end
    end
    curr = curr:parent()
  end

  if not scope_node then
    return nil, nil, nil, nil
  end

  local header_node = nil
  local parent_node = scope_node:parent()
  if parent_node then
    local p_type = parent_node:type()
    if not M.ROOT_AST_TYPES[p_type] and not M.IGNORE_AST_TYPES[p_type] then
      local p_s, _, p_e, _ = parent_node:range()
      if p_s < p_e then
        header_node = parent_node
      end
    end
  end

  local full_node = header_node or scope_node
  local start_row, _, end_row, _ = full_node:range()
  local scope_start = start_row + 1
  local scope_end = end_row + 1

  local active_col = 0
  local target_row = (header_node and header_node:range()) or start_row
  local ok_l, lines = pcall(nvim_buf_get_lines, buf, target_row, target_row + 1, false)
  if ok_l and lines and lines[1] then
    local lead = lines[1]:match("^%s*")
    local hdr_indent = utils.lead_display_width(lead or "", tabstop)
    active_col = math.max(0, hdr_indent - (width or 2))
  end

  return scope_start, scope_end, active_col, scope_node
end

--- Recursively collects leaf delimiter nodes matching valid_types on target_row.
---@param node userdata TSNode
---@param target_row integer 0-indexed line row
---@param valid_types table<string, boolean>
---@param matches integer[][] Array of { s_col, e_col }
---@param visited table<string, boolean>
local function collect_leaf_delimiters(node, target_row, valid_types, matches, visited)
  if not node then return end
  local ok_id, id = pcall(function() return node:id() end)
  id = (ok_id and tostring(id)) or tostring(node)
  if visited[id] then return end
  visited[id] = true

  local type_name = node:type()
  if M.IGNORE_AST_TYPES[type_name] then return end

  local s_row, s_col, e_row, e_col = node:range()
  if s_row > target_row or e_row < target_row then return end

  local child_count = node:child_count()
  if child_count == 0 then
    if s_row == target_row and e_row == target_row and valid_types[type_name] then
      table.insert(matches, { s_col, e_col })
    end
  else
    for i = 0, child_count - 1 do
      local child = node:child(i)
      if child then
        collect_leaf_delimiters(child, target_row, valid_types, matches, visited)
      end
    end
  end
end

--- Extracts delimiter byte ranges from Treesitter AST nodes on target_row.
---@param scope_node userdata|nil Treesitter TSNode
---@param target_row integer 0-indexed line row
---@param is_start boolean True for scope start line, false for end line
---@return integer[][] List of { s_col, e_col }
function M.get_treesitter_delimiters(scope_node, target_row, is_start)
  if not scope_node then
    return {}
  end

  local raw_matches = {}
  local valid_types = is_start and M.OPEN_DELIMITER_TYPES or M.CLOSE_DELIMITER_TYPES
  local visited = {}

  local curr_anc = scope_node
  while curr_anc do
    local a_s_row = curr_anc:range()
    if a_s_row == target_row then
      collect_leaf_delimiters(curr_anc, target_row, valid_types, raw_matches, visited)
      curr_anc = curr_anc:parent()
    else
      break
    end
  end

  local unique = {}
  local matches = {}
  for _, m in ipairs(raw_matches) do
    local key = m[1] .. ":" .. m[2]
    if not unique[key] then
      unique[key] = true
      table.insert(matches, m)
    end
  end
  table.sort(matches, function(a, b) return a[1] < b[1] end)

  return matches
end

--- Sanitizes line text by masking string literals and stripping comments.
---@param line_text string Raw line text
---@return string Sanitized line text
local function sanitize_line(line_text)
  if not line_text or line_text == "" then
    return ""
  end

  local clean = line_text:gsub('\\"', "  "):gsub("\\'", "  "):gsub("\\`", "  ")
  clean = clean:gsub('"[^"]*"', function(m) return string.rep(" ", #m) end)
  clean = clean:gsub("'[^']*'", function(m) return string.rep(" ", #m) end)
  clean = clean:gsub("`[^`]*`", function(m) return string.rep(" ", #m) end)
  clean = clean:gsub("%-%-.*$", ""):gsub("//.*$", ""):gsub("#.*$", "")
  clean = clean:gsub("/%*.-%*/", function(m) return string.rep(" ", #m) end)
  clean = clean:gsub("<!%-%-.-%-%->", function(m) return string.rep(" ", #m) end)

  return clean
end

--- Finds delimiter byte ranges on line_text using regex pattern matching.
---@param line_text string Raw line text
---@param is_start boolean True for start line, false for end line
---@return integer[][] List of { s_col, e_col }
function M.find_delimiters(line_text, is_start)
  if not line_text or line_text == "" then
    return {}
  end

  local clean_text = sanitize_line(line_text)
  local keywords = is_start and OPEN_KEYWORDS or CLOSE_KEYWORDS
  local char_map = is_start and OPEN_CHARS or CLOSE_CHARS
  local raw_matches = {}

  for _, kw in ipairs(keywords) do
    local init_pos = 1
    local pat = "%f[%w_]" .. kw .. "%f[%W]"
    while init_pos <= #clean_text do
      local s, e = clean_text:find(pat, init_pos)
      if not s then break end
      table.insert(raw_matches, { s - 1, e })
      init_pos = e + 1
    end
  end

  local len = #clean_text
  for col = 1, len do
    local char = clean_text:sub(col, col)
    if char_map[char] then
      table.insert(raw_matches, { col - 1, col })
    end
  end

  local unique = {}
  local matches = {}
  for _, m in ipairs(raw_matches) do
    local key = m[1] .. ":" .. m[2]
    if not unique[key] then
      unique[key] = true
      table.insert(matches, m)
    end
  end
  table.sort(matches, function(a, b) return a[1] < b[1] end)

  return matches
end

return M
