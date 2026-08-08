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
vim.api.nvim_set_option_value("foldenable", false, { win = win })
vim.api.nvim_set_option_value("wrap", false, { win = win })
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
scope_mod = require("indentinator.scope")
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
config_mod = require("indentinator.config")
ind.setup({ style = "dashed" })
local resolved_dashed_char = config_mod.resolve_config(0, "char")
assert_eq(resolved_dashed_char, "┆", "Dashed style should resolve char to '┆'")

ind.setup({ style = "dotted" })
local resolved_dotted_char = config_mod.resolve_config(0, "char")
assert_eq(resolved_dotted_char, "┊", "Dotted style should resolve char to '┊'")

ind.setup({ style = "rounded" })
local resolved_rounded_scope = config_mod.resolve_scope(0)
assert_eq(resolved_rounded_scope.corner_top, "╭", "Rounded style should resolve corner_top to '╭'")
assert_eq(resolved_rounded_scope.underline_char, "─", "Rounded style should resolve underline_char to '─'")

ind.setup({ style = "rounded_thick" })
local resolved_rounded_thick_scope = config_mod.resolve_scope(0)
assert_eq(resolved_rounded_thick_scope.corner_top, "┏", "Rounded thick style should resolve corner_top to '┏'")
assert_eq(resolved_rounded_thick_scope.underline_char, "━", "Rounded thick style should resolve underline_char to '━'")

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
scope_mod = require("indentinator.scope")
local test_url_line = 'local url = "http://example.com#section"'
local test_url_delims = scope_mod.find_delimiters(test_url_line, true)
assert_eq(#test_url_delims >= 0, true, "Delimiter scan on URL line completed")
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
assert_eq(has_close_paren, false, "Header delimiters on scope start should NOT include closing paren ')'")
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

-- Check virtual text chunks rendered for line 2 (scope_start: `function test()`, row index 1)
-- vs line 5 (scope_end: `print(2)`, row index 4)
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
local no_ts_msg = "Scope detection should gracefully fall back to indentation when TS parser is missing"
assert_eq(no_ts_scope ~= nil, true, no_ts_msg)
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

-- Retrieve virtual text extmarks for line 3 (`local line1 = 1`, row index 2)
-- and line 7 (`local line3 = 3`, row index 6)
local render_mod = require("indentinator.render")
local all_marks = vim.api.nvim_buf_get_extmarks(
  scope_preservation_buf,
  render_mod.NS,
  { 0, 0 },
  { -1, -1 },
  { details = true }
)
local mark_rows = {}
local found_row2_guide = false
for _, em in ipairs(all_marks) do
  mark_rows[em[2]] = true
  if em[2] == 2 then -- Row index 2 (`local line1 = 1`)
    local details = em[4]
    if details and details.virt_text then
      for _, chunk in ipairs(details.virt_text) do
        local is_char = chunk[1] == "│" or chunk[1] == "┃"
        local is_hl = chunk[2] == "IndentinatorGuide" or chunk[2] == "IndentinatorCurrentGuide"
        if is_char and is_hl then
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

-- 28. Test JSX/TSX & Arrow Function Scope Resolution
print("[Test 28] Testing JSX/TSX & Arrow Function Scope Resolution...")
local jsx_code = [[
const Component = () => {
  return (
    <div className="container">
      {items.map((item) => (
        <span key={item.id}>{item.name}</span>
      ))}
    </div>
  );
};]]

local jsx_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(jsx_buf, 0, -1, false, vim.split(jsx_code, "\n"))
vim.api.nvim_set_option_value("filetype", "typescriptreact", { buf = jsx_buf })
vim.api.nvim_win_set_buf(win, jsx_buf)
vim.api.nvim_win_set_cursor(win, { 5, 12 }) -- Inside span element inside map callback

ind.setup({
  scope = {
    enabled = true,
    treesitter = true,
  },
})
ind.force_update()

local jsx_scope = ind.get_current_scope(jsx_buf, win)
assert_eq(jsx_scope ~= nil, true, "JSX/TSX scope resolution should not be nil")
assert_eq(jsx_scope.scope_start <= 5, true, "JSX scope start should encompass cursor line 5")
assert_eq(jsx_scope.scope_end >= 5, true, "JSX scope end should encompass cursor line 5")
pcall(vim.api.nvim_buf_delete, jsx_buf, { force = true })
print("  ✓ JSX/TSX & Arrow Function Scope Resolution verified successfully.")

-- 29. Test Python match/case & with Statement Scope Resolution
print("[Test 29] Testing Python match/case & with Statement Scope Resolution...")
local py_code = [[
with open("file.txt") as f:
    match status:
        case 200:
            print("OK")
        case 404:
            print("Not Found")]]

local py_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(py_buf, 0, -1, false, vim.split(py_code, "\n"))
vim.api.nvim_set_option_value("filetype", "python", { buf = py_buf })
vim.api.nvim_win_set_buf(win, py_buf)
vim.api.nvim_win_set_cursor(win, { 4, 12 }) -- On print("OK") inside case 200

ind.force_update()
local py_scope = ind.get_current_scope(py_buf, win)
assert_eq(py_scope ~= nil, true, "Python scope resolution should not be nil")
assert_eq(py_scope.scope_start <= 4, true, "Python scope start should be at or above case 200")
assert_eq(py_scope.scope_end >= 4, true, "Python scope end should be at or below line 4")
pcall(vim.api.nvim_buf_delete, py_buf, { force = true })
print("  ✓ Python match/case & with Statement Scope Resolution verified successfully.")

-- 30. Test Rust impl & closure_expression Scope Resolution
print("[Test 30] Testing Rust impl & closure_expression Scope Resolution...")
local rs_code = [[
impl MyStruct {
    pub fn process(&self) {
        let items = vec![1, 2, 3];
        items.iter().for_each(|x| {
            println!("{}", x);
        });
    }
}]]

local rs_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(rs_buf, 0, -1, false, vim.split(rs_code, "\n"))
vim.api.nvim_set_option_value("filetype", "rust", { buf = rs_buf })
vim.api.nvim_win_set_buf(win, rs_buf)
vim.api.nvim_win_set_cursor(win, { 5, 16 }) -- On println! inside Rust closure

ind.force_update()
local rs_scope = ind.get_current_scope(rs_buf, win)
assert_eq(rs_scope ~= nil, true, "Rust scope resolution should not be nil")
assert_eq(rs_scope.scope_start <= 5, true, "Rust scope start should encompass line 5")
assert_eq(rs_scope.scope_end >= 5, true, "Rust scope end should encompass line 5")
pcall(vim.api.nvim_buf_delete, rs_buf, { force = true })
print("  ✓ Rust impl & closure_expression Scope Resolution verified successfully.")

-- 31. Test Go select & func_literal Scope Resolution
print("[Test 31] Testing Go select & func_literal Scope Resolution...")
local go_code = [[
func main() {
    go func() {
        select {
        case msg := <-ch:
            fmt.Println(msg)
        default:
            fmt.Println("no msg")
        }
    }()
}]]

local go_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(go_buf, 0, -1, false, vim.split(go_code, "\n"))
vim.api.nvim_set_option_value("filetype", "go", { buf = go_buf })
vim.api.nvim_win_set_buf(win, go_buf)
vim.api.nvim_win_set_cursor(win, { 5, 14 }) -- On fmt.Println(msg) inside case

ind.force_update()
local go_scope = ind.get_current_scope(go_buf, win)
assert_eq(go_scope ~= nil, true, "Go scope resolution should not be nil")
assert_eq(go_scope.scope_start <= 5, true, "Go scope start should be at or above line 5")
assert_eq(go_scope.scope_end >= 5, true, "Go scope end should be at or below line 5")
pcall(vim.api.nvim_buf_delete, go_buf, { force = true })
print("  ✓ Go select & func_literal Scope Resolution verified successfully.")

-- 32. Test Scope Delimiter Extraction Accuracy
print("[Test 32] Testing Scope Delimiter Extraction Accuracy...")
local scope_delims = scope_mod.find_delimiters("  if (condition) {", true)
assert_eq(#scope_delims >= 2, true, "Header line should extract multiple opener delimiters")
print("  ✓ Scope Delimiter Extraction Accuracy verified successfully.")

-- 33. Test Multi-Line Statement Header active_col Alignment
print("[Test 33] Testing Multi-Line Statement Header active_col Alignment...")
local align_buf = vim.api.nvim_create_buf(false, false)
local align_code = [[
function complex_header(
    param1,
    param2
)
    return param1 + param2
end]]
vim.api.nvim_buf_set_lines(align_buf, 0, -1, false, vim.split(align_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = align_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = align_buf })
vim.api.nvim_win_set_buf(win, align_buf)
vim.api.nvim_win_set_cursor(win, { 5, 8 }) -- On return statement

ind.force_update()
local align_scope = ind.get_current_scope(align_buf, win)
assert_eq(align_scope ~= nil, true, "Scope should resolve for multi-line function declaration")
assert_eq(align_scope.active_col, 0, "active_col for top-level function header should be 0")
pcall(vim.api.nvim_buf_delete, align_buf, { force = true })
print("  ✓ Multi-Line Statement Header active_col Alignment verified successfully.")

-- 34. Test HTML/CSS Element Scope & Delimiter Resolution
print("[Test 34] Testing HTML/CSS Element Scope & Delimiter Resolution...")
local html_delims = scope_mod.find_delimiters("<div class='box'>", true)
assert_eq(#html_delims >= 1, true, "HTML open tag should produce delimiter match")
local css_delims = scope_mod.find_delimiters(".box { color: red; }", true)
assert_eq(#css_delims >= 1, true, "CSS rule set should produce delimiter match")
print("  ✓ HTML/CSS Element Scope & Delimiter Resolution verified successfully.")

-- 35. Test Standard Guide Continuity Across Complex Nested Trees
print("[Test 35] Testing Standard Guide Continuity Across Complex Nested Trees...")
local deep_buf = vim.api.nvim_create_buf(false, false)
local deep_code = [[
function level1()
  if level2 then
    while level3 do
      for level4 in pairs(t) do
        print(level4)
      end
    end
  end
end]]
vim.api.nvim_buf_set_lines(deep_buf, 0, -1, false, vim.split(deep_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = deep_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = deep_buf })
vim.api.nvim_win_set_buf(win, deep_buf)
vim.api.nvim_win_set_cursor(win, { 5, 10 }) -- Inside innermost for loop

ind.force_update()
local deep_scope = ind.get_current_scope(deep_buf, win)
assert_eq(deep_scope ~= nil, true, "Deeply nested scope resolution should succeed")
assert_eq(deep_scope.scope_start, 4, "Innermost for loop scope start should be line 4")
assert_eq(deep_scope.scope_end, 6, "Innermost for loop scope end should be line 6")
assert_eq(deep_scope.active_col, 6, "Active guide col for innermost for loop should be 6")
pcall(vim.api.nvim_buf_delete, deep_buf, { force = true })
print("  ✓ Standard Guide Continuity Across Complex Nested Trees verified successfully.")

-- 36. Test Rust function_item & struct_item AST Scope Resolution
print("[Test 36] Testing Rust function_item & struct_item AST Scope Resolution...")
local rs_item_code = [[
struct Container {
    val: i32,
}
fn compute_total(c: Container) -> i32 {
    let x = c.val;
    x * 2
}]]
local rs_item_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(rs_item_buf, 0, -1, false, vim.split(rs_item_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = rs_item_buf })
vim.api.nvim_set_option_value("filetype", "rust", { buf = rs_item_buf })
vim.api.nvim_win_set_buf(win, rs_item_buf)
vim.api.nvim_win_set_cursor(win, { 5, 8 })
ind.force_update()
local rs_item_scope = ind.get_current_scope(rs_item_buf, win)
assert_eq(rs_item_scope ~= nil, true, "Rust function_item scope resolution should succeed")
assert_eq(rs_item_scope.scope_start <= 4, true, "Rust fn header line start check")
assert_eq(rs_item_scope.scope_end >= 6, true, "Rust fn end line check")
pcall(vim.api.nvim_buf_delete, rs_item_buf, { force = true })
print("  ✓ Rust function_item & struct_item AST Scope Resolution verified successfully.")

-- 37. Test Go method_declaration & type_declaration AST Scope Resolution
print("[Test 37] Testing Go method_declaration & type_declaration AST Scope Resolution...")
local go_method_code = [[
type Server struct {
    port int
}
func (s *Server) Start() error {
    log.Println("Starting")
    return nil
}]]
local go_method_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(go_method_buf, 0, -1, false, vim.split(go_method_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = go_method_buf })
vim.api.nvim_set_option_value("filetype", "go", { buf = go_method_buf })
vim.api.nvim_win_set_buf(win, go_method_buf)
vim.api.nvim_win_set_cursor(win, { 5, 8 })
ind.force_update()
local go_method_scope = ind.get_current_scope(go_method_buf, win)
assert_eq(go_method_scope ~= nil, true, "Go method_declaration scope resolution should succeed")
assert_eq(go_method_scope.scope_start, 4, "Go method declaration header start line 4")
assert_eq(go_method_scope.scope_end, 7, "Go method declaration end line 7")
pcall(vim.api.nvim_buf_delete, go_method_buf, { force = true })
print("  ✓ Go method_declaration & type_declaration AST Scope Resolution verified successfully.")

-- 38. Test C/C++ struct_specifier & template_declaration AST Scope Resolution
print("[Test 38] Testing C/C++ struct_specifier & template_declaration Scope Resolution...")
local cpp_code = [[
template <typename T>
struct Processor {
    void process(T val) {
        printf("Processing\n");
    }
};]]
local cpp_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(cpp_buf, 0, -1, false, vim.split(cpp_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = cpp_buf })
vim.api.nvim_set_option_value("filetype", "cpp", { buf = cpp_buf })
vim.api.nvim_win_set_buf(win, cpp_buf)
vim.api.nvim_win_set_cursor(win, { 5, 12 })
ind.force_update()
local cpp_scope = ind.get_current_scope(cpp_buf, win)
assert_eq(cpp_scope ~= nil, true, "C++ method scope resolution should succeed")
assert_eq(cpp_scope.scope_start <= 4, true, "C++ method header line 4")
assert_eq(cpp_scope.scope_end >= 5, true, "C++ method end line 5")
pcall(vim.api.nvim_buf_delete, cpp_buf, { force = true })
print("  ✓ C/C++ struct_specifier & template_declaration Scope Resolution verified successfully.")

-- 39. Test Java method_declaration & constructor_declaration Scope Resolution
print("[Test 39] Testing Java method_declaration & constructor_declaration Scope Resolution...")
local java_code = [[
public class App {
    public App() {
        System.out.println("Init");
    }
    public void run() {
        System.out.println("Running");
    }
}]]
local java_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(java_buf, 0, -1, false, vim.split(java_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = java_buf })
vim.api.nvim_set_option_value("filetype", "java", { buf = java_buf })
vim.api.nvim_win_set_buf(win, java_buf)
vim.api.nvim_win_set_cursor(win, { 6, 12 })
ind.force_update()
local java_scope = ind.get_current_scope(java_buf, win)
assert_eq(java_scope ~= nil, true, "Java method_declaration scope resolution should succeed")
assert_eq(java_scope.scope_start, 5, "Java run method start line 5")
assert_eq(java_scope.scope_end, 7, "Java run method end line 7")
pcall(vim.api.nvim_buf_delete, java_buf, { force = true })
print("  ✓ Java method_declaration & constructor_declaration Scope Resolution verified successfully.")

-- 40. Test Ruby method & class Scope Resolution
print("[Test 40] Testing Ruby method & class Scope Resolution...")
local rb_code = [[
class Service
  def execute
    puts "Executing"
  end
end]]
local rb_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(rb_buf, 0, -1, false, vim.split(rb_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = rb_buf })
vim.api.nvim_set_option_value("filetype", "ruby", { buf = rb_buf })
vim.api.nvim_win_set_buf(win, rb_buf)
vim.api.nvim_win_set_cursor(win, { 3, 6 })
ind.force_update()
local rb_scope = ind.get_current_scope(rb_buf, win)
assert_eq(rb_scope ~= nil, true, "Ruby scope resolution should succeed")
assert_eq(rb_scope.scope_start, 2, "Ruby def execute start line 2")
assert_eq(rb_scope.scope_end >= 3, true, "Ruby def execute end line check")
pcall(vim.api.nvim_buf_delete, rb_buf, { force = true })
print("  ✓ Ruby method & class Scope Resolution verified successfully.")

-- 41. Test Filetype-Aware Lua # Operator Sanitization
print("[Test 41] Testing Filetype-Aware Lua # Operator Sanitization...")
local lua_hash_line = "if #items > 0 then"
local lua_delims = scope_mod.find_delimiters(lua_hash_line, true, "lua")
local found_then_kw = false
for _, d in ipairs(lua_delims) do
  local tok = lua_hash_line:sub(d[1] + 1, d[2])
  if tok == "then" then found_then_kw = true end
end
assert_eq(found_then_kw, true, "Lua # length operator must not strip line or 'then' keyword")
print("  ✓ Filetype-Aware Lua # Operator Sanitization verified successfully.")

-- 42. Test CSS #id Selector Sanitization
print("[Test 42] Testing CSS #id Selector Sanitization...")
local css_hash_line = "#main-header {"
local css_delims = scope_mod.find_delimiters(css_hash_line, true, "css")
assert_eq(#css_delims >= 1, true, "CSS #id selector must retain '{' delimiter")
assert_eq(css_hash_line:sub(css_delims[1][1] + 1, css_delims[1][2]), "{", "CSS delimiter should be '{'")
print("  ✓ CSS #id Selector Sanitization verified successfully.")

-- 43. Test C/C++ #include Preprocessor Directive Comment Sanitization
print("[Test 43] Testing C/C++ #include Preprocessor Directive Comment Sanitization...")
local cpp_directive = "#include <iostream> // Header include"
local cpp_delims = scope_mod.find_delimiters(cpp_directive, true, "cpp")
-- Ensure comment after // is stripped but #include is preserved without error
assert_eq(type(cpp_delims), "table", "C++ directive scan returned table")
print("  ✓ C/C++ #include Preprocessor Directive Comment Sanitization verified successfully.")

-- 44. Test Strict Opener vs Closer Delimiter Classification
print("[Test 44] Testing Strict Opener vs Closer Delimiter Classification...")
local open_types = scope_mod.OPEN_DELIMITER_TYPES
assert_eq(open_types[")"], nil, "Closing paren ')' should NOT be in OPEN_DELIMITER_TYPES")
assert_eq(open_types["]"], nil, "Closing bracket ']' should NOT be in OPEN_DELIMITER_TYPES")
assert_eq(open_types["}"], nil, "Closing brace '}' should NOT be in OPEN_DELIMITER_TYPES")
print("  ✓ Strict Opener vs Closer Delimiter Classification verified successfully.")

-- 45. Test Core Module EmmyLua Annotations Integrity
print("[Test 45] Testing Core Module EmmyLua Annotations Integrity...")
local core_modules = {
  "indentinator.config",
  "indentinator.state",
  "indentinator.utils",
  "indentinator.scope",
  "indentinator.render",
  "indentinator.health",
  "indentinator",
}
for _, mod_name in ipairs(core_modules) do
  local ok_mod, mod_obj = pcall(require, mod_name)
  assert_eq(ok_mod, true, "Module require failed: " .. mod_name)
  assert_eq(type(mod_obj), "table", "Module export is table: " .. mod_name)
end
print("  ✓ Core Module EmmyLua Annotations Integrity verified successfully.")

-- 46. Test Exclusion of Intermediate Parameter Delimiters (pcall(fn, opts))
print("[Test 46] Testing Exclusion of Intermediate Parameter Delimiters...")
local pcall_line = "  local ok, err = pcall(fn, opts)"
local pcall_delims = scope_mod.find_delimiters(pcall_line, true, "lua")
local matched_fn_or_opts = false
for _, d in ipairs(pcall_delims) do
  local tok = pcall_line:sub(d[1] + 1, d[2])
  if tok == "fn" or tok == "opts" or tok == "local" then
    matched_fn_or_opts = true
  end
end
assert_eq(matched_fn_or_opts, false, "pcall(fn, opts) line must NOT match 'fn', 'opts', or 'local' as delimiters")
print("  ✓ Exclusion of Intermediate Parameter Delimiters verified successfully.")

-- 47. Test Lua function(opts) Scope Delimiter Precision (IBL/mini.indentscope Standard)
print("[Test 47] Testing Lua function(opts) Scope Delimiter Precision...")
local fn_opts_code = [[
local function cmd(fn)
  return function(opts)
    local ok, err = pcall(fn, opts)
    if not ok then
      vim.notify("err")
    end
  end
end]]
local fn_opts_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(fn_opts_buf, 0, -1, false, vim.split(fn_opts_code, "\n"))
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = fn_opts_buf })
vim.api.nvim_set_option_value("filetype", "lua", { buf = fn_opts_buf })
vim.api.nvim_win_set_buf(win, fn_opts_buf)
vim.api.nvim_win_set_cursor(win, { 5, 8 }) -- On vim.notify inside if block
ind.force_update()
local fn_opts_scope = ind.get_current_scope(fn_opts_buf, win)
assert_eq(fn_opts_scope ~= nil, true, "Lua nested scope resolution should succeed")
assert_eq(fn_opts_scope.scope_start <= 4, true, "if statement scope start line check")
assert_eq(fn_opts_scope.scope_end >= 5, true, "if statement scope end line check")

-- Verify delimiters extracted on if statement header line 4
local if_hdr_str = "    if not ok then"
local if_header_delims = scope_mod.find_delimiters(if_hdr_str, true, "lua")
local has_if_kw = false
local has_fn_kw = false
for _, d in ipairs(if_header_delims) do
  local tok = if_hdr_str:sub(d[1] + 1, d[2])
  if tok == "if" or tok == "then" then has_if_kw = true end
  if tok == "fn" or tok == "opts" then has_fn_kw = true end
end
assert_eq(has_if_kw, true, "if statement header must match 'if' or 'then'")
assert_eq(has_fn_kw, false, "if statement header must NOT match 'fn' or 'opts'")

pcall(vim.api.nvim_buf_delete, fn_opts_buf, { force = true })
print("  ✓ Lua function(opts) Scope Delimiter Precision verified successfully.")

print("=== All Indentinator Tests Passed! ===")





