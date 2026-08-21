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

vim.api.nvim_create_user_command("IndentinatorEnable", cmd(function()
  ind.enable()
end), { desc = "Enable indent & scope guides for current buffer" })

vim.api.nvim_create_user_command("IndentinatorDisable", cmd(function()
  ind.disable()
end), { desc = "Disable indent & scope guides for current buffer" })

vim.api.nvim_create_user_command("IndentinatorToggle", cmd(function(opts)
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
end), { desc = "Toggle indent & scope guides (use ! to toggle across active buffers)", bang = true })

vim.api.nvim_create_user_command("IndentinatorIndentToggle", cmd(function()
  local curr = ind.config.indent.enabled ~= false
  ind.config.indent.enabled = not curr
  ind.force_update()
end), { desc = "Toggle standard indentation guides" })

vim.api.nvim_create_user_command("IndentinatorScopeToggle", cmd(function()
  local curr = ind.config.scope.enabled ~= false
  ind.config.scope.enabled = not curr
  ind.force_update()
end), { desc = "Toggle active scope guide" })

vim.api.nvim_create_user_command("IndentinatorRainbowToggle", cmd(function()
  ind.config.indent.rainbow = ind.config.indent.rainbow or {}
  local curr = ind.config.indent.rainbow.enabled == true
  ind.config.indent.rainbow.enabled = not curr
  ind.force_update()
end), { desc = "Toggle rainbow indent guide colors" })

vim.api.nvim_create_user_command("IndentinatorCornersToggle", cmd(function()
  local curr = ind.config.scope.corners ~= false
  ind.config.scope.corners = not curr
  ind.force_update()
end), { desc = "Toggle active scope boundary corners" })

vim.api.nvim_create_user_command("IndentinatorHealth", cmd(function()
  vim.cmd("checkhealth indentinator")
end), { desc = "Run indentinator health check" })
