---
title: Nexus — TUI pairing grants (web-minted pairing URLs for nexus-tui)
status: completed
tags: [computing, self-hosting, local-llm, agents, gleam, beam, environments, tui]
updated: 2026-11-25
---

# TUI pairing grants: mint a pairing URL in the web UI, launch nexus-tui with it

> **Landed 2026-11-18/19** (Phase A #141, Phase B #142, Phase C + boot
> sweeps #143, per-thread node names #144, `@` in node names #146,
> pane-close one-time URL retirement #148). All planned phases and boot
> hygiene sweeps shipped; Phase D's two stretch items (`GET /pair/<code>`
> landing page and in-process reconnect-with-backoff in the PoC Gleam
> TUI) were deliberately dropped since the high-fidelity Rust TUI now
> lives in a separate repo.

**Thesis.** Starting `bin/nexus-tui` is painful because the caller must
supply the UI token (just to pass `protected()` on `POST /nodes`), the
thread id, and — worst — the script re-pairs on every launch: it deletes
the old row and mints a fresh token that lives only in process memory, so
nothing survives a crash or a closed terminal. The fix is a
**short-lived, web-minted pairing grant** exchanged by the TUI host for a
**durable node credential persisted locally**. Everything the reconnect
story needs beyond that already shipped with environments 2b-3:

- `/node/ws` join answers `Hello` + full replay (including the
  `turn_view` mid-turn mirror) — a reconnecting client sees the whole
  thread again.
- Replace-on-reconnect: a new connection under a live name kills the old
  plane and takes over (idempotent re-attach).
- Roster re-derivation from persisted roster rows survives *server*
  restarts.

The only missing piece is a credential that outlives one process and a
way to mint it without knowing the UI token. This plan is environments
Phase 2's deferred "Pairing UX" detail work
(`docs/plans/environments.md`, "Auth and persistence for nodes (P2)").

## Vocabulary

- **Pairing grant** — a server-side row authorizing the minting of node
  credentials: a hashed code, a pinned thread, an expiry. The unit the
  web UI creates, displays, and revokes.
- **Pairing code** — the grant's plaintext secret, shown exactly once at
  mint, embedded in the **pairing URL**
  (`http://boss.home.arpa:8080/pair/<code>`). 32 random bytes,
  URL-safe base64 (same mint as a node token). Never stored, never
  logged.
- **Node token** — the existing per-node bearer credential
  (`node.token_hash`), unchanged semantics; what the exchange mints.
- **TUI state file** — the node token persisted on the TUI host
  (`0600`), enabling crash-relaunch without re-pairing.

## Design summary

### Three separable lifetimes

| Thing            | Lifetime                                    | Revocation            |
| ---------------- | ------------------------------------------- | --------------------- |
| Pairing code     | 1 hour, **multi-use** (many hosts)          | grant row delete      |
| Node token       | idle expiry, default **7 days** since last seen | node row delete (shipped) |
| TUI state file   | until the token is revoked or expires       | `--reset`, or delete  |

### Server: one new table, one new public route, no new protected routes

`node_grant` (schema conventions: singular, `<parent>_<role>`, FK
`<parent>_id`, `timestamptz`, `<table>_<purpose>` indexes — verify
`node_grant` is unquoted-safe against a live database before landing,
per AGENTS.md):

```sql
CREATE TABLE IF NOT EXISTS node_grant (
  id           text PRIMARY KEY,
  code_hash    text NOT NULL,        -- SHA-256 hex (node.hash_token); never plaintext
  thread_id    text REFERENCES thread(id) ON DELETE CASCADE,  -- NULL reserved (see Non-goals)
  created_at   timestamptz NOT NULL,
  expires_at   timestamptz NOT NULL, -- created_at + 1h
  use_count    int NOT NULL DEFAULT 0,
  last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS node_grant_expiry ON node_grant (expires_at);
```

- `thread_id` CASCADE matches the bot-channels reasoning: a pairing URL
  for a deleted thread is meaningless and must die with it.
