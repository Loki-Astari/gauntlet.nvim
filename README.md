# gauntlet.nvim

A Neovim user interface for reviewing GitHub pull requests locally.

> **Status: early.** A review shows the PR's description, a two-pane diff of
> every changed file, and comments you can write offline and submit as one
> GitHub review. Backed by a git worktree, so the whole thing works
> disconnected.

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
| `c` | Comment on the line under the cursor |
| `dc` | Delete the comment on that line |
| `q` | Close the review |
| `<C-w>f` | Jump back to the file list |

Diffs use Neovim's own diff mode, so `]c`, `[c` and folding behave as they do
in `vimdiff`. Everything is read-only — the right-hand side is a real file in
the review worktree, so a language server and `gd` work on it, but reviewing
cannot change a checkout. The panes stay out of the buffer list and are
discarded as you move on, so a review leaves nothing behind in `:ls`, `<C-^>`
or a bufferline.

### Comments

`c` opens a buffer spanning both diff panes — an ordinary one, so `:w` keeps
the comment and `:q` throws it away, and both sides of the diff stay in view
above it. A commented line is marked and highlighted, with the comment drawn
beneath it as a bordered note:

```
 20 │ local function unquote(path)
    │   ╭─ comment ──────────────────────────────────╮
    │   │ you (draft)                                │
    │   │ this needs a note about why threads rather │
    │   │ than comments, because a reply has to be   │
    │   │ able to join one later                     │
    │   ╰────────────────────────────────────────────╯
```

The file list counts them (`●2`). Colours come from `GauntletComment`,
`GauntletCommentBorder`, `GauntletCommentAuthor` and `GauntletCommentSign`,
all defined as defaults so your colourscheme wins.

Comments anchor to a line *and* a side (left is the base, right is the PR).
GitHub only accepts comments on lines that are part of the diff, so `c`
refuses a line that isn't rather than letting it fail at submission.

The PR's existing threads are fetched when the review is first prepared and
cached, so other people's comments are there offline too — drawn the same way,
titled `thread` and naming each author. `T` shows or hides threads that are
resolved or pinned to code since changed; those start hidden, as on GitHub, and
the file list counts them apart (`●2` open, `✓1` settled). Fetched threads are
read-only for now — replying is a later step.

A review is reconnected to from disk, which is what lets it be finished
offline — and means it stays on the commit it was opened at.
`:GauntletRefresh` is the one command that goes back to GitHub: it fetches the
branch again, moves the worktree onto its current head so commits pushed since
are in view, recomputes the file list and diffs, and fetches the threads. The
file you were looking at stays on show; a failed thread fetch leaves the cache
alone.

Nothing leaves your machine until `:GauntletSubmit`, which sends the lot as a
single GitHub review: a verdict, a covering note, and the line comments. If it
fails, your comments are untouched and you can try again.

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
argument it does all the work first — checks the argument, fetches the PR,
checks it out, works out what changed — and only then starts Neovim, handing
it the finished review. Every way that can fail is an error on stderr and a
non-zero exit, with no editor left open.

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
