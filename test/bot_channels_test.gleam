//// Bot channel tests (bot-channels plan, #123): the per-parent routing
//// that fixes #123 — parallel parents get distinct channels (no pair-wide
//// busy serialization, no shared transcript), the same parent's second
//// delivery hits Busy on its own channel, restart re-derivation finds the
//// stored channel instead of duplicating it, a lookup failure during
//// re-derivation refuses retryably without creating, the sender-side
//// archive guard, the persistence-first archive cascade (transitive,
//// restore symmetric, in-flight turns preserved, live-actor notify),
//// durable refusal for archived channels (no re-derivation escape), and
//// the transitive delete cleanup (children AND grandchildren).
////
//// Fully offline: persistence rides the mock store seam; the hang-server
//// rig is a mist listener on loopback that never responds (a stream
//// against it hangs for the config's 1s sse timeout — the deterministic
//// busy window).

import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import mist
import nexus/bot
import nexus/bot_registry
import nexus/config.{type Config}
import nexus/delivery
import nexus/log
import nexus/openai
import nexus/store
import nexus/thread
import nexus/thread_registry
import nexus/tools
import store_mock

// ---------------------------------------------------------------------------
// Rigs
// ---------------------------------------------------------------------------

fn test_config() -> Config {
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
    web_fetch_cache_ttl_ms: 600_000,
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
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    max_bot_hops: 4,
  )
}

/// The refused endpoint: a loopback port nothing listens on — the
/// channels' own turns fail instantly (connection refused), keeping the
/// default tests deterministic and fast.
fn refused_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "http://127.0.0.1:9/v1",
    api_key: None,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
  )
}

/// A black-hole listener: accepts TCP, never responds. A stream against
/// it hangs until the sse first-response timeout (1s under `test_config`)
/// — the deterministic busy window for the channel-Busy assertions.
fn hang_server() -> Int {
  let bound = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(_req) {
      process.sleep(60_000)
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(bound, port) })
    |> mist.start
  let assert Ok(port) = process.receive(bound, 5000)
  port
}

fn hang_endpoint(port: Int) -> openai.Endpoint {
  openai.Endpoint(
    base_url: "http://127.0.0.1:" <> string.inspect(port) <> "/v1",
    api_key: None,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
  )
}

type Booted {
  Booted(
    registry: Subject(thread_registry.Msg),
    bots: Subject(bot_registry.Msg),
    seam: store.Store,
  )
}

/// Real registries over the mock store, with `endpoint` as every
/// thread's frozen provider endpoint.
fn boot_over(seam: store.Store, endpoint: openai.Endpoint) -> Booted {
  store_mock.ensure_fixture_provider(seam)
  let bots_name = process.new_name("nexus_channels_bot_registry")
  let assert Ok(started_bots) =
    bot_registry.start(
      seam,
      bots_name,
      fn(names) {
        tools.by_names(test_config(), names) |> result.replace(names)
      },
      fn() { bot_registry.ToolCatalog([], []) },
    )
  let factory_name = process.new_name("nexus_channels_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_channels_registry"),
      seam,
      fn(_id) { Ok(endpoint) },
      bots_name,
      dict.new(),
      dict.new(),
      None,
    )
  Booted(registry: started_registry.data, bots: started_bots.data, seam:)
}

fn boot() -> Booted {
  boot_over(store_mock.seam(store_mock.start()), refused_endpoint())
}

fn create_bot(booted: Booted, name: String) -> bot.Bot {
  let assert Ok(created) =
    bot_registry.create_bot(
      booted.bots,
      bot.BotParams(
        name: name,
        description: "",
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        tools: None,
      ),
    )
  created
}

/// A REAL originating thread for `bot` — the parent a channel hangs off
/// (bot-channels plan, #123). Its injected runner never streams (only
/// the channels turn in these tests).
fn create_parent_thread(booted: Booted, bot_id: String) -> String {
  let specs = tools.by_names(test_config(), []) |> result.unwrap([])
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      booted.registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: bot_id,
        parent_thread_id: None,
        title: "",
      ),
      thread.Toolset(
        names: [],
        specs: specs,
        runner: fn(_endpoint, tr, _cancel, _delivery, _environment, _on_event) {
          thread.StreamDone(
            openai.StreamStats(
              ttft_ms: Some(10),
              duration_ms: 100,
              token_deltas: 1,
              reasoning_deltas: 0,
              tool_call_deltas: 0,
              events_parsed: 1,
              decode_errors: 0,
              saw_done: True,
              usage: None,
            ),
            tr,
          )
        },
        utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
          Error("no utility call in this test")
        },
      ),
    )
  summary.id
}

