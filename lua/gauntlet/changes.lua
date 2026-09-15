---@diagnostic disable: undefined-global
-- The set of files a pull request changes, read from local git.
--
-- Nothing here touches the network: once gauntlet.worktree has brought the
-- review onto disk, the file list and both sides of every diff come out of
-- the object store, which is what lets a review be finished offline.
local git = require("gauntlet.git")

local M = {}

--- Undo the C-style quoting git applies to a path with awkward characters.
--- `core.quotepath=false` already stops non-ASCII being escaped; this covers
--- the rest (a quote, a backslash, a tab in a filename).
---@param path string
---@return string
local function unquote(path)
  if not path:match('^".*"$') then
    return path
  end
  local body = path:sub(2, -2)
  return (body:gsub("\\(.)", function(c)
    return ({ t = "\t", n = "\n", r = "\r", ['"'] = '"', ["\\"] = "\\" })[c] or c
  end))
end

--- Parse `git diff --name-status`: a status letter and a path per line.
--- A rename or copy carries both paths, old then new; the new one is the file
--- the review shows.  (`-z` would be the obvious choice, but Vim turns the NUL
--- separators into newlines and hands back one blob, so plain output it is.)
---@param lines string[]|nil
---@return table[] entries  { status, path, from? } in git's order
local function name_status(lines)
  local entries = {}
  for _, line in ipairs(lines or {}) do
    local status, rest = line:match("^(%a%d*)\t(.+)$")
    if status then
      local letter = status:sub(1, 1)
      if letter == "R" or letter == "C" then
        local from, to = rest:match("^(.-)\t(.+)$")
        table.insert(entries, { status = letter, path = unquote(to), from = unquote(from) })
      else
        table.insert(entries, { status = letter, path = unquote(rest) })
      end
    end
  end
  return entries
end

--- Parse `git diff --numstat`: added and deleted line counts, in the same
--- order as --name-status.  Matched to files by position rather than by path,
--- because numstat renders a rename as "src/{old.c => new.c}" and there is no
--- reason to unpick that when the order already answers it.
--- A binary file reports "-" for both counts.
---@param lines string[]|nil
---@return table[] counts
local function numstat(lines)
  local counts = {}
  for _, line in ipairs(lines or {}) do
    local adds, dels = line:match("^(%S+)\t(%S+)\t")
    if adds then
      table.insert(counts, {
        additions = tonumber(adds) or 0,
        deletions = tonumber(dels) or 0,
        binary = adds == "-",
      })
    end
  end
  return counts
end

--- What to put on git's command line to name the two sides of a diff.
--- `head` may be nil, meaning the working tree of `root` rather than a
--- commit: that is what an author's own review is diffed against, so edits
--- they have not committed yet still count.
---@param base string
---@param head string|nil
---@return string[] revisions
local function revisions(base, head)
  return head and { base, head } or { base }
end

--- Every file changed between the base and `head`, or the working tree.
---@param root string  repository root
---@param base string  merge base
---@param head string|nil  pull request head, or nil for the working tree
---@return table[]|nil files, string|nil err
---  files are { path, status, additions, deletions, binary, from? }, sorted by path
function M.list(root, base, head)
  -- --no-ext-diff because a configured diff.external would be run in place of
  -- git's own diff, and these want git's output.  -M so a rename is reported
  -- as one, and quotepath off so a non-ASCII path arrives as itself rather
  -- than as octal escapes.
  local args = { "-c", "core.quotepath=false", "diff", "--no-ext-diff", "-M" }
  local revs = revisions(base, head)
  local status_lines, err = git.run(root, vim.list_extend(
    vim.list_extend(vim.deepcopy(args), { "--name-status" }), vim.deepcopy(revs)))
  if not status_lines then
    return nil, err
  end
  local counts = numstat(git.run(root, vim.list_extend(
    vim.list_extend(vim.deepcopy(args), { "--numstat" }), vim.deepcopy(revs))))

  local files = {}
  for index, entry in ipairs(name_status(status_lines)) do
    if entry.path then
      local count = counts[index] or {}
      table.insert(files, {
        path = entry.path,
        status = entry.status,
        from = entry.from,
        additions = count.additions or 0,
        deletions = count.deletions or 0,
        binary = count.binary or false,
      })
    end
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- Which lines of a file appear in the pull request's diff.
---
--- GitHub will only take a review comment on a line that is part of the diff,
--- so this is what says where a comment may go.  Hunk headers are enough:
--- "@@ -a,b +c,d @@" means base lines a..a+b-1 and head lines c..c+d-1 are on
--- show.  Git's default three lines of context are kept, because GitHub
--- displays context lines too and accepts comments on them.
---@param root string
---@param base string
---@param head string
---@param path string
---@return table hunks { LEFT = { {first, last}, ... }, RIGHT = { ... } }
function M.hunks(root, base, head, path)
  local ranges = { LEFT = {}, RIGHT = {} }
  local lines = git.run(root, vim.list_extend(
    vim.list_extend({ "diff", "--no-ext-diff", "-M" }, revisions(base, head)),
    { "--", path }))

  for _, line in ipairs(lines or {}) do
    -- A count of 1 is left out: "@@ -5 +5,2 @@" means one line at 5.
    local old_start, old_count, new_start, new_count =
      line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      old_count = tonumber(old_count) or 1
      new_count = tonumber(new_count) or 1
      if old_count > 0 then
        table.insert(ranges.LEFT, { tonumber(old_start), tonumber(old_start) + old_count - 1 })
      end
      if new_count > 0 then
        table.insert(ranges.RIGHT, { tonumber(new_start), tonumber(new_start) + new_count - 1 })
      end
    end
  end
  return ranges
