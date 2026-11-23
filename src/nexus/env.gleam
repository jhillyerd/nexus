//// The environment domain (docs/plans/environments.md, Phase 1): the
//// place where environment tools execute, addressed from a frozen
//// toolset by a `target` string.
////
//// The v1 environment is the thread's own **workspace** — a
//// per-thread directory under a configurable root, resolved and FROZEN
//// per thread at creation (persisted as `thread.workspace_root`), with
//// lazy directory creation on first use. The four compiled-in tools
//// (`bash`, `read_file`, `write_file`, `list_dir`) are ordinary
//// catalog names — never in the default toolset, selected at creation
//// via a bot template or an explicit create toolset — and every one
//// takes `target` as a free string, so the wire schema is
//// byte-identical whether zero or five environments are attached:
//// only EXECUTION routing is dynamic, never the envelope.
////
//// The roster for v1 is the constant `["workspace"]` (nodes arrive
//// with Phase 2). Routing therefore resolves exactly one target and
//// fails fast on anything else — the error repeats the full attached
//// list so a stale belief self-heals on the next event. All failure
//// modes are ordinary tool results (tool errors are not loop errors):
//// the round commits and the model self-corrects.
////
//// v1 floor — hygiene, NOT a security boundary. cwd default +
//// per-call wall-clock timeout + kill-tree on cancel (setsid + pgid
//// on Linux; port_close-only fallback elsewhere) + byte caps
//// enforced WHILE READING (port output and file reads capped at
//// accumulation — post-hoc truncation does not bound memory) +
//// LEXICAL canonical-path confinement for the fs tools (symlinks can
//// still escape) + an ALLOWLIST child environment (PATH passthrough,
//// HOME rewritten to the workspace, TZ and CA-path vars when set —
//// the FFI's sandbox_env; `bash` never inherits the BEAM's secrets) (`bash`
//// can still reach the host filesystem and network as this uid —
//// the recorded accepted risk of the Pi model on the operator's own
//// server, #126's remaining work).
////
//// Process model: executors run inside the per-turn worker (the
//// codemode pattern). `bash` spawns a port owned by the calling
//// process and blocks in a select over {port data, turn cancel
//// subject, wall-clock deadline} — cancel kills the tree and
//// RE-SIGNALS the one-shot cancel subject (the codemode rule the
//// loop's LAST-call path depends on). The fs tools are direct file
//// I/O through simplifile + a capped-read FFI.
////
//// This module is deliberately a LEAF on the nexus side (stdlib +
//// filepath + simplifile + the tiny `nexus/timing` clock; the
//// ToolSpec assembly lives in `nexus/tools`, which imports this
//// module — the codemode↔tools cycle rule). It never imports
//// `nexus/tools`, `nexus/loop`, or any actor module.

import filepath
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glopenai/chat
import glopenai/shared.{FunctionObject}
import nexus/timing
import simplifile

// ---------------------------------------------------------------------------
// The environment handle and the roster
// ---------------------------------------------------------------------------

/// The per-thread environment handle carried by `tools.ToolCtx`
/// (injected by the registry's per-thread runner wrapper — the same
/// injection point as the bots-plan `Delivery` identity). Carries the
/// FROZEN resolved workspace root (persisted at creation, so a later
/// config change can never re-aim an existing thread's files), the
/// thread id (the per-thread directory derives from it), and the
/// ROSTER — the list of attached targets `route` resolves against.
///
/// Phase 2a: `roster` is a SNAPSHOT, seeded `["workspace"]` at
/// create/hydrate — NOT yet refreshed from the thread actor's live
/// roster (that is 2b's open seam: threading a live source through
/// `ToolCtx`). `route` therefore fails fast on every non-`workspace`
/// target, naming the snapshot's list in the error.
/// The remote dispatch seam (environments plan Phase 2b-2): one call
/// of an env tool against a NON-workspace target, executed by the
/// attached node. Receives the target name, the UNQUALIFIED tool name
/// ("bash", "read_file", …), the tool's RAW argument JSON, and the
/// turn's cancel subject; answers with the tool result — `Ok`/`Error`
/// exactly like a local execution (an `Error` is a failed tool result,
/// never a loop error). Built by the registry's `env_toolset` wrapper
/// (the bots-plan `Delivery` pattern): it asks the REGISTRY for the
/// target's execution plane and runs the provider-protocol adapter
/// executor against it, all inside the per-turn worker. Structural on
/// purpose — the handle stays a plain value this leaf module can
/// define without importing the seam that produces it.
pub type RemoteRouter =
  fn(String, String, String, Subject(Nil)) -> Result(String, String)

/// The per-thread environment handle carried by `tools.ToolCtx`
/// (injected by the registry's per-thread runner wrapper — the same
/// injection point as the bots-plan `Delivery` identity). Carries the
/// FROZEN resolved workspace root (persisted at creation, so a later
/// config change can never re-aim an existing thread's files), the
/// thread id (the per-thread directory derives from it), the ROSTER
/// seed snapshot, and — Phase 2b-2 — the `remote` router closure every
/// non-`workspace` target dispatches through.
///
/// `roster` remains the SEED snapshot (`["workspace"]` at
/// create/hydrate): live routing consults the thread actor through the
/// `remote` ask, never this list — it stays for `route`'s local
/// fail-fast text and as a value the offline tests can build by hand.
pub type Environment {
  Environment(
    workspace_root: String,
    thread_id: String,
    /// Relative path beneath `workspace_root` (workspace-sandbox plan
    /// Phase 1): `"threads/<id>"` for new thread workspaces, `"bots/<id>"`
    /// for shared bot workspaces, or `<id>` for legacy Phase 1 rows.
    /// `None` falls back to `thread_id` (legacy fixtures and TUI nodes).
    workspace_rel_path: Option(String),
    /// Relative path beneath `workspace_root` for the thread's isolated
    /// scratch temp directory (e.g. `"tmp/<id>"`). `None` for legacy
    /// Phase 1 rows without a managed `tmp` workspace and TUI nodes.
    tmp_rel_path: Option(String),
    roster: List(String),
    remote: Option(RemoteRouter),
  )
}

/// The executor fork every env tool takes after parsing its arguments
/// (Phase 2b-2): `None` means `workspace` — the LOCAL Phase 1 path in
/// this thread's own workspace continues; `Some(result)` is the call's
/// FINAL result, dispatched WHOLE (tool name + raw arguments) to the
/// attached node through the handle's router — the node executes the
/// same four tools in ITS workspace, which is why the byte-identical
/// wire schema makes this routing, never envelope mutation. A handle
/// with no router wired (a hand-built test value; production wraps
/// always wire one) fails fast with the honest not-routable wording,
/// not a "not attached" lie about a name the live roster may carry.
fn remote_result(
  environment: Option(Environment),
  target: String,
  tool: String,
  arguments: String,
  cancel: Subject(Nil),
) -> Option(Result(String, String)) {
  case target {
    "workspace" -> None
    _ ->
      case environment {
        None -> Some(Error("this thread has no environment attached"))
        Some(env) ->
          case env.remote {
            Some(router) -> Some(router(target, tool, arguments, cancel))
            // No router wired (a hand-built test value; production
            // wraps always wire one): fall through to the LOCAL path —
            // `route` answers with the honest roster-naming error.
            None -> None
          }
      }
  }
}

/// The complete v1 attached-target list, in stable order. `workspace`
/// is the reserved target for the thread's own workspace — the only
/// environment selected at thread creation. This is the SEED for a
/// fresh environment handle's `roster` (attach/detach grows the live
/// list from here in Phase 2a).
pub fn attached_targets() -> List(String) {
  ["workspace"]
}

/// The four compiled-in environment tool names — the single source the
/// catalog's `is_env_name` (and, through it, `tools.catalog_names`)
/// derives from.
pub fn tool_names() -> List(String) {
  ["bash", "read_file", "write_file", "list_dir"]
}

/// True for the four compiled-in environment tool names (the catalog's
/// `is_compiled_name` lookup delegates here).
pub fn is_env_name(name: String) -> Bool {
  list.contains(tool_names(), name)
}

/// The thread's workspace directory: `<root>/<rel_path>` (falling back to
/// `<root>/<thread_id>` when `workspace_rel_path` is `None` or fails lexical
/// validation). Mirrors `workspace_gc.safe_target_path`'s guard on `rel_path`
/// so use-time and GC-time invariants agree. Lazy — nothing creates it until
/// the first environment tool call (`ensure_workspace`).
pub fn workspace_dir(env: Environment) -> String {
  let rel = case env.workspace_rel_path {
    Some(candidate) ->
      case safe_rel_path(candidate) {
        Ok(valid) -> valid
        Error(Nil) -> env.thread_id
      }
    None -> env.thread_id
  }
  filepath.join(env.workspace_root, rel)
}

/// The thread's per-thread temp directory: `Some("<root>/<tmp_rel_path>")`
/// when `tmp_rel_path` is `Some` and passes lexical validation, otherwise
/// `None` (legacy Phase 1 rows without a `tmp` workspace row, TUI nodes, or
/// malformed `rel_path` values). Mirrors `workspace_dir` and
/// `workspace_gc.safe_target_path` so use-time and GC-time invariants agree.
/// Lazy — nothing creates it until `bash` runs (`ensure_tmp_dir`).
pub fn tmp_dir(env: Environment) -> Option(String) {
  case env.tmp_rel_path {
    Some(candidate) ->
      case safe_rel_path(candidate) {
        Ok(valid) -> Some(filepath.join(env.workspace_root, valid))
        Error(Nil) -> None
      }
    None -> None
  }
}

/// Lexical check for a `workspace.rel_path` value: non-empty, no NUL bytes,
/// relative (no leading `/`), no `..` segments, and does not collapse to `.`.
pub fn safe_rel_path(rel_path: String) -> Result(String, Nil) {
  let trimmed = string.trim(rel_path)
  case
    trimmed == ""
    || string.contains(rel_path, "\u{0}")
    || string.starts_with(rel_path, "/")
    || filepath.is_absolute(rel_path)
    || {
      rel_path
      |> string.split("/")
      |> list.any(fn(segment) { segment == ".." })
    }
  {
    True -> Error(Nil)
    False ->
      case normalize(rel_path) {
        "" -> Error(Nil)
        normalized -> Ok(normalized)
      }
  }
}

