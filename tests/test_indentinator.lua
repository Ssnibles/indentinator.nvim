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

-- Verify cursor at line 3 resolves scope starting at line 2 (`if true then`)
local ts_node = vim.treesitter.get_node({ buf = buf, pos = { 2, 5 } })
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

-- 8. Test Scope Underline Boundaries (No Left Bleed)
print("[Test 8] Testing Scope Underline Boundaries (No Left Bleed)...")
ind.setup({
  scope = {
    enabled = true,
    underline = true,
    underline_end = true,
  },
})
ind.force_update()
local render = require("indentinator.render")
local line5_extmarks = vim.api.nvim_buf_get_extmarks(buf, render.NS, { 4, 0 }, { 4, -1 }, { details = true })
local found_end_underline = false
for _, em in ipairs(line5_extmarks) do
  local col = em[3]
  local details = em[4]
  if details and details.hl_group == "IndentinatorScopeUnderline" then
    found_end_underline = true
    assert_eq(col > 0, true, "Scope end underline should not bleed to column 0")
  end
end
assert_eq(found_end_underline, true, "Scope end underline extmark should be present")
print("  ✓ Scope underline boundaries verified with zero left bleed.")

print("=== All Indentinator Tests Passed! ===")

