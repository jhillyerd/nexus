//// Offline pins for the node adapter actor (`nexus/node_adapter`,
//// environments plan Phase 2b-3). The adapter is driven directly
//// through its public seam (`start_adapter` — the test process stands
//// in for the socket owner, so IT receives every outbound frame)
//// against a FAKE thread speaking the REAL `thread.Msg` arms the
//// adapter uses (Join / AttachTarget / Send) — the fake-actor
//// discipline of `tool_provider_test`: no network, no real runner,
//// subject-owned receives only.

import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit/should
import nexus/config
import nexus/log
import nexus/node_adapter
import nexus/node_protocol
import nexus/thread
import nexus/tool_provider

// ---------------------------------------------------------------------------
// The fake thread: a plain process answering the three arms the
// adapter uses, with a MOOD the test picks at spawn and an exec-report
// subject (every AttachTarget's EnvExec is reported back to the test).
// ---------------------------------------------------------------------------

type Mood {
  // Attach Ok, Send Sent (with the user-line echo a real thread fans
  // back to its subscribers).
  Happy
  // Attach Ok, Send Busy — a turn is already streaming.
  BusySends
  // Attach refused (the roster-race wording), Send never reached.
  RefuseAttach
}

type Fake {
  Fake(
    id: String,
    mood: Mood,
    sub: Option(Subject(thread.ThreadEvent)),
    exec_report: Option(Subject(thread.EnvExec)),
  )
}

fn start_fake_thread(
  id: String,
  mood: Mood,
) -> #(Subject(thread.Msg), Subject(thread.EnvExec)) {
  let back = process.new_subject()
  let exec_report = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let own: Subject(thread.Msg) = process.new_subject()
      process.send(back, own)
      fake_loop(
        Fake(id: id, mood: mood, sub: None, exec_report: Some(exec_report)),
        own,
      )
    })
  let _ = pid
  let assert Ok(own) = process.receive(back, 2000)
  #(own, exec_report)
}

fn fake_loop(state: Fake, own: Subject(thread.Msg)) -> Nil {
  case process.receive(own, 5000) {
    Ok(thread.Join(sub, visit)) -> {
      // The Join contract: Hello first, then a replay line.
      process.send(
        sub,
        thread.ThreadEvent(state.id, visit, thread.Hello("fake-alias", 2, [])),
      )
      process.send(
        sub,
        thread.ThreadEvent(
          state.id,
          visit,
          thread.UserEcho(
            "attached targets: workspace.",
            Some(1),
            Some("system"),
          ),
        ),
      )
      fake_loop(Fake(..state, sub: Some(sub)), own)
    }
    Ok(thread.AttachTarget(name, exec, reply)) -> {
      // Report the plane to the test, then answer by mood.
      case exec, state.exec_report {
        Some(plane), Some(report) -> process.send(report, plane)
        _, _ -> Nil
      }
      process.send(reply, case state.mood {
        RefuseAttach -> Error("target \"" <> name <> "\" is already attached")
        _ -> Ok(Nil)
      })
      fake_loop(state, own)
    }
    Ok(thread.Send(text, _author, _depth, reply)) -> {
      process.send(reply, case state.mood {
        BusySends -> thread.Busy
        _ -> thread.Sent
      })
      // The Sent arm's echo: the real thread fans the user line back,
      // and so does the fake (on the newest subscription).
      case state.mood, state.sub {
        Happy, Some(sub) ->
          process.send(
            sub,
            thread.ThreadEvent(state.id, 1, thread.UserEcho(text, None, None)),
          )
        _, _ -> Nil
      }
      fake_loop(state, own)
    }
    // Everything else (Stop, RouteEnv, …) is ignored — this fake serves
    // the adapter's three-arm contract only.
    Ok(_) -> fake_loop(state, own)
    Error(Nil) -> Nil
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const thread_id = "t-node-1"

fn test_config() -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 8080,
    ui_token: None,
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    env_timeout_ms: 60_000,
    // The boundary cap the adapter applies to node results on receipt
    // (small so `adapter_caps_node_result_test` stays cheap).
    env_max_output_bytes: 1024,
    node_idle_days: 7,
    log_level: log.Info,
    max_bot_hops: 4,
  )
}

type Rig {
  Rig(
    fake: Subject(thread.Msg),
    adapter: Subject(node_adapter.Msg),
    frames: Subject(String),
    exec_report: Subject(thread.EnvExec),
  )
}

fn start_rig(role: node_adapter.Role) -> Rig {
  start_rig_mood(role, Happy)
}