- `use_count` / `last_used_at` are diagnostics (the pane shows "paired K
  TUIs, last used Nm ago"); no `max_uses` in v1 — multi-use is the
  feature.

**The exchange — `POST /nodes/pair` — is the only new HTTP route**, and
it is public: it carries its own auth (the code), exactly the
`GET /node/ws` precedent — answered pre-upgrade as plain HTTP statuses,
a deliberate absence in `requires_auth` with the same comment.

- Request: `{"code": …, "name": …}` (name validated by `node.valid_name`
  as today).
- Code check: row found by listing/scanning grants, `expires_at` in the
  future, `node.verify_token`-style constant-time hash compare. Expired,
  revoked, and unknown all answer the same merged `404 "unknown or
  expired pairing code"` — the route must not become a code oracle.
- On success: mint through the **existing** path (`create_node_row`
  factored shared with `POST /nodes`), bump `use_count` /
  `last_used_at` (best-effort, like `touch_node`), answer
  `201 {id, name, token, thread_id}`. The grant's thread rides along —
  the TUI host needs zero thread knowledge.
- `409` name-already-paired keeps today's friendly path (the same
  `node name is already paired` the admin route answers), surfacing
  only for a LIVE code: the code check deliberately precedes the
  collision check, because the reverse order would let an anonymous
  caller enumerate node names with a garbage code (409 taken vs 404
  free). **A code must
  never authorize taking over an existing name** — that would escalate a
  grant beyond mint-new. A lost state file with the row still live 409s;
  the SCRIPT's error output (Phase B) adds the pointer to the info
  pane's revoke — the route's own message stays the plain collision
  reason.

**No `POST /nodes/grants`, no grant list/revoke HTTP routes.** The
browser UI is a Lustre server component over `/ws`, and the standing
rule (AGENTS.md, HTTP API section) is that it uses *none* of the JSON
routes — they are the scripting/e2e surface. Mint, list, and revoke ride
`ui.Msg`:

- `ui.Flags` grows a `store.Store` handle, threaded from boot through
  `web.gleam`'s `/ws` route into `ui_runtime.websocket` →
  `runtime_flags`. This is the first UI-side store access; it is
  architecturally identical to the web routes (which call the seam
  directly from request processes) — the pool is process-safe. A
  node/grant registry *actor* was considered and rejected: the rows
  carry no in-memory state or lifecycle (unlike providers/bots), so an
  actor is ceremony.
- Effects follow the `models_effect` unlinked-worker pattern with the
  `nexus/rescue` wrap (any worker exit dispatches a Failed msg — no
  wedged pending state).

### Web UI: the thread info pane's Environments section

The minting surface is the **thread info pane** (impl landing now), not
a Settings tab — the grant is thread-scoped, so no thread picker is
needed. The pane gains an Environments section:

- The thread's environment roster (attached targets: `workspace` plus
  node names), with node `last_seen` and a Revoke button (row delete;
  a live connection survives until it disconnects — the shipped
  posture).
- A **"Pair a TUI…"** button: a worker mints a grant pinned to this
  thread and the pane shows the pairing URL with a copy button and an
  expiry countdown.
- **Minting is side-effect-free with respect to the thread**: a single
  `node_grant` insert through the store seam — no transcript row, no
  roster change, no thread-actor ask — so it cannot disturb connected
  environments or an in-flight turn, and a new mint never invalidates
  an earlier grant (independent rows, each with its own expiry). The
  same holds downstream: a newly paired TUI connecting under a *new*
  name attaches alongside the existing roster; replace-on-reconnect
  only ever applies to the *same* name (the shipped relaunch
  semantics).
- **One-time URL display**: the code is stored hashed only, so the URL
  renders only at mint time; while active the grant renders as
  "active · expires in Nm · paired K TUIs" with a Revoke button. A lost
  URL is re-minted — cheap by design. (Encrypting the code for
  re-display was considered and rejected as v1 overkill; re-mint
  matches the token-answers-once precedent.)
- Hostile-text and Pico rules as always: the code, URL, and node names
  are server-minted but still Lustre text nodes; no `innerHTML`; Pico
  tokens before new CSS.

