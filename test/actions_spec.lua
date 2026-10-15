-- The save-action runner: resolution (fail loud on a bad module/method), in-order
-- execution that AWAITS promise-returning actions, and run_and_write's write-after-
-- settle (and its skip-and-notify on failure). Uses a mock target module so the
-- assertions turn on the runner's behavior, not on any real editor verb.

local actions = require("bemtvi-workspaces.actions")

-- A mock module for save actions: records call order, offers a sync method, a
-- deferred-promise method (resolves on the NEXT tick — so "did the runner wait?" is
-- observable), and a throwing one.
local function make_mock()
  local mock = { calls = {} }
  function mock.sync(params)
    mock.calls[#mock.calls + 1] = { m = "sync", p = params }
  end
  function mock.asyncf(params)
    mock.calls[#mock.calls + 1] = { m = "asyncf-start", p = params }
    return btv.promise.new(function(resolve)
      btv.on_next_tick(function()
        mock.calls[#mock.calls + 1] = { m = "asyncf-done", p = params }
        resolve(true)
      end)
    end)
  end
  function mock.boom()
    error("kaboom")
  end
  return mock
end

btv.test.describe("bemtvi-workspaces.actions.resolve", function()
  btv.test.it("fails loud when neither a module nor a global resolves", function()
    btv.test
      .expect(function()
        actions.resolve({ require = "no_such_module_xyz", method = "x" })
      end)
      .to_error("cannot resolve")
  end)
  btv.test.it("fails loud on a missing method", function()
    package.loaded["bemtvi_ws_mock"] = make_mock()
    btv.test
      .expect(function()
        actions.resolve({ require = "bemtvi_ws_mock", method = "nope" })
      end)
      .to_error("is not a function")
  end)
  btv.test.it("resolves a real module method to its function", function()
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    btv.test
      .expect(actions.resolve({ require = "bemtvi_ws_mock", method = "sync" }))
      .to_be(mock.sync)
  end)
  btv.test.it("resolves a dotted GLOBAL path (btv.cmd) — the built-in verb form", function()
    btv.test.expect(actions.resolve({ require = "btv", method = "cmd" })).to_be(btv.cmd)
  end)
  btv.test.it("resolves a deeper global path (btv.lsp.format)", function()
    btv.test
      .expect(actions.resolve({ require = "btv.lsp", method = "format" }))
      .to_be(btv.lsp.format)
  end)

  -- The README's save-action table is a promise about what a config may name. Pin it,
  -- so a documented target can't quietly stop resolving (there is no `btv.lsp.buf` — a
  -- config naming it fails loud at save time, which is why the docs must not offer it).
  btv.test.it("resolves every save-action target the README documents", function()
    for _, spec in ipairs({
      { require = "btv.lsp", method = "format" },
      { require = "btv.lsp", method = "code_action" },
      { require = "btv.lsp", method = "rename" },
    }) do
      btv.test.expect(type(actions.resolve(spec))).to_be("function")
    end
  end)

  btv.test.it("fails loud on `btv.lsp.buf`, which does not exist", function()
    btv.test
      .expect(function()
        actions.resolve({ require = "btv.lsp.buf", method = "format" })
      end)
      .to_error("cannot resolve")
  end)
end)

btv.test.describe("bemtvi-workspaces.actions + the built-in btv.lsp verbs", function()
  -- The verbs return an btv.promise (resolving when the round-trip's edit is applied), so
  -- the runner treats them as await handles and the write lands after the last edit.
  -- With no server attached they resolve nil — a benign no-op that must neither hang nor
  -- abort the chain.
  btv.test.it("btv.lsp.format() hands back an await handle the runner recognizes", function()
    local handle = btv.lsp.format()
    btv.test.expect(actions.is_thenable(handle)).to_be_truthy()
    btv.await(handle) -- settles (nil) with no server attached rather than hanging
  end)

  btv.test.it("sequences a later action after an awaited btv.lsp verb", function()
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    btv.await(actions.run({
      { require = "btv.lsp", method = "format" },
      { require = "bemtvi_ws_mock", method = "sync", params = "after-format" },
    }))
    btv.test.expect(#mock.calls).to_be(1)
    btv.test.expect(mock.calls[1].p).to_be("after-format")
  end)

  -- A save action's `params` is the verb's argument, so the JSON a config carries for
  -- the fixAll-then-format chain has to be a shape `btv.lsp.code_action` accepts. It
  -- validates loudly, so a params shape it rejects would fail the run here.
  btv.test.it("passes a code_action's JSON params through to the verb", function()
    local decoded = btv.json.decode('{ "context": { "only": ["source.fixAll"] }, "apply": true }')
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    btv.await(actions.run({
      { require = "btv.lsp", method = "code_action", params = decoded },
      { require = "bemtvi_ws_mock", method = "sync", params = "after-fixall" },
    }))
    -- No server attached ⇒ the verb is a benign no-op that still settles, so the rest
    -- of the chain (and, in the real handler, the write) proceeds.
    btv.test.expect(#mock.calls).to_be(1)
    btv.test.expect(mock.calls[1].p).to_be("after-fixall")
  end)

  btv.test.it("surfaces a params shape the verb rejects", function()
    btv.test
      .expect(function()
        btv.await(actions.run({
          { require = "btv.lsp", method = "code_action", params = { filter = function() end } },
        }))
      end)
      .to_error("unsupported option")
  end)
end)

btv.test.describe("bemtvi-workspaces.actions.run", function()
  btv.test.it("runs actions in order, awaiting the promise-returning one first", function()
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    btv.await(actions.run({
      { require = "bemtvi_ws_mock", method = "asyncf", params = "a" },
      { require = "bemtvi_ws_mock", method = "sync", params = "b" },
    }))
    -- asyncf must fully finish (start THEN done) before sync runs.
    btv.test.expect(#mock.calls).to_be(3)
    btv.test.expect(mock.calls[1].m).to_be("asyncf-start")
    btv.test.expect(mock.calls[2].m).to_be("asyncf-done")
    btv.test.expect(mock.calls[3].m).to_be("sync")
    btv.test.expect(mock.calls[3].p).to_be("b")
  end)

  -- Resolution is pure lookup, so it happens for the WHOLE chain up front: a typo in the
  -- last action must not leave the earlier ones half-applied (the same validate-before-
  -- you-touch-anything discipline templates.add uses before writing).
  btv.test.it("resolves every action before running any (a bad one runs nothing)", function()
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    local caught
    btv.await(actions
      .run({
        { require = "bemtvi_ws_mock", method = "sync", params = "first" },
        { require = "bemtvi_ws_mock", method = "no_such_method" },
      })
      :catch(function(e)
        caught = e
        return true
      end))
    btv.test.expect(caught).never.to_be_nil()
    btv.test.expect(#mock.calls).to_be(0) -- the good first action never ran
  end)

  btv.test.it("rejects when an action throws", function()
    package.loaded["bemtvi_ws_mock"] = make_mock()
    local caught
    btv.await(actions.run({ { require = "bemtvi_ws_mock", method = "boom" } }):catch(function(e)
      caught = e
      return true
    end))
    btv.test.expect(caught).never.to_be_nil()
  end)
end)

btv.test.describe("bemtvi-workspaces.actions.run_and_write", function()
  btv.test.it("writes only after every action has settled", function()
    local mock = make_mock()
    package.loaded["bemtvi_ws_mock"] = mock
    local wrote_at
    local ocmd = btv.cmd
    btv.cmd = function(c)
      if c == "write" then
        wrote_at = #mock.calls -- how many action-calls had happened at write time
      end
    end
    btv.await(actions.run_and_write({
      { require = "bemtvi_ws_mock", method = "asyncf", params = "z" },
    }))
    btv.cmd = ocmd
    -- The write ran after asyncf-start AND asyncf-done (2 recorded calls).
    btv.test.expect(wrote_at).to_be(2)
    btv.test.expect(mock.calls[2].m).to_be("asyncf-done")
  end)

  btv.test.it("skips the write and notifies on a failing action", function()
    package.loaded["bemtvi_ws_mock"] = make_mock()
    local wrote, notified = false, false
    local ocmd, onotify = btv.cmd, btv.notify
    btv.cmd = function(c)
      if c == "write" then
        wrote = true
      end
    end
    btv.notify = function()
      notified = true
    end
    btv.await(actions.run_and_write({ { require = "bemtvi_ws_mock", method = "boom" } }))
    btv.cmd, btv.notify = ocmd, onotify
    btv.test.expect(wrote).to_be_falsy()
    btv.test.expect(notified).to_be_truthy()
  end)
end)