fn start_rig_mood(role: node_adapter.Role, mood: Mood) -> Rig {
  // The fake's fan-out ids match the adapter's thread id — the honest
  // production wiring (a thread's events always name itself).
  start_rig_ids(thread_id, thread_id, role, mood)
}

fn start_rig_ids(
  adapter_thread_id: String,
  fake_thread_id: String,
  role: node_adapter.Role,
  mood: Mood,
) -> Rig {
  let #(fake, exec_report) = start_fake_thread(fake_thread_id, mood)
  let frames = process.new_subject()
  let assert Ok(adapter) =
    node_adapter.start_adapter(
      test_config(),
      adapter_thread_id,
      fake,
      "node-a",
      role,
      frames,
    )
  Rig(fake: fake, adapter: adapter, frames: frames, exec_report: exec_report)
}

fn next_frame(frames: Subject(String)) -> String {
  let assert Ok(frame) = process.receive(frames, 2000)
  frame
}

/// The execution plane the adapter attached with (reported by the fake
/// at AttachTarget time).
fn exec_of(rig: Rig) -> thread.EnvExec {
  let assert Ok(exec) = process.receive(rig.exec_report, 2000)
  exec
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The receive bound budgets for aggressive JSON escaping (an escaped
/// surrogate pair is 12 wire bytes per char) plus envelope headroom,
/// so a frame carrying a capped result always passes while hostile
/// frames stay hard-bounded.
pub fn max_frame_bytes_budgets_escaping_test() {
  should.equal(node_adapter.max_frame_bytes(1024), 1024 * 12 + 16_384)
  should.be_true(node_adapter.max_frame_bytes(1024) > 1024 * 6)
}

/// The connect sequence: Hello + replay arrive as event frames, the
/// attach answer arrives as `attached` — the fake node's first breath.
pub fn adapter_connect_sequence_test() {
  let rig = start_rig(node_adapter.EnvRole)
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"hello\",\"model\":\"fake-alias\",\"messages\":2}",
  )
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"user\",\"text\":\"attached targets: workspace.\",\"at\":1,\"author\":\"system\"}",
  )
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"attached\",\"target\":\"node-a\"}",
  )
}

/// The tool plane: a provider Call becomes a tools/call frame with the
/// arguments VERBATIM; the node's response answers the caller's reply
/// subject as ToolOk, and ids increment per call.
pub fn adapter_call_round_trip_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)

  let exec = exec_of(rig)
  let reply = process.new_subject()
  process.send(
    exec.sub,
    tool_provider.Call(
      reference.new(),
      "bash",
      "{\"target\":\"node-a\",\"command\":\"echo hi\"}",
      reply,
    ),
  )
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"bash\",\"arguments\":{\"target\":\"node-a\",\"command\":\"echo hi\"}}}",
  )
  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.CallResponse(1, True, "hi\n")),
  )
  let assert Ok(tool_provider.ToolOk("hi\n")) = process.receive(reply, 2000)

  let reply2 = process.new_subject()
  process.send(
    exec.sub,
    tool_provider.Call(
      reference.new(),
      "bash",
      "{\"target\":\"node-a\",\"command\":\"echo again\"}",
      reply2,
    ),
  )
  should.be_true(string.contains(next_frame(rig.frames), "\"id\":2"))
}

/// An isError result answers ToolErr (a failed tool result, never a
/// loop error — the round commits).
pub fn adapter_call_error_result_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  let exec = exec_of(rig)

  let reply = process.new_subject()
  process.send(
    exec.sub,
    tool_provider.Call(
      reference.new(),
      "bash",
      "{\"target\":\"node-a\",\"command\":\"false\"}",
      reply,
    ),
  )
  let _call_frame = next_frame(rig.frames)
  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.CallResponse(1, False, "exit status 1")),
  )
  let assert Ok(tool_provider.ToolErr("exit status 1")) =
    process.receive(reply, 2000)
}

/// Cancel: the cancelled notification flows to the node naming the
/// request id, and a LATE response for the cancelled id is ignored (no
/// crash, no phantom reply).
pub fn adapter_cancel_then_late_response_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  let exec = exec_of(rig)

  let reply = process.new_subject()
  let ref = reference.new()
  process.send(
    exec.sub,
    tool_provider.Call(
      ref,
      "bash",
      "{\"target\":\"node-a\",\"command\":\"sleep 99\"}",
      reply,
    ),
  )
  let _call_frame = next_frame(rig.frames)

  process.send(exec.sub, tool_provider.Cancelled(ref))
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}",
  )

  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.CallResponse(1, True, "too late")),
  )
  should.equal(process.receive(reply, 200), Error(Nil))
}

