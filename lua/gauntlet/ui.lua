---@diagnostic disable: undefined-global
-- Windows and buffers.
local render = require("gauntlet.render")

local M = {}

--- Open the read-only conversation view for a pull request, in its own tab
--- page so the user's existing window layout is left alone.
---@param pr table
---@param repo table { owner, repo }
---@return integer buf
function M.conversation(pr, repo)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render.conversation(pr))

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = true

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].spell = false

  -- A stable, descriptive name; `silent!` because reopening the same PR would
  -- otherwise collide with the wiped buffer's name.
  pcall(vim.api.nvim_buf_set_name, buf, ("gauntlet://%s/%s/pull/%d"):format(repo.owner, repo.repo, pr.number))

  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", {
    buffer = buf,
    nowait = true,
    desc = "Gauntlet: close the pull request view",
  })

  return buf
end

--- Let the user choose from the open pull requests.
--- Routed through vim.ui.select so an installed picker takes over automatically.
---@param prs table[]
---@param on_choice fun(pr: table)
function M.pick(prs, on_choice)
  if #prs == 0 then
    vim.notify("gauntlet: no open pull requests", vim.log.levels.INFO)
    return
  end

  vim.ui.select(prs, {
    prompt = "Open pull requests",
    format_item = render.summary,
  }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

return M
