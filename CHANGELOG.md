# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Read-only runtime inspection commands `plugins`, `commands`, `events`, and
  `grants` over `bitty.debug.inspect` (bitty#1573), shown as bounded
  notifications.
- Event tracing commands `trace-start` (optional `filter`), `trace-dump`, and
  `trace-stop` over `bitty.debug.trace` / `trace_get`, using a single-handle
  state machine that recovers when the host drops a trace.
- Manifest requesting only `debug.inspect`, `debug.trace`, and
  `platform.notify`, with the nine v1 observation event kinds declared so
  traces have something to record.
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

### Removed

- Template `hello` command and `greeter` service.
