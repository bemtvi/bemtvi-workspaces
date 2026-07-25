-- Trust gate for the project config.
--
-- `.nxvim/config.json` executes code on apply — it spawns language-server commands, runs
-- save actions, and calls the async `setup` hook — so applying one from a repo you have
-- not reviewed is a code-execution vector. This module makes the editor ASK before the
-- first apply (an exrc / VSCode-workspace-trust style prompt) and remembers the answer,
-- keyed by the config's absolute path AND a hash of its CONTENT — so a config that
-- changes on disk (e.g. after a pull) is untrusted again and re-prompts.
--
-- STORAGE. One file PER CONFIG (named by a hash of the config's absolute path — every
-- path is canonicalized through `M.abs`, so the same config reached relatively is one
-- record, not a second unprompted one) under a trust dir, rather than a single shared
-- `trust.json`: unrelated workspaces never touch the same file, so concurrent editors
-- can't clobber each other's decisions with a read-modify-write race. The dir is created
-- 0700 — these are security decisions, not shared state. Each record is written
-- ATOMICALLY — to a unique temp file in the same dir, then renamed over the target
-- (rename is atomic on a POSIX fs) — so a reader never sees a half-written file and a
-- crash mid-write can't corrupt a record.
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

-- The permission bits the trust dir is created with. It holds security decisions, so it
-- is the user's alone (0700) rather than the 0755 a plain mkdir would give it.
local DIR_MODE = tonumber("700", 8)

-- The canonical form of a config path: ABSOLUTE, so the same config reached two ways
-- (a relative `setup({ path = … })`, a `..`-laden workspace root) is one record rather
-- than a second, silently-unprompted one. Every path that keys or lands in a record
-- goes through here.
function M.abs(config_path)
  return vim.fn.fnamemodify(config_path, ":p")
end

-- This config's record file: one per config PATH, named by the hash of its ABSOLUTE
-- form so unrelated workspaces never share a file. `dir` overrides the trust dir (tests).
function M.file(config_path, dir)
  return (dir or M.dir()) .. "/" .. nx.hash.sha256(M.abs(config_path)) .. ".json"
end

-- The content hash a decision is bound to.
function M.hash(text)
  return nx.hash.sha256(text)
end

-- The confirmation prompt -> promise of a boolean. A centered, focus-grabbing floating
-- window (a real modal dialog on the `nx.component` "view" surface — the shape the
-- `:Plugins` dialogs use), so a decision this consequential is impossible to miss. Only
-- `y`/`Y` trusts; everything else — `n`/`q`/`<Esc>` AND `<CR>` — declines, so No is the
-- default and trusting is a deliberate `y`. Overridable — tests inject a deterministic
-- answer.
function M.confirm(config_path)
  return nx.promise.new(function(resolve)
    -- The float is capped at 100 columns, so a deep path is elided from the LEFT — the
    -- tail (…/<project>/.nxvim/config.json) is the part that identifies it. Leading
    -- COMPONENTS are dropped whole, so the elision never cuts a path element (or a
    -- multi-byte character) in half.
    local shown = M.abs(config_path)
    local max_path = 94
    if #shown > max_path then
      local parts = nx.str.split(shown, "/")
      while #parts > 1 and #table.concat(parts, "/") + 2 > max_path do
        table.remove(parts, 1)
      end
      shown = "…/" .. table.concat(parts, "/")
    end
    local lines = {
      "This workspace wants to apply its config:",
      "  " .. shown,
      "",
      "Applying it RUNS CODE — language servers, save",
      "actions, and the setup hook.",
      "",
      "  [y] Trust and apply      [N] Don't trust (default)",
    }
    local width = 40
    for _, l in ipairs(lines) do
      width = math.max(width, nx.str.displaywidth(l))
    end
    width = math.min(width + 2, 100)

    local done = false
    local dialog = nx.component({
      setup = function(ctx)
        local function decide(v)
          if done then
            return
          end
          done = true
          ctx.close()
          resolve(v)
        end
        -- Only `y`/`Y` accepts; everything else (incl. `<CR>`) declines — No is default.
        for _, k in ipairs({ "y", "Y" }) do
          ctx.keymap_set("n", k, function()
            decide(true)
          end)
        end
        for _, k in ipairs({ "n", "N", "q", "<Esc>", "<CR>" }) do
          ctx.keymap_set("n", k, function()
            decide(false)
          end)
        end
        return {}
      end,
      render = function()
        return { lines = lines }
      end,
    })
    dialog.mount({
      name = "[nxvim-workspaces trust]",
      float = {
        width = width,
        height = #lines,
        grab = true,
        relative = "editor",
        align = "center",
        border = "rounded",
        title = " nxvim-workspaces — trust this config? ",
      },
    })
  end)
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
-- rename it over the target. Local seam. Returns a promise. A failed write/rename is
-- reported (never swallowed) but takes its half-written temp file with it, so a failure
-- leaves no litter in the store.
function M.write_record(config_path, rec, dir)
  return nx.async(function()
    local trust_dir = dir or M.dir()
    nx.await(nx.fs_local.mkdir(trust_dir, { recursive = true, mode = DIR_MODE }))
    local final = M.file(config_path, dir)
    local tmp = final .. "." .. nx.uuid() .. ".tmp"
    nx.await(nx.fs_local.write(tmp, nx.json.encode(rec, { pretty = true })))
    local ok, err = pcall(nx.await, nx.fs_local.rename(tmp, final))
    if not ok then
      pcall(nx.await, nx.fs_local.remove(tmp))
      error(err, 0)
    end
  end)()
end

-- Record a decision (allow / deny) for `config_path` at its current content.
function M.remember(config_path, text, trusted, dir)
  return M.write_record(config_path, {
    path = M.abs(config_path),
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
