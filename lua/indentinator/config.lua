--- Configuration module for indentinator.nvim.
--- Handles user options merging, corner presets, per-buffer overrides,
--- Luadoc typing, and buffer enablement checks.
---@class indentinator.config
local M = {}

local api = vim.api

---@class indentinator.RainbowConfig
---@field enabled boolean Whether rainbow coloring is enabled
---@field colors string[] List of hex color codes for indentation levels

---@class indentinator.IndentConfig
---@field enabled boolean Whether standard passive indent guides are enabled
---@field show_empty boolean Whether to render indent guides on empty/whitespace lines
---@field char string Passive indentation guide character
---@field hl string Highlight group name for passive indent guides
---@field rainbow indentinator.RainbowConfig Rainbow indent configuration

---@class indentinator.LanguageNodeOverride
---@field include string[]|nil Extra node types treated as scopes for this language
---@field exclude string[]|nil Node types never treated as scopes for this language

---@class indentinator.ScopeConfig
---@field enabled boolean Whether active scope indicator is enabled
---@field show_empty boolean Whether to render scope guide on empty/whitespace lines
---@field rainbow boolean Whether to cycle active scope colors through rainbow palette
---@field corner_style "sharp"|"round"|"double"|"bold" Preset style for scope corners
---@field char string Active scope delimiter character
---@field char_top string Top boundary corner character
---@field char_bottom string Bottom boundary corner character
---@field char_horizontal string Horizontal arm used by top/bottom corners
---@field corners boolean Whether to render corner delimiters at scope boundaries
---@field hl string Highlight group name for active scope guide
---@field hl_header string|nil Optional highlight group for scope header line
---@field treesitter boolean Whether to use Treesitter AST for active scope calculation
---@field include string[] Node types always treated as scopes (all languages)
---@field exclude string[] Node types never treated as scopes (all languages)
---@field languages table<string, indentinator.LanguageNodeOverride> Per-language node overrides

---@class indentinator.DelimitersConfig
---@field enabled boolean Whether to highlight scope boundary delimiters
---@field keywords boolean Whether to highlight boundary keywords (if, then, end, etc.)
---@field rainbow boolean Whether delimiter colors follow rainbow level palette
---@field bold boolean Whether delimiter highlight should be bold
---@field italic boolean Whether delimiter highlight should be italic
---@field underline boolean Whether delimiter highlight should be underlined
---@field hl string|nil Custom highlight group override for delimiters

---@class indentinator.ExcludeConfig
---@field filetypes string[] Filetypes to exclude from guide rendering
---@field buftypes string[] Buffer types to exclude from guide rendering

---@class indentinator.Config
---@field enabled boolean Global enablement switch
---@field debounce_ms integer Debounce delay in milliseconds for cursor events
---@field max_file_lines integer Maximum line count before guides are gracefully disabled
---@field viewport_buffer integer Extra lines rendered above/below the viewport
---@field priority integer Base extmark priority
---@field indent indentinator.IndentConfig Passive indent guides options
---@field scope indentinator.ScopeConfig Active scope guide options
---@field delimiters indentinator.DelimitersConfig Scope boundary delimiter options
---@field exclude indentinator.ExcludeConfig Exclusions options

--- Boundary corner character presets mapping
M.CORNER_PRESETS = {
  sharp = { char_top = "┌", char_bottom = "└", char_horizontal = "─" },
  round = { char_top = "╭", char_bottom = "╰", char_horizontal = "─" },
  double = { char_top = "╔", char_bottom = "╚", char_horizontal = "═" },
  bold = { char_top = "┏", char_bottom = "┗", char_horizontal = "━" },
}

--- Default plugin configuration values.
---@type indentinator.Config
M.defaults = {
  enabled = true,
  debounce_ms = 10,
  max_file_lines = 10000,
  viewport_buffer = 30,
  indent = {
    enabled = true,
    show_empty = true,
    char = "│",
    hl = "IndentinatorIndent",
    rainbow = {
      enabled = false,
      colors = {
        "#f38ba8", -- Red
        "#fab387", -- Peach
        "#f9e2af", -- Yellow
        "#a6e3a1", -- Green
        "#89b4fa", -- Blue
        "#cba6f7", -- Mauve
      },
    },
  },
  delimiters = {
    enabled = true,
    keywords = true,
    rainbow = false,
    bold = false,
    italic = false,
    underline = false,
    hl = nil,
  },
  scope = {
    enabled = true,
    show_empty = true,
    rainbow = false,
    corner_style = "sharp",
    char = "│",
    char_top = "┌",
    char_bottom = "└",
    char_horizontal = "─",
    corners = true,
    hl = "IndentinatorScope",
    hl_header = nil,
    treesitter = true,
    include = {},
    exclude = {},
    languages = {},
  },
  priority = 100,
  exclude = {
    filetypes = {},
    buftypes = { "terminal", "nofile", "quickfix", "prompt" },
  },
}

