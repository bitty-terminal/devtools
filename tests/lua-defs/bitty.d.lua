--- Bitty Plugin API v1 LuaLS definitions.
--- GENERATED FILE - DO NOT EDIT.
--- Source: surface/bitty-plugin-api-v1.json
--- Contract: bitty-docs:docs/decisions/adrs/ADR-0009-plugin-api-v1-lua-surface.md + bitty-docs:docs/specifications/plugin-api-v1-lua-surface-rfc.md
--- Regenerate: bun scripts/generate-lua-defs.ts --write
--- Verify: just lua-defs-check
---@meta bitty

--- Opaque generation-owned handle returned by bitty.commands.register.
---@alias BittyCommandHandle integer

--- Opaque generation-owned handle returned by bitty.events.subscribe.
---@alias BittySubscriptionHandle integer

--- Opaque generation-owned handle returned by bitty.keymaps.suggest.
---@alias BittyKeymapHandle integer

--- Opaque generation-owned handle returned by bitty.services.provide.
---@alias BittyServiceHandle integer

--- Opaque generation-owned block_id returned by bitty.ui.mount and accepted by bitty.ui.update.
---@alias BittyBlockHandle integer

--- Opaque generation-owned task handle returned by bitty.tasks.spawn; invalid after generation
--- disposal.
---@alias BittyTaskHandle integer

--- Opaque generation-owned timer handle returned by bitty.timers.create; invalid after generation
--- disposal.
---@alias BittyTimerHandle integer

--- Bounded JSON Schema fragment as accepted by the CLI Contract RFC and ADR 0009: depth at most 16,
--- bounded string fields, explicit additionalProperties flag, at most CMD_SCHEMA_MAX_BYTES (16 KiB)
--- per schema, no remote $ref, and no unbounded patterns.
---@alias BittyJsonSchema table

--- Command registration definition for bitty.commands.register; valid only during init.lua
--- activation.
---@class BittyCommandDef
---@field id string Plugin-local command segment matching ^[a-z][a-z0-9-]{0,63}$; the host qualifies it to <plugin-id>:<id>.
---@field title string Bounded display text; host-rendered, never markup.
---@field description? string Bounded display text.
---@field args_schema? BittyJsonSchema Argument schema validated by the host before dispatch.
---@field result_schema? BittyJsonSchema Result schema validated by the host before the result is returned.
---@field run fun(args: table): any Command body; args is a plain table already validated against args_schema.

--- Command registration surface (L1). Registration is valid only while init.lua executes.
---@class BittyCommandsNamespace
local BittyCommandsNamespace = {}

--- Registers a plugin command; valid only during init.lua activation. The qualified name must
--- already be reserved in the manifest [lazy].commands, duplicate qualified names are rejected at
--- graph construction, and a later registration attempt is a registration error.
---@param def BittyCommandDef
---@return BittyCommandHandle
function BittyCommandsNamespace.register(def) end

--- Closed v1 event-name set; subscribing to an undeclared or unknown name is a registration error.
---@alias BittyEventName "plugin.activated"|"plugin.suspended"|"plugin.disposed"|"handler.violation"|"terminal.opened"|"terminal.closed"|"terminal.title-changed"|"terminal.cwd-changed"|"terminal.bell"|"focus.changed"|"selection.changed"|"process.exited"|"config.reloaded"|"intercept.command-dispatch"|"intercept.terminal-spawn"|"intercept.paste"|"intercept.open-url"

--- Event payload with no fields for lifecycle, signal, and coalescable observation events.
---@class BittyEmptyPayload

--- terminal.opened payload delivering the accepted identity tuple.
---@class BittyTerminalOpenedPayload
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.
---@field generation integer Registry generation that allocated the terminal; lets consumers detect stale identities.

--- terminal.closed payload; emitted once per terminal as a cold-path event.
---@class BittyTerminalClosedPayload
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.
---@field reason string Bounded closed reason derived from the accepted TerminalClosed shape.

--- terminal.title-changed payload with attribution.
---@class BittyTerminalTitleChangedPayload
---@field title string Bounded title text (EVENT_MAX_BYTES).
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.

