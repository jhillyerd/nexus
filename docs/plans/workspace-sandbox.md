---
title: Nexus — local workspace sandboxing, lifecycle GC, and shared bot workspaces
status: draft
tags: [computing, self-hosting, local-llm, agents, gleam, beam, environments, security, nixos]
updated: 2026-11-21
---

# Workspace sandbox: isolate local bash, track and GC directories, support persistent bot workspaces

**Thesis.** Phase 1 of the environments plan (`docs/plans/environments.md`)
deliberately shipped local workspaces as hygiene, not a security boundary.
Commit `ad82078` closed the BEAM environment-variable leak (`sandbox_env/1`
in `src/nexus_env_ffi.erl`), but a prompt-injected `bash` call still runs
under the nexus user with read access to sibling thread workspaces and the
host filesystem, unrestricted outbound network access (including loopback
Postgres/Nexus and homelab LAN), and no memory or PID caps. Meanwhile,
workspace directories are derived from `thread.workspace_root` on the fly
with no DB ownership record, so `DELETE /threads/:id` and `prune_never_used`
orphan directories on disk forever.

This plan closes those gaps around four product priorities:

1. **Personal assistant safety** — prompt injection against a bot that
   reads untrusted external inputs must not leak host secrets, sibling
   workspaces, or local services, nor leave persistent host modifications.
2. **Light research ergonomics** — fast startup (~ms, not seconds), easy
   script execution, and common CLI tools (`python3`, `jq`, `curl`, `git`,
   `rg`, etc.).
3. **Scheduled tasks** — unattended server-side execution (ruling out
   laptop/TUI-only workspaces), often needing controlled outbound network
   access and CLI tools, plus an opt-in way for a bot to keep compiled
   tools or state across fresh per-run threads.
4. **Strong NixOS support** — declarative toolchains via `pkgs.buildEnv`,
   first-class systemd cgroup delegation, and zero VM/image maintenance
   overhead (`microvm.nix` is explicitly rejected for v1 due to image/disk
   lifecycle complexity).

Related: #126 (local workspace sandboxing), `docs/plans/environments.md`
(Phase 1 local workspace, Phase 3 escalation seam).

## Vocabulary

- **Sandbox backend** — the OS-level wrapper placed around local workspace
  `bash` execution (`nono` | `bwrap` | `none`). Selected by server config;
  `none` keeps offline tests and unsupported platforms working.
- **Workspace** — a managed directory on disk tracked by a row in the
  `workspace` table (`kind`: `'thread'` | `'bot'` | `'tmp'`), with a
  frozen `root` and relative path (`rel_path`) so lifecycle and crash-safe
  GC never guess paths.
- **Per-thread `/tmp`** — a thread-scoped scratch temp directory (`kind =
  'tmp'`) cleaned up when the thread is deleted, independent of whether
  the thread's main workspace is per-thread or bot-shared. Exists because
  LLMs strongly prefer writing throwaway files to `/tmp` over `$HOME/tmp`.
- **Bot-shared workspace** — opt-in bot setting (`workspace_mode = 'bot'`,
  Option B) where all threads created from that bot reuse a single
  persistent directory (`bots/<bot_id>`) as their `workspace` target,
  while each thread still gets its own ephemeral per-thread `/tmp`.
- **Network tier** — per-bot workspace egress posture (`none` | `proxy` |
  `host`), separating offline personal-assistant bots from network-enabled
  research and scheduled-task bots.

## Threat model and non-negotiables

Primary threat: **prompt injection → hostile `bash` invocation** on the
nexus host.

What local sandboxing MUST stop:

