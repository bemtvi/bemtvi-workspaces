-- Ready-made JSON workspace templates + the merge that materializes one into a
-- project's `.bemtvi/config.json`.
--
-- Templates live in the user's config dir under `workspace-templates/<name>.json`, each
-- a partial (or full) `.bemtvi/config.json` in the same schema. `:WorkspaceTemplate
-- <name>` (see init.lua) deep-merges the chosen template into the project's config,
-- validates the result, and writes it back — the JSON twin of the neovim setup that
-- copies a per-workspace rc from a template dir.
--
-- MERGE SEMANTICS. Objects merge recursively (a template can add one language without
-- dropping the others); a LIST replaces its counterpart wholesale (a template's
-- `save_actions` is the save chain, not a splice over the old one) — exactly
-- `btv.tbl.deep_extend("force", …)`, which `merge` below is a named alias for.
--
-- `setup` is the ONE key that accumulates: a template writes the single hook its
-- language needs (the dict form), and merging collects every config's hooks into one
-- deduped LIST, so a project built from three templates runs all three preparations
-- rather than only the last merged one. See `merge_setup`.
--
-- REMOTE SESSIONS. Two filesystems are in play, and they route to different sides:
--   * the TEMPLATES live in the config dir (`btv.stdpath("config")`), which is always
--     LOCAL to the editor process — in a `--connect-daemon` session it is the client's
--     config (or the daemon's config materialized onto a local cache). So templates are
--     read through `btv.fs_local` (the local-always seam), never `btv.fs` (which crosses to
--     the daemon). `btv.fs_local` is exactly `btv.fs` in a bare/local session.
--   * the PROJECT config (`.bemtvi/config.json`) lives in the workspace, which in a daemon
--     session is REMOTE — so it is read/written through `btv.fs`, the same seam the editor
--     opens the file with. `add()` therefore mixes the two: local template, remote config.

local config_mod = require("bemtvi-workspaces.config")

local M = {}

-- The templates directory: `<config-dir>/workspace-templates`. `btv.stdpath` resolves
-- the active bemtvi config dir ($BEMTVI_CONFIG / $XDG_CONFIG_HOME/bemtvi / ~/.config/bemtvi).
function M.dir()
  local cfg = btv.stdpath("config")
  return (cfg and cfg ~= "" and cfg or ".") .. "/workspace-templates"
end

-- The project's config path: `<workspace-root>/.bemtvi/config.json`, absolute (the cwd is
-- only a defensive fallback — the :Workspace* commands run inside a --workspace session).
function M.config_path()
  local root = btv.workspace.dir() or btv.cwd()
  return btv.fname.modify(root .. "/.bemtvi/config.json", ":p")
end

