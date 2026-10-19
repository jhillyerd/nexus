# M3 browser suite (validation only)

Headless-Chromium (Playwright) checks for the complete M3 flow: tool calls,
results, loop state, replay, stop, and the iteration guard in the real
Lustre/WebSocket UI. **This directory is not a Nexus runtime dependency** —
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

Checks: bearer auth (401/200), alias + session lists, session create/switch,
text-only turn, stop mid-stream with partial commit, `http_fetch` and
`web_search` tool cards (name, stable call id, argument preview, status,
compact result preview, no script injection), iteration chip, reload →
replay of the complete tool history as completed cards, iteration-guard
terminal rendering, byte-identical request-prefix growth per session
(including after title/tag/pin/archive mutations), a full
session-organization pass (auto-title from the first message, manual rename,
tag chips + filter, pin to the pinned section, archive/restore behind the
toggle, two-step delete), the connection dot going red while the backend is
down and green again on auto-reconnect, and a mobile-viewport overflow check.

## Preconditions

- **Postgres** (the compose service on `127.0.0.1:5433`) up with the
  schema applied — persistence is mandatory, so `gleam run` fails boot
  without it: `docker compose up -d` then
  `DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus gleam run -m nexus/store/migrate`.
- Each suite **resets the database first** (`psql -c 'truncate
  session_message, session, provider cascade'` against
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
Realistic-service verification (live Bifrost aliases, Nomad-hosted SearxNG)
is the integration smoke in `docs/plans/m3-verification.md` — the fake here
exists so UI behaviour is asserted deterministically, not to replace it.

Note for non-Nix Erlang hosts: the WebSocket upgrade needs the `crypto` NIF
to find `libcrypto`; export `LD_LIBRARY_PATH` pointing at an nixpkgs OpenSSL
`lib` directory if `erl -eval 'crypto:start(),halt().'` fails.
