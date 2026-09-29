--- Renderer module facade for indentinator.nvim.
--- Exposes viewport rendering methods and extmark options.
---@class indentinator.renderer
local render = require("indentinator.render")

local M = {}

M.NS = render.NS
M.set_hl = render.set_hl
M.clear_virt_text_cache = render.clear_virt_text_cache
M.clear = render.clear
M.clear_win = render.clear_win
M.prepare_win_context = render.prepare_win_context
M.render_line = render.render_line
M.render = render.render
M.render_all = render.render_all

return M
