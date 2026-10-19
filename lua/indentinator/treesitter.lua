--- Treesitter AST query engine and scope resolution module for indentinator.nvim.
--- Uses native Neovim 0.10+ treesitter APIs, data-driven per-language scope
--- allow-lists, range-limited queries, and intelligent indentation fallback.
---@class indentinator.treesitter
local M = {}

local utils = require("indentinator.utils")
local cache = require("indentinator.cache")
local config = require("indentinator.config")
local sl = require("indentinator.scope_languages")

local api = vim.api
local byte = string.byte

--- Finds the (possibly injected) language tree that contains a 0-indexed range.
--- Falls back to the given root tree when no injection matches.
---@param lang_tree vim.treesitter.LanguageTree
---@param s_row integer 0-indexed start row
---@param s_col integer 0-indexed start col
---@param e_row integer 0-indexed end row
---@param e_col integer 0-indexed end col
---@return vim.treesitter.LanguageTree
local function language_for_range(lang_tree, s_row, s_col, e_row, e_col)
  local range = { s_row, s_col, e_row, e_col }
  local ok_children, children = pcall(function()
    return lang_tree:children()
  end)
  if ok_children and children then
    for _, child in pairs(children) do
      local ok_contains, contains = pcall(function()
        return child:contains(range)
      end)
      if ok_contains and contains then
        return language_for_range(child, s_row, s_col, e_row, e_col)
      end
    end
  end
  return lang_tree
end

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

--- Closing delimiter patterns for indentation-based language scope boundaries
local CLOSING_DELIM_PATTERN = "^%s*([%}%)%]])"
local CLOSING_DELIM_WORD_PATTERN = "^%s*(%w+)"
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
  local m = text:match(CLOSING_DELIM_PATTERN) or text:match(CLOSING_DELIM_WORD_PATTERN)
  if not m then
    return false
  end
  return CLOSING_DELIM_WORDS[m] == true
end

--- Attaches buffer listener for incremental parser updates and cache invalidation.
---@param buf integer Buffer handle
function M.attach_buffer(buf)
  if not buf or not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return
  end
  if cache.is_attached(buf) then
    return
  end

  -- Only record the buffer as attached once `nvim_buf_attach` actually
  -- succeeds, otherwise a failed attach would permanently suppress retries.
  local ok = pcall(api.nvim_buf_attach, buf, false, {
    on_bytes = function(_, bufnr)
      cache.mark_dirty(bufnr)
    end,
    on_detach = function(_, bufnr)
      cache.clear_buf(bufnr)
    end,
  })
  if ok then
    cache.mark_attached(buf)
  end
end

