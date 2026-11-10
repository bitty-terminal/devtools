-- Minimal in-process `bitty` host stub for the devtools behavior tests.
--
-- This is a test double, not a host implementation: it models only the
-- Plugin API v1 subset the plugin uses (`commands`, `notify`, `ui.mount` /
-- `ui.update`, `timers.create` / `cancel`) plus the read-only `bitty.debug`
-- backend shape from bitty main (`inspect`, `trace`, `trace_get`, `control`),
-- with fail-closed capability gates, the host's per-plugin trace limit,
-- declared-kind trace recording, drain-on-read buffers, one-row-per-block
-- bands with hidden (empty-text) blocks, and a deterministic one-shot timer
-- queue driven by `advance(ms)`. Any access to an unknown namespace is
-- recorded so tests can assert the plugin never reaches outside its declared
-- surface. It performs no I/O.
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
-- Mirrors bitty-lua `ui.rs` budgets (SCN-1..5) and the v1 bridge depth.
MockHost.MAX_UI_BLOCKS = 64
MockHost.UI_MAX_NODES = 2048
MockHost.UI_MAX_DEPTH = 16
MockHost.UI_MAX_TEXT_BYTES = 256 * 1024
-- Closed v1 slot set; only horizontal bands and the retained overlay are
-- hosted by this build (bitty-runtime `band_slots.rs`).
MockHost.UI_SLOTS = {
  terminal = true,
  top = true,
  bottom = true,
  left = true,
  right = true,
  tabline = true,
  overlay = true,
}
MockHost.UI_HOSTED_SLOTS = { top = true, bottom = true, overlay = true }
-- Mirrors bitty-lua `timers` cap (32 live timers per plugin).
MockHost.MAX_TIMERS_PER_PLUGIN = 32
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
  -- `omit_ui` / `omit_timers` simulate a host that predates the UI/timer
  -- bridges: the namespace becomes an empty table, so plugin reads resolve to
  -- nil functions and never trip the unknown-namespace trap.
  self.omit_ui = options.omit_ui or false
  self.omit_timers = options.omit_timers or false
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
  -- Mounted UI blocks in mount order (the host's registry order) and the live
  -- one-shot timer set, so a test can drive the refresh chain deterministically.
  self.ui_blocks = {}
  self.next_block_handle = 1
  self.timers = {}
  self.next_timer_handle = 1
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

-- Validate one declarative v1 scene value (bitty-lua `ui.rs`): the reduced
-- `Text` / `Row` / `Column` / `List` vocabulary, bounded nodes/depth/text.
-- Returns the total text bytes; raises E_UI_COMPONENT_INVALID otherwise.
local function validate_component(value)
  local nodes = 0
  local text_bytes = 0

  local function walk(node, depth)
    if type(node) ~= "table" then
      fail("validation", "E_UI_COMPONENT_INVALID", "component node must be a table")
    end
    nodes = nodes + 1
    if nodes > MockHost.UI_MAX_NODES then
      fail("validation", "E_UI_COMPONENT_INVALID", "component exceeds the node budget")
    end
    if depth > MockHost.UI_MAX_DEPTH then
      fail("validation", "E_UI_COMPONENT_INVALID", "component exceeds the depth budget")
    end
    local kind = node.kind
    if kind == "Text" then
      if type(node.text) ~= "string" then
        fail("validation", "E_UI_COMPONENT_INVALID", "Text node requires a string text")
      end
      text_bytes = text_bytes + #node.text
    elseif kind == "Row" or kind == "Column" or kind == "List" then
      if type(node.children) ~= "table" then
        fail("validation", "E_UI_COMPONENT_INVALID", kind .. " node requires children")
      end
      for _, child in ipairs(node.children) do
        walk(child, depth + 1)
      end
    else
      fail("validation", "E_UI_COMPONENT_INVALID", "unknown component kind")
    end
  end

  walk(value, 1)
  if text_bytes > MockHost.UI_MAX_TEXT_BYTES then
    fail("validation", "E_UI_COMPONENT_INVALID", "component exceeds the text budget")
  end
  return text_bytes
end

-- Flatten a component subtree the way the band renderer flattens runs.
local function flatten_component(node)
  if type(node) ~= "table" then
    return ""
  end
  if node.kind == "Text" then
    return node.text or ""
  end
  local parts = {}
  for _, child in ipairs(node.children or {}) do
    parts[#parts + 1] = flatten_component(child)
  end
  return table.concat(parts, "")
end

function MockHost:block_count()
  return #self.ui_blocks
end

function MockHost:timer_count()
  return #self.timers
end

-- Simulate the host clearing a generation's blocks (suspend/dispose).
function MockHost:drop_ui_blocks()
  self.ui_blocks = {}
end

function MockHost:ui_mount(slot, component)
  self:record_call("ui.mount")
  if not self.grants["ui.rich"] then
    fail("runtime", "E_CAPABILITY_DENIED", "capability 'ui.rich' is not granted")
  end
  if type(slot) ~= "string" then
    fail("validation", "E_UI_COMPONENT_INVALID", "ui.mount slot must be a string")
  end
  if not MockHost.UI_SLOTS[slot] then
    fail("validation", "E_UI_COMPONENT_INVALID", "unknown UI slot '" .. slot .. "'")
  end
  if not MockHost.UI_HOSTED_SLOTS[slot] then
    fail("runtime", "E_UI_UNAVAILABLE", "host has no surface for slot '" .. slot .. "'")
  end
  validate_component(component)
  if #self.ui_blocks >= MockHost.MAX_UI_BLOCKS then
    fail("budget", "E_UI_BLOCK_BUDGET", "ui block registry is full (64 blocks)")
  end
  local handle = self.next_block_handle
  self.next_block_handle = handle + 1
  self.ui_blocks[#self.ui_blocks + 1] = {
    handle = handle,
    slot = slot,
    component = deepcopy(component),
    version = 1,
  }
  return handle
end

function MockHost:ui_update(handle, component)
  self:record_call("ui.update")
  if not self.grants["ui.rich"] then
    fail("runtime", "E_CAPABILITY_DENIED", "capability 'ui.rich' is not granted")
  end
  validate_component(component)
  for _, block in ipairs(self.ui_blocks) do
    if block.handle == handle then
      block.component = deepcopy(component)
      block.version = block.version + 1
      return true
    end
  end
  -- Stale or foreign handle: documented `false`, never an error.
  return false
end

function MockHost:timers_create(delay_ms, callback)
  self:record_call("timers.create")
  -- The bridge accepts a non-negative delay and raises E_DEF_LIMIT (not the
  -- E_BUDGET_TIMER the SDK definitions name) when the live-timer cap is hit
  -- (bitty-lua/src/host.rs:4845-4900); the mock mirrors the host.
  if math.type(delay_ms) ~= "integer" or delay_ms < 0 then
    fail("validation", "E_DEF_INVALID", "timer delay must be a non-negative integer")
  end
  if type(callback) ~= "function" then
    fail("validation", "E_DEF_INVALID", "timer callback must be a function")
  end
  if #self.timers >= MockHost.MAX_TIMERS_PER_PLUGIN then
    fail("validation", "E_DEF_LIMIT", "timer limit (32 per plugin) exceeded")
  end
  local handle = self.next_timer_handle
  self.next_timer_handle = handle + 1
  self.timers[#self.timers + 1] = {
    handle = handle,
    due = self.clock + delay_ms,
    callback = callback,
  }
  return handle
end

function MockHost:timers_cancel(handle)
  self:record_call("timers.cancel")
  for index, timer in ipairs(self.timers) do
    if timer.handle == handle then
      table.remove(self.timers, index)
      return true
    end
  end
  return false
end

-- Advance the fake clock, firing every due one-shot timer in due/handle order
-- (callbacks may arm the next timer). Raises if a callback raises, so a broken
-- tick surfaces as a suite crash instead of a silent stall.
function MockHost:advance(ms)
  local target = self.clock + (ms or 0)
  while true do
    local best, best_index = nil, nil
    for index, timer in ipairs(self.timers) do
      if timer.due <= target then
        if best == nil or timer.due < best.due or (timer.due == best.due and timer.handle < best.handle) then
          best, best_index = timer, index
        end
      end
    end
    if best == nil then
      break
    end
    table.remove(self.timers, best_index)
    if best.due > self.clock then
      self.clock = best.due
    end
    best.callback()
  end
  self.clock = target
end

-- Visible band rows on `edge`, outermost (window edge) first. Hidden blocks
-- (empty flattened text) reserve no row, and one plugin's blocks keep mount
-- order under the host's stable plugin-id sort.
function MockHost:bands(edge)
  edge = edge or "bottom"
  local rows = {}
  for _, block in ipairs(self.ui_blocks) do
    if block.slot == edge then
      local text = flatten_component(block.component)
      if text ~= "" then
        rows[#rows + 1] = text
      end
    end
  end
  return rows
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
  local ui = {
    mount = function(slot, component)
      return self:ui_mount(slot, component)
    end,
    update = function(handle, component)
      return self:ui_update(handle, component)
    end,
  }
  local timers = {
    create = function(delay_ms, callback)
      return self:timers_create(delay_ms, callback)
    end,
    cancel = function(handle)
      return self:timers_cancel(handle)
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
    ui = ui,
    timers = timers,
  }
  if self.omit_debug then
    root.debug = {}
  end
  if self.omit_notify then
    root.notify = {}
  end
  if self.omit_ui then
    root.ui = {}
  end
  if self.omit_timers then
    root.timers = {}
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
