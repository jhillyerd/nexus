//// Offline tests for the M1 thread actor protocol, using scripted fake
//// turn runners — no network, no Bifrost.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit/should
import nexus/config
import nexus/log
import nexus/loop
import nexus/openai
import nexus/thread
import nexus/timing
import nexus/tool_provider
import nexus/tools
import nexus/transcript
import nexus/utility

/// Every thread actor in this file starts with this id; `scoped` stamps
/// it onto expected events (each fan-out delivery carries the emitting
/// thread's id — see `thread.ThreadEvent`).
const test_thread_id = "s-test"

/// Wrap an expected payload in the delivered envelope (first visit).
fn scoped(kind: thread.EventKind) -> thread.ThreadEvent {
  scoped_at(1, kind)
}

/// Same, with an explicit visit generation.
fn scoped_at(visit: Int, kind: thread.EventKind) -> thread.ThreadEvent {
  thread.ThreadEvent(test_thread_id, visit, kind)
}

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
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_cache_ttl_ms: 600_000,
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
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    workspace_sandbox: config.SandboxNone,
    workspace_sandbox_bin: None,
    workspace_toolchain: None,
    workspace_state_dir: None,
    workspace_max_memory_mb: 1024,
    workspace_max_pids: 64,
    env_timeout_ms: 60_000,
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    // Bots P3c: the delivery hop guard; 4 = the shipped default.
    max_bot_hops: 4,
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
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("Hello")))
  on_event(loop.StreamEvent(openai.TokenDelta(" world")))
  // Stamped like the real loop stamps every append, so the turn's
  // terminal event and its replay carry the thread's committed stamp.
  thread.StreamDone(
    stats(),
    transcript.append_assistant(tr, "Hello world")
      |> transcript.stamp(timing.wall_now_s()),
  )
}

/// Emits one token, then blocks until cancelled (Stop) or times out.
fn blocking_runner(
  _endpoint,
  tr,
  cancel: process.Subject(Nil),
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("partial")))
  let selector = process.new_selector() |> process.select(cancel)
  case process.selector_receive(selector, 5000) {
    Ok(_) ->
      thread.StreamStopped(
        transcript.append_assistant(tr, "partial")
        |> transcript.stamp(timing.wall_now_s()),
      )
    Error(_) -> thread.StreamErrored("timeout")
  }
}

/// Emits two deltas separated by a delay, making a TTFT regression visible.
fn delayed_runner(
  _endpoint,
  tr,
  _cancel,
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("first")))
  process.sleep(60)
  on_event(loop.StreamEvent(openai.TokenDelta("second")))
  thread.StreamDone(
    stats(),
    transcript.append_assistant(tr, "firstsecond")
      |> transcript.stamp(timing.wall_now_s()),
  )
}

/// Emits a token then fails: nothing may be committed.
fn failing_runner(
  _endpoint,
  _tr,
  _cancel,
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("never committed")))
  thread.StreamErrored("non200")
}

/// Kills its own (worker) process: the monitor path must convert this into
/// a TurnFailed without hurting the thread actor.
fn crashing_runner(
  _endpoint,
  _tr,
  _cancel,
  _delivery,
  _environment,
  _on_event,
) -> thread.TurnOutcome {
  process.kill(process.self())
  thread.StreamErrored("unreachable")
}

/// Streams one token (so the turn reaches `Streaming`), then parks on a
/// gate, then — on gate release — KILLS its own worker process, driving
/// the `WorkerDown` path (not `WorkerDone`). The gate lets a test queue a
/// roster change while the worker is truly mid-turn before it dies.
fn crash_after_gate_runner(
  gate_request: process.Subject(process.Subject(Nil)),
) -> thread.TurnRunner {
  fn(_endpoint, _tr, _cancel, _delivery, _environment, on_event) {
    on_event(loop.StreamEvent(openai.TokenDelta("partial")))
    let gate = process.new_subject()
    process.send(gate_request, gate)
    let _ = process.receive(gate, 5000)
    process.kill(process.self())
    thread.StreamErrored("unreachable")
  }
}

type CounterMsg {
  Ping(reply: process.Subject(Int))
}

/// A tiny turn counter: the flaky runner below needs to know which turn it
/// is on, and the thread actor serialises turns, so the count is exact.
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

/// First turn streams normally, later turns fail: thread A gets two metric
/// samples while committing the same history as a single-turn thread.
fn flaky_runner(counter: process.Subject(CounterMsg)) -> thread.TurnRunner {
  fn(
    _endpoint,
    tr,
    _cancel,
    _delivery,
    _environment,
    on_event: fn(loop.LoopEvent) -> Nil,
  ) {
    let turn = process.call(counter, 1000, fn(reply) { Ping(reply) })
    on_event(loop.StreamEvent(openai.TokenDelta("Hello")))
    on_event(loop.StreamEvent(openai.TokenDelta(" world")))
    case turn {
      1 ->
        thread.StreamDone(
          stats(),
          transcript.append_assistant(tr, "Hello world")
            |> transcript.stamp(timing.wall_now_s()),
        )
      _ -> thread.StreamErrored("later turn failed")
    }
  }
}

fn expect_hello(
  sub: process.Subject(thread.ThreadEvent),
  model: String,
  messages: Int,
) -> thread.ThreadEvent {
  let event = expect_event(sub)
  case event {
    thread.ThreadEvent(_, 1, thread.Hello(model: m, messages: n, metrics: _))
      if m == model && n == messages
    -> event
    _ -> panic as "expected hello"
  }
}

/// The sample a `happy_runner` turn must leave behind. Timings are measured
/// from the actor's monotonic clock, so only the shape is asserted here.
fn is_completed(sample: thread.MetricSample) -> Bool {
  sample.outcome == thread.Completed
  && sample.token_deltas == 2
  && sample.duration_ms >= 0
  && sample.stopped_chars == None
  && sample.failure_reason == None
}

fn expect_event(
  sub: process.Subject(thread.ThreadEvent),
) -> thread.ThreadEvent {
  let assert Ok(event) = process.receive(sub, 2000)
  event
}

/// `expect_event |> should.equal(scoped_at(visit, UserEcho(text)))` for
/// events whose display stamp is the wall clock (unpredictable in
/// tests): assert the envelope's filter keys and the text, require the
/// stamp to be present (every live echo and replay is stamped), and
/// RETURN it so callers can verify the feature's contract — the same
/// message carries the same stamp live and on replay.
fn expect_user_echo_at(
  sub: process.Subject(thread.ThreadEvent),
  visit: Int,
  text: String,
) -> Int {
  let assert thread.ThreadEvent(
    sid,
    v,
    thread.UserEcho(actual, Some(stamp), author),
  ) = expect_event(sub)
  sid |> should.equal(test_thread_id)
  v |> should.equal(visit)
  actual |> should.equal(text)
  // Human sends (the only shape this helper drives) carry no provenance;
  // authored sends are pinned by the bots P3b tests.
  author |> should.equal(None)
  stamp
}

/// The first-visit shorthand — the overwhelmingly common shape.
fn expect_user_echo(
  sub: process.Subject(thread.ThreadEvent),
  text: String,
) -> Int {
  expect_user_echo_at(sub, 1, text)
}

/// The AssistantFull twin of `expect_user_echo_at`.
fn expect_assistant_full_at(
  sub: process.Subject(thread.ThreadEvent),
  visit: Int,
  text: String,
) -> Int {
  let assert thread.ThreadEvent(
    sid,
    v,
    thread.AssistantFull(actual, Some(stamp)),
  ) = expect_event(sub)
  sid |> should.equal(test_thread_id)
  v |> should.equal(visit)
  actual |> should.equal(text)
  stamp
}

