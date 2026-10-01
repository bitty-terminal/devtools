# Bitty DevTools repository guidance

## Repository and authority

- This is the independent `devtools` repository. Its canonical remote is
  <https://github.com/bitty-terminal/devtools>.
- The Bitty umbrella directory and [`bitty-plugins`](https://github.com/bitty-terminal/bitty-plugins) directory are grouping
  only; neither owns this repository's Git or CarryCtx state. The
  `bitty-plugins` commander owns this repository's jurisdiction.
- Enter this repository before running Git, CarryCtx, validation, or toolchain
  commands.
- [bitty-docs](https://github.com/bitty-terminal/bitty-docs) is the canonical source for plugin architecture, API, security,
  packaging, compatibility, and public-behavior contracts. This repository
  must not invent capabilities, lifecycle semantics, or release policy.
- The archived `bitty-devtools` repository is superseded by this plugin; do
  not copy or reference its code.

## Plugin identity and scope

- Plugin id: `bitty-featured.devtools` (manifest `plugin.id`), repository
  `devtools`, Lua modules under `lua/devtools/`.
- Purpose: read-only inspection of the plugin runtime (`bitty.debug.inspect`)
  and bounded event tracing (`bitty.debug.trace` / `trace_get`), surfaced as
  bounded host notifications.
- Authority boundary: only `debug.inspect`, `debug.trace`, and
  `platform.notify` are requested. `debug.control`, every `ui.*` identifier,
  filesystem, network, process spawn, clipboard, terminal input, and
  install-time code execution stay out. A wider request needs an explicitly
  scoped task and a reviewed privacy and security note; never widen silently.
- UI work (panels, overlays, rich surfaces, mounted views) is deferred until
  [bitty#1442](https://github.com/bitty-terminal/bitty/issues/1442) closes and
  the upstream GUI APIs are finished. Do not call `bitty.ui` or request `ui.*`
  capabilities before then.

## CarryCtx and agents

- Use this repository's CarryCtx state for tasks, dependencies, scopes,
  sessions, progress, decisions, checkpoints, handoffs, and review.
- Install the `carryctx` CLI globally for local development (recommended).
- The commander coordinates. Delegate substantial scoped work to focused
  agents and require an independent reviewer for acceptance.
- Every agent reads its persona and applicable rules, binds a named session to
  the task, and stays within explicit scopes.
- After the first commit, use a dedicated branch and Git worktree for each
  independent task.
- Branch and worktree naming is uniform across repositories: branches use
  `ctx-XXXX/<type>-<short-slug>` where `XXXX` is the owning CarryCtx task
  number, `<type>` is one of feat|fix|chore|docs, and the slug is short
  kebab-case. CarryCtx-bound worktrees live at
  `.worktrees/ctx-XXXX-<type>-<short-slug>` with `/` mapped to `-`. One branch
  per task; commander housekeeping branches may use `cmd/<slug>`.
- Preserve unrelated changes. Do not commit, push, release, publish packages,
  create repositories, or mutate remote state without authorization.
- Fresh clones have no CarryCtx state DB. Restore the local DB from the
  in-repo snapshot branch with `just workflow-import` (validate-only:
  `just workflow-import-dry`). It fetches `refs/heads/carryctx-snapshots`,
  refuses to replace a non-empty local DB without `--force`, and prints
  provenance and restored counts. Snapshots are redacted publication artifacts
  from `carryctx export --publication`: never merge them back, and rotate at
  the source any secret that leaked before rotation.

## Delivery lifecycle

- Use GitHub Issue -> CarryCtx team/task/dependencies/scopes/session ->
  isolated branch/worktree -> commit -> pull request -> independent review
  plus CI -> merge -> `bitty-docs` synchronization -> checkpoint -> Issue/task
  closure.
- Every Issue and PR carries labels (`feat`/`fix`/`docs`/`chore` +
  `P0`/`P1`/`P2` + `area:*`) and milestone `v0.1.0`. Bodies state
  `Priority: ... | Area: ... | Labels: ... | Milestone: ... | RFC: ... |
Task: CTX-XXXX` and PRs add `Closes #<issue>`.
- Pull requests name plugin-contract, privacy/security, CI/release,
  documentation, and compatibility impact with reproducible evidence.
- Documentation synchronization is part of definition of done. A plugin
  change is incomplete while canonical `bitty-docs` guidance or this
  repository's README/CHANGELOG are stale.

## Toolchain policy

- JavaScript runs on `bun` (pinned in `package.json` `packageManager` and the
  CI workflow).
- Never invoke formatters or linters directly by name. Run quality gates only
  via the justfile: `just check` plus `just lint`, `just fmt-check`,
  `just manifest`, `just lua`, `just test`.
- Dependency versions are pinned in `package.json` and locked in `bun.lock`;
  the justfile keeps no version pins and invokes installed tools as
  `bun run <bin>`. Do not bump pins as a side effect of an unrelated task;
  report drift instead of silently fixing it.
- `tests/lua-defs/bitty.d.lua` is the unmodified SDK file at the pinned
  commit; `tests/lua-defs/bitty-debug.d.lua` is a local stand-in for the
  `bitty.debug` surface until the SDK generates it.
- CI success is a hard acceptance gate. Workflow-affecting changes are
  validated locally with `actionlint` before push.

## Security and privacy invariants

- Deny-by-default capabilities; no allow-all or wildcard identifiers.
- Read-only: never call `bitty.debug.control` or any mutating runtime API.
- Traces observe only the event kinds declared in `bitty-plugin.toml`
  `[lazy] events`; adding a kind widens what the plugin can observe and needs
  the same review as a capability change.
- Trace records and inspect results are never persisted; output is bounded
  text in host notifications only.
- No secrets in the repository, fixtures, or logs. No hardcoded host paths,
  usernames, or machine layout in any artifact.
- Security requirements in the canonical `bitty-docs` security corpus
  override convenience or copied examples.

## Documentation and commands

- English is the only canonical documentation language.
- Separate accepted requirements, candidates, open questions, implemented
  facts, and verification evidence.
- Prefer narrow reads for inspection: read specific sections or line ranges
  and keep context small. Use `rg` for discovery.
- Ephemeral scratch goes under `/tmp/bitty/`; durable material goes under
  repo-local `recording/` (gitignored). Never move another agent's work.
