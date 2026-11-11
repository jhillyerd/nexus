//// Phase 2 offline persistence tests, all through the in-memory store
//// seam (`test/store_mock`): hydrate rebuilds the transcript
//// byte-identically, write-behind commits land in order, metadata writes
//// through, replays are idempotent, and a full registry teardown +
//// re-boot (the mock store playing the external Postgres) restores a
//// thread whose request prefix is byte-identical and grows by suffix
//// only. No database, no network — plain `gleam test`.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/string
import gleeunit/should
import nexus/config
import nexus/loop
import nexus/openai
import nexus/store
import nexus/thread
import nexus/thread_registry
import nexus/timing
import nexus/tools
import nexus/transcript.{type Options, type Transcript}
import store_mock

fn test_config() -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 8080,
    ui_token: None,
    system_prompt: "frozen system prompt ZZ-SYS-ZZ",
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
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
  )
}

fn stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(1),
    duration_ms: 2,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 1,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Arguments JSON exactly as a model would emit it: whitespace inside,
/// keys in non-sorted order. Byte-stability of this string across a
/// store round-trip is the whole point (jsonb would normalize it).
const args_a = "{\"url\":  \"https://example.com/a?x=1\", \"limit\": 3}"

const args_b = "{\"q\": \"gleam  BEAM\",\"page\": 2}"

/// The production resolver's offline stand-in (same as the registry
/// suite's): the fixture provider resolves, anything else is unknown.
fn fixture_resolver() -> thread_registry.ResolveProvider {
  fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Ok(test_endpoint())
      False -> Error(thread_registry.ProviderUnknown)
    }
  }
}

fn test_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "https://provider.example/v1",
    api_key: None,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
  )
}

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  thread.StreamDone(stats(), transcript.append_assistant(tr, "hi"))
}

/// A turn shaped like the real agent loop: one assistant message with
/// text AND two tool calls, tool results, then the final answer.
fn tool_round_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.ToolCallAssembled("call_a", "http_fetch", args_a, None))
  on_event(loop.ToolCallAssembled("call_b", "web_search", args_b, None))
  on_event(loop.ToolResultEvent("call_a", "http_fetch", True, "fetched body"))
  on_event(loop.ToolResultEvent("call_b", "web_search", True, "search body"))
  let tr =
    tr
    |> transcript.append_assistant_tool_calls(
      text: Some("checking"),
      calls: [
        #("call_a", "http_fetch", args_a),
        #("call_b", "web_search", args_b),
      ],
      reasoning: None,
    )
    |> transcript.append_tool_result("call_a", "fetched body", ok: True)
    |> transcript.append_tool_result("call_b", "search body", ok: True)
    |> transcript.append_assistant("all done")
  thread.StreamDone(stats(), tr)
}

/// The encoding options the agent loop uses (stream on, frozen tools).
fn loop_options() -> Options {
  transcript.Options(
    ..transcript.default_options(),
    stream: True,
    tools: tools.default(test_config()) |> tools.schemas,
  )
}

// ---------------------------------------------------------------------------
// Pure mapper tests: transcript ⇄ rows
// ---------------------------------------------------------------------------

fn rich_transcript() -> Transcript {
  transcript.new("alias-1", test_config().system_prompt)
  |> transcript.append_user("first question")
  |> transcript.append_assistant("plain answer")
  |> transcript.append_user("go use tools")
  |> transcript.append_assistant_tool_calls(
    text: Some("checking"),
    calls: [
      #("call_a", "http_fetch", args_a),
      #("call_b", "web_search", args_b),
    ],
    reasoning: None,
  )
  |> transcript.append_tool_result("call_a", "fetched body", ok: True)
  |> transcript.append_tool_result("call_b", "search body", ok: True)
  |> transcript.append_assistant("all done")
}

pub fn rows_round_trip_is_byte_identical_test() {
  let tr = rich_transcript()
  let opts = loop_options()
  let body_before = transcript.request_body(tr, opts)

  // Rows for everything past the system prompt…
  let rows = store.transcript_rows(tr, 1)
  // …one assistant-with-two-calls message becomes three rows (text on the
  // first), each tool result its own row.
  should.equal(list.length(rows), 8)
  let rebuilt =
    store.transcript_from_rows("alias-1", test_config().system_prompt, rows)
  should.equal(transcript.request_body(rebuilt, opts), body_before)
  should.equal(transcript.length(rebuilt), transcript.length(tr))
}

