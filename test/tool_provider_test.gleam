//// tool_provider tests (plugin-api plan Phase 1): boundary validation
//// (pure), the bounded ListTools ask, and the adapter's select loop —
//// pinned against a FAKE provider actor that speaks the protocol
//// directly, never a real plugin. Every behaviour the adapter must
//// survive is faked: instant replies, parked calls (timeout), gated
//// handoffs (cancel, provider-down, late replies), and a name that was
//// never registered.
////
//// Subject ownership (the AGENTS.md rule) shapes the harness: the
//// adapter receives on the reply subject it mints (caller-owned) and on
//// the CANCEL subject the caller owns. Tests that must act DURING a
//// run dispatch `run` into a spawned runner process which owns the
//// cancel subject and hands it out through a gate (the gated_runner
//// pattern from thread_test), then reports the outcome back.

import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/list
import gleam/otp/actor
import gleam/string
import gleeunit/should
import nexus/tool_provider.{
  type ToolDef, type ToolReply, Call, Cancelled, ListTools, ToolDef,
}

// ---------------------------------------------------------------------------
// The fake provider
// ---------------------------------------------------------------------------

/// Everything the fake does with a Call. Receives the call's parts
/// (ref, tool, arguments, reply) INSIDE the actor: reply at once, park
/// (do nothing), or hand the parts to the test through a gate.
pub type OnCall =
  fn(reference.Reference, String, String, Subject(ToolReply)) -> Nil

type FakeCfg {
  FakeCfg(
    tools: List(ToolDef),
    on_call: OnCall,
    on_cancel: fn(reference.Reference) -> Nil,
  )
}

fn start_fake(
  cfg: FakeCfg,
  name: process.Name(tool_provider.Msg),
) -> actor.StartResult(Subject(tool_provider.Msg)) {
  actor.new(cfg)
  |> actor.on_message(fn(cfg: FakeCfg, msg) {
    case msg {
      ListTools(reply) -> {
        process.send(reply, Ok(cfg.tools))
        actor.continue(cfg)
      }
      Call(ref, tool, arguments, reply) -> {
        cfg.on_call(ref, tool, arguments, reply)
        actor.continue(cfg)
      }
      Cancelled(ref) -> {
        cfg.on_cancel(ref)
        actor.continue(cfg)
      }
    }
  })
  |> actor.named(name)
  |> actor.start
}

fn noop(_ref: reference.Reference) -> Nil {
  Nil
}

/// One call's parts as handed to a test through a gate.
pub type CallParts {
  CallParts(ref: reference.Reference, reply: Subject(ToolReply))
}

/// The runner's report: the adapter outcome plus what the runner saw on
/// its own cancel subject after `run` returned.
type RunReport {
  RunReport(outcome: Result(String, String), resignalled: Bool)
}

/// Run the adapter in its own process (it must own the cancel subject),
/// hand the subject out through `gate`, and report the outcome plus
/// whether the mandatory re-signal arrived back on the cancel subject.
fn run_in_runner(
  name: process.Name(tool_provider.Msg),
  timeout_ms: Int,
  gate: Subject(Subject(Nil)),
  report: Subject(RunReport),
) -> Nil {
  let cancel = process.new_subject()
  process.send(gate, cancel)
  let outcome =
    tool_provider.run(
      provider: name,
      tool: "fetch",
      timeout_ms: timeout_ms,
      max_output_chars: 1000,
      cancel: cancel,
      arguments: "{}",
    )
  // The runner owns the subject, so this receive is legal. On the
  // cancel path the adapter must have put the Nil back.
  let resignalled = case process.receive(cancel, 0) {
    Ok(Nil) -> True
    Error(Nil) -> False
  }
  process.send(report, RunReport(outcome:, resignalled:))
}

const schema = "{\"type\":\"object\",\"properties\":{}}"

fn def(name: String) -> ToolDef {
  ToolDef(name: name, description: "fake " <> name, parameters_json: schema)
}

// ---------------------------------------------------------------------------
// Validation (pure)
// ---------------------------------------------------------------------------

