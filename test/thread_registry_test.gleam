//// Offline tests for the M2 thread registry: create/list/get, unique IDs,
//// injected runners, and the same-ID empty restart when a thread actor
//// dies. No network, no Bifrost.

import gleam/erlang/process.{type Monitor}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import nexus/bot
import nexus/bot_registry
import nexus/config
import nexus/loop
import nexus/openai
import nexus/provider_registry
import nexus/store
import nexus/thread
import nexus/thread_create
import nexus/thread_registry
import nexus/timing
import nexus/tools
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
    // These suites boot the registry via `start`, whose real utility
    // runner would stream from a network endpoint once a debounce fired —
    // and they never assert on the side call. Keep the feature off so
    // `gleam test` stays strictly offline/network-free (AGENTS.md).
    utility_enabled: False,
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

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  thread.StreamDone(stats(), transcript.append_assistant(tr, "hi"))
}

fn start_registry() -> process.Subject(thread_registry.Msg) {
  start_registry_with(thread_registry.thread_child)
}

/// Boot a factory + registry pair over an injectable child starter (the
/// plan's test seam for startup failures).
fn start_registry_with(
  child: fn(thread_registry.ChildArgument) ->
    actor.StartResult(process.Subject(thread.Msg)),
) -> process.Subject(thread_registry.Msg) {
  start_registry_keeping_seam_with(child, store_mock.seam(store_mock.start())).0
}

/// The production resolver's offline stand-in: the fixture provider
/// resolves to a fixed endpoint, everything else is unknown.
pub fn fixture_resolver() -> thread_registry.ResolveProvider {
  fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Ok(test_endpoint())
      False -> Error(thread_registry.ProviderUnknown)
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

/// Drain up to `n` events from a thread-event subject.
fn drain(
  sub: process.Subject(thread.ThreadEvent),
  n: Int,
) -> List(thread.ThreadEvent) {
  case n {
    0 -> []
    _ ->
      case process.receive(sub, 2000) {
        Ok(event) -> [event, ..drain(sub, n - 1)]
        Error(_) -> []
      }
  }
}

/// What a create hands the tests: the fresh summary's display fields plus
/// the live actor's identity (subject resolved through the registry, pid
/// derived from it — the create reply is a `ThreadSummary` now).
type Created {
  Created(
    id: String,
    model: String,
    subject: process.Subject(thread.Msg),
    pid: process.Pid,
  )
}

fn create(
  registry: process.Subject(thread_registry.Msg),
  model: String,
  runner: thread.TurnRunner,
) -> Created {
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      new_thread(store_mock.fixture_provider_id, model),
      toolset(runner),
    )
  let assert Ok(subject) = thread_registry.get(registry, summary.id)
  let assert Ok(pid) = process.subject_owner(subject)
  Created(id: summary.id, model: summary.model, subject: subject, pid: pid)
}

/// The common creation request shape: pin provider + model,
/// config-default prompt.
fn new_thread(provider_id: String, model: String) -> thread_registry.NewThread {
  thread_registry.NewThread(
    provider_id: provider_id,
    model: model,
    system_prompt: None,
    toolset: None,
    bot_id: None,
  )
}

/// Wrap a fake turn runner in the toolset bundle the create seam now
/// carries (#76): the default specs of the test config, named by their
/// own wire names. The utility side refuses — no test here expects a
/// utility call from an injected runner.
fn toolset(runner: thread.TurnRunner) -> thread.Toolset {
  let specs = tools.default(test_config())
  thread.Toolset(
    names: list.map(specs, tools.tool_name),
    specs: specs,
    runner: runner,
    utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
      Error("no utility call in this test")
    },
  )
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

  // Each subject is an independent thread with its own frozen alias.
  should.equal(thread.send_message(a.subject, "one"), thread.Sent)
  thread.snapshot(a.subject) |> transcript.model |> should.equal("alpha")
  thread.snapshot(b.subject) |> transcript.model |> should.equal("beta")
}

pub fn create_rejects_empty_model_test() {
  let registry = start_registry()
  thread_registry.create_with_toolset(
    registry,
    new_thread(store_mock.fixture_provider_id, "   "),
    toolset(happy_runner),
  )
  |> should.equal(Error(thread_registry.EmptyModel))
  thread_registry.list_threads(registry) |> should.equal([])
}

pub fn list_returns_creation_order_test() {
  let registry = start_registry()
  let a = create(registry, "first", happy_runner)
  let b = create(registry, "second", happy_runner)
  let _c = create(registry, "third", happy_runner)

  // Order under ties: threads created within the same wall second tie on
  // activity and list in creation order — but the creates cannot be
  // guaranteed to share one wall second on a loaded machine (the sort is
  // most-recently-active first), so this test asserts the list's MEMBERS
  // and per-thread fields, not positions. Regression (2026-11-08 CI): a
  // run where the creates and the turn below straddled a wall-second
  // boundary reordered the recency-sorted list and failed a positional
  // assert here.
  let summaries = thread_registry.list_threads(registry)
  list.length(summaries) |> should.equal(3)
  summaries
  |> list.map(fn(s) { s.model })
  |> list.sort(string.compare)
  |> should.equal(["first", "second", "third"])

  let assert Ok(first) = list.find(summaries, fn(s) { s.id == a.id })
  first.streaming |> should.be_false
  first.message_count |> should.equal(1)
  first.metrics |> should.equal([])

  // A turn on the middle thread shows up in the refreshed list. The fake
  // runner finishes immediately, so the count is 2 (mid-turn) or 3 (turn
  // committed); either way it has grown past the idle 1. The commit also
  // moves b's activity — possibly into a newer wall second than the
  // creates, which legitimately reorders the recency-sorted list — so the
  // refreshed thread is found by ID, not by position.
  should.equal(thread.send_message(b.subject, "go"), thread.Sent)
  let after = thread_registry.list_threads(registry)
  // The refresh must not have dropped anything: all three threads are
  // still listed (found by ID below, position-free).
  list.length(after) |> should.equal(3)
  let assert Ok(second) = list.find(after, fn(s) { s.id == b.id })
  should.be_true(second.message_count >= 2)
}

pub fn get_resolves_each_stored_subject_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  let assert Ok(subject_a) = thread_registry.get(registry, a.id)
  let assert Ok(subject_b) = thread_registry.get(registry, b.id)
  // Resolved subjects reach the right actors.
  should.equal(thread.send_message(subject_a, "hello"), thread.Sent)
  thread.snapshot(subject_a) |> transcript.model |> should.equal("alpha")
  thread.snapshot(subject_b) |> transcript.model |> should.equal("beta")

  // Unknown IDs resolve to nothing.
  thread_registry.get(registry, "nope") |> should.equal(Error(Nil))
}

