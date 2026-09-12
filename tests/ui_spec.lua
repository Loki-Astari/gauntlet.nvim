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

  --- Start from one tab holding the sort of empty buffer Neovim opens with.
  local function fresh_tab()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    vim.cmd("enew!")
  end

  before_each(fresh_tab)
  after_each(fresh_tab)

  describe("conversation", function()
    it("takes over the empty starting buffer rather than opening a tab", function()
      -- What `vig` leaves behind: nothing loaded, one window, one tab.
      local before = #vim.api.nvim_list_tabpages()
      local buf = ui.conversation(pr, repo)

      assert.equals(before, #vim.api.nvim_list_tabpages())
      assert.equals(buf, vim.api.nvim_get_current_buf())

      -- ...and no blank [No Name] buffer stranded beside it.
      local blank = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" then
          blank = blank + 1
        end
      end
      assert.equals(0, blank)
    end)

    it("opens its own tab when there is work on screen", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "some work in progress" })
      local before = #vim.api.nvim_list_tabpages()

      ui.conversation(pr, repo)
      assert.equals(before + 1, #vim.api.nvim_list_tabpages())
    end)

    it("opens its own tab when the window is shared", function()
      vim.cmd("split")
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

    it("titles the view PR Review <id>", function()
      assert.equals("PR Review 142", ui.title(pr))
    end)

    it("labels the tab with the title", function()
      -- Both Neovim's tabline and bufferline-style plugins label from the
      -- tail of the buffer name, so that is what has to read well.
      local buf = ui.conversation(pr, repo)
      assert.equals("PR Review 142", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
      assert.equals("PR Review 142", vim.t.gauntlet_title)
    end)

    it("keeps the repository in the buffer name, so two #1s can coexist", function()
      local name = vim.api.nvim_buf_get_name(ui.conversation(pr, repo))
      assert.is_truthy(name:find("o/r/PR Review 142", 1, true))
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
