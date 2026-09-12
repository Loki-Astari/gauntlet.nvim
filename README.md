# gauntlet.nvim

A Neovim user interface for reviewing GitHub pull requests locally.

> **Status: early.** A review shows the PR's description and a two-pane diff
> of every changed file, backed by a git worktree so it can be finished
> offline. Review comments are still to come.

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

A review is one tab page, labelled `PR Review <id>`: the changed files on the
left, and on the right either the PR's description or a two-pane diff.

```
+- Files ---------+- lua/gauntlet/ui.lua ---------------+
| > Conversation  |  base             |  head            |
|                 |                   |                  |
| M .gitignore +3 |  local M = {}     |  local M = {}    |
| A CLAUDE.md +54 |                   | +function M.pick |
+-----------------+-------------------+------------------+
```

| Key | |
| --- | --- |
| `<CR>` | Open the entry under the cursor |
| `q` | Close the review |
| `<C-w>f` | Jump back to the file list |

Diffs use Neovim's own diff mode, so `]c`, `[c` and folding behave as they do
in `vimdiff`. Everything is read-only — the right-hand side is a real file in
the review worktree, so a language server and `gd` work on it, but reviewing
cannot change a checkout.

`:GauntletDiscard` removes a review from disk when you are done with it.

### Offline

A review is backed by a git worktree, so it can be **started online and
finished offline**. Opening one fetches the PR's commits, checks them out, and
pulls down the blobs of both sides of every changed file — including on a
partial clone, where they would otherwise arrive one network round trip at a
time. After that the file list and every diff come from local git.

Reviews live in `~/.local/state/nvim/gauntlet/<repo>/pr-<n>/` and persist;
reopening one needs no network at all.

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
  dir = nil,   -- where review worktrees are kept
               -- (nil = stdpath("state")/gauntlet)
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
