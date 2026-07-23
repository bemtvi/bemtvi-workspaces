-- The applier: settings land through vim.o, lsps get configured + enabled, and a
-- language with buffer-local work installs a FileType autocmd that (when the filetype
-- settles) applies its settings and the <C-s> save-actions keymap on that buffer.

local apply = require("nxvim-workspaces.apply")

nx.test.describe("nxvim-workspaces.apply.apply_settings", function()
  nx.test.it("applies options through vim.o (scope-routed)", function()
    apply.apply_settings({ tabstop = 7 })
    nx.test.expect(vim.o.tabstop).to_be(7)
  end)
end)

nx.test.describe("nxvim-workspaces.apply.apply_lsps", function()
  nx.test.it("configures and enables each server", function()
    apply.apply_lsps({ ws_fake_server = { cmd = { "true" }, filetypes = { "ws_no_such_ft" } } })
    nx.test.expect(nx.lsp._enabled.ws_fake_server).to_be(true)
  end)
end)

nx.test.describe("nxvim-workspaces.apply.apply", function()
  nx.test.it("applies the global settings block once", function()
    apply.apply({
      settings = { tabstop = 5 },
      languages = {},
    }, { group = nx.augroup.create("ws-apply-globals", { clear = true }) })
    nx.test.expect(vim.o.tabstop).to_be(5)
  end)

  nx.test.it("installs the <C-s> save map on a matching buffer via FileType", function(t)
    apply.apply({
      settings = nil,
      languages = {
        {
          filetypes = { "wsfake" },
          lsps = {},
          settings = { tabstop = 3 },
          save_actions = { { require = "nx", method = "cmd" } },
        },
      },
    }, { group = nx.augroup.create("ws-apply-ft", { clear = true }) })

    -- Fire FileType on the current buffer, then let the autocmd settle.
    t:cmd("setfiletype wsfake")
    t:feed("", { settle = 1 })

    -- The per-language buffer-local setting was applied.
    nx.test.expect(vim.o.tabstop).to_be(3)

    -- A buffer-local <C-s> map with our description now exists on this buffer.
    local maps = nx.keymap.buf_get(0, "n")
    local found = false
    for _, m in ipairs(maps) do
      if m.desc == "nxvim-workspaces: run save actions + write" then
        found = true
      end
    end
    nx.test.expect(found).to_be_truthy()
  end)

  nx.test.it("applies retroactively to a buffer that already has the filetype", function(t)
    -- The launch file's FileType fires BEFORE the async config load — set the filetype
    -- first, then apply, and the map/settings must still land on this buffer.
    t:cmd("setfiletype wsretro")
    t:feed("", { settle = 1 })
    apply.apply({
      settings = nil,
      languages = {
        {
          filetypes = { "wsretro" },
          lsps = {},
          settings = { shiftwidth = 9 },
          save_actions = { { require = "nx", method = "cmd" } },
        },
      },
    }, { group = nx.augroup.create("ws-apply-retro", { clear = true }) })

    nx.test.expect(vim.o.shiftwidth).to_be(9)
    local found = false
    for _, m in ipairs(nx.keymap.buf_get(0, "n")) do
      if m.desc == "nxvim-workspaces: run save actions + write" then
        found = true
      end
    end
    nx.test.expect(found).to_be_truthy()
  end)

  nx.test.it("binds the configured save_key instead of <C-s>", function(t)
    apply.apply({
      settings = nil,
      languages = {
        {
          filetypes = { "wskey" },
          lsps = {},
          settings = nil,
          save_actions = { { require = "nx", method = "cmd" } },
        },
      },
    }, { save_key = "<F2>", group = nx.augroup.create("ws-apply-key", { clear = true }) })

    t:cmd("setfiletype wskey")
    t:feed("", { settle = 1 })

    local lhs
    for _, m in ipairs(nx.keymap.buf_get(0, "n")) do
      if m.desc == "nxvim-workspaces: run save actions + write" then
        lhs = m.lhs
      end
    end
    nx.test.expect(lhs).to_be("<F2>")
  end)

  nx.test.it("installs no FileType autocmd for an lsps-only language", function(t)
    local before = #nx.autocmd.get({ event = "FileType" })
    apply.apply({
      settings = nil,
      languages = {
        { filetypes = { "wsonlylsp" }, lsps = {}, save_actions = {}, settings = nil },
      },
    }, { group = nx.augroup.create("ws-apply-lspsonly", { clear = true }) })
    nx.test.expect(#nx.autocmd.get({ event = "FileType" })).to_be(before)
  end)
end)
