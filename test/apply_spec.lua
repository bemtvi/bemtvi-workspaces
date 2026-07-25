-- The applier: settings land through vim.o, lsps get configured + enabled, and a
-- language with buffer-local work installs a FileType autocmd that (when the filetype
-- settles) applies its settings and the <C-s> save-actions keymap on that buffer.

local apply = require("nxvim-workspaces.apply")

local DESC = "nxvim-workspaces: run save actions + write"

-- The lhs of every save map this plugin installed on `bufnr`.
local function save_maps(bufnr)
  local lhss = {}
  for _, m in ipairs(nx.keymap.buf_get(bufnr, "n")) do
    if m.desc == DESC then
      lhss[#lhss + 1] = m.lhs
    end
  end
  return lhss
end

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
    nx.test.expect(save_maps(0)).to_equal({ "<C-s>" })
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
    nx.test.expect(save_maps(0)).to_equal({ "<C-s>" })
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

  -- A --workspace session restores a whole layout, so several buffers of a language are
  -- already loaded when the (async) config lands. The catch-up pass must reach all of
  -- them — and each one's buffer-local settings must land on THAT buffer, not on
  -- whichever happens to be current.
  nx.test.it("catches up EVERY loaded buffer of the filetype, not just the current one", function(t)
    local d = nx.test.tempdir()
    nx.await(nx.fs.write(d .. "/a.txt", "a\n"))
    nx.await(nx.fs.write(d .. "/b.txt", "b\n"))
    t:cmd("edit " .. d .. "/a.txt")
    t:cmd("setfiletype wsmulti")
    local first = nx.buf.current()
    t:cmd("edit " .. d .. "/b.txt")
    t:cmd("setfiletype wsmulti")
    local second = nx.buf.current()
    t:feed("", { settle = 1 })
    nx.test.expect(first).never.to_be(second)

    apply.apply({
      settings = nil,
      languages = {
        {
          filetypes = { "wsmulti" },
          lsps = {},
          settings = { shiftwidth = 5 },
          save_actions = { { require = "nx", method = "cmd" } },
        },
      },
    }, { group = nx.augroup.create("ws-apply-multi", { clear = true }) })

    for _, b in ipairs({ first, second }) do
      nx.test.expect(nx.bo[b].shiftwidth).to_be(5)
      nx.test.expect(save_maps(b)).to_equal({ "<C-s>" })
    end
  end)

  -- :WorkspaceReload re-applies onto buffers that already carry the previous apply's
  -- map. Installing a second one would stack (both fire), and a changed save_key would
  -- leave the old key still bound — so a re-apply must clear what it installed before.
  nx.test.it("re-applying replaces its save map instead of stacking it", function(t)
    t:cmd("setfiletype wsreapply")
    t:feed("", { settle = 1 })
    local function cfg()
      return {
        settings = nil,
        languages = {
          {
            filetypes = { "wsreapply" },
            lsps = {},
            settings = nil,
            save_actions = { { require = "nx", method = "cmd" } },
          },
        },
      }
    end
    apply.apply(cfg(), {
      save_key = "<F6>",
      group = nx.augroup.create("ws-apply-reload", { clear = true }),
    })
    nx.test.expect(save_maps(0)).to_equal({ "<F6>" })

    apply.apply(cfg(), {
      save_key = "<F7>",
      group = nx.augroup.create("ws-apply-reload", { clear = true }),
    })
    -- Exactly one map, on the NEW key: the <F6> map from the first apply is gone.
    nx.test.expect(save_maps(0)).to_equal({ "<F7>" })
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
