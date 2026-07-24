-- Trust gate for the project config.
--
-- `.nxvim/config.json` executes code on apply — it spawns language-server commands, runs
-- save actions, and calls the async `setup` hook — so applying one from a repo you have
-- not reviewed is a code-execution vector. This module makes the editor ASK before the
-- first apply (an exrc / VSCode-workspace-trust style prompt) and remembers the answer,
-- keyed by the config's absolute path AND a hash of its CONTENT — so a config that
-- changes on disk (e.g. after a pull) is untrusted again and re-prompts.
--
-- The trust store is LOCAL, always. The decision is the user's and must not be
-- spoofable by a remote: in a `--connect-daemon` session the config is remote, but the
-- store is written to the CLIENT's disk through `nx.fs_local` (never `nx.fs`, which would
-- cross to the daemon). Store shape: `{ ["<abspath>"] = { hash = "<sha256>", trusted =
-- <bool> } }`.

local M = {}

-- The local trust-store path (mutable per-user state, alongside shada).
function M.store_path()
  return vim.fn.stdpath("state") .. "/nxvim-workspaces/trust.json"
end

-- The content hash a decision is bound to.
function M.hash(text)
  return nx.hash.sha256(text)
end

-- The confirmation prompt. Overridable (tests inject a deterministic answer). Defaults
-- to No, so a stray `<CR>` never trusts.
function M.confirm(config_path)
  return nx.ui.confirm(
    "nxvim-workspaces: '"
      .. config_path
      .. "' can run code (LSP servers, save actions, the setup hook). Trust and apply it?",
    { default = false }
  )
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$")
end

-- Read the local trust store (map). Missing / unreadable / malformed -> empty.
function M.load_store(store_path)
  store_path = store_path or M.store_path()
  return nx.async(function()
    if not nx.await(nx.fs_local.exists(store_path)) then
      return {}
    end
    local ok, text = pcall(nx.await, nx.fs_local.read_text(store_path))
    if not ok then
      return {}
    end
    local ok2, data = pcall(nx.json.decode, text)
    if not ok2 or type(data) ~= "table" then
      return {}
    end
    return data
  end)()
end

-- Record a decision (allow / deny) for `config_path` at its current content, on the
-- local disk. Returns a promise.
function M.remember(config_path, text, trusted, store_path)
  store_path = store_path or M.store_path()
  return nx.async(function()
    local store = nx.await(M.load_store(store_path))
    store[config_path] = { hash = M.hash(text), trusted = trusted and true or false }
    local dir = dirname(store_path)
    if dir then
      nx.await(nx.fs_local.mkdir(dir, { recursive = true }))
    end
    nx.await(nx.fs_local.write(store_path, nx.json.encode(store, { pretty = true })))
  end)()
end

-- Forget any decision for `config_path`, so the next apply re-prompts. Returns a promise.
function M.forget(config_path, store_path)
  store_path = store_path or M.store_path()
  return nx.async(function()
    local store = nx.await(M.load_store(store_path))
    if store[config_path] == nil then
      return
    end
    store[config_path] = nil
    nx.await(nx.fs_local.write(store_path, nx.json.encode(store, { pretty = true })))
  end)()
end

-- The recorded verdict for `config_path` at its CURRENT content: `true` (allowed),
-- `false` (denied), or `nil` (undecided — no record, or the content changed since).
function M.decision(config_path, text, store_path)
  return nx.async(function()
    local rec = nx.await(M.load_store(store_path))[config_path]
    if type(rec) ~= "table" or rec.hash ~= M.hash(text) then
      return nil
    end
    return rec.trusted == true
  end)()
end

-- The gate: resolve to whether `config_path` may be applied. Uses the remembered
-- decision when the content is unchanged; otherwise PROMPTS and persists the answer.
function M.ensure(config_path, text, store_path)
  return nx.async(function()
    local decided = nx.await(M.decision(config_path, text, store_path))
    if decided ~= nil then
      return decided
    end
    local yes = nx.await(M.confirm(config_path))
    nx.await(M.remember(config_path, text, yes, store_path))
    return yes
  end)()
end

return M
