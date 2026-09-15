---@diagnostic disable: undefined-global
-- GitHub access, via the `gh` CLI so we inherit its authentication.
local M = {}

-- Fields fetched for a single pull request.  Kept to cheap scalars; `commits`
-- and `files` would pull whole lists we do not display yet.
local PR_FIELDS = table.concat({
  "number",
  "title",
  "body",
  "author",
  "state",
  "isDraft",
  "url",
  "headRefName",
  "baseRefName",
  "headRefOid",
  "baseRefOid",
  "createdAt",
  "additions",
  "deletions",
  "changedFiles",
}, ",")

local LIST_FIELDS = "number,title,author,isDraft,headRefName,updatedAt"

--- Run `gh` and decode its JSON output.
---@param args string[]
---@return table|nil decoded, string|nil err
local function gh_json(args)
  local config = require("gauntlet").config
  local cmd = vim.list_extend({ config.gh }, args)

  if vim.fn.executable(config.gh) == 0 then
    return nil, ("%s not found on PATH; install the GitHub CLI"):format(config.gh)
  end

  local out = table.concat(vim.fn.systemlist(cmd), "\n")
  if vim.v.shell_error ~= 0 then
    -- gh writes its diagnostics to stderr, which systemlist() folds into out.
    return nil, vim.trim(out) ~= "" and vim.trim(out) or "gh exited with an error"
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not parse the response from gh"
  end
  return decoded
end

---@param repo table { owner, repo }
local function slug(repo)
  return repo.owner .. "/" .. repo.repo
end

--- Open pull requests for a repository.
--- An empty repository, or one with nothing open, yields an empty list --
--- that is a result, not an error.
---@return table[]|nil prs, string|nil err
function M.list_open(repo)
  local config = require("gauntlet").config
  return gh_json({
    "pr",
    "list",
    "--repo",
    slug(repo),
    "--state",
    "open",
    "--limit",
    tostring(config.limit),
    "--json",
    LIST_FIELDS,
  })
end

--- A single open pull request.
--- A PR that exists but is merged or closed is reported the same way as one
--- that never existed: there is no open PR with that id.
---@return table|nil pr, string|nil err
function M.get_open(repo, number)
  local pr, err = gh_json({
    "pr",
    "view",
    tostring(number),
    "--repo",
    slug(repo),
    "--json",
    PR_FIELDS,
  })
  if not pr then
    -- The ordinary "no such PR" case gets a plain message; anything else
    -- (auth, network, rate limit) keeps gh's own explanation.
    if err:match("Could not resolve to a PullRequest") or err:match("no pull requests found") then
      return nil, ("%s has no pull request #%d"):format(slug(repo), number)
    end
    return nil, ("could not read %s#%d: %s"):format(slug(repo), number, err)
  end
  if pr.state ~= "OPEN" then
    return nil,
      ("%s#%d is %s, not open"):format(slug(repo), number, pr.state:lower())
  end
  return pr
end

--- Make sense of a refusal from the API.
---
--- GitHub explains itself in the response body, which gh prints alongside its
--- own one-line summary.  The body is the useful half -- "Can not approve your
--- own pull request" says what to do about it, where "HTTP 422" does not.
---@param out string  everything gh wrote
---@return string
local function api_error(out)
  out = vim.trim(out or "")

  local ok, decoded = pcall(vim.json.decode, out)
  if ok and type(decoded) == "table" and decoded.message then
    local parts = { decoded.message }
    for _, item in ipairs(decoded.errors or {}) do
      -- An entry is either a string or an object explaining one field.
      local detail = type(item) == "table" and (item.message or item.field) or item
      if type(detail) == "string" then
        table.insert(parts, detail)
      end
    end
    return table.concat(parts, "; ")
  end

  -- gh's own form, when the body was not JSON: "gh: Not Found (HTTP 404)".
  for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
    local message = line:match("^gh: (.+)$")
    if message then
      return message
    end
  end

  return out ~= "" and out or "gh exited with an error"
end

--- Post a review: a verdict, a covering note, and the line comments together.
---
--- One request, because that is how GitHub models a review -- and it is what
--- lets the comments be written offline and sent in a single go.  It is also
--- all or nothing: a comment GitHub will not accept takes the verdict and the
--- covering note down with it, which is why gauntlet.send checks first.
---@param repo table { owner, repo }
---@param number integer
---@param payload table { commit_id, body, event, comments }
---@return table|nil review, string|nil err
function M.submit_review(repo, number, payload)
  local config = require("gauntlet").config
  if vim.fn.executable(config.gh) == 0 then
    return nil, ("%s not found on PATH; install the GitHub CLI"):format(config.gh)
  end

  local out = vim.fn.system({
    config.gh,
    "api",
    ("repos/%s/%s/pulls/%d/reviews"):format(repo.owner, repo.repo, number),
    "--method",
    "POST",
    "--input",
    "-",
  }, vim.json.encode(payload))

  if vim.v.shell_error ~= 0 then
    return nil, api_error(out)
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "could not parse the response from gh"
  end
  return decoded
end

--- The comments of a review, in the shape GitHub's reviews endpoint wants.
---@param threads table[]
---@return table[]
function M.review_comments(threads)
  local out = {}
  for _, thread in ipairs(threads) do
    local body = {}
    for _, comment in ipairs(thread.comments or {}) do
      table.insert(body, comment.body)
    end
    table.insert(out, {
      path = thread.path,
      line = thread.line,
      side = thread.side,
      body = table.concat(body, "\n\n"),
    })
  end
  return out
end

return M
