--- Configuration management for indentinator.nvim.
--- Handles plugin settings, visual style presets, per-filetype overrides, and buffer enablement logic.

---@class IndentinatorScopeConfig
---@field enabled boolean Whether active scope guide highlighting is enabled
---@field range "block"|"global" Scope calculation range ("block" or "global")
---@field only_scope boolean Whether to clip active scope guide outside scope boundaries
---@field background boolean|"block"|"boundaries" Scope background highlight mode
---@field corner boolean Whether to draw corner characters at scope boundaries
---@field corners boolean|nil Alias for corner
---@field use_corners boolean|nil Alias for corner
---@field corner_top string|nil Custom top corner character
---@field corner_bottom string|nil Custom bottom corner character
---@field underline_char string|nil Custom horizontal connector line character
---@field text_highlight boolean Whether to colorize text on scope start line
---@field delimiters boolean Whether to highlight scope opening/closing delimiter tokens
---@field treesitter boolean Whether to use Treesitter for scope resolution

---@class IndentinatorStylePreset
---@field char string Standard guide character
---@field current_char string Active guide character
---@field corner_top string Top boundary corner character
---@field corner_bottom string Bottom boundary corner character
---@field underline_char string Horizontal connector line character

---@class IndentinatorConfig
---@field enabled boolean Global/per-buffer guide enablement status
---@field smart boolean Whether blank lines inherit surrounding guide levels
---@field char string|nil Custom standard guide character
---@field current_char string|nil Custom active guide character
---@field style string Visual preset name ("thick", "thin", "curved", "rounded", "heavy", etc.)
---@field char_hl string Highlight group for standard guides
---@field gap_hl string Highlight group for gap spaces
---@field draw_gap_hl boolean Whether gap whitespace is highlighted
---@field show_first_indent_level boolean Whether column 0 guide level is rendered
---@field indent_width integer|nil Custom indent width override
---@field exclude string[] Excluded filetypes
---@field exclude_buftypes string[] Excluded buftypes
---@field priority integer Extmark rendering priority
---@field scope IndentinatorScopeConfig Active scope configuration
---@field current_char_hl string Highlight group for active scope guide
---@field scope_text_hl string Highlight group for scope start header text
---@field scope_bg_hl string Highlight group for scope background
---@field scope_delimiter_hl string Highlight group for scope delimiters
---@field exclude_fn (fun(buf: integer): boolean)|nil Custom callback for buffer exclusion
---@field filetypes table<string, table> Per-filetype configuration overrides

local M = {}

