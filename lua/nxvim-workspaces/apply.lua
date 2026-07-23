-- Apply a normalized workspace config onto the running editor.
--
-- Two kinds of effect:
--   * once, at start — the global `settings` block and every language's `lsps`.
--   * per language   — a `FileType` autocmd for its filetypes that applies the
--                      language's buffer-local `settings` and installs the `<C-s>`
--                      save-actions keymap on the matching buffer.

local actions = require("nxvim-workspaces.actions")

local M = {}

-- Apply an option map through `vim.o`, which routes each name to its scope: a global
-- name to the core, a window/buffer name to the CURRENT window/buffer. So the same
-- helper does both duties — global-at-start (the current context is the startup
-- buffer/window) and buffer-local inside a `FileType` autocmd (the current context is
-- the buffer that just got the filetype). An unmodeled name warns-but-stores (the
-- lenient compat surface), never aborts.
local function apply_settings(settings)
  for name, value in pairs(settings) do
    vim.o[name] = value
  end
end
M.apply_settings = apply_settings

-- Register + enable a language's LSP servers. `nx.lsp.enable` also dispatches the
-- CURRENT buffer's filetype, so a server enabled after the file already opened still
-- attaches (which matters here — the config is loaded async, after the first file).
local function apply_lsps(lsps)
  local names = {}
  for name, cfg in pairs(lsps) do
    nx.lsp.config(name, cfg)
    names[#names + 1] = name
  end
  if #names > 0 then
    nx.lsp.enable(names)
  end
end
M.apply_lsps = apply_lsps

-- Apply a full normalized config.
--   opts.save_key   the save-actions keymap (default "<C-s>")
--   opts.group      the augroup for the FileType autocmds (default a fresh, cleared one)
function M.apply(config, opts)
  opts = opts or {}
  local save_key = opts.save_key or "<C-s>"
  local group = opts.group or nx.augroup.create("nxvim-workspaces", { clear = true })

  if config.settings then
    apply_settings(config.settings)
  end

  for _, lang in ipairs(config.languages) do
    apply_lsps(lang.lsps)

    -- Only wire a FileType autocmd when the language actually carries buffer-local
    -- work (settings and/or save actions) — an lsps-only block needs none.
    if lang.settings or #lang.save_actions > 0 then
      local lang_settings = lang.settings
      local save_actions = lang.save_actions
      -- The per-buffer work, shared by the autocmd and the retroactive pass. `bufnr`
      -- is the current buffer at both call sites, so `apply_settings` (via vim.o) and
      -- the buffer-local keymap target the right buffer.
      local function on_buf(bufnr)
        if lang_settings then
          apply_settings(lang_settings)
        end
        if #save_actions > 0 then
          nx.keymap.set("n", save_key, function()
            actions.run_and_write(save_actions)
          end, { buffer = bufnr, desc = "nxvim-workspaces: run save actions + write" })
        end
      end

      nx.autocmd.create("FileType", {
        group = group,
        pattern = lang.filetypes,
        callback = function(a)
          on_buf(a.buf)
        end,
      })

      -- The config loads async, AFTER the launch file's FileType already fired, so the
      -- autocmd we just created won't catch it. Apply to the current buffer on the spot
      -- when it already matches (mirrors `nx.lsp.enable`'s current-buffer dispatch). Its
      -- live filetype is `vim.bo.filetype` (the persistent `nx._cur_buf` mirror lags).
      local cur = nx._cur_buf
      local cur_ft = vim.bo.filetype
      if cur and cur_ft ~= "" and vim.tbl_contains(lang.filetypes, cur_ft) then
        on_buf(cur.bufnr)
      end
    end
  end
end

return M
