--- Data-driven Treesitter scope node classification.
---
--- `M.languages` maps a Treesitter language name to the set of node types that
--- should be treated as an active scope. When a language is listed here, scope
--- resolution uses the allow-list for precision; languages without an entry fall
--- back to the generic heuristic in `indentinator.treesitter`.
---
--- Users may extend or override any of this without code changes via the
--- `scope.include`, `scope.exclude`, and `scope.languages` config options.
---
--- NOTE: `lua`, `c`, and `vim` are covered by the test suite (whatever parsers
--- the running Neovim bundles). Other lists are curated from grammar knowledge
--- and are intentionally generous (they include common multi-line containers);
--- tighten them per-project with `scope.exclude`.
---@class indentinator.scope_languages
local M = {}

--- Root AST node types that represent the whole document and must never be scopes.
---@type table<string, boolean>
M.root_types = {
  translation_unit = true,
  program = true,
  source_file = true,
  chunk = true,
  module = true,
  script = true,
  document = true,
  compilation_unit = true,
  file = true,
  root = true,
  stream = true,
}

--- Block/body container types that should be promoted to their enclosing construct.
---@type table<string, boolean>
M.block_types = {
  block = true,
  statement_block = true,
  compound_statement = true,
  body = true,
  statement_list = true,
  consequence = true,
  alternative = true,
  declaration_list = true,
  field_declaration_list = true,
  class_body = true,
  switch_body = true,
  switch_block = true,
}

--- Expression / non-compound node types that are never scopes (heuristic fallback).
---@type table<string, boolean>
M.excluded_types = {
  arguments = true,
  argument_list = true,
  parameters = true,
  parameter_list = true,
  formal_parameters = true,
  call_expression = true,
  function_call = true,
  method_call = true,

  assignment_statement = true,
  variable_declaration = true,
  local_variable_declaration = true,
  lexical_declaration = true,
  declaration = true,
  expression_statement = true,
  short_var_decl = true,
  assignment = true,
  augmented_assignment = true,

  return_statement = true,
  break_statement = true,
  continue_statement = true,
  yield_statement = true,
  throw_statement = true,
  goto_statement = true,

  expression_list = true,
  variable_list = true,
  binary_expression = true,
  unary_expression = true,
  boolean_expression = true,
  comparison_expression = true,
  concatenation = true,
  parenthesized_expression = true,
  subscript_expression = true,
  member_expression = true,
  dot_index_expression = true,
  bracket_index_expression = true,
  conditional_expression = true,
  ternary_expression = true,
  type_annotation = true,
  type_specifier = true,
  type_arguments = true,
  type_parameters = true,

  field = true,
  pair = true,
  property_assignment = true,
  shorthand_property_identifier = true,
  spread_element = true,
}

--- Conditional / exception branch clause types (branch partitioning).
---@type table<string, boolean>
M.clause_types = {
  except_clause = true,
  finally_clause = true,
  catch_clause = true,
  elif_clause = true,
  else_clause = true,
  elseif_statement = true,
  else_statement = true,
  case_clause = true,
  switch_case = true,
  match_arm = true,
  match_clause = true,
  elsif = true,
  ["else"] = true,
  elif = true,
}

--- Closing tokens that terminate a branch construct.
---@type table<string, boolean>
M.closing_types = {
  ["end"] = true,
  ["fi"] = true,
  ["done"] = true,
  ["esac"] = true,
  ["}"] = true,
  [")"] = true,
  ["]"] = true,
}

--- Parent constructs that own branch clauses and should be partitioned.
---@type table<string, boolean>
M.branch_parent_types = {
  if_statement = true,
  if_expression = true,
  try_statement = true,
  switch_statement = true,
  match_statement = true,
}

