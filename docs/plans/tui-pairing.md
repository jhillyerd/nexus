---
title: Nexus — TUI pairing grants (web-minted pairing URLs for nexus-tui)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, environments, tui]
updated: 2026-11-16
---

# TUI pairing grants: mint a pairing URL in the web UI, launch nexus-tui with it

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
- `409` name-already-paired keeps today's friendly path. **A code must
  never authorize taking over an existing name** — that would escalate a
  grant beyond mint-new. A lost state file with the row still live
  409s, and the error message points at the info pane's revoke.

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

- **State file** `${XDG_STATE_HOME:-$HOME/.local/state}/nexus/tui-<host>-<node>.json`,
  mode `0600`, content `{url, node, token, thread}` — keyed per (server,
  node name), so two threads on one host work via distinct `NEXUS_NODE`
  names (one live TUI per name: the second connection replaces the
  first — shipped replace-on-reconnect).
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
  authenticated connect (shipped `touch_node`), and never-connected
  rows expire from `created_at`.
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
   zero extra work now.
2. **7-day idle expiry** (since last seen; `created_at` for
   never-connected), `NEXUS_NODE_IDLE_DAYS`, default 7, `0` disables.
3. **Mint surface = the thread info pane's Environments section** (the
   info pane impl is landing), not a Settings tab.
4. **No new protected HTTP routes** — grant mint/list/revoke ride the
   server component (`ui.Msg` + store-in-Flags workers); the single new
   HTTP route is the public exchange, whose auth is the code itself.

## Phases

### Phase A — grant seam + public exchange (server, offline-provable)

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

### Phase B — script pairing mode + state file (the UX fix)

- `bin/nexus-tui`: pair-url arg / `NEXUS_PAIR_URL`, state read/write
  (`jq`, `0600`), `401` re-pair path, `--reset`, delete-and-re-pair
  removed.
- e2e: extend the fake-node/tui suite — seed a grant (store seam in
  server setup), pair via URL, kill the client, relaunch with the state
  file → same node row (assert through `GET /nodes`), transcript
  replayed.

A + B together are the whole UX fix; they land first.

### Phase C — info pane Environments section (after the info pane merges)

- `ui.Flags` store handle + boot→`web.gleam`→`ui_runtime` plumbing;
  `ui.Msg` variants; unlinked-worker effects (`models_effect` +
  `nexus/rescue` pattern).
- The section itself: roster + node last_seen + revoke; mint; one-time
  URL display + copy; grant list (active, expiry, paired-count) +
  revoke.
- Browser e2e: mint → URL visible in DOM → revoke; hostile-text
  payloads pinned; existing selectors untouched.

### Phase D — hygiene + stretch

- Boot sweeps (expired grants; idle nodes per `NEXUS_NODE_IDLE_DAYS`).
- Stretch: human-friendly `GET /pair/<code>` landing page (shows the
  launch command + expiry — the visitor already holds the code);
  in-process reconnect-with-backoff in the TUI so a *server* restart
  does not kill it (today `on_close` halts the VM — the environments
  plan's "reconnect with backoff" intent, never built in the PoC).

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