/// The roster message appended to the transcript when a target
/// attaches or detaches (environments plan: roster changes ride
/// MESSAGES, never the envelope, so the KV prefix survives every
/// roster change). Terse by rule — the full CURRENT attached list
/// repeats on every line so a stale belief self-heals on the next
/// event, and the model's tail context always names every live
/// target. Token-minimal for small-context local models. Appended as
/// a user-role row with the display-only author sidecar `system`;
/// never triggers a turn.
///
/// The two directions share ONE shape (the tail-short form, settled
/// in Phase 2a): `[system] attached targets: workspace, proxmox-2.`
/// Attach and detach both emit it AFTER mutating the roster, so the
/// line always describes the post-change state; the direction is NOT
/// in the text (the human pane learns it from the event stream). The
/// `target` argument is reserved for the caller-side reason / for
/// 2b's named-node audit and is deliberately unused in the line — the
/// FULL post-list is what self-heals, not the delta.
pub fn roster_attach_text(target: String, attached: List(String)) -> String {
  let _ = target
  roster_line(attached)
}

/// The symmetric detach text — same tail-short shape (see
/// `roster_attach_text`).
pub fn roster_detach_text(target: String, attached: List(String)) -> String {
  let _ = target
  roster_line(attached)
}

/// The one roster-line shape emitted on every attach/detach: a terse
/// repetition of the CURRENT attached-target list, self-healing and
/// tail-addressable.
fn roster_line(attached: List(String)) -> String {
  "attached targets: " <> string.join(attached, ", ") <> "."
}

/// The roster-line prefix — the discriminator a hydration-side reader
/// uses to recognise a persisted roster row (author `system` AND content
/// carrying this prefix) among the transcript's user rows.
pub const roster_prefix = "attached targets: "

/// Parse a roster line back into its target list (the inverse of
/// `roster_line`). `None` when the text is not a roster line (it does
/// not carry `roster_prefix`). Used by the hydration re-derivation
/// (environments plan Phase 2b): the newest persisted roster row names
/// the CURRENT live list, so a restart rebuilds the actor's roster
/// from the transcript tail instead of re-seeding `["workspace"]`.
/// The empty list `[]` (a plain thread with no attached targets) parses
/// back as `[]` — distinct from `None` (not a roster line).
pub fn roster_parse(text: String) -> Option(List(String)) {
  case string.starts_with(text, roster_prefix) {
    False -> None
    True -> {
      // Strip the prefix, then a trailing '.' if the line carries one,
      // then split on "," + trim each name (hand-crafted whitespace
      // cannot leak a bad name).
      let names =
        text
        |> string.drop_start(up_to: string.length(roster_prefix))
        |> strip_trailing_dot
        |> string.split(",")
        |> list.map(string.trim)
        |> list.filter(fn(n) { n != "" })
      Some(names)
    }
  }
}

fn strip_trailing_dot(s: String) -> String {
  case string.ends_with(s, ".") {
    True -> string.drop_end(s, up_to: 1)
    False -> s
  }
}

/// Validate a proposed node/roster target name before it enters the
/// live roster (environments plan Phase 2a): the plugin tool-name
/// charset plus `@` (so a node can register as `user@host`),
/// `workspace` reserved (it is the thread's own environment and never
/// attaches/detaches), no empty name. Refusal is loud and honest — no
/// name enters the roster that would be ambiguous in `route`'s error
/// or a roster line.
pub fn valid_target_name(name: String) -> Result(Nil, String) {
  case name {
    "" -> Error("target name must not be empty")
    "workspace" -> Error("target name 'workspace' is reserved")
    _ ->
      case string.split(name, "") |> list.all(fn(c) { is_name_char(c) }) {
        True -> Ok(Nil)
        False ->
          Error(
            "target name must match ^[a-zA-Z0-9_@-]+$ (got \"" <> name <> "\")",
          )
      }
  }
}

fn is_name_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@-",
    c,
  )
}

// ---------------------------------------------------------------------------
// Wire schemas
// ---------------------------------------------------------------------------

const target_param =
  "{\"target\":{\"type\":\"string\","
  <> "\"description\":\"Where to execute: the attached environment's"
  <> " name (\\\"workspace\\\" for this thread's workspace)\"}"

fn env_schema(
  name name: String,
  description description: String,
  parameters_json parameters_json: String,
) -> chat.ChatCompletionTool {
  let parameters = case json.parse(parameters_json, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: name,
    description: Some(description),
    parameters: parameters,
    strict: None,
  ))
}

/// The `bash` tool's wire schema.
pub fn bash_schema() -> chat.ChatCompletionTool {
  env_schema(
    name: "bash",
    description: "Run a bash command in an attached environment's working"
      <> " directory. stdout and stderr are combined; a non-zero exit"
      <> " status rides the result. Output is byte-capped and wall-clock"
      <> " time-limited; a timed-out or cancelled call reports its partial"
      <> " output.",
    parameters_json: "{\"type\":\"object\",\"properties\":"
      <> target_param
      <> ",\"command\":{\"type\":\"string\",\"description\":\"The bash"
      <> " command line to run\"}},\"required\":[\"target\",\"command\"],"
      <> "\"additionalProperties\":false}",
  )
}

/// The `read_file` tool's wire schema.
pub fn read_file_schema() -> chat.ChatCompletionTool {
  env_schema(
    name: "read_file",
    description: "Read a text file from an attached environment's"
      <> " workspace. Paths resolve against the workspace directory;"
      <> " escapes are refused. Non-UTF-8 bytes are decoded lossily.",
    parameters_json: "{\"type\":\"object\",\"properties\":"
      <> target_param
      <> ",\"path\":{\"type\":\"string\",\"description\":\"File path,"
      <> " relative to the workspace (or absolute inside it)\"}},"
      <> "\"required\":[\"target\",\"path\"],\"additionalProperties\":false}",
  )
}

/// The `write_file` tool's wire schema.
pub fn write_file_schema() -> chat.ChatCompletionTool {
  env_schema(
    name: "write_file",
    description: "Write a text file into an attached environment's"
      <> " workspace, creating parent directories as needed. Paths"
      <> " resolve against the workspace directory; escapes are refused.",
    parameters_json: "{\"type\":\"object\",\"properties\":"
      <> target_param
      <> ",\"path\":{\"type\":\"string\",\"description\":\"File path,"
      <> " relative to the workspace (or absolute inside it)\"},"
      <> "\"content\":{\"type\":\"string\",\"description\":\"The full file"
      <> " content to write\"}},\"required\":[\"target\",\"path\","
      <> "\"content\"],\"additionalProperties\":false}",
  )
}

/// The `list_dir` tool's wire schema.
pub fn list_dir_schema() -> chat.ChatCompletionTool {
  env_schema(
    name: "list_dir",
    description: "List an attached environment's workspace directory"
      <> " (or a subdirectory of it): entries sorted by name,"
      <> " directories suffixed with '/'. Paths resolve against the"
      <> " workspace directory; escapes are refused.",
    parameters_json: "{\"type\":\"object\",\"properties\":"
      <> target_param
      <> ",\"path\":{\"type\":\"string\",\"description\":\"Directory path"
      <> " relative to the workspace; omit for the workspace root\"}},"
      <> "\"required\":[\"target\"],\"additionalProperties\":false}",
  )
}

// ---------------------------------------------------------------------------
// Execution: target routing shared by every tool
// ---------------------------------------------------------------------------

/// Resolve `target` against the handle's roster and return the routed
/// environment, or the fail-fast error (no timeout burn — the model
/// self-corrects next round). `workspace` is the only target that
/// routes to execution in this slice (2b wires remote nodes' execution
/// subjects). A name IN the roster but not `workspace` fails fast too
/// — "attached but not routable yet" — so the error never claims a
/// listed target is absent; a name NOT in the roster reports the full
/// attached list so a typo'd or detached target self-heals next event.
pub fn route(
  environment: Option(Environment),
  target: String,
) -> Result(Environment, String) {
  case environment {
    None -> Error("this thread has no environment attached")
    Some(env) ->
      case target {
        "workspace" -> Ok(env)
        _ ->
          case list.contains(env.roster, target) {
            // Attached by name, but the execution subject does not exist
            // until 2b wires the node adapter — honest about WHY it
            // cannot route, and not a "not attached" lie.
            True ->
              Error(
                "target \""
                <> target
                <> "\" is attached but not routable (its node is not"
                <> " connected)",
              )
            False ->
              Error(
                "target \""
                <> target
                <> "\" is not attached. attached targets: "
                <> string.join(env.roster, ", "),
              )
          }
      }
  }
}

/// Create the workspace directory (idempotent). Called before every
/// environment operation — the lazy-create rule.
pub fn ensure_workspace(env: Environment) -> Result(Nil, String) {
  case simplifile.create_directory_all(workspace_dir(env)) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error("workspace unavailable: " <> simplifile.describe_error(error))
  }
}

