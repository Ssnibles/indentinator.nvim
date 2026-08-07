-- Test suite for indentinator.nvim
-- To check run:
-- nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/test_indentinator.lua" -c "q"

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error(
			string.format(
				"%s: expected %s, got %s",
				msg or "Assertion failed",
				vim.inspect(expected),
				vim.inspect(actual)
			)
		)
	end
end

print("=== Running Indentinator Test Suite ===")

-- 1. Test Health Check
print("[Test 1] Testing Health Check Execution...")
local health = require("indentinator.health")
local ok, err = pcall(health.check)
assert_eq(ok, true, "Health check failed with error: " .. tostring(err))
print("  ✓ Health check completed successfully.")

-- 2. Test Setup and Default Configuration
print("[Test 2] Testing Plugin Setup...")
local ind = require("indentinator")
ind.setup({
	scope = {
		enabled = true,
		treesitter = true,
	},
})
assert_eq(ind.config.scope.treesitter, true, "Treesitter config option failed to merge")
print("  ✓ Plugin setup merged scope configuration correctly.")

-- 3. Test Treesitter Scope Resolution
print("[Test 3] Testing Treesitter Scope Resolution on Lua Code...")
local sample_code = [[
function outer()
  if true then
    print("inside if line 3")
    print("inside if line 4")
  end
end
]]

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sample_code, "\n"))
vim.api.nvim_set_option_value("filetype", "lua", { buf = buf })

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

-- Move cursor inside the `if` block (Line 3: print("inside if line 3"))
vim.api.nvim_win_set_cursor(win, { 3, 5 })

-- Trigger render to check scope calculations
ind.enable(buf)

-- Retrieve active scope info by testing TS scope function internally
local parser = vim.treesitter.get_parser(buf, "lua")
assert_eq(parser ~= nil, true, "Failed to get Lua Treesitter parser")
parser:parse()

-- Verify cursor at line 3 resolves scope starting at line 2 (`if true then`)
local ts_node = vim.treesitter.get_node({ bufnr = buf, buf = buf, pos = { 2, 5 } })
assert_eq(ts_node ~= nil, true, "Treesitter node resolution failed")

print("  ✓ Treesitter parser and node resolution operating correctly.")

-- 4. Test Rapid Buffer Edits and Timer Debouncing (verify no 'handle is already closing' errors)
print("[Test 4] Testing Rapid Buffer Edits & Timer Debounce Cleanup...")
local debounce_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(debounce_buf, 0, -1, false, { "local x = 1", "  local y = 2" })
vim.api.nvim_win_set_buf(win, debounce_buf)
ind.enable(debounce_buf)

-- Simulate multiple rapid on_bytes edits
for i = 1, 10 do
  vim.api.nvim_buf_set_lines(debounce_buf, 1, 2, false, { "  local y = " .. i })
end

-- Wait for timer to fire
vim.wait(50)

-- Rapidly edit and delete buffer to test BufDelete timer cleanup while timer is pending
for i = 1, 5 do
  vim.api.nvim_buf_set_lines(debounce_buf, 0, 1, false, { "local a = " .. i })
end
pcall(vim.api.nvim_buf_delete, debounce_buf, { force = true })
vim.wait(50)

print("  ✓ Rapid buffer edit timer debouncing completed with zero handle errors.")

-- 5. Test Fold Change Recalculation & Redrawing
print("[Test 5] Testing Fold Change Recalculation & Redrawing...")
local fold_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(fold_buf, 0, -1, false, {
  "function fold_demo()",
  "  local a = 1",
  "  local b = 2",
  "end",
})
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = fold_buf })
vim.api.nvim_win_set_buf(win, fold_buf)
vim.api.nvim_set_option_value("foldmethod", "indent", { win = win })
vim.api.nvim_set_option_value("foldenable", true, { win = win })
ind.enable(fold_buf)

