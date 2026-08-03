-- nxvim-workspaces — apply a declarative, per-project `.nxvim/config.json`.
--
-- The JSON twin of a hand-written per-workspace rc: instead of Lua that enables LSP
-- servers, wires a `<C-s>` "format + write" map, and flips a few options, you commit a
-- small data file and this plugin applies it. It is built entirely on the documented
-- `nx.*` API — `nx.fs` (async config read), `nx.json`, `nx.lsp`, `nx.autocmd`,
-- `nx.keymap`, `vim.o` — nothing blocks and nothing is intercepted.
--
-- This is a WORKSPACE feature: it acts only in a `--workspace` session (`nxvim
-- --workspace [dir]`), reading `<workspace-root>/.nxvim/config.json`. A bare editor is
-- left untouched. (`nx.workspace.active()` / `nx.workspace.dir()` are the gate.)
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
--           { "require": "nx.lsp", "method": "code_action",
--             "params": { "context": { "only": ["source.fixAll"] }, "apply": true } },
--           { "require": "nx.lsp", "method": "format" }
--         ],
--         "settings": { "tabstop": 4 }     // optional: buffer-local for this filetype
--       },
--       "javascript,typescript,vue": { "lsps": { "ts_ls": {} } }
--     },
--     "settings": { "number": true },      // optional: global, applied once at start
--     "setup": [                           // optional: one object, or an array of them
--       { "require": "mymod", "method": "prepare", "params": {} }
--     ]
--   }
--
-- A comma-joined key ("javascript,typescript,vue") applies to each listed filetype.
--
-- The optional top-level `setup` names a function (a module `require` or a dotted
-- global) in the user's own config-dir Lua; it is called and, if it returns a promise,
-- AWAITED before the rest of the config is applied — the escape hatch for logic that
-- can't be plain data (compute paths, install deps, register a custom module). Write
-- ONE such object, or an ARRAY of them to run several IN ORDER, each awaited before the
-- next starts (so a hook may consume what the one before it produced).
--
-- A save action names `<module-or-dotted-global>.<method>(<params>)`. The built-in verbs
-- live on globals — `nx.lsp` (`format`, `code_action`, `rename`) and their neovim-shaped
-- `vim.lsp.buf` aliases. There is no `nx.lsp.buf`; naming it fails loud.
--
-- Applying the config runs code (LSP commands, save actions, the setup hook), so the
-- first apply of a given config PROMPTS for permission; the decision is remembered in a
-- LOCAL trust store keyed by the config's ABSOLUTE path + a hash of its content, so a
-- changed config re-prompts (see trust.lua).
--
-- Commands (registered by setup()):
--   :WorkspaceConfig            edit the project config (create an empty one if absent)
--   :WorkspaceTemplate {name}   merge a config-dir template into it, then open it
--   :WorkspaceReload            re-apply the config from disk
--   :WorkspaceTrust             trust + apply the config (e.g. after declining)
--   :WorkspaceUntrust           forget the trust decision (re-prompts next load)

local config_mod = require("nxvim-workspaces.config")
local apply_mod = require("nxvim-workspaces.apply")
local actions = require("nxvim-workspaces.actions")
local templates = require("nxvim-workspaces.templates")
local trust = require("nxvim-workspaces.trust")

local M = {}

M.defaults = {
  path = nil, -- config file path; nil -> "<workspace-root>/.nxvim/config.json"
  save_key = "<C-s>", -- the save-actions keymap
  notify_missing = false, -- notify when no config file is present (default: silent)
  templates_dir = nil, -- workspace-templates dir; nil -> "<config-dir>/workspace-templates"
  trust = true, -- prompt for permission before applying (the config runs code); false skips
  trust_dir = nil, -- local trust dir; nil -> "<state>/nxvim-workspaces/trust"
}

M.options = nil -- the last opts passed to setup() (for introspection / re-load)
M.config = nil -- the last normalized config applied (for introspection / tests)

-- The project config path: `<workspace-root>/.nxvim/config.json`, absolute. This is a
-- per-workspace feature, so the root comes from the `--workspace` session
-- (`nx.workspace.dir()`); the cwd is only a defensive fallback.
local function default_path()
  local root = nx.workspace.dir() or vim.fn.getcwd()
  return vim.fn.fnamemodify(root .. "/.nxvim/config.json", ":p")
end

