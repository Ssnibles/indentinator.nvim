-- Regression tests for the config-cache, motion column mapping, buffer-attach,
-- and test-runner fixes.
-- Run via tests/run.sh (which uses `nvim -l` so failures exit non-zero).

local helpers = dofile("tests/helpers.lua")
local assert_eq = helpers.assert_eq
local make_buf = helpers.make_buf

print("=== Running Indentinator Regression Tests ===")

local ind = require("indentinator")
local config = require("indentinator.config")
local render = require("indentinator.render")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")

local win = vim.api.nvim_get_current_win()

-- 1. Global toggle commands must reach buffers that hold per-buffer overrides.
-- Regression: config.get() memoized the merged config and force_update() did not
-- invalidate it, so `:IndentinatorIndentToggle` (which mutates ind.config in
-- place) had no effect on overridden buffers.
print("[Test 1] Global toggles propagate to overridden buffers...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0, indent = { enabled = true }, scope = { enabled = true } })
local buf = make_buf({ "    local a = 1", "    local b = 2" })
vim.api.nvim_win_set_buf(win, buf)
ind.enable(buf)
-- An override that deliberately does not mention indent.enabled.
ind.set_buffer_config({ scope = { enabled = false } }, buf)
assert_eq(config.get(buf).indent.enabled, true, "indent should start enabled")

ind.config.indent.enabled = false
ind.force_update()
assert_eq(config.get(buf).indent.enabled, false, "in-place global toggle must invalidate the resolved config")
assert_eq(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}), 0, "no indent guides should remain")

ind.config.indent.enabled = true
ind.force_update()
assert_eq(config.get(buf).indent.enabled, true, "toggling back must take effect")
assert_eq(#vim.api.nvim_buf_get_extmarks(buf, render.NS, 0, -1, {}) > 0, true, "indent guides should be restored")

-- The public update() path must propagate too.
ind.update({ indent = { enabled = false } })
assert_eq(config.get(buf).indent.enabled, false, "update() must propagate to overridden buffers")
ind.update({ indent = { enabled = true } })
pcall(vim.api.nvim_buf_delete, buf, { force = true })
print("  ✓ Global toggle propagation verified.")

-- 2. Scope jump motions must convert display columns back to byte columns.
-- Regression: active_col is tab-expanded, but nvim_win_set_cursor expects a byte
-- column, so jumps on tab-indented buffers landed at end-of-line.
print("[Test 2] Tab-indented scope jumps use byte columns...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0 })
local tab_buf = make_buf({
  "\tlocal function f()",
  "\t\tif true then",
  "\t\t\tlocal x = 1",
  "\t\tend",
  "\tend",
}, "lua", { shiftwidth = 8, tabstop = 8, expandtab = false })
vim.api.nvim_win_set_buf(win, tab_buf)
vim.api.nvim_win_set_cursor(win, { 3, 5 })
ind.enable(tab_buf)

assert_eq(ind.jump_to_scope_start(), true, "jump_to_scope_start should succeed")
local cur = vim.api.nvim_win_get_cursor(win)
local line_text = vim.api.nvim_buf_get_lines(tab_buf, cur[1] - 1, cur[1], false)[1]
local lead = line_text:match("^%s*") or ""
assert_eq(cur[1], 2, "start jump should target the scope header line")
assert_eq(cur[2], #lead, "cursor column must be the byte length of the leading whitespace")
assert_eq(cur[2] < #line_text, true, "cursor must not be clamped to end-of-line")

vim.api.nvim_win_set_cursor(win, { 3, 5 })
assert_eq(ind.jump_to_scope_end(), true, "jump_to_scope_end should succeed")
cur = vim.api.nvim_win_get_cursor(win)
line_text = vim.api.nvim_buf_get_lines(tab_buf, cur[1] - 1, cur[1], false)[1]
lead = line_text:match("^%s*") or ""
assert_eq(cur[1], 4, "end jump should target the closing line")
assert_eq(cur[2], #lead, "bottom jump must use the byte column of the leading whitespace")
pcall(vim.api.nvim_buf_delete, tab_buf, { force = true })
print("  ✓ Tab-indented jump column mapping verified.")

-- 3. attach_buffer must only mark a buffer attached after a successful attach.
print("[Test 3] attach_buffer marks attached only on success...")
ind.setup({ debounce_ms = 0 })
local attach_buf = make_buf({ "    local a = 1" })
cache.clear_buf(attach_buf)
assert_eq(cache.is_attached(attach_buf), false, "fresh buffer should not be attached")

treesitter.attach_buffer(attach_buf)
assert_eq(cache.is_attached(attach_buf), true, "buffer should be attached after a successful attach")
treesitter.attach_buffer(attach_buf) -- idempotent: must not raise
assert_eq(cache.is_attached(attach_buf), true, "re-attaching must remain a no-op")

local fail_buf = make_buf({ "    local b = 1" })
cache.clear_buf(fail_buf)
local real_attach = vim.api.nvim_buf_attach
vim.api.nvim_buf_attach = function()
  error("simulated attach failure")
end
treesitter.attach_buffer(fail_buf)
vim.api.nvim_buf_attach = real_attach
assert_eq(cache.is_attached(fail_buf), false, "failed attach must not mark the buffer attached")

treesitter.attach_buffer(fail_buf)
assert_eq(cache.is_attached(fail_buf), true, "attach must be retried after a failure")
pcall(vim.api.nvim_buf_delete, attach_buf, { force = true })
pcall(vim.api.nvim_buf_delete, fail_buf, { force = true })
print("  ✓ Buffer attach failure handling verified.")

-- 4. The test runner must propagate suite failures as a non-zero exit code.
print("[Test 4] Test runner propagates suite failures...")
local progpath = vim.v.progpath
if progpath and progpath ~= "" then
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ 'error("intentional failure")' }, script)
  vim.fn.system({ progpath, "--headless", "-u", "NONE", "-l", script })
  local code = vim.v.shell_error
  vim.fn.delete(script)
  assert_eq(code ~= 0, true, "nvim -l must exit non-zero when the suite errors")
  print("  ✓ Test runner error propagation verified.")
else
  print("  - skipped (nvim progpath unavailable)")
end

print("=== All Regression Tests Passed Successfully! ===")
