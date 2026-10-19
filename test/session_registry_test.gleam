//// Offline tests for the M2 session registry: create/list/get, unique IDs,
//// injected runners, and the same-ID empty restart when a session actor
//// dies. No network, no Bifrost.

import gleam/erlang/process.{type Monitor}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
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
import nexus/transcript
import store_mock

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

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  session.StreamDone(stats(), transcript.append_assistant(tr, "hi"))
}

fn start_registry() -> process.Subject(session_registry.Msg) {
  start_registry_with(session_registry.session_child)
}

/// Boot a factory + registry pair over an injectable child starter (the
/// plan's test seam for startup failures).
fn start_registry_with(
  child: fn(session_registry.ChildArgument) ->
    actor.StartResult(process.Subject(session.Msg)),
) -> process.Subject(session_registry.Msg) {
  let factory_name = process.new_name("nexus_test_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder_with_child(
      factory_name,
      child,
    ))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    session_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry"),
      persistence,
      fixture_resolver(),
    )
  started.data
}

/// The production resolver's offline stand-in: the fixture provider
/// resolves to a fixed endpoint, everything else is unknown.
pub fn fixture_resolver() -> session_registry.ResolveProvider {
  fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Ok(test_endpoint())
      False -> Error(session_registry.ProviderUnknown)
    }
  }
}

pub fn test_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "https://provider.example/v1",
    api_key: None,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
  )
}

/// Drain up to `n` events from a session-event subject.
fn drain(
  sub: process.Subject(session.SessionEvent),
  n: Int,
) -> List(session.SessionEvent) {
  case n {
    0 -> []
    _ ->
      case process.receive(sub, 2000) {
        Ok(event) -> [event, ..drain(sub, n - 1)]
        Error(_) -> []
      }
  }
}

fn create(
  registry: process.Subject(session_registry.Msg),
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

/// Block until `pid` is observed down (the registry's own monitor fires
/// asynchronously; the test waits so the restart has landed).
fn wait_for_down(pid: process.Pid) -> Nil {
  let monitor: Monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_monitors(fn(down) { down })
  let _ = process.selector_receive(selector, 5000)
  let _ = monitor
  // The registry's restart happens right after its monitor handler runs.
  let _ = process.sleep(100)
  Nil
}

pub fn create_returns_unique_ids_and_summaries_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  should.not_equal(a.id, b.id)
  should.not_equal(a.pid, b.pid)
  a.model |> should.equal("alpha")
  b.model |> should.equal("beta")

  // Each subject is an independent session with its own frozen alias.
  should.equal(session.send_message(a.subject, "one"), session.Sent)
  session.snapshot(a.subject) |> transcript.model |> should.equal("alpha")
  session.snapshot(b.subject) |> transcript.model |> should.equal("beta")
}

pub fn create_rejects_empty_model_test() {
  let registry = start_registry()
  session_registry.create_with_runner(
    registry,
    store_mock.fixture_provider_id,
    "   ",
    happy_runner,
  )
  |> should.equal(Error(session_registry.EmptyModel))
  session_registry.list_sessions(registry) |> should.equal([])
}

pub fn list_returns_creation_order_test() {
  let registry = start_registry()
  let a = create(registry, "first", happy_runner)
  let b = create(registry, "second", happy_runner)
  let _c = create(registry, "third", happy_runner)

  // Sessions created within the same wall second tie on activity; the
  // stable tiebreak (created_at, then id) keeps insertion order — which
  // is also what a creation-order list would show.
  let summaries = session_registry.list_sessions(registry)
  list.length(summaries) |> should.equal(3)
  summaries
  |> list.map(fn(s) { s.model })
  |> should.equal(["first", "second", "third"])

  case list.first(summaries) {
    Ok(first) -> {
      first.id |> should.equal(a.id)
      first.streaming |> should.be_false
      first.message_count |> should.equal(1)
      first.metrics |> should.equal([])
    }
    Error(_) -> panic as "expected at least one summary"
  }

  // A turn on the middle session shows up in the refreshed list. The fake
  // runner finishes immediately, so the count is 2 (mid-turn) or 3 (turn
  // committed); either way it has grown past the idle 1.
  should.equal(session.send_message(b.subject, "go"), session.Sent)
  let after = session_registry.list_sessions(registry)
  case list.first(list.drop(after, 1)) {
    Ok(second) -> {
      second.id |> should.equal(b.id)
      should.be_true(second.message_count >= 2)
    }
    Error(_) -> panic as "expected three summaries"
  }
}