--- terminal.cwd-changed payload with attribution; treat cwd as sensitive-capable display data.
---@class BittyTerminalCwdChangedPayload
---@field cwd string Bounded current working directory.
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.

--- focus.changed payload; coalescable.
---@class BittyFocusChangedPayload
---@field view_id integer Focused view identity.
---@field terminal_id? integer Attached terminal identity when the focused view has one.

--- selection.changed payload; coalescable and carries no selection text in v1.
---@class BittySelectionChangedPayload
---@field view_id integer View identity.
---@field terminal_id? integer Attached terminal identity when the view has one.

--- process.exited payload carrying the accepted exit-status field.
---@class BittyProcessExitedPayload
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.
---@field exit_code integer Process exit status.

--- Interception payload with bounded sanitized metadata; rewriting content is not expressible.
---@class BittyInterceptPayload
---@field action string Bounded action label.
---@field origin string Bounded origin label.
---@field preview string Bounded sanitized preview; intercept.paste never carries paste text without clipboard.read.

--- Union of the closed v1 event payload shapes.
---@alias BittyEventPayload BittyEmptyPayload|BittyTerminalOpenedPayload|BittyTerminalClosedPayload|BittyTerminalTitleChangedPayload|BittyTerminalCwdChangedPayload|BittyFocusChangedPayload|BittySelectionChangedPayload|BittyProcessExitedPayload|BittyInterceptPayload

--- Immutable bounded event envelope delivered to subscribed handlers.
---@class BittyEvent
---@field kind BittyEventName Event name from the closed v1 set.
---@field sequence integer Monotonic delivery sequence.
---@field payload BittyEventPayload Immutable payload copy, never a live core object.

--- Observation and lifecycle return values are ignored; interception handlers return false to veto
--- and anything else to approve.
---@alias BittyEventHandler fun(event: BittyEvent): boolean|nil

--- Event subscription surface (L1). Subscriptions must match manifest-declared event types.
---@class BittyEventsNamespace
local BittyEventsNamespace = {}

--- Subscribes to one closed v1 event name; the type must be declared for the plugin. Observation
--- and lifecycle handler results are ignored; interception handlers return false to veto, anything
--- else to approve.
---@param name BittyEventName
---@param handler BittyEventHandler
---@return BittySubscriptionHandle
function BittyEventsNamespace.subscribe(name, handler) end

--- Key-binding suggestion for bitty.keymaps.suggest; suggestions never override user or workspace
--- mappings.
---@class BittyKeymapSuggestion
---@field chord string Chord in the shipped configuration grammar: trimmed, case-insensitive modifiers joined with + (ctrl, alt, shift, super); single-character keys require a modifier.
---@field command string Qualified name of a command registered by the same generation.
---@field when? "global" v1 context; must be absent or "global", any other value is a registration error.

--- Key-binding suggestion surface (L1); suggestions are declarations with no forced mutation.
---@class BittyKeymapsNamespace
local BittyKeymapsNamespace = {}

--- Suggests a key binding for a command registered by the same generation; the accepted precedence
--- user > workspace > first-party/default > plugin always applies and conflicts produce diagnostics
--- for user resolution.
---@param def BittyKeymapSuggestion
---@return BittyKeymapHandle
function BittyKeymapsNamespace.suggest(def) end

--- Plugin settings value; typed schema, merge, and reload semantics are owned by the accepted
--- Configuration Model RFC.
---@alias BittySettingsValue boolean|number|string|table

--- Plugin settings surface (L1); keys are dot paths relative to plugins.<owner>.<name> only.
---@class BittySettingsNamespace
local BittySettingsNamespace = {}

--- Reads a key relative to plugins.<owner>.<name>; plugins cannot read outside their own namespace.
---@param key string
---@return BittySettingsValue
function BittySettingsNamespace.get(key) end

--- Writes a key relative to plugins.<owner>.<name>; plugins cannot write outside their own
--- namespace.
---@param key string
---@param value BittySettingsValue
---@return boolean
function BittySettingsNamespace.set(key, value) end

--- JSON-compatible plain data: depth at most 8, at most 1024 nodes, at most 8 KiB serialized
--- (STORE_MAX_VALUE_BYTES); functions, metatables, cycles, and non-finite numbers are rejected.
---@alias BittyStoreValue boolean|number|string|table

