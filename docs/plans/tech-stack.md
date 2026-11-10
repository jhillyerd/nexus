---
title: Nexus — MVP tech stack (how Gleam talks to Bifrost)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam]
updated: 2026-10-13
---

# Nexus tech stack: talking to Bifrost from Gleam

Companion to [2026-10-11-gleam-agent-mvp-prd.md](2026-10-11-gleam-agent-mvp-prd.md). The PRD's
open question was "how do we talk to Bifrost from Gleam" — historically the weakest part of the
Gleam ecosystem. Short version: **the ecosystem has grown the right pieces.** We don't adopt a
monolithic LLM client; we compose a sans-IO codec (`glopenai`) with a streaming HTTP transport
(`httpp`), and keep both swappable behind one module. Constraints applied throughout: **Erlang
target only** (JS-only libs invalid), **streaming is mandatory**, and libraries must not pin us to
an HTTP client or async framework they don't actually need.

## Decision at a glance

| Concern | Pick | Version | Notes |
|---|---|---|---|
| Language/runtime | Gleam → Erlang/OTP | Gleam 1.15, OTP 28 | Matches glopenai's CI matrix |
| LLM codec (types, JSON, tool schema, stream chunks) | **glopenai** | 1.0.0 | Sans-IO, `target = "erlang"` |
| HTTP transport (streaming) | **httpp** (hackney) | 1.8.0 | SSE actor → process subject |
| Transport fallback | own `httpc` FFI + `ssevents` | — | ~100 lines Erlang, zero third-party HTTP deps |
| Web server | **mist** | 6.0.3 | SSE support built in (`mist.server_sent_events`) |
| Web framework (non-streaming routes) | wisp | 2.2.2 | No streaming/SSE — bypass for the chat route |
| Concurrency | gleam_otp actor + supervisor | — | One actor per thread, per PRD |
| JSON | gleam_json | 3.x | Deterministic encoding — see cache notes |
| Env config | envoy | — | Bifrost URL, bearer token |
| Tests | gleeunit (+ birdie optional) | — | Birdie snapshots for request encoding |
| Frontend | **lustre/server_component** over mist WebSocket | lustre 5 | The shipped UI: component runs on the server, a ~10kb client runtime patches the DOM — see below |

## The Bifrost question, decomposed

Bifrost is OpenAI-compatible (`/v1/chat/completions`, `/v1/models`, aliased names). "Talk to
Bifrost" is really three separable problems, and Gleam now has a good answer for each:

1. **Types + codec** — encode chat requests (messages, tools, `stream: true`), decode responses
   and per-chunk stream deltas including tool-call accumulation.
2. **Streaming HTTP transport** — send the POST, receive the body incrementally as chunks.
3. **SSE framing** — split the byte stream into `data:` events, feed the codec.

No single Gleam library does all three well, but the pieces compose cleanly — deliberately so, via
sans-IO design. (Continuity note: nexus-old's `agent/llm.gleam` was a *buffered* `gleam_httpc`
completion function — no streaming, no tools. The prototype never solved this; this stack does.)

## LLM libraries evaluated

### glopenai — **pick (codec layer)**

