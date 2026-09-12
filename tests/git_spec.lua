describe("gauntlet.git", function()
  local git = require("gauntlet.git")

  describe("parse_remote", function()
    local cases = {
      ["https://github.com/Loki-Astari/gauntlet.nvim.git"] = { "Loki-Astari", "gauntlet.nvim" },
      ["https://github.com/Loki-Astari/gauntlet.nvim"] = { "Loki-Astari", "gauntlet.nvim" },
      ["git@github.com:Loki-Astari/gauntlet.nvim.git"] = { "Loki-Astari", "gauntlet.nvim" },
      ["ssh://git@github.com/Loki-Astari/gauntlet.nvim.git"] = { "Loki-Astari", "gauntlet.nvim" },
      ["https://token@github.com/Loki-Astari/gauntlet.nvim.git"] = { "Loki-Astari", "gauntlet.nvim" },
    }

    for url, want in pairs(cases) do
      it(("parses %s"):format(url), function()
        local host, owner, repo = git.parse_remote(url)
        assert.equals("github.com", host)
        assert.equals(want[1], owner)
        assert.equals(want[2], repo)
      end)
    end

    it("reports the host of a non-GitHub remote", function()
      local host = git.parse_remote("git@gitlab.com:o/r.git")
      assert.equals("gitlab.com", host)
    end)

    it("returns nothing for a URL it cannot split", function()
      assert.is_nil(git.parse_remote("github.com"))
      assert.is_nil(git.parse_remote(""))
      assert.is_nil(git.parse_remote(nil))
    end)
  end)
end)
