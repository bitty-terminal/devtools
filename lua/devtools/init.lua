-- Entry point for Bitty DevTools (bitty-featured.devtools).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here (commands, the trace handle) for the lifetime of
-- that generation. Registration calls are valid only while init.lua runs.
--
-- Surface: Plugin API v1 (`bitty.commands`, `bitty.notify`, `bitty.ui.mount` /
-- `bitty.ui.update`, `bitty.timers.create` / `cancel`) plus the read-only
-- `bitty.debug` namespace (`inspect`, `trace`, `trace_get`).
-- `bitty.debug.control` is never called, and `bitty.ui.overlay.*` is never
-- used: the optional live view is a non-focusable bottom band that never
-- captures input.
--
-- Capabilities used here must match `bitty-plugin.toml`: `debug.inspect`,
-- `debug.trace`, `platform.notify`, and `ui.rich` (the live view only). Every
-- host call is wrapped in pcall; a failure is surfaced as a concise
-- notification carrying the host error code and never escapes a command
-- handler. A missing bridge namespace or function (older host, revoked
-- grant) degrades to an `E_BRIDGE_ABSENT` error result through the same path,
-- never a raise. The seven read-only commands never touch `bitty.ui` or
-- `bitty.timers`, so they keep working grant-less when `ui.rich` is declined.
--
-- `args_schema` / `result_schema` document the intended contract only: the
-- current host bridge keeps `id`, `title`, `description`, and `run` and does
-- not enforce them, so `trace-start` validates its `filter` argument itself.
--
-- Pure formatting lives in `devtools.format`; the single-handle trace state
-- machine lives in `devtools.trace`.

local format = require("devtools.format")
local trace = require("devtools.trace")
local view = require("devtools.view")

local M = {}

local NOTIFY_TITLE = "Bitty DevTools"
local VIEW_TITLE = "DevTools: view"
-- Mirrors the host's TRACE_FILTER_MAX_BYTES; the host re-validates.
local TRACE_FILTER_MAX_BYTES = 128

local session = trace.new(bitty and bitty.debug)
-- One live view per plugin generation. The object survives close/reopen so
-- its mounted block handles are reused (Plugin API v1 has no ui.unmount).
local live = nil

