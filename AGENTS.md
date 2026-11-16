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
- **One frozen toolset per thread** (amended by bots plan P2;
  `docs/plans/completed/bots.md`). The toolset is persisted at creation as
  resolved tool names (`thread.toolset` — the default set's, or the
  creating bot's; never NULL-for-default) and resolved against the
  config-independent catalog (`tools.by_names`) into runner bundles
  cached by the name tuple, so the default snapshot shares the
  boot-built bundle and each distinct toolset builds exactly once.
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

- **Env tools are compiled names that never join the default set.**
  `bash`, `read_file`, `write_file`, `list_dir` resolve through the
  catalog config-INDEPENDENTLY (a snapshot pins past a removed
  `NEXUS_WORKSPACE_ROOT`, like `web_search` past SearxNG) — but a
  CREATE or BOT SAVE naming them refuses while no root can be frozen
  ("workspace tools require NEXUS_WORKSPACE_ROOT to be set", a 400).
  The RESOLVED root freezes per thread onto `thread.workspace_root`;
  hydration rebuilds the handle from the ROW, never the config.
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
  the binary to act (see `nexus_env_ffi.kill_tree`).
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
  LINKED to the socket process; both directions of death are clean
  (monitor-detach / client reconnect).
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
