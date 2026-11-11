# nexus

A Gleam-on-BEAM agent harness, talking to [Bifrost](https://github.com/maximhq/bifrost)
(OpenAI-compatible) via the `glopenai` codec and `httpp` streaming transport.
Multiple threads, a Lustre server-component UI over WebSocket with typed
tool-call rendering (name, call id, argument preview, status, inert result
preview), loop/iteration state, the bounded `http_fetch` + `web_search`
agent loop, and durable thread storage in external Postgres (a `thread`
table plus append-only `thread_message` rows;
hydrate-on-boot, lazy start, write-behind commits). See
`docs/plans/mvp-requirements.md`, `docs/plans/tech-stack.md`, and
`docs/plans/completed/m3-verification.md`. Schema naming and the schema
invariants are in `AGENTS.md`.
The multi-provider rollout is documented in
`docs/plans/completed/multi-provider.md`. Model-generated thread
titles and tags ride one prefix-cache "utility branch" — designed in
`docs/plans/completed/utility-titles.md`, with the tags pass landed per
`docs/plans/completed/utility-tags.md`.

## Development

```sh
docker compose up -d --wait   # local Postgres 17 on 127.0.0.1:5433 (waits for health)
gleam run -m nexus/store/migrate  # applies sql/schema.sql (idempotent; rerun after schema edits)
gleam run                   # web server (registry, threads, streaming, stop, auth, store)
gleam test                  # offline unit tests (no network, no database — the store is a mockable seam)
gleam format src test
```

The flake devShell provides gleam/erlang/rebar3: `nix develop`.

Persistence is mandatory: boot fails fast (no silent ephemeral mode) when
the database is unreachable. Local dev needs a `.env` (untracked;
`.envrc` loads it) with at least:

```
DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus
```

`DATABASE_URL` is the codegen/migration convention (squirrel and the
migrate runner read it); the server itself reads the `NEXUS_PG_*`
variables below (their defaults match the compose file, so the `.env`
above is enough locally).

Query changes: edit `src/nexus/store/sql/*.sql`, then regenerate the
typed Gleam (`gleam run -m squirrel` — needs the live DB above) and
commit the result; `gleam run -m squirrel check` (CI does this) fails
when the generated module is stale. Schema changes: edit
`sql/schema.sql`, re-apply with
`gleam run -m nexus/store/migrate` (idempotent).

## Providers

nexus talks to N OpenAI-compatible `/v1` endpoints ("providers"). Each
one is a row in the `provider` table with its base URL, an optional API
key stored as AES-256-GCM ciphertext (encrypted under `NEXUS_ENCRYPTION_KEY`,
AAD = provider id), and an `enabled` flag. Keyless providers (local
Ollama / llama.cpp / vLLM) are first-class: no key, no `Authorization`
header on the wire.

Every thread **pins one `(provider, model)` pair at creation** — frozen
like the system prompt for the thread's lifetime (KV-cache contract).
Changing provider or model means creating a new thread.

A fresh database has zero providers, and the server boots fine that way
(zero threads too — nothing auto-creates). Create the first provider
in the chat UI's **Providers** panel (sidebar, below the create panel)
or through the HTTP API:

```sh
curl -s http://127.0.0.1:8080/providers \
  -H "authorization: Bearer $NEXUS_UI_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"bifrost","base_url":"https://gateway.example/v1",
       "api_key":"sk-…"}'
# keyless provider? omit `api_key` entirely (local endpoints)
```

or seed it out-of-band while the server is not running:

```sh
DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
NEXUS_ENCRYPTION_KEY="$NEXUS_ENCRYPTION_KEY" \
NEXUS_SEED_PROVIDER_NAME=bifrost \
NEXUS_SEED_PROVIDER_BASE_URL=https://gateway.example/v1 \
gleam run -m nexus/dev_seed

# keyless provider? add NEXUS_SEED_PROVIDER_API_KEY=sk-… to the block
# (omit it entirely — or leave it blank — to keep/create a keyless row)
```

The seed tool is idempotent by name (re-running reports "nothing to
do"), and the key never appears in its output. Seed **before** booting
the server or restart it afterwards — the provider registry loads the
table once at start (a bad envelope fails boot loudly). Either way, the
chat UI's provider picker lists every enabled provider and reloads the
model aliases whenever the selection changes.

## The UI

The page is a Lustre **server component**: the Elm-architecture model
lives on the server (`nexus/ui`), view patches stream to a ~10kb client
runtime over the `/ws` WebSocket, and client events flow back in real
time. The server-rendered shell (`nexus/page`) hosts the component and a
connection dot that mirrors the client runtime's own connect/close
events, so a dropped backend still turns the dot red.

Every connection gets its **own runtime and model**: tabs never mirror
each other's selected thread or open panels. The shell also persists the
last-selected thread client-side and re-supplies it on the `/ws` route,
so a reload re-opens the same thread.

The transcript renders assistant tool calls as compact cards (tool name,
stable call id, truncated argument preview, running/completed/failed
status, and a truncated inert result preview — no `innerHTML`, escaped
text only), the model's **reasoning** (chain of thought) as a live
"thinking…” block that collapses into an inert, expandable summary
when assistant output begins (replayed from history on reconnect,
rolled back with a failed turn), an iteration chip (`iter n/max · phase`) while the agent
loop runs, terminal guard rendering when the iteration cap trips, and
full tool-history replay on reconnect or reload. Failed turns roll their
uncommitted display back (the server commits nothing); guard-tripped
turns keep their completed rounds.

The sidebar organizes threads as **in-memory registry metadata**: a global
**pinned** section on top, then one flat recency-sorted list bucketed into
Today / Yesterday / Previous 7 days / Older, with tag chips and a
(title + tag) filter. Titles auto-generate from the first user message
(truncated, no LLM call) and become manual once renamed, so auto-generation
never clobbers them; the row subtitle is
`provider/model · relative time` — the pin is the thread's identity,
not just display. Archiving soft-hides a thread behind the *Show
archived* toggle
(restorable); deleting removes it for good after a two-step confirmation.
Archived threads are never pinned — archiving clears the pin, and the
sidebar offers no pin control on archived rows.
All of this lives **beside the transcript** — the request-encoding path
never sees it, and the golden metadata-isolation test asserts not a single
request byte changes.

The create panel pins a new thread explicitly: a **provider select**
(enabled providers only, keyless ones marked) followed by the model
alias select, whose options are that provider's live `/v1/models` list —
switching providers reloads it, and *Create thread* stays disabled until
both halves exist. When bots exist, the panel also offers a **bot
select** (“start from bot”): picking one stands the provider/model
pickers down — the bot sources the pin and its system prompt, and the
sidebar row's subtitle leads with the bot's name as provenance.
Below it, the **Providers** panel manages providers
in-UI: add (name, base URL, optional key — keyless is first-class), edit
(name / base URL / replace key; the key field is write-only and renders
empty — blank keeps the stored key, `has_key` is the only key fact
shown), enable/disable (the reversible off-switch — the picker and
thread creates refuse disabled providers), and delete behind a
two-step confirmation (refused with `409` semantics while any thread
pins the provider). A **Bots** section mirrors the provider rows: add,
inline edit (name, description, provider, model, prompt — blank prompt
= the global default), and a two-step delete that never orphans
threads (they keep what they froze at creation). Every mutation fails
into a note in the log, never a silent no-op.

## Server

`gleam run` starts the store actor (Postgres pool — first, and boot fails
if it cannot start), the provider registry (loads and decrypt-validates
every provider row), the bot registry (loads the bot table), a factory
supervisor, a thread registry hydrated
from the store, and a Mist server at the bound address (default
`127.0.0.1:8080`). The Lustre server-component runtime is not a boot
child: each `/ws` connection starts its own runtime, linked to its
socket, so a UI crash costs that one connection (the browser reconnects
into a fresh runtime) instead of a supervision-tree restart. No thread
is created at
boot — threads are always user-initiated (the sidebar's create panel
auto-opens whenever no active thread is selectable), and never-used
threads (system prompt only, untitled, unpinned) past a 15-minute grace
window are swept at boot, so restarts cannot litter the list with
empties. Threads are durable: turn
commits persist
write-behind (in seq order, idempotent on replay), metadata mutations
write through, and a restart rehydrates — stored-but-not-live threads
appear in the sidebar and lazily start (hydrated, byte-identical request
prefix) on first use. Metrics history is in-memory only by design. A
killed thread actor restarts rehydrated from the store instead of empty.

Each thread actor owns its append-only transcript, frozen alias, and
bounded metric history. A failed turn commits no assistant message; retry
resends a byte-identical prefix to preserve the KV-cache contract.
Stopping commits partial text. Thread IDs, metrics, and organizational
metadata (titles, pins, tags, archive state, timestamps) never enter
request bodies.

### Routes

All routes except `GET /healthz` require the configured token when
`NEXUS_UI_TOKEN` is set.

- `GET /` — authenticated chat page (Lustre server-component shell)
- `GET /ws` — the server component's WebSocket transport
- `GET /lustre/runtime.mjs` — the Lustre client runtime asset
- `GET /providers` — provider list as masked metadata (`has_key`, never
  the key itself)
- `POST /providers` `{"name","base_url","api_key"?}` — create; the base
  URL must be OpenAI-compatible ending in `/v1` (normalized server-side);
  a blank or absent key creates a keyless provider (201, masked row)
- `GET /providers/<id>/models` — live alias list from that provider's own
  `/v1/models` (unknown → `404`, disabled → `400`, upstream failure → `502`)
- `PATCH /providers/<id>` `{"name"?,"base_url"?,"api_key"?,"enabled"?}` —
  present keys replace, absent keys keep; a present non-blank `api_key`
  replaces the stored key (blank means keep; there is no remove-key
  patch), and `enabled:false` is the reversible off-switch
- `DELETE /providers/<id>` — hard delete (204); `409` while any thread
  or bot pins the provider — disable it instead
- `GET /bots` — bot list (named creation-time thread templates:
  provider + model + system prompt; no secrets)
- `POST /bots`
  `{"name","provider","model","description"?,"system_prompt"?}` —
  create; the provider must exist (unknown → `400`), a blank or absent
  `system_prompt` means the global default (resolved when a thread is
  created from the bot)
- `PATCH /bots/<id>`
  `{"name"?,"description"?,"provider"?,"model"?,"system_prompt"?}` —
  present keys replace, absent keep; a blank `name`/`model`/`provider`
  keeps the stored value, while a present `description`/
  `system_prompt` replaces (blank clears — back to `""` and back to
  the default prompt). A body whose keys are all blank or absent is
  `400 empty patch`.
- `DELETE /bots/<id>` — hard delete (204), unguarded: threads created
  from a bot keep their frozen settings (`bot_id` provenance is
  `ON DELETE SET NULL`)
- `GET /threads` — summaries (each carrying the pinned `provider_id`
  and, when created from a bot, the `bot_id` provenance), pinned first
  then most recently active (default: active only)
- `GET /threads?archived=1` — archived summaries only
- `POST /threads` `{"provider":"id-or-name","model":"alias"}` —
  the provider is resolved by id or name (unknown/disabled → `400`),
  the alias validated against that provider's live model list, and the
  `(provider, model)` pair pinned for the thread's lifetime — or
  `{"bot":"id"}` alone, which sources the provider, model, and system
  prompt from the bot at creation (unknown bot → `400`, a stale alias
  → `400`; mixing `bot` with `provider`/`model` → `400`, even when the
  provider/model values are blank). Editing a bot never changes an
  existing thread — its provider/model/prompt were copied at creation —
  and deleting one only clears the `bot_id` provenance.
  (There is no global `GET /models` — with N providers there is no
  default endpoint to answer it; use `GET /providers/<id>/models`.)
- `PATCH /threads/<id>` `{"title?","pinned?","tags?","archived?"}` — update
  metadata (present keys only; `title` implies a manual rename) → updated
  summary. Invariant: an archived thread is never pinned — archiving
  clears the pin, and pinning without restoring in the same patch is a
  `409`
- `DELETE /threads/<id>` — stop the actor and remove the thread hard
  (204; a streaming turn is cancelled first)
- `POST /threads/<id>/send` `{"text":"…"}` — start a turn (202; 409 while busy);
  the first message also auto-titles the thread
- `POST /threads/<id>/stop` — cancel and commit the partial reply
- `GET /healthz` — unauthenticated liveness probe

The browser UI does not use the JSON routes — it talks to the server
component over `/ws`. The JSON surface is the scripting/e2e API (the
Playwright suites drive turns through `/send` and poll `/threads`).

Examples:

```sh
# provider management (P4 surface)
curl -H "Authorization: Bearer $NEXUS_UI_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"bifrost","base_url":"https://gateway.example/v1",
       "api_key":"sk-…"}' \
  "$BASE/providers"

curl -H "Authorization: Bearer $NEXUS_UI_TOKEN" "$BASE/providers/$PID/models"

# thread pinned to that provider + model
curl -H "Authorization: Bearer $NEXUS_UI_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"provider\":\"$PROVIDER\",\"model\":\"$MODEL\"}" \
  "$BASE/threads"
```

Verification lives in `e2e/` (see `e2e/README.md`): a Playwright browser
suite against controlled services, an integration smoke against real
Bifrost/SearxNG, and the production cache check whose golden fixture is
`test/fixtures/m3_cache_thread.json`. Results:
`docs/plans/completed/m3-verification.md`.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_ENCRYPTION_KEY` | — | master key for provider API keys at rest: base64 of exactly 32 random bytes (`openssl rand -base64 32`, required) |
| `NEXUS_HTTP_BIND` | `127.0.0.1` | server bind (loopback per PRD) |
| `NEXUS_HTTP_PORT` | `8080` | server port |
| `NEXUS_UI_TOKEN` | unset | single-user bearer token; unset disables auth |
| `NEXUS_SYSTEM_PROMPT` | concise assistant (default gains an ASCII-only codemode note while `NEXUS_CODEMODE=true`; explicitly set values are never amended) | frozen for newly created threads |
| `NEXUS_MAX_TOOL_ITERATIONS` | `32` | agent-loop guard: max model round-trips per user turn |
| `NEXUS_HTTP_FETCH_MAX_BYTES` | `20000` | `http_fetch`: response body cap per call |
| `NEXUS_HTTP_FETCH_TIMEOUT_MS` | `15000` | `http_fetch` HTTP connect+receive timeout per hop |
| `NEXUS_HTTP_FETCH_ALLOW_PRIVATE` | `false` | dev/test escape hatch for private/loopback targets; never in production |
| `NEXUS_SEARXNG_BASE_URL` | unset | enables the `web_search` tool (SearxNG instance) |
| `NEXUS_SEARXNG_TOKEN` | unset | optional SearxNG bearer token; never logged or echoed |
| `NEXUS_PG_HOST` | `127.0.0.1` | Postgres host (compose maps port 5433) |
| `NEXUS_PG_PORT` | `5433` | Postgres port |
| `NEXUS_PG_DATABASE` | `nexus` | database name |
| `NEXUS_PG_USER` | `nexus` | database user |
| `NEXUS_PG_PASSWORD` | unset | optional password; never logged or echoed |
| `NEXUS_UTILITY_ENABLED` | `true` | once-per-thread model-generated title upgrade (a side call branched off the committed transcript's cached prefix); `false` keeps the heuristic first-message title forever |
| `NEXUS_UTILITY_DELAY_MS` | `1500` | debounce after a turn commit before the title side call starts (a send cancels an in-flight call without consuming the thread's one attempt) |
| `NEXUS_CODEMODE` | `false` | registers the `codemode` tool: Lua scripts that call the sibling tools and return one compact result (`docs/plans/codemode.md`); off keeps the tool envelope unchanged |
| `NEXUS_CODEMODE_TIMEOUT_MS` | `30000` | `codemode`: per-script wall-clock deadline in ms (>= 1000; the engine is killed at the deadline, partial output kept) |
| `NEXUS_CODEMODE_MAX_OUTPUT_CHARS` | `32768` | `codemode`: rendered-output cap in characters (>= 0; head and tail kept, omission noted) |

The single-provider env trio (`BIFROST_BASE_URL`, `BIFROST_API_KEY`,
`NEXUS_MODEL_DEFAULT`) is gone: the `provider` table in Postgres is the
only provider source, and every thread pins its `(provider, model)`
pair explicitly at creation (see `docs/plans/completed/multi-provider.md`).

With `NEXUS_UI_TOKEN` set, open `/?token=<token>`. The page forwards the
token as a `Bearer` header for `fetch` requests and as a query parameter
for the WebSocket route and the runtime script tag, which cannot set
headers.

> Local-dev note: a non-flake Erlang needs `libcrypto` on the loader path,
> e.g. `LD_LIBRARY_PATH=$(nix build --print-out-paths nixpkgs#openssl)/lib`.
> The flake devShell handles this.

## Audit tool

`audit/ttft` is the keep-forever warm/cold TTFT audit harness (the
M0 evidence runners it grew beside are gone; this one stays). It is a
live-checkpoint activity, never CI:

```sh
gleam run -m audit/ttft                # warm/cold TTFT harness
gleam run -m audit/ttft -- --csv       # machine-readable rows
```

It is a standalone operator tool with its own configuration (`audit/config`),
deliberately decoupled from the server's env surface. It reads
`NEXUS_AUDIT_BASE_URL` (required, including `/v1`), `NEXUS_AUDIT_MODEL`
(required), optional `NEXUS_AUDIT_API_KEY` (unset targets keyless local
endpoints), plus `NEXUS_AUDIT_TURNS` (20), `NEXUS_AUDIT_REPEATS` (5), and
the stream timeouts `NEXUS_AUDIT_SSE_FIRST_RESPONSE_TIMEOUT_MS` (30000) /
`NEXUS_AUDIT_STREAM_IDLE_TIMEOUT_MS` (120000).

## Architecture

**Process model — actors, lifetimes, and communication — is mapped in
[ARCHITECTURE.md](ARCHITECTURE.md)** (which processes exist, what each is
scoped to — VM / browser connection / thread / turn — and who talks to
whom, with Mermaid diagrams).

Module map:
- `nexus/config` — environment-driven configuration and validation
- `nexus/transcript` — append-only transcript; **the single request-encoding path**
- `nexus/openai` — model listing, streaming, cancellation, and stream statistics
- `nexus/thread` — transcript, subscribers, turn lifecycle, and metrics
- `nexus/thread_registry` — IDs, aliases, live subjects, restart recovery,
  and the thread-organization metadata (title, pin, tags, archive);
  boot hydration, lazy hydrated start, write-behind + write-through
- `nexus/store` — persistence seam and the pure transcript⇄row
  mappers (mockable; offline tests substitute an in-memory store)
- `nexus/store/persist`, `nexus/store/sql` — the pog-backed store actor and
  the squirrel-generated typed queries over `src/nexus/store/sql/*.sql`
- `nexus/web` — the HTTP surface: JSON scripting API, the Lustre shell
  page, and the component's transport routes (`/ws`, `/lustre/runtime.mjs`)
- `nexus/page` — the server-rendered Lustre page shell (auth, connection
  dot, last-selected-thread echo script)
- `nexus/ui`, `nexus/ui_runtime` — the server-component model/view and
  the per-connection runtime + WebSocket glue
- `nexus/boot` — supervision tree and startup
- `audit/ttft`, `audit/config` — the warm/cold TTFT audit tool and its
  standalone configuration loader

KV-cache contract (PRD rules 1–6) is enforced structurally: append-only
transcript, one encode path, and no volatile thread ID or metrics above the
request tail. Golden-body and prefix-invariance tests cover the encoding path.