/// Phase 2 semantics: a killed thread's replacement REHYDRATES from the
/// store (its commits were persisted write-behind, in order, before the
/// registry processed the DOWN). Same ID, same frozen alias — and now the
/// same transcript instead of Phase 1's empty restart.
pub fn killed_thread_restarts_same_id_hydrated_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  should.equal(thread.send_message(a.subject, "remember me"), thread.Sent)
  // Let the write-behind lane land before the kill.
  process.sleep(100)

  process.kill(a.pid)
  wait_for_down(a.pid)

  let summaries = thread_registry.list_threads(registry)
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
    Error(_) -> panic as "expected the restarted thread"
  }

  // The restarted actor is usable under the same ID and its transcript
  // survived the crash verbatim (system, user, assistant).
  let assert Ok(subject) = thread_registry.get(registry, a.id)
  let sub = process.new_subject()
  process.send(subject, thread.Join(sub, 0))
  let _ = process.receive(sub, 2000)
  let tr = thread.snapshot(subject)
  transcript.length(tr) |> should.equal(3)
  transcript.model(tr) |> should.equal("alpha")
  should.equal(thread.send_message(subject, "again"), thread.Sent)
  // Drain to the terminal event so the commit has landed before snapshot.
  let _ = drain(sub, 4)
  let tr = thread.snapshot(subject)
  transcript.length(tr) |> should.equal(5)
}

pub fn get_reports_gone_thread_after_failed_restart_test() {
  // A runner that produces an actor which dies immediately cannot even be
  // started through the factory; instead we exercise the observable path:
  // kill the actor, and while it is down the registry must still answer.
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  process.kill(a.pid)
  wait_for_down(a.pid)

  // The registry survived and restarted it: get works, list works.
  let assert Ok(_subject) = thread_registry.get(registry, a.id)
  thread_registry.list_threads(registry) |> list.length |> should.equal(1)
}

/// A child starter that cannot produce an actor: `Create` must report the
/// failure instead of crashing the registry (plan §8).
pub fn startup_failure_is_surfaced_not_a_crash_test() {
  let registry =
    start_registry_with(fn(_argument) {
      Error(actor.InitFailed("child start failed"))
    })

  case
    thread_registry.create_with_toolset(
      registry,
      new_thread(store_mock.fixture_provider_id, "alpha"),
      toolset(happy_runner),
    )
  {
    Error(thread_registry.StartFailed(_reason)) -> Nil
    _ -> panic as "expected a StartFailed error"
  }

  // The registry survived and still answers its protocol.
  thread_registry.list_threads(registry) |> should.equal([])
  thread_registry.get(registry, "s1") |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// M3 thread organization: metadata, ordering, delete
// ---------------------------------------------------------------------------

fn find_summary(
  registry: process.Subject(thread_registry.Msg),
  id: String,
) -> thread.ThreadSummary {
  let assert Ok(summary) =
    thread_registry.list_threads(registry)
    |> list.find(fn(s) { s.id == id })
  summary
}

pub fn new_threads_start_with_default_metadata_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let summary = find_summary(registry, a.id)
  should.equal(summary.title, "")
  should.equal(summary.title_source, thread.AutoTitle)
  should.be_false(summary.pinned)
  should.equal(summary.tags, [])
  should.be_false(summary.archived)
  // created_at is a real wall-clock epoch; an empty thread's activity is
  // its creation time.
  should.be_true(summary.created_at > 1_600_000_000)
  should.equal(summary.last_active_at, summary.created_at)
}

pub fn set_title_marks_manual_and_auto_never_clobbers_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  // Auto-title applies while the title is the untouched auto default…
  thread_registry.auto_title(registry, a.id, "first message")
  |> should.be_true
  find_summary(registry, a.id).title |> should.equal("first message")
  // …and only once: a second auto-title is refused.
  thread_registry.auto_title(registry, a.id, "other message")
  |> should.be_false
  find_summary(registry, a.id).title |> should.equal("first message")

  // A manual rename wins and pins the title source…
  thread_registry.set_title(registry, a.id, "renamed") |> should.be_true
  let renamed = find_summary(registry, a.id)
  should.equal(renamed.title, "renamed")
  should.equal(renamed.title_source, thread.ManualTitle)

  // …so no later auto-generation can clobber it.
  thread_registry.auto_title(registry, a.id, "sneaky") |> should.be_false
  find_summary(registry, a.id).title |> should.equal("renamed")

  // Unknown IDs report failure without crashing.
  thread_registry.set_title(registry, "nope", "x") |> should.be_false
  thread_registry.auto_title(registry, "nope", "x") |> should.be_false
}

pub fn set_tags_normalizes_on_write_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  thread_registry.set_tags(registry, a.id, [" work ", "", "notes", "work"])
  |> should.be_true
  find_summary(registry, a.id).tags
  |> should.equal(["work", "notes"])

  // Clearing works; unknown IDs fail.
  thread_registry.set_tags(registry, a.id, []) |> should.be_true
  find_summary(registry, a.id).tags |> should.equal([])
  thread_registry.set_tags(registry, "nope", ["x"]) |> should.be_false
}

pub fn set_pinned_and_archived_roundtrip_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  thread_registry.set_pinned(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_true

  thread_registry.set_archived(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).archived |> should.be_true
  // Archiving implicitly unpins (see the dedicated invariant test).
  find_summary(registry, a.id).pinned |> should.be_false

  // Archived threads stay listed (soft-hide is the caller's business) and
  // restorable.
  thread_registry.set_archived(registry, a.id, False) |> should.be_true
  find_summary(registry, a.id).archived |> should.be_false

  thread_registry.set_pinned(registry, "nope", True) |> should.be_false
  thread_registry.set_archived(registry, "nope", True) |> should.be_false
}

/// Invariant: an archived thread is never pinned. Archiving clears the
/// pin; pinning an archived thread is refused; restoring does not
/// resurrect an old pin.
pub fn archived_threads_are_never_pinned_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  // Pin, then archive: the pin is gone.
  thread_registry.set_pinned(registry, a.id, True) |> should.be_true
  thread_registry.set_archived(registry, a.id, True) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_false

  // Restore: the pin stays gone (the user re-pins if they still want it).
  thread_registry.set_archived(registry, a.id, False) |> should.be_true
  find_summary(registry, a.id).pinned |> should.be_false

  // Pinning an archived thread is refused outright.
  thread_registry.set_archived(registry, b.id, True) |> should.be_true
  thread_registry.set_pinned(registry, b.id, True) |> should.be_false
  find_summary(registry, b.id).pinned |> should.be_false

  // Unpinning an archived thread is a harmless success (it is already
  // unpinned by the invariant).
  thread_registry.set_pinned(registry, b.id, False) |> should.be_true
}

/// Pinned first, then most recently active first. Distinct wall seconds
/// separate the threads so the ordering is deterministic.
pub fn list_orders_pinned_then_recency_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  process.sleep(1100)
  let b = create(registry, "beta", happy_runner)

  // b was created (and so last active) later: b leads.
  thread_registry.list_threads(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id, a.id])

  // Pinning a lifts it above the more recent b.
  should.be_true(thread_registry.set_pinned(registry, a.id, True))
  thread_registry.list_threads(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([a.id, b.id])

  // Unpinned again, a turn on the older thread makes it the most recent.
  should.be_true(thread_registry.set_pinned(registry, a.id, False))
  process.sleep(1100)
  should.equal(thread.send_message(a.subject, "bump"), thread.Sent)
  process.sleep(50)
  thread_registry.list_threads(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([a.id, b.id])
  // And its activity moved past its creation time.
  let summary = find_summary(registry, a.id)
  should.be_true(summary.last_active_at > summary.created_at)
}

pub fn delete_removes_the_thread_hard_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)
  let b = create(registry, "beta", happy_runner)

  thread_registry.delete_thread(registry, a.id) |> should.be_true
  thread_registry.list_threads(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id])
  thread_registry.get(registry, a.id) |> should.equal(Error(Nil))

  // Deleting is one-shot: the second attempt reports unknown.
  thread_registry.delete_thread(registry, a.id) |> should.be_false
  thread_registry.delete_thread(registry, "nope") |> should.be_false
}

