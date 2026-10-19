//// Phase 2 offline persistence tests, all through the in-memory store
//// seam (`test/store_mock`): hydrate rebuilds the transcript
//// byte-identically, write-behind commits land in order, metadata writes
//// through, replays are idempotent, and a full registry teardown +
//// re-boot (the mock store playing the external Postgres) restores a
//// session whose request prefix is byte-identical and grows by suffix
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
import nexus/session
import nexus/session_registry
import nexus/store
import nexus/timing
import nexus/tools
import nexus/transcript.{type Options, type Transcript}
import store_mock

fn test_config() -> config.Config {
  config.Config(
    base_url: "https://bifrost.example/v1",
    api_key: "sk-test",
    model_default: "default-alias",
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
  )
}

fn stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(1),
    duration_ms: 2,
    token_deltas: 1,
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

fn happy_runner(
  _cfg,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  session.StreamDone(stats(), transcript.append_assistant(tr, "hi"))
}

/// A turn shaped like the real agent loop: one assistant message with
/// text AND two tool calls, tool results, then the final answer.
fn tool_round_runner(
  _cfg,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.ToolCallAssembled("call_a", "http_fetch", args_a))
  on_event(loop.ToolCallAssembled("call_b", "web_search", args_b))
  on_event(loop.ToolResultEvent("call_a", "http_fetch", True, "fetched body"))
  on_event(loop.ToolResultEvent("call_b", "web_search", True, "search body"))
  let tr =
    tr
    |> transcript.append_assistant_tool_calls(text: Some("checking"), calls: [
      #("call_a", "http_fetch", args_a),
      #("call_b", "web_search", args_b),
    ])
    |> transcript.append_tool_result("call_a", "fetched body")
    |> transcript.append_tool_result("call_b", "search body")
    |> transcript.append_assistant("all done")
  session.StreamDone(stats(), tr)
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
  |> transcript.append_assistant_tool_calls(text: Some("checking"), calls: [
    #("call_a", "http_fetch", args_a),
    #("call_b", "web_search", args_b),
  ])
  |> transcript.append_tool_result("call_a", "fetched body")
  |> transcript.append_tool_result("call_b", "search body")
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
    |> transcript.append_assistant_tool_calls(text: None, calls: [
      #("c1", "web_search", args_b),
    ])
    |> transcript.append_tool_result("c1", "r")
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

// ---------------------------------------------------------------------------
// Registry + functional mock store
// ---------------------------------------------------------------------------

type Boot {
  Boot(
    registry: Subject(session_registry.Msg),
    registry_pid: Pid,
    factory_pid: Pid,
  )
}

/// Boot a factory + registry over a given store seam, keeping the pids so
/// a test can tear the whole "VM" down while the store survives.
fn boot(seam: store.Store) -> Boot {
  // Sessions created through the registry pin the fixture provider.
  store_mock.ensure_fixture_provider(seam)
  let factory_name = process.new_name("nexus_persist_factory")
  let registry_name = process.new_name("nexus_persist_registry")
  let assert Ok(factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let assert Ok(started) =
    session_registry.start_with_runner(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      registry_name,
      seam,
      tool_round_runner,
    )
  Boot(
    registry: started.data,
    registry_pid: started.pid,
    factory_pid: factory.pid,
  )
}

/// Simulate a whole-VM restart: the registry and its session factory die;
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

fn create(
  registry: Subject(session_registry.Msg),
  model: String,
  runner: session.TurnRunner,
) -> session_registry.SessionRecord {
  let assert Ok(record) =
    session_registry.create_with_runner(
      registry,
      store_mock.fixture_provider_id,
      model,
      runner,
    )
  record
}

/// Run one turn and wait for its commit to land in the store.
fn run_turn(
  subject: Subject(session.Msg),
  text: String,
  mock: Subject(store_mock.MockMsg),
  commits_before: Int,
) -> Nil {
  should.equal(session.send_message(subject, text), session.Sent)
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
    transcript.request_body(session.snapshot(record.subject), loop_options()),
  )
}

