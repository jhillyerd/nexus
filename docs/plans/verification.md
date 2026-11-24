---
title: Nexus — verification strategy (offline invariants, Postgres parity, CI E2E, and cost-bounded LLM checks)
status: proposed
tags: [nexus, verification, testing, kv-cache, postgres, gleam, beam, ci]
updated: 2026-11-24
---

# Verification strategy: proving Nexus's invariants without burning LLM tokens

**Thesis.** Nexus exists to drive LLMs, which are non-deterministic and
expensive to call—yet the LLM itself sits behind one narrow I/O boundary
(`src/nexus/openai.gleam`: JSON request body out, SSE byte stream in).
Roughly 90%+ of what can regress in Nexus—KV-cache byte-prefix stability,
actor lifecycles, Postgres persistence/hydration, bot-channel cascades,
workspace sandboxing, Lustre UI commit/replay parity, MCP/node/TUI
protocols—is **100% deterministic software**.

Today Nexus has a strong test suite (~45 offline `gleam test` files,
`squirrel check` + migrations in CI, deterministic Playwright/node/TUI
suites against a fake Bifrost, and a live `integration.spec.mjs` smoke).
However, four structural verification gaps remain where bugs can pass
every automated check and still break production:

1. **Mock-to-Postgres drift.** `test/store_mock.gleam` is ~2,000 lines of
   hand-maintained simulation of 48 SQL files in `src/nexus/store/sql/`.
   CI already boots `postgres:17` on every PR (`.github/workflows/test.yml`)
   for migrations and `squirrel check` (which prepares/type-checks the
   SQL against Postgres), but Nexus's `store/persist` code paths and
   behavioral contracts never execute against Postgres in tests.
2. **Example-only coverage on state-machine invariants.** Crown-jewel
   invariants (KV-cache prefix monotonicity across restarts, UI ↔ server
   commit/rollback/replay parity, multi-hop bot-channel archive/delete
   trees, arbitrary TCP chunk splits in SSE parsing) are checked on
   hand-picked examples rather than randomized/property-based traces.
   Inspection of `src/nexus/openai.gleam` already surfaces two real
   chunk-boundary hazards that example tests missed:
   - `raw_stream_loop` runs `bit_array.to_string(bits)` on each incoming
     `hackney.Binary(bits)` packet, so a multi-byte UTF-8 codepoint split
     across TCP frames fails the turn with `"stream contained non-UTF-8
     bytes"`.
   - `parse_sse` normalizes `\r\n` only on `incoming` before concatenating
     with `buffer`, so a `\r` / `\n` split across two chunks misses frame
     normalization.
3. **Deterministic E2E suites are manual-only.** `e2e/browser.spec.mjs`,
   `e2e/node.spec.mjs`, and `e2e/tui.spec.mjs` are $0 and deterministic
   (fake Bifrost), yet CI does not run them because the Gleam container
   image has no Node runtime.
4. **Live-traffic KV-cache regressions are silent.** The golden prefix
   fixture (`test/fixtures/m3_cache_thread.json`) proves one captured
   shape offline, but production traffic does not self-verify that
   outgoing requests remain prefix-monotonic.

This plan closes those gaps in descending order of payoff, preserving the
hard repo rule that **`gleam test` stays 100% offline and network-free**
(`AGENTS.md`).

---

## Current baseline (keep intact)

| Layer | Mechanism | Runs in CI? | LLM cost |
| :--- | :--- | :--- | :--- |
| Static / types | `gleam build --warnings-as-errors`, `gleam format --check` | Yes | $0 |
| Schema / SQL bindings | `nexus/store/migrate` + `squirrel check` vs Postgres 17 | Yes | $0 |
| Offline unit & actor tests | `gleam test` against `store_mock` + golden `m3_prefix_test` | Yes | $0 |
| Scripted E2E (UI, node, TUI) | `e2e/{browser,node,tui}.spec.mjs` (fake Bifrost + Postgres) | **No** | $0 |
| Live smoke + cache gate | `e2e/integration.spec.mjs` (real Bifrost + SearxNG, TTFT ratio) | No (by design) | Paid / local GPU |

