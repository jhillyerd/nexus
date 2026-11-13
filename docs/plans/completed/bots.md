---
title: Nexus — bots and profiles (named thread templates, per-bot toolsets, bot-to-bot messaging)
status: completed
tags: [nexus, bots, threads, agents, kv-cache, gleam, beam]
updated: 2026-11-13
---

# Bots and profiles

> **Landed 2026-11-10/13** (P0 rename #70; P1 #87; P2 prep #92 + toolsets
> #94; P3 design gaps #98, slices #99/#100/#101). All phases shipped as
> designed, with the cache gate re-verified at each contract-touching
> landing (P2: 0.234; P3c: 0.236, prior runs 0.228–0.243). What remains
> open is only the recorded non-goals below, plus the future-work notes
> flagged inline (the pre-P2 deployment materialization path, the sync
> `bot_message_wait` variant).

**Thesis.** A bot is a named, user-editable profile — default provider +
model, system prompt, and (from P2) a tool list — that a new thread is
created from. Threads keep everything they already freeze at creation
(provider, model, system prompt); a bot is simply the *source* those
frozen values are prefilled from, plus a provenance pointer. From P3, a
bot can also be the *user* of another bot's thread (Hermes-style DM
collaboration). The whole design keeps the KV-cache byte contract
structurally intact: a bot never mutates a thread that already exists.

Precedent: Hermes Agent (bots message each other; one bot is the user of
another bot's chat), Grok Bot, OpenAI Assistants (an "assistant" with
tools + model runs on "threads" — the same assistant/thread split this
plan builds, and the vocabulary the session→thread rename aligned with).

