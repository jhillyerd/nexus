# HTTP & WebSocket API

The browser UI talks exclusively to the Lustre server component over
`/ws`. The JSON routes below are the scripting, automation, and e2e API.

## Authentication

When `NEXUS_UI_TOKEN` is set, every route requires `Authorization: Bearer <token>`
(or `?token=<token>` on browser/WebSocket/asset routes), except:

- `GET /healthz` — unauthenticated liveness probe
- `GET /node/ws` — authenticated by a per-thread node token (`token`
  query param or `Authorization: Bearer`)
- `POST /nodes/pair` — public pairing exchange authenticated by the
  pairing code itself

## UI & static assets

- `GET /` — Lustre server-component page shell
- `GET /threads/<id>` — same page shell targeting a specific thread URL
- `GET /ws` — Lustre server-component WebSocket transport
- `GET /lustre/runtime.mjs` — vendored Lustre client runtime
- `GET /css/pico.min.css` — vendored Pico CSS stylesheet
- `GET /healthz` — returns `200 {"ok":true}`

## Providers

Each provider is an OpenAI-compatible `/v1` endpoint. API keys are stored
encrypted (AES-256-GCM) and never returned; responses expose `has_key`
only. Keyless local endpoints (Ollama, llama.cpp, vLLM) are first-class.

- `GET /providers` — list providers (masked metadata)
- `POST /providers` `{"name","base_url","api_key"?}` — create (`201`).
  `base_url` must end in `/v1` (normalized server-side). Omit or leave
  `api_key` blank for a keyless provider.
- `GET /providers/<id>/models` — live model list from the provider's
  `/v1/models` (`404` unknown, `400` disabled, `502` upstream error)
- `PATCH /providers/<id>` `{"name"?,"base_url"?,"api_key"?,"enabled"?}` —
  present keys replace, absent keys keep. A blank `api_key` keeps the
  stored key; `enabled: false` disables the provider without deleting it.
- `DELETE /providers/<id>` — hard delete (`204`); returns `409` while
  any thread or bot references the provider.

## Bots

Bots are named creation-time templates (provider, model, system prompt,
toolset). Editing a bot never mutates existing threads; deleting a bot
leaves existing threads intact (`bot_id` becomes `NULL`).

- `GET /bots` — list bots
- `POST /bots` `{"name","provider","model","description"?,"system_prompt"?,"tools"?}` —
  create (`201`). Unknown provider → `400`. Blank/absent `system_prompt`
  uses the server's default prompt at thread creation.
- `PATCH /bots/<id>` `{"name"?,"description"?,"provider"?,"model"?,"system_prompt"?,"tools"?,"allow_inbound"?}` —
  present keys replace, absent keep. Blank `name`/`provider`/`model`
  keeps the stored value; blank `description`/`system_prompt` clears it.
  An empty patch returns `400`.
- `DELETE /bots/<id>` — hard delete (`204`).

## Threads

Every thread is created from a bot and freezes its `(provider, model,
system_prompt, tools)` tuple at creation.

- `GET /threads` — active thread summaries, pinned first then most
  recently active (excludes child bot-channel threads)
- `GET /threads?archived=1` — archived thread summaries only
- `POST /threads` `{"bot":"<bot_id>"}` — create a thread from a bot
  (`201`). Any request body without `bot`—or combining `bot` with
  `provider`, `model`, or non-null `tools`—returns `400` (unknown bot
  also returns `400`).
- `PATCH /threads/<id>` `{"title"?,"pinned"?,"tags"?,"archived"?}` —
  update organizational metadata. Archiving clears `pinned`; pinning an
  archived thread without restoring it in the same patch returns `409`.
- `DELETE /threads/<id>` — cancel any running turn, stop the actor, and
  delete the thread (`204`).
- `POST /threads/<id>/send` `{"text":"…"}` — start a turn (`202`, or
  `409` while a turn is in flight).
- `POST /threads/<id>/stop` — cancel the active turn and commit partial
  text.
- `GET /threads/<id>/state` — read-only debug dump returning JSON
  `{summary, status, messages, live_turn}` (`live_turn` is `null` when
  idle). Lazy-starts dormant threads; intended for curl/tests, never as
  a UI data source.

## Remote nodes & pairing

Node names are unique per thread.

- `GET /nodes` — list paired nodes (token hashes are never returned)
- `POST /nodes` `{"name":"laptop","thread":"<thread_id>"}` — mint a node
  credential (`201`). The plaintext `token` is returned **once**; only
  its SHA-256 hash is stored. Duplicate name in that thread → `409`,
  invalid/reserved name → `400`, unknown thread → `404`.
- `POST /nodes/pair` `{"code":"…","name":"laptop","thread"?}` — redeem a
  web-minted 1-hour multi-use pairing code for a node credential and
  effective thread ID (no UI token required). Name validation runs
  before code lookup (`400` unconditionally for invalid/reserved names);
  after a valid name, unknown/expired/revoked codes return a single
  merged `404`. With a valid code, an unpinned grant with no `thread`
  returns `400`, an unknown effective thread returns `404`, and a
  duplicate name in that thread returns `409`.
- `DELETE /nodes/<id>` — revoke a node token (`204`, idempotent; blocks
  future connections without killing a live one).
- `GET /node/ws?node=<name>&token=<token>&thread=<id>&role=env|viewer` —
  versioned (`"v": 1`) JSON WebSocket protocol carrying thread events,
  user `send` frames, and MCP-shaped `tools/call` / `notifications/cancelled`
  frames. `role=env` (default) attaches the node as a workspace target
  (`403` on threads without env tools); `role=viewer` joins with events
  and send only.

## Examples

```sh
BASE="http://127.0.0.1:8080"
AUTH="Authorization: Bearer $NEXUS_UI_TOKEN"

# 1. Create a provider (omit api_key for keyless local endpoints)
PID=$(curl -s -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"local","base_url":"http://127.0.0.1:11434/v1"}' \
  "$BASE/providers" | jq -r .id)

# 2. Inspect models offered by that provider
curl -s -H "$AUTH" "$BASE/providers/$PID/models"

# 3. Create a bot
BID=$(curl -s -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"name\":\"assistant\",\"provider\":\"$PID\",\"model\":\"qwen3:8b\"}" \
  "$BASE/bots" | jq -r .id)

# 4. Create a thread from the bot and send a turn
TID=$(curl -s -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"bot\":\"$BID\"}" \
  "$BASE/threads" | jq -r .id)

curl -s -H "$AUTH" -H 'content-type: application/json' \
  -d '{"text":"Hello!"}' \
  "$BASE/threads/$TID/send"
```

## Out-of-band provider seeding (`dev_seed`)

To seed or update a provider row before starting the server (e.g. in CI
or local scripts):

```sh
DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
NEXUS_ENCRYPTION_KEY="$NEXUS_ENCRYPTION_KEY" \
NEXUS_SEED_PROVIDER_NAME=bifrost \
NEXUS_SEED_PROVIDER_BASE_URL=https://gateway.example/v1 \
NEXUS_SEED_PROVIDER_API_KEY="sk-…" \
gleam run -m nexus/dev_seed
```

Omit `NEXUS_SEED_PROVIDER_API_KEY` (or leave it blank) for a keyless
provider. The tool is idempotent by name and never prints the API key.
Run it before booting the server (or restart afterwards), as the
provider registry loads at startup.
