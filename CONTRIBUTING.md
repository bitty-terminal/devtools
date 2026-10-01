# Contributing to devtools

This guide is for contributors to the `devtools` plugin repository. The
plugin is pre-release: it is verified against a local mock host, not a
released Bitty host.

## Repository ground rules

- Read [AGENTS.md](AGENTS.md) before making any change. It defines authority,
  scope boundaries, CarryCtx workflow, toolchain policy, and the security and
  privacy constraints that override convenience.
- Canonical plugin architecture, API, packaging, compatibility, and security
  contracts live in `bitty-docs` and `bitty-plugins-docs`. This repository
  must not invent capabilities, lifecycle semantics, or release policy
  independently.
- Never commit, push, publish packages, or mutate remote state without
  explicit authorization from the owning task.

## Prerequisites

Toolchain expectations (dependency versions are pinned in
[package.json](package.json) and locked in `bun.lock`; never invoke formatters
or linters by name):

- `just` — command runner owning all quality-gate invocations.
- `bun` / `bun run <bin>` — JavaScript execution and package management; the
  justfile invokes installed tools as `bun run <bin>`. Never use `npm`, `npx`,
  or `yarn` in any Bitty repository.
- `markdownlint-cli2`, `prettier`, `commitlint`, `lefthook` — materialized by
  `just install` and invoked through the justfile.

## Development setup

1. Enter this repository before running Git, CarryCtx, or toolchain commands.
2. Install pinned development dependencies: `just install`.
3. Enable Git hooks (optional): `just hooks-install`.
4. Run all quality gates: `just check` (Markdown lint, Prettier format check,
   manifest validation, Lua parse, and the Lua behavior suite). CI runs the same aggregate target.
5. Record scoped work in CarryCtx (task, session, progress, checkpoint) and
   stop at review; independent review is required for acceptance.

## Delivery lifecycle

Changes follow Issue -> Branch -> Commit -> Pull Request -> Review -> Merge,
where independent review plus required CI must pass before merge. Before this
repository's first commit, branch/worktree/commit/pull-request stages are
unavailable: initialization happens in a shared checkout with explicit
disjoint scopes, preserved unrelated changes, and CI-equivalent local checks.

Every pull request states its Issue and CarryCtx task links, impact areas,
security and privacy impact, reproducible gate evidence, and documentation
synchronization status. Labels (`feat`/`fix`/`docs`/`chore`, `P0`/`P1`/`P2`,
`area:*`) and milestone `v0.1.0` are kept in sync.

## Contributor branches

The project is managed with CarryCtx. Official branches follow the CarryCtx
task convention `ctx-XXXX/<type>-<slug>`, where `XXXX` is the owning task id,
`<type>` is one of `feat|fix|chore|docs`, and the slug is short kebab-case.
Commander housekeeping branches use `cmd/<slug>`.

External contributors must use a distinguishable prefix such as
`<github-handle>/<type>-<slug>` (for example `octocat/fix-manifest-lint`) so
their branches are never confused with maintainer task branches.

## Capabilities and privacy

Manifest capability requests are deny by default and must stay minimal. The
plugin requests only `debug.inspect`, `debug.trace`, and `platform.notify`; any
wider request requires an explicitly scoped task plus a reviewed privacy and
security note. Never add high-risk capabilities, install scripts, secrets, or
ambient authority as a side effect of an unrelated change.

## Workflow snapshots

The engineering workflow snapshot lives in this repository on the branch
`refs/heads/carryctx-snapshots`. Merges run `just workflow-publish` (dry run:
`just workflow-publish-dry`) as part of the commander closeout; snapshots are
redacted publication artifacts and are never merged back. Fresh clones restore
with `just workflow-import` (`just workflow-import-dry`).

## Reporting

Report bugs and feature requests through the GitHub issue templates. Report
security issues privately per [SECURITY.md](SECURITY.md).
