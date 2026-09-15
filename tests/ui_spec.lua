describe("gauntlet.ui", function()
  local ui = require("gauntlet.ui")
  local changes = require("gauntlet.changes")
  local helpers = require("tests.helpers")

  local fixture, state, review_dir

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
  local function open(thread_store)
    return ui.review({
      threads = thread_store,
      repo = { owner = "o", repo = "r" },
      pr = pr,
      review = {
        dir = review_dir,
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

  --- The diff windows on the right, left to right.  The comment composer is
  --- not one of them, so it is excluded by its buffer type.
  local function panes()
    local out = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
      if win ~= state.sidebar_win and vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "acwrite" then
        table.insert(out, win)
      end
    end
    return out
  end

  before_each(function()
    fixture = helpers.repo()
    review_dir = vim.fn.tempname()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose!")
    end
    vim.cmd("enew!")
    state = open()
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose!")
    end
    vim.cmd("enew!")
    vim.fn.delete(review_dir, "rf")
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
      assert.is_truthy(text:find("Files (4)", 1, true))
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

  describe("the file list columns", function()
    -- A row used to work out its own path width from its own counts, so no
    -- two rows agreed where the numbers went.  Widths are now measured once
    -- over the whole list.
    local WIDTH = 40

    local function file_lines()
      local out = {}
      for _, line in ipairs(sidebar_lines()) do
        if line:match("^  %a ") then
          table.insert(out, line)
        end
      end
      return out
    end

    local function entry(path, adds, dels)
      return { path = path, status = "M", additions = adds or 1, deletions = dels or 0, binary = false }
    end

    --- Where `needle` starts, in display cells rather than bytes.
    local function column_of(line, needle)
      local at = assert(line:find(needle, 1, true), needle .. " not in " .. line)
      return vim.fn.strdisplaywidth(line:sub(1, at - 1))
    end

    local function thread_on(path)
      return {
        path = path, side = "RIGHT", line = 2, resolved = false, outdated = false,
        subject = "line", comments = { { author = "loki", body = "why not local?" } },
      }
    end

    it("makes every row the full width of the sidebar", function()
      for _, line in ipairs(file_lines()) do
        assert.equals(WIDTH, vim.fn.strdisplaywidth(line))
      end
    end)

    it("ends the additions in the same column on every row", function()
      -- Right-aligned, so the digits end together however many there are --
      -- which is what makes +193 and +58 comparable at a glance.
      state.files = { entry("a.txt", 1, 1), entry("b.txt", 193, 45), entry("c.txt", 58, 0) }
      ui.render_sidebar(state)

      local at
      for _, line in ipairs(file_lines()) do
        local upto = assert(line:match("^(.-%+%d+)"))
        local ends = vim.fn.strdisplaywidth(upto)
        at = at or ends
        assert.equals(at, ends)
        assert.equals(WIDTH, vim.fn.strdisplaywidth(line))
      end
    end)

    it("ends every row flush with the right edge", function()
      -- The deletions are the last column, so they are what proves it.  The
      -- old code measured the minus sign in bytes and the marker in cells,
      -- and came up three short.
      state.files = { entry("a.txt", 1, 1), entry("b.txt", 193, 45) }
      ui.render_sidebar(state)

      for _, line in ipairs(file_lines()) do
        assert.is_truthy(line:match("−%d+$"))
        assert.equals(WIDTH, vim.fn.strdisplaywidth(line))
      end
    end)

    it("lines the thread markers up with each other", function()
      state.threads = { threads = { thread_on("change.txt"), thread_on("new.txt") } }
      ui.render_sidebar(state)

      local seen = {}
      for _, line in ipairs(file_lines()) do
        if line:find("●", 1, true) then
          table.insert(seen, column_of(line, "●"))
        end
      end
      assert.equals(2, #seen)
      assert.equals(seen[1], seen[2])
    end)

    it("takes the marker column out of the path, not the counts", function()
      -- A path that fits while nothing is commented, and has to give way
      -- once something is.  The counts stay where they are, against the
      -- right edge.
      state.files = { entry("lua/gauntlet/exactlyfits.lua", 1, 1) }
      ui.render_sidebar(state)

      local before = file_lines()[1]
      assert.is_nil(before:find("●", 1, true))
      assert.is_truthy(before:find("lua/gauntlet/exactlyfits.lua", 1, true))

      state.threads = { threads = { thread_on("lua/gauntlet/exactlyfits.lua") } }
      ui.render_sidebar(state)

      local after = file_lines()[1]
      assert.is_truthy(after:find("●1", 1, true))
      assert.is_truthy(after:find("l/g/exactlyfits.lua", 1, true))
      assert.equals(before:match("−%d+$"), after:match("−%d+$"))
      assert.equals(WIDTH, vim.fn.strdisplaywidth(after))
    end)

    describe("fitting a path in", function()
      it("shortens the directories before it cuts anything", function()
        state.files = { entry("lua/gauntlet/deeply/nested/render.lua") }
        ui.render_sidebar(state)
        assert.is_truthy(file_lines()[1]:find("l/g/d/n/render.lua", 1, true))
      end)

      it("leaves a path that already fits alone", function()
        state.files = { entry("lua/gauntlet/ui.lua") }
        ui.render_sidebar(state)
        assert.is_truthy(file_lines()[1]:find("lua/gauntlet/ui.lua", 1, true))
      end)

      it("keeps two characters of a dotted directory", function()
        state.files = { entry(".github/workflows/deeply/nested/ci.yml") }
        ui.render_sidebar(state)
        assert.is_truthy(file_lines()[1]:find(".g/w/d/n/ci.yml", 1, true))
      end)

      it("keeps the end when even the short form will not fit", function()
        state.files = { entry("src/" .. string.rep("x", 60) .. ".lua") }
        ui.render_sidebar(state)

        local line = file_lines()[1]
        assert.is_truthy(line:find("…", 1, true))
        assert.is_truthy(line:find("xxx.lua", 1, true))
        assert.equals(WIDTH, vim.fn.strdisplaywidth(line))
      end)
    end)

    describe("colour", function()
      --- What each highlight on a row actually covers.
      local function covered(line_number)
        local ns = vim.api.nvim_create_namespace("GauntletSidebar")
        local text = sidebar_lines()[line_number]
        local out = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          state.sidebar_buf, ns, { line_number - 1, 0 }, { line_number - 1, -1 }, { details = true })) do
          out[mark[4].hl_group] = text:sub(mark[3] + 1, mark[4].end_col)
        end
        return out
      end

      it("colours each part of a row on its own", function()
        state.files = { entry("lua/gauntlet/ui.lua", 58, 45) }
        state.threads = { threads = { thread_on("lua/gauntlet/ui.lua") } }
        ui.render_sidebar(state)

        local hl = covered(line_of("ui.lua"))
        assert.equals("M", hl.GauntletStatusModified)
        assert.equals("lua/gauntlet/", hl.GauntletPathDir)
        assert.equals("ui.lua", hl.GauntletPathFile)
        assert.equals("●1", hl.GauntletThread)
        assert.equals("+58", hl.GauntletAdded)
        assert.equals("−45", hl.GauntletRemoved)
      end)

      it("tells an added file from a deleted one", function()
        assert.equals("A", covered(line_of("new.txt")).GauntletStatusAdded)
        assert.equals("D", covered(line_of("gone.txt")).GauntletStatusDeleted)
      end)

      it("draws a settled thread apart from an open one", function()
        state.threads = { threads = {
          thread_on("change.txt"),
          vim.tbl_extend("force", thread_on("new.txt"), { resolved = true }),
        } }
        state.show_settled = true
        ui.render_sidebar(state)

        assert.equals("●1", covered(line_of("change.txt")).GauntletThread)
        assert.equals("✓1", covered(line_of("new.txt")).GauntletSettled)
      end)

      it("defines every group as a default, so a colourscheme wins", function()
        ui.highlights()
        for _, group in ipairs({
          "GauntletStatusAdded", "GauntletStatusModified", "GauntletStatusDeleted",
          "GauntletStatusRenamed", "GauntletAdded", "GauntletRemoved",
          "GauntletThread", "GauntletSettled", "GauntletPathDir", "GauntletPathFile",
        }) do
          assert.is_truthy(vim.api.nvim_get_hl(0, { name = group }).link, group .. " should link")
        end
      end)
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

  describe("reloading after new commits", function()
    -- :GauntletRefresh moves the worktree onto the branch's current head and
    -- then calls ui.reload, which has to rebuild what was read from the old
    -- one.  The worktree move itself is covered in worktree_spec.

    it("rebuilds the file list", function()
      table.insert(state.files, {
        path = "later.txt", status = "A", additions = 1, deletions = 0, binary = false,
      })
      table.sort(state.files, function(a, b)
        return a.path < b.path
      end)
      ui.reload(state)

      local text = table.concat(sidebar_lines(), "\n")
      assert.is_truthy(text:find("Files (5)", 1, true))
      assert.is_truthy(text:find("A later.txt", 1, true))
    end)

    it("keeps the file on show, even when it has moved up the list", function()
      select_entry("new.txt")
      table.remove(state.files, 1) -- big.txt, above it in the list
      ui.reload(state)

      assert.equals("new.txt", state.diff.file.path)
      assert.equals(2, #panes())
      assert.same({ "fresh" }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes()[2]), 0, -1, false))
      assert.equals(line_of("new.txt"), state.current)
    end)

    it("falls back to the conversation when the new head drops that file", function()
      select_entry("new.txt")
      state.files = vim.tbl_filter(function(file)
        return file.path ~= "new.txt"
      end, state.files)
      ui.reload(state)

      assert.is_nil(state.diff)
      assert.equals(1, #panes())
      local buf = vim.api.nvim_win_get_buf(panes()[1])
      assert.equals("# #142  Fix off-by-one in ring buffer", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      assert.equals(line_of("Conversation"), state.current)
    end)

    it("re-reads the worktree rather than trusting the buffer it has", function()
      -- The right-hand pane is the real file, and the worktree has just been
      -- reset onto another commit underneath it.
      select_entry("change.txt")
      vim.fn.writefile({ "alpha", "BETA", "gamma", "delta" },
        vim.fs.joinpath(state.review.worktree, "change.txt"))
      ui.reload(state)

      assert.same(
        { "alpha", "BETA", "gamma", "delta" },
        vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panes()[2]), 0, -1, false)
      )
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

    it("shows the real file on the right, so LSP and gd have a path", function()
      -- The reason the whole project is checked out: the right-hand side is a
      -- genuine file, with its filetype detected from it.
      select_entry("change.txt")
      local buf = vim.api.nvim_win_get_buf(panes()[2])
      assert.equals("", vim.bo[buf].buftype)
      assert.equals(
        vim.fn.resolve(vim.fs.joinpath(state.review.worktree, "change.txt")),
        vim.fn.resolve(vim.api.nvim_buf_get_name(buf))
      )
    end)

    it("keeps that file out of the buffer list", function()
      -- It is a pane of the review, not a document the reviewer opened.  A
      -- listed buffer shows in :ls, in <C-^> and in bufferline plugins, where
      -- it reads as the file having been opened a second time.
      select_entry("change.txt")
      for _, win in ipairs(panes()) do
        assert.is_false(vim.bo[vim.api.nvim_win_get_buf(win)].buflisted)
      end
      assert.is_nil(
        vim.api.nvim_exec2("ls", { output = true }).output:find("change.txt", 1, true)
      )
    end)

    it("writes no swap file for a side that cannot be edited", function()
      select_entry("change.txt")
      assert.equals("", vim.fn.swapname(vim.api.nvim_win_get_buf(panes()[2])))
    end)

    it("leaves no buffer behind when another file is selected", function()
      -- Otherwise browsing a pull request strands one buffer per file looked at.
      select_entry("change.txt")
      local left, right = vim.api.nvim_win_get_buf(panes()[1]), vim.api.nvim_win_get_buf(panes()[2])

      select_entry("big.txt")
      assert.is_false(vim.api.nvim_buf_is_valid(left))
      assert.is_false(vim.api.nvim_buf_is_valid(right))
    end)

    it("spares a buffer the reviewer opened in another tab page", function()
      select_entry("change.txt")
      local right = vim.api.nvim_win_get_buf(panes()[2])

      vim.cmd("tabnew")
      vim.api.nvim_win_set_buf(0, right)
      vim.api.nvim_set_current_tabpage(state.tab)

      select_entry("big.txt")
      assert.is_true(vim.api.nvim_buf_is_valid(right))
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

  --- Put the cursor on a line of a diff pane and press a key.
  local function press(key, line, pane)
    pane = pane or 2
    vim.api.nvim_set_current_win(panes()[pane])
    vim.api.nvim_win_set_cursor(panes()[pane], { line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  end

  --- The composer is whichever window is neither the sidebar nor a diff pane.
  local function composer()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "acwrite" then
        return win
      end
    end
  end

  local function write_comment(text, line, file)
    select_entry(file or "change.txt")
    press("c", line or 2)
    local win = assert(composer(), "no composer opened")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false,
      vim.split(text, "\n", { plain = true }))
    vim.api.nvim_set_current_win(win)
    vim.cmd("write")
  end

  describe("comments", function()
    local comments = require("gauntlet.comments")

    it("opens a place to write, under the diff", function()
      select_entry("change.txt")
      press("c", 2)
      assert.is_true(composer() ~= nil)
      assert.equals("markdown", vim.bo[vim.api.nvim_win_get_buf(composer())].filetype)
    end)

    it("spans both diff panes, not just one", function()
      select_entry("change.txt")
      press("c", 2)
      local win = assert(composer(), "no composer opened")

      local left, right = panes()[1], panes()[2]
      local left_col = vim.api.nvim_win_get_position(left)[2]
      local widths = vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right)

      -- Flush with the left pane, and as wide as the two together (plus the
      -- separator between them).
      assert.equals(left_col, vim.api.nvim_win_get_position(win)[2])
      assert.is_true(vim.api.nvim_win_get_width(win) >= widths)
    end)

    it("leaves the sidebar alone while composing", function()
      local width = vim.api.nvim_win_get_width(state.sidebar_win)
      select_entry("change.txt")
      press("c", 2)
      assert.equals(width, vim.api.nvim_win_get_width(state.sidebar_win))
      assert.is_true(vim.api.nvim_win_get_position(composer())[2] > 0)
    end)

    it("keeps both sides of the diff in view while composing", function()
      select_entry("change.txt")
      press("c", 2)
      assert.equals(2, #panes())
      for _, win in ipairs(panes()) do
        assert.is_true(vim.wo[win].diff)
      end
    end)

    it("draws the comment as a bordered note", function()
      write_comment("needs a test")
      local ns = vim.api.nvim_create_namespace("GauntletComments")
      local marks = vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, { details = true })
      local drawn = vim.inspect(marks[1][4].virt_lines)

      -- A box reads as not-code whatever the colourscheme does, which dim
      -- virtual text among source lines did not.
      assert.is_truthy(drawn:find("╭", 1, true))
      assert.is_truthy(drawn:find("╰", 1, true))
      assert.is_truthy(drawn:find("GauntletCommentBorder", 1, true))
      assert.is_truthy(drawn:find("GauntletComment", 1, true))
    end)

    it("wraps a long comment instead of hiding the end of it", function()
      local long = "this comment is deliberately far too long to fit inside the "
        .. "width of a single diff pane and so it has to be broken across "
        .. "several lines rather than cut short"
      write_comment(long)

      local ns = vim.api.nvim_create_namespace("GauntletComments")
      local marks = vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, { details = true })

      local text = ""
      for _, line in ipairs(marks[1][4].virt_lines) do
        for _, chunk in ipairs(line) do
          text = text .. chunk[1]
        end
      end

      assert.is_nil(text:find("…", 1, true), "the comment was truncated")
      -- Every word survives, in order, across however many lines it took.
      for word in long:gmatch("%S+") do
        assert.is_truthy(text:find(word, 1, true), "lost the word: " .. word)
      end
      assert.is_true(#marks[1][4].virt_lines > 4)
    end)

    it("defines its highlights so a colourscheme can override them", function()
      ui.highlights()
      for _, group in ipairs({
        "GauntletComment", "GauntletCommentBorder", "GauntletCommentSign",
      }) do
        local hl = vim.api.nvim_get_hl(0, { name = group })
        assert.is_truthy(next(hl), group .. " is not defined")
      end
    end)

    it("keeps what was written, and closes", function()
      write_comment("needs a test for the empty case")

      assert.is_true(composer() == nil)
      local stored = comments.load(state.review)
      assert.equals(1, #stored.threads)
      assert.equals("change.txt", stored.threads[1].path)
      assert.equals("RIGHT", stored.threads[1].side)
      assert.equals(2, stored.threads[1].line)
      assert.equals("needs a test for the empty case", stored.threads[1].comments[1].body)
      assert.equals("draft", stored.threads[1].comments[1].state)
    end)

    it("keeps nothing when nothing was written", function()
      select_entry("change.txt")
      press("c", 2)
      vim.api.nvim_set_current_win(composer())
      vim.cmd("write")
      assert.same({}, comments.load(state.review).threads)
    end)

    it("refuses a line GitHub would not accept", function()
      -- big.txt changed only at line 20, so line 1 is not in the diff at all.
      -- Saying so now beats a puzzling rejection at submission time.
      select_entry("big.txt")
      press("c", 1)
      assert.is_true(composer() == nil)
      assert.same({}, comments.load(state.review).threads)
    end)

    it("allows a line that is in the diff", function()
      select_entry("big.txt")
      press("c", 20)
      assert.is_true(composer() ~= nil)
    end)

    it("marks the line it is on, and shows the text under it", function()
      write_comment("needs a test")
      local ns = vim.api.nvim_create_namespace("GauntletComments")
      local marks = vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, { details = true })

      assert.equals(1, #marks)
      assert.equals(1, marks[1][2]) -- line 2, zero-based
      assert.equals("●", marks[1][4].sign_text:gsub("%s", ""))
      assert.is_truthy(vim.inspect(marks[1][4].virt_lines):find("needs a test", 1, true))
    end)

    it("counts them beside the file in the list", function()
      write_comment("needs a test")
      local text = table.concat(sidebar_lines(), "\n")
      assert.is_truthy(text:find("●1", 1, true))
    end)

    it("deletes the comment on the line", function()
      write_comment("needs a test")
      press("dc", 2)

      assert.same({}, comments.load(state.review).threads)
      local ns = vim.api.nvim_create_namespace("GauntletComments")
      assert.same({}, vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, {}))
    end)

    it("are still there when the review is opened again", function()
      write_comment("needs a test")

      while #vim.api.nvim_list_tabpages() > 1 do
        vim.cmd("tabclose!")
      end
      vim.cmd("enew!")
      state = open()

      assert.equals(1, #state.comments.threads)
      assert.is_truthy(table.concat(sidebar_lines(), "\n"):find("●1", 1, true))
    end)

    it("sends them as one review, in the shape GitHub wants", function()
      write_comment("needs a test")
      local payload = require("gauntlet.github").review_comments(
        comments.drafts(state.comments))

      assert.equals(1, #payload)
      assert.equals("change.txt", payload[1].path)
      assert.equals(2, payload[1].line)
      assert.equals("RIGHT", payload[1].side)
      assert.equals("needs a test", payload[1].body)
    end)
  end)

  describe("threads pulled from GitHub", function()
    local comments = require("gauntlet.comments")

    --- `without` names fields to clear: a table constructor cannot hold an
    --- explicit nil, so `{ line = nil }` would silently keep the default.
    local function github_thread(over, without)
      local built = vim.tbl_extend("force", {
        id = "PRRT_1",
        origin = "github",
        path = "change.txt",
        side = "RIGHT",
        line = 2,
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

    local function reopen(store)
      while #vim.api.nvim_list_tabpages() > 1 do
        vim.cmd("tabclose!")
      end
      vim.cmd("enew!")
      state = open(store)
    end

    local function notes()
      local ns = vim.api.nvim_create_namespace("GauntletComments")
      return vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, { details = true })
    end

    local function drawn_text()
      local out = ""
      for _, mark in ipairs(notes()) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do
            out = out .. chunk[1]
          end
        end
      end
      return out
    end

    it("draws someone else's thread against its line", function()
      reopen({ fetched_at = "now", threads = { github_thread() } })
      select_entry("change.txt")

      assert.equals(1, #notes())
      local text = drawn_text()
      assert.is_truthy(text:find("loki", 1, true))
      assert.is_truthy(text:find("why not local?", 1, true))
      assert.is_truthy(text:find("thread", 1, true))
    end)

    it("shows them beside your own comments on the same line", function()
      reopen({ fetched_at = "now", threads = { github_thread() } })
      write_comment("and it needs a test")

      local text = drawn_text()
      assert.is_truthy(text:find("why not local?", 1, true))
      assert.is_truthy(text:find("and it needs a test", 1, true))
      assert.equals(2, #notes())
    end)

    it("hides a resolved thread", function()
      reopen({ fetched_at = "now", threads = { github_thread({ resolved = true }) } })
      select_entry("change.txt")
      assert.equals(0, #notes())
    end)

    it("hides an outdated thread", function()
      reopen({ fetched_at = "now", threads = { github_thread({ outdated = true }) } })
      select_entry("change.txt")
      assert.equals(0, #notes())
    end)

    it("reveals them on T, and hides them again", function()
      reopen({ fetched_at = "now", threads = { github_thread({ resolved = true }) } })
      select_entry("change.txt")
      assert.equals(0, #notes())

      vim.api.nvim_set_current_win(panes()[2])
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("T", true, false, true), "x", false)
      assert.equals(1, #notes())
      assert.is_truthy(drawn_text():find("resolved", 1, true))

      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("T", true, false, true), "x", false)
      assert.equals(0, #notes())
    end)

    it("counts open and settled separately in the file list", function()
      reopen({
        fetched_at = "now",
        threads = {
          github_thread({ id = "a" }),
          github_thread({ id = "b", resolved = true }),
          github_thread({ id = "c", outdated = true }),
        },
      })

      local text = table.concat(sidebar_lines(), "\n")
      assert.is_truthy(text:find("●1", 1, true), "one open thread")
      assert.is_truthy(text:find("✓2", 1, true), "two settled threads")
    end)

    it("never draws a thread that has no line to sit on", function()
      reopen({
        fetched_at = "now",
        threads = { github_thread({ subject = "file" }, { "line" }) },
      })
      select_entry("change.txt")

      vim.api.nvim_set_current_win(panes()[2])
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("T", true, false, true), "x", false)
      assert.equals(0, #notes())
    end)

    it("keeps them out of what gets submitted", function()
      -- Only what you wrote is yours to send.
      reopen({ fetched_at = "now", threads = { github_thread() } })
      write_comment("mine")

      local drafts = comments.drafts(state.comments)
      assert.equals(1, #drafts)
      assert.equals("mine", drafts[1].comments[1].body)
    end)

    it("puts a thread on the left-hand side when that is where it belongs", function()
      reopen({
        fetched_at = "now",
        threads = { github_thread({ side = "LEFT", line = 1 }) },
      })
      select_entry("change.txt")

      local ns = vim.api.nvim_create_namespace("GauntletComments")
      local left = vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[1]), ns, 0, -1, {})
      assert.equals(1, #left)
      assert.equals(0, #notes())
    end)
  end)

  describe("a pull request of your own", function()
    -- The fixture's working tree stands in for the review worktree, so
    -- writing in it is what the author editing the right-hand pane amounts to.
    local author = require("gauntlet.author")
    local comments = require("gauntlet.comments")

    local function as_author()
      state.review.mine = true
      state.review.branch = "pr"
      ui.render_sidebar(state)
    end

    local function edit_in_worktree(path, text)
      vim.fn.writefile(vim.split(text, "\n", { plain = true }),
        vim.fs.joinpath(state.review.worktree, path))
    end

    local function right_buf()
      return vim.api.nvim_win_get_buf(panes()[2])
    end

    it("leaves someone else's review shut", function()
      select_entry("change.txt")
      assert.is_false(vim.bo[right_buf()].modifiable)
      assert.is_true(vim.bo[right_buf()].readonly)
    end)

    it("opens the right-hand side for editing when it is yours", function()
      as_author()
      select_entry("change.txt")
      assert.is_true(vim.bo[right_buf()].modifiable)
      assert.is_false(vim.bo[right_buf()].readonly)
    end)

    it("still refuses the left-hand side, which is the base", function()
      as_author()
      select_entry("change.txt")
      assert.is_false(vim.bo[vim.api.nvim_win_get_buf(panes()[1])].modifiable)
    end)

    it("keeps unwritten work when another file is selected", function()
      -- Tidying up used to force-delete the pane, which would take the edit
      -- with it.
      as_author()
      select_entry("change.txt")
      local buf = right_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "EDITED", "gamma" })
      assert.is_true(vim.bo[buf].modified)

      select_entry("big.txt")
      assert.is_true(vim.api.nvim_buf_is_valid(buf), "the edited buffer was thrown away")
      assert.same(
        { "alpha", "EDITED", "gamma" },
        vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      )
    end)

    it("marks a file the worktree has changed", function()
      edit_in_worktree("change.txt", "alpha\nBETA\ngamma\ndelta")
      as_author()

      local row
      for _, line in ipairs(sidebar_lines()) do
        if line:find("change.txt", 1, true) and line:match("^  %a ") then
          row = line
        end
      end
      assert.is_truthy(row:find("✎", 1, true), "no local mark on " .. row)
      assert.is_nil(
        (sidebar_lines()[line_of("big.txt")]):find("✎", 1, true),
        "an untouched file should carry no local mark")
    end)

    it("says in the header how much is not on GitHub", function()
      edit_in_worktree("change.txt", "alpha\nBETA\ngamma\ndelta")
      as_author()
      assert.is_truthy(table.concat(sidebar_lines(), "\n"):find("1 uncommitted", 1, true))
    end)

    it("says nothing in the header when the worktree is clean", function()
      as_author()
      assert.is_nil(table.concat(sidebar_lines(), "\n"):find("uncommitted", 1, true))
    end)

    it("refuses a comment on a file that is not on GitHub", function()
      -- Its line numbers are not GitHub's, so the comment would land
      -- somewhere else entirely.
      edit_in_worktree("change.txt", "alpha\nBETA\ngamma\ndelta")
      as_author()
      select_entry("change.txt")
      press("c", 2)

      assert.is_nil(composer(), "a composer should not have opened")
      assert.same({}, comments.drafts(state.comments))
    end)

    it("takes a comment on a file it has not touched", function()
      -- Only the edited file is out of step with GitHub; the rest of the pull
      -- request is still exactly what GitHub holds.
      edit_in_worktree("change.txt", "alpha\nBETA\ngamma\ndelta")
      as_author()
      assert.same(
        { "change.txt" },
        vim.tbl_map(function(change)
          return change.path
        end, author.dirty(state.review))
      )

      write_comment("fine here", 20, "big.txt")
      assert.equals(1, #comments.drafts(state.comments))
    end)
  end)

  describe("sending a review", function()
    local comments = require("gauntlet.comments")
    local github = require("gauntlet.github")
    local threads = require("gauntlet.threads")
    local gauntlet = require("gauntlet")

    local calls, handed_back, real

    --- The payload of the request that carried the line comments.
    local function posted()
      for _, call in ipairs(calls) do
        if call.kind == "create" then
          return call.payload
        end
      end
      return {}
    end

    --- The verdict the review ended up with, whichever step gave it.
    local function verdict()
      for index = #calls, 1, -1 do
        if calls[index].payload.event then
          return calls[index].payload.event
        end
      end
    end

    local function composer_win()
      -- plenary runs after_each for every test in the file, not just this
      -- block's, so by the time it calls this the review may be long closed.
      if not vim.api.nvim_tabpage_is_valid(state.tab) then
        return nil
      end
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "acwrite" then
          return win
        end
      end
    end

    --- Write the covering note and send.
    local function note(text)
      local win = assert(composer_win(), "no note buffer opened")
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false,
        vim.split(text, "\n", { plain = true }))
      vim.api.nvim_set_current_win(win)
      -- A send that fails reports it with vim.notify at ERROR level, and a
      -- headless Neovim turns that into an error out of :write.  The refusal
      -- is the thing being tested, so it must not end the test here.
      pcall(vim.cmd, "write")
    end

    local function drawn()
      local ns = vim.api.nvim_create_namespace("GauntletComments")
      local out = ""
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        vim.api.nvim_win_get_buf(panes()[2]), ns, 0, -1, { details = true })) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do
            out = out .. chunk[1]
          end
        end
      end
      return out
    end

    before_each(function()
      calls = {}
      -- GitHub hands a sent comment back as a thread, as it does in life.
      handed_back = true
      real = {
        create_review = github.create_review,
        submit_review = github.submit_review,
        get_open = github.get_open,
        fetch = threads.fetch,
      }
      github.get_open = function()
        return { number = state.pr.number, state = "OPEN", headRefOid = fixture.head }
      end
      github.create_review = function(_, _, payload)
        table.insert(calls, { kind = "create", payload = payload })
        return { id = 99 }
      end
      github.submit_review = function(_, _, id, payload)
        table.insert(calls, { kind = "submit", id = id, payload = payload })
        return { id = id }
      end
      threads.fetch = function()
        if not handed_back then
          return {}
        end
        local out = {}
        for _, comment in ipairs(posted().comments or {}) do
          table.insert(out, {
            id = "PRRT_sent",
            origin = "github",
            path = comment.path,
            side = comment.side,
            line = comment.line,
            resolved = false,
            outdated = false,
            subject = "line",
            comments = { { author = "loki", body = comment.body, state = "published" } },
          })
        end
        return out
      end
    end)

    after_each(function()
      github.create_review = real.create_review
      github.submit_review, github.get_open = real.submit_review, real.get_open
      threads.fetch = real.fetch

      -- A failed send leaves the note open and modified on purpose, so that
      -- it can be tried again.  Teardown closes the tab page, which a
      -- modified buffer would refuse.
      local win = composer_win()
      if win then
        vim.bo[vim.api.nvim_win_get_buf(win)].modified = false
        pcall(vim.api.nvim_win_close, win, true)
      end
    end)

    it("sends nothing, and asks for nothing, when there is nothing new", function()
      gauntlet.push(state)
      assert.is_nil(composer_win())
      assert.same({}, calls)
    end)

    it("pushes the comments without asking for a note", function()
      -- The point of the command: the comments say what they have to say
      -- where they sit.
      write_comment("needs a test")
      gauntlet.push(state)

      assert.is_nil(composer_win(), "push should open no note buffer at all")
      assert.equals("COMMENT", verdict())
      assert.equals(1, #posted().comments)
      assert.equals("needs a test", posted().comments[1].body)
    end)

    it("takes a note of its own when one is wanted", function()
      write_comment("needs a test")
      gauntlet.note(state)
      assert.is_truthy(composer_win(), "a note should be asked for")
      note("a few thoughts overall")

      assert.equals("COMMENT", verdict())
      assert.equals("a few thoughts overall", posted().body)
      assert.equals(1, #posted().comments)
    end)

    it("approves, carrying anything still unsent with it", function()
      write_comment("one more thing")
      gauntlet.approve(state)
      note("")

      assert.equals("APPROVE", verdict())
      assert.equals(1, #posted().comments)
    end)

    it("requests changes", function()
      gauntlet.reject(state)
      note("not yet")

      assert.equals("REQUEST_CHANGES", verdict())
      assert.equals("not yet", posted().body)
    end)

    it("draws a sent comment once, not twice", function()
      -- It exists on both sides now: as a draft marked sent, and as the
      -- thread GitHub handed back.  Only one of them may be drawn.
      write_comment("needs a test")
      assert.equals(1, select(2, drawn():gsub("needs a test", "")))

      gauntlet.push(state)
      select_entry("change.txt")

      assert.equals(1, select(2, drawn():gsub("needs a test", "")))
      assert.is_truthy(drawn():find("loki", 1, true))
      assert.same({}, state.comments.threads)
    end)

    it("keeps the comment when GitHub has not handed it back yet", function()
      -- Dropping it before its double arrives would leave the line bare.
      handed_back = false
      write_comment("needs a test")
      gauntlet.push(state)
      select_entry("change.txt")

      assert.equals(1, #state.comments.threads)
      assert.is_truthy(drawn():find("needs a test", 1, true))
      assert.same({}, comments.drafts(state.comments))
    end)

    it("leaves the note where it is when the send fails", function()
      write_comment("needs a test")
      github.create_review = function()
        return nil, "Can not approve your own pull request"
      end

      gauntlet.approve(state)
      note("looks good")

      assert.is_truthy(composer_win(), "the note should still be open to try again")
      assert.equals(1, #comments.drafts(state.comments))
    end)
  end)
end)
