//// Offline tests for the M1 session actor protocol, using scripted fake
//// turn runners — no network, no Bifrost.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/config
import nexus/loop
import nexus/openai
import nexus/session
import nexus/transcript
import nexus/utility

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
    // Utility side-call on (the default): tests inject no-op fakes, and a
    // debounced failed attempt is invisible to event assertions.
    utility_enabled: True,
    utility_delay_ms: 1500,
  )
}

fn stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(12),
    duration_ms: 345,
    token_deltas: 2,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 7,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Emits two token deltas then reports success.
fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("Hello")))
  on_event(loop.StreamEvent(openai.TokenDelta(" world")))
  session.StreamDone(stats(), transcript.append_assistant(tr, "Hello world"))
}

/// Emits one token, then blocks until cancelled (Stop) or times out.
fn blocking_runner(
  _endpoint,
  tr,
  cancel: process.Subject(Nil),
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("partial")))
  let selector = process.new_selector() |> process.select(cancel)
  case process.selector_receive(selector, 5000) {
    Ok(_) -> session.StreamStopped(transcript.append_assistant(tr, "partial"))
    Error(_) -> session.StreamErrored("timeout")
  }
}

/// Emits two deltas separated by a delay, making a TTFT regression visible.
fn delayed_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("first")))
  process.sleep(60)
  on_event(loop.StreamEvent(openai.TokenDelta("second")))
  session.StreamDone(stats(), transcript.append_assistant(tr, "firstsecond"))
}

/// Emits a token then fails: nothing may be committed.
fn failing_runner(
  _endpoint,
  _tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("never committed")))
  session.StreamErrored("non200")
}

/// Kills its own (worker) process: the monitor path must convert this into
/// a TurnFailed without hurting the session actor.
fn crashing_runner(_endpoint, _tr, _cancel, _on_event) -> session.TurnOutcome {
  process.kill(process.self())
  session.StreamErrored("unreachable")
}

type CounterMsg {
  Ping(reply: process.Subject(Int))
}

/// A tiny turn counter: the flaky runner below needs to know which turn it
/// is on, and the session actor serialises turns, so the count is exact.
fn start_counter() -> process.Subject(CounterMsg) {
  // The subject must be owned by the counter process itself, so create it
  // there and hand it back over an ack subject.
  let ack = process.new_subject()
  process.spawn(fn() {
    let subj = process.new_subject()
    process.send(ack, subj)
    counter_loop(subj, 0)
  })
  let assert Ok(subj) = process.receive(ack, 1000)
  subj
}

fn counter_loop(subj: process.Subject(CounterMsg), count: Int) -> Nil {
  case process.receive_forever(subj) {
    Ping(reply) -> {
      process.send(reply, count + 1)
      counter_loop(subj, count + 1)
    }
  }
}

/// First turn streams normally, later turns fail: session A gets two metric
/// samples while committing the same history as a single-turn session.
fn flaky_runner(counter: process.Subject(CounterMsg)) -> session.TurnRunner {
  fn(_endpoint, tr, _cancel, on_event: fn(loop.LoopEvent) -> Nil) {
    let turn = process.call(counter, 1000, fn(reply) { Ping(reply) })
    on_event(loop.StreamEvent(openai.TokenDelta("Hello")))
    on_event(loop.StreamEvent(openai.TokenDelta(" world")))
    case turn {
      1 ->
        session.StreamDone(
          stats(),
          transcript.append_assistant(tr, "Hello world"),
        )
      _ -> session.StreamErrored("later turn failed")
    }
  }
}

fn expect_hello(
  sub: process.Subject(session.SessionEvent),
  model: String,
  messages: Int,
) -> session.SessionEvent {
  let event = expect_event(sub)
  case event {
    session.Hello(model: m, messages: n, metrics: _)
      if m == model && n == messages
    -> event
    _ -> panic as "expected hello"
  }
}

/// The sample a `happy_runner` turn must leave behind. Timings are measured
/// from the actor's monotonic clock, so only the shape is asserted here.
fn is_completed(sample: session.MetricSample) -> Bool {
  sample.outcome == session.Completed
  && sample.token_deltas == 2
  && sample.duration_ms >= 0
  && sample.stopped_chars == None
  && sample.failure_reason == None
}

fn expect_event(
  sub: process.Subject(session.SessionEvent),
) -> session.SessionEvent {
  let assert Ok(event) = process.receive(sub, 2000)
  event
}

fn test_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "https://provider.example/v1",
    api_key: None,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
  )
}

