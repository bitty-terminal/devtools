# Bitty DevTools

## Overview

Read-only inspection and event tracing of the Bitty plugin runtime
(`bitty-featured.devtools`). It summarizes what the plugin host knows
(plugins, commands, event subscriptions, its own grants) and records bounded
event traces, and shows the results as host-rendered text notifications —
optionally in a docked live view refreshed on a timer.

> Status: pre-release, verified on bitty `main` `811ba94c`. The read-only
> `bitty.debug` backend (bitty#1573, `c4af172b`) and the app-loop wiring
> (bitty#1564, `CTX-0892`) are both merged. `dispatch_command` and
> `deliver_event` have production callers (`terminal_app.rs`: dispatch on
> composer verbs and band clicks; deliver per-tick runtime events plus
> `overlay.released`); `drain_notifications` still has no production caller,
> so command results return through dispatch while notification bodies queue
> unseen. Of the nine declared trace kinds, the live loop emits only
> `terminal.title-changed` and `focus.changed` (plus `workspace.*` and
> `overlay.released`, which this plugin does not declare); the other seven
> record only when delivered through test seams. Live-host evidence
> (CTX-0005): all seven read-only commands dispatch and return bounded text
> (`plugins` 54 bytes / 1 row, `commands` 447 bytes / 7 rows, `events` 15
> bytes / 0 rows, `grants` 50 bytes / 3 grants, `trace-start` / `trace-dump`
> 9 records / `trace-stop` close cleanly, `terminal.*` filter keeps
> `terminal.bell` and drops `focus.changed`, 12 notifications queued). The
> plugin is also verified against the local mock host (1132 assertions,
> including the live view) and LuaLS definitions. Since `0.2.0` the plugin
> also ships an optional docked live view built from `bitty.ui.mount` /
> `update` and `bitty.timers`; it is non-focusable, never captures input, and
> needs the `ui.rich` grant. The design and its host evidence are in
> [docs/design/live-view.md](docs/design/live-view.md).

Run any command as `bitty-featured.devtools:<name>` from the command palette or
a user keymap; the plugin installs no default chord. For example, run
`bitty-featured.devtools:plugins` and the command result summarizes every
plugin id, version, lifecycle state, and generation the host reports; a
one-line notice is also queued as a notification when the host drains them.
The plugin has no panel or overlay surface: results are bounded text
notifications and command results.

## Install

Prerequisites:

- Bitty `>=0.0.21` with Plugin API `^1.0` (the manifest `[compat]` range).
- Consent to `debug.inspect`, `debug.trace`, `platform.notify`, and
  `ui.rich` (the live view only); the plugin requests no filesystem, process,
  network, or clipboard authority, and no input-capture surface.
- `just`, `bun`, `lua5.4`, and `luac5.4` only when you build or test from a
  checkout.

Install from a local checkout:

```sh
git clone https://github.com/bitty-terminal/devtools.git
cd devtools
bitty plugin install "$PWD"
bitty plugin enable bitty-featured.devtools
bitty plugin list
```

`bitty plugin install <path>` stages the package under the XDG data store and
records the capabilities you consent to; it executes no plugin code (`--yes`
approves non-interactively). Verify activation with `bitty plugin list`: the
entry must show `bitty-featured.devtools`, version `0.2.0`, source
`local-path`, enabled, and the four grants. `bitty plugin info
bitty-featured.devtools` prints the recorded grant set.

## Commands

All commands are plugin-qualified as `bitty-featured.devtools:<name>`. Every
command returns its full rendered text as the command result and shows a
one-line notice of it, at most 256 characters, as a notification.

| Command                               | Behavior                                                                                                                                                                                    |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bitty-featured.devtools:plugins`     | Summarize `bitty.debug.inspect("plugins")`: id, version, lifecycle state, generation.                                                                                                       |
| `bitty-featured.devtools:commands`    | Summarize registered commands (`plugin:id - title`).                                                                                                                                        |
| `bitty-featured.devtools:events`      | Summarize event subscriptions (`plugin <- kind`).                                                                                                                                           |
| `bitty-featured.devtools:grants`      | List the capabilities granted to this plugin (the host never exposes other plugins' grants).                                                                                                |
| `bitty-featured.devtools:trace-start` | Open one trace over the declared event kinds. Optional argument `filter` (exact kind, or a prefix ending in `*`, such as `terminal.*`; at most 128 bytes).                                  |
| `bitty-featured.devtools:trace-dump`  | Drain the buffered records and summarize the most recent ones, with the drained and dropped counts.                                                                                         |
| `bitty-featured.devtools:trace-stop`  | Drain the final records and close the trace. If the final drain fails, the trace is still closed and the drain error is reported.                                                           |
| `bitty-featured.devtools:view-open`   | Mount the live view. Optional `target` (`plugins` \| `commands` \| `events` \| `grants`), optional `filter` (same grammar as `trace-start`), optional `interval_ms` (clamped to 500–10000). |
| `bitty-featured.devtools:view-close`  | Hide the live view, cancel its timer, and release its own trace handle. Reports the record, dropped, and error counts.                                                                      |
| `bitty-featured.devtools:view-pause`  | Freeze the live view and cancel its timer. The trace keeps recording in the bounded host buffer until resume.                                                                               |
| `bitty-featured.devtools:view-resume` | Drain the records buffered while paused and restart the refresh timer.                                                                                                                      |

The commands hold at most one trace and the view holds at most one of its
own, so the plugin uses two of the host's four traces per plugin.
`trace-start` while a trace is running reports `E_TRACE_ACTIVE`; a view being
open never causes that. `trace-dump` / `trace-stop` only drain and close the
command trace, and `view-close` only closes the view trace. If the host drops
a trace (reload, failure, or disposal), the next dump reports `E_TRACE_GONE`
and a new trace can be started. The `panels` inspect target is reserved
upstream (`E_NOT_IMPLEMENTED`) and is not exposed.

Output is bounded. The command result holds at most 15 rows, with fields
capped at 64 bytes, lines at 112 bytes, and the whole text at 2048 bytes.
The notification body is a single line of at most 256 characters, because
the host chrome rejects longer bodies (`MAX_NOTIFICATION_TEXT_LEN`) instead
of truncating them. Control bytes in host-supplied strings are replaced with
`?`.

Each command definition carries `args_schema` and `result_schema` as
documentation of the intended contract. The current host bridge keeps only
`id`, `title`, `description`, and `run` and does not enforce them, so the
plugin validates the `filter` argument itself.

## Live view

`view-open` mounts a docked view into the window's `bottom` band. It is
composed of eight one-row blocks, because a band paints exactly one row per
mounted block:

| Row (top to bottom)   | Content                                                      |
| --------------------- | ------------------------------------------------------------ |
| 4 trace rows          | Newest first: `#seq +Nms topic k=v` for the drained records. |
| 3 inspect rows        | The count header plus the first rows of the selected target. |
| 1 status row (bottom) | `DEVTOOLS live <target> <cadence> \| rec N drop N err N`.    |

Behavior:

- **Cadence.** One second by default, `interval_ms` clamps to 500–10000 ms.
  The floor is documented: below it the view would spend more time refreshing
  than the data changes.
- **Only changed rows are updated.** An idle tick issues no `ui.update` at
  all; a tick with a new record updates the status line and one trace row.
  Ticks never notify, so the host notification rate policy is never touched.
- **Pause.** `view-pause` cancels the timer and stops draining but keeps the
  view's trace handle: records keep accumulating in the host's bounded
  drop-oldest buffer, and `view-resume` drains them in one tick. The dropped
  counter therefore keeps its meaning instead of resetting.
- **Close.** `view-close` hides every row (an empty band root reserves no
  row), cancels the timer, and releases the view's trace handle. Plugin API
  v1 has no `ui.unmount`, so the eight blocks stay allocated for the
  generation and a reopen reuses their handles; this is documented as a Core
  gap in [bitty#3106](https://github.com/bitty-terminal/bitty/issues/3106).
- **Grants.** The view needs `ui.rich`. It is non-focusable and never calls
  `bitty.ui.overlay.*`, so no input-capture capability is requested. When
  the grant is declined, revoked, or the host predates the bridge, the four
  `view-*` commands return a typed error through the notification path and
  the seven read-only commands keep working unchanged.
- **Hidden/focused.** v1 exposes no visibility signal for a mounted block, so
  the view cannot pause itself when hidden; use `view-pause`. Recorded as
  [bitty#3107](https://github.com/bitty-terminal/bitty/issues/3107).

The full design record, including the three decisions the feature required
and the host evidence behind each, is
[docs/design/live-view.md](docs/design/live-view.md).

## Configuration

This plugin declares no settings.

There is no plugin settings file: the manifest declares no `[settings]` keys
and the entry point reads none. The trace filter is a command argument, not a
setting.

## Keybindings

DevTools registers no default keybinding. Bind a read-only list command in
`$XDG_CONFIG_HOME/bitty/init.lua`; user mappings keep precedence:

```lua
return {
  keymaps = {
    {
      chord = "ctrl+alt+d",
      action = "command:bitty-featured.devtools:plugins",
      context = "global",
    },
  },
}
```

The four list commands take no arguments, so they are safe to bind bare.
`trace-start` accepts an optional `filter`; a bare binding traces all declared
kinds. The `view-*` commands take no arguments except `view-open`, so
`view-open` (or a toggle between `view-open` / `view-close`) also binds
bare.

## Troubleshooting

| Symptom / error          | Meaning                                                                               | What to do                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| No notification appears  | The host queues notification bodies but does not drain them yet (bitty#1827).         | Read the command result through dispatch; it carries the full bounded text.       |
| `E_BRIDGE_ABSENT`        | The host predates the `bitty.debug` backend, so `inspect` or `trace` is unavailable.  | Use a Bitty build that wires `bitty.debug`, or run the command on a host with it. |
| `E_CAPABILITY_DENIED`    | `debug.inspect`, `debug.trace`, or `platform.notify` is missing, expired, or revoked. | Re-run `bitty plugin install <path>` and approve the current grant set.           |
| `E_TRACE_ACTIVE`         | `trace-start` ran while this plugin already holds a trace.                            | Run `trace-dump` or `trace-stop` before starting another trace.                   |
| `E_TRACE_GONE`           | The host dropped the trace on reload, failure, or disposal.                           | Start a new trace; the previous records are gone.                                 |
| `E_DEF_INVALID`          | The `filter` argument is empty, not a string, or longer than 128 bytes.               | Pass a 1–128 byte exact kind or a prefix ending in `*`, such as `terminal.*`.     |
| `E_DEF_LIMIT`            | The host trace limit for this plugin is reached.                                      | Stop an existing trace and retry.                                                 |
| `E_VIEW_ACTIVE`          | `view-open` ran while this plugin already shows a live view.                          | Run `view-close` before opening another view.                                     |
| `E_VIEW_INACTIVE`        | `view-close` / `view-pause` / `view-resume` ran with no live view open.               | Run `view-open` first.                                                            |
| `E_UI_UNAVAILABLE`       | The host cannot present the `bottom` band on this build.                              | Use a build with a hosted `bottom` band, or keep using the seven commands.        |
| `E_BRIDGE_ABSENT` (view) | The host predates `bitty.ui` or `bitty.timers`.                                       | The view needs a host with both; the seven commands still work.                   |

## Error handling

Every host call is wrapped in `pcall`. A failure never escapes a command; it
is shown as `<action> failed: <code>: <hint>`, for example
`inspect plugins failed: E_CAPABILITY_DENIED: capability not granted` or
`trace start failed: E_DEF_LIMIT: trace limit reached for this plugin`. A
failed notification (rate policy) is ignored; the command still returns its
text. A missing bridge namespace or function (a host predating the
`bitty.debug` backend) reports `E_BRIDGE_ABSENT` through the same path, and
an absent notify bridge skips the notification while still returning the
text. The four `view-*` commands use the same path: a refused mount
(`E_CAPABILITY_DENIED`, `E_UI_UNAVAILABLE`, `E_BRIDGE_ABSENT`) or a refused
trace (`E_DEF_LIMIT`) is reported as `view open failed: …` and leaves no
visible row, no timer, and no handle.

## Capabilities

| Capability        | Why                                                             |
| ----------------- | --------------------------------------------------------------- |
| `debug.inspect`   | Read-only `bitty.debug.inspect` for the four list commands.     |
| `debug.trace`     | `bitty.debug.trace` / `trace_get` for the three trace commands. |
| `platform.notify` | Show the bounded summaries.                                     |
| `ui.rich`         | Mount the optional live view (declarative `Text` rows).         |

`debug.control`, `ui.overlay`, `ui.overlay.focus`, and every input-capture
identifier are intentionally not requested. The live view is non-focusable
window chrome: it never captures input and never paints outside its band.

## Traced event kinds

A trace records only event kinds this plugin declares in `bitty-plugin.toml`
`[lazy] events`, and only while the plugin is Active. The manifest declares
the nine v1 observation kinds from the closed event set (`EventKind` in
`bitty-plugin-host`): `terminal.opened`, `terminal.closed`,
`terminal.title-changed`, `terminal.cwd-changed`, `terminal.bell`,
`focus.changed`, `selection.changed`, `process.exited`, and
`config.reloaded`. Lifecycle and interception kinds are not traced. The
plugin subscribes to none of them; the declaration is what makes a kind
visible to a trace.

## Downstream enablement

Plugin-side follow-through for
[devtools#10](https://github.com/bitty-terminal/devtools/issues/10)
(post-0.0.22: the issue body says "post-0.0.24" but the title governs, and
bitty v0.0.22 released 2026-10-08, so the window is open). The plugin holds
its side of each item defensively; host, registry, and palette work is
tracked in the owning repositories, not done here.

| Item                             | Plugin guarantee (this repo)                                                                                                                                                                                                                                               | External dependency                                                                                                                                                                               |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Notification/result surfacing | Every command returns its full text as the result plus a one-line notice; notify failure or an absent notify bridge never crashes a command.                                                                                                                               | Host must drain `drain_notifications` into tick/present and surface dispatcher results: [bitty#1827](https://github.com/bitty-terminal/bitty/issues/1827).                                        |
| 2. Declared trace kinds          | All nine manifest kinds record when the host delivers them (mock suite delivers every kind in one drain); an absent `bitty.debug` bridge fails closed with `E_BRIDGE_ABSENT`. The manifest keeps all nine declarations (harmless preconditions) until the host catches up. | Host emits only `terminal.title-changed`, `focus.changed`, `workspace.*` today; the other seven kinds need emission: [bitty#1828](https://github.com/bitty-terminal/bitty/issues/1828).           |
| 3. Command-invocation path       | All seven commands run with empty args, carry closed schemas and bounded titles, and return string results (consumer-contract test).                                                                                                                                       | Generic palette/keybinding to `dispatch_command` path, deny-by-default: [bitty#1829](https://github.com/bitty-terminal/bitty/issues/1829).                                                        |
| 4. Registry + palette consumer   | Manifest validates with the authoritative linter; identity fields are present for metadata sync.                                                                                                                                                                           | Registry entry: [bitty-plugins#80](https://github.com/bitty-terminal/bitty-plugins/issues/80). Palette headless consumer test: [palette#31](https://github.com/bitty-terminal/palette/issues/31). |

## Privacy and security

- Read-only: the plugin never calls `bitty.debug.control` or any mutating
  runtime API, and holds no authority to suspend, reload, or reconfigure
  plugins.
- Inspect results carry ids, versions, lifecycle labels, generations,
  command titles, and event kinds only. The host never includes settings
  values, store contents, secrets, terminal content, or failure messages.
- Trace payloads are event payloads for declared kinds. Some can carry
  sensitive display data, such as `terminal.cwd-changed` paths and
  `terminal.title-changed` titles. They appear only in the transient
  notification text and are never persisted. The plugin has no store,
  filesystem, network, or process authority.
- Traces are bounded by the host: at most 4 open traces per plugin, a
  drop-oldest ring of at most 10000 records, and oversized payloads replaced
  by `{ truncated = true, bytes = n }`. This plugin uses at most two of those
  traces (one for the commands, one for the live view).
- The live view paints the same bounded text the commands return: inspect
  rows, trace record lines, and counters. It adds no data source, never reads
  PTY bytes or terminal cells, never persists anything, and is non-focusable,
  so it cannot capture input. Each row is capped at 112 bytes.

## Layout

| Path                       | Purpose                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`        | Manifest: identity, compatibility, capabilities, lazy commands and declared events.                     |
| `lua/devtools/init.lua`    | Entry point: registers the eleven commands and wires them to the modules below.                         |
| `lua/devtools/format.lua`  | Pure, bounded text rendering of inspect results, trace drains, view rows, and errors.                   |
| `lua/devtools/trace.lua`   | Single-handle trace state machine (start / dump / stop, nil-drain recovery, absent-bridge fail-closed). |
| `lua/devtools/view.lua`    | Live view state machine (mount / update / hide, one-shot timer chain, pause/resume, loss handling).     |
| `docs/design/live-view.md` | Design record: the three decisions, their host evidence, and the two filed Core gaps.                   |
| `tests/`                   | Plain-Lua behavior suite, mock host, and LuaLS conformance (see `tests/README.md`).                     |
| `scripts/workflow-*.sh`    | CarryCtx snapshot publish/restore on `refs/heads/carryctx-snapshots`.                                   |
| `.github/workflows/`       | CI quality gates, CodeQL, and the snapshot-source staleness check.                                      |

## Development

```sh
just check     # lint + fmt-check + manifest + lua + lua-control + test
```

This is a Lua-only repository with no JS/TS project. `just check` needs
`just`, `bun` (runs the pinned Markdown and SDK manifest linters through
`bunx`), `lua5.4`, and `luac5.4`; the Markdown and manifest gates fetch their
pinned tools on first run. `just test-lua` needs `lua5.4`. `just test-luals` needs `lua-language-server`
and skips with exit 0 when it is absent. Contribution rules are in
[CONTRIBUTING.md](CONTRIBUTING.md). The security policy is in
[SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
