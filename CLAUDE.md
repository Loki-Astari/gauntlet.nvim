# gauntlet.nvim

This is a claude modification.

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

## The review interface

Settled by design before implementation. One tab page per review, named
`PR Review <id>`.

```
[ PR Review 1 ]
+- Files ---------+- lua/gauntlet/ui.lua ---------------+
| > Conversation  |  base (read-only) |  head (read-only)|
|                 |                   |                  |
| M .gitignore +3 |  local M = {}     |  local M = {}    |
| A CLAUDE.md +54 |                   | +function M.pick |
| M README.md +52 |  return M         |  return M        |
+-----------------+-------------------+------------------+
```

- A **persistent sidebar** on the left lists the changed files as **flat
  sorted paths**, with status letter and line counts. `Conversation` is the
  first entry, so the description is one keystroke from any file.
- Selecting a file shows a **two-pane vimdiff**: merge-base version on the
  left, PR version on the right.
- **Everything is read-only.** Nothing the reviewer types can alter a file.
  This does not cost LSP or `gd`, which work on non-modifiable buffers.

Later, and deliberately not yet: review comments, and submitting a review.
The sidebar leaves room for a per-file "viewed" marker and comment counts.

## The review worktree

A review is backed by a **git worktree**, so that a review can be *started*
online and *finished* offline. Asking GitHub to serve each diff would make
that impossible.

```
~/.local/state/nvim/gauntlet/<repo>/pr-<N>/
    worktree/       git worktree, detached at the PR head
    comments.json   draft review comments (later)
    meta.json       base sha, head sha, when fetched
```

The worktree is a *subdirectory* of the review, not the review itself:
gauntlet's own files must never appear in the worktree's `git status`, where
they could be committed by accident.

Persistent, not `$TMPDIR`. This is the one deliberate departure from how
AIAgent creates worktrees (`~/Repo/AIAgent`, `create_worktree()`), which is
otherwise the model followed here: derive a path, reconnect if it already
exists, parse `git worktree list --porcelain` to find it. macOS purges
`$TMPDIR`, and a review whose worktree vanishes while its owner is offline
cannot be rebuilt.

### Starting a review, while still online

1. `git fetch origin refs/pull/<N>/head:refs/gauntlet/pr/<N>`. This ref
   exists on the base repository even for pull requests from forks.
2. Base commit is `git merge-base <baseRefOid> <headRefOid>`, both from `gh`.
   *Not* the tip of the base branch: for a merged pull request that gives a
   degenerate merge-base equal to the head, and so an empty diff.
3. `git worktree add --detach <dir>/worktree refs/gauntlet/pr/<N>`.
4. **Warm the object cache.** The clone may be partial (this one is
   `blob:none`), in which case base-side blobs are fetched lazily and the
   review would need the network after all. `git diff <base> <head>` touches
   both sides and lets git batch a single promisor fetch.

Afterwards the file list and both sides of every diff come from local git.
`GIT_NO_LAZY_FETCH=1` is how to test that offline really works.

**No diff is ever downloaded.** The only calls to GitHub in a review are `gh
pr view` for metadata -- number, title, body, `baseRefOid`, `headRefOid`.
Every hunk is computed locally.

Every `git diff` must pass `--no-ext-diff`: a configured `diff.external`
(this machine has one) is otherwise run in place of git's own diff, and
returns no usable output. And the cache warming must *not* use
`diff --quiet`, which stops at the first difference it finds and so never
reads the rest of the blobs -- the opposite of warming them. `--numstat` has
to read both sides of every file, which is the point.

### Why the whole project is checked out

Questioned and re-affirmed. Measured on a 14,572-file repository:

| approach | time | disk | real files for LSP |
| --- | --- | --- | --- |
| full worktree | 2.0s | 64M | yes, whole project |
| sparse, changed files only | 0.11s | 128K | changed files only |
| no checkout, `git show` | 0.02s | 0 | no |

The full checkout costs disk, not download -- the commits and trees are
fetched either way, and blobs only where the clone does not already have
them. What it buys is a complete project tree, so a language server resolves
imports into files the pull request never touched, `gd` jumps into them, and
the pull request's tests could be run. That was judged worth 64M a review.

## Conventions

- Tests use plenary.nvim's busted runner under `tests/`.
- `doc/gauntlet.txt` is the vim help file; `doc/tags` is generated, not edited.
