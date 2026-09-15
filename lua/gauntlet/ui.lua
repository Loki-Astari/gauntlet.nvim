---@diagnostic disable: undefined-global
-- The review interface: one tab page, a file list on the left, and on the
-- right either the pull request's description or a two-pane diff.
--
-- Everything shown is read-only.  That costs nothing a reviewer wants: LSP,
-- `gd` and `K` all work on a non-modifiable buffer.
local render = require("gauntlet.render")
local changes = require("gauntlet.changes")
local comments = require("gauntlet.comments")
local threads = require("gauntlet.threads")

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
---@param keep boolean|nil  survive its window closing
---@return integer buf
local function scratch(lines, name, filetype, keep)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  -- A diff pane's buffer has to outlive its window: opening the comment
  -- composer rebuilds the content area, and "wipe" would destroy the very
  -- buffer being put back.
  vim.bo[buf].bufhidden = keep and "hide" or "wipe"
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

-- Defined below, but needed above them.
local annotate, add_comment, delete_comment, discard_panes

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

--- Build the content area: two panes side by side, and optionally a slot
--- beneath them.
---
--- The horizontal split comes *first* on purpose.  Windows split from a row
--- become siblings in that row, so splitting a pane afterwards would give a
--- slot the width of that one pane.  Splitting first nests the two panes
--- inside a column, which makes the slot their sibling and so as wide as both
--- together.
---@param state table
---@param with_slot boolean
---@return integer left, integer right, integer|nil slot
local function layout(state, with_slot)
  local left = content_reset(state)

  local slot
  if with_slot then
    vim.api.nvim_set_current_win(left)
    vim.cmd("belowright split")
    slot = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_set_current_win(left)
  vim.cmd("rightbelow vsplit")
  local right = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_width(state.sidebar_win, SIDEBAR_WIDTH)
  return left, right, slot
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
  discard_panes(state)
  state.diff = nil
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
--- Is this buffer on show somewhere other than the review's own tab page?
--- The right-hand pane is a real file, and the reviewer may have split it off
--- or followed `gd` into it elsewhere.  A window they opened is theirs.
---@param state table
---@param buf integer
---@return boolean
local function shown_outside(state, buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_win_get_tabpage(win) ~= state.tab
    then
      return true
    end
  end
  return false
end

--- Throw away the buffers a diff was using.
---
--- They deliberately outlive their windows -- opening the comment composer
--- closes and reopens the panes around them -- so something has to end them
--- when the review moves on.  Both sides go, the right-hand one included:
--- it is a real file in the worktree, and left behind it would pile up, one
--- stale buffer per file the reviewer had looked at.
---@param state table
function discard_panes(state)
  if not state.diff then
    return
  end
  for _, pane in ipairs({ state.diff.left, state.diff.right }) do
    if vim.api.nvim_buf_is_valid(pane.buf) and not shown_outside(state, pane.buf) then
      pcall(vim.api.nvim_buf_delete, pane.buf, { force = true })
    end
  end
end

local function show_diff(state, file)
  discard_panes(state)
  local base_lines, existed = changes.base_lines(state.root, state.review.base, file.path)
  local filetype = vim.filetype.match({ filename = file.path }) or ""

  local left, right = layout(state, false)
  local base_buf = scratch(
    existed and base_lines or {},
    ("gauntlet://pr-%d/base/%s"):format(state.pr.number, file.path),
    filetype,
    true
  )
  vim.api.nvim_win_set_buf(left, base_buf)
  content_window(left)

  local worktree_file = vim.fs.joinpath(state.review.worktree, file.path)

  local head_buf
  if vim.fn.filereadable(worktree_file) == 1 then
    -- bufadd() and bufload() rather than :edit.  They do the part that is
    -- wanted -- read the real file, and run filetype detection, which is what
    -- a language server attaches to -- without the part that is not: :edit
    -- adds the buffer to the buffer list, where a pane of the review reads as
    -- a second copy of the file the reviewer just opened, in :ls, in <C-^>,
    -- and in every bufferline plugin.  Detection is worth keeping over
    -- setting 'filetype' by hand: it reads a shebang, which a filename alone
    -- cannot.
    head_buf = vim.fn.bufadd(worktree_file)
    -- Both before the load: no swap file is then ever written for a buffer
    -- that cannot be edited, and the buffer is never listed even briefly.
    vim.bo[head_buf].swapfile = false
    vim.bo[head_buf].buflisted = false
    vim.fn.bufload(head_buf)
    vim.bo[head_buf].modifiable = false
    vim.bo[head_buf].readonly = true
  else
    -- A deleted file has no right-hand side.
    head_buf = scratch({}, ("gauntlet://pr-%d/deleted/%s"):format(state.pr.number, file.path), filetype, true)
  end
  vim.api.nvim_win_set_buf(right, head_buf)
  content_window(right)

  for _, win in ipairs({ left, right }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end

  state.diff = {
    file = file,
    -- Which lines GitHub would accept a comment on.  Worked out once per
    -- file, from local git, so it is there offline too.
    hunks = changes.hunks(state.root, state.review.base, state.review.head, file.path),
    left = { win = left, buf = base_buf, side = "LEFT" },
    right = { win = right, buf = head_buf, side = "RIGHT" },
  }

  M.apply_keymaps(base_buf, state)
  M.apply_keymaps(head_buf, state)
  for _, buf in ipairs({ base_buf, head_buf }) do
    vim.keymap.set("n", "c", function()
      add_comment(state)
    end, { buffer = buf, nowait = true, desc = "Gauntlet: comment on this line" })
    vim.keymap.set("n", "dc", function()
      delete_comment(state)
    end, { buffer = buf, nowait = true, desc = "Gauntlet: delete the comment on this line" })
  end

  annotate(state)
  vim.api.nvim_set_current_win(right)
end

local COMMENT_NS = vim.api.nvim_create_namespace("GauntletComments")

--- Colours for comments, set up so a colourscheme can override them: all are
--- `default`, so anything the user defines wins.
---
--- They link to the floating-window groups because that is the effect wanted
--- -- a note laid over the code rather than part of it -- and because every
--- colourscheme gives those a background that stands apart from Normal.
function M.highlights()
  local links = {
    GauntletComment = "NormalFloat",
    GauntletCommentBorder = "FloatBorder",
    GauntletCommentSign = "DiagnosticSignInfo",
    GauntletCommentAuthor = "Title",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

--- Lay a comment thread out as a bordered note.
---
--- Comments were getting lost in the code they were about: dim virtual text
--- among lines of source reads as more source.  A box has an outline whatever
--- the colourscheme does, and the background makes it plainly not code.
---@param thread table
---@param width integer  the widest the note may be
---@return table[] virt_lines
--- What to write in the box's top border.
---@param thread table
---@return string
local function box_label(thread)
  if thread.origin ~= "github" then
    return " comment "
  end
  local marks = {}
  if thread.resolved then
    table.insert(marks, "✓ resolved")
  end
  if thread.outdated then
    table.insert(marks, "outdated")
  end
  if #marks > 0 then
    return (" thread · %s "):format(table.concat(marks, ", "))
  end
  return " thread "
end

local function comment_box(thread, width)
  local label = box_label(thread)
  local inner = math.max(width - 6, #label + 10)

  --- Break a line at spaces so it fits the box.  A comment is there to be
  --- read, so it wraps; truncating would hide the point of it.
  ---@param text string
  ---@return string[]
  local function wrap(text)
    if vim.fn.strdisplaywidth(text) <= inner then
      return { text }
    end
    local out, line = {}, ""
    for word in text:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if vim.fn.strdisplaywidth(candidate) <= inner then
        line = candidate
      else
        if line ~= "" then
          table.insert(out, line)
        end
        -- A single word longer than the box has to be cut somewhere.
        while vim.fn.strdisplaywidth(word) > inner do
          table.insert(out, vim.fn.strcharpart(word, 0, inner))
          word = vim.fn.strcharpart(word, inner)
        end
        line = word
      end
    end
    if line ~= "" then
      table.insert(out, line)
    end
    return out
  end

  local body = {}
  for _, comment in ipairs(thread.comments or {}) do
    local author = comment.author or "you"
    local mark = comment.state == "draft" and " (draft)" or ""
    table.insert(body, { text = author .. mark, author = true })
    for _, line in ipairs(vim.split(comment.body or "", "\n", { plain = true })) do
      if line == "" then
        table.insert(body, { text = "" })
      else
        for _, piece in ipairs(wrap(line)) do
          table.insert(body, { text = piece })
        end
      end
    end
  end

  -- Shrink the box to the longest line it actually holds.
  local widest = #label
  for _, line in ipairs(body) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line.text))
  end
  inner = math.min(inner, widest)

  local indent = "  "
  local lines = {}

  table.insert(lines, {
    { indent, "GauntletCommentBorder" },
    { "╭─" .. label .. string.rep("─", inner - #label) .. "─╮", "GauntletCommentBorder" },
  })

  for _, line in ipairs(body) do
    local text = line.text
    local pad = string.rep(" ", math.max(inner - vim.fn.strdisplaywidth(text), 0))
    table.insert(lines, {
      { indent, "GauntletCommentBorder" },
      { "│ ", "GauntletCommentBorder" },
      { text .. pad, line.author and "GauntletCommentAuthor" or "GauntletComment" },
      { " │", "GauntletCommentBorder" },
    })
  end

  table.insert(lines, {
    { indent, "GauntletCommentBorder" },
    { "╰" .. string.rep("─", inner + 2) .. "╯", "GauntletCommentBorder" },
  })

  return lines
end

--- Draw the comment threads onto whichever file is on show.
--- A marker in the sign column says a line carries one; the text itself goes
--- underneath the line it is about, so the code stays where it was.
---@param state table
function annotate(state)
  if not state.diff then
    return
  end

  local path = state.diff.file.path
  local drawn = comments.for_file(state.comments, path)

  for _, thread in ipairs(threads.visible(state.threads or {})) do
    if thread.path == path then
      table.insert(drawn, thread)
    end
  end
  if state.show_settled then
    -- Resolved and outdated threads, revealed by `T`.  One without a line
    -- cannot be drawn against the code at all.
    for _, thread in ipairs(threads.hidden(state.threads or {})) do
      if thread.path == path and thread.line then
        table.insert(drawn, thread)
      end
    end
  end

  for _, pane in ipairs({ state.diff.left, state.diff.right }) do
    if vim.api.nvim_buf_is_valid(pane.buf) then
      vim.api.nvim_buf_clear_namespace(pane.buf, COMMENT_NS, 0, -1)
      local last = vim.api.nvim_buf_line_count(pane.buf)

      local width = vim.api.nvim_win_is_valid(pane.win)
          and vim.api.nvim_win_get_width(pane.win)
        or 60

      for _, thread in ipairs(drawn) do
        if thread.side == pane.side and thread.line >= 1 and thread.line <= last then
          vim.api.nvim_buf_set_extmark(pane.buf, COMMENT_NS, thread.line - 1, 0, {
            sign_text = "●",
            sign_hl_group = "GauntletCommentSign",
            line_hl_group = "GauntletCommentSign",
            virt_lines = comment_box(thread, width),
          })
        end
      end
    end
  end
end

--- Which side of the diff a window is showing, and where its cursor is.
---@param state table
---@return table|nil anchor { path, side, line, commit_id }
local function anchor_here(state)
  if not state.diff then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  for _, pane in ipairs({ state.diff.left, state.diff.right }) do
    if pane.win == win then
      return {
        path = state.diff.file.path,
        side = pane.side,
        line = vim.api.nvim_win_get_cursor(win)[1],
        commit_id = state.review.head,
      }
    end
  end
  return nil
end

--- Open a buffer to write a comment in, under the diff.
--- An ordinary buffer, so every editing habit works: `:w` keeps it, `:q`
--- throws it away.
---@param state table
---@param anchor table
local function compose(state, anchor)
  -- Rebuild the content area with a slot underneath both panes.  The slot has
  -- to be created before the panes are split apart, or it would only be as
  -- wide as one of them -- see layout().
  local keep = {
    left = state.diff.left.buf,
    right = state.diff.right.buf,
    cursor = {},
  }
  for _, side in ipairs({ "left", "right" }) do
    local pane = state.diff[side]
    if vim.api.nvim_win_is_valid(pane.win) then
      keep.cursor[side] = vim.api.nvim_win_get_cursor(pane.win)
    end
  end

  local left, right, win = layout(state, true)
  for side, pane_win in pairs({ left = left, right = right }) do
    vim.api.nvim_win_set_buf(pane_win, keep[side])
    content_window(pane_win)
    state.diff[side].win = pane_win
    if keep.cursor[side] then
      pcall(vim.api.nvim_win_set_cursor, pane_win, keep.cursor[side])
    end
    vim.api.nvim_win_call(pane_win, function()
      vim.cmd("diffthis")
    end)
  end
  annotate(state)

  vim.api.nvim_win_set_height(win, 8)
  vim.api.nvim_set_current_win(win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  -- "acwrite" so that :w reaches BufWriteCmd instead of trying to write a file.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].winfixheight = true
  claim_name(buf, ("gauntlet://pr-%d/comment/%s:%s:%d"):format(
    state.pr.number, anchor.path, anchor.side:lower(), anchor.line))

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    desc = "Gauntlet: keep this comment",
    callback = function()
      local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      if body == "" then
        vim.notify("gauntlet: nothing written, so nothing kept", vim.log.levels.WARN)
        return
      end

      comments.add(state.comments, anchor, body)
      local ok, err = comments.save(state.review, state.comments)
      if not ok then
        vim.notify("gauntlet: could not keep the comment: " .. err, vim.log.levels.ERROR)
        return
      end

      vim.bo[buf].modified = false
      pcall(vim.api.nvim_win_close, win, true)
      annotate(state)
      M.render_sidebar(state)
    end,
  })

  vim.cmd("startinsert")
end

--- Start a comment on the line under the cursor.
---@param state table
function add_comment(state)
  local anchor = anchor_here(state)
  if not anchor then
    vim.notify("gauntlet: comments go on a line of a file, not here", vim.log.levels.WARN)
    return
  end

  -- GitHub will not take a comment on a line that is not part of the diff, so
  -- say so now rather than at submission, when it would be a puzzle.
  if not changes.commentable(state.diff.hunks, anchor.side, anchor.line) then
    vim.notify(
      ("gauntlet: line %d is not part of the diff, so GitHub would not take a comment there"):format(anchor.line),
      vim.log.levels.WARN
    )
    return
  end

  compose(state, anchor)
end

--- Drop the comment on the line under the cursor.
---@param state table
function delete_comment(state)
  local anchor = anchor_here(state)
  if not anchor then
    return
  end

  local found = comments.at(state.comments, anchor.path, anchor.side, anchor.line)
  if #found == 0 then
    vim.notify("gauntlet: no comment on this line", vim.log.levels.INFO)
    return
  end

  for _, thread in ipairs(found) do
    comments.remove(state.comments, thread)
  end
  comments.save(state.review, state.comments)
  annotate(state)
  M.render_sidebar(state)
  vim.notify(("gauntlet: removed %d comment%s"):format(#found, #found == 1 and "" or "s"), vim.log.levels.INFO)
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

  local open_count = comments.counts(state.comments or { threads = {} })
  local settled = {}
  for _, thread in ipairs(threads.visible(state.threads or {})) do
    open_count[thread.path] = (open_count[thread.path] or 0) + 1
  end
  for _, thread in ipairs(threads.hidden(state.threads or {})) do
    settled[thread.path] = (settled[thread.path] or 0) + 1
  end

  for _, file in ipairs(state.files) do
    local counts = ("+%d −%d"):format(file.additions, file.deletions)
    local mark = open_count[file.path] and ("●%d "):format(open_count[file.path]) or ""
    if settled[file.path] then
      mark = mark .. ("✓%d "):format(settled[file.path])
    end
    local room = SIDEBAR_WIDTH - 6 - #counts - vim.fn.strdisplaywidth(mark)
    local path = file.path
    if vim.fn.strdisplaywidth(path) > room then
      -- Keep the end of a long path: the filename matters more than the tree.
      path = "…" .. path:sub(-room + 1)
    end
    add(
      ("  %s %-" .. room .. "s %s%s"):format(file.status, path, mark, counts),
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
  map("T", function()
    M.toggle_settled(state)
  end, "show or hide resolved and outdated threads")
end

--- Draw the sidebar and whatever is on the right again.
---@param state table
function M.redraw(state)
  annotate(state)
  M.render_sidebar(state)
end

--- Draw a review whose content has moved underneath it: a new head commit,
--- and so a new file list and new diffs.
---
--- redraw() is not enough for that.  It repaints what is already on screen,
--- and after :GauntletRefresh what is on screen was read from the commit the
--- review used to be on.
---
--- The file being looked at is followed by path rather than by sidebar line,
--- because a new commit can add or drop files above it.  One the new head no
--- longer touches has nothing left to show, so that falls back to the
--- conversation.
---@param state table
function M.reload(state)
  -- The right-hand pane of a diff is the real file in the worktree, and the
  -- worktree has just been moved onto another commit.  Neovim is still
  -- holding the old contents, so drop those buffers rather than trusting
  -- :edit to notice the file changed under it.
  local inside = vim.fs.normalize(state.review.worktree) .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.startswith(vim.fs.normalize(name), inside) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local showing = state.diff and state.diff.file.path
  M.render_sidebar(state)

  local target_line, target
  for line, entry in pairs(state.lines) do
    if showing and entry.kind == "file" and entry.file.path == showing then
      target_line, target = line, entry
      break
    end
  end
  if not target then
    for line, entry in pairs(state.lines) do
      if entry.kind == "conversation" then
        target_line, target = line, entry
        break
      end
    end
  end

  state.current = target_line
  if target and target.kind == "file" then
    show_diff(state, target.file)
  else
    show_conversation(state)
  end

  if target_line then
    pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { target_line, 0 })
  end
  vim.api.nvim_set_current_win(state.sidebar_win)
  M.render_sidebar(state)
end

--- Show or hide the threads that are resolved or outdated.
---@param state table
function M.toggle_settled(state)
  state.show_settled = not state.show_settled
  M.redraw(state)

  local settled = #threads.hidden(state.threads or {})
  vim.notify(
    state.show_settled
        and ("gauntlet: showing %d resolved or outdated thread%s"):format(
          settled, settled == 1 and "" or "s")
      or "gauntlet: hiding resolved and outdated threads",
    vim.log.levels.INFO
  )
end

--- Close a review's tab page.  The worktree is left on disk so the review can
--- be picked up again, offline; :GauntletDiscard is what removes it.
---@param state table
function M.close(state)
  discard_panes(state)
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
    -- Whatever was written the last time this review was open.
    comments = comments.load(ctx.review),
    -- GitHub's threads, fetched by prepare() and cached on disk.
    threads = ctx.threads or threads.load(ctx.review),
    -- Resolved and outdated threads start hidden, as they do on GitHub.
    show_settled = false,
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

  M.highlights()
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

--- Choose a verdict, then write the note and send.
--- The three verdicts also have commands of their own; this is the way in
--- when you have not decided which yet.
---@param state table
function M.submit(state)
  local send = require("gauntlet.send")
  local drafts = comments.drafts(state.comments)

  local verdicts = {}
  for _, event in ipairs(send.ORDER) do
    table.insert(verdicts, { event = event, label = send.EVENTS[event].label })
  end

  vim.ui.select(verdicts, {
    prompt = ("Send %d new comment%s on #%d as:"):format(
      #drafts, #drafts == 1 and "" or "s", state.pr.number),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.compose(state, choice.event)
    end
  end)
end

--- Write the covering note, then send.  `:w` sends; `:q` calls it off.
---
--- Everything that can be judged without the network is judged before the
--- buffer opens, so a refusal never arrives after a note has been written.
--- What is left -- has the branch moved, will GitHub take it -- is answered
--- on `:w`, and leaves the note where it is so it can be tried again.
---@param state table
---@param event string  a key of gauntlet.send.EVENTS
function M.compose(state, event)
  local send = require("gauntlet.send")
  local gauntlet = require("gauntlet")

  local spec = send.EVENTS[event]
  if not spec then
    vim.notify(("gauntlet: %s is not a verdict"):format(tostring(event)), vim.log.levels.ERROR)
    return
  end

  local ok, err = send.ready(state, event)
  if not ok then
    vim.notify("gauntlet: " .. err, vim.log.levels.WARN)
    return
  end

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, 10)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  claim_name(buf, ("gauntlet://pr-%d/review"):format(state.pr.number))

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    desc = "Gauntlet: send this review",
    callback = function()
      local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

      local sent, serr = send.send(state, event, body)
      if not sent then
        -- Nothing left this machine, and the note is still here: fix what the
        -- message says and write again.
        vim.notify("gauntlet: could not send: " .. serr, vim.log.levels.ERROR)
        return
      end

      vim.bo[buf].modified = false
      pcall(vim.api.nvim_win_close, win, true)

      -- GitHub owns those comments now.  Fetching the threads back is what
      -- lets the drafts go, and what puts your own words on the line as the
      -- thread they have become.
      local _, ferr = gauntlet.settle(state)
      if ferr then
        vim.notify(
          "gauntlet: sent, but could not fetch the threads back: " .. ferr,
          vim.log.levels.WARN
        )
      end
      M.redraw(state)

      vim.notify(
        ("gauntlet: %s #%d%s"):format(
          spec.done,
          state.pr.number,
          sent.drafts > 0
              and (", with %d comment%s"):format(sent.drafts, sent.drafts == 1 and "" or "s")
            or ""),
        vim.log.levels.INFO
      )
    end,
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")
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
