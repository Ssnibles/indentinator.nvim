local M = {}

local NS = vim.api.nvim_create_namespace("indentinator")
local AUGROUP = "Indentinator"

M.config = {
  enabled = true,
  smart = true,
  char = "│",
  char_hl = "IndentinatorGuide",
  gap_hl = "IndentinatorGap",
  draw_gap_hl = false,
  show_first_indent_level = true,
  indent_width = nil,
  exclude = {},
  debounce = 120,
  priority = 100,
}

local state = {
  enabled = {},
  windows = {},
  timers = {},
  attached = {},
}

local function is_enabled(buf)
  local v = state.enabled[buf]
  if v ~= nil then return v end
  local ok_ft, ft = pcall(vim.api.nvim_get_options_value, buf, "filetype")
  if not ok_ft then ft = "" end
  for _, e in ipairs(M.config.exclude) do
    if ft == e then return false end
  end
  return M.config.enabled
end

local function indent_width(buf)
  local ok, sw = pcall(vim.api.nvim_get_options_value, buf, "shiftwidth")
  if ok and sw > 0 then return sw end
  local ok2, ts = pcall(vim.api.nvim_get_options_value, buf, "tabstop")
  if ok2 and ts > 0 then return ts end
  return 8
end

local function guide_cols(cells, width, show_first)
  if cells <= 0 then return nil end
  local cols, n = {}, width
  while n <= cells and #cols < 64 do
    if show_first or n ~= width then table.insert(cols, n) end
    n = n + width
  end
  return #cols > 0 and cols or nil
end

local function build_chunks(cols)
  local chunks, pos = {}, cols[1]
  for _, g in ipairs(cols) do
    local gap = g - pos
    if gap > 0 then
      if M.config.draw_gap_hl then
        table.insert(chunks, { string.rep(" ", gap), M.config.gap_hl })
      else
        table.insert(chunks, { string.rep(" ", gap) })
      end
    end
    table.insert(chunks, { M.config.char, M.config.char_hl })
    pos = g + 1
  end
  return chunks
end

local function clear_window(buf, win)
  local ranges = state.windows[buf]
  if not ranges then return end
  local r = ranges[win]
  if r then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, r[1] - 1, r[2])
    ranges[win] = nil
  end
end

local function clear_window_all(buf)
  if state.windows[buf] then
    for win, r in pairs(state.windows[buf]) do
      pcall(vim.api.nvim_buf_clear_namespace, buf, NS, r[1] - 1, r[2])
    end
    state.windows[buf] = nil
  end
end

local function render(buf, win)
  if not buf or not win or not vim.api.nvim_buf_is_loaded(buf) then return end
  if not is_enabled(buf) then
    clear_window(buf, win)
    return
  end

  local ok_r, r0, r1 = pcall(vim.fn.line, "w0", win)
  if not ok_r then return end
  local ok_s, r1b = pcall(vim.fn.line, "w$", win)
  if not ok_s then return end
  r1 = r1b
  if type(r0) ~= "number" or type(r1) ~= "number" or r1 < r0 then return end

  local ok_l, lines = pcall(vim.api.nvim_buf_get_lines, buf, r0 - 1, r1, false)
  if not ok_l then return end
  if #lines == 0 then
    clear_window(buf, win)
    return
  end

  local width = indent_width(buf)
  local show_first = M.config.show_first_indent_level

  local results = {}
  local blanks_start
  local prev_cells = 0
  for k, text in ipairs(lines) do
    local lead = text:match("^%s*")
    if text == "" or lead == text then
      if not blanks_start then blanks_start = k end
    else
      local cells = vim.fn.strdisplaywidth(lead)
      if cells > 1000 then
        results[k] = nil
      else
        results[k] = guide_cols(cells, width, show_first)
      end

      if blanks_start and not M.config.smart then
        local above = guide_cols(prev_cells, width, show_first)
        local below = results[k]
        if above and below then
          local merged, i, j = {}, 1, 1
          while i <= #above and j <= #below do
            if above[i] == below[j] then
              table.insert(merged, above[i])
              i = i + 1
              j = j + 1
            elseif above[i] < below[j] then
              i = i + 1
            else
              j = j + 1
            end
          end
          for b = blanks_start, k - 1 do
            results[b] = merged
          end
        end
        blanks_start = nil
      elseif blanks_start then
        blanks_start = nil
      end

      prev_cells = cells
    end
  end

  local occupied = {}
  if vim.tbl_count(state.windows[buf] or {}) > 1 then
    for other, r in pairs(state.windows[buf]) do
      if other ~= win then
        for ln = r[1], r[2] do occupied[ln] = true end
      end
    end
  end

  clear_window(buf, win)

  for k = 1, #lines do
    local cols = results[k]
    if cols and not occupied[r0 - 1 + k] then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, r0 - 2 + k, 0, {
        virt_text = build_chunks(cols),
        virt_text_pos = "overlay",
        virt_text_win_col = cols[1],
        priority = M.config.priority,
      })
    end
  end

  state.windows[buf] = state.windows[buf] or {}
  state.windows[buf][win] = { r0, r1 }
