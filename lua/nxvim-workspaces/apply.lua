-- Apply a normalized workspace config onto the running editor.
--
-- Two kinds of effect:
--   * once, at start — the global `settings` block and every language's `lsps`.
--   * per language   — a `FileType` autocmd for its filetypes that applies the
--                      language's buffer-local `settings` and installs the `<C-s>`
--                      save-actions keymap on the matching buffer.
--
-- Two things make it correct when it runs LATE, which it always does — the config is
-- read async, so every file already open has had its `FileType` fire:
--   * a CATCH-UP pass over the whole buffer list, so each already-loaded buffer of a
--     language gets its settings + map (a --workspace session restores a full layout,
--     so this is the common case, not the edge one);
--   * per-buffer targeting via `nx.buf.call` — both the autocmd and the catch-up hand
--     us a buffer that need not be the current one, and `vim.o` routes to whatever is
--     current, so the target buffer is installed as the context first.
--
-- Re-applying (`:WorkspaceReload`) is idempotent: the augroup is cleared, and the save
-- maps this module installed are removed before new ones go in, so keys don't stack and
-- a changed `save_key` doesn't strand the old binding.

local actions = require("nxvim-workspaces.actions")

local M = {}

M.SAVE_MAP_DESC = "nxvim-workspaces: run save actions + write"

-- The save maps THIS plugin installed, `{ [bufnr] = { [lhs] = true } }`. A re-apply
-- (`:WorkspaceReload`) revisits buffers that already carry the previous apply's map;
-- without this, a second map would stack on the same key (both fire) and a changed
-- `save_key` would leave the old one still bound. Only maps recorded here are removed,
-- so a `<C-s>` the user mapped themselves is never touched.
M._installed = {}

-- Apply an option map through `vim.o`, which routes each name to its scope: a global
-- name to the core, a window/buffer name to the CURRENT window/buffer. So the same
-- helper does both duties — global-at-start (the current context is the startup
-- buffer/window) and buffer-local for a language (the caller installs the target buffer
-- as the current context first; see `on_buf`). An unmodeled name warns-but-stores (the
-- lenient compat surface), never aborts.
local function apply_settings(settings)
  for name, value in pairs(settings) do
    vim.o[name] = value
  end
end
M.apply_settings = apply_settings

-- Register a set of LSP servers, returning their names. Kept separate from enabling
-- because registration is per-name and CUMULATIVE (`nx.lsp.config` deep-merges over
-- what is already registered), so two language blocks naming one server each contribute
-- their settings — while enabling is better done once for the whole config (below).
local function config_lsps(lsps)
  local names = {}
  for name, cfg in pairs(lsps) do
    nx.lsp.config(name, cfg)
    names[#names + 1] = name
  end
  return names
end

-- Register + enable a language's LSP servers. `nx.lsp.enable` also dispatches the
-- CURRENT buffer's filetype, so a server enabled after the file already opened still
-- attaches (which matters here — the config is loaded async, after the first file).
local function apply_lsps(lsps)
  local names = config_lsps(lsps)
  if #names > 0 then
    nx.lsp.enable(names)
  end
end
M.apply_lsps = apply_lsps

-- Drop every save map a previous apply installed, so this one starts from a clean slate
-- (no stacking, no orphaned binding when `save_key` changes or a language goes away).
local function clear_installed_maps()
  for bufnr, lhss in pairs(M._installed) do
    if nx.buf.is_valid(bufnr) then
      for lhs in pairs(lhss) do
        pcall(nx.keymap.buf_del, bufnr, "n", lhs)
      end
    end
  end
  M._installed = {}
end

-- Apply a full normalized config.
--   opts.save_key   the save-actions keymap (default "<C-s>")
--   opts.group      the augroup for the FileType autocmds (default a fresh, cleared one)
function M.apply(config, opts)
  opts = opts or {}
  local save_key = opts.save_key or "<C-s>"
  local group = opts.group or nx.augroup.create("nxvim-workspaces", { clear = true })

  clear_installed_maps()

  if config.settings then
    apply_settings(config.settings)
  end

  -- Register each language's servers (cumulative per name), then enable them all in ONE
  -- call rather than one per language block — `nx.lsp.enable` re-dispatches the current
  -- buffer's filetype each time, and once per apply is enough.
  local to_enable = {}
  for _, lang in ipairs(config.languages) do
    for _, name in ipairs(config_lsps(lang.lsps)) do
      to_enable[#to_enable + 1] = name
    end
  end
  if #to_enable > 0 then
    nx.lsp.enable(to_enable)
  end

  for _, lang in ipairs(config.languages) do
    -- Only wire a FileType autocmd when the language actually carries buffer-local
    -- work (settings and/or save actions) — an lsps-only block needs none.
    if lang.settings or #lang.save_actions > 0 then
      local lang_settings = lang.settings
      local save_actions = lang.save_actions
      -- The per-buffer work, shared by the autocmd and the catch-up pass. Both can hand
      -- us a buffer that is NOT the current one (a FileType fires for whichever buffer
      -- just got its type; the catch-up walks every loaded buffer), and `vim.o` routes
      -- buffer/window options to the CURRENT context — so install `bufnr` as that
      -- context for the duration, the way `nvim_buf_call` does.
      local function on_buf(bufnr)
        nx.buf.call(bufnr, function()
          if lang_settings then
            apply_settings(lang_settings)
          end
          if #save_actions > 0 then
            nx.keymap.set("n", save_key, function()
              actions.run_and_write(save_actions)
            end, { buffer = bufnr, desc = M.SAVE_MAP_DESC })
            M._installed[bufnr] = M._installed[bufnr] or {}
            M._installed[bufnr][save_key] = true
          end
        end)
      end

      nx.autocmd.create("FileType", {
        group = group,
        pattern = lang.filetypes,
        callback = function(a)
          on_buf(a.buf)
        end,
      })

      -- The config loads async, AFTER every already-open file's FileType has fired, so
      -- the autocmd we just created won't catch them. Apply on the spot to each loaded
      -- buffer that already matches (mirrors `nx.lsp.enable`'s current-buffer dispatch,
      -- but across the whole buffer list — a --workspace session restores a full layout,
      -- so several buffers of a language are typically open before the config lands).
      local wanted = {}
      for _, ft in ipairs(lang.filetypes) do
        wanted[ft] = true
      end
      for _, bufnr in ipairs(nx.buf.list()) do
        if wanted[nx.bo[bufnr].filetype] then
          on_buf(bufnr)
        end
      end
    end
  end
end

return M
