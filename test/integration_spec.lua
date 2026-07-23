-- End-to-end: setup() reads a real `.nxvim/config.json` off disk (the async nx.fs
-- path), validates it, applies the global settings, and wires each language — proven by
-- firing a filetype and finding the installed <C-s> map. Also covers the missing-file
-- no-op and the loud failures (bad JSON / broken shape).

local ws = require("nxvim-workspaces")

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

    nx.await(ws.setup({ path = path }))

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
      nx.await(ws.setup({ path = dir .. "/nope.json" }))
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
    nx.await(ws.setup({ path = path }))
    nx.notify = onotify
    nx.test.expect(notified).to_match("nxvim%-workspaces")
  end)

  nx.test.it("M.parse fails loud on a broken shape", function()
    nx.test
      .expect(function()
        ws.parse('{ "languages": "not-an-object" }')
      end)
      .to_error("languages")
  end)
end)
