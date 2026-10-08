-- Minimal in-process `bitty` host stub for the devtools behavior tests.
--
-- This is a test double, not a host implementation: it models only the
-- Plugin API v1 subset the plugin uses (`commands`, `notify`) plus the
-- read-only `bitty.debug` backend shape from bitty main (`inspect`, `trace`,
-- `trace_get`, `control`), with fail-closed capability gates, the host's
-- per-plugin trace limit, declared-kind trace recording, and drain-on-read
-- buffers. Any access to `bitty.ui` (or an unknown namespace) is recorded so
-- tests can assert the plugin never touches UI surfaces. It performs no I/O.
--
-- Deliberate simplifications versus the real host:
-- - `commands.register` rejects an id not reserved in `[lazy].commands`
--   immediately. The real bridge only captures the registration (and returns
--   nothing); the runtime validator then fails ACTIVATION after capture for
--   an undeclared or duplicate command.
-- - The real bridge keeps only `id`, `title`, `description`, and `run`;
--   `args_schema` / `result_schema` are not enforced by the host today.
-- - `notify.show` rejects a body over NOTIFY_MAX_CHARS characters, modeling
--   the downstream chrome rejection (`MAX_NOTIFICATION_TEXT_LEN`) rather
--   than the bridge, which accepts any string.

local MockHost = {}
MockHost.__index = MockHost

-- Mirrors bitty-runtime `plugin_runtime/debug.rs`.
MockHost.MAX_TRACES_PER_PLUGIN = 4
MockHost.DEFAULT_TRACE_MAX_EVENTS = 1000
MockHost.TRACE_MAX_EVENTS_LIMIT = 10000
MockHost.TRACE_FILTER_MAX_BYTES = 128
MockHost.MAX_INSPECT_ITEMS = 1024
-- Mirrors bitty-ui `window_chrome.rs` `MAX_NOTIFICATION_TEXT_LEN`.
MockHost.NOTIFY_MAX_CHARS = 256

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
end

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deepcopy(child)
  end
  return copy
end

local function sorted(list)
  local copy = deepcopy(list)
  table.sort(copy)
  return copy
end

local function parse_filter(pattern)
  if type(pattern) ~= "string" or #pattern == 0 or #pattern > MockHost.TRACE_FILTER_MAX_BYTES then
    fail("validation", "E_DEF_INVALID", "debug.trace filter must be 1..=128 bytes")
  end
  for index = 1, #pattern do
    local byte = string.byte(pattern, index)
    if byte <= 0x20 or byte >= 0x7F then
      fail("validation", "E_DEF_INVALID", "debug.trace filter must be printable ASCII without spaces")
    end
  end
  local star = string.find(pattern, "*", 1, true)
  if star == nil then
    return { kind = "exact", value = pattern }
  end
  if star ~= #pattern then
    fail("validation", "E_DEF_INVALID", "debug.trace filter allows a single trailing '*' only")
  end
  return { kind = "prefix", value = string.sub(pattern, 1, -2) }
end

