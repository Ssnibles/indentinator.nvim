--- Shared helpers for the headless test suites.

local M = {}

--- Asserts strict equality with a readable failure message.
---@param actual any
---@param expected any
---@param msg string|nil
function M.assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(
      string.format("%s: expected %s, got %s", msg or "Assertion failed", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

--- Creates a listed, non-scratch buffer with sensible indentation settings.
---@param lines string[]
---@param filetype string|nil
---@param opts table|nil `shiftwidth`, `tabstop`, `expandtab`
---@return integer
function M.make_buf(lines, filetype, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("shiftwidth", opts.shiftwidth or 2, { buf = buf })
  vim.api.nvim_set_option_value("tabstop", opts.tabstop or 2, { buf = buf })
  vim.api.nvim_set_option_value("expandtab", opts.expandtab ~= false, { buf = buf })
  if filetype then
    vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
  end
  return buf
end

--- Finds the first extmark whose virt_text contains `needle`.
--- Extmark ordering is an implementation detail, so tests look up marks by
--- content rather than by index.
---@param marks table[]
---@param needle string
---@return table|nil
function M.find_mark_with_text(marks, needle)
  for _, mark in ipairs(marks) do
    local virt_text = mark[4] and mark[4].virt_text
    if virt_text then
      for _, chunk in ipairs(virt_text) do
        if type(chunk[1]) == "string" and chunk[1]:find(needle, 1, true) then
          return mark
        end
      end
    end
  end
  return nil
end

return M
