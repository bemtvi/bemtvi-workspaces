-- The trust gate: prompt once when undecided, remember allow/deny keyed by content hash,
-- re-prompt when the content changes, and persist to a LOCAL store. `trust.confirm` is
-- injected so the "prompt" is deterministic (no real UI dialog).

local trust = require("nxvim-workspaces.trust")

local CFG = "/proj/.nxvim/config.json"
local TEXT = '{"settings":{"tabstop":4}}'

-- Run `fn` with trust.confirm stubbed to always answer `answer`, counting the prompts;
-- returns the count.
local function with_answer(answer, fn)
  local calls = 0
  local orig = trust.confirm
  trust.confirm = function()
    calls = calls + 1
    return nx.promise.resolve(answer)
  end
  local ok, err = pcall(fn)
  trust.confirm = orig
  if not ok then
    error(err)
  end
  return calls
end

nx.test.describe("nxvim-workspaces.trust", function()
  nx.test.it("prompts once when undecided, then remembers 'allow'", function()
    local dir = nx.test.tempdir()
    local a, b
    local calls = with_answer(true, function()
      a = nx.await(trust.ensure(CFG, TEXT, dir))
      b = nx.await(trust.ensure(CFG, TEXT, dir)) -- remembered -> no second prompt
    end)
    nx.test.expect(a).to_be_truthy()
    nx.test.expect(b).to_be_truthy()
    nx.test.expect(calls).to_be(1)
  end)

  nx.test.it("remembers a denial (returns false, no re-prompt)", function()
    local dir = nx.test.tempdir()
    local a, b
    local calls = with_answer(false, function()
      a = nx.await(trust.ensure(CFG, TEXT, dir))
      b = nx.await(trust.ensure(CFG, TEXT, dir))
    end)
    nx.test.expect(a).to_be_falsy()
    nx.test.expect(b).to_be_falsy()
    nx.test.expect(calls).to_be(1)
  end)

  nx.test.it("re-prompts when the config content changes", function()
    local dir = nx.test.tempdir()
    local calls = with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, dir))
      nx.await(trust.ensure(CFG, '{"settings":{"tabstop":8}}', dir)) -- changed -> prompt again
    end)
    nx.test.expect(calls).to_be(2)
  end)

  nx.test.it("forget() makes it re-prompt", function()
    local dir = nx.test.tempdir()
    local calls = with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, dir))
      nx.await(trust.forget(CFG, dir))
      nx.await(trust.ensure(CFG, TEXT, dir))
    end)
    nx.test.expect(calls).to_be(2)
  end)

  nx.test.it("uses a SEPARATE per-config file (no shared store to race on)", function()
    local dir = nx.test.tempdir()
    with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, dir))
      nx.await(trust.ensure("/other/.nxvim/config.json", TEXT, dir))
    end)
    -- Two distinct configs -> two distinct files under the trust dir.
    local entries = nx.await(nx.fs_local.readdir(dir))
    local json = 0
    for _, e in ipairs(entries) do
      if e.name:match("%.json$") then
        json = json + 1
      end
    end
    nx.test.expect(json).to_be(2)
    nx.test.expect(trust.file(CFG, dir)).never.to_be(trust.file("/other/.nxvim/config.json", dir))
  end)

  -- The decision is keyed by the config's ABSOLUTE path, so the same config reached
  -- through a relative path is the same record — not a second, unprompted one.
  nx.test.it("keys the decision to the absolute config path", function()
    local dir = nx.test.tempdir()
    local rel = "wsrel/.nxvim/config.json"
    local abs = vim.fn.fnamemodify(rel, ":p")
    nx.test.expect(trust.file(rel, dir)).to_be(trust.file(abs, dir))

    local calls = with_answer(true, function()
      nx.await(trust.ensure(rel, TEXT, dir))
      nx.await(trust.ensure(abs, TEXT, dir)) -- same config -> remembered, no re-prompt
    end)
    nx.test.expect(calls).to_be(1)

    local rec = nx.json.decode(nx.await(nx.fs_local.read_text(trust.file(abs, dir))))
    nx.test.expect(rec.path).to_be(abs) -- the record stores the absolute path
  end)

  -- The store holds security decisions, so the directory it lives in is private.
  nx.test.it("creates the trust dir private (0700)", function()
    local dir = nx.test.tempdir() .. "/trust"
    with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, dir))
    end)
    local st = nx.await(nx.fs.stat(dir))
    nx.test.expect(string.format("%o", st.mode % 512)).to_be("700")
  end)

  nx.test.it("leaves no temp file behind when the atomic rename fails", function()
    local dir = nx.test.tempdir()
    local orename = nx.fs_local.rename
    nx.fs_local.rename = function()
      return nx.promise.new(function(_, reject)
        reject({ message = "rename failed" })
      end)
    end
    local caught
    nx.await(trust.remember(CFG, TEXT, true, dir):catch(function(e)
      caught = e
      return true
    end))
    nx.fs_local.rename = orename
    nx.test.expect(caught).never.to_be_nil() -- the failure surfaces...
    for _, e in ipairs(nx.await(nx.fs_local.readdir(dir))) do
      nx.test.expect(e.name:match("%.tmp$")).to_be_nil() -- ...and leaves no litter
    end
  end)

  nx.test.it("confirm() is a real floating dialog, answered by y / n", function(t)
    -- Drive the actual grabbing-float dialog (not the stub): `y` trusts.
    local allow = "PENDING"
    trust.confirm("/x/.nxvim/config.json"):next(function(r)
      allow = r
    end)
    t:feed("", { settle = 3 })
    t:feed("y", { settle = 3 })
    nx.test.expect(tostring(allow)).to_be("true")

    -- `n` denies.
    local deny = "PENDING"
    trust.confirm("/x/.nxvim/config.json"):next(function(r)
      deny = r
    end)
    t:feed("", { settle = 3 })
    t:feed("n", { settle = 3 })
    nx.test.expect(tostring(deny)).to_be("false")

    -- <CR> is the default = No (only `y` accepts).
    local cr = "PENDING"
    trust.confirm("/x/.nxvim/config.json"):next(function(r)
      cr = r
    end)
    t:feed("", { settle = 3 })
    t:feed("<CR>", { settle = 3 })
    nx.test.expect(tostring(cr)).to_be("false")
  end)

  nx.test.it("persists the record { path, hash, trusted } to the local file", function()
    local dir = nx.test.tempdir()
    with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, dir))
    end)
    local file = trust.file(CFG, dir)
    nx.test.expect(nx.await(nx.fs_local.exists(file))).to_be_truthy()
    local rec = nx.json.decode(nx.await(nx.fs_local.read_text(file)))
    nx.test.expect(rec.path).to_be(CFG)
    nx.test.expect(rec.trusted).to_be(true)
    nx.test.expect(rec.hash).to_be(trust.hash(TEXT))
    -- No leftover temp files from the atomic write.
    for _, e in ipairs(nx.await(nx.fs_local.readdir(dir))) do
      nx.test.expect(e.name:match("%.tmp$")).to_be_nil()
    end
  end)
end)
