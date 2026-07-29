-- Ready-made JSON workspace templates + the merge that materializes one into a
-- project's `.nxvim/config.json`.
--
-- Templates live in the user's config dir under `workspace-templates/<name>.json`, each
-- a partial (or full) `.nxvim/config.json` in the same schema. `:WorkspaceTemplate
-- <name>` (see init.lua) deep-merges the chosen template into the project's config,
-- validates the result, and writes it back — the JSON twin of the neovim setup that
-- copies a per-workspace rc from a template dir.
--
-- MERGE SEMANTICS. Objects merge recursively (a template can add one language without
-- dropping the others); a LIST replaces its counterpart wholesale (a template's
-- `save_actions` is the save chain, not a splice over the old one) — exactly
-- `nx.tbl.deep_extend("force", …)`, which `merge` below is a named alias for.
--
-- REMOTE SESSIONS. Two filesystems are in play, and they route to different sides:
--   * the TEMPLATES live in the config dir (`vim.fn.stdpath("config")`), which is always
--     LOCAL to the editor process — in a `--connect-daemon` session it is the client's
--     config (or the daemon's config materialized onto a local cache). So templates are
--     read through `nx.fs_local` (the local-always seam), never `nx.fs` (which crosses to
--     the daemon). `nx.fs_local` is exactly `nx.fs` in a bare/local session.
--   * the PROJECT config (`.nxvim/config.json`) lives in the workspace, which in a daemon
--     session is REMOTE — so it is read/written through `nx.fs`, the same seam the editor
--     opens the file with. `add()` therefore mixes the two: local template, remote config.

local config_mod = require("nxvim-workspaces.config")

local M = {}

-- The templates directory: `<config-dir>/workspace-templates`. `vim.fn.stdpath` resolves
-- the active nxvim config dir ($NXVIM_CONFIG / $XDG_CONFIG_HOME/nxvim / ~/.config/nxvim).
function M.dir()
  local cfg = vim.fn.stdpath("config")
  return (cfg and cfg ~= "" and cfg or ".") .. "/workspace-templates"
end

-- The project's config path: `<workspace-root>/.nxvim/config.json`, absolute (the cwd is
-- only a defensive fallback — the :Workspace* commands run inside a --workspace session).
function M.config_path()
  local root = nx.workspace.dir() or vim.fn.getcwd()
  return vim.fn.fnamemodify(root .. "/.nxvim/config.json", ":p")
end

-- List available template names (basename without the `.json`), sorted. Returns a
-- promise. A missing templates dir is the ordinary "you have no templates yet" case and
-- resolves to an empty list; any OTHER failure (an unreadable dir) REJECTS — reporting
-- it as "no templates" would hide a real problem behind a plausible-looking answer.
function M.list(dir)
  dir = dir or M.dir()
  return nx.async(function()
    if not nx.await(nx.fs_local.exists(dir)) then
      return {}
    end
    local entries = nx.await(nx.fs_local.readdir(dir))
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
  return nx.fs_local.read_text(path):next(function(text)
    local ok, raw = pcall(nx.json.decode, text)
    if not ok then
      error("nxvim-workspaces: template '" .. name .. "' has invalid JSON: " .. tostring(raw), 0)
    end
    return raw
  end)
end

-- The directory part of a path (nil when there is none).
local function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

-- Deep-merge `src` over `dst` (template wins), returning a fresh table.
--
-- Objects merge recursively so a template can add one language without dropping the
-- others; a LIST replaces its counterpart WHOLESALE — a template's one-entry
-- `save_actions` over an existing three-entry one is that one entry, not a splice
-- leaving entries 2 and 3 of the OLD chain behind. A list in this schema is an ordered
-- whole, so "the template's list" means exactly that. Both halves are
-- `nx.tbl.deep_extend("force", …)`'s rule, so this is a named alias for it.
local function merge(dst, src)
  if type(src) ~= "table" or type(dst) ~= "table" then
    return src
  end
  return nx.tbl.deep_extend("force", dst, src)
end
M.merge = merge

-- Merge template `name` into the project's `.nxvim/config.json` (creating it when
-- absent), validate the merged result (fail loud BEFORE writing anything), and write it
-- back pretty-printed. `opts.dir` overrides the templates dir, `opts.config_path` the
-- destination. Returns a promise of the config path.
function M.add(name, opts)
  opts = opts or {}
  local config_path = opts.config_path or M.config_path()
  return nx.async(function()
    local template = nx.await(M.read(name, opts.dir))

    local existing = {}
    if nx.await(nx.fs.exists(config_path)) then
      local text = nx.await(nx.fs.read_text(config_path))
      local ok, raw = pcall(nx.json.decode, text)
      if not ok then
        error("nxvim-workspaces: existing config has invalid JSON: " .. tostring(raw), 0)
      end
      existing = raw
    end

    -- Template values win; objects merge recursively, lists replace wholesale.
    local merged = merge(existing, template)
    -- Validate the merged shape now, so a bad template/merge never lands on disk.
    config_mod.normalize(merged)

    local pdir = dirname(config_path)
    if pdir then
      nx.await(nx.fs.mkdir(pdir, { recursive = true }))
    end
    nx.await(nx.fs.write(config_path, nx.json.encode(merged, { pretty = true })))
    return config_path
  end)()
end

return M
