--- User command registration for indentinator.nvim.

local ind = require("indentinator")

ind.setup()

--- Wraps a command callback so errors are reported instead of aborting.
---@param fn fun(opts: table) Command callback
---@return fun(opts: table) Wrapper function
local function notify_on_error(fn)
  return function(opts)
    local ok, err = pcall(fn, opts)
    if not ok then
      vim.notify("indentinator: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Defines a user command with error reporting.
---@param name string Command name
---@param desc string Command description
---@param fn fun(opts: table)
---@param opts table|nil Extra command options
local function define(name, desc, fn, opts)
  opts = opts or {}
  opts.desc = desc
  vim.api.nvim_create_user_command(name, notify_on_error(fn), opts)
end

local function toggle_across_windows()
  local seen = {}
  vim.iter(vim.api.nvim_list_wins()):each(function(win)
    local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
    if ok and buf and not seen[buf] then
      seen[buf] = true
      ind.toggle(buf)
    end
  end)
end

define("IndentinatorEnable", "Enable indent & scope guides for current buffer", function()
  ind.enable()
end)

define("IndentinatorDisable", "Disable indent & scope guides for current buffer", function()
  ind.disable()
end)

define("IndentinatorToggle", "Toggle indent & scope guides (use ! for all active buffers)", function(opts)
  if opts.bang then
    toggle_across_windows()
  else
    ind.toggle()
  end
end, { bang = true })

-- Toggles go through `ind.update()` so resolved per-buffer configs are invalidated.

local toggles = {
  {
    name = "IndentinatorIndentToggle",
    desc = "Toggle standard indentation guides",
    run = function()
      ind.update({ indent = { enabled = ind.config.indent.enabled == false } })
    end,
  },
  {
    name = "IndentinatorScopeToggle",
    desc = "Toggle active scope guide",
    run = function()
      ind.update({ scope = { enabled = ind.config.scope.enabled == false } })
    end,
  },
  {
    name = "IndentinatorRainbowToggle",
    desc = "Toggle rainbow indent guide colours",
    run = function()
      local rainbow = ind.config.indent.rainbow or {}
      ind.update({ indent = { rainbow = { enabled = rainbow.enabled ~= true } } })
    end,
  },
  {
    name = "IndentinatorCornersToggle",
    desc = "Toggle active scope boundary corners",
    run = function()
      ind.update({ scope = { corners = ind.config.scope.corners == false } })
    end,
  },
  {
    name = "IndentinatorScopeRainbowToggle",
    desc = "Toggle rainbow active scope line colours",
    run = function()
      ind.update({ scope = { rainbow = ind.config.scope.rainbow ~= true } })
    end,
  },
  {
    name = "IndentinatorDelimitersToggle",
    desc = "Toggle scope boundary delimiter highlighting",
    run = function()
      local delimiters = ind.config.delimiters or {}
      ind.update({ delimiters = { enabled = delimiters.enabled ~= true } })
    end,
  },
  {
    name = "IndentinatorDelimitersRainbowToggle",
    desc = "Toggle rainbow scope boundary delimiter colours",
    run = function()
      local delimiters = ind.config.delimiters or {}
      ind.update({ delimiters = { rainbow = delimiters.rainbow ~= true } })
    end,
  },
}

for _, toggle in ipairs(toggles) do
  define(toggle.name, toggle.desc, toggle.run)
end

define("IndentinatorJumpTop", "Jump cursor to top boundary of active scope", function()
  ind.jump_to_scope_start()
end)

define("IndentinatorJumpBottom", "Jump cursor to bottom boundary of active scope", function()
  ind.jump_to_scope_end()
end)

define("IndentinatorHealth", "Run indentinator health check", function()
  vim.cmd("checkhealth indentinator")
end)