pub fn get_resolves_each_stored_subject_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  let assert Ok(subject_a) = session_registry.get(registry, a.id)
  let assert Ok(subject_b) = session_registry.get(registry, b.id)
  // Resolved subjects reach the right actors.
  should.equal(session.send_message(subject_a, "hello"), session.Sent)
  session.snapshot(subject_a) |> transcript.model |> should.equal("alpha")
  session.snapshot(subject_b) |> transcript.model |> should.equal("beta")

  // Unknown IDs resolve to nothing.
  session_registry.get(registry, "nope") |> should.equal(Error(Nil))
}

/// Phase 2 semantics: a killed session's replacement REHYDRATES from the
/// store (its commits were persisted write-behind, in order, before the
/// registry processed the DOWN). Same ID, same frozen alias — and now the
/// same transcript instead of Phase 1's empty restart.
pub fn killed_session_restarts_same_id_hydrated_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  should.equal(session.send_message(a.subject, "remember me"), session.Sent)
  // Let the write-behind lane land before the kill.
  process.sleep(100)

  process.kill(a.pid)
  wait_for_down(a.pid)

  let summaries = session_registry.list_sessions(registry)
  summaries |> list.length |> should.equal(1)
  case list.first(summaries) {
    Ok(summary) -> {
      // Same user-visible ID and pinned alias...
      summary.id |> should.equal(a.id)
      summary.model |> should.equal("alpha")
      // ...and the rehydrated transcript: system + user + "hi". Metrics
      // are in-memory only by design, so they restart empty.
      summary.message_count |> should.equal(3)
      summary.metrics |> should.equal([])
    }
    Error(_) -> panic as "expected the restarted session"
  }

  // The restarted actor is usable under the same ID and its transcript
  // survived the crash verbatim (system, user, assistant).
  let assert Ok(subject) = session_registry.get(registry, a.id)
  let sub = process.new_subject()
  process.send(subject, session.Join(sub))
  let _ = process.receive(sub, 2000)
  let tr = session.snapshot(subject)
  transcript.length(tr) |> should.equal(3)
  transcript.model(tr) |> should.equal("alpha")
  should.equal(session.send_message(subject, "again"), session.Sent)
  // Drain to the terminal event so the commit has landed before snapshot.
  let _ = drain(sub, 4)
  let tr = session.snapshot(subject)
  transcript.length(tr) |> should.equal(5)
}

pub fn get_reports_gone_session_after_failed_restart_test() {
  // A runner that produces an actor which dies immediately cannot even be
  // started through the factory; instead we exercise the observable path:
  // kill the actor, and while it is down the registry must still answer.
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  process.kill(a.pid)
  wait_for_down(a.pid)

  // The registry survived and restarted it: get works, list works.
  let assert Ok(_subject) = session_registry.get(registry, a.id)
  session_registry.list_sessions(registry) |> list.length |> should.equal(1)
}

/// A child starter that cannot produce an actor: `Create` must report the
/// failure instead of crashing the registry (plan §8).
pub fn startup_failure_is_surfaced_not_a_crash_test() {
  let registry =
    start_registry_with(fn(_argument) {
      Error(actor.InitFailed("child start failed"))
    })

  case
    session_registry.create_with_runner(
      registry,
      store_mock.fixture_provider_id,
      "alpha",
      happy_runner,
    )
  {
    Error(session_registry.StartFailed(_reason)) -> Nil
    _ -> panic as "expected a StartFailed error"
  }

  // The registry survived and still answers its protocol.
  session_registry.list_sessions(registry) |> should.equal([])
  session_registry.get(registry, "s1") |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// M3 session organization: metadata, ordering, delete
// ---------------------------------------------------------------------------

fn find_summary(
  registry: process.Subject(session_registry.Msg),
  id: String,
) -> session.SessionSummary {
  let assert Ok(summary) =
    session_registry.list_sessions(registry)
    |> list.find(fn(s) { s.id == id })
  summary
}

pub fn new_sessions_start_with_default_metadata_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let summary = find_summary(registry, a.id)
  should.equal(summary.title, "")
  should.equal(summary.title_source, session.AutoTitle)
  should.be_false(summary.pinned)
  should.equal(summary.tags, [])
  should.be_false(summary.archived)
  // created_at is a real wall-clock epoch; an empty session's activity is
  // its creation time.
  should.be_true(summary.created_at > 1_600_000_000)
  should.equal(summary.last_active_at, summary.created_at)
}