--- Active plugin configuration values.
---@type indentinator.Config
M.values = vim.deepcopy(M.defaults)

--- Per-buffer configuration overrides.
---@type table<integer, table>
M.buffer_values = {}

--- Resolved (merged + finalised) per-buffer configurations.
---@type table<integer, indentinator.Config>
M._resolved = {}

--- Converts a list into a lookup set.
---@param list string[]|nil
---@return table<string, boolean>
local function to_set(list)
  local set = {}
  if type(list) == "table" then
    for _, item in ipairs(list) do
      set[item] = true
    end
  end
  return set
end

--- Returns a numeric value, or the fallback when invalid or below `min`.
---@param value any
---@param fallback number
---@param min number
---@return number
local function number_or(value, fallback, min)
  if type(value) ~= "number" or value < min then
    return fallback
  end
  return value
end

--- Coerces numeric fields and builds all derived lookup sets on a config table.
---@param cfg indentinator.Config
---@return indentinator.Config
local function finalize(cfg)
  cfg.debounce_ms = number_or(cfg.debounce_ms, M.defaults.debounce_ms, 0)
  cfg.max_file_lines = number_or(cfg.max_file_lines, M.defaults.max_file_lines, 1)
  cfg.viewport_buffer = number_or(cfg.viewport_buffer, M.defaults.viewport_buffer, 0)
  if type(cfg.priority) ~= "number" then
    cfg.priority = M.defaults.priority
  end

  cfg.exclude = cfg.exclude or {}
  cfg.exclude.filetypes = cfg.exclude.filetypes or {}
  cfg.exclude.buftypes = cfg.exclude.buftypes or {}
  cfg._exclude_filetypes_set = to_set(cfg.exclude.filetypes)
  cfg._exclude_buftypes_set = to_set(cfg.exclude.buftypes)

  cfg.scope = cfg.scope or {}
  cfg.scope.include = cfg.scope.include or {}
  cfg.scope.exclude = cfg.scope.exclude or {}
  cfg.scope.languages = cfg.scope.languages or {}
  cfg._scope_include_set = to_set(cfg.scope.include)
  cfg._scope_exclude_set = to_set(cfg.scope.exclude)
  for _, override in pairs(cfg.scope.languages) do
    if type(override) == "table" then
      override._include_set = to_set(override.include)
      override._exclude_set = to_set(override.exclude)
    end
  end

  return cfg
end

finalize(M.values)

--- Normalises a user options table (boolean shorthands + corner presets).
---@param opts table|nil
---@return table
local function normalise(opts)
  local n = vim.deepcopy(opts) or {}
  if type(n.indent) == "boolean" then
    n.indent = { enabled = n.indent }
  end
  if type(n.scope) == "boolean" then
    n.scope = { enabled = n.scope }
  end
  if type(n.delimiters) == "boolean" then
    n.delimiters = { enabled = n.delimiters }
  end

  -- Apply corner preset if specified and characters were not explicitly provided.
  local scope_opt = type(n.scope) == "table" and n.scope or nil
  if scope_opt and scope_opt.corner_style and M.CORNER_PRESETS[scope_opt.corner_style] then
    local preset = M.CORNER_PRESETS[scope_opt.corner_style]
    if scope_opt.char_top == nil then
      scope_opt.char_top = preset.char_top
    end
    if scope_opt.char_bottom == nil then
      scope_opt.char_bottom = preset.char_bottom
    end
    if scope_opt.char_horizontal == nil then
      scope_opt.char_horizontal = preset.char_horizontal
    end
  end

  return n
end

--- Applies the flat convenience options onto a config table.
---@param cfg indentinator.Config
---@param opts table
local function apply_flat(cfg, opts)
  if opts.char then
    cfg.indent.char = opts.char
    cfg.scope.char = opts.char
  end
  if opts.hl then
    cfg.scope.hl = opts.hl
  end
  if opts.treesitter ~= nil then
    cfg.scope.treesitter = opts.treesitter
  end
  if opts.scope_rainbow ~= nil then
    cfg.scope.rainbow = opts.scope_rainbow
  end
  if opts.rainbow_delimiters ~= nil then
    cfg.delimiters.rainbow = opts.rainbow_delimiters
  end
  if type(opts.scope) == "table" and opts.scope.rainbow_delimiters ~= nil then
    cfg.delimiters.rainbow = opts.scope.rainbow_delimiters
  end
