---@diagnostic disable: undefined-global
-- Turn whatever the user typed into a PR reference.
local M = {}

--- Parse the argument given to `:Gauntlet` or `vig`.
---
--- Accepts a bare number (`142`), a hash-prefixed number (`#142`), or a full
--- pull request URL.  A URL also pins the owner/repo, which the caller checks
--- against the current repository.
---@param input string|nil
---@return table|nil target  { number, owner?, repo? }, or nil with an error
function M.target(input)
  input = vim.trim(input or "")
  if input == "" then
    return nil, "no pull request given"
  end

  local number = input:match("^#?(%d+)$")
  if number then
    return { number = tonumber(number) }
  end

  -- https://github.com/<owner>/<repo>/pull/<id>, with any trailing path
  -- (/files, /commits, #issuecomment-...) ignored.
  local owner, repo, id =
    input:match("^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)")
  if owner then
    return { number = tonumber(id), owner = owner, repo = (repo:gsub("%.git$", "")) }
  end

  if input:match("^https?://") then
    return nil, "not a GitHub pull request URL: " .. input
  end
  return nil, "not a pull request number or URL: " .. input
end

return M
