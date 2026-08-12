-- End-to-end: setup() reads a real `.bemtvi/config.json` off disk (the async btv.fs
-- path), validates it, applies the global settings, and wires each language — proven by
-- firing a filetype and finding the installed <C-s> map. Also covers the missing-file
-- no-op and the loud failures (bad JSON / broken shape).

local ws = require("bemtvi-workspaces")
local trust = require("bemtvi-workspaces.trust")

-- Write `tbl` as JSON to `<dir>/config.json` and return the path.
local function write_config(dir, tbl)
  local path = dir .. "/config.json"
  btv.await(btv.fs.write(path, btv.json.encode(tbl)))
  return path
end

btv.test.describe("bemtvi-workspaces end-to-end", function()
  btv.test.it("loads, applies global settings, and wires a language", function(t)
    local dir = btv.test.tempdir()
    local path = write_config(dir, {
      settings = { tabstop = 6 },
      languages = {
        wsint = {
          save_actions = { { require = "btv", method = "cmd" } },
          settings = { shiftwidth = 2 },
        },
      },
    })

    btv.await(ws.setup({ path = path, trust = false }))

    -- Global settings applied once, at load.
    btv.test.expect(vim.o.tabstop).to_be(6)
    btv.test.expect(ws.config).never.to_be_nil()

    -- Fire the language's filetype; its buffer-local setting + <C-s> map land.
    t:cmd("setfiletype wsint")
    t:feed("", { settle = 1 })
    btv.test.expect(vim.o.shiftwidth).to_be(2)

    local found = false
    for _, m in ipairs(btv.keymap.buf_get(0, "n")) do
      if m.desc == "bemtvi-workspaces: run save actions + write" then
        found = true
      end
    end
    btv.test.expect(found).to_be_truthy()
  end)

  btv.test.it("is a silent no-op when the config file is absent", function()
    local dir = btv.test.tempdir()
    local ok = pcall(function()
      btv.await(ws.setup({ path = dir .. "/nope.json", trust = false }))
    end)
    btv.test.expect(ok).to_be_truthy()
  end)

  btv.test.it("fails loud (notify) on invalid JSON", function()
    local dir = btv.test.tempdir()
    local path = dir .. "/broken.json"
    btv.await(btv.fs.write(path, "{ this is not json "))
    local notified
    local onotify = btv.notify
    btv.notify = function(msg)
      notified = msg
    end
    btv.await(ws.setup({ path = path, trust = false }))
    btv.notify = onotify
    btv.test.expect(notified).to_match("bemtvi%-workspaces")
  end)

  btv.test.it("runs the async `setup` hook, awaited, before applying the rest", function(t)
    local dir = btv.test.tempdir()
    _G.__ws_probe = nil
    _G.__ws_setup_ran = nil
    package.loaded["ws_setup_mock"] = {
      prepare = function()
        _G.__ws_probe = vim.o.tabstop -- captured BEFORE apply mutates it
        return btv.promise.new(function(resolve)
          btv.on_next_tick(function()
            _G.__ws_setup_ran = true
            resolve(true)
          end)
        end)
      end,
    }
    vim.o.tabstop = 3
    local path = write_config(dir, {
      setup = { require = "ws_setup_mock", method = "prepare" },
      settings = { tabstop = 8 },
    })

    btv.await(ws.setup({ path = path, trust = false }))

    btv.test.expect(_G.__ws_setup_ran).to_be_truthy() -- the hook ran (its promise settled)
    btv.test.expect(_G.__ws_probe).to_be(3) -- the hook saw the pre-apply value
    btv.test.expect(vim.o.tabstop).to_be(8) -- apply ran after the hook
  end)

  -- Several hooks, run STRICTLY in turn: each one's promise settles before the next
  -- starts, so a hook may consume what the one before it produced. If they were merely
  -- kicked off in a loop, hook 2 would run while hook 1's async work was still pending
  -- and the recorded order would interleave — which is what `order` catches.
  btv.test.it("runs an ARRAY of `setup` hooks in order, awaiting each", function()
    local dir = btv.test.tempdir()
    local order = {}
    -- Each hook resolves only on a LATER tick, so "started" and "finished" can interleave
    -- unless the runner really awaits between them.
    local function hook(name)
      return function()
        order[#order + 1] = name .. ":start"
        return btv.promise.new(function(resolve)
          btv.on_next_tick(function()
            order[#order + 1] = name .. ":done"
            resolve(true)
          end)
        end)
      end
    end
    package.loaded["ws_chain_mock"] = { one = hook("one"), two = hook("two") }
    -- A hook may also be a plain synchronous function; it must take its turn too.
    package.loaded["ws_chain_mock"].three = function()
      order[#order + 1] = "three:sync"
    end

    local path = write_config(dir, {
      setup = {
        { require = "ws_chain_mock", method = "one" },
        { require = "ws_chain_mock", method = "two" },
        { require = "ws_chain_mock", method = "three" },
      },
      settings = { tabstop = 7 },
    })

    btv.await(ws.setup({ path = path, trust = false }))

    btv.test
      .expect(order)
      .to_equal({ "one:start", "one:done", "two:start", "two:done", "three:sync" })
    btv.test.expect(vim.o.tabstop).to_be(7) -- and the apply waited for all of them
  end)

  -- A hook that fails aborts the apply: the hooks after it do not run, and the config's
  -- settings are never applied over a workspace whose preparation failed.
  btv.test.it("a failing `setup` hook stops the chain and the apply", function()
    local dir = btv.test.tempdir()
    local ran = {}
    package.loaded["ws_fail_mock"] = {
      boom = function()
        ran[#ran + 1] = "boom"
        error("hook exploded", 0)
      end,
      after = function()
        ran[#ran + 1] = "after"
      end,
    }
    vim.o.tabstop = 5
    local path = write_config(dir, {
      setup = {
        { require = "ws_fail_mock", method = "boom" },
        { require = "ws_fail_mock", method = "after" },
      },
      settings = { tabstop = 9 },
    })

    local onotify = btv.notify
    btv.notify = function() end
    local status = btv.await(ws.setup({ path = path, trust = false }))
    btv.notify = onotify

    btv.test.expect(status).to_be("error")
    btv.test.expect(ran).to_equal({ "boom" }) -- the second hook never started
    btv.test.expect(vim.o.tabstop).to_be(5) -- and nothing was applied
  end)

  btv.test.it("trust gate: applies only when the prompt is accepted", function()
    local dir = btv.test.tempdir()
    local path = write_config(dir, { settings = { tabstop = 7 } })
    local oconfirm = trust.confirm

    -- Decline -> nothing applied (fresh store).
    vim.o.tabstop = 2
    trust.confirm = function()
      return btv.promise.resolve(false)
    end
    btv.await(ws.setup({ path = path, trust_dir = dir .. "/deny" }))
    btv.test.expect(vim.o.tabstop).to_be(2)

    -- Accept -> applied (separate store, so it re-decides).
    trust.confirm = function()
      return btv.promise.resolve(true)
    end
    btv.await(ws.setup({ path = path, trust_dir = dir .. "/allow" }))
    trust.confirm = oconfirm
    btv.test.expect(vim.o.tabstop).to_be(7)
  end)

  -- load() resolves WHAT happened, so :WorkspaceReload can report the truth instead of
  -- claiming "reloaded" over a missing / declined / broken config.
  btv.test.it("load resolves its outcome (missing / applied / untrusted / error)", function()
    local dir = btv.test.tempdir()

    btv.test
      .expect(btv.await(ws.load({ path = dir .. "/nope.json", trust = false })))
      .to_be("missing")

    local path = write_config(dir, { settings = { tabstop = 5 } })
    btv.test.expect(btv.await(ws.load({ path = path, trust = false }))).to_be("applied")

    local oconfirm = trust.confirm
    trust.confirm = function()
      return btv.promise.resolve(false)
    end
    local onotify = btv.notify
    btv.notify = function() end
    local denied = btv.await(ws.load({ path = path, trust_dir = dir .. "/deny-status" }))
    btv.await(btv.fs.write(dir .. "/bad.json", "{ not json"))
    local broken = btv.await(ws.load({ path = dir .. "/bad.json", trust = false }))
    btv.notify = onotify
    trust.confirm = oconfirm

    btv.test.expect(denied).to_be("untrusted")
    btv.test.expect(broken).to_be("error")
  end)

  btv.test.it("registers the :Workspace* commands", function()
    ws._register_commands({})
    btv.test.expect(btv._user_commands["WorkspaceConfig"]).never.to_be_nil()
    btv.test.expect(btv._user_commands["WorkspaceTemplate"]).never.to_be_nil()
    btv.test.expect(btv._user_commands["WorkspaceReload"]).never.to_be_nil()
  end)

  -- :WorkspaceConfig is typically fired from wherever focus happens to be — a file
  -- tree, a sidebar, any dock. The config must land in the MAIN editing area, never
  -- replace the dock's own content (which `:edit` would do).
  btv.test.it(":WorkspaceConfig opens the config in the main layer, not the dock", function(t)
    local dir = btv.test.tempdir()
    local path = write_config(dir, { settings = {} })
    ws._register_commands({ path = path, trust = false })

    -- Open + focus a left dock, the way a tree plugin's keymap would.
    t:exec(function()
      btv.dock.open({ side = "left", size = 30 })
    end)
    t:feed("", { settle = 1 })
    local dock_win = btv.win.current()
    local dock_buf = btv.win.buf(dock_win)

    t:cmd("WorkspaceConfig")
    t:wait_for(function()
      return btv.buf.name(btv.buf.current()) == path
    end, { message = "config.json never opened" })

    -- The config is up, but NOT inside the dock: focus crossed to the main layer and
    -- the dock still shows its own buffer.
    btv.test.expect(btv.win.current()).never.to_be(dock_win)
    btv.test.expect(btv.win.buf(dock_win)).to_be(dock_buf)
  end)

  -- The skeleton :WorkspaceConfig writes for a project that has none must be the shape
  -- the schema describes: `languages` and `settings` are OBJECTS. A bare `{}` encodes as
  -- `[]`, so the file the plugin creates for you started out contradicting its own
  -- schema — and a config editor / JSON-schema validator flags it before you type a key.
  btv.test.it(":WorkspaceConfig creates a skeleton whose empty keys are objects", function(t)
    local path = btv.test.tempdir() .. "/.bemtvi/config.json"
    ws._register_commands({ path = path, trust = false })

    -- The command opens the file once it has written it, so the buffer landing is the
    -- signal that the write completed (the predicate itself cannot await).
    t:cmd("WorkspaceConfig")
    t:wait_for(function()
      return btv.buf.name(btv.buf.current()) == path
    end, { message = "skeleton never created" })

    local text = btv.await(btv.fs.read_text(path))
    btv.test.expect(text:find("%[%s*%]")).to_be_nil()
    btv.test.expect(text).to_contain("{}")
    -- And it still parses as the empty config it means.
    local decoded = btv.json.decode(text)
    btv.test.expect(next(decoded.languages)).to_be_nil()
    btv.test.expect(next(decoded.settings)).to_be_nil()
  end)

  -- Same for the template merge, which opens the merged config when it lands.
  btv.test.it(":WorkspaceTemplate opens the merged config in the main layer", function(t)
    local dir = btv.test.tempdir()
    local tpl_dir = btv.test.tempdir()
    local path = dir .. "/config.json"
    btv.await(btv.fs.write(tpl_dir .. "/rusty.json", btv.json.encode({ settings = { tabstop = 3 } })))
    ws._register_commands({ path = path, templates_dir = tpl_dir, trust = false })

    t:exec(function()
      btv.dock.open({ side = "left", size = 30 })
    end)
    t:feed("", { settle = 1 })
    local dock_win = btv.win.current()
    local dock_buf = btv.win.buf(dock_win)

    t:cmd("WorkspaceTemplate rusty")
    t:wait_for(function()
      return btv.buf.name(btv.buf.current()) == path
    end, { message = "merged config never opened" })

    btv.test.expect(btv.win.current()).never.to_be(dock_win)
    btv.test.expect(btv.win.buf(dock_win)).to_be(dock_buf)
  end)

  btv.test.it("M.parse fails loud on a broken shape", function()
    btv.test
      .expect(function()
        ws.parse('{ "languages": "not-an-object" }')
      end)
      .to_error("languages")
  end)
end)
