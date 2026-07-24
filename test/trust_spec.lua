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
    local store = nx.test.tempdir() .. "/trust.json"
    local a, b
    local calls = with_answer(true, function()
      a = nx.await(trust.ensure(CFG, TEXT, store))
      b = nx.await(trust.ensure(CFG, TEXT, store)) -- remembered -> no second prompt
    end)
    nx.test.expect(a).to_be_truthy()
    nx.test.expect(b).to_be_truthy()
    nx.test.expect(calls).to_be(1)
  end)

  nx.test.it("remembers a denial (returns false, no re-prompt)", function()
    local store = nx.test.tempdir() .. "/trust.json"
    local a, b
    local calls = with_answer(false, function()
      a = nx.await(trust.ensure(CFG, TEXT, store))
      b = nx.await(trust.ensure(CFG, TEXT, store))
    end)
    nx.test.expect(a).to_be_falsy()
    nx.test.expect(b).to_be_falsy()
    nx.test.expect(calls).to_be(1)
  end)

  nx.test.it("re-prompts when the config content changes", function()
    local store = nx.test.tempdir() .. "/trust.json"
    local calls = with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, store))
      nx.await(trust.ensure(CFG, '{"settings":{"tabstop":8}}', store)) -- changed -> prompt again
    end)
    nx.test.expect(calls).to_be(2)
  end)

  nx.test.it("forget() makes it re-prompt", function()
    local store = nx.test.tempdir() .. "/trust.json"
    local calls = with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, store))
      nx.await(trust.forget(CFG, store))
      nx.await(trust.ensure(CFG, TEXT, store))
    end)
    nx.test.expect(calls).to_be(2)
  end)

  nx.test.it("persists to the LOCAL store, keyed by path -> { hash, trusted }", function()
    local store = nx.test.tempdir() .. "/sub/trust.json"
    with_answer(true, function()
      nx.await(trust.ensure(CFG, TEXT, store))
    end)
    nx.test.expect(nx.await(nx.fs_local.exists(store))).to_be_truthy()
    local data = nx.json.decode(nx.await(nx.fs_local.read_text(store)))
    nx.test.expect(data[CFG].trusted).to_be(true)
    nx.test.expect(data[CFG].hash).to_be(trust.hash(TEXT))
  end)
end)
