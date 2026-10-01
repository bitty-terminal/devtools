-- Minimal TAP-like assertion helper for the devtools behavior tests.
--
-- Test-only module (plain Lua, no host authority). It prints a TAP header,
-- per-failure diagnostics, and a summary, then exits non-zero when any
-- assertion failed.

local M = {
  passed = 0,
  failed = 0,
  failures = {},
}

local function record(condition, message)
  if condition then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = message
  end
end

function M.ok(condition, message)
  record(condition and true or false, message or "expected truthy value")
end

function M.equal(actual, expected, message)
  record(
    actual == expected,
    string.format(
      "%s: expected %s, got %s",
      message or "equal",
      tostring(expected),
      tostring(actual)
    )
  )
end

function M.contains(haystack, needle, message)
  local found = type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil
  record(found, string.format("%s: missing %q", message or "contains", tostring(needle)))
end

function M.not_contains(haystack, needle, message)
  local found = type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil
  record(not found, string.format("%s: unexpectedly found %q", message or "not_contains", tostring(needle)))
end

function M.le(actual, limit, message)
  record(
    type(actual) == "number" and actual <= limit,
    string.format("%s: expected <= %s, got %s", message or "le", tostring(limit), tostring(actual))
  )
end

function M.crash(suite, err)
  M.failed = M.failed + 1
  M.failures[#M.failures + 1] = string.format("%s crashed: %s", suite, tostring(err))
end

function M.finish()
  local total = M.passed + M.failed
  print(string.format("1..%d", total))
  for _, failure in ipairs(M.failures) do
    print("not ok - " .. failure)
  end
  print(string.format("# passed %d, failed %d", M.passed, M.failed))
  if M.failed > 0 then
    os.exit(1)
  end
end

return M
