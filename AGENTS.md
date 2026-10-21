# AGENTS.md

Repo guidance for coding agents working on nexus. Sources of truth for the
"why" behind these rules: `docs/plans/p2-verification.md` (schema) and
`docs/plans/completed/m3-verification.md` (UI, agent loop, KV-cache
verification).

## Database schema naming (decided, follow it)

The persistence layer lives in `sql/schema.sql` + `src/nexus/store/sql/`.

- **Table names are singular** — `session`, `session_message`. Each row is
  one entity; this matches the Postgres system catalog's own convention
  (`pg_class`, `pg_proc`, `pg_type`). Do not pluralize new tables.
- **Child/link tables are named after their parent plus their role** —
  `session_message`, not `message`. A generic name hides the FK link as
  the schema grows; `session_message` makes it obvious.
- **Verify a name is unquoted-safe before using it.** `session` is a
  *non-reserved* keyword in Postgres and is used unquoted everywhere. Keep
  that property for new table/column names (check the keyword list, or
  just try it against a live database).
- **Indexes follow `<table>_<purpose>`** — `session_recency`,
  `session_tags`.
- **Foreign keys are `<parent>_id`** (`session_message.session_id`).
- Renaming after deployment requires a migration; renames while the schema
  has no deployed data (pre-merge) are just edits — that is how the
  `sessions`/`messages` → `session`/`session_message` rename landed.

## Schema invariants (hard constraints — do not break)

- **`session_message.tool_args` is `text`, never `jsonb`.** jsonb
  normalizes JSON (sorted keys, stripped whitespace); tool-call argument
  strings sit above the request tail, so normalized values would change
  request bytes and violate the KV-cache contract
  (`docs/plans/mvp-requirements.md`). Byte-stability beats queryability
  here.
- **Timestamps are `timestamptz`.** Read as `extract(epoch from x)::int8`
  (epoch seconds, the Phase 1 wire format), write via `to_timestamp($1)`
  or server-side `now()`. Never introduce naive `timestamp` columns —
  `now()` into one shifts by the session timezone under config drift
  (measured +9h; see `spikes/d_pg_roundtrip`).
- **`session.message_count` counts messages including the system prompt**
  (Phase 1 `SessionSummary` semantics) and doubles as the write-behind
  watermark: an assistant message with N tool calls is ONE message but N
  `session_message` rows, so a row count would undercount.
- **`seq` is the 0-based `session_message` row index**; inserts carry
  `on conflict (session_id, seq) do nothing` so crash-recovery replays are
  idempotent. An assistant message with N calls is N consecutive rows and
  the first row carries the message text (`''` on continuation rows).

## Changing the schema or queries

1. Edit `sql/schema.sql` idempotently (`IF NOT EXISTS`).
2. Re-apply: `gleam run -m nexus/store/migrate` (needs `DATABASE_URL`;
   `docker compose up -d` provides the local database on `127.0.0.1:5433`).
3. Edit the queries in `src/nexus/store/sql/*.sql` (one query per file,
   file name = generated function name), then regenerate:
   `gleam run -m squirrel` — the generated `sql.gleam` is committed.
4. CI runs `squirrel check` and fails on stale generated code.
5. `gleam test` must stay offline/network-free: persistence tests go
   through the mockable seam (`src/nexus/store.gleam`,
   `test/store_mock.gleam`), never a live database.

The runner's statement splitter (`statements` in `migrate.gleam`) is
quote-aware: single/double quotes, dollar quotes (`$$…$$`, `$tag$…$tag$`),
`--` lines, and nested `/* */` comments are understood, so a `;` inside a
`DO` block, `CREATE FUNCTION` body, or literal does not split a statement.
Unit tests: `test/migrate_test.gleam`.

## UI and agent-loop invariants (hard constraints — do not break)

Pinned by the M3 browser suite (`docs/plans/completed/m3-verification.md`);
`test/ui_test.gleam` keeps most of them green offline.

- **Model and tool output is hostile text.** Everything the UI renders is
  Lustre text nodes — no `innerHTML` anywhere (the module doc in
  `src/nexus/ui.gleam` is the contract). Tool arguments and results appear
  only as truncated, inert text previews. Regression tests feed
  `<script>` payloads; keep them passing.
- **UI display state mirrors the server's commit rules.** A failed turn
  commits nothing server-side, so the UI rolls its uncommitted lines back
  to the user line; a guard-tripped turn keeps its committed rounds and
  final text. If you change the loop's commit rules, change the UI
  rollback with it (`test/ui_test.gleam` pins both sides).
- **One frozen toolset for every session.** The registry builds the
  agent-loop runner once at boot
  (`session.agent_runner(cfg.max_tool_iterations, tools.default(cfg))`).
  Never add per-session tool configurations — an identical
  `tools` / `tool_choice` envelope across sessions is part of the
  KV-cache contract.
- **The shadow root stays open** (`open_shadow_root(True)` in
  `src/nexus/ui_runtime.gleam`), pierceable by the browser suite and
  devtools. A closed root broke the whole browser suite once
  (m3-verification §1, bug 2).
- **One Lustre runtime per `/ws` connection.** `ui_runtime.init_socket`
  starts a per-connection runtime (`lustre.start_server_component`)
  linked to its socket — no shared component child in `boot.gleam`, no
  cross-client model, so tabs never mirror each other's selection or
  panels. The client's last-selected session rides the `/ws` route query
  (`ui.Flags.session`, persisted by the page shell's `session_js`), which
  is what re-opens the same session after a reload; `GotEvents` is the
  connect point (no ClientConnected/Disconnected msgs). Do not
  reintroduce shared UI state across connections — the settings surface
  builds on per-client state.

## Changing the transcript / request-encoding path

`test/m3_prefix_test.gleam` is the offline golden: it replays the archived
real session in `test/fixtures/m3_cache_session.json` turn-by-turn through
`nexus/transcript` (the single encode path) and asserts, per turn
boundary, byte-deterministic re-encoding and suffix-only request growth
with an unchanged envelope (`model`, `stream`, `tools`, `tool_choice`).

If you legitimately change the encoding, this test fails **by design**:
re-capture the fixture from a real session via the integration smoke's
`capture` step (`node e2e/integration.spec.mjs`, which writes
`e2e/cache-session.json` — the committed fixture is a copy), never
hand-edit the JSON. The live half of the contract is that suite's cache
gate: warm/cold TTFT median ratio ≤ 0.3.
