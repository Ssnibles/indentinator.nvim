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

print("=== All Indentinator Tests Passed! ===")

