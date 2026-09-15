-- A throwaway git repository to test against.
--
-- The diff machinery reads real objects out of a real object store, so the
-- tests build one rather than mocking git: a base commit, then a head commit
-- that adds, modifies and deletes a file apiece.
local M = {}

---@param root string
---@param args string[]
local function git(root, args)
  local cmd = vim.list_extend({
    "git", "-C", root,
    "-c", "user.email=test@example.com",
    "-c", "user.name=Test",
  }, args)
  local out = vim.fn.systemlist(cmd)
  assert(vim.v.shell_error == 0, table.concat(out, "\n"))
  return out
end

---@param root string
---@param path string
---@param text string
local function write(root, path, text)
  local full = vim.fs.joinpath(root, path)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), full)
end

--- Build the fixture.  Its working tree is checked out at head, which is
--- exactly the shape of a review worktree.
---@return table repo { root, base, head, cleanup }
function M.repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  git(root, { "init", "-q", "-b", "main", "." })

  local long = {}
  for i = 1, 40 do
    long[i] = "line " .. i
  end

  write(root, "keep.txt", "one\ntwo")
  write(root, "change.txt", "alpha\nbeta")
  write(root, "gone.txt", "bye")
  -- Long enough that most of its lines fall outside the diff's hunks, which
  -- is where GitHub refuses a comment.
  write(root, "big.txt", table.concat(long, "\n"))
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "base" })
  local base = git(root, { "rev-parse", "HEAD" })[1]

  long[20] = "line 20 CHANGED"
  write(root, "big.txt", table.concat(long, "\n"))
  write(root, "change.txt", "alpha\nBETA\ngamma")
  vim.fn.delete(vim.fs.joinpath(root, "gone.txt"))
  write(root, "new.txt", "fresh")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "head" })
  local head = git(root, { "rev-parse", "HEAD" })[1]

  return {
    root = root,
    base = base,
    head = head,
    cleanup = function()
      vim.fn.delete(root, "rf")
    end,
  }
end

--- A repository with a remote that carries a pull request, the way GitHub
--- does: the head is reachable as refs/pull/<n>/head on the remote, which is
--- what lets one fetch cover pull requests from forks too.
---
--- Returns the clone, which is where git commands are run from.
---@param number integer  pull request number
---@return table repo { root, remote, base, head, cleanup }
function M.repo_with_pr(number)
  local remote = vim.fn.tempname()
  local root = vim.fn.tempname()
  vim.fn.mkdir(remote, "p")
  git(remote, { "init", "-q", "--bare", "-b", "main", "." })

  vim.fn.mkdir(root, "p")
  git(root, { "clone", "-q", remote, "." })

  write(root, "keep.txt", "one\ntwo")
  write(root, "change.txt", "alpha\nbeta")
  write(root, "gone.txt", "bye")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "base" })
  git(root, { "push", "-q", "origin", "main" })
  local base = git(root, { "rev-parse", "HEAD" })[1]

  git(root, { "checkout", "-q", "-b", "pr" })
  write(root, "change.txt", "alpha\nBETA\ngamma")
  vim.fn.delete(vim.fs.joinpath(root, "gone.txt"))
  write(root, "new.txt", "fresh")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "the pull request" })
  local head = git(root, { "rev-parse", "HEAD" })[1]
  git(root, { "push", "-q", "origin", ("pr:refs/pull/%d/head"):format(number) })

  -- Leave the clone where a reviewer would be: on the base branch, with no
  -- local trace of the pull request.
  git(root, { "checkout", "-q", "main" })
  git(root, { "branch", "-qD", "pr" })

  return {
    root = root,
    remote = remote,
    base = base,
    head = head,
    cleanup = function()
      vim.fn.delete(root, "rf")
      vim.fn.delete(remote, "rf")
    end,
  }
end

--- Push another commit onto a pull request, the way a contributor does after
--- a review has already been started.  The remote's refs/pull/<n>/head moves;
--- the clone is left exactly as it was, with no local trace of it.
---@param fixture table  from M.repo_with_pr
---@param number integer  pull request number
---@param path string  a file to add
---@param text string
---@return string head  the pull request's new head commit
function M.push_to_pr(fixture, number, path, text)
  local root = fixture.root
  git(root, { "fetch", "-q", "origin", ("+refs/pull/%d/head:refs/heads/pr-more"):format(number) })
  git(root, { "checkout", "-q", "pr-more" })

  write(root, path, text)
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "another commit on the pull request" })
  local head = git(root, { "rev-parse", "HEAD" })[1]

  git(root, { "push", "-q", "origin", ("+pr-more:refs/pull/%d/head"):format(number) })
  git(root, { "checkout", "-q", "main" })
  git(root, { "branch", "-qD", "pr-more" })
  return head
end

return M
