---
title: Nexus workspace sandbox — nono vs bwrap spike (Phase 0 research note)
status: decided
 decision: bwrap primary backend, pluggable Sandbox enum, nono as egress-tier alternate
tags: [computing, self-hosting, local-llm, agents, gleam, beam, security, nixos, landlock, bubblewrap, nono]
updated: 2026-11-21
---

# nono vs bwrap for local workspace sandboxing

> **Decision (2026-11-21): `bwrap` is the primary sandbox backend**, kept pluggable
> behind the planned `Sandbox` config enum (`bwrap` | `nono` | `none`), with `nono`
> retained as a fully supported alternate and the likely backend for the `proxy`
> network tier (shared `nono proxy` + `nono wrap --allow-connect-port`). The plan in
> `docs/plans/workspace-sandbox.md` proceeds with Phase 1 unchanged; Phase 2 carries
> the embedding contract recorded below. Everything here is the research record.

Spike for `docs/plans/workspace-sandbox.md` Phase 0 (decision gate), run 2026-11-21
on the real target host (`boss`, NixOS 26.05, kernel 6.18.59, Landlock **ABI 7**
active in `/sys/kernel/security/lsm`; nono reports "Landlock V7, enforcing V6" —
signal + abstract-UNIX-socket scoping both enforced; unprivileged userns enabled).
Binaries: `nono 0.82.0` (from github:numtide/llm-agents.nix), `bubblewrap 0.12.0`
(nixpkgs channel, built offline in 1.4 s). The toolchain profile (`pkgs.buildEnv`
of bash, coreutils, gnugrep, gnused, gawk, findutils, jq, curl, gitMinimal,
ripgrep, python3, sqlite, cacert, util-linux, procps) also builds offline in
seconds. Every check ran against nexus's EXACT spawn shape
(`setsid -w bash -c "<marker prelude><cmd>"` from `bash_workspace`, with the
scrubbed env) so wrapper compatibility is measured, not assumed.

## 1. Startup & per-call latency (20 consecutive calls, p50/p95)

| variant | `true` | `python3 -c 'print(1)'` |
| --- | --- | --- |
| baseline (today, no sandbox) | 2.3 / 2.4 ms | 14.8 / 15.0 ms |
| `nono wrap --block-net` | 6.5 / 6.6 ms | 16.9 / 19.0 ms |
| `nono run --block-net` (supervised, `--no-rollback --no-audit`) | 29.4 / 31.4 ms | 37.8 / 39.9 ms |
| `nono run --allow-domain` (per-call proxy boot) | **241 / 247 ms** | — |
| `nono wrap` + shared standalone `nono proxy` | 6.5 / 6.6 ms | — |
| `bwrap` (`--tmpfs /`, `--unshare-net`, `--unshare-pid`, `--die-with-parent`) | 4.4 / 4.6 ms | 16.9 / 17.0 ms |

**Verdict: PASS (< 50 ms p95) for every shape except `nono run` with a per-call
proxy boot (~210 ms extra).** The proxy must be a long-lived shared process
(see §4b) or egress-mode threads pay ~240 ms per call.

## 2. Stdio, cancel, kill-tree

All four variants (baseline included) pass the marker through as the first
stdout line (`nono` needs `-s` to keep its banner off stdout; `bwrap` adds
nothing), merge stderr into stdout, deliver partial output on kill, and leave
**zero orphan `sleep 60` grandchildren** after group-kill, stdin-close (the
owner-death sentinel fires correctly inside every sandbox — `kill -0 $$` and
`kill -9 -- -$$` work under Landlock signal scoping and inside the pid
namespace), and direct-child kill.

**bwrap amendment (load-bearing):** under `--unshare-pid` the marker is an
IN-NAMESPACE pid (observed: `2`). Nexus's host-side `kill -9 -- -<marker>`
(the `kill` binary spawned by the BEAM) then aims at an unrelated host process
group — observed harmlessly `ESRCH` here, but it is a collateral-risk no-op by
design. The correct kill path under bwrap is the DIRECT child (bwrap itself) —
which `port_close` already does — plus `--die-with-parent`; verified to reap
the whole namespace (orphans: NONE). Phase 2 must suppress the host-side group
kill (treat `kill_group` as `False`) for pid-namespace backends.

## 3. Host isolation

| probe | `nono wrap` | `nono run` | `bwrap` |
| --- | --- | --- | --- |
| read sibling thread workspace | blocked | blocked | blocked |
| read `~/.ssh` key material | blocked | blocked | n/a (`/home` absent) |
| write outside workspace root | blocked | blocked | blocked |
| write real `$HOME` | blocked | blocked | blocked |
| `kill -9` an outside process | **blocked (EPERM, Landlock V6 signal scoping)** | blocked | blocked (pid invisible) |

Baseline (today) fails every one of these — the recorded #126 exposure.
`bwrap --tmpfs /` additionally makes `/etc`, `/run`, `/home` nonexistent rather
than merely unreadable.

