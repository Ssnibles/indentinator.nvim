--- Renderer module facade for indentinator.nvim.
--- Exposes atomic viewport rendering methods and extmark options.
---@class indentinator.renderer
local render = require("indentinator.render")

local M = {}

M.NS = render.NS
M.set_hl = render.set_hl
M.clear_virt_text_cache = render.clear_virt_text_cache
M.clear = render.clear
M.prepare_win_context = render.prepare_win_context
M.render_line = render.render_line
M.setup_decoration_provider = render.setup_decoration_provider
M.render = render.render
M.render_all = render.render_all

return M
