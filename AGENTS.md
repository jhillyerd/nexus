# AGENTS.md

Repo guidance for coding agents working on nexus. The schema rules below
carry their own rationale; the "why" behind the UI, agent loop, and
KV-cache verification lives in `docs/plans/completed/m3-verification.md`.

## Database schema naming (decided, follow it)

The persistence layer lives in `sql/schema.sql` + `src/nexus/store/sql/`.

- **Table names are singular** — `thread`, `thread_message`. Each row is
  one entity; this matches the Postgres system catalog's own convention
  (`pg_class`, `pg_proc`, `pg_type`). Do not pluralize new tables.
- **Child/link tables are named after their parent plus their role** —
  `thread_message`, not `message`. A generic name hides the FK link as
  the schema grows; `thread_message` makes it obvious.
- **Verify a name is unquoted-safe before using it.** `thread` (like
  `provider`) is not a Postgres keyword at all — every table and column
  name is used unquoted. Keep that property for new table/column names
  (check the keyword list, or just try it against a live database).
- **Indexes follow `<table>_<purpose>`** — `thread_recency`,
  `thread_tags`.
- **Foreign keys are `<parent>_id`** (`thread_message.thread_id`).
- Renaming after deployment requires a migration; renames while the schema
  has no deployed data (pre-merge) are just edits — that is how the
  `sessions`/`messages` → `session`/`session_message` rename landed, and
  later the `session`/`session_message` → `thread`/`thread_message` rename
  (vocabulary alignment ahead of the bots/profiles system: a thread is the
  chat entity; "session" stays free for connection/auth scopes).

## Schema invariants (hard constraints — do not break)

- **`thread_message.tool_args` is `text`, never `jsonb`.** jsonb
  normalizes JSON (sorted keys, stripped whitespace); tool-call argument
  strings sit above the request tail, so normalized values would change
  request bytes and violate the KV-cache contract
  (`docs/plans/mvp-requirements.md`). Byte-stability beats queryability
  here.
- **Timestamps are `timestamptz`.** Read as `extract(epoch from x)::int8`
  (epoch seconds, the Phase 1 wire format), write via `to_timestamp($1)`
  or server-side `now()`. Never introduce naive `timestamp` columns —
  `now()` into one shifts by the Postgres connection's `TimeZone` under
  config drift (measured +9h in the Phase 2 round-trip spike).
- **`thread.message_count` counts messages including the system prompt**
  (Phase 1 `ThreadSummary` semantics) and doubles as the write-behind
  watermark: an assistant message with N tool calls is ONE message but N
  `thread_message` rows, so a row count would undercount.
- **`seq` is the 0-based `thread_message` row index**; inserts carry
  `on conflict (thread_id, seq) do nothing` so crash-recovery replays are
  idempotent. An assistant message with N calls is N consecutive rows and
  the first row carries the message text (`''` on continuation rows).
