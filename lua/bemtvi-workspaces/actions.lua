-- The save-action runner.
--
-- A save action is `{ require = <module>, method = <name>, params = <any?> }` — the
-- declarative twin of `require(<module>)[<name>](<params>)`. `run` resolves each one to
-- a callable and invokes them IN ORDER; when an action returns a promise, it is awaited
-- before the next runs (so a promise-returning formatter completes before the write).
-- `run_and_write` chains a `:write` after the last action settles.
--
-- The built-in `btv.lsp.*` verbs (`format`, `code_action`, `rename`, …) are among those:
-- each returns an `btv.promise` that resolves once the round-trip completes and its edit
-- is applied, so a `[code_action, format]` chain runs strictly in order and the `:write`
-- lands after the language server's last edit — not after a bare enqueue.
--
-- Those verbs are RESOLVE-ONLY: a benign no-op (no server attached, a superseded
-- request, an empty result, a cancelled prompt/chooser) resolves `nil` rather than
-- rejecting, so such an action never aborts the chain or blocks the write. Only a real
-- failure — an unresolvable module/method, or an action that raises — does.

local M = {}

-- A thenable is our await handle: a table exposing a `:next` method (an `btv.promise`).
local function is_thenable(v)
  return type(v) == "table" and type(v.next) == "function"
end
M.is_thenable = is_thenable

-- Resolve `name` to a table: prefer a real Lua module (`require`), else a DOTTED GLOBAL
-- path (`btv.lsp`, …). The built-in editor verbs (format, code_action)
-- live on global tables rather than modules, so both forms are supported — a `require`
-- name for plugin modules (`conform`, `btv.lsp.buf`-style modules), a dotted path for the
-- globals. Returns `(tbl)`, or `(nil, require_error)` when neither resolves.
local function resolve_module(name)
  local ok, mod = pcall(require, name)
  if ok and (type(mod) == "table" or type(mod) == "userdata") then
    return mod
  end
  local req_err = (not ok) and tostring(mod) or nil
  -- selene: allow(global_usage) -- walking a dotted global path is the feature itself
  local cur = _G
  for part in name:gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return nil, req_err
    end
    cur = cur[part]
  end
  if type(cur) == "table" or type(cur) == "userdata" then
    return cur
  end
  return nil, req_err
end

-- Resolve an action to its callable. Fails LOUD when the module/global can't be found
-- or the method isn't a function on it (a broken action is a config mistake, never a
-- silent no-op).
function M.resolve(action)
  local mod, req_err = resolve_module(action.require)
  if not mod then
    local hint = req_err and (" (" .. req_err .. ")") or ""
    error(
      "bemtvi-workspaces: cannot resolve '" .. action.require .. "' as a module or global" .. hint,
      0
    )
  end
  local fn = mod[action.method]
  if type(fn) ~= "function" then
    error(
      "bemtvi-workspaces: '" .. action.require .. "." .. action.method .. "' is not a function",
      0
    )
  end
  return fn
end

-- Run `actions` in order, awaiting any that return a promise. Returns a promise that
-- fulfils once all have completed, or rejects on the first failure (resolve/invoke).
--
-- Resolution is pure lookup with no side effects, so the WHOLE chain is resolved before
-- anything runs: a typo in the last action fails the run without half-applying the ones
-- before it (the same validate-before-you-touch-anything order `templates.add` uses).
function M.run(actions)
  return btv.async(function()
    local calls = {}
    for i, action in ipairs(actions) do
      calls[i] = { fn = M.resolve(action), params = action.params }
    end
    for _, call in ipairs(calls) do
      local result = call.fn(call.params)
      if is_thenable(result) then
        btv.await(result)
      end
    end
  end)()
end

-- The `<C-s>` handler: run the save actions, then `:write` — but only after every
-- action has settled, and never when one failed (the failure is surfaced loud instead).
function M.run_and_write(actions)
  return M.run(actions)
    :next(function()
      btv.cmd("write")
    end)
    :catch(function(err)
      local msg = type(err) == "table" and err.message or err
      btv.notify("bemtvi-workspaces: save actions failed: " .. tostring(msg), btv.log.levels.ERROR)
    end)
end

return M
