---@diagnostic disable: undefined-global
-- The review interface: one tab page, a file list on the left, and on the
-- right either the pull request's description or a two-pane diff.
--
-- Everything shown is read-only.  That costs nothing a reviewer wants: LSP,
-- `gd` and `K` all work on a non-modifiable buffer.
local render = require("gauntlet.render")
local changes = require("gauntlet.changes")

local M = {}

local SIDEBAR_WIDTH = 40

-- Review state, keyed by tab page handle, so several reviews can be open at
-- once without knowing about each other.
---@type table<integer, table>
local reviews = {}

--- True for the empty, unnamed, unmodified buffer Neovim starts with.
---@param buf integer
local function is_startup_scratch(buf)
  return vim.api.nvim_buf_get_name(buf) == ""
    and vim.bo[buf].buftype == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

--- The label a review is shown under.
---@param pr table
---@return string
function M.title(pr)
  return ("PR Review %d"):format(pr.number)
end

--- A scratch buffer holding `lines`, never written and never edited.
---@param lines string[]
---@param name string|nil
---@param filetype string|nil
---@return integer buf
local function scratch(lines, name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  return buf
end

--- Give `buf` a name, taking it from a stale buffer that still holds it.
---
--- Reopening a review, or opening the same pull request twice, would otherwise
--- leave the new buffer nameless -- and the name is what labels the tab.
---@param buf integer
---@param name string
local function claim_name(buf, name)
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.api.nvim_buf_get_name(other) == name then
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
end

--- Leave the tab page holding only the sidebar, and open one window beside it.
---@param state table
---@return integer win
local function content_reset(state)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if win ~= state.sidebar_win then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.api.nvim_set_current_win(state.sidebar_win)
  vim.cmd("rightbelow vsplit")
  vim.api.nvim_win_set_width(state.sidebar_win, SIDEBAR_WIDTH)
  return vim.api.nvim_get_current_win()
end

--- Settings shared by every window on the right-hand side.
---@param win integer
local function content_window(win)
  vim.wo[win].winfixwidth = false
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].spell = false
end

--- Show the pull request's description.
---@param state table
local function show_conversation(state)
  local win = content_reset(state)
  local buf = scratch(
    render.conversation(state.pr),
    ("gauntlet://pr-%d/conversation"):format(state.pr.number),
    "markdown"
  )
  vim.api.nvim_win_set_buf(win, buf)
  content_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  M.apply_keymaps(buf, state)
end