pub fn valid_name_accepts_charset_test() {
  should.be_true(tool_provider.valid_name("a"))
  should.be_true(tool_provider.valid_name("A-Z_9"))
  should.be_true(tool_provider.valid_name("my-plugin_2"))
}

pub fn valid_name_rejects_bad_and_reserved_test() {
  should.be_false(tool_provider.valid_name(""))
  // The reserved separator is enforced on both halves …
  should.be_false(tool_provider.valid_name("a__b"))
  should.be_false(tool_provider.valid_name("__"))
  // … and split-unambiguity forbids edge underscores: `a_`+`b` and
  // `a`+`_b` would both qualify to `a___b`.
  should.be_false(tool_provider.valid_name("a_"))
  should.be_false(tool_provider.valid_name("_b"))
  should.be_false(tool_provider.valid_name("_"))
  should.be_true(tool_provider.valid_name("a_b"))
  should.be_false(tool_provider.valid_name("a b"))
  should.be_false(tool_provider.valid_name("a.b"))
  should.be_false(tool_provider.valid_name("tül"))
  should.be_false(tool_provider.valid_name("a/b"))
}

pub fn qualified_joins_with_separator_test() {
  should.equal(tool_provider.qualified("myplugin", "fetch"), "myplugin__fetch")
}

pub fn valid_parameters_accepts_object_root_test() {
  should.be_true(tool_provider.valid_parameters("{\"type\":\"object\"}"))
  should.be_true(tool_provider.valid_parameters(
    "{\"a\":{\"b\":[1,2,null,true]}}",
  ))
}

pub fn valid_parameters_rejects_non_object_or_broken_test() {
  should.be_false(tool_provider.valid_parameters("[1,2,3]"))
  should.be_false(tool_provider.valid_parameters("\"string\""))
  should.be_false(tool_provider.valid_parameters("42"))
  should.be_false(tool_provider.valid_parameters("null"))
  should.be_false(tool_provider.valid_parameters("{oops"))
  should.be_false(tool_provider.valid_parameters(""))
  // The byte bound: a valid object whose serialized form is too large.
  should.be_false(tool_provider.valid_parameters(
    "{\"pad\":\""
    <> string.repeat("x", tool_provider.max_parameters_bytes)
    <> "\"}",
  ))
}

pub fn truncate_caps_with_marker_test() {
  should.equal(tool_provider.truncate("short", 100), "short")
  let cut = tool_provider.truncate(string.repeat("x", 10), 4)
  should.be_true(string.starts_with(cut, "xxxx"))
  should.be_true(string.contains(cut, "truncated at 4 chars"))
}

// ---------------------------------------------------------------------------
// ListTools ask
// ---------------------------------------------------------------------------

pub fn list_tools_round_trip_test() {
  let name = process.new_name("nexus_plugin_askfake")
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("a"), def("b")],
        on_call: fn(_, _, _, _) { Nil },
        on_cancel: noop,
      ),
      name,
    )
  let assert Ok(defs) = tool_provider.list_tools(name, 2000)
  should.equal(list.map(defs, fn(d) { d.name }), ["a", "b"])
}

pub fn list_tools_times_out_test() {
  // A name that was minted but never registered: the ask must fail, not
  // hang (and named_subject is only built after liveness in `run`).
  let name = process.new_name("nexus_plugin_never_started")
  let assert Error(_) = tool_provider.list_tools(name, 100)
}

// ---------------------------------------------------------------------------
// The adapter select loop
// ---------------------------------------------------------------------------

pub fn run_unavailable_without_registration_test() {
  let name = process.new_name("nexus_plugin_ghost")
  let cancel = process.new_subject()
  should.equal(
    tool_provider.run(name, "fetch", 1000, 100, cancel, "{}"),
    Error("tool provider is unavailable"),
  )
}