/// Deleting while a turn streams: the actor is stopped (cancel path) and
/// the row disappears; the registry and its other threads survive.
pub fn delete_while_streaming_drops_the_row_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", blocking_runner)
  let b = create(registry, "beta", happy_runner)
  should.equal(thread.send_message(a.subject, "mid-turn"), thread.Sent)
  process.sleep(50)

  thread_registry.delete_thread(registry, a.id) |> should.be_true
  process.sleep(100)

  thread_registry.list_threads(registry)
  |> list.map(fn(s) { s.id })
  |> should.equal([b.id])
  // The registry still answers and the survivor still works.
  thread_registry.get(registry, b.id) |> should.be_ok
  should.equal(thread.send_message(b.subject, "still here"), thread.Sent)
}

/// A runner that parks on its cancel subject until Stop arrives — the
/// stand-in for a live streaming turn.
fn blocking_runner(_cfg, tr, cancel, _on_event) -> thread.TurnOutcome {
  let selector =
    process.new_selector()
    |> process.select_map(cancel, fn(_) { Nil })
  let _ = process.selector_receive(selector, 5000)
  thread.StreamStopped(tr)
}

// ---------------------------------------------------------------------------
// Utility-tags P4 (§5): model-tag merge, provenance guards, TagCorpus
// ---------------------------------------------------------------------------

/// Seed one stored (dormant) thread row carrying display tags — what
/// the corpus and merge tests fork from. `message_count` 3 keeps the
/// row out of the boot sweep (a used thread), and the row lands with
/// its auto path open (insert_thread defaults `tags_source` 'auto'),
/// exactly like a stored row this feature's era created.
fn seed_with_tags(seam: store.Store, id: String, tags: List(String)) -> Nil {
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        id: id,
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        meta: thread.ThreadMeta(
          title: "stored " <> id,
          title_source: thread.AutoTitle,
          pinned: False,
          archived: False,
          tags: tags,
          tags_manual: [],
          tags_source: thread.AutoTags,
          bot_id: None,
          created_at: 1_700_000_000,
        ),
        last_active_at: 1_700_000_000,
        toolset: tools.default_names(test_config()),
        message_count: 3,
      ),
      "test system prompt",
    )
  Nil
}

/// The model-metadata upgrade (§3.5): applies while BOTH provenance
/// columns are 'auto' — the title replaces the placeholder and the
/// attempt's tags land as the display set — and is refused WHOLE under
/// a manual title rename OR a manual tag edit: each closes its side
/// forever, and neither write of the one ask survives alone.
pub fn upgrade_applies_under_both_auto_guards_test() {
  let registry = start_registry()
  let a = create(registry, "alpha", happy_runner)

  // Both-auto: applied, fresh metadata in the reply.
  thread_registry.upgrade_auto_title(registry, a.id, "Model Title", [
    "login", "auth",
  ])
  |> should.equal(
    thread_registry.UpgradeApplied("Model Title", ["login", "auth"]),
  )
  let summary = find_summary(registry, a.id)
  should.equal(summary.title, "Model Title")
  should.equal(summary.title_source, thread.AutoTitle)
  should.equal(summary.tags, ["login", "auth"])

  // A manual title rename closes the title side: whole ask refused.
  let b = create(registry, "beta", happy_runner)
  should.be_true(thread_registry.set_title(registry, b.id, "renamed"))
  thread_registry.upgrade_auto_title(registry, b.id, "Sneaky", ["x"])
  |> should.equal(thread_registry.UpgradeRefused)
  let summary = find_summary(registry, b.id)
  should.equal(summary.title, "renamed")
  should.equal(summary.tags, [])

  // A manual tag edit closes the tags side: same refusal, even though
  // the title side is still auto.
  let c = create(registry, "gamma", happy_runner)
  should.be_true(thread_registry.set_tags(registry, c.id, ["mine"]))
  thread_registry.upgrade_auto_title(registry, c.id, "Sneaky", ["x"])
  |> should.equal(thread_registry.UpgradeRefused)
  let summary = find_summary(registry, c.id)
  should.equal(summary.title, "")
  should.equal(summary.tags, ["mine"])
}

/// The merge itself (§3.5), on a dormant row carrying LEGACY spellings:
/// existing display entries pass through VERBATIM in order, a canonical
/// twin of a legacy spelling is not a duplicate (the presence check
/// compares through the shared normalization), new tags append
/// normalized, and the union caps at 5 per thread.
pub fn upgrade_union_order_verbatim_and_cap_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  seed_with_tags(seam, "s1", ["Work Notes", "login"])
  let registry = start_registry_over(seam)

  thread_registry.upgrade_auto_title(registry, "s1", "Model Title", [
    "work-notes", "AUTH", "cache", "ops",
  ])
  |> should.equal(
    thread_registry.UpgradeApplied("Model Title", [
      "Work Notes", "login", "auth", "cache", "ops",
    ]),
  )
  // The cap: a later attempt's further tag cannot grow past five — the
  // existing order wins, the newcomer falls off.
  thread_registry.upgrade_auto_title(registry, "s1", "Retitled", ["extra"])
  |> should.equal(
    thread_registry.UpgradeApplied("Retitled", [
      "Work Notes", "login", "auth", "cache", "ops",
    ]),
  )
  find_summary(registry, "s1").tags
  |> should.equal(["Work Notes", "login", "auth", "cache", "ops"])
}

/// The review-caught P1 (§3.5): a manual `SetTags` racing an in-flight
/// apply refuses the apply. The worker forked while the row was
/// both-auto; the manual save lands FIRST (directly in the store,
/// behind the registry's memory); the worker's guarded write-through —
/// `tags_source` checked atomically by the SQL — is refused, and the
/// registry honors the refusal without mutating anything.
pub fn manual_tag_save_racing_in_flight_apply_refuses_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let registry = start_registry_over(seam)
  let a = create(registry, "alpha", happy_runner)

  // The manual save lands in the store behind the registry's back; its
  // in-memory record still says both-auto, exactly like an in-flight
  // worker that forked before the save.
  should.equal(seam.set_tags(a.id, ["mine"]), Ok(Nil))

  thread_registry.upgrade_auto_title(registry, a.id, "Model Title", [
    "model-tag",
  ])
  |> should.equal(thread_registry.UpgradeRefused)
  let summary = find_summary(registry, a.id)
  should.equal(summary.title, "")
  should.equal(summary.tags, [])
  // The store recorded the manual save and never an upgrade.
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvSetTags(id, _) -> id == a.id
      store_mock.EvAutoMetaUpgrade(_, _, _) -> True
      _ -> False
    }
  })
  |> should.equal([store_mock.EvSetTags(a.id, ["mine"])])
}