/// The first-visit shorthand.
fn expect_assistant_full(
  sub: process.Subject(thread.ThreadEvent),
  text: String,
) -> Int {
  expect_assistant_full_at(sub, 1, text)
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

fn no_utility_apply(
  _title: String,
  _tags: List(String),
) -> Result(thread.UtilityMeta, Nil) {
  Error(Nil)
}

/// Wrap fake turn + utility runners in the toolset bundle ThreadSpec now
/// carries (#76): the default specs of the test config, named by their
/// own wire names. One value, so a thread's turn and utility branches
/// demonstrably ride one toolset.
fn toolset(
  runner: thread.TurnRunner,
  utility_runner: thread.UtilityRunner,
) -> thread.Toolset {
  let specs = tools.default(test_config())
  thread.Toolset(
    names: list.map(specs, tools.tool_name),
    specs: specs,
    runner: runner,
    utility_runner: utility_runner,
  )
}

fn start_with(runner: thread.TurnRunner) -> process.Subject(thread.Msg) {
  let assert Ok(started) =
    thread.start_with_spec(thread.ThreadSpec(
      id: test_thread_id,
      cfg: test_config(),
      endpoint: test_endpoint(),
      toolset: toolset(runner, no_utility_runner),
      commit_hook: fn(_) { Nil },
      // The registry normally builds this; tests build it directly
      // through the same one construction path.
      transcript: transcript.new("test-alias", ""),
      hydrated: False,
      roster: [],
      utility_apply: no_utility_apply,
      parent_thread_id: None,
      archived: False,
    ))
  started.data
}

/// A thread whose FROZEN toolset names an env tool — so the actor seeds
/// its roster `["workspace"]` (environments plan Phase 2a). The runner
/// is intentionally fake: roster tests never run a turn, and the specs
/// are irrelevant to the seeding (only `names` drives it).
fn start_with_env(runner: thread.TurnRunner) -> process.Subject(thread.Msg) {
  let base = toolset(runner, no_utility_runner)
  let env_toolset = thread.Toolset(..base, names: ["bash"])
  let assert Ok(started) =
    thread.start_with_spec(thread.ThreadSpec(
      id: test_thread_id,
      cfg: test_config(),
      endpoint: test_endpoint(),
      toolset: env_toolset,
      commit_hook: fn(_) { Nil },
      transcript: transcript.new("test-alias", ""),
      hydrated: False,
      roster: ["workspace"],
      utility_apply: no_utility_apply,
      parent_thread_id: None,
      archived: False,
    ))
  started.data
}

fn join(
  sess: process.Subject(thread.Msg),
) -> process.Subject(thread.ThreadEvent) {
  let sub = process.new_subject()
  process.send(sess, thread.Join(sub, 1))
  sub
}

/// Re-subscribe an EXISTING subject with a new visit generation (the
/// rapid A→B→A shape): later deliveries to `sub` carry generation 2.
fn rejoin(
  sess: process.Subject(thread.Msg),
  sub: process.Subject(thread.ThreadEvent),
) -> Nil {
  process.send(sess, thread.Join(sub, 2))
}

pub fn join_replays_history_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  expect_event(sub) |> should.equal(scoped(thread.Hello("test-alias", 1, [])))
  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  let live_stamp = expect_user_echo(sub, "hi")
  expect_event(sub) |> should.equal(scoped(thread.Token("Hello")))
  expect_event(sub) |> should.equal(scoped(thread.Token(" world")))
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(stats, Some(turn_stamp))) =
    expect_event(sub)
  stats.token_deltas |> should.equal(2)

  // A second subscriber joins after the turn: it gets Hello + replay.
  let sub2 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(model:, messages:, metrics:)) =
    expect_event(sub2)
  model |> should.equal("test-alias")
  messages |> should.equal(3)
  // Reconnect replays the turn's metric sample (M2 §4.2).
  metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(metrics)
  should.be_true(is_completed(sample))
  // The timestamp contract: replayed events carry the SAME stamps the
  // live echo/turn committed — one clock (the transcript sidecar), so a
  // reload renders identical ages. (The reply's stamp is TurnDone's, not
  // the echo's: different messages, different instants.)
  expect_user_echo_at(sub2, 1, "hi") |> should.equal(live_stamp)
  expect_assistant_full(sub2, "Hello world") |> should.equal(turn_stamp)
}

pub fn completed_turn_appends_and_is_byte_stable_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "question"), thread.Sent)
  expect_user_echo(sub, "question")
  expect_event(sub) |> should.equal(scoped(thread.Token("Hello")))
  expect_event(sub) |> should.equal(scoped(thread.Token(" world")))
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  let tr = thread.snapshot(sess)
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
  // The worker emits its token before blocking; wait for it.
  expect_user_echo(sub, "first")
  expect_event(sub) |> should.equal(scoped(thread.Token("partial")))

  // Turn in flight: second send is rejected.
  should.equal(thread.send_message(sess, "second"), thread.Busy)
  thread.stop(sess)
  let _ = expect_event(sub)
}

pub fn stop_cancels_and_commits_partial_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "stop me"), thread.Sent)
  expect_user_echo(sub, "stop me")
  expect_event(sub) |> should.equal(scoped(thread.Token("partial")))

  thread.stop(sess)
  // The stop commits the partial text, so the terminal event carries the
  // thread's committed stamp (the loop stamps every append).
  let assert thread.ThreadEvent(sid, 1, thread.TurnStopped(7, Some(_))) =
    expect_event(sub)
  sid |> should.equal(test_thread_id)

  // Partial text was committed as the assistant turn.
  transcript.length(thread.snapshot(sess)) |> should.equal(3)

  // Thread accepts a new turn after the stop.
  should.equal(thread.send_message(sess, "again"), thread.Sent)
  expect_user_echo(sub, "again")
  expect_event(sub) |> should.equal(scoped(thread.Token("partial")))
  thread.stop(sess)
  let _ = expect_event(sub)
}

pub fn failed_turn_commits_nothing_test() {
  let sess = start_with(failing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "will fail"), thread.Sent)
  expect_user_echo(sub, "will fail")
  expect_event(sub) |> should.equal(scoped(thread.Token("never committed")))
  let assert thread.ThreadEvent(_, 1, thread.TurnFailed(reason, _)) =
    expect_event(sub)
  should.be_true(string.contains(reason, "non200"))

  // System + user only: no assistant message, so a retry resends a
  // byte-identical prefix (cache-friendly).
  transcript.length(thread.snapshot(sess)) |> should.equal(2)

  // And the thread is usable again afterwards.
  should.equal(thread.send_message(sess, "retry"), thread.Sent)
  expect_user_echo(sub, "retry")
  expect_event(sub) |> should.equal(scoped(thread.Token("never committed")))
  let _ = expect_event(sub)
}

pub fn crashing_worker_does_not_kill_thread_test() {
  let sess = start_with(crashing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "boom"), thread.Sent)
  expect_user_echo(sub, "boom")
  let assert thread.ThreadEvent(_, 1, thread.TurnFailed(reason, _)) =
    expect_event(sub)
  should.be_true(string.contains(reason, "worker"))

  // The actor survived and accepts another turn.
  should.equal(thread.send_message(sess, "still alive"), thread.Sent)
}

/// Live-streaming threads stay single-turn even when the subscriber list
/// keeps growing: two subscribers both see every event.
pub fn fan_out_to_all_subscribers_test() {
  let sess = start_with(happy_runner)
  let sub1 = join(sess)
  let _ = expect_event(sub1)
  let sub2 = join(sess)
  let _ = expect_event(sub2)

  should.equal(thread.send_message(sess, "both"), thread.Sent)
  list.each([sub1, sub2], fn(sub) {
    expect_user_echo(sub, "both")
    expect_event(sub) |> should.equal(scoped(thread.Token("Hello")))
    expect_event(sub) |> should.equal(scoped(thread.Token(" world")))
  })
}

/// A subscriber that moved on must stop receiving events. The UI keeps
/// ONE subscription subject per connection and re-Joins it on every
/// thread switch (`nexus/ui.join_effect`), so the switch Leaves the old
/// thread — without the removal the old thread's stream kept fanning
/// out to the shared subject (the cross-thread contamination bug).
/// Delivery correctness beyond Leave is the id filter (`ThreadEvent`),
/// pinned by the UI tests; this pins the actor-side unsubscribe.
pub fn leave_stops_fan_out_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  // Leave, then run a whole turn; a fresh subscriber witnesses its
  // completion so the negative assertion below is a verdict, not a race.
  process.send(sess, thread.Leave(sub))
  let witness = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(witness)

  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  expect_user_echo(witness, "hi")
  expect_event(witness) |> should.equal(scoped(thread.Token("Hello")))
  expect_event(witness) |> should.equal(scoped(thread.Token(" world")))
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) =
    expect_event(witness)

  // The departed subscriber saw none of it.
  let assert Error(_) = process.receive(sub, 100)
}