-- Return `bitty[namespace][name]` when it is callable, nil otherwise. Hosts
-- predating the read-only debug backend (bitty#1573) have no `bitty.debug`,
-- and a revoked grant can surface as a missing `bitty.notify`. Indexing a
-- missing namespace raises past pcall, so every handler below resolves its
-- bridge function through here first and degrades to a bounded error result
-- (E_BRIDGE_ABSENT) instead of a raise.
local function bridge_fn(namespace, name)
  local space = bitty and bitty[namespace]
  local fn = space and space[name]
  if type(fn) == "function" then
    return fn
  end
  return nil
end

-- Show a one-line notice derived from `text` (at most
-- format.NOTIFY_MAX_CHARS characters, the host chrome limit) and return the
-- full bounded `text` as the command result. A notify failure (rate policy,
-- revoked grant) or an absent notify bridge is swallowed so it can never
-- turn a successful command into a crash.
local function show(title, text, urgency)
  local notify = bridge_fn("notify", "show")
  if notify ~= nil then
    pcall(notify, {
      title = title,
      body = format.notice(text),
      urgency = urgency or "low",
    })
  end
  return text
end

local function bridge_absent(action, qualified)
  return show(
    NOTIFY_TITLE,
    format.error(action, { code = "E_BRIDGE_ABSENT", message = qualified .. " is not available on this host" }),
    "normal"
  )
end

local function show_error(action, err)
  return show(NOTIFY_TITLE, format.error(action, err), "normal")
end

local function inspect_command(target)
  return function(_args)
    local inspect = bridge_fn("debug", "inspect")
    if inspect == nil then
      return bridge_absent("inspect " .. target, "bitty.debug.inspect")
    end
    local ok, result = pcall(inspect, target)
    if not ok then
      return show_error("inspect " .. target, result)
    end
    local title, body = format.inspect(target, result)
    return show(title, body)
  end
end

local INSPECT_TITLES = {
  plugins = "DevTools: list plugins",
  commands = "DevTools: list commands",
  events = "DevTools: list event subscriptions",
  grants = "DevTools: show own grants",
}

local INSPECT_DESCRIPTIONS = {
  plugins = "Summarize plugin ids, versions, lifecycle states, and generations.",
  commands = "Summarize registered plugin commands.",
  events = "Summarize plugin event subscriptions.",
  grants = "List the capabilities granted to Bitty DevTools.",
}

local EMPTY_ARGS_SCHEMA = { type = "object", properties = {}, additionalProperties = false }
local RESULT_SCHEMA = { type = "string" }

local register_command = bridge_fn("commands", "register")
if register_command == nil then
  return M
end

for _, target in ipairs(format.INSPECT_TARGETS) do
  register_command({
    id = target,
    title = INSPECT_TITLES[target],
    description = INSPECT_DESCRIPTIONS[target],
    args_schema = EMPTY_ARGS_SCHEMA,
    result_schema = RESULT_SCHEMA,
    run = inspect_command(target),
  })
end

-- Extract the optional `filter` argument. Returns `true, filter_or_nil` or
-- `false, err` for a value that cannot be a host filter.
local function filter_arg(args)
  if type(args) ~= "table" or args.filter == nil then
    return true, nil
  end
  local filter = args.filter
  if type(filter) ~= "string" or #filter == 0 or #filter > TRACE_FILTER_MAX_BYTES then
    return false, {
      code = "E_DEF_INVALID",
      message = string.format("filter must be a 1..%d byte string", TRACE_FILTER_MAX_BYTES),
    }
  end
  return true, filter
end

register_command({
  id = "trace-start",
  title = "DevTools: start event trace",
  description = "Start tracing the declared event kinds, optionally narrowed by a filter such as terminal.*.",
  args_schema = {
    type = "object",
    properties = {
      filter = { type = "string", minLength = 1, maxLength = TRACE_FILTER_MAX_BYTES },
    },
    additionalProperties = false,
  },
  result_schema = RESULT_SCHEMA,
  run = function(args)
    local valid, filter = filter_arg(args)
    if not valid then
      return show_error("trace start", filter)
    end
    local ok, result = session:start(filter)
    if not ok then
      return show_error("trace start", result)
    end
    local scope = filter and ("filter " .. format.field(filter)) or "all declared kinds"
    return show(NOTIFY_TITLE, string.format("trace %d started (%s)", result, scope))
  end,
})

register_command({
  id = "trace-dump",
  title = "DevTools: dump event trace",
  description = "Drain buffered trace records and summarize them, including the dropped count.",
  args_schema = EMPTY_ARGS_SCHEMA,
  result_schema = RESULT_SCHEMA,
  run = function(_args)
    local filter = session.filter
    local ok, result = session:dump()
    if not ok then
      return show_error("trace dump", result)
    end
    local title, body = format.trace(result, filter)
    return show(title, body)
  end,
})

register_command({
  id = "trace-stop",
  title = "DevTools: stop event trace",
  description = "Drain the final trace records and close the trace.",
  args_schema = EMPTY_ARGS_SCHEMA,
  result_schema = RESULT_SCHEMA,
  run = function(_args)
    local filter = session.filter
    local ok, outcome = session:stop()
    if not ok then
      return show_error("trace stop", outcome)
    end
    if outcome.kind == trace.STOP_GONE then
      return show(NOTIFY_TITLE, "trace stopped (the host had already dropped it)")
    end
    if outcome.kind == trace.STOP_DRAIN_FAILED then
      return show(NOTIFY_TITLE, "trace stopped; final drain failed: " .. format.error_detail(outcome.err), "normal")
    end
    local title, body = format.trace(outcome.result, filter)
    return show(title, "trace stopped; " .. body)
  end,
})

-- Live view commands. The view is optional: it needs `ui.rich`, `bitty.ui`,
-- and `bitty.timers`, and every command above still works without them. A
-- declined/absent grant surfaces as a typed error result through the same
-- notification path the other commands use — never a raise, never a silent
-- no-op.
local function view_state_text(state)
  return string.format(
    "%d records, %d dropped, %d errors",
    state.records,
    state.dropped,
    state.errors
  )
end

local function ensure_view()
  if live == nil then
    live = view.new(bitty, {
      on_lost = function(reason)
        -- One notification per loss, never per tick: the tick path is silent
        -- by design so the refresh budget never touches the notify policy.
        show(VIEW_TITLE, "view closed: " .. format.field(reason), "normal")
      end,
    })
  end
  return live
end

register_command({
  id = "view-open",
  title = "DevTools: open the live view",
  description = "Mount a docked live view (status line, inspect table, trace stream) refreshed on a timer.",
  args_schema = {
    type = "object",
    properties = {
      target = { type = "string", enum = format.INSPECT_TARGETS },
      filter = { type = "string", minLength = 1, maxLength = TRACE_FILTER_MAX_BYTES },
      interval_ms = { type = "integer" },
    },
    additionalProperties = false,
  },
  result_schema = RESULT_SCHEMA,
  run = function(args)
    local valid, filter = filter_arg(args)
    if not valid then
      return show_error("view open", filter)
    end
    local target = view.DEFAULT_TARGET
    if type(args) == "table" and args.target ~= nil then
      if not view.is_target(args.target) then
        return show_error("view open", {
          code = "E_DEF_INVALID",
          message = "target must be one of plugins, commands, events, grants",
        })
      end
      target = args.target
    end
    local interval = nil
    if type(args) == "table" and args.interval_ms ~= nil then
      local value = args.interval_ms
      if type(value) ~= "number" or value ~= math.floor(value) then
        return show_error("view open", {
          code = "E_DEF_INVALID",
          message = "interval_ms must be an integer",
        })
      end
      interval = value
    end
    local ok, result = ensure_view():open({ target = target, filter = filter, interval_ms = interval })
    if not ok then
      return show_error("view open", result)
    end
    local scope = filter and ("filter " .. format.field(filter)) or "all declared kinds"
    return show(
      VIEW_TITLE,
      string.format(
        "view open (%s, %s, %.1fs, %d rows)",
        result.target,
        scope,
        result.interval_ms / 1000,
        view.ROW_COUNT
      )
    )
  end,
})

register_command({
  id = "view-close",
  title = "DevTools: close the live view",
  description = "Hide the live view, cancel its timer, and release its trace handle.",
  args_schema = EMPTY_ARGS_SCHEMA,
  result_schema = RESULT_SCHEMA,
  run = function(_args)
    if live == nil then
      return show_error("view close", { code = view.E_VIEW_INACTIVE, message = "no live view is open" })
    end
    local ok, result = live:close()
    if not ok then
      return show_error("view close", result)
    end
    return show(VIEW_TITLE, "view closed; " .. view_state_text(result))
  end,
})

register_command({
  id = "view-pause",
  title = "DevTools: pause the live view",
  description = "Freeze the live view and cancel its timer; the trace keeps recording until resume.",
  args_schema = EMPTY_ARGS_SCHEMA,
  result_schema = RESULT_SCHEMA,
  run = function(_args)
    if live == nil then
      return show_error("view pause", { code = view.E_VIEW_INACTIVE, message = "no live view is open" })
    end
    local ok, result = live:pause()
    if not ok then
      return show_error("view pause", result)
    end
    return show(
      VIEW_TITLE,
      "view paused (" .. view_state_text(result) .. "); the trace keeps recording, resume drains it"
    )
  end,
})

register_command({
  id = "view-resume",
  title = "DevTools: resume the live view",
  description = "Drain the records buffered while paused and restart the refresh timer.",
  args_schema = EMPTY_ARGS_SCHEMA,
  result_schema = RESULT_SCHEMA,
  run = function(_args)
    if live == nil then
      return show_error("view resume", { code = view.E_VIEW_INACTIVE, message = "no live view is open" })
    end
    local ok, result = live:resume()
    if not ok then
      return show_error("view resume", result)
    end
    return show(VIEW_TITLE, "view resumed; " .. view_state_text(result))
  end,
})

return M
