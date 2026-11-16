-- Tests for per-buffer config, data-driven scope node overrides,
-- viewport_buffer rendering, and OptionSet re-rendering.
-- Run via tests/run.sh.

local helpers = dofile("tests/helpers.lua")
local assert_eq = helpers.assert_eq
local make_buf = helpers.make_buf

print("=== Running Indentinator New Feature Tests ===")

local ind = require("indentinator")
local render = require("indentinator.render")
local config = require("indentinator.config")

local win = vim.api.nvim_get_current_win()

-- 1. Per-buffer configuration overrides
print("[Test 1] Testing Per-Buffer Configuration Overrides...")
ind.setup({ debounce_ms = 0, viewport_buffer = 0, indent = { enabled = true }, scope = { enabled = true } })
local buf_a = make_buf({ "    local a = 1", "    local b = 2" })
local buf_b = make_buf({ "    local a = 1", "    local b = 2" })

assert_eq(config.get(buf_a).indent.enabled, true, "Global config should apply to buf_a by default")
ind.set_buffer_config({ indent = { enabled = false }, scope = { enabled = false } }, buf_a)
assert_eq(config.get(buf_a).indent.enabled, false, "Buffer override should disable indent for buf_a")
assert_eq(config.get(buf_a).scope.enabled, false, "Buffer override should disable scope for buf_a")
assert_eq(config.get(buf_b).indent.enabled, true, "buf_b must be unaffected by buf_a override")

render.render(buf_a, win)
render.render(buf_b, win)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(buf_a, render.NS, 0, -1, {}),
  0,
  "Buffer with rendering disabled must have no extmarks"
)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(buf_b, render.NS, 0, -1, {}) > 0,
  true,
  "Other buffers must still render with the global config"
)

-- Clearing the override restores global behaviour.
ind.set_buffer_config(nil, buf_a)
assert_eq(config.get(buf_a).indent.enabled, true, "Clearing override should restore global config")
pcall(vim.api.nvim_buf_delete, buf_a, { force = true })
pcall(vim.api.nvim_buf_delete, buf_b, { force = true })
print("  ✓ Per-buffer configuration overrides verified.")

-- 2. config.update() merges without resetting
print("[Test 2] Testing config.update() Partial Merge...")
ind.setup({ debounce_ms = 7, indent = { enabled = true } })
ind.update({ scope = { enabled = false } })
assert_eq(config.values.debounce_ms, 7, "update() must preserve unspecified values")
assert_eq(config.values.scope.enabled, false, "update() must apply the new value")
ind.setup({ debounce_ms = 10 })
print("  ✓ config.update() partial merge verified.")