pub fn rows_round_trip_without_call_text_test() {
  // An assistant tool-call message with NO text (the common case).
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("q")
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [
        #("c1", "web_search", args_b),
      ],
      reasoning: None,
    )
    |> transcript.append_tool_result("c1", "r", ok: True)
  let rows = store.transcript_rows(tr, 1)
  let rebuilt = store.transcript_from_rows("alias-1", "sys", rows)
  should.equal(
    transcript.request_body(rebuilt, loop_options()),
    transcript.request_body(tr, loop_options()),
  )
}

pub fn transcript_rows_skip_persisted_prefix_test() {
  let tr = rich_transcript()
  // After persisting 4 messages (system + 3), the delta is the rest:
  // 4 messages whose row shapes total 5 rows (an assistant message with
  // two calls is two rows).
  let delta = store.transcript_rows(tr, 4)
  should.equal(list.length(delta), 5)
  // Rebuilding from ALL rows still needs the full row list: the delta
  // alone plus the skipped prefix reconstructs everything.
  let all = store.transcript_rows(tr, 1)
  should.equal(
    store.transcript_from_rows("alias-1", test_config().system_prompt, all)
      |> transcript.request_body(loop_options()),
    transcript.request_body(tr, loop_options()),
  )
  // has_delta guards the write-behind lane.
  should.be_true(store.has_delta(tr, 4))
  should.be_false(store.has_delta(tr, transcript.length(tr)))
  should.be_false(store.has_delta(tr, 99))
}

pub fn failed_tool_result_round_trips_through_rows_test() {
  // A failed call must survive both the write-behind (rows carry the
  // real tool_ok) and the rehydration read (sidecar restored), so a
  // reload or restart replay keeps the card red instead of laundering
  // it green.
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("q")
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c1", "http_fetch", "{\"url\":\"x\"}")],
      reasoning: None,
    )
    |> transcript.append_tool_result("c1", "{\"error\":\"boom\"}", ok: False)
  let rows = store.transcript_rows(tr, 1)
  let assert [_, _, store.ToolResultRow(ok: False, ..)] = rows

  // The rebuilt transcript restores the outcome at the tool message's
  // chronological index (user=1, assistant=2, tool=3).
  let rebuilt = store.transcript_from_rows("alias-1", "sys", rows)
  transcript.tool_result_at(rebuilt, 3) |> should.equal(Some(False))
  // Successes keep the same shape with the real ok.
  let ok_tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("q")
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c1", "http_fetch", "{\"url\":\"x\"}")],
      reasoning: None,
    )
    |> transcript.append_tool_result("c1", "{\"status\":200}", ok: True)
  store.transcript_rows(ok_tr, 1)
  |> list.drop(2)
  |> list.first
  |> should.equal(
    Ok(store.ToolResultRow(
      call_id: "c1",
      name: "http_fetch",
      ok: True,
      content: "{\"status\":200}",
      at: None,
    )),
  )
}

// ---------------------------------------------------------------------------
// Registry + functional mock store
// ---------------------------------------------------------------------------

type Boot {
  Boot(
    registry: Subject(thread_registry.Msg),
    registry_pid: Pid,
    factory_pid: Pid,
  )
}

/// Boot a factory + registry over a given store seam, keeping the pids so
/// a test can tear the whole "VM" down while the store survives.
fn boot(seam: store.Store) -> Boot {
  // Threads created through the registry pin the fixture provider.
  store_mock.ensure_fixture_provider(seam)
  let factory_name = process.new_name("nexus_persist_factory")
  let registry_name = process.new_name("nexus_persist_registry")
  let assert Ok(factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started) =
    thread_registry.start_with_runner(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      registry_name,
      seam,
      tool_round_runner,
      fn(_endpoint, _tr, _cancel, _allow_pass) {
        Error("no utility call in this test")
      },
      // The corpus seam: never asked in these tests (the fake runner
      // above refuses before any request), pure to stay offline.
      fn() { [] },
      fixture_resolver(),
    )
  Boot(
    registry: started.data,
    registry_pid: started.pid,
    factory_pid: factory.pid,
  )
}

/// Simulate a whole-VM restart: the registry and its thread factory die;
/// the store (the external database) survives. Unlink first — the test
/// process started (and is therefore linked to) both supervisors, and a
/// plain kill would drag the test runner down with them.
fn restart_vm(booted: Boot) -> Nil {
  process.unlink(booted.registry_pid)
  process.unlink(booted.factory_pid)
  process.kill(booted.registry_pid)
  process.kill(booted.factory_pid)
  process.sleep(100)
}

/// What a create hands the tests: the fresh summary's id plus the live
/// actor's subject (resolved through the registry — the create reply is a
/// `ThreadSummary` now, and subjects are always fetched via `Get`).
type Created {
  Created(id: String, subject: Subject(thread.Msg))
}

