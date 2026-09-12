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
