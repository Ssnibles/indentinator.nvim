# indentinator.nvim

A tiny, fast indent guides plugin for Neovim. Pure Lua, zero dependencies, and built on modern Neovim APIs: extmark `virt_text` chunks rendered in a single overlay extmark per line, event-driven redraw only, and window-viewport rendering so cost stays bounded even in huge files.

## Features

- **Fast**: one extmark per line using `virt_text` chunks with `virt_text_pos = "overlay"`; guides are only computed and painted for the lines currently visible in the window
- **Smart by default**: blank lines break the guide column, so guides never run through empty space (`smart = false` continues them like VSCode)
- **Event-driven**: redraws only on scroll, window enter/resize, or buffer edits (no timers or debounce); never on cursor moves
- **Bounded work**: only visible viewport is touched and calculated, no debounce/timer, no full-buffer scan
- **Buffer-local toggles**: `:IndentinatorToggle` (with `!` for all buffers), `:IndentinatorEnable`, `:IndentinatorDisable`
- **Highlight-aware**: default highlight groups re-linked on `ColorScheme`, and the full gap span can be painted with `draw_gap_hl`

## Requirements

- Neovim 0.10+ (uses extmark `virt_text` overlays—no timers needed)

## Installation

### Native plugin manager (vim's built-in packages)

```bash
git clone https://github.com/Ssnibles/indentinator.nvim ~/.config/nvim/pack/plugins/start/indentinator.nvim
```

The `plugin/indentinator.lua` entry point runs `setup()` automatically, so guides work with zero configuration. Optional: call `require("indentinator").setup({...})` in your config to override options.

Or manually in your config:

```lua
vim.opt.rtp:append("~/indentinator.nvim")
require("indentinator").setup()
```

### lazy.nvim

```lua
{
  "Ssnibles/indentinator.nvim",
  event = "BufReadPre",
  config = function()
    require("indentinator").setup({
      -- options, see below
    })
  end,
}
```

`setup()` is idempotent: calling it again with your options simply re-applies them on top of the defaults (and the automatic one from `plugin/`).

### packer.nvim / vim-plug

```lua
-- packer
use { "Ssnibles/indentinator.nvim", config = function() require("indentinator").setup() end }
```

```vim
" vim-plug
Plug 'Ssnibles/indentinator.nvim'
lua require('indentinator').setup()
```

### Nix

```nix
{ lib, buildVimPlugin }:
buildVimPlugin {
  pname = "indentinator-nvim";
  version = "0.1.0";
  src = ./.;
}
```

## Usage

Guides appear automatically in every buffer. Per-buffer control:

- `:IndentinatorEnable` — enable guides in the current buffer
- `:IndentinatorDisable` — disable guides in the current buffer
- `:IndentinatorToggle` — toggle in the current buffer (`:IndentinatorToggle!` toggles in all buffers)
- `:IndentinatorHealth` — run diagnostics (also available via `:checkhealth indentinator`)

## Configuration

```lua
require("indentinator").setup({
  enabled = true,                    -- master switch
  smart = true,                      -- blank lines break guide columns; false = continuous guides through blanks
  char = "│",                        -- guide character (any single-width char, e.g. "▏", "¦")
  char_hl = "IndentinatorGuide",     -- highlight group for the guide char
  gap_hl = "IndentinatorGap",        -- highlight group for the gap fill (when draw_gap_hl)
  draw_gap_hl = false,               -- also paint the span between guide chars
  show_first_indent_level = true,    -- draw the first indent level's guide
  indent_width = nil,                -- guide column step; nil = use shiftwidth (fallback tabstop)
  show_current_indent = false,       -- display current indent: false (disable), true or "highlight" (highlight active guide), or "only" (only show the current guide)
  current_char_hl = "IndentinatorCurrentGuide", -- highlight group for the current indent guide
  exclude = {},                      -- filetypes to disable in, e.g. { "help", "markdown" }

  priority = 100,                    -- extmark priority
})
```

### Highlight groups

| Group | Default | Description |
|-------|---------|-------------|
| `IndentinatorGuide` | fg only (default: #555b6e), no background | guide characters |
| `IndentinatorGap` | links to `IndentinatorGuide` | gap fill when `draw_gap_hl = true` |
| `IndentinatorCurrentGuide` | fg only (default: #a6adc8), no background | current/active guide characters |

Override them after your colorscheme loads (re-applied from `setup()` / `ColorScheme`).

The highlight group **must have `bg = NONE`** or the guides will obscure background highlights (diagnostic underlines, colorcolumn, etc).

Examples:
```lua
vim.api.nvim_set_hl(0, "IndentinatorGuide", { fg = "#555b6e", bg = "NONE" })
```

## How it works

- Only the window's visible lines (`w0`–`w$`) are analyzed and painted, so per-keystroke cost is bounded regardless of file size; multiple windows on the same buffer each keep their own viewport extmarks
- Each line's guide columns are the multiples of `indent_width` (default `shiftwidth`) that fit within its leading whitespace; the deepest column is included only while it still *is* a real indent (columns are capped at `cells <= indent`, so nothing is drawn past the content)
- Smart mode stops at blank lines; non-smart mode fills blank lines with the intersection of the guide columns of the surrounding non-blank lines
- Edits (`TextChanged*`, `BufWritePost`) trigger immediate redraw; `WinScrolled`, `WinEnter`, `WinResized`, `BufWinEnter` are also handled; `OptionSet` on `shiftwidth`/`tabstop`/`expandtab`/`softtabstop` triggers redraw

## Notes and limitations

- Alignment is computed from `strdisplaywidth` of the leading whitespace. Space-indented code renders exactly; tab-indented code renders correctly when `tabstop` and `shiftwidth` match
- The guides follow the focused window when multiple windows display the same buffer
- Pathological lines with more than 1000 cells of leading whitespace are skipped

## Project structure

```
indentinator.nvim/
├── lua/indentinator/
│   ├── init.lua              # config, setup, extmark engine
│   └── health.lua            # health check diagnostics
├── plugin/
│   └── indentinator.lua      # commands + auto-setup entry point
├── default.nix               # Nix package
└── README.md
```

## License

MIT
