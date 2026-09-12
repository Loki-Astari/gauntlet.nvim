---@diagnostic disable: undefined-global
-- gauntlet.nvim - a Neovim user interface for working on pull requests.
local M = {}

M.version = "0.0.1"

-- Default configuration.  Overridable from setup().
M.config = {
  -- The GitHub CLI executable.  Its authentication is ours.
  gh = "gh",
  -- Most open pull requests to list at once.
  limit = 100,
}

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

--- Work out which repository and pull request an argument refers to.
--- This is the whole validation chain, shared by `:Gauntlet` and `vig`, and
--- deliberately free of UI so it can run headless.
---@param input string|nil  a PR number, a PR URL, or nil/"" for none
---@return table|nil repo, table|nil pr, string|nil err
function M.resolve(input)
  local git = require("gauntlet.git")
  local parse = require("gauntlet.parse")
  local github = require("gauntlet.github")

  if not git.is_repo() then
    return nil, nil, "not inside a git repository"
  end

  local repo, err = git.primary()
  if not repo then
    return nil, nil, err
  end

  input = vim.trim(input or "")
  if input == "" then
    return repo, nil
  end

  local target
  target, err = parse.target(input)
  if not target then
    return nil, nil, err
  end

  -- A URL names its own repository; refuse it if that is not this one.
  if target.owner and not git.has_remote(target.owner, target.repo) then
    return nil, nil,
      ("%s/%s is not a remote of this repository"):format(target.owner, target.repo)
  end

  local pr
  pr, err = github.get_open(repo, target.number)
  if not pr then
    return nil, nil, err
  end
  return repo, pr
end

--- The `:Gauntlet` command.  With an argument, review that PR; without one,
--- offer the open pull requests to choose from.
---@param input string|nil
function M.review(input)
  local ui = require("gauntlet.ui")
  local github = require("gauntlet.github")

  local repo, pr, err = M.resolve(input)
  if err then
    vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
    return
  end

  if pr then
    ui.conversation(pr, repo)
    return
  end

  local prs
  prs, err = github.list_open(repo)
  if not prs then
    vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
    return
  end

  ui.pick(prs, function(choice)
    local full, ferr = github.get_open(repo, choice.number)
    if not full then
      vim.notify("gauntlet: " .. ferr, vim.log.levels.ERROR)
      return
    end
    ui.conversation(full, repo)
  end)
end

--- Show the pull request `vig` left in $GAUNTLET_PRELOAD.
--- The file is ours, and is consumed exactly once.
--- Exposed for the tests; M.open_preload() is the entry point.
function M._open_preloaded()
  local path = vim.env.GAUNTLET_PRELOAD
  if not path or path == "" then
    return
  end
  vim.env.GAUNTLET_PRELOAD = nil

  local ok, content = pcall(vim.fn.readfile, path)
  pcall(vim.fn.delete, path)
  if not ok then
    return
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok or not decoded or not decoded.pr then
    vim.notify("gauntlet: could not read the preloaded pull request", vim.log.levels.ERROR)
    return
  end

  require("gauntlet.ui").conversation(decoded.pr, decoded.repo)
end

--- Open a pull request that `vig` already fetched and validated, so starting
--- Neovim does not repeat the network round trip.
function M.open_preload()
  -- `vig` calls this from a -c argument, and Neovim runs those *before*
  -- VimEnter.  A config that restores a session on VimEnter -- or opens a
  -- dashboard, or a file tree -- would then land on top of the review we had
  -- just put up, and 'bufhidden' "wipe" means the review would not survive
  -- even as a buffer.  Let startup finish first.
  if vim.v.vim_did_enter == 0 then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("GauntletPreload", { clear = true }),
      once = true,
      nested = true,
      callback = function()
        vim.schedule(M._open_preloaded)
      end,
      desc = "Gauntlet: open the preloaded pull request once startup has settled",
    })
    return
  end

  M._open_preloaded()
end

return M