/// Create the thread's per-thread temp directory (idempotent) when one is
/// configured on `env`. Called lazily before spawning `bash`, returning
/// `Ok(Some(path))` when ready or `Ok(None)` when the environment carries no
/// managed temp dir (legacy rows and TUI nodes).
pub fn ensure_tmp_dir(env: Environment) -> Result(Option(String), String) {
  case tmp_dir(env) {
    None -> Ok(None)
    Some(dir) ->
      case simplifile.create_directory_all(dir) {
        Ok(Nil) -> Ok(Some(dir))
        Error(error) ->
          Error(
            "workspace tmp unavailable: " <> simplifile.describe_error(error),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Execution: bash
// ---------------------------------------------------------------------------

/// Extra bytes past the cap that may accumulate before the kill
/// fires: the cap bounds accumulation at read, this slack keeps the
/// kill off the chunk boundary (the buffer never exceeds cap + one
/// chunk + slack).
const cap_slack_bytes = 4096

/// How long to wait for a killed child's `exit_status`: the group
/// kill lands in milliseconds; a bounded wait reaps the port instead
/// of queueing garbage in the worker.
const reap_ms = 1000

/// How long a kill path waits for the still-pending pid marker before
/// giving up on a targeted kill (CodeRabbit review): the wrapper prints
/// it before running anything, so it arrives within milliseconds —
/// unless the child never started, in which case there is nothing to
/// kill. Killing with NO target degrades to port_close, which kills
/// nothing (verified), so the brief wait trades a sliver of latency for
/// an armed kill.
const marker_wait_ms = 250

type PortEvent {
  Data(BitArray)
  Exited(Int)
}

type SelectMsg {
  Port(PortEvent)
  Cancelled
}

/// The bash watchdog's mail (CodeRabbit review): the parsed pgid once
/// the marker arrives, and the all-done notice when the bash loop
/// returns on any path.
type WatchMsg {
  WatchPgid(Int)
  WatchDone
}

/// What the watchdog selects over: its gate or the owner's DOWN.
type WatchEvent {
  Gate(WatchMsg)
  OwnerDown
}

/// The first-stdout-line state machine (the kill-tree marker):
/// `Pending` — under the setsid wrapper, the pid line is still to
/// come; `Leader(n)` — parsed, the child is its own group leader and
/// `kill_tree` may signal the whole group; `Absent` — no marker is
/// expected (wrapperless fallback) OR the first line was not one (a
/// bash that syntax-errored before `printf` ever ran) — in both cases
/// the kill degrades to port_close and every byte is ordinary output.
/// The distinction matters because a parse failure must NOT re-arm
/// `Pending`: the swallowed-diagnostic bug (smart-loop S1) was exactly
/// that — an unparseable first line consumed itself and every
/// successor as marker attempts.
type Marker {
  MarkerPending
  MarkerLeader(Int)
  MarkerAbsent
}

type BashState {
  BashState(
    /// Bytes not yet through first-line parsing (non-empty only while
    /// the marker is `Pending`).
    head: BitArray,
    /// The marker state (see `Marker`).
    marker: Marker,
    /// Collected output bytes past the marker (cap-checked).
    out: BitArray,
    /// Whether the over-cap kill already fired.
    killed: Bool,
  )
}

// ---------------------------------------------------------------------------
// Sandbox configuration & spawn planning (workspace-sandbox plan, Phase 2)
// ---------------------------------------------------------------------------

/// Local workspace `bash` sandbox backend (mirrors `config.WorkspaceSandbox`
/// so this leaf module stays independent of `nexus/config`).
pub type SandboxBackend {
  SandboxNone
  SandboxBwrap
  SandboxNono
}

/// Execution-time sandbox & resource-cap parameters for local workspace `bash`.
pub type SandboxConfig {
  SandboxConfig(
    backend: SandboxBackend,
    sandbox_bin: Option(String),
    toolchain: Option(String),
    state_dir: Option(String),
    max_memory_mb: Int,
    max_pids: Int,
  )
}

/// Unsandboxed default matching Phase 1 / offline tests / TUI remote nodes.
pub fn default_sandbox() -> SandboxConfig {
  SandboxConfig(
    backend: SandboxNone,
    sandbox_bin: None,
    toolchain: None,
    state_dir: None,
    max_memory_mb: 1024,
    max_pids: 64,
  )
}

/// How the BEAM kills a bash process tree on cancel, timeout, output cap, or
/// owner death:
/// - `KillGroup`: host PID namespace under `setsid`; marker PID is a host pgid.
/// - `KillPid`: host PID namespace without `setsid`; marker PID is the direct
///   child's host PID.
/// - `KillPortOsPid`: inside a PID namespace (`bwrap --unshare-pid`); the
///   stdout marker PID is in-namespace (e.g. `2`), so host-side `kill` MUST
///   NOT target it (Phase 0 spike amendment). Instead, kill the port's direct
///   host OS PID (`bwrap` itself) + `port_close`, letting `--die-with-parent`
///   reap the entire PID namespace atomically.
pub type KillMode {
  KillGroup
  KillPid
  KillPortOsPid
}

/// Pure, inspectable spawn specification built by `build_spawn_plan`.
pub type SpawnPlan {
  SpawnPlan(
    exe: String,
    argv: List(String),
    allow_env: List(#(String, String)),
    passthrough_env: List(String),
    kill_mode: KillMode,
  )
}

/// Host filesystem & PATH probes injected into `build_spawn_plan` so offline
/// unit tests can pin NixOS, FHS, cgroup, and `prlimit` spawn plans without
/// requiring `bwrap` or `nono` on the test machine.
pub type HostProbe {
  HostProbe(
    resolve: fn(String) -> Result(String, Nil),
    is_executable: fn(String) -> Bool,
    path_exists: fn(String) -> Bool,
    is_dir: fn(String) -> Bool,
    inherited_path: String,
    cgroup_dir: Option(String),
  )
}

/// Single-file write limit under `prlimit` fallback (256 MiB): large enough
/// for datasets/SQLite/builds while preventing runaway disk writes.
const prlimit_fsize_bytes = 268_435_456

const default_passthrough_env = ["TZ", "SSL_CERT_FILE", "SSL_CERT_DIR"]

/// The `nono` profile written lazily into `<state_dir>/config/nono/profiles/`
/// (Phase 0 spike §5): excludes `system_write_linux` so hardcoded host `/tmp`
/// writes fail closed (`EACCES`) instead of leaking into shared host `/tmp`.
const nono_nexus_profile_json =
  "{\"meta\":{\"name\":\"nexus\"},\"groups\":{\"exclude\":[\"system_write_linux\"]}}\n"

/// POSIX single-quote escaping for shell embedding (`'foo'\''bar'`).
pub fn shell_single_quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\"'\"'") <> "'"
}

/// Lazily prepare `<state_dir>` subdirectories and the `nexus` profile for
/// `nono` (Phase 0 embedding contract).
pub fn ensure_nono_state(state_dir: String) -> Result(Nil, String) {
  let subdirs = [
    filepath.join(state_dir, "state"),
    filepath.join(state_dir, "cache"),
    filepath.join(state_dir, "config/nono/profiles"),
    filepath.join(state_dir, "data"),
  ]
  use _ <- result.try(
    list.try_each(subdirs, fn(dir) {
      simplifile.create_directory_all(dir)
      |> result.map_error(fn(e) {
        "bash: nono state dir unavailable: " <> simplifile.describe_error(e)
      })
    }),
  )
  let profile_path = filepath.join(state_dir, "config/nono/profiles/nexus.json")
  case simplifile.is_file(profile_path) {
    Ok(True) -> Ok(Nil)
    _ -> {
      // Atomic write-then-rename so concurrent first-ever runs never observe
      // a partially written profile file.
      let tmp_path =
        profile_path <> "." <> int.to_string(timing.now_us()) <> ".tmp"
      use _ <- result.try(
        simplifile.write(tmp_path, nono_nexus_profile_json)
        |> result.map_error(fn(e) {
          "bash: failed to write nono profile: " <> simplifile.describe_error(e)
        }),
      )
      case simplifile.rename(at: tmp_path, to: profile_path) {
        Ok(Nil) -> Ok(Nil)
        Error(e) -> {
          let _ = simplifile.delete(tmp_path)
          Error(
            "bash: failed to install nono profile: "
            <> simplifile.describe_error(e),
          )
        }
      }
    }
  }
}

/// Build the exact command, arguments, scrubbed environment, and kill mode
/// for one local workspace `bash` invocation.
pub fn build_spawn_plan(
  sandbox sandbox: SandboxConfig,
  host host: HostProbe,
  workspace_dir ws_dir: String,
  tmp_dir tmp_dir: Option(String),
  command command: String,
) -> Result(SpawnPlan, String) {
  case sandbox.backend {
    SandboxNone -> build_unsandboxed_plan(host, ws_dir, tmp_dir, command)
    SandboxBwrap -> build_bwrap_plan(sandbox, host, ws_dir, tmp_dir, command)
    SandboxNono -> build_nono_plan(sandbox, host, ws_dir, tmp_dir, command)
  }
}

fn build_unsandboxed_plan(
  host: HostProbe,
  ws_dir: String,
  tmp_dir: Option(String),
  command: String,
) -> Result(SpawnPlan, String) {
  use bash_path <- result.try(case host.resolve("bash") {
    Ok(path) -> Ok(path)
    Error(_) -> Error("bash: no bash executable found on PATH")
  })
  let setsid = host.resolve("setsid")
  let #(exe, argv, kill_mode) = build_bash_inner(bash_path, setsid, "", command)
  let tmp_entry = case tmp_dir {
    Some(dir) -> [#("TMPDIR", dir)]
    None -> []
  }
  Ok(SpawnPlan(
    exe: exe,
    argv: argv,
    allow_env: [#("HOME", ws_dir), #("PATH", host.inherited_path), ..tmp_entry],
    passthrough_env: default_passthrough_env,
    kill_mode: kill_mode,
  ))
}

fn build_bwrap_plan(
  sandbox: SandboxConfig,
  host: HostProbe,
  ws_dir: String,
  tmp_dir: Option(String),
  command: String,
) -> Result(SpawnPlan, String) {
  use bwrap_bin <- result.try(resolve_sandbox_binary(
    "bwrap",
    sandbox.sandbox_bin,
    host,
  ))
  let has_nix_store = host.is_dir("/nix/store")
  use
    #(
      inner_bash,
      inner_setsid,
      inner_path,
      ro_binds,
      ssl_bind,
      symlinks,
      ssl_env,
    )
  <- result.try(case sandbox.toolchain {
    Some(tc) -> {
      let tc_bash = filepath.join(tc, "bin/bash")
      use Nil <- result.try(case host.is_executable(tc_bash) {
        True -> Ok(Nil)
        False ->
          Error(
            "bash: workspace toolchain missing executable bash: " <> tc_bash,
          )
      })
      let tc_setsid = filepath.join(tc, "bin/setsid")
      let setsid = case host.is_executable(tc_setsid) {
        True -> Ok(tc_setsid)
        False -> Error(Nil)
      }
      let store_binds = case has_nix_store {
        True ->
          case string.starts_with(tc, "/nix/store/") {
            True -> ["--ro-bind", "/nix/store", "/nix/store"]
            False -> [
              "--ro-bind",
              "/nix/store",
              "/nix/store",
              "--ro-bind",
              tc,
              tc,
            ]
          }
        False -> list.append(["--ro-bind", tc, tc], fhs_ro_binds(host))
      }
      let tc_ssl_dir = filepath.join(tc, "etc/ssl")
      let #(ssl_bind, ssl_env) = case host.is_dir(tc_ssl_dir) {
        True -> {
          let ca_bundle = filepath.join(tc_ssl_dir, "certs/ca-bundle.crt")
          let env_entries = case host.path_exists(ca_bundle) {
            True -> [
              #("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt"),
              #("SSL_CERT_DIR", "/etc/ssl/certs"),
            ]
            False -> []
          }
          #(["--ro-bind", tc_ssl_dir, "/etc/ssl"], env_entries)
        }
        False -> #([], [])
      }
      let tc_sh = filepath.join(tc, "bin/sh")
      let sh_target = case host.is_executable(tc_sh) {
        True -> tc_sh
        False -> tc_bash
      }
      let tc_env = filepath.join(tc, "bin/env")
      let env_symlink = case host.is_executable(tc_env) {
        True -> ["--symlink", tc_env, "/usr/bin/env"]
        False -> []
      }
      let symlinks =
        list.append(["--symlink", sh_target, "/bin/sh"], env_symlink)
      Ok(#(
        tc_bash,
        setsid,
        filepath.join(tc, "bin"),
        store_binds,
        ssl_bind,
        symlinks,
        ssl_env,
      ))
    }
    None -> {
      use bash_path <- result.try(case host.resolve("bash") {
        Ok(path) -> Ok(path)
        Error(_) -> Error("bash: no bash executable found on PATH")
      })
      // On NixOS without an explicit `NEXUS_WORKSPACE_TOOLCHAIN`, system
      // binaries live under `/run/current-system/sw/bin` (symlinks into
      // `/nix/store`). Mount only `/run/current-system/sw` (immutable profile),
      // never `/run` or `/run/secrets`.
      let nix_prefixes = case has_nix_store {
        True ->
          case host.is_dir("/run/current-system/sw") {
            True -> ["/nix/store", "/run/current-system/sw"]
            False -> ["/nix/store"]
          }
        False -> []
      }
      let mounted_prefixes = list.append(nix_prefixes, existing_fhs_paths(host))
      use Nil <- result.try(case path_under_any(bash_path, mounted_prefixes) {
        True -> Ok(Nil)
        False ->
          Error(
            "bash: resolved bash ("
            <> bash_path
            <> ") is outside the bwrap read-only mount set; set"
            <> " NEXUS_WORKSPACE_TOOLCHAIN",
          )
      })
      let setsid = case host.resolve("setsid") {
        Ok(p) ->
          case path_under_any(p, mounted_prefixes) {
            True -> Ok(p)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
      let filtered_path =
        filter_mounted_path(
          host.inherited_path,
          mounted_prefixes,
          filepath.directory_name(bash_path),
        )
      let ro_binds =
        list.flat_map(mounted_prefixes, fn(p) { ["--ro-bind", p, p] })
      Ok(#(bash_path, setsid, filtered_path, ro_binds, [], [], []))
    }
  })
  let #(inner_exe, inner_argv, _inner_kill) =
    build_bash_inner(inner_bash, inner_setsid, "", command)
  let tmp_bind = case tmp_dir {
    Some(dir) -> ["--bind", dir, "/tmp"]
    None -> ["--tmpfs", "/tmp"]
  }
  let bwrap_argv =
    list.flatten([
      ["--tmpfs", "/"],
      ro_binds,
      ["--dev", "/dev", "--proc", "/proc"],
      ssl_bind,
      symlinks,
      ["--bind", ws_dir, "/workspace", "--chdir", "/workspace"],
      tmp_bind,
      ["--unshare-net", "--unshare-pid", "--die-with-parent", "--", inner_exe],
      inner_argv,
    ])
  // Under delegated cgroup v2, memory and PID caps ride the cgroup while
  // `prlimit --fsize` keeps the 256 MiB single-file disk cap active (cgroup v2
  // has no fsize equivalent). Without cgroup delegation, `prlimit` also adds
  // `--as` (virtual memory fallback). Wall-clock time is enforced by the port
  // loop, so `--cpu` (summed across threads) is deliberately omitted.
  let #(capped_exe, capped_argv) = case
    host.cgroup_dir,
    host.resolve("prlimit")
  {
    Some(_), Ok(prlimit_bin) -> #(
      prlimit_bin,
      list.flatten([prlimit_fsize_args(), [bwrap_bin], bwrap_argv]),
    )
    None, Ok(prlimit_bin) -> #(
      prlimit_bin,
      list.flatten([prlimit_fallback_args(sandbox), [bwrap_bin], bwrap_argv]),
    )
    _, Error(_) -> #(bwrap_bin, bwrap_argv)
  }
  let #(final_exe, final_argv) = case host.cgroup_dir {
    Some(cg_dir) ->
      wrap_with_cgroup(host, sandbox.toolchain, cg_dir, capped_exe, capped_argv)
    None -> #(capped_exe, capped_argv)
  }
  Ok(SpawnPlan(
    exe: final_exe,
    argv: final_argv,
    allow_env: list.append(
      [#("HOME", "/workspace"), #("TMPDIR", "/tmp"), #("PATH", inner_path)],
      ssl_env,
    ),
    passthrough_env: default_passthrough_env,
    kill_mode: KillPortOsPid,
  ))
}

fn build_nono_plan(
  sandbox: SandboxConfig,
  host: HostProbe,
  ws_dir: String,
  tmp_dir: Option(String),
  command: String,
) -> Result(SpawnPlan, String) {
  use state_dir <- result.try(case sandbox.state_dir {
    Some(dir) -> Ok(dir)
    None -> Error("bash: nono sandbox requires workspace_state_dir")
  })
  use nono_bin <- result.try(resolve_sandbox_binary(
    "nono",
    sandbox.sandbox_bin,
    host,
  ))
  use #(inner_bash, inner_setsid, inner_path) <- result.try(
    case sandbox.toolchain {
      Some(tc) -> {
        let tc_bash = filepath.join(tc, "bin/bash")
        use Nil <- result.try(case host.is_executable(tc_bash) {
          True -> Ok(Nil)
          False ->
            Error(
              "bash: workspace toolchain missing executable bash: " <> tc_bash,
            )
        })
        let tc_setsid = filepath.join(tc, "bin/setsid")
        let setsid = case host.is_executable(tc_setsid) {
          True -> Ok(tc_setsid)
          False -> host.resolve("setsid")
        }
        Ok(#(tc_bash, setsid, filepath.join(tc, "bin")))
      }
      None -> {
        use bash_path <- result.try(case host.resolve("bash") {
          Ok(path) -> Ok(path)
          Error(_) -> Error("bash: no bash executable found on PATH")
        })
        Ok(#(bash_path, host.resolve("setsid"), host.inherited_path))
      }
    },
  )
  // Phase 0 embedding contract: nono itself runs with HOME/XDG_* pointing at
  // `state_dir` (outside all grants), and the bash prelude immediately
  // re-exports HOME/TMPDIR and unsets XDG_* as its first silent statement.
  let tmp_export = case tmp_dir {
    Some(dir) -> "export TMPDIR=" <> shell_single_quote(dir) <> "; "
    None -> "unset TMPDIR; "
  }
  let prelude_prefix =
    "export HOME="
    <> shell_single_quote(ws_dir)
    <> "; unset XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME; "
    <> tmp_export
  let #(inner_exe, inner_argv, kill_mode) =
    build_bash_inner(inner_bash, inner_setsid, prelude_prefix, command)
  // Apply `prlimit` INSIDE `nono` (after `--`) so `RLIMIT_AS` caps the user
  // command rather than nono's own Rust runtime; under cgroup delegation keep
  // `prlimit --fsize` so the 256 MiB single-file disk cap stays uniform.
  let inner_cmd = case
    host.cgroup_dir,
    resolve_inner_prlimit(sandbox.toolchain, host)
  {
    Some(_), Ok(prlimit_bin) ->
      list.flatten([
        [prlimit_bin],
        prlimit_fsize_args(),
        [inner_exe],
        inner_argv,
      ])
    None, Ok(prlimit_bin) ->
      list.flatten([
        [prlimit_bin],
        prlimit_fallback_args(sandbox),
        [inner_exe],
        inner_argv,
      ])
    _, Error(_) -> [inner_exe, ..inner_argv]
  }
  let tmp_grant = case tmp_dir {
    Some(dir) -> ["--allow", dir]
    None -> []
  }
  let nix_grant = case host.is_dir("/nix/store") {
    True -> ["--read", "/nix/store"]
    False -> []
  }
  let tc_grant = case sandbox.toolchain {
    Some(tc) ->
      case host.is_dir("/nix/store") && string.starts_with(tc, "/nix/store/") {
        True -> []
        False -> ["--read", tc]
      }
    None -> []
  }
  let nono_argv =
    list.flatten([
      [
        "wrap",
        "-s",
        "--block-net",
        "--allow-cwd",
        "-p",
        "nexus",
        "--allow-file",
        "/dev/null",
        "--allow-file",
        "/dev/zero",
        "--allow-file",
        "/dev/full",
        "--allow",
        ws_dir,
      ],
      tmp_grant,
      nix_grant,
      tc_grant,
      ["--"],
      inner_cmd,
    ])
  let #(final_exe, final_argv) = case host.cgroup_dir {
    Some(cg_dir) ->
      wrap_with_cgroup(host, sandbox.toolchain, cg_dir, nono_bin, nono_argv)
    None -> #(nono_bin, nono_argv)
  }
  Ok(SpawnPlan(
    exe: final_exe,
    argv: final_argv,
    allow_env: [
      #("HOME", state_dir),
      #("XDG_STATE_HOME", filepath.join(state_dir, "state")),
      #("XDG_CACHE_HOME", filepath.join(state_dir, "cache")),
      #("XDG_CONFIG_HOME", filepath.join(state_dir, "config")),
      #("XDG_DATA_HOME", filepath.join(state_dir, "data")),
      #("PATH", inner_path),
    ],
    passthrough_env: default_passthrough_env,
    kill_mode: kill_mode,
  ))
}

fn resolve_sandbox_binary(
  name: String,
  explicit: Option(String),
  host: HostProbe,
) -> Result(String, String) {
  case explicit {
    Some(path) ->
      case host.is_executable(path) {
        True -> Ok(path)
        False ->
          Error(
            "bash: " <> name <> " binary not found or not executable: " <> path,
          )
      }
    None ->
      case host.resolve(name) {
        Ok(path) -> Ok(path)
        Error(_) ->
          Error(
            "bash: "
            <> name
            <> " sandbox configured but no "
            <> name
            <> " executable found on PATH",
          )
      }
  }
}

fn resolve_inner_prlimit(
  toolchain: Option(String),
  host: HostProbe,
) -> Result(String, Nil) {
  case toolchain {
    Some(tc) -> {
      let tc_prlimit = filepath.join(tc, "bin/prlimit")
      case host.is_executable(tc_prlimit) {
        True -> Ok(tc_prlimit)
        False -> host.resolve("prlimit")
      }
    }
    None -> host.resolve("prlimit")
  }
}

/// Safe read-only FHS host mounts for `bwrap` when no self-contained Nix
/// toolchain is active. Deliberately omits `/etc` as a whole (no `/etc/shadow`
/// or host secrets), `/home`, `/root`, `/run`, and `/var`.
fn existing_fhs_paths(host: HostProbe) -> List(String) {
  [
    "/usr",
    "/bin",
    "/lib",
    "/lib64",
    "/lib32",
    "/etc/ssl",
    "/etc/ca-certificates",
    "/etc/alternatives",
    "/etc/ld.so.cache",
  ]
  |> list.filter(host.path_exists)
}

fn fhs_ro_binds(host: HostProbe) -> List(String) {
  existing_fhs_paths(host)
  |> list.flat_map(fn(path) { ["--ro-bind", path, path] })
}

fn path_under_any(path: String, prefixes: List(String)) -> Bool {
  let clean = normalize(path)
  list.any(prefixes, fn(prefix) {
    let p = normalize(prefix)
    clean == p || string.starts_with(clean, p <> "/")
  })
}

fn filter_mounted_path(
  inherited_path: String,
  mounted_prefixes: List(String),
  fallback_dir: String,
) -> String {
  let kept =
    inherited_path
    |> string.split(":")
    |> list.filter(fn(entry) {
      entry != "" && path_under_any(entry, mounted_prefixes)
    })
  case kept {
    [] -> fallback_dir
    _ -> string.join(kept, ":")
  }
}

fn prlimit_fsize_args() -> List(String) {
  ["--fsize=" <> int.to_string(prlimit_fsize_bytes), "--"]
}

fn prlimit_fallback_args(sandbox: SandboxConfig) -> List(String) {
  let mem_bytes = sandbox.max_memory_mb * 1024 * 1024
  [
    "--as=" <> int.to_string(mem_bytes),
    "--fsize=" <> int.to_string(prlimit_fsize_bytes),
    "--",
  ]
}

fn wrap_with_cgroup(
  host: HostProbe,
  toolchain: Option(String),
  cg_dir: String,
  exe: String,
  argv: List(String),
) -> #(String, List(String)) {
  let host_sh = case host.resolve("bash") {
    Ok(p) -> Ok(p)
    Error(_) ->
      case host.resolve("sh") {
        Ok(p) -> Ok(p)
        Error(_) ->
          case toolchain {
            Some(tc) -> {
              let tc_bash = filepath.join(tc, "bin/bash")
              case host.is_executable(tc_bash) {
                True -> Ok(tc_bash)
                False -> Error(Nil)
              }
            }
            None -> Error(Nil)
          }
      }
  }
  case host_sh {
    Ok(sh) -> #(sh, [
      "-c",
      "printf '%d\\n' \"$$\" > \"$1/cgroup.procs\" && shift && exec \"$@\"",
      "_",
      cg_dir,
      exe,
      ..argv
    ])
    Error(_) -> #(exe, argv)
  }
}