-- 3. User scope node-type exclude override
print("[Test 3] Testing User Scope Node Exclude Override...")
local exclude_buf = make_buf({
  "function outer()",
  "  if true then",
  "    local x = 1",
  "  end",
  "end",
}, "lua")
vim.api.nvim_win_set_buf(win, exclude_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(exclude_buf)

local default_scope = ind.get_current_scope(exclude_buf, win)
assert_eq(default_scope.scope_start, 2, "By default the inner if_statement should be the scope")

ind.set_buffer_config({ scope = { exclude = { "if_statement" } } }, exclude_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
local excluded_scope = ind.get_current_scope(exclude_buf, win)
assert_eq(excluded_scope.scope_start, 1, "Excluding if_statement must fall back to the enclosing function_declaration")
pcall(vim.api.nvim_buf_delete, exclude_buf, { force = true })
print("  ✓ User scope exclude override verified.")

-- 4. User scope node-type include override
print("[Test 4] Testing User Scope Node Include Override...")
local include_buf = make_buf({
  "local result = call_service(",
  "  argument_one,",
  "  argument_two",
  ")",
}, "lua")
vim.api.nvim_win_set_buf(win, include_buf)
vim.api.nvim_win_set_cursor(win, { 2, 4 })
ind.enable(include_buf)

ind.set_buffer_config({ scope = { include = { "function_call" } } }, include_buf)
vim.api.nvim_win_set_cursor(win, { 2, 4 })
local included_scope = ind.get_current_scope(include_buf, win)
assert_eq(included_scope ~= nil, true, "Including function_call should yield a scope")
assert_eq(included_scope.scope_start, 1, "Included function_call scope should start on line 1")
assert_eq(included_scope.scope_end, 4, "Included function_call scope should end on line 4")
pcall(vim.api.nvim_buf_delete, include_buf, { force = true })
print("  ✓ User scope include override verified.")

-- 5. viewport_buffer renders beyond the visible window
print("[Test 5] Testing viewport_buffer Rendering Beyond Viewport...")
ind.setup({ debounce_ms = 0, viewport_buffer = 12, max_file_lines = 10000 })
local tall_lines = {}
for i = 1, 100 do
  tall_lines[i] = "    local x = " .. i
end
local tall_buf = make_buf(tall_lines)
vim.api.nvim_win_set_buf(win, tall_buf)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
ind.enable(tall_buf)

local height = vim.api.nvim_win_get_height(win)
local beyond = math.min(100, height + 5)
assert_eq(beyond > height, true, "Test requires a line beyond the viewport")
local beyond_marks = vim.api.nvim_buf_get_extmarks(tall_buf, render.NS, { beyond - 1, 0 }, { beyond - 1, -1 }, {})
assert_eq(#beyond_marks > 0, true, "viewport_buffer must render guides beyond the visible lines")

-- With a zero buffer, that line must not be rendered.
ind.setup({ viewport_buffer = 0 })
render.render(tall_buf, win)
local beyond_marks_zero = vim.api.nvim_buf_get_extmarks(tall_buf, render.NS, { beyond - 1, 0 }, { beyond - 1, -1 }, {})
assert_eq(#beyond_marks_zero, 0, "viewport_buffer=0 must restrict rendering to the viewport")
pcall(vim.api.nvim_buf_delete, tall_buf, { force = true })
print("  ✓ viewport_buffer rendering verified.")

-- 6. OptionSet autocmd re-renders on shiftwidth change
print("[Test 6] Testing OptionSet Re-render...")
local opt_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(opt_buf, 0, -1, false, { "    local a = 1", "    local b = 2" })
vim.api.nvim_set_option_value("shiftwidth", 8, { buf = opt_buf })
vim.api.nvim_set_option_value("tabstop", 8, { buf = opt_buf })
vim.api.nvim_win_set_buf(win, opt_buf)
ind.enable(opt_buf)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(opt_buf, render.NS, 0, -1, {}),
  0,
  "With shiftwidth 8, a 4-space indent produces no guides"
)
vim.api.nvim_set_current_buf(opt_buf)
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = opt_buf })
-- OptionSet does not reliably fire in headless Neovim, so invoke the handler directly.
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "shiftwidth" })
assert_eq(
  #vim.api.nvim_buf_get_extmarks(opt_buf, render.NS, 0, -1, {}) > 0,
  true,
  "OptionSet must re-render guides after shiftwidth changes"
)
pcall(vim.api.nvim_buf_delete, opt_buf, { force = true })
print("  ✓ OptionSet re-render verified.")

-- 7. enable()/disable() unified into per-buffer config
print("[Test 7] Testing Per-Buffer Enable/Disable...")
ind.setup({ debounce_ms = 0 })
local toggle_buf = make_buf({ "    local a = 1", "    local b = 2" })
vim.api.nvim_win_set_buf(win, toggle_buf)
ind.enable(toggle_buf)
assert_eq(ind.is_enabled(toggle_buf), true, "enable() should enable the buffer")
assert_eq(config.get_enabled_override(toggle_buf), true, "enable() must record an override")
ind.disable(toggle_buf)
assert_eq(ind.is_enabled(toggle_buf), false, "disable() should disable the buffer")
assert_eq(config.get_enabled_override(toggle_buf), false, "disable() must record an override")
ind.enable(toggle_buf)
assert_eq(ind.is_enabled(toggle_buf), true, "enable() should restore the buffer")
pcall(vim.api.nvim_buf_delete, toggle_buf, { force = true })
print("  ✓ Per-buffer enable/disable verified.")

-- 8. Hooks
print("[Test 8] Testing Rendering Hooks...")
local hook_buf = make_buf({
  "function outer()",
  "  if true then",
  "    local x = 1",
  "  end",
  "end",
}, "lua")
vim.api.nvim_win_set_buf(win, hook_buf)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
ind.enable(hook_buf)
local baseline = #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, 0, -1, {})
assert_eq(baseline > 0, true, "Baseline render should produce marks")