/// Leave is not sticky: re-Joining the same subject subscribes it again
/// (fresh view of the same thread on the same connection). Guards a
/// naive "ignore subjects we have seen" Join dedupe regression.
pub fn rejoin_after_leave_resubscribes_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  process.send(sess, thread.Leave(sub))
  rejoin(sess, sub)
  // The refreshed generation rides the replay AND every later delivery:
  // a subscriber that filters on the old generation drops the whole
  // first-visit era.
  expect_event(sub)
  |> should.equal(scoped_at(2, thread.Hello("test-alias", 1, [])))

  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  expect_user_echo_at(sub, 2, "hi")
  expect_event(sub) |> should.equal(scoped_at(2, thread.Token("Hello")))
  expect_event(sub) |> should.equal(scoped_at(2, thread.Token(" world")))
  let assert thread.ThreadEvent(_, 2, thread.TurnDone(_, _)) = expect_event(sub)
}

// ---------------------------------------------------------------------------
// M2: model pinning, metrics, and describe
// ---------------------------------------------------------------------------

/// Step 1 (plan §7): the constructor takes the selected alias through the
/// spec; there is no config default to fall back to after the P3 hard cut.
pub fn selected_alias_is_frozen_test() {
  let spec =
    thread.ThreadSpec(
      id: test_thread_id,
      cfg: test_config(),
      endpoint: test_endpoint(),
      toolset: toolset(happy_runner, no_utility_runner),
      commit_hook: fn(_) { Nil },
      transcript: transcript.new("chosen-alias", ""),
      hydrated: False,
      roster: [],
      utility_apply: no_utility_apply,
      parent_thread_id: None,
      archived: False,
    )
  let assert Ok(started) = thread.start_with_spec(spec)
  let sess = started.data
  let sub = join(sess)
  expect_hello(sub, "chosen-alias", 1)

  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // The transcript carries the selected alias, never anything else —
  // there is no config default to fall back to after the P3 hard cut.
  let tr = thread.snapshot(sess)
  transcript.model(tr) |> should.equal("chosen-alias")
}

/// P3 (multi-provider §8): the thread hands its runner the FROZEN
/// endpoint from the spec — one provider per thread, for every turn of
/// its lifetime. A swapped-in different endpoint must never reach an
/// existing thread's runner.
pub fn runner_receives_frozen_endpoint_test() {
  let seen = process.new_subject()
  let capturing = fn(endpoint, tr, _cancel, _delivery, _environment, _on_event) {
    process.send(seen, endpoint)
    thread.StreamDone(
      stats(),
      transcript.append_assistant(tr, "ok")
        |> transcript.stamp(timing.wall_now_s()),
    )
  }
  let spec =
    thread.ThreadSpec(
      id: test_thread_id,
      cfg: test_config(),
      endpoint: test_endpoint(),
      toolset: toolset(capturing, no_utility_runner),
      commit_hook: fn(_) { Nil },
      transcript: transcript.new("test-alias", ""),
      hydrated: False,
      roster: [],
      utility_apply: no_utility_apply,
      parent_thread_id: None,
      archived: False,
    )
  let assert Ok(started) = thread.start_with_spec(spec)
  let sess = started.data
  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  let assert Ok(endpoint) = process.receive(seen, 2000)
  endpoint |> should.equal(test_endpoint())
}

/// A completed turn leaves exactly one `Completed` sample.
pub fn completed_turn_records_metric_test() {
  let sess = start_with(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "go"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  let status = thread.describe(sess)
  status.streaming |> should.be_false
  status.message_count |> should.equal(3)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(thread.Completed)
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

  should.equal(thread.send_message(sess, "slow second token"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  let status = thread.describe(sess)
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

  should.equal(thread.send_message(sess, "stop me"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  thread.stop(sess)
  // The stop commits the partial text, so the terminal event carries the
  // thread's committed stamp (the loop stamps every append).
  let assert thread.ThreadEvent(sid, 1, thread.TurnStopped(7, Some(_))) =
    expect_event(sub)
  sid |> should.equal(test_thread_id)

  let status = thread.describe(sess)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(thread.Stopped)
  sample.stopped_chars |> should.equal(Some(7))
  sample.failure_reason |> should.equal(None)
}

/// A failed turn records the reason and commits nothing.
pub fn failed_turn_records_metric_test() {
  let sess = start_with(failing_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "will fail"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  let status = thread.describe(sess)
  status.metrics |> list.length |> should.equal(1)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(thread.Failed)
  case sample.failure_reason {
    Some(reason) -> should.be_true(string.contains(reason, "non200"))
    None -> panic as "expected a failure reason"
  }
  // Nothing was committed: system + user only.
  status.message_count |> should.equal(2)
}

/// Metrics are display state only: two threads carrying different numbers
/// of metric samples must still produce byte-identical request bodies for
/// the same committed history (KV-cache contract rule 4).
pub fn metrics_do_not_affect_request_bytes_test() {
  // Thread A records a Completed *and* a Failed sample; the failed turn
  // commits nothing, so A's committed history equals thread B's.
  let counter = start_counter()
  let a = start_with(flaky_runner(counter))
  let sub_a = join(a)
  let _ = expect_event(sub_a)
  should.equal(thread.send_message(a, "same"), thread.Sent)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  // Snapshot after the successful turn: this is the history both threads
  // end up with.
  let tr_a = thread.snapshot(a)

  should.equal(thread.send_message(a, "boom"), thread.Sent)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)
  let _ = expect_event(sub_a)

  let b = start_with(happy_runner)
  let sub_b = join(b)
  let _ = expect_event(sub_b)
  should.equal(thread.send_message(b, "same"), thread.Sent)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)
  let _ = expect_event(sub_b)

  thread.describe(a).metrics |> list.length |> should.equal(2)
  thread.describe(b).metrics |> list.length |> should.equal(1)
  tr_a
  |> transcript.length
  |> should.equal(thread.snapshot(b) |> transcript.length)

  // Two threads with different metric histories encode identically.
  let opts = transcript.Options(..transcript.default_options(), stream: True)
  transcript.request_body(tr_a, opts)
  |> should.equal(transcript.request_body(thread.snapshot(b), opts))
}

/// `Describe` reports `streaming` while a turn is in flight.
pub fn describe_reports_streaming_test() {
  let sess = start_with(blocking_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(thread.send_message(sess, "slow"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  thread.describe(sess).streaming |> should.be_true
  thread.stop(sess)
  let _ = expect_event(sub)
  thread.describe(sess).streaming |> should.be_false
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
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
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
    None,
  ))
  on_event(loop.ToolResultEvent(
    "call_1",
    "http_fetch",
    True,
    "{\"status\":200}",
  ))
  on_event(loop.StreamEvent(openai.TokenDelta("based on the fetch: fine")))
  thread.StreamDone(
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
        ok: True,
      )
      |> transcript.append_assistant("based on the fetch: fine")
      |> transcript.stamp(timing.wall_now_s()),
  )
}

pub fn tool_events_are_broadcast_test() {
  let sess = start_with(tool_round_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "fetch it"), thread.Sent)
  expect_user_echo(sub, "fetch it")
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(1, 8, "request")))
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolCallDelta(
      0,
      Some("call_1"),
      Some("http_fetch"),
      "{\"url\":\"https://example.invalid/\"}",
    )),
  )
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(1, 8, "tools")))
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_1",
      "http_fetch",
      "{\"url\":\"https://example.invalid/\"}",
      None,
    )),
  )
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolResult("call_1", "http_fetch", True, "{\"status\":200}")),
  )
  expect_event(sub)
  |> should.equal(scoped(thread.Token("based on the fetch: fine")))
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  // The full tool history is committed: system, user, assistant(call),
  // tool result, assistant text.
  transcript.length(thread.snapshot(sess)) |> should.equal(5)
}