/// Utility seams for tests that never exercise the side call: the runner
/// refuses (best-effort failure, discarded) and the apply is never reached.
fn no_utility_runner(
  _endpoint,
  _tr,
  _cancel,
  _allow_pass,
) -> Result(utility.Verdict, String) {
  Error("no utility call expected in this test")
}

fn no_utility_apply(_title: String) -> Result(session.UtilityMeta, Nil) {
  Error(Nil)
}

fn start_with(runner: session.TurnRunner) -> process.Subject(session.Msg) {
  let assert Ok(started) =
    session.start_with_spec(session.SessionSpec(
      cfg: test_config(),
      model: "test-alias",
      endpoint: test_endpoint(),
      runner: runner,
      commit_hook: fn(_) { Nil },
      hydrate: None,
      // No utility attempt is expected in these tests: the fake refuses,
      // and a failed attempt broadcasts nothing.
      utility_runner: no_utility_runner,
      utility_apply: no_utility_apply,
    ))
  started.data
}

fn join(
  sess: process.Subject(session.Msg),
) -> process.Subject(session.SessionEvent) {
  let sub = process.new_subject()
  process.send(sess, session.Join(sub))
  sub
}

pub fn join_replays_history_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  expect_event(sub) |> should.equal(session.Hello("test-alias", 1, []))
  should.equal(session.send_message(sess, "hi"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("hi"))
  expect_event(sub) |> should.equal(session.Token("Hello"))
  expect_event(sub) |> should.equal(session.Token(" world"))
  let assert session.TurnDone(stats) = expect_event(sub)
  stats.token_deltas |> should.equal(2)

  // A second subscriber joins after the turn: it gets Hello + replay.
  let sub2 = join(sess)
  let assert session.Hello(model:, messages:, metrics:) = expect_event(sub2)
  model |> should.equal("test-alias")
  messages |> should.equal(3)
  // Reconnect replays the turn's metric sample (M2 §4.2).
  metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(metrics)
  should.be_true(is_completed(sample))
  expect_event(sub2) |> should.equal(session.UserEcho("hi"))
  expect_event(sub2) |> should.equal(session.AssistantFull("Hello world"))
}

pub fn completed_turn_appends_and_is_byte_stable_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "question"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("question"))
  expect_event(sub) |> should.equal(session.Token("Hello"))
  expect_event(sub) |> should.equal(session.Token(" world"))
  let assert session.TurnDone(_) = expect_event(sub)

  let tr = session.snapshot(sess)
  transcript.length(tr) |> should.equal(3)

  // Contract rule 4: rebuilding from the same immutable list is
  // byte-identical.
  let opts = transcript.Options(..transcript.default_options(), stream: True)
  let body = transcript.request_body(tr, opts)
  transcript.request_body(tr, opts) |> should.equal(body)
}

pub fn busy_rejects_second_send_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  // The worker emits its token before blocking; wait for it.
  expect_event(sub) |> should.equal(session.UserEcho("first"))
  expect_event(sub) |> should.equal(session.Token("partial"))

  // Turn in flight: second send is rejected.
  should.equal(session.send_message(sess, "second"), session.Busy)
  session.stop(sess)
  let _ = expect_event(sub)
}

pub fn stop_cancels_and_commits_partial_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "stop me"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("stop me"))
  expect_event(sub) |> should.equal(session.Token("partial"))

  session.stop(sess)
  expect_event(sub) |> should.equal(session.TurnStopped(7))

  // Partial text was committed as the assistant turn.
  transcript.length(session.snapshot(sess)) |> should.equal(3)

  // Session accepts a new turn after the stop.
  should.equal(session.send_message(sess, "again"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("again"))
  expect_event(sub) |> should.equal(session.Token("partial"))
  session.stop(sess)
  let _ = expect_event(sub)
}