pub fn run_ok_and_err_round_trip_test() {
  let name = process.new_name("nexus_plugin_echo")
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(_ref, tool, _args, reply) {
          case tool {
            "fetch" -> process.send(reply, tool_provider.ToolOk("did fetch"))
            other ->
              process.send(reply, tool_provider.ToolErr("no tool " <> other))
          }
        },
        on_cancel: noop,
      ),
      name,
    )
  let cancel = process.new_subject()
  should.equal(
    tool_provider.run(name, "fetch", 2000, 100, cancel, "{}"),
    Ok("did fetch"),
  )
  // A ToolErr is a failed tool result, not a loop error.
  should.equal(
    tool_provider.run(name, "bad", 2000, 100, cancel, "{}"),
    Error("no tool bad"),
  )
}

pub fn run_times_out_when_provider_parks_test() {
  let name = process.new_name("nexus_plugin_parked")
  let cancels = process.new_subject()
  // on_call does nothing: the reply never comes; on_cancel records the
  // ref so the deadline path's best-effort Cancelled is observable.
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(_, _, _, _) { Nil },
        on_cancel: fn(ref) { process.send(cancels, ref) },
      ),
      name,
    )
  let cancel = process.new_subject()
  should.equal(
    tool_provider.run(name, "fetch", 150, 1000, cancel, "{}"),
    Error("timed out after 150 ms"),
  )
  // The protocol's documented deadline behavior: the provider gets a
  // best-effort Cancelled for the abandoned call.
  let assert Ok(_ref) = process.receive(cancels, 2000)
  Nil
}

pub fn run_truncates_ok_and_err_test() {
  let name = process.new_name("nexus_plugin_loud")
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(_ref, tool, _args, reply) {
          case tool {
            "fetch" ->
              process.send(reply, tool_provider.ToolOk(string.repeat("y", 50)))
            "bad" ->
              process.send(reply, tool_provider.ToolErr(string.repeat("e", 50)))
            _ -> Nil
          }
        },
        on_cancel: noop,
      ),
      name,
    )
  let cancel = process.new_subject()
  let assert Ok(content) =
    tool_provider.run(name, "fetch", 2000, 10, cancel, "{}")
  should.be_true(string.contains(content, "truncated at 10 chars"))
  let assert Error(message) =
    tool_provider.run(name, "bad", 2000, 10, cancel, "{}")
  should.be_true(string.contains(message, "truncated at 10 chars"))
}

pub fn run_cancel_re_signals_and_notifies_provider_test() {
  let name = process.new_name("nexus_plugin_gated")
  let calls = process.new_subject()
  let cancels = process.new_subject()
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        // Hand the call parts to the test and park: the adapter's
        // cancel path must fire while the call is in flight.
        on_call: fn(ref, _tool, _args, reply) {
          process.send(calls, CallParts(ref, reply))
        },
        on_cancel: fn(ref) { process.send(cancels, ref) },
      ),
      name,
    )
  let runner_gate = process.new_subject()
  let report = process.new_subject()
  process.spawn(fn() { run_in_runner(name, 5000, runner_gate, report) })
  let assert Ok(cancel) = process.receive(runner_gate, 2000)
  // Stop the turn: the adapter consumes the Nil, must return cancelled,
  // re-signal the subject, and deliver Cancelled to the provider.
  process.send(cancel, Nil)
  let assert Ok(RunReport(Error("cancelled"), True)) =
    process.receive(report, 2000)
  // The provider saw the cancellation for the in-flight ref.
  let assert Ok(CallParts(ref, _)) = process.receive(calls, 0)
  let assert Ok(cancelled_ref) = process.receive(cancels, 2000)
  should.equal(cancelled_ref, ref)
}

pub fn run_answers_when_provider_dies_mid_call_test() {
  let name = process.new_name("nexus_plugin_doomed")
  let calls = process.new_subject()
  let assert Ok(started) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(ref, _tool, _args, _reply) {
          process.send(calls, CallParts(ref, process.new_subject()))
        },
        on_cancel: noop,
      ),
      name,
    )
  let runner_gate = process.new_subject()
  let report = process.new_subject()
  process.spawn(fn() { run_in_runner(name, 5000, runner_gate, report) })
  let _cancel = process.receive(runner_gate, 2000)
  // Wait for dispatch, then kill the provider: the monitor must answer
  // immediately instead of burning the deadline. The fake is linked to
  // this test process, so trap exits for the duration of the kill.
  let _ = process.receive(calls, 2000)
  process.trap_exits(True)
  process.kill(started.pid)
  let assert Ok(RunReport(Error("tool provider is unavailable"), False)) =
    process.receive(report, 2000)
  process.trap_exits(False)
}