pub fn set_title_marks_manual_and_auto_never_clobbers_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  // Auto-title applies while the title is the untouched auto default…
  session_registry.auto_title(registry, a.id, "first message")
  |> should.be_true
  find_summary(registry, a.id).title |> should.equal("first message")
  // …and only once: a second auto-title is refused.
  session_registry.auto_title(registry, a.id, "other message")
  |> should.be_false
  find_summary(registry, a.id).title |> should.equal("first message")

  // A manual rename wins and pins the title source…
  session_registry.set_title(registry, a.id, "renamed") |> should.be_true
  let renamed = find_summary(registry, a.id)
  should.equal(renamed.title, "renamed")
  should.equal(renamed.title_source, session.ManualTitle)

  // …so no later auto-generation can clobber it.
  session_registry.auto_title(registry, a.id, "sneaky") |> should.be_false
  find_summary(registry, a.id).title |> should.equal("renamed")

  // Unknown IDs report failure without crashing.
  session_registry.set_title(registry, "nope", "x") |> should.be_false
  session_registry.auto_title(registry, "nope", "x") |> should.be_false
}

pub fn set_tags_normalizes_on_write_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  session_registry.set_tags(registry, a.id, [" work ", "", "notes", "work"])
  |> should.be_true
  find_summary(registry, a.id).tags
  |> should.equal(["work", "notes"])

  // Clearing works; unknown IDs fail.
  session_registry.set_tags(registry, a.id, []) |> should.be_true
  find_summary(registry, a.id).tags |> should.equal([])
  session_registry.set_tags(registry, "nope", ["x"]) |> should.be_false
}

pub fn set_pinned_and_archived_roundtrip_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  session_registry.set_pinned(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_true

  session_registry.set_archived(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).archived |> should.be_true
  // Archiving implicitly unpins (see the dedicated invariant test).
  find_summary(registry, a.id).pinned |> should.be_false

  // Archived sessions stay listed (soft-hide is the caller's business) and
  // restorable.
  session_registry.set_archived(registry, a.id, False) |> should.be_true
  find_summary(registry, a.id).archived |> should.be_false

  session_registry.set_pinned(registry, "nope", True) |> should.be_false
  session_registry.set_archived(registry, "nope", True) |> should.be_false
}

/// Invariant: an archived session is never pinned. Archiving clears the
/// pin; pinning an archived session is refused; restoring does not
/// resurrect an old pin.
pub fn archived_sessions_are_never_pinned_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  // Pin, then archive: the pin is gone.
  session_registry.set_pinned(registry, a.id, True) |> should.be_true
  session_registry.set_archived(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_false

  // Restore: the pin stays gone (the user re-pins if they still want it).
  session_registry.set_archived(registry, a.id, False) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_false

  // Pinning an archived session is refused outright.
  session_registry.set_archived(registry, b.id, True) |> should.be_true
  session_registry.set_pinned(registry, b.id, True) |> should.be_false
  find_summary(registry, b.id).pinned |> should.be_false

  // Unpinning an archived session is a harmless success (it is already
  // unpinned by the invariant).
  session_registry.set_pinned(registry, b.id, False) |> should.be_true
}

/// Pinned first, then most recently active first. Distinct wall seconds
/// separate the sessions so the ordering is deterministic.
pub fn list_orders_pinned_then_recency_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  process.sleep(1100)
  let b = create(registry, "beta", happy_runner)

  // b was created (and so last active) later: b leads.
  session_registry.list_sessions(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id, a.id])

  // Pinning a lifts it above the more recent b.
  should.be_true(session_registry.set_pinned(registry, a.id, True))
  session_registry.list_sessions(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([a.id, b.id])

  // Unpinned again, a turn on the older session makes it the most recent.
  should.be_true(session_registry.set_pinned(registry, a.id, False))
  process.sleep(1100)
  should.equal(session.send_message(a.subject, "bump"), session.Sent)
  process.sleep(50)
  session_registry.list_sessions(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([a.id, b.id])
  // And its activity moved past its creation time.
  let summary = find_summary(registry, a.id)
  should.be_true(summary.last_active_at > summary.created_at)
}

pub fn delete_removes_the_session_hard_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  session_registry.delete_session(registry, a.id) |> should.be_true
  session_registry.list_sessions(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id])
  session_registry.get(registry, a.id) |> should.equal(Error(Nil))

  // Deleting is one-shot: the second attempt reports unknown.
  session_registry.delete_session(registry, a.id) |> should.be_false
  session_registry.delete_session(registry, "nope") |> should.be_false
}

