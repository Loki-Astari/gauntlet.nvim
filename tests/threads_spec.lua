describe("gauntlet.threads", function()
  local threads = require("gauntlet.threads")
  local comments = require("gauntlet.comments")
  local gauntlet = require("gauntlet")

  local review

  --- `without` names fields to clear.  A table constructor cannot hold an
  --- explicit nil -- `{ line = nil }` is simply a table with no `line` -- so
  --- tbl_extend would keep the default and the test would prove nothing.
  ---@param over table|nil
  ---@param without string[]|nil
  local function thread(over, without)
    local built = vim.tbl_extend("force", {
      id = "PRRT_1",
      origin = "github",
      path = "lua/gauntlet/ui.lua",
      side = "RIGHT",
      line = 42,
      resolved = false,
      outdated = false,
      subject = "line",
      comments = { { author = "loki", body = "why not local?", state = "published" } },
    }, over or {})
    for _, field in ipairs(without or {}) do
      built[field] = nil
    end
    return built
  end

  before_each(function()
    review = { dir = vim.fn.tempname(), number = 1 }
  end)

  after_each(function()
    vim.fn.delete(review.dir, "rf")
  end)

  describe("the cache", function()
    it("is a file of its own, never the one holding your comments", function()
      -- A re-fetch replaces GitHub's threads wholesale; it must not be able to
      -- touch something you wrote.
      assert.is_not.equals(threads.path(review), comments.path(review))
      assert.is_truthy(threads.path(review):find("threads.json", 1, true))
    end)

    it("reads as empty before anything has been fetched", function()
      local store = threads.load(review)
      assert.same({}, store.threads)
      assert.is_nil(store.fetched_at)
    end)

    it("survives a file it cannot make sense of", function()
      vim.fn.mkdir(review.dir, "p")
      vim.fn.writefile({ "{{{" }, threads.path(review))
      assert.same({}, threads.load(review).threads)
    end)

    it("survives a round trip", function()
      assert.is_true((threads.save(review, {
        fetched_at = "2026-09-12T00:00:00Z",
        threads = { thread() },
      })))

      local store = threads.load(review)
      assert.equals("2026-09-12T00:00:00Z", store.fetched_at)
      assert.equals(1, #store.threads)
      assert.equals("loki", store.threads[1].comments[1].author)
    end)

    it("remembers that it fetched, even when there was nothing to fetch", function()
      -- Otherwise every reopening would ask GitHub again.
      threads.save(review, { fetched_at = "2026-09-12T00:00:00Z", threads = {} })
      assert.is_string(threads.load(review).fetched_at)
    end)
  end)

  describe("what gets drawn", function()
    local store

    before_each(function()
      store = {
        threads = {
          thread({ id = "open" }),
          thread({ id = "resolved", resolved = true }),
          thread({ id = "outdated", outdated = true }),
          thread({ id = "file-level", subject = "file" }, { "line" }),
          thread({ id = "unanchored" }, { "line" }),
        },
      }
    end)

    local function ids(list)
      return vim.tbl_map(function(t)
        return t.id
      end, list)
    end

    it("is only the open, current, anchored threads", function()
      assert.same({ "open" }, ids(threads.visible(store)))
    end)

    it("holds back everything resolved, outdated or unanchored", function()
      assert.same({ "resolved", "outdated", "file-level", "unanchored" }, ids(threads.hidden(store)))
    end)

    it("accounts for every thread, once", function()
      assert.equals(#store.threads, #threads.visible(store) + #threads.hidden(store))
    end)

    it("copes with a store that was never filled in", function()
      assert.same({}, threads.visible({}))
      assert.same({}, threads.hidden({}))
    end)
  end)

  describe("fetching", function()
    it("reports a missing gh rather than failing obscurely", function()
      local real = gauntlet.config.gh
      gauntlet.config.gh = "gh-does-not-exist"
      local got, err = threads.fetch({ owner = "o", repo = "r" }, 1)
      gauntlet.config.gh = real

      assert.is_nil(got)
      assert.is_truthy(err:find("not found on PATH", 1, true))
    end)

    it("leaves the cache alone when a fetch fails", function()
      threads.save(review, { fetched_at = "2026-09-12T00:00:00Z", threads = { thread() } })

      local real = gauntlet.config.gh
      gauntlet.config.gh = "gh-does-not-exist"
      local store, err = threads.refresh({ owner = "o", repo = "r" }, review)
      gauntlet.config.gh = real

      assert.is_nil(store)
      assert.is_string(err)
      -- A bad connection must not cost you the threads you already had.
      assert.equals(1, #threads.load(review).threads)
    end)
  end)
end)