fn create(
  registry: Subject(thread_registry.Msg),
  model: String,
  runner: thread.TurnRunner,
) -> Created {
  let assert Ok(summary) =
    thread_registry.create_with_runner(
      registry,
      new_thread(store_mock.fixture_provider_id, model),
      runner,
    )
  let assert Ok(subject) = thread_registry.get(registry, summary.id)
  Created(id: summary.id, subject: subject)
}

/// The common creation request shape: pin provider + model,
/// config-default prompt.
fn new_thread(provider_id: String, model: String) -> thread_registry.NewThread {
  thread_registry.NewThread(
    provider_id: provider_id,
    model: model,
    system_prompt: None,
    bot_id: None,
  )
}

/// Run one turn and wait for its commit to land in the store.
fn run_turn(
  subject: Subject(thread.Msg),
  text: String,
  mock: Subject(store_mock.MockMsg),
  commits_before: Int,
) -> Nil {
  should.equal(thread.send_message(subject, text), thread.Sent)
  store_mock.await_commits(mock, commits_before + 2)
}

pub fn write_behind_persists_in_order_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", tool_round_runner)

  run_turn(record.subject, "first question", mock, 0)
  run_turn(record.subject, "second question", mock, 2)

  // Two turns → four commits (user + completion each), in order.
  let commits =
    store_mock.events(mock)
    |> list.filter_map(fn(event) {
      case event {
        store_mock.EvCommit(id, messages) -> Ok(#(id, messages))
        _ -> Error(Nil)
      }
    })
  should.equal(commits, [
    #(record.id, 2),
    #(record.id, 6),
    #(record.id, 7),
    #(record.id, 11),
  ])

  // The final rows reconstruct the full transcript byte-identically.
  let assert Ok([#(_, rows)]) = Ok(store_mock.rows(mock))
  let rebuilt =
    store.transcript_from_rows("alias-1", test_config().system_prompt, rows)
  should.equal(
    transcript.request_body(rebuilt, loop_options()),
    transcript.request_body(thread.snapshot(record.subject), loop_options()),
  )
}

pub fn metadata_writes_through_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", happy_runner)

  // Auto-title applies once and is guarded in the store too.
  should.be_true(thread_registry.auto_title(
    booted.registry,
    record.id,
    "first msg",
  ))
  should.be_false(thread_registry.auto_title(
    booted.registry,
    record.id,
    "sneaky",
  ))
  should.be_true(thread_registry.set_title(
    booted.registry,
    record.id,
    "renamed",
  ))
  should.be_true(
    thread_registry.set_tags(booted.registry, record.id, ["work", "notes"]),
  )
  should.be_true(thread_registry.set_pinned(booted.registry, record.id, True))
  should.be_true(thread_registry.set_archived(booted.registry, record.id, True))

  // The store saw the same sequence (write-through), archive included.
  let events =
    store_mock.events(mock)
    |> list.filter(fn(event) {
      case event {
        store_mock.EvInsertThread(_)
        | store_mock.EvCommit(_, _)
        | store_mock.EvAutoTitle(_, _) -> True
        _ -> False
      }
    })
  should.equal(events, [
    store_mock.EvInsertThread(record.id),
    store_mock.EvAutoTitle(record.id, "first msg"),
  ])
  let tail =
    store_mock.events(mock)
    |> list.filter(fn(event) {
      case event {
        store_mock.EvCommit(_, _) -> False
        // Fixture provider seeding (P1) is setup, not the sequence under
        // test here.
        store_mock.EvInsertProvider(_)
        | store_mock.EvUpdateProvider(_)
        | store_mock.EvDeleteProvider(_) -> False
        _ -> True
      }
    })
    |> list.drop(2)
  should.equal(tail, [
    store_mock.EvSetTitle(record.id, "renamed"),
    store_mock.EvSetTags(record.id, ["work", "notes"]),
    store_mock.EvSetPinned(record.id, True),
    store_mock.EvArchive(record.id),
  ])

  // And a fresh boot (the sidebar's view of the stored row) sees it all.
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    thread_registry.list_threads(booted2.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "renamed")
  should.equal(summary.title_source, thread.ManualTitle)
  should.equal(summary.tags, ["work", "notes"])
  should.be_true(summary.archived)
  // Archiving cleared the pin in the stored row as well.
  should.be_false(summary.pinned)
}

pub fn restart_hydrates_byte_identical_prefix_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", tool_round_runner)
  should.be_true(thread_registry.auto_title(
    booted.registry,
    record.id,
    "first question",
  ))

  run_turn(record.subject, "first question", mock, 0)
  run_turn(record.subject, "second question", mock, 2)
  let opts = loop_options()
  let body_before =
    transcript.request_body(thread.snapshot(record.subject), opts)

  // ---- the "VM" restarts; only the store survives ---------------------
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))

  // The thread is listed from the store (dormant), with its stored
  // metadata and message count (turn 1: 6 messages; turn 2 adds 5).
  let summaries = thread_registry.list_threads(booted2.registry)
  should.equal(list.length(summaries), 1)
  let assert Ok(summary) = list.first(summaries)
  should.equal(summary.id, record.id)
  should.equal(summary.model, "alias-1")
  should.equal(summary.title, "first question")
  should.equal(summary.message_count, 11)
  should.be_false(summary.streaming)
  should.equal(summary.metrics, [])

  // Lazily start it: the first Get hydrates from the store.
  let assert Ok(subject2) = thread_registry.get(booted2.registry, record.id)
  let snapshot2 = thread.snapshot(subject2)
  should.equal(transcript.model(snapshot2), "alias-1")
  // BYTE-IDENTICAL across the restart — the KV-cache contract.
  let body_after = transcript.request_body(snapshot2, opts)
  should.equal(body_after, body_before)

  // Continuing the thread grows the body by suffix only.
  should.equal(thread.send_message(subject2, "third question"), thread.Sent)
  store_mock.await_commits(mock, 6)
  let body_next = transcript.request_body(thread.snapshot(subject2), opts)
  should.be_true(extends(body_before, body_next))
}

