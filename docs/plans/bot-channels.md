---
title: Nexus — bot channels (per-parent DM threads + the thread info pane)
status: active
tags: [nexus, bots, threads, agents, kv-cache, gleam, beam]
updated: 2026-11-15
---

# Bot channels: per-parent DM threads + the thread info pane

**Thesis.** Bot-to-bot DM threads (bots plan P3c) are routed through an
in-memory map keyed by the **bot pair** — `#(from_bot_id, target_bot_id)`.
That makes the busy guard emergently global: bot A running in two parent
threads shares ONE DM thread with bot B, so parent 2's unrelated request
gets `Busy` while parent 1's is mid-turn (#123). Worse, one DM transcript
accumulates interleaved conversations from unrelated parents (context
bleed into the target model), and the in-memory map is lost at restart, so
the first post-restart delivery silently opens a duplicate DM thread. The
fix: key DM channels by **parent thread** — `thread.parent_thread_id` —
and make channels **second-class**: never in the sidebar, never consuming
utility title/tag completions, surfaced instead through a **thread info
pane** reached from the parent's chat pane (the lineage pattern: running
dots, `rel_time` ages, rows that navigate the main chat area). The pane is
built as a general thread-info surface — its Environments section is a
placeholder for `docs/plans/environments.md`'s roster.

Precedent: t3code's thread context panel (attached environment, branch,
changes, **Lineage · N running** with per-child running dots and ages) —
thread facts and attached things live in a popover pane, not the thread
list. The mock (`assets/bot-channels-mock.html`, script-free, works
offline in a browser) pins the agreed shape: header `info ▸ N` button,
Channels/Details/Environments sections, selection-without-listing.