/// Arguments that are not a JSON object never reach the wire — the
/// honest tool error answers instead, and the adapter keeps serving.
pub fn adapter_refuses_non_object_arguments_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  let exec = exec_of(rig)

  let reply = process.new_subject()
  process.send(
    exec.sub,
    tool_provider.Call(reference.new(), "bash", "[1,2,3]", reply),
  )
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 2000)
  should.be_true(string.contains(message, "not a JSON object"))
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(next_frame(rig.frames), "{\"v\":1,\"type\":\"pong\"}")
}

/// Results cap at the boundary: an oversized node result answers
/// truncated (display hygiene at the first nexus-side touch; the test
/// config's default cap is the 1024 floor).
pub fn adapter_caps_node_result_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  let exec = exec_of(rig)

  let reply = process.new_subject()
  process.send(
    exec.sub,
    tool_provider.Call(
      reference.new(),
      "read_file",
      "{\"target\":\"node-a\",\"path\":\"huge.txt\"}",
      reply,
    ),
  )
  let _call_frame = next_frame(rig.frames)
  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.CallResponse(
      1,
      True,
      string.repeat("x", 2000),
    )),
  )
  let assert Ok(tool_provider.ToolOk(capped)) = process.receive(reply, 2000)
  should.be_true(string.contains(capped, "truncated at"))
}

/// Ping answers pong.
pub fn adapter_ping_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(next_frame(rig.frames), "{\"v\":1,\"type\":\"pong\"}")
}

/// User input rides the thread's Send path: Sent fans the echo back as
/// an event frame (no ack frame of its own).
pub fn adapter_send_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)

  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.Send("case:bash")),
  )
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"user\",\"text\":\"case:bash\",\"at\":null,\"author\":null}",
  )
}

/// A Busy thread answers the send with the honest error frame (a turn
/// is already streaming — the TUI shows it, the socket stays).
pub fn adapter_busy_send_error_frame_test() {
  let rig = start_rig_mood(node_adapter.EnvRole, BusySends)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Send("again")))
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"error\",\"message\":\"a reply is already streaming\"}",
  )
}

/// An empty send refuses without touching the thread.
pub fn adapter_empty_send_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Send("   ")))
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"error\",\"message\":\"empty message\"}",
  )
}

/// Viewer role: no execution plane is attached (the fake never reported
/// one), but events still flow and send works.
pub fn adapter_viewer_role_test() {
  let rig = start_rig(node_adapter.ViewerRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  // No `attached` frame — the attach arm never ran. Prove absence by
  // the next frame being the send echo.
  process.send(
    rig.adapter,
    node_adapter.FrameIn(node_protocol.Send("hi from viewer")),
  )
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"user\",\"text\":\"hi from viewer\",\"at\":null,\"author\":null}",
  )
  should.equal(process.receive(rig.exec_report, 200), Error(Nil))
}

/// ListTools answers the honest refusal (nodes serve the compiled
/// environment tools; there is no list).
pub fn adapter_list_tools_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)
  let exec = exec_of(rig)
  let reply = process.new_subject()
  process.send(exec.sub, tool_provider.ListTools(reply))
  let assert Ok(Error(_)) = process.receive(reply, 2000)
  Nil
}

/// The one-thread filter: events naming ANOTHER thread never project —
/// even the Join replay of a mismatched fake is dropped — while the
/// connection itself stays alive (ping still answers).
pub fn adapter_filters_foreign_thread_events_test() {
  let rig = start_rig_ids("t-node-1", "t-other", node_adapter.EnvRole, Happy)
  // The attach answer rides its OWN subject, so `attached` arrives; the
  // fake's Hello + replay carry "t-other" ids and never project.
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"attached\",\"target\":\"node-a\"}",
  )
  should.equal(process.receive(rig.frames, 300), Error(Nil))
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(next_frame(rig.frames), "{\"v\":1,\"type\":\"pong\"}")
}

/// The thread actor's death does not strand the connection
/// (CodeRabbit): the adapter's monitor on the thread owner fires, the
/// node hears why, and the adapter stops — the socket-side monitor
/// closes the connection in production.
pub fn adapter_thread_death_stops_test() {
  let rig = start_rig(node_adapter.EnvRole)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  let _attached = next_frame(rig.frames)

  // Kill the fake thread's process: the adapter's monitor fires.
  let assert Ok(thread_pid) = process.subject_owner(rig.fake)
  process.kill(thread_pid)

  // The honest error frame, then silence (the adapter is dead — a late
  // ping is inert).
  let assert Ok(frame) = process.receive(rig.frames, 2000)
  should.be_true(string.contains(frame, "thread actor exited"))
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(process.receive(rig.frames, 200), Error(Nil))
}

