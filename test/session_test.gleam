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

fn start_with(runner: session.TurnRunner) -> process.Subject(session.Msg) {
  let assert Ok(started) =
    session.start_with_spec(session.SessionSpec(
      cfg: test_config(),
      model: "test-alias",
      endpoint: test_endpoint(),
      runner: runner,
      commit_hook: fn(_) { Nil },
      hydrate: None,
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
