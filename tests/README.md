# Devtools test harness

Headless checks for the `lua/devtools/**` implementation. `just check`
(`lint` + `fmt-check` + `manifest` + `lua` + `lua-control` + `test`) runs them locally and in
CI; the individual suites are also available directly.

## Prerequisites

- `lua5.4` (plugin VM baseline per ADR 0005) — required for behavior tests;
  CI installs it from the Ubuntu archive before `just check`.
- `luac5.4` — Lua 5.4 syntax gate (`just lua`) and its fail-closed control
  (`just lua-control`).
- `lua-language-server` (optional) — LuaLS conformance; the check skips with
  exit 0 when it is unavailable (CI does not install it).

## Commands

```sh
just test            # lua5.4 runner + LuaLS check

# Behavior tests: format bounds, trace state machine, commands, errors.
just test-lua

# LuaLS conformance against the vendored definitions
# (LUA_LANGUAGE_SERVER=/path/to/server overrides discovery).
just test-luals
```

## Layout

| Path                            | Purpose                                                                                                   |
| ------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `run.lua`                       | Plain-Lua runner; exits non-zero on assertion failure.                                                    |
| `support/tap.lua`               | Assertion helper (no external test framework).                                                            |
| `support/mock_host.lua`         | Fail-closed `bitty` stub: commands, notify, and `bitty.debug` with trace cap and declared-kind recording. |
| `spec/format_spec.lua`          | Rendering, truncation, sanitization, and bounds unit tests.                                               |
| `spec/trace_spec.lua`           | Trace state machine unit tests (start/dump/stop, E_DEF_LIMIT, nil drain, retry).                          |
| `spec/init_spec.lua`            | Entry-point behavior against the mock host, including the no-UI assertion.                                |
| `lua-defs/bitty.d.lua`          | Unmodified SDK LuaLS definitions (bitty-plugin-sdk `e1723b6`, sha256 `9aef9397...`).                      |
| `lua-defs/bitty-debug.d.lua`    | Local `bitty.debug` definitions mirroring bitty `c4af172b`; `control` deliberately undefined.             |
| `lua-defs/negative-fixture.lua` | Excluded-surface fixture that LuaLS must reject.                                                          |
| `check-luals.sh`                | POSIX shell positive/negative LuaLS workspace check.                                                      |

## Known gaps

- The SDK surface at the pinned commit does not generate `bitty.debug`, so
  `bitty-debug.d.lua` is hand-written from the host source and must be
  dropped once the SDK covers it.
- `support/mock_host.lua` models the host contract; it is not the host. End-to-end
  activation against a real `PluginRuntime` is not covered here.
- CI installs `lua5.4` but not `lua-language-server`, so the LuaLS wrapper
  reports `skipped` (exit 0) in CI.