/// `SetTags` writes all three fields through (§3.5): the user's
/// (normalized) set becomes the display set AND the manual set, and the
/// row's auto path closes — `tags_source = 'manual'` — in one atomic
/// statement.
pub fn set_tags_writes_display_manual_and_source_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let registry = start_registry_over(seam)
  let a = create(registry, "alpha", happy_runner)

  should.be_true(
    thread_registry.set_tags(registry, a.id, [" Work ", "notes", "work"]),
  )
  find_summary(registry, a.id).tags |> should.equal(["work", "notes"])

  let assert Ok(stored) = seam.get_thread(a.id)
  should.equal(stored.summary.meta.tags, ["work", "notes"])
  should.equal(stored.summary.meta.tags_manual, ["work", "notes"])
  should.equal(stored.summary.meta.tags_source, thread.ManualTags)
  // The mock recorded exactly the normalized tags write.
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvSetTags(_, _) -> True
      _ -> False
    }
  })
  |> should.equal([store_mock.EvSetTags(a.id, ["work", "notes"])])
}

/// `SetTags` on a FAILING store write keeps the in-memory freeze (the
/// documented degrade mode, §3.5): the record says manual, the reply
/// says applied, and a later utility apply is still refused by the
/// in-memory twin check — the store is never consulted again. The
/// stale persisted row is harmless in this pass; the next manual save
/// re-attempts the triple-write and heals it.
pub fn set_tags_store_failure_keeps_in_memory_freeze_test() {
  let mock = store_mock.start()
  let seam =
    store.Store(..store_mock.seam(mock), set_tags: fn(_id, _tags) {
      Error("disk full")
    })
  let registry = start_registry_over(seam)
  let a = create(registry, "alpha", happy_runner)

  should.be_true(thread_registry.set_tags(registry, a.id, ["work"]))
  find_summary(registry, a.id).tags |> should.equal(["work"])

  // The freeze stands in memory: a later apply is refused without the
  // store being asked.
  thread_registry.upgrade_auto_title(registry, a.id, "Model Title", ["x"])
  |> should.equal(thread_registry.UpgradeRefused)
  // The mock saw neither the failed save nor any upgrade.
  store_mock.events(mock)
  |> list.filter(fn(event) {
    case event {
      store_mock.EvSetTags(_, _) | store_mock.EvAutoMetaUpgrade(_, _, _) -> True
      _ -> False
    }
  })
  |> should.equal([])
}

/// `TagCorpus` (§3.3) is deterministic for a given registry state:
/// normalize-BEFORE-counting pools `Work Notes` / `work notes` /
/// `WORK-NOTES` into one entry; the frequency floor (≥ 2 threads)
/// keeps singletons out of Y; ordering is count descending with an
/// alphabetical tie-break.
pub fn tag_corpus_floor_order_and_tiebreak_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  seed_with_tags(seam, "s1", ["cache", "login", "Work Notes"])
  seed_with_tags(seam, "s2", ["cache", "auth", "work notes"])
  seed_with_tags(seam, "s3", ["auth", "WORK-NOTES", "singleton"])
  let registry = start_registry_over(seam)

  // work-notes: 3 threads pooled across spellings, so it leads; auth
  // and cache tie at 2 — alphabetical; login and singleton sit below
  // the floor and never reach Y.
  thread_registry.tag_corpus(registry)
  |> should.equal(["work-notes", "auth", "cache"])
}

/// The corpus counts EVERY thread the registry knows — active records
/// plus dormant summaries — and the floor counts THREADS, not mentions
/// (`normalize_tags` dedupes within one thread before counting).
pub fn tag_corpus_counts_active_and_dormant_by_thread_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  seed_with_tags(seam, "s1", ["shared", "dormant-only"])
  let registry = start_registry_over(seam)
  let a = create(registry, "alpha", happy_runner)
  should.be_true(
    thread_registry.set_tags(registry, a.id, [
      "shared",
      "active-only",
      "shared",
    ]),
  )

  // "shared" reaches the floor across one dormant + one active
  // thread; the singletons do not; the repeated mention in one save
  // still counts once.
  thread_registry.tag_corpus(registry)
  |> should.equal(["shared"])
}

/// The 30-entry cap: with more qualifying tags than the cap, the corpus
/// keeps thirty (all tied here) in the deterministic tie-break order —
/// 31 and beyond never reach Y.
fn tag_names(n: Int, acc: List(Int)) -> List(Int) {
  case n {
    0 -> list.reverse(acc)
    _ -> tag_names(n - 1, [n, ..acc])
  }
}

pub fn tag_corpus_caps_at_thirty_entries_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // "tag-01" … "tag-35", zero-padded so the alphabetical tie-break is
  // also the numeric order.
  let tags =
    tag_names(35, [])
    |> list.map(fn(n) { "tag-" <> string.pad_start(int.to_string(n), 2, "0") })
  seed_with_tags(seam, "s1", tags)
  seed_with_tags(seam, "s2", tags)
  let registry = start_registry_over(seam)

  let corpus = thread_registry.tag_corpus(registry)
  list.length(corpus) |> should.equal(30)
  // The alphabetical tie-break fills the cap: tag-01 … tag-30 survive,
  // tag-31 … tag-35 fall off.
  should.be_true(list.contains(corpus, "tag-30"))
  should.be_false(list.contains(corpus, "tag-31"))
  case list.first(corpus) {
    Ok(first) -> should.equal(first, "tag-01")
    Error(_) -> panic as "expected a corpus"
  }
}

/// The 30 × 24 embedding bound holds BY CONSTRUCTION (§3.3): a 10 KB
/// legacy tag enters the corpus truncated at 24 kebab characters, and
/// case-insensitive pooling folds its spellings into the one bounded
/// entry — whatever older rows contain, Y's corpus share is bounded.
pub fn tag_corpus_truncates_and_pools_legacy_tags_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // ~10 KB, mixed case and spacing: hostile to the bound, benign after
  // normalization.
  let flood = string.repeat("Ab Cd ", 1700)
  seed_with_tags(seam, "s1", [flood])
  seed_with_tags(seam, "s2", [string.lowercase(flood)])
  let registry = start_registry_over(seam)

  let corpus = thread_registry.tag_corpus(registry)
  should.equal(corpus, ["ab-cd-ab-cd-ab-cd-ab-cd-"])
  // Every entry obeys the per-tag cap: 30 × 24 is the hard ceiling.
  list.each(corpus, fn(tag) { should.be_true(string.length(tag) <= 24) })
}

// ---------------------------------------------------------------------------
// Boot sweep of never-used threads
// ---------------------------------------------------------------------------

/// Boot a factory + registry pair over an injectable store, so the sweep
/// runs against whatever the store was pre-seeded with — exactly what
/// production boot sees after a restart.
fn start_registry_over(
  persistence: store.Store,
) -> process.Subject(thread_registry.Msg) {
  // Threads created over this seam pin the fixture provider, and the
  // sweep tests below seed rows directly — both need it to exist.
  start_registry_keeping_seam_with(thread_registry.thread_child, persistence).0
}

