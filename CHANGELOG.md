# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Verified on bitty `main` `811ba94c`. The `bitty.debug` backend
(bitty#1573, `c4af172b`) and the app-loop wiring (bitty#1564, `CTX-0892`)
are both merged: `dispatch_command` and `deliver_event` have production
callers, while `drain_notifications` still has none, so command results
return through dispatch while notification bodies queue unseen. Of the nine
declared trace kinds, the live loop emits only `terminal.title-changed` and
`focus.changed`; the other seven record only through test seams.
Live-host evidence (CTX-0005): all seven commands dispatch with bounded text,
nine delivered kinds all record, `terminal.*` filtering holds, and 12
notifications queue. UI stays notification-only by scope; the upstream
overlay APIs have landed (CTX-0911 bitty#1594 / issue #1570; CTX-0941
bitty#1654 / #1633). bitty#1442 (session-restore input history, closed) is
not a GUI blocker.

### Added

- Read-only runtime inspection commands `plugins`, `commands`, `events`, and
  `grants` over `bitty.debug.inspect` (bitty#1573), shown as bounded
  notifications.
- Event tracing commands `trace-start` (optional `filter`), `trace-dump`, and
  `trace-stop` over `bitty.debug.trace` / `trace_get`, using a single-handle
  state machine that recovers when the host drops a trace. `trace-stop`
  tells apart a successful final drain, a trace the host already dropped,
  and a failed final drain.
- Notifications carry a one-line notice of at most 256 characters (the host
  chrome `MAX_NOTIFICATION_TEXT_LEN`). The full bounded text is the command
  result.
- Manifest requesting only `debug.inspect`, `debug.trace`, and
  `platform.notify`, with the nine v1 observation event kinds declared so
  traces have something to record. `compat.bitty = ">=0.0.21,<1.0"` admits
  the current pre-1.0 host.
- Pure formatting module with named output bounds and control-byte
  sanitization. Host errors are surfaced as `<action> failed: <code>`
  notifications and never raised.
- Behavior suite (`lua5.4 tests/run.lua`) with a fail-closed mock host that
  models `bitty.debug`. LuaLS conformance runs against the vendored SDK
  `bitty.d.lua` plus a local `bitty-debug.d.lua`.
- Repository scaffolding at parity with sibling plugin repositories: AGENTS,
  CONTRIBUTING, SECURITY, LICENSE (MIT), commitlint, lefthook, Markdown lint,
  CI, CodeQL, snapshot-source workflows, Dependabot, issue/PR templates,
  CarryCtx baseline config, and snapshot publish/restore scripts.

### Changed

- The repository is Lua-only: `package.json`, `bun.lock`, commitlint,
  lefthook, and the JavaScript LuaLS wrapper are removed, along with the
  `just install`, `commit-check`, and `hooks-*` recipes, the Dependabot `bun`
  entry, and the CodeQL `javascript-typescript` analysis (#6).
- Gate tool versions are pinned once as justfile variables and run through
  `bunx --bun`: markdownlint-cli2 0.23.2, Prettier 3.9.6, and the SDK
  `bitty-plugin-lint` at `bitty-plugin-sdk` commit `e1723b6`. CI reads the Bun
  version from `.bun-version`.
- The Lua syntax gate uses `luac5.4 -p` (the host VM implements a Lua 5.4
  subset) instead of the Lua 5.1 `luaparse` grammar, plus a `lua-control`
  recipe that confirms invalid Lua is rejected. LuaLS conformance runs as the
  POSIX shell script `tests/check-luals.sh`.
