-- bemtvi-workspaces — apply a declarative, per-project `.bemtvi/config.json`.
--
-- The JSON twin of a hand-written per-workspace rc: instead of Lua that enables LSP
-- servers, wires a `<C-s>` "format + write" map, and flips a few options, you commit a
-- small data file and this plugin applies it. It is built entirely on the documented
-- `btv.*` API — `btv.fs` (async config read), `btv.json`, `btv.lsp`, `btv.autocmd`,
-- `btv.keymap`, `vim.o` — nothing blocks and nothing is intercepted.
--
-- This is a WORKSPACE feature: it acts only in a `--workspace` session (`bemtvi
-- --workspace [dir]`), reading `<workspace-root>/.bemtvi/config.json`. A bare editor is
-- left untouched. (`btv.workspace.active()` / `btv.workspace.dir()` are the gate.)
--
-- `.bemtvi/config.json`:
--
--   {
--     "languages": {
--       "python": {
--         "lsps": {                       // registered + enabled once, at start
--           "basedpyright": { "settings": { ... } },
--           "ruff": {}
--         },
--         "save_actions": [               // run in order by <C-s>, then :write
--           { "require": "btv.lsp", "method": "code_action",
--             "params": { "context": { "only": ["source.fixAll"] }, "apply": true } },
--           { "require": "btv.lsp", "method": "format" }
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
-- live on globals — `btv.lsp` (`format`, `code_action`, `rename`) and their neovim-shaped
-- `vim.lsp.buf` aliases. There is no `btv.lsp.buf`; naming it fails loud.
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

local config_mod = require("bemtvi-workspaces.config")
local apply_mod = require("bemtvi-workspaces.apply")
local actions = require("bemtvi-workspaces.actions")
local templates = require("bemtvi-workspaces.templates")
local trust = require("bemtvi-workspaces.trust")

local M = {}

M.defaults = {
  path = nil, -- config file path; nil -> "<workspace-root>/.bemtvi/config.json"
  save_key = "<C-s>", -- the save-actions keymap
  notify_missing = false, -- notify when no config file is present (default: silent)
  templates_dir = nil, -- workspace-templates dir; nil -> "<config-dir>/workspace-templates"
  trust = true, -- prompt for permission before applying (the config runs code); false skips
  trust_dir = nil, -- local trust dir; nil -> "<state>/bemtvi-workspaces/trust"
}

M.options = nil -- the last opts passed to setup() (for introspection / re-load)
M.config = nil -- the last normalized config applied (for introspection / tests)

-- The project config path: `<workspace-root>/.bemtvi/config.json`, absolute. This is a
-- per-workspace feature, so the root comes from the `--workspace` session
-- (`btv.workspace.dir()`); the cwd is only a defensive fallback.
local function default_path()
  local root = btv.workspace.dir() or vim.fn.getcwd()
  return vim.fn.fnamemodify(root .. "/.bemtvi/config.json", ":p")
end

-- The config path in effect: an explicit `opts.path` (absolutized, so the trust key and
-- every message name one canonical file) else the workspace default.
local function config_path(opts)
  return opts.path and vim.fn.fnamemodify(opts.path, ":p") or default_path()
end

-- Parse + validate a raw JSON string into a normalized config. Fails LOUD on bad JSON.
function M.parse(text)
  local ok, raw = pcall(btv.json.decode, text)
  if not ok then
    error("bemtvi-workspaces: invalid JSON in config: " .. tostring(raw), 0)
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
    btv.notify("bemtvi-workspaces: " .. w, btv.log.levels.WARN)
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
    return btv.promise.resolve(true)
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
  local promise = btv.fs
    .exists(path)
    :next(function(exists)
      if not exists then
        if opts.notify_missing then
          btv.notify("bemtvi-workspaces: no config at " .. path, btv.log.levels.INFO)
        end
        return "missing"
      end
      return btv.fs.read_text(path):next(function(text)
        local config = M.parse(text)
        -- Trust gate: the config runs code, so ask before applying (unless the caller
        -- opts out with trust=false). This precedes the `setup` hook — which itself runs
        -- code — so nothing from an untrusted config executes.
        local gate
        if opts.trust == false then
          gate = btv.promise.resolve(true)
        else
          gate = trust.ensure(path, text, opts.trust_dir)
        end
        return gate:next(function(allowed)
          if not allowed then
            btv.notify(
              "bemtvi-workspaces: '"
                .. path
                .. "' not applied (untrusted) — :WorkspaceTrust to allow.",
              btv.log.levels.WARN
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
      btv.notify("bemtvi-workspaces: " .. tostring(msg), btv.log.levels.ERROR)
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
    btv.open(path, { where = "main" })
  end
  btv.fs
    .exists(path)
    :next(function(exists)
      if exists then
        return open()
      end
      return btv.async(function()
        local dir = path:match("^(.*)/[^/]+$")
        if dir then
          btv.await(btv.fs.mkdir(dir, { recursive = true }))
        end
        -- Both keys hold OBJECTS in the schema, and a bare `{}` encodes as `[]` (Lua
        -- cannot tell an empty map from an empty list) — so the skeleton must say
        -- which it is, or the file we just created contradicts its own schema.
        local skeleton = { languages = btv.json.empty_object(), settings = btv.json.empty_object() }
        btv.await(btv.fs.write(path, btv.json.encode(skeleton, { pretty = true })))
        open()
      end)()
    end)
    :catch(function(err)
      btv.notify(
        "bemtvi-workspaces: " .. tostring(err and err.message or err),
        btv.log.levels.ERROR
      )
    end)
end

-- Register the global :Workspace* commands (idempotent — safe to re-run on re-setup).
function M._register_commands(opts)
  btv.command("WorkspaceConfig", function()
    edit_config(opts)
  end, { desc = "Edit the project's .bemtvi/config.json (creating it if absent)" })

  btv.command("WorkspaceTemplate", function(o)
    local name = o.fargs and o.fargs[1]
    if not name or name == "" then
      btv.notify("bemtvi-workspaces: usage: :WorkspaceTemplate {name}", btv.log.levels.ERROR)
      return
    end
    templates
      .add(name, { dir = opts.templates_dir, config_path = opts.path })
      :next(function(path)
        btv.open(path, { where = "main" })
        btv.notify("bemtvi-workspaces: merged template '" .. name .. "'", btv.log.levels.INFO)
      end)
      :catch(function(err)
        btv.notify(
          "bemtvi-workspaces: " .. tostring(err and err.message or err),
          btv.log.levels.ERROR
        )
      end)
  end, {
    desc = "Merge a workspace template into .bemtvi/config.json, then open it",
    usage = "{template}",
    -- Async completer (lists template names in the picker).
    complete = function()
      return templates.list(opts.templates_dir)
    end,
  })

  -- Report what the reload actually did. A missing / declined / broken config has
  -- already said so in its own words; claiming "reloaded" over it would contradict it.
  btv.command("WorkspaceReload", function()
    M.load(opts):next(function(status)
      if status == "applied" then
        btv.notify("bemtvi-workspaces: reloaded config", btv.log.levels.INFO)
      elseif status == "missing" then
        btv.notify("bemtvi-workspaces: no config at " .. config_path(opts), btv.log.levels.WARN)
      end
    end)
  end, { desc = "Re-apply the project's .bemtvi/config.json from disk" })

  btv.command("WorkspaceTrust", function()
    local path = config_path(opts)
    btv.fs
      .read_text(path)
      :next(function(text)
        return trust.remember(path, text, true, opts.trust_dir)
      end)
      :next(function()
        return M.load(opts) -- decision is now "allow" -> applies without prompting
      end)
      :next(function(status)
        if status == "applied" then
          btv.notify("bemtvi-workspaces: trusted + applied '" .. path .. "'", btv.log.levels.INFO)
        end
      end)
      :catch(function(err)
        btv.notify(
          "bemtvi-workspaces: " .. tostring(err and err.message or err),
          btv.log.levels.ERROR
        )
      end)
  end, { desc = "Trust and apply the project's .bemtvi/config.json" })

  btv.command("WorkspaceUntrust", function()
    local path = config_path(opts)
    trust
      .forget(path, opts.trust_dir)
      :next(function()
        btv.notify(
          "bemtvi-workspaces: forgot trust for '" .. path .. "' (re-prompts next load)",
          btv.log.levels.INFO
        )
      end)
      :catch(function(err)
        btv.notify(
          "bemtvi-workspaces: " .. tostring(err and err.message or err),
          btv.log.levels.ERROR
        )
      end)
  end, { desc = "Forget the trust decision for the project config (re-prompts next load)" })
end

-- M.setup(opts) — the entry point. Records the options, and — WHEN this is a
-- `--workspace` session (the gate; an explicit `opts.path` forces it regardless) —
-- registers the :Workspace* commands and loads + applies the config. In a bare (non
-- `--workspace`) editor it is a silent no-op: `.bemtvi/config.json` is per-workspace.
--   opts.path            override the config path (default "<workspace>/.bemtvi/config.json")
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
    error("bemtvi-workspaces.setup: opts must be a table", 2)
  end
  M.options = opts
  -- Gate: only active in a --workspace session (or when a path is forced explicitly).
  if not opts.path and not btv.workspace.active() then
    return btv.promise.resolve("inactive")
  end
  M._register_commands(opts)
  return M.load(opts)
end

return M
