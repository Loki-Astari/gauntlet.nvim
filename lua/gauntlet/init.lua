---@diagnostic disable: undefined-global
-- gauntlet.nvim - run a pull request through review, from inside Neovim.
local M = {}

M.version = "0.0.1"

-- Default configuration.  Everything here is overridable from setup().
M.config = {
  -- Symbolic name of the agent CLI that performs the review.
  agent = "claude",
  -- Map of symbolic names to CLI executables.
  known_agents = {
    claude = "claude",
    codex  = "codex",
  },
  -- Forge the PRs are read from.  Only "github" (via the `gh` CLI) for now.
  forge = "github",
}

-- True once setup() has run.  Commands check this so an un-configured install
-- fails with a useful message rather than a nil index deep inside a callback.
M._configured = false

--- Merge user options into M.config.
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M._configured = true

  vim.api.nvim_create_augroup("Gauntlet", { clear = true })
end

--- Executable backing the configured agent, or nil when unknown.
---@return string|nil
function M.agent_command()
  return M.config.known_agents[M.config.agent]
end

--- One-line status, used by :Gauntlet and the health check.
---@return string
function M.status()
  local cmd = M.agent_command()
  return table.concat({
    "gauntlet.nvim " .. M.version,
    "agent: " .. tostring(M.config.agent) .. " (" .. tostring(cmd) .. ")",
    "forge: " .. tostring(M.config.forge),
  }, "  |  ")
end

return M
