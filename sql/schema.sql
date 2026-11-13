-- Nexus thread persistence (Phase 2).
--
-- Tables are singular and explicit (`thread`, `thread_message`): each
-- row is one entity, and the messages table's link to its thread stays
-- obvious as the schema grows.
--
-- The schema maps 1:1 onto the Phase 1 `ThreadSummary` field set
-- (src/nexus/thread.gleam): id, title, title_source, model, system_prompt,
-- pinned, archived, tags, created_at, last_active_at, message_count —
-- plus the multi-provider link `provider_id`
-- (docs/plans/multi-provider.md).
--
-- Timestamps are `timestamptz` (the Phase 2 round-trip spike measured a
-- naive `timestamp` column shifting +9h when `now()` was cast under a
-- Postgres connection left in a non-UTC `TimeZone`): the app reads them as epoch seconds via
-- `extract(epoch from x)::int8` (matching Phase 1's wire format) and writes
-- them through server-side `now()`; explicit params are rare and cast
-- `$1::timestamptz` from text.
--
-- Design notes (approved plan):
-- - tags as text[] + GIN — no join table.
-- - delete is a hard DELETE cascading to thread_message; `archived_at`
--   is the only soft state.
-- - message bodies stay plain text so FTS can be added later as a
--   tsvector generated column + index — no FTS now.
-- - MetricSample history stays in memory; persisting it is out of scope.
--
-- Provider design notes (docs/plans/multi-provider.md §5):
-- - `provider` is declared BEFORE `thread`: the `thread.provider_id`
--   FK target must exist first.
-- - `api_key_encrypted` is the nexus/crypto AES-256-GCM envelope
--   (`0x01 || nonce(12) || tag(16) || ciphertext`, AAD = provider id);
--   NULL means a keyless provider (local Ollama / llama.cpp endpoints).
--   The store only ever moves ciphertext — encryption lives in the
--   provider registry.
-- - `key_version` is 1 today; the column makes later rotation additive.
-- - `dialect` is always 'openai' today; the column keeps future dialects
--   a data change, not a schema change.
-- - `ON DELETE RESTRICT` + the registry's `409` pre-check: deleting a
--   referenced provider is refused; disabling is the reversible path.
--
-- Bot design notes (docs/plans/bots.md, Phase 1):
-- - `bot` is a creation-time template, NOT a runtime dependency: creating
--   a thread from a bot COPIES provider/model/system_prompt into the
--   thread's frozen-at-creation columns; editing or deleting a bot never
--   changes an existing thread. `thread.bot_id` is provenance/display
--   only, which is why it is `ON DELETE SET NULL` — deleting a bot
--   orphans nothing (`provider_id` stays RESTRICT: it is live at request
--   time, and `delete_provider`'s 409 pre-check counts bots too).
-- - `bot.system_prompt` NULL = the global default, resolved AT CREATION
--   into the thread's frozen `system_prompt` (same rule as an explicit
--   NEXUS_SYSTEM_PROMPT); never resolved at request time.
-- - `bot.tools` (bots plan Phase 2) is the LIVE template list: NULL = the
--   current default set, resolved AT CREATION into the new thread's
--   snapshot; `'{}'` = deliberately empty (a chat-only bot); a non-empty
--   array = an explicit list. Validated against the compiled-in catalog
--   at save time; a stale entry is refused again at thread create.
--
-- Phase 2 invariant amendment (landed alone with its AGENTS.md rewrite):
-- one frozen toolset PER THREAD — `thread.toolset` below is always the
-- resolved names persisted at creation, never NULL-for-default, so a
-- config or bot edit can never re-aim an existing thread's envelope.

CREATE TABLE IF NOT EXISTS provider (
  id                 text PRIMARY KEY,
  name               text NOT NULL UNIQUE,          -- display + lookup key
  base_url           text NOT NULL,                 -- OpenAI-compatible, ends /v1
  api_key_encrypted  bytea,                         -- NULL = keyless (local endpoints)
  key_version        int NOT NULL DEFAULT 1,
  dialect            text NOT NULL DEFAULT 'openai',-- future: 'anthropic', …
  enabled            boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL,
  updated_at         timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS provider_enabled ON provider (enabled);

CREATE TABLE IF NOT EXISTS bot (
  id            text PRIMARY KEY,
  name          text NOT NULL,                   -- display + lookup key (unique)
  description   text NOT NULL DEFAULT '',
  provider_id   text NOT NULL REFERENCES provider(id) ON DELETE RESTRICT,
                                                -- RESTRICT like thread.provider_id: a bot cannot outlive its provider;
                                                -- the registry's delete pre-check counts bots (count_bots_for_provider)
  model         text NOT NULL,                  -- alias, validated live at thread create (a bot can go stale)
  system_prompt text,                           -- NULL = global default, resolved AT CREATION into the thread's frozen prompt
  tools         text[],                         -- NULL = the current default set, resolved AT CREATION; '{}' = chat-only; else explicit names (validated against the compiled catalog at save)
  allow_inbound boolean NOT NULL DEFAULT true,  -- bots plan P3a (#95): the inbound gate — false blocks other bots from delivering messages into this bot's threads (the P3c delivery guard reads it via a STORE read, never a bot-registry call). Nothing consumes it until P3c ships.
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS bot_name ON bot (name);

CREATE TABLE IF NOT EXISTS thread (
  id             text PRIMARY KEY,             -- existing user-visible thread id
  provider_id    text NOT NULL REFERENCES provider(id) ON DELETE RESTRICT,
                                                -- frozen at creation with the model (contract rule 2)
  title          text NOT NULL,
  title_source   text NOT NULL DEFAULT 'auto', -- 'auto' | 'manual'
  model          text NOT NULL,                -- frozen alias (contract rule 2)
  system_prompt  text NOT NULL,                -- frozen at creation (contract rule 2); stored so hydration rebuilds the frozen prefix byte-identically
  pinned         boolean NOT NULL DEFAULT false,
  archived_at    timestamptz,                  -- NULL = active
  tags           text[] NOT NULL DEFAULT '{}', -- display set: manual ∪ auto, recomputed on write (utility-tags plan §3.4)
  tags_manual    text[] NOT NULL DEFAULT '{}', -- the user's exact set; display − manual is the auto contribution. No join table; GIN-indexed via `tags`
  tags_source    text NOT NULL DEFAULT 'auto', -- 'auto' | 'manual' (mirrors title_source): the first manual tag save (set_tags.sql) flips it to 'manual' forever — the guard IS the tombstone a future refresh policy reads
  created_at     timestamptz NOT NULL,
  last_active_at timestamptz NOT NULL,         -- bumped on turn commit; drives recency + buckets
  message_count  int NOT NULL DEFAULT 0,       -- denormalized for list queries
  toolset        text[] NOT NULL,              -- bots plan P2: the RESOLVED tool names persisted at creation (default set's, or the creating bot's) — a snapshot, never NULL-for-default, so no config change or bot edit can re-aim this thread's envelope
  bot_id         text REFERENCES bot(id) ON DELETE SET NULL
                                                -- provenance/display only (bots plan P1): which bot the frozen columns
                                                -- were sourced from. Never joined at request-encoding time; deleting
                                                -- the bot NULLs it — the thread is self-contained.
);

CREATE INDEX IF NOT EXISTS thread_recency ON thread (archived_at, last_active_at DESC);
CREATE INDEX IF NOT EXISTS thread_tags ON thread USING gin (tags);
CREATE INDEX IF NOT EXISTS thread_bot ON thread (bot_id);

CREATE TABLE IF NOT EXISTS thread_message (
  id           bigserial PRIMARY KEY,
  thread_id   text NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
  seq          int NOT NULL,                   -- append-only order
  role         text NOT NULL,                  -- 'user' | 'assistant' | 'tool' (transcript roles)
  content      text NOT NULL,                  -- exact transcript content, never mutated
  tool_call_id text,
  tool_name    text,
  tool_args    text,                           -- raw argument JSON as the model emitted it. NOTE: deliberately text, not jsonb: jsonb normalizes (sorts keys, strips whitespace, dedupes), which would break the byte-identical hydration contract for tool-call arguments that sit above the request tail (see the `tool_args` invariant in AGENTS.md)
  tool_ok      boolean,
  reasoning    text,                           -- display-only chain-of-thought emitted before an assistant message; NULL for user/tool rows and reasoning-free messages. Plain text for the same byte-stability rationale as tool_args. Never sent back to the model.
  created_at   timestamptz,                    -- display-only wall-clock stamp of the message (drives the chat log's relative ages). Deliberately nullable: the store's 0 sentinel writes NULL for unstamped rows (to_timestamp(nullif($n, 0))) instead of borrowing the write instant as a fake append time; unstamped rows render without a timestamp. Never sent back to the model.
  UNIQUE (thread_id, seq)
);