pub fn failed_tool_result_replays_as_failed_test() {
  // A reload must not launder a failed tool call into green: the outcome
  // rides the transcript's display-only sidecar, so the replayed
  // ToolResult carries the same ok the live event did.
  let sess =
    start_with(fn(_endpoint, tr, _cancel, _delivery, _environment, on_event) {
      on_event(loop.LoopStatus(1, 8, "tools"))
      on_event(loop.ToolCallAssembled("call_9", "http_fetch", "{}", None))
      on_event(loop.ToolResultEvent(
        "call_9",
        "http_fetch",
        False,
        "{\"error\":\"ssrf guard\"}",
      ))
      thread.StreamDone(
        stats(),
        tr
          |> transcript.append_assistant_tool_calls(
            text: None,
            calls: [#("call_9", "http_fetch", "{}")],
            reasoning: None,
          )
          |> transcript.append_tool_result(
            tool_call_id: "call_9",
            content: "{\"error\":\"ssrf guard\"}",
            ok: False,
          )
          |> transcript.append_assistant("the fetch failed")
          |> transcript.stamp(timing.wall_now_s()),
      )
    })
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(thread.send_message(sess, "fetch it"), thread.Sent)
  // Live events (UserEcho, LoopStatus, ToolCallAssembled, ToolResult,
  // TurnDone) — the ToolResult carries ok=False exactly as the loop said.
  expect_user_echo(sub, "fetch it")
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(1, 8, "tools")))
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolCallAssembled("call_9", "http_fetch", "{}", None)),
  )
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolResult(
      "call_9",
      "http_fetch",
      False,
      "{\"error\":\"ssrf guard\"}",
    )),
  )
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  // A fresh subscriber (the reload path) sees the failure too.
  let sub2 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(sub2)
  expect_user_echo(sub2, "fetch it")
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolCallAssembled("call_9", "http_fetch", "{}", None)),
  )
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolResult(
      "call_9",
      "http_fetch",
      False,
      "{\"error\":\"ssrf guard\"}",
    )),
  )
  expect_assistant_full(sub2, "the fetch failed")
}

pub fn tool_history_replays_on_rejoin_test() {
  let sess = start_with(tool_round_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(thread.send_message(sess, "fetch it"), thread.Sent)
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
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, messages, _)) =
    expect_event(sub2)
  messages |> should.equal(5)
  expect_user_echo(sub2, "fetch it")
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_1",
      "http_fetch",
      "{\"url\":\"https://example.invalid/\"}",
      None,
    )),
  )
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolResult("call_1", "http_fetch", True, "{\"status\":200}")),
  )
  expect_assistant_full(sub2, "based on the fetch: fine")
}

fn guard_runner(
  _endpoint,
  tr,
  _cancel,
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.LoopStatus(4, 4, "guard"))
  thread.StreamGuard(4, tr)
}

/// Streams a full tool round (reasoning + text + two calls + results),
/// then the next iteration's first deltas, then freezes until the test
/// opens its gate — parking the turn mid-flight with finished rounds that
/// only exist in the worker. The gate subject is created INSIDE the worker
/// (subjects select from their owner's mailbox) and handed to the test
/// through a request subject the test owns.
fn gated_runner(
  gate_request: process.Subject(process.Subject(Nil)),
) -> thread.TurnRunner {
  fn(_endpoint, tr, _cancel, _delivery, _environment, on_event) {
    // A fixed flush stamp: the loop stamps the round at append time and
    // broadcasts the same value on every assembled event — the tests pin
    // it end to end (live echo, mirror replay, restamp).
    let flushed = 1_729_000_000
    on_event(loop.LoopStatus(1, 8, "request"))
    on_event(loop.StreamEvent(openai.ReasoningDelta("weighing ")))
    on_event(loop.StreamEvent(openai.ReasoningDelta("options")))
    on_event(loop.StreamEvent(openai.TokenDelta("\n\nLet me check.")))
    on_event(loop.LoopStatus(1, 8, "tools"))
    on_event(loop.ToolCallAssembled(
      "call_1",
      "http_fetch",
      "{\"url\":\"a\"}",
      Some(flushed),
    ))
    on_event(loop.ToolResultEvent("call_1", "http_fetch", True, "{\"ok\":true}"))
    on_event(loop.ToolCallAssembled(
      "call_2",
      "web_search",
      "{\"q\":\"x\"}",
      Some(flushed),
    ))
    on_event(loop.ToolResultEvent("call_2", "web_search", True, "{\"r\":1}"))
    on_event(loop.LoopStatus(2, 8, "request"))
    on_event(loop.StreamEvent(openai.ReasoningDelta("final thinking")))
    on_event(loop.StreamEvent(openai.TokenDelta("Final answer")))
    let gate = process.new_subject()
    process.send(gate_request, gate)
    let _ = process.receive(gate, 5000)
    thread.StreamDone(
      stats(),
      transcript.append_assistant(tr, "Final answer")
        |> transcript.stamp(timing.wall_now_s()),
    )
  }
}

pub fn midturn_rejoin_replays_in_flight_rounds_test() {
  // The reload/thread-switch regression: mid-turn, the thread actor's
  // committed transcript does not yet hold the running turn's rounds (the
  // worker installs them at WorkerDone), so a Join replayed nothing of the
  // turn — chips and reasoning vanished until it finished. The in-flight
  // display mirror must replay them instead.
  let gate_request = process.new_subject()
  let sess = start_with(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  // Drain the live events up to the freeze point.
  expect_user_echo(sub, "research it")
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(1, 8, "request")))
  expect_event(sub) |> should.equal(scoped(thread.Reasoning("weighing ")))
  expect_event(sub) |> should.equal(scoped(thread.Reasoning("options")))
  expect_event(sub) |> should.equal(scoped(thread.Token("\n\nLet me check.")))
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(1, 8, "tools")))
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_1",
      "http_fetch",
      "{\"url\":\"a\"}",
      Some(1_729_000_000),
    )),
  )
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolResult("call_1", "http_fetch", True, "{\"ok\":true}")),
  )
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_2",
      "web_search",
      "{\"q\":\"x\"}",
      Some(1_729_000_000),
    )),
  )
  expect_event(sub)
  |> should.equal(
    scoped(thread.ToolResult("call_2", "web_search", True, "{\"r\":1}")),
  )
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(2, 8, "request")))
  expect_event(sub) |> should.equal(scoped(thread.Reasoning("final thinking")))
  expect_event(sub) |> should.equal(scoped(thread.Token("Final answer")))

  // The worker is now parked mid-iteration-2. A fresh subscriber — the
  // reload path — replays the finished round from the mirror: reasoning
  // rides the text message, calls/results land in broadcast order.
  let sub2 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(sub2)
  expect_user_echo(sub2, "research it")
  expect_event(sub2)
  |> should.equal(scoped(thread.ReasoningFull("weighing options")))
  // The mirror round carries the worker's flush stamp: the replayed
  // text and assembled events pin it exactly.
  expect_assistant_full(sub2, "\n\nLet me check.")
  |> should.equal(1_729_000_000)
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_1",
      "http_fetch",
      "{\"url\":\"a\"}",
      Some(1_729_000_000),
    )),
  )
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolResult("call_1", "http_fetch", True, "{\"ok\":true}")),
  )
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolCallAssembled(
      "call_2",
      "web_search",
      "{\"q\":\"x\"}",
      Some(1_729_000_000),
    )),
  )
  expect_event(sub2)
  |> should.equal(
    scoped(thread.ToolResult("call_2", "web_search", True, "{\"r\":1}")),
  )

  // Iteration 2's still-streaming text/reasoning are NOT replayed: no
  // phase boundary has flushed them into the mirror. Release the gate;
  // the next thing either subscriber sees is the terminal event.
  let assert Ok(gate) = process.receive(gate_request, 2000)
  process.send(gate, Nil)
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) =
    expect_event(sub2)
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  // After the turn the mirror is gone: a post-turn join replays the
  // committed transcript only — no reasoning or tool residue from the
  // mirror (the fake runner commits a plain text reply).
  let sub3 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, messages, _)) =
    expect_event(sub3)
  messages |> should.equal(3)
  expect_user_echo(sub3, "research it")
  expect_assistant_full(sub3, "Final answer")
}

pub fn guard_hit_renders_terminal_failure_test() {
  let sess = start_with(guard_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "keep calling"), thread.Sent)
  let _ = expect_event(sub)
  expect_event(sub) |> should.equal(scoped(thread.LoopStatus(4, 4, "guard")))
  let assert thread.ThreadEvent(_, 1, thread.TurnFailed(reason, _)) =
    expect_event(sub)
  should.be_true(string.contains(reason, "iteration guard"))

  // The turn still commits its transcript (tool rounds happened), and the
  // guard is visible as a Failed metric sample.
  let status = thread.describe(sess)
  let assert Ok(sample) = list.first(status.metrics)
  sample.outcome |> should.equal(thread.Failed)
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
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.ReasoningDelta("pondering ")))
  on_event(loop.StreamEvent(openai.ReasoningDelta("deeply")))
  on_event(loop.StreamEvent(openai.TokenDelta("answer")))
  thread.StreamDone(
    stats(),
    transcript.append_assistant_with_reasoning(
      tr,
      "answer",
      Some("pondering deeply"),
    )
      |> transcript.stamp(timing.wall_now_s()),
  )
}

