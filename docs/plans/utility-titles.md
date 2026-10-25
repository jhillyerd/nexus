---
title: Nexus — model-generated session titles via prefix-cache piggybacking
status: draft
tags: [nexus, titles, kv-cache, utility]
updated: 2026-10-25
---

# Nexus: model-generated session titles via prefix-cache piggybacking

Design for upgrading the instant first-message heuristic title into a
model-generated title after the first committed exchange — using a
single background completion that **branches off the session's cached
prefix**, so it costs ~the utility prompt + reply tokens on
cache-capable backends and needs **no second model**.

> Decisions from the 2026-10-24 planning session: titles only this pass
> (tags designed in §7, implemented later, merge policy); trigger once
> per session after the first committed exchange; offline-only
> verification this pass. Serving facts live in the
> `.agents/skills/llm-api` skill; this doc cites them, it does not
> re-derive them.
>
> Decision from the 2026-10-25 session (landed): **PASS postpone**. The
> first exchange often gives the model too little to title specifically
> (a greeting-only opener), so the model may reply exactly PASS and the
> attempt re-arms at the next turn-commit point. Exactly ONE pass is
> honored per session, then attempts run under a forced instruction with
> no PASS option, so every session converges. Retrying is cheap here by
> construction: the re-armed attempt reuses the still-warm cached prefix
> (~Y + title tokens again), and cancel-on-send + debounce already bound
> the latency harm on serialized backends.

## 1. Goal and non-goals

**Goal.** After a session's first committed assistant turn, ask the
session's own model — through the same endpoint, same envelope, same
encode path — for a concise title, appended to the committed transcript
as a user instruction. The reply is applied as the session title while
`title_source = 'auto'`; a manual rename still wins forever. On vLLM /
llama.cpp / Ollama / SGLang the request reuses the conversation's KV
prefix, so the incremental cost is the instruction + ~30–60 reply
tokens.

**Non-goals (this plan).**

- Auto-tagging (§7 designs it; vocabulary-growth controls must land
  with it). The utility instruction asks for a title only.
- An alternate "utility model" or per-provider model override (a
  different model means a different tokenizer — zero prefix share by
  construction, which is the whole point of not needing one).
- Periodic re-titling / topic-drift detection; e2e cache-branch
  verification (deferred to §9 P5); multi-user anything.

## 2. Why piggybacking works (summary)

Send prompt X, receive A → the backend caches the `X+A` prefix. While
the user reads, send **X+A+Y** (Y = title instruction): the backend
reuses `X+A` and processes only Y (+ generates B ≈ a title). **Y+B is
never committed.** The user's next message is sent as **X+A+Z**, which
branches back off the same cached `X+A` span; the dead `Y+B` branch is
an ordinary eviction candidate, and touching `X+A` during the utility
call refreshes its recency. Mechanics per backend: vLLM chained
full-block hashing, SGLang radix tree, llama.cpp/Ollama
truncate-to-longest-common-prefix — see `.agents/skills/llm-api`.

Prior art does the opposite of this plan: Open WebUI task models,
Claude Code's Haiku background model (`SESSION_TITLE_PROMPT`, JSON
`{"title": ...}`, 3–7 words), and LibreChat `titleModel` all run a
**separate model with a standalone short prompt** — which assumes a
second (cheap) model can be loaded. Single-model self-hosters can't;
piggybacking gets the model *the whole session as context* for ~Y+B
tokens instead.

## 3. Current state (seams this builds on)

| Seam | File | Today |
|---|---|---|
| Heuristic title | `src/nexus/web.gleam` ~L466–487, `src/nexus/ui.gleam` ~L1361–1377 | first user message at both send boundaries via `session_registry.auto_title` + `title_from_first_message` (whitespace-collapsed, length-capped) |
| Title semantics | `src/nexus/session_registry.gleam` AutoTitle handler ~L623; `src/nexus/store/sql/auto_title.sql` | guard `title_source='auto' AND title=''` — applies only while the auto title is untouched; `SetTitle` marks `ManualTitle` and wins forever |
| Tags | `set_tags.sql`, registry `SetTags` | manual only, normalized (`normalize_tags`) |
| Frozen envelope | `src/nexus/loop.gleam` ~L146–150 | `Options(stream: True, tools: tools.default(cfg) \|> schemas, tool_choice: auto)` built at boot |
| Encode path | `src/nexus/transcript.gleam` | `to_request` / `request_body` — single, byte-stable |
| Transport | `src/nexus/openai.gleam` | `stream_with_cancel` — cancellable SSE, takes the session's frozen `Endpoint` |
| Turn lifecycle | `src/nexus/session.gleam` | turn worker `spawn_unlinked` ~L470; `commit_hook(tr)` at the two commit points (~L484 user-message commit, ~L677 turn commit); `SessionEvent` broadcast to subscribers |
| Session events → UI | `src/nexus/ui.gleam` `from_session_event` ~L338; `TurnDone` refresh ~L786 | no metadata-changed event; only the *acting* client refreshes after a metadata mutation (~L1461) |
| Config | `src/nexus/config.gleam` | env-driven `NEXUS_*`, validated up front |

