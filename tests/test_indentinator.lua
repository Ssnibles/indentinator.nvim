-- Test suite for indentinator.nvim (scope & normal indent guide support)
-- Run via:
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

print("=== Running Indentinator Scope & Indent Guide Test Suite ===")

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
  indent = {
    enabled = true,
    char = "│",
    hl = "IndentinatorIndent",
  },
  scope = {
    enabled = true,
    char = "│",
    hl = "IndentinatorScope",
    treesitter = true,
  },
  exclude = {
    filetypes = { "NvimTree" },
  },
})
assert_eq(ind.config.indent.enabled, true, "Indent config enabled failed to merge")
assert_eq(ind.config.scope.treesitter, true, "Scope treesitter failed to merge")
assert_eq(ind.config.exclude.filetypes[1], "NvimTree", "Exclude filetypes failed to merge")
print("  ✓ Plugin setup merged nested configuration correctly.")

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

-- 4. Test Indentation Scope Fallback
print("[Test 4] Testing Indentation Scope Fallback...")
ind.setup({ scope = { treesitter = false } })
local indent_scope = ind.get_current_scope(buf, win)
assert_eq(indent_scope ~= nil, true, "Indentation scope fallback returned nil")
assert_eq(indent_scope.scope_start, 2, "Expected indentation scope start line 2")
assert_eq(indent_scope.scope_end, 5, "Expected indentation scope end line 5")
print("  ✓ Indentation scope fallback verified successfully.")

-- Re-enable treesitter for remaining tests
ind.setup({ scope = { treesitter = true } })

-- 5. Test Enable / Disable / Toggle Controls
print("[Test 5] Testing Enable, Disable, and Toggle Controls...")
assert_eq(ind.is_enabled(buf), true, "Buffer should be enabled")

ind.disable(buf)
assert_eq(ind.is_enabled(buf), false, "Buffer should be disabled")

local render = require("indentinator.render")
local disabled_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {})
assert_eq(#disabled_marks, 0, "Disabled buffer should have zero extmarks")

ind.toggle(buf)
assert_eq(ind.is_enabled(buf), true, "Toggled buffer should be re-enabled")
print("  ✓ Enable/disable/toggle controls verified successfully.")

-- 6. Test Multi-Level Indent & Scope Extmark Rendering
print("[Test 6] Testing Multi-Level Indent & Scope Rendering...")
ind.force_update()
local enabled_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, { details = true })
assert_eq(#enabled_marks > 0, true, "Active buffer should generate extmarks")

-- Check line 3 (has 6 spaces indent -> col 2 active scope, col 4 normal indent)
local line3_marks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 2, 0 }, { 2, -1 }, { details = true })
assert_eq(#line3_marks, 2, "Line 3 should have 2 extmarks (col 2 active scope, col 4 normal indent)")
assert_eq(line3_marks[1][4].virt_text_win_col, 2, "Col 2 should be first extmark")
assert_eq(line3_marks[2][4].virt_text_win_col, 4, "Col 4 should be second extmark")
assert_eq(line3_marks[1][4].virt_text[1][2], "IndentinatorScope", "Col 2 active scope should use IndentinatorScope")
assert_eq(line3_marks[2][4].virt_text[1][2], "IndentinatorIndent", "Col 4 normal indent should use IndentinatorIndent")
print("  ✓ Multi-level indent and scope extmarks verified successfully.")

-- 7. Test Buffer Lifecycle Cleanup
print("[Test 7] Testing Buffer Lifecycle Cleanup...")
local cleanup_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(cleanup_buf, 0, -1, false, { "function test()", "  return 1", "end" })
ind.enable(cleanup_buf)
assert_eq(ind.is_enabled(cleanup_buf), true, "Buffer should be enabled")

vim.api.nvim_exec_autocmds("BufDelete", { buffer = cleanup_buf })
local state_mod = require("indentinator.state")
assert_eq(state_mod.state.enabled[cleanup_buf], nil, "BufDelete should clear state entry")
pcall(vim.api.nvim_buf_delete, cleanup_buf, { force = true })
print("  ✓ Buffer lifecycle cleanup verified successfully.")

-- 8. Test Horizontal Scroll (leftcol) Positioning
print("[Test 8] Testing Horizontal Scroll (leftcol) Positioning...")
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

pcall(vim.api.nvim_buf_delete, scroll_buf, { force = true })

-- 9. Test Unindented Text Column 0 Protection
print("[Test 9] Testing Unindented Text Protection...")
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

pcall(vim.api.nvim_buf_delete, buf, { force = true })

print("=== All Indentinator Tests Passed Successfully! ===")
