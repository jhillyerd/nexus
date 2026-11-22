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

## Mission

Some of my goals for this project:

- Be a good personal assistant first, coding agent second
- Strong support for small local LLMs, maximizing use of their prefix-cache
- NixOS friendly, for both hosting and coding
- Take advantage of the BEAM's actor model and OTP supervision trees

## Development

```sh
docker compose up -d --wait   # local Postgres 17 on 127.0.0.1:5433 (waits for health)
gleam run -m nexus/store/migrate  # applies pending sql/migrations/*.sql (tracked in schema_migration)
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
when the generated module is stale. Schema changes: add a new numbered
file under `sql/migrations/` (never edit applied migrations), then apply
with `gleam run -m nexus/store/migrate`.

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

Every thread is also **born from a bot** — there is no provider+model
create shape. A bot is a named creation-time template (provider, model,
system prompt, toolset), and threads always arrive through it.

A fresh database has zero providers, and the server boots fine that way
(zero threads too — nothing auto-creates). Create the first provider
in the chat UI's **Settings → Providers** view or through the HTTP API:

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
table once at start (a bad envelope fails boot loudly). With a provider
in place, create a **bot** (Settings → Bots), and threads start from it:
click **New**, pick the bot beside the composer, type a message, and
send — the send creates the thread.

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

All routes except `GET /healthz`, `GET /node/ws`, and `POST /nodes/pair`
require the configured UI token when `NEXUS_UI_TOKEN` is set;
`/node/ws` carries its own NODE-token auth against the `node` table, and
`/nodes/pair`'s auth is the pairing code it redeems (tui-pairing plan).

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
  and the `bot_id` provenance — a deleted bot's is NULL), pinned first
  then most recently active (default: active only)
- `GET /threads?archived=1` — archived summaries only
- `POST /threads` `{"bot":"id"}` — the ONLY create shape: every thread
  is born from a bot, which sources the provider, model, system prompt,
  and toolset at creation (unknown bot → `400`). The alias is NOT
  validated against the provider's live model list (proxies like
  Bifrost accept aliases their `/v1/models` may not carry; a dead alias
  fails the thread's first turn). Any `provider`/`model` body or
  non-null `tools` value answers `400 threads require a bot`; mixing
  `bot` with those values is `400`, even when the provider/model values
  are blank (an explicit `"tools": null` is NOT a conflict — it
  flattens to the default-set sentinel like absence). Editing a bot
  never changes an existing thread — its provider/model/prompt were
  copied at creation — and deleting one only clears the `bot_id`
  provenance.
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
- `GET /threads/<id>/state` — debug dump: the server's complete
  point-in-time view of one thread as JSON — `summary`, `status`,
  `messages`, and `live_turn` while a turn is in flight (`null` when
  idle — the key is always present). Each message row carries
  chronological `seq` (0 = system prompt), role, content,
  `stamped_at`, `origin`; assistant rows add `reasoning` and
  `tool_calls` (id/name/arguments verbatim); tool rows add
  `tool_call_id` and `is_error` (failed call → `true`). `live_turn`'s
  `rounds` is the display mirror transcript — committed history as of
  the send plus the in-flight rounds finished so far — beside the
  pending stream buffers. Read-only side channel for curl and tests —
  the UI never consumes it (its data path stays `/ws`). Like every
  per-thread route it resolves the live actor, so a dormant thread
  lazy-starts; and `summary` is the registry's snapshot, so under
  concurrent activity its `message_count`/`streaming` can lag
  `status` by an instant. A future abridged print/PDF view
  (`/threads/<id>/transcript`) is tracked in issue #117
- `GET /healthz` — unauthenticated liveness probe
- `GET /nodes` — paired remote nodes (id, thread_id, name, stamps; the
  token hash is never on the wire)
- `POST /nodes` `{"name":"proxmox-2","thread":"<id>"}` — pair a node
  (names are unique PER THREAD; the row binds to its thread): 201
  answering the minted plaintext token EXACTLY ONCE (store keeps only
  its SHA-256 hash); duplicate name in that thread → `409`,
  reserved/invalid name → `400`, unknown thread → `404`
- `POST /nodes/pair` `{"code":"…","name":"proxmox-2"}` — the PUBLIC
  pairing exchange (tui-pairing plan): redeems a web-minted 1-hour,
  multi-use pairing code for a node token plus its thread — the
  grant's pinned `thread_id`, or the request's optional `"thread"`
  override (the launcher's `NEXUS_THREAD`) — no UI token, the code is
  the auth. The name VALIDITY gate runs before the code check (an
  invalid or reserved name answers `400` unconditionally — otherwise a
  garbage-code probe could tell live codes from dead ones); past it,
  expired/revoked/unknown codes answer one merged `404` so a dead code
  looks identical whatever the valid name; with a live code, a name
  taken IN THAT THREAD answers the same friendly `409` as
  `POST /nodes`
- `DELETE /nodes/<id>` — revoke the node's token (204, idempotent;
  future connections fail, a live one is not retroactively killed)
- `GET /node/ws?node=<name>&token=<token>&thread=<id>&role=env|viewer`
  — the remote-node WebSocket (environments plan): NODE-token auth
  against the (thread, name) PAIR — names are per-thread, so a row
  joins only its own thread (distinct from the UI token; also accepted
  as `Authorization: Bearer`), one thread per connection. The
  versioned, additive-only
  JSON client protocol (`"v":1`) serves an event plane (the thread's
  fan-out projected as frames), an MCP-shaped tool plane (`tools/call`
  down with the arguments verbatim, results up, `notifications/
  cancelled` down), and user input — every frame carries `"v":1`
  (`{"v":1,"type":"send","text":…}`).
  `role=env` (default) attaches the node's machine as an environment
  target — refused (403) on threads whose toolset has no env tools;
  `role=viewer` joins any thread with events and send but no tool
  plane. The reference client is the bundled node TUI (a REPL-style
  proof of concept — see the TUI section below); the protocol codec is
  shared (`nexus/node_protocol` owns both directions of the wire).

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
| `NEXUS_MAX_BOT_HOPS` | `4` | bot-to-bot delivery guard: max hops in an inter-bot message chain (bots plan P3c) |
| `NEXUS_HTTP_FETCH_MAX_BYTES` | `20000` | `http_fetch`: response body cap per call |
| `NEXUS_HTTP_FETCH_TIMEOUT_MS` | `15000` | `http_fetch` / `web_fetch` HTTP connect+receive timeout per hop |
| `NEXUS_HTTP_FETCH_ALLOW_PRIVATE` | `false` | dev/test escape hatch for private/loopback targets (`http_fetch` / `web_fetch`); never in production |
| `NEXUS_WEB_FETCH_MAX_RAW_BYTES` | `1048576` | `web_fetch`: streaming raw response byte cap before HTML-to-Markdown conversion (> 0) |
| `NEXUS_WEB_FETCH_DEFAULT_CHARS` | `12000` | `web_fetch`: default `max_length` returned per call in characters (> 0) |
| `NEXUS_WEB_FETCH_MAX_CHARS` | `32000` | `web_fetch`: hard upper clamp on `max_length` per call (>= `NEXUS_WEB_FETCH_DEFAULT_CHARS`) |
| `NEXUS_WEB_FETCH_CACHE_TTL_MS` | `600000` | `web_fetch`: in-memory extracted-document cache TTL in ms (`0` disables caching) |
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
| `NEXUS_PLUGINS` | _(unset)_ | comma-separated compiled-in plugins to start as tool providers (e.g. `example`); plugin tools enter a thread only via an explicit create toolset or a bot template, never the default (`docs/plans/plugin-api.md`) |
| `NEXUS_PLUGIN_TIMEOUT_MS` | `30000` | plugins: per-call wall-clock deadline in ms (>= 100); a provider that misses it renders as a failed tool result |
| `NEXUS_PLUGIN_MAX_OUTPUT_CHARS` | `32768` | plugins: the adapter's output cap in characters (>= 0) for provider results and error messages (shared with MCP adapters) |
| `NEXUS_MCP_SERVERS_JSON` | _(unset)_ | MCP stdio servers to mount as tool providers — a JSON array of `{"name","command","args"?,"env"?,"timeout_ms"?}` (bare commands resolve through `PATH`); a server that will not start or answer degrades loudly at boot (its creates re-ask live and refuse with an honest 400, never silent; frozen threads still hydrate); server tools freeze into a thread's manifest at creation and hydration never contacts the server (`docs/plans/plugin-api.md`) |
| `NEXUS_WORKSPACE_ROOT` | _(unset)_ | environments (`docs/plans/environments.md`): the directory under which each env-carrying thread gets its own workspace (`<root>/<thread id>`, created lazily); the RESOLVED root freezes per thread at creation, so changing it affects new threads only. Unset keeps `bash` / `read_file` / `write_file` / `list_dir` out of the default toolset (with a root set they join it — the default is every usable compiled-in catalog tool; plugin and MCP tools never join the default, they ride an explicit toolset or bot template); either way a bot save or thread create naming them explicitly refuses while no root can be frozen |
| `NEXUS_ENV_TIMEOUT_MS` | `60000` | environments: per-call wall-clock deadline for `bash` in ms (>= 1000; at the deadline the command's whole process tree is killed on Linux (setsid + process-group kill; without setsid — e.g. macOS dev machines — only the direct child dies and descendants may survive), partial output kept) |
| `NEXUS_ENV_MAX_OUTPUT_BYTES` | `262144` | environments: byte cap on bash output and file reads, enforced at accumulation (>= 1024; buffering is bounded at the cap plus one chunk and a small slack, omission noted) |
| `NEXUS_NODE_IDLE_DAYS` | `7` | node credentials unattended this many days (since last connect; creation for never-connected) are deleted by the boot sweep — a daily-driver TUI keeps its credential indefinitely, a crashed one has a week; `0` disables the sweep |
| `NEXUS_LOG_LEVEL` | `info` | minimum server log level (`debug`, `info`, `warn`/`warning`, `error`); logs are emitted as single-line `logfmt` via Erlang `:logger` |

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

## Node TUI (proof of concept)

The bundled remote-node client is a Gleam REPL — a proof of concept for
the environments plan's `/node/ws` protocol, not the eventual
high-fidelity TUI (that is a separate future initiative). It dials OUT
to nexus, renders the event plane as plain lines, sends your typed
lines to the thread, and — as `role=env` — serves `tools/call` frames
by executing the four env tools LOCALLY, in its own workspace
directory, through the same code the server runs for its own workspace
(kill-tree, byte caps while reading, path confinement included).

Pair a node and launch the TUI with the bundled launcher: mint a
pairing URL in the web UI (open the thread's info pane → Environments
→ "Pair a TUI…"), then run the launcher with it once — it exchanges
the code for a node credential pinned to that thread (no UI token, no
thread id needed), persists the credential in a `0600` state file
under `${XDG_STATE_HOME:-$HOME/.local/state}/nexus/`, and launches
the TUI:

```sh
bin/nexus-tui http://127.0.0.1:8080/pair/<code>   # first launch on a host
bin/nexus-tui                                     # relaunch — stored credential
bin/nexus-tui --reset                             # forget the stored credential
```

Relaunches reconnect with the stored token — no re-pairing — so a
crash or closed terminal no longer loses the pairing, and the same
node row (and its identity) survives. If the stored credential is
ever rejected (the node row was revoked, or swept by idle expiry),
the TUI exits 4: with a pairing URL the launcher re-pairs and tries
once more; without one it exits 4 with "credential rejected — pair
again". The pairing code never rests anywhere: the launcher does not
persist the URL (the state file stores only the server base, node
name, token, and thread), the server stores the code only as a hash,
and the grant itself stays redeemable — by anyone holding the URL —
until it expires or is revoked. Two hosts can pair from one URL
(grants are multi-use for their one-hour life) — each under its own
`NEXUS_NODE` name (hosts sharing a short hostname must override the
default). One host can also hold the SAME name in several threads:
names are unique per thread, so pairing the same `NEXUS_NODE` into
two threads mints two independent credentials, each with its own
state file; `NEXUS_THREAD` disambiguates a bare relaunch.

Manually, the analogous dance through the raw API (UI-token pairing
stays available to scripts — delete the stale row first, since a
re-pair over a name live in the SAME thread is a 409):

```sh
UI="Authorization: Bearer $NEXUS_UI_TOKEN"

