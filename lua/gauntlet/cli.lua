---@diagnostic disable: undefined-global
-- Headless entry point, run by bin/vig as `nvim --headless -l cli.lua ...`.
--
-- It exists so the terminal commands share one implementation with the editor
-- commands: every check `:Gauntlet` makes happens here too, before a full
-- Neovim is ever started.
--
--   cli.lua list            print the open pull requests
--   cli.lua review <arg>    validate <arg> and print a preload file path
--
-- Errors go to stderr with a non-zero exit, so vig can decline to start Neovim.

local root = vim.env.GAUNTLET_ROOT or vim.fn.fnamemodify(arg[0], ":h:h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local function die(msg)
  io.stderr:write("vig: " .. msg .. "\n")
  os.exit(1)
end

local gauntlet = require("gauntlet")
local github = require("gauntlet.github")
local render = require("gauntlet.render")

local mode = arg[1] or "list"

if mode == "list" then
  local repo, _, err = gauntlet.resolve(nil)
  if err then
    die(err)
  end

  local prs
  prs, err = github.list_open(repo)
  if not prs then
    die(err)
  end

  -- No open pull requests is an empty list, not a failure.
  for _, pr in ipairs(prs) do
    io.stdout:write(render.summary(pr) .. "\n")
  end
  os.exit(0)
end

if mode == "review" then
  local repo, pr, err = gauntlet.resolve(arg[2])
  if err then
    die(err)
  end

  -- Fetch the pull request and check it out here, not in the editor: this is
  -- the part that can fail slowly -- no network, a vanished branch, a
  -- repository too shallow to find the merge base -- and vig promises that a
  -- failure is a message on the terminal, not a half-open review.
  io.stderr:write(("vig: preparing the review of #%d\n"):format(pr.number))
  local ctx
  ctx, err = gauntlet.prepare(repo, pr)
  if not ctx then
    die(err)
  end

  -- Hand the whole prepared review to the Neovim we are about to start, rather
  -- than making it do any of that again.  os.tmpname() rather than
  -- vim.fn.tempname(): the latter is erased when this process exits.
  local path = os.tmpname()
  local file, ferr = io.open(path, "w")
  if not file then
    die(ferr or ("could not write " .. path))
  end
  file:write(vim.json.encode(ctx))
  file:close()

  io.stdout:write(path .. "\n")
  os.exit(0)
end

die("unknown mode: " .. tostring(mode))
