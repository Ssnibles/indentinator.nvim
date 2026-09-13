--- Configuration module for indentinator.nvim.
--- Handles user options merging, corner presets, Luadoc typing, and buffer enablement checks.
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

---@class indentinator.ScopeConfig
---@field enabled boolean Whether active scope indicator is enabled
---@field show_empty boolean Whether to render scope guide on empty/whitespace lines
---@field rainbow boolean Whether to cycle active scope colors through rainbow palette
---@field corner_style "sharp"|"round"|"double"|"bold" Preset style for scope corners
---@field char string Active scope delimiter character
---@field char_top string Top boundary corner character
---@field char_bottom string Bottom boundary corner character
---@field corners boolean Whether to render corner delimiters at scope boundaries
---@field hl string Highlight group name for active scope guide
---@field hl_header string|nil Optional highlight group for scope header line
---@field treesitter boolean Whether to use Treesitter AST for active scope calculation

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
---@field priority integer Base extmark priority
---@field indent indentinator.IndentConfig Passive indent guides options
---@field scope indentinator.ScopeConfig Active scope guide options
---@field delimiters indentinator.DelimitersConfig Scope boundary delimiter options
---@field exclude indentinator.ExcludeConfig Exclusions options

--- Boundary corner character presets mapping
M.CORNER_PRESETS = {
  sharp = { char_top = "┌", char_bottom = "└" },
  round = { char_top = "╭", char_bottom = "╰" },
  double = { char_top = "╔", char_bottom = "╚" },
  bold = { char_top = "┏", char_bottom = "┗" },
}

--- Default plugin configuration values.
---@type indentinator.Config
M.defaults = {
  enabled = true,
  debounce_ms = 10,
  max_file_lines = 10000,
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
    corners = true,
    hl = "IndentinatorScope",
    hl_header = nil,
    treesitter = true,
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

--- Fast lookup sets for excluded buftypes and filetypes.
local exclude_buftypes_set = {}
local exclude_filetypes_set = {}

--- Rebuilds exclude lookup sets using vim.iter.
local function rebuild_exclude_sets()
  exclude_buftypes_set = {}
  exclude_filetypes_set = {}
  if M.values.exclude then
    if M.values.exclude.buftypes then
      vim.iter(M.values.exclude.buftypes):each(function(bt)
        exclude_buftypes_set[bt] = true
      end)
    end
    if M.values.exclude.filetypes then
      vim.iter(M.values.exclude.filetypes):each(function(ft)
        exclude_filetypes_set[ft] = true
      end)
    end
  end
end
rebuild_exclude_sets()

--- Merges user options into configuration values.
---@param opts indentinator.Config|table|nil User configuration options
function M.setup(opts)
  if type(opts) ~= "table" then
    return
  end

  -- Handle boolean shorthand configs before deep merge
  local normalised = vim.deepcopy(opts)
  if type(normalised.indent) == "boolean" then
    normalised.indent = { enabled = normalised.indent }
  end
  if type(normalised.scope) == "boolean" then
    normalised.scope = { enabled = normalised.scope }
  end
  if type(normalised.delimiters) == "boolean" then
    normalised.delimiters = { enabled = normalised.delimiters }
  end

  -- Deep merge normalised options
  M.values = vim.tbl_deep_extend("force", M.values, normalised)

  -- Flat options support for user convenience
  if opts.char then
    M.values.indent.char = opts.char
    M.values.scope.char = opts.char
  end
  if opts.hl then
    M.values.scope.hl = opts.hl
  end
  if opts.treesitter ~= nil then
    M.values.scope.treesitter = opts.treesitter
  end
  if opts.scope_rainbow ~= nil then
    M.values.scope.rainbow = opts.scope_rainbow
  end
  if opts.rainbow_delimiters ~= nil then
    M.values.delimiters.rainbow = opts.rainbow_delimiters
  end
  if type(opts.scope) == "table" and opts.scope.rainbow_delimiters ~= nil then
    M.values.delimiters.rainbow = opts.scope.rainbow_delimiters
  end

  -- Apply corner preset if specified and characters were not explicitly provided
  local scope_opt = type(opts.scope) == "table" and opts.scope or nil
  if scope_opt and scope_opt.corner_style and M.CORNER_PRESETS[scope_opt.corner_style] then
    local preset = M.CORNER_PRESETS[scope_opt.corner_style]
    if scope_opt.char_top == nil then
      M.values.scope.char_top = preset.char_top
    end
    if scope_opt.char_bottom == nil then
      M.values.scope.char_bottom = preset.char_bottom
    end
  end

  rebuild_exclude_sets()
end

--- Checks if plugin features are enabled for a given buffer.
---@param buf integer Buffer handle
---@param state_enabled boolean|nil Buffer-specific explicit enablement override
---@return boolean True if guides should run for this buffer
function M.is_enabled(buf, state_enabled)
  if not buf or not api.nvim_buf_is_valid(buf) then
    return false
  end

  if state_enabled ~= nil then
    return state_enabled
  end

  if not M.values.enabled then
    return false
  end

  local ok_bt, bt = pcall(api.nvim_get_option_value, "buftype", { buf = buf })
  if ok_bt and type(bt) == "string" and bt ~= "" and exclude_buftypes_set[bt] then
    return false
  end

  local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = buf })
  if ok_ft and type(ft) == "string" and ft ~= "" and exclude_filetypes_set[ft] then
    return false
  end

  return true
end

return M
