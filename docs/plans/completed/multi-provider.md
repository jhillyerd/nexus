---
title: Nexus — multiple LLM providers, provider keys, and models
status: approved
tags: [nexus, providers, models, secrets, schema, kv-cache]
updated: 2026-10-18
---

# Nexus: multiple providers, provider keys, and models

Design + migration plan for moving nexus from **one hard-coded Bifrost
endpoint** to **N provider endpoints each with its own (encrypted) key**,
with **provider + model pinned per session**.

> Decisions captured here came out of the 2026-10-18 planning session;
> implementation is split into the phased roadmap (§17), each phase to be
> kicked off separately. Revised the same day after the pre-work merges
> landed on main: #5 (no boot session + boot sweep), #6 (quote-aware
> migrate splitter), #7 (audit tool decoupled to `audit/ttft`, and
> `nexus/openai` now takes a narrow `Endpoint` record — see §2).

## 1. Goal and non-goals

**Goal.** Let one nexus instance talk to N independent OpenAI-compatible
`/v1` endpoints ("providers"), each with its own base URL and optional
bearer key. Provider keys are stored in Postgres, encrypted at rest.
Every session pins exactly one `(provider, model)` pair for its lifetime.

**Non-goals (this plan).**

- Native non-OpenAI dialects (Anthropic Messages, Gemini). Providers stay
  OpenAI-compatible; the registry carries a `dialect` field defaulting to
  `openai` so a future dialect does not need a schema change.
- Multi-user. Auth stays the single `NEXUS_UI_TOKEN`.
- Per-provider retry/failover or routing between providers. A session's
  provider is fixed; recovery is out of scope.
- Provider health/scoring, cost accounting.

## 2. Current state (after the pre-work merges)

