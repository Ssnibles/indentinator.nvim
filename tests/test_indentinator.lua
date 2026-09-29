-- Test suite for indentinator.nvim (scope corners, rainbow indent, debounced rendering)
-- Run via:
-- nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/test_indentinator.lua" -c "q"

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(
      string.format("%s: expected %s, got %s", msg or "Assertion failed", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

print("=== Running Indentinator Expanded Test Suite ===")

-- 1. Test Health Check
print("[Test 1] Testing Health Check Execution...")
local health = require("indentinator.health")
local ok, err = pcall(health.check)
assert_eq(ok, true, "Health check failed with error: " .. tostring(err))
print("  ✓ Health check completed successfully.")

-- 2. Test Setup and Nested Configuration
print("[Test 2] Testing Plugin Setup & Config Merging...")
local ind = require("indentinator")
ind.setup({
  debounce_ms = 15,
  indent = {
    enabled = true,
    char = "│",
    hl = "IndentinatorIndent",
    rainbow = {
      enabled = true,
      colors = { "#f38ba8", "#fab387", "#a6e3a1" },
    },
  },
  scope = {
    enabled = true,
    char = "│",
    char_top = "┌",
    char_bottom = "└",
    corners = true,
    hl = "IndentinatorScope",
    treesitter = true,
  },
  exclude = {
    filetypes = { "NvimTree" },
  },
})
assert_eq(ind.config.debounce_ms, 15, "Debounce ms failed to merge")
assert_eq(ind.config.indent.rainbow.enabled, true, "Rainbow enabled failed to merge")
assert_eq(ind.config.scope.char_top, "┌", "Scope char_top failed to merge")
print("  ✓ Plugin setup merged expanded configuration correctly.")

-- 3. Test Treesitter Scope Resolution on Lua Code
print("[Test 3] Testing Treesitter Scope Resolution on Lua Code...")
local sample_code = [[
function outer()
  if true then
      print("deep inside if line 3")
      print("deep inside if line 4")
  end
end
]]

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sample_code, "\n"))
vim.api.nvim_set_option_value("filetype", "lua", { buf = buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = buf })

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)

-- Move cursor inside the `if` block (Line 3)
vim.api.nvim_win_set_cursor(win, { 3, 7 })

ind.enable(buf)
local scope_info = ind.get_current_scope(buf, win)
assert_eq(scope_info ~= nil, true, "get_current_scope returned nil")
assert_eq(scope_info.scope_start, 2, "Expected Treesitter scope start line 2")
assert_eq(scope_info.scope_end, 5, "Expected Treesitter scope end line 5")
print("  ✓ Treesitter scope resolution verified successfully.")

-- 4. Test Scope Corners Rendering (Top & Bottom Boundaries)
print("[Test 4] Testing Scope Corners Boundary Rendering...")
ind.force_update()
local render = require("indentinator.render")

-- Line 3 is first scope body line (renders `┌`), line 4 is last scope body line (renders `└`)
local line3_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 2, 0 }, { 2, -1 }, { details = true })
local line4_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 3, 0 }, { 3, -1 }, { details = true })

assert_eq(#line3_marks > 0, true, "Line 3 (first scope body line) should have extmark")
assert_eq(line3_marks[1][4].virt_text[1][1], "┌", "Line 3 should render top corner '┌'")

assert_eq(#line4_marks > 0, true, "Line 4 (last scope body line) should have extmark")
assert_eq(line4_marks[1][4].virt_text[1][1], "└", "Line 4 should render bottom corner '└'")
print("  ✓ Scope corner boundaries verified successfully.")

-- 5. Test Rainbow Indent Colors
print("[Test 5] Testing Rainbow Indent Color Extmarks...")
-- Line 3 has 6 spaces indent -> col 4 is level 2 -> uses IndentinatorRainbow2
assert_eq(#line3_marks, 2, "Line 3 should have 2 extmarks")
assert_eq(
  line3_marks[2][4].virt_text[1][2],
  "IndentinatorRainbow2",
  "Col 4 normal indent should use IndentinatorRainbow2"
)
print("  ✓ Rainbow indent color extmarks verified successfully.")

-- 6. Test Buffer Lifecycle Cleanup
print("[Test 6] Testing Buffer Lifecycle Cleanup...")
local cleanup_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cleanup_buf, 0, -1, false, { "function test()", "  return 1", "end" })
ind.enable(cleanup_buf)
assert_eq(ind.is_enabled(cleanup_buf), true, "Buffer should be enabled")

vim.api.nvim_exec_autocmds("BufDelete", { buffer = cleanup_buf })
local cfg_mod = require("indentinator.config")
assert_eq(cfg_mod.buffer_values[cleanup_buf], nil, "BufDelete should clear per-buffer config")
pcall(vim.api.nvim_buf_delete, cleanup_buf, { force = true })
print("  ✓ Buffer lifecycle cleanup verified successfully.")

-- 7. Test Horizontal Scroll (leftcol) Positioning
print("[Test 7] Testing Horizontal Scroll (leftcol) Positioning...")
local scroll_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scroll_buf, 0, -1, false, {
  "function scroll_demo()",
  "        local deep = 1",
  "end",
})
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = scroll_buf })
vim.api.nvim_set_option_value("tabstop", 4, { buf = scroll_buf })
vim.api.nvim_win_set_buf(win, scroll_buf)
vim.api.nvim_win_set_cursor(win, { 2, 10 })
ind.enable(scroll_buf)

