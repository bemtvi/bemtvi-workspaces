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