/// A thread whose turn blocks until the test releases it — the
/// in-flight-turn rig. The WORKER creates its own gate subject and hands
/// it back through `gate_request`; the test answers through that (the
/// gated_runner pattern in thread_test.gleam — a spawned worker cannot
/// receive on a subject owned by the calling process).
fn gated_runner(gate_request: Subject(Subject(Nil))) -> thread.TurnRunner {
  fn(_endpoint, tr, _cancel, _delivery, _environment, _on_event) {
    let gate = process.new_subject()
    process.send(gate_request, gate)
    let _ = process.receive(gate, 30_000)
    thread.StreamDone(
      openai.StreamStats(
        ttft_ms: Some(10),
        duration_ms: 100,
        token_deltas: 1,
        reasoning_deltas: 0,
        tool_call_deltas: 0,
        events_parsed: 1,
        decode_errors: 0,
        saw_done: True,
        usage: None,
      ),
      tr,
    )
  }
}

fn deliver(
  registry: Subject(thread_registry.Msg),
  from_bot_id: String,
  from_bot_name: String,
  from_thread_id: String,
  depth: Int,
  to: String,
  text: String,
) -> delivery.Reply {
  thread_registry.deliver(
    registry,
    delivery.Request(
      from_bot_id: from_bot_id,
      from_bot_name: from_bot_name,
      from_thread_id: from_thread_id,
      depth: depth,
      to: to,
      text: text,
    ),
  )
}

/// The stored channel row for one (parent, target bot) pair — the
/// persisted half of the channel identity. Channels are second-class:
/// absent from `list_threads`, so the store is how tests observe them.
fn stored_channel(
  booted: Booted,
  parent_id: String,
  bot_id: String,
) -> store.StoredSummary {
  let assert Ok(#(summaries, _)) = booted.seam.list_summaries()
  let assert [summary] =
    list.filter(summaries, fn(s) {
      s.meta.parent_thread_id == option.Some(parent_id)
      && s.meta.bot_id == option.Some(bot_id)
    })
  summary
}

fn stored_channel_count(booted: Booted, parent_id: String) -> Int {
  let assert Ok(#(summaries, _)) = booted.seam.list_summaries()
  list.filter(summaries, fn(s) {
    s.meta.parent_thread_id == option.Some(parent_id)
  })
  |> list.length
}

fn wait_idle(registry: Subject(thread_registry.Msg), thread_id: String) -> Nil {
  let assert Ok(subject) = thread_registry.get(registry, thread_id)
  wait_idle_loop(subject, 500)
}

fn wait_idle_loop(subject: Subject(thread.Msg), budget: Int) -> Nil {
  case thread.describe(subject).streaming {
    False -> Nil
    True ->
      case budget {
        0 -> panic as "thread never went idle"
        _ -> {
          process.sleep(10)
          wait_idle_loop(subject, budget - 1)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// The #123 fix: per-parent channels
// ---------------------------------------------------------------------------

/// Two parents whose bots message the SAME target bot each get their own
/// channel — no pair-wide map, so parent 2's unrelated request is
/// Delivered while parent 1's channel is mid-turn (the #123
/// serialization report), and neither transcript sees the other's line.
pub fn parallel_parents_distinct_channels_test() {
  let hang = hang_server()
  let booted =
    boot_over(store_mock.seam(store_mock.start()), hang_endpoint(hang))
  let alpha = create_bot(booted, "alpha")
  let alpha2 = create_bot(booted, "alpha2")
  let beta = create_bot(booted, "beta")
  let parent1 = create_parent_thread(booted, alpha.id)
  let parent2 = create_parent_thread(booted, alpha2.id)

  // Parent 1's channel takes the line and its turn HANGS (the black-hole
  // endpoint keeps it busy for ~1s).
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent1, 1, "beta", "task one")
  // While that channel is still mid-turn, parent 2 delivers: its OWN
  // channel answers Delivered — the pair-wide busy lock is gone.
  let assert delivery.Delivered(c2) =
    deliver(
      booted.registry,
      alpha2.id,
      "alpha2",
      parent2,
      1,
      "beta",
      "task two",
    )
  should.be_false(c1 == c2)

  // Distinct persisted channels, one per parent, each with the right
  // parent link and the deterministic target-bot title.
  let stored1 = stored_channel(booted, parent1, beta.id)
  let stored2 = stored_channel(booted, parent2, beta.id)
  should.equal(stored1.id, c1)
  should.equal(stored2.id, c2)
  should.equal(stored1.meta.title, "beta")
  should.equal(stored2.meta.title, "beta")

  // The running-dot state the info pane asks for: channel 1 is running,
  // channel 2 just delivered (its turn hangs too), and bot names resolve.
  let infos = thread_registry.channels(booted.registry, parent1)
  let assert [info1] = infos
  should.equal(info1.thread_id, c1)
  should.equal(info1.bot_name, option.Some("beta"))
  should.equal(info1.running, True)
  should.equal(infos |> list.length, 1)

  // Wait both hangs out (the 1s sse timeout errors the turns; nothing
  // was committed by a failed turn beyond the delivered line).
  wait_idle(booted.registry, c1)
  wait_idle(booted.registry, c2)
}

/// The same parent's second delivery into its OWN mid-turn channel
/// answers Busy immediately — contention scope is the conversation, not
/// the pair.
pub fn same_parent_second_delivery_busy_test() {
  let hang = hang_server()
  let booted =
    boot_over(store_mock.seam(store_mock.start()), hang_endpoint(hang))
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)

  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "one")
  deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "two")
  |> should.equal(delivery.Busy)

  wait_idle(booted.registry, c1)
  // Still exactly one channel for the pair.
  should.equal(stored_channel_count(booted, parent), 1)
}

// ---------------------------------------------------------------------------
// Restart re-derivation
// ---------------------------------------------------------------------------

/// A restart empties the in-memory map; the first post-restart delivery
/// RE-DERIVES the existing channel from the store instead of duplicating
/// it (the restart-loss bug #123 pins).
pub fn restart_rederivation_finds_existing_channel_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(dm_id) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "before")
  wait_idle(booted.registry, dm_id)

  // "Restart": a fresh registry over the SAME store — its map is empty.
  let booted2 = boot_over(booted.seam, refused_endpoint())
  let assert delivery.Delivered(dm_id2) =
    deliver(booted2.registry, alpha.id, "alpha", parent, 1, "beta", "after")
  should.equal(dm_id2, dm_id)
  // No duplicate: still exactly one channel row for the pair.
  should.equal(stored_channel_count(booted2, parent), 1)
}

