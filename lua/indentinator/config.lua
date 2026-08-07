---@class IndentinatorScopeConfig
---@field enabled boolean Whether to highlight the active scope guide
---@field range string Scope range: "block" (current block) or "global" (full column)
---@field only_scope boolean Whether to only draw the active scope column within scope boundaries
---@field background boolean|string Highlight scope background: true/"block", "boundaries", or false
---@field corner boolean Whether to draw corner characters at scope boundaries
---@field corner_top string|nil Custom top corner character
---@field corner_bottom string|nil Custom bottom corner character
---@field underline_char string|nil Custom horizontal connector character for corners
---@field text_highlight boolean Whether to colour the text on the scope-start line
---@field delimiters boolean Whether to highlight scope delimiter characters (braces, brackets, keywords)
---@field treesitter boolean Whether to use Treesitter for scope calculation (falls back to indentation if unavailable)

---@class IndentinatorConfig
---@field enabled boolean Whether the plugin is enabled globally or per-buffer
---@field smart boolean Whether blank lines inherit the indentation guides of neighbouring lines
---@field char string The character used for drawing the indentation guides
---@field current_char string|nil The character used for the active scope guide
---@field char_hl string The highlight group for standard guides
---@field gap_hl string The highlight group for gaps
---@field draw_gap_hl boolean Whether gaps should be highlighted
---@field show_first_indent_level boolean Whether the first indentation level (column 0) should be drawn
---@field indent_width number|nil Custom indentation width override (if nil, uses shiftwidth/tabstop)
---@field exclude string[] Filetypes to exclude from drawing guides
---@field exclude_buftypes string[] Buftypes to exclude from drawing guides
---@field priority number The priority level of the extmarks used for the guides
---@field scope IndentinatorScopeConfig Active scope highlighting configuration
---@field current_char_hl string The highlight group for the active guide
---@field scope_text_hl string The highlight group for the scope-start line text
---@field scope_bg_hl string The highlight group for scope boundary line background
---@field scope_delimiter_hl string The highlight group for scope delimiter characters
---@field exclude_fn (fun(buf: number): boolean)|nil Custom callback to exclude buffers
---@field filetypes table<string, table> Per-filetype configuration overrides

local M = {}

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
    current_char = "┃",
    corner_top = "╭",
    corner_bottom = "╰",
    underline_char = "─",
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

---@type IndentinatorConfig
M.defaults = {
  enabled = true,
  smart = false,
  char = nil,                        -- Standard guide character (defaults to style preset if nil)
  current_char = nil,                -- Active guide character (defaults to style preset if nil)
  style = "thick",                   -- Preset style: "thick", "thin", "double", "curved", "heavy", "dashed", "dotted"
  char_hl = "IndentinatorGuide",
  gap_hl = "IndentinatorGap",
  draw_gap_hl = false,
  show_first_indent_level = true,
  indent_width = nil,
  exclude = {},
  exclude_buftypes = { "terminal", "nofile", "quickfix", "prompt" },
  priority = 100,
  scope = {
    enabled = false,        -- highlight the active scope guide
    range = "block",        -- "block" (current block only) or "global" (entire column)
    only_scope = true,      -- only draw active scope column within scope boundaries (cut out lines outside scope)
    background = false,     -- highlight scope background: true/"block", "boundaries", or false
    corner = true,          -- draw corner characters (┏ and ┗) at scope top/bottom boundaries
    corner_top = nil,       -- custom top corner char (nil defaults to style preset, e.g. "┏")
    corner_bottom = nil,    -- custom bottom corner char (nil defaults to style preset, e.g. "┗")
    underline_char = nil,   -- horizontal character for scope top/bottom lines (nil defaults to style preset, e.g. "━")
    text_highlight = true,  -- colour the text on the scope-start line
    delimiters = false,     -- highlight delimiter characters (braces, brackets, keywords) at scope boundaries
    treesitter = false,     -- use Treesitter for active scope detection (falls back to indentation)
  },
  current_char_hl = "IndentinatorCurrentGuide",
  scope_text_hl = "IndentinatorScopeText",
  scope_bg_hl = "IndentinatorScopeBg",
  scope_delimiter_hl = "IndentinatorScopeDelimiter",
  exclude_fn = nil,
  filetypes = {},
}