end

--- Merges user options into global configuration values.
--- Resets the global config to defaults first, so it is safe to call repeatedly.
---@param opts indentinator.Config|table|nil User configuration options
function M.setup(opts)
  if type(opts) ~= "table" then
    return
  end

  -- Deep merge onto a fresh copy of defaults so that repeated setup() calls
  -- cannot leak stale overrides into later calls.
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), normalise(opts))
  apply_flat(M.values, opts)

  finalize(M.values)
  M._resolved = {}
end

--- Updates global configuration by merging into the current values (no reset).
---@param opts indentinator.Config|table|nil User configuration options
function M.update(opts)
  if type(opts) ~= "table" then
    return
  end

  M.values = vim.tbl_deep_extend("force", M.values, normalise(opts))
  apply_flat(M.values, opts)

  finalize(M.values)
  M._resolved = {}
end

--- Retrieves the resolved configuration for a buffer, falling back to the global
--- configuration when the buffer has no overrides. Results are memoized.
---@param buf integer|nil Buffer handle
---@return indentinator.Config
function M.get(buf)
  if not buf then
    return M.values
  end

  local resolved = M._resolved[buf]
  if resolved then
    return resolved
  end

  local override = M.buffer_values[buf]
  if not override then
    M._resolved[buf] = M.values
    return M.values
  end

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.values), normalise(override))
  finalize(merged)
  M._resolved[buf] = merged
  return merged
end

--- Sets per-buffer configuration overrides (same shape as `setup`).
--- Replaces any existing override for the buffer.
---@param buf integer Buffer handle
---@param opts table|nil Overrides; nil clears them
function M.set_buffer(buf, opts)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  if opts == nil then
    M.buffer_values[buf] = nil
  else
    M.buffer_values[buf] = vim.deepcopy(opts)
  end
  M._resolved[buf] = nil
end

--- Merges additional overrides into a buffer's existing override.
---@param buf integer Buffer handle
---@param opts table Overrides to merge
function M.update_buffer(buf, opts)
  if not buf or not api.nvim_buf_is_valid(buf) or type(opts) ~= "table" then
    return
  end
  local current = M.buffer_values[buf] or {}
  M.buffer_values[buf] = vim.tbl_deep_extend("force", vim.deepcopy(current), vim.deepcopy(opts))
  M._resolved[buf] = nil
end

--- Clears cached per-buffer configuration for a buffer.
---@param buf integer Buffer handle
function M.clear_buffer(buf)
  M.buffer_values[buf] = nil
  M._resolved[buf] = nil
end

--- Invalidates every memoized per-buffer resolved configuration.
--- Call this after mutating `M.values` in place (for example from the global
--- toggle commands) so buffers with overrides re-merge against the new globals
--- instead of returning a stale cached copy.
function M.clear_resolved()
  M._resolved = {}
end

--- Returns the explicit per-buffer `enabled` override, if any.
---@param buf integer Buffer handle
---@return boolean|nil
function M.get_enabled_override(buf)
  local override = M.buffer_values[buf]
  if type(override) == "table" and type(override.enabled) == "boolean" then
    return override.enabled
  end
  return nil
end

--- Checks whether a buffer option value is in an exclusion set.
---@param buf integer Buffer handle
---@param opt string Option name
---@param excluded table<string, boolean>
---@return boolean
local function option_is_excluded(buf, opt, excluded)
  local ok, value = pcall(api.nvim_get_option_value, opt, { buf = buf })
  return ok and type(value) == "string" and value ~= "" and excluded[value] == true
end

--- Checks if plugin features are enabled for a given buffer.
---
--- Precedence: an explicit per-buffer `enabled` override (set via the public
--- `enable`/`disable` API or `set_buffer_config`) wins over both the global
--- `enabled` switch and the filetype/buftype exclusions.
---@param buf integer Buffer handle
---@return boolean True if guides should run for this buffer
function M.is_enabled(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return false
  end

  local override = M.get_enabled_override(buf)
  if override ~= nil then
    return override
  end

  local cfg = M.get(buf)
  if not cfg.enabled then
    return false
  end

  if
    option_is_excluded(buf, "buftype", cfg._exclude_buftypes_set)
    or option_is_excluded(buf, "filetype", cfg._exclude_filetypes_set)
  then
    return false
  end

  return true
end

return M