/// Build the inner `[setsid -w] bash -c "<prelude><command>"` invocation
/// carrying the first-line PID marker and the owner-death stdin-EOF sentinel.
fn build_bash_inner(
  bash_path: String,
  setsid: Result(String, Nil),
  prelude_prefix: String,
  command: String,
) -> #(String, List(String), KillMode) {
  let sentinel_kill = case setsid {
    Ok(_) -> "kill -9 -- -$$"
    Error(_) -> "kill -9 $$"
  }
  let prelude =
    prelude_prefix
    <> "printf '%d\\n' $$; exec 3<&0 0</dev/null; "
    <> "(while read -r _line <&3; do :; done; kill -0 $$ 2>/dev/null && "
    <> sentinel_kill
    <> ") >/dev/null 2>&1 & "
  case setsid {
    Ok(setsid_path) -> #(
      setsid_path,
      ["-w", bash_path, "-c", prelude <> command],
      KillGroup,
    )
    Error(_) -> #(bash_path, ["-c", prelude <> command], KillPid)
  }
}

fn sandbox_backend_name(backend: SandboxBackend) -> String {
  case backend {
    SandboxNone -> "none"
    SandboxBwrap -> "bwrap"
    SandboxNono -> "nono"
  }
}

fn live_host_probe(cgroup_dir: Option(String)) -> HostProbe {
  HostProbe(
    resolve: ffi_resolve,
    is_executable: ffi_is_executable,
    path_exists: fn(path) { simplifile.file_info(path) |> result.is_ok },
    is_dir: fn(path) { simplifile.is_directory(path) == Ok(True) },
    inherited_path: ffi_inherited_path(),
    cgroup_dir: cgroup_dir,
  )
}

