---@diagnostic disable: undefined-global
-- The git worktree backing a review.
--
-- A review is started online and may be finished offline, so everything it
-- needs is brought onto disk up front: the pull request's commits, a worktree
-- checked out at its head, and -- on a partial clone -- the blobs of both
-- sides of every changed file.
--
-- Modelled on AIAgent's create_worktree() (~/Repo/AIAgent): derive a path,
-- reconnect if it already exists, find it again by parsing `git worktree list
-- --porcelain`.  The one departure is that these live somewhere persistent
-- rather than in $TMPDIR, which macOS purges -- a review whose worktree
-- vanished while its owner was offline could not be rebuilt.
local git = require("gauntlet.git")

local M = {}

--- Where all reviews are kept.  Overridable with the `dir` option, which the
--- tests use to keep their worktrees out of the real state directory.
---@return string
function M.root()
  local configured = require("gauntlet").config.dir
  if configured and configured ~= "" then
    return vim.fn.expand(configured)
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "gauntlet")
end

--- The directory holding one review: the worktree, and gauntlet's own files.
--- The worktree is a *subdirectory* so that nothing gauntlet writes -- draft
--- comments especially -- ever shows up in the worktree's `git status`.
---@param repo table { owner, repo }
---@param number integer
---@return string
function M.dir(repo, number)
  return vim.fs.joinpath(M.root(), repo.repo, "pr-" .. number)
end

--- The ref a pull request's head is fetched to.
---@param number integer
---@return string
local function pr_ref(number)
  return "refs/gauntlet/pr/" .. number
end

--- Is `path` already registered as a worktree of this repository?
---@param root string
---@param path string
---@return boolean
local function registered(root, path)
  local out = git.run(root, { "worktree", "list", "--porcelain" })
  for _, line in ipairs(out or {}) do
    local listed = line:match("^worktree (.+)$")
    -- Compare resolved paths: git stores them with symlinks resolved, which
    -- on macOS turns /var into /private/var.
    if listed and vim.fn.resolve(listed) == vim.fn.resolve(path) then
      return true
    end
  end
  return false
end

--- Create a directory, reporting failure rather than raising it.
--- vim.fn.mkdir() throws, and `vig` has to turn a failure into one line on
--- the terminal, not a Lua traceback.
---@param path string
---@return boolean ok, string|nil err
local function ensure_dir(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if ok then
    return true
  end
  -- Vim errors arrive as "Vim:E739: Cannot create directory ...".
  return false, tostring(err):gsub("^Vim:", "")
end

---@param path string
---@return table|nil
local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok and decoded or nil
end

---@param path string
---@param value table
local function write_json(path, value)
  if not ensure_dir(vim.fs.dirname(path)) then
    return
  end
  pcall(vim.fn.writefile, vim.split(vim.json.encode(value), "\n", { plain = true }), path)
end

--- Bring a pull request onto disk, or reconnect to a review already there.
---
--- Needs the network the first time and never again: see the cache warming
--- at the end, without which a partial clone would fetch base-side blobs
--- lazily, one network round trip at a time, as files are opened.
---@param repo table { name, owner, repo }
---@param pr table  as returned by gauntlet.github
---@return table|nil review { dir, worktree, base, head, number }, string|nil err
function M.open(repo, pr)
  local root, err = git.root()
  if not root then
    return nil, err
  end

  local dir = M.dir(repo, pr.number)
  local worktree = vim.fs.joinpath(dir, "worktree")
  local meta_path = vim.fs.joinpath(dir, "meta.json")

  if registered(root, worktree) and vim.fn.isdirectory(worktree) == 1 then
    local meta = read_json(meta_path)
    if meta and meta.base and meta.head then
      return {
        dir = dir,
        worktree = worktree,
        base = meta.base,
        head = meta.head,
        number = pr.number,
      }
    end
    -- The worktree is there but we cannot say what it holds; start again.
    git.run(root, { "worktree", "remove", "--force", worktree })
  end

  local ref = pr_ref(pr.number)
  local remote = repo.name or "origin"

  -- refs/pull/<n>/head exists on the base repository even when the pull
  -- request comes from a fork, so this one fetch covers both cases.
  local _, ferr = git.run(root, {
    "fetch", remote, ("+refs/pull/%d/head:%s"):format(pr.number, ref),
  })
  if ferr then
    return nil, ("could not fetch pull request #%d: %s"):format(pr.number, ferr)
  end

  local head = pr.headRefOid
  local base
  if pr.baseRefOid then
    -- The merge base, not the tip of the base branch: for a merged pull
    -- request the tip already contains the head, and the diff comes out empty.
    local out = git.run(root, { "merge-base", pr.baseRefOid, ref })
    base = out and out[1]
  end
  if not base or base == "" then
    return nil, "could not work out what this pull request branched from"
  end

  local ok, derr = ensure_dir(dir)
  if not ok then
    return nil, derr
  end

  local _, werr = git.run(root, { "worktree", "add", "--detach", worktree, ref })
  if werr then
    return nil, ("could not create the review worktree: %s"):format(werr)
  end

  -- Warm the object cache while we still have the network.  On a partial
  -- clone (this repository is filtered blob:none) the base side of every
  -- changed file is missing, and reading it later would need a fetch per
  -- file.  Counting the lines both ways has to read every blob on both
  -- sides, which pulls them all down in one go.
  --
  -- Not `diff --quiet`: that stops at the first difference it finds, so most
  -- of the blobs would never be read, which is the opposite of warming them.
  -- And --no-ext-diff because a configured diff.external would otherwise be
  -- run instead, producing no reads at all.
  git.run(root, { "diff", "--no-ext-diff", "--numstat", base, ref })

  write_json(meta_path, {
    base = base,
    head = head,
    number = pr.number,
    repo = repo.owner .. "/" .. repo.repo,
    fetched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })

  return {
    dir = dir,
    worktree = worktree,
    base = base,
    head = head,
    number = pr.number,
  }
end

--- Remove a review: its worktree, its ref, and everything gauntlet kept.
---@param repo table { owner, repo }
---@param number integer
---@return boolean ok, string|nil err
function M.remove(repo, number)
  local root, err = git.root()
  if not root then
    return false, err
  end

  local dir = M.dir(repo, number)
  local worktree = vim.fs.joinpath(dir, "worktree")

  if registered(root, worktree) then
    local _, rerr = git.run(root, { "worktree", "remove", "--force", worktree })
    if rerr then
      return false, rerr
    end
  end

  git.run(root, { "update-ref", "-d", pr_ref(number) })
  vim.fn.delete(dir, "rf")
  return true
end

--- Every review currently on disk for this repository.
---@param repo table { owner, repo }
---@return integer[] numbers  pull request numbers, ascending
function M.list(repo)
  local numbers = {}
  local base = vim.fs.joinpath(M.root(), repo.repo)
  for name, kind in vim.fs.dir(base) do
    local number = kind == "directory" and name:match("^pr%-(%d+)$")
    if number then
      table.insert(numbers, tonumber(number))
    end
  end
  table.sort(numbers)
  return numbers
end

return M