pub fn failed_turn_commits_nothing_test() {
  let sess = start_with(failing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "will fail"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("will fail"))
  expect_event(sub) |> should.equal(session.Token("never committed"))
  let assert session.TurnFailed(reason) = expect_event(sub)
  should.be_true(string.contains(reason, "non200"))

  // System + user only: no assistant message, so a retry resends a
  // byte-identical prefix (cache-friendly).
  transcript.length(session.snapshot(sess)) |> should.equal(2)

  // And the session is usable again afterwards.
  should.equal(session.send_message(sess, "retry"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("retry"))
  expect_event(sub) |> should.equal(session.Token("never committed"))
  let _ = expect_event(sub)
}

pub fn crashing_worker_does_not_kill_session_test() {
  let sess = start_with(crashing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "boom"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("boom"))
  let assert session.TurnFailed(reason) = expect_event(sub)
  should.be_true(string.contains(reason, "worker"))

  // The actor survived and accepts another turn.
  should.equal(session.send_message(sess, "still alive"), session.Sent)
}

/// Live-streaming sessions stay single-turn even when the subscriber list
/// keeps growing: two subscribers both see every event.
pub fn fan_out_to_all_subscribers_test() {
  let sess = start_with(happy_runner)
  let sub1 = join(sess)
  let _ = expect_event(sub1)
  let sub2 = join(sess)
  let _ = expect_event(sub2)

  should.equal(session.send_message(sess, "both"), session.Sent)
  let expected = [
    session.UserEcho("both"),
    session.Token("Hello"),
    session.Token(" world"),
  ]
  list.each(expected, fn(event) {
    expect_event(sub1) |> should.equal(event)
    expect_event(sub2) |> should.equal(event)
  })
}

// ---------------------------------------------------------------------------
// M2: model pinning, metrics, and describe
// ---------------------------------------------------------------------------

/// Step 1 (plan §7): the constructor takes the selected alias through the
/// spec; there is no config default to fall back to after the P3 hard cut.
pub fn selected_alias_is_frozen_test() {
  let spec =
    session.SessionSpec(
      cfg: test_config(),
      model: "chosen-alias",
      endpoint: test_endpoint(),
      runner: happy_runner,
      commit_hook: fn(_) { Nil },
      hydrate: None,
      utility_runner: no_utility_runner,
      utility_apply: no_utility_apply,
    )
  let assert Ok(started) = session.start_with_spec(spec)
  let sess = started.data
  let sub = join(sess)
  expect_hello(sub, "chosen-alias", 1)

  should.equal(session.send_message(sess, "hi"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // The transcript carries the selected alias, never anything else —
  // there is no config default to fall back to after the P3 hard cut.
  let tr = session.snapshot(sess)
  transcript.model(tr) |> should.equal("chosen-alias")
}

/// P3 (multi-provider §8): the session hands its runner the FROZEN
/// endpoint from the spec — one provider per session, for every turn of
/// its lifetime. A swapped-in different endpoint must never reach an
/// existing session's runner.
pub fn runner_receives_frozen_endpoint_test() {
  let seen = process.new_subject()
  let capturing = fn(endpoint, tr, _cancel, _on_event) {
    process.send(seen, endpoint)
    session.StreamDone(stats(), transcript.append_assistant(tr, "ok"))
  }
  let spec =
    session.SessionSpec(
      cfg: test_config(),
      model: "test-alias",
      endpoint: test_endpoint(),
      runner: capturing,
      commit_hook: fn(_) { Nil },
      hydrate: None,
      utility_runner: no_utility_runner,
      utility_apply: no_utility_apply,
    )
  let assert Ok(started) = session.start_with_spec(spec)
  let sess = started.data
  should.equal(session.send_message(sess, "hi"), session.Sent)
  let assert Ok(endpoint) = process.receive(seen, 2000)
  endpoint |> should.equal(test_endpoint())
}

/// A completed turn leaves exactly one `Completed` sample.
pub fn completed_turn_records_metric_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "go"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  let status = session.describe(sess)
  status.streaming |> should.be_false
  status.message_count |> should.equal(3)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(session.Completed)
  sample.token_deltas |> should.equal(2)
  sample.stopped_chars |> should.equal(None)
  sample.failure_reason |> should.equal(None)
  // Duration is measured from the actor's clock; a real turn is >= 0ms.
  should.be_true(sample.duration_ms >= 0)
}

/// TTFT is measured to the first delta, not the most recent delta.
pub fn completed_turn_preserves_first_token_time_test() {
  let sess = start_with(delayed_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "slow second token"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let assert session.TurnDone(_) = expect_event(sub)

  let status = session.describe(sess)
  let assert Ok(sample) = list.first(status.metrics)
  let assert Some(ttft_ms) = sample.ttft_ms
  should.be_true(ttft_ms + 10 <= sample.duration_ms)
  should.be_true(sample.duration_ms >= 50)
}

/// A stopped turn records the committed character count.
pub fn stopped_turn_records_metric_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "stop me"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  session.stop(sess)
  expect_event(sub) |> should.equal(session.TurnStopped(7))

  let status = session.describe(sess)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(session.Stopped)
  sample.stopped_chars |> should.equal(Some(7))
  sample.failure_reason |> should.equal(None)
}

/// A failed turn records the reason and commits nothing.
pub fn failed_turn_records_metric_test() {
  let sess = start_with(failing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "will fail"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  let status = session.describe(sess)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(session.Failed)
  case sample.failure_reason {
    Some(reason) -> should.be_true(string.contains(reason, "non200"))
    None -> panic as "expected a failure reason"
  }
  // Nothing was committed: system + user only.
  status.message_count |> should.equal(2)
}

/// Metrics are display state only: two sessions carrying different numbers
/// of metric samples must still produce byte-identical request bodies for
/// the same committed history (KV-cache contract rule 4).
pub fn metrics_do_not_affect_request_bytes_test() {
  // Session A records a Completed *and* a Failed sample; the failed turn
  // commits nothing, so A's committed history equals session B's.
  let counter = start_counter()
  let a = start_with(flaky_runner(counter))
  let sub_a = join(a)
  let _ = expect_event(sub_a)
  should.equal(session.send_message(a, "same"), session.Sent)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  // Snapshot after the successful turn: this is the history both sessions
  // end up with.
  let tr_a = session.snapshot(a)

  should.equal(session.send_message(a, "boom"), session.Sent)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)

  let b = start_with(happy_runner)
  let sub_b = join(b)
  let _ = expect_event(sub_b)
  should.equal(session.send_message(b, "same"), session.Sent)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)

  session.describe(a).metrics |> list.length |> should.equal(2)
  session.describe(b).metrics |> list.length |> should.equal(1)
  tr_a
  |> transcript.length
  |> should.equal(session.snapshot(b) |> transcript.length)

  // Two sessions with different metric histories encode identically.
  let opts = transcript.Options(..transcript.default_options(), stream: True)
  transcript.request_body(tr_a, opts)
  |> should.equal(transcript.request_body(session.snapshot(b), opts))
}

/// `Describe` reports `streaming` while a turn is in flight.
pub fn describe_reports_streaming_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(session.send_message(sess, "slow"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  session.describe(sess).streaming |> should.be_true
  session.stop(sess)
  let _ = expect_event(sub)
  session.describe(sess).streaming |> should.be_false
}

// ---------------------------------------------------------------------------
// M3: tool loop events, replay, and the iteration guard
// ---------------------------------------------------------------------------

/// A fake runner that walks one tool round: streams a fragment, assembles
/// a call, runs nothing, reports the result, then finishes the turn.
fn tool_round_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.LoopStatus(1, 8, "request"))
  on_event(
    loop.StreamEvent(openai.ToolCallDelta(
      0,
      Some("call_1"),
      Some("http_fetch"),
      "{\"url\":\"https://example.invalid/\"}",
    )),
  )
  on_event(loop.LoopStatus(1, 8, "tools"))
  on_event(loop.ToolCallAssembled(
    "call_1",
    "http_fetch",
    "{\"url\":\"https://example.invalid/\"}",
  ))
  on_event(loop.ToolResultEvent(
    "call_1",
    "http_fetch",
    True,
    "{\"status\":200}",
  ))
  on_event(loop.StreamEvent(openai.TokenDelta("based on the fetch: fine")))
  session.StreamDone(
    stats(),
    tr
      |> transcript.append_assistant_tool_calls(
        text: None,
        calls: [
          #("call_1", "http_fetch", "{\"url\":\"https://example.invalid/\"}"),
        ],
        reasoning: None,
      )
      |> transcript.append_tool_result(
        tool_call_id: "call_1",
        content: "{\"status\":200}",
      )
      |> transcript.append_assistant("based on the fetch: fine"),
  )
}