pub fn reasoning_streams_live_and_replays_on_rejoin_test() {
  let sess = start_with(reasoning_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(thread.send_message(sess, "think"), thread.Sent)
  expect_user_echo(sub, "think")
  expect_event(sub) |> should.equal(scoped(thread.Reasoning("pondering ")))
  expect_event(sub) |> should.equal(scoped(thread.Reasoning("deeply")))
  expect_event(sub) |> should.equal(scoped(thread.Token("answer")))
  let assert thread.ThreadEvent(_, 1, thread.TurnDone(_, _)) = expect_event(sub)

  // A fresh subscriber replays the committed reasoning just before the
  // assistant message it preceded.
  let sub2 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, 3, _)) =
    expect_event(sub2)
  expect_user_echo(sub2, "think")
  expect_event(sub2)
  |> should.equal(scoped(thread.ReasoningFull("pondering deeply")))
  expect_assistant_full(sub2, "answer")
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
  /// The apply seam was reached, and these are the PARSED tags the
  /// worker passed beside the title (utility-tags plan §3.7: the
  /// widened `Ok(utility.Title(...))` branch forwards both).
  UtilAppliedTags(tags: List(String))
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
/// trigger rules (failed turns, disabled config, once-per-thread).
fn expect_no_utility(events: process.Subject(UtilityEvent), ms: Int) -> Nil {
  let assert Error(_) = process.receive(events, ms)
  Nil
}

fn expect_no_event(sub: process.Subject(thread.ThreadEvent), ms: Int) -> Nil {
  let assert Error(_) = process.receive(sub, ms)
  Nil
}

/// The thread config with the side-call knob turned up for fast tests.
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
) -> thread.UtilityRunner {
  fn(_endpoint, tr, _cancel, _allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    Ok(utility.Title(title: title, tags: []))
  }
}

