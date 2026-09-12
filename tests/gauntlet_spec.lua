describe("gauntlet", function()
  local gauntlet

  before_each(function()
    package.loaded["gauntlet"] = nil
    gauntlet = require("gauntlet")
  end)

  it("loads without setup", function()
    assert.is_string(gauntlet.version)
    assert.is_false(gauntlet._configured)
  end)

  it("has usable defaults before setup", function()
    assert.equals("gh", gauntlet.config.gh)
    assert.is_number(gauntlet.config.limit)
  end)

  it("merges user options into the defaults", function()
    gauntlet.setup({ gh = "/usr/local/bin/gh" })
    assert.is_true(gauntlet._configured)
    assert.equals("/usr/local/bin/gh", gauntlet.config.gh)
    assert.is_number(gauntlet.config.limit)
  end)

  it("sources plugin/gauntlet.lua once", function()
    -- plenary prepends the plugin to 'runtimepath' after startup, so plugin/
    -- is never sourced automatically here; source it the way Neovim would.
    vim.g.loaded_gauntlet = nil
    vim.cmd("runtime plugin/gauntlet.lua")
    assert.is_true(vim.g.loaded_gauntlet)
  end)

  it("defines :Gauntlet, taking an optional argument", function()
    vim.g.loaded_gauntlet = nil
    vim.cmd("runtime plugin/gauntlet.lua")
    local command = vim.api.nvim_get_commands({})["Gauntlet"]
    assert.is_table(command)
    assert.equals("?", command.nargs)
  end)

  describe("open_preload", function()
    local function preload(contents)
      local path = vim.fn.tempname()
      vim.fn.writefile({ contents }, path)
      vim.env.GAUNTLET_PRELOAD = path
      return path
    end

    after_each(function()
      vim.env.GAUNTLET_PRELOAD = nil
      while #vim.api.nvim_list_tabpages() > 1 do
        vim.cmd("tabclose")
      end
    end)

    it("does nothing when nothing was preloaded", function()
      vim.env.GAUNTLET_PRELOAD = nil
      local before = #vim.api.nvim_list_tabpages()
      gauntlet._open_preloaded()
      assert.equals(before, #vim.api.nvim_list_tabpages())
    end)

    it("waits for startup to finish before opening anything", function()
      -- vig passes this as a -c argument, which Neovim runs before VimEnter;
      -- a config that restores a session there would otherwise replace the
      -- review.  (The test runner itself runs specs from -c, so this is the
      -- live case here.)
      if vim.v.vim_did_enter ~= 0 then
        return
      end

      preload(vim.json.encode({
        repo = { owner = "o", repo = "r" },
        pr = { number = 7 },
        review = { worktree = "/tmp/wt", base = "aaa", head = "bbb" },
        files = {},
        root = "/tmp/repo",
      }))
      local before = #vim.api.nvim_list_tabpages()
      gauntlet.open_preload()

      assert.equals(before, #vim.api.nvim_list_tabpages())
      assert.is_truthy(vim.env.GAUNTLET_PRELOAD)
      assert.is_true(#vim.api.nvim_get_autocmds({ group = "GauntletPreload", event = "VimEnter" }) > 0)
    end)

    it("opens the review vig prepared, without preparing it again", function()
      -- vig fetches and checks out the pull request before Neovim starts, so
      -- what arrives is a whole review, not something still to be worked out.
      local path = preload(vim.json.encode({
        repo = { owner = "o", repo = "r" },
        pr = { number = 7, title = "Handed over", author = { login = "loki" }, body = "Body." },
        review = { worktree = "/tmp/wt", base = "aaa", head = "bbb", number = 7 },
        files = { { path = "a.lua", status = "M", additions = 1, deletions = 0 } },
        root = "/tmp/repo",
      }))

      local ui = require("gauntlet.ui")
      local shown, real_review = nil, ui.review
      ui.review = function(ctx)
        shown = ctx
        return {}
      end
      local prepared, real_prepare = false, gauntlet.prepare
      gauntlet.prepare = function()
        prepared = true
      end

      gauntlet._open_preloaded()

      ui.review = real_review
      gauntlet.prepare = real_prepare

      assert.is_false(prepared)
      assert.equals(7, shown.pr.number)
      assert.equals("o", shown.repo.owner)
      assert.equals("bbb", shown.review.head)
      assert.equals("a.lua", shown.files[1].path)

      -- The handover file is ours, and is consumed exactly once...
      assert.equals(0, vim.fn.filereadable(path))
      local tabs = #vim.api.nvim_list_tabpages()
      gauntlet._open_preloaded()
      assert.equals(tabs, #vim.api.nvim_list_tabpages())

      -- ...but the variable stays set, so a config can tell for the whole
      -- session that this Neovim is only here to show a review.
      assert.equals(path, vim.env.GAUNTLET_PRELOAD)
    end)

    it("survives a handover file it cannot parse", function()
      preload("not json at all")
      assert.has_no.errors(function()
        gauntlet._open_preloaded()
      end)
    end)
  end)

  describe("resolve", function()
    it("refuses to run outside a git repository", function()
      local cwd = vim.fn.getcwd()
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, "p")

      vim.cmd.cd(elsewhere)
      local repo, pr, err = gauntlet.resolve("1")
      vim.cmd.cd(cwd)
      vim.fn.delete(elsewhere, "rf")

      assert.is_nil(repo)
      assert.is_nil(pr)
      assert.equals("not inside a git repository", err)
    end)

    it("rejects an argument that is not a pull request", function()
      local repo, pr, err = gauntlet.resolve("nonsense")
      assert.is_nil(repo)
      assert.is_nil(pr)
      assert.is_truthy(err:find("not a pull request", 1, true) or err:find("git repository", 1, true))
    end)
  end)
end)