### TUI script: `bin/nexus-tui <pair-url>`

```
nexus-tui http://boss.home.arpa:8080/pair/<code>   # first launch on a host
nexus-tui                                          # relaunch — stored credential
nexus-tui --reset                                  # forget the stored credential
env overrides: NEXUS_NODE, NEXUS_ROLE, NEXUS_THREAD (still wins over the grant's)
```

- **State file**
  `${XDG_STATE_HOME:-$HOME/.local/state}/nexus/tui-<host>-<node>-<thread>.json`,
  mode `0600`, content `{server, node, token, thread}` (`server` is
  the server's BASE URL — the launcher never persists the pairing
  URL; the code is stored only as a hash, and the grant itself stays
  redeemable until expiry or revocation) — keyed per (server, node
  name, thread) as of the 2026-11-19 per-thread-names delta (the
  original key was (server, node name), with two threads on one host
  working via distinct `NEXUS_NODE` names — now the SAME name works
  per thread; one live connection per row, the second connection to a
  row replaces the first — shipped replace-on-reconnect).
- Launch logic: state exists → connect with the stored token, no
  pairing at all. The WS upgrade answering `401` (the pre-upgrade plain
  status; row deleted or swept) → re-pair if a pair-url was given, else
  exit with "credential rejected — pair again". No state + pair-url →
  exchange, persist, connect. No state + no URL → usage message.
- The old **delete-stale-row-then-re-pair behavior is removed** — that
  is the point of the state file.
- Trust note: the token now lives on local disk. The node token
  authorizes joining/typing/serving tools *as that host*; an attacker
  who can read a `0600` file there already owns the host. Bounded risk.

### Hygiene: boot sweeps

- Grants: `DELETE FROM node_grant WHERE expires_at < now()` — pure
  garbage collection.
- Nodes (the "re-launch window"): `DELETE FROM node WHERE
  coalesce(last_seen_at, created_at) < now() - make_interval(days =>
  $1)`, driven by `NEXUS_NODE_IDLE_DAYS` (**default 7**, `0` = never
  sweep). A daily-driver TUI keeps its credential indefinitely; a
  crashed one has a week. `last_seen_at` is bumped on every
  authenticated connect (shipped `touch_node`) **and at every close
  mist reports** (the on_close bump — landed with Phase C's sweeps;
  mist fires on_close "for any reason, valid or otherwise", so the
  stamp tracks the last OBSERVED disconnect — see the as-built
  deltas): without it, a TUI
  connected right up to a server shutdown would carry a stale
  last-seen into the next boot, and the boot sweep — which runs before
  any reconnect can re-stamp it — could take a still-in-use
  credential (cubic review). Never-connected rows expire from
  `created_at`.
- Sweeping does not rewrite roster history: roster rows are transcript
  text, not FKs. A swept node's target simply stops resolving — env
  routing to an unknown target fails as an ordinary tool error listing
  the attached targets (shipped behavior). Node rows have no FK
  dependents (`node_grant` FKs `thread`, not `node`), so the
  parent-with-children boot-sweep caution from bot channels does not
  apply.

## Decisions locked in review (2026-11-16)

1. **Thread-pinned v1.** The mint always pins the issuing thread; the
   TUI of the future may want to switch/create threads, but that is the
   high-fidelity-TUI initiative, not this PoC. `thread_id` stays
   nullable so an unpinned grant shape needs no migration — door open,
   zero extra work now. *(Partially superseded by the 2026-11-19
   per-thread-names delta: the exchange now accepts an explicit
   `thread` override — the launcher's `NEXUS_THREAD` — which binds the
   minted row to that thread instead of the grant's pin; the default
   remains the grant's pin, and an unpinned grant without an override
   still refuses.)*
2. **7-day idle expiry** (since last seen; `created_at` for
   never-connected), `NEXUS_NODE_IDLE_DAYS`, default 7, `0` disables.
3. **Mint surface = the thread info pane's Environments section** (the
   info pane impl is landing), not a Settings tab.
