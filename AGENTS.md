# AGENTS.md

Repo guidance for coding agents working on nexus. The schema rules below
carry their own rationale; the "why" behind the UI, agent loop, and
KV-cache verification lives in `docs/plans/completed/m3-verification.md`.

## Database schema naming (decided, follow it)

The persistence layer lives in `sql/migrations/` + `src/nexus/store/sql/`.

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
- Schema changes (including renames) land as new sequential migrations
  under `sql/migrations/` — never edit an already-applied migration.
  (`0001_initial.sql` is the squashed baseline snapshot from the early
  pre-deployment phase when `sessions`/`messages` → `session`/`session_message`
  → `thread`/`thread_message` were edited in place.)

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
- **`thread.parent_thread_id` is routing/display metadata, never a
  request byte** (bot-channels plan, docs/plans/bot-channels.md). It is
  `NULL` on every ordinary thread; `ON DELETE CASCADE` is decided (a
  channel is meaningless outside its parent — `SET NULL` would resurrect
  orphaned channels into the sidebar). The partial unique index
  `thread_channel` on `(parent_thread_id, bot_id)` IS the channel
  identity: one DM thread per (parent, target bot), and the guarantee
  `find_channel` re-derivation matches unambiguously against.
- **Every thread is created FROM a bot (threads are bot-only).**
  The provider+model create shape is gone: the UI's compose-new flow
  creates on first send from the composer's bot picker, HTTP
  `POST /threads` accepts only `{"bot": id}` (a provider/model body is
  a 400), and `thread_registry.NewThread.bot_id` is a required `String`
  (blank → `CreateError.BotRequired`). The bot is a creation-time
  template — the frozen columns are still the thread's truth — and the
  column stays nullable (`ON DELETE SET NULL` keeps a deleted bot from
  orphaning anything); the invariant lives at CREATION, not in the
  schema. Consequence: the default toolset sentinel resolves to the
  default set PLUS `bot_message` + `list_bots` for every create (each
  thread carries a bot identity).

## Bot channel invariants (Phase 1 shipped)

`docs/plans/bot-channels.md` carries the design and as-built deltas;
the rules that bite silently:

- **Channels are second-class, and the sidebar filter is REGISTRY-SIDE,
  never SQL.** The `List` projection excludes threads with a parent, so
  the store stays complete and `Get` / `GET /threads/<id>/state` keep
  answering for channels (the debug dump is never a UI data source).
  Utility titles/tags never run on a channel: `create_dm` persists the
  target bot's name as the title directly, the actor's `arm_utility`
  no-ops on `spec.parent_thread_id`, and the guarded `AutoTitle` ask
  refuses a non-empty title anyway (the heuristic skip).
