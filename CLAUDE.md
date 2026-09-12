# gauntlet.nvim

## What this project is

A Neovim plugin for reviewing GitHub pull requests locally, without leaving the
editor. The goal is to pull a PR's content into Neovim and work through it there
instead of in the GitHub web UI.

## Invocation surface

The entry points were specified before any of the review UI. There are four,
and they are the contract the rest of the plugin is built behind.

### 1. `:Gauntlet <ID>` / `:Gauntlet <URL>`

Start a PR review for that PR.

- `<ID>` is a bare PR number.
- `<URL>` is `https://github.com/<User>/<Repo>/pull/<ID>`.

Errors:

- Not inside a git repository.
- The GitHub project has no *open* PR with that ID.
- The URL form names a repository other than the current one.

### 2. `:Gauntlet` (no argument)

List the open PRs for the current repository, and pick one to review.

- Not inside a git repository is an error.
- Zero open PRs is an *empty list*, not an error.

### 3. `vig <ID>` / `vig <URL>` (terminal)

Short for "nvim gauntlet". Starts Neovim with the PR review already open.

On error, the message goes to the console and Neovim does **not** stay running —
it either never starts, or starts only long enough to print and exit.

### 4. `vig` (no arguments, terminal)

Prints the list of open PRs to stdout. Neovim is not started.

## Current scope of "PR review mode"

Display a **read-only** window containing the conversation part of the PR —
the description the developer wrote to explain what the PR is about. Diffs,
comment threads, and review submission are all later work.

## Conventions

- Tests use plenary.nvim's busted runner under `tests/`.
- `doc/gauntlet.txt` is the vim help file; `doc/tags` is generated, not edited.