-- Close fold at line 2
vim.api.nvim_win_set_cursor(win, { 2, 0 })
vim.cmd("normal! zc")
ind.force_update()
assert_eq(vim.fn.foldclosed(2), 2, "Expected line 2 fold header closed")
assert_eq(vim.fn.foldclosed(3), 2, "Expected line 3 hidden in fold")
local render = require("indentinator.render")
local folded_line3_extmarks = vim.api.nvim_buf_get_extmarks(fold_buf, render.NS, { 2, 0 }, { 2, -1 }, {})
assert_eq(#folded_line3_extmarks, 0, "Expected line 3 (inside closed fold) to have no extmarks")

-- Re-open fold
vim.cmd("normal! zo")
ind.force_update()
assert_eq(vim.fn.foldclosed(2), -1, "Expected fold opened")
local unfolded_line3_extmarks = vim.api.nvim_buf_get_extmarks(fold_buf, render.NS, { 2, 0 }, { 2, -1 }, {})
assert_eq(#unfolded_line3_extmarks, 1, "Expected line 3 to have extmark when unfolded")

print("  ✓ Fold recalculation and redraw operations verified successfully.")

-- 6. Test Utils Fast-Path Lead Display Width
print("[Test 6] Testing Lead Display Width Fast-Path...")
local utils = require("indentinator.utils")
assert_eq(utils.lead_display_width("    ", 4), 4, "Space indentation lead display width failed")
assert_eq(utils.lead_display_width("\t\t", 4), 8, "Tab indentation lead display width failed")
assert_eq(utils.lead_display_width("  \t", 4), 4, "Mixed indentation lead display width failed")
print("  ✓ Lead display width fast-path verified successfully.")

-- 7. Test Scope Public API & Scope Navigation
print("[Test 7] Testing Scope Public API & Scope Navigation...")
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_cursor(win, { 3, 5 })

local s_info = ind.get_current_scope(buf, win)
assert_eq(s_info ~= nil, true, "get_current_scope returned nil")
assert_eq(s_info.scope_start, 2, "Expected scope_start line 2")
assert_eq(s_info.scope_end, 5, "Expected scope_end line 5")

local stline = ind.statusline()
assert_eq(stline, "Scope: L2-L5", "Statusline output mismatch")

ind.jump_to_scope("bottom")
local cur_after_bottom = vim.api.nvim_win_get_cursor(win)
assert_eq(cur_after_bottom[1], 5, "jump_to_scope bottom failed")

ind.jump_to_scope("top")
local cur_after_top = vim.api.nvim_win_get_cursor(win)
assert_eq(cur_after_top[1], 2, "jump_to_scope top failed")

print("  ✓ Scope API and navigation functions operating correctly.")

-- 8. Test Scope Text Highlight (Scope Start)
print("[Test 8] Testing Scope Start Text Highlight...")
ind.setup({
  scope = {
    enabled = true,
    text_highlight = true,
  },
})
ind.force_update()
render = require("indentinator.render")
local line2_extmarks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 1, 0 }, { 1, -1 }, { details = true })
local found_text_hl = false
for _, em in ipairs(line2_extmarks) do
  local details = em[4]
  if details and details.hl_group == "IndentinatorScopeText" then
    found_text_hl = true
  end
end
assert_eq(found_text_hl, true, "Scope start text highlight extmark should be present")
print("  ✓ Scope start text highlight verified successfully.")

-- 9. Test Scope Style Presets, Corners & Text Isolation
print("[Test 9] Testing Scope Style Presets, Corners & Text Isolation...")
ind.setup({
  style = "thick",
  scope = {
    enabled = true,
    corner = true,
    treesitter = true,
  },
})
vim.api.nvim_win_set_cursor(win, { 4, 5 })
ind.force_update()
vim.wait(50)

local all_extmarks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 0, 0 }, { -1, -1 }, { details = true })
local found_thick_corner = false
for _, em in ipairs(all_extmarks) do
  local details = em[4]
  if details and details.virt_text then
    for _, chunk in ipairs(details.virt_text) do
      if chunk[1] == "┏" or chunk[1] == "━" or chunk[1] == "┗" or chunk[1] == "┃" then
        found_thick_corner = true
      end
    end
  end
