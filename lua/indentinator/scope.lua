--- Scope resolution engine facade for indentinator.nvim.
--- Exposes modern Treesitter AST scope traversal and indentation fallback methods.
---@class indentinator.scope
local treesitter = require("indentinator.treesitter")

local M = {}

M.get_scope = treesitter.get_scope
M.get_treesitter_scope = treesitter.get_treesitter_scope
M.get_indent_scope = treesitter.get_indent_scope
M.get_parent_scope = treesitter.get_parent_scope
M.find_first_last_scope_lines = treesitter.find_first_last_scope_lines
M.resolve_treesitter_scope = treesitter.resolve_treesitter_scope
M.resolve_indent_scope = treesitter.resolve_indent_scope
M.attach_buffer = treesitter.attach_buffer
M.get_parser = treesitter.get_parser
M.get_boundary_delimiters = treesitter.get_boundary_delimiters

return M