/// The thread owner is resolved BEFORE any message (CodeRabbit): a
/// named subject with NO registered actor fails the adapter start
/// (the socket drops; the client reconnects) instead of starting a
/// monitor-less zombie.
pub fn adapter_missing_thread_owner_fails_start_test() {
  let name = process.new_name("nexus_test_absent_thread")
  let frames = process.new_subject()
  node_adapter.start_adapter(
    test_config(),
    thread_id,
    process.named_subject(name),
    "node-a",
    node_adapter.EnvRole,
    frames,
  )
  |> should.equal(Error(Nil))
}

/// The production shape (CodeRabbit): the thread subject is NAMED, and
/// a registry restart re-registers a REPLACEMENT under the same name.
/// The adapter's monitor holds the owner it resolved before sending,
/// so the replacement race is self-healing — the old owner's DOWN
/// closes the connection, and the node reconnects into the
/// replacement (fresh Join + AttachTarget).
pub fn adapter_thread_replacement_named_subject_test() {
  let name = process.new_name("nexus_test_named_thread")
  let first_pid = start_named_fake(name)
  let frames = process.new_subject()
  let assert Ok(adapter) =
    node_adapter.start_adapter(
      test_config(),
      thread_id,
      process.named_subject(name),
      "node-a",
      node_adapter.EnvRole,
      frames,
    )
  let _hello = next_frame(frames)
  let _replay = next_frame(frames)
  let _attached = next_frame(frames)

  // The registry analog: the old actor dies, a fresh one registers
  // under the SAME name (the adapter's Join/Attach went to the old
  // one — the messages cannot transfer).
  process.kill(first_pid)
  let _second_pid = start_named_fake(name)

  // The monitor's DOWN arrives: the honest error frame, then silence.
  let assert Ok(frame) = process.receive(frames, 2000)
  should.be_true(string.contains(frame, "thread actor exited"))
  process.send(adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(process.receive(frames, 200), Error(Nil))
}

/// A minimal NAMED thread fake: registers under `name` (the registry's
/// production shape) and answers the adapter's three arms. Started from
/// an UNLINKED wrapper so the test can kill the fake (the replacement)
/// without the `killed` exit propagating over a link to the TEST
/// process — actors started directly by a test are linked to it.
fn start_named_fake(name: process.Name(thread.Msg)) -> process.Pid {
  let back = process.new_subject()
  let _wrapper =
    process.spawn_unlinked(fn() {
      let assert Ok(started) =
        actor.new_with_initialiser(2000, fn(self) {
          actor.initialised(NamedFake(None))
          |> actor.returning(self)
          |> actor.selecting(process.new_selector() |> process.select(self))
          |> Ok
        })
        |> actor.named(name)
        |> actor.on_message(named_fake_handle)
        |> actor.start
      process.send(back, started.pid)
      process.sleep_forever()
    })
  let assert Ok(pid) = process.receive(back, 2000)
  pid
}

type NamedFake {
  NamedFake(sub: Option(Subject(thread.ThreadEvent)))
}

fn named_fake_handle(
  state: NamedFake,
  msg: thread.Msg,
) -> actor.Next(NamedFake, thread.Msg) {
  case msg {
    thread.Join(sub, visit) -> {
      process.send(
        sub,
        thread.ThreadEvent(thread_id, visit, thread.Hello("fake-alias", 2, [])),
      )
      process.send(
        sub,
        thread.ThreadEvent(
          thread_id,
          visit,
          thread.UserEcho(
            "attached targets: workspace.",
            Some(1),
            Some("system"),
          ),
        ),
      )
      actor.continue(NamedFake(Some(sub)))
    }
    thread.AttachTarget(_name, _exec, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }
    thread.Send(_text, _author, _depth, reply) -> {
      process.send(reply, thread.Sent)
      actor.continue(state)
    }
    _ -> actor.continue(state)
  }
}

/// A refused attach (roster race) tells the node why, then the adapter
/// stops — the linked socket dies with it.
pub fn adapter_attach_refusal_stops_test() {
  let rig = start_rig_mood(node_adapter.EnvRole, RefuseAttach)
  let _hello = next_frame(rig.frames)
  let _replay = next_frame(rig.frames)
  should.equal(
    next_frame(rig.frames),
    "{\"v\":1,\"type\":\"error\",\"message\":\"attach refused: target \\\"node-a\\\" is already attached\"}",
  )
  // The adapter is gone: a later frame send is inert.
  process.send(rig.adapter, node_adapter.FrameIn(node_protocol.Ping))
  should.equal(process.receive(rig.frames, 200), Error(Nil))
}
