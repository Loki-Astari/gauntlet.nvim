---@diagnostic disable: undefined-global
-- Windows and buffers.
local render = require("gauntlet.render")

local M = {}

--- True for the empty, unnamed, unmodified buffer Neovim starts with.
---@param buf integer
local function is_startup_scratch(buf)
  return vim.api.nvim_buf_get_name(buf) == ""
    and vim.bo[buf].buftype == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

--- Open the read-only conversation view for a pull request.
---
--- It gets a tab page of its own so the user's window layout is left alone --
--- unless the only thing on screen is Neovim's own empty starting buffer, in
--- which case that is taken over.  `vig` starts Neovim with nothing loaded, so
--- a new tab would strand a blank [No Name] tab beside the review.
---@param pr table
---@param repo table { owner, repo }
---@return integer buf
function M.conversation(pr, repo)
  local alone = #vim.api.nvim_tabpage_list_wins(0) == 1
    and is_startup_scratch(vim.api.nvim_get_current_buf())
  if not alone then
    vim.cmd("tabnew")
  end

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

  -- Tab and buffer labels are drawn from the tail of the buffer's name, both
  -- by Neovim's own tabline and by bufferline-style plugins, so the tail is
  -- the title and the leading path is only there to keep the name unique:
  -- two repositories can each have a pull request #1.
  -- `pcall` because a name still in use raises, and a nameless view beats a
  -- failed one.
  local title = M.title(pr)
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    ("%s/%s/%s"):format(repo.owner, repo.repo, title)
  )
  vim.t.gauntlet_title = title

  -- `quit` rather than `tabclose`: it closes the review's window, which closes
  -- its tab, and ends Neovim when the review was all that was open -- which is
  -- what `vig` leaves behind.
  vim.keymap.set("n", "q", "<cmd>quit<cr>", {
    buffer = buf,
    nowait = true,
    desc = "Gauntlet: close the pull request view",
  })

  return buf
end

--- The label a review is shown under.
---@param pr table
---@return string
function M.title(pr)
  return ("PR Review %d"):format(pr.number)
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