--- Quota-bounded persistent key-value area scoped to the plugin id and persisted across
--- generations; STORE_QUOTA_BYTES default 256 KiB.
---@class BittyStoreNamespace
local BittyStoreNamespace = {}

--- Reads a persisted value by key; keys match ^[a-z0-9][a-z0-9._-]{0,127}$ and the store survives
--- suspension, reload, and generation disposal.
---@param key string
---@return BittyStoreValue|nil
function BittyStoreNamespace.get(key) end

--- Writes or, with nil, deletes a persisted value; writes are synchronous and fail closed on value
--- invalidity or quota overflow without partial writes.
--- Errors: E_STORE_VALUE_INVALID, E_STORE_QUOTA.
---@param key string
---@param value BittyStoreValue|nil
---@return boolean
function BittyStoreNamespace.set(key, value) end

--- Notification payload gated by platform.notify and subject to host rate policy.
---@class BittyNotifyPayload
---@field title string Bounded title text.
---@field body? string Bounded body text.
---@field urgency? "low"|"normal"|"critical" Urgency level.

--- Notification surface (L1) gated by platform.notify.
---@class BittyNotifyNamespace
local BittyNotifyNamespace = {}

--- Shows a host-rendered notification via the platform.notify capability, subject to host rate
--- policy.
--- Capabilities: platform.notify.
--- Errors: E_CAPABILITY_DENIED.
---@param payload BittyNotifyPayload
---@return boolean
function BittyNotifyNamespace.show(payload) end

--- Environment read surface (L1) accepted by ADR 0006. This sub-table is absent unless the manifest
--- declares an env:<KEY> capability; when declared but not granted its functions fail closed with
--- E_CAPABILITY_DENIED and never enumerate keys.
---@class BittyEnvNamespace
local BittyEnvNamespace = {}

--- Reads a desensitized environment value for a bounded ASCII key matching ^[A-Z_][A-Z0-9_]*$
--- (1..64); keys outside the allowlist return nil, indistinguishable from an unset variable.
--- Available only when the namespace is declared.
--- Capabilities: env:<KEY>.
--- Host status: deferred - always fails with E_NOT_IMPLEMENTED (runtime) until the host backend lands.
--- Errors: E_NOT_IMPLEMENTED.
---@param name string
---@return string|nil
function BittyEnvNamespace.get(name) end

--- Reports presence without exposing the value beyond the trace surface. Available only when the
--- namespace is declared.
--- Capabilities: env:<KEY>.
--- Host status: deferred - always fails with E_NOT_IMPLEMENTED (runtime) until the host backend lands.
--- Errors: E_NOT_IMPLEMENTED.
---@param name string
---@return boolean
function BittyEnvNamespace.has(name) end

--- Consumer-side service resolution options for bitty.services.get.
---@class BittyServiceGetOpts
---@field version string Version requirement in the accepted grammar, for example ">=2.0". Required: the accepted RFC defines no default requirement.
---@field optional? boolean When true, a missing provider returns nil instead of failing with E_SERVICE_RESOLUTION.

--- Plain service table whose members are functions; calls are schema-validated by the host and
--- return plain values, never cross-VM handles.
---@alias BittyService table<string, fun(...): any>

--- Service consumer and provider surface (L1); provider declarations live in the manifest
--- [services.provided] table form.
---@class BittyServicesNamespace
local BittyServicesNamespace = {}

--- Resolves a provider before activation; a missing provider fails closed with E_SERVICE_RESOLUTION
--- unless opts.optional is true, and provider disappearance makes in-flight calls fail closed with
--- E_SERVICE_GONE.
--- Errors: E_DEF_INVALID, E_SERVICE_VERSION_INVALID, E_SERVICE_RESOLUTION.
---@param iface string
---@param opts BittyServiceGetOpts
---@return BittyService|nil
function BittyServicesNamespace.get(iface, opts) end

--- Provides an interface implementation during activation; the interface, version, and bounded
--- schemas must already be declared in the manifest [services.provided] table form, and arguments
--- and results are schema-validated by the host.
--- Errors: E_DEF_INVALID, E_SERVICE_UNDECLARED.
---@param iface string
---@param impl BittyService
---@return BittyServiceHandle
function BittyServicesNamespace.provide(iface, impl) end

