---@diagnostic disable: undefined-global
local M = {}

local function report(level, msg)
  local fn = vim.health[level] or vim.health["report_" .. level]
  fn(msg)
end

function M.check()
  vim.health.start("gauntlet.nvim")

  local ok, gauntlet = pcall(require, "gauntlet")
  if not ok then
    report("error", "cannot require('gauntlet'): " .. tostring(gauntlet))
    return
  end

  if gauntlet._configured then
    report("ok", "setup() has run")
  else
    report("warn", "setup() has not run - call require('gauntlet').setup()")
  end

  local cmd = gauntlet.agent_command()
  if not cmd then
    report("error", "unknown agent '" .. tostring(gauntlet.config.agent) .. "'")
  elseif vim.fn.executable(cmd) == 1 then
    report("ok", "agent CLI found: " .. cmd)
  else
    report("error", "agent CLI not on PATH: " .. cmd)
  end

  if gauntlet.config.forge == "github" then
    if vim.fn.executable("gh") == 1 then
      report("ok", "gh CLI found")
    else
      report("error", "gh CLI not on PATH (required for forge = 'github')")
    end
  end
end

return M