/// A store outage during re-derivation refuses with the retryable
/// vocabulary and NEVER falls through to creation — a transient failure
/// must not duplicate a channel that may well exist.
pub fn rederivation_lookup_error_refuses_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)

  let broken_seam =
    store.Store(..booted.seam, find_channel: fn(_, _) { Error("db down") })
  let booted2 = boot_over(broken_seam, refused_endpoint())
  deliver(booted2.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  |> should.equal(delivery.Refused("target lookup failed; try again"))
  // Nothing was created behind the failed lookup.
  should.equal(stored_channel_count(booted2, parent), 0)
}

// ---------------------------------------------------------------------------
// The archive cascade (persistence-first)
// ---------------------------------------------------------------------------

/// Archiving a parent cascades transitively down its channel subtree
/// (hop chains make channels of channels), store first, memory synced on
/// the acknowledged outcome; restore is symmetric; live actors learn
/// their refusal state via the notify (no restart) — and without any
/// `Stop` (the in-flight turn below is preserved).
pub fn parent_archive_cascades_and_restores_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let _gamma = create_bot(booted, "gamma")
  let parent = create_parent_thread(booted, alpha.id)

  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "one")
  wait_idle(booted.registry, c1)
  // Hop chain: a bot INSIDE the channel delivers onward — its channel
  // hangs off c1 (grandchild).
  let assert delivery.Delivered(c2) =
    deliver(booted.registry, beta.id, "beta", c1, 2, "gamma", "nested")
  wait_idle(booted.registry, c2)

  // Archive the parent: the whole subtree goes quiescent.
  should.equal(
    thread_registry.set_archived(booted.registry, parent, True),
    True,
  )
  should.equal(stored_by_id(booted, parent).meta.archived, True)
  should.equal(stored_by_id(booted, c1).meta.archived, True)
  should.equal(stored_by_id(booted, c2).meta.archived, True)

  // Memory synced immediately (no restart): the Channels asks report
  // archived children, and the LIVE c1 actor refuses human Sends via
  // the notify.
  let infos = thread_registry.channels(booted.registry, parent)
  let assert [info] = infos
  should.equal(info.thread_id, c1)
  should.equal(info.archived, True)
  let assert Ok(subject) = thread_registry.get(booted.registry, c1)
  thread.send_message(subject, "anyone?")
  |> should.equal(thread.Refused("thread is archived"))

  // Restore is symmetric: the whole subtree wakes.
  should.equal(
    thread_registry.set_archived(booted.registry, parent, False),
    True,
  )
  should.equal(stored_by_id(booted, parent).meta.archived, False)
  should.equal(stored_by_id(booted, c1).meta.archived, False)
  should.equal(stored_by_id(booted, c2).meta.archived, False)
  let assert Ok(subject2) = thread_registry.get(booted.registry, c1)
  should.equal(thread.send_message(subject2, "back"), thread.Sent)
  wait_idle(booted.registry, c1)
}