- **Host filesystem reads/writes** outside the thread's workspace and
  per-thread temp dir (no `/home`, `/run/secrets`, host `/etc` secrets,
  sibling thread workspaces, or other bots' workspaces).
- **Loopback / LAN SSRF and blind exfiltration** from `bash` by default
  (no reaching `127.0.0.1:5433` Postgres, Nexus's own HTTP API, metadata
  endpoints, or RFC1918/Tailscale homelab services).
- **Resource exhaustion** (fork bombs, runaway RAM allocation taking down
  the BEAM or host).
- **Process interference** (signaling the BEAM or sibling turn workers).
- **Orphaned disk state** when threads or bots are deleted or boot-pruned.

What is explicitly accepted in this plan (recorded risk):

- **Shared Linux kernel** — both `bwrap` and `nono` share the host kernel
  (unlike KVM/`microvm.nix`). Kernel-escape defense remains a future
  deployment-level escalation over `/node/ws`, not a Phase 1–4 requirement.
- **Cross-thread persistence risk on opt-in bot workspaces** — a writable
  `workspace_mode = 'bot'` directory can carry state from Run N to Run N+1
  (including a poisoned script if Run N is prompt-injected). Mitigated by
  making bot-shared workspaces **opt-in**, keeping standard CLI tools in
  immutable NixOS `workspace.packages`, and documenting an optional future
  read-only scheduled-run mode.

## Phase 0 — Spike: `nono` vs `bwrap` (decision gate)

Before writing production sandbox code in `src/nexus/env.gleam`, run a
time-boxed spike (target: 1–2 hours on Linux/NixOS) comparing **`nono`**
(`nolabs-ai/nono`, Landlock + Seatbelt + built-in egress proxy) against
**`bubblewrap` (`bwrap`)** (Linux mount/PID/net namespaces + Nix
`pkgs.buildEnv`).

Why both are contenders:

| Dimension | `nono` (Landlock + Seatbelt) | `bwrap` (Linux namespaces) |
| --- | --- | --- |
| **NixOS filesystem ergonomics** | High — overlays allow rules onto real paths (`/nix/store` ro, workspace rw); zero synthetic rootfs plumbing | Medium-high once wired by a NixOS module (`--tmpfs /` + `/nix/store` ro + `pkgs.buildEnv` profile), awkward to hand-roll outside Nix |
| **Per-thread `/tmp` at `/tmp`** | **Weak** — no mount namespace; can only deny host `/tmp` and set `TMPDIR=<thread_tmp>` (LLMs hardcoding `/tmp/...` hit `EACCES`) | **Strong** — `--bind <thread_tmp> /tmp` gives every thread a real, isolated, auto-cleaned `/tmp` |
| **Network egress & domain allowlists** | **Strong** — built-in HTTP(S) proxy mode, `--allow-domain`, and proxy-side credential injection | Requires pairing `--unshare-net` with a separate host-side egress proxy (over a bind-mounted Unix socket) |
| **UDP / DNS exfiltration** | Depends on `nono`'s seccomp-bpf layer + Landlock ABI (v4+/v6+); **must verify** | Watertight — `--unshare-net` creates an empty network namespace (zero TCP/UDP/ICMP) |
| **PID isolation & kill-tree** | Shares host PID namespace; relies on Landlock ABI v6 `LANDLOCK_SCOPE_SIGNAL` (Linux 6.12+) + Nexus's existing `setsid`/sentinel kill-tree | Full `--unshare-pid --die-with-parent` (kernel kills every descendant automatically) |
| **macOS & container/Nomad support** | Works on macOS (Seatbelt) and inside containers/Nomad without user namespaces | Linux-only; requires unprivileged userns (fine on NixOS, blocked by AppArmor/container policies in some environments) |
| **Resource caps (RAM / PIDs)** | Neither provides cgroup caps alone — both pair with systemd `Delegate=cpu memory pids` or `prlimit` | Same |

### Spike checklist (pass/fail criteria)

Run each check against a real NixOS host (and document kernel version +
Landlock ABI):

1. **Startup & per-call latency**: measure 20 consecutive `bash` tool
   invocations (`true`, `python3 -c 'print(1)'`) under `nono` (`--block-net`
   and `--allow-domain` proxy mode) vs `bwrap`. Target: < 50 ms p95 per
   call so multi-step research loops stay snappy.
2. **Stdio, cancel, and kill-tree compatibility**: verify `nono` and `bwrap`
   both pass through Nexus's first-line PID marker, `stderr_to_stdout`,
   partial output on timeout/cancel, and leave zero orphan `sleep 60`
   grandchildren after port close / kill.
3. **Host isolation verification**:
   - Cannot read `/run/secrets`, `~/.ssh`, host `/etc/shadow`, or a sibling
     thread workspace.
   - Cannot write outside `<thread_workspace>` and `<thread_tmp>`.
   - Cannot `kill` the parent/sibling process (`LANDLOCK_SCOPE_SIGNAL` on
     `nono`, `--unshare-pid` on `bwrap`).
4. **Network & exfiltration verification**:
   - In offline mode (`--block-net` / `--unshare-net`): TCP connect to
     loopback (`127.0.0.1:5433`), LAN, and public IP fails; **UDP / DNS
     (`python3` UDP socket to `1.1.1.1:53` / `dig`) also fails**.
   - In proxy/allowlist mode: `curl` / `python3` / `git` reach an allowed
     domain; disallowed domains, loopback, and RFC1918 IPs fail.
5. **Per-thread `/tmp` behavior**:
   - Confirm whether `nono` has any mount/remap mechanism or if `TMPDIR`
     alone causes friction with common LLM commands (`cat > /tmp/x.py`).
   - Evaluate whether a **hybrid** (`bwrap` for mount/PID/`/tmp` +
     `nono` or a tiny host-side HTTP CONNECT proxy for egress) is simpler
     or over-engineered compared to picking one primary backend.
6. **NixOS packaging**: confirm `nono` builds cleanly from its flake on
   current `nixpkgs-unstable` without fragile native build hacks.

**Spike deliverable:** record measurements and the backend decision
(`nono`, `bwrap`, or `bwrap` + proxy / pluggable backend) in an "As-built
spike results" section appended to this doc before starting Phase 2.

---

## Design

### 1. Schema: `workspace` table + crash-safe disk GC

Schema follows `AGENTS.md` rules verbatim: singular table name
(`workspace`), unquoted-safe column names (verify against live Postgres
before landing), `timestamptz` timestamps, `<table>_<purpose>` indexes,
`ON DELETE SET NULL` tombstones so disk paths survive owner deletion until
GC completes.

```sql
CREATE TABLE IF NOT EXISTS workspace (
  id           text PRIMARY KEY,
  kind         text NOT NULL,       -- 'thread' | 'bot' | 'tmp'
  root         text NOT NULL,       -- frozen resolved NEXUS_WORKSPACE_ROOT
  rel_path     text NOT NULL,       -- relative to root (e.g. 'threads/<id>', 'bots/<id>', 'tmp/<id>'); never absolute or '..'
  thread_id    text REFERENCES thread(id) ON DELETE SET NULL,
  bot_id       text REFERENCES bot(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL,
  last_used_at timestamptz,
  deleted_at   timestamptz          -- NULL = live; non-NULL = tombstoned awaiting disk rm -rf
);

CREATE UNIQUE INDEX IF NOT EXISTS workspace_path
  ON workspace (root, rel_path);

CREATE INDEX IF NOT EXISTS workspace_thread
  ON workspace (thread_id)
  WHERE thread_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS workspace_bot_live
  ON workspace (bot_id)
  WHERE kind = 'bot' AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS workspace_pending_gc
  ON workspace (deleted_at)
  WHERE deleted_at IS NOT NULL;
```

Links on `bot` and `thread` (land as a new sequential migration under
`sql/migrations/` — e.g. `0002_workspace_sandbox.sql` — with `CREATE TABLE
workspace` and `ALTER TABLE bot` / `ALTER TABLE thread` plus the backfill
for existing `thread.workspace_root` rows):

```sql
ALTER TABLE bot
  ADD COLUMN workspace_mode    text NOT NULL DEFAULT 'thread',   -- 'thread' (fresh per thread) | 'bot' (shared across this bot's threads)
  ADD COLUMN workspace_net     text NOT NULL DEFAULT 'none',     -- 'none' (offline bash) | 'proxy' (egress proxy + optional allowlist) | 'host' (explicit opt-in)
  ADD COLUMN workspace_domains text[] NOT NULL DEFAULT '{}';     -- domain allowlist for workspace_net = 'proxy' ('{}' = public internet via SSRF-checked proxy)

ALTER TABLE thread
  ADD COLUMN workspace_id      text REFERENCES workspace(id) ON DELETE SET NULL,
  ADD COLUMN tmp_workspace_id  text REFERENCES workspace(id) ON DELETE SET NULL,
  ADD COLUMN workspace_net     text NOT NULL DEFAULT 'none',     -- frozen from bot at thread creation
  ADD COLUMN workspace_domains text[] NOT NULL DEFAULT '{}';     -- frozen from bot at thread creation
```

**Why `workspace` is a separate table instead of relying on `thread.workspace_root`:**

- **Cascade safety:** deleting a parent thread cascades through
  `thread.parent_thread_id` to every child bot-channel thread. Without a
  durable `workspace` record tombstoned before/with the delete, child
  channel directories orphan silently.
- **Crash durability:** if `rm -rf` fails or Nexus restarts mid-delete,
  the `deleted_at IS NOT NULL` tombstone persists in Postgres and finishes
  on the next boot sweep.
- **Backward compatibility:** legacy Phase 1 threads have directories at
  `<workspace_root>/<thread_id>`. Migration backfills a `kind = 'thread'`
  row with `rel_path = thread.id` and wires `thread.workspace_id` so
  existing directories are tracked and GC'd cleanly without moving a
  single file on disk. New rows use structured `rel_path` prefixes
  (`threads/<id>`, `bots/<id>`, `tmp/<id>`).
- **Self-contained threads invariant preserved:** per `AGENTS.md`, deleting
  a bot sets `thread.bot_id = NULL` and must never break existing threads.
  Accordingly, a `kind = 'bot'` workspace is tombstoned **only** when its
  bot is deleted **and** no live `thread` still references it via
  `thread.workspace_id` — or when the last remaining thread referencing
  an orphaned (`bot_id IS NULL`) bot workspace is deleted.

### 2. Workspace creation and cleanup lifecycle

#### Creation (at thread create when env tools are in the frozen toolset)

- **Main workspace (`thread.workspace_id`):**
  - If `bot.workspace_mode == 'thread'`: create a `workspace` row
    (`kind = 'thread'`, `root = cfg.workspace_root`,
    `rel_path = "threads/" <> thread_id`, `thread_id = Some(thread_id)`).
  - If `bot.workspace_mode == 'bot'`: find-or-create the bot's live
    `kind = 'bot'` workspace row (`root = cfg.workspace_root`,
    `rel_path = "bots/" <> bot_id`, `bot_id = Some(bot_id)`) via
    `INSERT ... ON CONFLICT (bot_id) WHERE kind = 'bot' AND
    deleted_at IS NULL DO NOTHING` followed by a re-select, so the loser
    of a concurrent create reuses the winner's row instead of failing
    thread creation (matching the store's `on conflict ... do nothing`
    idiom).
- **Per-thread temp dir (`thread.tmp_workspace_id`):**
  - Always create a `workspace` row (`kind = 'tmp'`,
    `root = cfg.workspace_root`, `rel_path = "tmp/" <> thread_id`,
    `thread_id = Some(thread_id)`).
  - Even for `workspace_mode = 'bot'`, every thread gets its own isolated
    temp dir that dies with the thread.
- **Lazy disk creation stays:** directories are still created lazily on
  first env tool call (`ensure_workspace`), so threads that never invoke
  an env tool create zero directories (and GC treats `ENOENT` as success).

#### Deletion & GC (persistence-first, matching archive/delete discipline)

1. **`delete_thread` (including bot-channel subtree):**
   - In one SQL statement (recursive CTE over `parent_thread_id`), collect
     the deleted thread subtree, tombstone every owned `kind IN ('thread',
     'tmp')` workspace row (`SET deleted_at = now(), thread_id = NULL` so
     the subsequent `DELETE FROM thread` triggers no conflicting FK
     update), delete the root `thread` row (cascading channels), and
     tombstone any `kind = 'bot'` workspace whose `bot_id IS NULL` and
     that now has zero referencing threads. Return the tombstoned
     `#(id, root, rel_path)` list.
   - Registry stops/kills live actors in the subtree first (existing
     behavior), ensuring no in-flight `bash` worker recreates files in
     the directory.
   - Spawn an unlinked background cleanup task that runs the guarded
     recursive remove on each tombstoned path, then hard-deletes each
     `workspace` row on `Ok` / `ENOENT` (logging and leaving the tombstone
     for boot sweep on any filesystem error).
2. **`prune_never_used` (boot sweep):**
   - Extend `prune_never_used.sql` to tombstone owned `workspace` rows for
     pruned threads in the same statement.
3. **`delete_bot`:**
   - Tombstone the bot's `kind = 'bot'` workspace if no `thread` rows
     currently reference it; otherwise clear `bot_id = NULL` and let the
     last referencing thread's delete tombstone it.
4. **Boot GC sweep (`sweep_deleted_workspaces`):**
   - Runs at startup right beside `prune_never_used`: reads every
     `workspace` row with `deleted_at IS NOT NULL`, removes the directory
     if present, and hard-deletes the row on success (`Ok` or `ENOENT`).
5. **Path-safety guard before any `rm -rf`:**
   - Reject blank `root` or `rel_path`, reject `rel_path` starting with
     `/` or containing `..` segments, and verify the canonical joined path
     is strictly a descendant of `root` (never `root` itself). Refuse and
     log on any violation.

### 3. Per-thread `/tmp` + Option B bot-shared workspace UX

- **Environment variables inside `bash`** (extending `sandbox_env/1` in
  `src/nexus_env_ffi.erl`):
  - `HOME` → main workspace dir (thread dir or bot-shared dir, or
    `/workspace` under a mount namespace).
  - `TMPDIR` → per-thread temp dir (or `/tmp` when bind-mounted under
    `bwrap`).
  - `PATH` → configured workspace toolchain path (plus `$HOME/bin` optional
    or documented for bot-compiled tools).
- **With `bwrap` (mount namespace):**
  - `--bind <main_workspace_dir> /workspace` (`--chdir /workspace`,
    `HOME=/workspace`)
  - `--bind <thread_tmp_dir> /tmp` (`TMPDIR=/tmp`)
  - LLMs writing to `/tmp/scrape.py` automatically land in the per-thread
    temp dir, isolated from other threads and deleted with the thread.
  - Files saved in `/workspace` (cwd / `$HOME`) persist across threads for
    `workspace_mode = 'bot'` bots and are wiped on thread delete for
    `workspace_mode = 'thread'` bots.
- **With `nono` (Landlock, no mount namespace):**
  - Allow rw on `<main_workspace_dir>` (`cwd` and `HOME`) and
    `<thread_tmp_dir>` (`TMPDIR`); deny host `/tmp`.
  - Phase 0 spike explicitly evaluates whether hardcoded `/tmp` paths in
    LLM-authored scripts are an acceptable trade-off or push us toward
    `bwrap` (alone or composed).
- **FS tools (`read_file`, `write_file`, `list_dir`):**
  - Unchanged semantics! They continue confining lexically to the thread's
    resolved main workspace directory (which is `<root>/threads/<id>` for
    `'thread'` mode or `<root>/bots/<bot_id>` for `'bot'` mode). No new
    target names or envelope changes are needed.

### 4. Per-bot network policy (solving personal assistant vs scheduled tasks)

Network policy is configured on the **bot** and frozen onto the thread's
runtime environment at creation (or hydrated from the thread/bot config —
to keep threads self-contained even after bot edits/deletes, freeze
`workspace_net` and `workspace_domains` on `thread` at creation, matching
`system_prompt` and `workspace_root`!).

- **`none` (default):**
  - No outbound network from `bash`.
  - Best default for personal assistant bots: they can still run Python/jq
    on local files and use Nexus's SSRF-guarded `web_search` / `http_fetch`
    tools when enabled, without exposing arbitrary `curl` exfiltration.
- **`proxy`:**
  - Direct TCP/UDP/ICMP from `bash` is blocked.
  - HTTP/HTTPS traffic routes through a host-side egress proxy (either
    `nono`'s built-in proxy or a lightweight host proxy over a bind-mounted
    Unix socket for `bwrap`).
  - Proxy enforces **SSRF protection unconditionally** (reject loopback,
    link-local/metadata, RFC1918, and ULA/CGNAT/Tailscale ranges, reusing
    the same private-IP rules as `nexus/net.is_private_address` — the
    guard `nexus/http_fetch` delegates to), plus optional per-bot
    `workspace_domains` allowlisting.
  - Ideal for scheduled tasks and light research (`curl`, `python3`,
    `git`, `gh`, `uv`).
- **`host` (explicit opt-in):**
  - Unrestricted outbound networking from `bash` (filesystem, env-scrub,
    and process/resource limits still enforced).
  - Escape hatch for bots that need non-HTTP protocols (`ssh`, raw TCP,
    homelab administration).

### 5. Resource caps & NixOS packaging

- **Resource caps:**
  - Server config knobs (with sane defaults): per-command memory cap
    (e.g. `NEXUS_WORKSPACE_MAX_MEMORY_MB`, default `1024`), PID cap
    (`NEXUS_WORKSPACE_MAX_PIDS`, default `64`), CPU time / existing
    wall-clock timeout (`bash` timeout already exists).
  - Primary enforcement on Linux/systemd: run `nexus.service` with
    `Delegate=cpu memory pids` so each sandboxed command runs inside a
    transient sub-cgroup (`memory.max`, `pids.max`).
  - Lightweight fallback when cgroup delegation isn't available:
    `prlimit` for `RLIMIT_CPU` / `RLIMIT_FSIZE` / `RLIMIT_AS` (deliberately
    NOT `RLIMIT_NPROC` when sharing UID with the BEAM).
- **NixOS module (`nixosModules.default` in `flake.nix`):**
  - `services.nexus.workspace.enable`
  - `services.nexus.workspace.sandbox` (`"nono"` | `"bwrap"` | `"none"`,
    defaulting to the Phase 0 winner)
  - `services.nexus.workspace.packages` (default curated research set:
    `bash`, `coreutils`, `gnugrep`, `gnused`, `gawk`, `findutils`, `jq`,
    `curl`, `git`, `ripgrep`, `python3`, `sqlite`, `cacert`) → built via
    `pkgs.buildEnv` into one immutable store profile passed to Nexus.
  - `systemd.services.nexus` configured with `Delegate=cpu memory pids`,
    dedicated `nexus` user / `StateDirectory=nexus`, strict systemd
    hardening (`ProtectSystem=strict`, `ProtectHome=true`,
    `PrivateTmp=true`, `NoNewPrivileges` tuned carefully so sandbox helper
    works), and `ReadWritePaths` scoped to the workspace root.

## Phased rollout

### Phase 0 — Spike (`nono` vs `bwrap`)
- Run the 6-item spike checklist on NixOS, record latency, UDP/DNS
  blocking, kill-tree behavior, and `/tmp` ergonomics.
- Decide primary backend (and whether to keep both behind a small
  `Sandbox` config enum).

### Phase 1 — `workspace` table + crash-safe GC + per-thread `/tmp`
- Schema additions (`workspace`, `thread.workspace_id`,
  `thread.tmp_workspace_id`, backfill for existing `thread.workspace_root`
  rows) + Squirrel regen (`gleam run -m squirrel`).
- `store.Store` seam + mock (`test/store_mock.gleam`) updates.
- Tombstone on `delete_thread` (with recursive channel subtree),
  `prune_never_used`, and boot-time `sweep_deleted_workspaces`.
- Guarded `rm -rf` helper + offline unit tests covering cascade delete,
  interrupted delete recovery on boot, and path-traversal refusal.
- Wire `TMPDIR` to the per-thread `tmp` directory even before sandboxing
  lands.

### Phase 2 — Sandbox execution wrapper + resource caps
- Add sandbox config in `src/nexus/config.gleam` (`NEXUS_WORKSPACE_SANDBOX`,
  toolchain profile path, cgroup/rlimit caps).
- Integrate the chosen Phase 0 wrapper into `bash_workspace` in
  `src/nexus/env.gleam` + `src/nexus_env_ffi.erl`, preserving:
  - allowlist env scrub (`sandbox_env/1`),
  - first-line PID marker / cancel / timeout / partial output,
  - byte-capped streaming read,
  - offline `gleam test` (unsandboxed fallback + sandbox integration
    tests gated on an explicit opt-in env var, never binary-on-PATH
    detection, so the default suite stays deterministic and offline).
- Bind-mount or wire per-thread `/tmp` per Phase 0 decision.

### Phase 3 — Per-bot policies: network tiers + Option B bot-shared workspace
- Schema additions on `bot` (`workspace_mode`, `workspace_net`,
  `workspace_domains`) and frozen counterparts on `thread`
  (`workspace_net`, `workspace_domains`).
- Bot settings UI + HTTP validation (reject invalid mode/net/domain
  entries loudly).
- Wire `workspace_mode = 'bot'` creation/hydration and safe bot-delete GC
  (ref-checked against remaining threads).
- Wire `none` / `proxy` / `host` egress enforcement (using `nono`'s proxy
  or a host-side SSRF-checked Unix-socket proxy if `bwrap` wins Phase 0).

### Phase 4 — NixOS module & packaging
- Add `packages.<system>.default` and `nixosModules.default` to
  `flake.nix` (`services.nexus` with `workspace.packages`, sandbox binary,
  `Delegate=cpu memory pids`, and hardened systemd unit).
- Document NixOS setup and scheduled-task bot recipes in `docs/`.

## Open questions (to resolve during Phase 0–3)

1. **Mount namespace + `nono` composition:** If `nono`'s proxy + domain
   allowlist is great but lack of a real `/tmp` mount namespace trips up
   LLM scripts, can `bwrap` wrap `nono` cleanly (or is `bwrap` + a small
   dedicated egress proxy cleaner)? Answer in Phase 0.
2. **Concurrent runs on `workspace_mode = 'bot'`:** If two threads of the
   same bot run `bash` simultaneously in `bots/<bot_id>`, is "last write
   wins, use `/tmp` for per-run scratch" sufficient, or do we eventually
   want a per-bot lock or read-only mode for scheduled runs? Default to
   per-thread `/tmp` + shared `/workspace` first; revisit only if real
   scheduled tasks collide.
3. **Archived thread workspace retention:** Phase 1 cleans up on hard
   delete and `prune_never_used`. Should archived threads eventually GC
   their `kind = 'tmp'` (or `'thread'`) dirs after a configurable TTL?
   Easy additive query on `workspace` later; deferred from Phase 1.
4. **Proxy credential injection:** If `nono` wins Phase 0, its proxy can
   inject API secrets without exposing them to `bash`. Keep out of v1
   scope (avoid expanding the secret-management surface before basic
   egress filtering is proven), but note it as a natural follow-up for
   scheduled tasks.

## Non-goals

- **No KVM / `microvm.nix` orchestration in Nexus** — too much image,
  disk-space, and NixOS host complexity for v1. Users who want a VM
  boundary can still connect a VM as a remote node over `/node/ws`
  (`docs/plans/environments.md`).
- **No Docker socket access from Nexus** — never hand the BEAM privileges
  to spawn containers.
- **No mid-thread envelope mutation** — workspace mode, sandbox backend,
  and network policy never enter the LLM request envelope or change tool
  schemas (KV-cache contract untouched).
- **No approval prompts for `bash`** — Nexus stays on the Pi model;
  safety comes from hard OS isolation and per-bot capability tiers, not
  interactive click-through prompts (which also cannot work for scheduled
  tasks).

## Invariant checklist (what this plan must not break)

- **KV-cache byte contract (`m3_prefix_test`):** `workspace`,
  `workspace_mode`, `workspace_net`, `workspace_domains`, and
  `tmp_workspace_id` are execution/lifecycle metadata only — never request
  bytes, never tool-schema changes.
- **Schema conventions (`AGENTS.md`):** singular `workspace`; unquoted-safe
  names verified against live Postgres; `timestamptz` only;
  `<table>_<purpose>` indexes; `squirrel check` clean.
- **Self-contained threads:** deleting a bot never breaks or deletes the
  workspace of a live thread still referencing it; changing
  `NEXUS_WORKSPACE_ROOT` never re-aims an existing thread's `workspace.root`.
- **Bot-channel delete & boot sweep:** deleting a parent thread tombstones
  cascaded channel workspaces; `prune_never_used` still skips parents with
  channel children (`not exists (...)`) and tombstones pruned threads'
  workspaces atomically.
- **Cancel & kill-tree discipline:** executor still selects over
  `{port data, cancel, deadline}`, re-signals the one-shot cancel subject,
  and leaves zero orphan processes; byte caps remain enforced while
  reading.
- **Offline `gleam test`:** persistence and registry tests run through
  `test/store_mock.gleam` with zero database or network calls; local
  `bash` tests stay offline in temp dirs.
- **Hostile text:** sandbox stderr/errors flow through the same capped
  lossy text path and render only as inert Lustre text nodes.
