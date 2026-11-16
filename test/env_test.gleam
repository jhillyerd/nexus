//// Offline tests for the environment domain (environments plan
//// Phase 1): the v1 workspace tools, target routing, confinement,
//// and the bash port loop's bounded paths. These run REAL local
//// processes (`bash`) in temp directories — no network, per the
//// offline-suite rule; the port machinery itself is the thing under
//// test, so faking it would test nothing.

import filepath
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import nexus/env
import nexus/timing
import simplifile

/// A fresh workspace root per test: `/tmp/nexus-env-test-<now_us>`.
fn fresh_root() -> String {
  "/tmp/nexus-env-test-" <> int.to_string(timing.now_us())
}

fn env_for(root: String) -> Option(env.Environment) {
  Some(env.Environment(
    workspace_root: root,
    thread_id: "t1",
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

pub fn route_names_live_roster_test() {
  // The 2a observable: `route` reads the handle's ROSTER (not the
  // compiled constant), so an attached list is what the fail-fast error
  // names. `workspace` still routes to execution; a non-workspace
  // member is attached-by-name but not routable yet (2b wires it).
  let env =
    env.Environment(
      workspace_root: "/srv/nexus",
      thread_id: "s12",
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
        roster: env.attached_targets(),
        remote: None,
      )),
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
