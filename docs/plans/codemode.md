---
title: Nexus — codemode tool (Lua scripts in the agent loop)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, codemode]
updated: 2026-11-09
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
  - `text(value)` — append an output item (strings as-is, tables as JSON).
  - `print(...)` — overridden; appends to a `<console_output>` block.
  - The script's final `return` value becomes the last output item.
- **Sandbox**: `glua.new_sandboxed` (blocks `io`, `file`, `os.execute/exit/
  getenv/remove/rename/tmpname`, `package`, `load/loadfile/require/dofile/
  loadstring`). The only world-access is the host table. Codemode is excluded
  from its own `tools` table (recursion guard).
- **Tool schema**: `{"code": string}`; description documents the mini-API and
  limits (~400 tokens). Sibling tools stay declared normally — the codemode
  description documents only the *calling convention*, not their schemas.
- **Result format** (Pi-inspired):
  `Script completed (<wall ms>)` / `Script failed (<wall ms>)`, output items,
  then `<console_output>` block; failed runs keep partial output followed by
  `Script error: <reason>`. Output truncated at a configurable cap (keep head
  and tail, note the omission).
- **Process model**: `codemode.run` executes inside the per-turn worker
  process (existing seam). It spawns a dedicated engine child **linked to the
  turn worker** (turn cancel tears it down) and enforces its own wall-clock
  deadline by killing the child — safe because Luerl state is process-local.
  `text()`/`print` events stream to the worker before the kill, so partial
  output survives timeouts.
- **Envelope**: the tools array is frozen per boot. Codemode registers only
  when enabled (`web_search` precedent). Enabling it mid-deployment diverges
  existing sessions' prefixes once (full re-prefill) — documented, accepted.
  The offline golden test and e2e fixture keep codemode **off** in the smoke
  config, so no fixture recapture in these phases.

## Phase 1 — synchronous codemode

1. `gleam add glua` (pulls luerl; both from hex, offline builds stay clean).
2. Config (`src/nexus/config.gleam`, fail-fast as always):
   - `NEXUS_CODEMODE` — bool, default `false`.
   - `NEXUS_CODEMODE_TIMEOUT_MS` — int, default `30000`.
   - `NEXUS_CODEMODE_MAX_OUTPUT_CHARS` — int, default `32768`.
3. New `src/nexus/codemode.gleam`:
   - `schema() -> ChatCompletionTool`.
   - `run(specs, cfg, arguments) -> Result(String, String)` — decode `code`,
     build sandboxed Lua state, install host functions (each `tools.<name>`
     closure calls `tools.execute(specs, name, json)` synchronously), run in
     the engine child with deadline, format result.
4. Registry wiring (`src/nexus/tools.gleam`): `default(cfg)` appends the
   codemode spec **after** building the sibling list, capturing that list
   (registry stays one-per-boot; KV-cache rule 4 intact).
5. Tests (offline, `test/codemode_test.gleam` + `tools_test` additions):
   - Lua eval + host round-trip against mock specs (no network).
   - Hostile output: `<script>` payloads pass through as inert text.
   - Infinite-loop script (`while true do end`) killed at deadline, partial
     output preserved.
   - Sandbox: `load`, `require`, `os.execute` all error as sandboxed.
   - Unknown tool name; `codemode` absent from its own `tools` table.
   - Output truncation; `tools.default` envelope unchanged with flag off.
6. Acceptance: a model-authored script performs two sequential `fetch` calls,
   digests both, returns one small result; all tests green offline; UI renders
   script and result as ordinary (inert, truncated) tool content.

## Phase 2 — parallel batch (`tools.call_all`)

1. Add one host function: `tools.call_all({ {name=…, args=…}, … })` — spawns
   one BEAM process per entry (each runs the plain `spec.run` closure), waits
   on subjects with the remaining script deadline, returns a result list with
   **errors as values** (`{ok=false, error=…}`) so one failure never kills the
   batch (allSettled semantics).
2. Description gains ~3 lines documenting `call_all`.
3. Tests: fan-out ordering; a slow mock tool proves overlap (3 parallel calls
   complete in ~1× the single-call wall time, generous margins); per-entry
   failure isolation; deadline expiry returns partial results.
4. Acceptance: a script fans out three fetches concurrently and folds the
   results; wall time demonstrably sub-serial.

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

- Frozen per-boot toolset / identical `tools` envelope across sessions
  (config-gated registration; registry unchanged while off).
- `session_message.tool_args` stays `text` — codemode args are a JSON string
  stored byte-exact, no schema change.
- Offline `gleam test` — engine is pure BEAM; tests use mock tool specs.
- Hostile text — script source and output render as Lustre text nodes only.
- Fail-fast config validation, exit code 2 on bad values.