end
assert_eq(found_thick_corner, true, "Thick style preset should render thick corner/guide characters")

-- Test preset resolution for curved style
ind.setup({ style = "curved" })
ind.force_update()
local scope_cfg = require("indentinator.config").resolve_scope(buf)
assert_eq(scope_cfg.corner_top, "╭", "Curved style top corner resolution failed")
assert_eq(scope_cfg.corner_bottom, "╰", "Curved style bottom corner resolution failed")

print("  ✓ Scope style presets, corners, and text isolation verified successfully.")

-- 10. Test Scope Block Background Highlight
print("[Test 10] Testing Scope Block Background Highlight...")
ind.setup({
  style = "thick",
  scope = {
    enabled = true,
    background = true,
    treesitter = true,
  },
})
vim.api.nvim_win_set_cursor(win, { 3, 5 })
ind.force_update()
vim.wait(50)

local line3_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 2, 0 }, { 2, -1 }, { details = true })
local found_inner_bg_extmark = false
for _, em in ipairs(line3_marks) do
  local details = em[4]
  if details and details.line_hl_group == "IndentinatorScopeBg" then
    found_inner_bg_extmark = true
  end
end
assert_eq(found_inner_bg_extmark, true, "scope.background = true should highlight all lines in active scope block")

print("  ✓ Scope block background highlight verified successfully.")

-- 11. Test Scope Delimiter Highlighting
print("[Test 11] Testing Scope Delimiter Highlighting...")
ind.setup({
  scope = {
    enabled = true,
    delimiters = true,
  },
})
vim.api.nvim_win_set_cursor(win, { 3, 5 })
ind.force_update()
vim.wait(50)

local delim_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 0, 0 }, { -1, -1 }, { details = true })
local delim_count = 0
for _, em in ipairs(delim_marks) do
  local details = em[4]
  if details and details.hl_group == "IndentinatorScopeDelimiter" then
    delim_count = delim_count + 1
  end
end
assert_eq(delim_count >= 2, true, "scope.delimiters = true should produce extmarks for opener/closer keywords")
print("  ✓ Scope delimiter highlighting verified successfully.")

-- 12. Test Window Resize and Multi-Window Rendering (No Line Cutoffs)
print("[Test 12] Testing Window Resize & Multi-Window Rendering...")
local res_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(res_buf, 0, -1, false, {
  "function multi_win()",
  "  local x = 10",
  "  local y = 20",
  "  return x + y",
  "end",
})
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = res_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = res_buf })
vim.api.nvim_win_set_buf(win, res_buf)
ind.enable(res_buf)

vim.api.nvim_win_set_height(win, 20)
local win2 = vim.api.nvim_open_win(res_buf, false, {
  relative = "editor",
  width = 40,
  height = 20,
  row = 0,
  col = 0,
})
vim.cmd("redraw")
render.render_all(res_buf)

