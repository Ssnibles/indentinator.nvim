-- Entrypoint for Neovim's standard :checkhealth indentinator command
return {
  check = function()
    require("indentinator.health").check()
  end,
}
