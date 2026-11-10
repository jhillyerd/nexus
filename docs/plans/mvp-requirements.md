---
title: Nexus — Gleam on BEAM agent micro-PRD (MVP)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam]
updated: 2026-10-11
---

# Nexus: Gleam on BEAM — MVP PRD

**Thesis.** Replace hermes-agent + hermes-webui with nexus, a thin agent harness I own,
written in Gleam
on the BEAM. The MVP exists to answer one question: *can I get the LLM features I actually use —
streaming, tool calling, prefix-cache-friendly prompts — working in Gleam against Bifrost?*
Everything else is deferred. If the de-risking spikes (M0) fight the runtime, stop; hermes-webui
stays.

This continues [2026-10-06-personal-assistant-agents.md](2026-10-06-personal-assistant-agents.md):
same requirements, new candidate — write it.

## Why

- No third-party candidate satisfies both halves: hermes-agent is a fine harness but every UI
  option is a compromise (built-in dashboard / Hermes Desktop everywhere, or nesquena's webui
  which is rough and painful to pin).
- The gap is small: I need threads + streaming + tools + a UI, not a platform. That's a
  buildable amount of software.
- BEAM is the right runtime for a harness: supervision means a crashed LLM client or tool run
  never takes the thread store; one process per thread is the natural concurrency model;
  Telegram long-polling later is just another supervised actor.
- Honest motivation: I want to learn Gleam. The MVP is sized so that wanting-to-learn is the
  *only* thing at risk if it fails.

## Hard requirements (inherited, non-negotiable)

1. **Multi-thread web UI**, mobile-friendly — the primary surface.
2. **Prefill/KV-cache preservation** — hard disqualifier if violated (contract below).
3. **Topology**: deployed as a Nomad job (quick deploys), no GPU at the app; all inference via
   Bifrost (OpenAI-compatible, aliased model names).
4. **State**: none in the MVP — in-memory only, history lost on restart by design. When
   persistence lands in v1: external Postgres server (well supported from Gleam), never a
   database on NFS host volumes (SQLite on NFS corrupts).
5. **Single user**; loopback bind, remote access over the Tailscale **VPN** mesh (VPN
   transport only — no Serve/funnel, nothing to test on that front).
6. **Telegram reachable** — required for the v1 *product*, strictly post-MVP. The channel
   boundary stays clean from day one so it's additive, not a rewrite.

## MVP scope

**In:**

- Threads: create / list / resume; in-memory history only (lost on restart — accepted for MVP)
- Chat: send → tokens stream to the browser; stop button
- Model alias picker sourced from Bifrost `/v1/models`; alias pinned per thread
- Tool-calling loop with two safe tools: `http_fetch` + `web_search` (Nomad-hosted SearXNG);
  max-iteration guard
- Per-request metrics: TTFT, prefill hit/miss, token counts — the cache contract stays verified
  in production, not just in the spike
- Auth: single bearer token

**Out (post-MVP / v1):** Telegram channel, Hindsight memory (as a tool — cache-safe), durable
persistence (external Postgres), message editing/branching, attachments, scheduled jobs, MCP,
multi-user, voice.

## The KV-cache contract (the differentiator)

Rules enforced in code, not by convention:

1. Transcript is **append-only**. No edits, no reordering, no re-summarization. (MVP: editing
   simply disabled.)
2. System prompt + tool schema are **frozen at thread creation**. Changing either forks a new
   thread.
3. Volatile context (timestamps, recall results) may only appear **in the newest user turn** —
   never above the tail.
4. Requests are **stateless but identical**: full history every turn, byte-identical prefix.
   Prefix caching (llama.cpp `cache_prompt`, vLLM APC) does the actual work — the app's only job
   is to never change a byte above the tail. No per-turn IDs or timestamps injected early.
5. **Thread→backend affinity**: Bifrost must route one thread to one backend (llama.cpp slot /
   vLLM node) or hit rates collapse. Verify Bifrost routing; pin client-side if needed.
6. **Bifrost must pass request bodies through unmodified** between turns — verify in M0.

Acceptance: warm TTFT ≤ 30% of cold TTFT on a 20-turn thread. Every request logs prefill
hit/miss + TTFT; a warm/cold ratio drifting above the threshold is a bug, not a curiosity.

## Milestones

| ID | Scope | Timebox |
|----|-------|---------|
| M0 | De-risk spikes (see below) — go/no-go gate | ≤ 1 week |
| M1 | Walking skeleton: one thread, web page, streamed replies, clean restart recovery | ≤ 1 week |
| M2 | Multi-thread UI: list/switch, alias picker, stop, metrics panel | 1–2 weeks |
| M3 | Tool loop: `http_fetch` + `web_search` (SearXNG), iteration guard, tool calls rendered in UI | ≤ 1 week |
| v1 | Telegram adapter, external Postgres persistence, Hindsight tool, shell tool w/ approval gate, attachments | post-MVP |

MVP target: **4–6 weeks part-time. Hard review at 8**: ship what exists or revert to hermes-webui.

**M0 spikes** (each gets two evenings, then verdict):

- **A — Streaming**: token-by-token from Bifrost to stdout — any transport, FFI is fair game.
- **B — Tool calls**: round-trip with the models actually served (llama.cpp *and* vLLM behind
  aliases). Fallback if native tools are flaky: prompted JSON-mode tools.
- **C — Cache**: warm/cold TTFT measurement harness; confirms Bifrost passthrough + affinity.

Kill criteria: any spike still fighting the runtime after two evenings with no demo → M0 fails →
hermes-webui remains daily driver. (Keep the spike-C harness regardless — it's a useful tool for
auditing *any* candidate.)

## Success criteria

- Daily driver for one week; hermes-webui unused.
- Warm/cold TTFT ratio ≤ 0.3 sustained, visible in the metrics panel.
- `kill -9` mid-stream → clean supervisor restart. History loss on restart is accepted until v1.
- I understand every line. That's the point of owning it.

---

## Verdict (decision gate)

Build *iff* M0 passes all three spikes within budget. The PRD's real deliverable is the gate:
Gleam gets two evenings per spike to prove streaming, tool calling, and cache verification — not
a leap of faith, and not a rewrite of hermes-agent.
