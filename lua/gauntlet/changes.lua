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

--- Every file changed between two commits.
---@param root string  repository root
---@param base string  merge base
---@param head string  pull request head
---@return table[]|nil files, string|nil err
---  files are { path, status, additions, deletions, binary, from? }, sorted by path
function M.list(root, base, head)
  -- -M so a rename is reported as one, and quotepath off so a non-ASCII path
  -- arrives as itself rather than as octal escapes.
  local args = { "-c", "core.quotepath=false", "diff", "-M" }
  local status_lines, err = git.run(root, vim.list_extend(vim.deepcopy(args), { "--name-status", base, head }))
  if not status_lines then
    return nil, err
  end
  local counts = numstat(git.run(root, vim.list_extend(vim.deepcopy(args), { "--numstat", base, head })))

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

return M
