-- Ready-made JSON workspace templates + the merge that materializes one into a
-- project's `.nxvim/config.json`.
--
-- Templates live in the user's config dir under `workspace-templates/<name>.json`, each
-- a partial (or full) `.nxvim/config.json` in the same schema. `:WorkspaceTemplate
-- <name>` (see init.lua) deep-merges the chosen template into the project's config,
-- validates the result, and writes it back — the JSON twin of the neovim setup that
-- copies a per-workspace rc from a template dir.

local config_mod = require("nxvim-workspaces.config")

local M = {}

-- The templates directory: `<config-dir>/workspace-templates`. `vim.fn.stdpath` resolves
-- the active nxvim config dir ($NXVIM_CONFIG / $XDG_CONFIG_HOME/nxvim / ~/.config/nxvim).
function M.dir()
  local cfg = vim.fn.stdpath("config")
  return (cfg and cfg ~= "" and cfg or ".") .. "/workspace-templates"
end

-- The project's config path for the current working directory.
function M.config_path()
  return vim.fn.getcwd() .. "/.nxvim/config.json"
end

-- List available template names (basename without the `.json`), sorted. Returns a
-- promise; a missing/unreadable templates dir resolves to an empty list.
function M.list(dir)
  dir = dir or M.dir()
  return nx.async(function()
    local ok, entries = pcall(nx.await, nx.fs.readdir(dir))
    if not ok then
      return {}
    end
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
  return nx.fs.read_text(path):next(function(text)
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

    -- Template values win; lists (save_actions) replace wholesale under deep-extend.
    local merged = vim.tbl_deep_extend("force", existing, template)
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