fn cleanup_cgroup(cgroup_dir: Option(String)) -> Nil {
  case cgroup_dir {
    Some(dir) -> ffi_cgroup_cleanup(dir)
    None -> Nil
  }
}

/// Run one bash command in the routed environment's working directory using
/// the unsandboxed default posture (`default_sandbox()`).
pub fn bash(
  timeout_ms timeout_ms: Int,
  max_output_bytes max_output_bytes: Int,
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  bash_with_sandbox(
    timeout_ms: timeout_ms,
    max_output_bytes: max_output_bytes,
    sandbox: default_sandbox(),
    environment: environment,
    cancel: cancel,
    arguments: arguments,
  )
}

/// Run one bash command in the routed environment's working directory under
/// the given sandbox and resource-cap configuration.
/// The select loop is the codemode pattern over a port: {data,
/// exit_status, cancel, deadline}. `exit_status` 0 → Ok(output);
/// non-zero → Ok("exit status N" + output) — a failing command is
/// DATA, not a transport failure (the http_fetch non-2xx rule);
/// spawn/wrapper/cancel/timeout are the errors, each honestly worded, and
/// cancel/timeout carry the partial output. The over-cap kill renders
/// the capped output as data with an omission note (like every other
/// truncation in the harness).
pub fn bash_with_sandbox(
  timeout_ms timeout_ms: Int,
  max_output_bytes max_output_bytes: Int,
  sandbox sandbox: SandboxConfig,
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_bash_args(arguments))
  case remote_result(environment, args.target, "bash", arguments, cancel) {
    Some(result) -> result
    None ->
      bash_workspace(
        timeout_ms,
        max_output_bytes,
        sandbox,
        environment,
        cancel,
        args,
      )
  }
}

/// The local `workspace` path (Phase 1 + Phase 2 sandbox wrapper):
/// route/ensure workspace + tmp, prepare nono state / transient cgroup when
/// configured, build the spawn plan, and run the bounded port select loop.
fn bash_workspace(
  timeout_ms: Int,
  max_output_bytes: Int,
  sandbox: SandboxConfig,
  environment: Option(Environment),
  cancel: Subject(Nil),
  args: BashArgs,
) -> Result(String, String) {
  use env <- result.try(route(environment, args.target))
  use _ <- result.try(ensure_workspace(env))
  use tmp <- result.try(ensure_tmp_dir(env))
  use _ <- result.try(case sandbox.backend, sandbox.state_dir {
    SandboxNono, Some(state_dir) -> ensure_nono_state(state_dir)
    SandboxNono, None ->
      Error("bash: nono sandbox requires workspace_state_dir")
    _, _ -> Ok(Nil)
  })
  let cgroup_dir = case sandbox.backend {
    SandboxNone -> None
    SandboxBwrap | SandboxNono ->
      ffi_cgroup_create(sandbox.max_memory_mb, sandbox.max_pids)
      |> option.from_result
  }
  let host = live_host_probe(cgroup_dir)
  case
    build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: workspace_dir(env),
      tmp_dir: tmp,
      command: args.command,
    )
  {
    Error(reason) -> {
      cleanup_cgroup(cgroup_dir)
      Error(reason)
    }
    Ok(plan) ->
      run_spawn_plan(
        plan,
        sandbox.backend,
        workspace_dir(env),
        cgroup_dir,
        timeout_ms,
        max_output_bytes,
        cancel,
      )
  }
}

