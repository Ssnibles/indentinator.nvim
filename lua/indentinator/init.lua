-- Minimal event-driven indentation guides for Neovim
local config = require("indentinator.config")
local state_mod = require("indentinator.state")
local state = state_mod.state
local utils = require("indentinator.utils")
local render = require("indentinator.render")

local M = {}

local AUGROUP = "Indentinator"

---@type IndentinatorConfig
M.config = config.values

--- Configures and initialises the plugin with user settings.
--- Idempotent: calling setup() more than once merges configuration but
--- does not re-register autocmds or duplicate initial renders.
---@param opts table|nil User configuration options
function M.setup(opts)
	opts = opts or {}
	for k, v in pairs(opts) do
		if v ~= nil then
			if k == "scope" and type(v) == "table" then
				M.config.scope = vim.tbl_extend("force", M.config.scope, v)
			elseif k == "filetypes" and type(v) == "table" and type(M.config.filetypes) == "table" then
				for ft, ft_cfg in pairs(v) do
					M.config.filetypes[ft] = vim.tbl_extend("force", M.config.filetypes[ft] or {}, ft_cfg)
				end
			else
				M.config[k] = v
			end
		end
	end

	if M._setup_done then
		return
	end
	M._setup_done = true

	local char_width = vim.fn.strdisplaywidth(M.config.char)
	if char_width ~= 1 then
		vim.notify(
			("indentinator: char %q has display width %d (expected 1), falling back to '│'"):format(
				M.config.char,
				char_width
			),
			vim.log.levels.WARN
		)
		M.config.char = "│"
	end

	render.set_hl()
	vim.api.nvim_create_augroup(AUGROUP, { clear = true })

	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = AUGROUP,
		callback = function(e)
			if e.buf and vim.api.nvim_buf_is_valid(e.buf) then
				render.attach(e.buf)
				render.render_all(e.buf)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
		group = AUGROUP,
		callback = function(ev)
			local event_wins = vim.v.event and vim.v.event.all
			if event_wins and next(event_wins) then
				for win_id_str, _ in pairs(event_wins) do
					local win = tonumber(win_id_str)
					if win then
						local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
						if ok_b then
							render.render(wb, win)
						end
					end
				end
				return
			end
			local win = tonumber(ev.match)
			if win then
				local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
				if ok_b then
					render.render(wb, win)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinEnter", {
		group = AUGROUP,
		callback = function()
			local win = vim.api.nvim_get_current_win()
			local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
			if ok_b then
				render.render(wb, win)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = AUGROUP,
		callback = function(e)
			local win = tonumber(e.match)
			if not win then
				return
			end
			state_mod.clear_win_state(win)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = AUGROUP,
		callback = function(e)
			state_mod.clear_buf_state(e.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = AUGROUP,
		callback = function()
			local win = vim.api.nvim_get_current_win()
			local ok_b, buf = pcall(vim.api.nvim_win_get_buf, win)
			if not ok_b or not config.is_enabled(buf, state) then
				return
			end

			local scope_cfg = config.resolve_scope(buf)
			if not scope_cfg.enabled then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(win)
			local row, col = cursor[1], cursor[2]
			state.last_cursor_row = state.last_cursor_row or {}
			state.last_cursor_col = state.last_cursor_col or {}

			if not scope_cfg.treesitter and state.last_cursor_row[win] == row then
				return
			end
			if scope_cfg.treesitter and state.last_cursor_row[win] == row and state.last_cursor_col[win] == col then
				return
			end

			state.last_cursor_row[win] = row
			state.last_cursor_col[win] = col

			render.render(buf, win)
		end,
	})

	vim.api.nvim_create_autocmd("OptionSet", {
		group = AUGROUP,
		pattern = {
			"shiftwidth",
			"tabstop",
			"expandtab",
			"softtabstop",
			"foldenable",
			"foldlevel",
			"foldmethod",
			"foldexpr",
			"foldcolumn",
			"foldignore",
			"foldmarker",
		},
		callback = function(e)
			local buf = e.buf
			if buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
				buf = vim.api.nvim_get_current_buf()
			end
			render.render_all(buf)
		end,
	})

	local on_key_ns = vim.api.nvim_create_namespace("indentinator_on_key")
	vim.on_key(function(_, key)
		if not key or key == "" then
			return
		end
		local mode = vim.api.nvim_get_mode().mode
		if mode == "n" or mode == "no" or mode == "nov" or mode == "noV" then
			local win = vim.api.nvim_get_current_win()
			local ok_fe, fe = pcall(function()
				return vim.wo[win].foldenable
			end)
			if ok_fe and fe == true then
				vim.schedule(function()
					local ok_b, buf = pcall(vim.api.nvim_win_get_buf, win)
					if ok_b and config.is_enabled(buf, state) then
						render.render(buf, win)
					end
				end)
			end
		end
	end, on_key_ns)

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = AUGROUP,
		callback = function()
			render.set_hl()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
				if ok_b then
					render.render(wb, win)
				end
			end
		end,
	})

	vim.schedule(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
			if ok_b then
				render.attach(wb)
				if config.is_enabled(wb, state) then
					render.render(wb, win)
				end
			end
		end
	end)