/// The greeting-thread model: it PASSes every attempt that offers the
/// sentinel. Paired with the apply seam it lets tests pin both halves of
/// the one-pass policy — the re-armed attempt must arrive forced
/// (`UtilForcedAttempt`), and a PASS under the forced instruction must
/// consume the attempt like any failure.
fn passing_utility(
  events: process.Subject(UtilityEvent),
) -> thread.UtilityRunner {
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
/// the converging thread: pass once, then the forced instruction lands
/// the title.
fn pass_once_then_title_utility(
  events: process.Subject(UtilityEvent),
) -> thread.UtilityRunner {
  fn(_endpoint, tr, _cancel, allow_pass) {
    process.send(events, UtilCalled(transcript.length(tr)))
    case allow_pass {
      True -> Ok(utility.Pass)
      False -> {
        process.send(events, UtilForcedAttempt)
        Ok(utility.Title(title: "Model Title", tags: []))
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
) -> thread.UtilityRunner {
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
        Ok(utility.Title(title: "Model Title", tags: []))
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
) -> thread.UtilityApply {
  fn(t, _tags) {
    process.send(events, UtilAppliedNote(t))
    case t == title {
      True -> Ok(thread.UtilityMeta(title, ["auto-tag"]))
      False -> Ok(thread.UtilityMeta(t, []))
    }
  }
}

/// The registry guard REFUSED (a manual rename wins forever) — but the
/// call itself is recorded, so the test can tell a refusal from a guard
/// that was never reached.
fn refusing_apply(
  events: process.Subject(UtilityEvent),
) -> thread.UtilityApply {
  fn(t, _tags) {
    process.send(events, UtilRefusedNote(t))
    Error(Nil)
  }
}

fn start_with_utility(
  cfg: config.Config,
  runner: thread.TurnRunner,
  u_runner: thread.UtilityRunner,
  u_apply: thread.UtilityApply,
) -> process.Subject(thread.Msg) {
  let assert Ok(started) =
    thread.start_with_spec(thread.ThreadSpec(
      id: test_thread_id,
      cfg: cfg,
      endpoint: test_endpoint(),
      toolset: toolset(runner, u_runner),
      commit_hook: fn(_) { Nil },
      transcript: transcript.new("test-alias", ""),
      hydrated: False,
      roster: [],
      utility_apply: u_apply,
      parent_thread_id: None,
      archived: False,
    ))
  started.data
}

/// Fires ONCE, after the FIRST COMMITTED exchange: the runner receives
/// the 3-message snapshot (system + user + assistant), the applied title
/// broadcasts MetaUpdated, and the second exchange never re-arms. The
/// branch (Y and the reply) never enters the thread's transcript.
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
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
  |> should.equal(scoped(thread.MetaUpdated(Some("Model Title"), ["auto-tag"])))

  // The second exchange does not re-arm: once per thread.
  should.equal(thread.send_message(sess, "second"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // The throwaway branch is structurally unable to change a request
  // byte: Y never entered the thread's transcript.
  let tr = thread.snapshot(sess)
  transcript.length(tr) |> should.equal(5)
  let opts = transcript.Options(..transcript.default_options(), stream: True)
  should.be_false(string.contains(
    transcript.request_body(tr, opts),
    utility.instruction(True, []),
  ))
}

/// The two-line wiring (utility-tags plan §3.7): the runner's parsed
/// line-2 tags ride the widened apply seam BESIDE the title, and the
/// apply's fresh display tags ride the `MetaUpdated` broadcast. The
/// fake runner's signature is the UNCHANGED 4-arg `UtilityRunner` —
/// corpus plumbing lives registry-side only (§3.3), so thread-actor
/// fakes were never touched by it.
pub fn utility_apply_receives_parsed_tags_test() {
  let events = process.new_subject()
  let sess =
    start_with_utility(
      utility_config(20),
      happy_runner,
      fn(_endpoint, _tr, _cancel, _allow_pass) {
        Ok(utility.Title(title: "Model Title", tags: ["Login Bug", "auth"]))
      },
      fn(title, tags) {
        // The registry-shaped apply: replies with the fresh display set —
        // the incoming tags normalized, as the real merge would deliver.
        process.send(events, UtilAppliedTags(tags))
        Ok(thread.UtilityMeta(title, utility.normalize_tags(tags)))
      },
    )
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "first"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  // The worker forwarded the parsed tags beside the title, verbatim
  // through the seam (normalization/merge is the registry's business)…
  expect_utility(events)
  |> should.equal(UtilAppliedTags(["Login Bug", "auth"]))
  // …and the broadcast carries the apply's fresh display set.
  expect_event(sub)
  |> should.equal(
    scoped(thread.MetaUpdated(Some("Model Title"), ["login-bug", "auth"])),
  )

  // The branch never entered the transcript: one committed exchange —
  // system + user + assistant — and nothing else.
  transcript.length(thread.snapshot(sess)) |> should.equal(3)
}

/// A greeting-thread model that PASSes: the pass does NOT consume the
/// once-per-thread attempt (no apply, no MetaUpdated), the next
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

  should.equal(thread.send_message(sess, "hi"), thread.Sent)
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
  should.equal(thread.send_message(sess, "a real question"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(5) |> should.equal(expect_utility(events))
  UtilForcedAttempt |> should.equal(expect_utility(events))
  UtilAppliedNote("Model Title") |> should.equal(expect_utility(events))
  expect_event(sub)
  |> should.equal(scoped(thread.MetaUpdated(Some("Model Title"), ["auto-tag"])))

  // The forced attempt COMPLETED: the once-flag is spent now.
  should.equal(thread.send_message(sess, "third"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

/// A model that PASSes even under the forced instruction: that reply is
/// an unusable title, not a postpone — it consumes the attempt like any
/// failure, so the thread cannot defer twice (it keeps its heuristic
/// placeholder) instead of re-arming forever.
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

  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // Forced attempt: arrives with allow_pass = False, PASSes anyway, and
  // the once-flag is spent.
  should.equal(thread.send_message(sess, "still here"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(5) |> should.equal(expect_utility(events))
  UtilForcedAttempt |> should.equal(expect_utility(events))
  expect_no_utility(events, 400)
  expect_no_event(sub, 400)

  // No third attempt, ever.
  should.equal(thread.send_message(sess, "third"), thread.Sent)
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

  should.equal(thread.send_message(sess, "will fail"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

/// A utility side call in flight is invisible to callers: the thread is
/// never Busy because of it (fairness on serialized backends), a `Send`
/// cancels it instead, and the cancelled attempt does NOT consume the
/// once-per-thread flag — the debounce re-arms at the next commit point
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  // Each attempt hands over its own handle pair (owner = the worker).
  // Consume the first attempt's here: it is about to be cancelled.
  let assert Ok(cancelled_handles) = process.receive(ready, 2000)

  // The side call runs BESIDE the turn machinery: not streaming, not busy.
  thread.describe(sess).streaming |> should.be_false
  should.equal(thread.send_message(sess, "second"), thread.Sent)

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
  // the owed trigger is delivered and the thread's ONLY attempt runs
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
  |> should.equal(scoped(thread.MetaUpdated(Some("Model Title"), ["auto-tag"])))
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
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

/// A FAILED follow-up turn must not strand the thread's only attempt:
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  UtilCalled(3) |> should.equal(expect_utility(events))
  let assert Ok(handles) = process.receive(ready, 2000)

  // The follow-up send cancels the side call and its turn then FAILS
  // (flaky's failing turn streams two tokens before erroring).
  should.equal(thread.send_message(sess, "second"), thread.Sent)
  UtilCancelled |> should.equal(expect_utility(events))
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let assert thread.ThreadEvent(_, 1, thread.TurnFailed(_, _)) =
    expect_event(sub)

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
  |> should.equal(scoped(thread.MetaUpdated(Some("Model Title"), ["auto-tag"])))
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

  should.equal(thread.send_message(sess, "first"), thread.Sent)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)
  let _ = expect_event(sub)

  expect_no_utility(events, 400)
  expect_no_event(sub, 400)
}

// ---------------------------------------------------------------------------
// Bots P3b: authored sends (author + hop depth)
// ---------------------------------------------------------------------------

/// The bots P3b test seam — the shape the P3c delivery registry will
/// drive: the ONE `Send` message with display provenance. `send_message`
/// is the human path and keeps its `None`/`0` shape; no parallel
/// `Deliver` variant exists.
fn send_as(
  sess: process.Subject(thread.Msg),
  text: String,
  author: option.Option(String),
  depth: Int,
) -> thread.SendResult {
  actor.call(sess, 5000, fn(reply) { thread.Send(text, author, depth, reply) })
}

/// Drain a subscriber's queued events up to (and including) the turn's
/// terminal event. Used after releasing the gated runner, where the
/// in-flight mix of already-streamed events is timing-dependent but the
/// terminal event is not.
fn drain_until_turn_done(sub: process.Subject(thread.ThreadEvent)) -> Nil {
  case expect_event(sub) {
    thread.ThreadEvent(_, _, thread.TurnDone(_, _)) -> Nil
    _ -> drain_until_turn_done(sub)
  }
}

/// `UserEcho` with an unpredictable wall-clock stamp, returning the
/// author so callers can pin the provenance per render path.
fn expect_authored_echo(
  sub: process.Subject(thread.ThreadEvent),
  visit: Int,
  text: String,
) -> option.Option(String) {
  let assert thread.ThreadEvent(
    sid,
    v,
    thread.UserEcho(actual, Some(_), author),
  ) = expect_event(sub)
  sid |> should.equal(test_thread_id)
  v |> should.equal(visit)
  actual |> should.equal(text)
  author
}

/// The author rides EVERY render path — live echo, mid-turn join (the
/// `turn_view` display mirror), and post-turn replay — one shape per
/// path, so a reload never drops a badge (the empty-pill lesson). Depth
/// rides the display-only transcript sidecar only (never the wire);
/// pinned here through Snapshot.
pub fn authored_send_author_on_all_render_paths_test() {
  let gate_request = process.new_subject()
  let sess = start_with(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(send_as(sess, "ping", Some("Hermes"), 2), thread.Sent)

  // Live echo carries the author.
  expect_authored_echo(sub, 1, "ping") |> should.equal(Some("Hermes"))

  // Depth landed in the sidecar (index 1 = the user message; index 0 =
  // the system prompt is never marked).
  transcript.origin_at(thread.snapshot(sess), 1)
  |> should.equal(Some(transcript.Origin("Hermes", 2)))
  transcript.origin_at(thread.snapshot(sess), 0) |> should.equal(None)

  // Mid-turn join: the mirror replays the SAME author.
  let sub2 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(sub2)
  expect_authored_echo(sub2, 1, "ping") |> should.equal(Some("Hermes"))

  // Finish the turn.
  let assert Ok(gate) = process.receive(gate_request, 2000)
  process.send(gate, Nil)
  drain_until_turn_done(sub)
  drain_until_turn_done(sub2)

  // Post-turn join: the committed transcript replays the SAME author.
  let sub3 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(sub3)
  expect_authored_echo(sub3, 1, "ping") |> should.equal(Some("Hermes"))

  // A human send marks nothing — absence is the human case, live AND on
  // replay.
  should.equal(thread.send_message(sess, "human again"), thread.Sent)
  expect_authored_echo(sub, 1, "human again") |> should.equal(None)
  let sub4 = join(sess)
  let assert thread.ThreadEvent(_, 1, thread.Hello(_, _, _)) =
    expect_event(sub4)
  expect_authored_echo(sub4, 1, "ping") |> should.equal(Some("Hermes"))
  // The committed reply replays between the two user lines.
  let assert thread.ThreadEvent(
    _,
    1,
    thread.AssistantFull("Final answer", Some(_)),
  ) = expect_event(sub4)
  expect_authored_echo(sub4, 1, "human again") |> should.equal(None)

  // Release the "human again" turn's gate: the second gated runner would
  // otherwise park its worker on the 5s gate receive past the test.
  let assert Ok(gate2) = process.receive(gate_request, 2000)
  process.send(gate2, Nil)
}

/// An empty author is no author: `mark_origin` drops it, and the echo
/// reads the same sidecar a replay reads — so live and replay BOTH record
/// a human send (never Some(""), which the store's nullif sentinel would
/// file as NULL anyway). Pins the echo-reads-sidecar rule.
pub fn authored_send_empty_author_is_no_author_test() {
  let gate_request = process.new_subject()
  let sess = start_with(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(send_as(sess, "q", Some(""), 1), thread.Sent)
  expect_authored_echo(sub, 1, "q") |> should.equal(None)
  transcript.origin_at(thread.snapshot(sess), 1) |> should.equal(None)

  let assert Ok(gate) = process.receive(gate_request, 2000)
  process.send(gate, Nil)
}

/// The `/threads/<id>/state` dump's actor half (`web.gleam` asks
/// `thread.inspect`): idle — committed transcript only, not streaming,
/// no live mirror. The runner never fires.
pub fn inspect_reports_idle_state_test() {
  let sess = start_with(gated_runner(process.new_subject()))
  let inspect = thread.inspect(sess)

  should.be_false(inspect.status.streaming)
  should.equal(1, inspect.status.message_count)
  should.equal(None, inspect.live_turn)
  should.equal(1, transcript.length(inspect.transcript))
}

/// Mid-turn the dump must report the ACTOR's truth: the committed
/// transcript still holds only what was committed at Send (the worker
/// owns the extended one until WorkerDone), `streaming` is on, and the
/// live mirror carries the finished rounds plus the pending iteration
/// buffers. The mirror drops and the transcript settles at completion.
pub fn inspect_midturn_sees_mirror_then_settles_test() {
  let gate_request = process.new_subject()
  let sess = start_with(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  let assert Ok(gate) = process.receive(gate_request, 5000)

  let inspect = thread.inspect(sess)
  should.be_true(inspect.status.streaming)
  // Committed: system + user only — the worker's rounds are not
  // installed yet.
  should.equal(2, transcript.length(inspect.transcript))
  // Mirror renders the round the way the replay path consumes it —
  // pending text flushes as its own row, then ONE ROW PER CALL, then
  // each result (vs the loop's committed transcript, which is one
  // assistant row carrying both calls): system + user + text row + 2
  // call rows + 2 result rows.
  let assert Some(live) = inspect.live_turn
  should.equal(7, transcript.length(live.view))
  // Pending iteration-2 buffers (reset at the loop's "request" phase;
  // round 1's text/reasoning already flushed into the view).
  should.equal("Final answer", live.text)
  should.equal("final thinking", live.reasoning)

  process.send(gate, Nil)
  drain_until_turn_done(sub)

  let after = thread.inspect(sess)
  should.be_false(after.status.streaming)
  should.equal(None, after.live_turn)
  // The worker's RETURNED transcript installed wholesale: a TurnRunner
  // owns its transcript's shape, and the gated fake (like the real loop
  // contract) returns just what it appended — system + user + final
  // assistant. The mirror was event-driven, independent of it.
  should.equal(3, transcript.length(after.transcript))
}

// ---------------------------------------------------------------------------
// Roster attach/detach (environments plan Phase 2a)
// ---------------------------------------------------------------------------

/// Drive one roster change against an IDLE thread and return its reply
/// and the live `UserEcho` the tail line emits (the system-author status
/// row). `start_with_env` seeds the roster `["workspace"]`.
fn attach(
  sess: process.Subject(thread.Msg),
  sub: process.Subject(thread.ThreadEvent),
  name: String,
) -> Result(Nil, String) {
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget(name, None, reply))
  let result = process.receive(reply, 2000)
  // The tail line fans out immediately (idle path): a system-author
  // UserEcho naming the CURRENT full list.
  let assert thread.ThreadEvent(
    _sid,
    _v,
    thread.UserEcho(text, Some(_stamp), Some("system")),
  ) = expect_event(sub)
  let assert Ok(r) = result
  should.be_true(string.starts_with(text, "attached targets: "))
  r
}

pub fn attach_grows_roster_and_appends_tail_line_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  expect_event(sub) |> should.equal(scoped(thread.Hello("test-alias", 1, [])))

  let assert Ok(Nil) = attach(sess, sub, "proxmox-2")
  // Detach is symmetric.
  let reply = process.new_subject()
  process.send(sess, thread.DetachTarget("proxmox-2", reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho("attached targets: workspace.", Some(_), Some("system")),
  ) = expect_event(sub)
}

pub fn attach_refuses_reserved_and_duplicate_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  expect_event(sub) |> should.equal(scoped(thread.Hello("test-alias", 1, [])))

  // `workspace` is reserved and refused.
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("workspace", None, reply))
  let assert Ok(Error("target name 'workspace' is reserved")) =
    process.receive(reply, 2000)
  // A duplicate live attach is refused.
  let assert Ok(Nil) = attach(sess, sub, "node-1")
  let reply2 = process.new_subject()
  process.send(sess, thread.AttachTarget("node-1", None, reply2))
  let assert Ok(Error(reason)) = process.receive(reply2, 2000)
  reason |> should.equal("target \"node-1\" is already attached")
  // Detaching a non-attached name refuses.
  let reply3 = process.new_subject()
  process.send(sess, thread.DetachTarget("ghost", reply3))
  let assert Ok(Error(reason2)) = process.receive(reply3, 2000)
  reason2 |> should.equal("target \"ghost\" is not attached")
}

pub fn attach_refuses_bad_charset_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  expect_event(sub) |> should.equal(scoped(thread.Hello("test-alias", 1, [])))
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("bad name", None, reply))
  let assert Ok(Error(reason)) = process.receive(reply, 2000)
  should.be_true(string.contains(reason, "must match ^[a-zA-Z0-9_@-]+$"))
}

pub fn attach_mid_turn_queues_until_worker_done_test() {
  // The ordering rule (environments plan Phase 2a): an attach landing
  // while the worker owns the extended transcript must NOT append to the
  // transcript the worker will install (an actor-side append before
  // WorkerDone would be clobbered). It queues, replies Ok, emits no tail
  // line yet, and applies AFTER the worker installs its transcript —
  // so the subscriber sees TurnDone first, THEN the roster UserEcho.
  let gate_request = process.new_subject()
  let sess = start_with_env(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  // The turn is now in flight (Starting/Streaming): the worker owns the
  // extended transcript.
  expect_user_echo(sub, "research it")

  // Attach while the turn is in flight: accepted (queued), NO UserEcho
  // emitted yet.
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("proxmox-2", None, reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let snapshot = thread.snapshot(sess)
  // The committed transcript is STILL just system + user (the attach has
  // NOT been appended — it is queued, not clobbered).
  should.equal(2, transcript.length(snapshot))

  // Release the worker; the turn commits, THEN the queued attach applies.
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  drain_until_turn_done(sub)
  // After TurnDone: the tail line lands (system-author roster row).
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(text, Some(_), Some("system")),
  ) = expect_event(sub)
  should.equal(text, "attached targets: workspace, proxmox-2.")

  // The transcript now carries the roster row appended AFTER the turn.
  let after = thread.snapshot(sess)
  should.equal(4, transcript.length(after))
}

pub fn queued_roster_preview_fold_test() {
  // The queue's preview fold (environments plan Phase 2a): while a turn
  // is in flight, a NEW change validates against the roster the
  // already-queued changes will produce — so a duplicate attach against
  // a still-queued name refuses, and a detach of a still-queued name
  // applies in arrival order after WorkerDone.
  let gate_request = process.new_subject()
  let sess = start_with_env(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)
  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  expect_user_echo(sub, "research it")

  // Queue an attach of "proxmox-2".
  let r1 = process.new_subject()
  process.send(sess, thread.AttachTarget("proxmox-2", None, r1))
  let assert Ok(Ok(Nil)) = process.receive(r1, 2000)
  // A SECOND attach of the same name, still queued, refuses against the
  // preview (the live roster has not changed mid-turn).
  let r2 = process.new_subject()
  process.send(sess, thread.AttachTarget("proxmox-2", None, r2))
  let assert Ok(Error("target \"proxmox-2\" is already attached")) =
    process.receive(r2, 2000)
  // A detach of the still-queued name is accepted — the preview lists it
  // (attached by the queued change ahead of it).
  let r3 = process.new_subject()
  process.send(sess, thread.DetachTarget("proxmox-2", r3))
  let assert Ok(Ok(Nil)) = process.receive(r3, 2000)

  // Release: the two queued changes apply in order — attach, then detach
  // — netting back to just `workspace`, with a tail line per change.
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  drain_until_turn_done(sub)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(
      "attached targets: workspace, proxmox-2.",
      Some(_),
      Some("system"),
    ),
  ) = expect_event(sub)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho("attached targets: workspace.", Some(_), Some("system")),
  ) = expect_event(sub)
}

pub fn queued_roster_drains_on_worker_down_test() {
  // The crash-path drain (environments plan Phase 2a): a roster change
  // queued while the worker is mid-turn must still apply when the worker
  // DIES instead of completing — `WorkerDown` installs no transcript, so
  // the queued attach applies after `TurnFailed` rather than being
  // stranded forever (cubic review).
  let gate_request = process.new_subject()
  let sess = start_with_env(crash_after_gate_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "doomed"), thread.Sent)
  expect_user_echo(sub, "doomed")
  // The worker emits one token before parking: consume it so the next
  // event is the crash (TurnFailed), not leftover streaming.
  expect_event(sub) |> should.equal(scoped(thread.Token("partial")))

  // Queue an attach while the worker parks mid-turn.
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("proxmox-2", None, reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)

  // Release the gate: the worker kills itself → WorkerDown → TurnFailed,
  // THEN the queued attach drains and its roster row lands.
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  let assert thread.ThreadEvent(_, 1, thread.TurnFailed(reason, _)) =
    expect_event(sub)
  should.be_true(string.contains(reason, "worker"))
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(text, Some(_), Some("system")),
  ) = expect_event(sub)
  should.equal(text, "attached targets: workspace, proxmox-2.")
}

// ---------------------------------------------------------------------------
// Environment execution map (environments plan Phase 2b-2)
// ---------------------------------------------------------------------------

/// A parked fake NODE: it OWNS its subject (calls land in its mailbox
/// and park forever), reports the plane back through a handshake
/// subject, and lives until the test kills it — exactly the
/// registration shape the 2b-3 node adapter will present.
fn start_parked_node() -> #(process.Subject(tool_provider.Msg), process.Pid) {
  let back = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let own = process.new_subject()
      process.send(back, own)
      process.sleep_forever()
    })
  let assert Ok(own) = process.receive(back, 2000)
  #(own, pid)
}

fn route_env(
  sess: process.Subject(thread.Msg),
  target: String,
) -> Result(thread.EnvExec, String) {
  actor.call(sess, 2000, fn(reply) { thread.RouteEnv(target, reply) })
}

/// Wait (bounded) until the ask stops resolving — the DOWN signal is
/// asynchronous, so the actor may answer one more Ok before it
/// processes the death.
fn await_route_gone(
  sess: process.Subject(thread.Msg),
  target: String,
  tries: Int,
) -> Nil {
  case route_env(sess, target) {
    Error(_) -> Nil
    Ok(_) ->
      case tries > 0 {
        True -> {
          process.sleep(20)
          await_route_gone(sess, target, tries - 1)
        }
        False ->
          panic as { "target still routable after the node died: " <> target }
      }
  }
}

fn attach_with_exec(
  sess: process.Subject(thread.Msg),
  sub: process.Subject(thread.ThreadEvent),
  name: String,
  plane: #(process.Subject(tool_provider.Msg), process.Pid),
) -> Result(Nil, String) {
  let reply = process.new_subject()
  process.send(
    sess,
    thread.AttachTarget(name, Some(thread.EnvExec(plane.0, plane.1)), reply),
  )
  let result = process.receive(reply, 2000)
  let assert thread.ThreadEvent(
    _sid,
    _v,
    thread.UserEcho(text, Some(_stamp), Some("system")),
  ) = expect_event(sub)
  let assert Ok(r) = result
  should.be_true(string.starts_with(text, "attached targets: "))
  r
}

pub fn attach_with_exec_registers_routable_plane_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  let plane = start_parked_node()

  // Attach with the execution plane: roster line lands AND the routing
  // ask resolves the very same (subject, pid) pair.
  let assert Ok(Nil) = attach_with_exec(sess, sub, "node-a", plane)
  let assert Ok(thread.EnvExec(got_sub, got_pid)) = route_env(sess, "node-a")
  should.equal(got_sub, plane.0)
  should.equal(got_pid, plane.1)

  // Detach drops the plane immediately: routing errors honestly and
  // the roster line names the shrunken list.
  let reply = process.new_subject()
  process.send(sess, thread.DetachTarget("node-a", reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho("attached targets: workspace.", Some(_), Some("system")),
  ) = expect_event(sub)
  let assert Error(
    "target \"node-a\" is not attached. attached targets: workspace",
  ) = route_env(sess, "node-a")

  process.kill(plane.1)
}

/// Replace-on-reconnect (Phase 2b-3): a second connection for a live
/// name REPLACES the roster entry — the new plane routes at once, NO
/// roster line lands (the attached list is unchanged), the old plane's
/// process is killed, and a name-only attach of the live name still
/// refuses (the Phase 2a rule, unamended).
pub fn attach_replaces_live_plane_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  let plane1 = start_parked_node()
  let assert Ok(Nil) = attach_with_exec(sess, sub, "node-a", plane1)

  // The reconnect: same name, fresh plane.
  let plane2 = start_parked_node()
  let reply = process.new_subject()
  process.send(
    sess,
    thread.AttachTarget(
      "node-a",
      Some(thread.EnvExec(plane2.0, plane2.1)),
      reply,
    ),
  )
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)

  // No roster line lands: the subscriber hears NOTHING (the list is
  // unchanged — the model's tail context already names the target).
  should.equal(process.receive(sub, 150), Error(Nil))

  // Routing answers the NEW plane.
  let assert Ok(thread.EnvExec(got_sub, got_pid)) = route_env(sess, "node-a")
  should.equal(got_sub, plane2.0)
  should.equal(got_pid, plane2.1)

  // The OLD plane's process was killed (the linked socket died with
  // it); its stale DOWN is inert for the map — the entry stays live.
  await_dead(plane1.1, 20)
  let assert Ok(thread.EnvExec(still_sub, still_pid)) =
    route_env(sess, "node-a")
  should.equal(still_sub, plane2.0)
  should.equal(still_pid, plane2.1)

  // A name-only attach of the live name still refuses (Phase 2a rule).
  let plain = process.new_subject()
  process.send(sess, thread.AttachTarget("node-a", None, plain))
  let assert Ok(Error("target \"node-a\" is already attached")) =
    process.receive(plain, 2000)

  process.kill(plane2.1)
}

/// Wait (bounded) for a killed pid to register as dead.
fn await_dead(pid: process.Pid, tries: Int) -> Nil {
  case process.is_alive(pid) {
    False -> Nil
    True ->
      case tries {
        0 -> panic as "pid still alive after kill"
        _ -> {
          process.sleep(20)
          await_dead(pid, tries - 1)
        }
      }
  }
}

pub fn route_env_error_wording_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)

  // Not attached at all: the full live roster repeats.
  let assert Error(
    "target \"ghost\" is not attached. attached targets: workspace",
  ) = route_env(sess, "ghost")

  // Attached by NAME only (no execution plane — a roster-only attach):
  // the error must not lie that it is absent.
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("bare", None, reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(
      "attached targets: workspace, bare.",
      Some(_),
      Some("system"),
    ),
  ) = expect_event(sub)
  let assert Error(
    "target \"bare\" is attached but not routable (its node is not connected)",
  ) = route_env(sess, "bare")
}

