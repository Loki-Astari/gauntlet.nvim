---@diagnostic disable: undefined-global
-- gauntlet.nvim - pull request review in Neovim
-- Maintainer: Loki-Astari
-- License: MIT

if vim.g.loaded_gauntlet then
  return
end
vim.g.loaded_gauntlet = true

vim.api.nvim_create_user_command("Gauntlet", function()
  vim.notify(require("gauntlet").status(), vim.log.levels.INFO)
end, { nargs = 0, desc = "Show gauntlet.nvim status" })
