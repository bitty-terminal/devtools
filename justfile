# Quality gates for Bitty DevTools (bitty-featured.devtools).
#
# This is a Lua-only plugin repository: the host loads `bitty-plugin.toml` and
# `lua/`. There is no JS/TS project here (no package.json, no lockfile, no
# node_modules). The Markdown and manifest gates run pinned tools on demand
# through `bunx --bun`; every tool version is pinned exactly once, in the
# variables below. Lua gates use the system `lua5.4` / `luac5.4`. Never use
# npm, npx, or yarn in this repository.

# Pinned gate tool versions (single source of truth).
prettier_version := "3.9.6"
markdownlint_version := "0.23.2"

# Authoritative SDK manifest linter (R-SDK-2), pinned by bitty-plugin-sdk commit.
sdk_ref := "e1723b60cc94d3abc18821c9e6b14c6c88f33add"

# Lua sources checked by the syntax gate.
lua_sources := "lua/devtools/*.lua"

# List available recipes.
default:
    @just --list

# Lint all Markdown sources with markdownlint-cli2 (.markdownlint-cli2.jsonc).
lint:
    bunx --bun markdownlint-cli2@{{markdownlint_version}}

# Format all files with Prettier.
fmt:
    bunx --bun prettier@{{prettier_version}} --write . --ignore-unknown

# Check formatting of all files with Prettier.
fmt-check:
    bunx --bun prettier@{{prettier_version}} --check . --ignore-unknown

# Validate bitty-plugin.toml with the authoritative SDK linter (R-SDK-2),
# pinned by commit via `sdk_ref`. The manifest schema is owned by bitty-docs,
# not by this repository.
manifest:
    bunx --bun --package "github:bitty-terminal/bitty-plugin-sdk#{{sdk_ref}}" bitty-plugin-lint bitty-plugin.toml

# Parse every plugin Lua source with the Lua 5.4 compiler (`luac5.4 -p`, parse
# only, no output). The host VM (phodopus, via bitty-lua) implements a Lua 5.4
# language subset, so 5.4 syntax is the matching dialect.
lua:
    luac5.4 -p {{lua_sources}}

# Fail-closed control: the syntax checker must reject invalid Lua. Guards
# against a `lua` gate that silently accepts everything.
lua-control:
    @if printf 'local x =\n' | luac5.4 -p - 2>/dev/null; then echo "lua-control: luac5.4 accepted invalid Lua" >&2; exit 1; fi
    @echo "lua-control: luac5.4 rejects invalid Lua"

# Run the Lua 5.4 behavior suite (format bounds, trace state machine, commands).
# Requires lua5.4 (plugin VM baseline per ADR 0005).
test-lua:
    lua5.4 tests/run.lua

# LuaLS conformance against the vendored Plugin API v1 definitions. Skips with
# exit 0 when lua-language-server is unavailable (set LUA_LANGUAGE_SERVER).
test-luals:
    sh tests/check-luals.sh

# Run all behavior and conformance tests.
test: test-lua test-luals

# Aggregate gate run locally and in CI.
check: lint fmt-check manifest lua lua-control test

# Publish a redacted CarryCtx snapshot inside this repo (commander merge
# closeout only; never a git hook). `carryctx export --publication` redacts the
# bundle, stamps manifest.redacted, and commits one snapshot to the fixed ref
# `refs/heads/carryctx-snapshots`; the target pushes that branch only when the
# local ref advanced (native carryctx commits one snapshot per export, so a
# re-run publishes again rather than no-opping). Canonical closeout runs from
# the primary checkout on branch main
# (`cd "$BITTY_WORKSPACE/bitty-plugins/plugins/devtools" && just workflow-publish`); a
# detached or feature worktree records that branch as the snapshot source. Dry
# run validates the export and writes neither the ref nor the remote.
workflow-publish *args:
    bash scripts/workflow-publish.sh {{args}}

workflow-publish-dry *args:
    bash scripts/workflow-publish.sh --dry-run {{args}}

# Restore the local CarryCtx DB from the in-repo snapshot branch
# `refs/heads/carryctx-snapshots` (fresh-clone recipe). Refuses to replace a
# non-empty local DB without --force, e.g. `just workflow-import --force`.
workflow-import *args:
    bash scripts/workflow-import.sh {{args}}

workflow-import-dry *args:
    bash scripts/workflow-import.sh --dry-run {{args}}