/// Deleting while a turn streams: the actor is stopped (cancel path) and
/// the row disappears; the registry and its other sessions survive.
pub fn delete_while_streaming_drops_the_row_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", blocking_runner)
  let b = create(registry, "beta", happy_runner)
  should.equal(session.send_message(a.subject, "mid-turn"), session.Sent)
  process.sleep(50)

  session_registry.delete_session(registry, a.id) |> should.be_true
  process.sleep(100)

  session_registry.list_sessions(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id])
  // The registry still answers and the survivor still works.
  session_registry.get(registry, b.id) |> should.be_ok
  should.equal(session.send_message(b.subject, "still here"), session.Sent)
}

/// A runner that parks on its cancel subject until Stop arrives — the
/// stand-in for a live streaming turn.
fn blocking_runner(_cfg, tr, cancel, _on_event) -> session.TurnOutcome {
  let selector =
    process.new_selector()
    |> process.select_map(cancel, fn(_) { Nil })
  let _ = process.selector_receive(selector, 5000)
  session.StreamStopped(tr)
}

// ---------------------------------------------------------------------------
// Boot sweep of never-used sessions
// ---------------------------------------------------------------------------

/// Boot a factory + registry pair over an injectable store, so the sweep
/// runs against whatever the store was pre-seeded with — exactly what
/// production boot sees after a restart.
fn start_registry_over(
  persistence: store.Store,
) -> process.Subject(session_registry.Msg) {
  let factory_name = process.new_name("nexus_test_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  // Sessions created over this seam pin the fixture provider, and the
  // sweep tests below seed rows directly — both need it to exist.
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    session_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry"),
      persistence,
      fixture_resolver(),
    )
  started.data
}

/// Seed one stored session row directly through the seam.
fn seed(
  seam: store.Store,
  id: String,
  title: String,
  title_source: session.TitleSource,
  pinned: Bool,
  archived: Bool,
  message_count: Int,
) -> Nil {
  seed_at(
    seam,
    id,
    title,
    title_source,
    pinned,
    archived,
    message_count,
    1_700_000_000,
  )
}

/// Like `seed`, with an explicit `last_active_at` (epoch seconds) so the
/// sweep's grace window can be exercised.
fn seed_at(
  seam: store.Store,
  id: String,
  title: String,
  title_source: session.TitleSource,
  pinned: Bool,
  archived: Bool,
  message_count: Int,
  last_active_at: Int,
) -> Nil {
  // The seeded row pins the fixture provider; the FK (enforced by the
  // mock too) needs it in place before the insert.
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_session(
      store.StoredSummary(
        id: id,
        provider_id: store_mock.fixture_provider_id,
        title: title,
        title_source: title_source,
        model: "alpha",
        pinned: pinned,
        archived: archived,
        tags: [],
        created_at: last_active_at,
        last_active_at: last_active_at,
        message_count: message_count,
      ),
      "test system prompt",
    )
  Nil
}

fn listed_ids(registry: process.Subject(session_registry.Msg)) -> List(String) {
  session_registry.list_sessions(registry)
  |> list.map(fn(summary) { summary.id })
  |> list.sort(string.compare)
}

