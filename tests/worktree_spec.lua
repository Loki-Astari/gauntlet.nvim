describe("gauntlet.worktree", function()
  local worktree = require("gauntlet.worktree")
  local changes = require("gauntlet.changes")
  local gauntlet = require("gauntlet")
  local helpers = require("tests.helpers")

  local fixture, store, cwd
  local repo = { name = "origin", owner = "o", repo = "r" }
  local pr

  before_each(function()
    fixture = helpers.repo_with_pr(1)
    pr = { number = 1, baseRefOid = fixture.base, headRefOid = fixture.head }

    -- Keep test worktrees out of the real state directory.
    store = vim.fn.tempname()
    gauntlet.config.dir = store

    cwd = vim.fn.getcwd()
    vim.cmd.cd(fixture.root)
  end)

  after_each(function()
    pcall(worktree.remove, repo, 1)
    vim.cmd.cd(cwd)
    gauntlet.config.dir = nil
    vim.fn.delete(store, "rf")
    fixture.cleanup()
  end)

  it("puts a review under <store>/<repo>/pr-<n>", function()
    assert.equals(vim.fs.joinpath(store, "r", "pr-1"), worktree.dir(repo, 1))
  end)

  it("fetches the pull request and checks it out", function()
    local review = assert(worktree.open(repo, pr))

    assert.equals(fixture.head, review.head)
    assert.equals(fixture.base, review.base)
    assert.equals(1, vim.fn.isdirectory(review.worktree))
    assert.equals(
      "fresh",
      vim.fn.readfile(vim.fs.joinpath(review.worktree, "new.txt"))[1]
    )
  end)

  it("keeps its own files out of the worktree", function()
    -- Draft comments will live beside the worktree, never inside it: anything
    -- gauntlet writes there would show up in git status and could be
    -- committed by accident.
    local review = assert(worktree.open(repo, pr))
    assert.equals(vim.fs.joinpath(review.dir, "worktree"), review.worktree)

    local status = vim.fn.systemlist({ "git", "-C", review.worktree, "status", "--porcelain" })
    assert.same({}, status)
  end)

  it("records what it fetched, so a reconnect needs no network", function()
    worktree.open(repo, pr)
    local meta = vim.json.decode(
      table.concat(vim.fn.readfile(vim.fs.joinpath(worktree.dir(repo, 1), "meta.json")), "\n")
    )
    assert.equals(fixture.base, meta.base)
    assert.equals(fixture.head, meta.head)
    assert.equals("o/r", meta.repo)
  end)

  it("reconnects to a review it already has", function()
    local first = assert(worktree.open(repo, pr))
    local second = assert(worktree.open(repo, pr))
    assert.equals(first.worktree, second.worktree)
    assert.equals(first.base, second.base)
  end)

  it("serves the whole file list from local git afterwards", function()
    -- The point of the worktree: a review is started online and finished off it.
    local review = assert(worktree.open(repo, pr))
    local files = assert(changes.list(fixture.root, review.base, review.head))
    local paths = vim.tbl_map(function(f)
      return f.path
    end, files)
    assert.same({ "change.txt", "gone.txt", "new.txt" }, paths)
  end)

  it("removes the worktree, the ref and its own files", function()
    local review = assert(worktree.open(repo, pr))
    assert.is_true((worktree.remove(repo, 1)))

    assert.equals(0, vim.fn.isdirectory(review.worktree))
    assert.equals(0, vim.fn.isdirectory(review.dir))

    local refs = vim.fn.systemlist({ "git", "-C", fixture.root, "for-each-ref", "refs/gauntlet" })
    assert.same({}, refs)

    local listed = vim.fn.systemlist({ "git", "-C", fixture.root, "worktree", "list", "--porcelain" })
    assert.is_nil(table.concat(listed, "\n"):find("pr-1", 1, true))
  end)

  it("lists the reviews on disk", function()
    worktree.open(repo, pr)
    assert.same({ 1 }, worktree.list(repo))
  end)
end)
