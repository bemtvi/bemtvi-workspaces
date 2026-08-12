-- The templates surface: listing config-dir templates, reading them (fail loud on bad
-- JSON), and merging one into a project's .bemtvi/config.json (create + merge + validate
-- + write). Everything runs against temp dirs, so it is hermetic.

local templates = require("bemtvi-workspaces.templates")

local function write(path, tbl)
  btv.await(btv.fs.write(path, btv.json.encode(tbl)))
end

btv.test.describe("bemtvi-workspaces.templates", function()
  btv.test.it("lists template names, sorted, with .json stripped", function()
    local dir = btv.test.tempdir()
    write(dir .. "/rust.json", { languages = {} })
    write(dir .. "/python.json", { languages = {} })
    btv.await(btv.fs.write(dir .. "/notes.txt", "ignored"))
    btv.test.expect(btv.await(templates.list(dir))).to_equal({ "python", "rust" })
  end)

  btv.test.it("lists nothing for a missing dir", function()
    btv.test.expect(#btv.await(templates.list(btv.test.tempdir() .. "/nope"))).to_be(0)
  end)

  -- "No templates dir" is the one benign case. A dir that EXISTS but can't be read is a
  -- real failure and must surface — reporting it as "no templates" would hide it.
  btv.test.it("surfaces a real readdir failure instead of reporting no templates", function()
    local oexists, oreaddir = btv.fs_local.exists, btv.fs_local.readdir
    btv.fs_local.exists = function()
      return btv.promise.resolve(true)
    end
    btv.fs_local.readdir = function()
      return btv.promise.new(function(_, reject)
        reject({ message = "EACCES" })
      end)
    end
    local caught
    btv.await(templates.list("/anywhere"):catch(function(e)
      caught = e
      return {}
    end))
    btv.fs_local.exists, btv.fs_local.readdir = oexists, oreaddir
    btv.test.expect(caught).never.to_be_nil()
  end)

  btv.test.it("reads templates via the LOCAL seam (so they work in remote sessions)", function()
    -- The config dir is always local to the editor; btv.fs would cross to the daemon, so
    -- EVERY op the listing makes (exists + readdir) must ride btv.fs_local.
    local ofs_exists, ofs_readdir = btv.fs.exists, btv.fs.readdir
    local ofsl_exists, ofsl_readdir = btv.fs_local.exists, btv.fs_local.readdir
    local function remote()
      return btv.promise.new(function(_, reject)
        reject({ message = "templates must not use the remote btv.fs seam" })
      end)
    end
    btv.fs.exists, btv.fs.readdir = remote, remote
    btv.fs_local.exists = function()
      return btv.promise.resolve(true)
    end
    btv.fs_local.readdir = function()
      return btv.promise.resolve({ { name = "only.json", type = "file" } })
    end
    local ok, names = pcall(function()
      return btv.await(templates.list("/anywhere"))
    end)
    btv.fs.exists, btv.fs.readdir = ofs_exists, ofs_readdir
    btv.fs_local.exists, btv.fs_local.readdir = ofsl_exists, ofsl_readdir
    btv.test.expect(ok).to_be_truthy()
    btv.test.expect(names).to_equal({ "only" })
  end)

  btv.test.it("read fails loud on invalid JSON", function()
    local dir = btv.test.tempdir()
    btv.await(btv.fs.write(dir .. "/bad.json", "{ not json"))
    local caught
    btv.await(templates.read("bad", dir):catch(function(e)
      caught = e
      return true
    end))
    btv.test.expect(caught).never.to_be_nil()
  end)

  btv.test.it("add creates the config from a template", function()
    local tdir = btv.test.tempdir()
    write(tdir .. "/py.json", {
      settings = { tabstop = 4 },
      languages = { python = { lsps = { ruff = {} } } },
    })
    local cpath = btv.test.tempdir() .. "/.bemtvi/config.json"

    local path = btv.await(templates.add("py", { dir = tdir, config_path = cpath }))
    btv.test.expect(path).to_be(cpath)

    local w = btv.json.decode(btv.await(btv.fs.read_text(cpath)))
    btv.test.expect(w.settings.tabstop).to_be(4)
    btv.test.expect(w.languages.python.lsps.ruff).never.to_be_nil()
  end)

  btv.test.it("add merges into an existing config (template wins, siblings kept)", function()
    local tdir = btv.test.tempdir()
    write(tdir .. "/extra.json", {
      settings = { number = true },
      languages = { lua = { lsps = { lua_ls = {} } } },
    })
    local cpath = btv.test.tempdir() .. "/config.json"
    write(cpath, { settings = { tabstop = 2 }, languages = { python = { lsps = {} } } })

    btv.await(templates.add("extra", { dir = tdir, config_path = cpath }))

    local w = btv.json.decode(btv.await(btv.fs.read_text(cpath)))
    btv.test.expect(w.settings.tabstop).to_be(2) -- kept
    btv.test.expect(w.settings.number).to_be(true) -- added
    btv.test.expect(w.languages.python).never.to_be_nil() -- kept
    btv.test.expect(w.languages.lua.lsps.lua_ls).never.to_be_nil() -- added
  end)

  -- A deep merge that recursed into lists would splice the template's save_actions over
  -- the existing ones BY INDEX, leaving the old chain's tail behind — a save chain
  -- nobody wrote. A list-valued key replaces wholesale.
  btv.test.it("a template's save_actions replaces the list (no index-merge leftovers)", function()
    local tdir = btv.test.tempdir()
    write(tdir .. "/one.json", {
      languages = { python = { save_actions = { { require = "btv", method = "cmd" } } } },
    })
    local cpath = btv.test.tempdir() .. "/config.json"
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

    btv.await(templates.add("one", { dir = tdir, config_path = cpath }))

    local w = btv.json.decode(btv.await(btv.fs.read_text(cpath)))
    btv.test.expect(#w.languages.python.save_actions).to_be(1)
    btv.test.expect(w.languages.python.save_actions[1].require).to_be("btv")
  end)

  -- `setup` is the one key that ACCUMULATES. Each template carries the preparation its
  -- own language needs, so a project built from several templates has to run all of
  -- them; the plain "template wins" rule would leave it running only the last merged
  -- one, silently dropping the earlier preparations.
  btv.test.it("setup hooks from several templates accumulate into one list", function()
    local tdir = btv.test.tempdir()
    btv.await(btv.fs.write(
      tdir .. "/node.json",
      [[{
        "setup": { "require": "workspace-setup.node", "method": "ensure",
                   "params": ["vscode-langservers-extracted"] },
        "languages": { "javascript": { "lsps": { "eslint": {} } } }
      }]]
    ))
    btv.await(btv.fs.write(
      tdir .. "/python.json",
      [[{
        "setup": { "require": "workspace-setup.python", "method": "venv" },
        "languages": { "python": { "lsps": { "ruff": {} } } }
      }]]
    ))
    local cpath = btv.test.tempdir() .. "/config.json"

    btv.await(templates.add("node", { dir = tdir, config_path = cpath }))
    btv.await(templates.add("python", { dir = tdir, config_path = cpath }))

    local w = btv.json.decode(btv.await(btv.fs.read_text(cpath)))
    -- The merged config always spells `setup` as a list, in merge order.
    btv.test.expect(#w.setup).to_be(2)
    btv.test.expect(w.setup[1].require).to_be("workspace-setup.node")
    btv.test.expect(w.setup[1].method).to_be("ensure")
    btv.test.expect(w.setup[1].params).to_equal({ "vscode-langservers-extracted" })
    btv.test.expect(w.setup[2].require).to_be("workspace-setup.python")
    -- ...and the languages both templates brought are still there.
    btv.test.expect(w.languages.javascript.lsps.eslint).never.to_be_nil()
    btv.test.expect(w.languages.python.lsps.ruff).never.to_be_nil()
  end)

  -- Re-merging a template (or two templates sharing a hook) must not queue the same
  -- preparation twice — it would run `npm install` twice on every load.
  btv.test.it("a repeated setup hook is elided", function()
    local tdir = btv.test.tempdir()
    local hook = [[{ "require": "workspace-setup.node", "method": "ensure",
                     "params": ["vscode-langservers-extracted", "eslint-formatter-visualstudio"] }]]
    btv.await(btv.fs.write(tdir .. "/node.json", '{"setup": ' .. hook .. "}"))
    -- A different template naming the SAME hook, plus one of its own.
    btv.await(
      btv.fs.write(
        tdir .. "/web.json",
        '{"setup": [' .. hook .. ', { "require": "workspace-setup.web", "method": "prepare" }]}'
      )
    )
    local cpath = btv.test.tempdir() .. "/config.json"

    btv.await(templates.add("node", { dir = tdir, config_path = cpath }))
    btv.await(templates.add("node", { dir = tdir, config_path = cpath })) -- again
    btv.await(templates.add("web", { dir = tdir, config_path = cpath }))

    local w = btv.json.decode(btv.await(btv.fs.read_text(cpath)))
    btv.test.expect(#w.setup).to_be(2)
    btv.test.expect(w.setup[1].require).to_be("workspace-setup.node")
    btv.test.expect(w.setup[2].require).to_be("workspace-setup.web")
  end)

  -- Same require+method with DIFFERENT params is a different call — both must survive,
  -- or a template's package list silently disappears.
  btv.test.it("hooks differing only in params are both kept", function()
    local a = { require = "workspace-setup.node", method = "ensure", params = { "pkg-a" } }
    local b = { require = "workspace-setup.node", method = "ensure", params = { "pkg-b" } }
    btv.test.expect(#templates.merge_setup(a, b)).to_be(2)
    btv.test.expect(#templates.merge_setup(a, a)).to_be(1)
    -- Both spellings on either side, and "no hooks at all" stays no hooks.
    btv.test.expect(#templates.merge_setup({ a }, b)).to_be(2)
    btv.test.expect(#templates.merge_setup(nil, nil)).to_be(0)
    btv.test.expect(templates.merge({ x = 1 }, { y = 2 }).setup).to_be_nil()
  end)

  -- A template says `"pylsp": {}` — "this server, default options", the commonest thing
  -- to write. It has to survive decode -> merge -> encode as an OBJECT: an empty Lua
  -- table is equally an empty array, so the merged config was written back with
  -- `"pylsp": []` — a file contradicting the very schema this plugin validates. The
  -- fixture is raw JSON text (not btv.json.encode) so its `{}` is genuinely an object.
  btv.test.it("an empty object in a template stays an object on disk", function()
    local tdir = btv.test.tempdir()
    btv.await(
      btv.fs.write(tdir .. "/py.json", '{"languages":{"python":{"lsps":{"pylsp":{},"ruff":{}}}}}')
    )
    local cpath = btv.test.tempdir() .. "/config.json"

    btv.await(templates.add("py", { dir = tdir, config_path = cpath }))

    local text = btv.await(btv.fs.read_text(cpath))
    btv.test.expect(text:find("%[%s*%]")).to_be_nil()
    local w = btv.json.decode(text)
    btv.test.expect(type(w.languages.python.lsps.pylsp)).to_be("table")
    -- Re-encoding what we just read back is the NEXT :WorkspaceTemplate over this file;
    -- the object must not decay into an array on the second pass either.
    btv.test.expect(btv.json.encode(w)).to_contain('"pylsp":{}')
  end)

  btv.test.it(
    "add fails loud (and writes nothing) on a template that makes the config invalid",
    function()
      local tdir = btv.test.tempdir()
      write(tdir .. "/broken.json", { languages = "not-an-object" })
      local cpath = btv.test.tempdir() .. "/c.json"
      local caught
      btv.await(templates.add("broken", { dir = tdir, config_path = cpath }):catch(function(e)
        caught = e
        return true
      end))
      btv.test.expect(caught).never.to_be_nil()
      btv.test.expect(btv.await(btv.fs.exists(cpath))).to_be_falsy()
    end
  )
end)
