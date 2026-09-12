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
    gauntlet.setup({ agent = "codex" })
    assert.equals("codex", gauntlet.config.agent)
    -- untouched defaults survive the merge
    assert.equals("github", gauntlet.config.forge)
    assert.equals("claude", gauntlet.config.known_agents.claude)
  end)

  it("resolves the agent executable", function()
    gauntlet.setup({ agent = "codex" })
    assert.equals("codex", gauntlet.agent_command())

    gauntlet.setup({ agent = "nope" })
    assert.is_nil(gauntlet.agent_command())
  end)

  it("registers the :Gauntlet command", function()
    -- plenary prepends the plugin to 'runtimepath' after startup, so plugin/
    -- is never sourced automatically here; source it the way Neovim would.
    vim.g.loaded_gauntlet = nil
    vim.cmd("runtime plugin/gauntlet.lua")
    assert.is_table(vim.api.nvim_get_commands({})["Gauntlet"])
  end)
end)