---

## Ranked payoff matrix

Ordered by **bugs-prevented per unit of engineering effort and ongoing cost**:

| Phase | Workstream | LLM cost | Primary failure classes caught | Effort |
| :--- | :--- | :--- | :--- | :--- |
| **P1** | Differential `Store` contract suite (`store_mock` vs real Postgres 17 in CI) | $0 | SQL CTE bugs, FK cascade mismatches, `ON CONFLICT` / `seq` bugs, `timestamptz` drift, mock-vs-Postgres divergence across all 48 queries | Medium |
| **P2** | Deterministic E2E jobs in CI (`browser`, `node`, `tui` + sandbox probes) | $0 | Real WebSocket/Lustre/shadow-DOM/auth/reconnect/prefix regressions, node protocol & TUI regressions, sandbox leaks | Low–Med |
| **P3** | Property-based & adversarial invariant tests (offline in `gleam test`) | $0 | KV-cache prefix breaks across arbitrary sequences/restarts, UI↔server replay drift, bot-channel tree races, SSE chunk-split & malformed-wire bugs | Medium |
| **P4** | Runtime KV-cache prefix sentinel (always-on, zero wire-byte impact) | $0 | Any real-world prefix divergence in staging/prod caught on the exact turn it happens | Low |
| **P5** | Tiered live-LLM smoke + wire-capture cassettes (nightly / pre-release) | Low / bounded | Real provider SSE dialect drift (vLLM, llama.cpp, OpenAI, OpenRouter), real KV-cache hit-rate regressions, prompt/tool ergonomics | Low–Med |

---

## Phase 1 — Differential `Store` contract suite (`store_mock` vs real Postgres)

### Why this is #1
Every persistence test in `gleam test` (`thread_persistence_test`,
`bot_channels_test`, `store_bot_test`, `store_provider_test`,
`store_node_test`, `workspace_gc_test`) validates Nexus against
`test/store_mock.gleam`, not Postgres. Because `store_mock` is now >2,000
lines of re-implemented SQL logic (recursive `archive.sql` / `unarchive.sql`
CTEs, atomic roster insert in `insert_thread.sql`, `thread_channel` partial
unique index, `prune_never_used.sql` parent-with-children guard, workspace
tombstoning), any subtle discrepancy between SQL and mock is invisible
until manual E2E or production.

Meanwhile, `.github/workflows/test.yml` already starts `postgres:17`,
applies `sql/migrations/`, and runs `squirrel check` on every PR. Running
real queries against that same container costs seconds and $0.

### Design
- **Preserve the `AGENTS.md` offline rule**: `gleam test` must never touch
  a database. Keep the Postgres runner as a dedicated entry point (e.g.,
  `gleam run -m nexus/store/verify` reading `DATABASE_URL`, or a shared
  contract module exercised against `store_mock` in `gleam test` and
  against `nexus/store/persist` via the CLI verifier in CI).
- **One shared contract suite, two backends**: Define a pure contract
  harness taking a `fn() -> Store` factory (which resets state between
  cases — fresh actor for `store_mock`, `TRUNCATE ... CASCADE` for
  Postgres) and asserting identical results across both implementations.
