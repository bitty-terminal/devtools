# DevTools live view: design record

Status: implemented in `0.2.0` (tracking issue:
[bitty-plugins#85](https://github.com/bitty-terminal/bitty-plugins/issues/85)).

This record decides the three design wrinkles named by the issue **before**
the code, records the host evidence each decision rests on, and lists the two
Plugin API v1 gaps the work exposed. It is scoped to
`bitty-featured.devtools`; it invents no Core semantics.

## Scope

In scope:

- one optional, docked, timer-refreshed view: a status line, an inspect
  table, and a rolling trace stream;
- pause/resume, and a visible dropped-record counter;
- reuse of the existing filter validation and the existing bounded text
  renderers;
- fail-closed degradation to today's notification path.

Out of scope (unchanged by this record):

- write capability: `bitty.debug.control` is never called;
- raw PTY bytes and cell-level inspection: the redaction rule is not
  relaxed by adding a GUI;
- any new Core API, capability vocabulary, or manifest field.

## Host facts the design rests on

Every claim below is a property of the shipped host, cited so a reviewer can
check it instead of trusting this document.

| Fact                                                                                                                                        | Evidence                                                                           |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `ui.mount` requires `ui.rich`; only `overlay` additionally needs `ui.overlay`                                                               | `bitty/crates/bitty-runtime/src/plugin_runtime/services.rs:5682-5728`              |
| `bottom` is a hosted horizontal band; `left`/`right`/`tabline`/`terminal` fail closed at mount                                              | `bitty/crates/bitty-runtime/src/runtime/band_slots.rs:93-116`                      |
| A band paints **one row per mounted block**; index 0 is the window edge                                                                     | `bitty/crates/bitty-runtime/src/runtime/band_slots.rs:194-200`                     |
| Several mounts from one plugin on one edge are kept and stack in mount order (stable plugin-id sort)                                        | `bitty/crates/bitty-runtime/src/runtime/band_slots.rs:46-52,156-187`               |
| An empty-text band root is **hidden**: no row, no paint, no click routing                                                                   | `bitty/crates/bitty-runtime/src/runtime/band_host.rs:588-597`                      |
| `ui.update` has no per-second rate window; only the 64-block and 2 MiB retained-string budgets                                              | `bitty/crates/bitty-runtime/src/plugin_runtime/services.rs:1186-1247`              |
| The bridge exposes `ui.mount` / `ui.update` / `ui.overlay.*` / `ui.present` / `ui.targets` / `ui.labels` — and **no** `ui.unmount`          | `bitty/crates/bitty-lua/src/host.rs:6275,6336,6620,6685,6933,7006`                 |
| A plugin may hold at most 4 open traces                                                                                                     | `bitty/crates/bitty-runtime/src/plugin_runtime/debug.rs:53`                        |
| Timers are one-shot; a callback may create the next one, and the runtime re-syncs capture after each fire ("at most one optimistic re-arm") | `bitty/crates/bitty-runtime/src/plugin_runtime/mod.rs:976-987,2261-2263,2491-2500` |
| The live-timer cap counts unfired timers only (`consume_timer` frees the slot)                                                              | `bitty/crates/bitty-lua/src/host.rs:3503-3516`                                     |
| `platform.notify` is rate-governed by the RC-8 one-second window (10 events)                                                                | `bitty/crates/bitty-runtime/src/runtime/bell.rs:32-35`                             |

Two divergences noticed while collecting the evidence, reported rather than
fixed here (neither changes this design):

- The SDK definitions document `E_BUDGET_TIMER` for the timer cap and 32
  live timers; the bridge raises `E_DEF_LIMIT` and uses
  `REGISTRATION_MAX_TIMERS = 64` (`bitty-lua/src/host.rs:409,4885-4900`).
  The view holds exactly one timer, so neither value is reachable from it.
- `bitty.ui.targets` and `bitty.ui.overlay` are wired in the host but absent
  from the vendored SDK definitions, so the plugin does not use them.

## Decision 1: single-handle contention — a second handle, not a shared one

**Decision.** The live view owns its **own** `bitty.debug.trace` handle
(`devtools.view`), separate from the command handle (`devtools.trace`). The
plugin therefore holds at most two of the host's four traces.

Sharing rules:

1. `trace-start` / `trace-dump` / `trace-stop` only ever touch the command
   handle. A view being open never makes `trace-start` report
   `E_TRACE_ACTIVE`.
2. `view-open` / `view-close` only ever touch the view handle. `view-close`
   never closes the command trace, and `trace-stop` never closes the view.
3. Draining is per handle. The view drains its own buffer once per tick; the
   command dump drains the command buffer. Neither consumes the other's
   records.
4. `E_DEF_LIMIT` from the host is surfaced unchanged and fails the open
   closed (rows hidden, no timer, no handle kept). This plugin cannot reach
   it by itself: it holds two handles, and the only external holders would be
   a future feature of the same plugin.

**Why not "the view owns the handle while open".** That option makes
`trace-dump` / `trace-stop` behaviour depend on whether a view is open, which
contradicts the acceptance criterion "old 7 commands behave identically with
the view open or closed" and turns a read-only command into a mode-dependent
one. A typed `E_TRACE_ACTIVE`-adjacent refusal would still change the command
contract for the duration of a view. The second handle costs one of four
host slots, keeps every command byte-identical, and gives the view an
independent loss counter — which is exactly the accounting the trace backend
exists to expose.

**Evidence.** `tests/spec/view_spec.lua`: "command result is identical with
the view open: dump", "…: stop", "commands and view each own one trace (2 of
the host cap of 4)", "the view drain does not consume the command buffer",
"the command dump does not consume the view buffer", "view-close leaves the
command trace open", "trace-stop closes only the command handle", "the host
trace cap is surfaced".

## Decision 2: refresh budget — 1 s default, 500 ms floor, changed rows only

**Decision.**

| Parameter           | Value                                                  |
| ------------------- | ------------------------------------------------------ |
| Default cadence     | 1000 ms                                                |
| Configurable range  | clamped to `[500, 10000]` ms (`view-open interval_ms`) |
| Documented floor    | 500 ms                                                 |
| Timers held         | exactly one (one-shot chain re-armed by each tick)     |
| Host calls per tick | 1 `debug.inspect` + 1 `debug.trace_get` + changed rows |
| Notifications/tick  | 0                                                      |

Details:

1. **One-shot chain.** v1 timers are one-shot, so the cadence is
   `tick -> render -> timers.create(next)`. The runtime re-syncs the capture
   after a callback fires, which is the shipped path for "timers created
   inside a timer callback" (evidence row above). Exactly one timer is live,
   and the cap counts unfired timers only.
2. **Changed rows only.** A row is pushed through `ui.update` only when its
   text differs from the last frame. An idle tick therefore issues **zero**
   updates; a tick with one new record issues two (status line + one trace
   row). Worst case is `ROW_COUNT = 8` updates per tick, i.e. 8/s at the
   default cadence and 16/s at the floor.
3. **No notification on the tick path.** The view never notifies per tick:
   errors are counted in the status line (`err N`) instead. Notifications
   happen only on open/close/pause/resume (command path) and once on a loss.
   The RC-8 notify window (10 events/s) is therefore never in play, and
   `ui.update` has no rate window at all (evidence row above) — only the
   retained-string and block budgets, which eight one-line `Text` rows are
   orders of magnitude below.
4. **Pause on a hidden view.** Pause cancels the timer and stops draining,
   but keeps the trace handle: the host buffer keeps recording
   (drop-oldest, `dropped` counter) and `view-resume` drains the backlog in
   one tick, so loss stays visible instead of disappearing. A hidden band
   already costs no paint (`band_is_visible`), so a paused view is also
   invisible to the renderer.

**Open sub-decision: "pause on hidden/unfocused".** Plugin API v1 has no
signal for the visibility or focus of a _mounted block_: `focus.changed`
carries a view/terminal identity, not a block's presentation state, and a
`bottom` band is window chrome that stays visible while it has text. The
plugin therefore cannot implement automatic pause-on-hidden from v1
spellings; it exposes explicit `view-pause` / `view-resume` instead, and the
cost while the window is unfocused is bounded by the table above (two reads
and at most two updates per second). Filed as a Core gap (below) rather than
worked around with a heuristic on `focus.changed`.

**Evidence.** `tests/spec/view_spec.lua`: "no tick before the default
cadence", "the default cadence is 1 s", "the floor clamps a fast interval",
"no tick below the floor", "the ceiling clamps a slow interval", "an idle
tick repaints nothing", "a tick with one record updates the status line and
one trace row", "ten ticks emit no notification", "pause cancels the timer",
"a paused view does not repaint", "resume drains the backlog", "one timer
after repeated pause/resume", "one trace after repeated pause/resume".

## Decision 3: grants — `ui.rich` only, and the seven commands stay grant-less

**Decision.** The manifest requests exactly one additional capability,
`ui.rich`. `ui.overlay`, `ui.overlay.focus`, and every input-capture spelling
stay absent: the view is a non-focusable band and never captures input, so
`bitty.ui.overlay.*` is not used.

Consequences, stated for reviewers and users:

1. Adding `ui.rich` is a **re-consent event**: an existing install must
   approve the new grant set on upgrade. This is recorded in
   `CHANGELOG.md` and `README.md` as a permission change, not a silent
   widening.
2. The seven read-only commands never touch `bitty.ui` or `bitty.timers`.
   Their code paths are unchanged, so they keep working when the grant is
   declined, revoked, or the host predates the bridge.
3. The four `view-*` commands degrade to today's notification path with a
   typed result (`E_CAPABILITY_DENIED`, `E_BRIDGE_ABSENT`,
   `E_UI_UNAVAILABLE`), never a raise and never a silent no-op.
4. No capability is inferred, no wildcard is requested, and the plugin still
   never calls `debug.control`.

**Evidence.** `tests/spec/view_spec.lua`: "a declined ui.rich is a typed
error", "a declined grant mounts nothing", "read-only command works
grant-less: plugins/commands/events/grants", "trace-start works grant-less",
"absent ui bridge degrades", "absent timer bridge degrades", "absent debug
bridge degrades". `tests/spec/init_spec.lua` runs the whole command surface
with the three original grants only.

## Presentation shape (implementation decision)

A band row is one line, so the view is **eight one-row blocks** mounted into
`bottom` in visual reverse order (mount order is bottom-up):

| Mount index | Row (visual)                    |
| ----------- | ------------------------------- |
| 1           | status line (bottom-most)       |
| 2-4         | inspect table (header + 2 rows) |
| 5-8         | trace stream, newest on top     |

Close hides every row (empty `Text`, which reserves no row) and keeps the
block handles for the generation; reopen reuses them. This matters because
v1 has no `ui.unmount`: remounting on every open would consume the 64-block
generation budget after eight open/close cycles. Reuse keeps the plugin at
eight blocks for its whole generation.

Two host behaviors make this shape work from a command handler:

- `ui.mount` / `ui.update` are direct host calls, not registration-capture
  entries, so they are valid outside `init.lua`
  (`services.rs:5682-5728`, `5814-5823`).
- A timer created by a command is captured and picked up by
  `sync_new_timers` at the next pump (`mod.rs:2283-2285,2491-2520`), and a
  timer created by a timer callback is re-synced after the fire
  (`mod.rs:2340,2386`).

Band budget: eight rows plus the chrome content floor must fit the window
(`band_host.rs:1692-1716`), otherwise the host degrades **every** band to
zero rows rather than painting a clipped one. On a normal window the floor is
one content row plus the gaps and decoration ring, so eight rows fit; a
deliberately tiny window degrades the view away instead of squeezing the
terminal.

## Core gaps found (filed, not worked around)

1. **No `bitty.ui.unmount`.** A mounted block lives until the generation is
   torn down (suspend/reload/dispose). Hiding it (empty text) is the only
   plugin-side release; the block, its handle, and its retained-string budget
   stay allocated. Filed with evidence:
   [bitty#3106](https://github.com/bitty-terminal/bitty/issues/3106).
2. **No mounted-block visibility/focus signal.** A plugin cannot learn that
   its band was hidden or that the window lost focus, so "pause while
   hidden" is not expressible in v1. Filed with evidence:
   [bitty#3107](https://github.com/bitty-terminal/bitty/issues/3107).

Neither gap blocks the feature: the view is bounded at eight blocks per
generation and its refresh cost is independent of focus.

## Acceptance mapping

| Acceptance criterion                                           | Evidence                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| View mounts/updates/destroys cleanly                           | `view_spec`: mount/update/close block; close hides every row and releases the trace; open/close cycles never mount extra blocks                                                                                                                                                                           |
| Pause freezes without leaking the handle; resume continues     | `view_spec`: pause/resume block (timer 0 while paused, one trace kept, backlog drained on resume, no churn leak)                                                                                                                                                                                          |
| Dropped records are visible                                    | `view_spec`: "the dropped count is visible in the view" (`drop 5`), "resume reports the dropped count"                                                                                                                                                                                                    |
| Old 7 commands behave identically with the view open or closed | `view_spec`: parity block comparing every result string, plus per-handle drain/isolation assertions                                                                                                                                                                                                       |
| No new Core API used                                           | `view_spec`: every host call is asserted against the declared bridge surface (`ui.mount`, `ui.update`, `timers.create`, `timers.cancel`, `debug.inspect`, `debug.trace`, `debug.trace_get`, `notify.show`); `tests/check-luals.sh` type-checks the sources against the vendored Plugin API v1 definitions |
| `just check` green                                             | plugin repo gates (Markdown, Prettier, manifest linter, Lua syntax + control, behavior suite, LuaLS)                                                                                                                                                                                                      |
