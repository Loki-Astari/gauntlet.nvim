---@diagnostic disable: undefined-global
-- Draft review comments, kept beside the worktree.
--
-- Stored as *threads* even though a draft only ever has one comment in it.
-- A GitHub review thread is the same shape with more comments and an author
-- who is not you, so pulling threads in later adds entries, not a migration.
--
-- These live in the review directory but outside the worktree, so nothing
-- written here can turn up in the worktree's `git status` and be committed by
-- accident.
local M = {}

-- Bumped only if the shape below changes in a way a reader must know about.
local VERSION = 1

--- Where a review's drafts are kept.
--- GitHub's own threads, when they are fetched, will go in a file of their
--- own: a re-fetch must never be able to overwrite something you wrote.
---@param review table
---@return string
function M.path(review)
  return vim.fs.joinpath(review.dir, "comments.json")
end

--- Read a review's drafts.  Missing, empty or unreadable all mean "none yet":
--- a review that has never been commented on is the ordinary case.
---@param review table
---@return table store { version, threads }
function M.load(review)
  local empty = { version = VERSION, threads = {} }

  local ok, lines = pcall(vim.fn.readfile, M.path(review))
  if not ok or #lines == 0 then
    return empty
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.threads) ~= "table" then
    return empty
  end
  decoded.version = decoded.version or VERSION
  return decoded
end

--- Write a review's drafts back.
---@param review table
---@param store table
---@return boolean ok, string|nil err
function M.save(review, store)
  local ok, err = pcall(vim.fn.mkdir, review.dir, "p")
  if not ok then
    return false, tostring(err):gsub("^Vim:", "")
  end

  store.version = store.version or VERSION
  ok, err = pcall(
    vim.fn.writefile,
    vim.split(vim.json.encode(store), "\n", { plain = true }),
    M.path(review)
  )
  if not ok then
    return false, tostring(err):gsub("^Vim:", "")
  end
  return true
end

---@return string
local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Start a thread on a line.
---@param store table
---@param anchor table { path, side, line, commit_id }
---@param body string
---@return table thread
function M.add(store, anchor, body)
  local thread = {
    path = anchor.path,
    side = anchor.side,
    line = anchor.line,
    commit_id = anchor.commit_id,
    comments = {
      {
        -- No author: it is yours, and it has not been sent.  A thread fetched
        -- from GitHub will name one.
        author = nil,
        body = body,
        created_at = now(),
        state = "draft",
      },
    },
  }
  table.insert(store.threads, thread)
  return thread
end

--- Every thread anchored to one line.
---@param store table
---@param path string
---@param side string
---@param line integer
---@return table[] threads
function M.at(store, path, side, line)
  local found = {}
  for _, thread in ipairs(store.threads) do
    if thread.path == path and thread.side == side and thread.line == line then
      table.insert(found, thread)
    end
  end
  return found
end

--- Every thread on one file, whichever side it is on.
---@param store table
---@param path string
---@return table[] threads
function M.for_file(store, path)
  local found = {}
  for _, thread in ipairs(store.threads) do
    if thread.path == path then
      table.insert(found, thread)
    end
  end
  return found
end

--- How many threads each file carries, for the file list.
---@param store table
---@return table<string, integer>
function M.counts(store)
  local counts = {}
  for _, thread in ipairs(store.threads) do
    counts[thread.path] = (counts[thread.path] or 0) + 1
  end
  return counts
end

--- Drop a thread.
---@param store table
---@param thread table  the thread itself, as returned by at() or for_file()
---@return boolean removed
function M.remove(store, thread)
  for index, candidate in ipairs(store.threads) do
    if candidate == thread then
      table.remove(store.threads, index)
      return true
    end
  end
  return false
end

--- The threads that have never been sent, in the order they were written.
--- This is what a review submission is made of.
---@param store table
---@return table[] threads
function M.drafts(store)
  local drafts = {}
  for _, thread in ipairs(store.threads) do
    for _, comment in ipairs(thread.comments or {}) do
      if comment.state == "draft" then
        table.insert(drafts, thread)
        break
      end
    end
  end
  return drafts
end

--- The key a comment is recognised by when GitHub hands it back.
---
--- Not the line: an outdated thread reports the line it was pinned to rather
--- than the one it was written against, and the two differ exactly when the
--- pull request has changed the code since.  The file, the side and the text
--- identify it well enough, and the text is the part nothing else shares.
---@param path string
---@param side string
---@param body string
---@return string
local function key(path, side, body)
  return table.concat({ path or "", side or "", body or "" }, "\0")
end

--- Drop the drafts GitHub has taken over.
---
--- A comment that has been sent exists twice: here, marked published, and in
--- the threads fetched back from GitHub.  Drawn from both, it would appear
--- twice against its line.  The fetched copy wins -- it is the one that can
--- gain replies and be resolved -- but only once it has actually arrived, so
--- a fetch that has not happened yet, or that failed, never costs the record
--- of what was said.
---@param store table  the drafts
---@param fetched table|nil  a thread store, as gauntlet.threads returns one
---@return integer dropped
function M.forget_published(store, fetched)
  local arrived = {}
  for _, thread in ipairs((fetched or {}).threads or {}) do
    for _, comment in ipairs(thread.comments or {}) do
      arrived[key(thread.path, thread.side, comment.body)] = true
    end
  end

  local kept, dropped = {}, 0
  for _, thread in ipairs(store.threads or {}) do
    local handed_over = #(thread.comments or {}) > 0
    for _, comment in ipairs(thread.comments or {}) do
      if comment.state ~= "published"
        or not arrived[key(thread.path, thread.side, comment.body)]
      then
        handed_over = false
        break
      end
    end

    if handed_over then
      dropped = dropped + 1
    else
      table.insert(kept, thread)
    end
  end

  store.threads = kept
  return dropped
end

return M
