-- Entry point for Bitty DevTools (bitty-featured.devtools).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here (commands, the trace handle) for the lifetime of
-- that generation. Registration calls are valid only while init.lua runs.
--
-- Surface: Plugin API v1 (`bitty.commands`, `bitty.notify`) plus the
-- read-only `bitty.debug` namespace (`inspect`, `trace`, `trace_get`).
-- `bitty.debug.control` is never called, and no `bitty.ui` surface is used:
-- UI stays notification-only by scope; the upstream overlay APIs have landed
-- (CTX-0911, CTX-0941), and bitty#1442 is not a GUI blocker.
--
-- Capabilities used here must match `bitty-plugin.toml`: `debug.inspect`,
-- `debug.trace`, and `platform.notify`. Every host call is wrapped in pcall;
-- a failure is surfaced as a concise notification carrying the host error
-- code and never escapes a command handler.
--
-- `args_schema` / `result_schema` document the intended contract only: the
-- current host bridge keeps `id`, `title`, `description`, and `run` and does
-- not enforce them, so `trace-start` validates its `filter` argument itself.
--
-- Pure formatting lives in `devtools.format`; the single-handle trace state
-- machine lives in `devtools.trace`.

local format = require("devtools.format")
local trace = require("devtools.trace")

local M = {}

local NOTIFY_TITLE = "Bitty DevTools"
-- Mirrors the host's TRACE_FILTER_MAX_BYTES; the host re-validates.
local TRACE_FILTER_MAX_BYTES = 128

local session = trace.new(bitty.debug)

-- Show a one-line notice derived from `text` (at most
-- format.NOTIFY_MAX_CHARS characters, the host chrome limit) and return the
-- full bounded `text` as the command result. A notify failure (rate policy,
-- revoked grant) is swallowed so it can never turn a successful command into
-- a crash.
local function show(title, text, urgency)
  pcall(bitty.notify.show, {
    title = title,
    body = format.notice(text),
    urgency = urgency or "low",
  })
  return text
end

local function show_error(action, err)
  return show(NOTIFY_TITLE, format.error(action, err), "normal")
end

local function inspect_command(target)
  return function(_args)
    local ok, result = pcall(bitty.debug.inspect, target)
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

for _, target in ipairs(format.INSPECT_TARGETS) do
  bitty.commands.register({
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

bitty.commands.register({
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

bitty.commands.register({
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

bitty.commands.register({
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

return M
