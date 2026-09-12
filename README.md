# gauntlet.nvim

Run a pull request through the gauntlet, without leaving Neovim.

> **Status: early skeleton.** The repo installs and loads cleanly; the review
> workflow is still being built.

## Requirements

- Neovim 0.9+
- An agent CLI on your PATH ([Claude Code](https://claude.ai/code) by default)
- The [`gh`](https://cli.github.com) CLI, for reading pull requests

Run `:checkhealth gauntlet` after installing to verify both.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/gauntlet.nvim",
  cmd = "Gauntlet",
  opts = {},
}
```

`opts` is passed straight to `require("gauntlet").setup()`. Use a `config`
function instead if you prefer to call it yourself:

```lua
{
  "Loki-Astari/gauntlet.nvim",
  config = function()
    require("gauntlet").setup({
      agent = "claude",
    })
  end,
}
```

## Configuration

```lua
require("gauntlet").setup({
  agent = "claude",       -- symbolic name of the reviewing agent CLI
  known_agents = {        -- symbolic name -> executable
    claude = "claude",
    codex  = "codex",
  },
  forge = "github",       -- PR source; github uses the `gh` CLI
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:Gauntlet` | Show the plugin version and resolved configuration |

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted-compatible runner.

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Override the plenary location with `PLENARY_DIR` if it is not at the default
lazy.nvim path.
