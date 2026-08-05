local ind = require("indentinator")

ind.setup()

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
end), { desc = "Enable indent guides for the current buffer" })

vim.api.nvim_create_user_command("IndentinatorDisable", cmd(function()
  ind.disable()
end), { desc = "Disable indent guides for the current buffer" })

vim.api.nvim_create_user_command("IndentinatorToggle", cmd(function(opts)
  if opts.bang then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok then ind.toggle(buf) end
    end
  else
    ind.toggle()
  end
end), { desc = "Toggle indent guides (use ! to toggle in all buffers)", bang = true })

vim.api.nvim_create_user_command("IndentinatorHealth", cmd(function()
  require("indentinator.health").check()
end), { desc = "Run indentinator health check" })
