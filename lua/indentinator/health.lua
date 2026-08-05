local M = {}

local health = vim.health or {
  start = function(name) vim.fn["health#report_start"](name) end,
  ok = function(msg) vim.fn["health#report_ok"](msg) end,
  warn = function(msg) vim.fn["health#report_warn"](msg) end,
  error = function(msg) vim.fn["health#report_error"](msg) end,
  info = function(msg) vim.fn["health#report_info"](msg) end,
}

function M.check()
  health.start("indentinator")

  local v = vim.version()
  if v and (v.major > 0 or v.minor >= 10) then
    health.ok(("Neovim %s (extmark virt_text chunks supported)"):format(vim.fn.string(v)))
  else
    health.error("Neovim 0.10+ is required (uses vim.uv timers and extmark chunks)")
  end

  if vim.uv and vim.uv.new_timer then
    health.ok("vim.uv timers available")
  else
    health.error("vim.uv.new_timer not available")
  end

  local ok = pcall(vim.api.nvim_buf_set_extmark, 0, 0, 0, 0, {
    virt_text = { { " ", "IndentinatorGuide" } },
    virt_text_pos = "overlay",
  })
  if ok then
    health.ok("extmark overlay virt_text works")
  else
    health.error("extmark overlay virt_text failed: " .. tostring(ok))
  end

  local ind = require("indentinator")
  local c = ind.config
  health.info(("enabled=%s smart=%s char=%q indent_width=%s"):format(
    tostring(c.enabled), tostring(c.smart), c.char, tostring(c.indent_width)
  ))
  health.info(("show_first_indent_level=%s draw_gap_hl=%s exclude=%s"):format(
    tostring(c.show_first_indent_level), tostring(c.draw_gap_hl), vim.inspect(c.exclude)
  ))
  health.info(("show_current_indent=%s current_char_hl=%s"):format(
    tostring(c.show_current_indent), tostring(c.current_char_hl)
  ))
  if #c.exclude > 0 then
    health.info("excluded filetypes: " .. table.concat(c.exclude, ", "))
  end
end

return M