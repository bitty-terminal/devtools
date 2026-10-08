-- End-to-end behavior tests for the devtools entry point against the local
-- `bitty` host stub.

local MockHost = require("support.mock_host")
local format = require("devtools.format")

local M = {}

local PLUGIN_ID = "bitty-featured.devtools"

local COMMAND_IDS = {
  "plugins",
  "commands",
  "events",
  "grants",
  "trace-start",
  "trace-stop",
  "trace-dump",
}

local EVENTS = {
  "terminal.opened",
  "terminal.closed",
  "terminal.title-changed",
  "terminal.cwd-changed",
  "terminal.bell",
  "focus.changed",
  "selection.changed",
  "process.exited",
  "config.reloaded",
}

local GRANTS = { "debug.inspect", "debug.trace", "platform.notify" }

local VIEW = {
  plugins = {
    { id = "bitty-featured.activity", version = "0.0.1", state = "suspended", generation = 3 },
    { id = PLUGIN_ID, version = "0.1.0", state = "active", generation = 1 },
  },
  commands = {
    { plugin = PLUGIN_ID, id = "plugins", title = "DevTools: list plugins" },
  },
  events = {
    { plugin = "bitty-featured.activity", kind = "terminal.opened" },
  },
}

-- Read a manifest string array (`key = [ "...", ... ]`) without a TOML
-- dependency, so tests stay in sync with bitty-plugin.toml.
local function manifest_list(root, key)
  local handle = assert(io.open(root .. "/bitty-plugin.toml", "r"))
  local text = handle:read("a")
  handle:close()
  local body = string.match(text, "\n" .. key .. " = %[(.-)%]")
  local values = {}
  for value in string.gmatch(body or "", '"([^"]+)"') do
    values[#values + 1] = value
  end
  return values
end

function M.run(context)
  local tap = context.tap
  local root = context.root
  print("# init")

  local manifest_commands = manifest_list(root, "commands")
  local manifest_events = manifest_list(root, "events")
  tap.equal(#manifest_commands, #COMMAND_IDS, "manifest reserves every command")
  for index, id in ipairs(COMMAND_IDS) do
    tap.equal(manifest_commands[index], PLUGIN_ID .. ":" .. id, "manifest command " .. id)
  end
  tap.equal(#manifest_events, #EVENTS, "manifest declares the observation kinds")
  for index, kind in ipairs(EVENTS) do
    tap.equal(manifest_events[index], kind, "manifest event " .. kind)
  end

  local function new_host(options)
    options = options or {}
    options.plugin_id = PLUGIN_ID
    options.grants = options.grants or GRANTS
    options.commands = manifest_commands
    options.events = manifest_events
    options.view = options.view or VIEW
    return MockHost.new(options)
  end

  local function load_plugin(host)
    _G.bitty = host.bitty
    package.loaded["devtools.format"] = nil
    package.loaded["devtools.trace"] = nil
    local chunk = assert(loadfile(root .. "/lua/devtools/init.lua"))
    return chunk()
  end

  -- registration
  local registration = new_host()
  local module = load_plugin(registration)
  tap.equal(type(module), "table", "entry point returns a module table")
  for _, id in ipairs(COMMAND_IDS) do
    local def = registration.commands[PLUGIN_ID .. ":" .. id]
    tap.ok(def ~= nil, "command registered: " .. id)
    if def ~= nil then
      tap.equal(def.args_schema.type, "object", id .. " declares an args schema")
      tap.equal(def.args_schema.additionalProperties, false, id .. " args are closed")
      tap.equal(def.result_schema.type, "string", id .. " declares a result schema")
      tap.le(#def.title, 128, id .. " title within the host bound")
    end
  end
  tap.equal(#registration.calls, 0, "activation makes no host calls beyond registration")

  -- inspect happy paths
  local host = new_host()
  load_plugin(host)
  local plugins = host:run("plugins")
  tap.contains(plugins, "2 plugins", "plugins command summarizes inspect")
  tap.contains(plugins, "bitty-featured.activity 0.0.1 [suspended] gen 3", "plugins row")
  local note = host:last_notification()
  tap.equal(note.title, "DevTools: plugins", "plugins notification title")
  tap.equal(note.body, format.notice(plugins), "notification body is the one-line notice of the result")
  tap.not_contains(note.body, "\n", "notification body is a single line")
  tap.equal(note.urgency, "low", "summaries use low urgency")

  tap.contains(host:run("commands"), PLUGIN_ID .. ":plugins - DevTools: list plugins", "commands row")
  tap.contains(host:run("events"), "bitty-featured.activity <- terminal.opened", "events row")
  local grants = host:run("grants")
  tap.contains(grants, "3 grants", "grants count")
  tap.contains(grants, "debug.inspect\ndebug.trace\nplatform.notify", "grants are sorted")

  -- capability denied is surfaced, never raised
  local denied = new_host({ grants = { "platform.notify" } })
  load_plugin(denied)
  local denied_ok, denied_result = pcall(denied.run, denied, "plugins")
  tap.ok(denied_ok, "denied inspect does not raise")
  tap.contains(denied_result, "inspect plugins failed: E_CAPABILITY_DENIED", "denied inspect reports the code")
  tap.equal(denied:last_notification().urgency, "normal", "errors use normal urgency")
  local denied_trace = denied:run("trace-start")
  tap.contains(denied_trace, "trace start failed: E_CAPABILITY_DENIED", "denied trace reports the code")

  -- notify failure never crashes a command
  local quiet = new_host({ notify_fails = true })
  load_plugin(quiet)
  local quiet_ok, quiet_result = pcall(quiet.run, quiet, "grants")
  tap.ok(quiet_ok, "notify failure does not raise")
  tap.contains(quiet_result, "3 grants", "result still returned when notify fails")
  tap.equal(#quiet.notifications, 0, "no notification recorded when notify fails")

  -- absent bridge (older host without bitty.debug, or a missing notify
  -- namespace): commands fail closed with E_BRIDGE_ABSENT, never raise
  local no_debug = new_host({ omit_debug = true })
  load_plugin(no_debug)
  local nd_ok, nd_result = pcall(no_debug.run, no_debug, "plugins")
  tap.ok(nd_ok, "inspect without bitty.debug does not raise")
  tap.contains(nd_result, "E_BRIDGE_ABSENT", "absent debug.inspect is reported")
  tap.equal(#no_debug.notifications, 1, "absent-bridge error still notifies when notify exists")
  local nd_trace_ok, nd_trace = pcall(no_debug.run, no_debug, "trace-start")
  tap.ok(nd_trace_ok, "trace-start without bitty.debug does not raise")
  tap.contains(nd_trace, "trace start failed: E_BRIDGE_ABSENT", "absent debug.trace is reported")
  local no_notify = new_host({ omit_notify = true })
  load_plugin(no_notify)
  local nn_ok, nn_result = pcall(no_notify.run, no_notify, "plugins")
  tap.ok(nn_ok, "inspect without bitty.notify does not raise")
  tap.contains(nn_result, "2 plugins", "result still returned when notify is absent")
  tap.equal(#no_notify.notifications, 0, "no notification recorded when notify is absent")
  local bare = new_host({ omit_debug = true, omit_notify = true })
  load_plugin(bare)
  local bare_ok, bare_result = pcall(bare.run, bare, "plugins")
  tap.ok(bare_ok, "inspect without either bridge does not raise")
  tap.contains(bare_result, "E_BRIDGE_ABSENT", "doubly absent bridge is reported")
  tap.equal(#bare.notifications, 0, "doubly absent bridge notifies nothing")

  -- trace lifecycle through commands
  local tracer = new_host()
  load_plugin(tracer)
  local started = tracer:run("trace-start")
  tap.contains(started, "trace 1 started (all declared kinds)", "trace-start without filter")
  tracer:deliver("terminal.opened", { terminal_id = 4, runtime_id = 2, generation = 1 }, 10)
  tracer:deliver("intercept.paste", { action = "paste" }, 5) -- undeclared
  tracer:deliver("process.exited", { terminal_id = 4, runtime_id = 2, exit_code = 0 }, 40)
  local dump = tracer:run("trace-dump")
  tap.contains(dump, "2 records, 0 dropped", "trace-dump header")
  tap.contains(dump, "terminal.opened generation=1 runtime_id=2 terminal_id=4", "trace-dump record")
  tap.contains(dump, "+45ms process.exited", "trace-dump relative timestamps")
  tap.not_contains(dump, "intercept.paste", "undeclared kinds are never shown")
  tap.equal(tracer:last_notification().title, "DevTools: trace", "trace-dump notification title")
  local busy = tracer:run("trace-start")
  tap.contains(busy, "E_TRACE_ACTIVE", "second trace-start is refused")
  tracer:deliver("terminal.bell", {}, 1)
  local stop = tracer:run("trace-stop")
  tap.contains(stop, "trace stopped; 1 records, 0 dropped", "trace-stop drains the final records")
  tap.equal(tracer:open_trace_count(), 0, "trace-stop closes the host trace")
  tap.contains(tracer:run("trace-dump"), "trace dump failed: E_TRACE_INACTIVE", "dump after stop")
  tap.contains(tracer:run("trace-stop"), "trace stop failed: E_TRACE_INACTIVE", "stop after stop")

  -- every declared manifest kind is recorded when the host delivers it.
  -- Production hosts emit only a subset today (see README); the mock
  -- delivers all nine, which is what keeps the manifest honest.
  local kinds = new_host()
  load_plugin(kinds)
  kinds:run("trace-start")
  kinds:deliver("terminal.opened", { terminal_id = 1 }, 1)
  kinds:deliver("terminal.closed", { terminal_id = 1 }, 1)
  kinds:deliver("terminal.title-changed", { title = "t" }, 1)
  kinds:deliver("terminal.cwd-changed", { cwd = "/tmp" }, 1)
  kinds:deliver("terminal.bell", {}, 1)
  kinds:deliver("focus.changed", { focused = true }, 1)
  kinds:deliver("selection.changed", { selected = true }, 1)
  kinds:deliver("process.exited", { exit_code = 0 }, 1)
  kinds:deliver("config.reloaded", { path = "bitty.toml" }, 1)
  local kinds_dump = kinds:run("trace-dump")
  tap.contains(kinds_dump, "9 records, 0 dropped", "every declared kind is traced")
  for _, kind in ipairs(EVENTS) do
    tap.contains(kinds_dump, kind, "traced: " .. kind)
  end

  -- downstream consumer contract (palette-shaped): every command runs with
  -- empty args, returns its full text, and emits exactly one single-line
  -- notice that fits the host chrome limit. A registry or palette consumer
  -- may rely on this without reading the implementation.
  local consumer = new_host()
  load_plugin(consumer)
  local seen = #consumer.notifications
  for _, id in ipairs({ "plugins", "commands", "events", "grants", "trace-start", "trace-dump", "trace-stop" }) do
    local c_ok, c_result = pcall(consumer.run, consumer, id)
    tap.ok(c_ok, "consumer: " .. id .. " does not raise")
    tap.equal(type(c_result), "string", "consumer: " .. id .. " returns text")
    tap.equal(#consumer.notifications, seen + 1, "consumer: " .. id .. " emits one notice")
    seen = seen + 1
    local note = consumer:last_notification()
    tap.not_contains(note.body, "\n", "consumer: " .. id .. " notice is one line")
    tap.le(utf8.len(note.body), format.NOTIFY_MAX_CHARS, "consumer: " .. id .. " notice fits chrome")
  end

  -- filter argument
  local filtering = new_host()
  load_plugin(filtering)
  local filtered = filtering:run("trace-start", { filter = "terminal.*" })
  tap.contains(filtered, "(filter terminal.*)", "trace-start reports the filter")
  filtering:deliver("focus.changed", { view_id = 1 })
  filtering:deliver("terminal.closed", { terminal_id = 1 })
  local filtered_dump = filtering:run("trace-dump")
  tap.contains(filtered_dump, "1 records, 0 dropped, filter terminal.*", "dump reports the filter")
  tap.not_contains(filtered_dump, "focus.changed", "filtered kinds excluded")
  local bad_filter = new_host()
  load_plugin(bad_filter)
  tap.contains(
    bad_filter:run("trace-start", { filter = "a*b" }),
    "trace start failed: E_DEF_INVALID",
    "malformed filter surfaced from the host"
  )
  tap.contains(
    bad_filter:run("trace-start", { filter = 42 }),
    "trace start failed: E_DEF_INVALID",
    "non-string filter rejected locally"
  )
  tap.contains(
    bad_filter:run("trace-start", { filter = string.rep("x", 129) }),
    "E_DEF_INVALID",
    "oversized filter rejected locally"
  )
  tap.equal(bad_filter:open_trace_count(), 0, "rejected filters open no trace")

  -- E_DEF_LIMIT
  local limited = new_host()
  load_plugin(limited)
  for _ = 1, MockHost.MAX_TRACES_PER_PLUGIN do
    limited.bitty.debug.trace(nil)
  end
  tap.contains(
    limited:run("trace-start"),
    "trace start failed: E_DEF_LIMIT: trace limit reached",
    "E_DEF_LIMIT surfaced with a hint"
  )

  -- dropped records (drop-oldest) are reported
  local overflow = new_host()
  load_plugin(overflow)
  overflow:run("trace-start")
  for index = 1, MockHost.DEFAULT_TRACE_MAX_EVENTS + 5 do
    overflow:deliver("terminal.bell", {}, index == 1 and 1 or 0)
  end
  local overflow_dump = overflow:run("trace-dump")
  tap.contains(overflow_dump, MockHost.DEFAULT_TRACE_MAX_EVENTS .. " records, 5 dropped", "dropped count")
  tap.le(#overflow_dump, 2048, "large dumps stay bounded")

  -- host dropped the trace (nil drain)
  local dropped = new_host()
  load_plugin(dropped)
  dropped:run("trace-start")
  dropped:drop_traces()
  tap.contains(dropped:run("trace-dump"), "trace dump failed: E_TRACE_GONE", "nil drain surfaced")
  tap.contains(dropped:run("trace-start"), "trace 2 started", "a new trace starts after a nil drain")
  dropped:drop_traces()
  tap.contains(
    dropped:run("trace-stop"),
    "trace stopped (the host had already dropped it)",
    "stop after the host dropped the trace"
  )

  -- final drain error on trace-stop is surfaced, not reported as dropped
  for _, code in ipairs({ "E_TIMEOUT", "E_CAPABILITY_DENIED" }) do
    local failing = new_host()
    load_plugin(failing)
    failing:run("trace-start")
    failing:deliver("terminal.bell", {})
    failing.trace_get_error = { class = "runtime", code = code, message = "drain" }
    local text = failing:run("trace-stop")
    tap.contains(text, "trace stopped; final drain failed: " .. code, code .. " drain error surfaced")
    tap.not_contains(text, "already dropped", code .. " drain error is not reported as dropped")
    tap.equal(failing:open_trace_count(), 0, code .. " trace is closed despite the drain error")
    tap.equal(failing:last_notification().urgency, "normal", code .. " drain error uses normal urgency")
  end

  -- every notification body fits the host chrome limit for large inputs
  local big_view = { plugins = {}, commands = {}, events = {} }
  for index = 1, MockHost.MAX_INSPECT_ITEMS + 10 do
    local wide = string.rep("\u{e9}", 200) .. index
    big_view.plugins[index] = { id = wide, version = wide, state = "active", generation = index }
    big_view.commands[index] = { plugin = wide, id = wide, title = wide }
    big_view.events[index] = { plugin = wide, kind = wide }
  end
  local big = new_host({ view = big_view })
  load_plugin(big)
  for _, id in ipairs({ "plugins", "commands", "events", "grants" }) do
    big:run(id)
  end
  big:run("trace-start", { filter = string.rep("t", 128) })
  big:run("trace-stop")
  big:run("trace-start")
  for index = 1, 2000 do
    big:deliver("terminal.title-changed", { title = string.rep("\u{4e16}", 300), terminal_id = index }, 1)
  end
  local big_dump = big:run("trace-dump")
  tap.contains(big_dump, "1000 records, 1000 dropped", "large drain is rendered")
  big:deliver("terminal.bell", {})
  big:run("trace-stop")
  big:run("trace-dump")
  big.trace_get_error = nil
  for _ = 1, MockHost.MAX_TRACES_PER_PLUGIN do
    big.bitty.debug.trace(nil)
  end
  big:run("trace-start")
  tap.equal(big.rejected_notifications or 0, 0, "the host never rejects a notification body")
  tap.ok(#big.notifications >= 9, "large-input commands all notified")
  for _, sent in ipairs(big.notifications) do
    tap.le(utf8.len(sent.body), format.NOTIFY_MAX_CHARS, "notification body <= 256 characters")
    tap.not_contains(sent.body, "\n", "notification body is one line")
  end

  -- the plugin never reaches outside commands/notify/debug, and never calls
  -- debug.control
  for _, probe in ipairs({ host, denied, tracer, filtering, overflow, dropped, big, no_debug, no_notify, bare, kinds, consumer }) do
    tap.equal(#probe.ui_accesses, 0, "no ui or other namespace access")
    for _, call in ipairs(probe.calls) do
      tap.ok(call ~= "debug.control", "debug.control is never called")
    end
  end
end

return M