fn run_spawn_plan(
  plan: SpawnPlan,
  sandbox_backend: SandboxBackend,
  cwd: String,
  cgroup_dir: Option(String),
  timeout_ms: Int,
  max_output_bytes: Int,
  cancel: Subject(Nil),
) -> Result(String, String) {
  case
    ffi_open_port(
      plan.exe,
      plan.argv,
      cwd,
      plan.allow_env,
      plan.passthrough_env,
    )
  {
    Error(reason) -> {
      cleanup_cgroup(cgroup_dir)
      Error("bash: " <> reason)
    }
    Ok(p) -> {
      // Query the host OS PID immediately while the port is live: for
      // PID-namespace backends (`KillPortOsPid`), this arms both the loop and
      // the owner-death watchdog from instant zero with no marker-handoff race.
      let os_pid = ffi_port_os_pid(p) |> option.from_result
      let initial_watch_pid = case plan.kill_mode {
        KillPortOsPid -> os_pid
        KillGroup | KillPid -> None
      }
      let deadline_us = timing.now_us() + timeout_ms * 1000
      let selector =
        process.new_selector()
        |> process.select_map(cancel, fn(_) { Cancelled })
        |> process.select_record(tag: p, fields: 1, mapping: decode_port_msg)
      // The owner-death watchdog (the subject-owner rule inverted: the
      // watchdog creates its own gate and hands it back, so it — not
      // the executor — receives on it).
      let gate_back = process.new_subject()
      let owner = process.self()
      let _watchdog =
        process.spawn_unlinked(fn() {
          let gate = process.new_subject()
          process.send(gate_back, gate)
          let mon = process.monitor(owner)
          watch(gate, mon, p, plan.kill_mode, initial_watch_pid, cgroup_dir)
        })
      // The watchdog's gate handshake, degraded honestly instead of
      // asserted (cubic PR review): a scheduler delay past the budget
      // must answer the call, not crash the per-turn worker. Nothing
      // ran yet, so closing the port and refusing is clean.
      case process.receive(gate_back, 1000) {
        Error(Nil) -> {
          ffi_kill_tree(p, target_kill(initial_watch_pid, plan.kill_mode))
          cleanup_cgroup(cgroup_dir)
          Error("bash: the kill watchdog failed to start")
        }
        Ok(gate) -> {
          let outcome =
            bash_loop(
              BashLoop(
                p: p,
                selector: selector,
                cancel: cancel,
                timeout_ms: timeout_ms,
                deadline_us: deadline_us,
                max_output_bytes: max_output_bytes,
                kill_mode: plan.kill_mode,
                os_pid: os_pid,
                sandbox_backend: sandbox_backend,
                watch: gate,
              ),
              BashState(
                head: <<>>,
                marker: MarkerPending,
                out: <<>>,
                killed: False,
              ),
            )
          // Whatever the outcome, the loop is done with the port: the
          // watchdog stands down (it demonitors and exits) and any transient
          // cgroup is killed and removed.
          process.send(gate, WatchDone)
          cleanup_cgroup(cgroup_dir)
          outcome
        }
      }
    }
  }
}

/// The watchdog: if the OWNING process dies while the bash port is
/// live (a codemode task child killed at the script deadline, a
/// crashed per-turn worker), the port closes and the BEAM kills only
/// the DIRECT child — the setsid'd process group would survive. The
/// watchdog fires the configured kill on the owner's DOWN and cleans up
/// any transient cgroup. Under `KillPortOsPid` it is armed from spawn with
/// the host PID of `bwrap`; under `KillGroup`/`KillPid` it learns the pgid
/// when the executor parses the marker (`WatchPgid`).
fn watch(
  gate: Subject(WatchMsg),
  mon: process.Monitor,
  p: Port,
  kill_mode: KillMode,
  target_pid: Option(Int),
  cgroup_dir: Option(String),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(gate, Gate)
    |> process.select_specific_monitor(mon, fn(_down) { OwnerDown })
  case process.selector_receive_forever(selector) {
    Gate(WatchPgid(n)) -> watch(gate, mon, p, kill_mode, Some(n), cgroup_dir)
    Gate(WatchDone) -> {
      process.demonitor_process(mon)
      Nil
    }
    OwnerDown -> {
      ffi_kill_tree(p, target_kill(target_pid, kill_mode))
      cleanup_cgroup(cgroup_dir)
      Nil
    }
  }
}

type BashLoop {
  BashLoop(
    p: Port,
    selector: process.Selector(SelectMsg),
    cancel: Subject(Nil),
    timeout_ms: Int,
    deadline_us: Int,
    max_output_bytes: Int,
    /// Host-side kill discipline (see `KillMode`).
    kill_mode: KillMode,
    /// Host OS PID of the direct port child (used under `KillPortOsPid`).
    os_pid: Option(Int),
    /// Configured sandbox backend (used to surface silent wrapper failures).
    sandbox_backend: SandboxBackend,
    /// The owner-death watchdog's gate (see `watch`).
    watch: Subject(WatchMsg),
  )
}

fn bash_loop(loop: BashLoop, state: BashState) -> Result(String, String) {
  // Deadline BEFORE receive (CodeRabbit review): a saturated pipe can
  // keep queued `Data` permanently available to a zero-timeout
  // receive, starving the timeout branch — the wall-clock guarantee
  // must not depend on the child's output rate. Expired goes straight
  // to the timeout branch, whose bounded reap still drains buffered
  // output into the result.
  case loop.deadline_us - timing.now_us() <= 0 {
    True -> bash_timed_out(loop, state)
    False -> bash_receive(loop, state)
  }
}

fn bash_timed_out(loop: BashLoop, state: BashState) -> Result(String, String) {
  {
    let state = kill_and_reap(loop, state)
    Error(
      "timed out after "
      <> int.to_string(loop.timeout_ms)
      <> " ms. partial output:\n"
      <> render_output(state, loop.max_output_bytes),
    )
  }
}

fn bash_receive(loop: BashLoop, state: BashState) -> Result(String, String) {
  let remaining_us = loop.deadline_us - timing.now_us()
  let remaining_ms = case remaining_us < 0 {
    True -> 0
    False -> int.divide(remaining_us, 1000) |> result.unwrap(0)
  }
  case process.selector_receive(loop.selector, remaining_ms) {
    // The selector timed out with data still possible: same honest
    // answer as an expired deadline checked up front.
    Error(Nil) -> bash_timed_out(loop, state)
    Ok(Cancelled) -> {
      // The RE-SIGNAL is mandatory (the codemode rule): this select
      // consumed the turn's one-shot `Nil`, and the loop's LAST-call
      // path still needs to observe the Stop.
      process.send(loop.cancel, Nil)
      let state = kill_and_reap(loop, state)
      Error(
        "cancelled. partial output:\n"
        <> render_output(state, loop.max_output_bytes),
      )
    }
    Ok(Port(Data(bytes))) -> {
      let state = absorb(loop, state, bytes)
      case state.killed {
        // Over the cap + slack: the kill fires exactly once, the
        // bounded reap drains the rest, and the capped output returns
        // as data with the omission note (the command itself may have
        // been nowhere near done — the note says it was killed).
        True -> {
          let state = kill_and_reap(loop, state)
          Ok(
            render_output(state, loop.max_output_bytes)
            <> "\n[... output exceeded "
            <> int.to_string(loop.max_output_bytes)
            <> " bytes; the command was killed ...]",
          )
        }
        False -> bash_loop(loop, state)
      }
    }
    Ok(Port(Exited(code))) ->
      finish(state, loop.max_output_bytes, code, loop.sandbox_backend)
  }
}

/// Kill the child's tree and keep selecting (bounded at `reap_ms`)
/// for the exit_status: the killed child's remaining buffered output
/// lands too, and the port is consumed instead of queueing garbage.
/// The reap selector matches the PORT ONLY — never the cancel subject:
/// the cancel path has just RE-SIGNALLED its one-shot `Nil` (the
/// codemode rule), and a reap armed with the cancel map would consume
/// the very signal it is contractually putting back. A cancel landing
/// during a timeout/cap reap stays queued for the loop's next
/// `cancel_pending` check, exactly as before.
fn kill_and_reap(loop: BashLoop, state: BashState) -> BashState {
  // Marker still pending (cancel/timeout raced the child's first
  // output): give the pid line its brief chance so host-PID kills are armed
  // instead of a port_close that kills nothing. Under `KillPortOsPid`
  // (`bwrap --unshare-pid`), we already hold the host `bwrap` PID and never
  // target the in-namespace marker, so skip the wait.
  let state = case loop.kill_mode, state.marker {
    KillPortOsPid, _ -> state
    _, MarkerPending -> await_marker(loop, state, timing.now_us())
    _, MarkerLeader(_) | _, MarkerAbsent -> state
  }
  ffi_kill_tree(loop.p, loop_kill_target(loop, state.marker))
  let reap_selector = port_selector(loop.p)
  case process.selector_receive(reap_selector, reap_ms) {
    Ok(Port(Data(bytes))) -> kill_and_reap(loop, absorb(loop, state, bytes))
    // Unreachable by construction (the reap selector carries no
    // cancel map) — the arm keeps the match total.
    Ok(Port(Exited(_))) | Ok(Cancelled) | Error(Nil) -> state
  }
}

/// Drain briefly for the still-pending pid marker (bounded at
/// `marker_wait_ms`): each queued chunk goes through `absorb`, which
/// resolves the marker as soon as the first line lands; the wait ends
/// early once it does. Output keeps flowing through the normal
/// cap-checked path.
fn await_marker(
  loop: BashLoop,
  state: BashState,
  started_us: Int,
) -> BashState {
  // Remaining budget from the single start instant, so chunks cannot
  // extend the wait.
  let left_ms = case marker_wait_ms * 1000 - { timing.now_us() - started_us } {
    remainder if remainder <= 0 -> 0
    remainder -> { remainder + 999 } / 1000
  }
  case state.marker == MarkerPending && left_ms > 0 {
    False -> state
    True ->
      // PORT-ONLY selector (CodeRabbit review): the wait must never
      // touch the turn's one-shot cancel subject — a cancel landing
      // here stays queued untouched for the caller's main select and
      // the loop's LAST-call path, with no consume/re-signal dance.
      case process.selector_receive(port_selector(loop.p), left_ms) {
        Ok(Port(Data(bytes))) -> {
          let state = absorb(loop, state, bytes)
          await_marker(loop, state, started_us)
        }
        // The child exited before printing a marker — nothing to arm.
        // Cancelled is unreachable by construction (port-only
        // selector); the arm keeps the match total.
        Ok(Port(Exited(_))) | Ok(Cancelled) | Error(Nil) -> state
      }
  }
}

/// A selector over the port's records ONLY — never the cancel subject
/// (the shared shape of the marker wait and the kill reap).
fn port_selector(p: Port) -> process.Selector(SelectMsg) {
  process.new_selector()
  |> process.select_record(tag: p, fields: 1, mapping: decode_port_msg)
}