--- Retrieves the Treesitter parser for a buffer.
--- Safely returns nil if Treesitter is unavailable or no parser is installed for filetype.
---@param buf integer Buffer handle
---@return vim.treesitter.LanguageTree|nil
function M.get_parser(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return nil
  end

  M.attach_buffer(buf)

  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser then
    return parser
  end
  return nil
end

--- True for comment/string node types, which never form scopes.
---@param t string Node type
---@return boolean
local function is_trivia_type(t)
  return t:find("comment") ~= nil or t:find("string") ~= nil
end

--- Checks whether an AST node is a valid compound structural scope.
--- Uses a per-language allow-list when available, otherwise a generic heuristic.
--- User-provided include/exclude node types always take precedence.
---@param node userdata|nil TSNode
---@param lang string|nil Treesitter language name
---@param cfg indentinator.Config|nil Resolved configuration
---@return boolean
local function is_valid_scope_node(node, lang, cfg)
  if not node then
    return false
  end
  local t = node:type()
  if sl.is_root(t) or sl.is_block(t) then
    return false
  end

  local scope_cfg = (cfg and cfg.scope) or {}
  local lang_override = scope_cfg.languages and lang and scope_cfg.languages[lang] or nil
  local include_set = cfg and cfg._scope_include_set
  local exclude_set = cfg and cfg._scope_exclude_set
  if include_set and include_set[t] then
    return true
  end
  if lang_override and lang_override._include_set and lang_override._include_set[t] then
    return true
  end
  if exclude_set and exclude_set[t] then
    return false
  end
  if lang_override and lang_override._exclude_set and lang_override._exclude_set[t] then
    return false
  end

  local allow = sl.get(lang)
  if allow then
    return allow[t] == true
  end

  -- Generic heuristic fallback for languages without an allow-list.
  if sl.excluded_types[t] or is_trivia_type(t) then
    return false
  end
  if t:find("^identifier") or t:find("_identifier") or t:find("literal") then
    return false
  end
  return true
end

--- Partitions multi-branch constructs (if / elseif / else, try / except / finally, match / case)
--- so that each branch has precise start and end boundaries without leaking into sibling branches.
---@param scope_node userdata TSNode
---@param row integer 0-indexed cursor row
---@return integer s_row
---@return integer s_col
---@return integer e_row
---@return integer e_col
local function get_branch_range(scope_node, row)
  local t = scope_node:type()
  local s_row, s_col, e_row, e_col = scope_node:range()

  if sl.is_branch_parent(t) then
    for i = 0, scope_node:child_count() - 1 do
      local child = scope_node:child(i)
      local ct = child:type()
      if sl.is_clause(ct) then
        local cs_r, cs_c = child:range()
        if row < cs_r then
          return s_row, s_col, cs_r, cs_c
        end
      end
    end
  elseif sl.is_clause(t) then
    local parent = scope_node:parent()
    if parent then
      local found_self = false
      for i = 0, parent:child_count() - 1 do
        local child = parent:child(i)
        if child == scope_node then
          found_self = true
        elseif found_self then
          local ct = child:type()
          if sl.is_clause(ct) or sl.is_closing(ct) then
            local cs_r, cs_c = child:range()
            return s_row, s_col, cs_r, cs_c
          end
        end
      end
      -- No following clause or closing token found (e.g. a malformed tree):
      -- stay within the clause's own range rather than swallowing the parent.
      return s_row, s_col, e_row, e_col
    end
  end

  return s_row, s_col, e_row, e_col
end

--- Collects child scope ranges from a node for fast cursor containment tests.
--- Uses node:iter_children() and scans block containers to detect nested scopes.
---@param node userdata TSNode
---@param lang string|nil Treesitter language name
---@param cfg indentinator.Config|nil Resolved configuration
---@return integer[][] child_ranges Array of { s_row, e_row }
local function collect_child_scope_ranges(node, lang, cfg)
  local ranges = {}
  local s_row, _, e_row, _ = node:range()

  local function scan_children(parent)
    for child in parent:iter_children() do
      if child:named() then
        local t = child:type()
        if not is_trivia_type(t) then
          if sl.is_block(t) then
            scan_children(child)
          else
            local cs_row, _, ce_row, _ = child:range()
            if cs_row < ce_row and is_valid_scope_node(child, lang, cfg) then
              if cs_row > s_row or ce_row < e_row then
                ranges[#ranges + 1] = { cs_row, ce_row }
              end
            else
              -- Recurse into non-scope statements/expressions to find embedded scopes (e.g. callbacks)
              scan_children(child)
            end
          end
        end
      end
    end
  end

  scan_children(node)
  return ranges
end

--- Checks if a character column is within a comment or string node in Treesitter.
---@param scope_node userdata|nil TSNode
---@param line_idx integer 0-indexed row
---@param col integer 0-indexed byte column
---@return boolean
local function is_comment_or_string(scope_node, line_idx, col)
  if not scope_node then
    return false
  end
  local ok, desc = pcall(scope_node.descendant_for_range, scope_node, line_idx, col, line_idx, col + 1)
  if ok and desc then
    if is_trivia_type(desc:type()) then
      return true
    end
    local parent = desc:parent()
    if parent and is_trivia_type(parent:type()) then
      return true
    end
  end
  return false
end

--- Resolves boundary delimiter tokens (brackets and keywords) using Treesitter query engine.
--- Restricts queries strictly to the boundary lines [s_row, s_row + 1] and [e_row, e_row + 1].
---@param buf integer Buffer handle
---@param scope_node userdata|nil
---@param s_row integer 0-indexed start row
---@param e_row integer 0-indexed end row
---@param keywords_enabled boolean
---@param lang_tree vim.treesitter.LanguageTree|nil Language tree for the scope (injection-aware)
---@return table[] delimiter_spans Array of { row, s_col, e_col }
function M.get_boundary_delimiters(buf, scope_node, s_row, e_row, keywords_enabled, lang_tree)
  local spans = {}
  local boundary_rows = { s_row, e_row }

  local delim_min_col = { [s_row] = 0, [e_row] = 0 }
  local delim_max_col = { [s_row] = 999999, [e_row] = 999999 }

  if scope_node then
    local sn_s_row, sn_s_col, sn_e_row, sn_e_col = scope_node:range()
    if s_row == sn_s_row then
      delim_min_col[s_row] = sn_s_col
    end
    if e_row == sn_e_row then
      delim_max_col[e_row] = sn_e_col - 1
    end
  end

  -- Attempt query-driven extraction using highlights query if available
  local parser = lang_tree
  if not parser then
    local ok_p, root_parser = pcall(vim.treesitter.get_parser, buf)
    parser = ok_p and root_parser or nil
  end
  local query = nil
  if parser then
    local ok_q, q = pcall(vim.treesitter.query.get, parser:lang(), "highlights")
    query = ok_q and q or nil
  end

  for _, row in ipairs(boundary_rows) do
    local ok_l, lines = pcall(api.nvim_buf_get_lines, buf, row, row + 1, false)
    local text = (ok_l and lines and lines[1]) or ""
    if text ~= "" then
      local min_c = delim_min_col[row] or 0
      local max_c = math.min(#text - 1, delim_max_col[row] or 999999)

      -- 1. Bracket delimiters scanning
      for i = 1, #text do
        local c_idx = i - 1
        if c_idx >= min_c and c_idx <= max_c then
          if DELIM_BYTES[byte(text, i)] then
            if not is_comment_or_string(scope_node, row, c_idx) then
              spans[#spans + 1] = { row = row, s_col = c_idx, e_col = i }
            end
          end
        end
      end

      -- 2. Keyword delimiters scanning
      if keywords_enabled and scope_node then
        if query and parser then
          local tree = parser:trees()[1]
          if tree then
            local root = tree:root()
            for id, q_node in query:iter_captures(root, buf, row, row + 1) do
              local cname = query.captures[id]
              if cname and cname:find("^keyword") then
                local ns_row, ns_col, _, ne_col = q_node:range()
                if ns_row == row and ns_col >= min_c and ne_col - 1 <= max_c then
                  local ok_t, txt = pcall(vim.treesitter.get_node_text, q_node, buf)
                  if ok_t and txt and (KEYWORD_SET[txt] or KEYWORD_SET[q_node:type()]) then
                    if not is_comment_or_string(scope_node, row, ns_col) then
                      spans[#spans + 1] = { row = row, s_col = ns_col, e_col = ne_col }
                    end
                  end
                end
              end
            end
          end
        else
          -- AST fallback for keywords
          local function collect_keywords(n)
            if not n then
              return
            end
            local nr_s, nc_s, nr_e, nc_e = n:range()
            if nr_s > row or nr_e < row then
              return
            end
            local t_name = n:type()
            if is_trivia_type(t_name) then
              return
            end

            if nr_s == row and nr_e == row then
              local ok_t, txt = pcall(vim.treesitter.get_node_text, n, buf)
              if ok_t and txt and txt:match("^[%a_][%w_]*$") then
                if KEYWORD_SET[txt] or KEYWORD_SET[t_name] then
                  if nc_s >= min_c and nc_e - 1 <= max_c then
                    spans[#spans + 1] = { row = row, s_col = nc_s, e_col = nc_e }
                    return
                  end
                end
              end
            end

            for i = 0, n:child_count() - 1 do
              collect_keywords(n:child(i))
            end
          end

          collect_keywords(scope_node)
        end
      end
    end
  end

  return spans
end

--- Finds the first and last inner scope body lines (the lines that corners
--- connect to). Fetches the scope body once and stops at the first matching
--- line from each end, so cost is proportional to the leading/trailing gap.
---@param buf integer Buffer handle
---@param scope_start integer 1-indexed row
---@param scope_end integer 1-indexed row
---@param active_col integer 0-indexed column
---@param tabstop integer Buffer tabstop
---@return integer|nil first_scope_line
---@return integer|nil last_scope_line
function M.find_first_last_scope_lines(buf, scope_start, scope_end, active_col, tabstop)
  if scope_start >= scope_end then
    return nil, nil
  end

  -- 0-indexed [scope_start, scope_end) == 1-indexed body lines [scope_start+1, scope_end].
  local ok, lines = pcall(api.nvim_buf_get_lines, buf, scope_start, scope_end, false)
  if not ok or not lines or #lines == 0 then
    return nil, nil
  end

  local first_scope_line, last_scope_line
  for i = 1, #lines do
    local text = lines[i]
    local lead = text:match("^%s*") or ""
    if text ~= "" and #lead ~= #text and utils.lead_display_width(lead, tabstop) > active_col then
      first_scope_line = scope_start + i
      break
    end
  end

  for i = #lines, 1, -1 do
    local text = lines[i]
    local lead = text:match("^%s*") or ""
    if text ~= "" and #lead ~= #text and utils.lead_display_width(lead, tabstop) > active_col then
      last_scope_line = scope_start + i
      break
    end
  end

  return first_scope_line, last_scope_line
end

--- Resolves scope boundaries using Treesitter AST traversal.
---@param buf integer Buffer handle
---@param _win integer Window handle (unused; resolution is cursor-based)
---@param cursor_row integer 1-indexed row
---@param cursor_col integer 0-indexed col
---@param start_node userdata|nil Optional starting node
---@return indentinator.ScopeInfo|nil
function M.resolve_treesitter_scope(buf, _win, cursor_row, cursor_col, start_node)
  local parser = M.get_parser(buf)
  if not parser then
    return nil
  end

  -- Parse only when the buffer changed or has no tree yet. `parse(true)` is a
  -- full parse that also runs injection queries, so it is deliberately deferred
  -- to edits rather than run on every cursor movement.
  if cache.is_dirty(buf) or #parser:trees() == 0 then
    pcall(function()
      parser:parse(true)
    end)
    cache.mark_clean(buf)
  end

  local cfg = config.get(buf)

  local row = cursor_row - 1
  local col = cursor_col
  local lang_tree = language_for_range(parser, row, col, row, col)
  local lang = lang_tree:lang()

  local node = start_node
  if not node then
    -- Normalize query column to eliminate cursor column bias
    local line_text = ""
    local ok_l, lines = pcall(api.nvim_buf_get_lines, buf, row, row + 1, false)
    if ok_l and lines and lines[1] then
      line_text = lines[1]
    end

    local lead = line_text:match("^%s*") or ""
    local first_non_blank = #lead

    -- If target line is blank, find nearest non-blank line upward
    local query_row = row
    local query_col = first_non_blank
    if line_text == "" or first_non_blank == #line_text then
      local up_text, up_lead, up_row = utils.find_non_blank_up(buf, row)
      if up_text and up_lead and up_row then
        query_row = up_row - 1
        query_col = #up_lead
      end
    end

    local ok_n, n =
      pcall(vim.treesitter.get_node, { bufnr = buf, pos = { query_row, query_col }, ignore_injections = false })
    node = ok_n and n or nil

    if not node then
      local ok_t, trees = pcall(function()
        return parser:trees()
      end)
      if ok_t and trees and trees[1] then
        local root = trees[1]:root()
        if root then
          pcall(function()
            node = root:named_descendant_for_range(query_row, query_col, query_row, query_col)
          end)
        end
      end
    end
  end

  if not node then
    return nil
  end

  -- Traverse upward to find enclosing multi-line scope node (skipping expressions, comments, strings)
  local curr = node
  local scope_node = nil
  while curr do
    local s_r, _, e_r, _ = curr:range()
    if s_r < e_r and is_valid_scope_node(curr, lang, cfg) then
      scope_node = curr
      break
    end
    curr = curr:parent()
  end

  if not scope_node then
    return nil
  end

  -- Partition multi-branch conditional and exception constructs (if / elif / else, try / except / finally)
  local s_row, s_col, e_row, e_col = get_branch_range(scope_node, row)

  -- Clamp off-by-one boundary if tree-sitter node ends on col 0 of following line
  if e_col == 0 and e_row > s_row then
    e_row = e_row - 1
    local ok_end, end_lines = pcall(api.nvim_buf_get_lines, buf, e_row, e_row + 1, false)
    e_col = (ok_end and end_lines and end_lines[1]) and #end_lines[1] or 0
  end

  local scope_start = s_row + 1
  local scope_end = e_row + 1

  -- Calculate indentation column of scope start line, aligned to buffer indent width
  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)
  local active_col = 0
  local ok_l, lines = pcall(api.nvim_buf_get_lines, buf, s_row, s_row + 1, false)
  if ok_l and lines and lines[1] then
    local lead = lines[1]:match("^%s*") or ""
    local raw_disp = utils.lead_display_width(lead, tabstop)
    active_col = math.floor(raw_disp / width) * width
  end

  local child_ranges = collect_child_scope_ranges(scope_node, lang, cfg)
  local first_body_line, last_body_line =
    M.find_first_last_scope_lines(buf, scope_start, scope_end, active_col, tabstop)
  local delims = M.get_boundary_delimiters(buf, scope_node, s_row, e_row, true, lang_tree)

  ---@type indentinator.ScopeInfo
  return {
    scope_start = scope_start,
    scope_end = scope_end,
    active_col = active_col,
    s_row = s_row,
    s_col = s_col,
    e_row = e_row,
    e_col = e_col,
    node = scope_node,
    is_ts = true,
    child_ranges = child_ranges,
    first_body_line = first_body_line,
    last_body_line = last_body_line,
    delimiter_spans = delims,
  }
end

--- Resolves scope boundaries using indentation level scanning (fallback).
---@param buf integer Buffer handle
---@param win integer Window handle
---@param custom_row integer|nil Optional target row override
---@return indentinator.ScopeInfo|nil
function M.resolve_indent_scope(buf, win, custom_row)
  if not buf or not win or not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then
    return nil
  end

  local line_count = api.nvim_buf_line_count(buf)
  if line_count == 0 then
    return nil
  end

  local target_row
  if custom_row then
    target_row = math.min(math.max(1, custom_row), line_count)
  else
    local cursor = api.nvim_win_get_cursor(win)
    target_row = math.min(math.max(1, cursor[1]), line_count)
  end

  local ok_l, lines = pcall(api.nvim_buf_get_lines, buf, target_row - 1, target_row, false)
  if not ok_l or not lines or not lines[1] then
    return nil
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
    return nil
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
  local CHUNK = 64

  -- Scan upward for scope start. Lines are read in 64-line chunks (walked in
  -- reverse) rather than one call per line, so the fallback stays cheap on
  -- large, deeply nested files.
  local scope_start = target_row
  local curr_up = target_row - 1
  while curr_up > 0 do
    local from = math.max(1, curr_up - CHUNK + 1)
    local ok_u, u_lines = pcall(api.nvim_buf_get_lines, buf, from - 1, curr_up, false)
    if not ok_u or not u_lines or #u_lines == 0 then
      break
    end
    local found = false
    for i = #u_lines, 1, -1 do
      local row_idx = from + i - 1
      local u_text = u_lines[i]
      local u_lead = u_text:match("^%s*")
      if u_text ~= "" and u_lead ~= u_text then
        local u_disp = utils.lead_display_width(u_lead, tabstop)
        if u_disp < limit then
          scope_start = (u_disp == active_col) and row_idx or (row_idx + 1)
          found = true
          break
        end
      end
      scope_start = row_idx
    end
    if found then
      break
    end
    curr_up = from - 1
  end

  -- Scan downward for scope end, in 64-line chunks.
  local scope_end = target_row
  local curr_down = target_row + 1
  while curr_down <= line_count do
    local to = math.min(line_count, curr_down + CHUNK - 1)
    local ok_d, d_lines = pcall(api.nvim_buf_get_lines, buf, curr_down - 1, to, false)
    if not ok_d or not d_lines or #d_lines == 0 then
      break
    end
    local found = false
    for i = 1, #d_lines do
      local row_idx = curr_down + i - 1
      local d_text = d_lines[i]
      local d_lead = d_text:match("^%s*")
      if d_text ~= "" and d_lead ~= d_text then
        local d_disp = utils.lead_display_width(d_lead, tabstop)
        if d_disp < limit then
          -- Only include line at active_col if it's a closing delimiter
          if d_disp == active_col and is_closing_delimiter(d_text) then
            scope_end = row_idx
          else
            scope_end = row_idx - 1
          end
          found = true
          break
        end
      end
      scope_end = row_idx
    end
    if found then
      break
    end
    curr_down = to + 1
  end

  -- Trim trailing blank lines from scope end
  while scope_end > scope_start do
    local ok_t, t_lines = pcall(api.nvim_buf_get_lines, buf, scope_end - 1, scope_end, false)
    if ok_t and t_lines and t_lines[1] and t_lines[1]:match("^%s*$") then
      scope_end = scope_end - 1
    else
      break
    end
  end

  local first_body_line, last_body_line =
    M.find_first_last_scope_lines(buf, scope_start, scope_end, active_col, tabstop)

  return {
    scope_start = scope_start,
    scope_end = scope_end,
    active_col = active_col,
    s_row = scope_start - 1,
    s_col = 0,
    e_row = scope_end - 1,
    e_col = 0,
    node = nil,
    is_ts = false,
    child_ranges = {},
    first_body_line = first_body_line,
    last_body_line = last_body_line,
    delimiter_spans = {},
  }
end

--- Resolves the parent (enclosing) scope of the active scope.
--- Used for upward motion navigation when already at a scope boundary.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param current_scope_start integer Current scope start row
---@param current_node userdata|nil Current TSNode
---@param use_treesitter boolean
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
---@return userdata|nil scope_node
function M.get_parent_scope(buf, win, current_scope_start, current_node, use_treesitter)
  if use_treesitter ~= false and current_node then
    local parent = current_node:parent()
    if parent then
      local p_s_row, p_s_col, _, _ = parent:range()
      local p_scope = M.resolve_treesitter_scope(buf, win, p_s_row + 1, p_s_col, parent)
      if p_scope and p_scope.scope_start < current_scope_start then
        return p_scope.scope_start, p_scope.scope_end, p_scope.active_col, p_scope.node
      end
    end
  end

  -- Indentation-based parent lookup: scan above current_scope_start for outer indent
  local tabstop = utils.buffer_tabstop(buf)
  local curr_start_lead = ""
  local ok_l, lines = pcall(api.nvim_buf_get_lines, buf, current_scope_start - 1, current_scope_start, false)
  if ok_l and lines and lines[1] then
    curr_start_lead = lines[1]:match("^%s*") or ""
  end
  local curr_start_col = utils.lead_display_width(curr_start_lead, tabstop)

  local scan_row = current_scope_start - 1
  while scan_row > 0 do
    local text, lead, row = utils.find_non_blank_up(buf, scan_row, 500)
    if not text or not row then
      break
    end
    local disp = utils.lead_display_width(lead, tabstop)
    if disp < curr_start_col or (curr_start_col == 0 and row < current_scope_start) then
      local s = M.resolve_indent_scope(buf, win, row)
      if s then
        return s.scope_start, s.scope_end, s.active_col, nil
      end
    end
    scan_row = row - 1
  end

  return nil, nil, nil, nil
end

--- Primary scope resolution dispatcher with memoization caching.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param use_treesitter boolean Whether Treesitter scope is enabled
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
---@return userdata|nil scope_node
function M.get_scope(buf, win, use_treesitter)
  if not buf or not win or not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then
    return nil, nil, nil, nil
  end

  local ok_c, cursor = pcall(api.nvim_win_get_cursor, win)
  if not ok_c or not cursor then
    return nil, nil, nil, nil
  end

  local cursor_row = cursor[1]
  local cursor_col = cursor[2]

  -- Fast path: if cursor is still within active scope node bounds, return cached scope
  if cache.is_cursor_in_scope(win, buf, cursor_row, cursor_col) then
    local cached = cache.get_win_scope(win, buf)
    if cached then
      return cached.scope_start, cached.scope_end, cached.active_col, cached.node
    end
  end

  local scope = nil
  if use_treesitter ~= false then
    scope = M.resolve_treesitter_scope(buf, win, cursor_row, cursor_col)
  end

  if not scope then
    scope = M.resolve_indent_scope(buf, win, cursor_row)
  end

  if scope and scope.scope_start and scope.scope_end and scope.active_col >= 0 then
    cache.set_win_scope(win, buf, cursor_row, cursor_col, scope)
    return scope.scope_start, scope.scope_end, scope.active_col, scope.node
  end

  cache.set_win_scope(win, buf, cursor_row, cursor_col, nil)
  return nil, nil, nil, nil
end

--- Backward compatibility helper matching legacy scope.lua signature.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param start_node userdata|nil
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
---@return userdata|nil scope_node
function M.get_treesitter_scope(buf, win, start_node)
  local cursor = api.nvim_win_get_cursor(win)
  local scope = M.resolve_treesitter_scope(buf, win, cursor[1], cursor[2], start_node)
  if scope then
    return scope.scope_start, scope.scope_end, scope.active_col, scope.node
  end
  return nil, nil, nil, nil
end

--- Backward compatibility helper matching legacy scope.lua signature.
---@param buf integer Buffer handle
---@param win integer Window handle
---@param custom_row integer|nil
---@return integer|nil scope_start
---@return integer|nil scope_end
---@return integer|nil active_col
function M.get_indent_scope(buf, win, custom_row)
  local scope = M.resolve_indent_scope(buf, win, custom_row)
  if scope then
    return scope.scope_start, scope.scope_end, scope.active_col
  end
  return nil, nil, nil
end

return M