4. **No new protected HTTP routes** — grant mint/list/revoke ride the
   server component (`ui.Msg` + store-in-Flags workers); the single new
   HTTP route is the public exchange, whose auth is the code itself.

## Phases

### Phase A — grant seam + public exchange (server, offline-provable) —
IMPLEMENTED

- `sql/schema.sql` + `gleam run -m nexus/store/migrate`; squirrel
  queries (`insert_node_grant`, `list_node_grants`, `delete_node_grant`,
  `touch_node_grant`, sweep) + `gleam run -m squirrel`; `store.gleam`
  seam growth + `test/store_mock.gleam`.
- `nexus/node.gleam` (the leaf that owns token hashing) grows the grant
  mint helpers: code generation + `hash_token` reuse.
- `web.gleam`: `POST /nodes/pair` public exchange; factor the mint out
  of `create_node_row` for reuse; `requires_auth` deliberate absence.
- Offline tests: `web_routes_test` grant round trip seeded through the
  mock seam (mint → exchange `201` → duplicate name `409` → expired
  merged `404` → revoked merged `404` → `use_count`/`last_used_at`
  bumped); `node_test` for the mint/verify helpers; `migrate_test`
  idempotency.

### Phase B — script pairing mode + state file (the UX fix) —
IMPLEMENTED (2026-11-18)

- `bin/nexus-tui`: pair-url arg / `NEXUS_PAIR_URL`, state read/write
  (`jq`, `0600`), `401` re-pair path, `--reset`, delete-and-re-pair
  removed.
- e2e: extend the fake-node/tui suite — seed a grant (store seam in
  server setup), pair via URL, kill the client, relaunch with the state
  file → same node row (assert through `GET /nodes`), transcript
  replayed.

As-built deltas:

- **The 401 signal is an EXIT CODE, not stdout scraping.**
  `nexus/tui` parses the status out of stratus's handshake-failure
  reason (`handshake_status`, offline-pinned) and halts 4 on 401
  (credential rejected — node row revoked or swept), keeping 2 for
  every other connect failure. The launcher re-pairs on 4 (when it
  holds a pairing URL) and propagates everything else verbatim; the
  bare relaunch turns 4 into "credential rejected — pair again".
- **State discovery is by node name**, not only by the (server, node)
  key: a bare `nexus-tui` relaunch does not know the host, so the
  launcher `jq`-filters `tui-*.json` on the stored `.node`. One match
  connects; several match → exit 2 listing them (disambiguate by
  relaunching with the pairing URL or setting `NEXUS_URL`); none →
  the usage message. With a pairing URL given, only the matching
  server's file qualifies.
- **`NEXUS_URL` is no longer a pairing input** — the pairing URL and
  the state file carry the server base; `NEXUS_URL` survives only as
  the ambiguity disambiguator above. The old admin-token pairing path
  (`POST /nodes` + `NEXUS_UI_TOKEN`) is unchanged as a route for
  scripting; the launcher no longer uses it, and the
  delete-stale-row-then-re-pair behavior is removed as planned.
- **The state file stores the EFFECTIVE thread** — the grant's, unless
  `NEXUS_THREAD` overrode it at pair time — so a relaunch reproduces
  exactly the working configuration; the token is written 0600 via a
  same-directory tmp file + rename, never resting world-readable.