/// A completed run: marker consumed, output capped and lossily
/// decoded; exit 0 is plain output, non-zero prefixes the status (a
/// failing command is data — the model reacts, the round commits).
///
/// Phase 0 `nono` embedding contract: `-s` suppresses even fatal sandbox
/// errors (rc=1, empty output). When a sandboxed wrapper exits non-zero
/// without bash ever printing its first-line PID marker or any byte of output,
/// surface that as a tool `Error` rather than a silent `exit status N`.
fn finish(
  state: BashState,
  max_output_bytes: Int,
  code: Int,
  sandbox_backend: SandboxBackend,
) -> Result(String, String) {
  case
    sandbox_backend != SandboxNone
    && code != 0
    && state.marker == MarkerPending
    && state.head == <<>>
    && state.out == <<>>
  {
    True ->
      Error(
        "bash: sandbox wrapper ("
        <> sandbox_backend_name(sandbox_backend)
        <> ") exited with status "
        <> int.to_string(code)
        <> " before starting bash",
      )
    False -> {
      let output = render_output(state, max_output_bytes)
      case code {
        0 -> Ok(output)
        n -> Ok("exit status " <> int.to_string(n) <> "\n" <> output)
      }
    }
  }
}

/// Fold one data chunk into the state. While the marker is `Pending`,
/// the first newline splits it off: a parseable pid arms the group
/// kill (consumed — never shown); anything else is REAL OUTPUT — the
/// child never printed a marker (a bash syntax error means `printf`
/// never ran either) and the line folds into `out` with the marker
/// permanently `Absent`, so the diagnostic the model needs to
/// self-correct survives. Everything after accumulates under the byte
/// cap, tripping `killed` (once) when cap + slack is passed.
fn absorb(loop: BashLoop, state: BashState, bytes: BitArray) -> BashState {
  case state.marker {
    MarkerPending -> {
      let joined = bit_array.append(state.head, bytes)
      case ffi_split_line(joined) {
        Ok(#(line, rest)) -> {
          let marker = case bit_array.to_string(line) {
            Ok(text) ->
              case int.parse(string.trim(text)) {
                Ok(n) -> MarkerLeader(n)
                Error(_) -> MarkerAbsent
              }
            Error(_) -> MarkerAbsent
          }
          case marker {
            MarkerLeader(n) -> {
              // Arm the watchdog's host kill ONLY when the marker is a real
              // host PID/PGID; under `KillPortOsPid` (bwrap PID namespace),
              // `n` is an in-namespace PID and the watchdog is already armed
              // with the host `bwrap` PID.
              case loop.kill_mode {
                KillPortOsPid -> Nil
                KillGroup | KillPid -> process.send(loop.watch, WatchPgid(n))
              }
              absorb_out(
                BashState(..state, head: <<>>, marker: marker),
                rest,
                loop.max_output_bytes,
              )
            }
            // The first line was NOT the marker: all of it (line and
            // everything after) is output, and no marker is coming.
            MarkerAbsent ->
              absorb_out(
                BashState(..state, head: <<>>, marker: MarkerAbsent),
                joined,
                loop.max_output_bytes,
              )
            MarkerPending -> BashState(..state, head: joined)
          }
        }
        Error(_) ->
          // No newline yet: the marker is one short line; a head grown
          // past the cap with no marker in sight is output (bounded).
          case bit_array.byte_size(joined) > loop.max_output_bytes {
            True ->
              absorb_out(
                BashState(..state, head: <<>>, marker: MarkerAbsent),
                joined,
                loop.max_output_bytes,
              )
            False -> BashState(..state, head: joined)
          }
      }
    }
    MarkerLeader(_) | MarkerAbsent ->
      absorb_out(state, bytes, loop.max_output_bytes)
  }
}

/// Resolve the host kill target for the running loop.
fn loop_kill_target(
  loop: BashLoop,
  marker: Marker,
) -> Result(ErlangKillTarget, Nil) {
  case loop.kill_mode {
    KillPortOsPid -> target_kill(loop.os_pid, KillPortOsPid)
    KillGroup | KillPid ->
      case marker {
        MarkerLeader(n) -> target_kill(Some(n), loop.kill_mode)
        MarkerPending | MarkerAbsent -> Error(Nil)
      }
  }
}

/// Convert a host PID/PGID and `KillMode` to the FFI's kill target.
fn target_kill(
  pid: Option(Int),
  kill_mode: KillMode,
) -> Result(ErlangKillTarget, Nil) {
  case pid, kill_mode {
    Some(n), KillGroup -> Ok(ffi_kill_group(n))
    Some(n), KillPid | Some(n), KillPortOsPid -> Ok(ffi_kill_pid(n))
    None, _ -> Error(Nil)
  }
}

pub type ErlangKillTarget

@external(erlang, "nexus_env_ffi", "kill_group_marker")
fn ffi_kill_group(n: Int) -> ErlangKillTarget

@external(erlang, "nexus_env_ffi", "kill_pid_marker")
fn ffi_kill_pid(n: Int) -> ErlangKillTarget

fn absorb_out(
  state: BashState,
  bytes: BitArray,
  max_output_bytes: Int,
) -> BashState {
  case state.killed {
    // Post-kill chunks are DISCARDED, not buffered: between the
    // group-kill dispatch and the child's death a gushing pipe can
    // still deliver chunks, and feeding them through the append would
    // accumulate output past the cap bounded only by wall clock
    // (cubic PR review). The rendered result keeps the capped prefix
    // plus the omission note — the discarded bytes never render.
    True -> state
    False -> {
      let out = bit_array.append(state.out, bytes)
      case bit_array.byte_size(out) > max_output_bytes + cap_slack_bytes {
        True -> BashState(..state, out: out, killed: True)
        False -> BashState(..state, out: out)
      }
    }
  }
}

/// Cap the accumulated bytes to the cap and decode lossily; an empty
/// result renders as an explicit marker (a bare empty tool result
/// reads as breakage, not silence).
fn render_output(state: BashState, max_output_bytes: Int) -> String {
  // A still-pending head is bytes the child produced (the marker line
  // never completed — or never was one): on a terminal path they are
  // output, not garbage to drop.
  let all = bit_array.append(state.head, state.out)
  let #(bytes, truncated) = case bit_array.byte_size(all) > max_output_bytes {
    True -> #(
      bit_array.slice(all, 0, max_output_bytes) |> result.unwrap(<<>>),
      True,
    )
    False -> #(all, False)
  }
  let text = ffi_to_text_lossy(bytes)
  let text = case string.trim(text) {
    "" -> "(no output)"
    trimmed -> trimmed
  }
  case truncated {
    True ->
      text
      <> "\n[... truncated at "
      <> int.to_string(max_output_bytes)
      <> " bytes ...]"
    False -> text
  }
}

type BashArgs {
  BashArgs(target: String, command: String)
}

fn parse_bash_args(arguments: String) -> Result(BashArgs, String) {
  let decoder = {
    use target <- decode.field("target", decode.string)
    use command <- decode.field("command", decode.string)
    decode.success(BashArgs(target: string.trim(target), command: command))
  }
  case json.parse(arguments, decoder) {
    Ok(args) ->
      case args.target, string.trim(args.command) {
        "", _ -> Error("bash requires a non-empty `target`")
        _, "" -> Error("bash requires a non-empty `command`")
        _, _ -> Ok(args)
      }
    Error(_) -> Error("invalid bash arguments: {\"target\", \"command\"}")
  }
}

// ---------------------------------------------------------------------------
// Execution: the fs tools
// ---------------------------------------------------------------------------

/// Read a workspace file, capped WHILE READING. Non-UTF-8 bytes are
/// decoded lossily (never a crash on binary content).
pub fn read_file(
  max_output_bytes max_output_bytes: Int,
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_path_args(arguments, "read_file"))
  case remote_result(environment, args.target, "read_file", arguments, cancel) {
    Some(result) -> result
    None -> {
      use env <- result.try(route(environment, args.target))
      use _ <- result.try(ensure_workspace(env))
      use path <- result.try(confined(env, args.path))
      read_file_local(max_output_bytes, args, path)
    }
  }
}

fn read_file_local(
  max_output_bytes: Int,
  args: PathArgs,
  path: String,
) -> Result(String, String) {
  case regular_file(path) {
    // REGULAR FILES ONLY (cubic PR review): a workspace FIFO or device
    // node would block the turn worker's open/read indefinitely —
    // `bash` can create either inside the workspace, so the guard is
    // not hypothetical. Directories keep their honest error.
    Ok(False) -> Error("read_file: not a regular file: " <> args.path)
    _ ->
      case ffi_read_capped(path, max_output_bytes) {
        Error(reason) -> Error("read_file: " <> reason)
        Ok(#(bytes, truncated)) -> {
          let text = ffi_to_text_lossy(bytes)
          case truncated {
            True ->
              Ok(
                text
                <> "\n[... truncated at "
                <> int.to_string(max_output_bytes)
                <> " bytes ...]",
              )
            False -> Ok(text)
          }
        }
      }
  }
}

/// Write a workspace file (whole-content replace), creating parent
/// directories as needed.
pub fn write_file(
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_write_args(arguments))
  case
    remote_result(environment, args.target, "write_file", arguments, cancel)
  {
    Some(result) -> result
    None -> {
      use env <- result.try(route(environment, args.target))
      use _ <- result.try(ensure_workspace(env))
      use path <- result.try(confined(env, args.path))
      write_file_local(args, path)
    }
  }
}

fn write_file_local(args: WriteArgs, path: String) -> Result(String, String) {
  // An EXISTING non-regular target (a FIFO `bash` made) would block
  // the write until a reader arrives — refuse it; a not-yet-existing
  // path is a regular file to be created (cubic PR review). The
  // same guard read_file carries: special files are never touched.
  use _ <- result.try(case regular_file(path) {
    Ok(False) -> Error("write_file: not a regular file: " <> args.path)
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    simplifile.create_directory_all(filepath.directory_name(path))
    |> result.map_error(fn(e) { "write_file: " <> simplifile.describe_error(e) }),
  )
  case simplifile.write(path, args.content) {
    Ok(Nil) ->
      Ok(
        "wrote "
        <> int.to_string(string.byte_size(args.content))
        <> " bytes to "
        <> args.path,
      )
    Error(error) -> Error("write_file: " <> simplifile.describe_error(error))
  }
}

const list_dir_entry_cap = 500

/// List a workspace directory: sorted entries, directories suffixed
/// '/', capped at `list_dir_entry_cap` entries with an omission note.
pub fn list_dir(
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_path_args(arguments, "list_dir"))
  case remote_result(environment, args.target, "list_dir", arguments, cancel) {
    Some(result) -> result
    None -> {
      use env <- result.try(route(environment, args.target))
      use _ <- result.try(ensure_workspace(env))
      use path <- result.try(confined(env, args.path))
      list_dir_local(args, path)
    }
  }
}