/// Copied from the m3 golden test's shape: the messages array grows by
/// suffix only and the envelope after it stays byte-identical.
fn body_parts(body: String) -> #(String, String) {
  case string.split(body, on: ",\"stream\"") {
    [messages, envelope] -> #(messages, ",\"stream\"" <> envelope)
    _ -> panic as "request body has no stream marker"
  }
}

fn extends(prev: String, next: String) -> Bool {
  let #(prev_messages, prev_envelope) = body_parts(prev)
  let #(next_messages, next_envelope) = body_parts(next)
  string.starts_with(next_messages, string.drop_end(prev_messages, 1))
  && prev_envelope == next_envelope
}

pub fn lazy_start_is_one_shot_and_continues_ids_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // Pre-populate the "database" with two stored threads.
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(stored("s1"), "sys-1")
  let assert Ok(_) = seam.insert_thread(stored("s2"), "sys-2")

  let booted = boot(seam)
  let summaries = thread_registry.list_threads(booted.registry)
  should.equal(summaries |> list.map(fn(summary) { summary.id }), ["s1", "s2"])

  // The first Get hydrates; the second returns the SAME actor (one
  // thread, one commit lane: both sends' commits land on the one id,
  // and the snapshot grows monotonically).
  let assert Ok(subject_a) = thread_registry.get(booted.registry, "s2")
  let assert Ok(subject_b) = thread_registry.get(booted.registry, "s2")
  should.equal(thread.send_message(subject_a, "hi"), thread.Sent)
  should.equal(thread.send_message(subject_b, "again"), thread.Sent)
  store_mock.await_commits(mock, 4)
  should.equal(
    store_mock.events(mock)
      |> list.filter(fn(e) {
        case e {
          store_mock.EvCommit("s2", _) -> True
          _ -> False
        }
      })
      |> list.length,
    4,
  )
  // Both subjects address one transcript: sys + two complete tool rounds
  // (each: user, assistant-with-2-calls, 2 tool results, final).
  should.equal(transcript.length(thread.snapshot(subject_a)), 11)
  should.equal(transcript.length(thread.snapshot(subject_b)), 11)

  // A fresh create mints past the stored ids: s3, not a collision.
  let created = create(booted.registry, "alias-x", happy_runner)
  should.equal(created.id, "s3")
}

fn stored(id: String) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: store_mock.fixture_provider_id,
    model: "alias-1",
    // Manually titled: a dormant row the boot sweep must KEEP (a rename
    // is user intent, unlike a never-used empty). message_count stays 1 —
    // system prompt only, consistent with the empty row list.
    meta: thread.ThreadMeta(
      title: "stored",
      title_source: thread.ManualTitle,
      pinned: False,
      tags: [],
      tags_manual: [],
      tags_source: thread.AutoTags,
      archived: False,
      bot_id: None,
      created_at: timing.wall_now_s(),
    ),
    last_active_at: timing.wall_now_s(),
    message_count: 1,
  )
}

