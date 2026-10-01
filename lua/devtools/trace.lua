-- Trace session state machine for Bitty DevTools (bitty-featured.devtools).
--
-- Owns at most one `bitty.debug.trace` handle at a time. The host caps open
-- traces per plugin (E_DEF_LIMIT); holding a single handle keeps this plugin
-- far below that cap and makes start/stop/dump unambiguous.
--
-- States: idle (handle == nil) and tracing (handle ~= nil).
--   start: idle -> tracing; refused with E_TRACE_ACTIVE while tracing.
--   dump:  tracing -> tracing (drains the host buffer).
--   stop:  tracing -> idle (drains the final records, then closes).
-- A handle the host no longer knows (trace dropped on reload, failure, or
-- disposal) is detected by a nil drain and resets the machine to idle.
--
-- The `debug` table is injected (the host `bitty.debug` in production, a
-- stub in tests), so this module performs no ambient host access. Every host
-- call is wrapped in pcall; failures return `false, err` and never raise.

local M = {}

-- Plugin-local error codes (never produced by the host).
M.E_TRACE_ACTIVE = "E_TRACE_ACTIVE"
M.E_TRACE_INACTIVE = "E_TRACE_INACTIVE"
M.E_TRACE_GONE = "E_TRACE_GONE"

local Session = {}
Session.__index = Session

local function local_error(code, message)
  return { code = code, message = message }
end

local function is_handle(value)
  return math.type(value) == "integer" and value > 0
end

---@param debug table host `bitty.debug` namespace (or a test stub)
function M.new(debug)
  return setmetatable({ debug = debug, handle = nil, filter = nil }, Session)
end

function Session:active()
  return self.handle ~= nil
end

function Session:reset()
  self.handle = nil
  self.filter = nil
end

-- Open a trace. `filter` is nil (every declared kind) or a host filter
-- pattern (exact topic, or a prefix ending in a single `*`); the host owns
-- filter validation and reports E_DEF_INVALID for a malformed pattern.
-- Returns `true, handle` or `false, err`.
function Session:start(filter)
  if self.handle ~= nil then
    return false, local_error(M.E_TRACE_ACTIVE, "a trace is already running; stop it first")
  end
  local opts = { enabled = true }
  if filter ~= nil then
    opts.filter = filter
  end
  local ok, result = pcall(self.debug.trace, opts)
  if not ok then
    return false, result
  end
  if not is_handle(result) then
    return false, local_error("E_UNKNOWN", "host returned an invalid trace handle")
  end
  self.handle = result
  self.filter = filter
  return true, result
end

-- Drain buffered records without closing. Returns `true, result` where
-- result is `{ records, dropped }`, or `false, err`.
function Session:dump()
  if self.handle == nil then
    return false, local_error(M.E_TRACE_INACTIVE, "no trace is running")
  end
  local ok, result = pcall(self.debug.trace_get, self.handle)
  if not ok then
    return false, result
  end
  if result == nil then
    self:reset()
    return false, local_error(M.E_TRACE_GONE, "the host dropped the trace")
  end
  return true, result
end

-- Drain the final records, then close the trace. Returns `true, result`
-- (result may be nil when the final drain found the trace already gone) or
-- `false, err`. The machine returns to idle whenever the host no longer
-- holds the handle (successful close, unknown-handle E_DEF_INVALID, or a
-- nil drain); other close failures keep the handle so stop can be retried.
function Session:stop()
  if self.handle == nil then
    return false, local_error(M.E_TRACE_INACTIVE, "no trace is running")
  end
  local handle = self.handle
  local drained_ok, drained = pcall(self.debug.trace_get, handle)
  if drained_ok and drained == nil then
    self:reset()
    return true, nil
  end
  local ok, err = pcall(self.debug.trace, { enabled = false, handle = handle })
  if not ok then
    if type(err) == "table" and err.code == "E_DEF_INVALID" then
      self:reset()
      return true, drained_ok and drained or nil
    end
    return false, err
  end
  self:reset()
  if drained_ok then
    return true, drained
  end
  return true, nil
end

return M
