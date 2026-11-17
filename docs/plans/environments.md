---
title: Nexus — environments (bot workspaces + remote paired TUI nodes)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, environments]
updated: 2026-11-16
---

# Environments: one execution seam for bot workspaces and paired remote nodes

**Thesis.** Two features — (1) an optional bash-style workspace so bots can
download and process data or clone and investigate a repo, and (2) pairing a
remote "coding agent" style TUI with an existing thread so tools run on a
homelab node or the user's machine — are the *same* feature. Both need a
place where `bash`/file tools execute, addressed from a frozen toolset. The
plan introduces one abstraction, the **environment**, with three
deployments: the in-process workspace on the nexus host (v1), an external
container workspace (later, same wire protocol), and remote nodes reached
through TUI clients that dial out to nexus.

The tool plane has a named internal counterpart: the **tool provider
protocol** (`docs/plans/plugin-api.md`) — named OTP actors answering
`ListTools` / `Call` / `Cancelled` with caller-owned reply subjects. That
plan declares this plan's `/node/ws` tool plane the *third deployment* of
the protocol (after compiled-in plugins and MCP client adapters): the
node adapter answers internal `Call` / `Cancelled` by translating to and
from the client protocol's MCP-shaped frames. The two plans land
independently; this one owns the roster and `target` machinery, that one
owns the seam both consume.

