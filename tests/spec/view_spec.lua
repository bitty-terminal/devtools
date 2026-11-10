-- Behavior tests for the optional live view (`devtools.view` + the `view-*`
-- commands) against the local `bitty` host stub.
--
-- The suite pins the three design decisions in docs/design/live-view.md:
--   1. the view owns its OWN trace handle (the seven commands stay
--      byte-identical with the view open or closed),
--   2. the refresh budget (1 s default, 500 ms floor, one-shot timer chain,
--      changed rows only, zero notifications per tick),
--   3. grants (no `ui.rich` means the view degrades to the notification path
--      and the seven commands keep working).

local MockHost = require("support.mock_host")
local format = require("devtools.format")
local view = require("devtools.view")

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
  "view-open",
  "view-close",
  "view-pause",
  "view-resume",
}

local READ_ONLY_IDS = { "plugins", "commands", "events", "grants" }

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

local GRANTS = { "debug.inspect", "debug.trace", "platform.notify", "ui.rich" }
local NO_UI_GRANTS = { "debug.inspect", "debug.trace", "platform.notify" }

local SAMPLE_VIEW = {
  plugins = {
    { id = "bitty-featured.activity", version = "0.0.1", state = "suspended", generation = 3 },
    { id = PLUGIN_ID, version = "0.2.0", state = "active", generation = 1 },
  },
  commands = {
    { plugin = PLUGIN_ID, id = "plugins", title = "DevTools: list plugins" },
    { plugin = PLUGIN_ID, id = "trace-start", title = "DevTools: start event trace" },
  },
  events = {
    { plugin = "bitty-featured.activity", kind = "terminal.opened" },
  },
}

