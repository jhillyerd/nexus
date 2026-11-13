//// Bot-to-bot delivery tests (bots plan P3c, issue #97): the registry
//// guard matrix through the `Deliver` seam, the name→DM find-or-create
//// routing, the hop-depth arithmetic across a multi-hop chain, and the
//// loop interaction — a real `bot_message` tool execution inside a turn
//// (real specs + real registry asks over a scripted stream), proving the
//// wrapper's depth computation and the receipt/refusal rendering.
////
//// Fully offline: persistence rides the mock store seam; the scripted
//// stream never touches the network; the DM threads' own (failing) turns
//// point at a refused loopback port so they fail instantly and commit
//// nothing beyond the delivered user line.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import glopenai/chat
import nexus/bot
import nexus/bot_registry
import nexus/config.{type Config}
import nexus/delivery
import nexus/loop
import nexus/openai
import nexus/store
import nexus/thread
import nexus/thread_registry
import nexus/tools
import nexus/transcript
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
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
    // The real utility runner would stream from a network endpoint once a
    // debounce fired; the feature stays off so the suite stays offline.
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    max_bot_hops: 4,
  )
}

/// A loopback port nothing listens on: the DM threads' own turns fail
/// INSTANTLY (connection refused) instead of a DNS round-trip — the test
/// stays deterministic and network-free.
fn refused_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "http://127.0.0.1:9/v1",
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

/// Real registries over the mock store: the bot registry is booted under a
/// name so the delivery wrapper's sender-name ask (resolved by name at ask
/// time, inside the turn worker) reaches a live actor, exactly like boot.
fn boot() -> Booted {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let bots_name = process.new_name("nexus_delivery_bot_registry")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) {
      tools.by_names(test_config(), names) |> result.replace(names)
    })
  let factory_name = process.new_name("nexus_delivery_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_delivery_registry"),
      seam,
      fn(_id) { Ok(refused_endpoint()) },
      bots_name,
    )
  Booted(registry: started_registry.data, bots: started_bots.data, seam:)
}

fn create_bot(
  booted: Booted,
  name: String,
  allow_inbound allow_inbound: Bool,
) -> bot.Bot {
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
  // The create always opens the gate (P3a); PATCH it closed when a test
  // asks for the refused shape.
  case allow_inbound {
    True -> created
    False -> {
      let assert Ok(patch) =
        bot_registry.update_bot(
          booted.bots,
          created.id,
          bot.BotUpdate(
            name: None,
            description: None,
            provider_id: None,
            model: None,
            system_prompt: None,
            tools: None,
            allow_inbound: Some(False),
          ),
        )
      patch
    }
  }
}

/// A thread of `bot` whose turn runner is the REAL loop over the REAL
/// `bot_message` spec with a SCRIPTED stream (below) — the registry wraps
/// it with the delivery identity because `bot_id` is `Some`.
fn create_bot_thread(
  booted: Booted,
  bot_id: String,
  runner: thread.TurnRunner,
) -> thread.ThreadSummary {
  let specs = case tools.by_names(test_config(), ["bot_message"]) {
    Ok(specs) -> specs
    Error(reason) ->
      panic as { "bot_message must be in the catalog: " <> reason }
  }
  let bundle =
    thread.Toolset(
      names: ["bot_message"],
      specs: specs,
      runner: runner,
      utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
        Error("no utility call in this test")
      },
    )
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      booted.registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: Some(bot_id),
      ),
      bundle,
    )
  summary
}

/// The scripted stream: one round emitting a single complete
/// `bot_message(to, text)` tool call, then completing. The tool result
/// event (the receipt or the rendered refusal) is forwarded to `results`.
fn bot_message_stream(to: String, text: String) -> loop.StreamFn {
  let arguments = "{\"to\": \"" <> to <> "\", \"text\": \"" <> text <> "\"}"
  fn(_tr, _opts, on_event, _cancel) {
    on_event(openai.ToolCallDelta(
      0,
      Some("call_1"),
      Some("bot_message"),
      arguments,
    ))
    openai.Completed(completed_stats())
  }
}

fn completed_stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(10),
    duration_ms: 100,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 1,
    events_parsed: 3,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// The runner a bot thread under test runs: the REAL agent loop over the