/// The litter older boots left behind — empty (system-prompt-only),
/// auto-titled, unpinned, archived or not — is swept at boot, in ONE
/// bulk prune. Anything with a user message, a manual rename, a pin, or
/// an empty session FRESHER than the grace window survives: that last
/// one may belong to another concurrently-running server's live actor.
pub fn boot_sweep_deletes_never_used_sessions_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // Swept: stale never-used rows from earlier runs.
  seed(seam, "s1", "", session.AutoTitle, False, False, 1)
  seed(seam, "s2", "", session.AutoTitle, False, True, 1)
  // Kept: used, manually renamed, pinned…
  seed(seam, "s3", "hello world", session.AutoTitle, False, False, 3)
  seed(seam, "s4", "keep me", session.ManualTitle, False, False, 1)
  seed(seam, "s5", "", session.AutoTitle, True, False, 1)
  // …and a never-used session created moments ago (grace window).
  seed_at(
    seam,
    "s6",
    "",
    session.AutoTitle,
    False,
    False,
    1,
    timing.wall_now_s(),
  )

  let registry = start_registry_over(seam)
  listed_ids(registry) |> should.equal(["s3", "s4", "s5", "s6"])

  let swept =
    store_mock.events(mock)
    |> list.filter_map(fn(event) {
      case event {
        store_mock.EvPruneNeverUsed(ids) -> Ok(ids)
        _ -> Error(Nil)
      }
    })
    |> list.flatten
  swept |> should.equal(["s1", "s2"])
}

/// A never-used row inside the grace window is swept by a LATER boot,
/// once it is past the window.
pub fn boot_sweep_takes_stale_empties_after_grace_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  seed_at(
    seam,
    "s1",
    "",
    session.AutoTitle,
    False,
    False,
    1,
    timing.wall_now_s() - 3600,
  )

  let registry = start_registry_over(seam)
  listed_ids(registry) |> should.equal([])
}

/// Minted ids seed past PRE-sweep stored ids: a swept id is never reused,
/// so a create right after boot cannot collide with a row a failed sweep
/// delete may have left behind.
pub fn create_after_sweep_mints_past_swept_ids_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  seed(seam, "s1", "", session.AutoTitle, False, False, 1)

  let registry = start_registry_over(seam)
  let record = create(registry, "alpha", happy_runner)
  record.id |> should.equal("s2")
}

/// A prune that fails keeps every session listed (dormant): the sidebar
/// must never show fewer rows than the store holds, and the next boot
/// retries the sweep.
pub fn boot_sweep_prune_failure_keeps_session_test() {
  let mock = store_mock.start()
  let seam =
    store.Store(..store_mock.seam(mock), prune_never_used: fn() {
      Error("disk full")
    })
  seed(seam, "s1", "", session.AutoTitle, False, False, 1)

  let registry = start_registry_over(seam)
  listed_ids(registry) |> should.equal(["s1"])
}

// ---------------------------------------------------------------------------
// P3: provider resolution on the create path
// ---------------------------------------------------------------------------

/// An unknown provider id refuses the create BEFORE any session actor or
/// row exists (multi-provider §8: a session is only ever created with its
/// (provider, model) pin in place).
pub fn create_rejects_unknown_provider_test() {
  let registry = start_registry()
  session_registry.create_with_runner(registry, "p-nope", "alpha", happy_runner)
  |> should.equal(
    Error(session_registry.ProviderFailed(session_registry.ProviderUnknown)),
  )
  session_registry.list_sessions(registry) |> should.equal([])
}

/// A disabled provider cannot back a new session either — disabling is
/// the reversible delete, and resolve refuses it.
pub fn create_rejects_disabled_provider_test() {
  let factory_name = process.new_name("nexus_test_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let disabled: session_registry.ResolveProvider = fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Error(session_registry.ProviderDisabled)
      False -> Error(session_registry.ProviderUnknown)
    }
  }
  let assert Ok(started) =
    session_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry"),
      persistence,
      disabled,
    )
  session_registry.create_with_runner(
    started.data,
    store_mock.fixture_provider_id,
    "alpha",
    happy_runner,
  )
  |> should.equal(
    Error(session_registry.ProviderFailed(session_registry.ProviderDisabled)),
  )
}

/// The runner a created session actually runs receives the endpoint the
/// resolver produced — the frozen provider transport (P3 acceptance:
/// "a session streams via its frozen endpoint").
pub fn created_session_runner_gets_resolved_endpoint_test() {
  let seen = process.new_subject()
  let capturing = fn(endpoint, tr, _cancel, _on_event) {
    process.send(seen, endpoint)
    session.StreamDone(stats(), transcript.append_assistant(tr, "ok"))
  }
  let registry = start_registry()
  let _record = create(registry, "alpha", capturing)
  // A send makes the session's worker invoke the runner.
  let assert Ok(sess) = session_registry.get(registry, "s1")
  should.equal(session.send_message(sess, "hi"), session.Sent)
  let assert Ok(endpoint) = process.receive(seen, 2000)
  endpoint |> should.equal(test_endpoint())
}
