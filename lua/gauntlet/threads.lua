---@diagnostic disable: undefined-global
-- Review threads fetched from GitHub.
--
-- Kept in a file of their own, apart from the comments you write: a re-fetch
-- replaces this wholesale, and must never be able to touch a draft.
--
-- Read through GraphQL rather than REST.  REST returns a flat list of comments
-- that have to be stitched back into threads through in_reply_to_id, and it
-- cannot say whether a thread was resolved at all.
local M = {}

local VERSION = 1

local QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          diffSide
          subjectType
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              author { login }
              body
              createdAt
              originalLine
            }
          }
        }
      }
    }
  }
}
]]

--- Where a review's fetched threads are cached.
---@param review table
---@return string
function M.path(review)
  return vim.fs.joinpath(review.dir, "threads.json")
end

--- Read the cache.  Nothing fetched yet is the ordinary case, not a fault.
---@param review table
---@return table store { version, fetched_at, threads }
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
  return decoded
end

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

--- Turn one GraphQL thread into the shape the review already understands:
--- the same thread shape a draft uses, with what only GitHub knows added.
---@param node table
---@return table|nil thread
local function convert(node)
  local comments = {}
  for _, comment in ipairs(((node.comments or {}).nodes) or {}) do
    table.insert(comments, {
      -- A deleted account has no author, so say so rather than claiming it.
      author = (comment.author or {}).login or "(unknown)",
      body = comment.body or "",
      created_at = comment.createdAt,
      state = "published",
    })
  end
  if #comments == 0 then
    return nil
  end

  -- An outdated thread has no current line: it is pinned to code the pull
  -- request has since changed.  GitHub still remembers where it was.
  local line = node.line
  if line == vim.NIL or line == nil then
    line = (((node.comments or {}).nodes or {})[1] or {}).originalLine
  end
  if line == vim.NIL then
    line = nil
  end

  return {
    id = node.id,
    origin = "github",
    path = node.path,
    side = node.diffSide == "LEFT" and "LEFT" or "RIGHT",
    line = line,
    resolved = node.isResolved == true,
    outdated = node.isOutdated == true,
    -- A comment on a whole file rather than a line cannot be drawn against
    -- one, so it is kept and counted but not anchored.
    subject = node.subjectType == "FILE" and "file" or "line",
    comments = comments,
  }
end

--- Ask GitHub for a pull request's review threads.
---@param repo table { owner, repo }
---@param number integer
---@return table[]|nil threads, string|nil err
function M.fetch(repo, number)
  local config = require("gauntlet").config
  if vim.fn.executable(config.gh) == 0 then
    return nil, ("%s not found on PATH; install the GitHub CLI"):format(config.gh)
  end

  local out = table.concat(vim.fn.systemlist({
    config.gh, "api", "graphql",
    "-f", "query=" .. QUERY,
    "-F", "owner=" .. repo.owner,
    "-F", "repo=" .. repo.repo,
    "-F", "number=" .. number,
  }), "\n")

  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(out) ~= "" and vim.trim(out) or "gh exited with an error"
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not parse the response from gh"
  end

  local review_threads = (((((decoded or {}).data or {}).repository or {}).pullRequest or {}).reviewThreads)
  if not review_threads then
    return nil, "no review threads in the response from GitHub"
  end

  local threads = {}
  for _, node in ipairs(review_threads.nodes or {}) do
    local thread = convert(node)
    if thread then
      table.insert(threads, thread)
    end
  end
  return threads
end

--- Fetch and cache.  On failure the cache is left alone, so a review that
--- already has threads keeps them rather than losing them to a bad connection.
---@param repo table
---@param review table
---@return table|nil store, string|nil err
function M.refresh(repo, review)
  local threads, err = M.fetch(repo, review.number)
  if not threads then
    return nil, err
  end

  local store = {
    version = VERSION,
    fetched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    threads = threads,
  }
  local ok
  ok, err = M.save(review, store)
  if not ok then
    return nil, err
  end
  return store
end

--- Threads worth drawing against a line: open, current, and anchored.
---@param store table
---@return table[]
function M.visible(store)
  local out = {}
  for _, thread in ipairs(store.threads or {}) do
    if not thread.resolved and not thread.outdated and thread.line and thread.subject ~= "file" then
      table.insert(out, thread)
    end
  end
  return out
end

--- Threads held back: resolved, outdated, or not about a line at all.
---@param store table
---@return table[]
function M.hidden(store)
  local out = {}
  for _, thread in ipairs(store.threads or {}) do
    if thread.resolved or thread.outdated or not thread.line or thread.subject == "file" then
      table.insert(out, thread)
    end
  end
  return out
end

return M