--- Per-language scope node allow-lists.
---@type table<string, table<string, boolean>>
M.languages = {
  lua = {
    function_declaration = true,
    function_definition = true,
    if_statement = true,
    elseif_statement = true,
    else_statement = true,
    for_statement = true,
    while_statement = true,
    repeat_statement = true,
    do_statement = true,
  },

  python = {
    function_definition = true,
    class_definition = true,
    if_statement = true,
    elif_clause = true,
    else_clause = true,
    for_statement = true,
    while_statement = true,
    with_statement = true,
    try_statement = true,
    except_clause = true,
    finally_clause = true,
    match_statement = true,
    case_clause = true,
    decorated_definition = true,
  },

  javascript = {
    function_declaration = true,
    function_expression = true,
    generator_function = true,
    generator_function_declaration = true,
    arrow_function = true,
    method_definition = true,
    class_declaration = true,
    class = true,
    if_statement = true,
    else_clause = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    do_statement = true,
    switch_statement = true,
    switch_case = true,
    switch_default = true,
    try_statement = true,
    catch_clause = true,
    finally_clause = true,
    object = true,
    array = true,
  },
  typescript = {
    function_declaration = true,
    function_expression = true,
    generator_function = true,
    generator_function_declaration = true,
    arrow_function = true,
    method_definition = true,
    class_declaration = true,
    class = true,
    abstract_class_declaration = true,
    interface_declaration = true,
    enum_declaration = true,
    internal_module = true,
    if_statement = true,
    else_clause = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    do_statement = true,
    switch_statement = true,
    switch_case = true,
    switch_default = true,
    try_statement = true,
    catch_clause = true,
    finally_clause = true,
    object = true,
    array = true,
  },

  c = {
    function_definition = true,
    if_statement = true,
    for_statement = true,
    while_statement = true,
    do_statement = true,
    switch_statement = true,
    case_statement = true,
    struct_specifier = true,
    union_specifier = true,
    enum_specifier = true,
    initializer_list = true,
    preproc_if = true,
    preproc_else = true,
    preproc_elif = true,
  },
  cpp = {
    function_definition = true,
    if_statement = true,
    for_statement = true,
    for_range_loop = true,
    while_statement = true,
    do_statement = true,
    switch_statement = true,
    case_statement = true,
    class_specifier = true,
    struct_specifier = true,
    union_specifier = true,
    enum_specifier = true,
    namespace_definition = true,
    try_statement = true,
    catch_clause = true,
    template_declaration = true,
    lambda_expression = true,
    initializer_list = true,
    preproc_if = true,
    preproc_else = true,
    preproc_elif = true,
  },

  go = {
    function_declaration = true,
    method_declaration = true,
    func_literal = true,
    if_statement = true,
    for_statement = true,
    expression_switch_statement = true,
    type_switch_statement = true,
    select_statement = true,
    composite_literal = true,
  },

  rust = {
    function_item = true,
    impl_item = true,
    trait_item = true,
    mod_item = true,
    struct_item = true,
    enum_item = true,
    union_item = true,
    if_expression = true,
    else_clause = true,
    match_expression = true,
    match_arm = true,
    loop_expression = true,
    while_expression = true,
    for_expression = true,
    closure_expression = true,
    unsafe_block = true,
  },

  ruby = {
    method = true,
    singleton_method = true,
    class = true,
    module = true,
    ["if"] = true,
    unless = true,
    case = true,
    ["while"] = true,
    ["until"] = true,
    ["for"] = true,
    begin = true,
    do_block = true,
    lambda = true,
  },

  bash = {
    function_definition = true,
    if_statement = true,
    elif_clause = true,
    else_clause = true,
    for_statement = true,
    while_statement = true,
    case_statement = true,
    case_item = true,
    do_group = true,
    subshell = true,
  },

  java = {
    class_declaration = true,
    interface_declaration = true,
    enum_declaration = true,
    record_declaration = true,
    method_declaration = true,
    constructor_declaration = true,
    if_statement = true,
    for_statement = true,
    enhanced_for_statement = true,
    while_statement = true,
    do_statement = true,
    switch_expression = true,
    switch_block = true,
    try_statement = true,
    catch_clause = true,
    finally_clause = true,
    lambda_expression = true,
  },
}

-- Common aliases that share another language's grammar.
M.languages.javascriptreact = M.languages.javascript
M.languages.typescriptreact = M.languages.typescript
M.languages.tsx = M.languages.typescript
M.languages.sh = M.languages.bash
M.languages.zsh = M.languages.bash

---@param t string Node type
---@return boolean
function M.is_root(t)
  return M.root_types[t] == true
end

---@param t string Node type
---@return boolean
function M.is_block(t)
  return M.block_types[t] == true
end

---@param t string Node type
---@return boolean
function M.is_clause(t)
  return M.clause_types[t] == true
end

---@param t string Node type
---@return boolean
function M.is_branch_parent(t)
  return M.branch_parent_types[t] == true
end

---@param t string Node type
---@return boolean
function M.is_closing(t)
  return M.closing_types[t] == true
end

--- Returns the scope allow-list for a language, if one exists.
---@param lang string|nil
---@return table<string, boolean>|nil
function M.get(lang)
  if not lang then
    return nil
  end
  return M.languages[lang]
end

return M
