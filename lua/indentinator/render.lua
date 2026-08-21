--- Extmark renderer module for indentinator.nvim.
--- Handles extmark drawing for standard indent guides, rainbow colors, scope corners, and header highlights.

local config = require("indentinator.config")
local state = require("indentinator.state").state
local scope = require("indentinator.scope")
local utils = require("indentinator.utils")

local api = vim.api
local nvim_buf_is_valid = api.nvim_buf_is_valid
local nvim_buf_is_loaded = api.nvim_buf_is_loaded
local nvim_win_is_valid = api.nvim_win_is_valid
local nvim_buf_set_extmark = api.nvim_buf_set_extmark
local nvim_buf_clear_namespace = api.nvim_buf_clear_namespace
local nvim_list_wins = api.nvim_list_wins
local nvim_win_get_buf = api.nvim_win_get_buf
local nvim_buf_get_lines = api.nvim_buf_get_lines
local nvim_buf_line_count = api.nvim_buf_line_count

local M = {}

--- Extmark namespace handle for indentinator
M.NS = api.nvim_create_namespace("indentinator")

--- Initialises default highlight groups for standard indent, scope, and rainbow guides.
function M.set_hl()
  api.nvim_set_hl(0, "IndentinatorIndent", {
    fg = "#45475a",
    bg = "NONE",
    default = true,
  })
  api.nvim_set_hl(0, "IndentinatorScope", {
    fg = "#cdd6f4",
    bold = true,
    bg = "NONE",
    default = true,
  })

  local rainbow_cfg = config.values.indent and config.values.indent.rainbow
  if rainbow_cfg and type(rainbow_cfg.colors) == "table" then
    for idx, hex in ipairs(rainbow_cfg.colors) do
      api.nvim_set_hl(0, "IndentinatorRainbow" .. idx, {
        fg = hex,
        bg = "NONE",
        default = true,
      })
    end
  end
end

--- Clears scope extmarks for a buffer.
---@param buf integer Buffer handle
function M.clear(buf)
  if buf and nvim_buf_is_valid(buf) then
    pcall(nvim_buf_clear_namespace, buf, M.NS, 0, -1)
  end
end

--- Clears extmarks for a tracked window range.
---@param buf integer Buffer handle
---@param win integer Window handle
function M.clear_window(buf, win)
  local ranges = state.windows[buf]
  if not ranges then
    return
  end
  local r = ranges[win]
  if r then
    pcall(nvim_buf_clear_namespace, buf, M.NS, r[1] - 1, r[2])
    ranges[win] = nil
  end
end

