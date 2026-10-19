--- Health check diagnostic module for indentinator.nvim.
--- Verifies Neovim 0.10+ environment, viewport extmark rendering, Treesitter query support, and configuration.
---@class indentinator.health
local M = {}

--- Performs health check diagnostics.
function M.check()
  vim.health.start("indentinator")

  local v = vim.version()
  if v and (v.major > 0 or v.minor >= 10) then
    vim.health.ok(
      ("Neovim %d.%d.%d supported (0.10+ extmark API & Treesitter ready)"):format(
        v.major or 0,
        v.minor or 0,
        v.patch or 0
      )
    )
  else
    vim.health.error("Neovim 0.10+ required for the extmark API and viewport rendering")
  end

  local ind = require("indentinator")
  local c = ind.config
  local ind_cfg = c.indent or {}
  local scope_cfg = c.scope or {}
  local rainbow_cfg = ind_cfg.rainbow or {}
  local delim_cfg = c.delimiters or {}

  vim.health.info(
    ("enabled=%s debounce_ms=%d max_file_lines=%s viewport_buffer=%s priority=%s"):format(
      tostring(c.enabled),
      c.debounce_ms or 0,
      tostring(c.max_file_lines),
      tostring(c.viewport_buffer),
      tostring(c.priority)
    )
  )
  vim.health.info(
    ("indent.enabled=%s indent.show_empty=%s indent.char=%q"):format(
      tostring(ind_cfg.enabled),
      tostring(ind_cfg.show_empty),
      tostring(ind_cfg.char)
    )
  )
  vim.health.info(("indent.hl=%s rainbow.enabled=%s"):format(tostring(ind_cfg.hl), tostring(rainbow_cfg.enabled)))
  vim.health.info(
    ("scope.enabled=%s show_empty=%s rainbow=%s char=%q style=%q corners=%s (top=%q, bot=%q) treesitter=%s"):format(
      tostring(scope_cfg.enabled),
      tostring(scope_cfg.show_empty),
      tostring(scope_cfg.rainbow),
      tostring(scope_cfg.char),
      tostring(scope_cfg.corner_style),
      tostring(scope_cfg.corners),
      tostring(scope_cfg.char_top),
      tostring(scope_cfg.char_bottom),
      tostring(scope_cfg.treesitter)
    )
  )
  vim.health.info(
    ("delimiters.enabled=%s rainbow=%s bold=%s italic=%s underline=%s hl=%s"):format(
      tostring(delim_cfg.enabled),
      tostring(delim_cfg.rainbow),
      tostring(delim_cfg.bold),
      tostring(delim_cfg.italic),
      tostring(delim_cfg.underline),
      tostring(delim_cfg.hl)
    )
  )

  if scope_cfg.treesitter then
    if vim.treesitter and vim.treesitter.get_parser then
      vim.health.ok("vim.treesitter is available for active scope AST resolution")

      -- Probe the parser for the current buffer's filetype so a missing parser
      -- is visible before it silently falls back to indentation scanning.
      local buf = vim.api.nvim_get_current_buf()
      local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
      if not ft or ft == "" then
        vim.health.info("current buffer has no filetype; skipping parser probe")
      else
        local ok_parser = pcall(vim.treesitter.get_parser, buf, ft)
        if ok_parser then
          vim.health.ok(("Treesitter parser available for %q"):format(ft))
        else
          vim.health.info(("No Treesitter parser for %q; indentation fallback will be used"):format(ft))
        end
      end
    else
      vim.health.warn("scope.treesitter option is enabled but vim.treesitter is not available")
    end
  end

  local exclude = c.exclude or {}
  local filetypes = exclude.filetypes or {}
  local buftypes = exclude.buftypes or {}
  if #filetypes > 0 then
    vim.health.info("excluded filetypes: " .. table.concat(filetypes, ", "))
  end
  if #buftypes > 0 then
    vim.health.info("excluded buftypes: " .. table.concat(buftypes, ", "))
  end
end

return M