| Seam | File | Today |
|---|---|---|
| Config | `src/nexus/config.gleam` | one `base_url` (must end `/v1`) + `api_key` + `model_default`, all required |
| Transport | `src/nexus/openai.gleam` | **already endpoint-shaped**: `Endpoint(base_url, api_key: Option, sse timeouts)`; `stream`/`stream_with_cancel`/`list_models` take it; `endpoint_from_config(cfg)` derives it; `drop_empty_bearer` omits auth for keyless |
| Loop | `src/nexus/loop.gleam` | `bifrost_stream(cfg)` — still wraps `endpoint_from_config(cfg)` |
| Session | `src/nexus/session.gleam` | `agent_runner(cfg, specs)` closes over global `cfg`; `TurnRunner = fn(Config, Transcript, cancel, on_event)` |
| Model | `src/nexus/transcript.gleam` | `Transcript(model: String, …)` — the only model identity |
| Schema | `sql/schema.sql` | `session.model text` — alias only, provider implicit |
| Web | `src/nexus/web.gleam` | `GET /models`, `POST /sessions {model}` |
| UI | `src/nexus/ui.gleam` | one flat alias list; subtitle `model · relative time` |
| Boot | `src/nexus/boot.gleam` | mints **no** session (PR #5); creation is user-initiated, create panel auto-opens |
| Audit tool | `src/audit/ttft.gleam` + `src/audit/config.gleam` | own `NEXUS_AUDIT_*` env, builds its own `Endpoint` (PR #7) |

The PR #7 `Endpoint` seam is the big head start: the transport already
takes a per-endpoint record with an **optional** key (keyless endpoints
drop the Authorization header entirely), and glopenai is instantiated per
request from it. What is still single-provider: where the `Endpoint`
comes from (`endpoint_from_config` — one env pair), the loop/session
signatures (still `Config`), and the schema/UI/model picker.

The KV-cache contract (`docs/plans/mvp-requirements.md`) is the binding
constraint: provider + model are frozen at session creation (like the
system prompt), append-only transcript, one encode path, byte-identical
prefix. A mid-session provider/model switch is a **fork**, never an
in-place edit.

## 3. Decisions (this planning session)

1. **Multiple OpenAI-compatible endpoints** — nexus owns N provider
   definitions; it does not delegate provider identity to Bifrost.
2. **Keys in Postgres, encrypted at rest.**
3. **Provider + model pinned per session** (frozen like the alias today).
4. **Hard cut** on `BIFROST_BASE_URL` / `BIFROST_API_KEY` — removed from
   the server config; DB is the only source of providers.
5. **Single `NEXUS_ENCRYPTION_KEY`** master key (`key_version` stays 1;
   the column exists so rotation is additive later).
6. **Disable by default; hard delete only when unreferenced** — deleting a
   referenced provider is a `409`.
7. **Keyless providers allowed** — `api_key` optional (local Ollama /
   LM Studio / llama.cpp).
8. **Pre-deployment schema edit, not a migration** — nexus has not been
   deployed, so `sql/schema.sql` is edited in place (per `AGENTS.md`);
   no `ALTER`, no backfill, no legacy NULL handling.
9. **Pre-work landed before implementation** (main, 2026-10-18): the
   migrate splitter is quote-aware (#6, was "optional" in the draft), the
   audit tool is decoupled as `audit/ttft` with its own env (#7, was a P6
   precondition), and no boot session is minted (#5 — so this plan must
   not reintroduce one).

## 4. Architecture overview

```
boot
 └─ root supervisor (OneForAll)
    ├─ persist store actor        (ciphertext in/out, unchanged seam shape)
    ├─ provider_registry actor    (NEW: decrypt, cache, CRUD, resolve)
    ├─ session factory supervisor
    ├─ session_registry actor
    ├─ ui_runtime
    └─ mist

session actor ──frozen openai.Endpoint──> loop.run ──> openai.stream(endpoint, …)
                       ▲
                       └── resolved by provider_id at create / hydration
```

- `nexus/crypto` — pure AES-256-GCM over OTP `crypto` (FFI). No provider
  logic.
- `nexus/provider` — pure types + validation + masking (`Provider` row
  metadata, base-URL normalization, `has_key` hinting).
- `nexus/provider_registry` — actor: load from store, decrypt lazily,
  cache, CRUD, resolve `provider_id` → runtime `openai.Endpoint` plus
  metadata.
- Store stays dumb: it reads/writes **ciphertext only**. Encryption lives
  in the registry, so the mockable seam never handles plaintext and offline
  tests can fake crypto.
- The draft's `ProviderSpec` collapses into the **existing**
  `openai.Endpoint` (PR #7) plus a small `Provider` metadata record — no
  new runtime shape is invented.

## 5. Data model

### 5.1 New table (insert into `sql/schema.sql`)

Singular name, `<table>_<purpose>` indexes, `timestamptz` timestamps,
per `AGENTS.md`. **Declared before `session`** — `session.provider_id`
references it (§5.2), and the FK target must exist first.

```sql
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
```

`name` is unique → implicit unique index satisfies lookups by name;
`provider_enabled` supports the picker's `enabled = true` filter.

### 5.2 Session link (edit the existing `CREATE TABLE session`)

Because nexus is pre-deployment, add the column straight to the existing
`session` DDL rather than via `ALTER`:

```sql
provider_id  text NOT NULL REFERENCES provider(id) ON DELETE RESTRICT,
```

`NOT NULL` is safe — there are no rows to backfill (every local database is
disposable; §15). New sessions always write an explicit id, so no
NULL/legacy path exists. `ON DELETE RESTRICT` enforces the "hard delete
only if unreferenced" rule at the DB layer, backed by the registry's `409`
pre-check.

The `migrate` splitter is no longer a constraint at all: it is
quote-aware since #6 (single/double/dollar quotes, `--` lines, nested
`/* */` — see `AGENTS.md` and `test/migrate_test.gleam`), and the change is
a plain `CREATE` edit regardless. Moving the `session` block below the new
`provider` block is the only structural care needed.

### 5.3 Queries (`src/nexus/store/sql/*.sql`, one per file, filename = fn name)

New:

- `list_providers.sql` — all providers, ciphertext + key_version included
  (the store hands ciphertext to the registry).
- `get_provider.sql`
- `insert_provider.sql`
- `update_provider.sql` — name / base_url / key envelope / key_version /
  enabled / updated_at; present-key semantics via `COALESCE` or explicit
  full-row update. **Key replacement vs. keep** must be distinguishable:
  use a boolean `replace_key` flag so "PATCH without api_key" keeps the
  existing ciphertext instead of nulling it.
- `delete_provider.sql`
- `count_sessions_for_provider.sql` — the `409` guard.

Amended:

- `insert_session.sql`, `get_session.sql`, `list_summaries.sql` — carry
  `provider_id`; regenerate row types in `src/nexus/store/persist.gleam`.

Regenerate with `gleam run -m squirrel` and commit; CI's `squirrel check`
gates drift.

### 5.4 Migration splitter hardening — **landed** (#6)

`nexus/store/migrate.gleam`'s statement splitter is now quote-aware
(single/double quotes, dollar quotes `$$…$$` / `$tag$…$tag$`, `--` lines,
nested `/* */`), so future `DO $$…$$` blocks, `CREATE FUNCTION` bodies, or
literals containing `;` split correctly. Documented in `AGENTS.md`; unit
tests in `test/migrate_test.gleam`. Nothing left to do here.

## 6. Encryption at rest (`nexus/crypto`)

- **Algorithm:** AES-256-GCM via OTP `crypto`. New FFI module
  `src/nexus_crypto_ffi.erl`.
- **Master key:** `NEXUS_ENCRYPTION_KEY` = base64 of exactly 32 random
  bytes (`openssl rand -base64 32`). Validated at boot; wrong length /
  missing → boot fails loudly (matches the existing fail-fast config
  style). No default, no derived key.
- **Envelope** (single `bytea` column `api_key_encrypted`):
  `0x01 || nonce(12) || tag(16) || ciphertext`. Version byte allows a
  format change independent of `key_version`.
- **AAD = provider id** — binds ciphertext to its row; a swapped/copied
  envelope fails authentication.
- **Nonce:** 12 random bytes per encryption (`crypto:strong_rand_bytes`).
- **API:** `nexus/crypto.encrypt(key: BitArray, aad: String, plaintext:
  String) -> Result(BitArray, CryptoError)`,
  `decrypt(key, aad, envelope) -> Result(String, CryptoError)`.
- **Storage type:** `pog.bytea(BitArray)` for bind params; squirrel maps
  `bytea` columns to `gleam.BitArray` on read. (Verified against
  pog 4.1.0 / squirrel 4.7.0.)
- **Rotation (deferred):** `key_version` on the row plus an
  `NEXUS_ENCRYPTION_KEY_VERSION` env read; a `rewrap` path can re-encrypt
  rows with the active key. Not implemented now; the columns make it
  additive.
- Keys are **never** logged, echoed, or put in errors. `CryptoError` is a
  closed type with fixed strings.

## 7. Provider registry and boot order

`nexus/provider_registry` is a `gleam_otp` actor wrapped around the store
seam.

Messages:

- `List(reply: Subject(Result(List(Provider), _)))` — metadata + `has_key`,
  never the key.
- `Get(id, reply)` — metadata.
- `Resolve(id, reply) -> Result(ResolvedProvider, _)` — decrypts, returns
  the runtime pair used to stream.
- `Create(params, reply)`, `Update(id, params, reply)`,
  `Delete(id, reply)`, `SetEnabled(id, bool, reply)`.
- `ListModels(id, reply)` — delegates to `openai.list_models(endpoint)`.

`ResolvedProvider` (runtime, holds the **plaintext** key in its
`Endpoint`, never persisted or serialized):

```
ResolvedProvider(id: String, name: String, endpoint: openai.Endpoint)
```

The SSE timeouts ride on `Endpoint` exactly as `endpoint_from_config`
builds them today — they stay server-global policy, not per-provider
identity (per-provider overrides deferred, §18).

Caching: providers are small and change rarely; the actor keeps a
`Dict(String, ResolvedProvider)` cache populated on first `Resolve`,
invalidated on update/delete. Reads of the whole table happen once at
start (so a bad envelope fails loudly at boot, not on first message).

**Boot order change** (`src/nexus/boot.gleam`): store first, then
**provider_registry**, then factory, session_registry, ui_runtime, mist.
The registry resolves the seam by name like the session registry does.

## 8. Session pinning and the runner change

- `TurnRunner` becomes
  `fn(Endpoint, Transcript, cancel, on_event) -> StreamOutcome`.
  `session.agent_runner` captures only provider-independent config
  (`max_tool_iterations`, tool specs); the endpoint comes in per call.
- Session state gains a frozen `provider: ResolvedProvider` (or just its
  `Endpoint` + `provider_id`, whichever reads better) resolved at create.
  `SessionSpec` gains `provider_id`; `start_builder` resolves via the
  registry (production) or accepts an injected endpoint (tests).
- `loop.bifrost_stream(cfg)` → `loop.endpoint_stream(endpoint: Endpoint)`
  — it already derives an `Endpoint` internally (PR #7); the change is
  taking it as a parameter instead of `Config`.
- `openai.stream` / `stream_with_cancel` / `list_models` **already take
  `Endpoint`** (PR #7); `endpoint_from_config` is deleted at the hard cut.
- `session.model` and `transcript.model` stay the alias string; the
  provider lives beside them in session state and the `session.provider_id`
  column. Hydration resolves the endpoint by persisted id, then rebuilds
  the transcript exactly as today.
- **Fork rule:** a provider or model change = create a new session. No
  in-place switch, no re-encode. This preserves the frozen-prefix contract
  byte-for-byte.

## 9. KV-cache contract preservation

- Provider, model, system prompt, and tool schema are all frozen at
  creation. Nothing about the provider is written into the request body
  beyond the existing `model` field, so request bytes are unchanged.
- Session→backend affinity (contract rule 5) is now trivially satisfied
  *across* providers (different endpoints) and stays provider-local within
  one (Bifrost routing unchanged).
- The golden prefix tests (`test/m3_prefix_test.gleam`) must still pass
  with an injected `Endpoint`; a new golden test asserts that switching the
  endpoint's **key** (same base URL + model) produces byte-identical
  request bodies — credentials appear only in the `Authorization` header
  (and are omitted entirely when absent, per `drop_empty_bearer`).
- Warm/cold TTFT evidence is now **per provider**; the audit tool canon
  (§13) must name its provider.

## 10. Transport changes (`nexus/openai`) — mostly landed (PR #7)

- **Done:** `list_models`, `stream`, `stream_with_cancel`, and
  `to_openai_config` take `Endpoint`, not `Config`; keyless endpoints drop
  the `Authorization` header (`drop_empty_bearer`, unit-tested).
- **Remaining:** delete `endpoint_from_config` at the hard cut (its only
  remaining callers become registry-driven).
- `list_models` keeps the Bifrost `alias`-field fallback decoder.
- Add `dialect` dispatch stub: only `openai` implemented; anything else is
  a typed `UnsupportedDialect` error (no silent fallback).

## 11. HTTP API

All provider routes require `NEXUS_UI_TOKEN` when set (same gate as the
rest of the JSON surface).

| Route | Body | Notes |
|---|---|---|
| `GET /providers` | — | metadata list; `has_key: bool`, never the key |
| `POST /providers` | `{name, base_url, api_key?}` | validate base URL ends `/v1`; normalize; encrypt |
| `PATCH /providers/<id>` | `{name?, base_url?, api_key?, enabled?}` | present-api_key replaces; omitted keeps |
| `DELETE /providers/<id>` | — | `409` while `count_sessions_for_provider > 0`; prefer `enabled:false` |
| `GET /providers/<id>/models` | — | live alias list from that provider |
| `POST /sessions` | `{provider, model}` | both validated; provider resolved by name/id; pin both |
| `GET /models` | — | **removed** at the hard cut — no "default provider" exists to answer it; callers use `GET /providers/<id>/models` |

Session summaries gain `provider` (name) for display; the UI subtitle
becomes `provider/model · relative time`.

Error mapping: unknown provider → `400`; disabled provider → `400`;
unreachable/auth failure on model list → `502` (existing pattern).

## 12. UI (`nexus/ui` + `nexus/page`)

- Provider picker on session create; models load per selected provider
  (`aliases_effect` becomes provider-scoped).
- A providers settings surface (Lustre component route or a section in the
  shell): list, add, edit, enable/disable, delete. Key field is
  **write-only**: renders empty on edit; blank means "keep existing". Show
  `has_key` / a `configured` badge, never key material.
- Existing sessions display their pinned provider; changing it is
  "fork session", not an edit.

## 13. Config and first-run bootstrap (hard cut)

`nexus/config.Config`:

- **Removed:** `base_url`, `api_key`, and `model_default` — the last is
  dead weight since #5 stopped minting a boot session; this plan must not
  reintroduce one.
- **Added:** `encryption_key: String` (required).
- **Unchanged:** PG fields, SSE timeouts, system prompt, tool/web-search
  knobs. No `provider_default`/`model_default` env: nothing boots a
  session anymore; creation is user-initiated (sidebar create panel,
  auto-opened when no active session is selectable — the #5 UX).

First run:

1. Boot loads config; missing/invalid `NEXUS_ENCRYPTION_KEY` → fail loudly.
2. Provider registry starts with an empty table → zero providers, zero
   sessions, create panel auto-opens.
3. Operator creates a provider via the UI or `POST /providers`, then
   creates a session choosing provider + model.
4. README documents the new required env and the first-run flow.

**Audit tool — landed (#7).** `audit/ttft` reads its own
`NEXUS_AUDIT_BASE_URL` / `NEXUS_AUDIT_MODEL` / optional
`NEXUS_AUDIT_API_KEY` env via `src/audit/config.gleam`, builds its own
`Endpoint`, and no longer imports `nexus/config`. The server hard cut
cannot break it.

**Test churn.** Every `test/*.gleam` fixture that constructs
`config.Config(base_url:, api_key:, model_default:, …)` (`session_test`,
`session_persistence_test`, `session_registry_test`, `web_routes_test`,
`ui_test`, `m3_prefix_test`, …) must drop those fields and supply an
`Endpoint`/registry fixture instead.

## 14. Security and threat model

- **Auth:** provider CRUD is behind `NEXUS_UI_TOKEN`; with the token unset
  the app is loopback-only (PRD hard req. 5), so the DB is not reachable
  remotely anyway.
- **At rest:** AES-256-GCM protects against DB dumps, backups, and
  SQL-read leaks. It does **not** protect against VM/host compromise (the
  master key is in the process env). State this plainly in the doc.
- **In transit:** provider TLS is the operator's `base_url` scheme;
  loopback HTTP endpoints are allowed (local models).
- **In memory:** only `provider_registry` and the streaming session hold
  plaintext. Keys never enter the transcript, session summary, logs, or
  error strings.
- **SSRF:** `base_url` is operator-supplied trusted config (it is the
  destination of every request), so the `http_fetch` SSRF guard does not
  apply. `http_fetch`'s existing guard is untouched.
- **Delete:** `ON DELETE RESTRICT` + registry `409` prevent orphaning
  sessions; disable is the reversible path.

## 15. Migration and rollout

**No migration — nexus is pre-deployment.**

- Edit `sql/schema.sql` in place: add `provider` **before** `session`, add
  `session.provider_id NOT NULL REFERENCES provider(id)`.
- Local databases: recreate the compose volume
  (`docker compose down -v && docker compose up -d`) so
  `/docker-entrypoint-initdb.d/` re-applies the edited schema. The
  `IF NOT EXISTS` DDL will create the new `provider` table on an existing
  volume, but it will **not** alter the existing `session` table — recreate
  the volume instead of relying on `migrate` for that edit.
- CI applies schema via `gleam run -m nexus/store/migrate` on a fresh
  Postgres service container, so it picks the edit up with no change.
- Remove `BIFROST_*` and `NEXUS_MODEL_DEFAULT` from `.env` examples, the
  README env table, and `docker-compose`/e2e wiring; add
  `NEXUS_ENCRYPTION_KEY`. Delete `openai.endpoint_from_config` and the
  boot log line that prints the default alias; the audit tool's
  `NEXUS_AUDIT_*` env is untouched (separate since #7).
- No data exists, so there is no NULL-provider path and no backfill. The
  ciphertext format is introduced with the feature; nothing to rotate.

## 16. Testing strategy (offline, no network/DB)

- `nexus/crypto`: fixed test key; round-trip; wrong-AAD fails; tampered
  ciphertext/tag fails; malformed key length rejected.
- `nexus/provider` (pure): base-URL normalization (`/v1` suffix), name
  validation, `has_key` masking, present-key PATCH semantics.
- `provider_registry`: actor test against the in-memory store mock;
  CRUD; cache invalidation; `409` on delete-when-referenced; disabled
  provider refused.
- `store_mock.gleam`: in-memory `provider` table.
- `web_routes_test`: provider CRUD status codes; **assert the key never
  appears in any response body**; `POST /sessions` pins provider+model.
- new golden test: same base URL + model, different key ⇒ byte-identical
  request body; existing `m3_prefix_test` still byte-identical with an
  injected spec.
- `config_test`: `NEXUS_ENCRYPTION_KEY` required; `BIFROST_*` and
  `NEXUS_MODEL_DEFAULT` gone.

## 17. Phased roadmap

Landed pre-work (main, before implementation): **#5** no boot session +
boot sweep, **#6** quote-aware migrate splitter, **#7** audit tool
decoupled to `audit/ttft` and `openai` endpoint-shaped (`Endpoint`,
optional key, `drop_empty_bearer`). #7 in particular absorbs most of the
old P3 plumbing.

| Phase | Scope | Acceptance |
|---|---|---|
| P0 | `nexus/crypto` + FFI + tests | round-trip + tamper tests pass offline |
| P1 | `provider` table + `session.provider_id` + squirrel queries + store seam + mock | `squirrel check` clean; store tests offline |
| P2 | `nexus/provider_registry` + boot wiring | creates/lists/resolves a provider from a live DB; boot fails on bad key |
| P3 | Config hard cut; `loop`/`session` take `Endpoint` (transport already does); delete `endpoint_from_config` | server starts with zero providers, zero sessions; a session streams via its frozen endpoint |
| P4 | HTTP API (`/providers`, provider-scoped `/models`, `POST /sessions`) | curl CRUD; key never echoed; `409` delete guard |
| P5 | UI provider management + provider→model picker + docs | create provider, create session, stream a turn end-to-end; README updated |
| P6 (deferred) | key rotation/`rewrap`, dialect stubs, per-provider timeout overrides | not required for ship |

Each phase keeps `gleam test` offline and the golden prefix invariants
green.

## 18. Open questions / risks

- **Per-provider timeout overrides:** SSE first-response/idle timeouts ride
  on `Endpoint` but are filled from server-global config; per-provider
  values would need columns. Deferred (P6).
- **Model list caching:** live fetch per picker open is fine at this
  scale; add a short TTL only if it proves slow.
- **`update_provider.sql` key semantics** need an explicit `replace_key`
  boolean; verify squirrel handles the boolean + `COALESCE` ergonomically.
- **`Endpoint` holds a plaintext key inside session state** — accepted
  (in-process), but audit that it never lands in `describe`/metrics/
  summaries; add a "no key in serialized output" test.
- **`insert_session` gains a column** — the generated row/param types in
  `persist.gleam` change; expect mechanical churn in tests that build
  `StoredSummary` (add `provider_id`).