/// Seed one stored thread row directly through the seam.
fn seed(
  seam: store.Store,
  id: String,
  title: String,
  title_source: thread.TitleSource,
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
  title_source: thread.TitleSource,
  pinned: Bool,
  archived: Bool,
  message_count: Int,
  last_active_at: Int,
) -> Nil {
  // The seeded row pins the fixture provider; the FK (enforced by the
  // mock too) needs it in place before the insert.
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        id: id,
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        meta: thread.ThreadMeta(
          title: title,
          title_source: title_source,
          pinned: pinned,
          archived: archived,
          tags: [],
          tags_manual: [],
          tags_source: thread.AutoTags,
          bot_id: None,
          created_at: last_active_at,
        ),
        last_active_at: last_active_at,
        toolset: tools.default_names(test_config()),
        message_count: message_count,
      ),
      "test system prompt",
    )
  Nil
}

fn listed_ids(registry: process.Subject(thread_registry.Msg)) -> List(String) {
  thread_registry.list_threads(registry)
  |> list.map(fn(summary) { summary.id })
  |> list.sort(string.compare)
}

/// The litter older boots left behind — empty (system-prompt-only),
/// auto-titled, unpinned, archived or not — is swept at boot, in ONE
/// bulk prune. Anything with a user message, a manual rename, a pin, or
/// an empty thread FRESHER than the grace window survives: that last
/// one may belong to another concurrently-running server's live actor.
pub fn boot_sweep_deletes_never_used_threads_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  // Swept: stale never-used rows from earlier runs.
  seed(seam, "s1", "", thread.AutoTitle, False, False, 1)
  seed(seam, "s2", "", thread.AutoTitle, False, True, 1)
  // Kept: used, manually renamed, pinned…
  seed(seam, "s3", "hello world", thread.AutoTitle, False, False, 3)
  seed(seam, "s4", "keep me", thread.ManualTitle, False, False, 1)
  seed(seam, "s5", "", thread.AutoTitle, True, False, 1)
  // …and a never-used thread created moments ago (grace window).
  seed_at(
    seam,
    "s6",
    "",
    thread.AutoTitle,
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
    thread.AutoTitle,
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
  seed(seam, "s1", "", thread.AutoTitle, False, False, 1)

  let registry = start_registry_over(seam)
  let record = create(registry, "alpha", happy_runner)
  record.id |> should.equal("s2")
}

/// A prune that fails keeps every thread listed (dormant): the sidebar
/// must never show fewer rows than the store holds, and the next boot
/// retries the sweep.
pub fn boot_sweep_prune_failure_keeps_thread_test() {
  let mock = store_mock.start()
  let seam =
    store.Store(..store_mock.seam(mock), prune_never_used: fn() {
      Error("disk full")
    })
  seed(seam, "s1", "", thread.AutoTitle, False, False, 1)

  let registry = start_registry_over(seam)
  listed_ids(registry) |> should.equal(["s1"])
}

// ---------------------------------------------------------------------------
// P3: provider resolution on the create path
// ---------------------------------------------------------------------------

/// An unknown provider id refuses the create BEFORE any thread actor or
/// row exists (multi-provider §8: a thread is only ever created with its
/// (provider, model) pin in place).
pub fn create_rejects_unknown_provider_test() {
  let registry = start_registry()
  thread_registry.create_with_toolset(
    registry,
    new_thread("p-nope", "alpha"),
    toolset(happy_runner),
  )
  |> should.equal(
    Error(thread_registry.ProviderFailed(thread_registry.ProviderUnknown)),
  )
  thread_registry.list_threads(registry) |> should.equal([])
}

/// A disabled provider cannot back a new thread either — disabling is
/// the reversible delete, and resolve refuses it.
pub fn create_rejects_disabled_provider_test() {
  let factory_name = process.new_name("nexus_test_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let disabled: thread_registry.ResolveProvider = fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Error(thread_registry.ProviderDisabled)
      False -> Error(thread_registry.ProviderUnknown)
    }
  }
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry"),
      persistence,
      disabled,
    )
  thread_registry.create_with_toolset(
    started.data,
    new_thread(store_mock.fixture_provider_id, "alpha"),
    toolset(happy_runner),
  )
  |> should.equal(
    Error(thread_registry.ProviderFailed(thread_registry.ProviderDisabled)),
  )
}

/// The runner a created thread actually runs receives the endpoint the
/// resolver produced — the frozen provider transport (P3 acceptance:
/// "a thread streams via its frozen endpoint").
pub fn created_thread_runner_gets_resolved_endpoint_test() {
  let seen = process.new_subject()
  let capturing = fn(endpoint, tr, _cancel, _on_event) {
    process.send(seen, endpoint)
    thread.StreamDone(stats(), transcript.append_assistant(tr, "ok"))
  }
  let registry = start_registry()
  let _record = create(registry, "alpha", capturing)
  // A send makes the thread's worker invoke the runner.
  let assert Ok(sess) = thread_registry.get(registry, "s1")
  should.equal(thread.send_message(sess, "hi"), thread.Sent)
  let assert Ok(endpoint) = process.receive(seen, 2000)
  endpoint |> should.equal(test_endpoint())
}

// ---------------------------------------------------------------------------
// Bots plan P1: create-from-bot provenance (bots → frozen columns)
// ---------------------------------------------------------------------------

/// A rig that KEEPS its seam, so tests can seed bot rows and read back
/// frozen thread columns.
fn start_registry_keeping_seam() -> #(
  process.Subject(thread_registry.Msg),
  store.Store,
) {
  start_registry_keeping_seam_with(
    thread_registry.thread_child,
    store_mock.seam(store_mock.start()),
  )
}

/// The ONE boot body behind the registry rigs: factory + registry over
/// `persistence`, keeping the seam so callers can seed rows and read
/// back stored columns.
fn start_registry_keeping_seam_with(
  child: fn(thread_registry.ChildArgument) ->
    actor.StartResult(process.Subject(thread.Msg)),
  persistence: store.Store,
) -> #(process.Subject(thread_registry.Msg), store.Store) {
  let factory_name = process.new_name("nexus_test_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder_with_child(
      factory_name,
      child,
    ))
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry"),
      persistence,
      fixture_resolver(),
    )
  #(started.data, persistence)
}

fn seed_bot(
  seam: store.Store,
  id: String,
  prompt: option.Option(String),
) -> Result(Nil, String) {
  seed_bot_with_tools(seam, id, prompt, None)
}

/// Same, with the bot's toolset (bots plan P2's live template field).
fn seed_bot_with_tools(
  seam: store.Store,
  id: String,
  prompt: option.Option(String),
  tools: option.Option(List(String)),
) -> Result(Nil, String) {
  seam.insert_bot(bot.Bot(
    id: id,
    name: "bot " <> id,
    description: "",
    provider_id: store_mock.fixture_provider_id,
    model: "alpha",
    system_prompt: prompt,
    tools: tools,
    allow_inbound: True,
    created_at: 1_700_000_000,
    updated_at: 1_700_000_000,
  ))
}

/// A dormant stored thread with a MANUAL title (survives the boot sweep)
/// carrying an explicit toolset snapshot — the hydration rigs' fixture.
fn stored_with_toolset(
  id: String,
  toolset: List(String),
) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: store_mock.fixture_provider_id,
    model: "alpha",
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
    toolset: toolset,
    last_active_at: timing.wall_now_s(),
    message_count: 1,
  )
}

type Boot {
  Boot(registry: process.Subject(thread_registry.Msg))
}