- **`thread_message.reasoning` is display-only chain of thought** (nullable
  `text`, `''`-sentinel → NULL like `insert_provider.sql`'s key pattern).
  It rides a sidecar on the transcript (`transcript.reasoning_at`), never
  `messages`, so it is structurally unable to change a request byte; a
  turn that produced only reasoning commits nothing (no empty assistant
  messages — the pre-reasoning `"" -> tr` guard still holds).
- **`thread_message.created_at` is display-only wall-clock** (nullable
  `timestamptz`, read through the `coalesce(..., 0)` sentinel because the
  wire protocol reports expression columns as NOT NULL —
  `load_messages.sql`). It rides the transcript's timestamp sidecar
  (`transcript.stamp` / `transcript.stamped_at`), never `messages`, and
  drives the chat log's per-message ages. NULL is a live state, not
  legacy: continuation rows of a multi-call assistant message are
  unstamped by design (the stamp rides the message's first row, like
  content/reasoning) and render without their own timestamp.
- **One clock for message timestamps.** The sidecar stamp set at
  append time is the ONLY source: terminal events carry
  `transcript.last_text_stamp`, the loop broadcasts the flush stamp on
  `ToolCallAssembled` (the UI's delta-time flush commit restamps from
  it — that commit is deliberately unstamped, never UI-clock), and
  replay events carry `stamped_at`. The UI never reads a clock to stamp
  a line.

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

Pinned by the e2e browser suite (`docs/plans/completed/m3-verification.md`);
`test/ui_test.gleam` keeps most of them green offline.

- **Model and tool output is hostile text.** Everything the UI renders is
  Lustre text nodes — no `innerHTML` anywhere (the module doc in
  `src/nexus/ui.gleam` is the contract). Tool arguments and results appear
  only as truncated, inert text previews. Regression tests feed
  `<script>` payloads; keep them passing.
- **UI display state mirrors the server's commit rules.** A failed turn
  commits nothing server-side, so the UI rolls its uncommitted lines back
  to the user line; a guard-tripped turn keeps its committed rounds and
  final text. Reasoning follows the same rule: the live "thinking" buffer
  commits only when the assistant output it preceded commits, and a
  reasoning-only turn discards it. If you change the loop's commit rules,
  change the UI rollback with it (`test/ui_test.gleam` pins both sides).
- **Mid-turn joins replay the in-flight turn.** The worker owns the
  extended transcript and only installs it at `WorkerDone`, so a plain
  replay of the committed transcript shows a running turn's rounds as
  vanished (refresh or thread switch mid-turn loses the chips). The
  thread actor therefore keeps a display-only mirror (`turn_view` in
  `src/nexus/thread.gleam`) rebuilt from the same events it broadcasts,
  and `Join` replays it while a turn is in flight. It is display-only —
  never encoded into a request, dropped at `WorkerDone`/`WorkerDown` —
  so the KV-cache byte contract is structurally unaffected. Assistant
  text that renders to nothing under markdown (a model's bare newlines
  beside tool calls) is skipped by BOTH the live commit and the replay
  (`AssistantFull` / `commit_bubble` in `src/nexus/ui.gleam`) — one
  skipped shape per path, or a reload resurrects the empty pill.
- **One frozen toolset for every thread.** The registry builds the
  agent-loop runner once at boot
  (`thread.agent_runner(cfg.max_tool_iterations, tools.default(cfg))`).
  Never add per-thread tool configurations — an identical
  `tools` / `tool_choice` envelope across threads is part of the
  KV-cache contract.
- **The shadow root stays open** (`open_shadow_root(True)` in
  `src/nexus/ui_runtime.gleam`), pierceable by the browser suite and
  devtools. A closed root broke the whole browser suite once
  (m3-verification §1, bug 2).
- **One Lustre runtime per `/ws` connection.** `ui_runtime.init_socket`
  starts a per-connection runtime (`lustre.start_server_component`)
  linked to its socket — no shared component child in `boot.gleam`, no
  cross-client model, so tabs never mirror each other's selection or
  panels. The client's last-selected thread rides the `/ws` route query
  (`ui.Flags.thread`, persisted by the page shell's `thread_js`), which
  is what re-opens the same thread after a reload; `GotEvents` is the
  connect point (no ClientConnected/Disconnected msgs). Do not
  reintroduce shared UI state across connections — the settings surface
  builds on per-client state.

## UI styling and static assets

Pico CSS is the default styling layer (vendored at `priv/pico.min.css`,
served from `/css/pico.min.css`). Adopting it changed none of the UI hard
invariants above — hostile text stays Lustre text nodes, the shadow root
stays open, one runtime per connection.

- **Style Pico-first.** Reach for Pico's semantic elements, classes, and
  `--pico-*` tokens before writing new CSS — bare semantics get styled
  with zero classes, which is why upcoming markdown rendering will need
  no styling work. Hand-written CSS in `page.gleam`'s `css()` is the
  escape hatch: app-shell grid, chat chrome, and overrides — not a
  parallel design system. Adapt the look via the `:root, :host` token
  block (font size, radii, primary colors), not via more rules.
- **Two cascade traps when overriding Pico** (both bit during adoption;
  the comments in `css()` carry the details): token overrides must be
  restated at Pico's theme-rule specificity (`:root:not([data-theme=…])`)
  or dark mode silently reverts to Pico defaults; bare-element overrides
  must be `#app`-prefixed, because Pico matches `button`/`input` twice
  (element *and* `[type=…]` attribute selectors at 0,1,0) and an
  unprefixed reset loses the cascade.
- **Self-hosted assets only — no public CDNs, ever.** Everything the UI
  loads is vendored in-repo and served by nexus itself, so the UI works
  fully offline. New static assets follow the `runtime.mjs` /
  `pico.min.css` pattern: file under `priv/`, authed route in `web.gleam`
  (router **and** `requires_auth`), token on the query string,
  cache-friendly headers. `m3_page_no_cdn_urls_test` guards the shell
  against absolute and protocol-relative external URLs.
- **Upgrading Pico** = replace `priv/pico.min.css` (keep the provenance
  header: version, source URL, MIT), verify token names against the new
  file, and re-run the e2e browser suite — the offline suite cannot see
  visual regressions.

## Changing the transcript / request-encoding path

`test/m3_prefix_test.gleam` is the offline golden: it replays the archived
real thread in `test/fixtures/m3_cache_thread.json` turn-by-turn through
`nexus/transcript` (the single encode path) and asserts, per turn
boundary, byte-deterministic re-encoding and suffix-only request growth
with an unchanged envelope (`model`, `stream`, `tools`, `tool_choice`).

If you legitimately change the encoding, this test fails **by design**:
re-capture the fixture from a real thread via the integration smoke's
`capture` step (`node e2e/integration.spec.mjs`, which writes
`e2e/cache-thread.json` — the committed fixture is a copy), never
hand-edit the JSON. The live half of the contract is that suite's cache
gate: warm/cold TTFT median ratio ≤ 0.3.

## e2e browser suite (per-worktree setup)

`e2e/` is validation-only and its `node_modules` is not committed, so a
fresh worktree fails with `Cannot find module 'playwright'` until you run
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm --prefix e2e install` — sub-second,
thanks to npm's global tarball cache. The Chromium binary is never
per-worktree: it is shared machine-wide by revision at
`~/.cache/ms-playwright` (the pinned playwright 1.64.1 uses
`chromium-1248`), or comes from nixpkgs via `NIX_PLAYWRIGHT_CHROMIUM` in
the `e2e/playwright.nix` shell. Do not `npx playwright ...` ad hoc — it
fetches latest and drops a second, unpinned browser revision into the
shared cache. Postgres/migrate preconditions: `e2e/README.md`.

## Gleam API pitfalls (training data lags the pinned toolchain)

A flash model hit all three of these repeatedly during the issue #88
worker migration; each is checkable in seconds against the repo. The
pinned gleam_stdlib is 1.0.5 (`manifest.toml`) — confirm API existence in
`build/packages/gleam_stdlib/src/gleam/…`, not in training data.

- **`io.debug` does not exist.** The pinned `gleam/io` exports only
  `print`/`println` (plus `_error` variants); debug printing moved to the
  `echo` keyword expression (Gleam v1.9:
  https://gleam.run/news/hello-echo-hello-git/) — `echo some_expression`
  prints the value with file:line to stderr. Use `io.println` for
  deliberate output.
- **`string.find` does not exist.** Use `string.contains` (Bool) or
  `string.split_once` instead. (The `string.find` text in
  `src/nexus/codemode.gleam` is Lua inside generated codemode scripts,
  not Gleam.) Broader lesson: before using a less-common stdlib function,
  check it exists under `build/packages/gleam_stdlib/src/gleam/…` first.
- **`process.receive(subject, timeout)` only works on a Subject owned by
  the calling process** — the process that created it via
  `process.new_subject`. A spawned worker (`process.spawn_unlinked`)
  receiving on the test's subject panics outright (gleam_erlang 1.3.0:
  "Cannot receive with a subject owned by another process"). Invert the
  protocol: the worker creates its own gate subject and sends it back to
  the test, which answers through it — the `gated_runner` pattern in
  `test/thread_test.gleam` (its doc comment states the rule; the
  gate-fetcher landing in `test/ui_test.gleam` with issue #88 uses the
  same protocol). This one cost the session ~15 minutes of 60-second
  timeout panics before diagnosis.
