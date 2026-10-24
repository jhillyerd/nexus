---
name: llm-api
description: OpenAI-compatible LLM serving facts for nexus — prefix caching mechanics on vLLM, llama.cpp, Ollama, SGLang, and hosted OpenAI; request-shape rules that keep KV-cache prefixes reusable; and the metrics that prove cache hits. Use when changing the request-encoding path (nexus/transcript), adding background or side model calls, varying request parameters, or debugging cache hit rates.
---

# LLM API serving facts

nexus sends stateless full-history chat-completion requests to
OpenAI-compatible endpoints. Everything below is verified against
primary sources (linked at the end) and drives the client rules in §3,
which nexus's encode path already follows — keep it that way.

## 1. How the API state model works

- Every turn re-sends the entire message history. The server holds no
  conversation state; *reuse* comes from prefix caching keyed on the
  **tokenized prompt** (the rendered chat template output), not on the
  JSON body.
- A cache entry is keyed by an exact token prefix. If request N+1's
  tokens begin with request N's tokens, the shared span's KV cache is
  reused and only the new suffix is prefilled. If the head diverges
  (different system prompt, different `tools`, different model/tokenizer),
  nothing is reused.
- **Branching is safe and cheap.** From a cached prefix `X+A`, sending
  `X+A+Y` (a side request) and later `X+A+Z` (the real next turn) hits
  the shared `X+A` span both times. The dead `Y+B` branch never
  invalidates anything; it is an eviction candidate like any other
  leaf, and *touching* `X+A` during the side request refreshes its
  recency. This is the pattern behind `docs/plans/utility-titles.md`.

## 2. Per-backend mechanics

| Backend | Keying / granularity | Eviction | Branch behavior | Observability | Gotchas |
|---|---|---|---|---|---|
| **vLLM (V1)** | chained hash per **full block** (default 16 tok): `hash(parent hash, block tokens, extra hashes)`; extras include LoRA IDs, multimodal hashes, `cache_salt` | LRU from a free queue; hits *touch* blocks (refcount) so in-use prefixes survive | blocks shared across requests; branches are the documented "duplicated blocks" case | `usage.prompt_tokens_details.cached_tokens`; `vllm:gpu_prefix_cache_hit_rate` | APC on by default in V1 (V0 needs `--enable-prefix-caching`); only full blocks cached — sharing rounds down to block boundaries (≤ block_size−1 tail tokens re-prefilled); `cache_salt` isolates tenants |
| **llama.cpp (`llama-server`)** | per-slot KV (`-c` split across `-np` slots); slot chosen by prompt similarity (`-sps`, default 0.5) | slot contents replaced on divergence | `cache_prompt` (default true): keeps common prefix, `llama_memory_seq_rm` drops the rest (`kv cache rm [p, end)` in logs), decodes only the suffix | `cached_tokens` / `timings.cache_n`; slot logs (`n_past`, `n_tokens`) | `-sps` picks a *sufficient* match, not guaranteed the longest; `id_slot` pins a slot; `--cache-reuse` copies KV across slots; **`-np 1` serializes everything** — background calls block interactive ones, keep them short and cancellable; cached logits are not guaranteed bit-identical to full recompute (batch-size dependent) — never assert byte-equality on cached generations |
| **Ollama** | llama.cpp lineage; picks the slot with the **longest common prompt prefix** (not LRU) | KV retained per model ~`keep_alive` (default 5 min) | same truncate-to-common-prefix behavior | prompt-eval counts vs prompt size | occasional full re-evals have been reported — treat side calls as best-effort; `chatPrompt` truncates to the model's context (always keeps the newest message + system prompts) |
| **SGLang** | RadixAttention: radix **tree** over token prefixes shared across all requests | evicts only *leaves* (unlocked, not shadowed); interior/shared prefixes persist; `lru` default policy | branching is the native case (tree of conversations) | `cached_tokens` in usage (enable cache report) | — |
| **Hosted OpenAI** (and similar) | automatic prefix caching, prefixes ≥ ~1024 tokens | minutes-scale TTL | longest-prefix match; branches share the span before the fork | `usage.prompt_tokens_details.cached_tokens` | cached input billed at a discount; TTL means long-idle sessions re-prefill |

