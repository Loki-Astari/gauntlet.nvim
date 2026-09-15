---@diagnostic disable: undefined-global
-- gauntlet.nvim - a Neovim user interface for working on pull requests
-- Maintainer: Loki-Astari
-- License: MIT

if vim.g.loaded_gauntlet then
  return
end
vim.g.loaded_gauntlet = true

vim.api.nvim_create_user_command("Gauntlet", function(opts)
  require("gauntlet").review(opts.args)
end, {
  nargs = "?",
  desc = "Review a GitHub pull request (by number or URL; no argument lists open PRs)",
})

--- The commands that act on the review under the cursor all need one.
---@param what string  what the command would have done, for the message
---@return table|nil state
local function review(what)
  local state = require("gauntlet.ui").current()
  if not state then
    vim.notify(("gauntlet: no review here to %s"):format(what), vim.log.levels.ERROR)
    return nil
  end
  return state
end

vim.api.nvim_create_user_command("GauntletSubmit", function()
  local state = review("submit")
  if state then
    require("gauntlet.ui").submit(state)
  end
end, {
  desc = "Choose a verdict and send this review to GitHub",
})

vim.api.nvim_create_user_command("GauntletPush", function()
  local state = review("push")
  if state then
    require("gauntlet").push(state)
  end
end, {
  desc = "Send the comments written since the last send, and nothing else",
})

vim.api.nvim_create_user_command("GauntletNote", function()
  local state = review("write a note on")
  if state then
    require("gauntlet").note(state)
  end
end, {
  desc = "Write something about the pull request as a whole, and send it",
})

vim.api.nvim_create_user_command("GauntletApprove", function()
  local state = review("approve")
  if state then
    require("gauntlet").approve(state)
  end
end, {
  desc = "Approve this pull request, sending any unsent comments with it",
})

vim.api.nvim_create_user_command("GauntletReject", function()
  local state = review("reject")
  if state then
    require("gauntlet").reject(state)
  end
end, {
  desc = "Request changes on this pull request, sending any unsent comments with it",
})

vim.api.nvim_create_user_command("GauntletRefresh", function()
  local state = review("refresh")
  if state then
    require("gauntlet").refresh(state)
  end
end, {
  desc = "Fetch this review's new commits and comment threads from GitHub",
})

vim.api.nvim_create_user_command("GauntletCommit", function()
  local state = review("commit in")
  if state then
    require("gauntlet").commit(state)
  end
end, {
  desc = "Commit what you have changed in a pull request of your own",
})

vim.api.nvim_create_user_command("GauntletPublish", function()
  local state = review("publish")
  if state then
    require("gauntlet").publish(state)
  end
end, {
  desc = "Push what the review worktree holds onto the pull request's branch",
})

vim.api.nvim_create_user_command("GauntletDiscard", function(opts)
  require("gauntlet").discard(opts.args)
end, {
  nargs = "?",
  desc = "Remove a review from disk: its worktree, its ref and its drafts",
})
