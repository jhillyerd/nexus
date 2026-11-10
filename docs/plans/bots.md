---
title: Nexus — bots and profiles (named thread templates, per-bot toolsets, bot-to-bot messaging)
status: active
tags: [nexus, bots, threads, agents, kv-cache, gleam, beam]
updated: 2026-11-10
---

# Bots and profiles

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
  same rationale as the persisted `system_prompt`). Pre-P2 rows with
  `NULL` hydrate as the default set.

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

## Phase 1 — bot entity + create-thread-from-bot

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

## Phase 2 — per-bot toolsets (invariant amendment)

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
  tuple, so it shares the boot-built runner). The existing
  `start_with_runner` test seam extends to per-toolset runners.
- **`thread.toolset` is always a resolved snapshot** (coderabbit
  review, PR #71): plain threads persist the default set's names at
  creation, bot threads persist the bot-resolved list (`bot.tools`
  NULL = the current default, so the bot stays a live template for
  NEW threads). A NULL-for-default column would have re-aimed every
  default thread's envelope on a config change + restart — exactly
  what the persisted `system_prompt` exists to prevent. Hydration
  resolves names through the boot registry (`tools.by_names`); a name
  removed by an upgrade is skipped with a warning — the same envelope
  shift a default-set change causes today.

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
  this test.
- `e2e/integration.spec.mjs` cache gate re-run: warm/cold TTFT median
  ratio ≤ 0.3 on default-toolset threads (numbers comparable to today).

## Phase 3 — bot-to-bot messaging (bot as thread user)

**Scope:** a `bot_message`-style tool (exact name TBD) that delivers a
message from one bot's turn into another bot's thread as a user-role
turn. Hermes's "one bot is the user of another bot's session", mapped
onto the existing single-owner model:

- Delivery goes through the thread registry (internal actor call, no
  HTTP loop): append a user-role message, run the target thread's loop.
- Model-visible identity rides the **content** (a `From <bot>: …`
  prefix — message bytes, append-only, contract-clean). UI attribution
  rides a **display-only sidecar**: `thread_message.author text NULL`
  (NULL = human), the same never-in-request-bytes class as `reasoning`
  and `created_at`.
- **Guards** (the inter-bot analogue of `max_tool_iterations`):
  1. *Busy target* — a thread mid-turn rejects delivery; the rejection
     surfaces as the sender's tool error (no queueing in MVP — the
     sender bot can retry on its next turn).
  2. *Hop depth* — internal sends carry a depth counter; beyond
     `max_bot_hops` (config, default 4) the registry refuses delivery.
  3. *Inbound gate* — `bot.allow_inbound boolean NOT NULL DEFAULT true`
     for MVP; per-pair allowlists later if needed.
- UI: author badge on bot-sourced user lines; bot content renders under
  the hostile-text rules verbatim (it is user content).

Tests: depth and busy guards through the registry seam; author sidecar
round-trip (store mock); UI rendering of bot-authored lines with
payload-laden text; loop interaction — a bot message arriving mid-turn
is rejected, not queued, and the UI's rollback rules are untouched.

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