/// real spec, driven by the scripted stream, with the delivery context the
/// REGISTRY wrapper handed in. Tool result events ride to `results`.
fn bot_message_runner(
  to: String,
  text: String,
  results: Subject(loop.LoopEvent),
) -> thread.TurnRunner {
  let stream = bot_message_stream(to, text)
  let assert Ok(specs) = tools.by_names(test_config(), ["bot_message"])
  fn(_endpoint, tr, cancel, delivery, on_event) {
    // The registry's per-thread wrapper must have built the context —
    // a bot thread's runner never runs without one.
    let assert Some(_) = delivery
    // The tool result (receipt / rendered refusal) also rides to the test.
    let recording = fn(event) {
      case event {
        loop.ToolResultEvent(..) -> process.send(results, event)
        _ -> Nil
      }
      on_event(event)
    }
    case loop.run(specs, 8, stream, tr, cancel, delivery, recording) {
      loop.LoopDone(stats, tr) -> thread.StreamDone(stats, tr)
      loop.LoopStopped(tr) -> thread.StreamStopped(tr)
      loop.LoopGuardHit(max, tr) -> thread.StreamGuard(max, tr)
      loop.LoopFailed(reason) -> thread.StreamErrored(reason)
    }
  }
}

/// A blocking runner: holds the turn open until cancelled — the busy-target
/// rig and the mid-turn delivery rig.
fn blocking_runner() -> thread.TurnRunner {
  fn(_endpoint, tr, cancel, _delivery, _on_event) {
    let selector =
      process.new_selector()
      |> process.select_map(cancel, fn(_) { Nil })
    let _ = process.selector_receive(selector, 10_000)
    thread.StreamStopped(tr)
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

/// Wait for a live thread's turn (each delivery spawns one — the DM
/// threads' scripted-less runners fail fast against the refused endpoint,
/// but asynchronously) to finish, so a follow-up send/delivery cannot
/// race it into Busy.
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

/// The newest message of a live thread's transcript, with its origin.
fn last_user_line(
  registry: Subject(thread_registry.Msg),
  thread_id: String,
) -> #(String, Option(transcript.Origin)) {
  let assert Ok(subject) = thread_registry.get(registry, thread_id)
  let tr = thread.snapshot(subject)
  let index = transcript.length(tr) - 1
  let messages = list.reverse(transcript.messages(tr))
  let assert [chat.UserMessage(content: chat.UserTextContent(text), ..), ..] =
    messages
  #(text, transcript.origin_at(tr, index))
}

fn last_user_depth(
  registry: Subject(thread_registry.Msg),
  thread_id: String,
) -> Int {
  let #(_, origin) = last_user_line(registry, thread_id)
  let assert Some(transcript.Origin(_, depth)) = origin
  depth
}

// ---------------------------------------------------------------------------
// The guard matrix (each refusal reason, in the settled order)
// ---------------------------------------------------------------------------

/// Unknown targets refuse: neither a thread id nor a bot name resolves.
pub fn deliver_unknown_target_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)

  deliver(booted.registry, alpha.id, "alpha", "s999", 1, "s4242", "hi")
  |> should.equal(delivery.Refused("unknown target"))

  deliver(booted.registry, alpha.id, "alpha", "s999", 1, "nobody", "hi")
  |> should.equal(delivery.Refused("unknown target"))
}

/// Self-addressing refuses BEFORE routing in BOTH shapes: by name (a
/// find-or-create would otherwise open a second, idle A-thread) and by
/// the sender's own thread id (the busy guard would also catch it, but
/// the self guard comes first in the settled order).
pub fn deliver_self_addressed_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let runner = blocking_runner()
  let own = create_bot_thread(booted, alpha.id, runner)

  deliver(booted.registry, alpha.id, "alpha", own.id, 1, "alpha", "echo?")
  |> should.equal(delivery.Refused("self-addressed delivery"))

  deliver(booted.registry, alpha.id, "alpha", own.id, 1, own.id, "echo?")
  |> should.equal(delivery.Refused("self-addressed delivery"))

  // Nothing was routed: no (alpha, alpha) DM thread exists behind the
  // refusals — the name lookup alone would have created one.
  should.equal(
    list.any(thread_registry.list_threads(booted.registry), fn(s) {
      s.bot_id == Some(alpha.id) && s.id != own.id
    }),
    False,
  )
}