pub fn duplicate_commit_is_idempotent_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", tool_round_runner)
  run_turn(record.subject, "first question", mock, 0)

  let assert Ok([#(_, rows_before)]) = Ok(store_mock.rows(mock))
  let snapshot = thread.snapshot(record.subject)

  // Crash-recovery replay: the same commit arrives twice.
  seam.commit(record.id, snapshot)
  store_mock.await_commits(mock, 4)
  let assert Ok([#(_, rows_after)]) = Ok(store_mock.rows(mock))
  should.equal(rows_after, rows_before)

  // An OLDER transcript (as after a stale write-behind flush) is a no-op.
  let older = transcript.new("alias-1", test_config().system_prompt)
  seam.commit(record.id, older)
  store_mock.await_commits(mock, 5)
  let assert Ok([#(_, rows_still)]) = Ok(store_mock.rows(mock))
  should.equal(rows_still, rows_before)
}

pub fn replay_after_missed_commit_repair_rows_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", tool_round_runner)
  run_turn(record.subject, "first question", mock, 0)
  run_turn(record.subject, "second question", mock, 2)

  let assert Ok([#(_, rows_full)]) = Ok(store_mock.rows(mock))
  let snapshot = thread.snapshot(record.subject)

  // A crash loses the last flush: the store only has the first turn's
  // rows. The next commit (the retry) re-emits the missing delta.
  store_mock.rewind(mock, record.id, 6, 6)
  let assert Ok([#(_, rows_rewound)]) = Ok(store_mock.rows(mock))
  should.equal(list.length(rows_rewound), 6)
  seam.commit(record.id, snapshot)
  store_mock.await_commits(mock, 5)
  let assert Ok([#(_, rows_repaired)]) = Ok(store_mock.rows(mock))
  should.equal(rows_repaired, rows_full)
}

pub fn delete_removes_stored_rows_and_dormant_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // Stored BEFORE boot, so the registry hydrates it into the dormant set
  // (the store is single-writer: rows appear there only through this
  // registry's create path or a previous boot).
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(stored("s99"), "sys")
  let booted = boot(seam)
  let live = create(booted.registry, "alias-1", happy_runner)

  // Deleting a dormant thread (no live actor) removes the stored row.
  should.be_true(thread_registry.delete_thread(booted.registry, "s99"))
  should.equal(seam.get_thread("s99") |> result_is_error, True)

  // Deleting a live one stops the actor and removes the row + records.
  run_turn(live.subject, "hello", mock, 0)
  should.be_true(thread_registry.delete_thread(booted.registry, live.id))
  should.equal(seam.get_thread(live.id) |> result_is_error, True)
  should.equal(store_mock.rows(mock), [])

  // And it stays gone across a restart.
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  should.equal(thread_registry.list_threads(booted2.registry), [])
  should.equal(thread_registry.get(booted2.registry, live.id), Error(Nil))
}

fn result_is_error(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn dormant_metadata_writes_through_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(stored("s1"), "sys")
  let booted = boot(seam)

  // Metadata mutations on a DORMANT thread apply to the stored row and
  // are visible to the next boot — no live actor needed.
  should.be_true(thread_registry.set_title(booted.registry, "s1", "named"))
  should.be_true(thread_registry.set_tags(booted.registry, "s1", ["a"]))
  should.be_true(thread_registry.set_pinned(booted.registry, "s1", True))

  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    thread_registry.list_threads(booted2.registry)
    |> list.find(fn(summary) { summary.id == "s1" })
  should.equal(summary.title, "named")
  should.equal(summary.title_source, thread.ManualTitle)
  should.equal(summary.tags, ["a"])
  should.be_true(summary.pinned)
}

pub fn boot_fails_when_store_unreachable_test() {
  // A seam whose list_summaries fails must refuse to start the registry:
  // persistence is mandatory, no silent ephemeral mode.
  let broken =
    store.Store(..store_mock.seam(store_mock.start()), list_summaries: fn() {
      Error("connection refused")
    })
  let factory_name = process.new_name("nexus_broken_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let started =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_broken_registry"),
      broken,
      fixture_resolver(),
    )
  case started {
    Ok(_) -> panic as "registry must not start with an unreachable store"
    Error(_) -> Nil
  }
}

// ---------------------------------------------------------------------------
// Reasoning round-trip
// ---------------------------------------------------------------------------

pub fn reasoning_rows_round_trip_test() {
  let tr =
    transcript.new("alias-1", test_config().system_prompt)
    |> transcript.append_user("think hard")
    |> transcript.append_assistant_with_reasoning(
      "the answer",
      reasoning: Some("step one, then step two"),
    )
    |> transcript.append_user("again")
    |> transcript.append_assistant("done")
  let rows = store.transcript_rows(tr, 1)
  rows
  |> should.equal([
    store.UserRow("think hard", None),
    store.AssistantRow("the answer", Some("step one, then step two"), None),
    store.UserRow("again", None),
    store.AssistantRow("done", None, None),
  ])
  let rebuilt =
    store.transcript_from_rows("alias-1", test_config().system_prompt, rows)
  transcript.reasoning_at(rebuilt, 2)
  |> should.equal(Some("step one, then step two"))
  transcript.reasoning_at(rebuilt, 4) |> should.equal(None)
}

pub fn tool_call_reasoning_rides_first_row_of_run_test() {
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("q")
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c1", "echo", "{}"), #("c2", "echo", "{}")],
      reasoning: Some("two calls needed"),
    )
    |> transcript.append_tool_result("c1", "r1", ok: True)
    |> transcript.append_tool_result("c2", "r2", ok: True)
  store.transcript_rows(tr, 1)
  |> should.equal([
    store.UserRow("q", None),
    store.ToolCallRow("", "c1", "echo", "{}", Some("two calls needed"), None),
    store.ToolCallRow("", "c2", "echo", "{}", None, None),
    store.ToolResultRow("c1", "echo", True, "r1", None),
    store.ToolResultRow("c2", "echo", True, "r2", None),
  ])
}

// ---------------------------------------------------------------------------
// Timestamp stamps (display-only created_at round-trip)
// ---------------------------------------------------------------------------

pub fn timestamp_rows_round_trip_test() {
  let tr =
    transcript.new("alias-1", test_config().system_prompt)
    |> transcript.append_user("q")
    |> transcript.stamp(1000)
    |> transcript.append_assistant("a")
    |> transcript.stamp(2000)
    |> transcript.append_user("again")
    |> transcript.stamp(3000)
    |> transcript.append_assistant("done")
    |> transcript.stamp(4000)
  let rows = store.transcript_rows(tr, 1)
  rows
  |> should.equal([
    store.UserRow("q", Some(1000)),
    store.AssistantRow("a", None, Some(2000)),
    store.UserRow("again", Some(3000)),
    store.AssistantRow("done", None, Some(4000)),
  ])
  // Hydration restores the stamps at the same chronological indexes, so
  // a reloaded thread renders the same per-message ages.
  let rebuilt =
    store.transcript_from_rows("alias-1", test_config().system_prompt, rows)
  transcript.stamped_at(rebuilt, 1) |> should.equal(Some(1000))
  transcript.stamped_at(rebuilt, 2) |> should.equal(Some(2000))
  // The second user message rides the same round-trip: a hydration bug
  // affecting later USER timestamps must not slip through.
  transcript.stamped_at(rebuilt, 3) |> should.equal(Some(3000))
  transcript.stamped_at(rebuilt, 4) |> should.equal(Some(4000))
}

pub fn tool_call_stamp_rides_first_row_of_run_test() {
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("q")
    |> transcript.stamp(1000)
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c1", "echo", "{}"), #("c2", "echo", "{}")],
      reasoning: None,
    )
    |> transcript.stamp(2000)
    |> transcript.append_tool_result("c1", "r1", ok: True)
    |> transcript.stamp(3000)
  store.transcript_rows(tr, 1)
  |> should.equal([
    store.UserRow("q", Some(1000)),
    // One assistant message = one stamp, on the run's FIRST row only —
    // same rule as content/reasoning.
    store.ToolCallRow("", "c1", "echo", "{}", None, Some(2000)),
    store.ToolCallRow("", "c2", "echo", "{}", None, None),
    store.ToolResultRow("c1", "echo", True, "r1", Some(3000)),
  ])
  let rebuilt =
    store.transcript_from_rows("alias-1", "sys", store.transcript_rows(tr, 1))
  transcript.stamped_at(rebuilt, 2) |> should.equal(Some(2000))
  transcript.stamped_at(rebuilt, 3) |> should.equal(Some(3000))
}

// ---------------------------------------------------------------------------
// Utility-titles/tags: auto_meta_upgrade guard semantics (utility-titles
// plan §4.4, utility-tags plan §3.6) — the store-side twin of the
// registry's UpgradeAutoTitle guard: applies while BOTH provenance
// columns are 'auto', refused after a manual title rename OR a manual
// tag save, and the mock records the tags writes.
// ---------------------------------------------------------------------------

/// A stored summary like the heuristic title leaves behind: still
/// auto-generated, already carrying the placeholder text.
fn auto_stored(id: String, title: String) -> store.StoredSummary {
  store.StoredSummary(
    ..stored(id),
    meta: thread.ThreadMeta(
      ..stored(id).meta,
      title: title,
      title_source: thread.AutoTitle,
    ),
  )
}

/// `title_source = 'auto'`: the upgrade APPLIES and REPLACES — first the
/// heuristic placeholder, then even a previously upgraded title (the
/// guard is provenance only, never "empty title only").
pub fn auto_meta_upgrade_replaces_auto_title_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(auto_stored("s1", "heuristic"), "sys")

  should.equal(seam.auto_meta_upgrade("s1", "Model Title", []), Ok(True))
  let assert Ok(stored) = seam.get_thread("s1")
  should.equal(stored.summary.meta.title, "Model Title")
  should.equal(stored.summary.meta.title_source, thread.AutoTitle)

  // An upgraded title is still auto-generated: it may be replaced again.
  should.equal(seam.auto_meta_upgrade("s1", "Better Title", []), Ok(True))
  let assert Ok(stored) = seam.get_thread("s1")
  should.equal(stored.summary.meta.title, "Better Title")
}

/// `title_source = 'manual'`: the upgrade is REFUSED and replies False —
/// a rename wins forever, in the store exactly as in memory. An unknown
/// id is an error, like the real store.
pub fn auto_meta_upgrade_refuses_manual_title_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(auto_stored("s2", "heuristic"), "sys")

  should.equal(seam.set_title("s2", "renamed"), Ok(Nil))
  should.equal(seam.auto_meta_upgrade("s2", "Sneaky", []), Ok(False))
  let assert Ok(stored) = seam.get_thread("s2")
  should.equal(stored.summary.meta.title, "renamed")
  should.equal(stored.summary.meta.title_source, thread.ManualTitle)

  should.be_error(seam.auto_meta_upgrade("nope", "X", []))
}

/// The tags side of the same guard: a manual tag save (`set_tags.sql`'s
/// atomic triple-write) flips `tags_source` to 'manual' FIRST, so a
/// racing in-flight apply's write-through is refused — the whole write,
/// not just the tags half. The row keeps the user's exact set.
pub fn auto_meta_upgrade_refuses_after_manual_tag_save_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(auto_stored("s3", "heuristic"), "sys")

  should.equal(seam.set_tags("s3", ["mine"]), Ok(Nil))
  should.equal(
    seam.auto_meta_upgrade("s3", "Model Title", ["model-tag"]),
    Ok(False),
  )
  let assert Ok(stored) = seam.get_thread("s3")
  // Refused WHOLE: the title stays untouched too, not just the tags.
  should.equal(stored.summary.meta.title, "heuristic")
  should.equal(stored.summary.meta.tags, ["mine"])
  should.equal(stored.summary.meta.tags_manual, ["mine"])
  should.equal(stored.summary.meta.tags_source, thread.ManualTags)

  // The mock recorded the manual save; no upgrade was written.
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvSetTags(_, _) | store_mock.EvAutoMetaUpgrade(_, _, _) -> True
      _ -> False
    }
  })
  |> should.equal([store_mock.EvSetTags("s3", ["mine"])])
}