local function filter_matches(filter, topic)
  if filter == nil then
    return true
  end
  if filter.kind == "exact" then
    return filter.value == topic
  end
  return string.sub(topic, 1, #filter.value) == filter.value
end

function MockHost.new(options)
  options = options or {}
  local self = setmetatable({}, MockHost)
  self.plugin_id = options.plugin_id or "bitty-featured.devtools"
  -- `omit_debug` / `omit_notify` simulate a host predating the read-only
  -- debug backend (or a revoked notify grant surfacing as a missing
  -- namespace): the namespace becomes an empty table, so plugin reads never
  -- trip the unknown-namespace trap and resolve to nil functions.
  self.omit_debug = options.omit_debug or false
  self.omit_notify = options.omit_notify or false
  self.grants = {}
  for _, name in ipairs(options.grants or {}) do
    self.grants[name] = true
  end
  self.declared_commands = {}
  for _, name in ipairs(options.commands or {}) do
    self.declared_commands[name] = true
  end
  self.declared_events = {}
  for _, name in ipairs(options.events or {}) do
    self.declared_events[name] = true
  end
  self.view = options.view or { plugins = {}, commands = {}, events = {} }
  self.notify_fails = options.notify_fails or false
  -- When set to an error table, the next trace_get raises it (one shot).
  self.trace_get_error = nil
  self.commands = {}
  self.notifications = {}
  self.ui_accesses = {}
  self.calls = {}
  self.traces = {}
  self.next_trace_handle = 1
  self.clock = 0
  self.sequence = 0
  self.active = true
  self.bitty = self:build_bitty()
  return self
end

function MockHost:record_call(name)
  self.calls[#self.calls + 1] = name
end

function MockHost:open_trace_count()
  local count = 0
  for _ in pairs(self.traces) do
    count = count + 1
  end
  return count
end

function MockHost:inspect(target)
  self:record_call("debug.inspect")
  if not self.grants["debug.inspect"] then
    fail("runtime", "E_CAPABILITY_DENIED", "capability 'debug.inspect' is not granted")
  end
  if type(target) ~= "string" then
    fail("validation", "E_DEF_INVALID", "debug.inspect target must be a string")
  end
  local items
  if target == "plugins" or target == "commands" or target == "events" then
    items = deepcopy(self.view[target] or {})
  elseif target == "grants" then
    local names = {}
    for name in pairs(self.grants) do
      names[#names + 1] = name
    end
    items = sorted(names)
  elseif target == "panels" then
    fail("runtime", "E_NOT_IMPLEMENTED", "bitty.debug.inspect panels is not implemented by this host")
  else
    fail("validation", "E_DEF_INVALID", "unknown debug.inspect target '" .. target .. "'")
  end
  local truncated = #items > MockHost.MAX_INSPECT_ITEMS
  while #items > MockHost.MAX_INSPECT_ITEMS do
    items[#items] = nil
  end
  return { target = target, items = items, truncated = truncated }
end

function MockHost:trace(opts)
  self:record_call("debug.trace")
  if not self.grants["debug.trace"] then
    fail("runtime", "E_CAPABILITY_DENIED", "capability 'debug.trace' is not granted")
  end
  if opts ~= nil and type(opts) ~= "table" then
    fail("validation", "E_DEF_INVALID", "debug.trace opts must be a table or nil")
  end
  opts = opts or {}
  for key in pairs(opts) do
    if key ~= "enabled" and key ~= "filter" and key ~= "max_events" and key ~= "handle" then
      fail("validation", "E_DEF_INVALID", "unknown debug.trace option '" .. tostring(key) .. "'")
    end
  end
  local enabled = opts.enabled
  if enabled == nil then
    enabled = true
  end
  if enabled == false then
    local handle = opts.handle
    if math.type(handle) ~= "integer" or self.traces[handle] == nil then
      fail("validation", "E_DEF_INVALID", "unknown debug.trace handle")
    end
    self.traces[handle] = nil
    return handle
  end
  if opts.handle ~= nil then
    fail("validation", "E_DEF_INVALID", "debug.trace handle is only valid with enabled = false")
  end
  local filter = nil
  if opts.filter ~= nil then
    filter = parse_filter(opts.filter)
  end
  local max_events = opts.max_events or MockHost.DEFAULT_TRACE_MAX_EVENTS
  if math.type(max_events) ~= "integer" or max_events < 1 or max_events > MockHost.TRACE_MAX_EVENTS_LIMIT then
    fail("validation", "E_DEF_INVALID", "debug.trace max_events out of range")
  end
  if self:open_trace_count() >= MockHost.MAX_TRACES_PER_PLUGIN then
    fail("budget", "E_DEF_LIMIT", "debug.trace limit (4 per plugin) exceeded")
  end
  local handle = self.next_trace_handle
  self.next_trace_handle = handle + 1
  self.traces[handle] = { filter = filter, max_events = max_events, records = {}, dropped = 0 }
  return handle
end

function MockHost:trace_get(handle)
  self:record_call("debug.trace_get")
  if not self.grants["debug.trace"] then
    fail("runtime", "E_CAPABILITY_DENIED", "capability 'debug.trace' is not granted")
  end
  if math.type(handle) ~= "integer" then
    fail("validation", "E_DEF_INVALID", "debug.trace_get handle must be an integer")
  end
  if self.trace_get_error ~= nil then
    local injected = self.trace_get_error
    self.trace_get_error = nil
    error(injected, 0)
  end
  local entry = self.traces[handle]
  if entry == nil then
    return nil
  end
  local result = { records = entry.records, dropped = entry.dropped }
  entry.records = {}
  entry.dropped = 0
  return result
end

-- Deliver an event the way the runtime records traces: once, only for
-- declared kinds, only while Active, filtered, drop-oldest.
function MockHost:deliver(topic, payload, elapsed_ms)
  self.clock = self.clock + (elapsed_ms or 1)
  self.sequence = self.sequence + 1
  if not self.active or not self.declared_events[topic] then
    return
  end
  for _, entry in pairs(self.traces) do
    if filter_matches(entry.filter, topic) then
      if #entry.records >= entry.max_events then
        table.remove(entry.records, 1)
        entry.dropped = entry.dropped + 1
      end
      entry.records[#entry.records + 1] = {
        topic = topic,
        sequence = self.sequence,
        timestamp = self.clock,
        payload = deepcopy(payload or {}),
      }
    end
  end
end

-- Simulate the host dropping every trace (reload, failure, disposal).
function MockHost:drop_traces()
  self.traces = {}
end

function MockHost:build_bitty()
  local self = self
  local debug = {
    inspect = function(target)
      return self:inspect(target)
    end,
    trace = function(opts)
      return self:trace(opts)
    end,
    trace_get = function(handle)
      return self:trace_get(handle)
    end,
    control = function()
      self:record_call("debug.control")
      fail("runtime", "E_NOT_IMPLEMENTED", "bitty.debug.control is not implemented by this host")
    end,
  }
  local notify = {
    show = function(payload)
      self:record_call("notify.show")
        if not self.grants["platform.notify"] then
          fail("runtime", "E_CAPABILITY_DENIED", "capability 'platform.notify' is not granted")
        end
        if self.notify_fails then
          fail("budget", "E_RATE_LIMITED", "notification rate exceeded")
        end
        if type(payload) ~= "table" or type(payload.title) ~= "string" then
          fail("validation", "E_DEF_INVALID", "notification title must be a string")
        end
        if payload.body ~= nil and type(payload.body) ~= "string" then
          fail("validation", "E_DEF_INVALID", "notification body must be a string")
        end
        local length = payload.body and utf8.len(payload.body) or 0
        if length == nil or length > MockHost.NOTIFY_MAX_CHARS then
          self.rejected_notifications = (self.rejected_notifications or 0) + 1
          fail("validation", "E_TEXT_TOO_LONG", "notification body exceeds 256 characters")
        end
        self.notifications[#self.notifications + 1] = deepcopy(payload)
        return true
      end,
  }
  local root = {
    api_version = "1.0.0",
    commands = {
      register = function(def)
        if type(def) ~= "table" or type(def.id) ~= "string" or type(def.title) ~= "string" then
          fail("validation", "E_DEF_INVALID", "command definition is invalid")
        end
        if type(def.run) ~= "function" then
          fail("validation", "E_DEF_INVALID", "command 'run' must be a function")
        end
        local qualified = self.plugin_id .. ":" .. def.id
        if not self.declared_commands[qualified] then
          fail("validation", "E_COMMAND_UNDECLARED", "command is not reserved in the manifest: " .. qualified)
        end
        if self.commands[qualified] ~= nil then
          fail("validation", "E_COMMAND_DUPLICATE", "duplicate command: " .. qualified)
        end
        self.commands[qualified] = def
      end,
    },
    notify = notify,
    debug = debug,
  }
  if self.omit_debug then
    root.debug = {}
  end
  if self.omit_notify then
    root.notify = {}
  end
  -- Trap every other namespace (ui, terminal, store, ...) so a test can
  -- assert the plugin never reaches outside its declared surface.
  return setmetatable(root, {
    __index = function(_, key)
      self.ui_accesses[#self.ui_accesses + 1] = tostring(key)
      return nil
    end,
  })
end

function MockHost:last_notification()
  return self.notifications[#self.notifications]
end

function MockHost:run(command_id, args)
  local qualified = self.plugin_id .. ":" .. command_id
  local def = self.commands[qualified]
  if def == nil then
    fail("validation", "E_COMMAND_UNDECLARED", "command is not registered: " .. qualified)
  end
  return def.run(args or {})
end

return MockHost