## 4. Network & exfiltration

### a) Offline mode

`nono --block-net`: TCP connect to loopback (`127.0.0.1:5433` Postgres),
public IP, and LAN all fail with `EPERM`; UDP is stronger than expected —
`socket(AF_INET, SOCK_DGRAM)` itself fails `EPERM` (seccomp baseline), so there
is no raw UDP exfil path. **However `gethostbyname()` still resolves** — nono
deliberately keeps the host resolver working under `--block-net` (it survives
even `--isolate net`, so it rides nono's own machinery, not the network), and
no profile knob to disable it exists in the 0.82.0 schema. This is a residual
DNS channel (data can leave encoded in queries) that the checklist's "DNS must
fail" criterion expected to close. `bwrap --unshare-net` is watertight: no
TCP, no UDP, no DNS (empty netns; loopback refuses). **bwrap passes the
offline criterion in full; nono passes except for the resolver channel.**

### b) Proxy/allowlist mode

`nono run --allow-domain example.com`: allowed domain fetches return `200`;
denied domains fail closed; RFC1918 (`192.168.1.1`) and link-local metadata
(`169.254.169.254`) are answered by nono's proxy itself with `403 Forbidden:
host … is not in the allowlist` — a built-in SSRF guard, requests never leave.
`git` works through the proxy (plain allow-domains ride a CONNECT tunnel, no
MITM, so the scrub env must NOT point `SSL_CERT_FILE` at a bundle that hides
the system CA). Per-call proxy boot costs ~210 ms, so the winning shape is a
**shared standalone `nono proxy`** (started once per bot policy) plus
`nono wrap --block-net --allow-connect-port <proxy-port>` with `HTTP(S)_PROXY`
env: measured **6.6 ms p95**, same allowlist + SSRF posture, direct
loopback/Postgres still `EPERM`. Two caveats: the proxy must run with auth
(session token) in production, and `--allow-connect-port` is port-scoped with
no address scoping in Landlock V4+ — a sandboxed process can open a raw TCP
channel to ANY host on exactly that port (verified: LAN connect returned
`ConnectionRefused`, not `EPERM`). Pick an unguessable fixed port and record
the channel as accepted residual risk, or accept the 240 ms per-call session
proxy.

For bwrap the egress story is the mirror image: `--unshare-net` also isolates
the host loopback, so a shared proxy is unreachable without extra plumbing (a
bind-mounted UNIX-socket proxy bridged by an in-namespace `socat` listener
would work; curl cannot speak UNIX-socket proxies directly). Not built in this
spike — Phase 3 design work.

## 5. Per-thread `/tmp`

Confirmed: nono has **no mount/remap mechanism** (`--isolate` covers
net/ipc/uts only, and is not offered on `wrap` at all). Worse than the plan's
assumption: nono auto-grants **`w /tmp` (host, shared)** via its
`system_write_linux` group — hardcoded `/tmp` writes land in the shared host
`/tmp` (never GC'd, cross-thread visible), and `filesystem.deny` does NOT
override the group grant (verified: the write landed). The viable posture is a
profile with `groups.exclude: ["system_write_linux"]` plus explicit
`--allow-file /dev/null /dev/zero /dev/full`: `/dev/null` keeps working,
`/tmp` becomes a hard `EACCES`, `TMPDIR` works. So under nono the
LLM-friction trade-off is real but bounded: `$TMPDIR`-aware commands work,
hardcoded `/tmp/...` fails loudly. `bwrap --bind <thread_tmp> /tmp` gives
exactly the desired semantics (verified: the file appears in the thread's tmp
dir on the host) — zero friction, and the plan's per-thread `/tmp` design
works as-written.

## 6. NixOS packaging

`nono` is IN nixpkgs (0.61.1 — lags upstream), builds from its own flake
`github:nolabs-ai/nono` on the current channel (Rust, vendored cargo deps;
spike aborted the compile on time-box, dependencies all resolved), and 0.82.0
ships via github:numtide/llm-agents.nix. `bubblewrap` 0.12.0 builds from the
nixpkgs channel offline in ~1.4 s. The `pkgs.buildEnv` research toolchain is
trivial. Both backends are first-class NixOS citizens; the flake can pin nono
from upstream and bwrap from nixpkgs.

## Embedding findings (nono-specific, Phase 2 must honour)

- **State-root protection shapes the spawn chain.** nono refuses any grant
  containing `$HOME/.nono` or `$XDG_STATE_HOME/nono`. Since nexus's scrub sets
  `HOME=<workspace>` and grants that same dir, the wrapper chain would always
  be refused ("overlaps protected nono state root" — cost the spike ~30 min to
  diagnose). Contract: spawn the wrapper with `HOME=<nexus state dir outside
  all grants>` and redirect `XDG_{STATE,CACHE,CONFIG,DATA}_HOME` there; the
  bash prelude then re-exports `HOME=<workspace>` / `TMPDIR=<thread tmp>` as
  its first (silent) statement. Spawn-shape change only — zero request bytes.
- nono needs `--read /nix/store` (Landlock EXECUTE right) — the auto system
  paths grant individual files, not the store.
- First-ever run on cold state demands `--allow-cwd` in non-interactive mode
  even when cwd is already granted — pass it unconditionally.
- `-s` suppresses even fatal sandbox errors (rc=1, empty output) — the
  executor must surface wrapper failures by exit code, not text.
- Resource caps (`--memory`, `--max-processes`, cgroup v2) **fail closed**
  without a delegated cgroup subtree ("refusing to run unconfined") — they
  need exactly the `Delegate=cpu memory pids` systemd unit Phase 4 specifies;
  under a non-delegated login they error rather than degrade.
- Workspace roots must live outside `/tmp` and `/var/tmp` for nono (protected
  state roots) — production puts `NEXUS_WORKSPACE_ROOT` in `/var/lib/nexus`
  anyway.

## Why bwrap (against the plan's four priorities)

1. **Personal-assistant safety**: `--unshare-net` is the only offline posture
   with NO residual DNS channel; pid+mount namespaces give process
   interference and filesystem hiding by construction rather than by policy
   list.
2. **Research ergonomics**: fastest wrapper (+2 ms), and the per-thread `/tmp`
   bind is exactly the LLM-ergonomics design in the plan's §3 — no
   `EACCES`-on-`/tmp` friction, no TMPDIR discipline required.
3. **Scheduled tasks / egress**: the one place bwrap is weaker (loopback proxy
   unreachable under `--unshare-net`). Resolution deferred to Phase 3: either
   the socat/UNIX-socket bridge noted in §4b, or — simpler — the `proxy` net
   tier runs the **nono** wrapper (`nono wrap --block-net
   --allow-connect-port` + shared `nono proxy`, 6.6 ms p95, SSRF-guarded
   allowlists, credential-injection future) while `none`/`host` tiers stay
   bwrap. Per-tier backend selection is a config knob, not an architecture
   change, because both wrappers reproduce nexus's spawn shape verbatim.
4. **NixOS**: both packages are trivial; the flake pins bwrap from nixpkgs and
   (if the proxy tier ships) nono from upstream.

Hybrid question (plan Open question 1) answered empirically: `bwrap` around
`nono` is NOT needed. The composition that exists and measures well is
`nono wrap` + shared `nono proxy` (validated end-to-end in §4b); if
bwrap-primary ships, egress is the nono shape at the net tier, not a nesting
of wrappers.

## Reproduction (exact shapes)

Toolchain profile:

```bash
nix-build -E 'with import <nixpkgs> {}; buildEnv { name = "ws-tools";
  paths = [ bash coreutils gnugrep gnused gawk findutils jq curl gitMinimal
            ripgrep python3 sqlite cacert util-linux procps ]; }' -o toolchain
