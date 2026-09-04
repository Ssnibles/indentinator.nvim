--- Configuration module for indentinator.nvim.
--- Handles user settings, defaults, corner presets, and buffer enablement checks.

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
M.values = vim.deepcopy(M.defaults)

--- Fast lookup sets for excluded buftypes and filetypes.
local exclude_buftypes_set = {}
local exclude_filetypes_set = {}

local function rebuild_exclude_sets()
  exclude_buftypes_set = {}
  exclude_filetypes_set = {}
  if M.values.exclude then
    for _, bt in ipairs(M.values.exclude.buftypes or {}) do
      exclude_buftypes_set[bt] = true
    end
    for _, ft in ipairs(M.values.exclude.filetypes or {}) do
      exclude_filetypes_set[ft] = true
    end
  end
end
rebuild_exclude_sets()

--- Merges user options into configuration values.
---@param opts table|nil User configuration options
function M.setup(opts)
  if type(opts) ~= "table" then
    return
  end

  -- Handle boolean shorthand configs before merging
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