Related: fixes #123. Extends the bots plan (P3c delivery, `docs/plans/
completed/bots.md`); consumes nothing from environments.md yet — only
reserves the pane section.

## Vocabulary

- **Channel** — a DM thread created by `bot_message` delivery, tied to the
  thread whose turn originated the request (**parent**). Stored as
  `thread.parent_thread_id`; NULL on every ordinary thread. A channel's
  frozen columns are the TARGET bot's creation-time template, exactly as
  P3c builds them today — only the routing key and the parent link change.
- **Parent** — the thread a channel hangs off: the sender bot's own
  thread. A parent has one frozen bot, so `(parent_thread_id, target
  bot_id)` uniquely identifies a channel; hop chains make channels of
  channels (a bot inside a channel delivers onward — its `from_thread_id`
  is the channel), bounded by `NEXUS_MAX_BOT_HOPS` as today.
- **Thread info pane** — the header-toggle popover (the `tool_pop`
  precedent: shell top level, native overlay, no script) with sections
  **Channels**, **Details**, **Environments** (placeholder until the
  environments plan lands).
- **Selection-without-listing** — the display distinction between the
  thread the chat area shows (`selected`) and the rows the sidebar
  renders (`listed`). A selected channel highlights its parent's row;
  a breadcrumb offers the way back. One transcript renderer, one scroll
  territory — the pane never embeds a second log.

## The parallelism problem, precisely

`find_or_create_dm` keys `state.dm` by `#(request.from_bot_id, bot.id)`.
Busy is not a global flag — the target thread answers `thread.Busy` when
mid-turn — but pair-keyed routing funnels ALL of bot A's traffic to bot B
through one thread, so contention scope is the pair instead of the
conversation. Two visible failures follow: unrelated parent threads
serialize (the #123 report), and one mongrel transcript mixes unrelated
tasks (the target model's context, auto-title, and tag suggestions all
see the blend). The restart loss is the third failure: `state.dm` starts
empty at boot, so the next pair delivery find-or-CREATES — a second,
dangling DM thread in the sidebar.

## Design

### Schema: `thread.parent_thread_id`

    ALTER TABLE thread ADD COLUMN IF NOT EXISTS parent_thread_id
      text REFERENCES thread(id) ON DELETE CASCADE;
    CREATE UNIQUE INDEX IF NOT EXISTS thread_channel ON thread (parent_thread_id, bot_id)
      WHERE parent_thread_id IS NOT NULL;

- **One partial unique index, two jobs**: `(parent_thread_id, bot_id)` is
  the channel identity, and enforcing it (WHERE the parent link is set)
  means `find_channel` re-derivation can never match ambiguously. The
  leading column also serves the `parent_thread_id = $1` child-list
  scan, so no separate plain index is needed.
- **CASCADE, decided**: a channel is meaningless outside its parent's
  context; `SET NULL` would resurrect orphaned channels into the sidebar
  after a parent delete. (Contrast `bot_id ... ON DELETE SET NULL`: a
  thread IS self-contained without its bot; it is NOT self-contained
  without its parent.)
- Unquoted-safe name (not a Postgres keyword); singular-table, FK and
  index naming per AGENTS.md. Self-referencing FK is fine.
- **Never a request byte**: like `bot_id`, display/routing metadata only —
  structurally outside `messages` and the envelope, so the KV-cache
  contract and `m3_prefix_test` golden are untouched.

### Routing: re-key + restart re-derivation

- `delivery.Request` already carries `from_thread_id` — no wire change.
  `find_or_create_dm` keys `state.dm` by `#(request.from_thread_id,
  target_bot.id)`; `create_dm` sets `NewThread(parent_thread_id: Some(
  request.from_thread_id), …)` and inserts the map entry under the new
  key. Guards unchanged and still evaluated before find-or-create (a
  refused delivery must not leave a fresh channel behind).
- **Re-derivation replaces blind find-or-create on a map miss**: a new
  store query (`find_channel.sql` — `select … from thread where
  parent_thread_id = $1 and bot_id = $2`) answers a miss by looking up
  the existing channel row, with `classify_target`'s lookup-error
  discipline: the query yields `Result(Option(id), StoreError)` — a
  hit repoints the map and delivers; a NO-ROW result creates as today;
  a store ERROR refuses with the retryable vocabulary ("target lookup
  failed; try again") and NEVER falls through to creation — a
  transient outage must not duplicate a channel that may well exist.
  Post-restart, the FIRST delivery for a pair now re-finds the channel
  instead of duplicating it. A hit whose thread was actually deleted
  cannot occur (CASCADE) — the map's deleted-behind-the-map repoint
  branch keeps its current semantics for the live-map case only.
- **Upgrade path (legacy P3c pair threads)**: DM threads created before
  this change carry `parent_thread_id = NULL` and stay listed as
  ordinary threads. No backfill exists — a pair-keyed thread
  interleaves messages from multiple parent conversations, so no
  single correct parent could be assigned. Post-upgrade routing never
  re-enters them (`find_channel` matches on `parent_thread_id`, which
  they lack; a fresh map creates per-parent channels), and the schema
  lifecycle is pre-deploy (dev instances only, per AGENTS.md), so
  archiving or deleting them locally is the retirement path.
- Delete of a parent thread: the store cascade removes the whole
  channel SUBTREE (hop chains make channels of channels, and the FK
  deletes all descendants), so the registry's cleanup must be equally
  transitive — a fixpoint walk that stops and demonitor every live
  descendant, then drops each one's live/dormant records and `dm`
  entries (not just direct children — a scan on the deleted parent's
  id alone would orphan grandchild actors whose rows are gone).
  Stale `dm` entries pointing at dropped channels are tolerated (the
  known-ness check already repoints).
- **Archiving a parent cascades down its channel subtree** (transitive —
  the same fixpoint walk as delete). An archived parent cannot originate
  turns, so its channels could never be appended through the normal
  path; cascading keeps state honest and closes the odd edge where some
  other bot addresses a channel BY ID (the `FoundThread` path does not
  care where the sender ran) — that now refuses as archived too.
  **Persistence-first**: the authority is ONE idempotent recursive store
  update (a CTE walking `parent_thread_id`; restore runs the same shape,
  clearing the column). The registry must NOT inherit the memory-first
  `SetArchived` habit — that path logs write errors and updates memory
  anyway, so a failed write hydrates back ACTIVE after restart and the
  child accepts deliveries again. On CTE failure the cascade aborts
  loudly with memory untouched (both dicts still say active — a
  consistent state; retry re-runs the idempotent update, and nothing
  hydrates archived). On success the registry syncs memory from the
  acknowledged outcome: dormant summaries flipped in `state.dormant`
  (the `apply_meta` pattern, so the pane badge and `Channels` ask are
  correct immediately), live record metas updated, and live child
  actors notified by bounded ask so their own Send-refusal state
  applies (a dead actor's missed notify self-corrects at hydrate — the
  store row is what hydration reads). **Restore is symmetric**:
  unarchiving a parent unarchives its channel subtree — unambiguous
  today because channels have no individual archive affordance to
  conflict with; when individual channel archiving lands, restore
  policy must distinguish cascade-archived from human-archived (e.g.
  `archived_at` compared against the parent's cascade stamp).
- **Channels are not individually archivable in this plan** — the
  archive affordance lives on sidebar rows, and channels are hidden
  from the sidebar. The archived-CHANNEL delivery semantics are
  therefore the contract a future affordance builds on: from each
  child's row write ONWARD, an archived channel refuses deliveries
  from its parent to that bot DURABLY — `find_channel` re-finds the
  archived row and `deliver_to_thread` answers the existing honest
  receipt (`Refused("target thread is archived")`, a failed tool
  result the sender model can report). The cascade's propagation
  window is NOT covered by that refusal — a delivery landing before
  the child's row is written still succeeds and commits (at-most-once,
  the same accepted ambiguity class as the existing ask-timeout
  receipt; the window is one CTE wide). No bot-driven recovery exists
  BY DESIGN: unlike today's accidental post-restart duplicate (the
  lost map silently routing around an archive), a delivery must never
  resurrect or sidestep one. Deleting a channel row frees the pair, so
  the next delivery creates a fresh channel. The pane renders archived
  channels dimmed with an archive badge — still navigable (reading is
  allowed), never hidden.

### Second-class channels: no title/tag economy

Every channel's purpose is known at creation — a model call to title it
spends tokens discovering what we already know, and model tags would
pollute the shared tag corpus that feeds every later thread's utility
instruction. So:

- `title_from_first_message` does not run for channels; `create_dm` sets
  the (NOT NULL) title column to the target bot's name directly.
- The thread actor's utility arm (`arm_utility`, utility-titles §4.2)
  no-ops when the thread is a channel — one guard, keyed off the
  spec/meta parent id. No attempt is armed, so no completion fires, no
  PASS machinery engages, `title_source`/`tags_source` stay `'auto'`
  untouched. Manual tag editing remains possible (nothing generates, the
  display set just stays empty).
- Display labels derive from the bot name at render (the same bot-name
  resolution the sidebar subtitles already do), shown as `↳ <bot name>`.

### Listing and the thread info pane

- `list_summaries.sql` gains `parent_thread_id` (the boot load must carry
  it — the registry needs children for lazy hydration and channel
  lookups). The sidebar filter is **registry-side, not SQL**: the `List`
  projection excludes threads with a parent, so the store stays complete
  and `GET /threads/<id>/state` keeps answering for channels (debug side
  channel unchanged — never a UI data source).
- New registry ask `Channels(parent_id, reply)` — answered from state
  (live records: running + last-active known; dormant summaries: idle),
  bot names resolved through the existing `bots_name` handle (the same
  bounded boot-loaded ask `sender_name_ask` uses — no new cross-registry
  edge, §8 holds). Reply: `{thread_id, bot name, running, last_active_s}`.
- **Header**: `info ▸ N` button (the mock) — a pulsing dot + count of
  running channels. This is the ambient signal that replaces
  recency-jumping: activity is visible without opening anything, and the
  sidebar stays human-shaped. No channels → the button renders nothing.
- **Pane**: Channels rows (dot state, `↳ <bot name>`, `rel_time` age,
  chevron) from the `Channels` ask, refreshed on the event stream the
  way sidebar rows already update (`MetaUpdated`/turn events — the pane
  re-asks or re-projects on the same messages, per-connection state
  only). Details section: bot, provider/model, created age, toolset
  chips — all already in the summary the header renders from.
  Environments section: placeholder ("none attached").
- **Navigation**: a Channels row selects the channel into the main chat
  area (normal `Join`/replay machinery — channels are full thread
  actors; nothing new in the event path). The sidebar highlights the
  parent row; the header swaps to `‹ <parent title>` breadcrumb + the
  channel's bot name; a composer hint names the parent context.
  Sending into a viewed channel is an ordinary human `Send` — the
  channel is the target bot's thread and behaves like one.
- **Reload/route flag**: `Flags.thread` may name a channel (it was last
  selected). Allowed: chat shows the channel, the sidebar highlights the
  parent. No deep-link format changes.

### UI invariants audit (what this plan must not disturb)

- Display-only end to end: pane state is per-connection Lustre model; no
  request bytes change; the commit/rollback display rules and the
  `turn_view` replay mirror are untouched (channels use the existing
  paths — nothing new mirrors commit rules, per the m3 lesson that a
  second surface that does is where replay bugs breed).
- Hostile text: channel labels, ages, and Details render as Lustre text
  nodes; `From …` content in a viewed channel is the existing P3b
  rendering byte-for-byte. `ui_test` hostile-payload pins extend to the
  pane rows and breadcrumb.
- The shadow root stays open; one runtime per `/ws` connection — the
  pane is ordinary per-client model state.
- The `List` projection filter and the `Channels` ask never consult the
  store at ask time (§8: answers from state; the boot load already has
  every summary).

## Non-goals

- No re-parenting, renaming, or moving channels; no channel merge.
- No cross-parent channel index or global "all channels" view (the pane
  is strictly per parent; grandchild channels appear in their own
  parent-channel's pane, per the hop-chain rule).
- No notifications beyond the header badge (no push/email/unread
  persistence).
- No sync `bot_message_wait` (recorded non-goal of the bots plan).
- No individual channel archive/unarchive affordance (e.g. a pane-header
  control) — future work; the archived-channel delivery semantics in
  this plan are its contract.
- No changes to delivery receipts, guard order, or `NEXUS_MAX_BOT_HOPS`.

## Phases

### Phase 1 — schema, routing, re-derivation (offline-provable)

1. `sql/schema.sql`: column + index (idempotent); migrate re-applied;
   squirrel regen (`sql.gleam` committed; CI `squirrel check`).
2. Store: `NewThread`/insert carries `parent_thread_id`; summaries
   (`list_summaries.sql`) + `get_thread` carry it; store-mock seam
   (`store_mock.gleam`) round-trips it; new `find_channel.sql` query +
   mock wiring.
3. Registry: `dm` map re-key; `create_dm` sets parent + deterministic
   title; find-or-create consults `find_channel` on a miss; child
   cleanup on parent delete; `List` projection excludes channels;
   `Channels(parent_id)` ask.
4. Thread actor: utility-arm guard for channels; heuristic-title skip.
5. Tests: registry tests — two parents' bots message the same target
   concurrently, both `Delivered` (no `Busy`); same parent, second
   delivery mid-turn → `Busy`; post-restart re-derivation finds the
   existing channel (map cleared, no duplicate created); lookup error
   during re-derivation refuses (no creation); guard order unchanged
   (refusal creates nothing); parent-archive cascades transitively
   (store-first CTE; memory synced so the pane badge and `Channels`
   ask are correct immediately) and restore unarchives it; a failed
   cascade write aborts with memory untouched (nothing hydrates
   archived after restart); delivery into a cascade-archived channel
   refuses durably (no re-derivation escape hatch); parent-delete
   drops the whole descendant tree (direct children AND grandchildren);
   `m3_prefix_test` golden untouched; `gleam test` stays offline.

### Phase 2 — the thread info pane (UI + e2e)

1. `ThreadSummary`/spec plumbing of `parent_thread_id` into the UI model
   (selection-without-listing mapping, header badge state).
2. Header `info ▸ N` button + popover per the mock (Channels/Details/
   Environments sections; `rel_time` ages; running dots from turn
   events); channel row → select channel; breadcrumb + hints; sidebar
   parent-highlight while a channel is selected; reload flag handling.
3. Tests: `ui_test` — sidebar omits channels; pane renders rows with
   dots/ages/labels; badge counts; selection-without-listing highlight;
   breadcrumb; hostile-text payloads in labels; deleted-bot label
   fallback; archived channel renders dimmed with the archive badge and
   stays navigable (read-only transcript, never hidden); `m3_prefix_test` still golden; e2e — the bots P3c smoke
   (RelayAlpha → RelayBeta) drives the pane instead of the sidebar;
   integration `case:relay` scenario unchanged at the protocol level;
   the full browser suite re-run (the offline suite cannot see visual
   regressions — the mock is the visual reference).

## Cache gate

No envelope, transcript, or sidecar change: the golden (`test/fixtures/
m3_cache_thread.json`) must re-encode byte-identically with no re-capture,
and no warm/cold TTFT re-run is required — this plan touches routing
metadata and display state only. If it fails, the change is wrong.