fn stored_by_id(booted: Booted, id: String) -> store.StoredSummary {
  let assert Ok(#(summaries, _)) = booted.seam.list_summaries()
  let assert [summary] = list.filter(summaries, fn(s) { s.id == id })
  summary
}

/// A failed cascade write aborts LOUDLY with memory untouched — nothing
/// hydrates archived after a restart, so the children keep accepting
/// deliveries.
pub fn failed_cascade_write_aborts_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  wait_idle(booted.registry, c1)

  let broken_seam =
    store.Store(..booted.seam, archive: fn(_) { Error("db down") })
  let booted2 = boot_over(broken_seam, refused_endpoint())
  should.equal(
    thread_registry.set_archived(booted2.registry, parent, True),
    False,
  )
  // Store untouched, memory untouched: the channel still reads active.
  should.equal(stored_channel(booted2, parent, beta.id).meta.archived, False)
  let infos = thread_registry.channels(booted2.registry, parent)
  let assert [info] = infos
  should.equal(info.archived, False)
}

/// A delivery from an archived sender refuses — the sender-side guard —
/// and creates nothing (no fresh channel under an archived parent; the
/// turn that calls `bot_message` may still be in flight when the parent
/// is archived, because archive does not cancel turns).
pub fn sender_archived_refuses_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let _gamma = create_bot(booted, "gamma")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  wait_idle(booted.registry, c1)

  // Archive the SENDING thread (the parent), then a delivery from it:
  // refused before any find-or-create.
  should.equal(
    thread_registry.set_archived(booted.registry, parent, True),
    True,
  )
  deliver(booted.registry, alpha.id, "alpha", parent, 1, "gamma", "new target")
  |> should.equal(delivery.Refused("sender thread is archived"))
  // No fresh channel was opened under the archived parent.
  should.equal(stored_channel_count(booted, parent), 1)
}

/// A delivery whose SENDER is unknown to the registry is refused before
/// target resolution (CodeRabbit PR review on #137): Delete stops the
/// actor but not an in-flight turn worker, so a delivery can arrive from
/// a parent that is already gone — the parent FK would refuse any
/// channel create it triggered, and starting it anyway would strand the
/// exchange on an unpersisted phantom behind a Delivered reply.
pub fn unknown_sender_refuses_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")

  deliver(
    booted.registry,
    alpha.id,
    "alpha",
    "s-never-existed",
    1,
    "beta",
    "from a deleted parent",
  )
  |> should.equal(delivery.Refused("sender thread is gone"))
  // The pair opened no channel.
  should.equal(stored_channel_count(booted, "s-never-existed"), 0)
}

/// A CHANNEL create whose thread-row insert failed is refused outright
/// (CodeRabbit PR review on #137): without the persisted parent link the
/// channel is unreachable by re-derivation, and starting it anyway would
/// strand the exchange on an unpersisted phantom thread behind a
/// Delivered reply. Ordinary creates keep the Phase 1 unpersisted
/// fallback, so the failing insert is scoped to channel rows.
pub fn channel_persist_failure_refuses_test() {
  let base = store_mock.seam(store_mock.start())
  let persistence =
    store.Store(
      ..base,
      insert_thread: fn(summary: store.StoredSummary, prompt: String) {
        case summary.meta.parent_thread_id {
          option.Some(_) -> Error("channel insert refused (simulated outage)")
          option.None -> base.insert_thread(summary, prompt)
        }
      },
    )
  let booted = boot_over(persistence, refused_endpoint())
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)

  deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  |> should.equal(delivery.Refused("target bot's thread could not be started"))
  // No channel row landed, and no phantom thread started — the parent
  // is the only thread the registry lists.
  should.equal(stored_channel_count(booted, parent), 0)
  should.equal(
    thread_registry.list_threads(booted.registry)
      |> list.any(fn(summary) { summary.id != parent }),
    False,
  )
}

