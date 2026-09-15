---@diagnostic disable: undefined-global
-- Sending a review to GitHub: the rules, and the request itself.
--
-- Deliberately free of UI, like gauntlet.resolve, so the whole chain can run
-- headless in a test.  The covering note is asked for by the interface and
-- handed in; everything that can go wrong comes back as a message for the
-- interface to show.
--
-- A review is sent as GitHub models one: a verdict, a covering note, and the
-- line comments together in a single request.  Comments already sent are not
-- sent again -- only the drafts go -- so pushing twice in a row sends nothing
-- the second time.
local M = {}

--- What GitHub will accept as a verdict, and what each one needs.
---
--- `note` is GitHub's own rule: a body is required for COMMENT and
--- REQUEST_CHANGES, and optional for APPROVE.  Asking for it here rather than
--- letting the request fail keeps the reason in Neovim, where the note still
--- is.
M.EVENTS = {
  COMMENT = {
    label = "Comment -- send the comments without a verdict",
    note = true,
    done = "commented on",
  },
  APPROVE = {
    label = "Approve",
    note = false,
    done = "approved",
  },
  REQUEST_CHANGES = {
    label = "Request changes",
    note = true,
    done = "requested changes on",
  },
}

-- The order the verdicts are offered in.  Commenting is first because it is
-- the one that needs no permission and undoes nothing.
M.ORDER = { "COMMENT", "APPROVE", "REQUEST_CHANGES" }

--- Drafts GitHub would refuse, because the line they sit on is no longer part
--- of the diff.
---
--- One bad comment fails the whole request, taking the good ones and the
--- verdict with it, so they are found here instead -- locally, and by name.
--- A comment goes stale when the pull request changes the code under it after
--- the comment was written.
---@param state table
---@param drafts table[]
---@return table[] stale
function M.stale(state, drafts)
  local changes = require("gauntlet.changes")

  local hunks, stale = {}, {}
  for _, thread in ipairs(drafts) do
    if not hunks[thread.path] then
      hunks[thread.path] =
        changes.hunks(state.root, state.review.base, state.review.head, thread.path)
    end
    if not changes.commentable(hunks[thread.path], thread.side, thread.line) then
      table.insert(stale, thread)
    end
  end
  return stale
end

--- Name the stale ones, so they can be found and rewritten.
---@param stale table[]
---@return string
function M.stale_message(stale)
  local where = {}
  for _, thread in ipairs(stale) do
    table.insert(where, ("%s:%d (%s)"):format(thread.path, thread.line, thread.side:lower()))
  end
  return ("%d comment%s no longer sit%s on a line of the diff, and GitHub would refuse the whole review: %s")
    :format(#stale, #stale == 1 and "" or "s", #stale == 1 and "s" or "", table.concat(where, ", "))
end

--- Everything that can be checked without the network.
--- Called before the covering note is asked for, so the common refusals
--- arrive before anything is written rather than after.
---@param state table
---@param event string
---@return boolean ok, string|nil err
function M.ready(state, event)
  local comments = require("gauntlet.comments")

  local spec = M.EVENTS[event]
  if not spec then
    return false, ("%s is not a verdict GitHub understands"):format(tostring(event))
  end

  local drafts = comments.drafts(state.comments)
  if event == "COMMENT" and #drafts == 0 then
    return false, "no new comments to send"
  end

  local stale = M.stale(state, drafts)
  if #stale > 0 then
    return false, M.stale_message(stale)
  end
  return true
end

--- Is the review still looking at what GitHub has?
---
--- A review answers from disk, so the branch can have moved since it was
--- opened.  Approving a pull request that is no longer the one on screen is
--- the failure worth preventing; refreshing here instead would swap the diff
--- out from under a verdict just given, so this stops and says so.
---@param state table
---@return boolean ok, string|nil err
function M.current(state)
  local github = require("gauntlet.github")

  local pr, err = github.get_open(state.repo, state.pr.number)
  if not pr then
    return false, err
  end
  if pr.headRefOid ~= state.review.head then
    return false, ("#%d has moved on to %s since this review was opened; :GauntletRefresh first")
      :format(state.pr.number, pr.headRefOid:sub(1, 7))
  end
  return true
end

--- Send the unsent comments, with a verdict, as one review.
---
--- Everything is checked first, because GitHub takes the request whole: a
--- single comment it will not accept loses the covering note and the verdict
--- with it.
---
--- On success the comments are marked as sent, which is what keeps the next
--- send from repeating them.  They are dropped for good only once GitHub's
--- own copy has been fetched back -- see gauntlet.settle.
---@param state table
---@param event string  a key of M.EVENTS
---@param body string|nil  the covering note
---@return table|nil sent { review, drafts, event }, string|nil err
function M.send(state, event, body)
  local github = require("gauntlet.github")
  local comments = require("gauntlet.comments")

  local spec = M.EVENTS[event]
  if not spec then
    return nil, ("%s is not a verdict GitHub understands"):format(tostring(event))
  end

  body = vim.trim(body or "")
  if spec.note and body == "" then
    return nil, ("GitHub needs a covering note to %s a pull request"):format(
      event == "COMMENT" and "comment on" or "request changes on")
  end

  local ok, err = M.ready(state, event)
  if not ok then
    return nil, err
  end

  ok, err = M.current(state)
  if not ok then
    return nil, err
  end

  local drafts = comments.drafts(state.comments)
  local review
  review, err = github.submit_review(state.repo, state.pr.number, {
    commit_id = state.review.head,
    body = body,
    event = event,
    comments = github.review_comments(drafts),
  })
  if not review then
    -- Nothing was written, so this can simply be tried again.
    return nil, err
  end

  for _, thread in ipairs(drafts) do
    for _, comment in ipairs(thread.comments or {}) do
      comment.state = "published"
    end
  end
  comments.save(state.review, state.comments)

  return { review = review, drafts = #drafts, event = event }
end

return M