-- The config path in effect: an explicit `opts.path` (absolutized, so the trust key and
-- every message name one canonical file) else the workspace default.
local function config_path(opts)
  return opts.path and vim.fn.fnamemodify(opts.path, ":p") or default_path()
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

-- Run the optional async `setup` hooks and await them before the rest of the config is
-- applied. Returns a promise that fulfils once they have all settled (immediately when
-- there are none). They run IN ORDER, each awaited before the next starts — `actions.run`
-- is the same ordered, await-each runner the save chain uses, so a hook that computes a
-- path can be followed by one that consumes it. A hook failure rejects, aborting the
-- apply (surfaced loud upstream) without running the hooks after it.
function M._run_setup(config)
  if not config.setup or #config.setup == 0 then
    return nx.promise.resolve(true)
  end
  return actions.run(config.setup)
end

-- The in-flight `M.load`, so a second load (a `:WorkspaceReload` on top of the startup
-- one, or two reloads in a row) joins it instead of racing a second apply — and, when
-- the config is untrusted, a second trust prompt.
M._loading = nil

-- Load the config file (async) and apply it: run the `setup` hook first (awaited), then
-- apply settings / lsps / save actions. A MISSING file is the common, silent case (a
-- project may simply have none); a present-but-broken file fails LOUD.
--
-- Returns a promise of WHAT happened, so a caller can report the truth rather than
-- assuming success: `"applied"`, `"missing"`, `"untrusted"`, or `"error"` (already
-- notified). It never rejects — the failure is surfaced, not propagated.
function M.load(opts)
  opts = opts or M.options or {}
  if M._loading then
    return M._loading
  end
  local path = config_path(opts)
  local promise = nx.fs
    .exists(path)
    :next(function(exists)
      if not exists then
        if opts.notify_missing then
          nx.notify("nxvim-workspaces: no config at " .. path, nx.log.levels.INFO)
        end
        return "missing"
      end
      return nx.fs.read_text(path):next(function(text)
        local config = M.parse(text)
        -- Trust gate: the config runs code, so ask before applying (unless the caller
        -- opts out with trust=false). This precedes the `setup` hook — which itself runs
        -- code — so nothing from an untrusted config executes.
        local gate
        if opts.trust == false then
          gate = nx.promise.resolve(true)
        else
          gate = trust.ensure(path, text, opts.trust_dir)
        end
        return gate:next(function(allowed)
          if not allowed then
            nx.notify(
              "nxvim-workspaces: '"
                .. path
                .. "' not applied (untrusted) — :WorkspaceTrust to allow.",
              nx.log.levels.WARN
            )
            return "untrusted"
          end
          return M._run_setup(config):next(function()
            M.apply(config, opts)
            return "applied"
          end)
        end)
      end)
    end)
    :catch(function(err)
      local msg = type(err) == "table" and err.message or err
      nx.notify("nxvim-workspaces: " .. tostring(msg), nx.log.levels.ERROR)
      return "error"
    end)
  -- Release the guard once this load settles, whatever the outcome.
  M._loading = promise:next(function(status)
    M._loading = nil
    return status
  end)
  return M._loading
end

-- ----- the :Workspace* commands ---------------------------------------------