- **The `dm` map is keyed `(from_thread_id, target_bot_id)`** — one
  channel per parent thread, so parallel parents neither serialize on a
  pair-wide busy lock nor share a transcript (#123). A map miss
  RE-DERIVES through the store (`find_channel`) before creating: a hit
  repoints the map and delivers; `Ok(None)` creates; a store ERROR
  refuses retryably ("target lookup failed; try again") and NEVER falls
  through to creation — a transient outage must not duplicate a channel
  that may well exist. A STALE HIT (entry present, thread gone from
  both dicts) is not a creation license either: the entry is dropped
  and the miss path runs — the store may still hold the row, so
  re-derivation answers, never a blind `create_dm`.
- **A channel create that cannot persist is REFUSED, never started**
  (CodeRabbit PR review): without the parent row the channel is
  unreachable by re-derivation, so a failed insert answers
  `ChannelPersistFailed` ("target bot's thread could not be started")
  instead of starting an unpersisted phantom ordinary thread behind a
  Delivered reply. Ordinary (parent-less) creates keep the Phase 1
  unpersisted fallback. Unknown SENDERS are refused too ("sender thread
  is gone", beside the archive guard first in the chain): Delete stops
  the actor but not an in-flight turn worker, and the parent FK would
  refuse anything it tried to create anyway. Dormant senders count as
  known (a worker orphaned by a registry restart delivers normally).
- **Cross-registry name asks resolve the NAMED OWNER first, and the
  send itself runs rescued.** `try_send_named` (the provider adapter's
  `try_send` discipline): `process.named` answers instantly for a name
  nobody holds, and the rescued send closes the check→send window no
  liveness check can — a bot registry or descendant actor dying
  mid-window is "best not sent", never a crashed registry. All three
  named-subject sends ride it: `sender_name_ask` (channels arm +
  delivery path), the archive notify, and the delete cascade's
  `thread.Stop`.
- **The archive cascade is PERSISTENCE-FIRST.** ONE idempotent recursive
  store update (archive.sql's CTE over `parent_thread_id`) is the
  authority — the registry must NOT inherit the memory-first
  `write_through_or_log` habit here: a logged failure with memory
  updated anyway would hydrate back ACTIVE after restart. On store
  success the registry syncs memory (subtree metas + live-actor notify
  via bounded ask — the actor answers `thread.SetArchived` even MID-TURN)
  and never `thread.Stop`s: an in-flight turn is preserved. A notify
  failure (the actor down, or unresponsive within the bounded ask) is
  tolerated, never retried in place — the actor's replacement
  rehydrates FROM THE STORE, so it is born with the right archived
  state; dead or failed-start records are skipped outright (a send to
  an unregistered name would crash the registry). Restore is the
  symmetric cascade.
- **Deliveries refuse archived threads on BOTH ends.** Archived target:
  `deliver_to_thread`'s existing refusal, durable through restart (a
  re-derived archived row is refused, never resurrected). Archived
  sender: the guard FIRST in the delivery chain ("sender thread is
  archived") — archive does not cancel turns, so an in-flight turn can
  still call `bot_message`, and without the check `create_dm` would open
  a brand-new ACTIVE channel under an archived parent. Archived CHANNELS
  additionally refuse their own human Sends at the actor
  (`SendResult.Refused`); ordinary archived threads refuse nothing there
  (their human Send behavior is unchanged).
- **Delete cleanup is transitive.** Hop chains make channels of
  channels, and the FK deletes the whole subtree — so the registry's
  cleanup walks `parent_thread_id` to a fixpoint (live + dormant),
  demonitors and kills every live descendant, drops each one's
  records/dormant summaries and `dm` entries, then deletes the root (the
  store CASCADE removes the rows). The same try_send discipline as the
  archive notify applies on the way down: failed-start and queued-DOWN
  records are skipped (the kill is the real stop), never crashed into.
- **The boot sweep never takes a parent with channel children.**
  `prune_never_used.sql` carries `not exists (select 1 from thread c
  where c.parent_thread_id = thread.id)`: a parent looks never-used
  until its first turn commits, so a crash mid-first-turn plus a late
  restart would otherwise sweep it and CASCADE-delete a channel whose
  history is long since durable (CodeRabbit PR review).

## Changing the schema or queries

1. Add a new sequential migration under `sql/migrations/` named
   `NNNN_<snake_case>.sql` (next 4-digit version number, e.g.
   `0002_workspace_sandbox.sql`). **Never edit an already-applied
   migration** — the runner tracks applied versions and SHA-256 checksums
   in `schema_migration` (singular, unquoted-safe, `timestamptz`) and
   refuses modified files. Each pending migration runs once inside a
   PostgreSQL transaction alongside its `schema_migration` insert, so
   ordinary `ALTER TABLE` / `CREATE TABLE` / backfill DDL needs no
   idempotency shims. Pending gaps from parallel branches (a lower
   version merged after a higher one was applied locally) are applied in
   ascending version order, so keep independent migrations order-tolerant.
2. Apply: `gleam run -m nexus/store/migrate` (needs `DATABASE_URL`;
   `docker compose up -d` provides the local database on `127.0.0.1:5433`).
3. Edit the queries in `src/nexus/store/sql/*.sql` (one query per file,
   file name = generated function name), then regenerate:
   `gleam run -m squirrel` — the generated `sql.gleam` is committed.
4. CI runs `gleam run -m nexus/store/migrate` and `squirrel check` (fails
   on stale generated code).
5. `gleam test` must stay offline/network-free: persistence tests go
   through the mockable seam (`src/nexus/store.gleam`,
   `test/store_mock.gleam`), never a live database.

The runner's statement splitter (`statements` in `migrate.gleam`) is
quote-aware: single/double quotes, dollar quotes (`$$…$$`, `$tag$…$tag$`),
`--` lines, and nested `/* */` comments are understood, so a `;` inside a
`DO` block, `CREATE FUNCTION` body, or literal does not split a statement.
Unit tests (splitter, filename/checksum validation, planner, and live
`sql/migrations/` checks): `test/migrate_test.gleam`.

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
- **One frozen toolset per thread** (amended by bots plan P2;
  `docs/plans/completed/bots.md`; amended again — threads are bot-only).
  The toolset is persisted at creation as resolved manifest entries
  (the default set's, or the creating bot's; never NULL-for-default)
  and resolved through the registry's manifest path (`tools.by_names`
  covers the compiled-in names; provider and MCP entries are frozen as
  manifest entries at the create-time freeze) into runner bundles
  cached by the name tuple, so each distinct
  toolset builds exactly once — the default-create tuple is now the
  default set PLUS `bot_message`/`list_bots` (a different cache entry
  than the boot-seeded human default, which only boot-time hydration
  of pre-bot-only rows still hits).
  `tools` / `tool_choice` never vary mid-thread — that is the part the
  KV-cache byte contract needs. Divergent heads across DIFFERENT
  toolsets are fine (they simply don't share cache spans); a chat-only
  (`'{}'`) thread's envelope omits both fields, frozen at creation.
  A snapshot naming a tool absent from the compiled code fails
  hydration loudly — no silent skip.
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

## Environment / workspace invariants (Phase 1 shipped)

`docs/plans/environments.md` carries the full design and as-built
deltas; the rules that bite silently:

- **Env tools join the default set only while a root can be frozen.**
  `bash`, `read_file`, `write_file`, `list_dir` resolve through the
  catalog config-INDEPENDENTLY (a snapshot pins past a removed
  `NEXUS_WORKSPACE_ROOT`, like `web_search` past SearxNG) — but a
  CREATE or BOT SAVE naming them refuses while no root can be frozen
  ("workspace tools require NEXUS_WORKSPACE_ROOT to be set", a 400).
  The default toolset is every usable COMPILED-IN catalog tool
  (amended pre-deployment, operator call): `default_names` includes
  the env four exactly when the config has a root — plugin and MCP
  tools stay explicit-only (explicit toolset or bot template) — so the
  default envelope stays a pure function of the boot config — the
  config-stability property the original never-in-default rule
  protected. There is no HUMAN-facing create default anymore (the
  boot-seeded default bundle itself survives for hydration of pre-
  bot-only rows): every thread is bot-sourced (threads are bot-only —
  the provider+model create shape is gone), and the registry resolves
  the default sentinel to the
  default set PLUS `bot_message` and `list_bots` for EVERY create, so
  each thread carries its bot's delivery identity. The RESOLVED root
  freezes per thread onto `thread.workspace_root`; hydration rebuilds
  the handle from the ROW, never the config.
- **Every env tool takes `target` as a free string** — the schema is
  byte-identical however many environments are attached; only
  execution routing is dynamic. `workspace` runs the local Phase 1
  path; any other target dispatches WHOLE (tool name + raw arguments)
  through the handle's `remote` router closure (2b-2): a
  registry-routed ask (`RouteEnv`) resolves the thread actor's
  `target → EnvExec(subject, pid)` execution map, and the
  provider-protocol adapter executor (`tool_provider.run_remote`)
  carries the call — its monitor answers a node dying mid-call as an
  ordinary tool error. Unknown targets fail fast as tool errors
  repeating the attached list (tool errors are not loop errors — the
  round commits). The map mutates at attach/detach/DOWN immediately,
  even mid-turn (routing is not transcript state); only the ROSTER
  LINE obeys the pending-behind-turn ordering.
- **Roster changes ride MESSAGES, never the envelope.** Every
  attach/detach (creation-time seed included) appends a user-role row
  with the display-only origin sidecar author `system` (which is
  exactly why a bot cannot be NAMED `system`) naming the CURRENT full
  attached list — self-healing and tail-addressable for small-context
  models; the UI renders it as a muted status line (`.turn.status`),
  not a bubble. It never triggers a turn; hydration re-derives the
  roster from the newest persisted roster row (2b-1) — legacy env rows
  without that prefix fall back to the `["workspace"]` seed.
- **`bash` exec runs in the per-turn worker** (the codemode pattern):
  the executor selects over {port data, cancel, deadline}; cancel
  RE-SIGNALS the one-shot subject (the codemode rule) — and the
  bounded kill-reap must NOT re-consume the re-signal (its selector
  matches the port only). The kill-tree is `setsid` + the first-line
  pgid marker + the PATH-resolved `kill` BINARY with argv
  `["-9", "--", "-<pgid>"]` — the `--` is load-bearing (procps-ng
  4.x silently no-ops without it), and the kill helper must wait for
  the binary to act (see `nexus_env_ffi.kill_tree`). The port spawns
  with an ALLOWLIST environment, never the BEAM's inherited one (the
  FFI's internal `sandbox_env/1` helper: PATH passthrough, HOME
  rewritten to the workspace dir, TZ and CA-path vars when set) — a
  workspace `env` must not print `DATABASE_URL` and friends into the
  transcript (#126).
- **Caps are enforced WHILE READING** (bash output, `read_file` via
  the FFI's chunked read) — post-hoc truncation does not bound
  memory. Non-UTF-8 command output decodes lossily (latin-1
  fallback), never crashes. A bash non-zero exit status is DATA
  (`Ok("exit status N\n…")`); only spawn/timeout/cancel are errors —
  timeout and cancel carry their partial output, a spawn failure is
  an immediate error (nothing ran).
- **fs confinement is LEXICAL**: `..` folds against the workspace
  dir, absolute paths must already be inside it; symlinks are not
  resolved — v1 is hygiene, not a security boundary (the recorded
  accepted risk; the escalation is Phase 3's container workspace).
- **Offline tests**: `gleam test` runs real `bash` in temp dirs — no
  network. The env module is a LEAF (`nexus/env` imports no nexus
  actor module; the `nexus/tools` bridge builds the ToolSpecs — the
  codemode cycle rule).

## Node protocol invariants (environments 2b-3 shipped)

`docs/plans/environments.md` §2b-3 carries the design and as-built
 deltas; the rules that bite silently:

- **Only the socket-owner process sends frames.** mist panics on a
  WebSocket send from any other process (permessage-deflate state is
  process-local), so the node adapter hands finished frame STRINGS to
  a `frames` subject the socket loop selects on — never call
  `mist.send_text_frame` from the adapter actor. The adapter is
  LINKED to the socket process, and the route's `on_close` KILLS it:
  the link covers abnormal deaths (crash, the replace-kill), but an
  actor's own NORMAL exit does not rupture links — the graceful
  client close needs the explicit kill or the adapter stays orphaned
  and attached (the 2b-4 fake node's detach-mid-call check).
- **The adapter keeps no timers.** `tool_provider.run_remote` owns
  deadline, monitor, and cancel re-signal — a wedged node answers as
  an executor timeout, a dead adapter as a monitor DOWN, both
  ordinary tool errors. Result text caps at the boundary on receipt
  (the frame is the WS read unit; mist exposes no mid-frame cap).
- **`tools/call` arguments embed VERBATIM** (string concat around
  argument bytes proven a JSON object first — `valid_arguments`; a
  violation answers a ToolErr, never a malformed frame), and a
  JSON-RPC error-object response is a FAILED call. The protocol is
  `"v":1`, additive-only: changing a wire shape is a protocol change,
  never a refactor (`node_protocol_test` pins exact strings).
- **Replace-on-reconnect**: an attach carrying an execution plane
  whose name is already live KILLS the old plane's pid and registers
  the new one immediately, appending NO roster line (the list is
  unchanged); name-only duplicate attaches still refuse. Node identity
  is the authenticated `node` ROW — its name is the roster target.
- **Node tokens are distinct from the UI token**: pair-verified
  name+token against the `node` table pre-upgrade (401/400/404/403 as
  plain statuses), `role=env` gated by `thread_registry.env_capable`
  (the frozen toolset), `role=viewer` ungated. Revocation is a row
  delete — future connections fail, live ones keep running.

## Plugin / tool-provider invariants (Phase 1 shipped)

`docs/plans/plugin-api.md` carries the full design and as-built deltas;
the rules that bite silently:

- **`__` is the reserved tool-name separator.** Compiled-in tool names
  NEVER contain it; a provider/tool half-name containing it is refused
  at registration (charset `^[a-zA-Z0-9_-]+$`, no `__`, object-rooted
  parseable schema under the byte bound) — loudly, before any name
  enters the catalog. Keep `tools.is_compiled_name` complete when
  adding compiled tools.
- **A provider's `Name` is minted once and threaded as a VALUE.**
  `process.new_name` suffixes a unique counter per call — re-deriving
  `nexus_plugin_<name>` from a string mints a DIFFERENT atom. The
  supervisor child, the boot `ListTools` ask, and the spec executor all
  close over the same value.
- **Providers never join the default toolset.** `NEXUS_PLUGINS` gates
  availability; membership only via explicit create toolsets or bot
  templates, resolved through `tools.by_names_with` (compiled ∪ the
  boot-built provider table) — the default envelope cannot change under
  config drift.
- **Provider failure is a tool error, not a loop error.** The adapter
  (`tool_provider.run`) arms its monitor BEFORE dispatch, re-signals the
  cancel subject on the Cancel path (the codemode rule — the loop's
  LAST-call path depends on it), and truncates every provider byte at
  the boundary — a CHARACTER cap applied AFTER receipt, display
  hygiene only: it does not bound allocation for in-process plugins
  (trusted code, the same trust as compiled tools); external
  transports (MCP, Phase 2) must cap while READING. Boot asks are
  bounded; a compiled plugin that will not start or answer fails boot.
- **`plugin_sup` is a separate OneForOne tree linked to boot** (see
  ARCHITECTURE.md §2) — the provider table must be one value shared by
  the bot registry's validation closure and the thread registry; root
  children cannot hand values to each other. Phase 2 adds a SECOND
  provider tree, `mcp_sup` (also OneForOne, linked to boot), with the
  opposite failure posture: its adapter actors never crash-boot — an
  unreachable MCP server DEGRADES (loud log; every configured server
  still mounts, so frozen threads hydrate without it, and creates
  re-ask live and refuse with the honest reason) because it is an
  external dependency, not part of the release.

## `web_fetch` invariants (`docs/plans/web-fetch.md`)

- **Default vs opt-in split:** `web_fetch` is in `tools.default_names(cfg)`;
  `http_fetch` stays in `tools.catalog_names()` as an explicit opt-in raw
  HTTP tool (preserving existing frozen `http_fetch` manifests without
  migration).
- **Bounded streaming decompression (v2):** `web_fetch` advertises
  `Accept-Encoding: gzip, deflate` and decodes a single gzip/x-gzip/deflate
  coding via `net.inflate_bounded`: the wire-capped body is enqueued once
  and zlib's `safeInflate` returns at most one fixed 16 KiB output chunk
  per call (the NIF's chunk size), with the accumulated size checked
  against `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES` (default 8 MiB) after
  every call — a decompression bomb costs at most the cap plus one chunk,
  ENFORCED BY ZLIB ITSELF rather than our own input slicing. Over-cap
  TRUNCATES and surfaces `raw_truncated` (mirroring the wire cap; post-hoc
  truncation would not bound memory), and so does a stream that ends
  without its terminator (cut upstream, even on a cleanly closed
  connection) — the completeness verdict is `zlib:inflateEnd`, never
  `safeInflate`'s `{finished,_}`, which is spurious when input runs dry.
  A corrupt stream is a tool error. `deflate` is retried as raw deflate
  (windowBits -15) after auto-detection fails — the broken-server case;
  brotli, zstd, and stacked codings are still refused before decoding.
  hackney 1.25's manual `stream_body` path performs no content-encoding
  decoding itself (verified in source), so decompression is wholly
  nexus's.
- **Whitespace preservation in HTML parsing:** `htmgrrrl` invokes `htmerl`
  with `{preserve_ws, true}` so `<pre>` indentation/blank lines and inline
  tag boundary spaces survive; `nexus/html_markdown` normalizes whitespace
  only outside `<pre>`.
- **Fault-isolated in-memory cache:** `nexus/web_fetch_cache` runs in its
  own standalone `OneForOne` supervisor started at boot (outside the
  `OneForAll` root), accessed through `named_seam` (`process.named` +
  `rescue.rescue` + 250 ms call timeout), so a cache crash or timeout
  never restarts threads or fails turns. Only 2xx responses are cached,
  keyed by fragment-stripped normalized URL.

## `http_fetch` curl upgrades (Phase 5 shipped)

`docs/plans/web-fetch.md`'s v3 as-built delta carries the design; the
rules that bite silently:

- **`net.fetch` is a GET wrapper over `net.request`; `web_fetch` and
  `web_search` ride the wrapper and must not observe method/body.** The
  method+body path is `http_fetch`'s alone. Redirects on `net.request`
  follow RFC 9110 / the fetch spec / curl -L: 303 switches every verb
  except HEAD to a bodiless GET (GET itself loses any pathological
  body); 301/302 rewrite ONLY POST — the single rewrite the RFC
  sanctions (§15.4.2/§15.4.3); rewriting PUT/PATCH would silently turn
  an update into a read. 307/308 preserve method+body. A rewrite drops
  the body AND the caller's `content-length`/`transfer-encoding`
  (framing must never describe a body that is no longer sent), and a
  hop crossing scheme/host/port (scheme-default ports normalised:
  `http://h` ≡ `http://h:80`) strips `authorization` / `cookie` /
  `proxy-authorization` — exactly those three names, and for `fetch`
  callers too (web_search's SearxNG bearer never crosses an origin).
  A custom `x-api-key`-style header still follows the redirect, as in
  curl (default posture — `--location-trusted` is deliberately absent).
- **The method whitelist is enforced twice**: `http_fetch.parse_method`
  (GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS) and `method_atom` in the FFI
  — model bytes are never `binary_to_atom`-ed, so no atom-table
  exhaustion and no verb smuggling.
- **Request headers are validated BEFORE the wire**: names are RFC 9110
  tokens (checked per CODEPOINT — a grapheme-level range check has an
  NFD hole) outside the blocked framing/hop-by-hop set (`host`,
  `content-length`, `transfer-encoding`, `connection`, `keep-alive`,
  `proxy-connection`, `te`, `trailer`, `upgrade`, `expect` — hackney
  owns those, and a model-supplied `Expect: 100-continue` can stall a
  request past every soft bound), values carry no C0 controls/DEL (TAB
  and non-ASCII obs-text pass), and case-insensitive DUPLICATE names
  are refused ("Authorization" + "authorization" are one header).
  Unknown argument FIELDS are rejected too (the schema says
  `additionalProperties: false`; a misspelled `data` for `body` is a
  loud tool error, never a silently payload-less request). This plus
  the method whitelist is the STRUCTURAL request-splitting guard; do
  not loosen it piecemeal.
- **Response headers are capped at collection** (FFI): lowercased
  names, combinable duplicates joined ", " per RFC 9110 in FIRST-SEEN
  order — except `set-cookie`, which §5.2 excludes from combination
  (cookie values embed commas) and keeps as separate verbatim pairs —
  at most 128 pairs / 8 KiB rendered bytes, `headers_truncated`
  flagging the cut. The tool layer renders the cookie pairs as ONE
  array-valued `set-cookie` key. Context-window hygiene — hackney
  already materialized the head; the cap bounds what the TOOL RESULT
  carries.
- **Both result paths carry the full payload**: the 2xx Ok object and
  the non-2xx Error object (which keeps its `error` key) include final
  `url`, `headers`, `headers_truncated`, `truncated`, and `body`. The
  body is lossily UTF-8-decoded at the boundary before JSON encoding —
  never JSON-encode raw response bytes.
- **Bodiless hackney responses are a 3-tuple** (`{ok, Status, Headers}`
  — HEAD requests, 204/304): handled as empty bodies, never fed to
  `read_body`.

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

## HTTP API and the debug dump

The JSON routes are the scripting/e2e API (full list in the README's
HTTP section; the browser UI uses none of them — it talks to the
server component over `/ws`). One standing rule when touching them:

- **`GET /threads/<id>/state` is a read-only debug side channel — never
  a UI data source.** It answers "what does the server believe this
  thread looks like right now?" in one consistent ask
  (`ThreadInspect` in `src/nexus/thread.gleam`: committed transcript +
  status + the display-only `live_turn` mirror). Comparing it against
  what the DOM renders is exactly how replay/mirror bugs get caught.
  The UI's truth path stays the `/ws` event stream — a second client
  data source would fight the replay invariants above. Dump details:
  `seq` is the chronological index (0 = the system prompt), the same
  space the reasoning/stamp/origin sidecars address; `is_error` is the
  INVERTED tool-outcome sidecar (`append_tool_result`'s `ok`, so a
  failed call reads `true`); `live_turn` is display-only by the
  existing invariant and is `null` once the turn settles (the key is
  always present — scripts must not test key absence). The `summary`
  block is the registry's snapshot taken just before the actor ask, so
  under concurrent activity it can lag `status` by an instant. The
  abridged
  human/print-PDF HTML view (`/threads/<id>/transcript`) is deferred:
  jhillyerd/nexus#117.

## e2e browser suite (per-worktree setup)

`e2e/` is validation-only and its `node_modules` is not committed, so a
fresh worktree fails with `Cannot find module 'playwright'` until you run
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm --prefix e2e install` — sub-second,
thanks to npm's global tarball cache. The Chromium binary is never
per-worktree: it is shared per-user, revision-keyed, in Playwright's
cache (`~/.cache/ms-playwright` on Linux, `~/Library/Caches/ms-playwright`
on macOS; the pinned playwright 1.64.1 uses `chromium-1248`), or comes
from nixpkgs via `NIX_PLAYWRIGHT_CHROMIUM` in the `e2e/playwright.nix`
shell. On a machine with no cache yet, provision the browser with the
pinned package's own CLI: `npm --prefix e2e exec -- playwright install
chromium`. Never run a bare `npx playwright ...` — outside `e2e/` it
resolves no local install, fetches latest, and drops a second, unpinned
browser revision into the shared cache. Postgres/migrate preconditions:
`e2e/README.md`.

## Logging

Server logging lives in `src/nexus/log.gleam` + `src/nexus_log_ffi.erl`
and emits single-line `logfmt` through Erlang's built-in `:logger`
(human-readable in terminal / container logs and directly parseable by
Grafana Loki's `| logfmt` stage):

```gleam
import gleam/list
import gleam/string
import nexus/log

log.info("store", "boot sweep deleted idle nodes", [
  log.int("count", list.length(names)),
  log.str("nodes", string.join(list.take(names, 100), ",")),
])
```

- **Use `nexus/log` for all server logging** (`log.debug`, `log.info`,
  `log.warn`, `log.error` with a short `component`, short `msg`, and
  typed fields via `log.str`, `log.int`, `log.float`, `log.bool`) —
  never `io.println` in server modules. Keep `io.println` only for
  deliberate stdout output in standalone CLI tools (`tui`, `migrate`,
  `dev_seed`, `audit/ttft`).
- **Configured once at boot** (`log.configure` / `log.set_level` in
  `src/nexus/boot.gleam`, driven by `NEXUS_LOG_LEVEL`, default `info`).
  Because `mist`, `glisten`, `stratus`, and OTP supervisors all log
  through `:logger`, their output and crash reports share the same level
  filter and single-line `logfmt` formatter.
- **`nexus/log` is a leaf module** (imports `gleam_stdlib` only) so any
  module, including `nexus/config`, can import it without cycles.
- **Never log secrets** — `NEXUS_ENCRYPTION_KEY`, provider API keys,
  `NEXUS_UI_TOKEN`, `NEXUS_SEARXNG_TOKEN`, `NEXUS_PG_PASSWORD`, node
  tokens, and pairing codes must never appear in messages or fields.

## Gleam API pitfalls (training data lags the pinned toolchain)

A flash model hit all three of these repeatedly during the issue #88
worker migration; each is checkable in seconds against the repo. The
pinned gleam_stdlib is 1.0.5 (`manifest.toml`) — confirm API existence in
`build/packages/gleam_stdlib/src/gleam/…`, not in training data.

- **`io.debug` does not exist.** The pinned `gleam/io` exports only
  `print`/`println` (plus `_error` variants); debug printing moved to the
  `echo` keyword expression (Gleam v1.9:
  https://gleam.run/news/hello-echo-hello-git/) — `echo some_expression`
  prints the value with file:line to stderr. Because it is a KEYWORD,
  `echo` cannot be a function or variable name either (a helper named
  `echo` fails at its CALL SITE with "This parenthesis cannot be
  understood here" — misleading; rename it). Use `nexus/log` for server
  logging and `io.println` only for deliberate CLI stdout output.
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
