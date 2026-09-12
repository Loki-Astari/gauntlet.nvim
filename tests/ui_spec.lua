describe("gauntlet.ui", function()
  local ui = require("gauntlet.ui")

  local repo = { owner = "o", repo = "r" }
  local pr = {
    number = 142,
    title = "Fix off-by-one in ring buffer",
    author = { login = "loki" },
    headRefName = "fix/ring-buf",
    baseRefName = "master",
    createdAt = "2026-09-10T08:15:00Z",
    url = "https://github.com/o/r/pull/142",
    additions = 12,
    deletions = 4,
    changedFiles = 2,
    body = "A description.",
  }

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
  end)

  describe("conversation", function()
    it("opens in its own tab page", function()
      local before = #vim.api.nvim_list_tabpages()
      ui.conversation(pr, repo)
      assert.equals(before + 1, #vim.api.nvim_list_tabpages())
    end)

    it("is a read-only scratch buffer", function()
      local buf = ui.conversation(pr, repo)
      assert.equals("nofile", vim.bo[buf].buftype)
      assert.equals("markdown", vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.is_true(vim.bo[buf].readonly)
      assert.is_false(vim.bo[buf].swapfile)
    end)

    it("names the buffer after the pull request", function()
      local buf = ui.conversation(pr, repo)
      assert.is_truthy(vim.api.nvim_buf_get_name(buf):find("o/r/pull/142", 1, true))
    end)

    it("maps q to close the view", function()
      local buf = ui.conversation(pr, repo)
      local mapped = false
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        mapped = mapped or map.lhs == "q"
      end
      assert.is_true(mapped)
    end)

    it("holds the rendered conversation", function()
      local buf = ui.conversation(pr, repo)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.equals("# #142  Fix off-by-one in ring buffer", lines[1])
      assert.is_truthy(table.concat(lines, "\n"):find("A description.", 1, true))
    end)
  end)

  describe("pick", function()
    it("says nothing is open rather than failing on an empty list", function()
      local chosen = false
      ui.pick({}, function()
        chosen = true
      end)
      assert.is_false(chosen)
    end)

    it("passes the chosen pull request on", function()
      local select = vim.ui.select
      vim.ui.select = function(items, _, on_choice)
        on_choice(items[2])
      end

      local got
      ui.pick({ { number = 1, title = "a" }, { number = 2, title = "b" } }, function(choice)
        got = choice
      end)
      vim.ui.select = select

      assert.equals(2, got.number)
    end)

    it("does nothing when the picker is cancelled", function()
      local select = vim.ui.select
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end

      local chosen = false
      ui.pick({ { number = 1, title = "a" } }, function()
        chosen = true
      end)
      vim.ui.select = select

      assert.is_false(chosen)
    end)
  end)
end)