## 4. Design

### 4.1 New module `src/nexus/utility.gleam`

Pure request/parse helpers plus one runner — no actor of its own:

- `instruction(allow_pass) -> String` — the appended user message Y, in
  two variants. Both share the base wording and the tool prohibition
  ("Do not call any tools. Reply with the title only."). The allowed
  variant adds: *"If the conversation so far does not yet give you
  enough to write a specific title, reply with exactly PASS instead."*
  The forced variant adds: *"Even if the conversation is still slight,
  reply with the best title you can — do not defer."* — and must not
  mention the sentinel at all, so a model that never saw the option
  cannot be steered into it. Tool use is forbidden in the prompt
  because the frozen `tools` array renders into the prompt and cannot
  be stripped without diverging the prefix.
- `prepare(tr) -> Transcript` — `transcript.append_user(tr, instruction())`.
- `options(base) -> Options` — the loop's Options with exactly one
  delta: `max_completion_tokens: Some(64)`. Generation-side params do
  not affect the tokenized prompt (llm-api skill §3.3), so the prefix
  is untouched; the cap bounds cost and rambling.
- `parse(allow_pass, text) -> Result(Verdict, Nil)` — trim, strip
  Markdown code fences, collapse whitespace, and cap length with the
  same rule as `title_from_first_message`; reject empty (a refusal
  arrives as no content, so it fails here too). `Verdict` is
  `Title(String) | Pass`: the PASS sentinel matches only a WHOLE shaped
  reply, case-insensitively — a real title that merely contains the
  word ("Password Manager Setup") never postpones. Under the forced
  instruction a PASS reply is rejected as an unusable title (a
  failure), not a postpone — the session must converge. (Title text is
  display data: the UI renders it as a Lustre text node, so hostile
  output is inert by the existing no-`innerHTML` contract.)
- `run(endpoint, tr, base_opts, cancel) -> Result(String, String)` —
  one non-loop stream via `openai.stream_with_cancel`, accumulating
  text deltas; any assembled tool call, or a refusal, is a failure and
  the result is discarded (best-effort: no retry in this pass).

### 4.2 Session actor (`src/nexus/session.gleam`)

- `SessionSpec` gains an injected **`utility_runner`** seam (mirrors
  `TurnRunner`; the registry constructs the real one at boot, tests
  inject fakes — dependency direction stays registry → session). To
  guarantee byte-identical envelopes by construction, **extract the
  Options construction from `loop.gleam` (~L146–150) into one shared
  `fn`** consumed by both the agent loop and the utility runner.
- New messages: `UtilityStart` (debounce fired, spawn the worker) and
  `UtilityDone(pid, result)`. State gains `utility: UtilityState`
  (`Idle | Running(pid, cancel_subject)`), a once-per-session
  `utility_attempted: Bool` that flips **only when an attempt
  completes** (applied or failed) — never when one is armed or
  cancelled — and `utility_passes: Int`, the PASS replies honored so
  far (`max_utility_passes = 1`, a const: an uncapped pass-forever
  policy would re-arm a side call after every turn of a perpetual
  small-talk session and never converge). The runner receives
  `allow_pass = utility_passes < max_utility_passes`.
- **Trigger.** At the turn-commit point (~L677), when the turn
  committed, `transcript.length(tr) >= 3` (system + first user + first
  assistant), the once-flag is unset, and config enables the feature →
  arm a debounce timer (`NEXUS_UTILITY_DELAY_MS`, default 1500). When
  it fires and no turn is running, spawn an **unlinked** utility worker
  (mirror of the turn worker at ~L470) holding the committed
  transcript snapshot and a cancel subject. Failed turns (`StreamErrored`,
  nothing committed) never trigger it. A worker cancelled by an
  incoming `Send` does **not** count as an attempt: `utility_attempted`
  stays unset and the next turn-commit point re-arms the debounce, so
  a fast follow-up can kill at most the in-flight try, never the
  session's only one — the heuristic title is always eventually
  upgraded (or replaced by a manual rename).
- **PASS postpone.** A completed attempt reporting PASS (`UtilityPassed`)
  consumes nothing: the once-flag stays unset and the next turn-commit
  point re-arms the debounce, with the forced instruction because
  `utility_passes` has incremented. A PASS that raced a `Send`
  (cancelled mark) delivers any owed trigger immediately, like a
  cancelled failure. A PASS under the forced instruction is an unusable
  title: the worker maps it to `UtilityFailed`, so it consumes the
  attempt like any failure — no runner can smuggle an endless postpone
  past the actor boundary.