- **High-risk contracts to pin first**:
  1. **Transcript round-trip byte-equality**: plain messages, multi-call
     assistant turns (text + reasoning + timestamp on row 0 only, `''`/NULL
     on continuation rows), idempotent `Commit` replay (`on conflict
     (thread_id, seq) do nothing`), verbatim `tool_args` text preservation
     (no JSON normalization), and `to_request` byte-equality before vs.
     after `LoadMessages` hydration.
  2. **Atomic creation & watermarks**: `insert_thread` with creation-time
     `roster` row + `message_count` alignment so the first write-behind
     `Commit` never skips or duplicates the roster row.
  3. **Bot-channel invariants**: `thread_channel` partial unique index
     `(parent_thread_id, bot_id)`, `find_channel` re-derivation, recursive
     `archive` / `unarchive` CTE over multi-hop channel subtrees,
     `ON DELETE CASCADE` on parent delete, `ON DELETE SET NULL` on bot
     delete, and `prune_never_used` skipping a never-used parent that has
     channel children.
  4. **Workspace lifecycle & GC**: `insert_workspace`,
     `tombstone_workspaces_for_threads`, `tombstone_bot_workspaces`,
     `list_deleted_workspaces`, `delete_workspace` across thread delete and
     boot prune.
  5. **Metadata guards & timestamps**: `auto_title` / `auto_meta_upgrade`
     refusing manually edited titles/tags, `archive` clearing `pinned`,
     `timestamptz` epoch round-trip invariance under non-UTC connection
     `TimeZone` (e.g. `SET TIME ZONE 'Asia/Tokyo'` regression check).
  6. **Providers & nodes**: encrypted key round-trip, delete guards when
     referenced by threads/bots, idle node pruning and grant expiry.

### Exit criteria
- Same contract suite passes against `store_mock` in `gleam test` AND
  against `postgres:17` in `.github/workflows/test.yml`.
- Any behavioral divergence between `store_mock` and `persist` fails CI on
  the PR that introduces it.

---

## Phase 2 — Deterministic E2E & sandbox probes in CI

### Why this is #2
`e2e/browser.spec.mjs`, `e2e/node.spec.mjs`, and `e2e/tui.spec.mjs` already
exist, already use deterministic fake services (`e2e/services.mjs`), and
have caught real integration bugs that unit tests cannot see (auth-gated
static assets, closed shadow roots, reconnect loops, race windows in
utility tag freezing, prefix growth across UI mutations). Yet because CI
doesn't run them, they only catch regressions when someone remembers to
invoke them locally.

### Design
- **Add a second CI job (`e2e`)** in `.github/workflows/test.yml` running on
  `ubuntu-latest` (host runner with Node ≥ 22 — required by `node.spec.mjs`'s
  built-in `WebSocket` per `e2e/README.md` — plus cached Playwright Chromium,
  Erlang/Gleam, and a `postgres:17` service) so the fast `test` container job
  stays unchanged and lean.
- **Run all three $0 deterministic suites**:
  - `node e2e/browser.spec.mjs` (upload `e2e/report.json` on failure)
  - `node e2e/node.spec.mjs`
  - `node e2e/tui.spec.mjs`
- **Extend `e2e/services.mjs` with negative/chaos scenarios** (used by a
  dedicated fault test in `browser.spec.mjs`):
  - Mid-stream disconnect → verify UI rolls back uncommitted lines and
    keeps prior committed transcript intact.
  - Non-200 / rate-limit error → verify clean error rendering and retry
    resending a byte-identical prefix.
- **Deterministic local sandbox escape probes** (Linux CI job or dedicated
  `env` verification script):
  - When `bwrap` (and/or `nono`) is available on the runner, execute
    hostile bash probes through Nexus's real spawn plan verifying:
    - `env` does not contain `DATABASE_URL` or `NEXUS_*` secrets.
    - Reads of sibling thread directories or host sentinel files fail.
    - Background grandchild processes (`sleep 60 &`) are killed cleanly on
      cancel/timeout with no lingering processes.
    - Memory/PID caps trip cleanly and surface as a normal tool error
      without harming the BEAM VM.

### Exit criteria
- Every PR runs `browser.spec.mjs`, `node.spec.mjs`, and `tui.spec.mjs`
  automatically with zero LLM API calls and zero flaky retries.

---

## Phase 3 — Property-based & adversarial invariant verification (offline)

### Why this is #3
Example-based unit tests check the cases the author thought of; property
tests check that **invariants hold across hundreds of generated sequences
and edge-case inputs**, shrinking any failure to a minimal counterexample.
All of Phase 3 runs inside `gleam test` ($0, deterministic seeds, <few
seconds).