/// The applying side records the TAGS write (§5): while both sources
/// are auto the upgrade lands title AND display tags in one guarded
/// statement, and the mock's event log carries the exact payload.
pub fn auto_meta_upgrade_applies_and_records_tags_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(auto_stored("s4", "heuristic"), "sys")

  should.equal(
    seam.auto_meta_upgrade("s4", "Model Title", ["login", "auth"]),
    Ok(True),
  )
  let assert Ok(stored) = seam.get_thread("s4")
  should.equal(stored.summary.meta.title, "Model Title")
  should.equal(stored.summary.meta.tags, ["login", "auth"])
  // Both provenance columns stay 'auto': a later attempt may merge again.
  should.equal(stored.summary.meta.title_source, thread.AutoTitle)
  should.equal(stored.summary.meta.tags_source, thread.AutoTags)
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvAutoMetaUpgrade(_, _, _) -> True
      _ -> False
    }
  })
  |> should.equal([
    store_mock.EvAutoMetaUpgrade("s4", "Model Title", ["login", "auth"]),
  ])
}

/// The registry's UpgradeAutoTitle — what the utility worker's apply step
/// calls — applies for a LIVE thread with an auto title, writes through
/// to the store, and refuses (without touching the store) once a manual
/// rename landed. Across a restart the store's answer stands.
pub fn upgrade_auto_title_writes_through_and_survives_restart_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", happy_runner)
  should.be_true(thread_registry.auto_title(
    booted.registry,
    record.id,
    "first msg",
  ))

  // The utility worker's apply step: the heuristic placeholder is
  // upgraded to the model title, in memory and in the store.
  should.equal(
    thread_registry.upgrade_auto_title(
      booted.registry,
      record.id,
      "Model Title",
      [],
    ),
    thread_registry.UpgradeApplied("Model Title", []),
  )
  let assert Ok(summary) =
    thread_registry.list_threads(booted.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "Model Title")
  should.equal(summary.title_source, thread.AutoTitle)
  should.equal(
    store_mock.events(mock)
      |> list.filter(fn(event) {
        case event {
          store_mock.EvAutoMetaUpgrade(id, _title, _tags) -> id == record.id
          _ -> False
        }
      }),
    [store_mock.EvAutoMetaUpgrade(record.id, "Model Title", [])],
  )

  // A manual rename wins forever: refused, and the store is never asked.
  should.be_true(thread_registry.set_title(
    booted.registry,
    record.id,
    "renamed",
  ))
  should.equal(
    thread_registry.upgrade_auto_title(booted.registry, record.id, "Sneaky", []),
    thread_registry.UpgradeRefused,
  )
  should.equal(
    store_mock.events(mock)
      |> list.filter(fn(event) {
        case event {
          store_mock.EvAutoMetaUpgrade(_, "Sneaky", _) -> True
          _ -> False
        }
      }),
    [],
  )

  // The restart reads the stored row: the upgrade survived, and the
  // manual rename after it stands.
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    thread_registry.list_threads(booted2.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "renamed")
  should.equal(summary.title_source, thread.ManualTitle)
}

