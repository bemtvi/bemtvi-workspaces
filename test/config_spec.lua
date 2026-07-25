-- The config surface: normalization of the decoded JSON into the canonical shape, and
-- the LOUD validation that rejects any shape the plugin can't honor. Pure logic — no
-- editor state — so these are plain (non-driving) assertions.

local config = require("nxvim-workspaces.config")

nx.test.describe("nxvim-workspaces.config.is_array", function()
  nx.test.it("treats an empty table as an array (ambiguous [] / {})", function()
    nx.test.expect(config.is_array({})).to_be_truthy()
  end)
  nx.test.it("accepts a 1..n keyed list", function()
    nx.test.expect(config.is_array({ "a", "b" })).to_be_truthy()
  end)
  nx.test.it("rejects a string-keyed object", function()
    nx.test.expect(config.is_array({ foo = 1 })).to_be_falsy()
  end)
end)

nx.test.describe("nxvim-workspaces.config.split_filetypes", function()
  nx.test.it("splits a comma key and trims whitespace", function()
    nx.test.expect(config.split_filetypes("js, html ,vue")).to_equal({ "js", "html", "vue" })
  end)
  nx.test.it("returns a single filetype for a bare key", function()
    nx.test.expect(config.split_filetypes("python")).to_equal({ "python" })
  end)
end)

nx.test.describe("nxvim-workspaces.config.normalize", function()
  nx.test.it("normalizes a full config", function()
    local n = config.normalize({
      settings = { number = true },
      languages = {
        python = {
          lsps = { ruff = {}, basedpyright = { settings = { x = 1 } } },
          save_actions = {
            { require = "nx.lsp.buf", method = "format", params = { name = "ruff" } },
          },
          settings = { tabstop = 4 },
        },
        ["js,html"] = { lsps = { ts_ls = {} } },
      },
    })
    nx.test.expect(n.settings.number).to_be(true)
    nx.test.expect(#n.languages).to_be(2)

    -- pairs() order over the languages map is unspecified — locate each by filetype.
    local py, web
    for _, l in ipairs(n.languages) do
      if l.filetypes[1] == "python" then
        py = l
      else
        web = l
      end
    end
    nx.test.expect(py.filetypes).to_equal({ "python" })
    nx.test.expect(py.settings.tabstop).to_be(4)
    nx.test.expect(#py.save_actions).to_be(1)
    nx.test.expect(py.save_actions[1].require).to_be("nx.lsp.buf")
    nx.test.expect(py.save_actions[1].method).to_be("format")
    nx.test.expect(py.save_actions[1].params.name).to_be("ruff")
    nx.test.expect(py.lsps.basedpyright.settings.x).to_be(1)
    nx.test.expect(web.filetypes).to_equal({ "js", "html" })
    nx.test.expect(#web.save_actions).to_be(0)
    nx.test.expect(#n.warnings).to_be(0)
  end)

  nx.test.it("tolerates an empty config", function()
    local n = config.normalize({})
    nx.test.expect(n.settings).to_be_nil()
    nx.test.expect(#n.languages).to_be(0)
  end)

  nx.test.it("warns (never errors) on unknown keys", function()
    local n = config.normalize({ bogus = 1, languages = { lua = { junk = true } } })
    nx.test.expect(#n.warnings).to_be(2)
  end)

  -- Two blocks claiming one filetype is a config mistake with a silent outcome (both
  -- install a save map on the same buffer, last write wins), so it is worth a warning.
  nx.test.it("warns when two language blocks claim the same filetype", function()
    local n = config.normalize({
      languages = { python = { lsps = {} }, ["python,toml"] = { lsps = {} } },
    })
    nx.test.expect(#n.warnings).to_be(1)
    nx.test.expect(n.warnings[1]).to_match("python")
  end)

  nx.test.it("normalizes a top-level `setup` hook", function()
    local n = config.normalize({
      setup = { require = "mymod", method = "prepare", params = { a = 1 } },
      settings = { number = true },
    })
    nx.test.expect(n.setup.require).to_be("mymod")
    nx.test.expect(n.setup.method).to_be("prepare")
    nx.test.expect(n.setup.params.a).to_be(1)
    nx.test.expect(#n.warnings).to_be(0)
  end)
  nx.test.it("fails loud when `setup` lacks a method", function()
    nx.test
      .expect(function()
        config.normalize({ setup = { require = "x" } })
      end)
      .to_error("method")
  end)

  nx.test.it("fails loud on a non-object root", function()
    nx.test
      .expect(function()
        config.normalize({ 1, 2, 3 })
      end)
      .to_error("object")
  end)
  nx.test.it("fails loud when `languages` is not an object", function()
    nx.test
      .expect(function()
        config.normalize({ languages = "x" })
      end)
      .to_error("languages")
  end)
  nx.test.it("fails loud when a language block is not an object", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = 3 } })
      end)
      .to_error("must be an object")
  end)
  nx.test.it("fails loud when a language key names no filetypes", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { [" , "] = {} } })
      end)
      .to_error("no filetypes")
  end)
  nx.test.it("fails loud when `lsps` is not an object", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = { lsps = 5 } } })
      end)
      .to_error("`lsps`")
  end)
  nx.test.it("fails loud when an lsp config is not an object", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = { lsps = { ruff = 1 } } } })
      end)
      .to_error("config must be an object")
  end)
  nx.test.it("fails loud when `save_actions` is an object, not an array", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = { save_actions = { foo = 1 } } } })
      end)
      .to_error("array")
  end)
  nx.test.it("fails loud when a save_action lacks `require`", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = { save_actions = { { method = "x" } } } } })
      end)
      .to_error("require")
  end)
  nx.test.it("fails loud when a save_action lacks `method`", function()
    nx.test
      .expect(function()
        config.normalize({ languages = { python = { save_actions = { { require = "x" } } } } })
      end)
      .to_error("method")
  end)
  nx.test.it("fails loud when top-level `settings` is not an object", function()
    nx.test
      .expect(function()
        config.normalize({ settings = 7 })
      end)
      .to_error("settings")
  end)
end)