--- Accepted closed slot set. tabline is an exclusive claim; status components compose; overlay is
--- non-focusable presentation content.
---@alias BittyUiSlot "terminal"|"top"|"bottom"|"left"|"right"|"tabline"|"statusline"|"overlay"

--- Bounded declarative component table shaped by the accepted SceneNode contract; v1 accepts Text,
--- Row, Column, and List subtrees only. Exact table encoding is owned by the accepted Rich
--- Presentation RFC.
---@alias BittySceneNode table

--- Declarative UI contribution surface (L2); rich content requires ui.rich and the overlay slot
--- requires ui.overlay.
---@class BittyUiNamespace
local BittyUiNamespace = {}

--- Mounts declarative component content into an accepted semantic slot; rich content requires
--- ui.rich and the overlay slot additionally requires ui.overlay. Host layout owns placement and
--- decoration, and there are no global coordinates, shaders, pipelines, glyph injection, native
--- windows, or renderer handles.
--- Capabilities: ui.rich.
--- Conditional capabilities: ui.overlay (when slot == "overlay").
--- Errors: E_CAPABILITY_DENIED, E_UI_COMPONENT_INVALID.
---@param slot BittyUiSlot
---@param component BittySceneNode
---@return BittyBlockHandle
function BittyUiNamespace.mount(slot, component) end

--- Replaces a block's scene subtree under the same block_id with an incremented version; returns
--- false for a stale or foreign handle and raises E_UI_COMPONENT_INVALID for a component that
--- violates the scene contract.
--- Capabilities: ui.rich.
--- Errors: E_CAPABILITY_DENIED, E_UI_COMPONENT_INVALID.
---@param handle BittyBlockHandle
---@param component BittySceneNode
---@return boolean
function BittyUiNamespace.update(handle, component) end

--- Terminal snapshot options; only the semantic scope is accepted in v1.
---@class BittySnapshotOpts
---@field scope? "semantic" The only accepted v1 scope.
---@field terminal_id? integer Target terminal; defaults to the focused view's attached terminal and requires terminal.semantic-read.

--- Color value: "default", a palette index 0..255, or an "#RRGGBB" string.
---@alias BittyCellColor "default"|integer|string

--- Non-default cell attributes carried by a snapshot span; false boolean flags are omitted.
---@class BittyCellAttrs
---@field bold? boolean Bold attribute.
---@field faint? boolean Faint attribute.
---@field italic? boolean Italic attribute.
---@field blink? boolean Blink attribute.
---@field inverse? boolean Inverse attribute.
---@field invisible? boolean Invisible attribute.
---@field strikethrough? boolean Strikethrough attribute.
---@field underline? "none"|"single"|"double"|"curly"|"dotted"|"dashed" Underline style.
---@field fg? BittyCellColor Foreground color.
---@field bg? BittyCellColor Background color.
---@field underline_color? BittyCellColor Underline color.

--- Half-open column range [start, end) carrying only non-default attributes.
---@class BittyCellSpan
---@field start integer Inclusive start column.
---@field end integer Exclusive end column.
---@field attrs BittyCellAttrs Non-default attributes for the range.

--- One visible snapshot row with its semantic spans.
---@class BittySnapshotRow
---@field text string Visible row text as UTF-8.
---@field spans BittyCellSpan[] Attribute spans over the row.

--- Cursor position within the snapshot region.
---@class BittySnapshotCursor
---@field row integer Cursor row.
---@field col integer Cursor column.
---@field visible boolean Whether the cursor is visible.

--- Bounded mode flags reflected by the snapshot.
---@class BittySnapshotModes
---@field alternate_screen boolean Whether the alternate screen is active; zones may be absent while true.

--- Semantic zone kinds derived from committed terminal state (OSC 7/133); unknown covers terminals
--- without shell integration.
---@alias BittyZoneKind "prompt"|"input"|"command"|"output"|"unknown"

--- Line range of a semantic zone.
---@class BittyZoneRange
---@field start_line integer First line of the zone.
---@field end_line integer Last line of the zone.

