# indentinator.nvim

A lightweight, high-performance indentation and scope guides plugin for Neovim. Written in pure Lua, it renders standard indentation guides across all levels, active scope guide lines with boundary corners (`┌` / `└`), optional rainbow indent coloring, and debounced viewport rendering.

---

## Features

- **Standard Indentation Guides**: Renders vertical guide lines across all indentation steps (`col 2, col 4, col 6, ...`).
- **Active Scope Highlighting & Corners**: Dynamically highlights the active scope line with boundary corner connectors (`┌` top, `└` bottom).
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
      char = "│",
      rainbow = {
        enabled = false,
      },
    },
    scope = {
      enabled = true,
      char = "│",
      char_top = "┌",
      char_bottom = "└",
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
- `:IndentinatorCornersToggle` — Toggle active scope boundary corner characters.
- `:IndentinatorHealth` — Run configuration diagnostics.

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

  -- Active scope guide highlighting
  scope = {
    enabled = true,             -- Highlight active scope guide line
    char = "│",                 -- Active scope guide character
    char_top = "┌",             -- Top boundary corner character
    char_bottom = "└",          -- Bottom boundary corner character
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
| `IndentinatorRainbow1..6` | Configured hexes | Rainbow level guide colours |

---

## License

MIT
