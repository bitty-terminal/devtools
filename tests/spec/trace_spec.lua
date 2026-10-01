-- Unit tests for the `devtools.trace` single-handle state machine.

local MockHost = require("support.mock_host")
local trace = require("devtools.trace")

local M = {}

local EVENTS = { "terminal.opened", "terminal.closed", "terminal.bell" }

function M.run(context)
  local tap = context.tap
  print("# trace")

  local function new_host(grants)
    return MockHost.new({ grants = grants or { "debug.trace" }, events = EVENTS })
  end

  -- idle -> tracing -> dump -> stop -> idle
  local host = new_host()
  local session = trace.new(host.bitty.debug)
  tap.equal(session:active(), false, "new session is idle")
  local ok, handle = session:start(nil)
  tap.ok(ok, "start succeeds")
  tap.equal(math.type(handle), "integer", "start returns an integer handle")
  tap.equal(session:active(), true, "session is tracing after start")
  tap.equal(session.filter, nil, "no filter recorded when none given")

  host:deliver("terminal.opened", { terminal_id = 1 })
  host:deliver("focus.changed", { view_id = 1 }) -- undeclared: never recorded
  host:deliver("terminal.closed", { terminal_id = 1 })
  local dumped, result = session:dump()
  tap.ok(dumped, "dump succeeds")
  tap.equal(#result.records, 2, "dump returns only declared kinds")
  tap.equal(result.records[1].topic, "terminal.opened", "records keep delivery order")
  local again_ok, again = session:dump()
  tap.ok(again_ok, "second dump succeeds")
  tap.equal(#again.records, 0, "dump drains the host buffer")
  tap.equal(session:active(), true, "dump keeps the trace open")

  host:deliver("terminal.bell", {})
  local stopped, final = session:stop()
  tap.ok(stopped, "stop succeeds")
  tap.equal(#final.records, 1, "stop returns the final drained records")
  tap.equal(session:active(), false, "session is idle after stop")
  tap.equal(host:open_trace_count(), 0, "stop closes the host trace")

  -- refusing a second start while tracing
  local busy_host = new_host()
  local busy = trace.new(busy_host.bitty.debug)
  busy:start(nil)
  local second_ok, second_err = busy:start(nil)
  tap.equal(second_ok, false, "second start is refused")
  tap.equal(second_err.code, trace.E_TRACE_ACTIVE, "second start reports E_TRACE_ACTIVE")
  tap.equal(busy_host:open_trace_count(), 1, "only one host trace is ever opened")

  -- dump/stop while idle
  local idle = trace.new(new_host().bitty.debug)
  local idle_dump_ok, idle_dump_err = idle:dump()
  tap.equal(idle_dump_ok, false, "dump while idle fails")
  tap.equal(idle_dump_err.code, trace.E_TRACE_INACTIVE, "dump while idle reports E_TRACE_INACTIVE")
  local idle_stop_ok, idle_stop_err = idle:stop()
  tap.equal(idle_stop_ok, false, "stop while idle fails")
  tap.equal(idle_stop_err.code, trace.E_TRACE_INACTIVE, "stop while idle reports E_TRACE_INACTIVE")

  -- filter forwarded and applied by the host
  local filter_host = new_host()
  local filtered = trace.new(filter_host.bitty.debug)
  filtered:start("terminal.c*")
  tap.equal(filtered.filter, "terminal.c*", "filter is remembered")
  filter_host:deliver("terminal.opened", {})
  filter_host:deliver("terminal.closed", {})
  local _, filtered_result = filtered:dump()
  tap.equal(#filtered_result.records, 1, "host applies the prefix filter")

  -- invalid filter surfaced from the host, state stays idle
  local bad_host = new_host()
  local bad = trace.new(bad_host.bitty.debug)
  local bad_ok, bad_err = bad:start("a*b")
  tap.equal(bad_ok, false, "malformed filter fails")
  tap.equal(bad_err.code, "E_DEF_INVALID", "malformed filter reports E_DEF_INVALID")
  tap.equal(bad:active(), false, "failed start leaves the session idle")

  -- E_DEF_LIMIT when other traces already exhaust the per-plugin cap
  local limit_host = new_host()
  for _ = 1, MockHost.MAX_TRACES_PER_PLUGIN do
    limit_host.bitty.debug.trace(nil)
  end
  local limited = trace.new(limit_host.bitty.debug)
  local limit_ok, limit_err = limited:start(nil)
  tap.equal(limit_ok, false, "start fails at the host trace cap")
  tap.equal(limit_err.code, "E_DEF_LIMIT", "cap is reported as E_DEF_LIMIT")
  tap.equal(limited:active(), false, "E_DEF_LIMIT leaves the session idle")

  -- capability denied
  local denied = trace.new(new_host({}).bitty.debug)
  local denied_ok, denied_err = denied:start(nil)
  tap.equal(denied_ok, false, "start without debug.trace fails")
  tap.equal(denied_err.code, "E_CAPABILITY_DENIED", "denied start reports E_CAPABILITY_DENIED")

  -- nil drain: the host dropped the trace (reload/failure/disposal)
  local gone_host = new_host()
  local gone = trace.new(gone_host.bitty.debug)
  gone:start(nil)
  gone_host:drop_traces()
  local gone_ok, gone_err = gone:dump()
  tap.equal(gone_ok, false, "dump of a dropped trace fails")
  tap.equal(gone_err.code, trace.E_TRACE_GONE, "nil drain reports E_TRACE_GONE")
  tap.equal(gone:active(), false, "nil drain resets the session to idle")
  local restart_ok = gone:start(nil)
  tap.ok(restart_ok, "a fresh trace can start after a nil drain")

  local gone_stop_host = new_host()
  local gone_stop = trace.new(gone_stop_host.bitty.debug)
  gone_stop:start(nil)
  gone_stop_host:drop_traces()
  local gs_ok, gs_result = gone_stop:stop()
  tap.ok(gs_ok, "stop of a dropped trace succeeds")
  tap.equal(gs_result, nil, "stop of a dropped trace returns no records")
  tap.equal(gone_stop:active(), false, "stop of a dropped trace resets to idle")

  -- invalid handle shape from the host
  local weird = trace.new({
    trace = function()
      return "not-a-handle"
    end,
    trace_get = function()
      return nil
    end,
  })
  local weird_ok, weird_err = weird:start(nil)
  tap.equal(weird_ok, false, "non-integer handle is rejected")
  tap.equal(weird_err.code, "E_UNKNOWN", "non-integer handle reports E_UNKNOWN")
  tap.equal(weird:active(), false, "rejected handle leaves the session idle")

  -- close failure other than an unknown handle keeps the handle for retry
  local close_calls = 0
  local flaky = trace.new({
    trace = function(opts)
      if opts.enabled == false then
        close_calls = close_calls + 1
        if close_calls == 1 then
          error({ code = "E_TIMEOUT", message = "slow" }, 0)
        end
        return opts.handle
      end
      return 7
    end,
    trace_get = function()
      return { records = {}, dropped = 0 }
    end,
  })
  flaky:start(nil)
  local flaky_ok, flaky_err = flaky:stop()
  tap.equal(flaky_ok, false, "transient close failure is reported")
  tap.equal(flaky_err.code, "E_TIMEOUT", "transient close failure keeps its code")
  tap.equal(flaky:active(), true, "transient close failure keeps the handle")
  local retry_ok = flaky:stop()
  tap.ok(retry_ok, "stop can be retried")
  tap.equal(flaky:active(), false, "retried stop returns to idle")
end

return M
