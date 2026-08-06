-- Diagnostics and health checks for the indentinator plugin
local M = {}

---@class IndentinatorHealth
---@field start fun(name: string) Initialise a health report section
---@field ok fun(msg: string) Report a successful health check
---@field warn fun(msg: string) Report a warning health check
---@field error fun(msg: string) Report an error health check
---@field info fun(msg: string) Report an informational health check

---@type IndentinatorHealth
local health = vim.health or {
  start = function(name) vim.fn["health#report_start"](name) end,
  ok = function(msg) vim.fn["health#report_ok"](msg) end,
  warn = function(msg) vim.fn["health#report_warn"](msg) end,
  error = function(msg) vim.fn["health#report_error"](msg) end,
  info = function(msg) vim.fn["health#report_info"](msg) end,
}

--- Runs a suite of health checks to ensure Neovim features and plugin configuration are valid.
function M.check()
  health.start("indentinator")

  local v = vim.version()
  if v and (v.major > 0 or v.minor >= 10) then
    health.ok(("Neovim %s (extmark virt_text overlay is supported)"):format(vim.fn.string(v)))
  else
    health.error("Neovim 0.10+ is required (uses modern extmark layout features)")
  end

  if vim.uv and vim.uv.new_timer then
    health.ok("vim.uv timers are available")
  else
    health.error("vim.uv.new_timer is not available")
  end

  local ok = pcall(vim.api.nvim_buf_set_extmark, 0, 0, 0, 0, {
    virt_text = { { " ", "IndentinatorGuide" } },
    virt_text_pos = "overlay",
  })
  if ok then
    health.ok("extmark overlay virt_text works correctly")
  else
    health.error("extmark overlay virt_text failed: " .. tostring(ok))
  end

  local ind = require("indentinator")
  local c = ind.config
  health.info(("enabled=%s smart=%s char=%q indent_width=%s"):format(
    tostring(c.enabled), tostring(c.smart), c.char, tostring(c.indent_width)
  ))
  health.info(("show_first_indent_level=%s draw_gap_hl=%s"):format(
    tostring(c.show_first_indent_level), tostring(c.draw_gap_hl)
  ))
  local scope = c.scope or {}
  health.info(("scope.enabled=%s scope.range=%s scope.underline=%s scope.text_highlight=%s"):format(
    tostring(scope.enabled), tostring(scope.range), tostring(scope.underline), tostring(scope.text_highlight)
  ))
  health.info(("current_char_hl=%s scope_underline_hl=%s exclude_fn_configured=%s"):format(
    tostring(c.current_char_hl), tostring(c.scope_underline_hl), tostring(c.exclude_fn ~= nil)
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