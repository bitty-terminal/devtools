-- Headless behavior test runner for the devtools plugin.
--
-- Plain Lua 5.4, no external test framework. Run from the repository root:
--
--   lua5.4 tests/run.lua
--
-- Exits non-zero when any assertion fails. See tests/README.md for the full
-- local verification recipe.

local script = (arg and arg[0]) or "tests/run.lua"
local root = string.match(script, "^(.*)[/\\]tests[/\\]run%.lua$")
if root == nil or root == "" then
  root = "."
end

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local tap = require("support.tap")
local context = { root = root, tap = tap }

for _, suite in ipairs({
  "spec.format_spec",
  "spec.trace_spec",
  "spec.init_spec",
}) do
  local ok, err = pcall(function()
    require(suite).run(context)
  end)
  if not ok then
    tap.crash(suite, err)
  end
end

tap.finish()
