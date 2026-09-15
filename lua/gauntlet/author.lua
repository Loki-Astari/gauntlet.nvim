---@diagnostic disable: undefined-global
-- Editing a pull request you wrote.
--
-- A review is read-only unless it is yours.  When it is, the right-hand side
-- of every diff is the real file in the worktree and may be written to, and
-- what you write can be committed and pushed to the pull request's branch
-- from here.
--
-- The worktree is detached at the pull request's head, so a commit made in it
-- belongs to no branch; publishing is a push from HEAD to the branch by name.
-- Everything else in gauntlet treats that worktree as something only it
-- writes to, which is why gauntlet.worktree now refuses to reset over work
-- that is not on GitHub yet.
local git = require("gauntlet.git")

local M = {}

--- May this review's files be edited?
--- Only the author's own, and only once we know who both of them are: a
--- review reconnected to before that was ever recorded is read-only, which is
--- the safe way to be wrong.
---@param review table
---@return boolean
function M.editable(review)
  return review ~= nil and review.mine == true
end

--- What the review worktree has changed since its last commit.
--- Untracked files included: a file the author has just written is the most
--- interesting kind of change there is, and `git diff` cannot see it.
---@param review table
---@return table[] changes  { status, path }
function M.dirty(review)
  local out = {}
  for _, line in ipairs(git.run(review.worktree, { "status", "--porcelain" }) or {}) do
    local status, path = line:sub(1, 2), line:sub(4)
    path = path:match("%->%s*(.+)$") or path
    table.insert(out, { status = vim.trim(status), path = vim.trim(path) })
  end
  return out
end

--- Commits in the worktree that are not on GitHub yet.
---@param review table
---@return integer
function M.unpushed(review)
  local out = git.run(review.worktree, {
    "rev-list", "--count", ("%s..HEAD"):format(review.head),
  })
  return tonumber((out or {})[1] or "0") or 0
end

--- Commit everything the worktree has changed.
---
--- `add -A` then commit, because the alternative is asking a reviewer to
--- think about an index that gauntlet otherwise never shows them.  The
--- worktree is detached, so this lands on no branch; M.publish is what puts
--- it somewhere.
---@param review table
---@param message string
---@return table|nil commit { sha, subject }, string|nil err
function M.commit(review, message)
  message = vim.trim(message or "")
  if message == "" then
    return nil, "a commit needs a message"
  end
  if #M.dirty(review) == 0 then
    return nil, "nothing to commit"
  end

  local _, aerr = git.run(review.worktree, { "add", "-A" })
  if aerr then
    return nil, aerr
  end

  local _, cerr = git.run(review.worktree, { "commit", "--quiet", "-m", message })
  if cerr then
    return nil, cerr
  end

  local sha = git.run(review.worktree, { "rev-parse", "HEAD" })
  return {
    sha = sha and sha[1],
    subject = vim.split(message, "\n", { plain = true })[1],
  }
end

--- The remote holding this pull request's branch.
---
--- Not always the one the review was fetched from: a pull request from a fork
--- has its head in another repository, and `refs/pull/<n>/head` -- which is
--- how the commits got here -- is readable but not writable.
---@param repo table { name, owner, repo }
---@param pr table
---@return string|nil remote, string|nil err
function M.remote(repo, pr)
  if not pr.isCrossRepository then
    return repo.name or "origin"
  end

  local owner = (pr.headRepositoryOwner or {}).login
  local name = (pr.headRepository or {}).name
  if not owner or not name then
    return nil, "GitHub did not say which repository this pull request's branch is in"
  end

  for _, remote in ipairs(git.remotes()) do
    if remote.owner:lower() == owner:lower() and remote.repo:lower() == name:lower() then
      return remote.name
    end
  end
  return nil, ("#%d is from %s/%s, which is not a remote here; add it to publish to it")
    :format(pr.number, owner, name)
end

--- Push what the worktree has onto the pull request's branch.
---
--- By branch name rather than by pushing HEAD, because HEAD is detached: a
--- bare `git push` from here would have nothing to push to.
---@param repo table
---@param pr table
---@param review table
---@return table|nil published { head, remote, branch }, string|nil err
function M.publish(repo, pr, review)
  local branch = review.branch or pr.headRefName
  if not branch then
    return nil, "this review does not know which branch it belongs to"
  end

  local dirty = M.dirty(review)
  if #dirty > 0 then
    return nil, ("%d change%s in the worktree have not been committed; :GauntletCommit first")
      :format(#dirty, #dirty == 1 and "" or "s")
  end

  local head = git.run(review.worktree, { "rev-parse", "HEAD" })
  head = head and head[1]
  if not head or head == "" then
    return nil, "could not read the review worktree's HEAD"
  end
  if head == review.head then
    return nil, ("nothing to publish: %s is what GitHub already has"):format(head:sub(1, 7))
  end

  local remote, rerr = M.remote(repo, pr)
  if not remote then
    return nil, rerr
  end

  local _, perr = git.run(review.worktree, {
    "push", remote, ("HEAD:refs/heads/%s"):format(branch),
  })
  if perr then
    return nil, ("could not push to %s/%s: %s"):format(remote, branch, perr)
  end

  -- Keep gauntlet's own ref and its record of the head in step with what was
  -- just pushed, so a refresh afterwards sees no movement rather than a
  -- branch that ran ahead of it.
  local worktree = require("gauntlet.worktree")
  worktree.record(repo, review, head)

  return { head = head, remote = remote, branch = branch }
end

return M
