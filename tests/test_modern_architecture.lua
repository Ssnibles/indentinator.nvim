-- Architecture and Performance Verification Test Suite for Indentinator.nvim
-- Verifies viewport-scoped extmark rendering and clearing, scope node boundary
-- caching, and low-latency cursor tracking.

local helpers = dofile("tests/helpers.lua")
local assert_eq = helpers.assert_eq

print("=== Running Modern Indentinator Architecture Tests ===")

local ind = require("indentinator")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")
local renderer = require("indentinator.renderer")

ind.setup({
  debounce_ms = 0,
  max_file_lines = 50,
  scope = {
    enabled = true,
    treesitter = true,
    corners = true,
  },
})

-- Test 1: Viewport Rendering & Namespace Clearing
print("[Modern Test 1] Testing Viewport Rendering & Namespace Clearing...")
local buf = vim.api.nvim_create_buf(false, true)
local sample = {
  "function test_decor()",
  "  if true then",
  "    local x = 1",
  "    local y = 2",
  "  end",
  "end",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample)
vim.api.nvim_set_option_value("filetype", "lua", { buf = buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = buf })

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(buf)
renderer.render(buf, win)

-- Enabling must paint guides for the visible viewport.
local viewport_marks = vim.api.nvim_buf_get_extmarks(buf, renderer.NS, 0, -1, {})
assert_eq(#viewport_marks > 0, true, "Enabling must render viewport guides")

-- Clearing the namespace must leave no residual marks (no ghost marks).
renderer.clear(buf)
local cleared_marks = vim.api.nvim_buf_get_extmarks(buf, renderer.NS, 0, -1, {})
assert_eq(#cleared_marks, 0, "clear() must remove all namespace extmarks")
print("  ✓ Viewport rendering & namespace clearing verified.")

-- Test 2: Node Boundary Caching (No Recalculation Within Scope)
print("[Modern Test 2] Testing Active Scope AST Node Boundary Caching...")
local s1 = treesitter.get_scope(buf, win, true)
assert_eq(s1 ~= nil, true, "Scope 1 resolution failed")

local cached_scope = cache.get_win_scope(win, buf)
assert_eq(cached_scope ~= nil, true, "Cached scope should exist")
assert_eq(cached_scope.scope_start, 2, "Expected if statement start at line 2")
assert_eq(cached_scope.scope_end, 5, "Expected if statement end at line 5")

-- Cursor on line 3, col 4: inside scope
assert_eq(cache.is_cursor_in_scope(win, buf, 3, 4), true, "Cursor at line 3 should be in scope")

-- Cursor moves to line 4, col 6: STILL inside if statement, no child scopes
assert_eq(cache.is_cursor_in_scope(win, buf, 4, 6), true, "Cursor at line 4 should be in scope")

-- Cursor moves outside if statement to line 1 (function header)
assert_eq(cache.is_cursor_in_scope(win, buf, 1, 0), false, "Cursor at line 1 must exit if scope")

-- Cursor moves outside to line 6 (end of function)
assert_eq(cache.is_cursor_in_scope(win, buf, 6, 0), false, "Cursor at line 6 must exit if scope")
print("  ✓ Node boundary caching verified.")

-- Test 3: Nested Child Scope Boundary Detection
print("[Modern Test 3] Testing Nested Child Scope Boundary Detection...")
local nest_buf = vim.api.nvim_create_buf(false, true)
local nest_code = {
  "function nest()",
  "  local a = 1",
  "  if true then",
  "    local b = 2",
  "  end",
  "  local c = 3",
  "end",
}
vim.api.nvim_buf_set_lines(nest_buf, 0, -1, false, nest_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = nest_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = nest_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = nest_buf })
vim.api.nvim_win_set_buf(win, nest_buf)

-- Cursor on line 2 (local a = 1) -> active scope is outer function (lines 1..7)
vim.api.nvim_win_set_cursor(win, { 2, 2 })
local fn_scope_start, fn_scope_end = treesitter.get_scope(nest_buf, win, true)
assert_eq(fn_scope_start, 1, "Outer scope start should be line 1")
assert_eq(fn_scope_end, 7, "Outer scope end should be line 7")

-- Cursor moves to line 6 (local c = 3) -> STILL in function scope, not in nested if
assert_eq(cache.is_cursor_in_scope(win, nest_buf, 6, 2), true, "Cursor at line 6 should remain in function scope")

-- Cursor moves into nested if block on line 4 (local b = 2) -> must detect child scope entry
assert_eq(
  cache.is_cursor_in_scope(win, nest_buf, 4, 4),
  false,
  "Cursor inside child if block must trigger scope re-resolution"
)

vim.api.nvim_win_set_cursor(win, { 4, 4 })
local if_scope_start, if_scope_end = treesitter.get_scope(nest_buf, win, true)
assert_eq(if_scope_start, 3, "Nested scope start should be line 3")
assert_eq(if_scope_end, 5, "Nested scope end should be line 5")

pcall(vim.api.nvim_buf_delete, nest_buf, { force = true })
print("  ✓ Nested child scope boundary detection verified.")

-- Test 4: Buffer Modification (on_bytes) Cache Invalidation
print("[Modern Test 4] Testing on_bytes Invalidation & Incremental Parse...")
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
treesitter.get_scope(buf, win, true)
assert_eq(cache.is_dirty(buf), false, "Buffer should be clean after scope resolution")

-- Simulate on_bytes by appending a line
vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "    local injected = true" })
assert_eq(cache.is_dirty(buf), true, "Buffer must be marked dirty on edit")
assert_eq(cache.is_cursor_in_scope(win, buf, 3, 4), false, "Dirty buffer must invalidate cached scope")

