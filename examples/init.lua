-- ~~~ Runnable demo for nxvim-workspaces ~~~
--
-- This is a WORKSPACE feature, so launch with `--workspace` (its dir is where the plugin
-- looks for `.nxvim/config.json`). Run it FROM this examples dir:
--
--     cd examples
--     NXVIM_CONFIG=. nxvim --workspace . sample.lua
--
-- (Without `--workspace` the plugin does nothing — that is the point.)
--
-- What happens:
--   1. The plugin is put on the runtimepath below; its `plugin/` entry auto-runs
--      `setup({})`, which — in this --workspace session — reads `./.nxvim/config.json`
--      and applies it.
--   2. GLOBAL settings apply at once (see `.nxvim/config.json` -> "settings"):
--        SEE: a number column, relative numbers, and the current line highlighted.
--   3. sample.lua is a `lua` file, so the "lua" language block fires:
--        SEE: `:set shiftwidth?` -> 2, `:set expandtab?` -> on (buffer-local).
--        TYPE some code and press <C-s> -> it runs the save actions (LSP format, if
--        lua_ls is installed) and writes the file.
--   4. Open a Python file (`:e demo.py`) to see the "python" block's fixAll + format
--      chain on <C-s> (needs the `ruff` server installed to actually reformat).
--
-- Commands (this config dir ships one template, workspace-templates/python.json):
--   :WorkspaceConfig            open `.nxvim/config.json` for editing
--   :WorkspaceTemplate python   merge that template into `.nxvim/config.json`, then open
--                               it (tab-completes the template names)
--   :WorkspaceReload            re-apply the config from disk after editing
--
-- Nothing here is Lua config for the settings themselves — edit `.nxvim/config.json`
-- and relaunch (or `:WorkspaceReload`) to change the LSPs, save actions, or options.
-- That is the whole point: a committable, per-project JSON file instead of rc Lua.

local here = vim.fn.expand("<sfile>:p:h") -- the examples/ dir

nx.plugins({
  {
    name = "nxvim-workspaces",
    dir = vim.fn.fnamemodify(here, ":h"), -- the repo root (examples/'s parent)
  },
})