-- ACTIVE hook forces the buffer off
ind.register_hook(ind.hook_types.ACTIVE, function(buf)
  return buf ~= hook_buf
end)
assert_eq(
  #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, 0, -1, {}),
  0,
  "ACTIVE hook returning false must suppress rendering"
)
ind.clear_hooks(ind.hook_types.ACTIVE)
ind.force_update()
assert_eq(
  #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, 0, -1, {}) > 0,
  true,
  "Clearing the ACTIVE hook must restore rendering"
)

-- SKIP_LINE hook skips a single row
ind.register_hook(ind.hook_types.SKIP_LINE, function(_, row)
  return row == 2
end)
ind.force_update()
assert_eq(
  #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, { 2, 0 }, { 2, -1 }, {}),
  0,
  "SKIP_LINE hook must suppress marks on the skipped row"
)
ind.clear_hooks(ind.hook_types.SKIP_LINE)
ind.force_update()

-- SCOPE_ACTIVE hook removes the scope guide but keeps indent guides
local with_scope = #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, 0, -1, {})
ind.register_hook(ind.hook_types.SCOPE_ACTIVE, function()
  return false
end)
ind.force_update()
local without_scope = #vim.api.nvim_buf_get_extmarks(hook_buf, render.NS, 0, -1, {})
assert_eq(without_scope < with_scope, true, "SCOPE_ACTIVE hook must remove active scope marks")
ind.clear_hooks()
ind.force_update()
pcall(vim.api.nvim_buf_delete, hook_buf, { force = true })
print("  ✓ Rendering hooks verified.")

-- 9. Data-driven scope resolution across bundled grammars
print("[Test 9] Testing Data-Driven Scope Resolution Across Languages...")
ind.setup({ debounce_ms = 0 })
local samples = {
  {
    lang = "lua",
    code = {
      "local function f()",
      "  for i = 1, 10 do",
      "    print(i)",
      "  end",
      "end",
    },
    row = 3,
    start_line = 2,
    end_line = 4,
  },
  {
    lang = "c",
    code = {
      "int main() {",
      "    if (1) {",
      "        int x = 1;",
      "    }",
      "    return 0;",
      "}",
    },
    row = 3,
    start_line = 2,
    end_line = 4,
  },
  {
    lang = "vim",
    code = {
      "function! Foo()",
      "  if 1",
      "    echo 'x'",
      "  endif",
      "endfunction",
    },
    row = 3,
    start_line = 2,
    end_line = 4,
  },
}

for _, sample in ipairs(samples) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample.code)
  vim.api.nvim_set_option_value("filetype", sample.lang, { buf = buf })
  vim.api.nvim_set_option_value("shiftwidth", 2, { buf = buf })
  local has_parser = pcall(vim.treesitter.get_parser, buf, sample.lang)
  if has_parser then
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { sample.row, 4 })
    ind.enable(buf)
    local scope = ind.get_current_scope(buf, win)
    assert_eq(scope ~= nil, true, sample.lang .. ": expected a resolved scope")
    assert_eq(scope.scope_start, sample.start_line, sample.lang .. ": wrong scope start")
    assert_eq(scope.scope_end, sample.end_line, sample.lang .. ": wrong scope end")
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
print("  ✓ Data-driven scope resolution verified (lua/c/vim where available).")

-- 10. Injection-aware scope resolution (fenced code in markdown)
print("[Test 10] Testing Injection-Aware Scope Resolution...")
local md_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(md_buf, 0, -1, false, {
  "# Title",
  "",
  "```lua",
  "function f()",
  "  if true then",
  "    local x = 1",
  "  end",
  "end",
  "```",
})
vim.api.nvim_set_option_value("filetype", "markdown", { buf = md_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = md_buf })
local has_markdown = pcall(vim.treesitter.get_parser, md_buf, "markdown")
local has_lua = pcall(vim.treesitter.get_parser, md_buf, "lua")
if has_markdown and has_lua then
  vim.api.nvim_win_set_buf(win, md_buf)
  vim.api.nvim_win_set_cursor(win, { 6, 4 })
  ind.enable(md_buf)
  local scope = ind.get_current_scope(md_buf, win)
  assert_eq(scope ~= nil, true, "Scope inside an injected language should resolve")
  assert_eq(scope.scope_start, 5, "Injected scope should be the inner if (line 5)")
  assert_eq(scope.scope_end, 7, "Injected scope should end at line 7")
end
pcall(vim.api.nvim_buf_delete, md_buf, { force = true })
print("  ✓ Injection-aware scope resolution verified (markdown+lua where available).")

print("=== All New Feature Tests Passed Successfully! ===")