Dependency choice: add `qcheck` as a `dev_dependency` (pure Gleam,
deterministic seed support, shrinking, zero runtime impact) — or keep a
tiny internal seeded generator if zero new dev deps is preferred.

### Four target invariant suites

#### 3a. SSE framing & provider-dialect fuzzer (`test/openai_property_test.gleam`)
- **Expose a pure byte-level SSE feeder** in `src/nexus/openai.gleam`
  (operating on `BitArray` chunks rather than `String`, carrying a
  pending incomplete-UTF-8 byte buffer and normalizing `\r\n` *after*
  joining with the carry buffer — fixing both bugs identified above).
- **Chunk-boundary invariance property**: Take any valid SSE response
  containing ASCII, multi-byte UTF-8 (emoji, CJK, smart quotes), `\r\n`
  and `\n` delimiters, reasoning deltas, parallel tool-call deltas, and
  usage blocks. Split the raw `BitArray` at random chunk sizes (including
  1-byte chunks and splits directly inside UTF-8 sequences and `\r\n\r\n`).
  Assert that the emitted `List(StreamEvent)` and timing-independent
  `StreamStats` fields (`token_deltas`, `reasoning_deltas`,
  `tool_call_deltas`, `events_parsed`, `decode_errors`, `saw_done`,
  `usage`) are **identical** to delivering the whole stream in one chunk;
  verify `ttft_ms` and `duration_ms` separately with an injected
  deterministic clock.
- **Hostile/malformed stream property**: Feed truncated streams, garbage
  JSON lines, duplicate/missing tool call IDs, reasoning-only turns,
  whitespace-only assistant content alongside tool calls, and out-of-order
  usage chunks. Assert: never crashes, never produces invalid
  `StreamStats`, and respects `[DONE]` / `decode_errors` accounting.
- **Recorded dialect fixtures** (`test/fixtures/wire/*.sse`): Replay raw
  byte captures from vLLM, llama.cpp, OpenAI, and OpenRouter (e.g.,
  `reasoning_content` vs `reasoning`, usage-with-empty-choices, keyless
  responses).

#### 3b. KV-cache prefix & transcript round-trip property (`test/transcript_property_test.gleam`)
- Generate random multi-turn conversations: arbitrary system prompts,
  user messages, assistant replies, multi-call assistant turns (1..5
  parallel calls with arbitrary non-normalized JSON arg strings, optional
  leading text, optional reasoning), tool results (`ok: True/False`),
  timestamps, bot origins, and roster messages.
- Assert on every step $k$:
  1. `encode(tr_k)` is deterministic across repeated calls.
  2. `encode(tr_k)` preserves `encode(tr_{k-1})`'s serialized messages
     prefix **byte-for-byte** with an unchanged envelope (`model`,
     `stream`, `tools`, `tool_choice`).
  3. Mutating any sidecar (`reasoning`, `timestamps`, `origins`,
     `tool_results`) changes **zero bytes** of `to_request`.
  4. Persisting rows via `store.transcript_rows` and rebuilding via
     `store.transcript_from_rows` produces a **byte-identical** `to_request`
     body.

#### 3c. UI ↔ Server commit/rollback/replay parity (`test/ui_parity_property_test.gleam`)
- Generate random valid loop event sequences (interleaved `ReasoningDelta`,
  `TokenDelta` including bare-newline/whitespace-only bursts,
  `ToolCallDelta`, `ToolCallAssembled`, `ToolResultEvent`, `LoopStatus`)
  terminating in `Done`, `Stopped`, `GuardHit`, or `Failed`, plus optional
  mid-turn `Join` snapshots.
- Drive both the server commit/turn-view model and `nexus/ui` update loop.
- Assert:
  1. Post-turn live UI transcript equals a fresh `Hello` replay of the
     server's committed transcript (no resurrected empty pills, no
     dropped reasoning/timestamps/tool statuses, exact rollback on
     `Failed`, kept rounds on `GuardHit`).
  2. Any mid-turn `Join` replay produces the same visible items as a
     client that stayed connected from turn start.
  3. Hostile `<script>` / HTML strings injected into any generated text,
     tool arg, or tool result never produce raw HTML nodes.

