---@diagnostic disable: undefined-global
-- Local git inspection: are we in a repository, and which GitHub project is it?
local M = {}

--- Run a command, returning its stdout lines.
---@param cmd string[]
---@return string[]|nil lines, string|nil err
local function run(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(table.concat(out, "\n"))
  end
  return out
end

--- Split a git remote URL into its host and GitHub owner/repo.
--- Handles the three shapes git uses: scheme://host/path, user@host:path,
--- and a bare host/path.
---@param url string
---@return string|nil host, string|nil owner, string|nil repo
function M.parse_remote(url)
  url = vim.trim(url or ""):gsub("%.git$", "")
  if url == "" then
    return nil
  end

  local rest = url:match("^%a[%w+%-.]*://(.*)$") -- scheme://user@host/path
    or url:match("^[^/]-@([^/]+:.*)$") -- user@host:path
    or url

  rest = rest:gsub("^[^/@]*@", "") -- drop a leftover user@
  rest = rest:gsub(":", "/", 1) -- scp-style colon is a path separator

  local host, owner, repo = rest:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not host then
    return nil
  end
  return host, owner, repo
end

--- The root of the current work tree.
--- Git commands are run against this rather than the working directory: a
--- review's own worktree lives elsewhere, and `vig` may be started anywhere
--- inside the repository.
---@return string|nil root, string|nil err
function M.root()
  local out, err = run({ "git", "rev-parse", "--show-toplevel" })
  if not out or not out[1] or out[1] == "" then
    return nil, err or "could not find the repository root"
  end
  return out[1]
end

--- Run a git command inside `root`.
---@param root string
---@param args string[]
---@return string[]|nil lines, string|nil err
function M.run(root, args)
  return run(vim.list_extend({ "git", "-C", root }, args))
end

--- True when the current working directory is inside a git work tree.
function M.is_repo()
  local out = run({ "git", "rev-parse", "--is-inside-work-tree" })
  return out ~= nil and out[1] == "true"
end

--- Every GitHub remote of the current repository.
---@return table[] remotes  list of { name, owner, repo }
function M.remotes()
  local out = run({ "git", "remote", "-v" })
  if not out then
    return {}
  end

  local seen, remotes = {}, {}
  for _, line in ipairs(out) do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name and not seen[name] then
      local host, owner, repo = M.parse_remote(url)
      if host == "github.com" then
        seen[name] = true
        table.insert(remotes, { name = name, owner = owner, repo = repo })
      end
    end
  end
  return remotes
end

--- The repository a bare PR number refers to.
--- `upstream` wins over `origin` so that working from a fork reviews the PRs
--- of the project you forked, which is where they actually live.
---@return table|nil repo  { owner, repo }, or nil with an error message
function M.primary()
  local remotes = M.remotes()
  if #remotes == 0 then
    return nil, "no GitHub remote found for this repository"
  end

  for _, want in ipairs({ "upstream", "origin" }) do
    for _, remote in ipairs(remotes) do
      if remote.name == want then
        return remote
      end
    end
  end
  return remotes[1]
end

--- Does owner/repo name one of this repository's remotes?
function M.has_remote(owner, repo)
  for _, remote in ipairs(M.remotes()) do
    if remote.owner:lower() == owner:lower() and remote.repo:lower() == repo:lower() then
      return true
    end
  end
  return false
end

return M
