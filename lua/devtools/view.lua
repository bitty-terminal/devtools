-- Live view state machine for Bitty DevTools (bitty-featured.devtools).
--
-- A docked, timer-driven view of the same read-only data the commands
-- summarize: one status line, an inspect table, and a rolling trace stream.
-- It is built only from shipped Plugin API v1 spellings — `bitty.ui.mount` /
-- `bitty.ui.update`, `bitty.timers.create` / `bitty.timers.cancel`, and the
-- read-only `bitty.debug` backend. `bitty.ui.overlay.*` is never used: the
-- view is a non-focusable bottom band and never captures input, so it needs
-- `ui.rich` alone (no `ui.overlay`, no `ui.overlay.focus`).
--
-- Presentation shape (decided in docs/design/live-view.md): a chrome band
-- paints exactly ONE row per mounted block, and an empty-text block is
-- hidden (reserves no row, paints nothing, routes no clicks). The view
-- therefore mounts `ROW_COUNT` one-row blocks into the `bottom` slot and
-- updates only the rows whose text changed. Band index 0 is the window's
-- last row and later mounts stack inward, so the status line is mounted
-- first and the newest trace line ends up on top.
--
-- Trace ownership: the view owns its OWN `bitty.debug.trace` handle, never
-- the command session's handle in `devtools.trace`. The host caps open
-- traces per plugin at four; this plugin holds at most two (commands one,
-- view one) and neither drains the other's buffer, so the seven existing
-- commands behave identically with the view open or closed.
--
-- Close hides every row and releases the view's trace handle; the mounted
-- block handles are kept for the generation and reused on reopen, because
-- Plugin API v1 has no `ui.unmount` (filed as a Core gap, see the design
-- record). Pause cancels the tick timer and stops draining, but keeps the
-- trace handle: the host buffer keeps recording (drop-oldest with a dropped
-- counter) and resume drains the backlog, so loss stays visible instead of
-- disappearing.
--
-- The `bitty` table is injected (the host in production, a stub in tests),
-- so this module performs no ambient host access. Every host call is wrapped
-- in pcall; failures return `false, err` and never raise.

local format = require("devtools.format")
local trace = require("devtools.trace")

local M = {}

-- Closed v1 slot set member: a horizontal band. `left`/`right`/`tabline`/
-- `terminal` are not hosted by this Core build, and `overlay` would need
-- `ui.overlay` plus input capture, so `bottom` is the only slot the view uses.
M.SLOT = "bottom"
M.DEFAULT_TARGET = "plugins"
-- Refresh cadence. One second is the default; the floor keeps a tick from
-- becoming a busy loop, and the ceiling keeps a view from looking stale.
M.DEFAULT_INTERVAL_MS = 1000
M.MIN_INTERVAL_MS = 500
M.MAX_INTERVAL_MS = 10000
-- Rows: status line, inspect table, trace stream. One band row each.
M.INSPECT_ROWS = 3
M.TRACE_ROWS = 4
M.ROW_COUNT = 1 + M.INSPECT_ROWS + M.TRACE_ROWS

-- Plugin-local error codes (never produced by the host).
M.E_VIEW_ACTIVE = "E_VIEW_ACTIVE"
M.E_VIEW_INACTIVE = "E_VIEW_INACTIVE"
M.E_BRIDGE_ABSENT = trace.E_BRIDGE_ABSENT

local function local_error(code, message)
  return { code = code, message = message }
end

local function is_integer(value)
  return type(value) == "number" and value == value and value == math.floor(value)
    and value ~= math.huge and value ~= -math.huge
end

-- Return `bitty[namespace][name]` when it is callable, nil otherwise. A
-- missing namespace (older host, revoked grant) must degrade instead of
-- raising "attempt to index a nil value".
local function bridge_fn(bitty, namespace, name)
  local space = bitty and bitty[namespace]
  if type(space) ~= "table" then
    return nil
  end
  local fn = space[name]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

local function absent_error(qualified)
  return local_error(M.E_BRIDGE_ABSENT, qualified .. " is not available on this host")
end

-- One declarative v1 scene row. `Text` is the only v1 kind the view needs.
local function text_row(text)
  return { kind = "Text", text = text }
end

