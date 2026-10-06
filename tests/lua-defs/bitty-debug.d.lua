--- Local LuaLS definitions for the `bitty.debug` namespace.
--- HAND-WRITTEN; NOT PART OF THE SDK GENERATED SURFACE.
---
--- The vendored SDK `bitty.d.lua` (bitty-plugin-sdk e1723b6) does not define
--- `bitty.debug` yet. This file mirrors the host contract introduced on bitty
--- main (c4af172b, bitty-terminal/bitty#1573: `crates/bitty-lua/src/host.rs`
--- `HostServices::debug_*` and `crates/bitty-runtime/src/plugin_runtime/debug.rs`),
--- re-verified unchanged on bitty main `811ba94c` (CTX-0005).
--- Drop it once the SDK surface generates `bitty.debug`.
---
--- `bitty.debug.control` exists on the host but always fails closed with
--- E_NOT_IMPLEMENTED and requires the high-risk `debug.control` grant; it is
--- deliberately left undefined here so LuaLS rejects any use.
---@meta bitty-debug

--- Lifecycle label reported by `inspect("plugins")`; never carries a failure message.
---@alias BittyDebugLifecycleState "unloaded"|"loading"|"activating"|"active"|"suspended"|"disposing"|"disposed"|"failed"

--- Accepted inspect targets; "panels" is reserved and fails with E_NOT_IMPLEMENTED.
---@alias BittyDebugInspectTarget "plugins"|"commands"|"events"|"grants"|"panels"

--- `inspect("plugins")` row, sorted by id.
---@class BittyDebugPluginRow
---@field id string Owner-qualified plugin id.
---@field version string Manifest version.
---@field state BittyDebugLifecycleState Stable lifecycle label.
---@field generation integer Activation generation (0 before the first activation).

--- `inspect("commands")` row, sorted by plugin, id.
---@class BittyDebugCommandRow
---@field plugin string Owning plugin id.
---@field id string Unqualified command id.
---@field title string Bounded command title.

--- `inspect("events")` row, sorted by plugin, kind.
---@class BittyDebugEventRow
---@field plugin string Owning plugin id.
---@field kind string Subscribed event kind.

--- Result of `bitty.debug.inspect`; items are capped at 1024 rows. `grants`
--- items are the caller's own sorted capability ids (strings).
---@class BittyDebugInspectResult
---@field target string Echoed target.
---@field items (BittyDebugPluginRow|BittyDebugCommandRow|BittyDebugEventRow|string)[] Bounded rows.
---@field truncated boolean Whether rows were cut at the host item ceiling.

--- Options for `bitty.debug.trace`. Unknown keys, wrong types, and
--- out-of-range values are E_DEF_INVALID.
---@class BittyDebugTraceOpts
---@field enabled? boolean true (default) opens a trace; false closes `handle`.
---@field filter? string Exact topic or prefix ending in a single `*`; 1..128 printable ASCII bytes.
---@field max_events? integer Drop-oldest ring size, 1..10000 (default 1000).
---@field handle? integer Required with enabled = false, rejected otherwise.

--- One drained trace record.
---@class BittyDebugTraceRecord
---@field topic string Event kind.
---@field sequence integer Runtime event sequence.
---@field timestamp integer Milliseconds on a monotonic host clock (no wall clock).
---@field payload table Event payload, or `{ truncated = true, bytes = n }` above the host ceiling.

--- Result of `bitty.debug.trace_get`; draining empties the buffer.
---@class BittyDebugTraceResult
---@field records BittyDebugTraceRecord[] Buffered records, oldest first.
---@field dropped integer Records lost to drop-oldest since the previous drain.

--- Read-only runtime inspection and bounded event tracing.
---@class BittyDebugNamespace
local BittyDebugNamespace = {}

--- Inspects sanitized runtime state.
--- Capabilities: debug.inspect.
--- Errors: E_CAPABILITY_DENIED, E_DEF_INVALID, E_NOT_IMPLEMENTED (panels).
---@param target BittyDebugInspectTarget
---@return BittyDebugInspectResult
function BittyDebugNamespace.inspect(target) end

--- Opens (returns a fresh positive handle) or closes (returns the closed
--- handle) an event trace. A trace records only event kinds the plugin
--- declares in its manifest `[lazy] events`, only while the plugin is Active;
--- at most 4 traces are open per plugin.
--- Capabilities: debug.trace.
--- Errors: E_CAPABILITY_DENIED, E_DEF_INVALID, E_DEF_LIMIT.
---@param opts? BittyDebugTraceOpts
---@return integer
function BittyDebugNamespace.trace(opts) end

--- Drains buffered records; returns nil for an unknown or foreign handle.
--- Capabilities: debug.trace.
--- Errors: E_CAPABILITY_DENIED, E_DEF_INVALID.
---@param handle integer
---@return BittyDebugTraceResult|nil
function BittyDebugNamespace.trace_get(handle) end

---@class bitty
---@field debug BittyDebugNamespace