-- Host calls the plugin may make. Anything else is a surface regression.
local ALLOWED_CALLS = {
  ["ui.mount"] = true,
  ["ui.update"] = true,
  ["timers.create"] = true,
  ["timers.cancel"] = true,
  ["debug.inspect"] = true,
  ["debug.trace"] = true,
  ["debug.trace_get"] = true,
  ["notify.show"] = true,
}

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
  print("# view")

  local manifest_commands = manifest_list(root, "commands")
  local manifest_events = manifest_list(root, "events")

  local function new_host(options)
    options = options or {}
    options.plugin_id = PLUGIN_ID
    options.grants = options.grants or GRANTS
    options.commands = manifest_commands
    options.events = manifest_events
    options.view = options.view or SAMPLE_VIEW
    return MockHost.new(options)
  end

  local function load_plugin(host)
    _G.bitty = host.bitty
    package.loaded["devtools.format"] = nil
    package.loaded["devtools.trace"] = nil
    package.loaded["devtools.view"] = nil
    local chunk = assert(loadfile(root .. "/lua/devtools/init.lua"))
    return chunk()
  end

  local function call_count(host, name)
    local count = 0
    for _, call in ipairs(host.calls) do
      if call == name then
        count = count + 1
      end
    end
    return count
  end

  local function last_row(host)
    local rows = host:bands("bottom")
    return rows[#rows]
  end

  local function bottom_row(host)
    local rows = host:bands("bottom")
    return rows[1]
  end

  -- mount / update / destroy ------------------------------------------------

  local mounted = new_host()
  load_plugin(mounted)
  local open_text = mounted:run("view-open")
  tap.contains(open_text, "view open (plugins, all declared kinds, 1.0s, 8 rows)", "view-open reports the shape")
  tap.equal(mounted:block_count(), view.ROW_COUNT, "one block per row is mounted")
  for _, block in ipairs(mounted.ui_blocks) do
    tap.equal(block.slot, "bottom", "every row mounts into the bottom band")
    tap.equal(block.component.kind, "Text", "every row is a v1 Text node")
  end
  local rows = mounted:bands("bottom")
  tap.equal(#rows, 1 + view.INSPECT_ROWS, "status line plus inspect rows are visible")
  tap.contains(bottom_row(mounted), "DEVTOOLS live plugins 1.0s", "status line reports mode and cadence")
  tap.contains(bottom_row(mounted), "rec 0 drop 0 err 0", "status line carries the loss accounting")
  tap.contains(rows[2], "2 plugins", "inspect row carries the item count")
  tap.contains(rows[3], "bitty-featured.activity 0.0.1 [suspended] gen 3", "inspect row carries a table row")
  tap.equal(mounted:timer_count(), 1, "one refresh timer is armed")
  tap.equal(mounted:open_trace_count(), 1, "the view owns exactly one trace handle")
  tap.equal(#mounted.ui_accesses, 0, "the view reaches no namespace outside the bridge")

  -- the first frame is rendered by mount/update only: no overlay, no notify
  tap.equal(call_count(mounted, "ui.mount"), view.ROW_COUNT, "open mounts each row once")
  tap.equal(call_count(mounted, "ui.update"), 1 + view.INSPECT_ROWS, "open updates only the rows with text")
  tap.equal(mounted:last_notification().title, "DevTools: view", "open notifies on the command path")

  -- a tick repaints only the rows whose text changed
  local updates_after_open = call_count(mounted, "ui.update")
  mounted:deliver("terminal.bell", {})
  mounted:advance(1000)
  local updates_after_tick = call_count(mounted, "ui.update") - updates_after_open
  tap.equal(updates_after_tick, 2, "a tick with one record updates the status line and one trace row")
  tap.contains(bottom_row(mounted), "rec 1 drop 0 err 0", "the tick advanced the record counter")
  tap.contains(last_row(mounted), "terminal.bell", "the newest record is the top row")
  tap.equal(#mounted:bands("bottom"), 1 + view.INSPECT_ROWS + 1, "the trace row became visible")

  local idle = call_count(mounted, "ui.update")
  mounted:advance(1000)
  tap.equal(call_count(mounted, "ui.update") - idle, 0, "an idle tick repaints nothing")

  -- close hides every row, cancels the timer, releases the trace handle
  local close_text = mounted:run("view-close")
  tap.contains(close_text, "view closed; 1 records, 0 dropped, 0 errors", "close reports the counters")
  tap.equal(#mounted:bands("bottom"), 0, "close leaves no visible band row")
  tap.equal(mounted:timer_count(), 0, "close cancels the refresh timer")
  tap.equal(mounted:open_trace_count(), 0, "close releases the view trace handle")
  tap.equal(mounted:block_count(), view.ROW_COUNT, "close keeps the generation's block handles")

  -- reopen reuses the handles instead of mounting again (no ui.unmount in v1)
  for _ = 1, 6 do
    tap.contains(mounted:run("view-open"), "view open", "reopen succeeds")
    mounted:run("view-close")
  end
  tap.equal(mounted:block_count(), view.ROW_COUNT, "open/close cycles never mount extra blocks")
  tap.equal(mounted:timer_count(), 0, "no timer survives the last close")
  tap.equal(mounted:open_trace_count(), 0, "no trace survives the last close")

  -- refresh budget ----------------------------------------------------------

  local cadence = new_host()
  load_plugin(cadence)
  cadence:run("view-open")
  local before = call_count(cadence, "ui.update")
  cadence:advance(view.DEFAULT_INTERVAL_MS - 1)
  tap.equal(call_count(cadence, "ui.update"), before, "no tick before the default cadence")
  cadence:advance(1)
  tap.equal(cadence.clock, view.DEFAULT_INTERVAL_MS, "the default cadence is 1 s")
  tap.equal(cadence:timer_count(), 1, "the one-shot timer chain re-arms itself")

  local floor = new_host()
  load_plugin(floor)
  tap.contains(floor:run("view-open", { interval_ms = 10 }), "0.5s", "the floor clamps a fast interval")
  local floor_updates = call_count(floor, "ui.update")
  floor:advance(view.MIN_INTERVAL_MS - 1)
  tap.equal(call_count(floor, "ui.update"), floor_updates, "no tick below the floor")
  floor:advance(1)
  tap.equal(floor.clock, view.MIN_INTERVAL_MS, "the floor cadence is 500 ms")

  local ceiling = new_host()
  load_plugin(ceiling)
  tap.contains(ceiling:run("view-open", { interval_ms = 60000 }), "10.0s", "the ceiling clamps a slow interval")
  tap.contains(ceiling:run("view-open", { interval_ms = 1500.5 }), "E_DEF_INVALID", "a fractional interval is rejected")

  -- the tick path never notifies, so the notify rate policy is never in play
  local quiet = new_host()
  load_plugin(quiet)
  quiet:run("view-open")
  local notifications = #quiet.notifications
  for _ = 1, 10 do
    quiet:deliver("terminal.bell", {})
    quiet:advance(view.MIN_INTERVAL_MS)
  end
  tap.equal(#quiet.notifications, notifications, "ten ticks emit no notification")
  tap.le(call_count(quiet, "ui.update"), 10 * view.ROW_COUNT, "updates stay bounded by rows per tick")

  -- pause / resume ----------------------------------------------------------

  local paused = new_host()
  load_plugin(paused)
  paused:run("view-open")
  paused:deliver("terminal.opened", { terminal_id = 1 })
  paused:advance(1000)
  local paused_updates = call_count(paused, "ui.update")
  tap.contains(paused:run("view-pause"), "view paused (1 records, 0 dropped, 0 errors)", "pause reports state")
  tap.equal(paused:timer_count(), 0, "pause cancels the timer")
  tap.equal(paused:open_trace_count(), 1, "pause keeps the owned trace handle")
  tap.equal(#paused:bands("bottom"), 1 + view.INSPECT_ROWS + 1, "pause keeps the last frame on screen")
  tap.contains(bottom_row(paused), "DEVTOOLS paused", "the status line reports the paused mode")

  -- records keep accumulating in the bounded host buffer while paused
  for _ = 1, 3 do
    paused:deliver("terminal.bell", {})
  end
  paused:advance(5000)
  tap.equal(call_count(paused, "ui.update"), paused_updates + 1, "a paused view does not repaint")
  tap.contains(bottom_row(paused), "rec 1 drop 0", "paused counters stay frozen")

  tap.contains(paused:run("view-resume"), "view resumed; 4 records, 0 dropped, 0 errors", "resume drains the backlog")
  tap.contains(bottom_row(paused), "rec 4 drop 0 err 0", "the backlog is visible after resume")
  tap.equal(paused:timer_count(), 1, "resume re-arms the timer")
  tap.equal(paused:open_trace_count(), 1, "resume continues the same trace")
  tap.equal(paused:block_count(), view.ROW_COUNT, "resume mounts nothing new")

  -- pause/resume churn leaks neither a timer, a trace, nor a block
  for _ = 1, 5 do
    paused:run("view-pause")
    paused:run("view-resume")
  end
  tap.equal(paused:timer_count(), 1, "one timer after repeated pause/resume")
  tap.equal(paused:open_trace_count(), 1, "one trace after repeated pause/resume")
  tap.equal(paused:block_count(), view.ROW_COUNT, "no extra block after repeated pause/resume")

  -- close while paused releases everything
  paused:run("view-pause")
  paused:run("view-close")
  tap.equal(paused:timer_count(), 0, "close from paused cancels the timer")
  tap.equal(paused:open_trace_count(), 0, "close from paused releases the trace")
  tap.equal(#paused:bands("bottom"), 0, "close from paused hides every row")

  -- dropped records are the point of the trace backend: keep them visible
  local dropping = new_host()
  load_plugin(dropping)
  dropping:run("view-open")
  dropping:run("view-pause")
  for index = 1, MockHost.DEFAULT_TRACE_MAX_EVENTS + 5 do
    dropping:deliver("terminal.bell", {}, index == 1 and 1 or 0)
  end
  tap.contains(dropping:run("view-resume"), "1000 records, 5 dropped, 0 errors", "resume reports the dropped count")
  tap.contains(bottom_row(dropping), "drop 5", "the dropped count is visible in the view")
  tap.le(#bottom_row(dropping), format.MAX_LINE_BYTES, "the status row stays bounded")

  -- handle contention: the seven commands are identical with the view open --
  local function parity_script(host, with_view)
    local results = {}
    results.plugins = host:run("plugins")
    results.commands = host:run("commands")
    results.events = host:run("events")
    results.grants = host:run("grants")
    results.start = host:run("trace-start")
    if with_view then
      results.view = host:run("view-open")
    end
    host:deliver("terminal.opened", { terminal_id = 1, runtime_id = 1, generation = 1 }, 10)
    host:advance(1000) -- the view drains its own buffer; the command handle is untouched
    results.dump = host:run("trace-dump")
    host:deliver("terminal.bell", {}, 5)
    host:advance(1000)
    results.stop = host:run("trace-stop")
    return results
  end

  local closed_host = new_host()
  load_plugin(closed_host)
  local closed_results = parity_script(closed_host, false)

  local open_host = new_host()
  load_plugin(open_host)
  local open_results = parity_script(open_host, true)

  tap.contains(open_results.view, "view open", "the view script opened the view")
  for _, key in ipairs({ "plugins", "commands", "events", "grants", "start", "dump", "stop" }) do
    tap.equal(open_results[key], closed_results[key], "command result is identical with the view open: " .. key)
  end
  tap.contains(open_results.start, "trace 1 started", "the command trace still takes handle 1")
  tap.equal(open_host:open_trace_count(), 1, "only the view trace remains after trace-stop")
  tap.equal(closed_host:open_trace_count(), 0, "the control host has no trace left")

  -- the two handles are distinct and neither drains the other
  local isolation = new_host()
  load_plugin(isolation)
  isolation:run("trace-start")
  isolation:run("view-open")
  tap.equal(isolation:open_trace_count(), 2, "commands and view each own one trace (2 of the host cap of 4)")
  isolation:deliver("terminal.closed", { terminal_id = 1, runtime_id = 1, reason = "exit" })
  isolation:deliver("terminal.bell", {})
  isolation:advance(1000)
  tap.contains(isolation:run("trace-dump"), "2 records, 0 dropped", "the view drain does not consume the command buffer")
  tap.contains(bottom_row(isolation), "rec 2", "the command dump does not consume the view buffer")
  isolation:advance(1000)
  tap.contains(bottom_row(isolation), "rec 2", "the view buffer is drained once")

  -- view-close does not disturb the command handle
  isolation:run("view-close")
  tap.equal(isolation:open_trace_count(), 1, "view-close leaves the command trace open")
  tap.contains(isolation:run("trace-dump"), "0 records, 0 dropped", "the command trace still drains after view-close")
  tap.contains(isolation:run("trace-stop"), "trace stopped;", "the command trace still stops after view-close")

  -- the view keeps running across a command trace-stop
  local surviving = new_host()
  load_plugin(surviving)
  surviving:run("trace-start")
  surviving:run("view-open")
  surviving:run("trace-stop")
  surviving:deliver("terminal.bell", {})
  surviving:advance(1000)
  tap.equal(surviving:open_trace_count(), 1, "trace-stop closes only the command handle")
  tap.contains(bottom_row(surviving), "rec 1", "the view still records after trace-stop")
  tap.equal(surviving:timer_count(), 1, "the view timer survives trace-stop")

  -- grants and degradation --------------------------------------------------

  local declined = new_host({ grants = NO_UI_GRANTS })
  load_plugin(declined)
  local declined_text = declined:run("view-open")
  tap.contains(declined_text, "view open failed: E_CAPABILITY_DENIED", "a declined ui.rich is a typed error")
  tap.contains(declined_text, "capability not granted", "the error carries the hint")
  tap.equal(declined:last_notification().urgency, "normal", "a refused open notifies with normal urgency")
  tap.equal(declined:block_count(), 0, "a declined grant mounts nothing")
  tap.equal(declined:timer_count(), 0, "a declined grant arms no timer")
  tap.equal(declined:open_trace_count(), 0, "a declined grant opens no trace")

  -- the seven read-only commands are unchanged without ui.rich
  for _, id in ipairs(READ_ONLY_IDS) do
    tap.equal(declined:run(id), closed_host:run(id), "read-only command works grant-less: " .. id)
  end
  tap.contains(declined:run("trace-start"), "trace 1 started", "trace-start works grant-less")
  tap.contains(declined:run("trace-stop"), "trace stopped;", "trace-stop works grant-less")

  local older_ui = new_host({ omit_ui = true })
  load_plugin(older_ui)
  tap.contains(older_ui:run("view-open"), "bitty.ui.mount is not available on this host", "absent ui bridge degrades")
  local older_timers = new_host({ omit_timers = true })
  load_plugin(older_timers)
  tap.contains(older_timers:run("view-open"), "bitty.timers.create is not available on this host", "absent timer bridge degrades")
  local older_debug = new_host({ omit_debug = true })
  load_plugin(older_debug)
  tap.contains(older_debug:run("view-open"), "E_BRIDGE_ABSENT", "absent debug bridge degrades")
  tap.equal(older_debug:block_count(), 0, "an absent bridge mounts nothing")

  local quiet_notify = new_host({ omit_notify = true })
  load_plugin(quiet_notify)
  local quiet_ok, quiet_text = pcall(quiet_notify.run, quiet_notify, "view-open")
  tap.ok(quiet_ok, "view-open without notify does not raise")
  tap.contains(quiet_text, "view open", "view-open still returns its text")

  -- command state errors ----------------------------------------------------

  local states = new_host()
  load_plugin(states)
  tap.contains(states:run("view-close"), "view close failed: E_VIEW_INACTIVE", "close when closed is typed")
  tap.contains(states:run("view-pause"), "view pause failed: E_VIEW_INACTIVE", "pause when closed is typed")
  tap.contains(states:run("view-resume"), "view resume failed: E_VIEW_INACTIVE", "resume when closed is typed")
  states:run("view-open")
  tap.contains(states:run("view-open"), "view open failed: E_VIEW_ACTIVE", "a second open is refused")
  tap.contains(states:run("view-pause"), "view paused", "pause succeeds")
  tap.contains(states:run("view-pause"), "view paused", "pause is idempotent")
  tap.contains(states:run("view-resume"), "view resumed", "resume succeeds")
  tap.contains(states:run("view-resume"), "view resumed", "resume is idempotent")
  tap.equal(states:timer_count(), 1, "idempotent pause/resume keeps one timer")

  local bad_args = new_host()
  load_plugin(bad_args)
  tap.contains(bad_args:run("view-open", { target = "panels" }), "E_DEF_INVALID", "unknown target is rejected")
  tap.contains(bad_args:run("view-open", { filter = "a*b" }), "view open failed: E_DEF_INVALID", "malformed filter is rejected")
  tap.contains(bad_args:run("view-open", { filter = 42 }), "view open failed: E_DEF_INVALID", "non-string filter is rejected")
  tap.equal(#bad_args:bands("bottom"), 0, "rejected arguments leave no visible row")
  tap.equal(bad_args:timer_count(), 0, "rejected arguments arm no timer")
  tap.equal(bad_args:open_trace_count(), 0, "rejected arguments leave no trace")

  -- target and filter -------------------------------------------------------

  local targeted = new_host()
  load_plugin(targeted)
  targeted:run("view-open", { target = "commands" })
  tap.contains(bottom_row(targeted), "DEVTOOLS live commands", "the status line names the target")
  tap.contains(targeted:bands("bottom")[2], "2 commands", "the inspect rows follow the target")
  targeted:run("view-close")
  targeted:run("view-open", { target = "grants" })
  tap.contains(targeted:bands("bottom")[2], "4 grants", "the grants target lists the plugin's own grants")

  local filtered = new_host()
  load_plugin(filtered)
  filtered:run("view-open", { filter = "terminal.*" })
  filtered:deliver("focus.changed", { view_id = 1 })
  filtered:deliver("terminal.closed", { terminal_id = 1 })
  filtered:advance(1000)
  tap.contains(bottom_row(filtered), "rec 1", "the filter narrows the view trace")
  local stream = table.concat(filtered:bands("bottom"), "\n")
  tap.contains(stream, "terminal.closed", "a filtered record reaches the stream")
  tap.not_contains(stream, "focus.changed", "an out-of-filter record never reaches the stream")

  -- loss and surface allowlist ---------------------------------------------

  local lost = new_host()
  load_plugin(lost)
  lost:run("view-open")
  lost:deliver("terminal.bell", {})
  local before_loss = #lost.notifications
  lost:drop_traces()
  lost:drop_ui_blocks()
  lost:advance(1000)
  tap.equal(lost:timer_count(), 0, "a lost view cancels its timer")
  tap.equal(lost:open_trace_count(), 0, "a lost view releases its trace")
  tap.equal(#lost:bands("bottom"), 0, "a lost view leaves no row")
  tap.equal(#lost.notifications, before_loss + 1, "the loss notifies exactly once")
  tap.contains(lost:last_notification().body, "view closed:", "the loss notification names the cause")
  lost:advance(5000)
  tap.equal(#lost.notifications, before_loss + 1, "a lost view never notifies again")

  local trace_capped = new_host()
  load_plugin(trace_capped)
  for _ = 1, MockHost.MAX_TRACES_PER_PLUGIN do
    trace_capped.bitty.debug.trace(nil)
  end
  tap.contains(trace_capped:run("view-open"), "view open failed: E_DEF_LIMIT", "the host trace cap is surfaced")
  tap.equal(#trace_capped:bands("bottom"), 0, "a refused open leaves no row")
  tap.equal(trace_capped:timer_count(), 0, "a refused open arms no timer")
  tap.equal(trace_capped:block_count(), view.ROW_COUNT, "a refused open keeps its hidden handles")
  trace_capped:drop_traces()
  tap.contains(trace_capped:run("view-open"), "view open", "the view opens once the cap frees")
  tap.equal(trace_capped:block_count(), view.ROW_COUNT, "a retry reuses the hidden handles")

  -- bounds and surface ------------------------------------------------------

  local wide_view = { plugins = {}, commands = {}, events = {} }
  for index = 1, 40 do
    local wide = string.rep("\u{4e16}", 120) .. index
    wide_view.plugins[index] = { id = wide, version = wide, state = "active", generation = index }
  end
  local bounded = new_host({ view = wide_view })
  load_plugin(bounded)
  bounded:run("view-open", { target = "plugins" })
  for index = 1, 200 do
    bounded:deliver("terminal.title-changed", { title = string.rep("\u{4e16}", 200), terminal_id = index }, 1)
  end
  bounded:advance(1000)
  local bounded_rows = bounded:bands("bottom")
  tap.equal(#bounded_rows, view.ROW_COUNT, "every row is visible under a full trace")
  for index, row in ipairs(bounded_rows) do
    tap.le(#row, format.MAX_LINE_BYTES, "row " .. index .. " stays within the line bound")
  end
  tap.equal(bounded.rejected_notifications or 0, 0, "the host never rejects a notification body")

  for _, host in ipairs({ mounted, cadence, paused, dropping, open_host, isolation, states, lost, bounded }) do
    for _, call in ipairs(host.calls) do
      tap.ok(ALLOWED_CALLS[call] == true, "host call is on the declared bridge surface: " .. call)
    end
    tap.equal(#host.ui_accesses, 0, "no namespace outside the bridge was reached")
  end
end

return M