/// An ARCHIVED parent that is DORMANT refuses deliveries too (cubic PR
/// review on #137): the deleted-sender guard admits dormant senders, so
/// the archive guard must read the dormant summary's meta — failing
/// open there would let a worker orphaned by a registry restart open a
/// BRAND-NEW ACTIVE channel under an archived parent.
pub fn dormant_archived_sender_refuses_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let _gamma = create_bot(booted, "gamma")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  wait_idle(booted.registry, c1)

  // Archive the parent, then restart: it demotes to a dormant stored
  // summary carrying its archived flag.
  should.equal(
    thread_registry.set_archived(booted.registry, parent, True),
    True,
  )
  let booted2 = boot_over(booted.seam, refused_endpoint())

  // A delivery FROM the dormant archived parent to a FRESH target is
  // refused before any find-or-create: nothing new opens under an
  // archived parent.
  deliver(booted2.registry, alpha.id, "alpha", parent, 1, "gamma", "new")
  |> should.equal(delivery.Refused("sender thread is archived"))
  should.equal(stored_channel_count(booted2, parent), 1)
}

/// An ARCHIVED CHANNEL refuses deliveries from its parent DURABLY —
/// including after a restart, where re-derivation re-finds the archived
/// row instead of resurrecting or recreating it. Reading stays allowed.
pub fn archived_channel_delivery_refuses_durably_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "hello")
  wait_idle(booted.registry, c1)

  // Archive the channel alone (the contract a future individual
  // affordance builds on): the parent stays active.
  should.equal(thread_registry.set_archived(booted.registry, c1, True), True)
  deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "again")
  |> should.equal(delivery.Refused("target thread is archived"))

  // After a restart the map is gone: re-derivation re-finds the
  // ARCHIVED row and refuses again — no resurrection, no duplicate.
  let booted2 = boot_over(booted.seam, refused_endpoint())
  deliver(
    booted2.registry,
    alpha.id,
    "alpha",
    parent,
    1,
    "beta",
    "after restart",
  )
  |> should.equal(delivery.Refused("target thread is archived"))
  should.equal(stored_channel_count(booted2, parent), 1)
  // Reading stays allowed: the channel answers Get (a navigable,
  // read-only transcript — never hidden).
  let assert Ok(_) = thread_registry.get(booted2.registry, c1)
}

/// The archive mechanic never cancels a turn: archiving the parent
/// while its channel's turn is in flight flips the channel's refusal
/// flag (the notify lands mid-turn — the actor loop never blocks on its
/// worker) and preserves the in-flight turn untouched.
pub fn archive_preserves_in_flight_turn_test() {
  let hang = hang_server()
  let booted =
    boot_over(store_mock.seam(store_mock.start()), hang_endpoint(hang))
  let alpha = create_bot(booted, "alpha")
  let _beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)

  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "long task")
  // The channel's turn is hanging on the black-hole endpoint.
  let assert Ok(subject) = thread_registry.get(booted.registry, c1)
  should.equal(thread.describe(subject).streaming, True)

  // Archive mid-turn: the flag applies immediately, the turn keeps
  // running.
  should.equal(
    thread_registry.set_archived(booted.registry, parent, True),
    True,
  )
  should.equal(thread.describe(subject).streaming, True)
  thread.send_message(subject, "still refuses while streaming")
  |> should.equal(thread.Refused("thread is archived"))

  // The turn completes on its own (the 1s timeout) and commits nothing
  // beyond the delivered line — the archive never cancelled it.
  wait_idle(booted.registry, c1)
}