Sources:

- vLLM: <https://docs.vllm.ai/en/latest/design/prefix_caching/> and
  <https://docs.vllm.ai/en/latest/features/automatic_prefix_caching/>
- llama.cpp: server README
  <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>;
  KV-cache-reuse tutorial (discussion #13606)
  <https://github.com/ggml-org/llama.cpp/discussions/13606>
- Ollama: PR #5492 <https://github.com/ollama/ollama/pull/5492>,
  PR #6735 <https://github.com/ollama/ollama/pull/6735>,
  issue #5303 <https://github.com/ollama/ollama/issues/5303>
- SGLang: radix-cache eviction policy
  <https://docs.sglang.io/docs/advanced_features/radix_eviction_policy>;
  RadixAttention paper <https://arxiv.org/abs/2312.07104>
- Hosted OpenAI: prompt caching guide
  <https://platform.openai.com/docs/guides/prompt-caching>

## 3. Client rules (what keeps prefixes reusable)

1. **Append-only transcripts.** Never mutate, reorder, or re-format an
   already-sent message. Stored tool-call arguments must stay
   byte-exact (jsonb normalizes — sorted keys, stripped whitespace —
   which is why `session_message.tool_args` is `text`).
2. **Freeze everything that renders into tokens, per session**: model
   alias, system prompt, `tools` array, `tool_choice`. Any change
   diverges the prefix at the head = full re-prefill. Note some chat
   templates render `tool_choice: "required"` into the prompt — vary
   `tool_choice` only after verifying per backend.
3. **Generation-side params are the only free per-request variation**:
   `max_completion_tokens` / `max_tokens`, `temperature`, `top_p`,
   `stop` do not affect the tokenized prompt. Capping a background
   call's output does not cost prefix reuse.
4. **Side requests ride the committed transcript.** Build them through
   the same single encode path with the same envelope, append one
   instruction message, and never commit the reply — the branch is
   structurally unable to change a future request byte (same property
   as the reasoning sidecar).
5. **On serialized single-slot backends (llama.cpp `-np 1`, small
   Ollama), side calls block the user's next turn.** Fire them only
   when idle, cap their output, and cancel on the next user send.
   Dropping the connection *requests* server-side cancellation, but it
   is backend- and proxy-dependent, not a guarantee: modern
   `llama-server` watches for client disconnects, while some builds
   and buffering intermediaries have kept disconnected requests
   running. Treat cancel as best-effort, keep the output cap small,
   and verify disconnect behavior on the deployed endpoint before
   relying on it for interactive latency.
6. **Measure with `cached_tokens`, not TTFT alone.** TTFT carries
   queueing noise; `cached_tokens` (and llama.cpp's `timings.cache_n`)
   is the direct hit signal. The e2e cache gate (warm/cold TTFT median
   ratio ≤ 0.3) is the end-to-end proxy.

## 4. Where nexus encodes these rules

- `src/nexus/transcript.gleam` — the **single** request-encoding path;
  `request_body` is byte-stable by construction; `Options` carries the
  frozen envelope.
- `src/nexus/loop.gleam` (~L146) — the per-turn `Options` are built
  once at boot from global config (stream true, frozen tool schemas,
  `tool_choice: auto`); one session, one endpoint, never swapped.
- `test/m3_prefix_test.gleam` — offline golden: replaying the captured
  fixture, messages grow by suffix only and the envelope after the
  `,"stream"` marker stays byte-identical across turns.
- `e2e/integration.spec.mjs` — live cache gate on a real llama.cpp
  alias: warm/cold TTFT medians + cached-token capture; fixture
  `test/fixtures/m3_cache_session.json` (a copy of the capture step's
  `e2e/cache-session.json`).
- `sql/schema.sql` — `session_message.tool_args text` (never jsonb) and
  `session.system_prompt` frozen at creation for byte-identical
  hydration.
- `docs/plans/utility-titles.md` — the branch-request pattern applied
  to background session titles.
