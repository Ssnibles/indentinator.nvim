# indentinator.nvim

A lightweight, high-performance indentation and scope guides plugin for Neovim. Written in pure Lua, it renders standard indentation guides across all levels, active scope guide lines with boundary corners (`┌` / `└`), preset corner styles (`round`, `double`, `bold`), scope navigation motions, scope caching, and debounced viewport rendering.

---

## Features

- **Standard Indentation Guides**: Renders vertical guide lines across all indentation steps (`col 2, col 4, col 6, ...`).
- **Active Scope Highlighting & Preset Corners**: Dynamically highlights the active scope line with boundary corner connectors. Supports presets (`"sharp"`, `"round"`, `"double"`, `"bold"`).
- **Scope Navigation & Text Objects**: Motion API and commands to jump directly to top/bottom scope boundaries or visually select active scopes (`jump_to_scope_start`, `jump_to_scope_end`, `select_scope`).
- **Memoized Scope Caching**: Automatic scope calculation caching per buffer change tick for zero-overhead cursor movement.
- **Fine-Grained Blank Line Policies**: Configurable toggles (`indent.show_empty`, `scope.show_empty`) for blank line rendering.
- **Rainbow Indent Guides**: Optional level-by-level rainbow coloring for standard indentation guides.
- **Smart Debouncing**: Configurable micro-debounced rendering (`debounce_ms`) for high-frequency cursor movements (`CursorMoved`, `WinScrolled`).
- **Treesitter Integration (Default)**: Optional, enabled-by-default Treesitter AST scope resolution (`scope.treesitter = true`) with seamless fallback to indentation calculations.
- **Viewport-Bounded**: Only computes and paints guides for lines visible in the active window.

---

## Requirements

- Neovim 0.10+ (for modern extmark overlay support).

---

## Installation

### lazy.nvim
```lua
{
  "Ssnibles/indentinator.nvim",
  event = "BufReadPre",
  opts = {
    debounce_ms = 10,
    indent = {
      enabled = true,
      show_empty = true,
      char = "│",
      rainbow = {
        enabled = false,
      },
    },
    scope = {
      enabled = true,
      show_empty = true,
      corner_style = "round", -- "sharp", "round", "double", "bold"
      char = "│",
      corners = true,
      treesitter = true,
    },
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

- `:IndentinatorEnable` — Enable indent & scope guides in current buffer.
- `:IndentinatorDisable` — Disable indent & scope guides in current buffer.
- `:IndentinatorToggle` — Toggle indent & scope guides in current buffer (append `!` for all active buffers).
- `:IndentinatorIndentToggle` — Toggle standard indentation guides.
- `:IndentinatorScopeToggle` — Toggle active scope guide highlighting.
- `:IndentinatorRainbowToggle` — Toggle rainbow indent guide colors.
- `:IndentinatorScopeRainbowToggle` — Toggle rainbow active scope line colors.
- `:IndentinatorDelimitersToggle` — Toggle scope boundary delimiter highlighting.
- `:IndentinatorDelimitersRainbowToggle` — Toggle rainbow scope boundary delimiter colors.
- `:IndentinatorCornersToggle` — Toggle active scope boundary corner characters.
- `:IndentinatorJumpTop` — Jump cursor to top boundary of active scope.
- `:IndentinatorJumpBottom` — Jump cursor to bottom boundary of active scope.
- `:IndentinatorHealth` — Run configuration diagnostics.

---

## Scope Navigation & Keymaps

You can define custom keymaps using the Lua API:

```lua
local ind = require("indentinator")

-- Jump motions
vim.keymap.set("n", "[s", ind.jump_to_scope_start, { desc = "Jump to scope top" })
vim.keymap.set("n", "]s", ind.jump_to_scope_end, { desc = "Jump to scope bottom" })

-- Scope text objects
vim.keymap.set({ "x", "o" }, "ii", function() ind.select_scope(true) end, { desc = "Select inner scope" })
vim.keymap.set({ "x", "o" }, "ai", function() ind.select_scope(false) end, { desc = "Select around scope" })
```

---

## Configuration

Default configuration settings:

```lua
require("indentinator").setup({
  enabled = true,        -- Enable plugin globally
  debounce_ms = 10,      -- Micro-debounce delay in ms for autocommand re-renders
  priority = 100,        -- Extmark priority level

  -- Standard indentation guides across all levels
  indent = {
    enabled = true,             -- Render guides across all indent levels
    show_empty = true,          -- Render indent guides on blank lines
    char = "│",                 -- Standard guide character
    hl = "IndentinatorIndent",  -- Highlight group for standard guides
    rainbow = {
      enabled = false,          -- Enable rainbow colors per level
      colors = {                -- Custom hex palette for rainbow levels
        "#f38ba8", -- Red
        "#fab387", -- Peach
        "#f9e2af", -- Yellow
        "#a6e3a1", -- Green
        "#89b4fa", -- Blue
        "#cba6f7", -- Mauve
      },
    },
  },

  -- Scope boundary delimiters highlighting ({}, (), [], if/then/end/function/while/do/etc.)
  delimiters = {
    enabled = true,             -- Enable scope boundary delimiter highlighting
    keywords = true,            -- Highlight Treesitter scope keywords (if, then, end, function, while, do, etc.)
    rainbow = false,            -- Level rainbow colors for boundary delimiters
    bold = false,               -- Render delimiters in bold
    italic = false,             -- Render delimiters in italic
    underline = false,          -- Render delimiters with underline
    hl = nil,                   -- Custom highlight group override for delimiters
  },

  -- Active scope guide highlighting
  scope = {
    enabled = true,             -- Highlight active scope guide line
    show_empty = true,          -- Highlight active scope guide on blank lines
    rainbow = false,            -- Level rainbow colors for active scope guide line
    corner_style = "sharp",     -- Boundary corner preset ("sharp", "round", "double", "bold")
    char = "│",                 -- Active scope guide character
    char_top = "┌",             -- Top boundary corner character (overridden by preset)
    char_bottom = "└",          -- Bottom boundary corner character (overridden by preset)
    corners = true,             -- Render top/bottom boundary corner characters
    hl = "IndentinatorScope",   -- Highlight group for active scope guide
    hl_header = nil,            -- Optional highlight group for scope header line
    treesitter = true,          -- Use Treesitter for scope calculation
  },

  exclude = {
    filetypes = {},      -- List of excluded filetypes, e.g. { "NvimTree" }
    buftypes = {         -- List of excluded buftypes
      "terminal",
      "nofile",
      "quickfix",
      "prompt"
    },
  },
})
```

---

## Highlights

| Highlight Group | Default | Description |
|-----------------|---------|-------------|
| `IndentinatorIndent` | `#45475a` | Standard guide character colour |
| `IndentinatorScope` | `#cdd6f4` (bold) | Active scope guide character colour |
| `IndentinatorDelimiter` | `IndentinatorScope` | Scope boundary delimiter brackets |
| `IndentinatorDelimiter1..6` | Configured hexes | Styled rainbow delimiter bracket colours |
| `IndentinatorRainbow1..6` | Configured hexes | Rainbow level guide colours |

---

## License

MIT


