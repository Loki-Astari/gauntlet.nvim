describe("gauntlet.changes", function()
  local changes = require("gauntlet.changes")
  local helpers = require("tests.helpers")

  local repo

  before_each(function()
    repo = helpers.repo()
  end)

  after_each(function()
    repo.cleanup()
  end)

  describe("list", function()
    local function by_path()
      local files = assert(changes.list(repo.root, repo.base, repo.head))
      local map = {}
      for _, file in ipairs(files) do
        map[file.path] = file
      end
      return files, map
    end

    it("reports every changed file, sorted, and nothing else", function()
      local files = by_path()
      local paths = vim.tbl_map(function(f)
        return f.path
      end, files)
      assert.same({ "change.txt", "gone.txt", "new.txt" }, paths)
    end)

    it("leaves untouched files out", function()
      local _, map = by_path()
      assert.is_nil(map["keep.txt"])
    end)

    it("marks added, modified and deleted apart", function()
      local _, map = by_path()
      assert.equals("A", map["new.txt"].status)
      assert.equals("M", map["change.txt"].status)
      assert.equals("D", map["gone.txt"].status)
    end)

    it("counts the lines each way", function()
      local _, map = by_path()
      assert.equals(2, map["change.txt"].additions)
      assert.equals(1, map["change.txt"].deletions)
      assert.equals(1, map["new.txt"].additions)
      assert.equals(0, map["new.txt"].deletions)
      assert.equals(0, map["gone.txt"].additions)
      assert.equals(1, map["gone.txt"].deletions)
    end)

    it("reports an error rather than an empty list for a bad revision", function()
      local files, err = changes.list(repo.root, "nosuchcommit", repo.head)
      assert.is_nil(files)
      assert.is_string(err)
    end)
  end)

  describe("base_lines", function()
    it("returns the file as it was before the change", function()
      local lines, existed = changes.base_lines(repo.root, repo.base, "change.txt")
      assert.is_true(existed)
      assert.same({ "alpha", "beta" }, lines)
    end)

    it("distinguishes an added file from an empty one", function()
      -- An added file has no base side at all; that is an empty left-hand
      -- pane, not a failure, and the caller has to be able to tell.
      local lines, existed = changes.base_lines(repo.root, repo.base, "new.txt")
      assert.is_false(existed)
      assert.same({}, lines)
    end)

    it("still has the contents of a deleted file", function()
      local lines, existed = changes.base_lines(repo.root, repo.base, "gone.txt")
      assert.is_true(existed)
      assert.same({ "bye" }, lines)
    end)
  end)
end)
