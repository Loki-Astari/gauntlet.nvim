---@diagnostic disable: undefined-global
-- gauntlet.nvim - a Neovim user interface for working on pull requests.
local M = {}

M.version = "0.0.1"

-- Default configuration.  Overridable from setup().
M.config = {}

-- True once setup() has run.
M._configured = false

--- Merge user options into M.config.
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M._configured = true

  -- All autocmds live in this group, so re-running setup() re-registers them
  -- cleanly instead of stacking duplicates.
  vim.api.nvim_create_augroup("Gauntlet", { clear = true })
end

return M