pub fn metadata_writes_through_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let booted = boot(seam)
  let record = create(booted.registry, "alias-1", happy_runner)

  // Auto-title applies once and is guarded in the store too.
  should.be_true(session_registry.auto_title(
    booted.registry,
    record.id,
    "first msg",
  ))
  should.be_false(session_registry.auto_title(
    booted.registry,
    record.id,
    "sneaky",
  ))
  should.be_true(session_registry.set_title(
    booted.registry,
    record.id,
    "renamed",
  ))
  should.be_true(
    session_registry.set_tags(booted.registry, record.id, ["work", "notes"]),
  )
  should.be_true(session_registry.set_pinned(booted.registry, record.id, True))
  should.be_true(session_registry.set_archived(booted.registry, record.id, True))

  // The store saw the same sequence (write-through), archive included.
  let events =
    store_mock.events(mock)
    |> list.filter(fn(event) {
      case event {
        store_mock.EvInsertSession(_)
        | store_mock.EvCommit(_, _)
        | store_mock.EvAutoTitle(_, _) -> True
        _ -> False
      }
    })
  should.equal(events, [
    store_mock.EvInsertSession(record.id),
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
    session_registry.list_sessions(booted2.registry)
    |> list.find(fn(summary) { summary.id == record.id })
  should.equal(summary.title, "renamed")
  should.equal(summary.title_source, session.ManualTitle)
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
  should.be_true(session_registry.auto_title(
    booted.registry,
    record.id,
    "first question",
  ))

  run_turn(record.subject, "first question", mock, 0)
  run_turn(record.subject, "second question", mock, 2)
  let opts = loop_options()
  let body_before =
    transcript.request_body(session.snapshot(record.subject), opts)

  // ---- the "VM" restarts; only the store survives ---------------------
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))

  // The session is listed from the store (dormant), with its stored
  // metadata and message count (turn 1: 6 messages; turn 2 adds 5).
  let summaries = session_registry.list_sessions(booted2.registry)
  should.equal(list.length(summaries), 1)
  let assert Ok(summary) = list.first(summaries)
  should.equal(summary.id, record.id)
  should.equal(summary.model, "alias-1")
  should.equal(summary.title, "first question")
  should.equal(summary.message_count, 11)
  should.be_false(summary.streaming)
  should.equal(summary.metrics, [])

  // Lazily start it: the first Get hydrates from the store.
  let assert Ok(subject2) = session_registry.get(booted2.registry, record.id)
  let snapshot2 = session.snapshot(subject2)
  should.equal(transcript.model(snapshot2), "alias-1")
  // BYTE-IDENTICAL across the restart — the KV-cache contract.
  let body_after = transcript.request_body(snapshot2, opts)
  should.equal(body_after, body_before)

  // Continuing the session grows the body by suffix only.
  should.equal(session.send_message(subject2, "third question"), session.Sent)
  store_mock.await_commits(mock, 6)
  let body_next = transcript.request_body(session.snapshot(subject2), opts)
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
  // Pre-populate the "database" with two stored sessions.
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(_) = seam.insert_session(stored("s1"), "sys-1")
  let assert Ok(_) = seam.insert_session(stored("s2"), "sys-2")

  let booted = boot(seam)
  let summaries = session_registry.list_sessions(booted.registry)
  should.equal(summaries |> list.map(fn(summary) { summary.id }), ["s1", "s2"])

  // The first Get hydrates; the second returns the SAME actor (one
  // session, one commit lane: both sends' commits land on the one id,
  // and the snapshot grows monotonically).
  let assert Ok(subject_a) = session_registry.get(booted.registry, "s2")
  let assert Ok(subject_b) = session_registry.get(booted.registry, "s2")
  should.equal(session.send_message(subject_a, "hi"), session.Sent)
  should.equal(session.send_message(subject_b, "again"), session.Sent)
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
  should.equal(transcript.length(session.snapshot(subject_a)), 11)
  should.equal(transcript.length(session.snapshot(subject_b)), 11)

  // A fresh create mints past the stored ids: s3, not a collision.
  let created = create(booted.registry, "alias-x", happy_runner)
  should.equal(created.id, "s3")
}

fn stored(id: String) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: store_mock.fixture_provider_id,
    // Manually titled: a dormant row the boot sweep must KEEP (a rename
    // is user intent, unlike a never-used empty). message_count stays 1 —
    // system prompt only, consistent with the empty row list.
    title: "stored",
    title_source: session.ManualTitle,
    model: "alias-1",
    pinned: False,
    archived: False,
    tags: [],
    created_at: timing.wall_now_s(),
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
  let snapshot = session.snapshot(record.subject)

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
  let snapshot = session.snapshot(record.subject)

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
  let assert Ok(_) = seam.insert_session(stored("s99"), "sys")
  let booted = boot(seam)
  let live = create(booted.registry, "alias-1", happy_runner)

  // Deleting a dormant session (no live actor) removes the stored row.
  should.be_true(session_registry.delete_session(booted.registry, "s99"))
  should.equal(seam.get_session("s99") |> result_is_error, True)

  // Deleting a live one stops the actor and removes the row + records.
  run_turn(live.subject, "hello", mock, 0)
  should.be_true(session_registry.delete_session(booted.registry, live.id))
  should.equal(seam.get_session(live.id) |> result_is_error, True)
  should.equal(store_mock.rows(mock), [])

  // And it stays gone across a restart.
  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  should.equal(session_registry.list_sessions(booted2.registry), [])
  should.equal(session_registry.get(booted2.registry, live.id), Error(Nil))
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
  let assert Ok(_) = seam.insert_session(stored("s1"), "sys")
  let booted = boot(seam)

  // Metadata mutations on a DORMANT session apply to the stored row and
  // are visible to the next boot — no live actor needed.
  should.be_true(session_registry.set_title(booted.registry, "s1", "named"))
  should.be_true(session_registry.set_tags(booted.registry, "s1", ["a"]))
  should.be_true(session_registry.set_pinned(booted.registry, "s1", True))

  restart_vm(booted)
  let booted2 = boot(store_mock.seam(mock))
  let assert Ok(summary) =
    session_registry.list_sessions(booted2.registry)
    |> list.find(fn(summary) { summary.id == "s1" })
  should.equal(summary.title, "named")
  should.equal(summary.title_source, session.ManualTitle)
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
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let started =
    session_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_broken_registry"),
      broken,
    )
  case started {
    Ok(_) -> panic as "registry must not start with an unreachable store"
    Error(_) -> Nil
  }
}
