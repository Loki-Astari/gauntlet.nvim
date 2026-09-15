describe("gauntlet.send", function()
  local send = require("gauntlet.send")
  local comments = require("gauntlet.comments")
  local changes = require("gauntlet.changes")
  local github = require("gauntlet.github")
  local helpers = require("tests.helpers")

  local fixture, state, review_dir
  local posted, real

  --- A draft on a line that is part of the diff.
  local function draft(path, line, body, side)
    return comments.add(state.comments, {
      path = path, side = side or "RIGHT", line = line, commit_id = state.review.head,
    }, body)
  end

  before_each(function()
    fixture = helpers.repo()
    review_dir = vim.fn.tempname()

    state = {
      repo = { owner = "o", repo = "r" },
      pr = { number = 1 },
      review = {
        dir = review_dir,
        worktree = fixture.root,
        base = fixture.base,
        head = fixture.head,
        number = 1,
      },
      root = fixture.root,
      comments = { version = 1, threads = {} },
    }

    -- Stand in for GitHub.  The branch has not moved, and the API takes
    -- whatever it is given; the tests that care override these.
    posted = nil
    real = { submit_review = github.submit_review, get_open = github.get_open }
    github.get_open = function()
      return { number = 1, state = "OPEN", headRefOid = fixture.head }
    end
    github.submit_review = function(_, _, payload)
      posted = payload
      return { id = 99, state = "COMMENTED" }
    end
  end)

  after_each(function()
    github.submit_review, github.get_open = real.submit_review, real.get_open
    vim.fn.delete(review_dir, "rf")
    fixture.cleanup()
  end)

  describe("what it refuses before asking for a note", function()
    it("will not push when nothing new has been written", function()
      local ok, err = send.ready(state, "COMMENT")
      assert.is_false(ok)
      assert.equals("no new comments to send", err)
    end)

    it("lets a verdict through with nothing to send with it", function()
      -- Approving without a word is a perfectly ordinary review.
      assert.is_true((send.ready(state, "APPROVE")))
    end)

    it("names a comment whose line has left the diff", function()
      -- GitHub refuses the whole review over one such comment, taking the
      -- verdict and the other comments with it, so it is caught here.
      draft("big.txt", 1, "outside every hunk")
      local ok, err = send.ready(state, "COMMENT")

      assert.is_false(ok)
      assert.is_truthy(err:find("big.txt:1 (right)", 1, true))
      assert.is_false(changes.commentable(
        changes.hunks(state.root, state.review.base, state.review.head, "big.txt"), "RIGHT", 1))
    end)

    it("refuses a verdict it does not know", function()
      assert.is_false((send.ready(state, "LGTM")))
    end)
  end)

  describe("the covering note", function()
    it("is required to comment, because GitHub requires it", function()
      draft("change.txt", 2, "needs a test")
      local sent, err = send.send(state, "COMMENT", "   \n  ")

      assert.is_nil(sent)
      assert.is_truthy(err:find("covering note", 1, true))
      assert.is_nil(posted)
    end)

    it("is required to request changes", function()
      local sent = send.send(state, "REQUEST_CHANGES", "")
      assert.is_nil(sent)
      assert.is_nil(posted)
    end)

    it("is not required to approve", function()
      assert.is_truthy(send.send(state, "APPROVE", ""))
      assert.equals("APPROVE", posted.event)
    end)
  end)

  describe("sending", function()
    it("sends the verdict, the note and the comments as one request", function()
      draft("change.txt", 2, "needs a test")
      assert.is_truthy(send.send(state, "COMMENT", "a few notes"))

      assert.equals("COMMENT", posted.event)
      assert.equals("a few notes", posted.body)
      assert.equals(fixture.head, posted.commit_id)
      assert.equals(1, #posted.comments)
      assert.same(
        { path = "change.txt", line = 2, side = "RIGHT", body = "needs a test" },
        posted.comments[1]
      )
    end)

    it("carries anything still unsent along with a verdict", function()
      draft("change.txt", 2, "one more thing")
      local sent = assert(send.send(state, "APPROVE", ""))

      assert.equals(1, sent.drafts)
      assert.equals(1, #posted.comments)
    end)

    it("does not send the same comment twice", function()
      draft("change.txt", 2, "needs a test")
      assert.is_truthy(send.send(state, "COMMENT", "first"))

      -- Pushing again has nothing left to say.
      local ok, err = send.ready(state, "COMMENT")
      assert.is_false(ok)
      assert.equals("no new comments to send", err)

      -- And a verdict afterwards carries no comments at all.
      posted = nil
      assert.is_truthy(send.send(state, "APPROVE", ""))
      assert.same({}, posted.comments)
    end)

    it("writes the drafts to disk as sent", function()
      draft("change.txt", 2, "needs a test")
      assert.is_truthy(send.send(state, "COMMENT", "first"))

      local reloaded = comments.load(state.review)
      assert.equals(1, #reloaded.threads)
      assert.equals("published", reloaded.threads[1].comments[1].state)
      assert.same({}, comments.drafts(reloaded))
    end)

    it("leaves the drafts alone when GitHub refuses", function()
      draft("change.txt", 2, "needs a test")
      github.submit_review = function()
        return nil, "Can not approve your own pull request"
      end

      local sent, err = send.send(state, "APPROVE", "")
      assert.is_nil(sent)
      assert.equals("Can not approve your own pull request", err)
      -- Untouched, so it can simply be tried again.
      assert.equals(1, #comments.drafts(state.comments))
    end)
  end)

  describe("a branch that has moved", function()
    it("is refused rather than reviewed as it was", function()
      -- Approving a pull request that is no longer the one on screen is the
      -- failure worth preventing.
      github.get_open = function()
        return { number = 1, state = "OPEN", headRefOid = string.rep("a", 40) }
      end

      local sent, err = send.send(state, "APPROVE", "")
      assert.is_nil(sent)
      assert.is_truthy(err:find("moved on", 1, true))
      assert.is_truthy(err:find("GauntletRefresh", 1, true))
      assert.is_nil(posted)
    end)

    it("reports what GitHub said when the pull request cannot be read", function()
      github.get_open = function()
        return nil, "o/r has no pull request #1"
      end

      local sent, err = send.send(state, "APPROVE", "")
      assert.is_nil(sent)
      assert.equals("o/r has no pull request #1", err)
    end)
  end)
end)
