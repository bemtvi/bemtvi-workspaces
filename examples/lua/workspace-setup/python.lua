-- The python half of the example `setup` hooks — see workspace-setup/node.lua for what a
-- hook is and how the JSON names it. Two templates each carrying their own hook is the
-- point: merging both leaves the project config running BOTH preparations, in the order
-- they were merged, rather than only the last one's.
local M = {}

-- `venv(params)` -> a promise. A real one would create/activate the virtualenv and hand
-- its interpreter to the servers the config enables; this reports what it would do.
function M.venv(params)
  local where = (params and params.dir) or ".venv"
  return btv.promise.new(function(resolve)
    btv.on_next_tick(function()
      btv.notify(
        "workspace-setup.python (example hook): would prepare the venv at " .. where,
        btv.log.levels.INFO
      )
      resolve(true)
    end)
  end)
end

return M
