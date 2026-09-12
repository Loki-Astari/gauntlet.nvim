describe("gauntlet.render", function()
  local render = require("gauntlet.render")

  local pr = {
    number = 142,
    title = "Fix off-by-one in ring buffer",
    author = { login = "loki" },
    state = "OPEN",
    isDraft = false,
    url = "https://github.com/o/r/pull/142",
    headRefName = "fix/ring-buf",
    baseRefName = "master",
    createdAt = "2026-09-10T08:15:00Z",
    additions = 12,
    deletions = 4,
    changedFiles = 2,
    body = "The wrap check used <= where it should have used <.\r\n\r\nCloses #17.",
  }

  it("summarises a pull request on one line", function()
    local line = render.summary(pr)
    assert.is_truthy(line:find("#142", 1, true))
    assert.is_truthy(line:find("Fix off-by-one", 1, true))
    assert.is_truthy(line:find("loki", 1, true))
    assert.is_nil(line:find("draft", 1, true))
  end)

  it("marks drafts in the summary", function()
    local draft = vim.tbl_extend("force", pr, { isDraft = true })
    assert.is_truthy(render.summary(draft):find("draft", 1, true))
  end)

  it("falls back when the author is missing", function()
    assert.equals("unknown", render.author({}))
  end)

  it("shortens an ISO timestamp to a date", function()
    assert.equals("2026-09-10", render.date("2026-09-10T08:15:00Z"))
    assert.equals("", render.date(nil))
    assert.equals("whenever", render.date("whenever"))
  end)

  describe("conversation", function()
    it("puts the number and title in the heading", function()
      local lines = render.conversation(pr)
      assert.equals("# #142  Fix off-by-one in ring buffer", lines[1])
    end)

    it("describes the merge and the diff size", function()
      local text = table.concat(render.conversation(pr), "\n")
      assert.is_truthy(text:find("loki wants to merge `fix/ring-buf` into `master`", 1, true))
      assert.is_truthy(text:find("Open · 2 files changed · +12 −4 · opened 2026-09-10", 1, true))
      assert.is_truthy(text:find("https://github.com/o/r/pull/142", 1, true))
    end)

    it("includes the body, with the CRLF endings stripped", function()
      local lines = render.conversation(pr)
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("The wrap check used <=", 1, true))
      assert.is_truthy(text:find("Closes #17.", 1, true))
      for _, line in ipairs(lines) do
        assert.is_nil(line:find("\r", 1, true))
      end
    end)

    it("says so when there is no description", function()
      local text = table.concat(render.conversation(vim.tbl_extend("force", pr, { body = "" })), "\n")
      assert.is_truthy(text:find("No description provided", 1, true))
    end)

    it("uses the singular for a one-file change", function()
      local one = vim.tbl_extend("force", pr, { changedFiles = 1 })
      assert.is_truthy(table.concat(render.conversation(one), "\n"):find("1 file changed", 1, true))
    end)

    it("labels a draft", function()
      local draft = vim.tbl_extend("force", pr, { isDraft = true })
      assert.is_truthy(table.concat(render.conversation(draft), "\n"):find("Draft ·", 1, true))
    end)
  end)
end)
