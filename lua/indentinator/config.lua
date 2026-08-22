--- Configuration module for indentinator.nvim.
--- Handles user settings, defaults, and buffer enablement checks for indent and scope guides.

---@class IndentinatorRainbowConfig
---@field enabled boolean Whether rainbow indent colors are enabled (default false)
---@field colors string[] Array of hex color strings for rainbow levels

---@class IndentinatorIndentConfig
---@field enabled boolean Whether normal indent guides across all levels are enabled (default true)
---@field show_empty boolean Whether normal indent guides render on blank lines (default true)
---@field char string Standard guide character (default "│")
---@field hl string Highlight group name for standard guides (default "IndentinatorIndent")
---@field rainbow IndentinatorRainbowConfig Rainbow indent guides configuration

---@class IndentinatorDelimitersConfig
---@field enabled boolean Whether boundary delimiter highlighting is enabled (default true)
---@field keywords boolean Whether Treesitter scope keywords (if, then, end, function, etc.)
---  are highlighted as delimiters (default true)
---@field rainbow boolean Whether delimiters use depth-level rainbow colors (default false)
---@field bold boolean Whether delimiters render in bold (default false)
---@field italic boolean Whether delimiters render in italic (default false)
---@field underline boolean Whether delimiters render with underline (default false)
---@field hl string|nil Optional custom highlight group name for delimiters

---@class IndentinatorScopeConfig
---@field enabled boolean Whether active scope guide highlighting is enabled (default true)
---@field show_empty boolean Whether scope guide highlighting renders on blank lines (default true)
---@field rainbow boolean Whether active scope line uses level rainbow colors (default false)
---@field char string Active scope guide character (default "│")
---@field corner_style string Boundary corner style preset ("sharp", "round", "double", "bold") (default "sharp")
---@field char_top string Top corner boundary character (default "┌")
---@field char_bottom string Bottom corner boundary character (default "└")
---@field corners boolean Whether top and bottom boundary corners are rendered (default true)
---@field hl string Highlight group name for active scope guide (default "IndentinatorScope")
---@field hl_header string|nil Optional highlight group name for scope header line
---@field treesitter boolean Whether Treesitter scope detection is enabled (default true)

---@class IndentinatorConfig
---@field enabled boolean Whether plugin is globally enabled
---@field debounce_ms integer Debounce delay in milliseconds for cursor/scroll updates (default 10)
---@field max_file_lines integer Maximum file line count before rendering is skipped (default 10000)
---@field indent IndentinatorIndentConfig Standard indentation guides config
---@field scope IndentinatorScopeConfig Active scope guide config
---@field delimiters IndentinatorDelimitersConfig Scope boundary delimiters config
---@field priority integer Extmark priority (default 100)
---@field exclude table Excluded filetypes and buftypes

local api = vim.api

local M = {}

--- Boundary corner character presets mapping
M.CORNER_PRESETS = {
  sharp = { char_top = "┌", char_bottom = "└" },
  round = { char_top = "╭", char_bottom = "╰" },
  double = { char_top = "╔", char_bottom = "╚" },
  bold = { char_top = "┏", char_bottom = "┗" },
}

--- Default configuration values.
---@type IndentinatorConfig
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
---@type IndentinatorConfig
M.values = vim.deepcopy(M.defaults)

--- Merges user options into configuration values.
---@param opts table|nil User configuration options
function M.setup(opts)
  if type(opts) ~= "table" then
    return
  end

  if opts.enabled ~= nil then
    M.values.enabled = opts.enabled
  end
  if opts.debounce_ms ~= nil then
    M.values.debounce_ms = opts.debounce_ms
  end
  if opts.max_file_lines ~= nil then
    M.values.max_file_lines = opts.max_file_lines
  end
  if opts.priority ~= nil then
    M.values.priority = opts.priority
  end

  if type(opts.indent) == "table" then
    M.values.indent = vim.tbl_deep_extend("force", M.values.indent, opts.indent)
  elseif type(opts.indent) == "boolean" then
    M.values.indent.enabled = opts.indent
  end

  if type(opts.delimiters) == "table" then
    M.values.delimiters = vim.tbl_deep_extend("force", M.values.delimiters, opts.delimiters)
  elseif type(opts.delimiters) == "boolean" then
    M.values.delimiters.enabled = opts.delimiters
  end

  if type(opts.scope) == "table" then
    M.values.scope = vim.tbl_deep_extend("force", M.values.scope, opts.scope)
    if opts.scope.rainbow_delimiters ~= nil then
      M.values.delimiters.rainbow = opts.scope.rainbow_delimiters
    end
    if opts.scope.corner_style and M.CORNER_PRESETS[opts.scope.corner_style] then
      local preset = M.CORNER_PRESETS[opts.scope.corner_style]
      if opts.scope.char_top == nil then
        M.values.scope.char_top = preset.char_top
      end
      if opts.scope.char_bottom == nil then
        M.values.scope.char_bottom = preset.char_bottom
      end
    end
  elseif type(opts.scope) == "boolean" then
    M.values.scope.enabled = opts.scope
  end

  -- Flat options support for convenience
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

  if type(opts.exclude) == "table" then
    if opts.exclude.filetypes then
      M.values.exclude.filetypes = opts.exclude.filetypes
    end
    if opts.exclude.buftypes then
      M.values.exclude.buftypes = opts.exclude.buftypes
    end
  end
end

--- Pre-built set of excluded buftypes for O(1) lookup.
---@param buf integer Buffer handle
---@return boolean True if buftype is excluded
local function is_buftype_excluded(buf)
  local ok, bt = pcall(function() return vim.bo[buf].buftype end)
  if not ok or type(bt) ~= "string" or bt == "" then
    return false
  end
  local excluded = M.values.exclude.buftypes or {}
  for _, ex_bt in ipairs(excluded) do
    if bt == ex_bt then
      return true
    end
  end
  return false
end

--- Checks if a buffer filetype is excluded.
---@param buf integer Buffer handle
---@return boolean True if filetype is excluded
local function is_filetype_excluded(buf)
  local ok, ft = pcall(function() return vim.bo[buf].filetype end)
  if not ok or type(ft) ~= "string" or ft == "" then
    return false
  end
  local excluded = M.values.exclude.filetypes or {}
  for _, ex_ft in ipairs(excluded) do
    if ft == ex_ft then
      return true
    end
  end
  return false
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

  if is_buftype_excluded(buf) then
    return false
  end

  if is_filetype_excluded(buf) then
    return false
  end

  return true
end

return M
