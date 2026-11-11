# e2e test suite (validation only)

Headless-Chromium (Playwright) checks for the complete tool-loop flow:
tool calls, results, loop state, replay, stop, and the iteration guard in the
real Lustre/WebSocket UI. **This directory is not a Nexus runtime dependency** —
nothing here affects `gleam run` / `gleam test` / the project devShell.

## What it exercises

The suite starts everything it needs on loopback:

- **fake Bifrost** — an OpenAI-compatible SSE server with scripted scenarios
  (`case:text`, `case:slow`, `case:fetch`, `case:search`, `case:loop`) so
  tool behaviour is deterministic; it also records every chat request body
  verbatim,
- **controlled doc server** — the `http_fetch` target (including a
  `<script>` string proving previews are inert text nodes),
- **SearxNG stub** — a `/search?format=json` endpoint,
- **two real Nexus servers** (`gleam run`): the main one
  (`NEXUS_MAX_TOOL_ITERATIONS=8`, bearer auth on) and a guard instance
  (`NEXUS_MAX_TOOL_ITERATIONS=2`).

Checks: bearer auth (401/200), alias + thread lists, thread create/switch,
text-only turn, stop mid-stream with partial commit, `http_fetch` and
`web_search` tool cards (name, stable call id, argument preview, status,
compact result preview, no script injection), iteration chip, reload →
replay of the complete tool history as completed cards, iteration-guard
terminal rendering, byte-identical request-prefix growth per thread
(including after title/tag/pin/archive mutations) plus the utility
branch's own contract (the once-per-thread title+tags side call:
suffix-only branch growth off the committed transcript, envelope delta
exactly `max_completion_tokens`, the two-line reply landing as inert
tag chips, and a manual tags save freezing the set against the racing
model apply), a full
thread-organization pass (auto-title from the first message, manual rename,
tag chips + filter, pin to the pinned section, archive/restore behind the
toggle, two-step delete), the connection dot going red while the backend is
down and green again on auto-reconnect, a mobile-viewport second-context
check (per-client runtimes: a fresh context owns its selection and panels,
reload restores its own thread, no horizontal overflow with tool cards),
and (multi-provider P5) provider management end-to-end: a provider created
in the Providers panel, picked in the create panel with its model aliases
reloading, a thread pinned to it streaming a turn, and the delete-guard /
disable-picker rails — plus (bots plan P1) the bots surface: a bot created
in the Bots section, a thread started FROM it through the create panel's
bot picker (row subtitle carrying the provenance name), and the bot's
deletion leaving the thread's frozen pin intact.

## Preconditions

- **Postgres** (the compose service on `127.0.0.1:5433`) up with the
  schema applied — persistence is mandatory, so `gleam run` fails boot
  without it: `docker compose up -d` then
  `DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus gleam run -m nexus/store/migrate`.
- Each suite **resets the database first** (`psql -c 'truncate
  thread_message, thread, provider cascade'` against
  `E2E_DATABASE_URL`, default `postgres://nexus@127.0.0.1:5433/nexus`)
  so reruns and interleaved runs are deterministic, then seeds its own
  provider row (`gleam run -m nexus/dev_seed`) before booting the server — the provider table is the only provider
  source since the multi-provider P3 hard cut, and no `BIFROST_*` env
  reaches the server anymore. The browser suite's fake is keyless; the
  integration smoke encrypts the real gateway key under the same
  `NEXUS_ENCRYPTION_KEY` the server boots with.

## Run

```sh
# any machine with node ≥ 20 (browsers via `nix`/`npx playwright install chromium`):
npm --prefix e2e install
node e2e/browser.spec.mjs

# NixOS:
nix-shell e2e/playwright.nix   # node + nixpkgs chromium (see playwright.nix)
npm --prefix e2e install
node e2e/browser.spec.mjs
```

The suite writes `e2e/report.json` and exits non-zero on any failure.
The fake here exists so UI behaviour is asserted deterministically — the
integration smoke below is its realistic-service counterpart, not a
replacement.

Note for non-Nix Erlang hosts: the WebSocket upgrade needs the `crypto` NIF
to find `libcrypto`; export `LD_LIBRARY_PATH` pointing at an nixpkgs OpenSSL
`lib` directory if `erl -eval 'crypto:start(),halt().'` fails.

## Integration smoke (real services) — `node e2e/integration.spec.mjs`

Production posture through the real browser UI: bearer auth on, SSRF guard
on (`NEXUS_HTTP_FETCH_ALLOW_PRIVATE=false`), real Bifrost (llama.cpp and
vLLM aliases), real SearxNG. Same preconditions as the browser suite
(Postgres up; the suite truncates and seeds the gateway as a provider row
itself). Needs network and ~10 minutes — a live-checkpoint activity, never
CI (the CI runner has no node).

```sh
node e2e/integration.spec.mjs
# Env: BIFROST_BASE_URL, BIFROST_API_KEY (default: the live gateway),
#      SEARXNG_BASE_URL (default: https://search.bytemonkey.org/)
```

It writes `e2e/integration-report.json` and `e2e/cache-thread.json`. The
multi-turn cache check enforces the PRD KV-cache gate — warm/cold TTFT
median ratio ≤ 0.3 (one retry after node settle if the first attempt is
above the gate). Its final `capture` step archives the replayed cache
thread; the committed offline golden fixture
`test/fixtures/m3_cache_thread.json` (driving
`test/m3_prefix_test.gleam`) is a copy of that capture. When the
request-encoding path legitimately changes, re-capture the fixture through
this step — never hand-edit the JSON.

Historical evidence and measured numbers:
`docs/plans/completed/m3-verification.md`.
