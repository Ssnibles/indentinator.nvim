--- Health check diagnostic module for indentinator.nvim.

local M = {}

---@class IndentinatorHealthReporter
---@field start fun(name: string) Initialise health section
---@field ok fun(msg: string) Report check success
---@field warn fun(msg: string) Report check warning
---@field error fun(msg: string) Report check error
---@field info fun(msg: string) Report check informational message

--- Health API compatibility wrapper
---@type IndentinatorHealthReporter
local health = vim.health or {
  start = function(name) vim.fn["health#report_start"](name) end,
  ok = function(msg) vim.fn["health#report_ok"](msg) end,
  warn = function(msg) vim.fn["health#report_warn"](msg) end,
  error = function(msg) vim.fn["health#report_error"](msg) end,
  info = function(msg) vim.fn["health#report_info"](msg) end,
}

--- Performs health check diagnostics.
function M.check()
  health.start("indentinator")

  local v = vim.version()
  if v and (v.major > 0 or v.minor >= 10) then
    health.ok(("Neovim %s supported"):format(vim.fn.string(v)))
  else
    health.error("Neovim 0.10+ recommended for extmark scope features")
  end

  local ind = require("indentinator")
  local c = ind.config
  local ind_cfg = c.indent or {}
  local scope_cfg = c.scope or {}

  health.info(("enabled=%s priority=%s"):format(tostring(c.enabled), tostring(c.priority)))
  health.info(("indent.enabled=%s indent.char=%q indent.hl=%s"):format(
    tostring(ind_cfg.enabled), tostring(ind_cfg.char), tostring(ind_cfg.hl)
  ))
  health.info(("scope.enabled=%s scope.char=%q scope.hl=%s scope.treesitter=%s"):format(
    tostring(scope_cfg.enabled), tostring(scope_cfg.char), tostring(scope_cfg.hl), tostring(scope_cfg.treesitter)
  ))

  if scope_cfg.treesitter then
    if vim.treesitter and vim.treesitter.get_parser then
      health.ok("Treesitter is available for active scope calculation")
    else
      health.warn("scope.treesitter option is enabled but vim.treesitter is not available")
    end
  end

  if #c.exclude.filetypes > 0 then
    health.info("excluded filetypes: " .. table.concat(c.exclude.filetypes, ", "))
  end
  if #c.exclude.buftypes > 0 then
    health.info("excluded buftypes: " .. table.concat(c.exclude.buftypes, ", "))
  end
end

return M