/// Archiving an ordinary (non-channel) thread preserves its in-flight
/// turn end to end — the no-cancel rule at the registry: no Stop, the
/// gated runner completes and commits only when the test releases it.
pub fn archive_no_cancel_of_parent_turn_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let gate_request = process.new_subject()
  let runner = gated_runner(gate_request)
  let specs = tools.by_names(test_config(), []) |> result.unwrap([])
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      booted.registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: alpha.id,
        parent_thread_id: None,
        title: "",
      ),
      thread.Toolset(
        names: [],
        specs: specs,
        runner: runner,
        utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
          Error("no utility call in this test")
        },
      ),
    )
  let assert Ok(subject) = thread_registry.get(booted.registry, summary.id)
  should.equal(thread.send_message(subject, "start"), thread.Sent)

  should.equal(
    thread_registry.set_archived(booted.registry, summary.id, True),
    True,
  )
  should.equal(thread.describe(subject).streaming, True)

  // Release: the turn completes normally and commits. The worker handed
  // its gate back; answer through it.
  let assert Ok(gate) = process.receive(gate_request, 5000)
  process.send(gate, Nil)
  wait_idle(booted.registry, summary.id)
}

// ---------------------------------------------------------------------------
// Delete cascade
// ---------------------------------------------------------------------------

/// Deleting a parent drops the whole descendant tree — direct children
/// AND grandchildren (the FK cascades rows; the registry drops the
/// actors, records, and dm entries transitively). The deleted pair is
/// simply gone: a deleted thread has no actor or worker that could
/// originate a next delivery, so no fresh channel can ever hang off it.
pub fn parent_delete_drops_subtree_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let _gamma = create_bot(booted, "gamma")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "one")
  wait_idle(booted.registry, c1)
  let assert delivery.Delivered(c2) =
    deliver(booted.registry, beta.id, "beta", c1, 2, "gamma", "nested")
  wait_idle(booted.registry, c2)

  should.equal(thread_registry.delete_thread(booted.registry, parent), True)

  // The store rows are gone (all three).
  let assert Ok(#(summaries, _)) = booted.seam.list_summaries()
  should.be_false(
    list.any(summaries, fn(s) { list.contains([parent, c1, c2], s.id) }),
  )
  // The registry knows none of them (Get fails — the lazy-start would
  // have rehydrated a surviving row).
  should.equal(thread_registry.get(booted.registry, c1), Error(Nil))
  should.equal(thread_registry.get(booted.registry, c2), Error(Nil))
}

// ---------------------------------------------------------------------------
// The Channels ask (the info pane's data)
// ---------------------------------------------------------------------------

/// The Channels ask answers from state: one row per child channel
/// (bot names resolved, idle channels not running, archived flag
/// carried), grandchildren excluded from the parent's pane (they appear
/// in their own parent-channel's pane, per the hop-chain rule), and a
/// thread with no channels gets an empty list.
pub fn channels_ask_rows_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let _gamma = create_bot(booted, "gamma")
  let _delta = create_bot(booted, "delta")
  let parent = create_parent_thread(booted, alpha.id)

  // No channels yet: empty.
  should.equal(thread_registry.channels(booted.registry, parent), [])

  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "beta", "one")
  wait_idle(booted.registry, c1)
  let assert delivery.Delivered(c2) =
    deliver(booted.registry, alpha.id, "alpha", parent, 1, "gamma", "two")
  wait_idle(booted.registry, c2)

  // Hop chain: a bot INSIDE c1 delivers onward — the grandchild hangs
  // off c1, never the parent.
  let assert delivery.Delivered(c3) =
    deliver(booted.registry, beta.id, "beta", c1, 2, "delta", "nested")
  wait_idle(booted.registry, c3)

  let infos =
    thread_registry.channels(booted.registry, parent)
    |> list.sort(fn(a, b) { string.compare(a.thread_id, b.thread_id) })
  // Exactly the two direct children — the grandchild is absent here.
  should.equal(list.length(infos), 2)
  let assert [beta_row, gamma_row] = infos
  should.equal(beta_row.thread_id, c1)
  should.equal(beta_row.bot_name, option.Some("beta"))
  should.equal(beta_row.running, False)
  should.equal(beta_row.archived, False)
  should.equal(gamma_row.thread_id, c2)
  should.equal(gamma_row.bot_name, option.Some("gamma"))

  // The grandchild shows up in its OWN parent-channel's pane.
  let c1_infos = thread_registry.channels(booted.registry, c1)
  let assert [delta_row] = c1_infos
  should.equal(delta_row.thread_id, c3)
  should.equal(delta_row.bot_name, option.Some("delta"))
}

