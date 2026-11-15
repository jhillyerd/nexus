---
title: Nexus — plugin API and the tool provider protocol
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, plugins, mcp]
updated: 2026-11-15
---

# Plugin API: one provider protocol for plugins, MCP servers, and nodes

**Thesis.** Nexus will eventually let users write their own in-process
plugins that expose tools. The decision recorded here: a plugin shows up
as a **named OTP actor** behind ONE internal message protocol — the
**tool provider protocol** — and mounts at the tool catalog as ordinary
`ToolSpec`s. The agent loop never learns what a plugin is. The same
protocol has three deployments: compiled-in plugin actors (user plugins;
v1 compiled into the release, load mechanism deferred), **MCP client
adapters** (configured MCP servers — a config option, NOT a plugin), and
**remote node adapters** (the environments plan's `/node/ws` tool plane).

This plan stands alone: it carries its own context and does not assume
the environments plan doc (`docs/plans/environments.md`, a sibling
draft at the time of writing) or any unmerged work. Where the two plans
touch, the connection is named explicitly.

Designed 2026-11-14 in conversation; every `gleam_erlang` API named here
was verified against the pinned 1.3.0 source (`named_subject`,
`process.named`, `monitor`, `select_specific_monitor`,
`selector_receive`, `reference.new` all exist — check
`build/packages/gleam_erlang/…` before trusting training data, per the
AGENTS.md pitfall list). The MCP
semantics adopted (tools/call, notifications/cancelled, plain-content
results) follow the precedent research recorded in the environments
plan.

## Vocabulary

- **Provider** — a named OTP actor that exposes tools. Registered under
  `nexus_plugin_<name>` (a `process.Name(ProviderMsg)`), supervised, and
  restartable; tool executors address it by NAME, never by a captured
  `Subject`, so a restart cannot dangle a reference in the catalog.
- **ToolDef** — a schema triple: unqualified name, description,
  parameters-JSON **text** (same raw-JSON-text convention as
  `tools.function_tool` today).
- **Qualified name** — the wire name `<provider>__<tool>` (e.g.
  `myplugin__fetch`). `__` is reserved: compiled-in tool names never
  contain it, and the catalog rejects a provider that violates it or
  collides, loudly, at registration.
- **Adapter** — the catalog-side glue that turns a provider's ToolDefs
  into `ToolSpec`s: builds the wire schema and runs the per-call
  executor (the select loop below).
- **Foreign snapshot** — schema text frozen at thread creation for tools
  whose provider is external (MCP); what makes hydration independent of
  the server being online.
- **Manifest** — the ordered, tagged toolset record persisted per thread
  once foreign entries exist (today's `thread.toolset text[]` holds only
  in-process names).

## Design summary

### Plugins mount at the catalog, not the loop

The loop's seam is `ToolSpec` — wire schema plus
`fn(ToolCtx, String) -> Result(String, String)` — executed synchronously
inside the per-turn worker (`loop.execute_all`). Everything in this plan
PRODUCES ToolSpecs; nothing changes `loop.gleam`, the frozen-envelope
construction, the per-toolset bundle cache, or the `m3_prefix_test`
golden. This is the same move the environments plan makes for env tools,
generalized: any future tool source becomes "something that resolves
names into specs".

### The provider protocol

```gleam
//// src/nexus/provider.gleam — the in-process tool-provider seam.

pub type ToolDef {
  ToolDef(name: String, description: String, parameters_json: String)
  // `name` is UNQUALIFIED ("fetch"); the catalog qualifies it to
  // "myplugin__fetch" so wire names stay in ^[a-zA-Z0-9_-]+$.
}

pub type ToolReply {
  ToolOk(content: String)   // plain text — the ADAPTER truncates/sanitises
  ToolErr(message: String)  // a failed tool result, never a loop error
}

pub type Msg {
  // Boot-time ask: the provider's tool list. The actor is the single
  // source of truth (no module-vs-actor drift).
  ListTools(reply: Subject(Result(List(ToolDef), String)))

  // Execute one call. `reply` is created by and owned by the CALLER —
  // the per-turn worker (the subject-owner rule). Exactly one reply
  // must eventually arrive; the adapter enforces the deadline anyway.
  Call(ref: Ref, tool: String, arguments: String, reply: Subject(ToolReply))

  // Best-effort notice: user Stop or adapter deadline hit. The
  // transcript already carries its cancelled/timeout result; this lets
  // the provider stop work. Mirrors MCP notifications/cancelled.
  Cancelled(ref: Ref)
}
```

`Ref` is `reference.Reference` from the pinned gleam_erlang — minted
per call with `reference.new()` (a thin wrap of `erlang:make_ref/0`;
an earlier draft of this plan wrongly claimed nothing in the pinned
packages mints one). It correlates `Call` ↔ `Cancelled` purely between
adapter and provider, which is why `ToolSpec.run` does NOT need the
wire `call_id` threaded into its signature.

Shape rationale:

- **Cancel is a message, not a subject.** A plugin actor cannot receive
  on the worker's cancel subject anyway (the AGENTS.md subject-owner
  pitfall), so the adapter translates. Plugins never see a Gleam
  subject they don't own.
