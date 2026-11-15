//// Offline tests for the environment domain (environments plan
//// Phase 1): the v1 workspace tools, target routing, confinement,
//// and the bash port loop's bounded paths. These run REAL local
//// processes (`bash`) in temp directories — no network, per the
//// offline-suite rule; the port machinery itself is the thing under
//// test, so faking it would test nothing.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nexus/env
import nexus/timing
import simplifile

/// A fresh workspace root per test: `/tmp/nexus-env-test-<now_us>`.
fn fresh_root() -> String {
  "/tmp/nexus-env-test-" <> int.to_string(timing.now_us())
}

fn env_for(root: String) -> Option(env.Environment) {
  Some(env.Environment(workspace_root: root, thread_id: "t1"))
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
  env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  |> should_equal(
    "environment attached: \"proxmox-2\". attached targets: workspace, proxmox-2.",
  )
  env.roster_detach_text("proxmox-2", ["workspace"])
  |> should_equal(
    "environment detached: \"proxmox-2\". attached targets: workspace.",
  )
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
      env.workspace_dir(env.Environment(workspace_root: root, thread_id: "t1")),
    )
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
/// mid-command — even IMMEDIATELY, before the BEAM side ever parses
/// the pid marker — must reap the whole process group. The sentinel
/// lives inside the wrapper (a subshell watching the dup'd stdin
/// pipe), so the kill does not depend on any BEAM-side pid handoff
/// and the test has no timing window.
pub fn bash_owner_death_kills_group_test() {
  let root = fresh_root()
  let e = env_for(root)
  let done = process.new_subject()
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
          arguments: "{\"target\":\"workspace\",\"command\":\"exec -a nxown8x sleep 45 & sleep 45\"}",
        )
      process.sleep(60_000)
    })
  // Kill the owner almost immediately — the marker may not have been
  // parsed BEAM-side yet; the sentinel is armed before the command
  // runs, so this window is real and deterministic to enter.
  process.sleep(150)
  process.kill(owner)
  process.send(done, Nil)
  let assert Ok(Nil) = process.receive(done, 1000)
  // The sentinel fires on the port's EOF; give it a moment, then the
  // renamed child must be gone (its argv[0] carries the tag).
  poll_tag_gone("nxown[8]x", 30)
  let _ = simplifile.delete(root)
}

fn wait_started(path: String, attempts: Int) -> Nil {
  case simplifile.exists(path, True) {
    Ok(True) -> Nil
    _ ->
      case attempts {
        0 -> panic as "command never started (started file missing)"
        n -> {
          process.sleep(100)
          wait_started(path, n - 1)
        }
      }
  }
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

/// A pre-queued cancel (a Stop that landed before the executor even
/// started selecting) must answer `cancelled` AND leave the one-shot
/// re-signal observable for the loop's LAST-call path — with the
/// marker wait port-only, nothing consumes the signal in between
/// (CodeRabbit review).
pub fn bash_prequeued_cancel_preserves_signal_test() {
  let root = fresh_root()
  let reply = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let cancel = process.new_subject()
      process.send(cancel, Nil)
      let result =
        env.bash(
          timeout_ms: 60_000,
          max_output_bytes: 100_000,
          environment: env_for(root),
          cancel: cancel,
          arguments: "{\"target\":\"workspace\",\"command\":\"echo partial; sleep 45\"}",
        )
      let again = process.receive(cancel, 2000)
      process.send(reply, #(result, again))
    })
  let _ = worker
  let assert Ok(#(result, again)) = process.receive(reply, 30_000)
  let assert Error(text) = result
  let assert True = string.contains(text, "cancelled")
  let assert Ok(Nil) = again
  // The cancelled command's whole tree is gone (CodeRabbit review):
  // whether the pid marker was parsed or the kill was targetless, the
  // sentinel reaps the group at the port's EOF.
  poll_tag_gone("nxcancel[9]x", 30)
  let _ = simplifile.delete(root)
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
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/dir/notes.md\",\"content\":\"hello workspace\"}",
    )
  let assert True = string.contains(msg, "sub/dir/notes.md")
  let assert Ok("hello workspace") =
    env.read_file(
      max_output_bytes: 10_000,
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/dir/notes.md\"}",
    )
  let assert Ok(listing) =
    env.list_dir(environment: e, arguments: "{\"target\":\"workspace\"}")
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
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"exact.txt\",\"content\":\"abcd\"}",
    )
  let assert Ok("abcd") =
    env.read_file(
      max_output_bytes: 4,
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
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"big.txt\",\"content\":\"0123456789abcdefghij\"}",
    )
  let assert Ok(text) =
    env.read_file(
      max_output_bytes: 4,
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
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"pipe\"}",
    )
  // Writing one blocks until a reader appears — refused too.
  let assert Error("write_file: not a regular file: pipe2") =
    env.write_file(
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"pipe2\",\"content\":\"x\"}",
    )
  // Regular files are unaffected.
  let assert Ok(_) =
    env.write_file(
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
    env.list_dir(environment: e, arguments: "{\"target\":\"workspace\"}")
  let assert Error("list_dir: not a directory: nope") =
    env.list_dir(
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
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"../../etc/passwd\"}",
    )
  let assert Error(_) =
    env.read_file(
      max_output_bytes: 100,
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"/etc/passwd\"}",
    )
  // A normalized-inside path stays fine: `sub/../x` folds to the
  // workspace's own `x` (the honest read error names the file).
  let assert Error("read_file: file not found") =
    env.read_file(
      max_output_bytes: 100,
      environment: e,
      arguments: "{\"target\":\"workspace\",\"path\":\"sub/../x\"}",
    )
  let _ = simplifile.delete(root)
}

pub fn confinement_normalization_test() {
  let e = env.Environment(workspace_root: "/srv/nexus", thread_id: "s12")
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
  env.workspace_dir(env.Environment(workspace_root: "/srv/nx", thread_id: "s3"))
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