> **Decisions from the 2026-11-10 planning session** (recorded before
> implementation):
>
> 1. **Rename first** — landed as `212eea` (#70). All bots work uses
>    thread vocabulary from day one.
> 2. **A bot is a creation-time template, not a runtime dependency.**
>    Creating a thread from a bot COPIES the bot's provider/model/system
>    prompt (P2: toolset snapshot) into the thread's frozen-at-creation
>    columns. Editing or deleting a bot never changes an existing
>    thread. `thread.bot_id` is provenance/display only.
> 3. **P1 ships zero contract changes** (default toolset unchanged);
>    per-bot toolsets are their own PR that deliberately amends the
>    frozen-toolset invariant in AGENTS.md, with the e2e cache gate
>    re-run.
> 4. **DM-style collaboration before shared rooms.** "Bot A appends a
>    user-role turn to bot B's thread" fits the single-owner transcript
>    model almost for free; rooms (one transcript, several assistant
>    identities) are a recorded non-goal pending P3 learnings.
> 5. **No skills column yet** — nexus has no skills system; adding a
>    vestigial column would be schema debt.
> 6. Bot-generated content is **hostile text** under the existing UI
>    contract — rendered as Lustre text nodes, never `innerHTML`.
> 7. **Bot CRUD is owned by a separate `bot_registry` actor** (issue
>    #74), not folded into the provider registry — the provider
>    registry's identity is the key-material boundary, and secret-free
>    bots on a growth path through P3 would only bloat it. Registries
>    stay mutually ignorant; orchestration lives with the callers — web
>    and UI runtime, through `nexus/thread_create` (Phase 1, "Process
>    ownership").

## Vocabulary

- **bot** — the named profile entity (table `bot`, singular per schema
  convention). "Profile" is a synonym in discussion; `bot` is the
  schema/API name (`bot`, `profile` both verified non-keywords in
  Postgres; `bot` chosen — shorter, and "profile" will be wanted for
  user accounts later).
- **thread** — the chat entity, exactly as today. Unchanged semantics;
  gains `bot_id` provenance and (P2) a `toolset` snapshot.
- **toolset** — an ordered list of tool names. On `bot`: `NULL` = the
  *current* default, resolved when a thread is created
  (`tools.default(cfg)`); `'{}'` = deliberately empty (a chat-only bot
  is legitimate — its envelope is defined in P2); a non-empty array =
  explicit list. On `thread`: always the **resolved names persisted at
  creation** — never NULL-for-default — so neither a config change nor
  a bot edit can re-aim an existing thread's envelope (decision 2; the
  same rationale as the persisted `system_prompt`). Landed form: the
  column is NOT NULL in the base CREATE — under the pre-deployment
  rule there are no pre-P2 rows anywhere, so no materialization path
  exists. A future deployment that upgrades a database created before
  this phase would need one (a first-boot stamp of the boot-resolved
  default into each NULL row, after which they are ordinary snapshot
  rows — never a read path resolving `NULL` against live config); that
  is future work, deliberately not built now.

## Design summary

The schema is already shaped for this: `thread.provider_id`, `model`,
and `system_prompt` are stored per row, frozen at creation (contract
rule 2) precisely so hydration rebuilds the prefix byte-identically. A
bot adds one indirection in front of that freeze:

```
bot (id, name, description, provider_id, model, system_prompt?, tools?)
                  │  create thread from bot        ┌────────────────┐
                  └──────────────────────────────► │ thread          │
                        copy at creation           │ provider_id     │
                                                   │ model           │
                                                   │ system_prompt   │
                                                   │ toolset?   (P2) │
                                                   │ bot_id  (nullable provenance)
                                                   └────────────────┘
```

Consequences that make the contract safe by construction:

- **Bot edits apply to new threads only.** The frozen columns are the
  thread's truth; the bot row is never joined at request-encoding time.
- **`ON DELETE SET NULL` for `thread.bot_id`** — deleting a bot orphans
  nothing; its threads are self-contained. (Unlike `provider_id`, which
  stays `RESTRICT` because it is live at request time.)
- **`bot.provider_id` is `RESTRICT`** like `thread.provider_id` —
  `delete_provider.sql`'s count-based 409 pre-check grows a bot count
  (`count_bots_for_provider.sql`).

## Phase 0 — rename prerequisite — DONE

`session` → `thread` everywhere (tables, modules, types, wire keys,
`?thread=` query param, CSS classes, tests, docs). Landed as `212eea`
(PR #70) after the migration squash (`cecd906`) — the rename was pure
base-CREATE edits, no migration. Deliberate leftovers: browser-API
`sessionStorage` usage in `page.gleam` (that "session" is the browser's
word, and the word is now free for connection/auth scopes), and
completed plan docs kept as historical records under their old names.

## Phase 1 — bot entity + create-thread-from-bot — DONE

**Scope:** bots exist, threads can name their bot, UI can create both.
No contract changes — every thread still runs `tools.default(cfg)`.

Schema (pre-deployment rule: edit the base `CREATE`s in
`sql/schema.sql`, keep them idempotent). These are base-`CREATE` edits,
not upgrade statements — `schema.sql` carries no `ALTER TABLE`s, and
`CREATE TABLE IF NOT EXISTS` skips an already-existing `thread`. On a
database created before this phase the failure is loud but partial:
`bot` and `bot_name` apply, then `thread_bot` fails (`thread.bot_id`
does not exist) and `apply_schema` panics mid-file, leaving a
half-applied schema. Pre-deployment means
dev databases are **recreated** (`docker compose down -v && docker
compose up -d`), never upgraded; no backfill statements are kept.

```sql
CREATE TABLE IF NOT EXISTS bot (
  id            text PRIMARY KEY,
  name          text NOT NULL,
  description   text NOT NULL DEFAULT '',
  provider_id   text NOT NULL REFERENCES provider(id) ON DELETE RESTRICT,
  model         text NOT NULL,               -- alias, validated live like POST /threads
  system_prompt text,                        -- NULL = global default, resolved AT CREATION
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS bot_name ON bot (name);

-- new final column inside the existing CREATE TABLE thread:
CREATE TABLE IF NOT EXISTS thread (
  -- …existing columns unchanged…
  message_count  int NOT NULL DEFAULT 0,
  bot_id         text REFERENCES bot(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS thread_bot ON thread (bot_id);
```

`system_prompt` NULL-resolution happens at creation: `NULL` resolves
to `cfg.system_prompt` **verbatim** — whatever `config.from_env`
computed, which includes the codemode ASCII note only when the value
is the built-in default (the note rides the default prompt only; an
explicit prompt is never amended). An explicit `bot.system_prompt`
follows the same default-versus-explicit rule as an explicit
`NEXUS_SYSTEM_PROMPT`: used verbatim, never amended. Either way the
stored thread value is the full frozen prompt, so hydration is
unchanged.

Store (squirrel, one query per file, then `gleam run -m squirrel`):
`insert_bot`, `get_bot`, `list_bots`, `update_bot`, `delete_bot`,
`count_bots_for_provider`; `insert_thread.sql` grows a `bot_id` column;
`get_thread`/`list_threads` return it.

### Process ownership — the bot registry (#74)

All store access other than the thread commit hook goes through a
registry (ARCHITECTURE.md §8 rule 2), so bot rows get their own small
actor: `nexus/bot_registry`, a `gleam_otp` actor around the store seam
following the provider-registry pattern **minus its security machinery**
— bots carry no key material, so there is no envelope to
decrypt-validate at boot and no resolve memo, and no network call ever
runs inside it (nothing `ListModels`-like to quarantine).

- **Messages** mirror provider CRUD — `List`, `Get`, `Create(params)`,
  `Update(id, patch)`, `Delete(id)`, the patch a present-fields-replace
  `BotUpdate` record like `provider.ProviderUpdate` — with a closed
  error vocabulary
  (`Unknown`, `InvalidName`, `DuplicateName`, `StoreFailed`) the HTTP
  layer maps exactly like `provider_registry.RegistryError`.
- **State**: the whole table loaded once at start (uniform with the
  provider registry, so the duplicate-name pre-check answers from
  state; `bot_name` stays the backstop), write-through on CRUD. Unlike
  providers there is nothing to validate at load — a bot row cannot
  be invalid at rest, and a stale model alias is legitimate (it is
  caught at thread create, below). The load itself still fails boot on
  an unreachable store, exactly as the provider registry's does.
- **Boot slot**: after the provider registry, before the factory —
  start order becomes store → provider registry → **bot registry** →
  factory → thread registry → mist. Strictly the actor needs only the
  store; the slot groups the settings entities. Under the OneForAll
  root the split buys no isolation and folding would buy none either
  — this decision is about message surface and state ownership.
- **No registry→registry edges** (the §8-shaped rule to record):
  - `delete_provider`'s bot guard is a **store count** —
    `count_bots_for_provider` inside the provider registry, exactly
    like `count_threads_for_provider` today, riding both halves of the
    guard (the pre-check and the post-error `still_pinned` recheck) —
    never a call into the bot registry.
  - `POST`/`PATCH /bots` validate `provider_id` against the
    provider-registry subject the web layer already holds (friendly
    400 — a PATCH can move a bot between providers); the
    `ON DELETE RESTRICT` FK is the backstop.
  - Create-from-bot orchestration extends `nexus/thread_create` (#73,
    in flight as PR #83) — the one creation path its two callers
    share once #72/#73 land (web routes and the UI runtime's create
    effect each had their own before): resolve the bot → re-validate
    the model alias against the provider's live list →
    `thread_registry.create`. #83's `NewThread(provider_id, model,
    system_prompt)` — `None` resolving to `cfg.system_prompt` at the
    one creation point — grows by exactly one field here: `bot_id`,
    persisted as provenance (#83 defers the field for exactly this
    PR; there is no column to fill before Phase 1's schema). The bot
    registry never resolves providers; the thread registry never sees
    bots beyond the `bot_id` column.
  - P3 keeps it CRUD-only: bot-to-bot delivery goes through the thread
    registry (Phase 3). The bot registry's callers are the web/UI
    surfaces and — from P3, if the delivery tool needs the sender's
    identity — the **unlinked turn worker**, reading worker-side the
    way the utility worker asks the thread registry (§8 rule 1's
    exception class); no thread actor's loop ever calls it.
- **Rejected alternative** — folding bots into the provider registry
  ("both are settings entities"): that is a UI-similarity argument, not
  an ownership one. The provider registry's contract is key custody at
  stable scope, while bots grow through P2/P3; folding's one advantage
  (validating `bot.provider_id` against the in-state provider list) is
  had instead by the web-layer check above.
- **ARCHITECTURE.md** rides in the Phase 1 implementation PR, landed
  together with the code, never in a doc-only PR ahead of it (the
  file's header has it track HEAD, so it must not describe the actor
  before the actor exists): §2 supervision tree (new
  child after the provider registry; start steps renumbered), §3
  inventory row, §4 communication map (`rt → bot registry` for the
  Settings Bots section AND the create-from-bot flow, `api → bot
  registry` for `/bots`; create-from-bot fans out from the callers
  through `thread_create`, so it adds no registry-to-registry edge), §6 "Bot registry" subsection after Provider
  registry recording the no-cross-edges rule (store counts, not actor
  calls). Coverage: a bot-registry actor test against the store mock
  (CRUD round-trip, in-state name pre-check, unknown-id update/delete),
  plus the provider-side `delete_provider` 409 while bots pin.

Wire (`web.gleam`, following the `/providers` pattern):
`GET/POST/PATCH/DELETE /bots`. `POST /threads` accepts either
`{"provider", "model"}` (today's shape, `bot_id` NULL) or `{"bot": id}`
(provider/model/system_prompt sourced from the bot, model alias
re-validated against the provider's live list — a bot can go stale, the
create must not silently succeed on a dead alias).

UI:
- Settings surface (`ui_settings.gleam`) gains a Bots section — per-row
  inline editor, add form, two-step delete, mirroring the provider rows.
- New-thread flow gains "start from bot"; the sidebar thread row shows
  the bot name as subtitle/provenance when `bot_id` is set.

Tests (offline-first, per conventions): store CRUD through the mock
seam (`test/store_mock.gleam`); creation sourcing (bot → frozen
columns, NULL system-prompt resolution, stale-alias 400); UI rendering
of bot-sourced fields with `<script>` payloads in names/descriptions;
browser-suite coverage for the picker and settings section.

## Phase 2 — per-bot toolsets (invariant amendment) — DONE

Landed on `t3/bots-phase-2`: `bot.tools text[] NULL` (the write
sentinel is an is-default bool — `'{}'` is meaningful, so no
nullif-style value sentinel can express NULL) and `thread.toolset
text[] NOT NULL`, always populated at insert with the resolved names.
The registry resolves toolsets through the per-toolset bundle cache
(#76 prep), `loop.frozen_options` omits `tools`/`tool_choice` for the
empty toolset, bot save validates names through the injected catalog
seam (boot wires `tools.by_names`; the registry stays config-free),
hydration resolves snapshots with loud failure on absent names, and
the AGENTS.md invariant carries the amended form. Pre-deployment rule
held: the snapshot column is NOT NULL in the base CREATE and dev
databases are recreated — see the vocabulary note above for what a
future pre-P2 deployment would need.

Verification outcomes: `m3_prefix_test` passed unchanged; 621 offline
tests green; the e2e cache gate re-run on default-toolset threads —
warm/cold TTFT median ratio **0.234 ≤ 0.3** (cold ~3.1s, warm ~0.7s
medians). The smoke's secondary `cached_tokens` assertion could not
run: the gateway's vLLM backends do not report `prompt_tokens_details`
through Bifrost right now (the TTFT ratio is the PRD gate; the token
check is conditional until usage flows again).

**Scope:** `bot.tools text[] NULL` on the bot (NULL = current
default), and `thread.toolset text[]` always populated at creation
with the resolved names — plain threads snapshot the default set,
bot threads snapshot the bot-resolved list. This is the phase that
touches a hard invariant, so it lands alone, with its AGENTS.md
rewrite in the same PR.

The amended invariant (AGENTS.md "One frozen toolset for every thread"):

> One frozen toolset **per thread**, persisted at creation as resolved
> tool names (the default set's, or the creating bot's). Runners are
> built per toolset and
> cached by toolset identity. `tools` / `tool_choice` never vary
> mid-thread — that is the part the KV-cache byte contract needs.

Why this is safe (serving facts live in the `.agents/skills/llm-api`
skill; this doc cites them, it does not re-derive them): the cache is
keyed on exact token prefixes; divergent heads across threads don't
break anything, they simply don't share spans. Threads of the same bot
still share their system+tools head (per-bot cross-thread reuse); the
system prompt is already per-thread, so the only sharing given up is
the tools array across *different* bots — accepted. The utility branch
(titles/tags) rides the thread's own envelope, so it keeps hitting as
long as the per-thread utility runner uses the same specs — which the
registry already guarantees by construction (same `specs` build turn
and utility runners; that property must be preserved per toolset).

Mechanics:
- `tools.by_names(cfg, names)` resolver in the tool registry; unknown
  name at bot save or thread create → 400 (validated against the same
  registry that builds schemas).
- **codemode's host list is per-toolset** (surfaced by #76, not
  previously stated here): `tools.by_names` builds codemode LAST
  capturing its siblings, and under per-toolset resolution those
  siblings are exactly the thread's own toolset minus codemode, in
  toolset order. A codemode script can reach only the tools of the
  thread (bot) it runs on — the global boot registry no longer exists
  to leak from — and a bot whose toolset omits codemode simply has no
  bridge. Validation note: a toolset of ONLY codemode resolves fine —
  with zero hosts it cannot call sibling tools, but the script itself
  still runs pure Lua and emits `text`/`return` output; save-time
  validation MAY reject it as a UX nicety, not a correctness need.
- **The no-tools envelope is omission.** A `'{}'`-toolset thread sends
  neither `tools` nor `tool_choice`: the single encode path already
  branches this way (`transcript.request_body` skips `with_tools` for
  `[]` and `with_tool_choice` for `None`), so no encoder change is
  needed — only `loop.gleam`'s turn Options, which today always carry
  non-empty schemas and `Some(ToolChoiceAuto)`, gain the per-thread
  form. The omitted-fields envelope is frozen at creation like any
  other.
- `thread_registry` builds specs once per distinct toolset (cache keyed
  by the name tuple — the default snapshot resolves to today's boot
  tuple, so it shares the boot-built runner). The `start_with_runner`
  test seam extended to per-toolset bundles (`start_with_toolset` /
  `CreateWithToolset` / `create_with_toolset`, #76).
- **`thread.toolset` is always a resolved snapshot** (coderabbit
  review, PR #71): plain threads persist the default set's names at
  creation, bot threads persist the bot-resolved list (`bot.tools`
  NULL = the current default, so the bot stays a live template for
  NEW threads). A NULL-for-default column would have re-aimed every
  default thread's envelope on a config change + restart — exactly
  what the persisted `system_prompt` exists to prevent. Hydration
  resolves names via `tools.by_names` against a **config-independent**
  catalog — a snapshot pins its tools past later config gating (the
  freeze overrides the gate: disabling codemode globally cannot brick
  threads that pinned it). A name absent from the compiled code
  entirely (removed by an upgrade) **fails hydration loudly** — no
  silent skip, matching the repo's no-silent-fallback boot philosophy;
  the remedy is recreating the thread or hand-editing its row.

Verification:
- `test/m3_prefix_test.gleam` passes **unchanged** — the golden's
  contract is per-thread envelope stability, which this phase preserves.
- New offline test: two threads with different toolsets get different
  envelopes by design; one thread's envelope stays byte-identical
  across turns. A chat-only (`'{}'`) thread is covered too — its
  requests stay byte-stable with both `tools` and `tool_choice`
  absent.
- Snapshot stability: a thread's persisted `toolset` keeps its
  envelope byte-identical across a simulated restart with a changed
  default config — the rejected NULL-for-default design would fail
  this test. A toolset naming a tool absent from the codebase fails
  hydration — no silent envelope change.
- `e2e/integration.spec.mjs` cache gate re-run: warm/cold TTFT median
  ratio ≤ 0.3 on default-toolset threads (numbers comparable to today).

## Phase 3 — bot-to-bot messaging (bot as thread user) — DONE

**Scope:** a `bot_message` tool that delivers a message from one bot's
turn into another bot's thread as a user-role turn. Hermes's "one bot
is the user of another bot's session", mapped onto the existing
single-owner model. Delivery goes through the thread registry
(internal actor call, no HTTP loop): append a user-role message, run
the target thread's loop.

**Design settled in the issue #77 session** (remaining gaps closed by
#98) — this section is the record; the slices landed as #99 (P3a), #100
(P3b), #101 (P3c):

1. **Delivery is async — a receipt, not a reply.** The tool returns
   once delivery is accepted or refused, never waiting for the
   target's turn. Sync would need the target actor to hold a reply
   subject across its whole turn state machine (`TurnStarted` →
   `WorkerDone`/`WorkerDown`) and would block the sender's worker past
   every bounded `actor.call` timeout in the repo — 5s on the registry
   and thread ask paths, 20s at the largest (bot/provider CRUD) — none
   of which is sized for a full LLM turn; the
   busy-guard semantics ("sender retries on its next turn") already
   assume async. The receipt names where the reply will land:
   `delivered to <bot> in thread <id>`. Refusals are failed tool
   results (tool errors are not loop errors) — the sender model sees
   the error and adapts. A sync variant (`bot_message_wait`) is a
   recorded non-goal pending P3 learnings.
2. **Addressing takes a bot name or a thread id.** The sender model
   addresses bots by name; the thread registry keeps an in-memory per
   (sender bot, target bot) DM-thread map — find-or-create from the
   target bot through `nexus/thread_create` (no new frozen-value
   path). A restart loses the map and opens a fresh DM thread
   (accepted MVP tradeoff; persisted DM columns would be schema debt
   until proven needed). The receipt and the `From` prefix both carry
   the thread id so replies can address it precisely. Self-addressed
   delivery is refused BEFORE routing — any resolved target whose bot
   is the sender's own bot. The busy guard alone is not enough there:
   a NAME-addressed self-send with no `(A, A)` map entry would
   find-or-create a different, idle A-thread and deliver into it; the
   busy guard only covers thread-id addressing of the in-flight
   thread.
3. **`ToolCtx` grows `delivery: Option(Delivery)`** —
   `Delivery(registry, bots, thread_id, bot_id, depth)`. `Some` only on
   threads created from a bot: the HUMAN default toolset never
   includes the tool (a plain thread has no bot identity to send
   from), while create-from-bot with `bot.tools = NULL` resolves to
   the human default PLUS `bot_message` — bots are the only senders,
   so an ordinary bot gets the feature without listing it, and a bot
   that wants it gone names an explicit list without it (a chat-only
   `'{}'` bot already excludes it). Threads created before P3c keep
   their frozen snapshots without it, like any snapshot change. Identity is per-THREAD, never per-toolset — bundles are
   cached by name tuple and shared across a bot's threads — so the
   registry injects it by wrapping the bundle's turn fn per thread at
   create/hydrate. Depth is computed per turn from the initiating
   user message's sidecar depth + 1 (human sends reset to 0), so it
   survives restart. The sender's display name is resolved at SEND
   time by a worker-side ask to the bot registry (the caller P1
   anticipated): renames stay current, and a deleted sender bot is an
   honest tool error — at send time AND after restart: a hydrated
   thread whose bot was deleted (`thread.bot_id` NULL via
   `ON DELETE SET NULL`) builds no delivery context, so `bot_message`
   fails with the same error. No second durable marker column for
   that — schema debt for a dead-bot edge, inconsistent with P1's
   deletion semantics.
4. **Thread `Send` grows `author` and `depth`** —
   `Send(text, author: Option(String), depth: Int, reply)`, the ONE
   turn-machine path (no parallel `Deliver` message; human sends pass
   `None`/`0`). Model-visible identity rides **content** only:
   `From <bot> (thread <id>): …` — message bytes, append-only,
   contract-clean. UI attribution rides the display-only sidecar
   class: one transcript dict `Dict(Int, Origin)` — `Origin(author,
   depth)`, distinct from the ToolCtx `Delivery` record, which carries
   the per-thread identity — mirroring `timestamps`, set by
   `mark_origin` immediately after
   `append_user` + `stamp` (same call-after-append rule). Persistence:
   `thread_message.author text NULL` (NULL = human; value = the bot's
   display name at send time — frozen like everything a bot sources,
   rename/delete-safe) and `thread_message.hop_depth int NOT NULL
   DEFAULT 0` (base-CREATE edits, pre-deployment rule). All three
   render paths carry the author — live echo, `turn_view` mid-turn
   join, hydration replay (one shape per path; a reload must not drop
   badges). UI: author badge on bot-sourced user lines; bot content
   renders under the hostile-text rules verbatim (it is user
   content).
5. **Guards** (the inter-bot analogue of `max_tool_iterations`),
   checked by the registry in order: unknown target; archived target
   (refuse — archived is quiescent); inbound gate —
   `bot.allow_inbound boolean NOT NULL DEFAULT true` for MVP
   (per-pair allowlists later if needed), read from the store (the
   count/guard pattern, never a bot-registry call); hop depth —
   internal sends carry a depth counter, and the registry refuses
   delivery beyond `max_bot_hops` (`NEXUS_MAX_BOT_HOPS`, config,
   default 4); busy target — a thread mid-turn rejects delivery, and
   the target actor answers immediately in both states (idle: append
   + spawn + `Sent`; busy: `Busy`) since it never blocks on its own
   worker. No queueing in MVP. Reply vocabulary:
   `Delivered(thread_id) | Busy | Refused(reason)`.
6. **§8 rule 1's exception generalizes to a class** (recorded here;
   lands in ARCHITECTURE.md with the P3c PR, per the track-HEAD
   rule): unlinked workers may ask the registries — the utility
   worker today, the turn worker's delivery tool from this phase.
   Deadlock-safe because the ask originates in a worker nothing
   waits on synchronously (the actor monitors, never blocks), the
   registry's answer path is state plus one bounded `actor.call` into
   an idle-or-busy-answering actor, and no path leads from the
   registry back into a waiting worker — no cycle can close.
   Deliveries serialize through the registry actor; under heavy
   cross-traffic a worker's 5s ask can time out as a retryable tool
   error, never a deadlock.

Implementation slices (each landed as its own PR with its own tests;
#99/#100 are independent of each other, #101 depends on both):

- **P3a (#99): inbound gate** — the `bot.allow_inbound` column, the
  bot-registry patch field, `PATCH /bots`, the Settings toggle.
- **P3b (#100): author + hop-depth plumbing** — the schema columns,
  store queries, transcript delivery sidecar, `Send` fields,
  `UserEcho` + both replay paths, the UI badge. Lands producer-free
  (a test seam sets authors; the writer is P3c) — the
  sidecar/replay/persistence parity is where the subtle bugs live,
  and the split keeps the delivery PR reviewable.
- **P3c (#101): the delivery mechanism** — the tool,
  `ToolCtx.delivery` + the per-thread runner wrapper, both worker-side
  asks, registry `Deliver` with routing and guards, the `From`
  prefix, the ARCHITECTURE.md §8 ride-along, `NEXUS_MAX_BOT_HOPS`,
  and the e2e bot-to-bot smoke + cache gate re-run.

Tests: depth and busy guards through the registry seam; author sidecar
round-trip (store mock); replay parity (the live badge and the
post-reload badge render the same author); UI rendering of
bot-authored lines with payload-laden text; loop interaction — a bot
message arriving mid-turn is rejected, not queued, and the UI's
rollback rules are untouched.

## Non-goals (recorded, not planned)

- **Shared chat rooms** (one transcript, multiple assistant
  identities) — changes thread ownership/turn semantics fundamentally;
  revisit after P3 proves DM-style collaboration.
- **Skills lists on bots** — no skills system exists in nexus yet.
  When one lands, `bot.skills` follows the same snapshot-at-creation
  pattern as `toolset`.
- **Bot autonomy/scheduling** (bots acting without an incoming
  message), bot avatars/themes, and an external bot-to-bot HTTP API.

## Invariant checklist (what this plan must not break)

- Per-thread envelope freeze: model alias, system prompt, `tools`,
  `tool_choice` never vary mid-thread. Bots only ever source
  frozen-at-creation values.
- Single encode path (`nexus/transcript`) — bot threads hydrate through
  it like any other; no bot-specific request shaping.
- `thread_message.tool_args` stays `text`; `reasoning`/`created_at` (and
  the new `author`) stay display-only sidecars, never request bytes.
- `thread.message_count` / `seq` semantics unchanged (a bot-delivered
  user turn is one row, seq append-only).
- One frozen toolset per thread (amended P2 form); the registry's
  turn/utility same-specs property preserved per toolset.
- Hostile text: everything bot-sourced renders as Lustre text nodes.
- Offline `gleam test` stays network-free — persistence via the mock
  seam; live DB only in migrate/e2e paths.
