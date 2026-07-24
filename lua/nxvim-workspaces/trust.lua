-- Trust gate for the project config.
--
-- `.nxvim/config.json` executes code on apply — it spawns language-server commands, runs
-- save actions, and calls the async `setup` hook — so applying one from a repo you have
-- not reviewed is a code-execution vector. This module makes the editor ASK before the
-- first apply (an exrc / VSCode-workspace-trust style prompt) and remembers the answer,
-- keyed by the config's absolute path AND a hash of its CONTENT — so a config that
-- changes on disk (e.g. after a pull) is untrusted again and re-prompts.
--
-- STORAGE. One file PER CONFIG (named by a hash of the config's absolute path) under a
-- trust dir, rather than a single shared `trust.json`: unrelated workspaces never touch
-- the same file, so concurrent editors can't clobber each other's decisions with a
-- read-modify-write race. Each record is written ATOMICALLY — to a unique temp file in
-- the same dir, then renamed over the target (rename is atomic on a POSIX fs) — so a
-- reader never sees a half-written file and a crash mid-write can't corrupt a record.
--
-- The trust dir is LOCAL, always. The decision is the user's and must not be spoofable
-- by a remote: in a `--connect-daemon` session the config is remote, but the store is on
-- the CLIENT's disk through `nx.fs_local` (never `nx.fs`, which would cross to the
-- daemon). Record shape: `{ path = "<abspath>", hash = "<sha256>", trusted = <bool> }`.

local M = {}

-- The local trust directory (per-config files live here), alongside shada state.
function M.dir()
  return vim.fn.stdpath("state") .. "/nxvim-workspaces/trust"
end

-- This config's record file: one per config PATH, named by its hash so unrelated
-- workspaces never share a file. `dir` overrides the trust dir (tests).
function M.file(config_path, dir)
  return (dir or M.dir()) .. "/" .. nx.hash.sha256(config_path) .. ".json"
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

-- Read this config's record (or nil when absent / unreadable / malformed). Local seam.
function M.read_record(config_path, dir)
  return nx.async(function()
    local path = M.file(config_path, dir)
    if not nx.await(nx.fs_local.exists(path)) then
      return nil
    end
    local ok, text = pcall(nx.await, nx.fs_local.read_text(path))
    if not ok then
      return nil
    end
    local ok2, rec = pcall(nx.json.decode, text)
    if not ok2 or type(rec) ~= "table" then
      return nil
    end
    return rec
  end)()
end

-- Atomically write this config's record: write a unique temp file in the trust dir, then
-- rename it over the target. Local seam. Returns a promise.
function M.write_record(config_path, rec, dir)
  return nx.async(function()
    local trust_dir = dir or M.dir()
    nx.await(nx.fs_local.mkdir(trust_dir, { recursive = true }))
    local final = M.file(config_path, dir)
    local tmp = final .. "." .. nx.uuid() .. ".tmp"
    nx.await(nx.fs_local.write(tmp, nx.json.encode(rec, { pretty = true })))
    nx.await(nx.fs_local.rename(tmp, final))
  end)()
end

-- Record a decision (allow / deny) for `config_path` at its current content.
function M.remember(config_path, text, trusted, dir)
  return M.write_record(config_path, {
    path = config_path,
    hash = M.hash(text),
    trusted = trusted and true or false,
  }, dir)
end

-- Forget any decision for `config_path`, so the next apply re-prompts. Returns a promise.
function M.forget(config_path, dir)
  return nx.async(function()
    local path = M.file(config_path, dir)
    if nx.await(nx.fs_local.exists(path)) then
      nx.await(nx.fs_local.remove(path))
    end
  end)()
end

-- The recorded verdict for `config_path` at its CURRENT content: `true` (allowed),
-- `false` (denied), or `nil` (undecided — no record, or the content changed since).
function M.decision(config_path, text, dir)
  return nx.async(function()
    local rec = nx.await(M.read_record(config_path, dir))
    if type(rec) ~= "table" or rec.hash ~= M.hash(text) then
      return nil
    end
    return rec.trusted == true
  end)()
end

-- The gate: resolve to whether `config_path` may be applied. Uses the remembered
-- decision when the content is unchanged; otherwise PROMPTS and persists the answer.
function M.ensure(config_path, text, dir)
  return nx.async(function()
    local decided = nx.await(M.decision(config_path, text, dir))
    if decided ~= nil then
      return decided
    end
    local yes = nx.await(M.confirm(config_path))
    nx.await(M.remember(config_path, text, yes, dir))
    return yes
  end)()
end

return M
