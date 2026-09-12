---@diagnostic disable: undefined-global
-- Turning pull request data into lines of text.
-- Kept apart from the windowing code so it can be tested without a UI.
local M = {}

---@param pr table
---@return string
function M.author(pr)
  return pr.author and pr.author.login or "unknown"
end

--- "2026-09-12T10:04:00Z" -> "2026-09-12".  Anything unexpected is passed
--- through untouched rather than guessed at.
---@param stamp string|nil
---@return string
function M.date(stamp)
  return (stamp or ""):match("^(%d%d%d%d%-%d%d%-%d%d)") or (stamp or "")
end

--- One line describing a PR, for the picker.
---@param pr table
---@return string
function M.summary(pr)
  return ("#%-5d %s  (%s)%s"):format(
    pr.number,
    pr.title,
    M.author(pr),
    pr.isDraft and "  [draft]" or ""
  )
end

--- The conversation view: a header block, then the PR description verbatim.
---@param pr table
---@return string[]
function M.conversation(pr)
  local lines = {
    ("# #%d  %s"):format(pr.number, pr.title),
    "",
    ("%s wants to merge `%s` into `%s`"):format(
      M.author(pr),
      pr.headRefName or "?",
      pr.baseRefName or "?"
    ),
    ("%s · %d file%s changed · +%d −%d · opened %s"):format(
      pr.isDraft and "Draft" or "Open",
      pr.changedFiles or 0,
      (pr.changedFiles == 1) and "" or "s",
      pr.additions or 0,
      pr.deletions or 0,
      M.date(pr.createdAt)
    ),
    pr.url or "",
    "",
    "---",
    "",
  }

  local body = vim.trim(pr.body or "")
  if body == "" then
    table.insert(lines, "*No description provided.*")
  else
    -- GitHub stores bodies with CRLF line endings.
    for _, line in ipairs(vim.split(body:gsub("\r", ""), "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  return lines
end

return M