-- Open the project's config, creating an empty skeleton first when it doesn't exist.
local function edit_config(opts)
  local path = config_path(opts)
  -- `where = "main"` so a :WorkspaceConfig fired from a dock / sidebar (a tree, a
  -- picker's window) lands in the main editing area rather than inside that dock.
  local function open()
    nx.open(path, { where = "main" })
  end
  nx.fs
    .exists(path)
    :next(function(exists)
      if exists then
        return open()
      end
      return nx.async(function()
        local dir = path:match("^(.*)/[^/]+$")
        if dir then
          nx.await(nx.fs.mkdir(dir, { recursive = true }))
        end
        -- Both keys hold OBJECTS in the schema, and a bare `{}` encodes as `[]` (Lua
        -- cannot tell an empty map from an empty list) — so the skeleton must say
        -- which it is, or the file we just created contradicts its own schema.
        local skeleton = { languages = nx.json.empty_object(), settings = nx.json.empty_object() }
        nx.await(nx.fs.write(path, nx.json.encode(skeleton, { pretty = true })))
        open()
      end)()
    end)
    :catch(function(err)
      nx.notify("nxvim-workspaces: " .. tostring(err and err.message or err), nx.log.levels.ERROR)
    end)
end

-- Register the global :Workspace* commands (idempotent — safe to re-run on re-setup).
function M._register_commands(opts)
  nx.command("WorkspaceConfig", function()
    edit_config(opts)
  end, { desc = "Edit the project's .nxvim/config.json (creating it if absent)" })

  nx.command("WorkspaceTemplate", function(o)
    local name = o.fargs and o.fargs[1]
    if not name or name == "" then
      nx.notify("nxvim-workspaces: usage: :WorkspaceTemplate {name}", nx.log.levels.ERROR)
      return
    end
    templates
      .add(name, { dir = opts.templates_dir, config_path = opts.path })
      :next(function(path)
        nx.open(path, { where = "main" })
        nx.notify("nxvim-workspaces: merged template '" .. name .. "'", nx.log.levels.INFO)
      end)
      :catch(function(err)
        nx.notify("nxvim-workspaces: " .. tostring(err and err.message or err), nx.log.levels.ERROR)
      end)
  end, {
    desc = "Merge a workspace template into .nxvim/config.json, then open it",
    usage = "{template}",
    -- Async completer (lists template names in the picker).
    complete = function()
      return templates.list(opts.templates_dir)
    end,
  })

  -- Report what the reload actually did. A missing / declined / broken config has
  -- already said so in its own words; claiming "reloaded" over it would contradict it.
  nx.command("WorkspaceReload", function()
    M.load(opts):next(function(status)
      if status == "applied" then
        nx.notify("nxvim-workspaces: reloaded config", nx.log.levels.INFO)
      elseif status == "missing" then
        nx.notify("nxvim-workspaces: no config at " .. config_path(opts), nx.log.levels.WARN)
      end
    end)
  end, { desc = "Re-apply the project's .nxvim/config.json from disk" })

  nx.command("WorkspaceTrust", function()
    local path = config_path(opts)
    nx.fs
      .read_text(path)
      :next(function(text)
        return trust.remember(path, text, true, opts.trust_dir)
      end)
      :next(function()
        return M.load(opts) -- decision is now "allow" -> applies without prompting
      end)
      :next(function(status)
        if status == "applied" then
          nx.notify("nxvim-workspaces: trusted + applied '" .. path .. "'", nx.log.levels.INFO)
        end
      end)
      :catch(function(err)
        nx.notify("nxvim-workspaces: " .. tostring(err and err.message or err), nx.log.levels.ERROR)
      end)
  end, { desc = "Trust and apply the project's .nxvim/config.json" })

  nx.command("WorkspaceUntrust", function()
    local path = config_path(opts)
    trust
      .forget(path, opts.trust_dir)
      :next(function()
        nx.notify(
          "nxvim-workspaces: forgot trust for '" .. path .. "' (re-prompts next load)",
          nx.log.levels.INFO
        )
      end)
      :catch(function(err)
        nx.notify("nxvim-workspaces: " .. tostring(err and err.message or err), nx.log.levels.ERROR)
      end)
  end, { desc = "Forget the trust decision for the project config (re-prompts next load)" })
end

-- M.setup(opts) — the entry point. Records the options, and — WHEN this is a
-- `--workspace` session (the gate; an explicit `opts.path` forces it regardless) —
-- registers the :Workspace* commands and loads + applies the config. In a bare (non
-- `--workspace`) editor it is a silent no-op: `.nxvim/config.json` is per-workspace.
--   opts.path            override the config path (default "<workspace>/.nxvim/config.json")
--   opts.save_key        override the save-actions keymap (default "<C-s>")
--   opts.notify_missing  notify when no config file is found (default false)
--   opts.templates_dir   override the templates dir (default "<config>/workspace-templates")
--   opts.trust           prompt for permission before applying (default true; false skips)
--   opts.trust_dir       override the local trust dir (default under stdpath("state"))
-- Returns a promise of the outcome — `M.load`'s status (`"applied"` / `"missing"` /
-- `"untrusted"` / `"error"`), or `"inactive"` when the workspace gate said no.
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("nxvim-workspaces.setup: opts must be a table", 2)
  end
  M.options = opts
  -- Gate: only active in a --workspace session (or when a path is forced explicitly).
  if not opts.path and not nx.workspace.active() then
    return nx.promise.resolve("inactive")
  end
  M._register_commands(opts)
  return M.load(opts)
end

return M