/// An archived target refuses — archived is quiescent.
pub fn deliver_archived_target_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let beta = create_bot(booted, "beta", allow_inbound: True)
  let beta_thread = create_bot_thread(booted, beta.id, blocking_runner())

  let assert Ok(subject) = thread_registry.get(booted.registry, beta_thread.id)
  should.equal(
    thread_registry.set_archived(booted.registry, beta_thread.id, True),
    True,
  )
  let _ = subject

  deliver(booted.registry, alpha.id, "alpha", "s1", 1, beta_thread.id, "hi")
  |> should.equal(delivery.Refused("target thread is archived"))
}

/// The #95 inbound gate: `allow_inbound = False` refuses, read from the
/// STORE (this test would still pass with the bot registry unplugged for
/// lookups — the registry reads the seam, never another actor).
pub fn deliver_inbound_gate_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let closed = create_bot(booted, "closed", allow_inbound: False)
  let closed_thread = create_bot_thread(booted, closed.id, blocking_runner())

  // Name-addressed: the gate refuses before any DM thread is created.
  deliver(booted.registry, alpha.id, "alpha", "s1", 1, "closed", "hi")
  |> should.equal(delivery.Refused(
    "target does not accept inbound bot messages",
  ))
  // No litter: the refused name delivery left no thread behind.
  should.equal(
    list.any(thread_registry.list_threads(booted.registry), fn(s) {
      s.bot_id == Some(closed.id) && s.id != closed_thread.id
    }),
    False,
  )

  // Thread-id addressed to a bot thread: the same gate, read by the
  // thread's bot id.
  deliver(booted.registry, alpha.id, "alpha", "s1", 1, closed_thread.id, "hi")
  |> should.equal(delivery.Refused(
    "target does not accept inbound bot messages",
  ))
}

/// Hop depth: the inter-bot analogue of the iteration guard. A chain of
/// deliveries increments the depth each hop; delivering beyond
/// `max_bot_hops` (4) refuses.
pub fn deliver_hop_depth_chain_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let bots =
    list.map(["b1", "b2", "b3", "b4", "b5"], fn(name) {
      create_bot(booted, name, allow_inbound: True)
    })
  let _ = alpha

  // Hops 1..4 land (b1→b2→b3→b4); each delivered line carries its hop
  // number as the target's origin depth — the arithmetic the wrapper
  // reproduces per turn from the initiating message's sidecar.
  let chain =
    list.index_fold(
      list.take(bots, 4),
      "s-chain",
      fn(from_thread_id, bot, index) {
        let depth = index + 1
        let assert [target, ..] = list.drop(bots, index + 1)
        case
          deliver(
            booted.registry,
            bot.id,
            bot.name,
            from_thread_id,
            depth,
            target.name,
            "hop " <> string.inspect(depth),
          )
        {
          delivery.Delivered(thread_id) -> thread_id
          other ->
            panic as {
              "hop "
              <> string.inspect(depth)
              <> " should land: "
              <> string.inspect(other)
            }
        }
      },
    )

  // Hop 4 landed at depth 4 (the chain's last successful delivery went
  // into the fourth bot's DM thread — `chain` is its id).
  should.equal(last_user_depth(booted.registry, chain), 4)

  // Hop 5 exceeds max_bot_hops: refused even though every name resolves.
  let assert [fifth] = list.drop(bots, 4)
  deliver(
    booted.registry,
    fifth.id,
    fifth.name,
    chain,
    5,
    "alpha",
    "one hop too far",
  )
  |> should.equal(delivery.Refused("max bot hops exceeded"))
}

