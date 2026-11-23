//// Offline tests for the environment domain (environments plan
//// Phase 1): the v1 workspace tools, target routing, confinement,
//// and the bash port loop's bounded paths. These run REAL local
//// processes (`bash`) in temp directories — no network, per the
//// offline-suite rule; the port machinery itself is the thing under
//// test, so faking it would test nothing.

import filepath
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import nexus/config
import nexus/env
import nexus/timing
import nexus/tools
import simplifile

/// A fresh workspace root per test: `/tmp/nexus-env-test-<now_us>`.
fn fresh_root() -> String {
  "/tmp/nexus-env-test-" <> int.to_string(timing.now_us())
}

fn env_for(root: String) -> Option(env.Environment) {
  Some(env.Environment(
    workspace_root: root,
    thread_id: "t1",
    workspace_rel_path: None,
    tmp_rel_path: None,
    roster: env.attached_targets(),
    remote: None,
  ))
}

fn bash(
  environment: Option(env.Environment),
  timeout_ms: Int,
  command: String,
) -> Result(String, String) {
  let cancel = process.new_subject()
  env.bash(
    timeout_ms: timeout_ms,
    max_output_bytes: 100_000,
    environment: environment,
    cancel: cancel,
    arguments: json_args([#("target", "workspace"), #("command", command)]),
  )
}

fn json_args(pairs: List(#(String, String))) -> String {
  "{"
  <> string.join(
    list.map(pairs, fn(p) {
      "\"" <> p.0 <> "\":\"" <> string.replace(p.1, "\\", "\\\\") <> "\""
    }),
    ",",
  )
  <> "}"
}

// ---------------------------------------------------------------------------
// Roster vocabulary and routing
// ---------------------------------------------------------------------------

pub fn attached_targets_test() {
  env.attached_targets()
  |> should_equal(["workspace"])
}

pub fn roster_texts_test() {
  // Both directions share the ONE tail-short shape: the full CURRENT
  // list, self-healing, with no direction (the human pane reads it
  // from the event stream).
  env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  |> should_equal("attached targets: workspace, proxmox-2.")
  env.roster_detach_text("proxmox-2", ["workspace"])
  |> should_equal("attached targets: workspace.")
}

pub fn roster_parse_roundtrips_test() {
  // The inverse of the tail line (Phase 2b hydration re-derivation): a
  // roster line parses back to its list, and a non-roster line is `None`.
  // The serialized inputs come from the EMITTERS (attach/detach), so a
  // change to the emitters cannot silently break hydration — the
  // round-trip is asserted end to end, not against hardcoded strings.
  env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  |> env.roster_parse
  |> should_equal(Some(["workspace", "proxmox-2"]))
  env.roster_detach_text("proxmox-2", ["workspace"])
  |> env.roster_parse
  |> should_equal(Some(["workspace"]))
  // Not a roster line: a plain user message or bot-authored row is None.
  env.roster_parse("what is the weather?")
  |> should_equal(None)
  // Tolerant of a missing trailing dot (defensive on hand-written rows).
  env.roster_parse("attached targets: workspace")
  |> should_equal(Some(["workspace"]))
}

pub fn valid_target_name_test() {
  let assert Ok(Nil) = env.valid_target_name("proxmox-2")
  let assert Ok(Nil) = env.valid_target_name("node_a_1")
  // Reserved: the thread's own workspace never attaches/detaches.
  let assert Error(_) = env.valid_target_name("workspace")
  // Empty and charset violations refuse loudly.
  let assert Error(_) = env.valid_target_name("")
  let assert Error(_) = env.valid_target_name("bad name")
  let assert Error(_) = env.valid_target_name("bad/name")
}

pub fn is_env_name_test() {
  let assert True = env.is_env_name("bash")
  let assert True = env.is_env_name("read_file")
  let assert True = env.is_env_name("write_file")
  let assert True = env.is_env_name("list_dir")
  let assert False = env.is_env_name("http_fetch")
  let assert False = env.is_env_name("bash__x")
}

pub fn unknown_target_fails_fast_test() {
  let cancel = process.new_subject()
  let result =
    env.bash(
      timeout_ms: 1000,
      max_output_bytes: 1000,
      environment: env_for(fresh_root()),
      cancel: cancel,
      arguments: "{\"target\":\"proxmox-2\",\"command\":\"echo hi\"}",
    )
  // The self-healing shape: the full attached list repeats.
  let assert Error(
    "target \"proxmox-2\" is not attached. attached targets: workspace",
  ) = result
}

// ---------------------------------------------------------------------------
// Node-side serving (2b-5: the TUI's tool plane)
// ---------------------------------------------------------------------------

fn node_for(root: String) -> env.Environment {
  env.Environment(
    workspace_root: root,
    thread_id: "srv-thread",
    workspace_rel_path: None,
    tmp_rel_path: None,
    roster: env.attached_targets(),
    remote: None,
  )
}

pub fn serve_node_call_routes_to_local_test() {
  // The node IS the target the server routed to: arguments naming the
  // NODE (not "workspace") execute on the Phase 1 local path anyway —
  // the parsed target is rewritten to the reserved local value before
  // route, so `route`'s honest not-routable refusal for attached-but-
  // unroutable names never bites the node's own calls.
  let root = fresh_root()
  let assert Ok(text) =
    env.serve_node_call(
      handle: node_for(root),
      tool: "bash",
      arguments: "{\"target\":\"tui-node\",\"command\":\"echo served\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: process.new_subject(),
    )
  string.contains(text, "served") |> should_equal(True)
  // Lazy workspace creation still applies, scoped by the handle's
  // thread id.
  simplifile.is_directory(root <> "/srv-thread") |> should_equal(Ok(True))
  let _ = simplifile.delete(root)
}

pub fn serve_node_call_file_tools_test() {
  let root = fresh_root()
  let handle = node_for(root)
  let cancel = process.new_subject()
  let assert Ok(wrote) =
    env.serve_node_call(
      handle: handle,
      tool: "write_file",
      arguments: "{\"target\":\"tui-node\",\"path\":\"a.txt\",\"content\":\"data\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  let assert Ok(read) =
    env.serve_node_call(
      handle: handle,
      tool: "read_file",
      arguments: "{\"target\":\"tui-node\",\"path\":\"a.txt\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  wrote |> should_equal("wrote 4 bytes to a.txt")
  read |> should_equal("data")
  let assert Ok(listing) =
    env.serve_node_call(
      handle: handle,
      tool: "list_dir",
      arguments: "{\"target\":\"tui-node\",\"path\":\"\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  string.contains(listing, "a.txt") |> should_equal(True)
  let _ = simplifile.delete(root)
}

pub fn serve_node_call_refusals_test() {
  let root = fresh_root()
  let handle = node_for(root)
  let cancel = process.new_subject()
  // Unknown tool name: a node serves the four compiled env tools only.
  let assert Error(reason) =
    env.serve_node_call(
      handle: handle,
      tool: "web_search",
      arguments: "{}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  reason |> should_equal("this node does not serve the tool \"web_search\"")
  // Malformed arguments propagate the parser's error, not a crash.
  let assert Error(_) =
    env.serve_node_call(
      handle: handle,
      tool: "bash",
      arguments: "{\"command\":\"echo hi\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  // Confinement still applies on the node side: an escaping path
  // refuses exactly as it does in the server's own workspace.
  let assert Error(_) =
    env.serve_node_call(
      handle: handle,
      tool: "read_file",
      arguments: "{\"target\":\"tui-node\",\"path\":\"../outside.txt\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: cancel,
    )
  let _ = simplifile.delete(root)
}

pub fn serve_node_call_nonzero_exit_is_data_test() {
  let root = fresh_root()
  let assert Ok(text) =
    env.serve_node_call(
      handle: node_for(root),
      tool: "bash",
      arguments: "{\"target\":\"tui-node\",\"command\":\"exit 7\"}",
      timeout_ms: 10_000,
      max_output_bytes: 10_000,
      cancel: process.new_subject(),
    )
  string.starts_with(text, "exit status 7") |> should_equal(True)
  let _ = simplifile.delete(root)
}

pub fn route_names_live_roster_test() {
  // The 2a observable: `route` reads the handle's ROSTER (not the
  // compiled constant), so an attached list is what the fail-fast error
  // names. `workspace` still routes to execution; a non-workspace
  // member is attached-by-name but not routable yet (2b wires it).
  let env =
    env.Environment(
      workspace_root: "/srv/nexus",
      thread_id: "s12",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: [
        "workspace",
        "proxmox-2",
      ],
      remote: None,
    )
  let assert Ok(_) = env.route(Some(env), "workspace")
  let assert Error(
    "target \"typo\" is not attached. attached targets: workspace, proxmox-2",
  ) = env.route(Some(env), "typo")
}

pub fn no_environment_handle_errors_honestly_test() {
  let cancel = process.new_subject()
  let assert Error("this thread has no environment attached") =
    env.bash(
      timeout_ms: 1000,
      max_output_bytes: 1000,
      environment: None,
      cancel: cancel,
      arguments: "{\"target\":\"workspace\",\"command\":\"echo hi\"}",
    )
}

// ---------------------------------------------------------------------------
// bash
// ---------------------------------------------------------------------------

pub fn bash_runs_in_workspace_cwd_test() {
  let root = fresh_root()
  let assert Ok(out) = bash(env_for(root), 5000, "pwd")
  // cwd default is the per-thread workspace dir.
  let assert True =
    string.contains(
      out,
      env.workspace_dir(env.Environment(
        workspace_root: root,
        thread_id: "t1",
        workspace_rel_path: None,
        tmp_rel_path: None,
        roster: env.attached_targets(),
        remote: None,
      )),
    )
  let _ = simplifile.delete(root)
}

/// Plant a canary in the EMULATOR's environment (the test FFI
/// converts binaries to the lists os:putenv demands). A plain port
/// would hand that environment to the child — the scrubbed spawn
/// must not carry it across.
@external(erlang, "nexus_env_test_ffi", "put_env")
fn put_env(name: String, value: String) -> Nil

@external(erlang, "nexus_env_test_ffi", "unset_env")
fn unset_env(name: String) -> Nil

@external(erlang, "nexus_env_test_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

/// Restore a stomped variable to its ORIGINAL value — unset only when
/// it was absent before the plant (OCR review: an unconditional unset
/// destroys a machine's real CA config for the rest of the run).
fn restore(name: String, original: Result(String, Nil)) -> Nil {
  case original {
    Ok(value) -> put_env(name, value)
    Error(Nil) -> unset_env(name)
  }
}

pub fn bash_environment_is_allowlisted_test() {
  let root = fresh_root()
  let original_cert = get_env("SSL_CERT_FILE")
  let original_tz = get_env("TZ")
  let original_tmp = get_env("TMPDIR")
  put_env("NEXUS_TEST_SECRET_CANARY", "hunter2-database-url")
  put_env("SSL_CERT_FILE", root <> "/fake-ca.pem")
  put_env("TZ", "UTC")
  put_env("TMPDIR", "/tmp/host-tmpdir-canary")
  // Failure-safe cleanup (OCR review): bind WITHOUT asserting first, so
  // a failing bash call cannot skip the restore and leave the plants in
  // the emulator's process-global environment for the rest of the run.
  let out = bash(env_for(root), 5000, "env")
  unset_env("NEXUS_TEST_SECRET_CANARY")
  restore("SSL_CERT_FILE", original_cert)
  restore("TZ", original_tz)
  restore("TMPDIR", original_tmp)
  let assert Ok(out) = out
  // The BEAM's secrets do NOT ride into the child (#126): the canary
  // planted in the emulator's own environment is absent…
  let assert False = string.contains(out, "hunter2-database-url")
  let assert False = string.contains(out, "NEXUS_TEST_SECRET_CANARY")
  // Host TMPDIR is scrubbed when tmp_rel_path is None (legacy / TUI).
  let assert False = string.contains(out, "TMPDIR=")
  let assert False = string.contains(out, "host-tmpdir-canary")
  // …while the allowlist keeps the child working: PATH resolves bare
  // names, HOME is REWRITTEN to the workspace dir (not the operator's
  // home, which may well be this test's real HOME).
  let assert True = string.contains(out, "PATH=")
  let ws =
    env.workspace_dir(env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: env.attached_targets(),
      remote: None,
    ))
  let assert True = string.contains(out, "HOME=" <> ws)
  // CA paths pass through (OCR review): non-secret, and dropping them
  // breaks TLS on env-configured systems. TZ's "when set" half of the
  // passthrough is pinned the same way.
  let assert True = string.contains(out, "SSL_CERT_FILE=" <> root)
  let assert True = string.contains(out, "TZ=UTC")
  // Bare-name resolution really works through the passed PATH.
  let assert Ok(tr) = bash(env_for(root), 5000, "command -v cat")
  let assert True = string.contains(tr, "/cat")
  let _ = simplifile.delete(root)
}

pub fn bash_sets_and_lazily_creates_per_thread_tmpdir_test() {
  let root = fresh_root()
  let handle =
    env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: Some("threads/t1"),
      tmp_rel_path: Some("tmp/t1"),
      roster: env.attached_targets(),
      remote: None,
    )
  let expected_tmp = filepath.join(root, "tmp/t1")
  env.tmp_dir(handle) |> should_equal(Some(expected_tmp))
  // Lazy creation: the tmp directory does not exist before bash runs.
  simplifile.is_directory(expected_tmp) |> should_equal(Ok(False))

  let original_tmp = get_env("TMPDIR")
  put_env("TMPDIR", "/tmp/host-tmpdir-canary")
  let out =
    bash(
      Some(handle),
      5000,
      "printf '%s' $TMPDIR && printf 'hi' > $TMPDIR/scratch.txt",
    )
  restore("TMPDIR", original_tmp)

  let assert Ok(got_tmp) = out
  got_tmp |> should_equal(expected_tmp)
  simplifile.is_directory(expected_tmp) |> should_equal(Ok(True))
  simplifile.read(filepath.join(expected_tmp, "scratch.txt"))
  |> should_equal(Ok("hi"))
  let _ = simplifile.delete(root)
}

pub fn bash_exit_status_is_data_test() {
  let root = fresh_root()
  let assert Ok(out) = bash(env_for(root), 5000, "echo oops >&2; exit 3")
  // A failing command is data: the status rides the result, the call
  // itself succeeds (the http_fetch non-2xx rule).
  let assert True = string.contains(out, "exit status 3")
  let assert True = string.contains(out, "oops")
  let _ = simplifile.delete(root)
}

pub fn bash_stderr_merges_test() {
  let root = fresh_root()
  let assert Ok(out) = bash(env_for(root), 5000, "echo to-err >&2")
  let assert True = string.contains(out, "to-err")
  let _ = simplifile.delete(root)
}

pub fn bash_timeout_kills_and_reports_partial_test() {
  let root = fresh_root()
  let assert Error(text) = bash(env_for(root), 400, "echo partial; sleep 30")
  let assert True = string.contains(text, "timed out after 400 ms")
  let assert True = string.contains(text, "partial")
  let _ = simplifile.delete(root)
}

pub fn bash_timeout_kills_background_children_test() {
  // The group kill is the setsid path's guarantee; a host without
  // setsid (macOS dev machines) kills only the direct child by
  // design — skip, not fail (cubic PR review).
  case bash(env_for("/tmp"), 5000, "command -v setsid") {
    Error("bash: no bash executable found on PATH") -> Nil
    Ok("exit status 1" <> _) -> Nil
    _ -> {
      bash_timeout_kills_background_children_with_group_kill()
      Nil
    }
  }
}

fn bash_timeout_kills_background_children_with_group_kill() {
  let root = fresh_root()
  // A background child that outlives the foreground: the group kill
  // (setsid + pgid) must reap it with the timeout. The child is
  // RENAMED (`exec -a`) so its own argv carries a unique tag, and the
  // probe pattern uses the classic `[x]` bracket so the PROBE's
  // command line (which contains the pattern text) cannot match
  // itself (a `#` comment cannot carry the tag — bash strips it from
  // the spawned argv entirely).
  let tag = "nxenvbg" <> int.to_string(timing.now_us())
  let assert Error(_) =
    bash(env_for(root), 500, "exec -a " <> tag <> "sleep sleep 30 & sleep 30")
  // The kill helper is a detached process: poll briefly for the child
  // to disappear (pgrep exits 1 when nothing matches).
  let probe = "pgrep -f '" <> tag <> "slee[p]'"
  let gone = poll_gone(probe, 25)
  let _ = simplifile.delete(root)
  let assert True = gone
}

fn poll_gone(probe: String, attempts: Int) -> Bool {
  case bash(env_for("/tmp"), 5000, probe) {
    // No match: pgrep exited 1 — the child is gone.
    Ok("exit status 1" <> _) -> True
    // No bash/pgrep on this machine: cannot verify, do not fail.
    Error("bash: no bash executable found on PATH") -> True
    _ ->
      case attempts {
        0 -> False
        n -> {
          process.sleep(200)
          poll_gone(probe, n - 1)
        }
      }
  }
}

pub fn bash_cancel_replies_and_resignals_test() {
  // The subject-owner rule (AGENTS.md pitfall): the cancel subject
  // must be created and received on by the process running the tool —
  // a spawned worker, signalled by a timer sibling.
  let root = fresh_root()
  let reply = process.new_subject()
  let worker =
    process.spawn(fn() {
      let cancel = process.new_subject()
      let timer =
        process.spawn(fn() {
          process.sleep(300)
          process.send(cancel, Nil)
        })
      let _ = timer
      let result =
        env.bash(
          timeout_ms: 60_000,
          max_output_bytes: 100_000,
          environment: env_for(root),
          cancel: cancel,
          arguments: "{\"target\":\"workspace\",\"command\":\"echo before-cancel; sleep 30\"}",
        )
      // The one-shot cancel subject must be RE-SIGNALLED by the
      // executor (the codemode rule): the worker observes the Nil it
      // put back.
      let resignalled = process.receive(cancel, 1000)
      process.send(reply, #(result, resignalled))
    })
  let _ = worker
  let assert Ok(#(result, resignalled)) = process.receive(reply, 5000)
  let _ = simplifile.delete(root)
  let assert Error(text) = result
  let assert True = string.contains(text, "cancelled")
  let assert True = string.contains(text, "before-cancel")
  // The re-signal: the executor consumed the timer's Nil and put it
  // back for the loop's LAST-call path.
  let assert Ok(Nil) = resignalled
}

pub fn bash_output_cap_truncates_and_kills_test() {
  let root = fresh_root()
  // The generator keeps producing past the cap; the executor kills it
  // and returns the capped output with the omission note.
  let assert Ok(out) =
    env.bash(
      timeout_ms: 10_000,
      max_output_bytes: 1000,
      environment: env_for(root),
      cancel: process.new_subject(),
      arguments: "{\"target\":\"workspace\",\"command\":\"for i in $(seq 1 100000); do echo 0123456789012345678901234567890123456789; done\"}",
    )
  let _ = simplifile.delete(root)
  let assert True =
    string.contains(
      out,
      "[... output exceeded 1000 bytes; the command was killed ...]",
    )
}

/// Smart-loop S1: when the first stdout line is NOT the pid marker (a
/// bash syntax error means `printf` never ran either), the line is
/// REAL OUTPUT — the diagnostic the model needs to self-correct must
/// survive, and the marker expectation must not re-arm and swallow
/// successor lines.
pub fn bash_marker_parse_failure_keeps_output_test() {
  let root = fresh_root()
  let assert Ok(out) = bash(env_for(root), 5000, "echo 'unterminated")
  let _ = simplifile.delete(root)
  let assert True = string.contains(out, "exit status 2")
  let assert True = string.contains(out, "unexpected EOF")
}

/// Multi-line output after a successful marker stays in order (the
/// marker-absent path is the syntax-error test above — the marker
/// always precedes a command's own output when it prints at all).
pub fn bash_multiline_output_after_marker_test() {
  let root = fresh_root()
  let assert Ok(out) = bash(env_for(root), 5000, "echo notanumber; echo hello")
  let _ = simplifile.delete(root)
  let assert True = string.contains(out, "notanumber")
  let assert True = string.contains(out, "hello")
}

/// The death-with-port sentinel (cubic PR review): the owner dying
/// mid-command — even before the BEAM side ever parses the pid
/// marker — must reap the whole process group. The sentinel lives
/// inside the wrapper (a subshell watching the dup'd stdin pipe), so
/// the kill does not depend on any BEAM-side pid handoff.
/// Synchronization is ps-based (cubic PR review): the presence probe
/// waits for the WRAPPER bash's own command line, which carries the
/// per-run tag from spawn — before the marker is read BEAM-side and
/// before the tagged child forks — so the owner's death lands in the
/// pre-handoff window (watchdog unarmed, sentinel-only cleanup) and
/// the disappearance probe cannot pass vacuously.
pub fn bash_owner_death_kills_group_test() {
  let root = fresh_root()
  let e = env_for(root)
  let done = process.new_subject()
  // PER-RUN tag (CodeRabbit review): an orphan from a failed earlier
  // run could satisfy a fixed tag's presence probe and let both
  // checks pass vacuously. The trailing letter pairs with the
  // bracketed probe patterns (which the probe's own command line
  // cannot match).
  let uniq = int.to_string(timing.now_us())
  let tag = "nxown" <> uniq <> "q"
  // UNLINKED: process.spawn links, and killing a linked owner would
  // propagate the `killed` exit reason into this test's own process.
  let owner =
    process.spawn_unlinked(fn() {
      let cancel = process.new_subject()
      let _ =
        env.bash(
          timeout_ms: 60_000,
          max_output_bytes: 100_000,
          environment: e,
          cancel: cancel,
          arguments: "{\"target\":\"workspace\",\"command\":\"exec -a "
            <> tag
            <> " sleep 45 & sleep 45\"}",
        )
      process.sleep(60_000)
    })
  // SYNCHRONIZE on the WRAPPER's ps line (CodeRabbit review): the
  // tag appears in the wrapper bash's own command line (the -c script
  // names it), which exists from spawn — BEFORE the marker pid has
  // been read by the executor and BEFORE the tagged child forks. The
  // owner therefore dies in the PRE-HANDOFF window (the watchdog has
  // no parsed pgid), where the die-with-port sentinel is the only
  // cleanup — and the presence probe makes the disappearance probe
  // non-vacuous: the group provably existed.
  poll_tag_present("nxown" <> uniq <> "[q]", 50)
  process.kill(owner)
  process.send(done, Nil)
  let assert Ok(Nil) = process.receive(done, 1000)
  // The sentinel fires on the port's EOF; give it a moment, then the
  // whole group (wrapper and any forked child, both matching the tag
  // in ps) must be gone.
  poll_tag_gone("nxown" <> uniq <> "[q]", 50)
  let _ = simplifile.delete(root)
}

fn poll_tag_gone(pattern: String, attempts: Int) -> Nil {
  case
    bash(
      env_for("/tmp"),
      5000,
      "ps -eo cmd | grep -c '" <> pattern <> "' || true",
    )
  {
    // "0" means only the probe's own pipeline counted zero matches.
    Ok("0") -> Nil
    Ok("exit status 1" <> _) -> Nil
    Error("bash: no bash executable found on PATH") -> Nil
    _ ->
      case attempts {
        0 -> panic as "owner-death group kill did not reap the tagged child"
        n -> {
          process.sleep(200)
          poll_tag_gone(pattern, n - 1)
        }
      }
  }
}

/// A mid-command cancel (CodeRabbit review): the tagged child
/// provably started (the command touches a marker file first), the
/// cancel lands while it runs, the result is `cancelled`, the
/// one-shot re-signal is observable afterward, and the whole tree —
/// including the tagged background child — is gone. Whether the pid
/// marker had been parsed BEAM-side at cancel time is immaterial: the
/// sentinel reaps the group at the port's EOF either way.
pub fn bash_cancel_midrun_reaps_group_and_signal_test() {
  let root = fresh_root()
  let reply = process.new_subject()
  // The worker hands its cancel subject to the test BEFORE starting
  // the call (CodeRabbit review): the test then provably observes the
  // tagged child running — not a marker file the command touches
  // before forking it — and only then delivers the cancel. Sending on
  // a subject is legal from any process; only receiving is
  // owner-restricted, and the worker keeps that.
  let handoff = process.new_subject()
  // PER-RUN tag (CodeRabbit review): same orphan-aliasing hazard as
  // the owner-death test.
  let uniq = int.to_string(timing.now_us())
  let tag = "nxcancel" <> uniq <> "q"
  let worker =
    process.spawn_unlinked(fn() {
      let cancel = process.new_subject()
      process.send(handoff, cancel)
      let result =
        env.bash(
          timeout_ms: 60_000,
          max_output_bytes: 100_000,
          environment: env_for(root),
          cancel: cancel,
          arguments: "{\"target\":\"workspace\",\"command\":\"exec -a "
            <> tag
            <> " sleep 45 & sleep 45\"}",
        )
      let again = process.receive(cancel, 2000)
      process.send(reply, #(result, again))
    })
  let _ = worker
  let assert Ok(cancel) = process.receive(handoff, 5000)
  // The tagged child itself is up (its ps line is "nxcancel9x 45" —
  // exec -a replaces argv[0]; the bracketed probe cannot match its
  // own command line).
  poll_tag_present("nxcancel" <> uniq <> "[q] 4[5]", 50)
  process.send(cancel, Nil)
  let assert Ok(#(result, again)) = process.receive(reply, 30_000)
  let assert Error(text) = result
  let assert True = string.contains(text, "cancelled")
  let assert Ok(Nil) = again
  poll_tag_gone("nxcancel" <> uniq <> "[q]", 50)
  let _ = simplifile.delete(root)
}

/// Poll until the tagged process's ps line exists — the positive half
/// of `poll_tag_gone`, so a disappearance probe can never pass
fn poll_tag_present(pattern: String, attempts: Int) -> Nil {
  case
    bash(
      env_for("/tmp"),
      10_000,
      "ps -eo cmd | grep -c '" <> pattern <> "' || true",
    )
  {
    Ok(n) ->
      case int.parse(string.trim(n)) {
        Ok(count) if count > 0 -> Nil
        _ -> retry_present(pattern, attempts)
      }
    Error("bash: no bash executable found on PATH") -> Nil
    _ -> retry_present(pattern, attempts)
  }
}

fn retry_present(pattern: String, attempts: Int) -> Nil {
  case attempts {
    0 -> panic as "tagged child never appeared"
    n -> {
      process.sleep(200)
      poll_tag_present(pattern, n - 1)
    }
  }
}

pub fn bash_empty_output_marker_test() {
  let root = fresh_root()
  let assert Ok("(no output)") = bash(env_for(root), 5000, "true")
  let _ = simplifile.delete(root)
}

pub fn bash_invalid_arguments_test() {
  let root = fresh_root()
  let assert Error("bash requires a non-empty `command`") =
    bash(env_for(root), 1000, "")
  let assert Error("invalid bash arguments: {\"target\", \"command\"}") =
    env.bash(
      timeout_ms: 1000,
      max_output_bytes: 100,
      environment: env_for(root),
      cancel: process.new_subject(),
      arguments: "not json",
    )
}

// ---------------------------------------------------------------------------
// fs tools
// ---------------------------------------------------------------------------

pub fn fs_round_trip_test() {
  let root = fresh_root()
  let e = env_for(root)
  let assert Ok(msg) =
    env.write_file(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/dir/notes.md\",\"content\":\"hello workspace\"}",
    )
  let assert True = string.contains(msg, "sub/dir/notes.md")
  let assert Ok("hello workspace") =
    env.read_file(
      max_output_bytes: 10_000,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/dir/notes.md\"}",
    )
  let assert Ok(listing) =
    env.list_dir(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\"}",
    )
  let assert True = string.contains(listing, "sub/")
  let _ = simplifile.delete(root)
}

/// Smart-loop S2: a file of EXACTLY the cap is not truncated —
/// truncation is claimed only when a byte was actually cut.
pub fn read_file_exact_cap_not_truncated_test() {
  let root = fresh_root()
  let e = env_for(root)
  let assert Ok(_) =
    env.write_file(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"exact.txt\",\"content\":\"abcd\"}",
    )
  let assert Ok("abcd") =
    env.read_file(
      max_output_bytes: 4,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"exact.txt\"}",
    )
  let _ = simplifile.delete(root)
}

pub fn read_file_cap_truncates_test() {
  let root = fresh_root()
  let e = env_for(root)
  let assert Ok(_) =
    env.write_file(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"big.txt\",\"content\":\"0123456789abcdefghij\"}",
    )
  let assert Ok(text) =
    env.read_file(
      max_output_bytes: 4,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"big.txt\"}",
    )
  let _ = simplifile.delete(root)
  let assert True = string.contains(text, "0123")
  let assert True = string.contains(text, "[... truncated at 4 bytes ...]")
}

/// Cubic PR review (P1): a workspace FIFO would block the turn
/// worker's open/read indefinitely — `bash` can create one inside the
/// workspace, so both fs tools refuse non-regular files instead of
/// touching them.
pub fn fifo_refused_by_fs_tools_test() {
  let root = fresh_root()
  let e = env_for(root)
  let assert Ok(_) = bash(env_for(root), 5000, "mkfifo pipe; mkfifo pipe2")
  // Reading a FIFO blocks until a writer appears — refused, not read.
  let assert Error("read_file: not a regular file: pipe") =
    env.read_file(
      max_output_bytes: 100,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"pipe\"}",
    )
  // Writing one blocks until a reader appears — refused too.
  let assert Error("write_file: not a regular file: pipe2") =
    env.write_file(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"pipe2\",\"content\":\"x\"}",
    )
  // Regular files are unaffected.
  let assert Ok(_) =
    env.write_file(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"plain.txt\",\"content\":\"ok\"}",
    )
  let _ = simplifile.delete(root)
}

/// Directories keep their honest read error under the regular-file
/// guard.
pub fn read_file_directory_refused_test() {
  let root = fresh_root()
  let e = env_for(root)
  // The workspace root itself is a directory (a subdirectory would
  // need creating first — "." is always there).
  let assert Error("read_file: not a regular file: .") =
    env.read_file(
      max_output_bytes: 100,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\".\"}",
    )
  let _ = simplifile.delete(root)
}

pub fn list_dir_root_and_missing_test() {
  let root = fresh_root()
  let e = env_for(root)
  // Path omitted = the workspace root.
  let assert Ok("(empty)") =
    env.list_dir(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\"}",
    )
  let assert Error("list_dir: not a directory: nope") =
    env.list_dir(
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"nope\"}",
    )
  let _ = simplifile.delete(root)
}

// ---------------------------------------------------------------------------
// Confinement
// ---------------------------------------------------------------------------

pub fn path_escape_refused_test() {
  let root = fresh_root()
  let e = env_for(root)
  let assert Error("path escapes the workspace: ../../etc/passwd") =
    env.read_file(
      max_output_bytes: 100,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"../../etc/passwd\"}",
    )
  let assert Error(_) =
    env.read_file(
      max_output_bytes: 100,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"/etc/passwd\"}",
    )
  // A normalized-inside path stays fine: `sub/../x` folds to the
  // workspace's own `x` (the honest read error names the file).
  let assert Error("read_file: file not found") =
    env.read_file(
      max_output_bytes: 100,
      cancel: process.new_subject(),
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/../x\"}",
    )
  let _ = simplifile.delete(root)
}

pub fn confinement_normalization_test() {
  let e =
    env.Environment(
      workspace_root: "/srv/nexus",
      thread_id: "s12",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: env.attached_targets(),
      remote: None,
    )
  let assert Ok("/srv/nexus/s12") = env.confined(e, ".")
  // `a/../..` folds ABOVE the workspace root: refused (the pop is
  // lexical — it cannot take the path past the confinement check).
  let assert Error(_) = env.confined(e, "a/../..")
  let assert Ok("/srv/nexus/s12/data/x") = env.confined(e, "a/../data/x")
  let assert Error(_) = env.confined(e, "a/../../x")
}

// ---------------------------------------------------------------------------
// Workspace directory
// ---------------------------------------------------------------------------

pub fn workspace_dir_derivation_test() {
  env.workspace_dir(env.Environment(
    workspace_root: "/srv/nx",
    thread_id: "s3",
    workspace_rel_path: None,
    tmp_rel_path: None,
    roster: env.attached_targets(),
    remote: None,
  ))
  |> should_equal("/srv/nx/s3")
}

fn should_equal(got: a, want: a) -> Nil {
  case got == want {
    True -> Nil
    False ->
      panic as {
        "expected:\n  "
        <> string.inspect(want)
        <> "\ngot:\n  "
        <> string.inspect(got)
      }
  }
}

// ---------------------------------------------------------------------------
// Remote dispatch (environments plan Phase 2b-2)
// ---------------------------------------------------------------------------

/// A capturing router: records `(target, tool, raw arguments)` into
/// `seen` (same-process send — received after the executor returns)
/// and answers a canned result.
fn capture_router(
  seen: process.Subject(#(String, String, String)),
) -> env.RemoteRouter {
  fn(target, tool, arguments, _cancel) {
    process.send(seen, #(target, tool, arguments))
    Ok("from the node: " <> tool)
  }
}

pub fn remote_dispatch_routes_all_four_tools_test() {
  let seen = process.new_subject()
  let handle =
    Some(env.Environment(
      workspace_root: "/srv/nx",
      thread_id: "t1",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: ["workspace", "node-a"],
      remote: Some(capture_router(seen)),
    ))
  let cancel = process.new_subject()

  // bash: the whole call goes to the node — tool name + RAW arguments.
  let assert Ok("from the node: bash") =
    env.bash(
      timeout_ms: 5000,
      max_output_bytes: 1000,
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\",\"command\":\"uptime\"}",
    )
  let assert Ok(#(
    "node-a",
    "bash",
    "{\"target\":\"node-a\",\"command\":\"uptime\"}",
  )) = process.receive(seen, 1000)

  let assert Ok("from the node: read_file") =
    env.read_file(
      max_output_bytes: 1000,
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\",\"path\":\"x\"}",
    )
  let assert Ok(#(
    "node-a",
    "read_file",
    "{\"target\":\"node-a\",\"path\":\"x\"}",
  )) = process.receive(seen, 1000)

  let assert Ok("from the node: write_file") =
    env.write_file(
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\",\"path\":\"x\",\"content\":\"y\"}",
    )
  let assert Ok(#(
    "node-a",
    "write_file",
    "{\"target\":\"node-a\",\"path\":\"x\",\"content\":\"y\"}",
  )) = process.receive(seen, 1000)

  let assert Ok("from the node: list_dir") =
    env.list_dir(
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\"}",
    )
  let assert Ok(#("node-a", "list_dir", "{\"target\":\"node-a\"}")) =
    process.receive(seen, 1000)
}

pub fn remote_errors_pass_through_test() {
  // The router's Error is the tool result verbatim (a failed tool
  // result, never a loop error).
  let handle =
    Some(env.Environment(
      workspace_root: "/srv/nx",
      thread_id: "t1",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: ["workspace", "node-a"],
      remote: Some(fn(_t, _tool, _args, _c) {
        Error("target \"node-a\" is not attached. attached targets: workspace")
      }),
    ))
  let cancel = process.new_subject()
  let assert Error(
    "target \"node-a\" is not attached. attached targets: workspace",
  ) =
    env.bash(
      timeout_ms: 5000,
      max_output_bytes: 1000,
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\",\"command\":\"uptime\"}",
    )
}

pub fn remote_none_falls_back_to_local_route_test() {
  // A handle with no router wired (a hand-built value): the local
  // path's `route` answers — the honest not-routable wording, never a
  // "not attached" lie about a name the roster snapshot carries.
  let handle =
    Some(env.Environment(
      workspace_root: "/srv/nx",
      thread_id: "t1",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: ["workspace", "node-a"],
      remote: None,
    ))
  let cancel = process.new_subject()
  let assert Error(reason) =
    env.bash(
      timeout_ms: 5000,
      max_output_bytes: 1000,
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"node-a\",\"command\":\"uptime\"}",
    )
  should.equal(
    reason,
    "target \"node-a\" is attached but not routable (its node is not connected)",
  )
}

pub fn workspace_target_never_dispatches_remotely_test() {
  // `workspace` stays the LOCAL path: the router must not fire, and a
  // real write lands in the local workspace root.
  let root = fresh_root()
  let seen = process.new_subject()
  let handle =
    Some(env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: ["workspace"],
      remote: Some(capture_router(seen)),
    ))
  let cancel = process.new_subject()
  let assert Ok(_) =
    env.write_file(
      environment: handle,
      cancel: cancel,
      arguments: "{\"target\":\"workspace\",\"path\":\"local.txt\",\"content\":\"hi\"}",
    )
  let assert Ok(True) =
    simplifile.is_file(filepath.join(filepath.join(root, "t1"), "local.txt"))
  // No router call was recorded.
  should.equal(Error(Nil), process.receive(seen, 0))
  let _ = simplifile.delete(root)
}

// ---------------------------------------------------------------------------
// Phase 2: sandbox spawn planning (offline, pure)
// ---------------------------------------------------------------------------

fn fake_probe(
  resolved resolved: List(#(String, String)),
  executables executables: List(String),
  existing existing: List(String),
  dirs dirs: List(String),
  inherited_path inherited_path: String,
  cgroup_dir cgroup_dir: Option(String),
) -> env.HostProbe {
  let resolve_map = dict.from_list(resolved)
  env.HostProbe(
    resolve: fn(name) { dict.get(resolve_map, name) },
    is_executable: fn(path) { list.contains(executables, path) },
    path_exists: fn(path) {
      list.contains(existing, path)
      || list.contains(dirs, path)
      || list.contains(executables, path)
    },
    is_dir: fn(path) { list.contains(dirs, path) },
    inherited_path: inherited_path,
    cgroup_dir: cgroup_dir,
  )
}

pub fn sandbox_plan_none_matches_phase1_test() {
  let host =
    fake_probe(
      resolved: [#("bash", "/usr/bin/bash"), #("setsid", "/usr/bin/setsid")],
      executables: ["/usr/bin/bash", "/usr/bin/setsid"],
      existing: [],
      dirs: [],
      inherited_path: "/usr/bin:/bin",
      cgroup_dir: None,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: env.default_sandbox(),
      host: host,
      workspace_dir: "/srv/ws/threads/t1",
      tmp_dir: Some("/srv/ws/tmp/t1"),
      command: "echo hi",
    )
  plan.exe |> should_equal("/usr/bin/setsid")
  plan.kill_mode |> should_equal(env.KillGroup)
  plan.allow_env
  |> should_equal([
    #("HOME", "/srv/ws/threads/t1"),
    #("PATH", "/usr/bin:/bin"),
    #("TMPDIR", "/srv/ws/tmp/t1"),
  ])
  plan.passthrough_env |> should_equal(["TZ", "SSL_CERT_FILE", "SSL_CERT_DIR"])
  let assert ["-w", "/usr/bin/bash", "-c", script] = plan.argv
  string.ends_with(script, "echo hi") |> should_equal(True)

  // Without setsid, falls back to direct bash + KillPid.
  let host_no_setsid =
    fake_probe(
      resolved: [#("bash", "/usr/bin/bash")],
      executables: ["/usr/bin/bash"],
      existing: [],
      dirs: [],
      inherited_path: "/usr/bin:/bin",
      cgroup_dir: None,
    )
  let assert Ok(plan2) =
    env.build_spawn_plan(
      sandbox: env.default_sandbox(),
      host: host_no_setsid,
      workspace_dir: "/srv/ws/threads/t1",
      tmp_dir: None,
      command: "true",
    )
  plan2.exe |> should_equal("/usr/bin/bash")
  plan2.kill_mode |> should_equal(env.KillPid)
  plan2.allow_env
  |> should_equal([
    #("HOME", "/srv/ws/threads/t1"),
    #("PATH", "/usr/bin:/bin"),
  ])
}

pub fn sandbox_plan_bwrap_nixos_toolchain_test() {
  let tc = "/nix/store/abc123-ws-tools"
  let host =
    fake_probe(
      resolved: [
        #("bwrap", "/nix/store/bw-1/bin/bwrap"),
        #("prlimit", "/nix/store/ul-1/bin/prlimit"),
      ],
      executables: [
        tc <> "/bin/bash",
        tc <> "/bin/setsid",
        tc <> "/bin/sh",
        tc <> "/bin/env",
      ],
      existing: [tc <> "/etc/ssl/certs/ca-bundle.crt"],
      dirs: ["/nix/store", tc <> "/etc/ssl"],
      inherited_path: "/run/current-system/sw/bin",
      cgroup_dir: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: None,
      toolchain: Some(tc),
      state_dir: None,
      max_memory_mb: 512,
      max_pids: 64,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: "/var/lib/nexus/ws/threads/t1",
      tmp_dir: Some("/var/lib/nexus/ws/tmp/t1"),
      command: "python3 -c 'print(1)'",
    )
  // Fallback prlimit wraps bwrap in-place (no --nproc, no --cpu).
  plan.exe |> should_equal("/nix/store/ul-1/bin/prlimit")
  plan.kill_mode |> should_equal(env.KillPortOsPid)
  list.any(plan.argv, fn(a) { string.starts_with(a, "--nproc") })
  |> should_equal(False)
  list.any(plan.argv, fn(a) { string.starts_with(a, "--cpu") })
  |> should_equal(False)
  let assert [
    "--as=536870912",
    "--fsize=268435456",
    "--",
    "/nix/store/bw-1/bin/bwrap",
    "--tmpfs",
    "/",
    "--ro-bind",
    "/nix/store",
    "/nix/store",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    "--ro-bind",
    "/nix/store/abc123-ws-tools/etc/ssl",
    "/etc/ssl",
    "--symlink",
    "/nix/store/abc123-ws-tools/bin/sh",
    "/bin/sh",
    "--symlink",
    "/nix/store/abc123-ws-tools/bin/env",
    "/usr/bin/env",
    "--bind",
    "/var/lib/nexus/ws/threads/t1",
    "/workspace",
    "--chdir",
    "/workspace",
    "--bind",
    "/var/lib/nexus/ws/tmp/t1",
    "/tmp",
    "--unshare-net",
    "--unshare-pid",
    "--die-with-parent",
    "--",
    "/nix/store/abc123-ws-tools/bin/setsid",
    "-w",
    "/nix/store/abc123-ws-tools/bin/bash",
    "-c",
    script,
  ] = plan.argv
  string.ends_with(script, "python3 -c 'print(1)'") |> should_equal(True)
  plan.allow_env
  |> should_equal([
    #("HOME", "/workspace"),
    #("TMPDIR", "/tmp"),
    #("PATH", tc <> "/bin"),
    #("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt"),
    #("SSL_CERT_DIR", "/etc/ssl/certs"),
  ])
}

pub fn sandbox_plan_bwrap_nixos_without_toolchain_test() {
  // NixOS host without explicit NEXUS_WORKSPACE_TOOLCHAIN: mounts /nix/store
  // and /run/current-system/sw (never /run or /run/secrets) and filters
  // unmounted host PATH entries (e.g. ~/.local/bin) out of PATH.
  let host =
    fake_probe(
      resolved: [
        #("bwrap", "/run/current-system/sw/bin/bwrap"),
        #("bash", "/run/current-system/sw/bin/bash"),
        #("setsid", "/run/current-system/sw/bin/setsid"),
      ],
      executables: [
        "/run/current-system/sw/bin/bwrap",
        "/run/current-system/sw/bin/bash",
        "/run/current-system/sw/bin/setsid",
      ],
      existing: ["/etc/ssl"],
      dirs: ["/nix/store", "/run/current-system/sw", "/etc/ssl"],
      inherited_path: "/home/james/.local/bin:/run/current-system/sw/bin",
      cgroup_dir: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: None,
      toolchain: None,
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: "/var/lib/nexus/ws/threads/t1",
      tmp_dir: Some("/var/lib/nexus/ws/tmp/t1"),
      command: "echo nixos-ok",
    )
  has_triple(plan.argv, "--ro-bind", "/nix/store", "/nix/store")
  |> should_equal(True)
  has_triple(
    plan.argv,
    "--ro-bind",
    "/run/current-system/sw",
    "/run/current-system/sw",
  )
  |> should_equal(True)
  has_triple(plan.argv, "--ro-bind", "/run", "/run") |> should_equal(False)
  has_triple(plan.argv, "--ro-bind", "/run/secrets", "/run/secrets")
  |> should_equal(False)
  // Unmounted host PATH entry `/home/james/.local/bin` is filtered out.
  plan.allow_env
  |> should_equal([
    #("HOME", "/workspace"),
    #("TMPDIR", "/tmp"),
    #("PATH", "/run/current-system/sw/bin"),
  ])
}

pub fn sandbox_plan_bwrap_fhs_and_legacy_no_tmp_test() {
  let host =
    fake_probe(
      resolved: [
        #("bwrap", "/usr/bin/bwrap"),
        #("bash", "/usr/bin/bash"),
        #("setsid", "/usr/bin/setsid"),
      ],
      executables: ["/usr/bin/bwrap", "/usr/bin/bash", "/usr/bin/setsid"],
      existing: [
        "/usr",
        "/bin",
        "/lib",
        "/lib64",
        "/etc/ssl",
        "/etc/ld.so.cache",
      ],
      dirs: ["/usr", "/bin", "/lib", "/lib64", "/etc/ssl"],
      inherited_path: "/home/james/.local/bin:/usr/bin:/bin",
      cgroup_dir: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: None,
      toolchain: None,
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: "/srv/ws/t-legacy",
      tmp_dir: None,
      command: "pwd",
    )
  // Without prlimit or cgroup, bwrap is spawned directly.
  plan.exe |> should_equal("/usr/bin/bwrap")
  plan.kill_mode |> should_equal(env.KillPortOsPid)
  // Legacy thread without tmp_dir gets an ephemeral --tmpfs /tmp.
  has_pair(plan.argv, "--tmpfs", "/tmp") |> should_equal(True)
  // Safe FHS mounts are present; host /etc as a whole, /home, /run are absent.
  has_triple(plan.argv, "--ro-bind", "/usr", "/usr") |> should_equal(True)
  has_triple(plan.argv, "--ro-bind", "/etc/ssl", "/etc/ssl")
  |> should_equal(True)
  has_triple(plan.argv, "--ro-bind", "/etc", "/etc") |> should_equal(False)
  has_triple(plan.argv, "--ro-bind", "/home", "/home") |> should_equal(False)
  has_triple(plan.argv, "--ro-bind", "/run", "/run") |> should_equal(False)
  // PATH keeps only mounted prefixes.
  plan.allow_env
  |> should_equal([
    #("HOME", "/workspace"),
    #("TMPDIR", "/tmp"),
    #("PATH", "/usr/bin:/bin"),
  ])
}

pub fn sandbox_plan_bwrap_cgroup_keeps_fsize_drops_as_test() {
  let host =
    fake_probe(
      resolved: [
        #("bwrap", "/usr/bin/bwrap"),
        #("bash", "/usr/bin/bash"),
        #("setsid", "/usr/bin/setsid"),
        #("prlimit", "/usr/bin/prlimit"),
      ],
      executables: ["/usr/bin/bwrap", "/usr/bin/bash", "/usr/bin/setsid"],
      existing: ["/usr", "/bin", "/lib64"],
      dirs: ["/usr", "/bin", "/lib64"],
      inherited_path: "/usr/bin:/bin",
      cgroup_dir: Some("/sys/fs/cgroup/system.slice/nexus.service/ws-42"),
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: None,
      toolchain: None,
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: "/srv/ws/threads/t1",
      tmp_dir: Some("/srv/ws/tmp/t1"),
      command: "true",
    )
  plan.exe |> should_equal("/usr/bin/bash")
  // Cgroup handles memory.max + pids.max (no --as), while prlimit --fsize
  // keeps the 256 MiB single-file disk cap active on delegated hosts too.
  let assert [
    "-c",
    cg_script,
    "_",
    "/sys/fs/cgroup/system.slice/nexus.service/ws-42",
    "/usr/bin/prlimit",
    "--fsize=268435456",
    "--",
    "/usr/bin/bwrap",
    ..rest
  ] = plan.argv
  string.contains(cg_script, "cgroup.procs") |> should_equal(True)
  string.contains(cg_script, "exec \"$@\"") |> should_equal(True)
  list.any(rest, fn(a) { string.starts_with(a, "--as=") })
  |> should_equal(False)
}

pub fn sandbox_plan_bwrap_symlink_toolchain_outside_store_test() {
  let tc = "/etc/nexus/toolchain"
  let host =
    fake_probe(
      resolved: [],
      executables: ["/opt/bin/bwrap", tc <> "/bin/bash"],
      existing: [],
      dirs: ["/nix/store"],
      inherited_path: "/usr/bin",
      cgroup_dir: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: Some("/opt/bin/bwrap"),
      toolchain: Some(tc),
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: "/var/lib/nexus/threads/t1",
      tmp_dir: Some("/var/lib/nexus/tmp/t1"),
      command: "true",
    )
  plan.exe |> should_equal("/opt/bin/bwrap")
  has_triple(plan.argv, "--ro-bind", "/nix/store", "/nix/store")
  |> should_equal(True)
  has_triple(plan.argv, "--ro-bind", tc, tc) |> should_equal(True)
}

pub fn sandbox_plan_nono_embedding_contract_test() {
  let tc = "/nix/store/abc-ws-tools"
  let state = "/var/lib/nexus/sandbox-state"
  let ws = "/var/lib/nexus/ws/threads/t1"
  let tmp = "/var/lib/nexus/ws/tmp/t1"
  let host =
    fake_probe(
      resolved: [#("nono", "/nix/store/nono-1/bin/nono")],
      executables: [
        tc <> "/bin/bash",
        tc <> "/bin/setsid",
        tc <> "/bin/prlimit",
      ],
      existing: [],
      dirs: ["/nix/store"],
      inherited_path: "/usr/bin",
      cgroup_dir: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxNono,
      sandbox_bin: None,
      toolchain: Some(tc),
      state_dir: Some(state),
      max_memory_mb: 256,
      max_pids: 32,
    )
  let assert Ok(plan) =
    env.build_spawn_plan(
      sandbox: sandbox,
      host: host,
      workspace_dir: ws,
      tmp_dir: Some(tmp),
      command: "echo ok",
    )
  plan.exe |> should_equal("/nix/store/nono-1/bin/nono")
  // nono shares the host PID namespace so setsid group-kill stays active.
  plan.kill_mode |> should_equal(env.KillGroup)
  // Wrapper HOME/XDG_* point at state_dir outside all grants.
  plan.allow_env
  |> should_equal([
    #("HOME", state),
    #("XDG_STATE_HOME", state <> "/state"),
    #("XDG_CACHE_HOME", state <> "/cache"),
    #("XDG_CONFIG_HOME", state <> "/config"),
    #("XDG_DATA_HOME", state <> "/data"),
    #("PATH", tc <> "/bin"),
  ])
  // prlimit runs INSIDE nono (after `--`) so RLIMIT_AS does not cap nono.
  let assert [
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
    got_ws,
    "--allow",
    got_tmp,
    "--read",
    "/nix/store",
    "--",
    got_prlimit,
    "--as=268435456",
    "--fsize=268435456",
    "--",
    got_setsid,
    "-w",
    got_bash,
    "-c",
    script,
  ] = plan.argv
  got_ws |> should_equal(ws)
  got_tmp |> should_equal(tmp)
  got_prlimit |> should_equal(tc <> "/bin/prlimit")
  got_setsid |> should_equal(tc <> "/bin/setsid")
  got_bash |> should_equal(tc <> "/bin/bash")
  // Prelude re-exports HOME/TMPDIR and unsets XDG_* BEFORE the PID marker.
  let expected_prefix =
    "export HOME='"
    <> ws
    <> "'; unset XDG_STATE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME; "
    <> "export TMPDIR='"
    <> tmp
    <> "'; printf '%d\\n' $$;"
  string.starts_with(script, expected_prefix) |> should_equal(True)
  string.ends_with(script, "echo ok") |> should_equal(True)
}

pub fn sandbox_plan_nono_quotes_special_paths_test() {
  env.shell_single_quote("/srv/o'brien/$ws")
  |> should_equal("'/srv/o'\"'\"'brien/$ws'")
}

pub fn sandbox_plan_refusals_test() {
  let empty_host =
    fake_probe(
      resolved: [#("bash", "/usr/bin/bash")],
      executables: ["/usr/bin/bash"],
      existing: [],
      dirs: [],
      inherited_path: "/usr/bin",
      cgroup_dir: None,
    )
  // bwrap missing on PATH
  let assert Error(msg1) =
    env.build_spawn_plan(
      sandbox: env.SandboxConfig(
        ..env.default_sandbox(),
        backend: env.SandboxBwrap,
      ),
      host: empty_host,
      workspace_dir: "/srv/ws/t1",
      tmp_dir: None,
      command: "true",
    )
  string.contains(msg1, "no bwrap executable found") |> should_equal(True)

  // explicit non-executable sandbox_bin
  let assert Error(msg2) =
    env.build_spawn_plan(
      sandbox: env.SandboxConfig(
        ..env.default_sandbox(),
        backend: env.SandboxBwrap,
        sandbox_bin: Some("/opt/missing-bwrap"),
      ),
      host: empty_host,
      workspace_dir: "/srv/ws/t1",
      tmp_dir: None,
      command: "true",
    )
  string.contains(msg2, "/opt/missing-bwrap") |> should_equal(True)

  // nono without state_dir
  let assert Error(msg3) =
    env.build_spawn_plan(
      sandbox: env.SandboxConfig(
        ..env.default_sandbox(),
        backend: env.SandboxNono,
      ),
      host: empty_host,
      workspace_dir: "/srv/ws/t1",
      tmp_dir: None,
      command: "true",
    )
  string.contains(msg3, "workspace_state_dir") |> should_equal(True)

  // toolchain missing bin/bash
  let host_with_bwrap =
    fake_probe(
      resolved: [#("bwrap", "/usr/bin/bwrap")],
      executables: ["/usr/bin/bwrap"],
      existing: [],
      dirs: [],
      inherited_path: "/usr/bin",
      cgroup_dir: None,
    )
  let assert Error(msg4) =
    env.build_spawn_plan(
      sandbox: env.SandboxConfig(
        ..env.default_sandbox(),
        backend: env.SandboxBwrap,
        toolchain: Some("/opt/empty-tc"),
      ),
      host: host_with_bwrap,
      workspace_dir: "/srv/ws/t1",
      tmp_dir: None,
      command: "true",
    )
  string.contains(msg4, "/opt/empty-tc/bin/bash") |> should_equal(True)

  // no-toolchain bwrap refuses loudly when resolved bash lives outside mounts
  let host_unmounted_bash =
    fake_probe(
      resolved: [
        #("bwrap", "/usr/bin/bwrap"),
        #("bash", "/home/james/.local/bin/bash"),
      ],
      executables: ["/usr/bin/bwrap", "/home/james/.local/bin/bash"],
      existing: ["/usr"],
      dirs: ["/usr"],
      inherited_path: "/home/james/.local/bin:/usr/bin",
      cgroup_dir: None,
    )
  let assert Error(msg5) =
    env.build_spawn_plan(
      sandbox: env.SandboxConfig(
        ..env.default_sandbox(),
        backend: env.SandboxBwrap,
      ),
      host: host_unmounted_bash,
      workspace_dir: "/srv/ws/t1",
      tmp_dir: None,
      command: "true",
    )
  string.contains(msg5, "outside the bwrap read-only mount set")
  |> should_equal(True)
}

fn has_pair(xs: List(String), a: String, b: String) -> Bool {
  case xs {
    [x, y, ..rest] ->
      case x == a && y == b {
        True -> True
        False -> has_pair([y, ..rest], a, b)
      }
    _ -> False
  }
}

fn has_triple(xs: List(String), a: String, b: String, c: String) -> Bool {
  case xs {
    [x, y, z, ..rest] ->
      case x == a && y == b && z == c {
        True -> True
        False -> has_triple([y, z, ..rest], a, b, c)
      }
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Phase 2: offline end-to-end wrapper tests (fake sandbox_bin scripts)
// ---------------------------------------------------------------------------

fn write_executable_script(path: String, body: String) -> Nil {
  let assert Ok(Nil) =
    simplifile.create_directory_all(filepath.directory_name(path))
  let assert Ok(Nil) = simplifile.write(path, body)
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
  Nil
}

/// Phase 0 embedding contract: `nono -s` hides even fatal sandbox errors
/// (exit 1, empty output). Verify `bash_with_sandbox` surfaces a silent
/// non-zero exit before the PID marker as a tool `Error`, AND lazily creates
/// `<state_dir>/config/nono/profiles/nexus.json` excluding `system_write_linux`.
pub fn sandbox_silent_wrapper_exit_surfaces_as_error_test() {
  let root = fresh_root()
  let state_dir = root <> "-state"
  let fake_nono = root <> "-bin/fake-nono"
  write_executable_script(fake_nono, "#!/bin/sh\nexit 1\n")

  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxNono,
      sandbox_bin: Some(fake_nono),
      toolchain: None,
      state_dir: Some(state_dir),
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let result =
    env.bash_with_sandbox(
      timeout_ms: 5000,
      max_output_bytes: 10_000,
      sandbox: sandbox,
      environment: env_for(root),
      cancel: process.new_subject(),
      arguments: "{\"target\":\"workspace\",\"command\":\"echo should-not-run\"}",
    )
  let assert Error(reason) = result
  string.contains(reason, "sandbox wrapper (nono) exited with status 1")
  |> should_equal(True)

  // Verify the nexus profile was lazily created with system_write_linux excluded.
  let profile_path = filepath.join(state_dir, "config/nono/profiles/nexus.json")
  let assert Ok(profile) = simplifile.read(profile_path)
  string.contains(profile, "system_write_linux") |> should_equal(True)

  let _ = simplifile.delete(root)
  let _ = simplifile.delete(state_dir)
  let _ = simplifile.delete(root <> "-bin")
}

/// Verify end-to-end through a real port that `SandboxNono` launches the
/// wrapper with `HOME`/`XDG_*` in `state_dir` and scrubbed BEAM secrets, while
/// the inner bash command sees `HOME=<workspace>`, `TMPDIR=<thread_tmp>`, and
/// unset `XDG_*`.
pub fn sandbox_nono_fake_wrapper_env_and_reexport_test() {
  let root = fresh_root()
  let state_dir = root <> "-state"
  let wrapper_log = root <> "-wrapper.env"
  let fake_nono = root <> "-bin/fake-nono"
  // Record wrapper's env, strip everything up to `--`, and exec the inner cmd.
  let script =
    "#!/bin/sh\n"
    <> "printf 'WRAP_HOME=%s\\nWRAP_XDG=%s\\nWRAP_CANARY=%s\\n' \"$HOME\" \"$XDG_CONFIG_HOME\" \"$NEXUS_TEST_SECRET_CANARY\" > "
    <> env.shell_single_quote(wrapper_log)
    <> "\n"
    <> "while [ \"$#\" -gt 0 ]; do\n"
    <> "  arg=\"$1\"; shift\n"
    <> "  if [ \"$arg\" = \"--\" ]; then exec \"$@\"; fi\n"
    <> "done\n"
    <> "exit 99\n"
  write_executable_script(fake_nono, script)

  let handle =
    env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: Some("threads/t1"),
      tmp_rel_path: Some("tmp/t1"),
      roster: env.attached_targets(),
      remote: None,
    )
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxNono,
      sandbox_bin: Some(fake_nono),
      toolchain: None,
      state_dir: Some(state_dir),
      max_memory_mb: 1024,
      max_pids: 64,
    )
  put_env("NEXUS_TEST_SECRET_CANARY", "secret-must-not-leak")
  let res =
    env.bash_with_sandbox(
      timeout_ms: 5000,
      max_output_bytes: 10_000,
      sandbox: sandbox,
      environment: Some(handle),
      cancel: process.new_subject(),
      arguments: "{\"target\":\"workspace\",\"command\":\"printf 'INNER_HOME=%s\\nINNER_TMP=%s\\nINNER_XDG=%s\\n' \\\"$HOME\\\" \\\"$TMPDIR\\\" \\\"$XDG_CONFIG_HOME\\\"\"}",
    )
  unset_env("NEXUS_TEST_SECRET_CANARY")

  let assert Ok(out) = res
  let assert Ok(wrap_env) = simplifile.read(wrapper_log)
  string.contains(wrap_env, "WRAP_HOME=" <> state_dir) |> should_equal(True)
  string.contains(wrap_env, "WRAP_XDG=" <> state_dir <> "/config")
  |> should_equal(True)
  string.contains(wrap_env, "secret-must-not-leak") |> should_equal(False)

  string.contains(out, "INNER_HOME=" <> filepath.join(root, "threads/t1"))
  |> should_equal(True)
  string.contains(out, "INNER_TMP=" <> filepath.join(root, "tmp/t1"))
  |> should_equal(True)
  string.contains(out, "INNER_XDG=\n")
  |> fn(matched) { matched || string.ends_with(out, "INNER_XDG=") }
  |> should_equal(True)

  let _ = simplifile.delete(root)
  let _ = simplifile.delete(state_dir)
  let _ = simplifile.delete(wrapper_log)
  let _ = simplifile.delete(root <> "-bin")
}

type LoopbackSocket

@external(erlang, "nexus_env_test_ffi", "listen_loopback")
fn listen_loopback() -> Result(#(LoopbackSocket, Int), Nil)

@external(erlang, "nexus_env_test_ffi", "close_socket")
fn close_socket(socket: LoopbackSocket) -> Nil

/// Verify `KillPortOsPid` (the `bwrap` PID-namespace kill path) kills the
/// direct wrapper host PID on cancel, re-signals the one-shot cancel subject,
/// and ignores an in-namespace marker PID (`2`) on the host.
pub fn sandbox_bwrap_fake_wrapper_kill_port_os_pid_test() {
  let root = fresh_root()
  let fake_bwrap = root <> "-bin/fake-bwrap"
  let uniq = int.to_string(timing.now_us())
  let tag = "nxfakebw" <> uniq <> "q"
  // Emulate a PID-namespace wrapper printing in-namespace PID `2` as line 1,
  // flushing output, and blocking under a unique argv tag until killed by its
  // own host OS PID (bash `exec -a` tags the process in `ps`).
  let script =
    "#!/usr/bin/env bash\n"
    <> "printf '2\\n'\n"
    <> "printf 'ready-in-fake-bwrap\\n'\n"
    <> "exec -a "
    <> tag
    <> " sleep 30\n"
  write_executable_script(fake_bwrap, script)

  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: Some(fake_bwrap),
      toolchain: None,
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let handoff = process.new_subject()
  let reply = process.new_subject()
  let _worker =
    process.spawn_unlinked(fn() {
      let cancel = process.new_subject()
      process.send(handoff, cancel)
      let res =
        env.bash_with_sandbox(
          timeout_ms: 30_000,
          max_output_bytes: 10_000,
          sandbox: sandbox,
          environment: env_for(root),
          cancel: cancel,
          arguments: "{\"target\":\"workspace\",\"command\":\"sleep 30\"}",
        )
      let resignalled = process.receive(cancel, 1000)
      process.send(reply, #(res, resignalled))
    })
  let assert Ok(cancel) = process.receive(handoff, 5000)
  // Positive control: observe the tagged fake wrapper running before cancel.
  poll_tag_present("nxfakebw" <> uniq <> "[q] 3[0]", 50)
  process.send(cancel, Nil)
  let assert Ok(#(res, resignalled)) = process.receive(reply, 10_000)
  // Confirm `KillPortOsPid` actually terminated the wrapper process.
  poll_tag_gone("nxfakebw" <> uniq <> "[q]", 50)
  let _ = simplifile.delete(root)
  let _ = simplifile.delete(root <> "-bin")

  let assert Error(text) = res
  string.contains(text, "cancelled") |> should_equal(True)
  string.contains(text, "ready-in-fake-bwrap") |> should_equal(True)
  // Marker line `2` was consumed cleanly, not leaked into user output.
  string.contains(text, "\n2\n") |> should_equal(False)
  let assert Ok(Nil) = resignalled
}

/// Pin the `tools.gleam` bridge: configuring `workspace_sandbox = SandboxBwrap`
/// with a missing `sandbox_bin` routes through `env.bash_with_sandbox` when
/// the `bash` ToolSpec runs (wire schema unchanged).
pub fn sandbox_tools_wiring_passes_config_test() {
  let base =
    config.from_env(fn(name) {
      case name {
        "NEXUS_ENCRYPTION_KEY" ->
          Ok("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        "NEXUS_WORKSPACE_ROOT" -> Ok("/tmp/nexus-tools-wiring-test")
        "NEXUS_WORKSPACE_SANDBOX" -> Ok("bwrap")
        "NEXUS_WORKSPACE_SANDBOX_BIN" -> Ok("/nonexistent/test-bwrap-bin")
        _ -> Error(Nil)
      }
    })
  let assert Ok(cfg) = base
  let assert Ok([spec]) = tools.by_names(cfg, ["bash"])
  let root = fresh_root()
  let ctx =
    tools.ToolCtx(
      cancel: process.new_subject(),
      delivery: None,
      environment: env_for(root),
    )
  let res = spec.run(ctx, "{\"target\":\"workspace\",\"command\":\"echo hi\"}")
  let _ = simplifile.delete(root)
  let assert Error(reason) = res
  string.contains(reason, "/nonexistent/test-bwrap-bin") |> should_equal(True)
}

// ---------------------------------------------------------------------------
// Phase 2: opt-in real sandbox integration tests (never PATH-probed)
// ---------------------------------------------------------------------------

/// Real `bwrap` isolation suite. Runs ONLY when `NEXUS_TEST_BWRAP=1` is set
/// explicitly (workspace-sandbox plan: default `gleam test` stays deterministic
/// and offline). Optional overrides: `NEXUS_TEST_BWRAP_BIN`,
/// `NEXUS_TEST_TOOLCHAIN`.
pub fn sandbox_bwrap_integration_opt_in_test() {
  case get_env("NEXUS_TEST_BWRAP") {
    Ok("1") -> run_real_bwrap_integration()
    _ -> Nil
  }
}

fn run_real_bwrap_integration() -> Nil {
  let root = fresh_root()
  let sibling_dir = filepath.join(root, "threads/sibling")
  let assert Ok(Nil) = simplifile.create_directory_all(sibling_dir)
  let assert Ok(Nil) =
    simplifile.write(filepath.join(sibling_dir, "secret.txt"), "sibling-secret")

  let handle =
    Some(env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: Some("threads/t1"),
      tmp_rel_path: Some("tmp/t1"),
      roster: env.attached_targets(),
      remote: None,
    ))
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxBwrap,
      sandbox_bin: get_env("NEXUS_TEST_BWRAP_BIN") |> option.from_result,
      toolchain: get_env("NEXUS_TEST_TOOLCHAIN") |> option.from_result,
      state_dir: None,
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let run = fn(timeout_ms, cmd) {
    env.bash_with_sandbox(
      timeout_ms: timeout_ms,
      max_output_bytes: 50_000,
      sandbox: sandbox,
      environment: handle,
      cancel: process.new_subject(),
      arguments: json_args([#("target", "workspace"), #("command", cmd)]),
    )
  }

  // 1. In-sandbox cwd/HOME=/workspace and /tmp maps to the thread's tmp dir.
  let assert Ok(out1) =
    run(
      10_000,
      "pwd && echo HOME=$HOME && echo TMPDIR=$TMPDIR && echo ok > /tmp/probe.txt",
    )
  string.contains(out1, "/workspace") |> should_equal(True)
  string.contains(out1, "HOME=/workspace") |> should_equal(True)
  string.contains(out1, "TMPDIR=/tmp") |> should_equal(True)
  simplifile.read(filepath.join(root, "tmp/t1/probe.txt"))
  |> should_equal(Ok("ok\n"))

  // 2. Sibling workspace and host secrets are unreachable.
  let assert Ok(out2) =
    run(10_000, "cat " <> filepath.join(sibling_dir, "secret.txt"))
  string.contains(out2, "sibling-secret") |> should_equal(False)
  let assert Ok(out3) = run(10_000, "cat /etc/shadow")
  string.starts_with(out3, "exit status") |> should_equal(True)

  // 3. Offline netns blocks TCP loopback (with a real local listener as
  //    positive control so the check cannot pass vacuously).
  let assert Ok(#(sock, port)) = listen_loopback()
  let tcp_probe =
    "bash -c 'exec 3<>/dev/tcp/127.0.0.1/"
    <> int.to_string(port)
    <> "' 2>&1; echo rc=$?"
  let host_probe = bash(handle, 10_000, tcp_probe)
  let sandbox_probe = run(10_000, tcp_probe)
  close_socket(sock)
  let assert Ok(host_out) = host_probe
  string.contains(host_out, "rc=0") |> should_equal(True)
  let assert Ok(out4) = sandbox_probe
  string.contains(out4, "rc=0") |> should_equal(False)

  // 4. Timeout reaps background children inside the PID namespace.
  let tag = "nxbwrap" <> int.to_string(timing.now_us()) <> "q"
  let assert Error(timeout_msg) =
    run(500, "exec -a " <> tag <> " sleep 30 & sleep 30")
  string.contains(timeout_msg, "timed out") |> should_equal(True)
  poll_tag_gone(
    "nxbwrap" <> string.drop_start(tag, 7) |> string.drop_end(1) <> "[q]",
    25,
  )

  let _ = simplifile.delete(root)
  Nil
}

/// Real `nono` isolation suite. Runs ONLY when `NEXUS_TEST_NONO=1` is set
/// explicitly. Optional overrides: `NEXUS_TEST_NONO_BIN`,
/// `NEXUS_TEST_TOOLCHAIN`, `NEXUS_TEST_NONO_ROOT` (a parent dir outside
/// `/tmp` and `/var/tmp`, which nono treats as protected state roots).
pub fn sandbox_nono_integration_opt_in_test() {
  case get_env("NEXUS_TEST_NONO") {
    Ok("1") -> run_real_nono_integration()
    _ -> Nil
  }
}

fn run_real_nono_integration() -> Nil {
  let base = case get_env("NEXUS_TEST_NONO_ROOT") {
    Ok(dir) -> dir
    Error(Nil) ->
      case get_env("HOME") {
        Ok(home) -> filepath.join(home, ".cache/nexus-nono-test")
        Error(Nil) -> "/var/tmp/nexus-nono-test"
      }
  }
  let uniq = int.to_string(timing.now_us())
  let root = filepath.join(base, "ws-" <> uniq)
  let state_dir = filepath.join(base, "state-" <> uniq)
  let sibling_dir = filepath.join(root, "threads/sibling")
  let assert Ok(Nil) = simplifile.create_directory_all(sibling_dir)
  let assert Ok(Nil) =
    simplifile.write(filepath.join(sibling_dir, "secret.txt"), "sibling-secret")

  let handle =
    Some(env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: Some("threads/t1"),
      tmp_rel_path: Some("tmp/t1"),
      roster: env.attached_targets(),
      remote: None,
    ))
  let sandbox =
    env.SandboxConfig(
      backend: env.SandboxNono,
      sandbox_bin: get_env("NEXUS_TEST_NONO_BIN") |> option.from_result,
      toolchain: get_env("NEXUS_TEST_TOOLCHAIN") |> option.from_result,
      state_dir: Some(state_dir),
      max_memory_mb: 1024,
      max_pids: 64,
    )
  let run = fn(timeout_ms, cmd) {
    env.bash_with_sandbox(
      timeout_ms: timeout_ms,
      max_output_bytes: 50_000,
      sandbox: sandbox,
      environment: handle,
      cancel: process.new_subject(),
      arguments: json_args([#("target", "workspace"), #("command", cmd)]),
    )
  }

  // 1. HOME/TMPDIR re-exported; XDG_* unset.
  let assert Ok(out1) =
    run(
      10_000,
      "echo HOME=$HOME && echo TMPDIR=$TMPDIR && echo XDG=$XDG_CONFIG_HOME",
    )
  string.contains(out1, "HOME=" <> filepath.join(root, "threads/t1"))
  |> should_equal(True)
  string.contains(out1, "TMPDIR=" <> filepath.join(root, "tmp/t1"))
  |> should_equal(True)
  string.contains(out1, state_dir) |> should_equal(False)

  // 2. Sibling workspace read blocked and hardcoded /tmp write blocked.
  let assert Ok(out2) =
    run(10_000, "cat " <> filepath.join(sibling_dir, "secret.txt"))
  string.contains(out2, "sibling-secret") |> should_equal(False)
  let host_tmp_probe = "/tmp/nexus-nono-escape-" <> uniq
  let assert Ok(out3) = run(10_000, "echo bad > " <> host_tmp_probe)
  string.starts_with(out3, "exit status") |> should_equal(True)
  simplifile.is_file(host_tmp_probe) |> should_equal(Ok(False))

  // 3. Offline --block-net blocks TCP loopback connect (with a real local
  //    listener as positive control).
  let assert Ok(#(sock, port)) = listen_loopback()
  let tcp_probe =
    "bash -c 'exec 3<>/dev/tcp/127.0.0.1/"
    <> int.to_string(port)
    <> "' 2>&1; echo rc=$?"
  let host_probe = bash(handle, 10_000, tcp_probe)
  let sandbox_probe = run(10_000, tcp_probe)
  close_socket(sock)
  let assert Ok(host_out) = host_probe
  string.contains(host_out, "rc=0") |> should_equal(True)
  let assert Ok(out4) = sandbox_probe
  string.contains(out4, "rc=0") |> should_equal(False)

  // 4. Timeout reaps background children under nono (setsid group kill).
  let tag = "nxnono" <> uniq <> "q"
  let assert Error(timeout_msg) =
    run(500, "exec -a " <> tag <> " sleep 30 & sleep 30")
  string.contains(timeout_msg, "timed out") |> should_equal(True)
  poll_tag_gone("nxnono" <> uniq <> "[q]", 25)

  let _ = simplifile.delete(root)
  let _ = simplifile.delete(state_dir)
  Nil
}
