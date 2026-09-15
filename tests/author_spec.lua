describe("gauntlet.author", function()
  local author = require("gauntlet.author")
  local worktree = require("gauntlet.worktree")
  local changes = require("gauntlet.changes")
  local github = require("gauntlet.github")
  local gauntlet = require("gauntlet")
  local helpers = require("tests.helpers")

  local fixture, store, cwd, review, real_me
  local repo = { name = "origin", owner = "o", repo = "r" }
  local pr

  --- Write a file in the review worktree, the way the author would.
  local function write(path, text)
    vim.fn.writefile(vim.split(text, "\n", { plain = true }),
      vim.fs.joinpath(review.worktree, path))
  end

  --- What GitHub does of its own accord when a pull request branch is pushed:
  --- refs/pull/<n>/head follows it.  A bare test remote does not, so the
  --- fixture has to.
  local function github_follows_the_branch()
    vim.fn.systemlist({
      "git", "-C", fixture.remote, "update-ref", "refs/pull/1/head", "refs/heads/pr",
    })
  end

  local function remote_sha(ref)
    local out = vim.fn.systemlist({ "git", "-C", fixture.remote, "rev-parse", ref })
    return vim.v.shell_error == 0 and out[1] or nil
  end

  before_each(function()
    fixture = helpers.repo_with_pr(1)
    pr = {
      number = 1,
      baseRefOid = fixture.base,
      headRefOid = fixture.head,
      headRefName = "pr",
      isCrossRepository = false,
      author = { login = "loki" },
    }

    store = vim.fn.tempname()
    gauntlet.config.dir = store
    cwd = vim.fn.getcwd()
    vim.cmd.cd(fixture.root)

    -- Who gh says we are, without asking gh.
    real_me = github.me
    github.me = function()
      return "loki"
    end

    review = assert(worktree.open(repo, pr))
  end)

  after_each(function()
    github.me = real_me
    pcall(worktree.remove, repo, 1)
    vim.cmd.cd(cwd)
    gauntlet.config.dir = nil
    vim.fn.delete(store, "rf")
    fixture.cleanup()
  end)

  describe("whose review it is", function()
    it("is yours when you wrote the pull request", function()
      assert.is_true(review.mine)
      assert.is_true(author.editable(review))
    end)

    it("is not yours when somebody else did", function()
      pcall(worktree.remove, repo, 1)
      pr.author = { login = "someone-else" }
      local theirs = assert(worktree.open(repo, pr))

      assert.is_false(theirs.mine)
      assert.is_false(author.editable(theirs))
    end)

    it("is nobody's when it cannot be told", function()
      -- A review reconnected to before this was ever recorded stays shut,
      -- which is the safe way to be wrong.
      assert.is_false(author.editable({ worktree = review.worktree }))
    end)

    it("is remembered, so reconnecting offline still knows", function()
      local again = assert(worktree.open(repo, pr))
      assert.is_true(again.mine)
      assert.equals("loki", again.author)
      assert.equals("pr", again.branch)
    end)
  end)

  describe("what the worktree is holding", function()
    it("sees a file the author has changed", function()
      write("change.txt", "alpha\nBETA\ngamma\ndelta")
      assert.same({ { status = "M", path = "change.txt" } }, author.dirty(review))
    end)

    it("sees a file the author has just created", function()
      write("brand-new.txt", "fresh work")
      assert.same({ { status = "??", path = "brand-new.txt" } }, author.dirty(review))
    end)

    it("counts an uncommitted edit in the file list", function()
      write("change.txt", "alpha\nBETA\ngamma\ndelta")
      local files = assert(changes.for_review(fixture.root, review))

      for _, file in ipairs(files) do
        if file.path == "change.txt" then
          -- Against the base "alpha/beta": BETA, gamma and delta added, beta gone.
          assert.equals(3, file.additions)
          assert.equals(1, file.deletions)
          return
        end
      end
      error("change.txt was not in the list")
    end)

    it("lists a brand new file, which git diff cannot see", function()
      -- Untracked files are invisible to `git diff` until they are staged,
      -- and a file the author just wrote is the most interesting kind there is.
      write("brand-new.txt", "one\ntwo\nthree")
      local files = assert(changes.for_review(fixture.root, review))

      local found
      for _, file in ipairs(files) do
        if file.path == "brand-new.txt" then
          found = file
        end
      end
      assert.is_truthy(found, "brand-new.txt was not in the list")
      assert.equals("A", found.status)
      assert.equals(3, found.additions)
    end)

    it("shows nothing local for a review that is not yours", function()
      write("change.txt", "edited anyway")
      assert.same({}, changes.unpublished({ worktree = review.worktree, mine = false }))
    end)
  end)

  describe("committing", function()
    it("commits everything the worktree has changed", function()
      write("change.txt", "alpha\nBETA\ngamma\ndelta")
      write("brand-new.txt", "fresh work")

      local commit = assert(author.commit(review, "Answer the review"))
      assert.equals("Answer the review", commit.subject)
      assert.is_truthy(commit.sha)
      assert.same({}, author.dirty(review))
      assert.equals(1, author.unpushed(review))
    end)

    it("wants a message", function()
      write("change.txt", "something")
      local commit, err = author.commit(review, "   ")
      assert.is_nil(commit)
      assert.equals("a commit needs a message", err)
    end)

    it("says so when there is nothing to commit", function()
      local commit, err = author.commit(review, "nothing doing")
      assert.is_nil(commit)
      assert.equals("nothing to commit", err)
    end)
  end)

  describe("publishing", function()
    it("pushes the branch and brings the review up to it", function()
      write("change.txt", "alpha\nBETA\ngamma\ndelta")
      local commit = assert(author.commit(review, "Answer the review"))

      local published = assert(author.publish(repo, pr, review))
      assert.equals(commit.sha, published.head)
      assert.equals("origin", published.remote)
      assert.equals("pr", published.branch)

      -- On the remote, and recorded here, so a refresh sees no movement.
      assert.equals(commit.sha, remote_sha("refs/heads/pr"))
      assert.equals(commit.sha, review.head)
      assert.equals(commit.sha,
        vim.json.decode(table.concat(
          vim.fn.readfile(vim.fs.joinpath(review.dir, "meta.json")), "\n")).head)
    end)

    it("refuses while anything is uncommitted", function()
      write("change.txt", "not committed")
      local published, err = author.publish(repo, pr, review)

      assert.is_nil(published)
      assert.is_truthy(err:find("not been committed", 1, true))
      assert.is_nil(remote_sha("refs/heads/pr"))
    end)

    it("says so when there is nothing to publish", function()
      local published, err = author.publish(repo, pr, review)
      assert.is_nil(published)
      assert.is_truthy(err:find("nothing to publish", 1, true))
    end)

    it("pushes a same-repository pull request to its own remote", function()
      assert.equals("origin", (author.remote(repo, pr)))
    end)

    it("will not guess where a fork lives", function()
      -- The commits arrived through refs/pull/<n>/head, which is readable and
      -- not writable; the branch itself is in somebody else's repository.
      local forked = vim.tbl_extend("force", pr, {
        isCrossRepository = true,
        headRepositoryOwner = { login = "a-fork" },
        headRepository = { name = "r" },
      })
      local remote, err = author.remote(repo, forked)

      assert.is_nil(remote)
      assert.is_truthy(err:find("a-fork/r", 1, true))
      assert.is_truthy(err:find("not a remote here", 1, true))
    end)
  end)

  describe("what a refresh will not do", function()
    it("refuses to reset over uncommitted work", function()
      write("change.txt", "work in progress")
      local updated, err = worktree.update(repo, pr)

      assert.is_nil(updated)
      assert.is_truthy(err:find("uncommitted", 1, true))
      -- Still there, which is the whole point.
      assert.equals("work in progress",
        vim.fn.readfile(vim.fs.joinpath(review.worktree, "change.txt"))[1])
    end)

    it("refuses to reset over commits that are not on GitHub", function()
      write("change.txt", "committed but not pushed")
      local commit = assert(author.commit(review, "local only"))

      local updated, err = worktree.update(repo, pr)
      assert.is_nil(updated)
      assert.is_truthy(err:find("not on GitHub", 1, true))

      local head = vim.fn.systemlist({ "git", "-C", review.worktree, "rev-parse", "HEAD" })[1]
      assert.equals(commit.sha, head)
    end)

    it("moves again once the work has been published", function()
      write("change.txt", "committed and pushed")
      local commit = assert(author.commit(review, "local only"))
      assert.is_truthy(author.publish(repo, pr, review))
      github_follows_the_branch()

      pr.headRefOid = commit.sha
      local updated = assert(worktree.update(repo, pr))
      assert.equals(commit.sha, updated.head)
    end)
  end)
end)