--- Show one file as a diff: the merge-base version on the left, the pull
--- request's version on the right.
---
--- The right-hand side is the real file in the review worktree, so language
--- servers and `gd` see a genuine path, but it is opened non-modifiable: a
--- review must not be able to change the checkout.
---@param state table
---@param file table
local function show_diff(state, file)
  local base_lines, existed = changes.base_lines(state.root, state.review.base, file.path)
  local filetype = vim.filetype.match({ filename = file.path }) or ""

  local left = content_reset(state)
  local base_buf = scratch(
    existed and base_lines or {},
    ("gauntlet://pr-%d/base/%s"):format(state.pr.number, file.path),
    filetype
  )
  vim.api.nvim_win_set_buf(left, base_buf)
  content_window(left)

  vim.cmd("rightbelow vsplit")
  local right = vim.api.nvim_get_current_win()
  local worktree_file = vim.fs.joinpath(state.review.worktree, file.path)

  local head_buf
  if vim.fn.filereadable(worktree_file) == 1 then
    vim.cmd.edit(vim.fn.fnameescape(worktree_file))
    head_buf = vim.api.nvim_get_current_buf()
    vim.bo[head_buf].modifiable = false
    vim.bo[head_buf].readonly = true
  else
    -- A deleted file has no right-hand side.
    head_buf = scratch({}, ("gauntlet://pr-%d/deleted/%s"):format(state.pr.number, file.path), filetype)
    vim.api.nvim_win_set_buf(right, head_buf)
  end
  content_window(right)

  for _, win in ipairs({ left, right }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  vim.api.nvim_win_set_width(state.sidebar_win, SIDEBAR_WIDTH)

  M.apply_keymaps(base_buf, state)
  M.apply_keymaps(head_buf, state)
  vim.api.nvim_set_current_win(right)
end

--- Open whatever the sidebar's cursor is on.
---@param state table
local function open_entry(state)
  local line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
  local entry = state.lines[line]
  if not entry then
    return
  end
  state.current = line
  if entry.kind == "conversation" then
    show_conversation(state)
  else
    show_diff(state, entry.file)
  end
  vim.api.nvim_set_current_win(state.sidebar_win)
  M.render_sidebar(state)
end

--- Draw the file list.
---@param state table
function M.render_sidebar(state)
  local lines, map, marks = {}, {}, {}

  local function add(text, entry, hl)
    table.insert(lines, text)
    if entry then
      map[#lines] = entry
    end
    if hl then
      table.insert(marks, { line = #lines - 1, group = hl })
    end
  end

  add(M.title(state.pr), nil, "Title")
  add(("%s/%s"):format(state.repo.owner, state.repo.repo), nil, "Comment")
  add("")
  add("  Conversation", { kind = "conversation" })
  add("")
  add(("  Files (%d)"):format(#state.files), nil, "Comment")

  for _, file in ipairs(state.files) do
    local counts = ("+%d −%d"):format(file.additions, file.deletions)
    local room = SIDEBAR_WIDTH - 6 - #counts
    local path = file.path
    if vim.fn.strdisplaywidth(path) > room then
      -- Keep the end of a long path: the filename matters more than the tree.
      path = "…" .. path:sub(-room + 1)
    end
    add(
      ("  %s %-" .. room .. "s %s"):format(file.status, path, counts),
      { kind = "file", file = file }
    )
  end

  state.lines = map

  vim.bo[state.sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
  vim.bo[state.sidebar_buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("GauntletSidebar")
  vim.api.nvim_buf_clear_namespace(state.sidebar_buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_add_highlight(state.sidebar_buf, ns, mark.group, mark.line, 0, -1)
  end
  -- Colour the status letter by what it means.
  local status_hl = { A = "DiffAdd", D = "DiffDelete", M = "DiffChange", R = "DiffChange", C = "DiffChange" }
  for line, entry in pairs(map) do
    if entry.kind == "file" then
      local hl = status_hl[entry.file.status]
      if hl then
        vim.api.nvim_buf_add_highlight(state.sidebar_buf, ns, hl, line - 1, 2, 3)
      end
    end
    if line == state.current then
      vim.api.nvim_buf_add_highlight(state.sidebar_buf, ns, "CursorLine", line - 1, 0, -1)
    end
  end
end

--- Keys that work from anywhere in the review.
---@param buf integer
---@param state table
function M.apply_keymaps(buf, state)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Gauntlet: " .. desc })
  end
  map("q", function()
    M.close(state)
  end, "close the review")
  map("<C-w>f", function()
    vim.api.nvim_set_current_win(state.sidebar_win)
  end, "jump to the file list")
end

--- Close a review's tab page.  The worktree is left on disk so the review can
--- be picked up again, offline; :GauntletDiscard is what removes it.
---@param state table
function M.close(state)
  reviews[state.tab] = nil
  if #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose")
  else
    vim.cmd("quit")
  end
end

--- Open the review interface for a pull request.
---@param ctx table { repo, pr, review, files, root }
---@return table state
function M.review(ctx)
  -- Take over Neovim's empty starting buffer when that is all there is, so
  -- `vig` does not strand a blank [No Name] tab beside the review.
  local alone = #vim.api.nvim_tabpage_list_wins(0) == 1
    and is_startup_scratch(vim.api.nvim_get_current_buf())
  if not alone then
    vim.cmd("tabnew")
  end

  local state = vim.tbl_extend("force", ctx, {
    tab = vim.api.nvim_get_current_tabpage(),
    sidebar_win = vim.api.nvim_get_current_win(),
    current = 4,
  })

  state.sidebar_buf = scratch({}, nil, nil)
  vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)

  -- Tab and buffer labels come from the tail of the buffer name, in Neovim's
  -- own tabline and in bufferline-style plugins alike; the repository in
  -- front keeps it unique, two repositories each having a pull request #1.
  claim_name(
    state.sidebar_buf,
    ("%s/%s/%s"):format(ctx.repo.owner, ctx.repo.repo, M.title(ctx.pr))
  )
  vim.t.gauntlet_title = M.title(ctx.pr)

  local win = state.sidebar_win
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].spell = false
  vim.wo[win].signcolumn = "no"

  M.render_sidebar(state)
  M.apply_keymaps(state.sidebar_buf, state)
  vim.keymap.set("n", "<CR>", function()
    open_entry(state)
  end, { buffer = state.sidebar_buf, nowait = true, desc = "Gauntlet: open the file under the cursor" })

  reviews[state.tab] = state

  -- Start on the description, which is what a reviewer reads first.
  vim.api.nvim_win_set_cursor(state.sidebar_win, { 4, 0 })
  show_conversation(state)
  vim.api.nvim_set_current_win(state.sidebar_win)

  return state
end

--- The review on the current tab page, if there is one.
---@return table|nil
function M.current()
  return reviews[vim.api.nvim_get_current_tabpage()]
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