pub fn tool_events_are_broadcast_test() {
  let sess = start_with(tool_round_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "fetch it"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("fetch it"))
  expect_event(sub) |> should.equal(session.LoopStatus(1, 8, "request"))
  expect_event(sub)
  |> should.equal(session.ToolCallDelta(
    0,
    Some("call_1"),
    Some("http_fetch"),
    "{\"url\":\"https://example.invalid/\"}",
  ))
  expect_event(sub) |> should.equal(session.LoopStatus(1, 8, "tools"))
  expect_event(sub)
  |> should.equal(session.ToolCallAssembled(
    "call_1",
    "http_fetch",
    "{\"url\":\"https://example.invalid/\"}",
  ))
  expect_event(sub)
  |> should.equal(session.ToolResult(
    "call_1",
    "http_fetch",
    True,
    "{\"status\":200}",
  ))
  expect_event(sub) |> should.equal(session.Token("based on the fetch: fine"))
  let assert session.TurnDone(_) = expect_event(sub)

  // The full tool history is committed: system, user, assistant(call),
  // tool result, assistant text.
  transcript.length(session.snapshot(sess)) |> should.equal(5)
}

pub fn tool_history_replays_on_rejoin_test() {
  let sess = start_with(tool_round_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(session.send_message(sess, "fetch it"), session.Sent)
  // Drain the live events (UserEcho, LoopStatus, ToolCallDelta, LoopStatus,
  // ToolCallAssembled, ToolResult, Token, TurnDone).
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // A fresh subscriber gets the tool history reconstructed from the
  // transcript, with tool names resolved from the assistant message.
  let sub2 = join(sess)
  let assert session.Hello(_, messages, _) = expect_event(sub2)
  messages |> should.equal(5)
  expect_event(sub2) |> should.equal(session.UserEcho("fetch it"))
  expect_event(sub2)
  |> should.equal(session.ToolCallAssembled(
    "call_1",
    "http_fetch",
    "{\"url\":\"https://example.invalid/\"}",
  ))
  expect_event(sub2)
  |> should.equal(session.ToolResult(
    "call_1",
    "http_fetch",
    True,
    "{\"status\":200}",
  ))
  expect_event(sub2)
  |> should.equal(session.AssistantFull("based on the fetch: fine"))
}

fn guard_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.LoopStatus(4, 4, "guard"))
  session.StreamGuard(4, tr)
}

