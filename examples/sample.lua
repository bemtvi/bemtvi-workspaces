-- sample.lua — open this with the demo (see init.lua).
--
-- With the "lua" block from .nxvim/config.json applied, this buffer has
-- shiftwidth = 2, tabstop = 2, expandtab on. Try it:
--   * `:set shiftwidth?`  -> 2
--   * type a new function, mis-indent it, then press <C-s>: the save actions run
--     (LSP format if lua_ls is installed) and the file is written.

local M = {}

function M.greet(name)
  return "hello, " .. tostring(name)
end

function M.add(a, b)
  return a + b
end

return M
