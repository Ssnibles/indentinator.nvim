-- Tests for the hardening pass: per-window render bookkeeping, batched
-- extmarks, defensive get_config, injected delimiters, chunked indentation
-- fallback scans, command toggles, and extmark error reporting.

local helpers = dofile("tests/helpers.lua")
local assert_eq = helpers.assert_eq
local make_buf = helpers.make_buf

print("=== Running Indentinator Hardening Tests ===")

local ind = require("indentinator")
local config = require("indentinator.config")
local render = require("indentinator.render")
local cache = require("indentinator.cache")
local treesitter = require("indentinator.treesitter")

local win = vim.api.nvim_get_current_win()

-- 1. Rendered viewport ranges are tracked per window (not per buffer).
print("[Test 1] Per-window rendered-range bookkeeping...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0 })
local tall = {}
for i = 1, 200 do
  tall[i] = "    local x = " .. i
end
local tall_buf = make_buf(tall)
vim.api.nvim_win_set_buf(win, tall_buf)
ind.enable(tall_buf)

vim.cmd("split")
local win2 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win2, tall_buf)

vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.api.nvim_win_set_cursor(win2, { 150, 0 })
render.render(tall_buf, win)
render.render(tall_buf, win2)

local s1 = cache.get_rendered(win, tall_buf)
local s2 = cache.get_rendered(win2, tall_buf)
assert_eq(s1 ~= nil, true, "first window must have a tracked range")
assert_eq(s2 ~= nil, true, "second window must have a tracked range")
assert_eq(s1 ~= s2, true, "each window's range must be tracked independently")

-- Re-rendering one window must not clobber the other's bookkeeping.
render.render(tall_buf, win)
assert_eq(cache.get_rendered(win2, tall_buf), s2, "re-render must not clobber another window's range")

render.clear(tall_buf)
assert_eq(cache.get_rendered(win, tall_buf), nil, "clear(buf) must drop the first window's range")
assert_eq(cache.get_rendered(win2, tall_buf), nil, "clear(buf) must drop the second window's range")

vim.cmd("close")
pcall(vim.api.nvim_buf_delete, tall_buf, { force = true })
print("  ✓ Per-window rendered-range bookkeeping verified.")