pcall(vim.api.nvim_buf_delete, buf, { force = true })
print("  ✓ Buffer modification on_bytes invalidation verified.")

-- Test 5: Graceful Handling for Large Files (max_file_lines threshold)
print("[Modern Test 5] Testing Graceful Large File Degradation...")
local big_buf = vim.api.nvim_create_buf(false, true)
local big_lines = {}
for i = 1, 60 do -- max_file_lines is 50
  big_lines[i] = "    local x = " .. i
end
vim.api.nvim_buf_set_lines(big_buf, 0, -1, false, big_lines)
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = big_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = big_buf })
vim.api.nvim_win_set_buf(win, big_buf)
ind.enable(big_buf)

assert_eq(vim.api.nvim_buf_line_count(big_buf) > ind.config.max_file_lines, true, "Big buffer exceeds max lines")
ind.force_update()
local big_marks = vim.api.nvim_buf_get_extmarks(big_buf, renderer.NS, 0, -1, {})
assert_eq(#big_marks, 0, "Exceeding max_file_lines must produce 0 extmarks")

pcall(vim.api.nvim_buf_delete, big_buf, { force = true })
print("  ✓ Graceful large file degradation verified.")

-- Test 6: Regression - stale marks cleared when a buffer grows past max_file_lines
print("[Modern Test 6] Testing Stale Mark Cleanup When Buffer Grows Past Limit...")
local grow_buf = vim.api.nvim_create_buf(false, true)
local small_lines = {}
for i = 1, 40 do -- below max_file_lines (50)
  small_lines[i] = "    local x = " .. i
end
vim.api.nvim_buf_set_lines(grow_buf, 0, -1, false, small_lines)
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = grow_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = grow_buf })
vim.api.nvim_win_set_buf(win, grow_buf)
ind.enable(grow_buf)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(grow_buf, renderer.NS, 0, -1, {}) > 0,
  true,
  "A buffer below max_file_lines should render guides"
)

-- Grow the buffer past the threshold; previous viewport marks must be cleared.
local grown_lines = {}
for i = 41, 80 do
  grown_lines[#grown_lines + 1] = "    local x = " .. i
end
vim.api.nvim_buf_set_lines(grow_buf, 40, -1, false, grown_lines)
assert_eq(vim.api.nvim_buf_line_count(grow_buf) > ind.config.max_file_lines, true, "Grown buffer exceeds max lines")
ind.force_update()
assert_eq(
  #vim.api.nvim_buf_get_extmarks(grow_buf, renderer.NS, 0, -1, {}),
  0,
  "Exceeding max_file_lines must clear previously rendered extmarks"
)

pcall(vim.api.nvim_buf_delete, grow_buf, { force = true })
print("  ✓ Stale mark cleanup past max_file_lines verified.")

print("=== All Modern Architecture Tests Passed Successfully! ===")
