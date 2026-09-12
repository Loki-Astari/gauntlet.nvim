# gauntlet.nvim

A Neovim user interface for working on pull requests.

> **Status: empty skeleton.** The plugin installs and loads cleanly. It does
> nothing else yet.

## Requirements

- Neovim 0.9+

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/gauntlet.nvim",
  config = function()
    require("gauntlet").setup({})
  end,
}
```

## Configuration

```lua
require("gauntlet").setup({})
```

There are no options yet.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted-compatible runner.

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Override the plenary location with `PLENARY_DIR` if it is not at the default
lazy.nvim path.
