---
title: Nexus — Context Usage Monitoring & KV-Cache-Aware Compaction
status: draft
tags: [nexus, context, compaction, kv-cache, usage, slash-commands, postgres]
updated: 2026-11-28
---

# Context Usage Monitoring & KV-Cache-Aware Compaction

Related: `.agents/skills/llm-api/SKILL.md` (prefix-caching mechanics across vLLM, llama.cpp, SGLang, Ollama, OpenAI), `docs/plans/completed/utility-titles.md` (prefix-cache piggybacking pattern), `docs/plans/completed/bots.md` (snapshot-at-creation bot templates), `docs/plans/environments.md` (tail roster lines).

**Thesis.** Long-lived threads (and autonomous bot DM channels) inevitably approach a model's context limit — or the smaller working budget an operator wants a local model to stay within so generation stays fast. In Nexus, naive context management (sliding windows or per-turn tool-output pruning) would destroy prefix caching on every turn. Instead, Nexus monitors active context occupancy and performs **append-only checkpoint compaction**, generating each summary via **prefix-cache piggybacking** (reusing the exact `nexus/utility` pattern) after a turn settles while the user reads — plus a `/compact [focus]` composer command for manual control.

> Decisions locked in during the 2026-11-28 planning session:
> 1. **Per-bot `context_window`** (optional, frozen onto the thread at creation like `model`/`system_prompt`/`tools`, with a global env fallback) — lets operators cap a bot's context budget below the model's theoretical max for speed/focus, while still letting `/v1/models` act as an optional UI hint.
> 2. **Post-turn background auto-compaction** — local models generate slower as context grows, so hiding compaction latency right after a turn commits (while the KV cache is still hot and the user is reading, cancelled immediately on a new `Send`) beats blocking the next turn.
> 3. **`/compact [focus]` slash command** in the composer — standard UX, supports optional focus instructions naturally, avoids header button clutter, and requires no new HTTP endpoint for the Lustre UI.

---

## 1. Goals and non-goals

**Goals:**
- Measure and display each thread's active context occupancy (`prompt_tokens + completion_tokens` from server `usage`, with a self-calibrating char fallback when a backend omits `usage`).
- Allow per-bot (frozen per-thread) context budgets (`context_window`), with an optional global default (`NEXUS_DEFAULT_CONTEXT_WINDOW`).
- Compact older turns into a structured rolling summary checkpoint without deleting or mutating `thread_message` rows — preserving full UI scrollback and `persist.gleam`'s append-only `seq` / `message_count` watermark.
- Piggyback the summarization completion on the thread's warm KV cache (exact frozen envelope, prefix-only slice up to the cut point, no second model required).
- Trigger compaction automatically post-turn when active occupancy crosses threshold, manually via `/compact [focus]`, and reactively as a safety net on context-length overflow errors.

**Non-goals (this plan):**
- Local model tokenizers / NIF bindings (tiktoken, HuggingFace `tokenizer.json`) — server-reported `usage` + calibrated char estimation avoids native deps and chat-template drift.
- Per-turn sliding windows or continuous retroactive tool-output pruning — breaks KV-cache prefix stability on every turn.
- Embeddings / vector RAG over compacted history or tool-output blob offloading to disk.
- Provider-specific compaction endpoints (OpenAI Responses `/compact`, Anthropic server-side compaction) — Nexus stays OpenAI-compatible and self-hosted first.
- New HTTP mutation route (`POST /threads/<id>/compact`) — Lustre dispatches directly through `thread_registry`; `GET /threads/<id>/state` exposes compaction & usage state for debugging/e2e. (An HTTP endpoint can be added later if scripting callers need it.)
- Mid-turn compaction inside `nexus/loop` between tool iterations — deferred to Phase 4 (optional) once the checkpoint primitive is proven.

---

## 2. Current seams & gaps