--- Visual style presets defining guide and corner characters.
---@type table<string, IndentinatorStylePreset>
M.STYLE_PRESETS = {
  thick = {
    char = "│",
    current_char = "┃",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
  heavy = {
    char = "┃",
    current_char = "█",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
  thin = {
    char = "│",
    current_char = "│",
    corner_top = "┌",
    corner_bottom = "└",
    underline_char = "─",
  },
  double = {
    char = "│",
    current_char = "║",
    corner_top = "╔",
    corner_bottom = "╚",
    underline_char = "═",
  },
  curved = {
    char = "│",
    current_char = "│",
    corner_top = "╭",
    corner_bottom = "╰",
    underline_char = "─",
  },
  rounded = {
    char = "│",
    current_char = "│",
    corner_top = "╭",
    corner_bottom = "╰",
    underline_char = "─",
  },
  curved_thick = {
    char = "│",
    current_char = "┃",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
  rounded_thick = {
    char = "│",
    current_char = "┃",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
  dashed = {
    char = "┆",
    current_char = "┃",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
  dotted = {
    char = "┊",
    current_char = "┃",
    corner_top = "┏",
    corner_bottom = "┗",
    underline_char = "━",
  },
}

--- Default plugin configuration settings.
---@type IndentinatorConfig
M.defaults = {
  enabled = true,
  smart = false,
  char = nil,
  current_char = nil,
  style = "thick",
  char_hl = "IndentinatorGuide",
  gap_hl = "IndentinatorGap",
  draw_gap_hl = false,
  show_first_indent_level = true,
  indent_width = nil,
  exclude = {},
  exclude_buftypes = { "terminal", "nofile", "quickfix", "prompt" },
  priority = 100,
  scope = {
    enabled = false,
    range = "block",
    only_scope = true,
    background = false,
    corner = true,
    corner_top = nil,
    corner_bottom = nil,
    underline_char = nil,
    text_highlight = true,
    delimiters = false,
    treesitter = false,
  },
  current_char_hl = "IndentinatorCurrentGuide",
  scope_text_hl = "IndentinatorScopeText",
  scope_bg_hl = "IndentinatorScopeBg",
  scope_delimiter_hl = "IndentinatorScopeDelimiter",
  exclude_fn = nil,
  filetypes = {},
}

--- Active user runtime configuration table.
---@type IndentinatorConfig
M.values = vim.deepcopy(M.defaults)

--- Retrieves filetype for a given buffer safely.
---@param buf integer Buffer handle
---@return string Filetype string or empty string if unset
local function get_filetype(buf)
  local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  return (ok and type(ft) == "string") and ft or ""
end

--- Resolves a configuration option value for a buffer, respecting per-filetype overrides.
---@param buf integer The buffer handle
---@param opt string Configuration key name
---@param ft string|nil Optional pre-fetched filetype
---@return any The resolved configuration value
function M.resolve_config(buf, opt, ft)
  ft = ft or get_filetype(buf)

  -- Check per-filetype specific override first
  if ft ~= "" and M.values.filetypes and M.values.filetypes[ft] then
    local ft_cfg = M.values.filetypes[ft]
    if ft_cfg[opt] ~= nil then
      return ft_cfg[opt]
    end
  end

  -- Check global configuration value
  local val = M.values[opt]
  if val ~= nil then
    return val
  end

  -- Fall back to style preset character defaults if char or current_char is unconfigured
  local style_name = M.values.style or "thick"
  local preset = M.STYLE_PRESETS[style_name] or M.STYLE_PRESETS.thick

  if opt == "current_char" then
    return preset.current_char
  end
  if opt == "char" then
    return preset.char
  end

  return nil
end

--- Resolves merged scope configuration for a buffer.
---@param buf integer The buffer handle
---@param ft string|nil Optional pre-fetched filetype
---@return IndentinatorScopeConfig The resolved scope configuration table
function M.resolve_scope(buf, ft)
  ft = ft or get_filetype(buf)
  local scope_cfg = vim.deepcopy(M.values.scope or {})

  -- Apply filetype scope override if present
  if ft ~= "" and M.values.filetypes and M.values.filetypes[ft] then
    local ft_scope = M.values.filetypes[ft].scope
    if type(ft_scope) == "table" then
      scope_cfg = vim.tbl_extend("force", scope_cfg, ft_scope)
    end
  end

  -- Process corner option aliases (corners, use_corners)
  if scope_cfg.corners ~= nil then
    scope_cfg.corner = scope_cfg.corners
  elseif scope_cfg.use_corners ~= nil then
    scope_cfg.corner = scope_cfg.use_corners
  end

  -- Resolve boundary corner characters from active style preset defaults
  local style_name = M.resolve_config(buf, "style", ft) or "thick"
  local preset = M.STYLE_PRESETS[style_name] or M.STYLE_PRESETS.thick

  scope_cfg.corner_top = scope_cfg.corner_top or preset.corner_top
  scope_cfg.corner_bottom = scope_cfg.corner_bottom or preset.corner_bottom
  scope_cfg.underline_char = scope_cfg.underline_char or preset.underline_char

  return scope_cfg
end

--- Checks whether indentation guides are enabled for a buffer.
---@param buf integer The buffer handle
---@param state IndentinatorStateData|nil Optional state module reference
---@return boolean True if guides should be rendered for this buffer, false otherwise
function M.is_enabled(buf, state)
  state = state or require("indentinator.state").state

  -- Respect explicit buffer override state if set
  local explicit = state.enabled[buf]
  if explicit ~= nil then
    return explicit
  end

  -- Check custom user exclusion callback
  local exclude_fn = M.resolve_config(buf, "exclude_fn")
  if type(exclude_fn) == "function" then
    local ok, result = pcall(exclude_fn, buf)
    if ok and result then
      return false
    end
  end

  -- Check excluded filetypes
  local ft = get_filetype(buf)
  local excluded_fts = M.resolve_config(buf, "exclude", ft) or {}
  for _, excluded_ft in ipairs(excluded_fts) do
    if ft == excluded_ft then
      return false
    end
  end

  -- Check excluded buftypes
  local ok_bt, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
  bt = (ok_bt and type(bt) == "string") and bt or ""
  local excluded_bts = M.resolve_config(buf, "exclude_buftypes", ft) or {}
  for _, excluded_bt in ipairs(excluded_bts) do
    if bt == excluded_bt then
      return false
    end
  end

  return M.resolve_config(buf, "enabled", ft) == true
end

return M
