-- Unit tests for the pure `devtools.format` module.

local format = require("devtools.format")

local M = {}

function M.run(context)
  local tap = context.tap
  print("# format")

  -- limits invariant: MAX_LINES full lines plus two header lines fit
  local worst = (format.MAX_LINES + 2) * format.MAX_LINE_BYTES + (format.MAX_LINES + 1)
  tap.le(worst, format.MAX_BODY_BYTES, "line limits fit inside the body limit")

  -- truncate
  tap.equal(format.truncate("abc", 10), "abc", "short text is unchanged")
  local cut = format.truncate(string.rep("x", 100), 10)
  tap.equal(#cut, 10, "truncate respects the byte limit")
  tap.equal(string.sub(cut, -3), format.ELLIPSIS, "truncated text ends with the ellipsis")
  -- "é" is two bytes (0xC3 0xA9); a cut inside it must back off.
  local accented = format.truncate("ab" .. string.rep("\u{e9}", 10), 8)
  tap.ok(utf8.len(accented) ~= nil, "truncate never splits a UTF-8 sequence")
  tap.le(#accented, 8, "UTF-8 truncate stays within the limit")
  tap.equal(format.truncate("abcdef", 2), "..", "a limit below the ellipsis still respects the limit")

  -- field sanitizes control bytes
  tap.equal(format.field("a\nb\27[31m"), "a?b?[31m", "control bytes are replaced")
  tap.equal(format.field(nil), "-", "nil fields render as a dash")
  tap.le(#format.field(string.rep("y", 500)), format.MAX_FIELD_BYTES, "fields are bounded")

  -- inspect: plugins
  local title, body = format.inspect("plugins", {
    target = "plugins",
    items = {
      { id = "bitty-featured.devtools", version = "0.1.0", state = "active", generation = 1 },
      { id = "bitty-featured.activity", version = "0.0.1", state = "failed", generation = 2 },
    },
    truncated = false,
  })
  tap.equal(title, "DevTools: plugins", "inspect title names the target")
  tap.contains(body, "2 plugins", "plugins header counts items")
  tap.contains(body, "bitty-featured.devtools 0.1.0 [active] gen 1", "plugin row rendered")
  tap.contains(body, "[failed] gen 2", "failed state rendered")

  -- inspect: commands / events / grants
  local _, commands_body = format.inspect("commands", {
    items = { { plugin = "p", id = "go", title = "Go now" } },
  })
  tap.contains(commands_body, "p:go - Go now", "command row rendered")
  local _, events_body = format.inspect("events", { items = { { plugin = "p", kind = "terminal.opened" } } })
  tap.contains(events_body, "p <- terminal.opened", "event row rendered")
  local _, grants_body = format.inspect("grants", { items = { "debug.inspect", "platform.notify" } })
  tap.contains(grants_body, "2 grants", "grants header")
  tap.contains(grants_body, "debug.inspect\nplatform.notify", "grant strings rendered one per line")
  local _, empty_body = format.inspect("events", { items = {}, truncated = false })
  tap.contains(empty_body, "(none)", "empty list is explicit")

  -- inspect: bounds
  local many = {}
  for index = 1, 1024 do
    many[index] = { plugin = "plugin-" .. index, kind = "terminal.opened" }
  end
  local _, many_body = format.inspect("events", { items = many, truncated = true })
  tap.contains(many_body, "(host list truncated)", "host truncation is reported")
  tap.contains(many_body, "(+" .. (1024 - format.MAX_LINES) .. " more)", "overflow rows are counted")
  tap.le(#many_body, format.MAX_BODY_BYTES, "inspect body is bounded")
  local wide = {}
  for index = 1, format.MAX_LINES do
    wide[index] = { plugin = string.rep("p", 300), id = string.rep("i", 300), title = string.rep("t", 300) }
  end
  local _, wide_body = format.inspect("commands", { items = wide })
  for line in string.gmatch(wide_body, "[^\n]+") do
    tap.le(#line, format.MAX_LINE_BYTES, "every inspect line is bounded")
  end
  tap.le(#wide_body, format.MAX_BODY_BYTES, "wide inspect body is bounded")

  -- inspect: malformed
  local _, bad = format.inspect("plugins", nil)
  tap.contains(bad, "unexpected", "malformed inspect result is reported, not raised")
  local _, unknown = format.inspect("panels", { items = {} })
  tap.contains(unknown, "unexpected", "unsupported target is reported, not raised")

  -- payload
  tap.equal(format.payload({ terminal_id = 3, runtime_id = 9 }), "runtime_id=9 terminal_id=3", "payload keys sorted")
  tap.equal(
    format.payload({ truncated = true, bytes = 9000 }),
    "payload truncated (9000 bytes)",
    "host-truncated payload rendered"
  )
  tap.equal(format.payload({ a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }), "a=1 b=2 c=3 d=4 +2", "payload fields bounded")
  tap.equal(format.payload({ nested = { x = 1 } }), "nested={...}", "nested tables collapse")
  tap.equal(format.payload(nil), "<nil>", "nil payload renders a type marker")
  tap.equal(format.payload("raw"), "<string>", "string payload renders a type marker")

  -- trace
  local _, trace_body = format.trace({
    records = {
      { topic = "terminal.opened", sequence = 5, timestamp = 1000, payload = { terminal_id = 1 } },
      { topic = "terminal.closed", sequence = 6, timestamp = 1250, payload = { terminal_id = 1 } },
    },
    dropped = 3,
  }, "terminal.*")
  tap.contains(trace_body, "2 records, 3 dropped, filter terminal.*", "trace header with counts and filter")
  tap.contains(trace_body, "#5 +0ms terminal.opened terminal_id=1", "first record relative to itself")
  tap.contains(trace_body, "#6 +250ms terminal.closed", "later record offset in ms")
  local _, empty_trace = format.trace({ records = {}, dropped = 0 })
  tap.contains(empty_trace, "0 records, 0 dropped", "empty drain header")
  tap.contains(empty_trace, "only declared event kinds", "empty drain explains declared-kind scope")

  local records = {}
  for index = 1, 500 do
    records[index] = {
      topic = "terminal.title-changed",
      sequence = index,
      timestamp = index,
      payload = { title = string.rep("z", 400) },
    }
  end
  local _, long_trace = format.trace({ records = records, dropped = 0 })
  tap.contains(long_trace, "(" .. (500 - format.MAX_LINES) .. " earlier records omitted)", "older records omitted")
  tap.contains(long_trace, "#500 ", "most recent record shown")
  tap.not_contains(long_trace, "#1 ", "oldest record not shown")
  tap.le(#long_trace, format.MAX_BODY_BYTES, "trace body is bounded")
  local _, bad_trace = format.trace({ dropped = 1 })
  tap.contains(bad_trace, "unexpected", "malformed trace result is reported, not raised")

  -- notice: one line, <= NOTIFY_MAX_CHARS characters
  tap.equal(format.NOTIFY_MAX_CHARS, 256, "notice limit mirrors MAX_NOTIFICATION_TEXT_LEN")
  tap.equal(format.notice("a\nb"), "a; b", "line breaks become separators")
  tap.equal(format.notice("short"), "short", "short text is unchanged")
  local ascii_notice = format.notice(string.rep("x", 5000))
  tap.equal(#ascii_notice, format.NOTIFY_MAX_CHARS, "ASCII notice is cut to the limit")
  tap.equal(string.sub(ascii_notice, -3), format.ELLIPSIS, "cut notice ends with the ellipsis")
  local wide_notice = format.notice(string.rep("\u{4e16}", 1000))
  tap.equal(utf8.len(wide_notice), format.NOTIFY_MAX_CHARS, "multibyte notice is cut by characters")
  tap.ok(#wide_notice > format.NOTIFY_MAX_CHARS, "multibyte notice limit counts characters, not bytes")
  local exact = string.rep("\u{e9}", format.NOTIFY_MAX_CHARS)
  tap.equal(format.notice(exact), exact, "exactly 256 characters is kept")
  local invalid_notice = format.notice(string.rep("\xff", 1000))
  tap.le(#invalid_notice, format.NOTIFY_MAX_CHARS, "invalid UTF-8 notice is bounded by bytes")
  tap.not_contains(format.notice("a\27[31mb"), "\27", "notice carries no control bytes")
  local _, huge_trace = format.trace({ records = records, dropped = 9 })
  tap.le(utf8.len(format.notice(huge_trace)), format.NOTIFY_MAX_CHARS, "trace notice is bounded")
  tap.le(utf8.len(format.notice(many_body)), format.NOTIFY_MAX_CHARS, "inspect notice is bounded")
  tap.le(utf8.len(format.notice(format.error("x", { code = "E_X", message = string.rep("m", 900) }))),
    format.NOTIFY_MAX_CHARS, "error notice is bounded")

  -- errors
  local info = format.error_info({ class = "runtime", code = "E_CAPABILITY_DENIED", message = "nope" })
  tap.equal(info.code, "E_CAPABILITY_DENIED", "error code extracted")
  tap.equal(format.error_info("boom").code, "E_UNKNOWN", "string errors map to E_UNKNOWN")
  tap.equal(format.error_info(nil).code, "E_UNKNOWN", "nil errors map to E_UNKNOWN")
  local denied = format.error("inspect plugins", { code = "E_CAPABILITY_DENIED", message = "x" })
  tap.contains(denied, "inspect plugins failed: E_CAPABILITY_DENIED: capability not granted", "denied hint")
  local limit = format.error("trace start", { code = "E_DEF_LIMIT" })
  tap.contains(limit, "E_DEF_LIMIT: trace limit reached", "limit hint without message")
  local long_error = format.error("x", { code = "E_X", message = string.rep("m\n", 1000) })
  tap.le(#long_error, format.MAX_ERROR_BYTES, "error body is bounded")
  tap.not_contains(long_error, "\n", "error body carries no control bytes")
  tap.equal(format.error_detail({ code = "E_TIMEOUT" }), "E_TIMEOUT: host call timed out", "error detail")
  tap.le(#format.error_detail({ code = "E_X", message = string.rep("q", 900) }), format.MAX_ERROR_BYTES,
    "error detail is bounded")
end

return M
