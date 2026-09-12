describe("gauntlet.parse", function()
  local parse = require("gauntlet.parse")

  it("accepts a bare pull request number", function()
    local target = assert(parse.target("142"))
    assert.equals(142, target.number)
    assert.is_nil(target.owner)
  end)

  it("accepts a hash-prefixed number", function()
    assert.equals(142, assert(parse.target("#142")).number)
  end)

  it("ignores surrounding whitespace", function()
    assert.equals(7, assert(parse.target("  7 ")).number)
  end)

  it("accepts a pull request URL and keeps the repository", function()
    local target = assert(parse.target("https://github.com/Loki-Astari/gauntlet.nvim/pull/9"))
    assert.equals(9, target.number)
    assert.equals("Loki-Astari", target.owner)
    assert.equals("gauntlet.nvim", target.repo)
  end)

  it("accepts a URL with a trailing path", function()
    local target = assert(parse.target("https://github.com/neovim/neovim/pull/41871/files"))
    assert.equals(41871, target.number)
    assert.equals("neovim", target.owner)
  end)

  for _, bad in ipairs({
    "",
    "   ",
    "not-a-pr",
    "12a",
    "https://gitlab.com/o/r/pull/1",
    "https://github.com/o/r/issues/1",
  }) do
    it(("rejects %q"):format(bad), function()
      local target, err = parse.target(bad)
      assert.is_nil(target)
      assert.is_string(err)
    end)
  end

  it("rejects a missing argument", function()
    assert.is_nil(parse.target(nil))
  end)
end)
