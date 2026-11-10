---
title: Nexus — codemode tool (Lua scripts in the agent loop)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, codemode]
updated: 2026-11-08
---

# Codemode: model-authored Lua scripts as a tool

**Thesis.** Give the model a `codemode` tool whose argument is a Lua script.
The script calls nexus's other tools from inside the tool execution, filters
and digests the results, and returns one compact tool result. N tool
round-trips collapse into one model turn, and intermediate blobs never enter
the transcript — fewer requests, smaller prefix growth (KV-cache contract
rule: fewer, smaller suffixes, same frozen envelope).

Precedent: pi's codemode (QuickJS sandbox, `tools.*` host calls, output-only
results). Engine research is recorded in Hindsight memory: Luerl/glua chosen
(pure BEAM, no NIFs, offline-testable, models write Lua well); QuickJS-NIF,
EYG and ports documented as future alternatives behind the same seam.

## Design summary

- **Engine**: [glua](https://hex.pm/packages/glua) v2 (Gleam wrapper over
  Luerl, pure-Erlang Lua 5.3 — no `coroutine` library, which codemode does
  not need).
- **Script surface**: plain Lua 5.3 plus a host table:
  - `tools.<name>(args)` — call a sibling tool; `args` is a Lua table shaped
    like the tool's JSON schema; returns the tool's content string, or raises
    a Lua error carrying the tool error text.
  - `tools.call_all({{name=…, args=…}, …})` — phase 2: run a list of calls in
    parallel, one array of allSettled values back in input order.
  - `text(value)` — append an output item (strings as-is, tables as JSON).
  - `print(...)` — overridden; appends to a `<console_output>` block.
  - **Every** value the script's `return` yields becomes a trailing output
    item (same rendering as `text()`; `nil` values and an absent `return`
    add nothing). Amended 2026-11 after live-agent review — the original
    "the final return value becomes the last output item" kept only the
    first value and silently discarded Lua's idiomatic multi-returns
    (`return a, b`). The same review considered deduplicating
    `text(x)` + `return x` in the harness and **rejected** it:
    string-equality magic can eat legitimate repeats, and a visible,
    predictable duplicate is self-correcting; the tool description tells
    the model to emit its answer once.
- **Sandbox**: `glua.new_sandboxed` (blocks `io`, `file`, `os.execute/exit/
  getenv/remove/rename/tmpname`, `package`, `load/loadfile/require/dofile/
  loadstring`). The only world-access is the host table. Codemode is excluded
  from its own `tools` table (recursion guard).
