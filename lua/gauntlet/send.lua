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

--- What GitHub will accept as a verdict.
---
--- `demands_note` is GitHub's own rule about creating a review outright: a
--- body is required for COMMENT and REQUEST_CHANGES, and optional for
--- APPROVE.  It is not a rule about gauntlet -- nothing here makes anyone
--- write a note, because a review submitted in two steps needs none.
M.EVENTS = {
  COMMENT = {
    label = "Comment -- the line comments, with a note over them",
    demands_note = true,
    done = "commented on",
  },
  APPROVE = {
    label = "Approve",
    demands_note = false,
    done = "approved",
  },
  REQUEST_CHANGES = {
    label = "Request changes",
    demands_note = true,
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

--- Put a review up, in whichever way GitHub will take it.
---
--- GitHub demands a covering note when a COMMENT or REQUEST_CHANGES review is
--- created outright, and a push has none to give.  It does not demand one of
--- a review created *without* a verdict -- that is a draft, visible to nobody
--- else -- nor of the verdict that is then given to it.  So a send with no
--- note goes in two steps, which is what GitHub's own web interface does when
--- you start a review, add comments and finish it.
---
--- One step wherever one will do, because the two-step form can be
--- interrupted between them, leaving a draft review on GitHub holding the
--- comments.  That is recoverable -- the id is kept, and the next send
--- submits it rather than starting another -- but better not to risk for a
--- send that never needed it.
---@param state table
---@param event string  a key of M.EVENTS
---@param body string|nil  the covering note, which may be nothing at all
---@return table|nil sent { review, drafts, event }, string|nil err
function M.send(state, event, body)
  local github = require("gauntlet.github")
  local comments = require("gauntlet.comments")

  local spec = M.EVENTS[event]
  if not spec then
    return nil, ("%s is not a verdict GitHub understands"):format(tostring(event))
  end
  body = vim.trim(body or "")

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

  -- A draft review left behind by a send that failed halfway already holds
  -- these comments; give it its verdict rather than sending them twice.
  local pending = state.comments.pending

  if pending then
    review, err = github.submit_review(state.repo, state.pr.number, pending, {
      event = event,
      body = body,
    })
  elseif body == "" and spec.demands_note then
    review, err = github.create_review(state.repo, state.pr.number, {
      commit_id = state.review.head,
      comments = github.review_comments(drafts),
    })
    if review then
      -- Remember it before the verdict, so an interruption between the two
      -- leaves something to pick up rather than an orphan.
      state.comments.pending = review.id
      comments.save(state.review, state.comments)

      review, err = github.submit_review(state.repo, state.pr.number, review.id, {
        event = event,
        body = body,
      })
    end
  else
    review, err = github.create_review(state.repo, state.pr.number, {
      commit_id = state.review.head,
      body = body,
      event = event,
      comments = github.review_comments(drafts),
    })
  end

  if not review then
    if state.comments.pending then
      err = err .. ("; the comments are in a draft review on GitHub, and sending again will submit it")
    end
    return nil, err
  end

  state.comments.pending = nil
  for _, thread in ipairs(drafts) do
    for _, comment in ipairs(thread.comments or {}) do
      comment.state = "published"
    end
  end
  comments.save(state.review, state.comments)

  return { review = review, drafts = #drafts, event = event }
end

return M