| Seam | File | Today | Gap for this plan |
|---|---|---|---|
| Usage decoding | `src/nexus/openai.gleam` | Decodes `chunk.usage` (`prompt_tokens`, `completion_tokens`, `cached_tokens`) into `StreamStats.usage` | `glopenai` 1.0 has no `stream_options` field, so `stream_options.include_usage: true` is never sent; many OpenAI/vLLM servers omit `usage` on streams without it |
| Model metadata | `src/nexus/openai.gleam` (`list_models`) | Extracts only `id`/`alias` | Doesn't extract optional context-length hints (`max_model_len`, `context_length`, `meta.n_ctx_train`) |
| Loop stats | `src/nexus/loop.gleam` (`fold_stats`) | Keeps the latest iteration's `usage` (already the right context-size signal for multi-round turns) | None — works as-is; `StreamStopped` / `StreamGuard` currently drop `stats.usage` in `thread.finish_outcome` |
| Thread metrics | `src/nexus/thread.gleam` (`MetricSample`) | In-memory only, lost on restart, ignored in `ui.gleam` (`Hello(model, _messages, _metrics)`) | Need persistent `last_context_tokens` (or active-window estimate on hydration) + UI meter |
| Request encoding | `src/nexus/transcript.gleam` | Single byte-stable encode path (`to_request` / `request_body`) | Currently encodes all messages unconditionally; needs active-window projection past the latest compaction checkpoint + `stream_options` emission |
| Background side-call | `src/nexus/utility.gleam`, `src/nexus/thread.gleam` | Debounced post-turn cache-piggybacked worker, cancelled on `Send`, never causes `Busy` | Reusable pattern for post-turn auto-compaction; need serialization so utility and compaction never contend on single-slot (`-np 1`) backends |
| Persistence | `src/nexus/store/persist.gleam` | Ordered mailbox (`Commit` fire-and-forget), `persisted` watermark = `thread.message_count` | Add `thread_compaction` table + `RecordCompaction` message in the same ordered actor mailbox |
| Bot templates | `src/nexus/bot.gleam`, `src/nexus/ui_settings.gleam` | Freezes `provider_id`, `model`, `system_prompt`, `tools` onto `thread` at create | Add optional `context_window: Option(Int)` on `bot` and `thread` |

---

## 3. Architecture & KV-cache contract

### 3.1 How compaction interacts with prefix caching

Between compactions, every turn stays **100% append-only and byte-identical** — zero prefix invalidation.

When a compaction runs on a thread with active messages `[system, m1..m50, m51..m55]` where `m51..m55` is the kept recent tail:

1. **Summarization call (cache-piggybacked):**
   Send `[system, m1..m50, compaction_instruction]` using the thread's exact frozen envelope (`loop.frozen_options(specs)`) with only one generation-side delta: `max_completion_tokens`.
   - `system + m1..m50` is a **strict prefix** of the previously cached `system + m1..m55`, enabling **best-effort** prefix reuse when the prefix is still resident:
     - **vLLM / SGLang / Hosted OpenAI:** reuses the shared token prefix when resident; actual hit length depends on backend granularity (e.g. vLLM full block boundaries), cache eviction, and TTL.
     - **llama.cpp / Ollama:** truncates only `m51..m55` from the matching slot and reuses the shared `system + m1..m50` prefix when still resident (subject to slot selection / `keep_alive`).
   - Reuse is verified via `usage.prompt_tokens_details.cached_tokens` (or backend metrics), never assumed.
   - Because `m51..m55` are excluded from the summary request, the model summarizes only what is actually being dropped and cannot contradict or duplicate the kept tail.
   - No second model is needed.
2. **Checkpoint install:**
   The active request window becomes:
   ```
   [system, checkpoint_user_msg(summary, roster?), checkpoint_ack_assistant_msg, m51..m55]
   ```
3. **Next turn:**
   Pays **one** small cold prefill of the compacted window (typically 10–25% of the old context), after which every subsequent turn is again **100% append-only and prefix-cached** until the next compaction.

### 3.2 Strict role alternation (local chat-template safety)

Many OpenAI-compatible Jinja chat templates (Mistral, Gemma, several llama.cpp GGUF templates) reject consecutive `user` messages with HTTP 400. Because `cutoff_index` always lands on a `user` turn (or the end of the transcript), emitting a single synthetic `user` summary followed directly by `m51` (`user`) would violate role alternation.

To guarantee strict alternation on every backend, **both** the post-compaction window and the summarization call itself must alternate cleanly:

- **Summarization request (`[system, m1..m(cutoff-1), compaction_instruction]`):** `pick_cutoff` must ALSO require the last summarized message (`cutoff_index - 1`) to be `assistant`- or `tool`-role — never `user`-role. Without this check, cutting right after an env roster line (which is stored as a `user` row with `author = "system"`) or after a user message retained from an errored turn would append the `user`-role compaction instruction directly after a `user` message and 400 on the very templates this section protects.
- **Post-compaction active window:** the compaction boundary projects as a **fixed user/assistant pair**:

1. `user`:
   ```
   [Earlier conversation compacted]

   <summary>
   ```
   *(If the thread is env-capable and the newest roster line was cut, append the current live roster line — e.g. `[attached targets: workspace, laptop]` — inside this block so the model never loses track of attached targets.)*
2. `assistant`:
   ```
   Understood. I will continue using the compacted context above.
   ```