nix-build '<nixpkgs>' -A bubblewrap -o bwrap-result
```

Both wrappers wrap nexus's existing `setsid -w <bash> -c "<prelude><cmd>"`
unchanged (the prelude gains a leading `export HOME=<ws> TMPDIR=<thread_tmp>; `
under nono only). Wrapper env: `HOME=<state dir outside grants>`,
`PATH=<toolchain>/bin`, `XDG_*` redirected into the state dir.

```bash
# nono (offline posture; profile nexus = { groups.exclude: [system_write_linux] })
nono wrap -s --block-net --allow-cwd -p nexus \
  --allow-file /dev/null --allow-file /dev/zero --allow-file /dev/full \
  --allow <workspace> --allow <thread_tmp> --read /nix/store -- \
  setsid -w <toolchain>/bin/bash -c '<prelude><cmd>'

# nono (egress tier; shared proxy started once with the bot's allowlist profile)
nono proxy --listen 127.0.0.1 --port <P> --pass <token> -p <allowlist-profile> &
nono wrap -s --block-net --allow-connect-port <P> <...as above...> -- \
  setsid -w <toolchain>/bin/bash -c '<prelude><cmd>'   # + HTTP(S)_PROXY env

# bwrap (offline posture)
bwrap --tmpfs / --ro-bind /nix/store /nix/store --dev /dev --proc /proc \
  --ro-bind <toolchain>/etc/ssl /etc/ssl \
  --bind <workspace> /workspace --chdir /workspace --bind <thread_tmp> /tmp \
  --unshare-net --unshare-pid --die-with-parent -- \
  setsid -w <toolchain>/bin/bash -c '<prelude><cmd>'   # HOME=/workspace in env
```

nono profiles used (`$XDG_CONFIG_HOME/nono/profiles/`):

```json
{ "meta": { "name": "nexus" }, "groups": { "exclude": ["system_write_linux"] } }
{ "meta": { "name": "proxy" }, "network": { "allow_domain": ["example.com"] } }
```

The driving harness (marker parse, killpg / stdin-close emulation matching
BEAM port semantics, latency percentiles) was session-local; the shapes above
are sufficient to re-run every check by hand.