---@param value any requested refresh interval in milliseconds
---@return integer effective interval, clamped to the documented floor/ceiling
function M.clamp_interval(value)
  if not is_integer(value) then
    return M.DEFAULT_INTERVAL_MS
  end
  local interval = math.tointeger(value) or M.DEFAULT_INTERVAL_MS
  if interval < M.MIN_INTERVAL_MS then
    return M.MIN_INTERVAL_MS
  end
  if interval > M.MAX_INTERVAL_MS then
    return M.MAX_INTERVAL_MS
  end
  return interval
end

---@param target any requested inspect target
---@return boolean whether `target` is a supported inspect target
function M.is_target(target)
  if type(target) ~= "string" then
    return false
  end
  for _, name in ipairs(format.INSPECT_TARGETS) do
    if name == target then
      return true
    end
  end
  return false
end

local View = {}
View.__index = View

---@param bitty table host bridge table (or a test stub)
---@param opts table|nil `{ on_lost = fun(reason: string) }`; `on_lost` runs at
--- most once per loss and never from a tick that is still healthy.
function M.new(bitty, opts)
  opts = opts or {}
  return setmetatable({
    bitty = bitty,
    on_lost = opts.on_lost,
    opened = false,
    paused = false,
    target = M.DEFAULT_TARGET,
    filter = nil,
    interval_ms = M.DEFAULT_INTERVAL_MS,
    blocks = nil,
    rows = {},
    inspect_lines = {},
    trace_window = {},
    trace = nil,
    timer = nil,
    records = 0,
    dropped = 0,
    errors = 0,
  }, View)
end

function View:snapshot()
  return {
    open = self.opened,
    paused = self.paused,
    target = self.target,
    interval_ms = self.interval_ms,
    records = self.records,
    dropped = self.dropped,
    errors = self.errors,
    rows = self.rows,
    tracing = self.trace ~= nil and self.trace:active(),
    timer_armed = self.timer ~= nil,
  }
end

function View:cancel_timer()
  local timer = self.timer
  self.timer = nil
  if timer == nil then
    return
  end
  local cancel = bridge_fn(self.bitty, "timers", "cancel")
  if cancel ~= nil then
    pcall(cancel, timer)
  end
end

-- Hide every mounted row (empty text = no band row) but keep the handles.
-- A close, a refused open, and a lost view all end with no visible row; only
-- a loss drops the handles (they are stale there).
function View:hide_blocks()
  local blocks = self.blocks
  if blocks == nil then
    return
  end
  local update = bridge_fn(self.bitty, "ui", "update")
  if update == nil then
    return
  end
  for _, handle in ipairs(blocks) do
    pcall(update, handle, text_row(""))
  end
end

-- Hide every mounted row and drop the handles. Used when the generation's
-- registry is gone (suspend/reload), where every handle is stale.
function View:release_blocks()
  local blocks = self.blocks
  self.blocks = nil
  if blocks == nil then
    return
  end
  local update = bridge_fn(self.bitty, "ui", "update")
  if update == nil then
    return
  end
  for _, handle in ipairs(blocks) do
    pcall(update, handle, text_row(""))
  end
end

function View:release_trace()
  local session = self.trace
  self.trace = nil
  if session == nil then
    return
  end
  pcall(function()
    session:stop()
  end)
end

-- Mark the view lost (the host dropped the generation's blocks or the trace
-- bridge) and report it once. No timer survives and no handle is kept.
function View:lose(reason)
  if not self.opened and self.blocks == nil then
    return
  end
  self:cancel_timer()
  self:release_trace()
  self:release_blocks()
  self.opened = false
  self.paused = false
  self.rows = {}
  self.inspect_lines = {}
  self.trace_window = {}
  self.lost_reason = reason
  if self.on_lost ~= nil then
    pcall(self.on_lost, reason)
  end
end

-- Arm the next one-shot tick. Plugin API v1 timers are one-shot only, so the
-- live cadence is a chain: tick -> render -> arm the next timer. One live
-- timer at a time, far below the host's live-timer cap.
-- Returns `true` or `false, err` (E_DEF_LIMIT / E_BRIDGE_ABSENT).
function View:schedule()
  self:cancel_timer()
  if not self.opened or self.paused then
    return true
  end
  local create = bridge_fn(self.bitty, "timers", "create")
  if create == nil then
    return false, absent_error("bitty.timers.create")
  end
  local ok, timer = pcall(create, self.interval_ms, function()
    self:on_timer()
  end)
  if not ok then
    return false, timer
  end
  if not is_integer(timer) then
    return false, local_error("E_UNKNOWN", "host returned an invalid timer handle")
  end
  self.timer = math.tointeger(timer)
  return true