- **Results are plain text plus an ok/err flag**, and the adapter
  truncates/sanitises centrally. Today each executor truncates itself;
  plugins and MCP servers are untrusted content sources, so the
  hostile-text invariant is enforced at the boundary, not delegated.
  Truncation is display hygiene, not the memory bound: an external
  provider's result size is capped while READING its transport
  (bounded accumulation — the `http_fetch` max-bytes pattern), since
  truncating after receipt does not bound allocation. In-process
  plugins are trusted code — the same trust as compiled tools — where
  adapter-side truncation is the whole story.
- **Provider failure is a tool error.** A dead or wedged provider
  renders as a failed tool result; the round commits; the model
  self-corrects — the environments plan's fail-fast rule, applied
  in-process.

### The adapter executor

Runs inside the per-turn worker (a plain function, like every other
executor). Codemode's worker select loop is the template:

```gleam
//// Pseudocode — illustrative, not compilable Gleam. The ordering is
//// the contract: resolve liveness and arm the monitor BEFORE the
//// dispatch, so a crash in between cannot drop the call into an
//// unmonitored void.
fn provider_run(provider, tool, timeout_ms, ctx, arguments) {
  case process.named(provider) {                    // liveness FIRST
    Error(Nil) -> Error("tool provider is unavailable")  // no send
    Ok(pid) -> {
      let reply = process.new_subject()             // worker-owned ✓
      let ref = reference.new()
      let mon = process.monitor(pid)
      let subject = process.named_subject(provider) // Name → Subject:
      process.send(subject, provider.Call(ref, tool, arguments, reply))
      case selector over {reply → GotReply, ctx.cancel → Cancel,
                          mon → Down, deadline = timeout_ms} {
        GotReply(ToolOk(content)) ->
          { demonitor(mon); Ok(truncate(content)) }
        GotReply(ToolErr(message)) ->
          { demonitor(mon); Error(truncate(message)) }
        Cancel -> {
          demonitor(mon)                        // every non-Down exit
          process.send(ctx.cancel, Nil)        // RE-SIGNAL (see below)
          process.send(subject, provider.Cancelled(ref))
          Error("cancelled")
        }
        Down -> Error("tool provider is unavailable")
        Timeout -> {
          demonitor(mon)
          process.send(subject, provider.Cancelled(ref))
          Error("timed out after …ms")
        }
      }
    }
  }
}
```

Pinned details:

- **The cancel re-signal is mandatory.** An interruptible executor
  consumes the `Nil` from `ctx.cancel` to wake its select — and must put
  it back, because the loop's LAST-call path relies on the re-signal
  reaching the next `cancel_pending` check (the codemode rule; see the
  comment on `loop.cancel_pending`). Dropping it would let a turn open
  another model request after the user asked it to stop.