pub fn run_late_reply_is_inert_test() {
  let name = process.new_name("nexus_plugin_late")
  let calls = process.new_subject()
  let assert Ok(_) =
    start_fake(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(ref, _tool, _args, reply) {
          process.send(calls, CallParts(ref, reply))
        },
        on_cancel: noop,
      ),
      name,
    )
  let runner_gate = process.new_subject()
  let report = process.new_subject()
  process.spawn(fn() { run_in_runner(name, 150, runner_gate, report) })
  let _cancel = process.receive(runner_gate, 2000)
  // The deadline expires first…
  let assert Ok(RunReport(Error("timed out after 150 ms"), False)) =
    process.receive(report, 2000)
  // …then the provider answers anyway. The reply lands on a subject
  // owned by the (finished) runner: inert by construction, and sending
  // to it must not crash anyone. The provider must still be usable —
  // it gates (and parks) a follow-up call, proving the actor still
  // processes after the late reply was sent.
  let assert Ok(CallParts(_ref, reply_subject)) = process.receive(calls, 2000)
  process.send(reply_subject, tool_provider.ToolOk("too late"))
  let cancel2 = process.new_subject()
  should.equal(
    tool_provider.run(name, "fetch", 150, 100, cancel2, "{}"),
    Error("timed out after 150 ms"),
  )
  let assert Ok(CallParts(_, _)) = process.receive(calls, 0)
}

// ---------------------------------------------------------------------------
// run_remote (environments plan Phase 2b-2)
// ---------------------------------------------------------------------------

/// An UNNAMED fake — the execution-plane shape the thread actor's map
/// hands out: subject + pid, no registered name (node names are unique
/// per roster, not per instance; the map is the registry). Same
/// protocol handler as the named fake.
fn start_fake_unnamed(
  cfg: FakeCfg,
) -> #(Subject(tool_provider.Msg), process.Pid) {
  let assert Ok(started) =
    actor.new(cfg)
    |> actor.on_message(fn(cfg: FakeCfg, msg: tool_provider.Msg) {
      case msg {
        ListTools(reply) -> {
          process.send(reply, Ok(cfg.tools))
          actor.continue(cfg)
        }
        Call(ref, tool, arguments, reply) -> {
          cfg.on_call(ref, tool, arguments, reply)
          actor.continue(cfg)
        }
        Cancelled(ref) -> {
          cfg.on_cancel(ref)
          actor.continue(cfg)
        }
      }
    })
    |> actor.start
  #(started.data, started.pid)
}

/// The `run_in_runner` shape against a (subject, pid) plane: the
/// runner owns the cancel subject, hands it out through the gate, and
/// reports the outcome plus whether the mandatory re-signal arrived.
fn run_remote_in_runner(
  plane: #(Subject(tool_provider.Msg), process.Pid),
  timeout_ms: Int,
  gate: Subject(Subject(Nil)),
  report: Subject(RunReport),
) -> Nil {
  let cancel = process.new_subject()
  process.send(gate, cancel)
  let outcome =
    tool_provider.run_remote(
      provider: plane.0,
      owner: plane.1,
      tool: "fetch",
      timeout_ms: timeout_ms,
      max_output_chars: 1000,
      cancel: cancel,
      arguments: "{}",
    )
  let resignalled = case process.receive(cancel, 0) {
    Ok(Nil) -> True
    Error(Nil) -> False
  }
  process.send(report, RunReport(outcome:, resignalled:))
}

