-- Initialise user commands and default setup for the indentinator plugin
local ind = require("indentinator")

ind.setup()

--- Wraps a function with safe execution and notifies the user of any errors.
---@param fn fun(opts: table) The command callback function
---@return fun(opts: table) The protected function execution wrapper
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
end), { desc = "Enable indentation guides for the current buffer" })

vim.api.nvim_create_user_command("IndentinatorDisable", cmd(function()
  ind.disable()
end), { desc = "Disable indentation guides for the current buffer" })

vim.api.nvim_create_user_command("IndentinatorToggle", cmd(function(opts)
  if opts.bang then
    -- Toggle guides across all active buffers displaying in any window
    local processed = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok and not processed[buf] then
        processed[buf] = true
        ind.toggle(buf)
      end
    end
  else
    ind.toggle()
  end
end), { desc = "Toggle indentation guides (use ! to toggle in all buffers)", bang = true })

vim.api.nvim_create_user_command("IndentinatorHealth", cmd(function()
  vim.cmd("checkhealth indentinator")
end), { desc = "Run indentinator health check" })

vim.api.nvim_create_user_command("IndentinatorScopeJump", cmd(function(opts)
  local target = opts.args ~= "" and opts.args or "top"
  ind.jump_to_scope(target)
end), {
  desc = "Jump cursor to start ('top') or end ('bottom') of active scope block",
  nargs = "?",
  complete = function(arg_lead)
    local choices = { "top", "bottom" }
    return vim.tbl_filter(function(c) return c:find(arg_lead, 1, true) == 1 end, choices)
  end,
})
