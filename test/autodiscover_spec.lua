-- The workspace gate: setup({}) (no explicit path) acts only in a --workspace session,
-- and then discovers `<workspace-root>/.bemtvi/config.json`. A real --workspace launch
-- can't be entered mid-test, so the read-only `btv.workspace` surface is stubbed.

local ws = require("bemtvi-workspaces")

-- Run `fn` with btv.workspace.active()/dir() stubbed to the given values, restoring after.
local function with_workspace(active, dir, fn)
  local oactive, odir = btv.workspace.active, btv.workspace.dir
  btv.workspace.active = function()
    return active
  end
  btv.workspace.dir = function()
    return dir
  end
  local ok, err = pcall(fn)
  btv.workspace.active, btv.workspace.dir = oactive, odir
  if not ok then
    error(err)
  end
end

btv.test.describe("bemtvi-workspaces workspace gate", function()
  btv.test.it("setup({}) is a no-op outside a --workspace session", function()
    local dir = btv.test.tempdir()
    btv.await(btv.fs.mkdir(dir .. "/.bemtvi", { recursive = true }))
    btv.await(
      btv.fs.write(dir .. "/.bemtvi/config.json", btv.json.encode({ settings = { tabstop = 9 } }))
    )

    vim.o.tabstop = 4
    with_workspace(false, dir, function()
      btv.await(ws.setup({ trust = false })) -- no path + not a workspace -> nothing happens
    end)
    btv.test.expect(vim.o.tabstop).to_be(4) -- unchanged
  end)

  btv.test.it("setup({}) in a --workspace session reads <workspace>/.bemtvi/config.json", function()
    local dir = btv.test.tempdir()
    btv.await(btv.fs.mkdir(dir .. "/.bemtvi", { recursive = true }))
    btv.await(
      btv.fs.write(dir .. "/.bemtvi/config.json", btv.json.encode({ settings = { tabstop = 6 } }))
    )

    with_workspace(true, dir, function()
      btv.await(ws.setup({ trust = false }))
    end)
    btv.test.expect(vim.o.tabstop).to_be(6)
  end)
end)