#### 3d. Bot-channel & thread-registry state machine (`test/registry_property_test.gleam`)
- Generate random command sequences over `thread_registry` + `store_mock`:
  `Create`, `Deliver` (valid, self, archived sender, archived target,
  hop-limit exceeded, store lookup error), `Archive`, `Restore`, `Delete`,
  `PruneNeverUsed`, and `SimulatedRestart` (stop registry, boot fresh
  registry over the same `store_mock`).
- Assert invariants after **every** command:
  - `List` never contains any thread with `parent_thread_id != None`.
  - No live or dormant thread references a non-existent parent.
  - `(parent_thread_id, bot_id)` has at most one channel across restarts
    (re-derivation never duplicates).
  - Archived threads (and their entire descendant subtree) refuse
    deliveries from both sender and target sides.
  - After `SimulatedRestart`, the hydrated registry state matches the
    pre-restart durable state.

### Exit criteria
- All four property suites run in `gleam test` with fixed reproducible
  seeds (and log the seed on failure so any counterexample is immediately
  replayable).
- The two real chunk-boundary bugs in `src/nexus/openai.gleam` are fixed
  and permanently pinned by 3a.

---

## Phase 4 — Runtime KV-cache prefix sentinel (zero-token production verification)

### Why this is #4
Offline tests prove the code paths we tested; a runtime sentinel proves
**every real conversation in staging and production** upholds the
KV-cache contract at zero extra LLM cost.

### Design
- In `src/nexus/transcript.gleam` (or `src/nexus/thread.gleam` /
  `src/nexus/loop.gleam`), add a small pure helper that extracts and
  hashes two independent regions of the serialized request body using
  `gleam_crypto` SHA-256:
  1. `envelope_hash`: SHA-256 of the serialized request with the
     `messages` array removed (covering `model`, `stream`, `tools`,
     `tool_choice`, and any other top-level envelope fields).
  2. `messages_prefix_hash` + `messages_prefix_len`: SHA-256 and byte
     length of the serialized `messages` array up to the end of its last
     element, **excluding the closing `]`** (so appending a message
     extends the exact byte prefix with `,` + new element(s) + `]`).
- Store `#(envelope_hash, messages_prefix_len, messages_prefix_hash)`
  from the previous turn in the live thread actor's ephemeral state
  (never persisted, never encoded into requests).
- Before dispatching each subsequent request on a thread:
  - Verify that `envelope_hash` is identical to the stored value, and
    that the first `messages_prefix_len` bytes of the new serialized
    `messages` array (excluding its closing `]`) hash identically to
    `messages_prefix_hash` (with the next byte being `,` on growth or `]`
    on an unchanged retry). Then update the stored `messages_prefix_len`
    and `messages_prefix_hash` from the new request's `messages` slice
    (again excluding the closing `]`).
  - On mismatch: emit a structured `ERROR` log (`event=kv_prefix_broken`,
    `thread_id`, `turn`, `reason`) and increment an observable counter in
    `GET /threads/<id>/state` (debug dump). Do **not** abort the user's
    turn in production (fail-open for UX, fail-loud in observability;
    optionally assert-fail in E2E mode via env flag so E2E catches any
    violation instantly).
- Keep the check strictly read-only on the already-serialized request body
  so it cannot alter a single wire byte.

### Exit criteria
- Zero wire-byte change (existing `m3_prefix_test` unchanged).
- Deliberately mutating an earlier message in a unit test trips
  `kv_prefix_broken` immediately.
- Running `e2e/browser.spec.mjs` with strict sentinel mode enabled passes
  with zero violations.

---

## Phase 5 — Tiered live-LLM verification & wire-capture cassettes

