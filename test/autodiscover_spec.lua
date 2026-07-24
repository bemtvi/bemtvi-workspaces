-- The workspace gate: setup({}) (no explicit path) acts only in a --workspace session,
-- and then discovers `<workspace-root>/.nxvim/config.json`. A real --workspace launch
-- can't be entered mid-test, so the read-only `nx.workspace` surface is stubbed.

local ws = require("nxvim-workspaces")

-- Run `fn` with nx.workspace.active()/dir() stubbed to the given values, restoring after.
local function with_workspace(active, dir, fn)
  local oactive, odir = nx.workspace.active, nx.workspace.dir
  nx.workspace.active = function()
    return active
  end
  nx.workspace.dir = function()
    return dir
  end
  local ok, err = pcall(fn)
  nx.workspace.active, nx.workspace.dir = oactive, odir
  if not ok then
    error(err)
  end
end

nx.test.describe("nxvim-workspaces workspace gate", function()
  nx.test.it("setup({}) is a no-op outside a --workspace session", function()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.mkdir(dir .. "/.nxvim", { recursive = true }))
    nx.await(
      nx.fs.write(dir .. "/.nxvim/config.json", nx.json.encode({ settings = { tabstop = 9 } }))
    )

    vim.o.tabstop = 4
    with_workspace(false, dir, function()
      nx.await(ws.setup({ trust = false })) -- no path + not a workspace -> nothing happens
    end)
    nx.test.expect(vim.o.tabstop).to_be(4) -- unchanged
  end)

  nx.test.it("setup({}) in a --workspace session reads <workspace>/.nxvim/config.json", function()
    local dir = nx.test.tempdir()
    nx.await(nx.fs.mkdir(dir .. "/.nxvim", { recursive = true }))
    nx.await(
      nx.fs.write(dir .. "/.nxvim/config.json", nx.json.encode({ settings = { tabstop = 6 } }))
    )

    with_workspace(true, dir, function()
      nx.await(ws.setup({ trust = false }))
    end)
    nx.test.expect(vim.o.tabstop).to_be(6)
  end)
end)
