# Bitty DevTools

Read-only inspection and event tracing of the Bitty plugin runtime
(`bitty-featured.devtools`). It summarizes what the plugin host knows
(plugins, commands, event subscriptions, its own grants) and records bounded
event traces, and shows the results as host-rendered text notifications.

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
> (CTX-0005): all seven commands dispatch and return bounded text (`plugins`
> 54 bytes / 1 row, `commands` 447 bytes / 7 rows, `events` 15 bytes /
> 0 rows, `grants` 50 bytes / 3 grants, `trace-start` / `trace-dump`
> 9 records / `trace-stop` close cleanly, `terminal.*` filter keeps
> `terminal.bell` and drops `focus.changed`, 12 notifications queued). The
> plugin is also verified against the local mock host (436 assertions) and
> LuaLS definitions. UI surfaces (panels, overlays, mounted views) stay
> notification-only by scope; the upstream overlay APIs have landed (CTX-0911
> edge-band `UiBlock` rendering, bitty#1594 / issue #1570; CTX-0941 focusable
> overlay and transient input capture, bitty#1654 / #1633). Do not cite
> bitty#1442 (session-restore input history, closed) as a GUI blocker.

## Commands

All commands are plugin-qualified as `bitty-featured.devtools:<name>`. Every
command returns its full rendered text as the command result and shows a
one-line notice of it, at most 256 characters, as a notification.

| Command       | Behavior                                                                                                                                                   |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plugins`     | Summarize `bitty.debug.inspect("plugins")`: id, version, lifecycle state, generation.                                                                      |
| `commands`    | Summarize registered commands (`plugin:id - title`).                                                                                                       |
| `events`      | Summarize event subscriptions (`plugin <- kind`).                                                                                                          |
| `grants`      | List the capabilities granted to this plugin (the host never exposes other plugins' grants).                                                               |
| `trace-start` | Open one trace over the declared event kinds. Optional argument `filter` (exact kind, or a prefix ending in `*`, such as `terminal.*`; at most 128 bytes). |
| `trace-dump`  | Drain the buffered records and summarize the most recent ones, with the drained and dropped counts.                                                        |
| `trace-stop`  | Drain the final records and close the trace. If the final drain fails, the trace is still closed and the drain error is reported.                          |

The plugin holds at most one trace at a time; `trace-start` while a trace is
running reports `E_TRACE_ACTIVE`. If the host drops the trace (reload,
failure, or disposal), the next dump reports `E_TRACE_GONE` and a new trace
can be started. The `panels` inspect target is reserved upstream
(`E_NOT_IMPLEMENTED`) and is not exposed.

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

## Error handling

Every host call is wrapped in `pcall`. A failure never escapes a command; it
is shown as `<action> failed: <code>: <hint>`, for example
`inspect plugins failed: E_CAPABILITY_DENIED: capability not granted` or
`trace start failed: E_DEF_LIMIT: trace limit reached for this plugin`. A
failed notification (rate policy) is ignored; the command still returns its
text. A missing bridge namespace or function (a host predating the
`bitty.debug` backend) reports `E_BRIDGE_ABSENT` through the same path, and
an absent notify bridge skips the notification while still returning the
text.

## Capabilities

| Capability        | Why                                                             |
| ----------------- | --------------------------------------------------------------- |
| `debug.inspect`   | Read-only `bitty.debug.inspect` for the four list commands.     |
| `debug.trace`     | `bitty.debug.trace` / `trace_get` for the three trace commands. |
| `platform.notify` | Show the bounded summaries.                                     |

`debug.control` and every `ui.*` identifier are intentionally not requested.

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
  by `{ truncated = true, bytes = n }`.

## Layout

| Path                      | Purpose                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`       | Manifest: identity, compatibility, capabilities, lazy commands and declared events.                     |
| `lua/devtools/init.lua`   | Entry point: registers the seven commands and wires them to the modules below.                          |
| `lua/devtools/format.lua` | Pure, bounded text rendering of inspect results, trace drains, and errors.                              |
| `lua/devtools/trace.lua`  | Single-handle trace state machine (start / dump / stop, nil-drain recovery, absent-bridge fail-closed). |
| `tests/`                  | Plain-Lua behavior suite, mock host, and LuaLS conformance (see `tests/README.md`).                     |
| `scripts/workflow-*.sh`   | CarryCtx snapshot publish/restore on `refs/heads/carryctx-snapshots`.                                   |
| `.github/workflows/`      | CI quality gates, CodeQL, and the snapshot-source staleness check.                                      |

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