end

--- Explicitly enables guides for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.enable(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	state.enabled[buf] = true
	render.render_all(buf)
end

--- Explicitly disables guides for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.disable(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	state.enabled[buf] = false
	render.clear_window_all(buf)
end

--- Toggles guides on or off for a specific buffer.
---@param buf number|nil The buffer handle (defaults to current)
function M.toggle(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if config.is_enabled(buf, state) then
		M.disable(buf)
	else
		M.enable(buf)
	end
end

--- Checks if guides are enabled for the specified buffer.
---@param buf number|nil The buffer handle (defaults to current)
---@return boolean True if enabled, false otherwise
function M.is_enabled(buf)
	return config.is_enabled(buf or vim.api.nvim_get_current_buf(), state)
end

--- Forces a full redraw of guides in all active windows.
function M.force_update()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
		if ok_b then
			render.render(wb, win)
		end
	end
end

--- Retrieves the active scope bounds for a buffer and window.
---@param buf number|nil Buffer handle (defaults to current)
---@param win number|nil Window handle (defaults to current)
---@return table|nil Table containing { scope_start, scope_end, active_col } or nil
function M.get_current_scope(buf, win)
	win = win or vim.api.nvim_get_current_win()
	buf = buf or vim.api.nvim_win_get_buf(win)
	if not buf or not win or not vim.api.nvim_buf_is_loaded(buf) then
		return nil
	end

	local width = utils.indent_width(buf)
	local tabstop = utils.buffer_tabstop(buf)
	local scope_cfg = config.resolve_scope(buf)

	local scope_start, scope_end, active_col = nil, nil, nil

	if scope_cfg.treesitter then
		local ts_start, ts_end, ts_col =
			require("indentinator.scope").get_treesitter_scope_range(buf, win, width, tabstop)
		if ts_start and ts_end and ts_col then
			scope_start, scope_end, active_col = ts_start, ts_end, ts_col
		end
	end

	if scope_start == nil then
		active_col = utils.get_current_indent_col(buf, win)
		if active_col then
			local cursor = vim.api.nvim_win_get_cursor(win)
			scope_start, scope_end =
				require("indentinator.scope").get_scope_range(buf, cursor[1], active_col, width, tabstop)
		end
	end

	if scope_start and scope_end then
		return {
			scope_start = scope_start,
			scope_end = scope_end,
			active_col = active_col,
		}
	end
	return nil
end

--- Jumps cursor to the top or bottom of the active scope block.
---@param where "top"|"bottom" Target position (defaults to "top")
function M.jump_to_scope(where)
	where = where or "top"
	local win = vim.api.nvim_get_current_win()
	local scope_info = M.get_current_scope(nil, win)
	if not scope_info then
		return
	end

	local target_row = (where == "bottom" or where == "end") and scope_info.scope_end or scope_info.scope_start
	if target_row then
		local cursor = vim.api.nvim_win_get_cursor(win)
		vim.api.nvim_win_set_cursor(win, { target_row, cursor[2] })
	end
end

--- Returns a human-readable statusline string of the current scope bounds.
---@return string Statusline segment (e.g. "Scope: L10-L45") or empty string
function M.statusline()
	local scope_info = M.get_current_scope()
	if scope_info and scope_info.scope_start and scope_info.scope_end then
		return string.format("Scope: L%d-L%d", scope_info.scope_start, scope_info.scope_end)
	end
	return ""
end

return M
