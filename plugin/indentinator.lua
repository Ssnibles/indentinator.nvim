--- User commands registration for indentinator.nvim.

local ind = require("indentinator")

ind.setup()

--- Wraps a command callback in safe execution and notifies errors.
---@param fn fun(opts: table) Command callback
---@return fun(opts: table) Wrapper function
local function cmd(fn)
  return function(opts)
    local ok, err = pcall(fn, opts)
    if not ok then
      vim.notify("indentinator: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

vim.api.nvim_create_user_command(
  "IndentinatorEnable",
  cmd(function()
    ind.enable()
  end),
  { desc = "Enable indent & scope guides for current buffer" }
)

vim.api.nvim_create_user_command(
  "IndentinatorDisable",
  cmd(function()
    ind.disable()
  end),
  { desc = "Disable indent & scope guides for current buffer" }
)

vim.api.nvim_create_user_command(
  "IndentinatorToggle",
  cmd(function(opts)
    if opts.bang then
      local processed = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
        if ok and buf and not processed[buf] then
          processed[buf] = true
          ind.toggle(buf)
        end
      end
    else
      ind.toggle()
    end
  end),
  { desc = "Toggle indent & scope guides (use ! to toggle across active buffers)", bang = true }
)

-- The toggles below go through `ind.update()` so `finalize()` re-runs and the
-- memoized per-buffer resolved configs are invalidated, keeping buffers with
-- per-buffer overrides in sync with the global switches.

vim.api.nvim_create_user_command(
  "IndentinatorIndentToggle",
  cmd(function()
    local enabled = ind.config.indent.enabled ~= false
    ind.update({ indent = { enabled = not enabled } })
  end),
  { desc = "Toggle standard indentation guides" }
)

vim.api.nvim_create_user_command(
  "IndentinatorScopeToggle",
  cmd(function()
    local enabled = ind.config.scope.enabled ~= false
    ind.update({ scope = { enabled = not enabled } })
  end),
  { desc = "Toggle active scope guide" }
)

vim.api.nvim_create_user_command(
  "IndentinatorRainbowToggle",
  cmd(function()
    local rainbow = ind.config.indent.rainbow or {}
    ind.update({ indent = { rainbow = { enabled = rainbow.enabled ~= true } } })
  end),
  { desc = "Toggle rainbow indent guide colors" }
)

vim.api.nvim_create_user_command(
  "IndentinatorCornersToggle",
  cmd(function()
    local corners = ind.config.scope.corners ~= false
    ind.update({ scope = { corners = not corners } })
  end),
  { desc = "Toggle active scope boundary corners" }
)

vim.api.nvim_create_user_command(
  "IndentinatorScopeRainbowToggle",
  cmd(function()
    local rainbow = ind.config.scope.rainbow == true
    ind.update({ scope = { rainbow = not rainbow } })
  end),
  { desc = "Toggle rainbow active scope line colors" }
)

vim.api.nvim_create_user_command(
  "IndentinatorDelimitersToggle",
  cmd(function()
    local delimiters = ind.config.delimiters or {}
    ind.update({ delimiters = { enabled = delimiters.enabled == false } })
  end),
  { desc = "Toggle scope boundary delimiter highlighting" }
)

vim.api.nvim_create_user_command(
  "IndentinatorDelimitersRainbowToggle",
  cmd(function()
    local delimiters = ind.config.delimiters or {}
    ind.update({ delimiters = { rainbow = delimiters.rainbow ~= true } })
  end),
  { desc = "Toggle rainbow scope boundary delimiter colors" }
)

vim.api.nvim_create_user_command(
  "IndentinatorJumpTop",
  cmd(function()
    ind.jump_to_scope_start()
  end),
  { desc = "Jump cursor to top boundary of active scope" }
)

vim.api.nvim_create_user_command(
  "IndentinatorJumpBottom",
  cmd(function()
    ind.jump_to_scope_end()
  end),
  { desc = "Jump cursor to bottom boundary of active scope" }
)

vim.api.nvim_create_user_command(
  "IndentinatorHealth",
  cmd(function()
    vim.cmd("checkhealth indentinator")
  end),
  { desc = "Run indentinator health check" }
)