/// A busy target (mid-turn) answers Busy immediately — never queued —
/// and its transcript gains nothing.
pub fn deliver_busy_target_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let beta = create_bot(booted, "beta", allow_inbound: True)
  let beta_thread = create_bot_thread(booted, beta.id, blocking_runner())
  let assert Ok(subject) = thread_registry.get(booted.registry, beta_thread.id)
  should.equal(thread.send_message(subject, "human question"), thread.Sent)

  deliver(
    booted.registry,
    alpha.id,
    "alpha",
    "s1",
    1,
    beta_thread.id,
    "while you are busy",
  )
  |> should.equal(delivery.Busy)

  // Rejected, not queued: the transcript still holds only the human turn.
  let #(text, origin) = last_user_line(booted.registry, beta_thread.id)
  should.equal(text, "human question")
  should.equal(origin, None)
}

// ---------------------------------------------------------------------------
// Routing: name → DM find-or-create, thread id → direct
// ---------------------------------------------------------------------------

/// A name-addressed delivery find-or-creates the per-pair DM thread from
/// the TARGET bot, delivers the prefixed line (model-visible identity
/// rides content only), marks the display sidecar, and the receipt names
/// the DM thread. A second name delivery reuses the same thread.
pub fn deliver_by_name_creates_dm_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let beta = create_bot(booted, "beta", allow_inbound: True)

  let reply =
    deliver(
      booted.registry,
      alpha.id,
      "alpha",
      "s-alpha",
      1,
      "beta",
      "hello beta",
    )
  let assert delivery.Delivered(dm_id) = reply

  // The DM thread exists, belongs to the TARGET bot, and carries the
  // delivered line: the From prefix names the sender + the sender's
  // thread (so the target can reply precisely), and the origin sidecar
  // records author + hop depth for the UI badge.
  let #(text, origin) = last_user_line(booted.registry, dm_id)
  should.equal(text, "From alpha (thread s-alpha): hello beta")
  should.equal(origin, Some(transcript.Origin("alpha", 1)))

  let assert Ok(dm_summary) =
    list.find(thread_registry.list_threads(booted.registry), fn(s) {
      s.id == dm_id
    })
  should.equal(dm_summary.bot_id, Some(beta.id))

  // The second name-addressed delivery reuses the SAME DM thread (the
  // in-memory pair map) — no fresh thread per message.
  // Already waited above; re-check so a slow DM turn cannot race Busy.
  wait_idle(booted.registry, dm_id)
  let assert delivery.Delivered(dm_id2) =
    deliver(booted.registry, alpha.id, "alpha", "s-alpha", 1, "beta", "again")
  should.equal(dm_id2, dm_id)
  let #(text2, _) = last_user_line(booted.registry, dm_id)
  should.equal(text2, "From alpha (thread s-alpha): again")
}

/// Thread-id addressing goes direct (no DM map), including into a HUMAN
/// thread (no bot on the target — no gate to read).
pub fn deliver_by_thread_id_direct_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let specs = tools.by_names(test_config(), []) |> result.unwrap([])
  let assert Ok(human) =
    thread_registry.create_with_toolset(
      booted.registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: None,
      ),
      thread.Toolset(
        names: [],
        specs: specs,
        runner: blocking_runner(),
        utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
          Error("no utility call in this test")
        },
      ),
    )

  let assert delivery.Delivered(tid) =
    deliver(
      booted.registry,
      alpha.id,
      "alpha",
      "s-alpha",
      1,
      human.id,
      "dropping a note",
    )
  should.equal(tid, human.id)
  let #(text, origin) = last_user_line(booted.registry, human.id)
  should.equal(text, "From alpha (thread s-alpha): dropping a note")
  should.equal(origin, Some(transcript.Origin("alpha", 1)))
}

// ---------------------------------------------------------------------------
// Loop interaction: the tool end to end through a real turn
// ---------------------------------------------------------------------------