3. `...messages[cutoff_index..]` (starting on a `user` message, or empty if compacting to the end).

Both framing strings are constants in `nexus/transcript.gleam`, so re-encoding after restart/hydration is byte-identical.

### 3.3 `stream_options.include_usage` & golden test impact

- Add `include_usage: Bool` to `transcript.Options` (default `False`; set `True` in `loop.frozen_options(specs)` alongside `stream: True`).
- Emit `"stream_options":{"include_usage":true}` from `transcript.request_body` (the single encode path) and have `openai.stream_with_cancel` use `transcript.request_body` directly for the HTTP request body rather than letting `glopenai`'s `chat.create_request` re-encode without `stream_options`.
- **Golden test note (`test/m3_prefix_test.gleam`):** `body_parts` splits on the literal `,"stream"` (closing quote included). Because `,"stream_options"` has an underscore rather than a closing quote after `stream`, adding `stream_options` does **not** double-match and requires no delimiter change — just re-run `m3_prefix_test` plus a live Bifrost/llama.cpp check in Phase 1 to confirm the envelope delta stays suffix-only and accepted.

---

## 4. Schema (`sql/migrations/000N_context_compaction.sql`)

Uses the next available 4-digit migration number at implementation time. Follows `AGENTS.md` naming rules (singular tables, `<parent>_<role>`, unquoted-safe identifiers, `timestamptz`, plain `text` for request bytes).

```sql
ALTER TABLE bot
  ADD COLUMN context_window int CHECK (context_window IS NULL OR context_window >= 4096);

ALTER TABLE thread
  ADD COLUMN context_window      int CHECK (context_window IS NULL OR context_window >= 4096),
  ADD COLUMN last_context_tokens int CHECK (last_context_tokens IS NULL OR last_context_tokens >= 0);

-- Append-only compaction checkpoints. `thread_message` rows are NEVER deleted
-- or mutated; hydration loads messages plus checkpoints and `nexus/transcript`
-- projects the active request window from the latest checkpoint's `cutoff_index`.
CREATE TABLE thread_compaction (
  id               bigserial PRIMARY KEY,
  thread_id        text NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
  cutoff_index     int NOT NULL CHECK (cutoff_index > 0), -- chronological Transcript index (first message KEPT verbatim; 0 = system prompt)
  summary          text NOT NULL,                         -- verbatim model summary text (never mutated — KV-cache contract)
  roster_snapshot  text,                                  -- frozen roster line re-injected at the boundary on env threads (NULL on plain threads)
  focus            text,                                  -- optional user /compact instructions (display-only)
  trigger_kind     text NOT NULL CHECK (trigger_kind IN ('auto', 'manual', 'overflow')),
  before_tokens    int,                                   -- observed/estimated active tokens before compaction
  after_tokens     int,                                   -- estimated active tokens after compaction
  created_at       timestamptz NOT NULL
);

CREATE INDEX thread_compaction_thread ON thread_compaction (thread_id, id DESC);
```

Notes:
- Column name is `trigger_kind` (not `trigger`, avoiding the Postgres keyword).
- `cutoff_index` addresses the exact same 0-based chronological `Transcript` message space as `reasoning` / `timestamps` / `origins` (0 = system prompt, 1 = first message).
- `roster_snapshot` is frozen into the checkpoint row at compaction time — not re-derived from live config/nodes on hydration — so a restarted thread re-encodes the post-compaction prefix byte-identically even if a remote node later detached.
- `thread_message` is untouched: `seq`, `on conflict (thread_id, seq) do nothing`, `thread.message_count`, and full UI scrollback all stay intact.

---

## 5. Domain design

### 5.1 Usage tracking & occupancy estimation

Track a lightweight `ContextUsage` struct on the `thread` actor (display + trigger state, never encoded into requests):

```gleam
pub type TokenSource {
  /// Derived from server-reported `usage.prompt_tokens + completion_tokens`.
  Measured
  /// Estimated from active request bytes (calibrated if any measured sample was seen).
  Estimated
}

pub type ContextUsage {
  ContextUsage(
    /// Current estimated/measured active context size in tokens.
    tokens: Int,
    source: TokenSource,
    /// Configured budget frozen on the thread (`None` = unconfigured).
    context_window: Option(Int),
    /// Last turn's prompt_tokens and cached_tokens (for cache-hit tooltip).
    last_prompt_tokens: Option(Int),
    last_cached_tokens: Option(Int),
    /// Learned bytes-per-token ratio (default 4.0, updated whenever server
    /// reports `prompt_tokens` alongside the known active request byte size).
    bytes_per_token: Float,
  )
}
```

