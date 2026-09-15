describe("gauntlet.comments", function()
  local comments = require("gauntlet.comments")

  local review, store

  local anchor = {
    path = "lua/gauntlet/ui.lua",
    side = "RIGHT",
    line = 42,
    commit_id = "ab684b05",
  }

  before_each(function()
    review = { dir = vim.fn.tempname() }
    store = comments.load(review)
  end)

  after_each(function()
    vim.fn.delete(review.dir, "rf")
  end)

  describe("load", function()
    it("treats a review with no comments as empty, not broken", function()
      assert.same({}, store.threads)
      assert.equals(1, store.version)
    end)

    it("survives a file it cannot make sense of", function()
      vim.fn.mkdir(review.dir, "p")
      vim.fn.writefile({ "not json" }, comments.path(review))
      assert.same({}, comments.load(review).threads)
    end)
  end)

  describe("add", function()
    it("stores a comment as a thread, so replies can join it later", function()
      local thread = comments.add(store, anchor, "needs a test")

      assert.equals("lua/gauntlet/ui.lua", thread.path)
      assert.equals("RIGHT", thread.side)
      assert.equals(42, thread.line)
      assert.equals("ab684b05", thread.commit_id)
      assert.equals(1, #thread.comments)
      assert.equals("needs a test", thread.comments[1].body)
      assert.equals("draft", thread.comments[1].state)
    end)

    it("keeps the anchor GitHub needs at submission", function()
      local thread = comments.add(store, anchor, "x")
      assert.is_string(thread.commit_id)
      assert.is_truthy(thread.side == "LEFT" or thread.side == "RIGHT")
    end)
  end)

  describe("finding threads", function()
    before_each(function()
      comments.add(store, anchor, "first")
      comments.add(store, anchor, "second on the same line")
      comments.add(store, vim.tbl_extend("force", anchor, { line = 7 }), "elsewhere")
      comments.add(store, vim.tbl_extend("force", anchor, { side = "LEFT" }), "other side")
      comments.add(store, vim.tbl_extend("force", anchor, { path = "README.md" }), "other file")
    end)

    it("finds every thread on a line", function()
      assert.equals(2, #comments.at(store, anchor.path, "RIGHT", 42))
    end)

    it("does not mix the two sides of a diff", function()
      assert.equals(1, #comments.at(store, anchor.path, "LEFT", 42))
    end)

    it("finds every thread on a file", function()
      assert.equals(4, #comments.for_file(store, anchor.path))
    end)

    it("counts threads per file, for the sidebar", function()
      local counts = comments.counts(store)
      assert.equals(4, counts[anchor.path])
      assert.equals(1, counts["README.md"])
    end)
  end)

  describe("remove", function()
    it("drops the thread it is given and leaves the rest", function()
      comments.add(store, anchor, "keep me")
      local doomed = comments.add(store, anchor, "delete me")

      assert.is_true(comments.remove(store, doomed))
      assert.equals(1, #store.threads)
      assert.equals("keep me", store.threads[1].comments[1].body)
    end)

    it("says so when the thread is not there", function()
      assert.is_false(comments.remove(store, { path = "nope" }))
    end)
  end)

  describe("drafts", function()
    it("are what a submission is made of", function()
      comments.add(store, anchor, "unsent")
      local sent = comments.add(store, anchor, "already sent")
      sent.comments[1].state = "published"

      local drafts = comments.drafts(store)
      assert.equals(1, #drafts)
      assert.equals("unsent", drafts[1].comments[1].body)
    end)
  end)

  describe("handing a sent comment over to GitHub", function()
    -- Once a comment has been sent it exists twice: here, marked published,
    -- and as a thread fetched back from GitHub.  Drawn from both it would
    -- appear twice on the line, so the fetched copy wins -- but only once it
    -- has actually arrived.

    local function sent(body, line)
      local thread = comments.add(store, vim.tbl_extend("force", anchor, { line = line or 42 }), body)
      thread.comments[1].state = "published"
      return thread
    end

    --- The shape gauntlet.threads hands back.
    local function fetched(body, line)
      return {
        threads = {
          {
            path = anchor.path,
            side = anchor.side,
            line = line or 42,
            comments = { { author = "loki", body = body, state = "published" } },
          },
        },
      }
    end

    it("drops a sent comment once GitHub hands it back", function()
      sent("needs a test")
      assert.equals(1, comments.forget_published(store, fetched("needs a test")))
      assert.same({}, store.threads)
    end)

    it("keeps one GitHub has not handed back yet", function()
      -- Otherwise a fetch that has not caught up loses the record of what was
      -- said until the next one does.
      sent("needs a test")
      assert.equals(0, comments.forget_published(store, fetched("something else")))
      assert.equals(1, #store.threads)
    end)

    it("keeps one that was never sent, whatever GitHub carries", function()
      comments.add(store, anchor, "needs a test")
      assert.equals(0, comments.forget_published(store, fetched("needs a test")))
      assert.equals(1, #store.threads)
      assert.equals(1, #comments.drafts(store))
    end)

    it("still recognises it when the line has moved", function()
      -- A thread GitHub calls outdated reports the line it was pinned to, not
      -- the one it was written against, so the line cannot be part of the
      -- match.
      sent("needs a test", 42)
      assert.equals(1, comments.forget_published(store, fetched("needs a test", 17)))
      assert.same({}, store.threads)
    end)

    it("copes with nothing fetched at all", function()
      sent("needs a test")
      assert.equals(0, comments.forget_published(store, nil))
      assert.equals(0, comments.forget_published(store, {}))
      assert.equals(1, #store.threads)
    end)

    it("leaves the rest of the file alone", function()
      sent("gone")
      comments.add(store, anchor, "still mine")
      comments.forget_published(store, fetched("gone"))

      assert.equals(1, #store.threads)
      assert.equals("still mine", store.threads[1].comments[1].body)
    end)
  end)

  describe("persistence", function()
    it("survives a round trip to disk", function()
      comments.add(store, anchor, "needs a test")
      assert.is_true((comments.save(review, store)))

      local reloaded = comments.load(review)
      assert.equals(1, #reloaded.threads)
      assert.equals("needs a test", reloaded.threads[1].comments[1].body)
      assert.equals(42, reloaded.threads[1].line)
      assert.equals("RIGHT", reloaded.threads[1].side)
    end)

    it("keeps drafts out of the worktree", function()
      -- Anything written inside the worktree would show up in git status and
      -- could be committed by accident.
      assert.is_nil(comments.path({ dir = "/r/pr-1" }):find("worktree", 1, true))
      assert.equals("/r/pr-1/comments.json", comments.path({ dir = "/r/pr-1" }))
    end)
  end)
end)