- **e2e seeds grants via psql** (hex `sha256(code)`, one-hour expiry,
  pinned to the suite's env thread) — the schema row is the contract
  the store seam writes; grants then live through the whole launcher
  flow: exchange → 0600 state → SIGKILL + stored-credential relaunch
  (same node row, replay rendered) → revoked credential refuses with
  exit 4 → a fresh URL re-pairs and replaces the row.

A + B together are the whole UX fix; they land first.

### Phase C — info pane Environments section (after the info pane merges)
— IMPLEMENTED (2026-11-18), hygiene sweeps landed with it

**Ordering constraint (cubic review): the grant boot sweep (Phase D's
hygiene list) lands no later than this phase** — expired-grant
accumulation only becomes real the moment a mint caller exists, and
the exchange scans the live list.

- `ui.Flags` store handle + boot→`web.gleam`→`ui_runtime` plumbing;
  `ui.Msg` variants; unlinked-worker effects (`models_effect` +
  `nexus/rescue` pattern).
- The section itself: roster + node last_seen + revoke; mint; one-time
  URL display + copy; grant list (active, expiry, paired-count) +
  revoke.
- Browser e2e: mint → URL visible in DOM → revoke; hostile-text
  payloads pinned; existing selectors untouched.

As-built deltas:

- **The boot sweeps run from `main`, through the seam — not inside the
  store actor's initialiser.** `persist.boot_sweeps(cfg, db)` is called
  once the supervision tree is up (an `actor.call` to self inside the
  store actor's own initialiser would block it on the actor it is
  still building) and is unit-tested offline over the mock seam.
  Ordering is unconstrained — unlike the thread prune, no hydration
  depends on these rows being gone first. BOTH hygiene sweeps landed
  with Phase C (the grant sweep per the ordering constraint; the idle-
  node sweep rode along — Phase D is now stretch-only). The sweep's
  freshness guard landed with it: the node route's close (`on_close`)
  bumps `last_seen` best-effort. Mist invokes `on_close` for ANY
  shutdown reason ("valid or otherwise") — clean client closes,
  replace-kill teardown, server shutdown, surfaced socket errors — so
  `last_seen` tracks the last OBSERVED disconnect and the idle window
  runs from there; only a hard VM kill skips it, in which case the
  window runs from the previous stamp (connect or an earlier close),
  still bounded — the plan's "a crashed TUI has a week". (Gating the
  bump on a "clean" flag would unprotect the server-shutdown case, the
  very disconnect the bump exists to cover — cubic PR review.)
- **The roster the pane renders re-derives from the UI's OWN LOG** (the
  newest `system`-authored roster row, parsed with the same
  `env.roster_parse` the server's hydration uses) — no new registry
  ask, and a live attach/detach echo updates the section with no extra
  load. A thread with NO roster row reads "no environment" and the
  mint button does not render (a TUI could not serve a thread without
  env tools).
- **The pane's store reads do NOT ride the every-refresh cascade** the
  channels ask rides (that would put a Postgres read behind every
  commit bump); the section loads on pane OPEN and self-refreshes
  after each of its own mutations (revoke = delete + re-read in one
  worker round trip; a successful mint appends the persisted row
  directly).
- **The info badge renders for EVERY selected thread** (Phase 2
  amendment): the pane is the mint surface, so it must be reachable on
  a channel-less thread — the count chip still hides at zero and the
  dot stays gray there (the ambient signal exists only where channels
  exist; `badge_counts_running_channels_test` was updated
deliberately).
- **The mint URL's origin is the BROWSING origin**: the server renders
  the boot-config base (`pair_base` in Flags) as a no-JS fallback, and
  the page shell's `pairing_js` rewrites every `[data-pair-url]`
  element to `location.origin + "/pair/" + code` on mount — a `0.0.0.0`
  bind or a LAN hostname must not leak into the link the operator
  copies for a TUI host. The Copy button rebuilds the same URL at
  click time (clipboard with an execCommand fallback for plain-http
  LAN origins); the expiry ticks via a `[data-expires]` span the
  timestamps script re-renders on its 30s pass (the rel_time twin
  rule).
- **A minted grant lands in the grants list immediately** (the
  write-through succeeded — the msg only lands then), and a re-read
  that no longer carries the displayed mint's grant (revoked, or
  swept) drops the one-time URL display with it.
- **Pane close retires the one-time URL display** (follow-up): the
  server-component model outlives the pane, so closing the info pane
  (toggle or Settings) now clears the mint display — before the fix,
  the plaintext re-rendered on every pane reopen for the whole /ws
  connection and "shown once" was false. A mint landing on an
  already-closed pane drops the code (the row still lands). A lost URL
  is re-minted, as the pane's own note promises.