### Why this is #5
Some bugs only exist at the real model boundary: a provider upgrade
changing SSE chunk fields, real KV-cache eviction or tokenization breaks
on vLLM/llama.cpp, or a tool schema / system prompt change confusing real
models. The goal is to verify those **cheaply, on a cadence, using
structural and statistical gates instead of brittle string checks**.

### Design
- **Cadence**: Never per-commit. Run manually before releases, when
  modifying `openai.gleam` / `transcript.gleam` / tool schemas / utility
  prompts, or on a nightly schedule against local/cheap models (Bifrost →
  llama.cpp / vLLM, or a small hosted model with strict
  `max_completion_tokens` caps).
- **Wire-capture recorder**: Add an opt-in capture flag (e.g.,
  `NEXUS_CAPTURE_WIRE_DIR` in E2E / proxy layer in `integration.spec.mjs`,
  never in production runtime) restricted strictly to **synthetic smoke
  prompts**, never live user conversations. Before committing any
  captured SSE stream into `test/fixtures/wire/`, run an explicit
  redaction/scrubbing pass (stripping request/response headers, API keys,
  provider/internal hostnames, org IDs, and any unexpected secrets) so
  only sanitized synthetic fixtures enter version control and serve as
  permanent $0 offline regression inputs in Phase 3a.
- **Invariant-based live gates** (extending `e2e/integration.spec.mjs`):
  - **Streaming & reasoning**: at least one real turn emits content (and
    reasoning on reasoning-capable aliases), completes cleanly, and
    survives reload.
  - **Tool round-trip**: real `web_search` and `http_fetch` tool calls
    parse, execute, persist, and replay as completed cards (retried up to
    3× for model non-determinism, logged transparently).
  - **Utility resilience**: real utility title/tags call lands valid
    metadata (or degrades cleanly without crashing/corrupting the thread)
    while preserving the prefix branch contract.
  - **KV-cache metric gate**: `cached_tokens / prompt_tokens >= 0.90` on
    warm turns and median warm/cold TTFT ratio `<= 0.3`, plus **zero**
    Phase 4 runtime prefix-sentinel alerts across the run.
- **Optional future extension (agent evals)**: Only when tuning agent
  prompts, `codemode` Lua ergonomics, or workspace tool descriptions—add a
  tiny suite of 5–10 objective-outcome tasks (graded deterministically by
  exit code / file contents, never LLM-as-judge) run $k$ times against a
  cheap model with a pass-rate gate (e.g., ≥ 85%).

---

## Explicit non-goals

- **No LLM calls in PR CI.** Every PR check must remain $0, fast, and
  deterministic.
- **No live Postgres in `gleam test`.** Keep `gleam test` offline and
  network-free per `AGENTS.md`; real-Postgres parity runs in its own
  explicit command and CI step.
- **No LLM-as-a-judge assertions for core infrastructure.** Nexus's
  correctness is defined by deterministic contracts (wire bytes, SQL
  state, actor invariants, DOM safety, TTFT/cache metrics), not prose
  quality.
- **No heavyweight formal methods upfront.** Reserve TLA+ / Quint only if
  Phase 3d stateful property testing fails to flush out a recurring
  multi-actor concurrency bug.

---

## Recommended execution order

1. **Start with Phase 1 (Differential Store Contract Suite)** — highest
   bug-finding probability per hour, leverages CI's existing `postgres:17`
   container, and protects all 48 SQL queries against `store_mock` drift.
2. **Immediately follow with Phase 2 (CI E2E job)** — turns existing
   high-signal Playwright/node/TUI suites into automatic PR gates.
3. **Add Phase 3a (SSE chunk-boundary property test + fix the two
   `openai.gleam` framing bugs)** — small, self-contained win that fixes
   real production UTF-8/CRLF framing hazards.
4. **Roll out Phases 3b–3d (KV-cache, UI parity, registry state-machine
   properties) and Phase 4 (runtime prefix sentinel)** incrementally as
   companion guards on future feature work.
5. **Maintain Phase 5 (live smoke + wire captures)** as the pre-release /
   provider-change checkpoint.