pub fn node_death_detaches_roster_and_map_test() {
  let sess = start_with_env(happy_runner)
  let sub = join(sess)
  let _ = expect_event(sub)
  let plane = start_parked_node()
  let assert Ok(Nil) = attach_with_exec(sess, sub, "node-a", plane)

  // The adapter process dies (socket closed / crash): the monitor's
  // DOWN drops the routing entry and detaches through the same path as
  // an explicit DetachTarget — roster line included, while idle.
  process.kill(plane.1)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho("attached targets: workspace.", Some(_), Some("system")),
  ) = expect_event(sub)
  await_route_gone(sess, "node-a", 100)
}

pub fn node_death_mid_turn_queues_lines_after_worker_done_test() {
  // A node dying while a turn is in flight: the roster lines (the
  // queued attach, then the DOWN-driven detach) land AFTER the worker
  // installs its transcript, in FIFO order — the honest sequence. The
  // execution plane, meanwhile, was routable the moment the attach
  // landed and dead the moment the node died, regardless of the queue.
  let gate_request = process.new_subject()
  let sess = start_with_env(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)
  let plane = start_parked_node()

  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  expect_user_echo(sub, "research it")

  // Mid-turn attach with a plane: accepted (queued), routable NOW.
  let reply = process.new_subject()
  process.send(
    sess,
    thread.AttachTarget("node-a", Some(thread.EnvExec(plane.0, plane.1)), reply),
  )
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let assert Ok(thread.EnvExec(_, _)) = route_env(sess, "node-a")

  // The node dies mid-turn: the DOWN-driven detach queues behind the
  // attach; routing stops immediately.
  process.kill(plane.1)
  await_route_gone(sess, "node-a", 100)
  // Nothing appended to the committed transcript yet.
  should.equal(2, transcript.length(thread.snapshot(sess)))

  // Release the worker: TurnDone, then attach line, then detach line.
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  drain_until_turn_done(sub)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(
      "attached targets: workspace, node-a.",
      Some(_),
      Some("system"),
    ),
  ) = expect_event(sub)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho("attached targets: workspace.", Some(_), Some("system")),
  ) = expect_event(sub)
  let assert Error(
    "target \"node-a\" is not attached. attached targets: workspace",
  ) = route_env(sess, "node-a")
}

