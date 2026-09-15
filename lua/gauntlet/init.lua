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
  -- Where review worktrees are kept.  Defaults to
  -- stdpath("state")/gauntlet, which persists: a review started online has
  -- to survive long enough to be finished offline.
  dir = nil,
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

--- Bring a pull request onto disk: fetch it, check it out, and work out what
--- it changes.
---
--- This is the step that needs the network, and the only one -- afterwards the
--- file list and both sides of every diff are read from local git.  It is kept
--- apart from the interface so `vig` can do it before Neovim starts, and fail
--- on the terminal rather than inside an editor that should not have opened.
---
--- Everything it returns survives vim.json, because that is how `vig` hands it
--- over.
---@param repo table
---@param pr table
---@return table|nil ctx { repo, pr, review, files, root }, string|nil err
function M.prepare(repo, pr)
  local worktree = require("gauntlet.worktree")
  local changes = require("gauntlet.changes")
  local git = require("gauntlet.git")

  local root, err = git.root()
  if not root then
    return nil, err
  end

  local review
  review, err = worktree.open(repo, pr)
  if not review then
    return nil, err
  end

  local files
  files, err = changes.list(root, review.base, review.head)
  if not files then
    return nil, err
  end

  -- GitHub's own review threads, fetched the first time and cached after, so
  -- that reconnecting to a review offline still shows the discussion.  A
  -- failure here is not fatal: a review without the threads is still a review,
  -- and :GauntletRefresh can try again.
  local threads = require("gauntlet.threads")
  local thread_store, thread_err = threads.load(review), nil
  if not thread_store.fetched_at then
    local fetched
    fetched, thread_err = threads.refresh(repo, review)
    thread_store = fetched or thread_store
  end

  return {
    repo = repo,
    pr = pr,
    review = review,
    files = files,
    root = root,
    threads = thread_store,
    threads_error = thread_err,
  }
end

--- Prepare a pull request and open the review interface for it.
---@param repo table
---@param pr table
---@return table|nil state, string|nil err
function M.start(repo, pr)
  local ctx, err = M.prepare(repo, pr)
  if not ctx then
    return nil, err
  end
  return require("gauntlet.ui").review(ctx)
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
    local _, serr = M.start(repo, pr)
    if serr then
      vim.notify("gauntlet: " .. serr, vim.log.levels.ERROR)
    end
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
    local _, serr = M.start(repo, full)
    if serr then
      vim.notify("gauntlet: " .. serr, vim.log.levels.ERROR)
    end
  end)
end

--- Fetch the comment threads, and hand GitHub anything it has taken over.
---
--- A comment that has been sent exists twice: as a draft of yours marked
--- published, and as a thread fetched back from GitHub.  The fetched copy
--- wins -- it is the one that can gain replies and be resolved -- so the
--- draft is dropped, but only once its double has actually arrived.  A fetch
--- that failed therefore costs nothing.
---@param state table
---@return table|nil store, string|nil err
function M.settle(state)
  local threads = require("gauntlet.threads")
  local comments = require("gauntlet.comments")

  local store, err = threads.refresh(state.repo, state.review)
  if not store then
    return nil, err
  end

  state.threads = store
  if comments.forget_published(state.comments or { threads = {} }, store) > 0 then
    comments.save(state.review, state.comments)
  end
  return store
end

--- Bring a review up to date with GitHub: commits pushed to the branch since
--- it was started, and the comment threads.
---
--- This is the other half of the offline bargain.  Everything else answers
--- from disk -- which is what lets a review be finished with no network, and
--- what leaves it on the commit it was opened at.  This is the one command
--- that goes and looks.
---
--- The commits come first because the threads are read against them, and
--- because a review showing a stale diff is the worse failure of the two: a
--- thread fetch that fails leaves the cached threads in place and says so,
--- and the new commits are on show either way.
---@param state table  a review, as returned by ui.review
---@return boolean ok
function M.refresh(state)
  local github = require("gauntlet.github")
  local worktree = require("gauntlet.worktree")
  local changes = require("gauntlet.changes")

  local was = state.review.head

  -- The pull request itself first: it carries the head the branch is on now,
  -- and the base branch tip the merge base is worked out from.
  local pr, err = github.get_open(state.repo, state.pr.number)
  if not pr then
    vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
    return false
  end

  local review
  review, err = worktree.update(state.repo, pr)
  if not review then
    vim.notify("gauntlet: could not update the review: " .. err, vim.log.levels.ERROR)
    return false
  end

  local files
  files, err = changes.list(state.root, review.base, review.head)
  if not files then
    vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
    return false
  end

  state.pr, state.review, state.files = pr, review, files

  local store, terr = M.settle(state)
  if not store then
    -- A failed fetch leaves the cache alone, so the threads already on show
    -- stay on show.  The new commits are worth having without them.
    vim.notify("gauntlet: could not fetch the comment threads: " .. terr, vim.log.levels.WARN)
  end

  require("gauntlet.ui").reload(state)

  local count = #((state.threads or {}).threads or {})
  vim.notify(
    ("gauntlet: #%d %s %s -- %d file%s, %d comment thread%s"):format(
      state.pr.number,
      was == review.head and "is still at" or "moved to",
      review.head:sub(1, 7),
      #files, #files == 1 and "" or "s",
      count, count == 1 and "" or "s"),
    vim.log.levels.INFO
  )
  return true