// ---------------------------------------------------------------------------
// The pane's reverse lookup (bot-channels plan Phase 2)
// ---------------------------------------------------------------------------

/// `channel_of` resolves a CHANNEL's context — parent, bot pointer,
/// frozen creation title, archived flag — and refuses everything that is
/// not one: the ordinary parent and unknown ids alike answer Error, so
/// the UI's breadcrumb/highlight mapping can never misfire on an
/// ordinary selection.
pub fn channel_of_resolves_channel_context_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)

  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 0, "beta", "check it")

  let channel = stored_channel(booted, parent, beta.id)
  should.equal(channel.id, c1)
  let assert Ok(ctx) = thread_registry.channel_of(booted.registry, c1)
  should.equal(ctx.parent_id, parent)
  should.equal(ctx.bot_id, option.Some(beta.id))
  // The frozen title is the target bot's name (create_dm's
  // deterministic title) — the header's deleted-bot fallback.
  should.equal(ctx.title, "beta")
  should.equal(ctx.archived, False)

  // Ordinary thread and unknown id: not a channel, either of them.
  should.equal(thread_registry.channel_of(booted.registry, parent), Error(Nil))
  should.equal(
    thread_registry.channel_of(booted.registry, "no-such-thread"),
    Error(Nil),
  )
}

/// Post-restart the channel sits in the registry's dormant summaries
/// (boot hydrates lazily) — the pane's reverse lookup answers from that
/// dict too, so a reload with a channel as the last-selected thread
/// restores the breadcrumb and the parent highlight.
pub fn channel_of_answers_dormant_channels_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 0, "beta", "check it")

  let booted2 = boot_over(booted.seam, refused_endpoint())
  let assert Ok(ctx) = thread_registry.channel_of(booted2.registry, c1)
  should.equal(ctx.parent_id, parent)
  should.equal(ctx.bot_id, option.Some(beta.id))
  should.equal(ctx.title, "beta")
}

/// The pane's rows carry the frozen title beside the resolved bot name —
/// the deleted-bot fallback the UI renders (the as-built amended the
/// plan's "falls back to the id": the frozen name reads as a name).
pub fn channel_rows_carry_frozen_title_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 0, "beta", "check it")

  let assert [row] = thread_registry.channels(booted.registry, parent)
  should.equal(row.thread_id, c1)
  should.equal(row.bot_name, option.Some("beta"))
  should.equal(row.title, "beta")

  // After the bot is deleted, `bot_name` resolves to None while the
  // frozen title survives — exactly the fallback pair the pane needs.
  let assert Ok(Nil) = bot_registry.delete_bot(booted.bots, beta.id)
  let assert [row] = thread_registry.channels(booted.registry, parent)
  should.equal(row.bot_name, None)
  should.equal(row.title, "beta")
}

/// The per-thread HTTP routes' resolution (with_thread): the summary for
/// ANY id — channels included, which the `List` projection hides. The
/// Phase 1 projection accidentally 404'd every per-thread route on a
/// channel (state/delete/send); `summary_of` + the get-first ordering in
/// `web.with_thread` restore the "Get/state keep answering" contract.
pub fn summary_of_answers_for_channels_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha")
  let beta = create_bot(booted, "beta")
  let parent = create_parent_thread(booted, alpha.id)
  let assert delivery.Delivered(c1) =
    deliver(booted.registry, alpha.id, "alpha", parent, 0, "beta", "check it")

  // Live channel: full summary, parent provenance intact.
  let assert Ok(summary) = thread_registry.summary_of(booted.registry, c1)
  should.equal(summary.id, c1)
  should.equal(summary.bot_id, option.Some(beta.id))
  should.equal(summary.title, "beta")

  // Dormant channel: the store snapshot answers the same way (the
  // provenance pointer rides the stored meta).
  let booted2 = boot_over(booted.seam, refused_endpoint())
  let assert Ok(summary) = thread_registry.summary_of(booted2.registry, c1)
  should.equal(summary.id, c1)
  should.equal(summary.bot_id, option.Some(beta.id))

  // The parent (ordinary) still answers, and an unknown id refuses.
  let assert Ok(_) = thread_registry.summary_of(booted2.registry, parent)
  should.equal(
    thread_registry.summary_of(booted2.registry, "no-such-thread"),
    Error(Nil),
  )
}