Rules:
- **After a committed turn** with server `usage`:
  - `active_tokens = usage.prompt_tokens + usage.completion_tokens` (exact occupancy before the next user message; note: for `StreamDone` / `StreamStopped` / `StreamGuard`, thread `stats.usage` through `finish_outcome` so stopped/guarded multi-round turns don't throw away their last iteration's usage!).
  - Update `bytes_per_token` (clamped to `2.0..6.0`) from the request's active character/byte length divided by `usage.prompt_tokens`, so subsequent estimates (e.g. immediately after compaction or while a backend drops usage) are accurate for the specific model's tokenizer.
- **When server `usage` is absent** (or on hydration before the next turn):
  - Estimate from the active request window's message bytes + frozen tool schema bytes divided by `bytes_per_token` (or seed from persisted `thread.last_context_tokens` on hydration).
- **After compaction installs:**
  - Recompute `tokens` as `Estimated` from the newly compacted active window using the calibrated `bytes_per_token`, and persist `last_context_tokens`.

### 5.2 Thresholds & safe cut-point selection (`nexus/compaction.gleam`)

Pure module (mirrors `nexus/utility.gleam` — zero actor imports, fully offline-testable):

**Config knobs (`src/nexus/config.gleam`):**
- `NEXUS_DEFAULT_CONTEXT_WINDOW` (optional int, min `4096`, default `None`) — fallback when a bot leaves `context_window` unset.
- `NEXUS_COMPACTION_ENABLED` (bool, default `True`) — master switch for **auto**-compaction (manual `/compact` remains available).
- `NEXUS_COMPACTION_THRESHOLD_PCT` (int, `50..95`, default `80`) — percentage of `context_window` that triggers post-turn auto-compaction.
- `NEXUS_COMPACTION_KEEP_TAIL_PCT` (int, `0..40`, default `20`) — target share of `context_window` to keep verbatim after the cut point.
- `NEXUS_COMPACTION_DELAY_MS` (int, `>= 0`, default `1500`) — post-turn debounce before spawning the auto-compaction worker.
- `NEXUS_COMPACTION_MAX_TOKENS` (int, min `512`, default `4096`) — `max_completion_tokens` for the summarization call (generous headroom for reasoning models' chain-of-thought, same lesson as `utility_token_cap`).

**Auto-trigger condition:**
Given `context_window = Some(limit)`:
```
summary_max_tokens   = min(cfg.compaction_max_tokens, max(512, limit / 4))
instruction_headroom = 512   // base compaction prompt + framing + capped focus
reserve              = summary_max_tokens + instruction_headroom
trigger_at           = min(limit * cfg.compaction_threshold_pct / 100, limit - reserve)
should_auto_compact  = reserve < limit && trigger_at > 0 && usage.tokens >= trigger_at
```
Bounding `summary_max_tokens` to at most `limit / 4` (with a 512-token floor) and basing `reserve` directly on `summary_max_tokens + instruction_headroom` ensures the piggybacked summarization prompt and its `max_completion_tokens` always fit inside `limit` — even at the minimum `4096`-token window (`summary_max_tokens = 1024`, `reserve = 1536`, `trigger_at = 2560`). When `reserve >= limit` (impossible under the `4096` floor, defensive guard), auto-compaction stays disabled rather than firing a request that cannot fit.

*Known behavior when `context_window` is `None`:* if neither the bot nor `NEXUS_DEFAULT_CONTEXT_WINDOW` sets a budget, auto-compaction never arms — those threads rely on manual `/compact` and Phase 3's reactive overflow recovery. Live `/v1/models` context-length hints from Phase 1 remain non-binding UI aids and never feed this trigger.

**Safe cut-point picker (`pick_cutoff`):**
Given the active message slice `[start_index .. total_len)` and a `keep_tail_tokens` budget (e.g. `min(16_000, max(2_000, limit * keep_tail_pct / 100))`, or `4_000` for manual `/compact` when `context_window` is `None`):
1. Identify all **valid boundary indices** strictly inside `(start_index, total_len]`:
   - **Left side (summarized tail):** `messages[i - 1]` MUST be `AssistantMessage` or `ToolMessage` (never `UserMessage`, including env roster lines and user messages retained from failed turns) so appending the `user`-role compaction instruction stays strictly alternating.
   - **Right side (kept head):** `i == total_len` (compact everything) OR `messages[i]` is a `UserMessage` whose `origin_at(tr, i)` is NOT `Some(Origin("system", _))` (guaranteed outside any `assistant(tool_calls) → tool` pair and never stranding a roster line at the head).
   - Never land on an `AssistantMessage` or `ToolMessage`.
2. Walk backward from `total_len`, accumulating estimated tokens of kept turns, and pick the earliest valid boundary whose tail fits within `keep_tail_tokens` — subject to **actually freeing meaningful context** (at least 1 complete exchange before `cutoff_index`, and if the single newest turn alone exceeds `50%` of `limit`, allow the highest valid boundary up to `total_len` so compaction can still make progress).
3. If no valid cutoff exists past the current compaction start (e.g. a brand-new thread with 0–1 turns, or only trailing user messages with no committed assistant reply yet), refuse cleanly (`NothingToCompact`).

### 5.3 Summarization prompt & runner (`nexus/compaction.gleam`)

- **`prepare(tr, cutoff_index, focus)`**:
  Builds a throwaway transcript containing only the **active prefix up to `cutoff_index`** (`transcript.slice_active(tr, cutoff_index)`) — preserving exact prefix bytes for KV-cache reuse — and appends one `user` instruction message:
  - Explicitly forbids tool calls (`Do not call any tools.`), matching `utility.gleam`, because the frozen `tools` array stays in the envelope.
  - Requests a concise, factual, structured handoff with fixed headings:
    - **Goal & Constraints**
    - **Decisions & Completed Work**
    - **Current State & Key Details** (file paths, commands, symbols, identifiers, URLs, error outputs still relevant)
    - **Open Questions & Next Steps**
  - When a prior compaction already sits at the start of the active prefix, explicitly instructs the model to **merge and update** the earlier summary rather than nesting summaries.
  - When `focus` is `Some(note)` (from `/compact <note>`), validate length **before** starting compaction (`max_focus_chars = 1000`, ~250 tokens — fits safely inside the 512-token `instruction_headroom`; reject longer notes loudly with `FocusTooLong`), then append `"Preserve detail especially regarding: " <> note`.
- **`options(base, context_window)`**:
  `transcript.Options(..base, max_completion_tokens: Some(summary_max_tokens))` where `base` is `loop.frozen_options(specs)` and `summary_max_tokens = case context_window { Some(limit) -> min(cfg.compaction_max_tokens, max(512, limit / 4)), None -> cfg.compaction_max_tokens }`.
- **`run(...)`**:
  Same blocking single-stream runner shape as `utility.run`:
  - Accumulates `TokenDelta`s (ignoring `ReasoningDelta` so CoT never leaks into the stored summary!).
  - Fails on any `ToolCallDelta`, cancellation, transport error, or blank/too-short summary.
  - Strips wrapping outer markdown fences if the model fenced the whole summary.
  - Bounds stored summary size against the thread's token budget (not just a global character cap): cap to at most `summary_max_tokens` (converted via the thread's calibrated `bytes_per_token`, with a defensive `32_000`-char global ceiling when `context_window` is `None`), and fail an `AutoCompact`/`OverflowCompact` attempt whose estimated post-compaction `after_tokens >= before_tokens` so a runaway summary can never leave the active window larger than before.

