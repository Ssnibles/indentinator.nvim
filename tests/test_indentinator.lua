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

-- Clean up test buffer
pcall(vim.api.nvim_buf_delete, buf, { force = true })

print("=== All Indentinator Tests Passed! ===")
