-- Test suite for scope detection precision and stability improvements
-- Run via tests/run.sh.

local helpers = dofile("tests/helpers.lua")
local assert_eq = helpers.assert_eq

print("=== Running Indentinator Scope Detection Precision Tests ===")

local ind = require("indentinator")
local treesitter = require("indentinator.treesitter")

ind.setup({
  debounce_ms = 0,
  indent = { enabled = true },
  scope = {
    enabled = true,
    treesitter = true,
    corners = true,
  },
})

-- Test 1: Column Bias Stability (Cursor at Col 0 vs Inside Statement on Same Line)
print("[Test 1] Testing Cursor Horizontal Movement Stability Across Columns...")
local col_buf = vim.api.nvim_create_buf(false, true)
local col_code = {
  "function outer_demo()",
  "  if condition then",
  "    local value = 42",
  "  end",
  "end",
}
vim.api.nvim_buf_set_lines(col_buf, 0, -1, false, col_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = col_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = col_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = col_buf })

local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, col_buf)
ind.enable(col_buf)

-- Cursor at col 0 of line 2 ("  if condition then")
vim.api.nvim_win_set_cursor(win, { 2, 0 })
local s_col0 = treesitter.resolve_treesitter_scope(col_buf, win, 2, 0)
assert_eq(s_col0 ~= nil, true, "Scope resolution at col 0 should succeed")
assert_eq(s_col0.scope_start, 2, "Scope start at col 0 must be line 2 (if statement)")
assert_eq(s_col0.scope_end, 4, "Scope end at col 0 must be line 4 (end)")
assert_eq(s_col0.active_col, 2, "Active col at col 0 must be 2")

-- Cursor at col 2 of line 2 (the 'i' in 'if')
vim.api.nvim_win_set_cursor(win, { 2, 2 })
local s_col2 = treesitter.resolve_treesitter_scope(col_buf, win, 2, 2)
assert_eq(s_col2 ~= nil, true, "Scope resolution at col 2 should succeed")
assert_eq(s_col2.scope_start, 2, "Scope start at col 2 must be line 2 (if statement)")
assert_eq(s_col2.scope_end, 4, "Scope end at col 2 must be line 4 (end)")
assert_eq(s_col2.active_col, 2, "Active col at col 2 must be 2")

-- Cursor at col 6 of line 2 (inside 'condition')
vim.api.nvim_win_set_cursor(win, { 2, 6 })
local s_col6 = treesitter.resolve_treesitter_scope(col_buf, win, 2, 6)
assert_eq(s_col6.scope_start, 2, "Scope start at col 6 must still be line 2")
assert_eq(s_col6.scope_end, 4, "Scope end at col 6 must still be line 4")
assert_eq(s_col6.active_col, 2, "Active col at col 6 must remain 2")

pcall(vim.api.nvim_buf_delete, col_buf, { force = true })
print("  ✓ Column bias eliminated: cursor movement across columns preserves exact scope.")

-- Test 2: Expression & Argument Bypassing (Multi-line Function Calls & Args)
print("[Test 2] Testing Multi-line Arguments & Expression Bypassing...")
local call_buf = vim.api.nvim_create_buf(false, true)
local call_code = {
  "function process_data()",
  "  call_remote_service(",
  "    argument_one,",
  "    argument_two",
  "  )",
  "  local final_result = true",
  "end",
}
vim.api.nvim_buf_set_lines(call_buf, 0, -1, false, call_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = call_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = call_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = call_buf })
vim.api.nvim_win_set_buf(win, call_buf)
ind.enable(call_buf)

-- Cursor on line 3 ("    argument_one,")
vim.api.nvim_win_set_cursor(win, { 3, 6 })
local s_arg = treesitter.resolve_treesitter_scope(call_buf, win, 3, 6)
assert_eq(s_arg ~= nil, true, "Scope resolution on argument line should succeed")
assert_eq(s_arg.node:type(), "function_declaration", "Scope node must be enclosing function, NOT arguments or call")
assert_eq(s_arg.scope_start, 1, "Enclosing function scope start should be line 1")
assert_eq(s_arg.scope_end, 7, "Enclosing function scope end should be line 7")
assert_eq(s_arg.active_col, 0, "Outer function active_col must be 0")

pcall(vim.api.nvim_buf_delete, call_buf, { force = true })
print("  ✓ Multi-line arguments and expressions bypassed cleanly without hijacking scope.")

-- Test 3: Multi-Branch Conditional Partitioning (if / elseif / else / end)
print("[Test 3] Testing Multi-Branch Conditional Partitioning...")
local branch_buf = vim.api.nvim_create_buf(false, true)
local branch_code = {
  "function evaluate(val)",
  "  if val == 1 then",
  "    print('branch 1')",
  "  elseif val == 2 then",
  "    print('branch 2')",
  "  else",
  "    print('branch 3')",
  "  end",
  "end",
}
vim.api.nvim_buf_set_lines(branch_buf, 0, -1, false, branch_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = branch_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = branch_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = branch_buf })
vim.api.nvim_win_set_buf(win, branch_buf)
ind.enable(branch_buf)