/// The full path: a bot thread's turn executes the real `bot_message`
/// spec against the real registries. The receipt renders as successful
/// tool content naming the DM thread; the wrapper computed depth 1 from
/// the human-initiated transcript (sidecar depth 0 + 1).
pub fn bot_message_tool_delivers_end_to_end_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let beta = create_bot(booted, "beta", allow_inbound: True)
  let _ = beta

  let results = process.new_subject()
  let alpha_thread =
    create_bot_thread(
      booted,
      alpha.id,
      bot_message_runner("beta", "hello from the loop", results),
    )
  let assert Ok(subject) = thread_registry.get(booted.registry, alpha_thread.id)
  should.equal(thread.send_message(subject, "please ping beta"), thread.Sent)

  // The tool result (the receipt) rides the loop's ToolResultEvent.
  let receipt = drain_tool_result(results)
  should.equal(receipt.ok, True)
  should.be_true(string.contains(
    receipt.content,
    "delivered to beta in thread s",
  ))

  // And the line landed in the DM thread with wrapper-computed depth 1.
  let dm_id = case
    thread_registry.list_threads(booted.registry)
    |> list.find(fn(s) { s.bot_id == Some(beta.id) })
  {
    Ok(summary) -> summary.id
    Error(_) -> panic as "DM thread not found"
  }
  let #(text, origin) = last_user_line(booted.registry, dm_id)
  should.equal(
    text,
    "From alpha (thread " <> alpha_thread.id <> "): hello from the loop",
  )
  should.equal(origin, Some(transcript.Origin("alpha", 1)))
}

/// Wrapper depth arithmetic: an inbound bot line at depth 1 initiates the
/// turn, so the tool delivers at depth 2 — computed from the initiating
/// user message's sidecar (persisted data, restart-safe).
pub fn bot_message_tool_depth_arithmetic_test() {
  let booted = boot()
  let epsilon = create_bot(booted, "epsilon", allow_inbound: True)
  let zeta = create_bot(booted, "zeta", allow_inbound: True)
  let _ = zeta

  let results = process.new_subject()
  let epsilon_thread =
    create_bot_thread(
      booted,
      epsilon.id,
      bot_message_runner("zeta", "replying", results),
    )

  // Simulate hop 1: another bot's delivery lands in epsilon's thread at
  // depth 1 (direct thread-id addressing). The delivery IS the turn
  // initiator — it spawns epsilon's scripted turn, which runs the tool.
  // (A HUMAN send here would reset the depth to 0 — that reset is the
  // spec, and the chain test covers multi-hop arithmetic separately.)
  let assert delivery.Delivered(_) =
    deliver(
      booted.registry,
      create_bot(booted, "outbound", allow_inbound: True).id,
      "outbound",
      "s-outbound",
      1,
      epsilon_thread.id,
      "your turn",
    )

  // Epsilon's delivery-initiated turn runs the tool: its reply must
  // carry depth 2 (initiating sidecar depth 1 + 1).
  let receipt = drain_tool_result(results)
  should.be_true(string.contains(
    receipt.content,
    "delivered to zeta in thread s",
  ))

  let dm_id = case
    thread_registry.list_threads(booted.registry)
    |> list.find(fn(s) { s.bot_id == Some(zeta.id) })
  {
    Ok(summary) -> summary.id
    Error(_) -> panic as "DM thread not found"
  }
  should.equal(last_user_depth(booted.registry, dm_id), 2)
}

/// Guard refusals render as FAILED tool results — tool errors are not
/// loop errors — and the sender's deleted-bot edge is an honest tool
/// error from the ask-at-send name lookup.
pub fn bot_message_tool_refusals_test() {
  let booted = boot()
  let alpha = create_bot(booted, "alpha", allow_inbound: True)
  let closed = create_bot(booted, "closed", allow_inbound: False)

  let results = process.new_subject()
  let alpha_thread =
    create_bot_thread(
      booted,
      alpha.id,
      bot_message_runner("closed", "anyone there?", results),
    )
  let assert Ok(subject) = thread_registry.get(booted.registry, alpha_thread.id)
  should.equal(thread.send_message(subject, "go"), thread.Sent)
  let receipt = drain_tool_result(results)
  should.equal(receipt.ok, False)
  should.equal(
    receipt.content,
    "{\"error\":\"bot_message refused: target does not accept inbound bot messages\"}",
  )
  let _ = closed
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type ToolReceipt {
  ToolReceipt(call_id: String, ok: Bool, content: String)
}

fn drain_tool_result(events: Subject(loop.LoopEvent)) -> ToolReceipt {
  case process.receive(events, 5000) {
    Ok(loop.ToolResultEvent(call_id, _, ok, content)) ->
      ToolReceipt(call_id, ok, content)
    Ok(_) -> drain_tool_result(events)
    Error(Nil) -> panic as "no tool result event within the budget"
  }
}