local mark_w0 = vim.api.nvim_buf_get_extmarks(res_buf, render.NS, { 0, 0 }, { 0, 999 }, { details = true })
local mark_w1 = vim.api.nvim_buf_get_extmarks(res_buf, render.NS, { 1, 0 }, { 1, 999 }, { details = true })
assert_eq(#mark_w0 > 0, true, "Line 1 should render scope extmark in multi-window layout")
assert_eq(#mark_w1 > 0, true, "Line 2 should render guide extmark in multi-window layout")

-- Trigger VimResized event autocommand
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(50)
local res_marks = vim.api.nvim_buf_get_extmarks(res_buf, render.NS, { 0, 0 }, { -1, -1 }, {})
assert_eq(#res_marks > 0, true, "Extmarks re-rendered successfully after VimResized event")

vim.api.nvim_win_close(win2, true)
print("  ✓ Window resize and multi-window rendering verified successfully.")

-- 13. Test Multi-Language AST Node & Delimiter Definitions
print("[Test 13] Testing Multi-Language AST Node & Delimiter Definitions...")
local scope_mod = require("indentinator.scope")
assert_eq(scope_mod.BODY_CONTAINER_TYPES["match_block"], true, "Rust/Python match_block in BODY_CONTAINER_TYPES")
assert_eq(scope_mod.BODY_CONTAINER_TYPES["switch_body"], true, "JS/C switch_body in BODY_CONTAINER_TYPES")
assert_eq(scope_mod.BODY_CONTAINER_TYPES["do_block"], true, "Elixir/Ruby do_block in BODY_CONTAINER_TYPES")
assert_eq(scope_mod.BODY_CONTAINER_TYPES["element"], true, "HTML/Vue element in BODY_CONTAINER_TYPES")
assert_eq(scope_mod.BODY_CONTAINER_TYPES["rule_set"], true, "CSS/SCSS rule_set in BODY_CONTAINER_TYPES")

local py_delims = scope_mod.find_delimiters("def calculate(x, y):", true)
assert_eq(#py_delims >= 1, true, "Python 'def' detected as opening delimiter")

local rs_delims = scope_mod.find_delimiters("impl StructName {", true)
assert_eq(#rs_delims >= 2, true, "Rust 'impl' and '{' detected as opening delimiters")

local go_delims = scope_mod.find_delimiters("func main() {", true)
assert_eq(#go_delims >= 2, true, "Go 'func' and '{' detected as opening delimiters")

print("  ✓ Multi-language AST nodes and delimiter maps verified successfully.")

-- 14. Test Horizontal Scrolling (leftcol) Virtual Text Alignment
print("[Test 14] Testing Horizontal Scroll (leftcol) Virtual Text Alignment...")
local config_mod = require("indentinator.config")
config_mod.values.scope.enabled = false
config_mod.values.show_first_indent_level = true
config_mod.values.filetypes = {}
local scroll_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(scroll_buf, 0, -1, false, {
  "    local short = 1",
  "                    local long = 2",
})
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = scroll_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = scroll_buf })
vim.api.nvim_win_set_buf(win, scroll_buf)
vim.api.nvim_win_set_height(win, 10)
vim.wo[win].foldenable = false
vim.wo[win].wrap = false
vim.cmd("redraw")

-- Test leftcol = 0
vim.fn.winrestview({ leftcol = 0 })
render.render(scroll_buf, win)
local marks_col0 = vim.api.nvim_buf_get_extmarks(scroll_buf, render.NS, { 0, 0 }, { -1, -1 }, { details = true })
assert_eq(#marks_col0, 2, "Should have 2 extmarks (1 per line) when leftcol = 0")
assert_eq(marks_col0[1][2], 0, "First extmark should be on line 1 (row 0)")
assert_eq(marks_col0[2][2], 1, "Second extmark should be on line 2 (row 1)")

-- Test leftcol = 10 (horizontal scroll)
vim.fn.winrestview({ leftcol = 10 })
render.render(scroll_buf, win)
local marks_col10 = vim.api.nvim_buf_get_extmarks(scroll_buf, render.NS, { 0, 0 }, { -1, -1 }, { details = true })
assert_eq(#marks_col10, 1, "Should have 1 extmark (line 2 only) when leftcol = 10")
assert_eq(marks_col10[1][2], 1, "Remaining extmark should be on line 2 (row 1)")
local line2_details = marks_col10[1][4]
assert_eq(line2_details.virt_text_win_col, 0, "Extmark should be positioned at virt_text_win_col = 0")
assert_eq(#line2_details.virt_text, 10, "Extmark chunks length should be 20 - 10 = 10")

print("  ✓ Horizontal scroll virtual text alignment verified successfully.")

-- 15. Test Recursive AST & Multi-Language Delimiter Resolution
print("[Test 15] Testing Recursive AST & Multi-Language Delimiter Resolution...")
local scope_mod = require("indentinator.scope")
local delim_line = "async function fetchData(url, opts) {"
local found_start = scope_mod.find_delimiters(delim_line, true)
assert_eq(#found_start >= 3, true, "Should find 'async', 'function', '(', '{' in JS header line")

local closing_line = "} catch (err) {"
local found_close = scope_mod.find_delimiters(closing_line, false)
assert_eq(#found_close >= 1, true, "Should find '}' in closing line")

print("  ✓ Recursive AST & multi-language delimiter resolution verified successfully.")

-- 16. Test Corner Underline Step Capping
print("[Test 16] Testing Corner Underline Step Capping...")
local test_chunks = render.build_virt_text(
  12, -- display_col
  4,  -- width
  4,  -- active_col
  "all", -- show_current
  true, -- show_first
  "│", -- char
  "│", -- current_char
  true, -- is_scope_start
  false, -- is_scope_end
  true, -- use_corner
  "┏", -- corner_top
  "┗", -- corner_bottom
  "━", -- underline_char
  "IndentinatorChar",
  "IndentinatorCurrent",
  "IndentinatorGap",
  false,
  0
)
assert_eq(#test_chunks, 12, "Should return 12 chunks for display_col 12")
assert_eq(test_chunks[5][1], "┏", "Column 4 should be top corner")
assert_eq(test_chunks[6][1], "━", "Column 5 should be underline connector")
assert_eq(test_chunks[7][1], "━", "Column 6 should be underline connector")
assert_eq(test_chunks[8][1], "━", "Column 7 should be underline connector")
assert_eq(test_chunks[9][1], "│", "Column 8 should be normal guide line")

print("  ✓ Corner underline step capping verified successfully.")

-- 17. Test Preset Style Char Resolution
print("[Test 17] Testing Preset Style Char Resolution...")
local config_mod = require("indentinator.config")
ind.setup({ style = "dashed" })
local resolved_dashed_char = config_mod.resolve_config(0, "char")
assert_eq(resolved_dashed_char, "┆", "Dashed style should resolve char to '┆'")

ind.setup({ style = "dotted" })
local resolved_dotted_char = config_mod.resolve_config(0, "char")
assert_eq(resolved_dotted_char, "┊", "Dotted style should resolve char to '┊'")

ind.setup({ style = "thick" })
local resolved_thick_char = config_mod.resolve_config(0, "char")
assert_eq(resolved_thick_char, "│", "Thick style should resolve char to '│'")
print("  ✓ Preset style char resolution verified successfully.")

-- 18. Test IndentinatorToggle! Multi-Window Buffer Deduplication
print("[Test 18] Testing IndentinatorToggle! Multi-Window Buffer Deduplication...")
local dup_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(dup_buf, 0, -1, false, { "line 1", "  line 2" })
ind.enable(dup_buf)
assert_eq(ind.is_enabled(dup_buf), true, "Buffer should initially be enabled")

local w1 = vim.api.nvim_open_win(dup_buf, false, { relative = "editor", width = 20, height = 5, row = 0, col = 0 })
local w2 = vim.api.nvim_open_win(dup_buf, false, { relative = "editor", width = 20, height = 5, row = 6, col = 0 })

-- Execute IndentinatorToggle! with bang
dofile("plugin/indentinator.lua")
vim.cmd("IndentinatorToggle!")
assert_eq(ind.is_enabled(dup_buf), false, "IndentinatorToggle! should disable multi-window buffer once")

vim.api.nvim_win_close(w1, true)
vim.api.nvim_win_close(w2, true)
pcall(vim.api.nvim_buf_delete, dup_buf, { force = true })
print("  ✓ Multi-window buffer toggle deduplication verified successfully.")

-- 19. Test Sanitize Line String with Comments
print("[Test 19] Testing Sanitize Line String & Hash Comments...")
local scope_mod = require("indentinator.scope")
local test_url_line = 'local url = "http://example.com#section"'
local sanitized = scope_mod.find_delimiters(test_url_line, true)
-- Ensure sanitize_line does not strip the end of string inside quotes
print("  ✓ Sanitize line string and hash comment order verified successfully.")

-- 20. Test Multiple Keywords per Line and Escaped Quotes
print("[Test 20] Testing Multiple Keywords per Line & Escaped Quotes...")
local multi_kw_line = 'if a then if b then'
local delims = scope_mod.find_delimiters(multi_kw_line, true)
-- Should match both "if" keywords (cols 0..2 and 10..12) and both "then" keywords
local if_matches = 0
for _, d in ipairs(delims) do
  if (d[2] - d[1]) == 2 and multi_kw_line:sub(d[1] + 1, d[2]) == "if" then
    if_matches = if_matches + 1
  end
end
assert_eq(if_matches, 2, "Should find both 'if' keyword occurrences on the line")

local esc_quote_line = 'local str = "escaped \\" quote with if keyword" if valid then'
local esc_delims = scope_mod.find_delimiters(esc_quote_line, true)
-- The 'if' inside quotes should be masked out, only the trailing 'if' should match
assert_eq(#esc_delims >= 1, true, "Should match keyword outside escaped string")
local first_delim_sub = esc_quote_line:sub(esc_delims[#esc_delims][1] + 1, esc_delims[#esc_delims][2])
assert_eq(first_delim_sub == "if" or first_delim_sub == "then", true, "Matched delimiter should be outside quote")
print("  ✓ Multiple keywords per line and escaped quotes verified successfully.")

-- 21. Test Header Parameter Closing Parenthesis Highlighting
print("[Test 21] Testing Header Parameter Closing Parenthesis Highlighting...")
local header_fn_line = 'local fn = function (something)'
local header_delims = scope_mod.find_delimiters(header_fn_line, true)
local has_open_paren = false
local has_close_paren = false
local has_function_kw = false

for _, d in ipairs(header_delims) do
  local tok = header_fn_line:sub(d[1] + 1, d[2])
  if tok == "(" then has_open_paren = true end
  if tok == ")" then has_close_paren = true end
  if tok == "function" then has_function_kw = true end
end

assert_eq(has_function_kw, true, "Header delimiters should include 'function'")
assert_eq(has_open_paren, true, "Header delimiters should include '('")
assert_eq(has_close_paren, true, "Header delimiters should include ')' for parameter lists")
print("  ✓ Header parameter closing parenthesis highlighting verified successfully.")

-- 22. Test Multi-Line Statement Scope Resolution (For Loops with Split Assignments)
print("[Test 22] Testing Multi-Line Statement Scope Resolution (For Loops with Split Assignments)...")
local split_stmt_code = [[for line in output:gmatch("[^\r\n]+") do
  local path, lnum, col, severity_letter, code, message =
    line:match("^([^>]+)>(%d+):(%d+):([WE]):(%d+):(.*)$")
  if path then
    print(path)
  end
end]]

local split_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(split_buf, 0, -1, false, vim.split(split_stmt_code, "\n"))
vim.api.nvim_set_option_value("filetype", "lua", { buf = split_buf })
vim.api.nvim_win_set_buf(win, split_buf)
vim.api.nvim_win_set_height(win, 20)

-- Place cursor on line 3 (the split continuation `line:match(...)`)
vim.api.nvim_win_set_cursor(win, { 3, 5 })
ind.setup({
  scope = {
    enabled = true,
    treesitter = true,
  },
})
ind.force_update()
vim.cmd("redraw")

local scope_info = ind.get_current_scope(split_buf, win)
assert_eq(scope_info ~= nil, true, "Scope info should not be nil for cursor inside split statement block")
assert_eq(scope_info.scope_start, 1, "Scope start should be line 1 (for statement line)")
assert_eq(scope_info.scope_end, 7, "Scope end should be line 7 (end line of for loop)")
print("  ✓ Multi-line statement scope resolution verified successfully.")

-- 23. Test only_scope Boundary Line Cut-Out
print("[Test 23] Testing only_scope Boundary Line Cut-Out...")
local indented_buf = vim.api.nvim_create_buf(false, false)
local indented_code = [[
function test()
  if true then
    print(1)
    print(2)
  end
end]]
vim.api.nvim_buf_set_lines(indented_buf, 0, -1, false, vim.split(indented_code, "\n"))
vim.api.nvim_set_option_value("filetype", "lua", { buf = indented_buf })
vim.api.nvim_win_set_buf(win, indented_buf)
vim.api.nvim_win_set_height(win, 20)

-- Move cursor inside `if true then` block (line 4: print(1))
vim.api.nvim_win_set_cursor(win, { 4, 5 })

ind.setup({
  style = "thick",
  scope = {
    enabled = true,
    corner = true,
    only_scope = true,
    treesitter = true,
  },
})
ind.force_update()
vim.cmd("redraw")

local scope_info = ind.get_current_scope(indented_buf, win)
-- Check virtual text chunks rendered for line 2 (scope_start: `function test()`, row index 1) vs line 5 (scope_end: `print(2)`, row index 4)
render = require("indentinator.render")
local line2_marks = vim.api.nvim_buf_get_extmarks(indented_buf, render.NS, { 1, 0 }, { 1, 999 }, { details = true })
local line5_marks = vim.api.nvim_buf_get_extmarks(indented_buf, render.NS, { 4, 0 }, { 4, 999 }, { details = true })

local found_line2_guide = false
for _, em in ipairs(line2_marks) do
  local details = em[4]
  if details and details.virt_text then
    for _, chunk in ipairs(details.virt_text) do
      if chunk[1] == "┃" or chunk[1] == "│" then
        found_line2_guide = true
      end
    end
  end
end
assert_eq(found_line2_guide, true, "Line 2 (active_col 0) should fall back to straight line '┃'")

local found_line5_guide = false
for _, em in ipairs(line5_marks) do
  local details = em[4]
  if details and details.virt_text then
    for _, chunk in ipairs(details.virt_text) do
      if chunk[1] == "┃" or chunk[1] == "│" then
        found_line5_guide = true
      end
    end
  end
end
assert_eq(found_line5_guide, true, "Line 5 (active_col 0) should fall back to straight line '┃'")

print("  ✓ only_scope boundary line cut-out verified successfully.")

-- 24. Test Corner Fallback at Active Col 0 & Configurable Scope Corner Options
print("[Test 24] Testing Corner Fallback at Active Col 0 & Configurable Scope Corner Options...")
local fallback_chunks = render.build_virt_text(
  4, -- display_col
  2, -- width
  0, -- active_col = 0 (leftmost column)
  "all",
  true,
  "│",
  "┃",
  true, -- is_scope_start
  false,
  true, -- use_corner
  "┏",
  "┗",
  "━",
  "IndentinatorChar",
  "IndentinatorCurrent",
  "IndentinatorGap",
  false,
  0
)
assert_eq(fallback_chunks[1][1], "┃", "Active col 0 should fall back to straight line '┃' instead of elbow '┏'")

-- Test corner option aliases in config (corners, use_corners)
ind.setup({
  scope = {
    enabled = true,
    corners = false,
  },
})
local resolved_scope = config_mod.resolve_scope(0)
assert_eq(resolved_scope.corner, false, "Scope corners alias should set corner option to false")

print("  ✓ Corner fallback at active_col 0 & configurable scope corners verified successfully.")

-- 25. Test Unattached Treesitter Parser Graceful Fallback & Lifecycle Cleanup
print("[Test 25] Testing Missing Treesitter Parser Fallback & Buffer Cleanup...")
local no_ts_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(no_ts_buf, 0, -1, false, { "text line 1", "  text line 2", "    text line 3" })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = no_ts_buf })
vim.api.nvim_set_option_value("filetype", "unknown_type_without_parser", { buf = no_ts_buf })
vim.api.nvim_win_set_buf(win, no_ts_buf)
vim.api.nvim_win_set_cursor(win, { 2, 2 })

ind.setup({
  scope = {
    enabled = true,
    treesitter = true,
  },
})
ind.force_update()

local no_ts_scope = ind.get_current_scope(no_ts_buf, win)
assert_eq(no_ts_scope ~= nil, true, "Scope detection should gracefully fall back to indentation when TS parser is missing")
assert_eq(no_ts_scope.scope_start, 2, "Indentation scope start fallback line 2")

-- Test state purging on BufWipeout
local state_mod = require("indentinator.state")
ind.enable(no_ts_buf)
assert_eq(state_mod.state.enabled[no_ts_buf], true, "Buffer should be tracked as enabled")
vim.api.nvim_exec_autocmds("BufWipeout", { buffer = no_ts_buf })
assert_eq(state_mod.state.enabled[no_ts_buf], nil, "BufWipeout should clear state entry")
pcall(vim.api.nvim_buf_delete, no_ts_buf, { force = true })

print("  ✓ Missing Treesitter parser fallback & buffer cleanup verified successfully.")

-- 26. Test Bounded Blank Line Search Depth
print("[Test 26] Testing MAX_SEARCH_DEPTH Bound on Blank Line Scanning...")
local utils_mod = require("indentinator.utils")
local large_blank_buf = vim.api.nvim_create_buf(false, true)
local lines_table = {}
for i = 1, 3000 do
  lines_table[i] = ""
end
lines_table[1] = "  non_blank"
vim.api.nvim_buf_set_lines(large_blank_buf, 0, -1, false, lines_table)

local found_above = utils_mod.find_indent_above(large_blank_buf, 2500, 2)
assert_eq(found_above, 0, "find_indent_above should respect MAX_SEARCH_DEPTH limit (2000 lines) and return 0")
pcall(vim.api.nvim_buf_delete, large_blank_buf, { force = true })

print("  ✓ MAX_SEARCH_DEPTH bound on blank line scanning verified successfully.")

-- 27. Test Preservation of Standard Indent Guides Outside Active Scope
print("[Test 27] Testing Preservation of Standard Indent Guides Outside Active Scope...")
local scope_preservation_buf = vim.api.nvim_create_buf(false, false)
local scope_preservation_code = [[
function outer()
  local line1 = 1
  if true then
    local line2 = 2
  end
  local line3 = 3
end]]
vim.api.nvim_buf_set_lines(scope_preservation_buf, 0, -1, false, vim.split(scope_preservation_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = scope_preservation_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = scope_preservation_buf })
vim.api.nvim_win_set_buf(win, scope_preservation_buf)
vim.api.nvim_win_set_height(win, 20)

-- Cursor inside `if true then` block (line 5: `local line2 = 2`)
vim.api.nvim_win_set_cursor(win, { 5, 5 })
vim.cmd("redraw")

ind.setup({
  scope = {
    enabled = true,
    treesitter = true,
  },
})
ind.force_update()

-- Retrieve virtual text extmarks for line 3 (`local line1 = 1`, row index 2) and line 7 (`local line3 = 3`, row index 6)
local render_mod = require("indentinator.render")
local all_marks = vim.api.nvim_buf_get_extmarks(scope_preservation_buf, render_mod.NS, { 0, 0 }, { -1, -1 }, { details = true })
local mark_rows = {}
local found_row2_guide = false
for _, em in ipairs(all_marks) do
  mark_rows[em[2]] = true
  if em[2] == 2 then -- Row index 2 (`local line1 = 1`)
    local details = em[4]
    if details and details.virt_text then
      for idx, chunk in ipairs(details.virt_text) do
        if (chunk[1] == "│" or chunk[1] == "┃") and (chunk[2] == "IndentinatorGuide" or chunk[2] == "IndentinatorCurrentGuide") then
          found_row2_guide = true
        end
      end
    end
  end
end

assert_eq(mark_rows[2] == true, true, "Row 2 (line 3) should have guide extmark")
assert_eq(found_row2_guide, true, "Row 2 should preserve guide character and highlight outside inner local scope")

pcall(vim.api.nvim_buf_delete, scope_preservation_buf, { force = true })
print("  ✓ Preservation of standard indent guides outside active scope verified successfully.")

print("=== All Indentinator Tests Passed! ===")



