-- nxvim-workspaces — apply a declarative, per-project `.nxvim/config.json`.
--
-- The JSON twin of a hand-written per-workspace rc: instead of Lua that enables LSP
-- servers, wires a `<C-s>` "format + write" map, and flips a few options, you commit a
-- small data file and this plugin applies it. It is built entirely on the documented
-- `nx.*` API — `nx.fs` (async config read), `nx.json`, `nx.lsp`, `nx.autocmd`,
-- `nx.keymap`, `vim.o` — nothing blocks and nothing is intercepted.
--
-- `.nxvim/config.json`:
--
--   {
--     "languages": {
--       "python": {
--         "lsps": {                       // registered + enabled once, at start
--           "basedpyright": { "settings": { ... } },
--           "ruff": {}
--         },
--         "save_actions": [               // run in order by <C-s>, then :write
--           { "require": "nx.lsp.buf", "method": "code_action",
--             "params": { "context": { "only": ["source.fixAll"] }, "apply": true } },
--           { "require": "nx.lsp.buf", "method": "format", "params": { "name": "ruff" } }
--         ],
--         "settings": { "tabstop": 4 }     // optional: buffer-local for this filetype
--       },
--       "javascript,typescript,vue": { "lsps": { "ts_ls": {} } }
--     },
--     "settings": { "number": true }       // optional: global, applied once at start
--   }
--
-- A comma-joined key ("javascript,typescript,vue") applies to each listed filetype.

local config_mod = require("nxvim-workspaces.config")
local apply_mod = require("nxvim-workspaces.apply")

local M = {}

M.defaults = {
  path = nil, -- config file path; nil -> "<cwd>/.nxvim/config.json"
  save_key = "<C-s>", -- the save-actions keymap
  notify_missing = false, -- notify when no config file is present (default: silent)
}

M.options = nil -- the last opts passed to setup() (for introspection / re-load)
M.config = nil -- the last normalized config applied (for introspection / tests)

local function default_path()
  return vim.fn.getcwd() .. "/.nxvim/config.json"
end

-- Parse + validate a raw JSON string into a normalized config. Fails LOUD on bad JSON.
function M.parse(text)
  local ok, raw = pcall(nx.json.decode, text)
  if not ok then
    error("nxvim-workspaces: invalid JSON in config: " .. tostring(raw), 0)
  end
  return config_mod.normalize(raw)
end

-- Apply a normalized config (or, given a raw decoded table, normalize it first),
-- emitting any accumulated warnings. Records it on `M.config` and returns it.
function M.apply(config, opts)
  opts = opts or M.options or {}
  if config.warnings == nil then
    config = config_mod.normalize(config)
  end
  for _, w in ipairs(config.warnings) do
    nx.notify("nxvim-workspaces: " .. w, nx.log.levels.WARN)
  end
  apply_mod.apply(config, { save_key = opts.save_key or M.defaults.save_key })
  M.config = config
  return config
end

-- Load the config file (async) and apply it. A MISSING file is the common, silent case
-- (a project may simply have none); a present-but-broken file fails LOUD. Returns the
-- promise so callers (and tests) can await completion.
function M.load(opts)
  opts = opts or M.options or {}
  local path = opts.path or default_path()
  return nx.fs
    .exists(path)
    :next(function(exists)
      if not exists then
        if opts.notify_missing then
          nx.notify("nxvim-workspaces: no config at " .. path, nx.log.levels.INFO)
        end
        return
      end
      return nx.fs.read_text(path):next(function(text)
        M.apply(M.parse(text), opts)
      end)
    end)
    :catch(function(err)
      local msg = type(err) == "table" and err.message or err
      nx.notify("nxvim-workspaces: " .. tostring(msg), nx.log.levels.ERROR)
    end)
end

-- M.setup(opts) — the entry point. Records the options, then loads + applies the config.
--   opts.path            override the config path (default "<cwd>/.nxvim/config.json")
--   opts.save_key        override the save-actions keymap (default "<C-s>")
--   opts.notify_missing  notify when no config file is found (default false)
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("nxvim-workspaces.setup: opts must be a table", 2)
  end
  M.options = opts
  return M.load(opts)
end

return M
