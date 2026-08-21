--- Configuration module for indentinator.nvim.
--- Handles user settings, defaults, and buffer enablement checks for indent and scope guides.

---@class IndentinatorIndentConfig
---@field enabled boolean Whether normal indent guides across all levels are enabled (default true)
---@field char string Standard guide character (default "│")
---@field hl string Highlight group name for standard guides (default "IndentinatorIndent")

---@class IndentinatorScopeConfig
---@field enabled boolean Whether active scope guide highlighting is enabled (default true)
---@field char string Active scope guide character (default "│")
---@field hl string Highlight group name for scope guide (default "IndentinatorScope")
---@field treesitter boolean Whether Treesitter scope detection is enabled (default true)

---@class IndentinatorConfig
---@field enabled boolean Whether plugin is globally enabled
---@field indent IndentinatorIndentConfig Standard indentation guides config
---@field scope IndentinatorScopeConfig Active scope guide config
---@field priority integer Extmark priority (default 100)
---@field exclude table Excluded filetypes and buftypes

local M = {}

--- Default configuration values.
---@type IndentinatorConfig
M.defaults = {
  enabled = true,
  indent = {
    enabled = true,
    char = "│",
    hl = "IndentinatorIndent",
  },
  scope = {
    enabled = true,
    char = "│",
    hl = "IndentinatorScope",
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
  if opts.priority ~= nil then
    M.values.priority = opts.priority
  end

  if type(opts.indent) == "table" then
    M.values.indent = vim.tbl_deep_extend("force", M.values.indent, opts.indent)
  elseif type(opts.indent) == "boolean" then
    M.values.indent.enabled = opts.indent
  end

  if type(opts.scope) == "table" then
    M.values.scope = vim.tbl_deep_extend("force", M.values.scope, opts.scope)
  elseif type(opts.scope) == "boolean" then
    M.values.scope.enabled = opts.scope
  end

  -- Flat options support for backward compatibility
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

  if type(opts.exclude) == "table" then
    if opts.exclude.filetypes then
      M.values.exclude.filetypes = opts.exclude.filetypes
    end
    if opts.exclude.buftypes then
      M.values.exclude.buftypes = opts.exclude.buftypes
    end
  end
end

--- Checks if plugin features are enabled for a given buffer.
---@param buf integer Buffer handle
---@param state_enabled boolean|nil Buffer-specific explicit enablement override
---@return boolean True if guides should run for this buffer
function M.is_enabled(buf, state_enabled)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  if state_enabled ~= nil then
    return state_enabled
  end

  if not M.values.enabled then
    return false
  end

  -- Check excluded buftype
  local ok_bt, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
  if ok_bt and bt and type(bt) == "string" and bt ~= "" then
    for _, ex_bt in ipairs(M.values.exclude.buftypes or {}) do
      if bt == ex_bt then
        return false
      end
    end
  end

  -- Check excluded filetype
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
  if ok_ft and ft and type(ft) == "string" and ft ~= "" then
    for _, ex_ft in ipairs(M.values.exclude.filetypes or {}) do
      if ft == ex_ft then
        return false
      end
    end
  end

  return true
end

return M
