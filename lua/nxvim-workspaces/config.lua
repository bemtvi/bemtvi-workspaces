-- Validation + normalization of the `.nxvim/config.json` declarative workspace config.
--
-- Pure logic (no `nx.*` runtime), so it is fully testable in isolation: it turns a
-- decoded-JSON table into a canonical, checked shape the applier consumes, and fails
-- LOUD on any shape it cannot honor (no silent stubs). Non-fatal issues — an unknown
-- key we choose to tolerate for forward-compat — are collected into `warnings` for the
-- caller to surface, rather than aborting the load.
--
-- The normalized shape:
--
--   {
--     settings   = { <name> = <value>, ... } | nil,   -- global, applied once at start
--     setup      = { require=, method=, params= } | nil, -- async hook, awaited first
--     languages  = {
--       { filetypes   = { "js", "html", ... },        -- the language key, comma-split
--         lsps        = { <name> = <cfg-table>, ... }, -- may be empty
--         save_actions= { { require=, method=, params= }, ... }, -- may be empty
--         settings    = { <name> = <value>, ... } | nil }, -- per-language, buffer-local
--       ...
--     },
--     warnings   = { <string>, ... },                 -- non-fatal notes for the caller
--   }

local M = {}

-- Fail loud with the plugin-prefixed message and no `file:line` noise (level 0).
local function fail(msg)
  error("nxvim-workspaces: " .. msg, 0)
end

-- Is `t` a JSON array (a list)? After decode an empty `[]` and empty `{}` are
-- indistinguishable (both `{}`); we treat an empty table as an empty list. A non-empty
-- table is a list only when its keys are exactly `1..n`, so a misused object (a table
-- with string keys) fails the check and its caller fails loud instead of silently
-- treating it as empty.
local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end
M.is_array = is_array

-- Split a language key (`"python"` or `"js,html,vue"`) into a trimmed filetype list.
local function split_filetypes(key)
  local fts = {}
  for part in tostring(key):gmatch("[^,]+") do
    local ft = part:match("^%s*(.-)%s*$") -- trim surrounding whitespace
    if ft ~= "" then
      fts[#fts + 1] = ft
    end
  end
  return fts
end
M.split_filetypes = split_filetypes

-- Validate an option map (`settings`): a string-keyed object. Values pass through
-- untouched to `vim.o` (the lenient compat surface classifies + stores them).
local function check_settings(settings, where)
  if type(settings) ~= "table" then
    fail(where .. " `settings` must be an object")
  end
  if is_array(settings) and next(settings) ~= nil then
    fail(where .. " `settings` must be an object, not an array")
  end
  for k in pairs(settings) do
    if type(k) ~= "string" then
      fail(where .. " `settings` keys must be option-name strings")
    end
  end
  return settings
end

-- Validate a call spec: `{ require=<string>, method=<string>, params=<any?> }` — the
-- shape shared by save actions and the top-level `setup` hook. `params` is optional and
-- opaque; it is handed to the resolved function verbatim.
local function check_call(spec, where)
  if type(spec) ~= "table" then
    fail(where .. " must be an object with `require`/`method`")
  end
  if type(spec.require) ~= "string" or spec.require == "" then
    fail(where .. " `require` must be a non-empty module-name string")
  end
  if type(spec.method) ~= "string" or spec.method == "" then
    fail(where .. " `method` must be a non-empty method-name string")
  end
  return { require = spec.require, method = spec.method, params = spec.params }
end

-- Validate one language block (`{ lsps?, save_actions?, settings? }`) under its key.
local function check_language(key, block, warn)
  if type(block) ~= "table" then
    fail("language '" .. tostring(key) .. "' must be an object")
  end
  local fts = split_filetypes(key)
  if #fts == 0 then
    fail("language key '" .. tostring(key) .. "' names no filetypes")
  end
  local where = "language '" .. tostring(key) .. "':"

  local lsps = {}
  if block.lsps ~= nil then
    if type(block.lsps) ~= "table" then
      fail(where .. " `lsps` must be an object")
    end
    for name, cfg in pairs(block.lsps) do
      if type(name) ~= "string" then
        fail(where .. " `lsps` keys must be server-name strings")
      end
      if type(cfg) ~= "table" then
        fail(where .. " lsp '" .. name .. "' config must be an object")
      end
      lsps[name] = cfg
    end
  end

  local save_actions = {}
  if block.save_actions ~= nil then
    if not is_array(block.save_actions) then
      fail(where .. " `save_actions` must be an array")
    end
    for i, a in ipairs(block.save_actions) do
      save_actions[i] = check_call(a, where .. " save_action[" .. i .. "]")
    end
  end

  local settings = nil
  if block.settings ~= nil then
    settings = check_settings(block.settings, where)
  end

  for k in pairs(block) do
    if k ~= "lsps" and k ~= "save_actions" and k ~= "settings" then
      warn(where .. " unknown key '" .. tostring(k) .. "' (ignored)")
    end
  end

  return { filetypes = fts, lsps = lsps, save_actions = save_actions, settings = settings }
end

-- Normalize + validate a decoded-JSON config table into the canonical shape above.
-- Structural errors fail loud; tolerated oddities (unknown keys) become `warnings`.
function M.normalize(raw)
  if type(raw) ~= "table" then
    fail("config root must be a JSON object")
  end
  if is_array(raw) and next(raw) ~= nil then
    fail("config root must be an object, not an array")
  end

  local warnings = {}
  local function warn(msg)
    warnings[#warnings + 1] = msg
  end

  local settings = nil
  if raw.settings ~= nil then
    settings = check_settings(raw.settings, "top-level")
  end

  -- The optional async `setup` hook: a call spec run + awaited BEFORE the rest of the
  -- config is applied (its Lua lives in the user's config dir; the JSON just names it).
  local setup = nil
  if raw.setup ~= nil then
    setup = check_call(raw.setup, "top-level `setup`")
  end

  local languages = {}
  if raw.languages ~= nil then
    if type(raw.languages) ~= "table" then
      fail("`languages` must be an object")
    end
    for key, block in pairs(raw.languages) do
      languages[#languages + 1] = check_language(key, block, warn)
    end
  end

  for k in pairs(raw) do
    if k ~= "settings" and k ~= "languages" and k ~= "setup" then
      warn("unknown top-level key '" .. tostring(k) .. "' (ignored)")
    end
  end

  return { settings = settings, setup = setup, languages = languages, warnings = warnings }
end

return M