- **Budgets**: four bounds — wall-clock deadline, output cap (separator-
  inclusive: the renderer's item/console joins count against it — issue
  #53), per-script
  **tool-call budget** (constant, ~25 calls; exceeding it fails the script),
  and a **VM memory bound**. The call budget bounds retained *host results*
  (each is already truncated by its own tool's limits, so host-derived memory
  ≤ budget × per-tool cap) — it does **not** bound pure-Lua allocation, so
  the engine child also sets `process_flag(max_heap_size, …)` (~64 MiB in
  words; `gleam_erlang` does not expose it — a one-line `nexus_*_n.erl` FFI).
  Exceeding it kills the engine and surfaces as `Script error: out of
  memory` (pi caps its codemode VM at 256 MB for comparison). The tool
  description documents all bounds.
- **Tool schema**: `{"code": string}`; description documents the mini-API and
  limits (~400 tokens). Sibling tools stay declared normally — the codemode
  description documents only the *calling convention*, not their schemas.
- **Result format** (Pi-inspired):
  `Script completed (<wall ms>)` / `Script failed (<wall ms>)`, output items,
  then `<console_output>` block; failed runs keep partial output followed by
  `Script error: <reason>`. Output truncated at a configurable cap (keep head
  and tail, note the omission). A failed script surfaces as the tool's
  `Error` — carrying that same formatted result — so the agent loop marks
  the tool result failed (red chip, persisted `ok=false`, the #44
  convention) while the model still sees every byte of the failure detail.
- **Process model & cancellation**: `codemode.run` executes inside the
  per-turn worker process, which spawns a dedicated engine child **linked to
  the worker**. Today `Stop` cannot reach tool execution — the thread's
  `Stop` handler only signals the *stream* cancel subject or sets a
  stop-pending flag; nothing interrupts the worker while it runs a tool. So
  the seam must pass the turn's cancel subject down (see step 4): while the
  engine child evaluates, the worker blocks in a select over
  `{engine reply, cancel subject, deadline}` — cancel, timeout, and worker
  death all kill the engine (safe: Luerl state is process-local; the link
  covers worker crash/turn teardown). `text()`/`print` events stream to the
  worker as they happen, so partial output survives timeouts and cancels.
- **Envelope**: the tools array is frozen per boot. Codemode registers only
  when enabled (`web_search` precedent). Enabling it mid-deployment diverges
  existing threads' prefixes once (full re-prefill) — documented, accepted.
  The offline golden test and e2e fixture keep codemode **off** in the smoke
  config, so no fixture recapture in these phases.

## Phase 1 — synchronous codemode — IMPLEMENTED

(Implemented in PR #50 plus review fixes #52/#55 and #53/#56.)

1. `gleam add glua` (pulls luerl; both from hex, offline builds stay clean).
2. Config (`src/nexus/config.gleam`, fail-fast as always) with validated
   ranges (invalid values halt boot like every other config error):
   - `NEXUS_CODEMODE` — bool, default `false`.
   - `NEXUS_CODEMODE_TIMEOUT_MS` — int ≥ 1000, default `30000`.
   - `NEXUS_CODEMODE_MAX_OUTPUT_CHARS` — int ≥ 0, default `32768`.
   - Negative/zero timeout or negative cap → boot error; covered by
     invalid-value cases in `test/config_test.gleam`.
3. New `src/nexus/codemode.gleam`:
   - `schema() -> ChatCompletionTool`.
   - `run(specs, cfg, ctx, arguments) -> Result(String, String)` — decode
     `code`, build sandboxed Lua state, install host functions (each
     `tools.<name>` closure calls `tools.execute(specs, name, json)`
     synchronously, counting against the call budget), spawn the engine
     child, and run the worker select loop over
     `{reply, ctx.cancel, deadline}`; format the result.
4. Seam + registry wiring (`src/nexus/tools.gleam`, `src/nexus/loop.gleam`):
   - Widen `ToolSpec.run` to take a per-turn context
     (`fn(ctx, arguments)`, `ToolCtx(cancel: Subject(Nil))`); existing tools
     ignore `ctx`. The loop already receives the cancel subject (the streaming
     seam's input) — `execute_all` passes it down, which is what makes
     mid-script `Stop` work (a `Stop` sent during tool execution lands in the
     subject's queue and wakes the worker's select loop).
   - `default(cfg)` appends the codemode spec **after** building the sibling
     list, capturing that list (registry stays one-per-boot; KV-cache rule 4
     intact).
5. Tests (offline, `test/codemode_test.gleam` + `config_test.gleam` +
   `tools_test` additions):
   - Lua eval + host round-trip against mock specs (no network).
   - Hostile output: `<script>` payloads pass through as inert text.
   - Infinite-loop script (`while true do end`) killed at deadline, partial
     output preserved.
   - Cancellation: a cancel sent mid-script kills the engine and returns
     `Script failed (<wall ms>)` with `Script error: cancelled` and partial
     output.
   - Tool-call budget: a script looping past the budget fails with the
     budget error, not an unbounded loop.
   - Config: invalid timeout/cap values rejected at load
     (`test/config_test.gleam`).
   - Sandbox: `load`, `require`, `os.execute` all error as sandboxed.
   - Unknown tool name; `codemode` absent from its own `tools` table.
   - Output truncation; `tools.default` envelope unchanged with flag off.
6. Acceptance: a model-authored script performs two sequential `http_fetch`
   calls, digests both, returns one small result; all tests green offline; UI
   renders script and result as ordinary (inert, truncated) tool content.

## Phase 2 — parallel batch (`tools.call_all`) — IMPLEMENTED

Implemented 2026-11-08 alongside two hardening points the plan text
under-specified (both found by tests, both pinned by regression tests),
plus three cubic review fixes on the phase-2 PR (all pinned):

- **The batch is budgeted BEFORE the deadline short-circuit** —
  deadline-exceeded values are still handed to the script, so those
  entries must draw the same 25-call budget as any other call, or a
  near-deadline script could keep issuing uncounted batches.
- **Sparse batches are rejected** (`dense 1-based array` script error):
  iterating to `#v` silently dropped entries after a hole, dodging
  both the calls and the budget accounting.
- **Crash terms are bounded before formatting** (`cap_term`: depth 3,
  breadth 16, 100-byte binaries): pretty-printing a pathological
  reason whole and truncating after would still materialise an
  unbounded iolist in an uncapped batch child.

- **Crashing entries are error values, not engine deaths.** Each child
  runs its host closure under a crash-catching FFI (`safe_call`) — a
  panicking entry returns `{ok=false, error="host crashed: …"}` instead
  of taking the engine down through the link (allSettled semantics,
  applied to crashes too; the SYNC path still dies as "engine crashed",
  its pinned phase-1 behavior).
- **The straggler reap unlinks before killing.** Killing a child that
  already reported but is still winding down would otherwise deliver
  `EXIT(killed)` through its link and take the ENGINE down — every
  outcome was already collected, so the child is unlinked first.
  A `glua` formatter bug also surfaced here and was wrapped at the
  seam: a Lua runtime TYPE error (`'a' .. true`, badarg/badarith)
  crashed glua's `format_error` (it feeds `luerl_lib:format_value`'s
  IO data to `string.join`), turning a script type error into
  "engine crashed" with no self-correction signal; `engine_main` now
  formats through `safe_format_error`, falling back to
  `luerl_lib:format_error/1`.

Original plan (as implemented, with the batch deadline margined 50 ms
inside the script deadline so a partial list can be folded and emitted
before the wall-clock kill — see `batch_deadline_margin_us`):

1. Add one host function: `tools.call_all({ {name=…, args=…}, … })` — spawns
   one BEAM process per entry **linked to the engine process** (each runs the
   plain `spec.run` closure), waits on subjects with the remaining script
   deadline, returns a result list with **errors as values**
   (`{ok=false, error=…}`) so one failure never kills the batch (allSettled
   semantics). Linking means the deadline cannot strand work: engine exit —
   normal end, timeout, cancel, or kill — reaps every in-flight call.
2. Description gains ~3 lines documenting `call_all`.
3. Tests: fan-out ordering; a slow mock tool proves overlap (3 parallel calls
   complete in ~1× the single-call wall time, generous margins); per-entry
   failure isolation; deadline expiry returns the partial result list and no
   worker outlives the engine (assert via `ProcessDown`/monitor draining).
4. Acceptance: a script fans out three `http_fetch` calls concurrently and
   folds the results; wall time demonstrably sub-serial. (Offline overlap
   test pins the mechanism; live http_fetch acceptance rides the next
   codemode-enabled e2e pass — the m3 smoke keeps codemode off.)

## Later / non-goals (recorded, not planned)

- `bg`/`await` futures (overlapping dependent work) — additive later; the
  `go`/`wait` state-forking design is rejected for now (outside glua's
  state-threading contract).
- `luerl_sandbox` reduction-budget FFI (CPU-hog preemption nicer than kill).
- `store`/`load` KV across calls — would ride the transcript sidecar pattern
  (`reasoning_at` precedent) so it can never perturb request bytes.
- Alternative engines (EYG, QuickJS NIF) behind the same `codemode.gleam`
  seam, if model-written Lua proves limiting.
- Hiding sibling tools from the model (pi's `codemode.mode: only`) — not now.

## Invariant checklist (what this plan must not break)

- Frozen per-boot toolset / identical `tools` envelope across threads
  (config-gated registration; registry unchanged while off).
- `thread_message.tool_args` stays `text` — codemode args are a JSON string
  stored byte-exact, no schema change.
- Offline `gleam test` — engine is pure BEAM; tests use mock tool specs.
- Hostile text — script source and output render as Lustre text nodes only.
- Stop/cancel reaches tool execution, not just the streaming seam — a
  codemode script is interruptible mid-run (verified: the current `Stop`
  handler only signals the stream cancel subject or sets a stop-pending
  flag, so this requires the seam change in phase 1 step 4).
- Fail-fast config validation, exit code 2 on bad values.