end

--- Send the comments written since the last send, and nothing else.
---
--- The everyday one, and the reason it asks for nothing: the comments say
--- what they have to say where they sit, and stopping to write a summary over
--- them is a toll on the common case.  :GauntletNote is there for when there
--- is something to say about the pull request as a whole.
---@param state table
---@return boolean ok
function M.push(state)
  local send = require("gauntlet.send")
  local ui = require("gauntlet.ui")

  local ok, err = send.ready(state, "COMMENT")
  if not ok then
    vim.notify("gauntlet: " .. err, vim.log.levels.WARN)
    return false
  end

  local sent
  sent, err = send.send(state, "COMMENT", "")
  if not sent then
    vim.notify("gauntlet: could not send: " .. err, vim.log.levels.ERROR)
    return false
  end

  ui.delivered(state, sent)
  return true
end

--- Write something about the pull request as a whole, and send it -- with
--- anything still unsent underneath it.
---@param state table
function M.note(state)
  require("gauntlet.ui").compose(state, "COMMENT")
end

--- Approve the pull request, sending anything still unsent along with it.
---@param state table
function M.approve(state)
  require("gauntlet.ui").compose(state, "APPROVE")
end

--- Ask for changes, sending anything still unsent along with it.
---@param state table
function M.reject(state)
  require("gauntlet.ui").compose(state, "REQUEST_CHANGES")
end

--- Remove a review from disk: its worktree, its ref, and its drafts.
---@param input string|nil  a pull request number; defaults to the current review
function M.discard(input)
  local worktree = require("gauntlet.worktree")
  local ui = require("gauntlet.ui")

  local repo, number
  local state = ui.current()
  input = vim.trim(input or "")

  if input == "" then
    if not state then
      vim.notify("gauntlet: no review here, and no pull request given", vim.log.levels.ERROR)
      return
    end
    repo, number = state.repo, state.pr.number
  else
    local err
    repo, _, err = M.resolve(nil)
    if err then
      vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
      return
    end
    local target
    target, err = require("gauntlet.parse").target(input)
    if not target then
      vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
      return
    end
    number = target.number
  end

  local ok, err = worktree.remove(repo, number)
  if not ok then
    vim.notify("gauntlet: " .. err, vim.log.levels.ERROR)
    return
  end
  if state and state.pr.number == number then
    ui.close(state)
  end
  vim.notify(("gauntlet: discarded the review of #%d"):format(number), vim.log.levels.INFO)
end

-- Guards the handover below against running twice.  $GAUNTLET_PRELOAD is
-- deliberately *not* cleared instead: it is how a config tells that this
-- Neovim exists only to show a review, and it has to stay true until the
-- process exits -- a session-saving VimLeavePre autocmd is the case that
-- matters, since a review is not a workspace worth saving over one.
local preloaded = false

--- Show the pull request `vig` left in $GAUNTLET_PRELOAD.
--- The file is ours, and is consumed exactly once.
--- Exposed for the tests; M.open_preload() is the entry point.
function M._open_preloaded()
  local path = vim.env.GAUNTLET_PRELOAD
  if preloaded or not path or path == "" then
    return
  end
  preloaded = true

  local ok, content = pcall(vim.fn.readfile, path)
  pcall(vim.fn.delete, path)
  if not ok then
    return
  end

  local ctx
  ok, ctx = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok or not ctx or not ctx.pr or not ctx.review then
    vim.notify("gauntlet: could not read the preloaded pull request", vim.log.levels.ERROR)
    return
  end

  -- `vig` already fetched the pull request and worked out what it changes, so
  -- there is nothing left to do but show it.
  require("gauntlet.ui").review(ctx)
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