end

--- May a comment be left on this line?
---@param hunks table  from M.hunks
---@param side string  "LEFT" or "RIGHT"
---@param line integer
---@return boolean
function M.commentable(hunks, side, line)
  for _, range in ipairs((hunks or {})[side] or {}) do
    if line >= range[1] and line <= range[2] then
      return true
    end
  end
  return false
end

--- The contents of a file as it was before the pull request.
--- An added file has no before, which is an empty left-hand pane, not a
--- failure -- so the two cases are told apart by `ok`, not by emptiness.
---@param root string
---@param base string
---@param path string
---@return string[] lines, boolean existed
function M.base_lines(root, base, path)
  local lines = git.run(root, { "show", ("%s:%s"):format(base, path) })
  if not lines then
    return {}, false
  end
  return lines, true
end

--- The file list of a review, read from wherever its truth is.
---
--- A review of someone else's pull request is diffed between two commits: it
--- is what GitHub has, and nothing local can change it.  Your own is diffed
--- against the worktree itself, because you may have edited it, and the list
--- would otherwise not show your own work.
---@param root string  repository root
---@param review table
---@return table[]|nil files, string|nil err
function M.for_review(root, review)
  if not review.mine then
    return M.list(root, review.base, review.head)
  end

  local files, err = M.list(review.worktree, review.base, nil)
  if not files then
    return nil, err
  end

  -- A file that has never been committed is invisible to `git diff` until it
  -- is staged, and an author who adds one would otherwise not see it at all.
  -- Counted rather than staged: putting it in the index would be gauntlet
  -- writing to a worktree the author is also using by hand.
  for path in pairs(M.untracked(review)) do
    local lines = vim.fn.readfile(vim.fs.joinpath(review.worktree, path))
    table.insert(files, {
      path = path,
      status = "A",
      additions = type(lines) == "table" and #lines or 0,
      deletions = 0,
      binary = false,
    })
  end

  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- Paths in the review worktree that git is not tracking at all.
---@param review table
---@return table<string, boolean> paths
function M.untracked(review)
  local out = {}
  for _, line in ipairs(git.run(review.worktree, { "status", "--porcelain" }) or {}) do
    if line:sub(1, 2) == "??" then
      out[unquote(vim.trim(line:sub(4)))] = true
    end
  end
  return out
end

--- Files the review worktree has changed since its last commit, by path.
---
--- Work that exists only on this machine: it is not on GitHub, and a comment
--- cannot be anchored against it.  Untracked files are included -- git's own
--- diff does not see them until they are staged, and an author adding a file
--- would otherwise not see it at all.
---@param review table
---@return table<string, boolean> paths
function M.unpublished(review)
  local out = {}
  if not review.mine then
    return out
  end
  for _, line in ipairs(git.run(review.worktree, { "status", "--porcelain" }) or {}) do
    -- "XY path", and "XY old -> new" for a rename; the new name is the file.
    local path = line:sub(4)
    path = path:match("%->%s*(.+)$") or path
    out[unquote(vim.trim(path))] = true
  end
  return out
end

return M