/// Boot a registry over `seam` with the test config's default bundle —
/// the hydration rigs (dormant threads rehydrate from their snapshots).
/// `spec_captor` receives every child `ThreadSpec` the factory starts,
/// so the rigs can assert WHICH toolset bundle a hydration selected
/// (the persisted snapshot, not the boot default — the distinction a
/// bare `get → Ok` cannot make).
fn boot(
  seam: store.Store,
  spec_captor: process.Subject(thread.ThreadSpec),
) -> Boot {
  boot_with_config(seam, test_config(), spec_captor)
}

fn boot_with_config(
  seam: store.Store,
  cfg: config.Config,
  spec_captor: process.Subject(thread.ThreadSpec),
) -> Boot {
  let factory_name = process.new_name("nexus_hydration_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(
      thread_registry.factory_builder_with_child(
        factory_name,
        fn(argument: thread_registry.ChildArgument) {
          process.send(spec_captor, argument.spec)
          thread_registry.thread_child(argument)
        },
      ),
    )
  let assert Ok(started) =
    thread_registry.start(
      cfg,
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_hydration_registry"),
      seam,
      fixture_resolver(),
    )
  Boot(registry: started.data)
}

/// What `thread_create.create_thread_from_bot` asks for once it has
/// resolved the bot: the bot's explicit prompt, and its id as
/// provenance. The registry freezes both — the stored row's prompt is
/// the exact bytes the transcript froze, and `bot_id` is display-only.
pub fn create_from_bot_freezes_columns_and_provenance_test() {
  let #(registry, seam) = start_registry_keeping_seam()
  let assert Ok(Nil) = seed_bot(seam, "b1", Some("be terse"))

  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: Some("be terse"),
        toolset: None,
        bot_id: Some("b1"),
      ),
      toolset(happy_runner),
    )
  should.equal(summary.bot_id, Some("b1"))

  let assert Ok(stored) = seam.get_thread(summary.id)
  should.equal(stored.system_prompt, "be terse")
  should.equal(stored.summary.model, "alpha")
  should.equal(stored.summary.meta.bot_id, Some("b1"))

  // A plain create stays unprovenanced.
  let assert Ok(plain) =
    thread_registry.create_with_toolset(
      registry,
      new_thread(store_mock.fixture_provider_id, "alpha"),
      toolset(happy_runner),
    )
  should.equal(plain.bot_id, None)
  let assert Ok(plain_stored) = seam.get_thread(plain.id)
  should.equal(plain_stored.summary.meta.bot_id, None)
}

/// The bot's NULL prompt is the config default resolved AT CREATION
/// (#72's one resolution point): a bot without an explicit prompt
/// creates threads with `cfg.system_prompt` frozen — never a NULL that
/// hydration would later re-resolve against changed config.
pub fn create_from_null_prompt_bot_freezes_config_default_test() {
  let #(registry, seam) = start_registry_keeping_seam()
  let assert Ok(Nil) = seed_bot(seam, "b2", None)

  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: Some("b2"),
      ),
      toolset(happy_runner),
    )
  should.equal(summary.bot_id, Some("b2"))
  let assert Ok(stored) = seam.get_thread(summary.id)
  should.equal(stored.system_prompt, "test system prompt")
}

// ---------------------------------------------------------------------------
// Per-bot toolsets (bots plan P2): every thread snapshots RESOLVED names
// at creation; unknown names refuse loudly.
// ---------------------------------------------------------------------------

/// An explicit toolset persists its resolved names; a plain create
/// snapshots the DEFAULT names. Neither is ever a NULL-for-default —
/// that design would re-aim every default thread's envelope on a config
/// change + restart (the rejected alternative, coderabbit review PR #71).
pub fn toolset_snapshot_persisted_at_creation_test() {
  let #(registry, seam) = start_registry_keeping_seam()

  // The explicit list (the same tuple as the boot default here, so this
  // exercises the boot-bundle cache hit).
  let assert Ok(explicit) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some(["http_fetch"]),
        bot_id: None,
      ),
    )
  let assert Ok(stored) = seam.get_thread(explicit.id)
  should.equal(stored.summary.toolset, ["http_fetch"])

  // A plain create: the default set's names, persisted verbatim.
  let assert Ok(plain) =
    thread_registry.create(
      registry,
      new_thread(store_mock.fixture_provider_id, "alpha"),
    )
  let assert Ok(plain_stored) = seam.get_thread(plain.id)
  should.equal(plain_stored.summary.toolset, tools.default_names(test_config()))
}

/// A `'{}'` (chat-only) toolset builds its own bundle (cache miss on the
/// boot tuple) and persists the empty snapshot.
pub fn chat_only_toolset_create_test() {
  let #(registry, seam) = start_registry_keeping_seam()

  let assert Ok(summary) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some([]),
        bot_id: None,
      ),
    )
  let assert Ok(stored) = seam.get_thread(summary.id)
  should.equal(stored.summary.toolset, [])

  // The chat-only bundle is cached by its own tuple: a second thread of
  // the same toolset resolves through the shared bundle and starts fine.
  let assert Ok(second) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some([]),
        bot_id: None,
      ),
    )
  let assert Ok(second_stored) = seam.get_thread(second.id)
  should.equal(second_stored.summary.toolset, [])
}

/// A toolset naming a tool outside the compiled catalog refuses the
/// create with `UnknownToolset` (a 400-class client error) and inserts
/// nothing.
pub fn unknown_toolset_create_refused_test() {
  let #(registry, _seam) = start_registry_keeping_seam()

  thread_registry.create(
    registry,
    thread_registry.NewThread(
      provider_id: store_mock.fixture_provider_id,
      model: "alpha",
      system_prompt: None,
      toolset: Some(["nope"]),
      bot_id: None,
    ),
  )
  |> should.equal(
    Error(thread_registry.UnknownToolset("unknown tool name: nope")),
  )

  // Nothing was created.
  thread_registry.list_threads(registry) |> should.equal([])
}

/// A bot's toolset snapshots into the threads created from it: the
/// orchestration passes `bot.tools` as the request's toolset (the same
/// shape `create_thread_from_bot` builds), and the registry persists the
/// resolved names.
pub fn create_from_bot_toolset_snapshot_test() {
  let #(registry, seam) = start_registry_keeping_seam()
  let assert Ok(Nil) =
    seed_bot_with_tools(seam, "b-tools", None, Some(["http_fetch"]))

  let assert Ok(summary) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some(["http_fetch"]),
        bot_id: Some("b-tools"),
      ),
    )
  let assert Ok(stored) = seam.get_thread(summary.id)
  should.equal(stored.summary.toolset, ["http_fetch"])
  should.equal(stored.summary.meta.bot_id, Some("b-tools"))

  // The NULL-tools bot is the LIVE template half: `None` resolves to
  // the current default at each create (below, via a plain request).
  let assert Ok(Nil) = seed_bot_with_tools(seam, "b-default", None, None)
  let assert Ok(from_default_bot) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: Some("b-default"),
      ),
    )
  let assert Ok(stored) = seam.get_thread(from_default_bot.id)
  should.equal(stored.summary.toolset, tools.default_names(test_config()))
}

