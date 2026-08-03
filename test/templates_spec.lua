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

  -- "No templates dir" is the one benign case. A dir that EXISTS but can't be read is a
  -- real failure and must surface — reporting it as "no templates" would hide it.
  nx.test.it("surfaces a real readdir failure instead of reporting no templates", function()
    local oexists, oreaddir = nx.fs_local.exists, nx.fs_local.readdir
    nx.fs_local.exists = function()
      return nx.promise.resolve(true)
    end
    nx.fs_local.readdir = function()
      return nx.promise.new(function(_, reject)
        reject({ message = "EACCES" })
      end)
    end
    local caught
    nx.await(templates.list("/anywhere"):catch(function(e)
      caught = e
      return {}
    end))
    nx.fs_local.exists, nx.fs_local.readdir = oexists, oreaddir
    nx.test.expect(caught).never.to_be_nil()
  end)

  nx.test.it("reads templates via the LOCAL seam (so they work in remote sessions)", function()
    -- The config dir is always local to the editor; nx.fs would cross to the daemon, so
    -- EVERY op the listing makes (exists + readdir) must ride nx.fs_local.
    local ofs_exists, ofs_readdir = nx.fs.exists, nx.fs.readdir
    local ofsl_exists, ofsl_readdir = nx.fs_local.exists, nx.fs_local.readdir
    local function remote()
      return nx.promise.new(function(_, reject)
        reject({ message = "templates must not use the remote nx.fs seam" })
      end)
    end
    nx.fs.exists, nx.fs.readdir = remote, remote
    nx.fs_local.exists = function()
      return nx.promise.resolve(true)
    end
    nx.fs_local.readdir = function()
      return nx.promise.resolve({ { name = "only.json", type = "file" } })
    end
    local ok, names = pcall(function()
      return nx.await(templates.list("/anywhere"))
    end)
    nx.fs.exists, nx.fs.readdir = ofs_exists, ofs_readdir
    nx.fs_local.exists, nx.fs_local.readdir = ofsl_exists, ofsl_readdir
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

  -- A deep merge that recursed into lists would splice the template's save_actions over
  -- the existing ones BY INDEX, leaving the old chain's tail behind — a save chain
  -- nobody wrote. A list-valued key replaces wholesale.
  nx.test.it("a template's save_actions replaces the list (no index-merge leftovers)", function()
    local tdir = nx.test.tempdir()
    write(tdir .. "/one.json", {
      languages = { python = { save_actions = { { require = "nx", method = "cmd" } } } },
    })
    local cpath = nx.test.tempdir() .. "/config.json"
    write(cpath, {
      languages = {
        python = {
          save_actions = {
            { require = "old_a", method = "x" },
            { require = "old_b", method = "y" },
            { require = "old_c", method = "z" },
          },
        },
      },
    })

    nx.await(templates.add("one", { dir = tdir, config_path = cpath }))

    local w = nx.json.decode(nx.await(nx.fs.read_text(cpath)))
    nx.test.expect(#w.languages.python.save_actions).to_be(1)
    nx.test.expect(w.languages.python.save_actions[1].require).to_be("nx")
  end)

  -- `setup` is the one key that ACCUMULATES. Each template carries the preparation its
  -- own language needs, so a project built from several templates has to run all of
  -- them; the plain "template wins" rule would leave it running only the last merged
  -- one, silently dropping the earlier preparations.
  nx.test.it("setup hooks from several templates accumulate into one list", function()
    local tdir = nx.test.tempdir()
    nx.await(nx.fs.write(
      tdir .. "/node.json",
      [[{
        "setup": { "require": "workspace-setup.node", "method": "ensure",
                   "params": ["vscode-langservers-extracted"] },
        "languages": { "javascript": { "lsps": { "eslint": {} } } }
      }]]
    ))
    nx.await(nx.fs.write(
      tdir .. "/python.json",
      [[{
        "setup": { "require": "workspace-setup.python", "method": "venv" },
        "languages": { "python": { "lsps": { "ruff": {} } } }
      }]]
    ))
    local cpath = nx.test.tempdir() .. "/config.json"

    nx.await(templates.add("node", { dir = tdir, config_path = cpath }))
    nx.await(templates.add("python", { dir = tdir, config_path = cpath }))

    local w = nx.json.decode(nx.await(nx.fs.read_text(cpath)))
    -- The merged config always spells `setup` as a list, in merge order.
    nx.test.expect(#w.setup).to_be(2)
    nx.test.expect(w.setup[1].require).to_be("workspace-setup.node")
    nx.test.expect(w.setup[1].method).to_be("ensure")
    nx.test.expect(w.setup[1].params).to_equal({ "vscode-langservers-extracted" })
    nx.test.expect(w.setup[2].require).to_be("workspace-setup.python")
    -- ...and the languages both templates brought are still there.
    nx.test.expect(w.languages.javascript.lsps.eslint).never.to_be_nil()
    nx.test.expect(w.languages.python.lsps.ruff).never.to_be_nil()
  end)

  -- Re-merging a template (or two templates sharing a hook) must not queue the same
  -- preparation twice — it would run `npm install` twice on every load.
  nx.test.it("a repeated setup hook is elided", function()
    local tdir = nx.test.tempdir()
    local hook = [[{ "require": "workspace-setup.node", "method": "ensure",
                     "params": ["vscode-langservers-extracted", "eslint-formatter-visualstudio"] }]]
    nx.await(nx.fs.write(tdir .. "/node.json", '{"setup": ' .. hook .. "}"))
    -- A different template naming the SAME hook, plus one of its own.
    nx.await(
      nx.fs.write(
        tdir .. "/web.json",
        '{"setup": [' .. hook .. ', { "require": "workspace-setup.web", "method": "prepare" }]}'
      )
    )
    local cpath = nx.test.tempdir() .. "/config.json"

    nx.await(templates.add("node", { dir = tdir, config_path = cpath }))
    nx.await(templates.add("node", { dir = tdir, config_path = cpath })) -- again
    nx.await(templates.add("web", { dir = tdir, config_path = cpath }))

    local w = nx.json.decode(nx.await(nx.fs.read_text(cpath)))
    nx.test.expect(#w.setup).to_be(2)
    nx.test.expect(w.setup[1].require).to_be("workspace-setup.node")
    nx.test.expect(w.setup[2].require).to_be("workspace-setup.web")
  end)

  -- Same require+method with DIFFERENT params is a different call — both must survive,
  -- or a template's package list silently disappears.
  nx.test.it("hooks differing only in params are both kept", function()
    local a = { require = "workspace-setup.node", method = "ensure", params = { "pkg-a" } }
    local b = { require = "workspace-setup.node", method = "ensure", params = { "pkg-b" } }
    nx.test.expect(#templates.merge_setup(a, b)).to_be(2)
    nx.test.expect(#templates.merge_setup(a, a)).to_be(1)
    -- Both spellings on either side, and "no hooks at all" stays no hooks.
    nx.test.expect(#templates.merge_setup({ a }, b)).to_be(2)
    nx.test.expect(#templates.merge_setup(nil, nil)).to_be(0)
    nx.test.expect(templates.merge({ x = 1 }, { y = 2 }).setup).to_be_nil()
  end)

  -- A template says `"pylsp": {}` — "this server, default options", the commonest thing
  -- to write. It has to survive decode -> merge -> encode as an OBJECT: an empty Lua
  -- table is equally an empty array, so the merged config was written back with
  -- `"pylsp": []` — a file contradicting the very schema this plugin validates. The
  -- fixture is raw JSON text (not nx.json.encode) so its `{}` is genuinely an object.
  nx.test.it("an empty object in a template stays an object on disk", function()
    local tdir = nx.test.tempdir()
    nx.await(
      nx.fs.write(tdir .. "/py.json", '{"languages":{"python":{"lsps":{"pylsp":{},"ruff":{}}}}}')
    )
    local cpath = nx.test.tempdir() .. "/config.json"

    nx.await(templates.add("py", { dir = tdir, config_path = cpath }))

    local text = nx.await(nx.fs.read_text(cpath))
    nx.test.expect(text:find("%[%s*%]")).to_be_nil()
    local w = nx.json.decode(text)
    nx.test.expect(type(w.languages.python.lsps.pylsp)).to_be("table")
    -- Re-encoding what we just read back is the NEXT :WorkspaceTemplate over this file;
    -- the object must not decay into an array on the second pass either.
    nx.test.expect(nx.json.encode(w)).to_contain('"pylsp":{}')
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