[nilp0inter/glopenai](https://github.com/nilp0inter/glopenai) · v1.0.0 · MIT · sans-IO port of
Rust's `async-openai`.

- **Sans-IO**: builds `Request(String)`, parses `Response(String)`, never sends anything. Deps are
  only `gleam_stdlib`, `gleam_json`, `gleam_http`. No HTTP client, no async framework — exactly the
  runtime-agnostic property we need, and it means swapping transports later costs nothing.
- **`target = "erlang"`** in its gleam.toml — not JS-only, it's the inverse: Erlang-only. Fine for
  us, disqualifying only if we ever wanted the JS target.
- **Streaming is modeled properly**: `chat.parse_stream_chunk(data)` parses one SSE `data:` line
  into a `CreateChatCompletionStreamResponse`, handles the `[DONE]` sentinel itself, and the stream
  delta decoder covers `content`, `refusal`, and **`tool_calls` chunks (index/id/function)** — i.e.
  streamed tool-call accumulation is a solved decode; we only write the accumulator.
- **Tools + JSON schema + reasoning effort** all represented (`with_tools`, `with_tool_choice`,
  `with_response_format`, `with_reasoning_effort`).
- **Bifrost fit**: `config.with_api_base("http://bifrost:port/v1")` + bearer key via `config.new`;
  README explicitly blesses OpenAI-compatible endpoints (Ollama example).
- Caveats, honestly: young project (first pushed 2026-04, single maintainer, quiet since), and its
  "generic SSE parsing helper" is listed as *planned* — SSE framing must come from the transport.
  Risk is contained: it's a pure codec with tests, trivially vendorable/forkable if abandoned.

### starlet — **reject as dependency, steal the design**

[jtdowney/starlet](https://github.com/jtdowney/starlet) · v1.0.1 · provider-agnostic (OpenAI /
Anthropic / Gemini / Ollama).

- README's own "Missing Features": **streaming responses**. Non-starter for us — long-reasoning
  models make token streaming mandatory.
- It also **prescribes the transport**: depends on `gleam_httpc`, which only does buffered
  requests. The coupling we were told to avoid, in its mildest form.
- Worth keeping as *prior art*: its `starlet.step` / `ToolCall` / `apply_tool_results` +
  `tool.dispatch` shape is a clean model for nexus's own agent-loop API. Read it, don't import it.

### Footnotes

- **anthropic_gleam** v0.1.1 — sans-IO Anthropic client *with* incremental SSE streaming handler.
  Irrelevant while Bifrost speaks the OpenAI dialect, but it's the best in-repo example of the
  incremental-parse pattern if we roll our own transport.
- **overlay_llm** v0.2.0 (CrowdHailer's overlay) — provider-unifying completion API, too young and
  Ollama/Mistral-only.
- **llmgleam** v0.0.x — pre-1.0, provider support unclear, skip.

## Transport: how the bytes actually move

### First choice for M0: httpp (hackney + SSE actor)

[VioletBuse/httpp](https://github.com/VioletBuse/httpp) · v1.8.0 · Apache-2.0 · Erlang-only
(hackney 1.18).

- `httpp/sse.event_source(req, timeout, subject)` spawns a managed process that streams the
  response and **sends parsed `Event(event_type, event_id, data)` / `Closed` messages to a Gleam
  subject**. That's the BEAM-native shape we want: a thread actor just receives tokens like any
  other message, supervision falls out for free.
- SSE framing handled internally (data/event/id/comment lines, `\n\n` splits). No auto-reconnect —
  which is what we want: a dropped stream is a failed turn, never a silently-resumed one (append-only
  contract).
- Also does plain buffered sends, so it's the **only HTTP dependency** — one client for chat
  streaming, `/v1/models`, `http_fetch`, and SearXNG.

Assembly: `glopenai.chat.create_request(... |> with_stream(True))` → `event_source` → for each
`Event(data: d)` call `glopenai.chat.parse_stream_chunk(d)` → forward text/tool deltas to the
thread actor → `mist` SSE to the browser.

### Fallback: stdlib httpc FFI + ssevents

`gleam_httpc` is **buffer-only** — the docs and the `aws_gleam_runtime` FFI comments are explicit
that streaming needs `{sync, false}, {stream, self}` which `gleam_httpc` does not expose. But that
FFI is ~100 lines of Erlang (precedent: `aws_streaming_ffi.erl` in aws_gleam_runtime) and pairs
with **ssevents** v0.14.0 — runtime-agnostic SSE encode/decode with incremental chunk parsing.
This is the "own every line" option: zero third-party HTTP deps, chunks arrive as plain OTP
messages. If httpp fights us in spike A, this is the two-evening fallback, not a redesign.

## Server side: mist (+ wisp, with a caveat)

- **mist** v6.0.3 is the server. It has **built-in SSE**: `mist.server_sent_events` +
  `mist.send_event`, with `actor.stop()` closing the stream — exactly the stop-button semantics we
  need, and WebSockets too (the shipped UI uses the WebSocket path).
- **wisp** v2.2.2 for the boring routes (auth check, thread list, model picker) — but it
  **cannot stream**: [wisp#149](https://github.com/gleam-wisp/wisp/issues/149) is still open and
  lpil explicitly notes wisp lacks SSE/chunked by design pending a story. Pattern: mount mist as
  the server, branch the streaming path (SSE or WebSocket) *before* delegating the rest to
  `wisp_mist.handler`. This isn't theoretical — nexus-old's `router.mist_handler` shipped exactly
  this shape, branching `/ws/chat` to a mist websocket and passing everything else to wisp. If the
  branching feels gross in M1, wisp is optional — mist alone can serve the whole (small) MVP.

## Frontend: lustre server components (the shipped choice)

The original M1 plan was server-rendered HTML + a vanilla `EventSource` client,
with lustre as the researched alternative; the alternative won and is what
ships (`nexus/ui_runtime` + `/ws`). The detailed lifecycle and transport
research that informed the switch lives in git history
(`docs/plans/chat-ui-server-rendering.md`, removed post-MVP).

[lustre](https://lustre.hexdocs.pm/lustre/server_component.html) v5 server components run the
component *on the server*: view patches broadcast to a ~10kb client runtime
(`lustre-server-component.mjs`) that patches the DOM, and client events flow back in real time.
The Elm-architecture model lives in our thread actor — the UI state and the transcript state are
the same process.

This isn't hypothetical either: **nexus-old's chat used exactly this** (lustre 5.6, mist 5, wisp 2)
and it worked:

- `agent/socket.gleam` renders `server_component.element([server_component.route("/ws/chat")])`
  inside a wisp-served page; the runtime connects back over a mist websocket mounted ahead of the
  wisp handler (`router.mist_handler`), with `server_component.register_subject` wiring each
  client's events into the shared `lustre.Runtime(chat.Msg)`.
- The runtime script is served from the lustre hex package's priv dir (`/lustre/runtime.mjs`
  route → `priv/static/lustre-server-component.mjs`) — one wisp static route.

What it buys: typed Gleam views instead of JS string-shuffling; **free multi-client sync** (phone
+ desktop tabs on one thread stay in sync — each connection just registers another subject); the
stop button is a message to the actor, not DOM plumbing. What it costs: the lustre dependency and
its "advanced feature" surface, WebSocket instead of plain SSE, per-token server re-render
(irrelevant at chat scale), markdown needing unsafe-HTML insertion, and API drift to re-verify
(5.6 in nexus-old → 5.7.1 current).

**Decision** (historical): EventSource for the M1 skeleton, lustre to be
revisited when tool-call rendering and the metrics panel landed. That
revisit happened at M3 and lustre won — the shipped UI is the server
component over `/ws`; the vanilla-EventSource client was removed in the
post-MVP cleanup (git history).

## Rest of the stack (quick justifications)

- **Concurrency**: one `gleam_otp` actor per thread holding the transcript; a supervisor restarts
  crashed threads clean (`kill -9` acceptance criterion). Telegram adapter later is just another
  supervised actor.
- **gleam_json**: deterministic encoding — field order follows construction order, so re-encoding
  an unchanged transcript prefix yields byte-identical output. The KV-cache contract's
  "byte-identical prefix" rule is enforceable by *always rebuilding requests from the same
  immutable message list with the same code path* — never store serialized turns and re-serialize.
- **Frontend**: lustre server component over WebSocket — see the dedicated section above.
- **Deployment**: `gleam export erlang-shipment` → tarball artifact (or a Nix-built image) run as
  a Nomad job, loopback bind; remote access rides the Tailscale VPN mesh (VPN only, no Serve).
- **Post-MVP**: persistence = `pog` (Postgres), when v1 lands.

## Mapping to M0 spikes

- **Spike A (streaming)**: glopenai + httpp against Bifrost, tokens to stdout. Checklist while
  there: (a) non-200 responses must surface as a catchable error — `httpp/sse`'s error path may
  need the lower-level `httpp/streaming` API or a small patch; (b) hackney receive-timeout
  behavior on long silent prefill/reasoning gaps — needs a long/infinite idle timeout, not a total
  one.
- **Spike B (tools)**: `with_tools` + `parse_stream_chunk` tool-call deltas → accumulator →
  `apply` a result turn; test llama.cpp *and* vLLM behind aliases.
- **Spike C (cache)**: unchanged from PRD; additionally assert our own encoder emits stable bytes
  across turns (golden-file a 20-turn prefix hash).

## Risks

| Risk | Mitigation |
|---|---|
| glopenai abandoned / drifts | Pure codec, vendor it; API surface we use is small (chat + models) |
| httpp small project | Fallback exists and is cheap (httpc FFI + ssevents); or vendor — the SSE module is ~200 lines |
| hackney TLS/pooling quirks in Nomad | Single-loopback upstream; if painful, fallback transport again |
| lustre server components drift/break | "Advanced feature" label; nexus-old pins a working 5.6 wiring; the pre-lustre EventSource client is recoverable from git history |
| wisp can't stream (by design) | Streaming route bypasses wisp at the mist layer (pattern shipped in nexus-old); wisp is convenience, not load-bearing |

Bottom line: nothing here justifies failing M0 on paper — the stack is Gleam 1.15/OTP 28, glopenai
for the OpenAI wire format, httpp for streaming bytes, mist for streaming to the browser, plain
actors for threads. The spikes now verify behavior (timeouts, error paths, cache passthrough),
not whether the pieces exist.
