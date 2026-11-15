---
title: Nexus — environments (bot workspaces + remote paired TUI nodes)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, environments]
updated: 2026-11-15
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
  are **never in the default toolset**: a config flip must not change the
  default envelope (same reasoning as the SearxNG gate on `web_search`).
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
  `[system] environment attached: "proxmox-2" (linux/x86_64, hostname pve2). attached targets: workspace, proxmox-2.`
  and symmetrically for detach: `[system] environment detached: "proxmox-2". attached targets: workspace.`
- **They never trigger a turn.** Roster messages are passive context; the
  agent does not wake on attach (no runaway loops). The user's next Send
  — from web or TUI — carries the turn.
- **Ordering**: the thread actor serializes. An attach during an
  in-flight turn is queued behind it — NEW pending machinery beside the
  existing `Busy` refusal (a late `Send` today is rejected, not queued;
  `utility_pending` is a debounce flag, not a queue), and it must queue
  on the actor side because the worker owns the extended transcript
  mid-turn — an actor-side append before `WorkerDone` would be clobbered
  when the worker installs its transcript. The message lands after
  `WorkerDone`, before the next request is built.

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
  environment handle) — not a new protocol field here.

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
  and the queued-attach machinery arrive with Phase 2, the first
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
- **The roster row persists with the first commit**, not at insert:
  it rides the registry-built starting transcript, and the write-
  behind lane lands it with the first `Send` — before any request is
  built nothing was ever sent, so hydration byte-determinism cannot
  observe the gap (a create-then-crash-before-send thread loses the
  status line in its empty replay and is swept by the boot prune as
  never-used).
- **Boot's bot-tool validation closure is extracted** into
  `boot.bot_validate_tools(cfg, providers, foreign)` so the env gate
  is offline-testable without starting the tree.
- **Confinement is LEXICAL**: `..` folds against the workspace root,
  absolute paths must already live inside it; symlinks are not
  resolved (the accepted v1 hygiene posture, now pinned by tests).

### Phase 2 — node registry + client protocol + TUI

1. `node` table + migrate + squirrel queries; token auth for `/node/ws`.
2. Client protocol v1 (event projection + tool plane + user input);
   adapter actor with socket-linked lifecycle, registered as a named
   provider actor at attach (the plugin-api seam); attach/detach roster
   mechanics incl. replace-on-reconnect and refuse-duplicate-live.
3. Fail-fast paths for unknown target / mid-run detach / timeout through
   the live tool plane (tool errors commit; UI unchanged).
4. A headless **fake node** in `e2e/` (Node script speaking the client
   protocol) driven by the integration spec — the browser suite cannot
   exercise a TUI, but a raw WS client can: attach, receive events, serve
   a call, detach mid-call.
5. The TUI itself (separate binary, language TBD — the protocol is JSON;
   a Gleam TUI could share decode types). Ships when the protocol is
   proven by the fake node.

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
