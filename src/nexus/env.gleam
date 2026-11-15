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
//// still escape; `bash` can always reach the host — the recorded
//// accepted risk of the Pi model on the operator's own server).
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
/// Phase 2a: `roster` starts as the frozen seed (`["workspace"]`) and
/// is the live attached list the actor mirrors; attach/detach re-aim
/// `route` by replacing this value's contents on the thread actor's
/// copy. Until the live source lands, `route` fails fast on anything
/// but the seed — the Phase 1 behaviour, now parametrised.
pub type Environment {
  Environment(workspace_root: String, thread_id: String, roster: List(String))
}

/// The complete v1 attached-target list, in stable order. `workspace`
/// is the reserved target for the thread's own workspace — the only
/// environment selected at thread creation. This is the SEED for a
/// fresh environment handle's `roster` (attach/detach grows the live
/// list from here in Phase 2a).
pub fn attached_targets() -> List(String) {
  ["workspace"]
}

/// True for the four compiled-in environment tool names (the catalog's
/// `is_compiled_name` lookup delegates here).
pub fn is_env_name(name: String) -> Bool {
  case name {
    "bash" | "read_file" | "write_file" | "list_dir" -> True
    _ -> False
  }
}

/// The thread's workspace directory: `<root>/<thread id>`. Lazy —
/// nothing creates it until the first environment tool call
/// (`ensure_workspace`).
pub fn workspace_dir(env: Environment) -> String {
  filepath.join(env.workspace_root, env.thread_id)
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

/// Validate a proposed node/roster target name before it enters the
/// live roster (environments plan Phase 2a): the charset rule shared
/// with plugin tool half-names, `workspace` reserved (it is the
/// thread's own environment and never attaches/detaches), no empty
/// name. Refusal is loud and honest — no name enters the roster that
/// would be ambiguous in `route`'s error or a roster line.
pub fn valid_target_name(name: String) -> Result(Nil, String) {
  case name {
    "" -> Error("target name must not be empty")
    "workspace" -> Error("target name 'workspace' is reserved")
    _ ->
      case string.split(name, "") |> list.all(fn(c) { is_name_char(c) }) {
        True -> Ok(Nil)
        False ->
          Error(
            "target name must match ^[a-zA-Z0-9_-]+$ (got \"" <> name <> "\")",
          )
      }
  }
}

fn is_name_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
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
/// subjects); every other name fails fast, and the error repeats the
/// full CURRENT attached list (the live roster) so a typo'd or
/// detached target self-heals on the next event.
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
          Error(
            "target \""
            <> target
            <> "\" is not attached. attached targets: "
            <> string.join(env.roster, ", "),
          )
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

/// Run one bash command in the routed environment's working directory.
/// The select loop is the codemode pattern over a port: {data,
/// exit_status, cancel, deadline}. `exit_status` 0 → Ok(output);
/// non-zero → Ok("exit status N" + output) — a failing command is
/// DATA, not a transport failure (the http_fetch non-2xx rule);
/// spawn/cancel/timeout are the errors, each honestly worded, and
/// cancel/timeout carry the partial output. The over-cap kill renders
/// the capped output as data with an omission note (like every other
/// truncation in the harness).
pub fn bash(
  timeout_ms timeout_ms: Int,
  max_output_bytes max_output_bytes: Int,
  environment environment: Option(Environment),
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_bash_args(arguments))
  use env <- result.try(route(environment, args.target))
  use _ <- result.try(ensure_workspace(env))
  use bash_path <- result.try(case ffi_resolve("bash") {
    Ok(path) -> Ok(path)
    Error(_) -> Error("bash: no bash executable found on PATH")
  })
  // Kill-tree hygiene (Linux): wrap in setsid so the bash becomes its
  // own session/group leader, and have it print its pid (== pgid) as
  // the FIRST stdout line — the loop parses it and `kill_tree` can
  // signal the whole group on cancel/timeout/cap. `-w` matters twice:
  // when setsid forks (its child already a group leader — never the
  // case for a fresh port child, but kept honest) the parent WAITS
  // and propagates the exit status, which the result encodes; without
  // it a forked setsid exits 0 and swallows the child's status
  // (verified against util-linux). Without setsid at all (macOS dev
  // machines) there is no marker and no pgid: the kill degrades to
  // port_close (direct child only) — the documented fallback.
  let setsid = ffi_resolve("setsid")
  // BOTH paths print the first-line pid marker: under setsid it is the
  // process-group id (the child is its own session leader); without
  // setsid it is still the direct child's pid, and the kill targets
  // THAT single process — port_close alone provably kills nothing
  // (CodeRabbit review: an owner-killed port left `/bin/sleep`
  // running). Descendants survive the fallback (documented posture).
  //
  // The death-with-port SENTINEL (cubic PR review) closes the window
  // no BEAM-side kill can: the owner dying before the marker pid was
  // parsed leaves every kill targetless, and port_close kills nothing.
  // A subshell inside the wrapper dup's the stdin pipe (fd 3) and
  // blocks reading it; EOF on that pipe means the PORT closed, and a
  // `kill -0 $$` check distinguishes the two closes — parent bash
  // still alive means the owner vanished mid-command (kill the tree
  // from inside, no pid handoff needed); parent gone means normal
  // completion, so deliberate background strays survive (the
  // documented posture). The command itself runs with stdin on
  // /dev/null — the port never writes stdin, and instant EOF beats
  // blocking on a writeless pipe.
  let sentinel_kill = case setsid {
    Ok(_) -> "kill -9 -- -$$"
    Error(_) -> "kill -9 $$"
  }
  let prelude =
    "printf '%d\\n' $$; exec 3<&0 0</dev/null; "
    <> "(while read -r _line <&3; do :; done; kill -0 $$ 2>/dev/null && "
    <> sentinel_kill
    <> ") >/dev/null 2>&1 & "
  let #(exe, argv, kill_group) = case setsid {
    Ok(setsid_path) -> #(
      setsid_path,
      ["-w", bash_path, "-c", prelude <> args.command],
      True,
    )
    Error(_) -> #(bash_path, ["-c", prelude <> args.command], False)
  }
  case ffi_open_port(exe, argv, workspace_dir(env)) {
    Error(reason) -> Error("bash: " <> reason)
    Ok(p) -> {
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
          watch(gate, mon, p, kill_group, None)
        })
      // The watchdog's gate handshake, degraded honestly instead of
      // asserted (cubic PR review): a scheduler delay past the budget
      // must answer the call, not crash the per-turn worker. Nothing
      // ran yet, so closing the port and refusing is clean.
      case process.receive(gate_back, 1000) {
        Error(Nil) -> {
          ffi_kill_tree(p, Error(Nil))
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
                kill_group: kill_group,
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
          // watchdog stands down (it demonitors and exits).
          process.send(gate, WatchDone)
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
/// watchdog fires the group kill on the owner's DOWN. It learns the
/// pgid when the executor parses the marker (WatchPgid); an owner
/// death before that degrades to port_close, no worse than before.
/// One tiny process per bash call, gone when the loop returns.
fn watch(
  gate: Subject(WatchMsg),
  mon: process.Monitor,
  p: Port,
  kill_group: Bool,
  pgid: Option(Int),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(gate, Gate)
    |> process.select_specific_monitor(mon, fn(_down) { OwnerDown })
  case process.selector_receive_forever(selector) {
    Gate(WatchPgid(n)) -> watch(gate, mon, p, kill_group, Some(n))
    Gate(WatchDone) -> {
      process.demonitor_process(mon)
      Nil
    }
    OwnerDown -> {
      ffi_kill_tree(p, case pgid, kill_group {
        Some(n), True -> Ok(ffi_kill_group(n))
        Some(n), False -> Ok(ffi_kill_pid(n))
        None, _ -> Error(Nil)
      })
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
    /// True under the setsid wrapper: the marker pid is a process-group
    /// id and kills target the whole group; false (wrapperless
    /// fallback): the marker pid is the direct child, killed alone.
    kill_group: Bool,
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
    Ok(Port(Exited(code))) -> finish(state, loop.max_output_bytes, code)
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
  // output): give the pid line its brief chance so the kill is armed
  // instead of a port_close that kills nothing.
  let state = case state.marker {
    MarkerPending -> await_marker(loop, state, timing.now_us())
    MarkerLeader(_) | MarkerAbsent -> state
  }
  ffi_kill_tree(loop.p, marker_kill(state.marker, loop.kill_group))
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
fn finish(
  state: BashState,
  max_output_bytes: Int,
  code: Int,
) -> Result(String, String) {
  let output = render_output(state, max_output_bytes)
  case code {
    0 -> Ok(output)
    n -> Ok("exit status " <> int.to_string(n) <> "\n" <> output)
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
              // Arm the watchdog's group kill with the parsed pgid.
              process.send(loop.watch, WatchPgid(n))
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

/// The kill-tree target: a parsed `MarkerLeader` pid — as a GROUP id
/// under the setsid wrapper, as the single direct pid in the
/// wrapperless fallback; `Error` when no marker was parsed (port_close
/// only).
fn marker_kill(
  marker: Marker,
  kill_group: Bool,
) -> Result(ErlangKillTarget, Nil) {
  case marker {
    MarkerLeader(n) ->
      case kill_group {
        True -> Ok(ffi_kill_group(n))
        False -> Ok(ffi_kill_pid(n))
      }
    MarkerPending | MarkerAbsent -> Error(Nil)
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
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_path_args(arguments, "read_file"))
  use env <- result.try(route(environment, args.target))
  use _ <- result.try(ensure_workspace(env))
  use path <- result.try(confined(env, args.path))
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
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_write_args(arguments))
  use env <- result.try(route(environment, args.target))
  use _ <- result.try(ensure_workspace(env))
  use path <- result.try(confined(env, args.path))
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
  arguments arguments: String,
) -> Result(String, String) {
  use args <- result.try(parse_path_args(arguments, "list_dir"))
  use env <- result.try(route(environment, args.target))
  use _ <- result.try(ensure_workspace(env))
  use path <- result.try(confined(env, args.path))
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

@external(erlang, "nexus_env_ffi", "open_port")
fn ffi_open_port(
  command: String,
  args: List(String),
  cwd: String,
) -> Result(Port, String)

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