end

local function render_all(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
    if ok_b and wb == buf then render(buf, win) end
  end
end

local function schedule(buf)
  local t = state.timers[buf]
  if t then
    t:stop()
  else
    t = vim.uv.new_timer()
    state.timers[buf] = t
  end
  t:start(M.config.debounce, 0, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then render_all(buf) end
    end)
  end)
end

local function attach(buf)
  if state.attached[buf] and vim.api.nvim_buf_is_loaded(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then
    state.attached[buf] = nil
    return
  end
  local ok, res = pcall(vim.api.nvim_buf_attach, buf, false, {
    on_bytes = function()
      schedule(buf)
    end,
  })
  state.attached[buf] = ok and res or nil
end

local function set_hl()
  vim.api.nvim_set_hl(0, "IndentinatorGuide", { link = "SpecialKey" })
  vim.api.nvim_set_hl(0, "IndentinatorGap", { link = "IndentinatorGuide" })
end

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if v ~= nil then M.config[k] = v end
  end

  set_hl()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    callback = function(e)
      if e.buf and vim.api.nvim_buf_is_valid(e.buf) then
        attach(e.buf)
        render(e.buf, vim.api.nvim_get_current_win())
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinEnter" }, {
    group = AUGROUP,
    callback = function(e)
      local win = e.win or tonumber(e.match) or vim.api.nvim_get_current_win()
      local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
      if ok_b then render(wb, win) end
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = AUGROUP,
    callback = function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
        if ok_b then render(wb, win) end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    callback = function(e)
      local win = tonumber(e.match)
      for buf, ranges in pairs(state.windows) do
        if ranges[win] then ranges[win] = nil end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = AUGROUP,
    callback = function(e)
      if e.buf and vim.api.nvim_buf_is_valid(e.buf) then schedule(e.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = AUGROUP,
    pattern = { "shiftwidth", "tabstop", "expandtab", "softtabstop" },
    callback = function(e)
      local buf = e.buf
      if buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_get_current_buf()
      end
      schedule(buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    callback = function()
      set_hl()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
        if ok_b then render(wb, win) end
      end
    end,
  })

  vim.schedule(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
      if ok_b then
        attach(wb)
        if is_enabled(wb) then render(wb, win) end
      end
    end
  end)
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state.enabled[buf] = true
  render_all(buf)
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state.enabled[buf] = false
  clear_window_all(buf)
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if is_enabled(buf) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

function M.is_enabled(buf)
  return is_enabled(buf or vim.api.nvim_get_current_buf())
end

function M.force_update()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_b, wb = pcall(vim.api.nvim_win_get_buf, win)
    if ok_b then render(wb, win) end
  end
end

return M