fn list_dir_local(args: PathArgs, path: String) -> Result(String, String) {
  case simplifile.is_directory(path) {
    Ok(False) -> Error("list_dir: not a directory: " <> args.path)
    _ ->
      case simplifile.read_directory(path) {
        Error(error) -> Error("list_dir: " <> simplifile.describe_error(error))
        Ok(entries) -> {
          let sorted = list.sort(entries, string.compare)
          let shown = list.take(sorted, list_dir_entry_cap)
          let lines =
            list.map(shown, fn(entry) {
              case simplifile.is_directory(filepath.join(path, entry)) {
                Ok(True) -> entry <> "/"
                _ -> entry
              }
            })
          let listing = case lines {
            [] -> "(empty)"
            _ -> string.join(lines, "\n")
          }
          case list.length(entries) > list_dir_entry_cap {
            True ->
              Ok(
                listing
                <> "\n[... "
                <> int.to_string(list.length(entries) - list_dir_entry_cap)
                <> " more entries omitted ...]",
              )
            False -> Ok(listing)
          }
        }
      }
  }
}

/// Serve one env-tool call ON THIS NODE (environments 2b-5): the
/// node-side twin of the server's remote dispatch. The call arrived
/// HERE because the server routed it to this node's connection, so the
/// arguments' `target` names this node — the node translates it to the
/// reserved local `"workspace"` in the parsed arguments and runs the
/// Phase 1 local path UNCHANGED (kill-tree, caps enforced while
/// reading, lexical confinement; the same code the server runs for its
/// own workspace). Unknown tool names refuse: a node serves the four
/// compiled env tools only. The TUI (`nexus/tui`) calls this from its
/// tool-plane worker; offline tests drive it with real bash in a temp
/// workspace, no socket required.
pub fn serve_node_call(
  handle handle: Environment,
  tool tool: String,
  arguments arguments: String,
  timeout_ms timeout_ms: Int,
  max_output_bytes max_output_bytes: Int,
  cancel cancel: Subject(Nil),
) -> Result(String, String) {
  case tool {
    "bash" ->
      case parse_bash_args(arguments) {
        Ok(args) ->
          bash_workspace(
            timeout_ms,
            max_output_bytes,
            default_sandbox(),
            Some(handle),
            cancel,
            BashArgs(..args, target: "workspace"),
          )
        Error(e) -> Error(e)
      }
    "read_file" ->
      case parse_path_args(arguments, "read_file") {
        Ok(args) -> {
          use _ <- result.try(ensure_workspace(handle))
          use path <- result.try(confined(handle, args.path))
          read_file_local(
            max_output_bytes,
            PathArgs(..args, target: "workspace"),
            path,
          )
        }
        Error(e) -> Error(e)
      }
    "write_file" ->
      case parse_write_args(arguments) {
        Ok(args) -> {
          use _ <- result.try(ensure_workspace(handle))
          use path <- result.try(confined(handle, args.path))
          write_file_local(WriteArgs(..args, target: "workspace"), path)
        }
        Error(e) -> Error(e)
      }
    "list_dir" ->
      case parse_path_args(arguments, "list_dir") {
        Ok(args) -> {
          use _ <- result.try(ensure_workspace(handle))
          use path <- result.try(confined(handle, args.path))
          list_dir_local(PathArgs(..args, target: "workspace"), path)
        }
        Error(e) -> Error(e)
      }
    _ -> Error("this node does not serve the tool \"" <> tool <> "\"")
  }
}

/// True when the path is a regular file; `Error` when it does not
/// exist (or is unreadable) — the caller decides which answers are
/// acceptable. `file_info` FOLLOWS symlinks, so a link to a regular
/// file passes and a link to a FIFO does not.
fn regular_file(path: String) -> Result(Bool, Nil) {
  case simplifile.file_info(path) {
    Ok(info) -> Ok(simplifile.file_info_type(info) == simplifile.File)
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Path confinement (lexical)
// ---------------------------------------------------------------------------

/// Resolve `user_path` against the workspace directory and refuse
/// escapes: `..` segments fold LEXICALLY, absolute paths must already
/// live inside the workspace, and the normalized result must be the
/// workspace dir or under it. Symlinks are NOT resolved — v1 is
/// hygiene, not a security boundary (a symlink planted inside the
/// workspace can still point out; the recorded accepted risk).
pub fn confined(env: Environment, user_path: String) -> Result(String, String) {
  let dir = normalize(workspace_dir(env))
  let joined = case filepath.is_absolute(user_path) {
    True -> user_path
    False -> filepath.join(dir, user_path)
  }
  let normalized = normalize(joined)
  case normalized == dir || string.starts_with(normalized, dir <> "/") {
    True -> Ok(normalized)
    False -> Error("path escapes the workspace: " <> user_path)
  }
}

/// Lexical normalization: split on '/', fold '.' and '' away, pop on
/// '..' (never above the root), keep the leading '/' for absolute
/// paths. `workspace_dir` never contains '..' segments (the root is
/// operator config, the id registry-minted), so the fold is stable.
pub fn normalize(path: String) -> String {
  let absolute = string.starts_with(path, "/")
  let segments =
    path
    |> string.split("/")
    |> list.fold([], fn(acc, segment) {
      case segment {
        "" | "." -> acc
        ".." ->
          case acc {
            [] -> acc
            [_, ..rest] -> rest
          }
        _ -> [segment, ..acc]
      }
    })
    |> list.reverse
  case absolute, segments {
    True, [] -> "/"
    True, _ -> "/" <> string.join(segments, "/")
    False, _ -> string.join(segments, "/")
  }
}

// ---------------------------------------------------------------------------
// Argument parsing helpers
// ---------------------------------------------------------------------------

type PathArgs {
  PathArgs(target: String, path: String)
}

type WriteArgs {
  WriteArgs(target: String, path: String, content: String)
}

/// `path` is optional at the schema level only for `list_dir` (the
/// workspace root); `read_file` validates non-emptiness itself.
fn parse_path_args(
  arguments: String,
  tool: String,
) -> Result(PathArgs, String) {
  let decoder = {
    use target <- decode.field("target", decode.string)
    use path <- decode.optional_field("path", "", decode.string)
    decode.success(PathArgs(target: string.trim(target), path: path))
  }
  case json.parse(arguments, decoder) {
    Ok(args) ->
      case args.target {
        "" -> Error(tool <> " requires a non-empty `target`")
        _ -> Ok(args)
      }
    Error(_) ->
      Error("invalid " <> tool <> " arguments: {\"target\", \"path\"}")
  }
}

fn parse_write_args(arguments: String) -> Result(WriteArgs, String) {
  let decoder = {
    use target <- decode.field("target", decode.string)
    use path <- decode.field("path", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(WriteArgs(
      target: string.trim(target),
      path: path,
      content: content,
    ))
  }
  case json.parse(arguments, decoder) {
    Ok(args) ->
      case args.target, string.trim(args.path) {
        "", _ -> Error("write_file requires a non-empty `target`")
        _, "" -> Error("write_file requires a non-empty `path`")
        _, _ -> Ok(args)
      }
    Error(_) ->
      Error("invalid write_file arguments: {\"target\", \"path\", \"content\"}")
  }
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "nexus_env_ffi", "resolve")
fn ffi_resolve(name: String) -> Result(String, Nil)

@external(erlang, "nexus_env_ffi", "is_executable")
fn ffi_is_executable(path: String) -> Bool

@external(erlang, "nexus_env_ffi", "inherited_path")
fn ffi_inherited_path() -> String

@external(erlang, "nexus_env_ffi", "open_port")
fn ffi_open_port(
  command: String,
  args: List(String),
  cwd: String,
  allow_env: List(#(String, String)),
  passthrough_env: List(String),
) -> Result(Port, String)

@external(erlang, "nexus_env_ffi", "port_os_pid")
fn ffi_port_os_pid(port: Port) -> Result(Int, Nil)

@external(erlang, "nexus_env_ffi", "cgroup_create")
fn ffi_cgroup_create(max_memory_mb: Int, max_pids: Int) -> Result(String, Nil)

@external(erlang, "nexus_env_ffi", "cgroup_cleanup")
fn ffi_cgroup_cleanup(cgroup_dir: String) -> Nil

@external(erlang, "nexus_env_ffi", "kill_tree")
fn ffi_kill_tree(port: Port, target: Result(ErlangKillTarget, Nil)) -> Nil

@external(erlang, "nexus_env_ffi", "to_text_lossy")
fn ffi_to_text_lossy(bytes: BitArray) -> String

@external(erlang, "nexus_env_ffi", "read_capped")
fn ffi_read_capped(
  path: String,
  max_bytes: Int,
) -> Result(#(BitArray, Bool), String)

@external(erlang, "nexus_env_ffi", "split_line")
fn ffi_split_line(buf: BitArray) -> Result(#(BitArray, BitArray), Nil)

// The port message is {Port, Inner}: peel element 1 (the inner
// tuple), then classify `data` / `exit_status` (the nexus/mcp decode
// pattern verbatim). Anything else matching the tag is treated as an
// empty chunk (harmless).
fn decode_port_msg(message: Dynamic) -> SelectMsg {
  let inner = {
    use kind <- decode.field(0, atom.decoder())
    case atom.to_string(kind) {
      "data" -> {
        use bytes <- decode.field(1, decode.bit_array)
        decode.success(Data(bytes))
      }
      "exit_status" -> {
        use code <- decode.field(1, decode.int)
        decode.success(Exited(code))
      }
      _ -> decode.failure(Data(<<>>), "PortEvent")
    }
  }
  case decode.run(message, decode.field(1, decode.dynamic, decode.success)) {
    Ok(d) ->
      case decode.run(d, inner) {
        Ok(event) -> Port(event)
        Error(_) -> Port(Data(<<>>))
      }
    Error(_) -> Port(Data(<<>>))
  }
}
