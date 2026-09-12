-- Minimal Neovim init for running tests with plenary.nvim.
-- Usage:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
--
-- Set PLENARY_DIR to override the default plenary path, e.g.:
--   PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless ...

local plenary_dir = os.getenv("PLENARY_DIR")
  or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

-- Resolve the plugin root from this file rather than from the working
-- directory: a test that changes directory must still be able to require the
-- plugin's own modules.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

vim.opt.runtimepath:prepend(plenary_dir)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":p:h"))
