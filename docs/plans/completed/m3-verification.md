# M3 verification report — tool/loop UI, browser suite, integration smoke, production cache

Workstream C of the M3 plan. Verifies the complete M3 flow — typed tool-call
rendering in the Lustre UI, replay, iteration state, and the guard — first in
a real browser against controlled services, then against the realistic
Bifrost/SearxNG services, and finally the production KV-cache contract on a
multi-turn tool session.

Branch: `feature/render-m3-tools-and-c4e576`. All commands run from the repo
root on NixOS (playwright + headless Chromium via `e2e/playwright.nix`; the
suite itself only needs Node ≥ 20 — see `e2e/README.md`).

## 1. What shipped

### UI (`src/nexus/ui.gleam`, `src/nexus/page.gleam`)

- **Typed tool-call cards**: tool name, stable call id
  (`data-call-id`), truncated argument preview (120 chars), status
  (`running` / `completed` / `failed`), and a compact **inert** result
  preview (200 chars). All output is Lustre text nodes — no `innerHTML`
  anywhere (regression-tested with `<script>` payloads).
- **Live assembly**: `ToolCallDelta` fragments accumulate into pending cards
  keyed by chunk index (parallel calls stay separate);
  `ToolCallAssembled` finalises them; `ToolResult` attaches the result and
  terminal status. Assistant text streaming before a call commits first,
  mirroring the server's transcript order.
- **Iteration chip**: `iter n/max · phase` (`request` / `tools` / `guard`)
  while a turn is in flight; terminal guard rendering rides the chip plus
  the turn-failed note.