end

function View:on_timer()
  self.timer = nil
  if not self.opened or self.paused then
    return
  end
  local ok, err = pcall(View.tick, self)
  if not ok then
    self.errors = self.errors + 1
    self.lost_reason = tostring(err)
  end
  -- Re-arm only when the tick left the view open and running; a lost view
  -- has already cancelled everything.
  self:schedule()
end

-- One refresh: drain the view's trace, inspect the target, and repaint the
-- rows whose text changed. Never raises.
function View:tick()
  if not self.opened then
    return
  end
  self:tick_trace()
  self:tick_inspect()
  self:render()
end

function View:tick_inspect()
  local inspect = bridge_fn(self.bitty, "debug", "inspect")
  if inspect == nil then
    self.errors = self.errors + 1
    return
  end
  local ok, result = pcall(inspect, self.target)
  if not ok then
    self.errors = self.errors + 1
    return
  end
  self.inspect_lines = format.inspect_lines(self.target, result, M.INSPECT_ROWS)
end

function View:tick_trace()
  local session = self.trace
  if session == nil then
    return
  end
  if not session:active() then
    -- The host dropped the handle (reload, suspend, disposal) or a restart
    -- failed earlier: try again, so a transient cap recovers on its own.
    local restarted = session:start(self.filter)
    if not restarted then
      self.errors = self.errors + 1
      return
    end
  end
  local ok, result = session:dump()
  if not ok then
    self.errors = self.errors + 1
    return
  end
  self.records = self.records + #result.records
  if is_integer(result.dropped) then
    self.dropped = self.dropped + result.dropped
  end
  for _, line in ipairs(format.trace_lines(result, M.TRACE_ROWS)) do
    self.trace_window[#self.trace_window + 1] = line
  end
  while #self.trace_window > M.TRACE_ROWS do
    table.remove(self.trace_window, 1)
  end
end

-- Rows in mount order (index 1 is the window's bottom row). Only changed
-- rows are pushed through `ui.update`; an unchanged row costs nothing.
function View:render()
  local blocks = self.blocks
  if blocks == nil then
    return
  end
  local update = bridge_fn(self.bitty, "ui", "update")
  if update == nil then
    self:lose("bitty.ui.update is not available on this host")
    return
  end
  local rows = {}
  rows[1] = format.view_header({
    status = self.paused and "paused" or "live",
    target = self.target,
    interval_ms = self.interval_ms,
    records = self.records,
    dropped = self.dropped,
    errors = self.errors,
  })
  for index = 1, M.INSPECT_ROWS do
    rows[1 + index] = self.inspect_lines[index] or ""
  end
  for index = 1, M.TRACE_ROWS do
    -- Newest record on the top row: mount index grows inward/upward.
    local line = self.trace_window[#self.trace_window - index + 1]
    rows[1 + M.INSPECT_ROWS + (M.TRACE_ROWS - index + 1)] = line or ""
  end
  for index = 1, M.ROW_COUNT do
    local text = rows[index] or ""
    if text ~= self.rows[index] then
      local ok, updated = pcall(update, blocks[index], text_row(text))
      if not ok then
        self.errors = self.errors + 1
      elseif updated ~= true then
        -- A stale handle means the host cleared the generation's blocks
        -- (suspend/reload); the view cannot paint anymore.
        self:lose("the host dropped the view blocks")
        return
      end
      self.rows[index] = text
    end
  end
end

-- Mount every row block, or reuse the generation's existing handles. Rows
-- start hidden (empty text) so a failed mount leaves nothing on screen.
function View:mount_blocks()
  if self.blocks ~= nil then
    return true
  end
  local mount = bridge_fn(self.bitty, "ui", "mount")
  if mount == nil then
    return false, absent_error("bitty.ui.mount")
  end
  local blocks = {}
  for index = 1, M.ROW_COUNT do
    local ok, handle = pcall(mount, M.SLOT, text_row(""))
    if not ok then
      self.blocks = blocks
      self:release_blocks()
      return false, handle
    end
    if not is_integer(handle) then
      self.blocks = blocks
      self:release_blocks()
      return false, local_error("E_UNKNOWN", "host returned an invalid ui block handle")
    end
    blocks[index] = math.tointeger(handle)
  end
  self.blocks = blocks
  return true
end

---@param opts table `{ target = string, filter = string|nil, interval_ms = integer }`
---@return boolean, table|nil state on success, error table on failure
function View:open(opts)
  if self.opened then
    return false, local_error(M.E_VIEW_ACTIVE, "a live view is already open; close it first")
  end
  opts = opts or {}
  if not M.is_target(opts.target) then
    return false, local_error("E_DEF_INVALID", "target must be one of the inspect targets")
  end
  -- Resolve every bridge the view needs before touching the host, so a
  -- degraded host fails closed with nothing mounted and nothing ticking.
  if bridge_fn(self.bitty, "ui", "mount") == nil then
    return false, absent_error("bitty.ui.mount")
  end
  if bridge_fn(self.bitty, "ui", "update") == nil then
    return false, absent_error("bitty.ui.update")
  end
  if bridge_fn(self.bitty, "timers", "create") == nil then
    return false, absent_error("bitty.timers.create")
  end
  if bridge_fn(self.bitty, "debug", "inspect") == nil then
    return false, absent_error("bitty.debug.inspect")
  end

  self.target = opts.target
  self.filter = opts.filter
  self.interval_ms = M.clamp_interval(opts.interval_ms)
  self.records = 0
  self.dropped = 0
  self.errors = 0
  self.inspect_lines = {}
  self.trace_window = {}
  self.rows = {}
  self.lost_reason = nil

  local mounted, mount_err = self:mount_blocks()
  if not mounted then
    return false, mount_err
  end
  -- Rows mount hidden (empty text); record that so the first tick updates only
  -- the rows that actually gain text.
  self.rows = {}
  for index = 1, M.ROW_COUNT do
    self.rows[index] = ""
  end

  -- The view's own trace handle (never the command session's).
  self.trace = trace.new(self.bitty and self.bitty.debug)
  local started, start_err = self.trace:start(self.filter)
  if not started then
    -- Keep the mounted (hidden) handles for a retry; the host has no unmount.
    self:release_trace()
    self:hide_blocks()
    return false, start_err
  end

  self.opened = true
  self.paused = false
  self:tick()
  if not self.opened then
    return false, local_error("E_VIEW_INACTIVE", self.lost_reason or "the view was lost while opening")
  end
  local scheduled, schedule_err = self:schedule()
  if not scheduled then
    self:cancel_timer()
    self:release_trace()
    self:hide_blocks()
    self.opened = false
    return false, schedule_err
  end
  return true, self:snapshot()
end

---@return boolean, table|nil state on success, error table on failure
function View:close()
  if not self.opened then
    return false, local_error(M.E_VIEW_INACTIVE, "no live view is open")
  end
  self:cancel_timer()
  self:release_trace()
  -- Hide the rows but keep the block handles for the generation: v1 has no
  -- ui.unmount, and remounting every open would consume the 64-block budget.
  self:hide_blocks()
  self.opened = false
  self.paused = false
  self.rows = {}
  for index = 1, M.ROW_COUNT do
    self.rows[index] = ""
  end
  self.inspect_lines = {}
  self.trace_window = {}
  return true, self:snapshot()
end

---@return boolean, table|nil state on success, error table on failure
function View:pause()
  if not self.opened then
    return false, local_error(M.E_VIEW_INACTIVE, "no live view is open")
  end
  if self.paused then
    return true, self:snapshot()
  end
  self.paused = true
  -- Freeze presentation: no live timer. The trace handle stays owned by the
  -- view (single owner, released on close), so records keep accumulating in
  -- the bounded host buffer and the dropped counter keeps its meaning.
  self:cancel_timer()
  self:render()
  return true, self:snapshot()
end

---@return boolean, table|nil state on success, error table on failure
function View:resume()
  if not self.opened then
    return false, local_error(M.E_VIEW_INACTIVE, "no live view is open")
  end
  if not self.paused then
    return true, self:snapshot()
  end
  self.paused = false
  -- Drain the backlog accumulated while paused before re-arming the timer.
  self:tick()
  if not self.opened then
    return false, local_error("E_VIEW_INACTIVE", self.lost_reason or "the view was lost")
  end
  local scheduled, schedule_err = self:schedule()
  if not scheduled then
    -- The rows are still mounted and visible, but without a timer the view
    -- cannot refresh: report the refusal and leave it coherently paused.
    self:cancel_timer()
    self.paused = true
    return false, schedule_err
  end
  return true, self:snapshot()
end

return M
