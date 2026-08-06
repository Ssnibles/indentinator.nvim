# indentinator.nvim

A lightweight, high-performance indentation guides plugin for Neovim. Written in pure Lua, it uses modern Neovim APIs to render guides efficiently:
- Renders visible lines within the current window viewport only (unbounded file sizes cause no performance degradation).
- Uses a single overlay extmark per line with `virt_text` chunks.
- Avoids background timers or polling by hook-in on native editor events.

---

## Features

- **Viewport-Bounded**: Only computes and paints guides for lines visible in the active viewport.
- **Smart Guide Continuity**: Empty lines inherit guides from surrounding blocks (`smart = false`) or break them (`smart = true`).
- **Scope Highlighting**: Highlights the current indentation level based on cursor position, with a look-ahead mechanism to correctly highlight block header scopes.
- **Dynamic Overrides**: Customize options per filetype or exclude specific buffer types.

---

## Requirements

- Neovim 0.10+ (requires modern extmark overlay support).

---

## Installation

### lazy.nvim
```lua
{
  "Ssnibles/indentinator.nvim",
  event = "BufReadPre",
  opts = {
    -- Customise configuration here (see options below)
  }
}
```

### packer.nvim
```lua
use {
  "Ssnibles/indentinator.nvim",
  config = function()
    require("indentinator").setup()
  end
}
```

---

## Commands

- `:IndentinatorEnable` — Enable guides in the current buffer.
- `:IndentinatorDisable` — Disable guides in the current buffer.
- `:IndentinatorToggle` — Toggle guides in the current buffer (append `!` to toggle in all active buffers).
- `:IndentinatorHealth` — Run configuration diagnostics.

---

## Configuration

Default settings can be overridden during the `setup` call:

```lua
require("indentinator").setup({
  enabled = true,                    -- Enable or disable guides globally
  smart = false,                     -- Continue guides through blank lines (true to break them)
  char = "│",                        -- Guide character (single-width)
  char_hl = "IndentinatorGuide",     -- Highlight group for standard guides
  gap_hl = "IndentinatorGap",        -- Highlight group for gaps (when draw_gap_hl is true)
  draw_gap_hl = false,               -- Whether to highlight the span between guides
  show_first_indent_level = true,    -- Draw guides at column 0
  indent_width = nil,                -- Column step size (nil defaults to shiftwidth/tabstop)
  priority = 100,                    -- Extmark priority level

  -- Active scope highlighting
  scope = {
    enabled = false,        -- highlight the guide at the cursor's active scope
    range = "block",        -- "block" (current block only) or "global" (entire column)
    underline = false,      -- underline the top line of the active scope block
    text_highlight = true,  -- colour the text on the scope-start line
  },

  current_char_hl = "IndentinatorCurrentGuide",     -- Highlight group for the active guide
  scope_underline_hl = "IndentinatorScopeUnderline", -- Highlight group for the scope underline
  scope_text_hl = "IndentinatorScopeText",           -- Highlight group for scope-start text
  exclude_fn = nil,                  -- Custom callback: fun(buf: number): boolean (true to exclude)
  exclude = {},                      -- List of excluded filetypes, e.g. { "help", "markdown" }
  exclude_buftypes = {               -- List of excluded buftypes
    "terminal",
    "nofile",
    "quickfix",
    "prompt"
  },
  -- Per-filetype overrides (deep-merged, so only specified keys are overridden)
  filetypes = {
    python = {
      indent_width = 2
    }
  }
})
```

---

## Colour Customisation

Standard highlight definitions:

| Highlight Group | Default Colour | Description |
|-----------------|----------------|-------------|
| `IndentinatorGuide` | `#555b6e` | Default guide character colour |
| `IndentinatorGap` | `#555b6e` | Gap fill colour (when `draw_gap_hl = true`) |
| `IndentinatorCurrentGuide` | `#a6adc8` | Current/active guide character colour |
| `IndentinatorScopeUnderline` | `#a6adc8` (underlined) | Underline style for the top level of active scopes |
| `IndentinatorScopeText` | `#a6adc8` | Foreground colour for scope-start line text |

Highlights are automatically re-applied on `ColorScheme` events. Customise colours in your configuration after loading your preferred colorscheme:

```lua
vim.api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE" })
vim.api.nvim_set_hl(0, "IndentinatorCurrentGuide", { fg = "#a6adc8", bg = "NONE" })
vim.api.nvim_set_hl(0, "IndentinatorScopeUnderline", { fg = "#a6adc8", bg = "NONE", underline = true })
```

> [!IMPORTANT]
> Always set `bg = "NONE"` on these highlight groups to prevent guides from obscuring background styling (such as diagnostics, search highlights, or colorcolumns).

### Scope Underline Example

With `scope.enabled` and `scope.underline` both set to `true`, the first line of the active block gets an underline when the cursor is anywhere inside it:

```lua
-- "callback = function(ev)" is underlined when cursor is inside this block:
callback = function(ev)
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = ev.buf, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = ev.buf, silent = true })
end,
```

```lua
require("indentinator").setup({
  scope = {
    enabled = true,
    underline = true,
  },
})
```

---

## License

MIT
