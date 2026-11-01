-- The trust gate: prompt once when undecided, remember allow/deny keyed by content hash,
-- re-prompt when the content changes, and persist to a LOCAL store. `trust.confirm` is
-- injected so the "prompt" is deterministic (no real UI dialog).

local trust = require("bemtvi-workspaces.trust")

local CFG = "/proj/.bemtvi/config.json"
local TEXT = '{"settings":{"tabstop":4}}'

-- Run `fn` with trust.confirm stubbed to always answer `answer`, counting the prompts;
-- returns the count.
local function with_answer(answer, fn)
  local calls = 0
  local orig = trust.confirm
  trust.confirm = function()
    calls = calls + 1
    return btv.promise.resolve(answer)
  end
  local ok, err = pcall(fn)
  trust.confirm = orig
  if not ok then
    error(err)
  end
  return calls
end

btv.test.describe("bemtvi-workspaces.trust", function()
  btv.test.it("prompts once when undecided, then remembers 'allow'", function()
    local dir = btv.test.tempdir()
    local a, b
    local calls = with_answer(true, function()
      a = btv.await(trust.ensure(CFG, TEXT, dir))
      b = btv.await(trust.ensure(CFG, TEXT, dir)) -- remembered -> no second prompt
    end)
    btv.test.expect(a).to_be_truthy()
    btv.test.expect(b).to_be_truthy()
    btv.test.expect(calls).to_be(1)
  end)

  btv.test.it("remembers a denial (returns false, no re-prompt)", function()
    local dir = btv.test.tempdir()
    local a, b
    local calls = with_answer(false, function()
      a = btv.await(trust.ensure(CFG, TEXT, dir))
      b = btv.await(trust.ensure(CFG, TEXT, dir))
    end)
    btv.test.expect(a).to_be_falsy()
    btv.test.expect(b).to_be_falsy()
    btv.test.expect(calls).to_be(1)
  end)

  btv.test.it("re-prompts when the config content changes", function()
    local dir = btv.test.tempdir()
    local calls = with_answer(true, function()
      btv.await(trust.ensure(CFG, TEXT, dir))
      btv.await(trust.ensure(CFG, '{"settings":{"tabstop":8}}', dir)) -- changed -> prompt again
    end)
    btv.test.expect(calls).to_be(2)
  end)

  btv.test.it("forget() makes it re-prompt", function()
    local dir = btv.test.tempdir()
    local calls = with_answer(true, function()
      btv.await(trust.ensure(CFG, TEXT, dir))
      btv.await(trust.forget(CFG, dir))
      btv.await(trust.ensure(CFG, TEXT, dir))
    end)
    btv.test.expect(calls).to_be(2)
  end)

  btv.test.it("uses a SEPARATE per-config file (no shared store to race on)", function()
    local dir = btv.test.tempdir()
    with_answer(true, function()
      btv.await(trust.ensure(CFG, TEXT, dir))
      btv.await(trust.ensure("/other/.bemtvi/config.json", TEXT, dir))
    end)
    -- Two distinct configs -> two distinct files under the trust dir.
    local entries = btv.await(btv.fs_local.readdir(dir))
    local json = 0
    for _, e in ipairs(entries) do
      if e.name:match("%.json$") then
        json = json + 1
      end
    end
    btv.test.expect(json).to_be(2)
    btv.test.expect(trust.file(CFG, dir)).never.to_be(trust.file("/other/.bemtvi/config.json", dir))
  end)

  -- The decision is keyed by the config's ABSOLUTE path, so the same config reached
  -- through a relative path is the same record — not a second, unprompted one.
  btv.test.it("keys the decision to the absolute config path", function()
    local dir = btv.test.tempdir()
    local rel = "wsrel/.bemtvi/config.json"
    local abs = btv.fname.modify(rel, ":p")
    btv.test.expect(trust.file(rel, dir)).to_be(trust.file(abs, dir))

    local calls = with_answer(true, function()
      btv.await(trust.ensure(rel, TEXT, dir))
      btv.await(trust.ensure(abs, TEXT, dir)) -- same config -> remembered, no re-prompt
    end)
    btv.test.expect(calls).to_be(1)

    local rec = btv.json.decode(btv.await(btv.fs_local.read_text(trust.file(abs, dir))))
    btv.test.expect(rec.path).to_be(abs) -- the record stores the absolute path
  end)

  -- The store holds security decisions, so the directory it lives in is private.
  btv.test.it("creates the trust dir private (0700)", function()
    local dir = btv.test.tempdir() .. "/trust"
    with_answer(true, function()
      btv.await(trust.ensure(CFG, TEXT, dir))
    end)
    local st = btv.await(btv.fs.stat(dir))
    btv.test.expect(string.format("%o", st.mode % 512)).to_be("700")
  end)

  btv.test.it("leaves no temp file behind when the atomic rename fails", function()
    local dir = btv.test.tempdir()
    local orename = btv.fs_local.rename
    btv.fs_local.rename = function()
      return btv.promise.new(function(_, reject)
        reject({ message = "rename failed" })
      end)
    end
    local caught
    btv.await(trust.remember(CFG, TEXT, true, dir):catch(function(e)
      caught = e
      return true
    end))
    btv.fs_local.rename = orename
    btv.test.expect(caught).never.to_be_nil() -- the failure surfaces...
    for _, e in ipairs(btv.await(btv.fs_local.readdir(dir))) do
      btv.test.expect(e.name:match("%.tmp$")).to_be_nil() -- ...and leaves no litter
    end
  end)

  btv.test.it("confirm() is a real floating dialog, answered by y / n", function(t)
    -- Drive the actual grabbing-float dialog (not the stub): `y` trusts.
    local allow = "PENDING"
    trust.confirm("/x/.bemtvi/config.json"):next(function(r)
      allow = r
    end)
    t:feed("", { settle = 3 })
    t:feed("y", { settle = 3 })
    btv.test.expect(tostring(allow)).to_be("true")

    -- `n` denies.
    local deny = "PENDING"
    trust.confirm("/x/.bemtvi/config.json"):next(function(r)
      deny = r
    end)
    t:feed("", { settle = 3 })
    t:feed("n", { settle = 3 })
    btv.test.expect(tostring(deny)).to_be("false")

    -- <CR> is the default = No (only `y` accepts).
    local cr = "PENDING"
    trust.confirm("/x/.bemtvi/config.json"):next(function(r)
      cr = r
    end)
    t:feed("", { settle = 3 })
    t:feed("<CR>", { settle = 3 })
    btv.test.expect(tostring(cr)).to_be("false")
  end)

  -- A modeless session (`'modeless'`, GUI and web) has no Normal mode: the dialog rests
  -- in Insert, refuses typing, and takes its keys through the `modeless` keymap layer.
  -- Without them nothing answers the grabbing dialog, and the user is stuck in it.
  btv.test.it("answers y / n / <Esc> in a modeless session", function(t)
    btv.o.modeless = true
    for key, want in pairs({ y = "true", n = "false", ["<Esc>"] = "false" }) do
      local got = "PENDING"
      trust.confirm("/x/.bemtvi/config.json"):next(function(r)
        got = r
      end)
      t:feed("", { settle = 3 })
      t:feed(key, { settle = 3 })
      btv.test.expect(key .. "=" .. tostring(got)).to_be(key .. "=" .. want)
    end
  end)

  btv.test.it("persists the record { path, hash, trusted } to the local file", function()
    local dir = btv.test.tempdir()
    with_answer(true, function()
      btv.await(trust.ensure(CFG, TEXT, dir))
    end)
    local file = trust.file(CFG, dir)
    btv.test.expect(btv.await(btv.fs_local.exists(file))).to_be_truthy()
    local rec = btv.json.decode(btv.await(btv.fs_local.read_text(file)))
    btv.test.expect(rec.path).to_be(CFG)
    btv.test.expect(rec.trusted).to_be(true)
    btv.test.expect(rec.hash).to_be(trust.hash(TEXT))
    -- No leftover temp files from the atomic write.
    for _, e in ipairs(btv.await(btv.fs_local.readdir(dir))) do
      btv.test.expect(e.name:match("%.tmp$")).to_be_nil()
    end
  end)
end)