LAPTOP_ID=$(curl -s -H "$UI" \
  http://127.0.0.1:8080/nodes | jq -r --arg t '<thread id>' \
  '.nodes[] | select(.name == "laptop" and .thread_id == $t) | .id')
# Names are unique per THREAD: filter by both, or a same-named node of
# another thread would match.
[ -n "$LAPTOP_ID" ] && curl -s -X DELETE -H "$UI" \
  "http://127.0.0.1:8080/nodes/$LAPTOP_ID"

token=$(curl -s -X POST -H "$UI" -H 'content-type: application/json' \
  -d '{"name":"laptop","thread":"<thread id>"}' http://127.0.0.1:8080/nodes | jq -r .token)  # shown exactly once

NEXUS_URL=http://127.0.0.1:8080 \
NEXUS_NODE=laptop \
NEXUS_NODE_TOKEN="$token" \
NEXUS_THREAD='<thread id>' \
gleam run -m nexus/tui
```

Optional: `NEXUS_ROLE=viewer` (events + send, no tool plane; default
`env`), `NEXUS_NODE_WORKSPACE=<dir>` (default `./node-workspace`), and
the shared knobs `NEXUS_ENV_TIMEOUT_MS` / `NEXUS_ENV_MAX_OUTPUT_BYTES`
(same floors as the server). The launcher honors `NEXUS_NODE` (node
name), `NEXUS_THREAD` (join a different thread than the grant's), and
`NEXUS_PAIR_URL` (the env form of the pairing URL); `NEXUS_URL` only
disambiguates when several servers hold stored credentials under the
same node name. Type a line to send it; `/quit` (or stdin EOF) leaves
cleanly. It is a REPL: output arriving while you type interleaves
with the half-typed line, and there is no input history.

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