Precedent researched 2026-11-14 (Hindsight: "Environments: bot workspaces +
remote paired TUI nodes"): OpenAI's self-hosted Agents API environments —
harness in the cloud, executor in the user's environment, **outbound**
WebSocket with reconnect and `pending / connected / failed` lifecycle — is
the connectivity model for remote nodes. MCP semantics (tools/call,
notifications/cancelled, plain-content results) are adopted for the tool
sub-protocol; ACP was evaluated and rejected (editor↔local-agent protocol,
stdio transport, wrong trust model — it may return later as a *front-end*
adapter, never as this transport).

## Vocabulary

- **Environment** — a place where environment tools execute. Named by a
  **target** string. `workspace` is the reserved target for the thread's
  own workspace, the only environment selected at thread creation.
- **Roster** — the set of currently attached targets for a thread, live
  state in the thread actor. `[workspace, proxmox-2, …]`.
- **Node** — a remote machine running a **TUI client** that connects to
  nexus outbound over WebSocket, joins a thread, and serves its machine as
  a target. Identified by a stable user-assigned name.
- **Attach / detach** — a node joining/leaving a thread's roster. Reflected
  to the agent as a transcript **roster message**, never as an envelope
  change.
- **Client protocol** — the nexus-owned, versioned JSON WebSocket protocol
  spoken by TUI clients (`/node/ws`). Deliberately *not* Lustre's `/ws`
  server-component protocol, which is Lustre-internal and version-coupled
  to the generated `runtime.mjs` it ships with.
- **Provider protocol** — the internal tool-provider seam defined by
  `docs/plans/plugin-api.md` (`nexus/provider.gleam`: `ListTools`, `Call`,
  `Cancelled`; ok/err replies; adapter-side truncation). Node adapters are
  one deployment of it.

## Design summary

### The envelope never learns about the roster (KV-cache rule 4 intact)

- **Env tools are ordinary compiled-in tools** (`bash`, `read_file`,
  `write_file`, `list_dir`), frozen into `thread.toolset` at creation like
  any other names — via a bot template or an explicit create flag. They
  are gated OUT of the default toolset while no workspace root is
  configured: a config flip must not change the default envelope (same
  reasoning as the SearxNG gate on `web_search`). *As-built delta
  (post-#121 picker, pre-deployment operator call):* the default toolset
  is now "every catalog tool that works in this deployment", so WITH a
  root configured the env four JOIN the default (and future compiled
  tools join automatically via `catalog_names`) — the stability property
  is unchanged, the posture is deliberately richer.
- Every env tool takes a **`target: string` parameter** — a free string,
  not an enum. The schema is byte-identical whether zero or five nodes are
  attached; per-node tools (`bash_on_proxmox2`) are structurally
  impossible. Schemas compiled-in forever; only **execution routing** is
  dynamic.
- **Roster changes ride messages, not the envelope.** Attach/detach
  appends a short roster message to the transcript (below). Messages are
  append-only content — exactly how conversations already grow — so the
  KV prefix survives every roster change. No invariant amendment is
  needed; the frozen-toolset invariant (bots plan P2) holds unamended.
- **Hydration is unaffected**: env tool names resolve through the compiled
  catalog (`tools.by_names`) exactly like today; a dormant env thread
  hydrates fine with every node offline.

### Roster messages

- Appended as **user-role rows with a display-only author sidecar**
  (the bots P3b `Origin` pattern), author `system`, rendered by the UI as
  a status line, not a chat bubble. They encode through the single
  `nexus/transcript` path like bot-authored user rows — byte
  determinism and replay fall out for free.
- Shape (terse, stable, self-healing — the full attached list is repeated
  so a stale belief corrects on the next event):
  `[system] attached targets: workspace, proxmox-2.`
  The tail-short form (settled in Phase 2a) drops the per-node metadata
  and the direction from the line — the human pane's Environments
  section carries hostname/arch/direction from the event stream, and the
  transcript line keeps only what the model needs: the CURRENT list,
  token-minimal for small context windows. Phase 1 emitted a richer
  creation-time line (`environment attached: "<target>" …`) for the
  workspace seed; Phase 2a normalizes the workspace seed row, attach,
  AND detach to the tail form (the seed row flows through the same
  `roster_attach_text` path, so it changes with the rest).
- **They never trigger a turn.** Roster messages are passive context; the
  agent does not wake on attach (no runaway loops). The user's next Send
  — from web or TUI — carries the turn.
- **Ordering**: the thread actor serializes. A roster change (attach OR
  detach) during an in-flight turn is queued behind it — NEW pending
  machinery beside the existing `Busy` refusal (a late `Send` today is
  rejected, not queued; `utility_pending` is a debounce flag, not a
  queue), and it must queue on the actor side because the worker owns
  the extended transcript mid-turn — an actor-side append before
  `WorkerDone` would be clobbered when the worker installs its
  transcript. The message lands after `WorkerDone` (or `WorkerDown`, for
  a crashed worker, which installs nothing), before the next request is
  built.

### Fail fast (verified against the loop)

Tool errors are NOT loop errors — they become failed tool results and the
round commits (`loop.gleam`, `execute_all`). All failure modes are
ordinary tool results:

- **Unknown target** (detached, typo'd, hallucinated): immediate error
  result — `target "proxmox-2" is not attached. attached targets: workspace` —
  no timeout burn; the model self-corrects next round.
- **Mid-run detach** (node dies mid-command): the adapter's process
  monitor fires — the plugin-api adapter executor arms the monitor before
  dispatch, so a dying provider is answered immediately, no burned
  deadline — and the in-flight call resolves as a failed tool result; a
  cancel notification is best-effort.
- **Call timeout**: per-call wall clock (configurable per tool), rendered
  like any error.

The UI's display-state contract is untouched: committed rounds stay
committed; nothing new rolls back.

### The environment seam (internal)

- `tools.ToolCtx` gains an **environment handle** beside `delivery`
  (same injection point: the registry's per-thread runner wrapper). Env
  tool executors consult it: resolve `target` against the roster, route,
  or fail fast.
- The thread actor owns **roster state** (target → execution subject) and
  the workspace child. Node adapters are owned per-connection by the
  socket handler and register/unregister with the thread actor — the
  `ui_runtime` socket-lifecycle pattern (linked, die together, re-Join
  without duplicate fan-out entries).
- Codemode synergy: env tools in a codemode toolset are ordinary siblings
  (toolset minus codemode), so Lua scripts can `bash` + digest in one
  round trip; `target` is just an argument.
- Remote dispatch rides the provider seam: a node adapter is a named
  provider actor (registered at attach, unregistered at detach) whose
  internal side is `provider.Msg` and whose transport side is the client
  protocol — the plugin-api adapter executor (monitor-before-dispatch,
  demonitor on every non-`Down` exit, the mandatory cancel re-signal,
  per-call deadline) IS the fail-fast machinery above, verbatim. If env
  routing ever needs identity inside a provider call, the route is
  plugin-api phase 3's additive `Call` context growth (thread id,
  environment handle) — not a new protocol field here. (As-built
  delta, 2b-2: "named" became SUBJECT-addressed through the thread
  actor's `target → EnvExec` map — same protocol, same executor —
  because node names are unique per roster, not per instance; see
  Phase 2b-2.)

### The workspace (v1: in-process)

- Per-thread directory under a configurable root
  (`workspace_root: Option(String)`; `None` disables env toolset
  selection at creation — the SearxNG-gating pattern). Path derives from
  the thread id, and the RESOLVED root is frozen per thread at creation
  (persisted on the thread — the frozen-endpoint pattern), so a later
  `workspace_root` change affects new threads only and can never hide
  an existing thread's files or re-aim its commands at another
  directory; lazy creation on first env tool call; retention policy
  deferred (thread deletion exists today — a hard `DELETE /threads/:id`
  cascading `thread_message`, with no workspace-cleanup hook — so without
  a retention/cleanup decision, deleted threads would leave orphaned
  workspace dirs).
- **v1 floor — hygiene, NOT a security boundary.** cwd default +
  per-call wall-clock timeout + kill-tree on cancel (the codemode
  cancel-subject pattern is the template) + hard byte caps enforced
  WHILE READING (port output and file reads capped at accumulation —
  `http_fetch`'s max-bytes pattern; post-hoc truncation does not bound
  memory) + canonical-path confinement for the fs tools
  (`read_file`/`write_file`/`list_dir` resolve against the workspace
  root and refuse escapes). This contains accidents and bounded output,
  not a hostile model: a `bash` command can still reach the host (`cd
  /`, absolute paths, symlinks — cwd confines nothing by itself), so
  until the escalation lands, prompt-injection → host access under the
  nexus user is an accepted, recorded risk of the Pi model on the
  operator's own server. The escalation is container-per-workspace —
  and the **external container workspace** (a
  container that connects in at startup and speaks the node protocol as
  target `workspace`) is the *same protocol participant* as a remote
  node, so the escalation changes deployment, not protocol. Mechanism
  TBD; deliberately not solved in this plan.

### Remote nodes: the TUI client and the client protocol

- **Connectivity**: the TUI dials OUT to nexus over WebSocket (NAT-proof;
  the Codex `exec-server` pattern: outbound-only, token auth, reconnect
  with backoff). Nexus never dials a node.
- **Route** `/node/ws` (authed like other routes; node token). An adapter
  actor `Join`s the thread's event fan-out exactly like a Lustre runtime
  (`Join(sub, visit)` → `Hello` + replay, `turn_view` mirror for mid-turn
  joins) and serves two planes:
  - **Event plane** (server→client): a nexus-owned JSON projection of
    `ThreadEvent` — transcript lines, tool chips, metrics — versioned
    (`"v":1`), additive-only. User input (client→server) rides the same
    socket via the same `Send` path the web UI uses. The TUI is a full
    client: view, type, and execute.
  - **Tool plane** (bidirectional): MCP-shaped JSON-RPC — `tools/call`
    requests down, tool results up, `notifications/cancelled` down — the
    third deployment of the provider protocol: the node adapter translates
    these frames to and from internal `Call` / `Cancelled` (already
    aligned: cancel-as-message, per-call caller-owned reply subject,
    ok/err as a failed tool result). Familiar shapes, zero novel
    semantics; a future standalone MCP listener on the node could share
    the handler.
- **Not Lustre**: Lustre never appears in the path; Lustre upgrades cannot
  break remote clients. Cost: nexus owns a second wire format — same
  discipline as the store seam: owned boundary, versioned deliberately,
  mockable offline.
- **Identity**: stable user-assigned node names (`proxmox-2`), enforced
  unique across the live roster; reconnection with the same name replaces
  the roster entry (idempotent re-attach); a second live connection with
  a live name is refused. `workspace` is reserved.
- **Authorization**: environment-role join is refused on threads whose
  toolset has no env tools ("thread has no workspace toolset" — the
  `UnknownToolset` loud-refusal philosophy). Viewer-role join (no tool
  plane) is allowed on any thread, matching the web UI's read model.
- **Approvals: none.** The Pi model — the agent has free rein on attached
  targets; the human at the terminal watching commands run *is* the
  control surface; users who want gating sandbox the TUI/node itself.
  Nexus adds no approval protocol.

### Auth and persistence for nodes (P2)

New `node` table (schema conventions: singular, unquoted-safe — `node` is
not a Postgres keyword; FK/index naming per AGENTS.md):

- `node.id` (pk), `node.name` (unique, `node_name` index), `node.token_hash`
  (node tokens are distinct from the single UI token — scoped, revocable),
  `node.created_at`, `node.last_seen_at` (`node_recency`).
- **Token authority is instance-wide by design (v1)**: nexus is
  single-user today (one UI token guards the whole web surface), so a
  node token grants exactly what a UI connection grants — join any
  thread as viewer, join env-toolset threads as environment, Send —
  scoped to node operations and revocable per node. Per-thread grants
  and owner binding become REQUIRED the day multi-user accounts exist;
  the join-authorization check is the seam they will extend.
- Pairing UX deferred to P2 detail work (settings surface entry and/or a
  printed `nexus-node pair` bootstrap); the table lands first so tokens
  are verifiable statelessly per connection.

### General MCP (future, owned by the plugin-api plan)

Third-party MCP servers mount **at thread creation only**, never
mid-thread — the generalization is specified in
`docs/plans/plugin-api.md`: an MCP client adapter per configured server
(a config option, not a plugin), `thread.toolset` growing into an ordered
manifest of tagged entries, schema TEXT frozen at create, hydration that
never contacts the server, and boundary validation of `tools/list`
entries. This plan's half of the contract is simply that env tools stay
curated and compiled-in — precisely so hydration never depends on an
external server being online.

## Phases

### Phase 1 — environment seam + in-process workspace (offline-provable) — IMPLEMENTED

As built (see the deltas below the list):

1. Env tools (`bash`, `read_file`, `write_file`, `list_dir`) in the
   compiled catalog, each with `target`; `workspace_root` config
   (`NEXUS_WORKSPACE_ROOT`); `default_names` unchanged (env tools
   opt-in via bot template or create flag — the HTTP create body's
   `tools` field carries it, `UnknownToolset` semantics reused).
2. Workspace execution (port exec with cwd default, timeout,
   kill-on-cancel, byte caps at read, canonical-path fs tools); the
   per-thread frozen workspace root; `ToolCtx` environment handle;
   the roster constant `"workspace"`.
3. Roster messages: system-authored user rows (author sidecar),
   UI status-line rendering, replay path.
4. Tests: `test/env_test.gleam` (executor paths, kill-tree, caps,
   confinement, cancel re-signal); `tools_test` catalog pins;
   `ui_test` status-line + hostile-text pins; `thread_registry_test`
   env create/hydration; `m3_prefix_test` golden untouched.

**As-built deltas** (Phase 1 met code the design predates, plus
mechanics discovered mid-build):

- **No workspace child actor in v1.** The plan's "workspace
  environment actor" and "roster state in the thread actor"
  collapse into nothing measurable for a roster of exactly one:
  the env executors run the port/fs work DIRECTLY in the per-turn
  worker (the codemode engine pattern — cancel selects on the turn
  subject in the executor itself), and the v1 roster is the constant
  `["workspace"]` carried by the handle and the creation-time roster
  message. The thread-actor roster map (target → execution subject)
  and the queued-attach machinery arrive with Phase 2a, the first
  feature that needs live roster state (nodes attach mid-thread).
- **The environment rides `TurnRunner` beside `delivery`** (the bots
  P3c precedent): `tools.ToolCtx` gained `environment:
  Option(env.Environment)`; `loop.run` and the runner type grew one
  parameter each; the registry wraps the cached bundle per thread
  (`env_toolset`), composing with the delivery wrapper (the delivery
  wrap now wraps the CURRENT spec's toolset, not the base bundle —
  composing both was a bug the registry tests would have caught).
- **The kill-tree is `setsid` + pgid-marker + the real `kill`
  binary.** The bash wrapper prints `$$` as the first stdout line and
  runs under `setsid` (so the child is its own group leader); cancel /
  timeout / cap-kill signal the whole GROUP via the PATH-resolved
  `/usr/bin/kill` binary with argv `["-9", "--", "-<pgid>"]` — two
  silent-failure traps found the hard way: procps-ng 4.x parses a
  bare `"-<pgid>"` as another signal spec and exits 0 having killed
  NOTHING (the `--` guard is required), and the detached kill helper
  must WAIT for the kill to act (a helper returning early closes its
  own port and kills the killer mid-flight). `setsid -w` propagates
  the child's exit status (without it a forked setsid exits 0 and
  swallows every non-zero bash status). Without setsid (macOS dev)
  there is no marker and the kill degrades to port_close — the
  documented fallback.
- **The over-cap kill answers Ok**, not an error: the output that
  WAS captured returns as data with an omission note naming the kill
  (the http_fetch truncation posture — the command itself may have
  been nowhere near done). Timeout and cancel remain errors carrying
  their partial output.
- **A bash non-zero exit status is DATA** — `Ok("exit status N\n" <>
  output)` (the http_fetch non-2xx rule: a failing grep or compiler
  is signal for the model, not a transport failure; errors stay for
  nexus-side failures: spawn, timeout, cancel).
- **One timeout knob, not per-tool**: `NEXUS_ENV_TIMEOUT_MS` (floor
  1000) covers `bash`; `NEXUS_ENV_MAX_OUTPUT_BYTES` (floor 1024)
  covers bash output AND `read_file`. Per-tool overrides can grow
  onto the config when a consumer exists.
- **`bot` names reserve `system`**: roster messages ride the origin
  sidecar with author exactly `system`, and the UI branches on that
  string to render a status line — a bot named `system` would have
  its messages render as status lines on every path, so
  `bot.validate_name` refuses it at save.
- **The roster row persists AT INSERT**, in the same statement as the
  thread row (insert_thread's roster CTE): `message_count` seeds the
  write-behind watermark and counts the row, so storing it later would
  make the first commit start PAST it and it would never persist
  (CodeRabbit review — caught live). Every rebuild path (lazy start,
  Down replacement, retry) therefore replays the announcement from the
  stored rows; no in-memory repair exists. Byte-determinism holds
  before the first send because no request was ever built on the
  shorter prefix. Never-used env rows (system + roster = 2) are swept
  past the grace window by the boot prune's env-aware ceiling.
- **Boot's bot-tool validation closure is extracted** into
  `boot.bot_validate_tools(cfg, providers, foreign)` so the env gate
  is offline-testable without starting the tree.
- **Confinement is LEXICAL**: `..` folds against the workspace root,
  absolute paths must already live inside it; symlinks are not
  resolved (the accepted v1 hygiene posture, now pinned by tests).

### Phase 2a — live roster state + attach/detach (this slice)

Sliced from the original Phase 2 for review: this slice owns ONLY the
live-roster machinery — the thing Phase 1's `["workspace"]` constant
was explicitly deferring. The node table, `/node/ws` client protocol,
adapter actor, fake-node e2e, and TUI all move to Phase 2b (unchanged
in substance, re-labelled for the split). Phase 2b needs a roster that
actually routes, so this slice lands first as its own reviewable unit.

**The model-facing-roster decision (settled, token-minimal).** Roster
changes ride MESSAGES, never the envelope — but the model can only act
on what it has IN its window, and the plan's single creation-time
attach line scrolled off long ago. The fix is to keep the roster
**queryable at the committed transcript's tail**: each attach/detach
re-appends one terse user-role, author-`system` status line naming the
CURRENT full attached list, so the newest context the model sees always
names every live target. Terse by rule (one line, `"attached targets:
a, b"`), minimised for small-context local models. Prior roster lines
remain ordinary committed transcript rows — nothing replays a roster
history into the request, so a provider that truncates context to the
tail keeps only the most recent line; a long-context provider simply
carries whichever old rows are still in its window (the same economics
as any other transcript growth). The bot-channels info pane's
Environments section (still plan-only) becomes the HUMAN mirror of the
same state, fed by the same events — it cannot reach the model, so the
tail line is deliberately separate from the click-to-reveal pane.

1. **Live roster state in the thread actor** — the `["workspace"]`
   constant that `env.attached_targets()` reads becomes an actor-owned
   `State` field `roster: List(String)` (stable order, `workspace`
   always first), seeded `["workspace"]` on env-toolset threads and `[]`
   on plain threads. `env.route` gains a `roster` field on the handle
   (a SNAPSHOT — see step 5) so the fail-fast error names a list rather
   than the hard-coded constant; the live wiring is 2b's seam.
2. **Attach / detach actor messages** — `AttachTarget(name)` /
   `DetachTarget(name)` mutate `roster`, fan out a roster event, and
   append the tail roster line (below). `name` charset
   `^[a-zA-Z0-9_-]+$`, `workspace` reserved (refused on attach), no
   duplicate-live attach, no detach of an absent target, and `workspace`
   is never detachable. (Reconnect-replace and the `target → execution
   subject` map arrive with the node adapter in 2b; here the roster is
   names-only — execution routing is still `workspace`-only until 2b
   wires a source.)
3. **The tail roster line** — `attach`/`detach` re-append a user-role,
   `system`-author, stamped status line via the SAME `append_user
   → mark_origin → stamp` path Phase 1 used at creation. Attach and
   detach share one text shape (the terse `attached targets: …` form,
   `roster_attach_text`/`roster_detach_text` slimmed to the tail-short
   wording); the full current list always repeats so a stale belief is
   self-healing. It never triggers a turn.
4. **Queued roster changes behind an in-flight turn** — the NEW pending
   machinery the plan already foretold: an attach OR detach landing
   mid-turn is queued beside the existing `Busy` refusal (a late `Send`
   is rejected, not queued; `utility_pending` is a debounce flag, not a
   queue) and lands AFTER `WorkerDone` (or `WorkerDown`, a crashed
   worker that installs nothing), before the next request is built —
   because the worker owns the extended transcript mid-turn and an
   actor-side append before install would be clobbered.
5. **Dynamic `target` routing into the tool plane (DEFERRED to 2b)** —
   this slice does NOT thread the live roster into `ToolCtx`: the
   `Environment` handle remains a FROZEN per-thread value baked into the
   registry's `env_toolset` runner wrapper (it still carries
   `workspace_root` + `thread_id` + the SEED roster snapshot), so a
   freshly-attached node is not yet routable at execution time. Making
   `ToolCtx.environment` consult a LIVE source (an ask to the thread
   actor, or a shared reference) is the open seam — the design fork is
   recorded, not decided, and it is 2b work alongside the node adapter's
   `target → execution subject` map. The envelope keeps the frozen
   schemas; only EXECUTION routing would become dynamic.
6. **Fail-fast is already correct** — `route`'s unknown-target error
   names the roster the handle carries (the seed snapshot in this
   slice), and an attached-but-unroutable target gets its own honest
   "attached but not routable yet" error rather than a false
   "not attached". Attach/detach are the only new failure shapes; both
   are ordinary tool/actor outcomes, no loop-error or rollback change.

**Tests.** `env_test` keeps the workspace/`route`/confinement/kill-tree
pins and gains: `route` against a NON-constant roster (live-list
passed in), duplicate-live and reserved-name refusal, the tail-line
text shape, and the unknown-target error naming the live list.
`thread_registry_test` covers create seeding `["workspace"]`, and (gated
on step 4) the queued-attach-lands-after-`WorkerDone` ordering.
`ui_test` keeps the status-line rendering pin (the tail line is the
same row shape) and hostile-text for the attach name. `m3_prefix_test`
golden is UNTOUCHED — roster lines are transcript rows through the
single encode path, appended to the tail, committed like any message;
the frozen envelope never changes. `gleam test` stays network-free
(roster is actor state; no WS in this slice).

### Phase 2b — node registry + client protocol + TUI (follow-up)

Sliced for review into 2b-1 (node table + token auth, merged) →
2b-2 (the live-routing execution seam, offline) → 2b-3 (the client
protocol + adapter) → 2b-4 (fake-node e2e) → 2b-5 (the TUI).

**2b-1 — node table + token auth + roster hydration re-derivation —
IMPLEMENTED (#132).** The `node` table (singular, unquoted-safe;
`node_name` unique index, `node_recency`), one-way SHA-256 token
hashing with constant-time verify (`nexus/node`), the store seam
(list/get/insert/touch/delete; revoke = row delete), and the plan's
hydration re-derivation pulled EARLY (it was this phase's own open
note): `ThreadSpec.roster` re-derives the current attached list from
the newest persisted roster row, so a restart no longer re-seeds
`["workspace"]` after nodes attached mid-life. `nexus/node` stays a
leaf (no network, no store, no actor); node names validate through
`env.valid_target_name` (one charset/reserved rule, no drift).

**2b-2 — live target routing: the execution seam (offline-provable).**
The design fork 2a's step 5 recorded as open is DECIDED here — an
ASK, not a shared value or a global name:

- **The thread actor owns the execution map**: `target → EnvExec` —
  the attached node's `(Subject(tool_provider.Msg), Pid)`. The env
  executors' routing ask reaches it through the REGISTRY (`RouteEnv`,
  the `deliver_ask` precedent: a worker-owned reply subject, manual
  send + bounded receive, honest timeout error), never a captured
  thread subject (the runner wrap is built before the actor starts,
  at create and hydrate alike).
- **NOT a globally named provider actor.** The plan's earlier "named
  provider actor" wording predates the collision: node names are
  unique per ROSTER, not per instance — two threads can host
  same-named nodes, so a global name would collide (and
  `process.new_name` counter-suffixing cannot be re-derived anyway).
  The PROTOCOL is still the plugin-api seam — the adapter speaks
  `tool_provider.Msg`, and the adapter executor's
  monitor-before-dispatch / cancel re-signal / per-call deadline
  machinery is reused verbatim through a `run_remote(sub, pid, …)`
  variant that addresses the provider by the map's explicit
  (subject, pid) pair instead of a registered name.
- **The `Environment` handle grows a `remote` router closure**
  (`env.RemoteRouter`: target, tool, arguments, cancel → result),
  injected by the registry's `env_toolset` wrapper exactly like the
  bots-plan `Delivery` closure. The four env executors branch on
  `target`: `workspace` runs the Phase 1 local path unchanged; any
  other target dispatches the WHOLE call (tool name + raw arguments)
  through the router — the node executes the same four tools in ITS
  workspace, so the byte-identical wire schema is what makes this
  routing, never envelope mutation.
- **Execution registers immediately, even mid-turn.** `AttachTarget`
  grows an optional `EnvExec`: the roster line obeys the turn
  ordering (queued behind `WorkerDone`), but the execution map
  mutates at once — routing is not transcript state, nothing to
  clobber. A monitored node's DOWN drops the map entry immediately
  and detaches through the SAME queueing rules as an explicit
  `DetachTarget` (a queued attach followed by a node death drains as
  attach-then-detach lines — the FIFO pending queue already produces
  the honest sequence). In-flight calls answer via the executor's
  monitor: an ordinary failed tool result.
- Refuse-duplicate-live stays (an attach of a live name refuses; the
  old entry's DOWN will detach it). **Replace-on-reconnect arrives
  with the real adapter** (2b-3) — it needs the connection lifecycle
  to be meaningful.
- One knob each, reused: `NEXUS_ENV_TIMEOUT_MS` is the remote call
  deadline; `NEXUS_ENV_MAX_OUTPUT_BYTES` the result truncation cap
  (chars at the adapter boundary — display hygiene; the transport
  itself caps while READING in 2b-3).

**Tests.** `tool_provider_test` pins `run_remote` (ok / err / timeout
/ cancel re-signal / provider death) against a fake subject-owned
actor; `thread_test` pins the map (RouteEnv ask, attach/detach,
DOWN-driven detach, mid-turn DOWN ordering); `thread_registry_test`
pins the registry ask; `env_test` pins the executors' remote branch.
All offline, fake actors only; `m3_prefix_test` untouched.

**2b-3 — `/node/ws` client protocol v1 + node adapter actor —
IMPLEMENTED.** The event projection + tool plane + user-input frames
(`"v":1`, additive-only); token auth on the route (the 2b-1 table);
the adapter actor with socket-linked lifecycle (the `ui_runtime`
pattern) that ATTACHES with its `EnvExec` (consuming this slice's
map), translates client-protocol frames to and from
`tool_provider.Msg`, and handles replace-on-reconnect and
refuse-duplicate-live at the connection level. The
`GET /threads/<id>/state` dump (already shipped, #119) is the
development side channel for the event projection. Fail-fast paths
through the live tool plane are pinned here too (unknown target /
mid-run detach / timeout — tool errors commit; UI unchanged):
`route`'s live-roster error (2a step 1) plus the adapter executor's
monitor-before-dispatch detach-mid-call answer (2b-2's `run_remote`).

**As-built deltas** (2b-3 met code the design predates, plus
mechanics discovered mid-build):

- **The socket-owner process sends every frame; the adapter never
touches the connection.** mist PANICS when a frame is sent from
any process but the socket's owner (permessage-deflate state is
process-local), so the adapter hands finished frame STRINGS to a
`frames` subject the socket process created and selects on
(`mist.Custom`), and the socket loop does the `send_text_frame` —
the `ui_runtime` pattern with the direction inverted. Inbound, the
socket loop decodes client frames and forwards them to the adapter's
subject; undecodable frames answer an `error` frame and keep the
socket. The adapter is linked to the socket process: a crashed
socket or the replace-kill takes the adapter down (the thread actor's
monitor detaches), a crashed adapter takes the socket down (the
node's client reconnects into a fresh pair). The GRACEFUL client
close is the route's `on_close` KILLING the adapter (the
`ui_runtime` `close_socket` rule): an actor's own normal exit does
not rupture links, so the link alone leaves a closed socket's
adapter orphaned and attached — found by the 2b-4 fake node's
detach-mid-call check.
- **Auth is name+token pair-verify, not hash lookup** —
`/node/ws?node=<name>&token=<token>&thread=<id>&role=env|viewer`
(the token also accepted as `Authorization: Bearer`): the named row
loads through the EXISTING `get_node_by_name` and `node.verify_token`
checks it constant-time — zero new store queries, and a wrong name
and a wrong token answer the identical 401 (no oracle). `touch_node`
marks last-seen at the route. Pre-upgrade failures answer as plain
HTTP statuses (401/400/404/403) so a reconnecting client can tell
bad token from bad path; the env-role gate on non-env threads
("thread has no workspace toolset") is a new registry ask
(`thread_registry.env_capable`, read from the record's FROZEN
`spec.toolset` — dormant threads answer without waking).
- **`tools/call` embeds the arguments VERBATIM.** The adapter builds
the frame by string concatenation around the argument bytes (name
JSON-encoded defensively; arguments PROVEN a JSON object by
`node_protocol.valid_arguments` before dispatch — the env executors
only route already-parsed object arguments, and a violation answers
an ordinary ToolErr, never a malformed frame). MCP-shaped, not
MCP-exact: `params.arguments` is the raw object, results flatten to
one text, and a JSON-RPC error-object response decodes as a FAILED
call — a hostile node cannot smuggle a success past a refused call.
- **No adapter-side timers, on purpose.** The executor
(`run_remote`) owns the deadline, monitor, and cancel re-signal; the
adapter keeps none — a wedged node is answered by the executor's
timeout, a dead adapter by its monitor, both as ordinary failed
tool results. Result text caps at the boundary on receipt
(`NEXUS_ENV_MAX_OUTPUT_BYTES` chars); WS frames arrive whole (the
frame is the read unit — mist exposes no mid-frame cap), so the cap
lands on the first nexus-side touch of the node's bytes.
- **Replace-on-reconnect lives in the thread actor, not the
adapter**: an attach CARRYING an execution plane whose name is
already in the effective roster is a reconnection — the old plane's
pid is killed (its linked socket dies with it; in-flight calls
answer through the executor-side monitor), the new plane registers
immediately, and NO roster line lands (the attached list is
unchanged; the model's tail context already names the target). A
name-only attach of a live name still refuses (the 2a rule,
unamended). The stale DOWN is inert: the `WorkerDown` scan matches
entries by pid, and the entry now carries the new one.
- **A minimal node-pairing scripting API landed with the route**
(UI-token-guarded): `GET /nodes` (rows, never the hash), `POST
/nodes {"name":…}` → 201 answering the minted plaintext token
EXACTLY ONCE (32 random bytes, URL-safe base64; only the SHA-256
hash is stored), `DELETE /nodes/<id>` → 204 idempotent revoke. The
settings-surface pairing UX stays plan-deferred — these routes are
the curl/e2e path (the 2b-4 fake node pairs through them). A revoke
is NOT retroactive: a live connection keeps running; reconnects
fail.
- **Offline pins**: `node_protocol_test` (every wire shape, exact
strings), `node_adapter_test` (the actor against a fake thread
speaking real `thread.Msg`: connect sequence, call round trip,
error results, cancel + inert late response, non-object arguments,
the boundary cap, send Sent/Busy/empty, viewer role, foreign-thread
event filter, ListTools refusal, attach-refusal stop),
`thread_test.attach_replaces_live_plane_test` (the replace
semantics), `thread_registry_test.env_capable_ask_test`, and
`web_routes_test` (the pairing round trip + the pre-upgrade
refusals). The upgrade itself is the fake node's to prove (2b-4).

**2b-4 — a headless fake node in `e2e/` — IMPLEMENTED (`e2e/node.spec.mjs`).**
A Node script speaking the client protocol (Node's built-in WebSocket —
zero new dependencies, no Playwright: the browser suite cannot exercise
a TUI, but a raw WS client can). A DEDICATED loopback suite with its
own fake OpenAI SSE provider scripting env-tool turns (`case:nodebash`,
`case:nodehang`) — an as-built delta on "driven by the integration
spec": the live-services smoke needs network and ~10 minutes; this
suite is deterministic, offline-beyond-loopback, and runs in ~1 minute,
which is what a protocol proof loop needs. Ten checks through the REAL
socket and REAL thread actor: pairing via `POST /nodes`; the connect
sequence (hello + replay with the roster lines + attached); a full
remote tool round (arguments VERBATIM on the wire, node result →
committed tool row → the model's round-2 answer embedding the node's
bytes); replace-on-reconnect (old socket dies, NO roster line —
message_count unchanged — new plane serves the next round, graceful
close lands the detach line); detach mid-call (the node drops the
socket with a call in flight → the executor-side monitor answers an
ordinary failed tool result, the round commits, the queued detach line
lands behind the turn); wrong-token 401; env-role 403 on a plain
thread; viewer role (events + send + ping, no `attached`, no tool
plane). It also caught the graceful-close lifecycle hole: see the
on_close delta under 2b-3.

**2b-5 — the TUI itself — IMPLEMENTED as the Gleam REPL proof of
concept.** The language question is decided (a Gleam TUI shares the
codec for free), and the SHAPE is decided too: a line-oriented REPL
now, the high-fidelity client later as a separate initiative (survey
existing coding-agent TUIs and modify one — do not grow this PoC
into it). Ships when the protocol is proven by the fake node — it
was. What landed:

- **The codec is now bidirectional.** `node_protocol` gained the
  client half: `ServerFrame` + `decode_server_frame` (every event
  kind, the connection frames, and the tool plane's request half; an
  unknown KIND decodes as `Unknown` — forward-compatible by rule,
  the renderer skips it; malformed JSON or a malformed KNOWN shape
  refuses), plus the client→server encoders `encode_send` /
  `encode_ping` / `encode_call_response`, all round-trip-pinned
  against the decoders in `node_protocol_test`. One module owns the
  whole wire.
- **`params.arguments` decodes canonically.** The wire carries a RAW
  JSON object (the encoder's verbatim property, unchanged and still
  pinned by the encode tests + the fake-node e2e wire capture); the
  Gleam client decodes the VALUE and re-encodes it compact —
  execution reads values, not bytes. The recursive dynamic→Json
  decoder hit the stdlib's warned-about trap (a self-referential
  decoder constructed eagerly loops forever) — `decode.recursive` is
  load-bearing.
- **`env.serve_node_call` is the node-side twin of remote dispatch.**
  The call arrived HERE because the server routed it to this node, so
  the arguments' `target` names the NODE, not `workspace` — the
  parsed target rewrites to the reserved local value and the Phase 1
  local path runs unchanged (kill-tree, caps while reading, lexical
  confinement inherited, not reimplemented). Unknown tool names
  refuse; `tui_test` / `env_test` drive it with real bash in temp
  workspaces, offline.
- **The connection is a stratus actor obeying the socket-owner rule,
  inverted.** Every frame send happens inside `on_message` (the
  adapter-side lesson mirrored); user messages (stdin lines, finished
  calls, quit) arrive through an actor-owned inbox created in the
  connection's init and handed to main via a main-owned handoff
  subject — the `gated_runner` ownership rule from AGENTS.md (send
  across owners freely, never RECEIVE across them). `tools/call`
  runs in a short-lived worker so a full deadline never stalls the
  render loop; `notifications/cancelled` re-signals the in-flight
  worker's cancel subject from a Dict registry (the codemode rule).
- **Quit closes, then continues — never `stop()`.** `stop()` after
  `close()` killed the actor before the close handshake finished, so
  `on_close` (the halt-0 path) never fired — found by the e2e's
  graceful-exit check. The stdin FFI is `io:get_line` over the group
  leader (`nexus_tui_ffi`), eof modeled as `Error` so piped stdin
  (the e2e) and a TTY take the same path.
- **The renderer is pure**: `ServerFrame → List(Line | Inline)` in
  `nexus/tui/render` — streaming tokens print inline, everything else
  is a truncated display-only line, hostile text stays plain string
  concatenation. Documented PoC jank: output arriving mid-line
  interleaves with the half-typed line, and there is no input
  history.
- **`e2e/tui.spec.mjs` proves the real binary** with piped stdin
  against the fake-provider server (the node.spec.mjs posture):
  join + replay render + server-side attach, a full remote round the
  TUI executes LOCALLY (noncanonical argument JSON proving the value
  round-trip; the command's files land in the TUI's own workspace
  dir), and stdin EOF → exit 0 with the queued detach line behind
  the turn. 5 checks, ~1 minute, offline beyond loopback.

### Phase 3 — deferred (recorded, not scheduled)

- External container workspace speaking the node protocol as `workspace`.
- General MCP mounts at creation — owned by `docs/plans/plugin-api.md`
  phase 2 (ordered manifests, frozen TEXT snapshots, boundary
  validation); nothing left to build here.
- Parallel tool fan-out across targets (today `execute_all` is a
   sequential fold; correct-first).
- Fork/upgrade path for chat-only threads that later want env tools
   (a different-toolset fork already shares no cache spans; the UX is the
   open question).

## Non-goals (recorded, not planned)

- **No mid-thread envelope mutation, ever** — roster changes are messages;
  tools/targets never enter the envelope after creation.
- **No approval protocol** — Pi model; sandboxing is the node operator's
  choice.
- **No ACP** on this path; an ACP front-end adapter is a separate future
  initiative.
- **No agent-mesh features** — nodes are tool executors and clients, not
  peers in bot-to-bot messaging (bots P3 owns that).
- **No nexus→node dialing** — outbound-only from nodes.

## Invariant checklist (what this plan must not break)

- **KV-cache contract**: envelope (`model`, `stream`, `tools`,
  `tool_choice`) frozen per thread; env tools freeze at creation or never
  appear; roster messages are transcript content through the single
  encode path; `m3_prefix_test` golden byte-identical.
- **`thread.toolset` semantics** (bots P2): always resolved names at
  insert; env names refuse loudly at bot save and thread create when
  `workspace_root` is unset; hydration resolves them from the compiled
  catalog.
- **Hostile text**: everything a node reports (metadata, command output,
  errors) renders as Lustre text nodes — truncated, inert previews only;
  node bytes are external provider content, so the plugin-api adapter's
  transport-read byte caps apply, not just post-hoc truncation — and
  the in-process workspace gets the same treatment (port output and
  file reads capped at accumulation, never truncated only after
  receipt).
- **UI display-state mirror**: tool errors commit as failed results; no
  new rollback shape; roster messages replay like any user row.
- **Schema conventions**: singular `node`; unquoted-safe names;
  `<table>_<purpose>` indexes; `timestamptz` only.
- **Offline tests**: `gleam test` stays network-free — node adapter and
  environment both behind subject-based seams; live WS coverage belongs
  to the e2e/integration suites.
- **One Lustre runtime per `/ws` connection**: untouched; `/node/ws` is a
  plain adapter, never a Lustre runtime.
- **Self-hosted assets**: the TUI is a separate program fetching nothing
  from nexus beyond its WS; no CDN creep.
