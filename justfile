# Quality gates for Bitty DevTools (bitty-featured.devtools).
#
# Dependencies live in package.json and are locked in bun.lock; `just install`
# materializes them. Installed tools are invoked with `bun run <bin>` so every
# gate resolves from node_modules and runs offline once install has completed.
# The manifest gate runs the authoritative SDK linter (bitty-plugin-lint,
# commit-pinned in package.json + bun.lock), not a vendored re-implementation.
# A gate with missing dependencies fails closed (`just deps`) instead of
# fetching. Never use npm, npx, or yarn in this repository.

# List available recipes.
default:
    @just --list

# Install pinned dev dependencies from bun.lock. This is the only gate step
# that may use the network; install once, then `just check` is offline.
install:
    bun install --frozen-lockfile

# Fail closed when dependencies are absent, so a gate never silently fetches
# from the network. Run `just install` first.
deps:
    @test -d node_modules || { echo "dependencies are not installed; run 'just install'" >&2; exit 1; }

# Lint all Markdown sources with markdownlint-cli2 (.markdownlint-cli2.jsonc).
lint: deps
    bun run markdownlint-cli2

# Lint specific Markdown files (used by the pre-commit hook).
lint-files *files: deps
    bun run markdownlint-cli2 {{files}}

# Format all files with Prettier.
fmt: deps
    bun run prettier --write . --ignore-unknown

# Format specific files with Prettier.
fmt-files *files: deps
    bun run prettier --write {{files}}

# Check formatting of all files with Prettier.
fmt-check: deps
    bun run prettier --check . --ignore-unknown

# Check formatting of specific files (used by the pre-commit hook).
fmt-check-files *files: deps
    bun run prettier --check {{files}}

# Validate a commit message file with commitlint (conventional commits).
commit-check message=".git/COMMIT_EDITMSG": deps
    bun run commitlint --edit "{{message}}"

# Install Git hooks managed by lefthook (opt-in per contributor checkout).
hooks-install: deps
    bun run lefthook install

# Remove lefthook-managed Git hooks.
hooks-uninstall: deps
    bun run lefthook uninstall

# Validate bitty-plugin.toml with the authoritative SDK linter (R-SDK-2),
# pinned by commit in package.json and bun.lock. The SDK binary is checked here,
# not in `deps`, so an unrelated gate never requires it. The manifest schema is
# owned by bitty-docs, not by this repository.
manifest: deps
    @test -x node_modules/.bin/bitty-plugin-lint || { echo "bitty-plugin-lint is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-lint bitty-plugin.toml

# Parse the Lua entry point with the pinned Lua 5.1 grammar parser (luaparse,
# version pinned in package.json + bun.lock).
lua: deps
    bun run luaparse --quiet --file lua/devtools/init.lua lua/devtools/format.lua lua/devtools/trace.lua

# Run the Lua 5.4 behavior suite (format bounds, trace state machine, commands).
# Requires lua5.4 (plugin VM baseline per ADR 0005).
test-lua:
    lua5.4 tests/run.lua

# LuaLS conformance against the vendored Plugin API v1 definitions. Skips with
# exit 0 when lua-language-server is unavailable (set LUA_LANGUAGE_SERVER).
test-luals:
    bun tests/check-lua-luals.mjs

# Run all behavior and conformance tests.
test: test-lua test-luals

# Aggregate gate run locally and in CI (after `just install`).
check: lint fmt-check manifest lua test

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
