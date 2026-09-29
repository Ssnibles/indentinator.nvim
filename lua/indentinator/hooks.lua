--- User-extensible hooks for indentinator.nvim.
---
--- Hooks let users influence rendering without forking the plugin. Register
--- callbacks with `register`; callbacks receive the buffer and (where relevant)
--- line information. All callbacks are wrapped in `pcall`, so a failing hook
--- never breaks rendering.
---
--- Hook types:
--- - `ACTIVE(buf) -> boolean`        Return false to skip rendering a buffer.
--- - `SCOPE_ACTIVE(buf) -> boolean`  Return false to hide the active scope guide.
--- - `SKIP_LINE(buf, row, line) -> boolean` Return true to skip painting a line.
---@class indentinator.hooks
local M = {}

--- Available hook type names.
M.type = {
  ACTIVE = "active",
  SCOPE_ACTIVE = "scope_active",
  SKIP_LINE = "skip_line",
}

---@type table<string, fun(...): boolean[]>
local registry = {}

--- Set of valid hook type names.
local valid_types = {}
for _, name in pairs(M.type) do
  valid_types[name] = true
end

--- Registers a callback for a hook type.
---@param type_name string One of `M.type`
---@param fn fun(...): boolean
function M.register(type_name, fn)
  if type(fn) ~= "function" or not valid_types[type_name] then
    return
  end
  registry[type_name] = registry[type_name] or {}
  table.insert(registry[type_name], fn)
end

--- Removes hooks. Pass a type to clear only that type, or nil to clear all.
---@param type_name string|nil One of `M.type`
function M.clear(type_name)
  if type_name then
    registry[type_name] = nil
  else
    registry = {}
  end
end

--- Runs all hooks of a type until one returns true.
---@param type_name string
---@param ... any
---@return boolean any_true
local function any(type_name, ...)
  local list = registry[type_name]
  if not list then
    return false
  end
  for _, fn in ipairs(list) do
    local ok, result = pcall(fn, ...)
    if ok and result == true then
      return true
    end
  end
  return false
end

--- Runs all hooks of a type; returns false if any returns false.
---@param type_name string
---@param ... any
---@return boolean all_true
local function all(type_name, ...)
  local list = registry[type_name]
  if not list then
    return true
  end
  for _, fn in ipairs(list) do
    local ok, result = pcall(fn, ...)
    if ok and result == false then
      return false
    end
  end
  return true
end

--- True if the buffer is allowed to render.
---@param buf integer
---@return boolean
function M.is_active(buf)
  return all(M.type.ACTIVE, buf)
end

--- True if the active scope guide is allowed to render.
---@param buf integer
---@return boolean
function M.is_scope_active(buf)
  return all(M.type.SCOPE_ACTIVE, buf)
end

--- True if the given line should not be painted.
---@param buf integer
---@param row integer 0-indexed row
---@param line string Line text
---@return boolean
function M.skip_line(buf, row, line)
  return any(M.type.SKIP_LINE, buf, row, line)
end

return M
