# gauntlet.nvim

A Neovim user interface for reviewing GitHub pull requests locally.

> **Status: early.** The invocation surface is in place. A review currently
> shows the PR's conversation — the description the author wrote — in a
> read-only window. Diffs and comment threads are still to come.

## Requirements

- Neovim 0.9+
- [`gh`](https://cli.github.com), the GitHub CLI, authenticated (`gh auth login`)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/gauntlet.nvim",
  cmd = "Gauntlet",
  config = function()
    require("gauntlet").setup({})
  end,
}
```

## Usage

### In Neovim

| Command | Effect |
| --- | --- |
| `:Gauntlet 142` | Review pull request 142 |
| `:Gauntlet https://github.com/user/repo/pull/142` | Review that pull request |
| `:Gauntlet` | Choose from the open pull requests |

The review opens in a tab page of its own, labelled `PR Review <id>`. Press
`q` to close it. If Neovim was started purely to show the review — as `vig`
does — it takes over the empty starting buffer instead of opening a second
tab, and `q` exits.

`:Gauntlet` reports an error if you are not inside a git repository, if there is
no *open* pull request with that number, or if a URL names a repository that is
not a remote of the one you are in. Having no open pull requests at all is not
an error — the list is simply empty.

### From the terminal

`bin/vig` ("nvim gauntlet") does the same from a shell:

```bash
vig 142                                        # review PR 142 in Neovim
vig https://github.com/user/repo/pull/142      # same, from a URL
vig                                            # print the open PRs and exit
```

With no argument `vig` prints the list and never starts Neovim. With an
argument it validates and fetches the pull request first, so a bad argument
prints an error to stderr and exits non-zero without an editor appearing.

Install it by putting `bin/` on your `PATH`, or with an alias:

```bash
alias vig='~/.local/share/nvim/lazy/gauntlet.nvim/bin/vig'
```

## Configuration

```lua
require("gauntlet").setup({
  gh = "gh",   -- path to the GitHub CLI
  limit = 100, -- most open pull requests to list at once
})
```

The pull request picker goes through `vim.ui.select`, so Telescope, fzf-lua,
snacks.nvim or any other picker that overrides it is used automatically.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted-compatible runner.

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Override the plenary location with `PLENARY_DIR` if it is not at the default
lazy.nvim path.