vim.fn.winrestview({ leftcol = 4 })
ind.force_update()

local scroll_marks = vim.api.nvim_buf_get_extmarks(scroll_buf, render.NS, 0, -1, { details = true })
assert_eq(#scroll_marks > 0, true, "Horizontal scroll should produce extmarks")
local scroll_win_col = scroll_marks[1][4].virt_text_win_col
assert_eq(scroll_win_col, 0, "virt_text_win_col should be adjusted for leftcol scroll")
print("  ✓ Horizontal scroll (leftcol) positioning verified.")

pcall(vim.api.nvim_buf_delete, scroll_buf, { force = true })

-- 8. Test Unindented Text Column 0 Protection
print("[Test 8] Testing Unindented Text Protection...")
local plain_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(plain_buf, 0, -1, false, {
  "result",
  ".log",
  "direnv/",
  ".envrc",
})
vim.api.nvim_win_set_buf(win, plain_buf)
vim.api.nvim_win_set_cursor(win, { 2, 0 })
ind.enable(plain_buf)
ind.force_update()

local plain_marks = vim.api.nvim_buf_get_extmarks(plain_buf, render.NS, 0, -1, {})
assert_eq(#plain_marks, 0, "Unindented text at active_col 0 should not have virtual text obscuring first character")
print("  ✓ Unindented text character protection verified successfully.")
pcall(vim.api.nvim_buf_delete, plain_buf, { force = true })

-- 9. Test Corner Style Presets ("round", "double", "bold")
print("[Test 9] Testing Corner Style Presets...")
ind.setup({
  scope = {
    corner_style = "round",
  },
})
assert_eq(ind.config.scope.char_top, "╭", "Round corner char_top failed")
assert_eq(ind.config.scope.char_bottom, "╰", "Round corner char_bottom failed")

ind.setup({
  scope = {
    corner_style = "double",
  },
})
assert_eq(ind.config.scope.char_top, "╔", "Double corner char_top failed")
assert_eq(ind.config.scope.char_bottom, "╚", "Double corner char_bottom failed")
print("  ✓ Corner style presets verified successfully.")

-- 10. Test Scope Motions (jump_to_scope_start, jump_to_scope_end, select_scope)
print("[Test 10] Testing Scope Motions & Text Objects...")
local motion_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(motion_buf, 0, -1, false, {
  "function motion_test()",
  "  if true then",
  "    local x = 1",
  "    local y = 2",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = motion_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = motion_buf })
vim.api.nvim_win_set_buf(win, motion_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(motion_buf)

local jumped_start = ind.jump_to_scope_start()
assert_eq(jumped_start, true, "jump_to_scope_start failed")
local pos_start = vim.api.nvim_win_get_cursor(win)
assert_eq(pos_start[1], 2, "Expected cursor line 2 after jump_to_scope_start")

vim.api.nvim_win_set_cursor(win, { 3, 4 })
local jumped_end = ind.jump_to_scope_end()
assert_eq(jumped_end, true, "jump_to_scope_end failed")
local pos_end = vim.api.nvim_win_get_cursor(win)
assert_eq(pos_end[1], 5, "Expected cursor line 5 after jump_to_scope_end")

vim.api.nvim_win_set_cursor(win, { 3, 4 })
local selected = ind.select_scope(true)
assert_eq(selected, true, "select_scope failed")
print("  ✓ Scope motions and text objects verified successfully.")
pcall(vim.api.nvim_buf_delete, motion_buf, { force = true })

-- 11. Test Scope Caching Layer
print("[Test 11] Testing Scope Memoization Cache...")
local cache_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cache_buf, 0, -1, false, {
  "function cache_demo()",
  "  if true then",
  "    local a = 1",
  "    local b = 2",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = cache_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = cache_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = cache_buf })
vim.api.nvim_win_set_buf(win, cache_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(cache_buf)

local s1 = ind.get_current_scope(cache_buf, win)
assert_eq(s1 ~= nil, true, "First get_current_scope failed")
local state_ref = require("indentinator.state")
assert_eq(state_ref.state.cache[cache_buf] ~= nil, true, "Cache entry should exist for cache_buf")

pcall(vim.api.nvim_buf_delete, cache_buf, { force = true })
print("  ✓ Scope memoization cache verified successfully.")

-- 12. Test Fine-Grained Blank Line Handling Policies
print("[Test 12] Testing Blank Line Policy Options...")
ind.setup({
  indent = { show_empty = false },
  scope = { show_empty = false },
})
assert_eq(ind.config.indent.show_empty, false, "indent.show_empty failed to merge")
assert_eq(ind.config.scope.show_empty, false, "scope.show_empty failed to merge")
print("  ✓ Blank line policy configuration verified successfully.")

-- 13. Test Rainbow Scope Lines, Delimiters Config & Scope Corner Uniformity
print("[Test 13] Testing Delimiters Configuration & Scope Corner Uniformity...")
local rainbow_test_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(rainbow_test_buf, 0, -1, false, {
  "function scope_rainbow_test()",
  "  if (true) then",
  "    print('hello line 1')",
  "    print('hello line 2')",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = rainbow_test_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = rainbow_test_buf })
vim.api.nvim_win_set_buf(win, rainbow_test_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(rainbow_test_buf)

-- Case A: scope.rainbow = true, delimiters.bold = true, delimiters.italic = true, delimiters.underline = true
ind.setup({
  scope = {
    enabled = true,
    rainbow = true,
  },
  delimiters = {
    enabled = true,
    rainbow = false,
    bold = true,
    italic = true,
    underline = true,
  },
})
ind.force_update()

local marks_a_corner = vim.api.nvim_buf_get_extmarks(
  rainbow_test_buf,
  render.NS,
  { 2, 0 },
  { 2, -1 },
  { details = true }
)
assert_eq(#marks_a_corner > 0, true, "Extmarks should exist for line 3")
assert_eq(
  marks_a_corner[1][4].virt_text[1][2],
  "IndentinatorRainbow1",
  "Scope line & top corner should use IndentinatorRainbow1 when scope.rainbow=true"
)

local delim_hl_info = vim.api.nvim_get_hl(0, { name = "IndentinatorDelimiter" })
assert_eq(delim_hl_info.bold, true, "IndentinatorDelimiter should have bold=true")
assert_eq(delim_hl_info.italic, true, "IndentinatorDelimiter should have italic=true")
assert_eq(delim_hl_info.underline, true, "IndentinatorDelimiter should have underline=true")

-- Case B: scope.rainbow = false, delimiters.rainbow = true
-- (Corners MUST match scope line IndentinatorScope, NOT delimiters!)
ind.setup({
  scope = {
    enabled = true,
    rainbow = false,
  },
  delimiters = {
    enabled = true,
    rainbow = true,
  },
})
ind.force_update()

-- Line 2 (0-indexed 1) is scope_start with delimiters `(`, `)`, `{`
local marks_b_start = vim.api.nvim_buf_get_extmarks(
  rainbow_test_buf,
  render.NS,
  { 1, 0 },
  { 1, -1 },
  { details = true }
)
-- Line 3 (0-indexed 2) is first body line with top corner `┌`
local marks_b_topcorner = vim.api.nvim_buf_get_extmarks(
  rainbow_test_buf,
  render.NS,
  { 2, 0 },
  { 2, -1 },
  { details = true }
)

local delim_hl = nil
for _, m in ipairs(marks_b_start) do
  if m[4].hl_group then
    delim_hl = m[4].hl_group
  end
end

assert_eq(
  delim_hl,
  "IndentinatorDelimiter1",
  "Delimiter bracket should use IndentinatorDelimiter1 when delimiters.rainbow=true"
)
assert_eq(
  marks_b_topcorner[1][4].virt_text[1][2],
  "IndentinatorScope",
  "Top corner MUST use IndentinatorScope when scope.rainbow=false"
)
print("  ✓ Delimiters config (bold, italic, underline, rainbow) & scope corner uniformity verified successfully.")

pcall(vim.api.nvim_buf_delete, rainbow_test_buf, { force = true })

-- 14. Test Treesitter Keyword Scope Delimiters
print("[Test 14] Testing Treesitter Keyword Scope Delimiters...")
local ts_kw_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(ts_kw_buf, 0, -1, false, {
  "function keyword_demo()",
  "  local text_data = 'if then end' -- comment with while and for",
  "  if true then",
  "    print(text_data)",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = ts_kw_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = ts_kw_buf })
vim.api.nvim_win_set_buf(win, ts_kw_buf)
vim.api.nvim_win_set_cursor(win, { 4, 4 })
ind.enable(ts_kw_buf)

ind.setup({
  scope = { enabled = true, treesitter = true },
  delimiters = { enabled = true, keywords = true, rainbow = true },
})
ind.force_update()

-- Line 3 (0-indexed 2) is `if true then` (scope_start for if statement)
local marks_if_line = vim.api.nvim_buf_get_extmarks(ts_kw_buf, render.NS, { 2, 0 }, { 2, -1 }, { details = true })
local if_kw_count = 0
for _, m in ipairs(marks_if_line) do
  if m[4].hl_group and m[4].hl_group:find("IndentinatorDelimiter") then
    if_kw_count = if_kw_count + 1
  end
end
assert_eq(
  if_kw_count >= 2,
  true,
  "Both 'if' and 'then' keywords on scope start boundary should receive delimiter extmarks"
)

-- Line 5 (0-indexed 4) is `end` (scope_end for block)
local marks_end_line = vim.api.nvim_buf_get_extmarks(ts_kw_buf, render.NS, { 4, 0 }, { 4, -1 }, { details = true })
local end_kw_count = 0
for _, m in ipairs(marks_end_line) do
  if m[4].hl_group and m[4].hl_group:find("IndentinatorDelimiter") then
    end_kw_count = end_kw_count + 1
  end
end
assert_eq(end_kw_count >= 1, true, "Treesitter keyword 'end' on scope boundary should receive delimiter extmark")

-- Line 2 (0-indexed 1) is `local text_data = 'if then end' -- comment with while and for`
local marks_str_line = vim.api.nvim_buf_get_extmarks(ts_kw_buf, render.NS, { 1, 0 }, { 1, -1 }, { details = true })
local str_kw_count = 0
for _, m in ipairs(marks_str_line) do
  if m[4].hl_group and m[4].hl_group:find("IndentinatorDelimiter") then
    str_kw_count = str_kw_count + 1
  end
end
assert_eq(str_kw_count, 0, "Keywords inside string/comment MUST NOT receive delimiter extmarks")
print("  ✓ Treesitter keyword scope delimiters verified successfully without string/comment false positives.")

pcall(vim.api.nvim_buf_delete, ts_kw_buf, { force = true })
pcall(vim.api.nvim_buf_delete, buf, { force = true })

-- 15. Test Hierarchical Multi-Level Scope Navigation
print("[Test 15] Testing Hierarchical Multi-Level Scope Navigation...")
local nest_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(nest_buf, 0, -1, false, {
  "function outer_fn()",
  "  if true then",
  "    local x = 1",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = nest_buf })
vim.api.nvim_win_set_buf(win, nest_buf)

-- Start on line 3 (local x = 1)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.jump_to_scope_start()
local j1 = vim.api.nvim_win_get_cursor(win)
assert_eq(j1[1], 2, "First jump_to_scope_start should land on line 2 (if true then)")

-- Repeat jump from line 2 (should climb to parent scope line 1)
ind.jump_to_scope_start()
local j2 = vim.api.nvim_win_get_cursor(win)
assert_eq(j2[1], 1, "Second jump_to_scope_start should climb to parent scope line 1 (outer_fn)")

-- Repeat jump downward
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.jump_to_scope_end()
local je1 = vim.api.nvim_win_get_cursor(win)
assert_eq(je1[1], 4, "First jump_to_scope_end should land on line 4 (end of if)")

-- Repeat jump from line 4 (should climb to parent scope line 5)
ind.jump_to_scope_end()
local je2 = vim.api.nvim_win_get_cursor(win)
assert_eq(je2[1], 5, "Second jump_to_scope_end should climb to parent scope line 5 (end of outer_fn)")

pcall(vim.api.nvim_buf_delete, nest_buf, { force = true })
print("  ✓ Hierarchical multi-level scope navigation verified successfully.")

-- 16. Test Visual Mode Safety for select_scope
print("[Test 16] Testing Visual Mode Safety for select_scope...")
local vis_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(vis_buf, 0, -1, false, {
  "function vis_test()",
  "  if true then",
  "    local val = 123",
  "  end",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = vis_buf })
vim.api.nvim_win_set_buf(win, vis_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })

-- Enter visual line mode manually before calling select_scope
vim.cmd("normal! V")
local mode_before = vim.api.nvim_get_mode().mode
assert_eq(mode_before, "V", "Should be in Visual Line mode")
ind.select_scope(true)
local mode_after = vim.api.nvim_get_mode().mode
assert_eq(mode_after, "V", "select_scope must preserve Visual Line mode without toggling it off")

pcall(vim.api.nvim_buf_delete, vis_buf, { force = true })
print("  ✓ Visual mode safety for select_scope verified successfully.")

-- 17. Test Comment and String Bypassing in Treesitter Scope
print("[Test 17] Testing Comment & String Bypassing in Treesitter Scope...")
local cmt_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cmt_buf, 0, -1, false, {
  "function comment_scope()",
  "  -- Multi-line comment header",
  "  -- Second comment line",
  "  return 42",
  "end",
})
vim.api.nvim_set_option_value("filetype", "lua", { buf = cmt_buf })
vim.api.nvim_win_set_buf(win, cmt_buf)

-- Cursor on line 2 (comment)
vim.api.nvim_win_set_cursor(win, { 2, 5 })
local cmt_scope = ind.get_current_scope(cmt_buf, win)
assert_eq(cmt_scope ~= nil, true, "Scope should be detected from comment line")
assert_eq(cmt_scope.scope_start, 1, "Cursor in comment should resolve to enclosing function scope start (line 1)")
assert_eq(cmt_scope.scope_end, 5, "Cursor in comment should resolve to enclosing function scope end (line 5)")

pcall(vim.api.nvim_buf_delete, cmt_buf, { force = true })
print("  ✓ Comment and string bypassing in Treesitter scope verified successfully.")

-- 18. Test Indentation-based Scope Fallback Delimiter Accuracy
print("[Test 18] Testing Indentation-based Scope Fallback Delimiter Accuracy...")
local py_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(py_buf, 0, -1, false, {
  "def py_test():",
  "    if True:",
  "        x = 1",
  "        y = 2",
  "    subsequent_statement = True",
})
vim.api.nvim_set_option_value("shiftwidth", 4, { buf = py_buf })
vim.api.nvim_set_option_value("tabstop", 4, { buf = py_buf })
vim.api.nvim_win_set_buf(win, py_buf)
vim.api.nvim_win_set_cursor(win, { 3, 8 })

ind.setup({ scope = { treesitter = false } })
local py_scope = ind.get_current_scope(py_buf, win)
assert_eq(py_scope.scope_start, 2, "Python if block should start at line 2")
assert_eq(
  py_scope.scope_end,
  4,
  "Python if block should end at line 4 (must not swallow subsequent non-closing statement on line 5)"
)

-- Restore treesitter config
ind.setup({ scope = { treesitter = true } })
pcall(vim.api.nvim_buf_delete, py_buf, { force = true })
print("  ✓ Indentation fallback closing delimiter accuracy verified successfully.")

-- 19. Test Viewport Scrolling Ghost Mark Elimination
print("[Test 19] Testing Viewport Scrolling Ghost Mark Elimination...")
local scroll_clean_buf = vim.api.nvim_create_buf(false, true)
local long_lines = {}
for i = 1, 100 do
  long_lines[i] = "    local item = " .. i
end
vim.api.nvim_buf_set_lines(scroll_clean_buf, 0, -1, false, long_lines)
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = scroll_clean_buf })
vim.api.nvim_win_set_buf(win, scroll_clean_buf)
ind.enable(scroll_clean_buf)

-- Render viewport near top
vim.cmd("normal! 1G")
vim.cmd("redraw")
render.render(scroll_clean_buf, win)
local marks_top_before = vim.api.nvim_buf_get_extmarks(scroll_clean_buf, render.NS, { 0, 0 }, { 9, -1 }, {})
assert_eq(#marks_top_before > 0, true, "Lines 1..10 should have extmarks initially")

-- Scroll down so lines 1..10 are out of view
vim.cmd("normal! 60G")
vim.cmd("redraw")
render.render(scroll_clean_buf, win)
local marks_top_after = vim.api.nvim_buf_get_extmarks(scroll_clean_buf, render.NS, { 0, 0 }, { 9, -1 }, {})
assert_eq(#marks_top_after, 0, "Lines 1..10 must have zero extmarks after scrolling past them")

pcall(vim.api.nvim_buf_delete, scroll_clean_buf, { force = true })
print("  ✓ Viewport scrolling ghost mark elimination verified successfully.")

print("=== All Indentinator Tests Passed Successfully! ===")
