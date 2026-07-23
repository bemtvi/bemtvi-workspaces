-- The zero-config path: the plugin entry (plugin/nxvim-workspaces.lua) auto-runs
-- setup({}) with no path, which discovers `<cwd>/.nxvim/config.json`. Verified
-- hermetically by cd-ing into a temp dir that holds one.

nx.test.describe("nxvim-workspaces auto-discovery", function()
  nx.test.it("setup() with no path reads <cwd>/.nxvim/config.json", function(t)
    local dir = nx.test.tempdir()
    nx.await(nx.fs.mkdir(dir .. "/.nxvim", { recursive = true }))
    nx.await(
      nx.fs.write(dir .. "/.nxvim/config.json", nx.json.encode({ settings = { tabstop = 4 } }))
    )

    local old = vim.fn.getcwd()
    t:cmd("cd " .. dir)
    nx.await(require("nxvim-workspaces").setup({}))
    t:cmd("cd " .. old)

    nx.test.expect(vim.o.tabstop).to_be(4)
  end)
end)