/// THE shared orchestration (the gap the registry-level snapshot tests
/// leave): `thread_create.create_thread_from_bot` must carry `bot.tools`
/// into the creation request — a regression that drops or mis-resolves
/// the field would otherwise still pass. Real registries over the mock
/// store, the bot created THROUGH the bot registry (catalog-checked).
pub fn create_from_bot_orchestration_carries_bot_toolset_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let cfg = test_config()
  let assert Ok(started_bots) =
    bot_registry.start(seam, process.new_name("nexus_orch_bots"), fn(names) {
      tools.by_names(cfg, names) |> result.replace(names)
    })
  let bots = started_bots.data
  // The provider registry's live model list, fixed: the orchestration
  // re-validates the bot's alias against it before the registry runs.
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      cfg,
      seam,
      process.new_name("nexus_orch_providers"),
      fn(_endpoint) { Ok(["alpha"]) },
    )
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_orch_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start(
      cfg,
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_orch_registry"),
      seam,
      fixture_resolver(),
    )
  let registry = started_registry.data

  // A toolset-carrying bot, created through the bot registry.
  let assert Ok(bot_row) =
    bot_registry.create_bot(
      bots,
      bot.BotParams(
        name: "researcher",
        description: "",
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        tools: Some(["http_fetch"]),
      ),
    )
  let assert Ok(summary) =
    thread_create.create_thread_from_bot(
      bots,
      providers,
      registry,
      5000,
      bot_row.id,
    )
  let assert Ok(stored) = seam.get_thread(summary.id)
  should.equal(stored.summary.toolset, ["http_fetch"])
  should.equal(stored.summary.meta.bot_id, Some(bot_row.id))

  // The chat-only bot's empty set survives the same path.
  let assert Ok(chat_bot) =
    bot_registry.create_bot(
      bots,
      bot.BotParams(
        name: "quiet",
        description: "",
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        tools: Some([]),
      ),
    )
  let assert Ok(chat_summary) =
    thread_create.create_thread_from_bot(
      bots,
      providers,
      registry,
      5000,
      chat_bot.id,
    )
  let assert Ok(chat_stored) = seam.get_thread(chat_summary.id)
  should.equal(chat_stored.summary.toolset, [])
}

/// A dormant thread's PERSISTED toolset rehydrates through the same
/// cache a create uses — the snapshot wins over today's boot default.
/// The captured child spec is the observable: the hydrated actor must
/// carry the CHAT-ONLY bundle ([]), not the boot default's.
pub fn dormant_toolset_rehydrates_through_snapshot_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  // A row whose snapshot is a NON-default toolset (the test config's
  // default is ["http_fetch"]; this thread pinned chat-only).
  let assert Ok(Nil) =
    seam.insert_thread(stored_with_toolset("s-chat", []), "sys")

  let spec_captor = process.new_subject()
  let booted = boot(seam, spec_captor)
  // Lazy start resolves [] through by_names (an empty bundle — valid:
  // a chat-only thread) instead of falling back to the default bundle.
  thread_registry.get(booted.registry, "s-chat")
  |> should.be_ok
  let assert Ok(spec) = process.receive(spec_captor, 5000)
  should.equal(spec.toolset.names, [])
}

/// A snapshot naming a tool absent from the compiled code fails
/// hydration LOUDLY — no silent skip, no envelope change. The thread
/// stays dormant (a later Get retries, like the provider-failure path);
/// the remedy is recreating the thread or hand-editing its row.
pub fn absent_tool_name_hydration_fails_loud_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_thread(stored_with_toolset("s-gone", ["vanished"]), "sys")

  let spec_captor = process.new_subject()
  let booted = boot(seam, spec_captor)
  thread_registry.get(booted.registry, "s-gone")
  |> should.equal(Error(Nil))
  // Still listed (dormant), still refusing.
  should.be_true(
    thread_registry.list_threads(booted.registry)
    |> list.any(fn(summary) { summary.id == "s-gone" }),
  )
  thread_registry.get(booted.registry, "s-gone")
  |> should.equal(Error(Nil))
  // No child was ever started — the loud refusal never silently falls
  // back to any bundle.
  let assert Error(Nil) = process.receive(spec_captor, 300)
}

/// The snapshot keeps its envelope across a restart under a registry
/// whose DEFAULT config differs: the dormant thread's names resolve
/// against the config-independent catalog, never against the new boot
/// default (the rejected NULL-for-default design would re-aim it here).
pub fn toolset_snapshot_survives_changed_default_config_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  // Created under a default of ["http_fetch"], the thread pinned a
  // DIFFERENT explicit toolset.
  let assert Ok(Nil) =
    seam.insert_thread(stored_with_toolset("s-pin", ["web_search"]), "sys")

  // The next boot runs with codemode ON — its default tuple is now
  // ["http_fetch", "codemode"].
  let codemode_on = config.Config(..test_config(), codemode: True)
  should.equal(tools.default_names(codemode_on), [
    "http_fetch",
    "codemode",
  ])
  let spec_captor = process.new_subject()
  let booted = boot_with_config(seam, codemode_on, spec_captor)

  // The thread starts — with ITS snapshot ("web_search" resolves
  // config-independently), not the new default. The captured child spec
  // is the observable that the persisted tuple SELECTED the bundle: a
  // fallback-to-default design would hand the actor
  // ["http_fetch", "codemode"] here. The config-independent schemas are
  // pinned by tools_test, the wire bytes by loop_test.
  thread_registry.get(booted.registry, "s-pin") |> should.be_ok
  let assert Ok(spec) = process.receive(spec_captor, 5000)
  should.equal(spec.toolset.names, ["web_search"])
  let assert Ok(stored) = seam.get_thread("s-pin")
  should.equal(stored.summary.toolset, ["web_search"])
}

/// The create seam carries the WHOLE toolset bundle (#76): the created
/// thread turns through the bundle's turn runner and its utility branch
/// calls the bundle's utility runner — not the registry default's. Before
/// the bundling, the utility side always came from the registry state, so
/// the bundle's own pinging fake is the observable that per-toolset
/// carriage is real (the default's fake refuses silently, which would be
/// indistinguishable from a lost call).
pub fn create_with_toolset_carries_the_whole_bundle_test() {
  // The utility branch is config-gated OFF in this suite's test_config
  // (keeps `gleam test` offline); this pin asserts the side call itself,
  // so this one registry boots with it on — the bundle's fake keeps it
  // offline regardless.
  let factory_name = process.new_name("nexus_bundle_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    thread_registry.start(
      config.Config(..test_config(), utility_enabled: True),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_bundle_registry"),
      persistence,
      fixture_resolver(),
    )
  let registry = started.data
  let ping = process.new_subject()
  let specs = tools.default(test_config())
  let bundle =
    thread.Toolset(
      names: list.map(specs, tools.tool_name),
      specs: specs,
      runner: happy_runner,
      utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
        process.send(ping, Nil)
        Error("asserted by the ping, not the verdict")
      },
    )
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      new_thread(store_mock.fixture_provider_id, "alpha"),
      bundle,
    )
  let assert Ok(subject) = thread_registry.get(registry, summary.id)

  // The first committed exchange arms the utility branch (utility-titles
  // plan §8): the call must land on the bundle's utility runner.
  should.equal(thread.send_message(subject, "hello"), thread.Sent)
  let assert Ok(Nil) = process.receive(ping, 5000)
}