-- List available template names (basename without the `.json`), sorted. Returns a
-- promise. A missing templates dir is the ordinary "you have no templates yet" case and
-- resolves to an empty list; any OTHER failure (an unreadable dir) REJECTS — reporting
-- it as "no templates" would hide a real problem behind a plausible-looking answer.
function M.list(dir)
  dir = dir or M.dir()
  return btv.async(function()
    if not btv.await(btv.fs_local.exists(dir)) then
      return {}
    end
    local entries = btv.await(btv.fs_local.readdir(dir))
    local names = {}
    for _, e in ipairs(entries) do
      if e.type ~= "directory" then
        local name = e.name:match("^(.+)%.json$")
        if name then
          names[#names + 1] = name
        end
      end
    end
    table.sort(names)
    return names
  end)()
end

-- Read + decode a template's JSON into a Lua table. Rejects LOUD when the template is
-- missing or holds invalid JSON.
function M.read(name, dir)
  dir = dir or M.dir()
  local path = dir .. "/" .. name .. ".json"
  return btv.fs_local.read_text(path):next(function(text)
    local ok, raw = pcall(btv.json.decode, text)
    if not ok then
      error("bemtvi-workspaces: template '" .. name .. "' has invalid JSON: " .. tostring(raw), 0)
    end
    return raw
  end)
end

-- The directory part of a path (nil when there is none).
local function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

-- The `setup` hooks of one config as a LIST, whatever the source spelled them. A
-- template writes the dict form (`{ require=, method=, params= }`) — one hook is what a
-- template has to say — and the schema also takes an array; both mean a list of calls.
-- Shape errors are left to `config.normalize`, which validates the merged result: this
-- only has to decide "one, or several".
local function setup_entries(value)
  if type(value) ~= "table" or next(value) == nil then
    return {}
  end
  if not config_mod.is_array(value) then
    return { value }
  end
  local out = {}
  for i, entry in ipairs(value) do
    out[i] = entry
  end
  return out
end

-- The merged `setup`: every hook from `dst` then every hook from `src`, in that order,
-- with entries that are structurally identical elided.
--
-- Setup hooks are the one key that ACCUMULATES rather than being overwritten. Each
-- template carries the preparation its own language needs (a node template ensures its
-- npm packages, a python one its venv), so a project that merges three templates must
-- end up running all three — "template wins" would leave it running only the last one's,
-- silently dropping the preparation the earlier merges were for. Re-merging a template,
-- or two templates that share a hook, must NOT run it twice, hence the dedupe: identical
-- means same require/method/params all the way down (`btv.tbl.deep_equal`), so two
-- `ensure` calls listing different packages are two different hooks and both survive.
local function merge_setup(dst, src)
  local merged = {}
  local function add(entry)
    for _, seen in ipairs(merged) do
      if btv.tbl.deep_equal(seen, entry) then
        return
      end
    end
    merged[#merged + 1] = entry
  end
  for _, entry in ipairs(setup_entries(dst)) do
    add(entry)
  end
  for _, entry in ipairs(setup_entries(src)) do
    add(entry)
  end
  return merged
end
M.merge_setup = merge_setup

-- Deep-merge `src` over `dst` (template wins), returning a fresh table.
--
-- Objects merge recursively so a template can add one language without dropping the
-- others; a LIST replaces its counterpart WHOLESALE — a template's one-entry
-- `save_actions` over an existing three-entry one is that one entry, not a splice
-- leaving entries 2 and 3 of the OLD chain behind. A list in this schema is an ordered
-- whole, so "the template's list" means exactly that. Both halves are
-- `btv.tbl.deep_extend("force", …)`'s rule, so most of this is a named alias for it.
--
-- The exception is `setup` (see `merge_setup`): its hooks accumulate into a deduped
-- list, so the merged config always spells `setup` as an array — the canonical form.
local function merge(dst, src)
  if type(src) ~= "table" or type(dst) ~= "table" then
    return src
  end
  local merged = btv.tbl.deep_extend("force", dst, src)
  local setup = merge_setup(dst.setup, src.setup)
  merged.setup = #setup > 0 and setup or nil
  return merged
end
M.merge = merge

-- Merge template `name` into the project's `.bemtvi/config.json` (creating it when
-- absent), validate the merged result (fail loud BEFORE writing anything), and write it
-- back pretty-printed. `opts.dir` overrides the templates dir, `opts.config_path` the
-- destination. Returns a promise of the config path.
function M.add(name, opts)
  opts = opts or {}
  local config_path = opts.config_path or M.config_path()
  return btv.async(function()
    local template = btv.await(M.read(name, opts.dir))

    local existing = {}
    if btv.await(btv.fs.exists(config_path)) then
      local text = btv.await(btv.fs.read_text(config_path))
      local ok, raw = pcall(btv.json.decode, text)
      if not ok then
        error("bemtvi-workspaces: existing config has invalid JSON: " .. tostring(raw), 0)
      end
      existing = raw
    end

    -- Template values win; objects merge recursively, lists replace wholesale.
    local merged = merge(existing, template)
    -- Validate the merged shape now, so a bad template/merge never lands on disk.
    config_mod.normalize(merged)

    local pdir = dirname(config_path)
    if pdir then
      btv.await(btv.fs.mkdir(pdir, { recursive = true }))
    end
    btv.await(btv.fs.write(config_path, btv.json.encode(merged, { pretty = true })))
    return config_path
  end)()
end

return M
