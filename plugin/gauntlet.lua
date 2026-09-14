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

vim.api.nvim_create_user_command("GauntletSubmit", function()
  local state = require("gauntlet.ui").current()
  if not state then
    vim.notify("gauntlet: no review here to submit", vim.log.levels.ERROR)
    return
  end
  require("gauntlet.ui").submit(state)
end, {
  desc = "Send this review's comments to GitHub as one review",
})

vim.api.nvim_create_user_command("GauntletRefresh", function()
  local state = require("gauntlet.ui").current()
  if not state then
    vim.notify("gauntlet: no review here to refresh", vim.log.levels.ERROR)
    return
  end
  require("gauntlet").refresh(state)
end, {
  desc = "Fetch this review's comment threads from GitHub again",
})

vim.api.nvim_create_user_command("GauntletDiscard", function(opts)
  require("gauntlet").discard(opts.args)
end, {
  nargs = "?",
  desc = "Remove a review from disk: its worktree, its ref and its drafts",
})
