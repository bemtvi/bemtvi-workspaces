-- The templates surface: listing config-dir templates, reading them (fail loud on bad
-- JSON), and merging one into a project's .nxvim/config.json (create + merge + validate
-- + write). Everything runs against temp dirs, so it is hermetic.

local templates = require("nxvim-workspaces.templates")

local function write(path, tbl)
  nx.await(nx.fs.write(path, nx.json.encode(tbl)))
end

nx.test.describe("nxvim-workspaces.templates", function()
  nx.test.it("lists template names, sorted, with .json stripped", function()
    local dir = nx.test.tempdir()
    write(dir .. "/rust.json", { languages = {} })
    write(dir .. "/python.json", { languages = {} })
    nx.await(nx.fs.write(dir .. "/notes.txt", "ignored"))
    nx.test.expect(nx.await(templates.list(dir))).to_equal({ "python", "rust" })
  end)

  nx.test.it("lists nothing for a missing dir", function()
    nx.test.expect(#nx.await(templates.list(nx.test.tempdir() .. "/nope"))).to_be(0)
  end)

  nx.test.it("reads templates via the LOCAL seam (so they work in remote sessions)", function()
    -- The config dir is always local to the editor; nx.fs would cross to the daemon.
    local ofs, ofsl = nx.fs.readdir, nx.fs_local.readdir
    nx.fs.readdir = function()
      return nx.promise.new(function(_, reject)
        reject({ message = "templates must not use the remote nx.fs seam" })
      end)
    end
    nx.fs_local.readdir = function()
      return nx.promise.resolve({ { name = "only.json", type = "file" } })
    end
    local ok, names = pcall(function()
      return nx.await(templates.list("/anywhere"))
    end)
    nx.fs.readdir, nx.fs_local.readdir = ofs, ofsl
    nx.test.expect(ok).to_be_truthy()
    nx.test.expect(names).to_equal({ "only" })
  end)

  nx.test.it("read fails loud on invalid JSON", function()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/bad.json", "{ not json"))
    local caught
    nx.await(templates.read("bad", dir):catch(function(e)
      caught = e
      return true
    end))
    nx.test.expect(caught).never.to_be_nil()
  end)

  nx.test.it("add creates the config from a template", function()
    local tdir = nx.test.tempdir()
    write(tdir .. "/py.json", {
      settings = { tabstop = 4 },
      languages = { python = { lsps = { ruff = {} } } },
    })
    local cpath = nx.test.tempdir() .. "/.nxvim/config.json"

    local path = nx.await(templates.add("py", { dir = tdir, config_path = cpath }))
    nx.test.expect(path).to_be(cpath)

    local w = nx.json.decode(nx.await(nx.fs.read_text(cpath)))
    nx.test.expect(w.settings.tabstop).to_be(4)
    nx.test.expect(w.languages.python.lsps.ruff).never.to_be_nil()
  end)

  nx.test.it("add merges into an existing config (template wins, siblings kept)", function()
    local tdir = nx.test.tempdir()
    write(tdir .. "/extra.json", {
      settings = { number = true },
      languages = { lua = { lsps = { lua_ls = {} } } },
    })
    local cpath = nx.test.tempdir() .. "/config.json"
    write(cpath, { settings = { tabstop = 2 }, languages = { python = { lsps = {} } } })

    nx.await(templates.add("extra", { dir = tdir, config_path = cpath }))

    local w = nx.json.decode(nx.await(nx.fs.read_text(cpath)))
    nx.test.expect(w.settings.tabstop).to_be(2) -- kept
    nx.test.expect(w.settings.number).to_be(true) -- added
    nx.test.expect(w.languages.python).never.to_be_nil() -- kept
    nx.test.expect(w.languages.lua.lsps.lua_ls).never.to_be_nil() -- added
  end)

  nx.test.it(
    "add fails loud (and writes nothing) on a template that makes the config invalid",
    function()
      local tdir = nx.test.tempdir()
      write(tdir .. "/broken.json", { languages = "not-an-object" })
      local cpath = nx.test.tempdir() .. "/c.json"
      local caught
      nx.await(templates.add("broken", { dir = tdir, config_path = cpath }):catch(function(e)
        caught = e
        return true
      end))
      nx.test.expect(caught).never.to_be_nil()
      nx.test.expect(nx.await(nx.fs.exists(cpath))).to_be_falsy()
    end
  )
end)
