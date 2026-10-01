# Pull request

## Summary

<!-- Provide a concise description of the change and its motivation. -->

## Related issue and CarryCtx task

- Closes #
- CarryCtx task: CTX-

Priority: P0/P1/P2 | Area: plugins | Labels: feat | Milestone: v0.1.0 | RFC: OQ-011..013 | Task: CTX-

## Changes

-

## Quality gates

- [ ] `just check` passes (lint + fmt-check + manifest + lua + test)
- [ ] `just fmt-check` passes (Prettier 3.9.6)
- [ ] `just lint` passes (markdownlint-cli2 0.23.2)
- [ ] `just install` ran (`bun install --frozen-lockfile`) so the commit-pinned SDK linter is present
- [ ] `just manifest` passes (authoritative SDK `bitty-plugin-lint`, R-SDK-2)
- [ ] `just lua` passes (luaparse 0.3.1)
- [ ] `just test` passes (lua5.4 behavior suite; LuaLS wrapper green or documented skip)
- [ ] `actionlint` passes (actionlint 1.7.12)

## Security impact

<!-- Describe any security or privacy impact, capability changes, or state "None". -->

## Docs synchronization

<!-- List any canonical docs, decision register, open questions, README, CHANGELOG, or release notes updated, or state "None required". -->
