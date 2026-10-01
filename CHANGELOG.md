# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Not usable on a real host yet. On bitty `main` `c4af172b`,
`PluginRuntime::deliver_event`, `dispatch_command`, and `drain_notifications`
have no production caller. Live tracing, command dispatch, and notification
delivery depend on bitty#1564 (`CTX-0892`). Until it lands, traces record
nothing and the commands are reachable only through runtime test seams. UI
is deferred until bitty#1442 closes.

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
