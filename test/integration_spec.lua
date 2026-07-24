-- End-to-end: setup() reads a real `.nxvim/config.json` off disk (the async nx.fs
-- path), validates it, applies the global settings, and wires each language — proven by
-- firing a filetype and finding the installed <C-s> map. Also covers the missing-file
-- no-op and the loud failures (bad JSON / broken shape).

local ws = require("nxvim-workspaces")
local trust = require("nxvim-workspaces.trust")

-- Write `tbl` as JSON to `<dir>/config.json` and return the path.
local function write_config(dir, tbl)
  local path = dir .. "/config.json"
  nx.await(nx.fs.write(path, nx.json.encode(tbl)))
  return path
end

nx.test.describe("nxvim-workspaces end-to-end", function()
  nx.test.it("loads, applies global settings, and wires a language", function(t)
    local dir = nx.test.tempdir()
    local path = write_config(dir, {
      settings = { tabstop = 6 },
      languages = {
        wsint = {
          save_actions = { { require = "nx", method = "cmd" } },
          settings = { shiftwidth = 2 },
        },
      },
    })

    nx.await(ws.setup({ path = path, trust = false }))

    -- Global settings applied once, at load.
    nx.test.expect(vim.o.tabstop).to_be(6)
    nx.test.expect(ws.config).never.to_be_nil()

    -- Fire the language's filetype; its buffer-local setting + <C-s> map land.
    t:cmd("setfiletype wsint")
    t:feed("", { settle = 1 })
    nx.test.expect(vim.o.shiftwidth).to_be(2)

    local found = false
    for _, m in ipairs(nx.keymap.buf_get(0, "n")) do
      if m.desc == "nxvim-workspaces: run save actions + write" then
        found = true
      end
    end
    nx.test.expect(found).to_be_truthy()
  end)

  nx.test.it("is a silent no-op when the config file is absent", function()
    local dir = nx.test.tempdir()
    local ok = pcall(function()
      nx.await(ws.setup({ path = dir .. "/nope.json", trust = false }))
    end)
    nx.test.expect(ok).to_be_truthy()
  end)

  nx.test.it("fails loud (notify) on invalid JSON", function()
    local dir = nx.test.tempdir()
    local path = dir .. "/broken.json"
    nx.await(nx.fs.write(path, "{ this is not json "))
    local notified
    local onotify = nx.notify
    nx.notify = function(msg)
      notified = msg
    end
    nx.await(ws.setup({ path = path, trust = false }))
    nx.notify = onotify
    nx.test.expect(notified).to_match("nxvim%-workspaces")
  end)

  nx.test.it("runs the async `setup` hook, awaited, before applying the rest", function(t)
    local dir = nx.test.tempdir()
    _G.__ws_probe = nil
    _G.__ws_setup_ran = nil
    package.loaded["ws_setup_mock"] = {
      prepare = function()
        _G.__ws_probe = vim.o.tabstop -- captured BEFORE apply mutates it
        return nx.promise.new(function(resolve)
          nx.on_next_tick(function()
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

    nx.await(ws.setup({ path = path, trust = false }))

    nx.test.expect(_G.__ws_setup_ran).to_be_truthy() -- the hook ran (its promise settled)
    nx.test.expect(_G.__ws_probe).to_be(3) -- the hook saw the pre-apply value
    nx.test.expect(vim.o.tabstop).to_be(8) -- apply ran after the hook
  end)

  nx.test.it("trust gate: applies only when the prompt is accepted", function()
    local dir = nx.test.tempdir()
    local path = write_config(dir, { settings = { tabstop = 7 } })
    local oconfirm = trust.confirm

    -- Decline -> nothing applied (fresh store).
    vim.o.tabstop = 2
    trust.confirm = function()
      return nx.promise.resolve(false)
    end
    nx.await(ws.setup({ path = path, trust_path = dir .. "/deny.json" }))
    nx.test.expect(vim.o.tabstop).to_be(2)

    -- Accept -> applied (separate store, so it re-decides).
    trust.confirm = function()
      return nx.promise.resolve(true)
    end
    nx.await(ws.setup({ path = path, trust_path = dir .. "/allow.json" }))
    trust.confirm = oconfirm
    nx.test.expect(vim.o.tabstop).to_be(7)
  end)

  nx.test.it("registers the :Workspace* commands", function()
    ws._register_commands({})
    nx.test.expect(nx._user_commands["WorkspaceConfig"]).never.to_be_nil()
    nx.test.expect(nx._user_commands["WorkspaceTemplate"]).never.to_be_nil()
    nx.test.expect(nx._user_commands["WorkspaceReload"]).never.to_be_nil()
  end)

  nx.test.it("M.parse fails loud on a broken shape", function()
    nx.test
      .expect(function()
        ws.parse('{ "languages": "not-an-object" }')
      end)
      .to_error("languages")
  end)
end)
