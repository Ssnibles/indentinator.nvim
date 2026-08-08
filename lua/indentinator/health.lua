--- Health check diagnostic module for indentinator.nvim.

local M = {}

---@class IndentinatorHealthReporter
---@field start fun(name: string) Initialise health section
---@field ok fun(msg: string) Report check success
---@field warn fun(msg: string) Report check warning
---@field error fun(msg: string) Report check error
---@field info fun(msg: string) Report check informational message

--- Health API compatibility wrapper for Neovim versions
---@type IndentinatorHealthReporter
local health = vim.health or {
  start = function(name) vim.fn["health#report_start"](name) end,
  ok = function(msg) vim.fn["health#report_ok"](msg) end,
  warn = function(msg) vim.fn["health#report_warn"](msg) end,
  error = function(msg) vim.fn["health#report_error"](msg) end,
  info = function(msg) vim.fn["health#report_info"](msg) end,
}

--- Performs health check diagnostics for environment support and plugin configuration.
function M.check()
  health.start("indentinator")

  local v = vim.version()
  if v and (v.major > 0 or v.minor >= 10) then
    health.ok(("Neovim %s (extmark virt_text overlay supported)"):format(vim.fn.string(v)))
  else
    health.error("Neovim 0.10+ required for extmark overlay features")
  end

  if vim.uv and vim.uv.new_timer then
    health.ok("vim.uv.new_timer is available")
  else
    health.error("vim.uv.new_timer is not available")
  end

  local ns = vim.api.nvim_create_namespace("indentinator_health_test")
  local ok, err_or_id = pcall(vim.api.nvim_buf_set_extmark, 0, ns, 0, 0, {
    virt_text = { { " ", "IndentinatorGuide" } },
    virt_text_pos = "overlay",
  })
  if ok then
    pcall(vim.api.nvim_buf_clear_namespace, 0, ns, 0, -1)
    health.ok("extmark overlay virt_text operating correctly")
  else
    health.error("extmark overlay virt_text failed: " .. tostring(err_or_id))
  end

  local ind = require("indentinator")
  local config_mod = require("indentinator.config")
  local c = ind.config
  local char_val = config_mod.resolve_config(0, "char")

  health.info(("enabled=%s smart=%s char=%q indent_width=%s"):format(
    tostring(c.enabled), tostring(c.smart), char_val, tostring(c.indent_width)
  ))
  health.info(("show_first_indent_level=%s draw_gap_hl=%s"):format(
    tostring(c.show_first_indent_level), tostring(c.draw_gap_hl)
  ))

  local scope_cfg = c.scope or {}
  health.info(
    ("scope.enabled=%s scope.range=%s scope.bg=%s scope.delims=%s scope.text_hl=%s scope.ts=%s"):format(
      tostring(scope_cfg.enabled),
      tostring(scope_cfg.range),
      tostring(scope_cfg.background),
      tostring(scope_cfg.delimiters),
      tostring(scope_cfg.text_highlight),
      tostring(scope_cfg.treesitter)
    )
  )

  if scope_cfg.treesitter then
    if vim.treesitter and vim.treesitter.get_parser then
      health.ok("Treesitter is available for scope calculation")
    else
      health.warn("scope.treesitter is enabled but vim.treesitter is not available")
    end
  end

  health.info(("current_char_hl=%s scope_bg_hl=%s scope_delimiter_hl=%s exclude_fn_configured=%s"):format(
    tostring(c.current_char_hl), tostring(c.scope_bg_hl), tostring(c.scope_delimiter_hl), tostring(c.exclude_fn ~= nil)
  ))

  if #c.exclude > 0 then
    health.info("excluded filetypes: " .. table.concat(c.exclude, ", "))
  end
  if #c.exclude_buftypes > 0 then
    health.info("excluded buftypes: " .. table.concat(c.exclude_buftypes, ", "))
  end
  if vim.tbl_count(c.filetypes or {}) > 0 then
    health.info("custom filetype overrides configured for: " .. table.concat(vim.tbl_keys(c.filetypes), ", "))
  end
end

return M