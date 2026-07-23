-- The save-action runner: resolution (fail loud on a bad module/method), in-order
-- execution that AWAITS promise-returning actions, and run_and_write's write-after-
-- settle (and its skip-and-notify on failure). Uses a mock target module so the
-- assertions turn on the runner's behavior, not on any real editor verb.

local actions = require("nxvim-workspaces.actions")

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
    return nx.promise.new(function(resolve)
      nx.on_next_tick(function()
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

nx.test.describe("nxvim-workspaces.actions.resolve", function()
  nx.test.it("fails loud when neither a module nor a global resolves", function()
    nx.test
      .expect(function()
        actions.resolve({ require = "no_such_module_xyz", method = "x" })
      end)
      .to_error("cannot resolve")
  end)
  nx.test.it("fails loud on a missing method", function()
    package.loaded["nxvim_ws_mock"] = make_mock()
    nx.test
      .expect(function()
        actions.resolve({ require = "nxvim_ws_mock", method = "nope" })
      end)
      .to_error("is not a function")
  end)
  nx.test.it("resolves a real module method to its function", function()
    local mock = make_mock()
    package.loaded["nxvim_ws_mock"] = mock
    nx.test.expect(actions.resolve({ require = "nxvim_ws_mock", method = "sync" })).to_be(mock.sync)
  end)
  nx.test.it("resolves a dotted GLOBAL path (nx.cmd) — the built-in verb form", function()
    nx.test.expect(actions.resolve({ require = "nx", method = "cmd" })).to_be(nx.cmd)
  end)
  nx.test.it("resolves a deeper global path (vim.lsp.buf.format)", function()
    nx.test
      .expect(actions.resolve({ require = "vim.lsp.buf", method = "format" }))
      .to_be(vim.lsp.buf.format)
  end)
end)

nx.test.describe("nxvim-workspaces.actions.run", function()
  nx.test.it("runs actions in order, awaiting the promise-returning one first", function()
    local mock = make_mock()
    package.loaded["nxvim_ws_mock"] = mock
    nx.await(actions.run({
      { require = "nxvim_ws_mock", method = "asyncf", params = "a" },
      { require = "nxvim_ws_mock", method = "sync", params = "b" },
    }))
    -- asyncf must fully finish (start THEN done) before sync runs.
    nx.test.expect(#mock.calls).to_be(3)
    nx.test.expect(mock.calls[1].m).to_be("asyncf-start")
    nx.test.expect(mock.calls[2].m).to_be("asyncf-done")
    nx.test.expect(mock.calls[3].m).to_be("sync")
    nx.test.expect(mock.calls[3].p).to_be("b")
  end)

  nx.test.it("rejects when an action throws", function()
    package.loaded["nxvim_ws_mock"] = make_mock()
    local caught
    nx.await(actions.run({ { require = "nxvim_ws_mock", method = "boom" } }):catch(function(e)
      caught = e
      return true
    end))
    nx.test.expect(caught).never.to_be_nil()
  end)
end)

nx.test.describe("nxvim-workspaces.actions.run_and_write", function()
  nx.test.it("writes only after every action has settled", function()
    local mock = make_mock()
    package.loaded["nxvim_ws_mock"] = mock
    local wrote_at
    local ocmd = nx.cmd
    nx.cmd = function(c)
      if c == "write" then
        wrote_at = #mock.calls -- how many action-calls had happened at write time
      end
    end
    nx.await(actions.run_and_write({
      { require = "nxvim_ws_mock", method = "asyncf", params = "z" },
    }))
    nx.cmd = ocmd
    -- The write ran after asyncf-start AND asyncf-done (2 recorded calls).
    nx.test.expect(wrote_at).to_be(2)
    nx.test.expect(mock.calls[2].m).to_be("asyncf-done")
  end)

  nx.test.it("skips the write and notifies on a failing action", function()
    package.loaded["nxvim_ws_mock"] = make_mock()
    local wrote, notified = false, false
    local ocmd, onotify = nx.cmd, nx.notify
    nx.cmd = function(c)
      if c == "write" then
        wrote = true
      end
    end
    nx.notify = function()
      notified = true
    end
    nx.await(actions.run_and_write({ { require = "nxvim_ws_mock", method = "boom" } }))
    nx.cmd, nx.notify = ocmd, onotify
    nx.test.expect(wrote).to_be_falsy()
    nx.test.expect(notified).to_be_truthy()
  end)
end)