/// The store guard has the final word (twin-invariant): a concurrent
/// manual rename can land in the store while a registry instance still
/// holds `AutoTitle` in memory. The registry then REFUSES — no local
/// mutation, no `UpgradeApplied` — instead of clobbering the rename with
/// a title its own guard would have rejected.
pub fn upgrade_auto_title_honors_store_refusal_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", happy_runner)
  should.be_true(thread_registry.auto_title(
    booted.registry,
    record.id,
    "first msg",
  ))

  // A concurrent rename lands in the store BEHIND the registry's back
  // (direct seam write, bypassing the registry's in-memory record).
  should.equal(seam.set_title(record.id, "concurrent rename"), Ok(Nil))

  // The registry's memory still says AutoTitle, but the store refuses —
  // and the registry honors it: nothing applied, nothing changed.
  should.equal(
    thread_registry.upgrade_auto_title(
      booted.registry,
      record.id,
      "Model Title",
      [],
    ),
    thread_registry.UpgradeRefused,
  )
  let assert Ok(summary) =
    thread_registry.list_threads(booted.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "first msg")
  should.equal(summary.title_source, thread.AutoTitle)
  should.equal(
    store_mock.events(mock)
      |> list.filter(fn(event) {
        case event {
          store_mock.EvAutoMetaUpgrade(_, _, _) -> True
          _ -> False
        }
      }),
    [],
  )
}