-- Cursor on line 3 (inside `if` branch)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
local s_branch1 = treesitter.resolve_treesitter_scope(branch_buf, win, 3, 4)
assert_eq(s_branch1 ~= nil, true, "Scope resolution in if branch should succeed")
assert_eq(s_branch1.scope_start, 2, "If-branch scope start must be line 2 (if val == 1 then)")
assert_eq(s_branch1.scope_end, 4, "If-branch scope end must be line 4 (elseif val == 2 then)")

-- Cursor on line 5 (inside `elseif` branch)
vim.api.nvim_win_set_cursor(win, { 5, 4 })
local s_branch2 = treesitter.resolve_treesitter_scope(branch_buf, win, 5, 4)
assert_eq(s_branch2 ~= nil, true, "Scope resolution in elseif branch should succeed")
assert_eq(s_branch2.scope_start, 4, "Elseif-branch scope start must be line 4 (elseif val == 2 then)")
assert_eq(s_branch2.scope_end, 6, "Elseif-branch scope end must be line 6 (else)")

-- Cursor on line 7 (inside `else` branch)
vim.api.nvim_win_set_cursor(win, { 7, 4 })
local s_branch3 = treesitter.resolve_treesitter_scope(branch_buf, win, 7, 4)
assert_eq(s_branch3 ~= nil, true, "Scope resolution in else branch should succeed")
assert_eq(s_branch3.scope_start, 6, "Else-branch scope start must be line 6 (else)")
assert_eq(s_branch3.scope_end, 8, "Else-branch scope end must be line 8 (end)")

pcall(vim.api.nvim_buf_delete, branch_buf, { force = true })
print("  ✓ Multi-branch conditionals partitioned cleanly into independent scopes.")

-- Test 4: Scope Corners On Blank Lines Protection
print("[Test 4] Testing Scope Corners Protection on Blank Lines...")
local blank_buf = vim.api.nvim_create_buf(false, true)
local blank_code = {
  "function with_blanks()",
  "  if true then",
  "",
  "    print('after blank')",
  "",
  "  end",
  "end",
}
vim.api.nvim_buf_set_lines(blank_buf, 0, -1, false, blank_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = blank_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = blank_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = blank_buf })
vim.api.nvim_win_set_buf(win, blank_buf)
ind.enable(blank_buf)

-- Cursor on line 4 ("    print('after blank')")
vim.api.nvim_win_set_cursor(win, { 4, 6 })
local s_blank = treesitter.resolve_treesitter_scope(blank_buf, win, 4, 6)
assert_eq(s_blank ~= nil, true, "Scope resolution with blank lines should succeed")
assert_eq(s_blank.first_body_line, 4, "First body line must skip blank line 3 and land on line 4")
assert_eq(s_blank.last_body_line, 4, "Last body line must skip blank line 5 and land on line 4")

pcall(vim.api.nvim_buf_delete, blank_buf, { force = true })
print("  ✓ Blank lines skipped when determining corner locations: corners never float on blank lines.")

-- Test 5: Adjacent Sibling Scopes Isolation (No Bleed into Next Scope)
print("[Test 5] Testing Adjacent Sibling Scopes Boundary Isolation...")
local sib_buf = vim.api.nvim_create_buf(false, true)
local sib_code = {
  "function siblings()",
  "  if first then",
  "    local x = 1",
  "  end",
  "  if second then",
  "    local y = 2",
  "  end",
  "end",
}
vim.api.nvim_buf_set_lines(sib_buf, 0, -1, false, sib_code)
vim.api.nvim_set_option_value("filetype", "lua", { buf = sib_buf })
vim.api.nvim_set_option_value("shiftwidth", 2, { buf = sib_buf })
vim.api.nvim_set_option_value("tabstop", 2, { buf = sib_buf })
vim.api.nvim_win_set_buf(win, sib_buf)
ind.enable(sib_buf)

-- Cursor on line 3 (inside first if)
vim.api.nvim_win_set_cursor(win, { 3, 4 })
local s_sib1 = treesitter.resolve_treesitter_scope(sib_buf, win, 3, 4)
assert_eq(s_sib1.scope_start, 2, "First if scope_start must be line 2")
assert_eq(s_sib1.scope_end, 4, "First if scope_end must be line 4 (MUST NOT bleed into line 5)")

-- Cursor on line 6 (inside second if)
vim.api.nvim_win_set_cursor(win, { 6, 4 })
local s_sib2 = treesitter.resolve_treesitter_scope(sib_buf, win, 6, 4)
assert_eq(s_sib2.scope_start, 5, "Second if scope_start must be line 5")
assert_eq(s_sib2.scope_end, 7, "Second if scope_end must be line 7")

pcall(vim.api.nvim_buf_delete, sib_buf, { force = true })
print("  ✓ Sibling scopes completely isolated without bleeding into adjacent headers.")

print("=== All Scope Detection Precision Tests Passed Successfully! ===")