pub fn guard_hit_renders_terminal_failure_test() {
  let sess = start_with(guard_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "keep calling"), session.Sent)
  let _ = expect_event(sub)
  expect_event(sub) |> should.equal(session.LoopStatus(4, 4, "guard"))
  let assert session.TurnFailed(reason) = expect_event(sub)
  should.be_true(string.contains(reason, "iteration guard"))

  // The turn still commits its transcript (tool rounds happened), and the
  // guard is visible as a Failed metric sample.
  let status = session.describe(sess)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(session.Failed)
  should.be_true(string.contains(
    option.unwrap(sample.failure_reason, ""),
    "guard",
  ))
}

// ---------------------------------------------------------------------------
// Reasoning (chain of thought)
// ---------------------------------------------------------------------------

/// Emits reasoning deltas, then content, committing both with the message.
fn reasoning_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.ReasoningDelta("pondering ")))
  on_event(loop.StreamEvent(openai.ReasoningDelta("deeply")))
  on_event(loop.StreamEvent(openai.TokenDelta("answer")))
  session.StreamDone(
    stats(),
    transcript.append_assistant_with_reasoning(
      tr,
      "answer",
      Some("pondering deeply"),
    ),
  )
}

pub fn reasoning_streams_live_and_replays_on_rejoin_test() {
  let sess = start_with(reasoning_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(session.send_message(sess, "think"), session.Sent)
  expect_event(sub) |> should.equal(session.UserEcho("think"))
  expect_event(sub) |> should.equal(session.Reasoning("pondering "))
  expect_event(sub) |> should.equal(session.Reasoning("deeply"))
  expect_event(sub) |> should.equal(session.Token("answer"))
  let assert session.TurnDone(_) = expect_event(sub)

  // A fresh subscriber replays the committed reasoning just before the
  // assistant message it preceded.
  let sub2 = join(sess)
  let assert session.Hello(_, 3, _) = expect_event(sub2)
  expect_event(sub2) |> should.equal(session.UserEcho("think"))
  expect_event(sub2) |> should.equal(session.ReasoningFull("pondering deeply"))
  expect_event(sub2) |> should.equal(session.AssistantFull("answer"))
}

// ---------------------------------------------------------------------------
// Utility side-call (utility-titles plan §4.2/§6): trigger, cancel, result
// ---------------------------------------------------------------------------

/// What the fake utility runner / apply seam reports back to the test.
type UtilityEvent {
  /// The runner was invoked, with the committed snapshot's message count.
  UtilCalled(messages: Int)
  /// The runner was invoked with `allow_pass = False` — a re-armed
  /// attempt after a pass MUST arrive this way (the one-pass policy).
  UtilForcedAttempt
  /// The runner observed its cancel subject fire.
  UtilCancelled
  /// The runner observed the test's release signal.
  UtilReleased
  /// The apply seam was reached with the parsed title.
  UtilAppliedNote(title: String)
  /// The apply seam was REFUSED (guard declined); still records the call.
  UtilRefusedNote(title: String)
}

/// The per-attempt handles a blocking fake hands to the test: `release`
/// completes the attempt with a title, `resume` lets a CANCELLED attempt
/// finally report (the test holds it until the racing turn's commit has
/// been observed, pinning the arm-while-unreported order).
type AttemptHandles {
  AttemptHandles(release: process.Subject(Nil), resume: process.Subject(Nil))
}

fn expect_utility(events: process.Subject(UtilityEvent)) -> UtilityEvent {
  let assert Ok(event) = process.receive(events, 2000)
  event
}

/// Like `expect_utility`, but the wait names itself — a timeout panic
/// points at the step that never happened.
fn expect_utility_step(
  events: process.Subject(UtilityEvent),
  step: String,
) -> UtilityEvent {
  case process.receive(events, 2000) {
    Ok(event) -> event
    Error(_) -> panic as { "timed out waiting for: " <> step }
  }
}

/// No utility (or apply) activity within `ms` — the negative half of the
/// trigger rules (failed turns, disabled config, once-per-session).
fn expect_no_utility(events: process.Subject(UtilityEvent), ms: Int) -> Nil {
  let assert Error(_) = process.receive(events, ms)
  Nil
}

fn expect_no_event(sub: process.Subject(session.SessionEvent), ms: Int) -> Nil {
  let assert Error(_) = process.receive(sub, ms)
  Nil
}

/// The session config with the side-call knob turned up for fast tests.
fn utility_config(delay_ms: Int) -> config.Config {
  config.Config(
    ..test_config(),
    utility_enabled: True,
    utility_delay_ms: delay_ms,
  )
}

/// A runner that completes immediately with `title`, recording the
/// snapshot size it was handed (the committed exchange it forked from).
fn ok_utility(
  events: process.Subject(UtilityEvent),
  title: String,
) -> session.UtilityRunner {
  fn(_endpoint, tr, _cancel, _allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    Ok(utility.Title(title))
  }
}

/// The greeting-session model: it PASSes every attempt that offers the
/// sentinel. Paired with the apply seam it lets tests pin both halves of
/// the one-pass policy — the re-armed attempt must arrive forced
/// (`UtilForcedAttempt`), and a PASS under the forced instruction must
/// consume the attempt like any failure.
fn passing_utility(
  events: process.Subject(UtilityEvent),
) -> session.UtilityRunner {
  fn(_endpoint, tr, _cancel, allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    case allow_pass {
      True -> Ok(utility.Pass)
      False -> {
        process.send(events, UtilForcedAttempt)
        Ok(utility.Pass)
      }
    }
  }
}

/// Like `passing_utility`, but the forced attempt produces a real title —
/// the converging session: pass once, then the forced instruction lands
/// the title.
fn pass_once_then_title_utility(
  events: process.Subject(UtilityEvent),
) -> session.UtilityRunner {
  fn(_endpoint, tr, _cancel, allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    case allow_pass {
      True -> Ok(utility.Pass)
      False -> {
        process.send(events, UtilForcedAttempt)
        Ok(utility.Title("Model Title"))
      }
    }
  }
}

/// A runner that blocks until its cancel subject fires (a `Send` racing
/// the side call) or the test releases it. A CANCELLED attempt stays held
/// on its `resume` subject: the test observes the racing turn's TurnDone
/// FIRST and only then lets the attempt report, so `UtilityDone` is
/// processed strictly after the turn's commit — the arm-while-unreported
/// order the re-arm rule must survive, deterministically rather than by
/// sleep racing. Each attempt hands its own subjects over via `ready`
/// (subjects are receivable only by their owner, so the worker mints
/// them).
fn blocking_utility(
  events: process.Subject(UtilityEvent),
  ready: process.Subject(AttemptHandles),
) -> session.UtilityRunner {
  fn(_endpoint, tr, cancel, _allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    let handles =
      AttemptHandles(
        release: process.new_subject(),
        resume: process.new_subject(),
      )
    process.send(ready, handles)
    let selector =
      process.new_selector()
      |> process.select_map(cancel, fn(_) { UtilCancelled })
      |> process.select_map(handles.release, fn(_) { UtilReleased })
    case process.selector_receive(selector, 5000) {
      Ok(UtilCancelled) -> {
        process.send(events, UtilCancelled)
        let assert Ok(Nil) = process.receive(handles.resume, 5000)
        Error("cancelled mid-flight")
      }
      Ok(UtilReleased) -> {
        process.send(events, UtilReleased)
        Ok(utility.Title("Model Title"))
      }
      // UtilCalled never rides this selector, but the event type is
      // shared with the test's recording subject — cover it.
      Ok(_) -> Error("unexpected event on the utility selector")
      Error(_) -> Error("utility runner timed out")
    }
  }
}

/// The registry guard APPLIED the title: records the call and carries the
/// fresh display metadata the MetaUpdated broadcast must use.
fn ok_apply(
  events: process.Subject(UtilityEvent),
  title: String,
) -> session.UtilityApply {
  fn(t) {
    process.send(events, UtilAppliedNote(t))
    case t == title {
      True -> Ok(session.UtilityMeta(title, ["auto-tag"]))
      False -> Ok(session.UtilityMeta(t, []))
    }
  }
}

/// The registry guard REFUSED (a manual rename wins forever) — but the
/// call itself is recorded, so the test can tell a refusal from a guard
/// that was never reached.
fn refusing_apply(
  events: process.Subject(UtilityEvent),
) -> session.UtilityApply {
  fn(t) {
    process.send(events, UtilRefusedNote(t))
    Error(Nil)
  }
}

fn start_with_utility(
  cfg: config.Config,
  runner: session.TurnRunner,
  u_runner: session.UtilityRunner,
  u_apply: session.UtilityApply,
) -> process.Subject(session.Msg) {
  let assert Ok(started) =
    session.start_with_spec(session.SessionSpec(
      cfg: cfg,
      model: "test-alias",
      endpoint: test_endpoint(),
      runner: runner,
      commit_hook: fn(_) { Nil },
      hydrate: None,
      utility_runner: u_runner,
      utility_apply: u_apply,
    ))
  started.data
}

/// Fires ONCE, after the FIRST COMMITTED exchange: the runner receives
/// the 3-message snapshot (system + user + assistant), the applied title
/// broadcasts MetaUpdated, and the second exchange never re-arms. The
/// branch (Y and the reply) never enters the session's transcript.
pub fn utility_fires_once_after_first_exchange_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      ok_utility(events, "Model Title"),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // The branch forked off the COMMITTED exchange: a 3-message snapshot —
  // the transcript as of the turn commit, never the in-flight state.
  UtilCalled(3) |> should.equal(expect_utility(events))
  // The worker applied the title through the guard, and the actor
  // broadcast the fresh metadata to subscribers.
  UtilAppliedNote("Model Title") |> should.equal(expect_utility(events))
  expect_event(sub)
  |> should.equal(session.MetaUpdated(Some("Model Title"), ["auto-tag"]))

  // The second exchange does not re-arm: once per session.
  should.equal(session.send_message(sess, "second"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // The throwaway branch is structurally unable to change a request
  // byte: Y never entered the session's transcript.
  let tr = session.snapshot(sess)
  transcript.length(tr) |> should.equal(5)
  let opts = transcript.Options(..transcript.default_options(), stream: True)
  should.be_false(string.contains(
    transcript.request_body(tr, opts),
    utility.instruction(True),
  ))
}

/// A greeting-session model that PASSes: the pass does NOT consume the
/// once-per-session attempt (no apply, no MetaUpdated), the next
/// turn-commit point re-arms, and the re-armed attempt arrives FORCED
/// (`allow_pass = False`) — its title applies, and only then is the flag
/// spent: the third exchange never re-arms.
pub fn utility_pass_postpones_once_then_forced_title_applies_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      pass_once_then_title_utility(events),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "hi"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  // The pass: no apply attempt, no sidebar refresh, flag untouched.
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // The second exchange re-arms the attempt — FORCED this time — and its
  // title applies.
  should.equal(session.send_message(sess, "a real question"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(5) |> should.equal(expect_utility(events))
  UtilForcedAttempt |> should.equal(expect_utility(events))
  UtilAppliedNote("Model Title") |> should.equal(expect_utility(events))
  expect_event(sub)
  |> should.equal(session.MetaUpdated(Some("Model Title"), ["auto-tag"]))

  // The forced attempt COMPLETED: the once-flag is spent now.
  should.equal(session.send_message(sess, "third"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

/// A model that PASSes even under the forced instruction: that reply is
/// an unusable title, not a postpone — it consumes the attempt like any
/// failure, so the session converges (keeps its heuristic placeholder)
/// instead of re-arming forever.
pub fn utility_pass_on_forced_attempt_consumes_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      passing_utility(events),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "hi"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // Forced attempt: arrives with allow_pass = False, PASSes anyway, and
  // the once-flag is spent.
  should.equal(session.send_message(sess, "still here"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(5) |> should.equal(expect_utility(events))
  UtilForcedAttempt |> should.equal(expect_utility(events))
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // No third attempt, ever.
  should.equal(session.send_message(sess, "third"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

/// A FAILED turn commits nothing — the trigger never arms for it.
pub fn utility_not_fired_on_failed_turn_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      failing_runner,
      ok_utility(events, "Model Title"),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "will fail"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

/// A utility side call in flight is invisible to callers: the session is
/// never Busy because of it (fairness on serialized backends), a `Send`
/// cancels it instead, and the cancelled attempt does NOT consume the
/// once-per-session flag — the debounce re-arms at the next commit point
/// and the title still lands.
pub fn utility_cancels_on_send_and_rearms_test() {
  let events = process.new_subject()
  let ready = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      blocking_utility(events, ready),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  // Each attempt hands over its own handle pair (owner = the worker).
  // Consume the first attempt's here: it is about to be cancelled.
  let assert Ok(cancelled_handles) = process.receive(ready, 2000)

  // The side call runs BESIDE the turn machinery: not streaming, not busy.
  session.describe(sess).streaming |> should.be_false
  should.equal(session.send_message(sess, "second"), session.Sent)

  // The in-flight attempt was cancelled by the send…
  UtilCancelled |> should.equal(expect_utility(events))
  // …whose commits then land — TurnDone observed, so the actor's
  // commit-point arm has run while the attempt is still unreported…
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  // …and ONLY NOW does the held attempt report its cancellation: the
  // arm-while-unreported order is deterministic. The once-flag is intact:
  // the owed trigger is delivered and the session's ONLY attempt runs
  // again.
  process.send(cancelled_handles.resume, Nil)
  UtilCalled(5)
  |> should.equal(expect_utility_step(events, "re-armed second attempt"))

  // This attempt completes: applied → broadcast, and the attempt is spent.
  let assert Ok(release) = process.receive(ready, 2000)
  process.send(release.release, Nil)
  UtilReleased
  |> should.equal(expect_utility_step(events, "released"))
  UtilAppliedNote("Model Title")
  |> should.equal(expect_utility_step(events, "applied"))
  expect_event(sub)
  |> should.equal(session.MetaUpdated(Some("Model Title"), ["auto-tag"]))
  expect_no_utility(events, 400)
}

/// MetaUpdated is broadcast ONLY when the registry guard applied — a
/// refused upgrade (a manual rename wins forever) keeps every subscriber
/// silent.
pub fn utility_no_broadcast_when_guard_refuses_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      ok_utility(events, "Model Title"),
      refusing_apply(events),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // The runner produced a title, the guard reached and refused it — and
  // nothing was broadcast. The apply seam's call is asserted explicitly:
  // a silent guard would otherwise be indistinguishable from a skipped
  // one.
  UtilCalled(3) |> should.equal(expect_utility(events))
  UtilRefusedNote("Model Title")
  |> should.equal(expect_utility_step(events, "guard reached and refused"))
  expect_no_event(sub, 400)
  // The attempt completed on its own (not cancelled), so it is spent.
  expect_no_utility(events, 400)
}

/// A FAILED follow-up turn must not strand the session's only attempt:
/// the turn commits nothing, so its commit point delivers no trigger —
/// the cancelled in-flight attempt's completion records the trigger as
/// owed and re-arms, and the title still lands.
pub fn utility_rearms_when_followup_turn_fails_test() {
  let events = process.new_subject()
  let ready = process.new_subject()
  // The first turn succeeds, later turns fail (the existing flaky runner,
  // serialised through its counter).
  let counter = start_counter()
  let sess =
    start_with_utility(
      utility_config(20),
      flaky_runner(counter),
      blocking_utility(events, ready),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  let assert Ok(handles) = process.receive(ready, 2000)

  // The follow-up send cancels the side call and its turn then FAILS
  // (flaky's failing turn streams two tokens before erroring).
  should.equal(session.send_message(sess, "second"), session.Sent)
  UtilCancelled |> should.equal(expect_utility(events))
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let assert session.TurnFailed(_) = expect_event(sub)

  // Nothing has re-armed yet — a failed turn commits nothing. The held
  // attempt now reports its cancellation: its completion records the
  // trigger as owed and delivers it. (The re-armed snapshot carries the
  // kept user message: sys + first exchange + the failed turn's user
  // line = 4 messages.)
  process.send(handles.resume, Nil)
  UtilCalled(4)
  |> should.equal(expect_utility_step(events, "re-armed after failed turn"))

  // The retried attempt completes: applied → broadcast, attempt spent.
  let assert Ok(release) = process.receive(ready, 2000)
  process.send(release.release, Nil)
  UtilReleased
  |> should.equal(expect_utility_step(events, "released"))
  UtilAppliedNote("Model Title")
  |> should.equal(expect_utility_step(events, "applied"))
  expect_event(sub)
  |> should.equal(session.MetaUpdated(Some("Model Title"), ["auto-tag"]))
  expect_no_utility(events, 400)
}

/// `NEXUS_UTILITY_ENABLED=false` disables the side call entirely.
pub fn utility_disabled_never_runs_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      config.Config(..test_config(), utility_enabled: False),
      happy_runner,
      ok_utility(events, "Model Title"),
      ok_apply(events, "Model Title"),
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(session.send_message(sess, "first"), session.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}
