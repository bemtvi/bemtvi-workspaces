-- A workspace `setup` hook, in the user's own config-dir Lua.
--
-- A template's `"setup": { "require": "workspace-setup.node", "method": "ensure",
-- "params": [...] }` names exactly this: `require("workspace-setup.node").ensure(params)`.
-- The JSON only names the call; the logic that cannot be plain data lives here.
--
-- Returning a PROMISE is what makes it a real hook: nxvim-workspaces awaits it before it
-- applies the rest of the config (and before the next hook starts), so the servers this
-- prepares for are enabled only once the preparation has actually finished.
--
-- This example DEMONSTRATES the mechanism rather than installing anything: it reports
-- what a real hook would ensure. Swap the body for your package manager of choice.
local M = {}

-- `ensure(packages)` -> a promise. The real thing would run `npm i -g <packages>` (or
-- check them first); here it just says what it would do, one tick later, so the await is
-- visible in the message order.
function M.ensure(packages)
  return nx.promise.new(function(resolve)
    nx.on_next_tick(function()
      nx.notify(
        "workspace-setup.node (example hook): would ensure " .. table.concat(packages, ", "),
        nx.log.levels.INFO
      )
      resolve(true)
    end)
  end)
end

return M