---

## 6. Thread actor lifecycle & concurrency (`src/nexus/thread.gleam`)

### 6.1 State additions

```gleam
pub type CompactionTrigger {
  AutoCompact
  ManualCompact
  OverflowCompact
}

type CompactionState {
  CompactIdle
  /// Spawned worker awaiting its `CompactStarted(pid, cancel)` handshake
  /// (mirroring `UtilityStarting` / `UtilityStarted`). Cancellation during
  /// `CompactStarting` sets `cancelled: True`, and the handshake handler
  /// immediately signals `cancel` upon arrival so neither manual `Stop` nor
  /// a Send-raced auto-compaction can miss the spawn→handshake window.
  CompactStarting(
    worker: Pid,
    monitor: Monitor,
    trigger: CompactionTrigger,
    cancelled: Bool,
    base_len: Int,
  )
  CompactRunning(
    worker: Pid,
    monitor: Monitor,
    cancel: Subject(Nil),
    trigger: CompactionTrigger,
    cancelled: Bool,
    base_len: Int,
  )
}
```

Additional fields on `thread.State`:
- `compaction: CompactionState`
- `compaction_pending: Bool` — non-blocking owed-trigger flag (mirroring `utility_pending`): set when an auto-compaction trigger fires while `utility` is in flight, and delivered in `finish_utility` once the utility slot clears.
- `compaction_failed_at_len: Option(Int)` — prevents infinite auto-retry loops when a model refuses or fails compaction; clears automatically when the transcript grows (next committed turn) or a manual `/compact` runs.
- `context_window: Option(Int)` — frozen from `ThreadSpec`.
- `usage: ContextUsage` — updated on turn commit, compaction install, and hydration.

