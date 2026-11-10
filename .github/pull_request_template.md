<!-- Title: conventional-commit style (feat:|fix:|docs:|chore:|refactor:|test:)
     — it becomes the squash-merge commit message. -->

## What

<!-- One paragraph: what changed, at what scope. For wide changes, one bullet or
     table row per layer (schema / store / modules / wire+UI / docs). Reference
     the plan it implements: docs/plans/<name>.md -->

## Why

<!-- The motivation and the decision it honours — plan doc, issue, or prior
     discussion. Note rejected alternatives only if they shaped the design. -->

## Breaking changes

<!-- State explicitly, even when none. "None" is written as e.g.
     "None — nexus is undeployed, so this is a plain edit per AGENTS.md."
     Otherwise: env vars, schema (idempotent on next migrate), API/ws routes. -->

Closes # <!-- issue number, or delete the line; GitHub closes it on merge -->

## Invariants honoured

<!-- Required for PRs touching schema, transcript/request encoding, the agent
     loop, or UI commit/replay paths; delete if not applicable. Address the ones
     you touch, citing the test that pins each:
- KV-cache contract: envelope (model/stream/tools/tool_choice) unchanged;
  m3_prefix_test green — fixture untouched, or re-captured via the e2e capture
  step (never hand-edited)
- gleam test stays offline/network-free: new tests go through the store mock seam
- Hostile text: rendered as Lustre text nodes, no innerHTML / unsafe HTML
- Schema: singular unquoted-safe names, tool_args stays text, timestamptz,
  message_count/seq semantics (AGENTS.md)
- Pico-first styling, self-hosted assets only (no-CDN guard test green) -->

## Tests

<!-- Don't restate what the green checks prove — CI already runs gleam test,
     squirrel check, and gleam format --check. Report the two things CI can't:
     what coverage changed, and what you verified outside the regular suites. -->

**Coverage** — <base> → <head> tests. What the new tests pin, by behaviour,
naming the invariant each holds. Changes pinned by existing tests: name them.
Docs-only: say so here, and put what you verified under Beyond CI.

**Beyond CI** — delete lines that don't apply:
- e2e browser suite: run / not run, and why (never runs in CI)
- live migration: idempotent re-run on an existing DB (CI only applies to a
  fresh one)
- manual visual sweep: light/dark/mobile screenshots
- repeated-run stability, when this PR touches a flake