pub fn run_remote_round_trip_test() {
  let plane =
    start_fake_unnamed(FakeCfg(
      tools: [def("fetch")],
      on_call: fn(_ref, tool, _args, reply) {
        case tool {
          "fetch" -> process.send(reply, tool_provider.ToolOk("from the node"))
          other ->
            process.send(reply, tool_provider.ToolErr("no tool " <> other))
        }
      },
      on_cancel: noop,
    ))
  let cancel = process.new_subject()
  should.equal(
    tool_provider.run_remote(
      provider: plane.0,
      owner: plane.1,
      tool: "fetch",
      timeout_ms: 2000,
      max_output_chars: 100,
      cancel: cancel,
      arguments: "{}",
    ),
    Ok("from the node"),
  )
  should.equal(
    tool_provider.run_remote(
      provider: plane.0,
      owner: plane.1,
      tool: "bad",
      timeout_ms: 2000,
      max_output_chars: 100,
      cancel: cancel,
      arguments: "{}",
    ),
    Error("no tool bad"),
  )
}

/// Wait (bounded) until the pid is gone — `kill` delivers
/// asynchronously.
fn await_dead(pid: process.Pid, tries: Int) -> Nil {
  case process.is_alive(pid), tries > 0 {
    False, _ -> Nil
    True, True -> {
      process.sleep(20)
      await_dead(pid, tries - 1)
    }
    True, False -> panic as "owner survived the kill"
  }
}

pub fn run_remote_unavailable_when_owner_is_dead_test() {
  // An UNLINKED parked owner (the actor fakes are linked to this test
  // process — killing one races an untrapped EXIT into the runner).
  // Unlinked, the kill carries no exit signal here; the bounded
  // liveness poll waits out the kill's asynchronous delivery.
  let back = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(back, process.new_subject())
      process.sleep_forever()
    })
  let assert Ok(sub) = process.receive(back, 2000)
  process.kill(pid)
  await_dead(pid, 100)
  let cancel = process.new_subject()
  // The liveness check answers immediately — no dispatch, no burned
  // deadline.
  should.equal(
    tool_provider.run_remote(
      provider: sub,
      owner: pid,
      tool: "fetch",
      timeout_ms: 2000,
      max_output_chars: 100,
      cancel: cancel,
      arguments: "{}",
    ),
    Error("tool provider is unavailable"),
  )
}

pub fn run_remote_cancel_re_signals_and_notifies_provider_test() {
  let calls = process.new_subject()
  let cancels = process.new_subject()
  let plane =
    start_fake_unnamed(
      FakeCfg(
        tools: [def("fetch")],
        on_call: fn(ref, _tool, _args, reply) {
          process.send(calls, CallParts(ref, reply))
        },
        on_cancel: fn(ref) { process.send(cancels, ref) },
      ),
    )
  let runner_gate = process.new_subject()
  let report = process.new_subject()
  process.spawn(fn() { run_remote_in_runner(plane, 5000, runner_gate, report) })
  let assert Ok(cancel) = process.receive(runner_gate, 2000)
  process.send(cancel, Nil)
  let assert Ok(RunReport(Error("cancelled"), True)) =
    process.receive(report, 2000)
  let assert Ok(CallParts(ref, _)) = process.receive(calls, 0)
  let assert Ok(cancelled_ref) = process.receive(cancels, 2000)
  should.equal(cancelled_ref, ref)
}

pub fn run_remote_answers_when_owner_dies_mid_call_test() {
  let calls = process.new_subject()
  let plane =
    start_fake_unnamed(FakeCfg(
      tools: [def("fetch")],
      on_call: fn(ref, _tool, _args, _reply) {
        process.send(calls, CallParts(ref, process.new_subject()))
      },
      on_cancel: noop,
    ))
  let runner_gate = process.new_subject()
  let report = process.new_subject()
  process.spawn(fn() { run_remote_in_runner(plane, 5000, runner_gate, report) })
  let _cancel = process.receive(runner_gate, 2000)
  let _ = process.receive(calls, 2000)
  process.trap_exits(True)
  process.kill(plane.1)
  let assert Ok(RunReport(Error("tool provider is unavailable"), False)) =
    process.receive(report, 2000)
  process.trap_exits(False)
}