/// Provenance survives the boot round trip: a dormant stored thread
/// with a bot_id lists with it (the sidebar's subtitle source), and a
/// deleted bot leaves the stored row NULLed (SET NULL) — so the boot
/// load can never resurrect a dead pointer.
pub fn dormant_summary_carries_bot_provenance_test() {
  let #(registry, seam) = start_registry_keeping_seam()
  let assert Ok(Nil) = seed_bot(seam, "b1", Some("p"))

  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        id: "s9",
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        meta: thread.ThreadMeta(
          title: "from bot",
          title_source: thread.AutoTitle,
          pinned: False,
          archived: False,
          tags: [],
          tags_manual: [],
          tags_source: thread.AutoTags,
          bot_id: Some("b1"),
          created_at: 1_700_000_000,
        ),
        last_active_at: 1_700_000_000,
        toolset: tools.default_names(test_config()),
        message_count: 3,
      ),
      "frozen",
    )

  // Boot a SECOND registry over the same seam (the first is discardable
  // scaffolding; the mock store is the survivor).
  let factory_name = process.new_name("nexus_test_factory_boot")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder_with_child(
      factory_name,
      thread_registry.thread_child,
    ))
  let assert Ok(booted) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_test_registry_boot"),
      seam,
      fixture_resolver(),
    )

  let summaries = thread_registry.list_threads(booted.data)
  let assert Ok(found) = list.find(summaries, fn(s) { s.id == "s9" })
  should.equal(found.bot_id, Some("b1"))

  // Deleting the bot NULLs the stored provenance (the mock mirrors SET
  // NULL): a later boot lists the thread unprovenanced.
  let assert Ok(Nil) = seam.delete_bot("b1")
  let factory2 = process.new_name("nexus_test_factory_boot2")
  let assert Ok(_factory2) =
    factory_supervisor.start(thread_registry.factory_builder_with_child(
      factory2,
      thread_registry.thread_child,
    ))
  let assert Ok(rebooted) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory2),
      process.new_name("nexus_test_registry_boot2"),
      seam,
      fixture_resolver(),
    )
  let after = thread_registry.list_threads(rebooted.data)
  let assert Ok(after_found) = list.find(after, fn(s) { s.id == "s9" })
  should.equal(after_found.bot_id, None)

  let _ = registry
  Nil
}

/// A bot delete must also reach the registry's IN-MEMORY mirror: the FK
/// fixes the stored rows inside the delete itself, but the live records
/// and the boot-hydrated dormant dict would keep reporting the dead id
/// until the next rehydration. The scrub (bot_deleted, the delete
/// caller's orchestration step) clears exactly that bot's pointer from
/// both summary halves and preserves every other bot's.
pub fn bot_delete_scrubs_cached_provenance_test() {
  // Seed BEFORE the boot: the registry hydrates its dormant dict from
  // `list_summaries` at start, so rows inserted after boot are invisible
  // to it. Ids stay clear of the live "s<n>" counter range (the boot
  // counter only scans ids present at start, so later live creates
  // would otherwise mint colliding ids).
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) = seed_bot(seam, "b1", Some("p"))
  // The unrelated bot exists too — the mock enforces the insert-time FK.
  let assert Ok(Nil) = seed_bot(seam, "b9", Some("p"))

  // Dormant threads: one provenanced by the bot-to-be-deleted, one by
  // an unrelated bot that must survive the scrub untouched.
  let dormant = fn(id: String, bot: String) {
    let assert Ok(Nil) =
      seam.insert_thread(
        store.StoredSummary(
          id: id,
          provider_id: store_mock.fixture_provider_id,
          model: "alpha",
          meta: thread.ThreadMeta(
            title: "from " <> bot,
            title_source: thread.AutoTitle,
            pinned: False,
            archived: False,
            tags: [],
            tags_manual: [],
            tags_source: thread.AutoTags,
            bot_id: Some(bot),
            created_at: 1_700_000_000,
          ),
          last_active_at: 1_700_000_000,
          toolset: tools.default_names(test_config()),
          message_count: 3,
        ),
        "frozen",
      )
    Nil
  }
  dormant("s9", "b1")
  dormant("s8", "b9")

  // Boot the registry over the prepared seam (keeps it for the
  // orchestration's store half below).
  let #(registry, seam) =
    start_registry_keeping_seam_with(thread_registry.thread_child, seam)

  // And a LIVE thread sourced from b1.
  let assert Ok(live) =
    thread_registry.create_with_toolset(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: Some("p"),
        toolset: None,
        bot_id: Some("b1"),
      ),
      toolset(happy_runner),
    )

  let bot_of = fn(id: String) {
    let assert Ok(found) =
      list.find(thread_registry.list_threads(registry), fn(s) { s.id == id })
    found.bot_id
  }
  should.equal(bot_of(live.id), Some("b1"))
  should.equal(bot_of("s9"), Some("b1"))
  should.equal(bot_of("s8"), Some("b9"))

  // The delete orchestration's order: the store NULLs the rows (SET
  // NULL) inside the bot delete, then the registry mirror is scrubbed.
  let assert Ok(Nil) = seam.delete_bot("b1")
  thread_registry.bot_deleted(registry, "b1")

  // Both halves scrubbed; the unrelated pointer preserved.
  should.equal(bot_of(live.id), None)
  should.equal(bot_of("s9"), None)
  should.equal(bot_of("s8"), Some("b9"))

  // The scrub writes nothing: bot_id rides no query but insert_thread,
  // so the stored rows keep whatever the FK last set (None here — the
  // delete's SET NULL; scrubbing must not resurrect).
  let assert Ok(stored) = seam.get_thread(live.id)
  should.equal(stored.summary.meta.bot_id, None)
  Nil
}

/// The residual of the bot-delete race (coderabbit re-review, PR #87):
/// a create-from-bot that reads the bot BEFORE deletion but reaches the
/// registry AFTER the scrub fails its insert (the FK rejects the dead
/// pointer) and lands in the unpersisted lane — the one record the
/// delete-time scrub could not reach. Provenance mirrors a stored row's
/// FK-maintained column, so an unpersisted create carries NO pointer:
/// neither the create reply nor a following List may report one.
pub fn unpersisted_create_carries_no_provenance_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) = seed_bot(seam, "b1", Some("p"))

  // A store whose thread inserts always fail (the store-down half of
  // the lane; the FK half fails the same insert with the same shape).
  let failing =
    store.Store(..seam, insert_thread: fn(_summary, _prompt) {
      Error("disk full")
    })
  let #(registry, _seam) =
    start_registry_keeping_seam_with(thread_registry.thread_child, failing)

  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: Some("p"),
        toolset: None,
        bot_id: Some("b1"),
      ),
      toolset(happy_runner),
    )
  // The create reply strips the pointer (the request asked for Some).
  should.equal(summary.bot_id, None)
  // And the registry's own summary path agrees.
  let assert Ok(listed) =
    list.find(thread_registry.list_threads(registry), fn(s) {
      s.id == summary.id
    })
  should.equal(listed.bot_id, None)
  // Nothing was stored, so nothing could resurrect the pointer later.
  let assert Error(_) = seam.get_thread(summary.id)
  Nil
}
