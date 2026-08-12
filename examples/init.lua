-- ~~~ Runnable demo for bemtvi-workspaces ~~~
--
-- This is a WORKSPACE feature, so launch with `--workspace` (its dir is where the plugin
-- looks for `.bemtvi/config.json`). Run it FROM this examples dir:
--
--     cd examples
--     BEMTVI_CONFIG=. bemtvi --workspace . sample.lua
--
-- (Without `--workspace` the plugin does nothing — that is the point.)
--
-- The spec below pulls in bemtvi-lspconfig as a dependency, so run `:PluginSync` once to
-- clone it. That is where the SERVER PRESETS live: the config names `lua_ls` / `pyright`
-- and nothing more, and the runtimepath `lsp/<name>.lua` preset supplies the actual
-- command, filetypes, and root markers. Without it a bare `{}` server entry has no
-- `cmd` and bemtvi says so, loudly.
--
-- `ruff` has no bundled preset, so `.bemtvi/config.json` spells its `cmd` out — the other
-- half of the same story: an `lsps` entry is just an `btv.lsp.config` table, and a server
-- nobody wrote a preset for is a couple of extra keys, not a blocker.
--
-- What happens:
--   1. The plugin is put on the runtimepath below; its `plugin/` entry auto-runs
--      `setup({})`, which — in this --workspace session — reads `./.bemtvi/config.json`.
--   1a. FIRST LAUNCH ONLY: a centered "trust this config?" dialog appears, because
--      applying a config runs code (language servers, save actions, the setup hook).
--        TYPE: `y` to trust and apply. Anything else — `n`, `<Esc>`, even `<CR>` —
--        declines, and none of the steps below happen (`:WorkspaceTrust` applies it
--      later). The answer is remembered per config path + content hash, so it asks
--      once; editing `.bemtvi/config.json` changes the hash and it asks again.
--   2. GLOBAL settings apply at once (see `.bemtvi/config.json` -> "settings"):
--        SEE: a number column, relative numbers, and the current line highlighted.
--   3. sample.lua is a `lua` file, so the "lua" language block fires:
--        SEE: `:set shiftwidth?` -> 2, `:set expandtab?` -> on (buffer-local).
--        TYPE some code and press <C-s> -> it runs the save actions (LSP format, if
--        lua_ls is installed) and writes the file. The write waits for the server's
--        edits to land: `btv.lsp.format()` hands back a promise the runner awaits.
--   4. Open a Python file (`:e demo.py`) to see the "python" block's fixAll + format
--      chain on <C-s> (needs the `ruff` server installed to actually do anything). The
--      fixAll step is `code_action` narrowed by `context.only` + `apply`, so it runs
--      without popping the chooser.
--        NOTE: that block enables BOTH `pyright` and `ruff`, and both really attach —
--        each syncs the file and publishes its own diagnostics, and a bare
--        `:LspCodeAction` merges what both offer into one chooser. The format step
--        names `ruff` explicitly (`params.name`) because pyright also advertises
--        formatting, and "whichever comes first" is not a formatter choice.
--
--   5. SETUP HOOKS — the escape hatch for what cannot be plain data. Both templates in
--      workspace-templates/ carry one, as a dict: `{ require, method, params }` naming a
--      function in this config dir's own Lua (lua/workspace-setup/{node,python}.lua).
--        TYPE: `:WorkspaceTemplate node` then `:WorkspaceTemplate python`.
--        SEE: `.bemtvi/config.json` now has ONE `"setup"` LIST holding BOTH hooks, in
--        merge order — hooks accumulate rather than overwrite, so each template keeps the
--        preparation its own language needs. Merge either template again: the list does
--        NOT grow, identical entries are elided.
--        TYPE: `:WorkspaceReload` -> both hooks run IN ORDER, each awaited before the
--        next (they resolve a tick later, so the two messages arrive in order), and the
--        rest of the config applies only after both have finished. The example hooks
--        report what they WOULD ensure rather than installing anything; swap the body
--        for your package manager.
--
-- Commands (this config dir ships two templates under workspace-templates/):
--   :WorkspaceConfig            open `.bemtvi/config.json` for editing
--   :WorkspaceTemplate python   merge that template into `.bemtvi/config.json`, then open
--                               it (tab-completes: `node`, `python`)
--   :WorkspaceReload            re-apply the config from disk after editing (it reports
--                               "reloaded config" only when it really applied)
--   :WorkspaceTrust             trust + apply — use it if you declined the dialog
--   :WorkspaceUntrust           forget the answer, so the dialog returns next launch
--
-- Nothing here is Lua config for the settings themselves — edit `.bemtvi/config.json`
-- and relaunch (or `:WorkspaceReload`) to change the LSPs, save actions, or options.
-- That is the whole point: a committable, per-project JSON file instead of rc Lua.

local here = vim.fn.expand("<sfile>:p:h") -- the examples/ dir

btv.plugins({
  {
    name = "bemtvi-workspaces",
    dir = vim.fn.fnamemodify(here, ":h"), -- the repo root (examples/'s parent)
    -- The config names servers (`lua_ls`, `ruff`, …) and nothing else — no `cmd`, no
    -- filetypes. Those come from the runtimepath preset `lsp/<name>.lua`, which is what
    -- bemtvi-lspconfig ships, so it has to be on the runtimepath for a bare `{}` server
    -- entry to resolve to something spawnable. Declaring it here makes `:PluginSync`
    -- clone it first and load it before this plugin.
    dependencies = { "bemtvi/bemtvi-lspconfig" },
  },
})