--- Renders indent and scope guides for visible lines in a window.
---@param buf integer Buffer handle
---@param win integer Window handle
function M.render(buf, win)
  if not buf or not win or not nvim_buf_is_loaded(buf) or not nvim_win_is_valid(win) then
    return
  end

  if not config.is_enabled(buf, state.enabled[buf]) then
    M.clear(buf)
    return
  end

  M.clear_window(buf, win)

  local ok_v, view = pcall(function()
    return api.nvim_win_call(win, function()
      return { vim.fn.line("w0"), vim.fn.line("w$"), vim.fn.winsaveview().leftcol }
    end)
  end)
  if not ok_v or type(view) ~= "table" then
    return
  end

  local w0, w1 = view[1], view[2]
  local leftcol = (type(view[3]) == "number" and view[3] >= 0) and view[3] or 0

  if type(w0) ~= "number" or type(w1) ~= "number" or w1 < w0 or w0 <= 0 then
    return
  end

  local indent_cfg = config.values.indent or {}
  local scope_cfg = config.values.scope or {}
  local rainbow_cfg = indent_cfg.rainbow or {}

  local indent_enabled = indent_cfg.enabled ~= false
  local scope_enabled = scope_cfg.enabled ~= false
  local rainbow_enabled = rainbow_cfg.enabled == true and type(rainbow_cfg.colors) == "table" and #rainbow_cfg.colors > 0

  if not indent_enabled and not scope_enabled then
    return
  end

  local scope_start, scope_end, active_col
  if scope_enabled then
    scope_start, scope_end, active_col = scope.get_scope(buf, win, scope_cfg.treesitter)
  end

  local start_line = math.max(w0, 1)
  local total_lines = nvim_buf_line_count(buf)
  local end_line = math.min(w1, total_lines)
  if start_line > end_line then
    return
  end

  local width = utils.indent_width(buf)
  local tabstop = utils.buffer_tabstop(buf)
  local priority = config.values.priority or 100

  M.set_hl()

  -- Compute actual rendered boundary lines for active scope corners
  local first_scope_line, last_scope_line
  if scope_enabled and scope_start and scope_end and scope_start < scope_end then
    for l = scope_start, scope_end do
      local ok_l, lines = pcall(nvim_buf_get_lines, buf, l - 1, l, false)
      if ok_l and lines and lines[1] then
        local lead = lines[1]:match("^%s*") or ""
        local is_b = (lines[1] == "" or #lead == #lines[1])
        local lw = is_b and 9999 or utils.lead_display_width(lead, tabstop)
        if active_col and active_col < lw then
          if not first_scope_line then first_scope_line = l end
          last_scope_line = l
        end
      end
    end
  end

  for line = start_line, end_line do
    local line_idx = line - 1
    local ok_l, lines = pcall(nvim_buf_get_lines, buf, line_idx, line, false)
    if ok_l and lines and lines[1] then
      local text = lines[1]
      local lead = text:match("^%s*") or ""
      local is_blank = (text == "" or #lead == #text)

      local target_width = 0
      if not is_blank then
        target_width = utils.lead_display_width(lead, tabstop)
      else
        local up_text, up_lead = utils.find_non_blank_up(buf, line_idx)
        local down_text, down_lead = utils.find_non_blank_down(buf, line + 1, total_lines)
        local up_w = up_lead and utils.lead_display_width(up_lead, tabstop) or 0
        local down_w = down_lead and utils.lead_display_width(down_lead, tabstop) or 0
        target_width = math.min(up_w, down_w)
      end

      local in_scope_range = scope_start and scope_end and (line >= scope_start and line <= scope_end)
      local max_col = target_width - (is_blank and 0 or width)

      -- Optional header line highlighting
      if scope_enabled and in_scope_range and line == scope_start and scope_cfg.hl_header then
        pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
          line_hl_group = scope_cfg.hl_header,
          priority = priority - 1,
        })
      end

      if max_col >= width then
        for col = width, max_col, width do
          local win_col = col - leftcol
          if win_col >= 0 then
            local is_active = in_scope_range and active_col and (col == active_col)
            local char, hl

            if is_active and scope_enabled then
              char = scope_cfg.char or "│"
              if scope_cfg.corners and first_scope_line and last_scope_line and first_scope_line < last_scope_line then
                if line == first_scope_line and scope_cfg.char_top and scope_cfg.char_top ~= "" then
                  char = scope_cfg.char_top
                elseif line == last_scope_line and scope_cfg.char_bottom and scope_cfg.char_bottom ~= "" then
                  char = scope_cfg.char_bottom
                end
              end
              hl = scope_cfg.hl or "IndentinatorScope"
            elseif indent_enabled then
              char = indent_cfg.char or "│"
              if rainbow_enabled then
                local level = math.max(1, math.floor(col / width))
                local r_idx = (level - 1) % #rainbow_cfg.colors + 1
                hl = "IndentinatorRainbow" .. r_idx
              else
                hl = indent_cfg.hl or "IndentinatorIndent"
              end
            end

            if char and hl then
              pcall(nvim_buf_set_extmark, buf, M.NS, line_idx, 0, {
                virt_text = { { char, hl } },
                virt_text_win_col = win_col,
                hl_mode = "combine",
                priority = is_active and (priority + 10) or priority,
              })
            end
          end
        end
      end
    end
  end

  state.windows[buf] = state.windows[buf] or {}
  state.windows[buf][win] = { w0, w1 }
end

--- Renders scope guides for all windows displaying a buffer.
---@param buf integer Buffer handle
function M.render_all(buf)
  if not buf or not nvim_buf_is_loaded(buf) then
    return
  end
  for _, win in ipairs(nvim_list_wins()) do
    local ok, wb = pcall(nvim_win_get_buf, win)
    if ok and wb == buf then
      M.render(buf, win)
    end
  end
end

return M
