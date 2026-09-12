describe("gauntlet.ui", function()
  local ui = require("gauntlet.ui")
  local changes = require("gauntlet.changes")
  local helpers = require("tests.helpers")

  local fixture, state

  local pr = {
    number = 142,
    title = "Fix off-by-one in ring buffer",
    author = { login = "loki" },
    headRefName = "fix/ring-buf",
    baseRefName = "main",
    createdAt = "2026-09-10T08:15:00Z",
    url = "https://github.com/o/r/pull/142",
    additions = 2,
    deletions = 1,
    changedFiles = 3,
    body = "A description.",
  }

  --- The fixture's working tree is checked out at head, which is the shape of
  --- a review worktree, so it stands in for one.
  local function open()
    return ui.review({
      repo = { owner = "o", repo = "r" },
      pr = pr,
      review = {
        dir = fixture.root,
        worktree = fixture.root,
        base = fixture.base,
        head = fixture.head,
        number = pr.number,
      },
      files = assert(changes.list(fixture.root, fixture.base, fixture.head)),
      root = fixture.root,
    })
  end

  local function sidebar_lines()
    return vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)
  end

  --- Line number of the sidebar entry whose text contains `needle`.
  local function line_of(needle)
    for i, text in ipairs(sidebar_lines()) do
      if text:find(needle, 1, true) then
        return i
      end
    end
    error("no sidebar line containing " .. needle)
  end

  local function select_entry(needle)
    vim.api.nvim_set_current_win(state.sidebar_win)
    vim.api.nvim_win_set_cursor(state.sidebar_win, { line_of(needle), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end

  --- The windows on the right, left to right.
  local function panes()
    local out = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
      if win ~= state.sidebar_win then
        table.insert(out, win)
      end
    end
    return out
  end

  before_each(function()
    fixture = helpers.repo()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    vim.cmd("enew!")
    state = open()
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    vim.cmd("enew!")
    fixture.cleanup()
  end)

  describe("the sidebar", function()
    it("names the review and the repository", function()
      local lines = sidebar_lines()
      assert.equals("PR Review 142", lines[1])
      assert.equals("o/r", lines[2])
    end)

    it("offers the conversation as its first entry", function()
      assert.is_truthy(line_of("Conversation"))
    end)

    it("lists every changed file with its status and counts", function()
      local text = table.concat(sidebar_lines(), "\n")
      assert.is_truthy(text:find("Files (3)", 1, true))
      assert.is_truthy(text:find("M change.txt", 1, true))
      assert.is_truthy(text:find("A new.txt", 1, true))
      assert.is_truthy(text:find("D gone.txt", 1, true))
      assert.is_truthy(text:find("+2 −1", 1, true))
    end)

    it("leaves unchanged files out", function()
      assert.is_nil(table.concat(sidebar_lines(), "\n"):find("keep.txt", 1, true))
    end)

    it("cannot be edited", function()
      assert.is_false(vim.bo[state.sidebar_buf].modifiable)
    end)

    it("keeps its width when a diff opens beside it", function()
      local width = vim.api.nvim_win_get_width(state.sidebar_win)
      select_entry("change.txt")
      assert.equals(width, vim.api.nvim_win_get_width(state.sidebar_win))
    end)
  end)

  describe("the review tab", function()
    it("is labelled PR Review <id>", function()
      assert.equals("PR Review 142", vim.t.gauntlet_title)
      assert.equals("PR Review 142", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(state.sidebar_buf), ":t"))
    end)

    it("opens on the conversation", function()
      assert.equals(1, #panes())
      local buf = vim.api.nvim_win_get_buf(panes()[1])
      assert.equals("# #142  Fix off-by-one in ring buffer", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    end)
  end)

  describe("selecting a file", function()
    it("shows both sides side by side, in diff mode", function()
      select_entry("change.txt")
      local wins = panes()
      assert.equals(2, #wins)
      for _, win in ipairs(wins) do
        assert.is_true(vim.wo[win].diff)
      end
    end)

    it("puts the base on the left and the pull request on the right", function()
      select_entry("change.txt")
      local left, right = panes()[1], panes()[2]
      assert.same({ "alpha", "beta" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(left), 0, -1, false))
      assert.same({ "alpha", "BETA", "gamma" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(right), 0, -1, false))
    end)

    it("leaves the left side empty for an added file", function()
      select_entry("new.txt")
      local left = vim.api.nvim_win_get_buf(panes()[1])
      assert.same({ "" }, vim.api.nvim_buf_get_lines(left, 0, -1, false))
      assert.same({ "fresh" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes()[2]), 0, -1, false))
    end)

    it("leaves the right side empty for a deleted file", function()
      select_entry("gone.txt")
      assert.same({ "bye" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes()[1]), 0, -1, false))
      assert.same({ "" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes()[2]), 0, -1, false))
    end)

    it("makes neither side editable", function()
      -- A review must not be able to change the checkout, and the right-hand
      -- side is a real file in the worktree.
      select_entry("change.txt")
      for _, win in ipairs(panes()) do
        assert.is_false(vim.bo[vim.api.nvim_win_get_buf(win)].modifiable)
      end
    end)

    it("goes back to the conversation", function()
      select_entry("change.txt")
      assert.equals(2, #panes())
      select_entry("Conversation")
      assert.equals(1, #panes())
    end)

    it("returns the cursor to the file list", function()
      select_entry("change.txt")
      assert.equals(state.sidebar_win, vim.api.nvim_get_current_win())
    end)
  end)
end)