### 6.2 Auto vs. Manual rules (avoiding `-np 1` contention and races)

| Scenario | Auto compaction (background) | Manual `/compact` (foreground) |
|---|---|---|
| **When it starts** | Post-turn debounce (`NEXUS_COMPACTION_DELAY_MS`) after `WorkerDone` commits, when `usage.tokens >= trigger_at`, `turn == Idle`, `utility == UtilityIdle` | Immediate on `Compact(focus, reply)` when `turn == Idle` and not an archived channel; cancels any in-flight `utility` or `AutoCompact` first |
| **`Send` arrives mid-compaction** | **Cancels immediately** (`process.send(cancel, Nil)` when `CompactRunning`, or flips `cancelled: True` when `CompactStarting` so `CompactStarted` signals `cancel` on arrival), proceeds with `Send` (never returns `Busy`), re-evaluates after the new turn commits | Returns **`Busy`** — user explicitly asked to compact before continuing |
| **`Stop` button** | Not shown (or no-op; invisible side-call) | Cancels the manual compaction cleanly (including during `CompactStarting` via the deferred-cancel handshake), emits `CompactionFinished(ManualCompact, Some("cancelled"))` / status reset |
| **Utility title/tags interaction** | Never runs concurrently with `utility` and never blocks the actor: if `utility` is active when auto-compaction wants to fire, record `compaction_pending = True` and deliver it in `finish_utility`; symmetrically, if `AutoCompact` is active when `arm_utility` runs, set `utility_pending = True` and re-arm in `finish_compaction` | Cancels `utility` if somehow running (utility's cancelled-does-not-consume rule re-arms it later) |
| **Stale completion guard** | Installs **only** when `turn == Idle && not cancelled && transcript.length(state.transcript) == base_len && state.pending_roster == []`; otherwise discards cleanly (and re-arms if still over threshold) | Installs **only** when `turn == Idle && not cancelled && transcript.length(state.transcript) == base_len`; then immediately drains any `pending_roster` queued during the foreground compact |
| **Roster change arrives mid-compaction** | While `turn == Idle`, a live attach/detach appends its roster row immediately (bumping `transcript.length` past `base_len`, so the stale guard discards and re-arms); requiring `state.pending_roster == []` also prevents installing behind any queued roster change | Queue `pending_roster` behind foreground manual compaction just like behind a turn: `roster_snapshot` freezes the pre-queue `state.roster` at `cutoff_index`, the checkpoint installs at `base_len`, and `drain_pending_roster` immediately appends the queued roster line(s) *after* the compaction checkpoint |

### 6.3 Persistence ordering

On compaction install:
1. Build the `transcript.Compaction(cutoff_index, summary, roster_snapshot, focus, trigger, before_tokens, after_tokens, created_at)` value.
2. Install onto `state.transcript` via `transcript.apply_compaction(state.transcript, checkpoint)` — checkpoints are stored in a **sidecar list beside `messages`**, **never** spliced into `messages`: `store.transcript_delta` maps transcript positions directly to `thread_message.seq` (`base_seq + index`), so splicing synthetic framing rows into `messages` would corrupt `seq`, `thread.message_count`, `persist.gleam`'s watermark, and hydration byte-identity. The synthetic `user`/`assistant` checkpoint pair exists solely inside the `request_messages` / `slice_active` encode-time projections.
3. Persist atomically via `RecordCompaction(thread_id, state.transcript, checkpoint)` on `nexus/store/persist`: inside **one `pog.transaction`**, `persist` idempotently flushes any uncommitted `thread_message` delta rows up to `base_len` (reusing `on conflict (thread_id, seq) do nothing` and advancing `message_count` / `persisted`), inserts the `thread_compaction` row, and updates `thread.last_context_tokens`. Mailbox ordering alone is **not** relied on for durability — if an earlier write-behind `Commit` failed or the process crashes mid-flight, the transaction either commits both the referenced messages and the checkpoint together or rolls back cleanly. Defensively, hydration also validates `cutoff_index <= transcript.length(tr)` and ignores/logs any inconsistent checkpoint.
4. Update `state.usage` (`tokens = after_tokens`, `source = Estimated`).
5. Emit `Compacted(...)` + `UsageUpdated(usage)` events to all subscribed UI tabs.

### 6.4 Reactive overflow recovery (Phase 3)

When a turn fails with `StreamErrored(reason)` matching a known HTTP 400 context-length-exceeded pattern (`context_length_exceeded`, `maximum context length`, `exceeds the available context size`, `too many tokens`, etc.):
- **Matching discipline:** Match **only** HTTP 400 (`non-200 response: 400:`) plus an overflow keyword — never trigger recovery on decode, timeout, or transport errors. Note that `loop.error_string` truncates error bodies to the first 200 characters (`string.slice(body, 0, 200)`), so match against that snippet (or preserve a slightly wider structured error on `StreamErrored`) and log unmatched HTTP 400 reasons via `nexus/log` so operators can extend backend wording coverage without guessing.
- **Guard:** At most **one** automatic overflow recovery per `Send` (tracked on the turn / actor state so it can never loop).
- Because the full active window already overflowed, build the emergency summarization input by **trimming to ~60% of the active window** (truncating oversized tool results first, then oldest messages if needed) and summarizing with `cutoff_index` at the highest valid boundary before the triggering user message (keeping the user's message intact!).
- Once compacted, automatically retry that user message once; if emergency compaction itself fails, surface the original overflow error clearly to the user.

---

## 7. UI & `/compact` command UX

### 7.1 Slash command parsing (`nexus/command.gleam` or `nexus/compaction.gleam`)

Pure parser invoked by `ui.gleam`'s composer submit handler (and reusable by `tui.gleam`):

```gleam
pub type Command {
  Compact(focus: Option(String))
}

pub fn parse(input: String) -> Option(Command)
```

Strict matching rule so normal messages starting with `/` (like `/etc/hosts` or `/var/log/syslog is full`) are **never** swallowed:
- Trim input.
- Match `"/compact"` → `Some(Compact(None))`.
- Match `"/compact " <> rest` (or tab/newline after `"/compact"`) → `Some(Compact(non_empty_trim(rest)))`.
- Anything else → `None` (passes straight through as a normal chat message).

When `Compact(focus)` is parsed in `ui.gleam`:
- Requires an active selected thread (if on compose-new with no thread yet, show a subtle inline notice *"Nothing to compact in a new thread"*).
- Clears the composer input, dispatches `thread_registry.compact(thread_id, focus)` via an effect.
- On `Busy`: shows standard busy notice; on `NothingToCompact`: shows subtle notice (*"Not enough conversation history to compact yet"*); on `FocusTooLong(max)`: shows inline notice (*"Compact instructions must be at most 1,000 characters"*); on `Started`: enters `"Compacting context…"` state with Stop enabled.

### 7.2 Context usage indicator (`src/nexus/ui.gleam`)

- Extend `thread.EventKind`:
  - `Hello(model, messages, metrics, usage, compactions)` (or emit `UsageUpdated(usage)` + `Compacted(...)` during replay in `Join` — keeping `Hello` minimal!).
  - `UsageUpdated(usage: ContextUsage)`
  - `CompactionStarted(trigger: CompactionTrigger)`
  - `Compacted(checkpoint: CompactionSummary)` (replayed at `cutoff_index` on `Join` and emitted live on install)
  - `CompactionFinished(trigger: CompactionTrigger, error: Option(String))` (clears `"Compacting…"` spinner; surfaces error only for `ManualCompact`)
- Render a quiet, single-line pill in the thread header (or right-aligned above the composer):
  - With `context_window`: `42k / 128k (33%)` (prefixed with `~` when `Estimated`, e.g. `~42k / 128k`; subtle warning tint above threshold).
  - Without `context_window`: `42k tok` (or `~42k tok`).
  - `title` tooltip: exact numbers + last turn's cache hit rate when `cached_tokens` is present (`Prompt: 42,180 · Cached: 39,400 (93%)`).
- Render each compaction checkpoint in the chat log at its chronological `cutoff_index` using Pico-native `<details>` / `<summary>` (hostile-text-safe Lustre text nodes, zero custom CSS design system):
  - Summary line: `Context compacted · 98k → 11k tokens` (with `auto` / `manual` label).
  - Expanded body: the verbatim summary text (and focus note if provided), rendered as inert text / existing markdown renderer.

### 7.3 Bot settings (`src/nexus/ui_settings.gleam`, `src/nexus/web.gleam`)

- Add optional `Context window (tokens)` number field to Add/Edit Bot forms (`blank` = default/unset; validated `>= 4096`).
- When live `/v1/models` for the chosen provider returns a context length for the selected model alias, display it as non-binding helper text beside the input (e.g. `Provider reports 131,072 tokens`) — the operator stays in full control and can enter a smaller cap (e.g. `32768`).
- Extend `POST /bots` and `PATCH /bots/<id>` JSON bodies with optional `context_window` (following `BotUpdate`'s blank/null clears to `None`, absent keeps).

---

## 8. Implementation phases

### Phase 1 — Usage monitoring & context budget (no compaction yet)
1. **Transport & encoding:** Add `include_usage` to `transcript.Options`, emit `stream_options: {"include_usage": true}` via `transcript.request_body`, route `openai.stream_with_cancel` through it, re-run `m3_prefix_test`, and verify live against Bifrost/llama.cpp.
2. **Model hint (best-effort):** Extend `openai.list_models` (or a sibling helper) to optionally parse `max_model_len` / `context_length` / `meta.n_ctx_train` when present.
3. **Schema & bot/thread config:** Migration adding `bot.context_window`, `thread.context_window`, `thread.last_context_tokens` + `NEXUS_DEFAULT_CONTEXT_WINDOW` in `config.gleam`; thread through `bot`, `store`, `thread_registry`, `web`, and `ui_settings`.
4. **Actor tracking & UI pill:** Track `ContextUsage` (including `StreamStopped` / `StreamGuard` usage + calibrated char fallback), persist `last_context_tokens`, expose in `GET /threads/<id>/state`, and render the usage pill in `ui.gleam`.
5. **Tests:** Offline unit tests for `stream_options` encoding, prefix stability (`m3_prefix_test`), calibrated estimator, bot validation/freeze, and UI usage rendering.

### Phase 2 — Checkpoint schema, `Transcript` projection & manual `/compact`
1. **Schema & store:** Add `thread_compaction` table (can land in the same migration if Phase 1 & 2 ship together, or as the next sequential migration), `insert_compaction.sql`, `load_compactions.sql`, `RecordCompaction` in `store/persist.gleam`, and hydration loading in `thread_registry.gleam`.
2. **`Transcript` active-window projection:** Add compaction checkpoints to `Transcript`, `request_messages` (with strict `user`/`assistant` pair + frozen `roster_snapshot`), `slice_active(tr, cutoff_index)`, and golden byte-stability tests across hydration/restart!
3. **Pure compaction module (`src/nexus/compaction.gleam`):** Cut-point picker (respecting tool-call boundaries), structured prompt (initial + incremental merge + optional `focus`), cache-piggybacked `run`, and `/compact` command parser.
4. **Thread actor & UI:** Foreground `Compact(focus, reply)` path (with Stop cancellation, `Busy` while running, `pending_roster` queueing), `/compact [focus]` handling in `ui.gleam` (and `tui.gleam` if desired), `<details>` compaction divider on live + replay.
5. **Tests:** Offline tests for cut-point safety (tool rounds, roster lines, short threads), strict role alternation, KV-cache prefix reuse proof for `slice_active` + instruction, hydration byte-equality, Stop cancellation, and UI replay/divider rendering.

### Phase 3 — Post-turn auto-compaction & overflow recovery
1. **Post-turn auto-compaction:** Debounced background trigger after `WorkerDone` commits when `usage.tokens >= trigger_at`, serialized with `utility`, cancelled immediately on `Send` (never `Busy`), stale-completion guard, failure backoff (`compaction_failed_at_len`).
2. **Reactive overflow recovery:** Detect context-length-exceeded HTTP 400s in `thread.gleam`, run trimmed emergency compaction (1 retry cap), and retry the turn once.
3. **Bot channels check:** Verify long-lived DM channels (`parent_thread_id`) auto-compact cleanly without interfering with `bot_message` delivery.
4. **Tests & e2e:** Offline race tests (Send cancels auto-compaction, utility/compaction serialization, stale `CompactDone` dropped, failure backoff, overflow single-retry), plus Playwright e2e test for `/compact` + reload persistence.

### Phase 4 (Optional, later) — Mid-turn compaction
- If marathon tool loops (`NEXUS_MAX_TOOL_ITERATIONS = 32`) routinely blow context inside a single user turn, allow `loop.gleam` to invoke a checkpoint compaction between tool iterations and mirror the checkpoint event into `turn_view`.

---

## 9. Verification checklist (when implementing)

- `gleam test` passes completely offline (no network, no live Postgres).
- `test/m3_prefix_test.gleam` passes: normal turns remain suffix-only byte-identical; `slice_active` + compaction instruction shares exact prefix bytes with the last turn's request; post-compaction hydrated requests re-encode byte-identically across restarts.
- `gleam run -m nexus/store/migrate` and `gleam run -m squirrel check` pass cleanly against local Postgres.
- Live check against local Bifrost / llama.cpp confirming `stream_options: {"include_usage": true}` is accepted and returns `prompt_tokens` / `cached_tokens`, and that a post-turn compaction call achieves a KV-cache hit on the summarized prefix.
- E2e browser test covering usage indicator update, `/compact <focus>`, `<details>` divider rendering, and page-reload fidelity (matching `GET /threads/<id>/state`).