- Browser e2e (`browser.spec.mjs`, its own workspace-rooted instance
  on :18083 — the main instances keep their env-less default toolsets
  for the byte-prefix pins): pane → mint → URL shape → REAL public
  exchange redeeming the DOM's code (no auth) → pane reopen shows the
  paired count → revoke kills row + display → revoked code answers the
  merged 404. Hostile roster rows are pinned offline (ui_test). The
  run also surfaced (and the spec now strips) a foot-gun: a
  `NEXUS_SEED_PROVIDER_API_KEY` in the caller's shell keyed the seeded
  provider and broke the suite's keyless pins.
- **Ghost-row revoke gap, then the ROOT CAUSE (2026-11-19, per-thread
  node names).** The pane originally rendered only the current
  thread's ROSTERED targets, while names were instance-global
  (`node_name` UNIQUE) — a disconnected TUI's row blocked its name
  everywhere yet no pane could show it, so the 409's advice was
  unreachable. The first fix rendered unrostered rows as a "not
  attached:" group; the REAL fix aligned the store with the
  environments plan's own 2b-2 rule (names unique per THREAD): rows
  gained `thread_id`, the unique index and the 409 checks scoped to
  (thread, name), `/node/ws` auth became the (thread, name) pair
  lookup, and the exchange grew an optional `thread` override (the
  launcher's `NEXUS_THREAD` rides it) binding the row to the thread it
  will join — a lost state file on thread A never blocks pairing the
  same host name into thread B again. The "not attached:" group stays,
  now scoped by thread (the pane filters rows to the selected
  thread): it is the Revoke surface for THIS thread's paired-but-
  disconnected rows (the lost-state-file case). The launcher's state
  file key grew the thread too — `tui-<server>-<node>-<thread>.json` —
  since one host can now hold credentials for the same name in
  several threads (`NEXUS_THREAD` disambiguates a bare relaunch).
  Pre-change state files (`tui-<server>-<node>.json`) are orphaned by
  the new key — one re-pair per host, same as the row migration.

### Phase D — stretch (dropped)

- ~~Boot sweeps~~ — landed with Phase C (see above).
- ~~Stretch: human-friendly `GET /pair/<code>` landing page (shows the
  launch command + expiry — the visitor already holds the code);
  in-process reconnect-with-backoff in the TUI so a *server* restart
  does not kill it (today `on_close` halts the VM — the environments
  plan's "reconnect with backoff" intent, never built in the PoC).~~
  Dropped: superseded by the high-fidelity Rust TUI in a separate repo.

## Non-goals (recorded, not planned)

- **TUI thread switching/creation** — future high-fidelity TUI; the
  nullable `thread_id` is the only accommodation.
- **`max_uses` on grants** — multi-use is the feature; `use_count` is
  diagnostics.
- **Multi-user / scoped authority** — node-token authority stays
  instance-wide v1 (the environments plan's recorded posture); a grant
  inherits exactly that authority for one hour.
- **Approval flows** — the Pi model, unchanged.
- **Encrypted-code re-display** — re-mint instead.

## Invariant checklist (what this plan must not break)

- **KV-cache byte contract untouched** — grants are a pure auth/UX
  layer; no envelope, transcript, or `/node/ws` protocol v1 change (the
  exchange is additive HTTP).
- **Hostile text** — everything the pane renders (code, URL, node
  names, counts) is a Lustre text node; the `<script>`-payload
  regression tests keep passing.
- **`requires_auth`** — the exchange is a deliberate absence with the
  `/node/ws` comment; no existing route's protection changes.
- **Store seam mockability** — grant queries live behind
  `store.gleam` + `store_mock`; `gleam test` stays offline/network-free.
- **One Lustre runtime per connection** — the store handle is
  per-connection plumbing, used from unlinked workers; no shared UI
  state across connections.
- **Schema conventions** — singular unquoted-safe names (verify against
  a live DB), `<table>_<purpose>` indexes, `timestamptz`, FK
  `<parent>_id`, idempotent `CREATE IF NOT EXISTS`, committed
  regenerated `sql.gleam`.
- **The UI's truth path** — the pane's data arrives over `/ws` msgs,
  never via the JSON routes (`GET /threads/<id>/state` stays a debug
  side channel).