/// The upgrade also reaches a DORMANT (stored-but-not-live) thread —
/// the registry branch for ids with no live actor.
pub fn upgrade_auto_title_on_dormant_thread_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_thread(auto_stored("s9", "heuristic"), "sys")
  let booted = boot(seam)

  should.equal(
    thread_registry.upgrade_auto_title(booted.registry, "s9", "Model Title", []),
    thread_registry.UpgradeApplied("Model Title", []),
  )
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    thread_registry.list_threads(booted2.registry)
    |> list.find(fn(summary) { summary.id == "s9" })
  should.equal(summary.title, "Model Title")
  should.equal(summary.title_source, thread.AutoTitle)
}

/// The tags ride the SAME write as the title (§5): the registry's
/// upgrade merges the attempt's tags into the display set, writes them
/// through in one guarded statement (the mock records the payload),
/// and a restart reads the merged set back from the stored row.
pub fn upgrade_auto_title_merges_tags_and_survives_restart_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", happy_runner)
  should.be_true(thread_registry.auto_title(
    booted.registry,
    record.id,
    "first msg",
  ))

  thread_registry.upgrade_auto_title(booted.registry, record.id, "Model Title", [
    "Login Bug",
    "auth",
  ])
  |> should.equal(
    thread_registry.UpgradeApplied("Model Title", ["login-bug", "auth"]),
  )
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvAutoMetaUpgrade(id, _, _) -> id == record.id
      _ -> False
    }
  })
  |> should.equal([
    store_mock.EvAutoMetaUpgrade(record.id, "Model Title", ["login-bug", "auth"]),
  ])

  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    thread_registry.list_threads(booted2.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "Model Title")
  should.equal(summary.tags, ["login-bug", "auth"])
}