- **Cancellation.** A `Send` arriving while a utility worker runs
  sends its cancel subject and proceeds normally — the session never
  reports `Busy` because of a utility call. This is required fairness
  on serialized backends (llama.cpp `-np 1`: the side call would
  otherwise queue the user's turn behind it).
- **Result path.** The *worker* (not the actor) applies the title
  through the registry ask-pattern `UpgradeAutoTitle` (below) — keeping
  the actor non-blocking — then sends `UtilityDone(applied)`; the actor
  broadcasts the new `SessionEvent.MetaUpdated(title: Option(String),
  tags: List(String))` to subscribers only when something applied.
- The utility transcript is a throwaway snapshot: like the reasoning
  sidecar, Y and B are **structurally unable to change a request byte**
  — they never enter the session's transcript.

### 4.3 Registry (`src/nexus/session_registry.gleam`)

New public message `UpgradeAutoTitle(id, title, reply: Subject(Bool))`
— same shape as the existing `AutoTitle` handler, but the guard is
**`title_source = 'auto'` only**: the model title may replace the
heuristic placeholder, while a manual rename still wins forever. Both
the in-memory record update and the store write-through carry the same
guard (the twin-invariant pattern the existing `AutoTitle`/`auto_title.sql`
pair already uses). The heuristic title stays as the instant
placeholder; the model title upgrades it shortly after.

### 4.4 Store

- New squirrel query `src/nexus/store/sql/auto_title_upgrade.sql`:
  `update session set title = $1 where id = $2 and title_source = 'auto'`.
- Seam field in `src/nexus/store.gleam`, implementation in
  `src/nexus/store/persist.gleam`, mock in `test/store_mock.gleam`;
  regenerate with `gleam run -m squirrel` (committed `sql.gleam`;
  CI's `squirrel check` gates drift).
- **No schema change**: `title` / `title_source` already exist.

### 4.5 UI (`src/nexus/ui.gleam`)

`from_session_event` maps `MetaUpdated` to a session-list refresh (the
same `sessions_effect` path `TurnDone` uses, ~L786), so **every**
connected tab's sidebar updates — today only the client that performed
a metadata mutation refreshes (~L1461). Titles render as text nodes;
add a `<script>`-payload regression test to keep that pinned.

### 4.6 Config (`src/nexus/config.gleam`)

`NEXUS_UTILITY_ENABLED` (default `true`) and
`NEXUS_UTILITY_DELAY_MS` (default `1500`), validated up front like the
other `NEXUS_*` fields.

### 4.7 Sequence

```mermaid
sequenceDiagram
  participant U as User
  participant S as session actor
  participant W as utility worker (unlinked)
  participant P as provider (vLLM / llama.cpp / …)
  U->>S: first message
  S->>P: turn 1 request X (+ stream) → reply A
  Note over S: commit X+A (cache warm), count ≥ 3 → arm debounce
  S->>W: timer fires, idle → spawn(snapshot X+A, cancel)
  W->>P: request X+A+Y (same envelope + max_completion_tokens cap)
  P-->>W: B (title); cache keeps X+A (touched) + dead Y+B
  W->>S: UtilityDone(applied)
  Note over W: applied via registry UpgradeAutoTitle (guard title_source='auto')
  S->>U: broadcast MetaUpdated → all sidebars refresh
  U->>S: next message Z (cancels W if still running)
  S->>P: request X+A+Z (branches off cached X+A)
```

## 5. Why the cache contract is preserved

- The utility request is built by the **same** `nexus/transcript`
  encoder from the committed transcript with the **same** envelope —
  the shared-frozen-Options invariant (`loop.gleam`) is reused, not
  re-implemented. Its token stream is the conversation's prefix plus a
  tail message; nothing above the tail changes.
- `max_completion_tokens` is the only Options delta and is
  generation-side only (does not tokenize into the prompt).
- The branch reply never enters the transcript, so conversation
  re-encoding stays byte-identical turn over turn —
  `test/m3_prefix_test.gleam` keeps guarding it unchanged.
- The session's endpoint is the frozen per-session `Endpoint`
  (multi-provider plan §8): the utility call routes to the exact same
  backend as every turn, by construction.

## 6. Verification (offline only this pass)

`gleam test` stays offline/network-free (AGENTS.md); the mockable seams
carry everything.

- **`test/utility_test.gleam`** (new):
  - *Prefix property*: replay a turn of `test/fixtures/m3_cache_session.json`
    through the transcript path; assert `request_body(conv)` vs
    `request_body(conv + Y)` differ by messages-suffix-only with a
    byte-identical envelope after the `,"stream"` marker — reusing the
    `body_parts`/`extends` helpers from `test/m3_prefix_test.gleam`
    (extract or duplicate them there) — and that the envelope's only
    Options delta is `max_completion_tokens`.
  - *Parser*: code-fenced output, multi-line, leading prose,
    `<script>` payloads (must pass through inert + capped), empty,
    refusal; PASS sentinel (bare / padded / fenced, case-insensitive),
    whole-string matching ("Password Manager Setup" and "PASS." are
    titles, not passes), and forced-instruction rejection.
  - *Instruction*: Y forbids tool calls (both variants); Y is a single
    user message; only the allowed variant mentions PASS.
- **`test/session_test.gleam`** (extend, fake `utility_runner`): fires
  once after the first committed exchange; not on failed turns; never
  marks the session `Busy`; cancelled when a `Send` arrives
  mid-flight, and a cancelled attempt does not consume the once-flag
  (it re-arms at the next commit point); `MetaUpdated` broadcast only
  when the registry guard applied; PASS postpone — a PASS consumes
  nothing and the re-armed attempt arrives forced, its title applies,
  and only then is the flag spent; a PASS under the forced attempt
  consumes the attempt (no third try).
- **`test/session_persistence_test.gleam`** + `test/store_mock.gleam`:
  `auto_title_upgrade` guard semantics (auto → applies and replaces
  the heuristic; manual → refused, reply `False`).
- **`test/ui_test.gleam`**: `MetaUpdated` → sidebar refresh; hostile
  title rendered inert.
- **`test/m3_prefix_test.gleam`** stays green, untouched.

Live/e2e verification (deferred, §9 P5): extend `e2e/integration.spec.mjs`
cache gate with the branch scenario — utility request ≈ near-full
`cached_tokens` hit; the post-branch user turn still hits the
pre-utility prefix.

## 7. Deferred: tags (design now, implement later)

Policy (planning decision): **merge** — model tags are unioned into
manual tags, so manual tags are never clobbered. Provenance is
required; sketch: keep `tags text[]` as the display set and add
`tags_manual text[]` (manual = the user's exact set; auto = display
minus manual, recomputed on write) rather than per-tag sources. New
queries in the `merge_auto_tags` family. Exact shape stays open.

**Vocabulary-growth controls** (the reason tags are deferred — an
unconstrained tagger explodes the global vocabulary):

1. *Corpus-constrained generation*: the utility instruction includes
   the existing global tag corpus (from `select distinct unnest(tags)`
   with a frequency floor) and allows at most K new tags per run —
   reuse dominates, growth is bounded per session.
2. *Normalization + caps*: lowercase, trim, no internal whitespace
   (extend `normalize_tags`); ≤ 5 tags per session.
3. *Prune sweep* (later): a boot-time `bump_activity`-style sweep
   drops tags used by fewer than N sessions.

Recommended: (1) + (2) with the tags pass, (3) only if the corpus
still drifts. When implemented, tags ride the **same** utility call as
titles (one Y producing JSON `{"title": ...}`) — one branch, one
request; until then Y stays title-only.

## 8. Risks and open questions

- **Model answers Y with a tool call** → discard (best-effort, no
  retry). A single retry with `tool_choice: "none"` is template-
  dependent (some chat templates render it into the prompt, diverging
  the prefix) — verify per backend before ever enabling; default off.
- **Backends without prefix caching** pay one full-context prefill —
  bounded by the once-per-session trigger. Acceptable per planning
  decision; revisit if re-titling ever lands.
- **Serialized single-slot backends** (llama.cpp `-np 1`): debounce +
  cap + cancel-on-send make the side call harmless to interactive
  latency.
- **Fast typers vs. debounce**: cancellation must not consume the
  session's only attempt. `utility_attempted` flips only on a
  *completed* attempt; a `Send` that cancels an in-flight worker
  leaves it unset, and the next turn-commit point re-arms the debounce.
  Worst case the title lands one turn later than it could have.
- **Not enough signal in the first exchange** (greeting-only openers):
  resolved by the PASS postpone (see the 2026-10-25 decision above) —
  the model self-assesses and defers once, then the forced instruction
  guarantees convergence. Bounded cost: one extra ~Y + title-token
  side call per passing session on cache-capable backends.
- **Open**: exact Y wording and whether the title upgrade should also
  fire for sessions rehydrated from the store that already have a
  heuristic title but were created before this feature (proposal: no —
  only sessions whose first exchange happens after the feature boots).

## 9. Roadmap

- **P1 (this pass)**: `.agents/skills/llm-api` skill + this design doc.
- **P2**: `nexus/utility` module; shared Options extraction; session
  actor seam (`utility_runner`, trigger/cancel/result); registry
  `UpgradeAutoTitle`; `auto_title_upgrade.sql` + store wiring;
  `MetaUpdated` event + UI refresh; config knobs.
- **P3**: offline verification suite (§6).
- **P4** (later): tags per §7.
- **P5** (later): e2e cache-branch scenario on the llama.cpp alias.
