# indentinator.nvim

A lightweight, high-performance indentation and scope guides plugin for Neovim. Written in pure Lua, it renders standard indentation guides across all levels and highlights the active scope using modern Neovim extmarks and viewport-bounded rendering.

---

## Features

- **Standard Indentation Guides**: Renders vertical guide lines across all indentation steps (`col 2, col 4, col 6, ...`).
- **Active Scope Highlighting**: Dynamically highlights the active code scope line enclosing your cursor.
- **Treesitter Integration (Default)**: Optional, enabled-by-default Treesitter AST scope resolution (`scope.treesitter = true`) with seamless fallback to indentation calculations.
- **Viewport-Bounded**: Only computes and paints guides for lines visible in the active window.
- **Minimal & Performant**: Clean Lua codebase with zero fluff, no heavy regex scanning, and lightweight autocommands.

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
    indent = {
      enabled = true,
      char = "│",
    },
    scope = {
      enabled = true,
      char = "│",
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
- `:IndentinatorHealth` — Run configuration diagnostics.

---

## Configuration

Default configuration settings:

```lua
require("indentinator").setup({
  enabled = true,        -- Enable plugin globally
  priority = 100,        -- Extmark priority level

  -- Standard indentation guides across all levels
  indent = {
    enabled = true,             -- Render guides across all indent levels
    char = "│",                 -- Standard guide character
    hl = "IndentinatorIndent",  -- Highlight group for standard guides
  },

  -- Active scope guide highlighting
  scope = {
    enabled = true,             -- Highlight active scope guide line
    char = "│",                 -- Active scope guide character
    hl = "IndentinatorScope",   -- Highlight group for active scope guide
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

## Lua API

- **`require("indentinator").get_current_scope(buf, win)`**:
  Returns `{ scope_start = line_num, scope_end = line_num, active_col = col_idx }` or `nil`.
- **`require("indentinator").enable(buf)`** / **`disable(buf)`** / **`toggle(buf)`**:
  Buffer-level enablement controls.

---

## Highlights

| Highlight Group | Default | Description |
|-----------------|---------|-------------|
| `IndentinatorIndent` | `#45475a` | Standard guide character colour |
| `IndentinatorScope` | `#cdd6f4` (bold) | Active scope guide character colour |

---

## License

MIT