- **Monitor before dispatch, don't wait out the timeout.** The pid is
  resolved and the monitor armed BEFORE the `Call` is sent: a provider
  already down fails without a send (`process.named` → `Error`), and
  one that dies mid-call is answered immediately by the monitor
  (`select_specific_monitor`) instead of a burned deadline (the
  environments plan's mid-run-detach analog). Dispatching first would
  leave a window where the call lands in a dead or unmonitored mailbox
  and only the timeout answers.
- **Demonitor on every non-`Down` exit.** The monitor is per-call and
  must not outlive it: on `GotReply`, `Cancel`, and `Timeout` the
  adapter calls `process.demonitor_process` before returning — an
  armed-but-forgotten monitor would queue an unmatched `DOWN` in the
  still-live worker for every past call of the turn. The pinned API
  exposes no flush flag, so a `DOWN` that already fired in the gap can
  remain queued — at most one inert message per call, the same
  bounded-by-the-turn garbage class as a late reply, never matched by
  any later select.
- **Late replies are harmless — but not because the worker is gone.**
  On timeout the worker lives on (sibling calls, the next iterations)
  and a stale `ToolReply` does queue in its mailbox. It is inert: the
  reply subject is minted fresh per call, so no later select can ever
  match it (selectors bind to their own subject), and the per-turn
  worker dies at turn end, dropping the queue. Abandoned calls cost at
  most mailbox garbage; the `Cancelled` notification is the best-effort
  cleanup.
- **Timeouts are per-call wall clock** — config default, overridable
  per provider — and render like any tool error, never a loop failure.

### What a plugin author writes

Two tiers, because "actor that must not block its own mailbox" is too
much ceremony for a fetch-shaped tool:

```gleam
//// Tier 1 — the SDK (a new nexus/plugin.gleam builds the actor for you).
//// The SDK spawns an unlinked worker per Call (kill-tree on Cancelled,
//// the codemode pattern), monitors it, and guarantees exactly-one
//// reply — a crashed tool worker is answered with
//// ToolErr("plugin tool crashed").
pub fn plugin() -> plugin.Plugin {
  plugin.Plugin(
    name: "myplugin",
    tools: [plugin.ToolDef("fetch", "Fetch a thing", "{…schema json…}")],
    call: fn(tool, arguments) -> Result(String, String),
  )
}
```

Tier 2 — a stateful plugin (owns a port, a connection, ETS) speaks
`provider.Msg` directly in its own actor: handle `ListTools`, spawn per
`Call`, track `ref → cancel route`, forward `Cancelled`, and reply
exactly once from wherever the work finishes. The protocol is the whole
contract; nothing else about the plugin's internals is nexus's business.

Lifecycle: providers start under a `plugin_sup` BEFORE the thread
registry builds its catalog. The boot-time `ListTools` ask is BOUNDED
(a short fixed timeout): a compiled plugin that won't start or won't
answer fails boot loudly (the no-silent-fallback philosophy), and an
MCP adapter that won't answer degrades exactly like an unreachable
server — its names unresolvable at create, with the honest 400 — so
nothing external can hang boot. The interface is
load-mechanism-agnostic on purpose: anything that can (1) register the
name and (2) speak `Msg` is a provider. v1 plugins are compiled into the
release and listed by config; a future load mechanism only has to
produce the same two things.

### Catalog, freezing, and names

- The boot-built catalog becomes **compiled ∪ plugins**: each provider
  is asked `ListTools` once at boot, and its qualified names enter the
  same catalog `tools.by_names` resolves. Plugin names therefore behave
  exactly like compiled names — resolvable offline, snapshot-pinnable by
  bots, loud `unknown tool name` refusal when stale.
- **The catalog validates before it admits.** A `ToolDef` is untrusted
  at the boundary: the unqualified name must match `^[a-zA-Z0-9_-]+$`
  (the `__` separator is reserved, enforced on both halves of the
  qualified name), `parameters_json` must parse with an OBJECT root and
  fit a byte bound — anything less refuses the provider's registration
  loudly, before any name enters the catalog or a frozen manifest.
  (`tools.function_tool` today silently drops unparseable schema text
  to `parameters: None` — acceptable for compiled-in programmer error,
  wrong for provider input.)
- **Never in the default toolset.** Plugin/MCP tools enter a thread only
  via a bot template or an explicit create flag. Config gates
  AVAILABILITY (the provider exists), never default membership — the
  SearxNG/`web_search` rule, so the default envelope cannot change under
  config drift.
- Create-time refusal reuses `UnknownToolset` (a 400) for names the
  catalog doesn't know — one more entry in that error's existing
  meaning, no new semantics.

### MCP servers are a config option, not a plugin

A shipped **MCP client adapter** implements the provider protocol on
behalf of configured servers: one actor per server (config lists name +
stdio command or HTTP URL), owning the port/connection, doing the
`initialize` / `tools/list` handshake at start. `Call` becomes a
JSON-RPC `tools/call`; `Cancelled` becomes
`notifications/cancelled`; the reply maps to `ToolOk`/`ToolErr`.

The one asymmetry vs in-process plugins: **the schema must come from
somewhere at creation.** So:

- Create naming `github__create_issue` → the registry asks the adapter's
  live `tools/list`, validates each entry at the boundary (charset,
  `__`, parseable object-rooted JSON, byte bound — the catalog rule
  above), **freezes the schema** into the toolset manifest,
  and builds the bundle (bundle cache keyed by name tuple + snapshot
  identity, so two threads of one snapshot share it).
- Hydration replays the frozen snapshot and never contacts the server —
  the environments plan's property, restated: hydration must not depend
  on an external server being online.
- Server down at call time → fail-fast error result (the
  web_search-without-SearxNG pattern).
- The snapshot's schema is persisted as **text, not jsonb** — the
  `thread_message.tool_args` philosophy: byte-stability of envelope
  bytes beats queryability. The envelope is built from the stored
  snapshot from request #1 (create precedes the first request), so
  prefixes stay byte-identical for the thread's life.
- `thread.toolset` grows from `text[]` into an **ordered manifest** of
  tagged entries — plain in-process names or `{server, tool, frozen
  schema}` — because order IS the envelope order and must live in one
  ordered structure. Schema work follows the usual flow
  (`sql/schema.sql` idempotently, migrate, squirrel, committed generated
  code).

An unreachable MCP server at BOOT degrades (external dependency, like
SearxNG absence): its names are simply unresolvable at create, with an
honest 400 naming the server. A compiled plugin failing at boot is the
opposite — fail-fast — because it is part of the release.

### Relation to the environments plan

The environments plan's remote-node tool plane is the third deployment
of this protocol: the node adapter answers the internal `Call` /
`Cancelled` by translating to the versioned client protocol's tool
plane. That makes the plan's "one execution seam" concrete internally —
plugin, MCP server, and node are the same actor shape with different
transports behind them. The roster/`target` machinery stays entirely
the environments plan's concern; this plan owns only the seam both
consume. The plans land independently either way.

## Phases

### Phase 1 — provider protocol + in-process plugins (offline-provable) — IMPLEMENTED

As built (see the deltas below the list):

1. `src/nexus/tool_provider.gleam` (protocol types), `src/nexus/plugin.gleam`
   (tier-1 SDK), the adapter executor with its select loop, and the
   boot catalog generalization (compiled ∪ providers; loud
   registration-time collision/refusal).
2. One in-repo example plugin (`src/nexus/plugins/example.gleam`,
   compiled, config-listed) as the reference implementation and test
   vehicle.
3. Tests through subject-based seams, network-free (`test/tool_provider_test.gleam`,
   `test/plugin_test.gleam`, registry/config additions): a fake provider
   (`gated_runner`-style where gating is needed) pinning — cancel-delivery
   + re-signal, timeout, provider-DOWN, late-reply no-op, truncation at
   the adapter, exactly-one-reply under a crashing SDK worker, catalog
   loudness, and `m3_prefix_test` untouched (default envelope unchanged).

**As-built deltas** (Phase 1 met code the design predates, plus two
mechanics discovered mid-build):

- The protocol module is `tool_provider.gleam`, not `provider.gleam` —
  that path has been the LLM-provider domain since the multi-provider
  rollout (Oct 2026). The `Plugin` DECLARATION type lives in
  `tool_provider` too, so `nexus/plugins/*` import only the leaf (the
  codemode↔tools cycle rule); the SDK actor and boot live in `plugin.gleam`.
- `plugin_sup` is a separate OneForOne tree linked to boot main, not a
  child of the OneForAll root: the boot-built provider table must be one
  value shared by `bot_registry`'s ValidateTools closure and
  `thread_registry`'s resolution, and root-tree children cannot hand
  values to each other. A crash-looping plugin still fails loud — the
  linked tree dying takes boot down, the same mechanism the root relies on.
- `process.new_name` suffixes a unique counter per call, so a provider's
  `Name` is minted ONCE and the VALUE threaded (supervisor child, snapshot
  ask, and the spec executor all close over the same value — never
  re-derived). The SDK actor registers that name itself in its
  initialiser (`process.register`), so a supervisor restart re-registers
  the fresh pid; its own message type is a superset (`SdkMsg`) fed by a
  custom selector over the named subject, a private subject, and monitor
  downs.
- Sending to an UNREGISTERED named subject panics at the send — both
  `run` and the boot-time `list_tools` resolve liveness (`process.named`)
  BEFORE building the subject (pinned by a test).
- Config knobs: `NEXUS_PLUGINS` (default empty — the pre-plugin boot,
  byte for byte), `NEXUS_PLUGIN_TIMEOUT_MS` (default 30 000, floor 100),
  `NEXUS_PLUGIN_MAX_OUTPUT_CHARS` (default 32 768). The catalog merge is
  `tools.by_names_with(cfg, table, names)`; `by_names` is the empty-table
  case; the bot registry's validation closure resolves through the table
  too, so bot templates can pin plugin tools.
- Review-hardened after the PR review (cubic): half-names also reject
  leading/trailing `_` — `a_`+`b` and `a`+`_b` both qualified to
  `a___b`, so the separator was not the only `__` in a qualified name
  (split-ambiguity); a plugin's `timeout_ms` override is validated
  against the same 100 ms floor as the config (a negative override
  reaches Erlang's `after` and crashes the per-turn worker with
  `timeout_value`); the failed-dispatch branch demonitors before
  returning; and every send to a provider's named subject is
  rescue-guarded (unregistered-name sends badarg in the pinned
  gleam_erlang — a provider dying with its DOWN in flight must
  degrade to a tool error, never kill the worker).

### Phase 2 — MCP config adapter + frozen snapshots — IMPLEMENTED

As built (see the deltas below the list):

1. `src/nexus/mcp.gleam` — the codec (request builders, frame
   classification, the `tools/list` boundary, the bounded line reader,
   canonical JSON) and the `Transport` seam; `src/nexus/mcp_adapter.gleam`
   — the actor + boot mount (`mcp_sup`). Config: `NEXUS_MCP_SERVERS_JSON`,
   a JSON array of `{name, command, args?, env?, timeout_ms?}` entries,
   validated loudly at config load.
2. The ordered manifest: `thread_toolset`
   (`thread_id, seq, name, description, schema_json`; PK
   `(thread_id, seq)`, singular-table conventions, frozen columns
   TEXT) replaced `thread.toolset text[]`. The upgrade is LOSSLESS:
   a database still carrying the old column has its name lists
   backfilled as plain manifest entries inside one guarded `DO` block
   before the drop (plain entry is exactly what those names were); a
   database already migrated skips both.
   `insert_thread` writes row + manifest as ONE statement (CTE +
   `json_to_recordset`), so a half-thread cannot exist; reads aggregate
   the manifest as one json text (transport only — stored columns stay
   TEXT). Create-time live `tools/list` freeze in
   `thread_registry.freeze_entries`; hydration replays the frozen
   manifest (`tools.by_entries_with` → `foreign_spec`) with NO server
   contact; the bundle cache keys on the ENTRY tuple (name + description
   + schema), so byte-identical snapshots share a bundle and drifted
   ones never do.
3. Tests, offline: the codec suite (canonical-JSON determinism, hostile
   schemas, the 8 MiB read cap, frame classification) and the actor
   suite over a fake transport (`start_probing`, the `gated_runner`
   inversion — the test plays the server on the actor-owned events
   subject), plus registry freeze/hydration/down-at-call integration
   through the mock store. Live stdio behavior verified manually against
   a Python echo server (PATH-resolved spawn, handshake, tools/list,
   tools/call); live-server e2e coverage belongs to the integration
   suite and is NOT yet added.

**As-built deltas** (Phase 2 met code the design predates, plus the
mechanics discovered mid-build):

- **Frozen schemas are CANONICAL text, not the server's raw bytes.**
  OTP's JSON decoder loses object key order, so freezing the server's
  bytes verbatim is impossible after a parse — and an unsorted
  re-encode would drift across VM runs (map iteration order is
  unspecified). The freeze therefore persists OUR canonical form
  (whitespace-free, keys sorted at every level), which is deterministic
  from the parsed value and byte-stable forever after; the 16 KiB
  boundary applies to the canonical text. Semantically lossless (key
  order is not schema semantics) and envelope-stable — the two
  properties the contract needs.
- **The manifest freezes the DESCRIPTION too.** Descriptions ride the
  request envelope, so a foreign entry persists (name, description,
  schema) — the design's `{server, tool, frozen schema}` triple, with
  description added where the envelope demanded it. Descriptions are
  capped at 2 000 chars (marker counts inside the cap) at the same
  boundary.
- **`spawn_executable` does NOT search PATH** — a bare `npx` fails —
  so the FFI resolves slash-free commands against the inherited PATH
  (first hit wins) before spawning. Env pairs override/add to the
  inherited environment (verified live).
- **Boot asks run CONCURRENTLY and every configured server is
  mounted.** The bounded probes run as spawned askers over one shared
  reply subject (N unreachable servers cost one budget, not N). A
  failed probe logs loudly but does NOT unmount: the actor is alive
  and registered, the create-time freeze asks LIVE and refuses with
  the honest reason, and — the point — hydration of that server's
  frozen threads keeps working from the manifest, which is the plan's
  own hydration-never-contacts-the-server property. A server absent
  from CONFIG is absent from the map and refuses as unknown (the same
  loud rule as a plugin removed from `NEXUS_PLUGINS`). An actor's
  initialiser NEVER fails the supervisor child — a spawn failure is a
  `Down` phase (a crash-looping supervisor would take boot down for
  what is an external process). Port death arrives as
  `{exit_status, N}` (no exit signal): the actor degrades to `Down`,
  fails every pending ask/call honestly, and stays up; the next nexus
  restart re-spawns the server. Mid-life retry/reconnect is recorded
  as future work.
- **The actor's outbound deadline IS the server's resolved per-call
  timeout** (config default or the entry's `timeout_ms` override), so
  actor and executor give up at the same DURATION. Their clocks start
  at different instants, so EITHER side may time out first; both paths
  answer honestly (the actor's carries the `notifications/cancelled`
  notice) and the loser's reply or notice is inert.
- **`ListTools` is ALWAYS a live round trip** — boot mount and
  create-time freeze both get the server's current catalog, and askers
  arriving mid-round-trip (or during the handshake) ride it. Pagination
  (`nextCursor`) is followed to 10 pages. One bad `tools/list` entry
  fails the whole catalog (refusing half a hostile server would be a
  silent narrowing).
- **Bot validation never asks the server.** A name whose server half is
  mounted passes the bot registry's closure without a live ask (a bot
  SAVE must not depend on a server's mood); the freeze happens per
  THREAD at create. Collisions between `NEXUS_PLUGINS` and server
  names refuse boot loudly (deterministic user config).
- **Server-initiated JSON-RPC requests are answered `-32601`** (a
  request REQUIRES a response; nexus is a tool client only);
  notifications are ignored. Call arguments are canonicalized to an
  object before the wire (MCP requires an arguments OBJECT, and the
  canonical form is newline-free so the framing survives
  pretty-printed model output); non-objects refuse before the wire.
- **`tool_provider.run` is untouched** — a foreign spec is the same
  executor shape with the frozen schema, addressing the adapter by its
  minted name (the foreign map), monitor-armed before dispatch,
  cancel re-signalling per the codemode rule, truncation at the
  adapter.
- **Config is ONE JSON env var** (`NEXUS_MCP_SERVERS_JSON`), not
  per-server vars: a stdio command carries arguments with spaces, and
  JSON already has the quoting rules. Empty/unset keeps boot
  byte-identical to the pre-MCP world; the `m3_prefix_test` golden is
  untouched.
- **HTTP transport deferred** (the plan's "stdio first; HTTP after"):
  the `Transport` seam is the only HTTP-shaped hole. URL entries are
  FUTURE CONFIG-SCHEMA WORK: the current schema validates the stdio
  shape (duplicate names, provider-name syntax, non-empty command, env
  key/value rules, timeout floor) and has no URL form; a `url` variant
  adds its own fields and checks when that transport lands, with
  live-server e2e integration coverage.

### Phase 3 — deferred (recorded, not scheduled)

- Plugin load mechanism research (BEAM code-path loading / release
  packaging); the protocol is already load-agnostic.
- `Call` context growth (thread id, environment handle): additive,
  versioned field, only when a consumer exists.
- Parallel tool fan-out (today `execute_all` is a sequential fold; the
  protocol already tolerates concurrency).

## Non-goals (recorded, not planned)

- **No UI, hooks, or plugin lifecycle management beyond supervision** —
  tools only; those surfaces are future initiatives.
- **No mid-thread mounting** — the frozen-toolset invariant is
  untouched: provider tools freeze at creation or never appear.
- **No approvals or sandboxing at the provider seam** — same stance as
  the environments plan; a plugin is trusted code (it runs in-process),
  an MCP server is untrusted CONTENT (truncation) but its tools are
  user-configured on purpose.
- **No plugin-to-plugin bus** — providers are tool sources, not peers;
  bot-to-bot messaging is the bots plan's territory.

## Invariant checklist (what this plan must not break)

- **KV-cache contract**: the envelope (`model`, `stream`, `tools`,
  `tool_choice`) stays frozen per thread; provider tools freeze at
  creation (plain name or foreign snapshot) or never appear; snapshot
  schemas are stored as text and encoded through the single
  construction path; `m3_prefix_test` golden untouched (default
  envelope unchanged).
- **Hostile text**: every provider/MCP byte that reaches the UI passes
  the adapter's truncation/sanitisation; external providers' result
  sizes are capped at transport read (truncation is display hygiene,
  not the memory bound); schemas are validated at the boundary before
  entering the catalog or a frozen manifest; results render as inert
  Lustre text nodes like every other tool.
- **Loud unknown names**: `by_names` keeps refusing unknown names
  loudly (hydration of a name whose provider vanished from the catalog
  fails loudly, never silently narrows).
- **Offline tests**: `gleam test` stays network-free — providers are
  exercised through subject seams; live MCP/stdio coverage lives in the
  e2e suites.
- **Schema conventions** (when the manifest lands): singular table
  names, unquoted-safe names, `<table>_<purpose>` indexes, `timestamptz`
  only; snapshot schema text stays TEXT.
- **Subject ownership**: only the per-turn worker receives on its
  subjects; every other participant gets messages.