--- Active configuration values table.
---@type IndentinatorConfig
M.values = vim.deepcopy(M.defaults)

--- Resolves the merged scope config for a buffer, respecting filetype overrides.
---@param buf number The buffer handle
---@param ft string|nil Optional pre-fetched filetype string
---@return IndentinatorScopeConfig The resolved scope configuration
function M.resolve_scope(buf, ft)
  local base = vim.deepcopy(M.values.scope or {})
  if not ft then
    local ok_ft, res = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
    ft = (ok_ft and res) or ""
  end
  if ft ~= "" and M.values.filetypes and M.values.filetypes[ft] then
    local ft_scope = M.values.filetypes[ft].scope
    if type(ft_scope) == "table" then
      base = vim.tbl_extend("force", base, ft_scope)
    end
  end

  if base.corners ~= nil then
    base.corner = base.corners
  elseif base.use_corners ~= nil then
    base.corner = base.use_corners
  end

  local style_name = M.resolve_config(buf, "style", ft) or "thick"
  local preset = M.STYLE_PRESETS[style_name] or M.STYLE_PRESETS.thick
  if not base.corner_top then base.corner_top = preset.corner_top end
  if not base.corner_bottom then base.corner_bottom = preset.corner_bottom end
  if not base.underline_char then base.underline_char = preset.underline_char end

  return base
end

--- Resolves a configuration option, taking into account filetype-specific overrides.
---@param buf number The buffer handle
---@param opt string The configuration key to resolve
---@param ft string|nil Optional pre-fetched filetype string
---@return any The resolved configuration value
function M.resolve_config(buf, opt, ft)
  if not ft then
    local ok_ft, res = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
    ft = (ok_ft and res) or ""
  end
  local val = nil
  if ft ~= "" and M.values.filetypes and M.values.filetypes[ft] then
    local ft_cfg = M.values.filetypes[ft]
    if ft_cfg[opt] ~= nil then
      val = ft_cfg[opt]
    end
  end
  if val == nil then
    val = M.values[opt]
  end

  if val == nil then
    local style_name = M.values.style or "thick"
    local preset = M.STYLE_PRESETS[style_name] or M.STYLE_PRESETS.thick
    if opt == "current_char" then
      val = preset.current_char
    elseif opt == "char" then
      val = preset.char
    end
  end

  return val
end

--- Checks if indentation guides are enabled for the specified buffer.
---@param buf number The buffer handle
---@param state IndentinatorState|nil State module reference
---@return boolean True if enabled, false otherwise
function M.is_enabled(buf, state)
  if not state then
    state = require("indentinator.state").state
  end
  local v = state.enabled[buf]
  if v ~= nil then return v end

  -- Exclude by custom function callback
  local exclude_fn = M.resolve_config(buf, "exclude_fn")
  if type(exclude_fn) == "function" then
    local ok, res = pcall(exclude_fn, buf)
    if ok and res then return false end
  end

  -- Exclude by filetype
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  if not ok_ft or not ft then ft = "" end
  local exclude_fts = M.resolve_config(buf, "exclude") or {}
  for _, e in ipairs(exclude_fts) do
    if ft == e then return false end
  end

  -- Exclude by buftype
  local ok_bt, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
  if not ok_bt or not bt then bt = "" end
  local exclude_bts = M.resolve_config(buf, "exclude_buftypes") or {}
  for _, e in ipairs(exclude_bts) do
    if bt == e then return false end
  end

  return M.resolve_config(buf, "enabled")
end

return M