- **Failure semantics**: a failed turn rolls its uncommitted lines back to
  the user line (matching the server, which commits nothing); a
  guard-tripped turn keeps its committed rounds and final text (matching the
  loop's commit rules).
- **Replay**: `Hello` replay reconstructs the complete tool history as
  completed cards — tool events are never rendered as model text.
- Mobile-friendly CSS; the whole card is `overflow-wrap: anywhere`.

### Bugs the browser suite caught (all fixed here)

1. **UI dead under auth**: the Lustre client runtime `<script>` had no token
   path, so `/lustre/runtime.mjs` 401'd and the component never booted. The
   token now rides the script query string (same exposure as the ws route;
   never enters JavaScript).
2. **Closed shadow root**: `open_shadow_root(False)` is a *closed* root (the
   "light DOM" comment was wrong). Switched to an open root — pierceable by
   tests/devtools; `adopt_styles` still clones the page stylesheet in.
3. **Create-panel latch**: the panel auto-opened when the component booted
   before the registry's first session existed and then stayed open —
   clicking "New" *closed* it. Auto-opened panels now auto-close once a
   session is selectable.
4. **Alias list never retried**: a transient `list-models` failure at boot
   left the picker empty for the component's lifetime; reconnects now
   refresh aliases.
5. **Tool-less sessions**: UI/API-created sessions used
   `session.bifrost_runner` (empty tool registry), so only the boot session
   could call tools. The registry now owns the agent-loop runner built once
   from the frozen toolset at its boot (identical schema for every session,
   per the M3 pre-creation requirement).

## 2. Offline suite

```
gleam format --check   # clean
gleam check            # clean
gleam test             # 158 passed, no failures
```

New coverage: `test/ui_test.gleam` (tool deltas → pending cards, parallel
call separation, assembled cards, result attach, statuses, replay
reconstruction, rollback vs guard-keeps, truncation, chip rendering,
escaping), `test/web_test.gleam` (tokenised runtime src), and
`test/m3_prefix_test.gleam` (the golden prefix test below).

## 3. Browser suite (controlled services) — `node e2e/browser.spec.mjs`

Real Nexus servers (`gleam run`) + real Chromium + real WebSocket UI; the
model backend is a scripted OpenAI-compatible fake so tool behaviour is
deterministic; `http_fetch` targets a controlled doc server (whose payload
contains a `<script>` string) and `web_search` a SearxNG stub.

Two instances: main (`NEXUS_MAX_TOOL_ITERATIONS=8`, bearer auth on) and a
guard instance (`=2`).

```
14 passed, 0 failed
  auth: page without token is 401
  auth: page with token is 200 html
  auth: models api requires token
  page: loads, connects websocket, lists aliases and sessions
  sessions: create on second alias and switch back
  turn: text-only round streams and completes with metrics   (cached 800/1000 visible)
  stop: mid-stream stop commits partial text                 (stopped metric row)
  tools: http_fetch card renders args, result, and status
  tools: web_search card completes with stub result
  loop: iteration chip visible while streaming, hidden after
  reconnect: reload replays full tool history as cards       (2 fetch + 1 search, stable ids)
  guard: max-iteration turn renders terminal state           (guard note + kept completed card)
  prefix: recorded request bodies grow by suffix only        (per session, envelope identical)
  mobile: no horizontal overflow with tool cards
```

Inertness is asserted directly: the fetched `<script>` payload appears as
text and the page still contains exactly one `<script>` element (the
runtime).

## 4. Integration smoke (real services) — `node e2e/integration.spec.mjs`

Production posture: `NEXUS_UI_TOKEN` on, `NEXUS_HTTP_FETCH_ALLOW_PRIVATE=false`,
live Bifrost (`bifrost.bytemonkey.org/v1`), Nomad-hosted SearxNG
(`search.bytemonkey.org`).

```
7 passed, 0 failed
  auth: bearer token gates the page
  page: live alias list from real Bifrost          (dgx1/qwen3.8-flash-next-a5b, fractal/unsloth/Qwen3.6-35B-A3B-GGUF:…)
  tools: web_search round on vLLM via real SearxNG (completed card, GitHub releases result)
  tools: http_fetch round on llama.cpp             (public URL — see note)
  reconnect: real tool history replays after reload (per session)
  cache: multi-turn tool sessions — warm/cold TTFT medians + cached tokens
  capture: cache session archived for the golden prefix test
```

Notes:

- **Real tool calls observed end-to-end** on both backends: vLLM streamed a
  native `web_search` call (call id `chatcmpl-tool-…`) whose result came from
  the real SearxNG instance; llama.cpp streamed an `http_fetch` call whose
  result preview shows the fetched README body.
- **SSRF guard verified in production posture**: hosts on this network
  resolve to private ranges, and the guard refused them with
  `refusing private address …` rendered as a **failed** tool card — the
  fetch round therefore targets a genuinely public URL
  (`raw.githubusercontent.com`).
- Model flakiness is absorbed by up to three send-retries per tool round
  (real models occasionally answer from memory); every retry is visible in
  the log.

## 5. Production cache verification

Spike-C methodology on the llama.cpp alias (the backend proven to pass cache
through Bifrost): **3 fresh nexus VMs**, each with a unique ~6.4k-token nonce
system prompt so the first turn prefills genuinely uncached tokens, then one
`http_fetch` round plus five short warm follow-ups. Gate: PRD
warm/cold TTFT ratio ≤ 0.3 on medians.

```
session 1 ttfts=[10382, 1449, 1677, 1515, 2690, 3205]ms  cached=[6023/6408, 6404/6474, 6470/6513, 6509/6553, 6549/6579, 6575/6604]
session 2 ttfts=[11647, 4139, 1569, 2846, null, 6938]ms cached=[5933/6318, 6314/6380, 6376/6420, 6416/6460, 6456/6486, 6482/6501]
session 3 ttfts=[11010, 1688, 1785, 2131, 1755, 3196]ms cached=[5933/6318, 6314/6380, 6376/6419, 6415/6459, 6455/6485, 6481/6510]

cold median = 11010 ms   warm median = 1785 ms   ratio = 0.162  ✓ (≤ 0.3, attempt 1)
```

- Warm turns report **95–99 % cached prompt tokens** (`cached_tokens` /
  `prompt_tokens`), visible in the metrics panel as `cached 6575/6604`.
- The `null` TTFT is a completed turn with no content deltas (tool-only
  round); medians ignore it.
- Warm TTFT variance (±5 s outliers on turns with the *best* cache hits) is
  llama.cpp scheduling / reasoning-before-content, not prefill — this is why
  the gate uses medians, exactly as spike C did.

### Byte-identical prefixes (offline golden)

The last real session (system prompt incl. nonce, user texts, tool call
ids/names/arguments, tool results, final answers) is archived in
`test/fixtures/m3_cache_session.json`. `test/m3_prefix_test.gleam` rebuilds
it turn-by-turn through the same append-only `nexus/transcript` path the
loop uses and asserts, per turn boundary:

1. re-encoding is deterministic (byte-equal), and
2. each request embeds the previous request's message array verbatim
   (suffix-only growth) with an unchanged envelope (`model`, `stream`,
   `tools`, `tool_choice`) — the frozen tool schema.

Together with the live measurements above this closes the KV-cache contract:
prefixes are byte-identical *and* the engine confirms the hits.

## 6. Re-running

```sh
gleam format --check && gleam check && gleam test   # offline, network-free
npm --prefix e2e install
node e2e/browser.spec.mjs                           # controlled services (fake Bifrost)
node e2e/integration.spec.mjs                       # real Bifrost + SearxNG + cache gate (~10 min)
```

`e2e/integration.spec.mjs` writes `e2e/integration-report.json` and
`e2e/cache-session.json`; the committed fixture is a copy of the capture.