pub fn route_env_names_pending_targets_mid_turn_test() {
  // The routing ask's error names the EFFECTIVE roster (live + queued),
  // not the turn-frozen one: mid-turn, an attach's execution registers
  // immediately, so its name belongs in the honest list a typo'd or
  // hallucinated call reads (CodeRabbit review).
  let gate_request = process.new_subject()
  let sess = start_with_env(gated_runner(gate_request))
  let sub = join(sess)
  let _ = expect_event(sub)

  should.equal(thread.send_message(sess, "research it"), thread.Sent)
  expect_user_echo(sub, "research it")

  // Mid-turn roster-only attach of node-a: accepted (queued), no tail
  // line yet — but the effective roster the ask names already has it.
  let reply = process.new_subject()
  process.send(sess, thread.AttachTarget("node-a", None, reply))
  let assert Ok(Ok(Nil)) = process.receive(reply, 2000)
  let assert Error(
    "target \"typo\" is not attached. attached targets: workspace, node-a",
  ) = route_env(sess, "typo")

  // Release the worker; the queued line lands (the roster catches up to
  // what the ask already reported).
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  drain_until_turn_done(sub)
  let assert thread.ThreadEvent(
    _,
    _,
    thread.UserEcho(
      "attached targets: workspace, node-a.",
      Some(_),
      Some("system"),
    ),
  ) = expect_event(sub)
}