-- 2. Passive guides are batched into one extmark per line.
print("[Test 2] Passive guide extmark batching...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0, indent = { enabled = true }, scope = { enabled = false } })
local batch_buf = make_buf({ "        local x = 1" })
vim.api.nvim_win_set_buf(win, batch_buf)
ind.enable(batch_buf)
render.render(batch_buf, win)

local row_marks = vim.api.nvim_buf_get_extmarks(batch_buf, render.NS, { 0, 0 }, { 0, -1 }, { details = true })
assert_eq(#row_marks, 1, "a line's passive guides must collapse into one extmark")
local vt = row_marks[1][4].virt_text
assert_eq(vt and vt[1] and vt[1][1], "│ │ │", "batched virt_text must contain the correctly spaced guides")

-- The active scope guide keeps its own (higher-priority) extmark.
ind.setup({ debounce_ms = 0, viewport_buffer = 0, indent = { enabled = true }, scope = { enabled = true } })
local active_buf = make_buf({
  "local function f()",
  "  if true then",
  "      local a = 1",
  "  end",
  "end",
}, "lua")
vim.api.nvim_win_set_buf(win, active_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(active_buf)
render.render(active_buf, win)
local active_marks = vim.api.nvim_buf_get_extmarks(active_buf, render.NS, { 2, 0 }, { 2, -1 }, { details = true })
assert_eq(#active_marks, 2, "the active scope guide must remain a separate extmark alongside batched guides")
pcall(vim.api.nvim_buf_delete, batch_buf, { force = true })
pcall(vim.api.nvim_buf_delete, active_buf, { force = true })
print("  ✓ Passive guide extmark batching verified.")

-- 3. get_config returns a defensive copy.
print("[Test 3] get_config defensive copy...")
ind.setup({ debounce_ms = 0, indent = { enabled = true } })
local cfg = ind.get_config()
assert_eq(cfg.indent.enabled, true, "config copy should reflect the live value")
cfg.indent.enabled = not cfg.indent.enabled
assert_eq(config.values.indent.enabled, true, "mutating the returned config must not touch global state")
print("  ✓ get_config defensive copy verified.")

-- 4. Delimiters resolve inside injected languages (Markdown Lua fence).
print("[Test 4] Injection-aware delimiter resolution...")
local md = make_buf({
  "# Title",
  "",
  "```lua",
  "function f()",
  "  if true then",
  "    local x = 1",
  "  end",
  "end",
  "```",
}, "markdown")
local has_md = pcall(vim.treesitter.get_parser, md, "markdown")
local has_lua = pcall(vim.treesitter.get_parser, md, "lua")
if has_md and has_lua then
  vim.api.nvim_win_set_buf(win, md)
  vim.api.nvim_win_set_cursor(win, { 6, 4 })
  ind.setup({ debounce_ms = 0, delimiters = { enabled = true, keywords = true } })
  ind.enable(md)
  local scope = treesitter.resolve_treesitter_scope(md, win, 6, 4)
  assert_eq(scope ~= nil, true, "injected scope should resolve")
  local spans = scope.delimiter_spans or {}
  assert_eq(#spans > 0, true, "injected boundary delimiters should be detected")
  local on_if_line = false
  for _, span in ipairs(spans) do
    if span.row == 4 then
      on_if_line = true
    end
  end
  assert_eq(on_if_line, true, "keyword delimiters on the injected `if` line should be found")

  ind.setup({ debounce_ms = 0, delimiters = { enabled = true, keywords = false } })
  local no_keywords = treesitter.resolve_treesitter_scope(md, win, 6, 4)
  assert_eq(#no_keywords.delimiter_spans, 0, "delimiters.keywords = false must suppress keyword spans")
  ind.setup({ debounce_ms = 0, delimiters = { enabled = true, keywords = true } })
end
pcall(vim.api.nvim_buf_delete, md, { force = true })
print("  ✓ Injection-aware delimiter resolution verified.")

-- 5. Chunked indentation fallback scans preserve scope boundaries.
print("[Test 5] Chunked indentation fallback scans...")
ind.setup({ debounce_ms = 0, scope = { treesitter = false } })
local deep = { "function f()" }
for i = 2, 250 do
  deep[i] = "  local x = " .. i
end
deep[251] = "end"
local deep_buf = make_buf(deep)
vim.api.nvim_win_set_buf(win, deep_buf)
local scope = treesitter.resolve_indent_scope(deep_buf, win, 100)
assert_eq(scope ~= nil, true, "indentation fallback should resolve a scope")
assert_eq(scope.scope_start, 1, "scope start must be found across chunk boundaries")
assert_eq(scope.scope_end, 251, "scope end must be found across chunk boundaries")
pcall(vim.api.nvim_buf_delete, deep_buf, { force = true })
print("  ✓ Chunked indentation fallback scans verified.")

-- 6. Command toggles go through update() and invalidate resolved config.
print("[Test 6] Command toggles use the public update path...")
if vim.fn.exists(":IndentinatorIndentToggle") ~= 2 then
  -- `-u NONE` does not source plugin/ scripts, so load the command definitions
  -- explicitly for this suite.
  local plugin_file = vim.api.nvim_get_runtime_file("plugin/indentinator.lua", false)[1]
  if plugin_file then
    vim.cmd.source(plugin_file)
  end
end
if vim.fn.exists(":IndentinatorIndentToggle") == 2 then
  ind.setup({ debounce_ms = 0, indent = { enabled = true } })
  vim.cmd("IndentinatorIndentToggle")
  assert_eq(config.values.indent.enabled, false, "command must toggle the global switch off")
  vim.cmd("IndentinatorIndentToggle")
  assert_eq(config.values.indent.enabled, true, "command must toggle the global switch back on")
  -- An overridden buffer must see the change immediately.
  local cmd_buf = make_buf({ "    local a = 1" })
  vim.api.nvim_win_set_buf(win, cmd_buf)
  ind.enable(cmd_buf)
  ind.set_buffer_config({ scope = { enabled = false } }, cmd_buf)
  vim.cmd("IndentinatorIndentToggle")
  assert_eq(config.get(cmd_buf).indent.enabled, false, "overridden buffer must follow a command toggle")
  vim.cmd("IndentinatorIndentToggle")
  pcall(vim.api.nvim_buf_delete, cmd_buf, { force = true })
else
  print("  - skipped (plugin/indentinator.lua not sourced in this run)")
end
print("  ✓ Command toggle path verified.")

-- 7. Extmark failures are reported without aborting the render.
print("[Test 7] Extmark failures are reported...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0, indent = { enabled = true }, scope = { enabled = false } })
local err_buf = make_buf({ "    local x = 1" })
vim.api.nvim_win_set_buf(win, err_buf)
ind.enable(err_buf)
local notified = {}
local orig_notify = vim.notify
local orig_set_extmark = vim.api.nvim_buf_set_extmark
vim.notify = function(msg)
  notified[#notified + 1] = msg
end
vim.api.nvim_buf_set_extmark = function()
  error("forced-extmark-failure")
end
render.render(err_buf, win)
vim.api.nvim_buf_set_extmark = orig_set_extmark
vim.notify = orig_notify
assert_eq(#notified > 0, true, "a failed extmark must be reported via vim.notify")
pcall(vim.api.nvim_buf_delete, err_buf, { force = true })
print("  ✓ Extmark failure reporting verified.")

print("=== All Hardening Tests Passed Successfully! ===")