--- Bounded untrusted zone metadata; values are never expanded or executed.
---@class BittyZoneMetadata
---@field cwd? string Zone working directory.
---@field host? string Zone host name.
---@field command? string Command text.
---@field exit_code? integer Command exit status.

--- Semantic zone in a terminal snapshot.
---@class BittySemanticZone
---@field kind BittyZoneKind Zone kind.
---@field range BittyZoneRange Zone line range.
---@field metadata? BittyZoneMetadata Bounded zone metadata.

--- Read-only semantic snapshot of the visible viewport; a serialized snapshot over
--- SNAPSHOT_MAX_BYTES (256 KiB) is rejected with E_SNAPSHOT_TOO_LARGE rather than truncated.
---@class BittyTerminalSnapshot
---@field version integer Snapshot contract version (1).
---@field terminal_id integer Terminal identity.
---@field runtime_id integer Live PTY incarnation identity.
---@field generation integer Registry generation.
---@field snapshot_generation integer Terminal damage generation reflected by the snapshot.
---@field width integer Grid columns in the snapshot region.
---@field height integer Grid rows in the snapshot region.
---@field rows BittySnapshotRow[] Visible rows, top-down.
---@field cursor BittySnapshotCursor Cursor state.
---@field modes BittySnapshotModes Mode flags.
---@field title string Bounded title text.
---@field zones? BittySemanticZone[] Semantic zones; may be absent.

--- Read-only terminal observation surface (L2) gated by terminal.semantic-read; there is no write
--- path to grid, cursor, modes, or scrollback in v1.
---@class BittyTerminalNamespace
local BittyTerminalNamespace = {}

--- Returns a read-only semantic snapshot of the visible viewport; only the semantic scope is
--- accepted in v1 and there is no raw scope, scrollback, or full-grid selection.
--- Capabilities: terminal.semantic-read.
--- Errors: E_CAPABILITY_DENIED, E_SNAPSHOT_TOO_LARGE.
---@param opts BittySnapshotOpts
---@return BittyTerminalSnapshot
function BittyTerminalNamespace.snapshot(opts) end

--- Host-owned task surface (L1) capped at 64 live tasks per plugin; exceeding the cap fails with
--- E_BUDGET_TASK and never queues silently.
---@class BittyTasksNamespace
local BittyTasksNamespace = {}

--- Spawns a host-owned task wrapping a Lua continuation; handles are generation-owned and all
--- generation N handles fail closed after disposal.
--- Errors: E_BUDGET_TASK.
---@param fn fun(): any
---@return BittyTaskHandle
function BittyTasksNamespace.spawn(fn) end

--- Cancels a task cooperatively at the next host slice; cancellation releases the cap slot and
--- there is no Lua-visible abort hook in v1.
---@param task_id BittyTaskHandle
---@return boolean
function BittyTasksNamespace.cancel(task_id) end

--- Host-owned one-shot timer surface (L1) capped at 32 live timers per plugin; exceeding the cap
--- fails with E_BUDGET_TIMER.
---@class BittyTimersNamespace
local BittyTimersNamespace = {}

--- Creates a generation-owned one-shot timer; repeating timers are a 1.x minor addition.
--- Errors: E_BUDGET_TIMER.
---@param delay_ms integer
---@param callback fun(): any
---@return BittyTimerHandle
function BittyTimersNamespace.create(delay_ms, callback) end

--- Cancels a timer and releases the cap slot; handles from a disposed generation fail closed.
---@param timer_id BittyTimerHandle
---@return boolean
function BittyTimersNamespace.cancel(timer_id) end

--- Host-injected read-only module table; it is not loaded through require.
---@class bitty
---@field api_version string Host bridge API version (1.0.0); minor versions are additive only.
---@field commands BittyCommandsNamespace
---@field events BittyEventsNamespace
---@field keymaps BittyKeymapsNamespace
---@field settings BittySettingsNamespace
---@field store BittyStoreNamespace
---@field notify BittyNotifyNamespace
---@field env? BittyEnvNamespace
---@field services BittyServicesNamespace
---@field ui BittyUiNamespace
---@field terminal BittyTerminalNamespace
---@field tasks BittyTasksNamespace
---@field timers BittyTimersNamespace
bitty = {}
