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

  it("merges user options into the defaults", function()
    gauntlet.setup({ example = 1 })
    assert.is_true(gauntlet._configured)
    assert.equals(1, gauntlet.config.example)
  end)

  it("sources plugin/gauntlet.lua once", function()
    -- plenary prepends the plugin to 'runtimepath' after startup, so plugin/
    -- is never sourced automatically here; source it the way Neovim would.
    vim.g.loaded_gauntlet = nil
    vim.cmd("runtime plugin/gauntlet.lua")
    assert.is_true(vim.g.loaded_gauntlet)
  end)
end)
