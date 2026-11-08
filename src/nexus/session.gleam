//// The M1 session actor: one process owns the single session's transcript,
//// fan-out to SSE subscribers, and the per-turn worker lifecycle.
////
//// Concurrency model (PRD: "one actor per session"):
////
//// - The actor never blocks on the network. Each turn spawns an **unlinked,
////   monitored** worker process that runs the seam (`stream_with_cancel`)
////   and reports deltas back as messages; a crashed worker or SSE handler
////   (verdict finding 9) therefore cannot take the session actor down.
//// - One turn at a time (M1). A `Send` while a turn is streaming is
////   rejected as `Busy`.
//// - `Stop` cancels the in-flight turn through the seam's cancel subject;
////   partial text received so far is committed as the assistant turn.
////
//// Utility side-call (utility-titles plan §4.2): after the first committed
//// exchange, a debounced, once-per-session title branch runs in its own
//// unlinked worker beside the turn machinery. It is invisible to callers —
//// a `Send` cancels it instead of reporting `Busy` — and structurally
//// isolated: the branch never enters the session's transcript, like the
//// reasoning sidecar.
////
//// KV-cache contract: the transcript is only ever appended to
//// (`append_user` / `append_assistant`), and every request is rebuilt from
//// the immutable message list through `nexus/transcript.to_request` — the
//// single encode path guarded by the golden test. A failed turn commits
//// nothing, so retrying sends a byte-identical prefix.
////
//// M2 adds per-session model pinning (`SessionSpec`), turn metrics kept
//// outside the transcript, and the `Describe` request the registry uses to
//// build sidebar summaries.

import gleam/dict
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glopenai/chat
import glopenai/shared.{type CompletionUsage}
import nexus/config.{type Config}
import nexus/loop
import nexus/openai
import nexus/timing
import nexus/tools
import nexus/transcript.{type Transcript}
import nexus/utility

/// One fan-out delivery: the emitting session's id and the receiving
/// subscriber's current visit generation, stamped beside the payload
/// (`EventKind`). Both are filter keys, not bookkeeping: a subscriber
/// shares ONE event subject across every session it visits
/// (`nexus/ui.events_effect`), and `Leave` cannot stop broadcasts that
/// are already in the subscriber's mailbox when it lands — cross-actor
/// message ordering gives no guarantee. Carrying both lets the UI drop
/// anything not from the session it is viewing NOW: the id covers
/// deliveries from other sessions, the visit generation covers stale
/// deliveries from an EARLIER visit to the same session (a rapid
/// A→B→A switch would otherwise re-apply queued first-visit events on
/// top of the second visit's replay — the cross-session
/// stream-contamination bug and its same-session cousin).
pub type SessionEvent {
  SessionEvent(session_id: String, visit: Int, kind: EventKind)
}

/// The fan-out payload. Always delivered inside a `SessionEvent` envelope
/// stamped with the emitting session's id.
pub type EventKind {
  /// Sent once to a fresh subscriber after `Join` (before any replay).
  Hello(model: String, messages: Int, metrics: List(MetricSample))
  /// A user turn, echoed so every tab sees it. Also used for history replay.
  UserEcho(text: String)
  /// A complete assistant turn, used for history replay on (re)connect.
  AssistantFull(text: String)
  /// A committed assistant message's full reasoning — history replay,
  /// always sent just before that message's own events.
  ReasoningFull(text: String)
  /// A streamed fragment of the assistant turn in flight.
  Token(text: String)
  /// A streamed fragment of the model's reasoning (chain of thought),
  /// emitted before any content. Display-only — reasoning is never
  /// replayed into a request.
  Reasoning(text: String)
  /// The turn finished; stats for the metrics line.
  TurnDone(stats: openai.StreamStats)
  /// The turn was stopped by the user; `chars` were committed.
  TurnStopped(chars: Int)
  /// The turn failed (non-200 / transport / decode); nothing was committed.
  TurnFailed(reason: String)
  /// M3: a fragment of a native tool call, still unassembled.
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    fragment: String,
  )
  /// M3: a fully-assembled tool call about to be executed. Also used for
  /// history replay of assistant tool-call messages.
  ToolCallAssembled(id: String, name: String, arguments: String)
  /// M3: a tool finished. `content` is truncated/inert. Also used for
  /// replay of tool result messages.
  ToolResult(call_id: String, name: String, ok: Bool, content: String)
  /// M3: loop progress — `iteration` is 1-based; `phase` is "request",
  /// "tools", or "guard" (terminal rendering when the guard trips).
  LoopStatus(iteration: Int, max_iterations: Int, phase: String)
  /// The session's organizational metadata changed server-side — P2: the
  /// model-generated title upgrade landed. Broadcast to subscribers ONLY
  /// when something applied, so every connected tab refreshes its sidebar
  /// (the registry mutations of the acting client refresh via their own
  /// reply path). Display metadata; never enters a request body.
  MetaUpdated(title: Option(String), tags: List(String))
}

/// What a turn runner reports when its blocking stream returns. The
/// worker owns the transcript mutation for the turn (M3 tool rounds append
/// assistant tool-call and tool-result messages as they happen); on every
/// non-error outcome it returns the extended transcript, which the actor
/// installs wholesale. On `StreamErrored` nothing is committed — the
/// actor's own transcript is untouched, so a retry resends a
/// byte-identical prefix.
pub type TurnOutcome {
  StreamDone(stats: openai.StreamStats, transcript: Transcript)
  StreamStopped(transcript: Transcript)
  StreamGuard(max_iterations: Int, transcript: Transcript)
  StreamErrored(reason: String)
}

/// A blocking turn runner. Runs inside a dedicated worker process; must
/// honour the cancel subject (see `agent_runner` for the real one and the
/// tests for fakes). The endpoint is the session's frozen provider
/// endpoint — resolved once at create/hydration, never swapped mid-session
/// (multi-provider plan §8; a provider change is a fork, not an edit).
pub type TurnRunner =
  fn(openai.Endpoint, Transcript, Subject(Nil), fn(loop.LoopEvent) -> Nil) ->
    TurnOutcome

/// The utility side-call seam (utility-titles plan §4.2): ONE blocking
/// model round-trip over a committed transcript snapshot — the title
/// branch. Returns `Ok(utility.Pass)` when the model defers (honored only
/// while passes remain — the actor owns that policy), `Ok(utility.Title)`
/// for a parsed title, or `Error` for anything unusable (transport
/// failure, cancellation, a tool-call answer, a refusal, or a PASS under
/// the forced instruction): best-effort, discarded, never retried. The
/// endpoint is the session's frozen one; `cancel` must be owned by the
/// calling process.
pub type UtilityRunner =
  fn(openai.Endpoint, Transcript, Subject(Nil), Bool) ->
    Result(utility.Verdict, String)

/// Fresh display metadata as the apply step reports it: what actually
/// landed, carried to the `MetaUpdated` broadcast.
pub type UtilityMeta {
  UtilityMeta(title: String, tags: List(String))
}

/// The apply seam: guarded title + tags application — in production the
/// registry `UpgradeAutoTitle` ask (guard: `title_source = 'auto'` AND
/// `tags_source = 'auto'`, utility-tags plan §3.5), injected exactly like
/// the turn runner so this module never depends on the registry
/// (dependency direction stays registry → session, and the session actor
/// never blocks on an ask). `Error` when the guard refused (a manual
/// rename or a manual tag edit wins forever, unknown id, empty title).
/// The title argument is line 1 of the utility reply; the tags argument
/// is the parsed, normalized, corpus-capped line 2 (zero tags when the
/// reply had none — best-effort).
pub type UtilityApply =
  fn(String, List(String)) -> Result(UtilityMeta, Nil)

/// What a completed utility attempt reports to the actor.
pub type UtilityResult {
  /// The guard applied the title; carries the fresh display metadata.
  UtilityApplied(title: String, tags: List(String))
  /// The model replied PASS (honored only on an allow-pass attempt): no
  /// title yet, and the once-per-session attempt is NOT consumed — the
  /// debounce re-arms at the next turn-commit point. Exactly
  /// `max_utility_passes` passes are honored; later attempts run under
  /// the forced instruction, where a PASS reply arrives as
  /// `UtilityFailed` instead (the forced attempt cannot defer again).
  UtilityPassed
  /// Nothing applied: stream failed/cancelled, or the guard refused.
  UtilityFailed
}

/// The real utility runner (utility-titles plan §4.2, extended by the
/// utility-tags plan §3.3), built ONCE at boot beside `agent_runner`:
/// closes over the shared frozen envelope (`loop.frozen_options` —
/// byte-identical to every turn request by construction), so the only
/// per-call delta is the generation-side token cap applied inside
/// `utility.run`. `specs` is the same boot-frozen tool registry the agent
/// loop uses — never a per-session set.
///
/// `corpus` supplies the reuse vocabulary for the instruction (Y): a
/// closure asked from INSIDE the utility worker right before the one
/// request — in production the registry's `TagCorpus` ask over its
/// registered name, exactly the `utility_apply_for` ask pattern. Y is the
/// tail message (generation-side, never committed), so a dynamic corpus
/// cannot touch the cached prefix.
pub fn utility_runner(
  specs: List(tools.ToolSpec),
  corpus: fn() -> List(String),
) -> UtilityRunner {
  let base = loop.frozen_options(specs)
  fn(endpoint, tr, cancel, allow_pass) {
    utility.run(endpoint, tr, base, cancel, allow_pass, corpus())
  }
}

pub type SendResult {
  Sent
  Busy
}

/// Everything needed to construct one session actor. The alias is frozen at
/// construction (M2 §4.1): the transcript is created from `model`, never
/// from a config default, and the config itself is never mutated.
///
/// Multi-provider P3 adds the second frozen half of the pin: `endpoint`,
/// the provider transport resolved by the registry at create/hydration
/// and held for the session's lifetime. Together `model` + `endpoint`
/// fix every request byte of the session (KV-cache contract rule 5).
///
/// Phase 2 adds two seams, both injected by the registry so this module
/// never depends on it (dependency direction stays registry → session):
///
/// - `commit_hook` is called with the committed transcript at every commit
///   point (user append, turn completion). It is a non-blocking observer —
///   the store's write-behind lane — and must never mutate or encode
///   anything; the transcript it receives is the immutable actor state.
/// - `hydrate` optionally supplies the transcript to start from. It must
///   have been built through `nexus/transcript.new` + the `append_*`
///   functions (the one construction path); a hydrated actor therefore
///   re-encodes byte-identically by construction.
///
/// Utility-titles P2 adds two more injected seams, again built by the
/// registry so the dependency direction stays registry → session:
///
/// - `utility_runner` performs the one side-call (title branch) over a
///   committed transcript snapshot; the real one is `utility_runner`
///   below, tests inject fakes.
/// - `utility_apply` lands the parsed title + tags behind the registry's
///   provenance guards (`title_source` AND `tags_source` both 'auto'; a
///   manual rename or manual tag edit wins forever).
pub type SessionSpec {
  SessionSpec(
    /// The session's own id (registry-assigned). Stamped onto every
    /// fan-out event as the subscriber-side filter key — see
    /// `SessionEvent`.
    id: String,
    cfg: Config,
    model: String,
    /// The frozen provider endpoint — what the runner streams through.
    endpoint: openai.Endpoint,
    runner: TurnRunner,
    /// Write-behind observer; `fn(_) { Nil }` when nobody persists.
    commit_hook: fn(Transcript) -> Nil,
    /// Starting transcript for a hydrated (restored) session; `None`
    /// builds `transcript.new(model, cfg.system_prompt)` as before.
    hydrate: Option(Transcript),
    /// The utility side-call (title branch) — see `UtilityRunner`.
    utility_runner: UtilityRunner,
    /// Guarded title application — see `UtilityApply`.
    utility_apply: UtilityApply,
  )
}

/// How a turn ended. Drives the metrics panel row.
pub type MetricOutcome {
  Completed
  Stopped
  Failed
}

/// One turn's metrics. Display state only — never passed to
/// `nexus/transcript` or into any request body.
pub type MetricSample {
  MetricSample(
    outcome: MetricOutcome,
    ttft_ms: Option(Int),
    duration_ms: Int,
    token_deltas: Int,
    prompt_tokens: Option(Int),
    cached_tokens: Option(Int),
    stopped_chars: Option(Int),
    failure_reason: Option(String),
  )
}

/// How a session's display title came to be. Organizational metadata —
/// lives beside the transcript in the registry, never in a request body.
pub type TitleSource {
  AutoTitle
  ManualTitle
}

/// How a session's tag set is governed (utility-tags plan §3.4):
/// `AutoTags` — model tags may still merge into the display set;
/// `ManualTags` — a manual tag edit froze the set forever (the guard IS
/// the tombstone: a user-deleted auto tag can never resurrect). Mirrors
/// `tags_source` in the schema ('auto' | 'manual'). Organizational
/// metadata beside the transcript; the UI-facing `SessionSummary`
/// deliberately does not carry it — chips are provenance-indistinguishable.
pub type TagsSource {
  AutoTags
  ManualTags
}

/// What a session reports about itself; the registry fills in the
/// user-visible `id` and the organizational metadata when it builds a
/// `SessionSummary`.
pub type SessionStatus {
  SessionStatus(
    model: String,
    message_count: Int,
    streaming: Bool,
    metrics: List(MetricSample),
    /// Wall-clock epoch seconds of the newest committed message (0 while
    /// the transcript holds only the system prompt). Display ordering
    /// only — the transcript itself never stores a timestamp.
    last_commit_at: Int,
  )
}

/// Sidebar row (M2 §4.2). `id` is assigned by the registry, never by the
/// session, and never enters the transcript. The M3 organization fields
/// (title, title_source, pinned, tags, archived, created_at,
/// last_active_at) are registry-owned metadata: they ride beside the
/// transcript and must never alter a single request byte (KV-cache
/// contract — guarded by the golden metadata-isolation test).
pub type SessionSummary {
  SessionSummary(
    id: String,
    /// The pinned provider (its registry id; display names are resolved
    /// by the caller — the UI looks the name up in its provider list, so
    /// the session registry stays decoupled from the provider registry).
    /// A rename never reaches summaries; a provider cannot be deleted
    /// while sessions pin it, so the id always resolves.
    provider_id: String,
    model: String,
    title: String,
    title_source: TitleSource,
    pinned: Bool,
    tags: List(String),
    archived: Bool,
    message_count: Int,
    streaming: Bool,
    created_at: Int,
    last_active_at: Int,
    metrics: List(MetricSample),
  )
}

pub type Msg {
  /// Subscribe `sub` to session events (replies with Hello + replay).
  /// `visit` is the subscriber-issued generation for THIS visit; the
  /// actor echoes it on every delivery to `sub` (replacing any previous
  /// generation for the same subject), so the subscriber can drop
  /// deliveries left over from an earlier visit to this session.
  Join(sub: Subject(SessionEvent), visit: Int)
  /// Unsubscribe `sub` from session events (unknown subs are ignored).
  Leave(sub: Subject(SessionEvent))
  /// Append a user turn and start streaming a reply.
  Send(text: String, reply: Subject(SendResult))
  /// Cancel the in-flight turn, if any.
  Stop
  /// Current transcript (for M2 session resume / tests).
  Snapshot(reply: Subject(Transcript))
  /// Current status for the registry's session list (M2 §4.2).
  Describe(reply: Subject(SessionStatus))
  /// Worker plumbing (internal).
  TurnStarted(worker: Pid, cancel: Subject(Nil))
  WorkerEvent(worker: Pid, event: loop.LoopEvent)
  WorkerDone(worker: Pid, outcome: TurnOutcome)
  /// Utility plumbing (internal, utility-titles plan §4.2): the debounce
  /// fired, a worker took the cancel subject, an attempt completed.
  UtilityStart
  UtilityStarted(worker: Pid, cancel: Subject(Nil))
  UtilityDone(worker: Pid, result: UtilityResult)
  /// Monitor plumbing: a monitored process went down.
  WorkerDown(worker: Pid)
  /// Selector plumbing for non-process monitors; always ignored.
  MonitorNoise
}

/// One fan-out subscriber: its current visit generation (echoed on every
/// delivery — the subscriber-side filter key, see `SessionEvent`) and the
/// owner monitor taken at Join, demonitored on Leave so cycling away and
/// back cannot accumulate monitors on the same connection.
type Subscriber {
  Subscriber(visit: Int, monitor: Option(Monitor))
}

type TurnState {
  Idle
  Starting(worker: Pid, monitor: Monitor, stop_requested: Bool, started_us: Int)
  Streaming(
    worker: Pid,
    monitor: Monitor,
    cancel: Subject(Nil),
    acc: String,
    deltas: Int,
    started_us: Int,
    first_delta_us: Option(Int),
  )
}

/// Display-only mirror of the turn in flight: the transcript as of `Send`
/// (committed prefix + the user message) plus every round the worker has
/// appended so far, rebuilt from the same loop events that are broadcast
/// to subscribers. The worker owns the real extended transcript and only
/// hands it over at `WorkerDone`, so without this mirror a client that
/// joins mid-turn — a page reload or a session switch — replays nothing
/// of the running turn: its already-executed tool rounds and reasoning
/// would never render (regression: chips vanished on refresh mid-turn).
///
/// It never touches request encoding: `to_request` reads only the
/// committed `transcript`, and the mirror is dropped at `WorkerDone`
/// (committed or failed alike), so the KV-cache byte contract is
/// structurally unaffected. Fidelity note: an iteration's text flushes at
/// the loop's own phase boundaries ("tools" / first assembled call), so
/// the FINAL iteration's still-streaming text is not mirrored — no event
/// fires between stream close and the terminal broadcast. Chips and
/// reasoning — the parts that made refreshes lose history — are.
type LiveTurn {
  LiveTurn(
    view: Transcript,
    /// Content tokens accumulated since the iteration began (reset at the
    /// loop's "request" phase, flushed into `view` at "tools").
    text: String,
    /// Reasoning accumulated since the iteration began. Consumed by the
    /// text flush when text exists, else attached to the first assembled
    /// call — mirroring `append_calls`' one-message-with-reasoning shape.
    reasoning: String,
  )
}

/// Utility side-call lifecycle (utility-titles plan §4.2). Mirrors the
/// turn lifecycle but is invisible to callers: the session never reports
/// `Busy` because of a side call. `cancelled` is set when a `Send` raced
/// the attempt — a cancelled attempt's completion must not consume
/// `utility_attempted`.
type UtilityState {
  UtilityIdle
  UtilityStarting(worker: Pid, monitor: Monitor, cancelled: Bool)
  UtilityRunning(
    worker: Pid,
    monitor: Monitor,
    cancel: Subject(Nil),
    cancelled: Bool,
  )
}

/// Newest-first cap on stored metric samples (M2 §4.2).
const metrics_cap = 20

/// How many PASS replies the session honors before the forced instruction
/// takes over (utility-titles §4.2, PASS postpone): one. A postponed
/// attempt is nearly free under the cached prefix (~Y + title tokens), but
/// an uncapped pass-forever policy would re-arm a side call after every
/// turn of a perpetual small-talk session and never converge to a title.
const max_utility_passes = 1

type State {
  State(
    /// This session's id (`SessionSpec.id`): stamped onto every fan-out
    /// event as the subscriber-side filter key — see `SessionEvent`.
    id: String,
    cfg: Config,
    endpoint: openai.Endpoint,
    runner: TurnRunner,
    transcript: Transcript,
    /// Fan-out subscribers by event subject, each carrying its current
    /// visit generation (echoed on every delivery) and the owner monitor
    /// taken at Join — demonitored on Leave so cycling away and back
    /// cannot accumulate monitors.
    subs: dict.Dict(Subject(SessionEvent), Subscriber),
    turn: TurnState,
    /// The in-flight turn's display mirror (see `LiveTurn`). `Some` from
    /// `Send` until `WorkerDone`/`WorkerDown` — committed or failed alike.
    /// Read by `Join` replay only.
    turn_view: Option(LiveTurn),
    self: Subject(Msg),
    metrics: List(MetricSample),
    /// Wall-clock epoch seconds of the newest committed message (0 until
    /// the first user turn). Display ordering only.
    last_commit_s: Int,
    /// Phase 2 write-behind observer — the store's commit lane. Runs at
    /// commit points only, is a plain send, and never blocks.
    commit_hook: fn(Transcript) -> Nil,
    /// Utility side-call state (utility-titles plan §4.2).
    utility: UtilityState,
    /// A debounce is OWED: `UtilityStart` fired while a turn was in flight
    /// (the side call must not queue behind it), or the turn-commit-point
    /// arm ran while a side call was still unreported — the trigger is
    /// deferred to the turn's end (committed or failed) or to the running
    /// attempt's completion, instead of being dropped or rescheduled (a
    /// timer-based re-arm would spin at delay 0). Whoever finds the
    /// session idle consumes this: the commit-point arm and
    /// `finish_utility` both deliver through `arm_utility`.
    utility_pending: Bool,
    /// The session's ONE title attempt (utility-titles plan §4.2). Flips
    /// only when an attempt COMPLETES (applied or failed) — never when one
    /// is armed or cancelled — so a fast follow-up can kill at most the
    /// in-flight try, never the session's only one.
    utility_attempted: Bool,
    /// PASS replies honored so far. Gates the instruction variant handed
    /// to the runner: below `max_utility_passes` the attempt may pass,
    /// after it the forced instruction applies and a PASS reply counts as
    /// a failure. Bumped only when a `UtilityPassed` completes.
    utility_passes: Int,
    /// The injected side-call seams (see `SessionSpec`): the LLM branch
    /// and the guarded title application, both run by the unlinked worker.
    utility_runner: UtilityRunner,
    utility_apply: UtilityApply,
  )
}

/// The real turn runner (M3): the bounded agent loop over the frozen tool
/// registry. `specs` is built once at boot from the global config — never
/// per session — so the tool schema is identical in every request; the
/// endpoint arrives per call and is the session's frozen one.
pub fn agent_runner(
  max_iterations: Int,
  specs: List(tools.ToolSpec),
) -> TurnRunner {
  fn(endpoint, tr, cancel, on_event) {
    case
      loop.run(
        specs,
        max_iterations,
        // The session's frozen endpoint threads straight through: one
        // provider per session for every iteration of every turn
        // (byte-identical prefixes, single encode path).
        loop.endpoint_stream(endpoint),
        tr,
        cancel,
        on_event,
      )
    {
      loop.LoopDone(stats, tr) -> StreamDone(stats, tr)
      loop.LoopStopped(tr) -> StreamStopped(tr)
      loop.LoopGuardHit(max, tr) -> StreamGuard(max, tr)
      loop.LoopFailed(reason) -> StreamErrored(reason)
    }
  }
}

/// Start the session actor standalone with an explicit spec (M2 §7 step 1).
pub fn start_with_spec(spec: SessionSpec) -> actor.StartResult(Subject(Msg)) {
  start_builder(spec) |> actor.start
}

/// Child specification for the supervision tree (boot).
pub fn supervised(
  spec: SessionSpec,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  start_builder(spec)
  |> actor.named(name)
  |> actor.start
}

fn start_builder(spec: SessionSpec) {
  let SessionSpec(
    id: id,
    cfg: cfg,
    model: model,
    endpoint: endpoint,
    runner: runner,
    commit_hook: commit_hook,
    hydrate: hydrate,
    utility_runner: utility_runner,
    utility_apply: utility_apply,
  ) = spec
  actor.new_with_initialiser(1000, fn(self) {
    actor.initialised(State(
      id: id,
      cfg: cfg,
      endpoint: endpoint,
      runner: runner,
      // The selected alias is frozen into the transcript (M2 §4.1);
      // the provider endpoint is frozen beside it (multi-provider §8).
      // A hydrated session starts from the rebuilt transcript — built by
      // the very same `transcript.new` + `append_*` path, so the actor
      // re-encodes byte-identically (KV-cache contract).
      transcript: case hydrate {
        Some(restored) -> restored
        None -> transcript.new(model, cfg.system_prompt)
      },
      subs: dict.new(),
      turn: Idle,
      turn_view: None,
      utility: UtilityIdle,
      utility_pending: False,
      // A hydrated (restored) session's first exchange predates this actor:
      // the utility-titles plan's §8 proposal — only sessions whose first
      // exchange happens in the actor's lifetime attempt the upgrade. A
      // restart therefore never re-titles an already-upgraded session (the
      // upgrade leaves title_source = 'auto', so the store alone cannot
      // tell "upgraded" from "still the heuristic placeholder").
      utility_attempted: case hydrate {
        Some(_) -> True
        None -> False
      },
      // A hydrated session never attempts anyway (above), so the pass
      // count starts at zero in both cases and never moves.
      utility_passes: 0,
      self: self,
      metrics: [],
      last_commit_s: 0,
      commit_hook: commit_hook,
      utility_runner: utility_runner,
      utility_apply: utility_apply,
    ))
    |> actor.returning(self)
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(_, pid, _) -> WorkerDown(pid)
          process.PortDown(_, _, _) -> MonitorNoise
        }
      }),
    )
    |> Ok
  })
  |> actor.on_message(handle)
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Join(sub, visit) -> {
      // Deliveries to the JOINING subscriber carry its visit generation:
      // the filter key that lets it drop leftovers from an earlier visit
      // to this session (see `SessionEvent`).
      let deliver = fn(kind) {
        process.send(sub, SessionEvent(state.id, visit, kind))
      }
      deliver(Hello(
        transcript.model(state.transcript),
        transcript.length(state.transcript),
        state.metrics,
      ))
      // Replay existing history so a fresh page load / reconnect sees the
      // session (system prompt stays server-side, per the cache contract).
      // M3: tool history is replayed too — assistant tool-call messages as
      // `ToolCallAssembled`, tool results as `ToolResult` — so a reconnect
      // can rebuild the full tool state (names resolved from earlier
      // assistant messages, since tool messages only carry ids).
      //
      // While a turn is in flight the worker holds the extended
      // transcript, so the committed one would replay nothing of the
      // running turn. Replay the display mirror instead: the rounds the
      // worker already finished (chips + reasoning) render as history,
      // and the client then joins the live stream from the current point.
      let replay = case state.turn_view {
        Some(live) -> live.view
        None -> state.transcript
      }
      let names =
        replay
        |> transcript.messages
        |> list.fold(dict.new(), fn(names, message) {
          case message {
            chat.AssistantMessage(tool_calls: Some(calls), ..) ->
              list.fold(calls, names, fn(names, call) {
                let chat.FunctionToolCall(id: id, function: f) = call
                dict.insert(names, id, f.name)
              })
            _ -> names
          }
        })
      replay
      |> transcript.messages
      |> list.index_fold(Nil, fn(_, message, index) {
        case message {
          chat.UserMessage(content: chat.UserTextContent(text), ..) ->
            deliver(UserEcho(text))
          chat.AssistantMessage(content: text, tool_calls: calls, ..) -> {
            // Reasoning replay first: it was streamed before the message's
            // own output, so it replays before it too.
            case transcript.reasoning_at(replay, index) {
              Some(reasoning) -> deliver(ReasoningFull(reasoning))
              None -> Nil
            }
            case text {
              Some(chat.AssistantTextContent(content)) ->
                deliver(AssistantFull(content))
              _ -> Nil
            }
            case calls {
              Some(calls) ->
                list.each(calls, fn(call) {
                  let chat.FunctionToolCall(id: id, function: f) = call
                  deliver(ToolCallAssembled(id, f.name, f.arguments))
                })
              None -> Nil
            }
          }
          chat.ToolMessage(
            content: chat.ToolTextContent(content),
            tool_call_id: id,
          ) ->
            deliver(ToolResult(
              id,
              dict.get(names, id) |> result.unwrap("tool"),
              // The outcome rides the display-only sidecar — failed
              // calls stay failed across a reload (True when unknown,
              // e.g. rows persisted before the sidecar existed).
              transcript.tool_result_at(replay, index)
                |> option.unwrap(True),
              content,
            ))
          _ -> Nil
        }
        Nil
      })
      // M3: the UI component keeps one long-lived subscription across
      // reconnects, so a re-Join must not duplicate the fan-out entry —
      // it REFRESHES the visit generation instead (the stale-delivery
      // filter keys off it, see `SessionEvent`) and keeps the existing
      // owner monitor. Per-client break: subscriber subjects are owned
      // by per-connection Lustre runtimes that die with their sockets —
      // monitor a new subscriber's owner so its exit prunes the entry in
      // the `WorkerDown` arm (every monitored ProcessDown funnels there).
      let subs = case dict.get(state.subs, sub) {
        Ok(subscriber) ->
          dict.insert(state.subs, sub, Subscriber(..subscriber, visit: visit))
        Error(_) -> {
          let monitor = case process.subject_owner(sub) {
            Ok(owner) -> Some(process.monitor(owner))
            Error(_) -> None
          }
          dict.insert(state.subs, sub, Subscriber(visit:, monitor:))
        }
      }
      actor.continue(State(..state, subs: subs))
    }

    Leave(sub) -> {
      // A subscriber that moved to another session. The UI component keeps
      // ONE long-lived event subject per connection and re-Joins it on
      // every session switch (`nexus/ui.join_effect`), so a switch must
      // Leave here explicitly: nothing else removes a live subscriber —
      // the owner monitor only fires when the subscriber's process dies —
      // and without the removal this session's stream kept fanning out to
      // the shared subject, rendering into the OTHER session's view
      // (cross-session contamination while a turn was in flight).
      //
      // Demonitor on the way out: a subscriber that cycles away and back
      // would otherwise accumulate one dangling monitor per visit on the
      // same connection.
      let state = case dict.get(state.subs, sub) {
        Ok(subscriber) -> {
          case subscriber.monitor {
            Some(monitor) -> process.demonitor_process(monitor)
            None -> Nil
          }
          State(..state, subs: dict.delete(state.subs, sub))
        }
        Error(_) -> state
      }
      actor.continue(state)
    }

    Send(text, reply) -> {
      // A utility side-call in flight never blocks a send: cancel it and
      // proceed normally — the session must never report `Busy` because of
      // a side call (required fairness on serialized backends: the side
      // call would otherwise queue the user's turn behind it). The
      // cancelled attempt does not consume `utility_attempted`; the next
      // turn-commit point re-arms the debounce.
      let state = cancel_utility(state)
      case state.turn {
        Idle -> {
          let tr = transcript.append_user(state.transcript, text)
          emit(state, UserEcho(text))
          let worker =
            process.spawn_unlinked(fn() {
              let cancel = process.new_subject()
              let pid = process.self()
              process.send(state.self, TurnStarted(pid, cancel))
              let on_event = fn(event) {
                process.send(state.self, WorkerEvent(pid, event))
              }
              let outcome = state.runner(state.endpoint, tr, cancel, on_event)
              process.send(state.self, WorkerDone(pid, outcome))
            })
          let monitor = process.monitor(worker)
          process.send(reply, Sent)
          // Write-behind: hand the committed transcript to the store's
          // lane (a plain send — never blocks the actor).
          let _ = state.commit_hook(tr)
          actor.continue(
            State(
              ..state,
              transcript: tr,
              turn: Starting(worker, monitor, False, timing.now_us()),
              // The mirror starts from the send-time transcript (user
              // message included): a mid-turn join replays it while the
              // worker streams the reply.
              turn_view: Some(LiveTurn(tr, "", "")),
              // The user message is committed the moment it is appended
              // (even a failed turn keeps it), so activity starts here.
              last_commit_s: timing.wall_now_s(),
            ),
          )
        }
        Streaming(..) | Starting(..) -> {
          process.send(reply, Busy)
          actor.continue(state)
        }
      }
    }

    Stop ->
      case state.turn {
        Idle -> actor.continue(state)
        Starting(_worker, _monitor, True, _started_us) -> actor.continue(state)
        Starting(worker, monitor, False, started_us) ->
          actor.continue(
            State(..state, turn: Starting(worker, monitor, True, started_us)),
          )
        Streaming(_, _, cancel, _, _, _, _) -> {
          process.send(cancel, Nil)
          actor.continue(state)
        }
      }

    Snapshot(reply) -> {
      process.send(reply, state.transcript)
      actor.continue(state)
    }

    Describe(reply) -> {
      process.send(
        reply,
        SessionStatus(
          model: transcript.model(state.transcript),
          message_count: transcript.length(state.transcript),
          streaming: case state.turn {
            Idle -> False
            Starting(..) | Streaming(..) -> True
          },
          metrics: state.metrics,
          last_commit_at: state.last_commit_s,
        ),
      )
      actor.continue(state)
    }

    TurnStarted(worker, cancel) ->
      case state.turn {
        Starting(candidate, monitor, stop_requested, started_us)
          if candidate == worker
        -> {
          case stop_requested {
            True -> process.send(cancel, Nil)
            False -> Nil
          }
          actor.continue(
            State(
              ..state,
              turn: Streaming(worker, monitor, cancel, "", 0, started_us, None),
            ),
          )
        }
        _ -> actor.continue(state)
      }

    WorkerEvent(worker, event) ->
      case state.turn, event {
        Streaming(candidate, monitor, cancel, acc, deltas, started_us, first),
          loop.StreamEvent(openai.TokenDelta(text))
          if candidate == worker
        -> {
          emit(state, Token(text))
          actor.continue(
            State(
              ..state,
              turn: Streaming(
                candidate,
                monitor,
                cancel,
                acc <> text,
                deltas + 1,
                started_us,
                case first {
                  Some(_) -> first
                  None -> Some(timing.now_us())
                },
              ),
              turn_view: option.map(state.turn_view, fn(live) {
                LiveTurn(..live, text: live.text <> text)
              }),
            ),
          )
        }

        // Reasoning is forwarded to subscribers only — it is display
        // state that never joins the turn's committed text accounting
        // (chars/deltas keep counting content, like the metrics do). The
        // first reasoning delta still starts the turn's TTFT clock:
        // reasoning models lead with it, so the displayed TTFT must
        // match the stream stats (send → first reasoning/content/tool
        // delta) instead of waiting for a content token that a
        // reasoning-only turn never produces.
        Streaming(candidate, monitor, cancel, acc, deltas, started_us, first),
          loop.StreamEvent(openai.ReasoningDelta(text))
          if candidate == worker
        -> {
          emit(state, Reasoning(text))
          actor.continue(
            State(
              ..state,
              turn: Streaming(
                candidate,
                monitor,
                cancel,
                acc,
                deltas,
                started_us,
                case first {
                  Some(_) -> first
                  None -> Some(timing.now_us())
                },
              ),
              turn_view: option.map(state.turn_view, fn(live) {
                LiveTurn(..live, reasoning: live.reasoning <> text)
              }),
            ),
          )
        }

        Streaming(candidate, ..),
          loop.StreamEvent(openai.ToolCallDelta(index, id, name, fragment))
          if candidate == worker
        -> {
          emit(state, ToolCallDelta(index, id, name, fragment))
          actor.continue(state)
        }

        Streaming(candidate, ..), loop.ToolCallAssembled(id, name, arguments)
          if candidate == worker
        -> {
          emit(state, ToolCallAssembled(id, name, arguments))
          actor.continue(
            State(
              ..state,
              turn_view: option.map(state.turn_view, fn(live) {
                // Reasoning still unattached this iteration (no text was
                // flushed at the "tools" boundary) rides the first call's
                // message — the mirror's twin of `append_calls` attaching
                // reasoning to the calls message.
                let #(view, reasoning) = case live.reasoning {
                  "" -> #(
                    transcript.append_assistant_tool_call(
                      live.view,
                      id: id,
                      name: name,
                      arguments: arguments,
                    ),
                    "",
                  )
                  r -> #(
                    transcript.append_assistant_tool_calls(
                      live.view,
                      text: None,
                      calls: [#(id, name, arguments)],
                      reasoning: Some(r),
                    ),
                    "",
                  )
                }
                LiveTurn(..live, view: view, reasoning: reasoning)
              }),
            ),
          )
        }

        Streaming(candidate, ..),
          loop.ToolResultEvent(call_id, name, ok, content)
          if candidate == worker
        -> {
          emit(state, ToolResult(call_id, name, ok, content))
          actor.continue(
            State(
              ..state,
              turn_view: option.map(state.turn_view, fn(live) {
                LiveTurn(
                  ..live,
                  view: transcript.append_tool_result(
                    live.view,
                    tool_call_id: call_id,
                    content: content,
                    ok: ok,
                  ),
                )
              }),
            ),
          )
        }

        Streaming(candidate, ..), loop.LoopStatus(iteration, max, phase)
          if candidate == worker
        -> {
          emit(state, LoopStatus(iteration, max, phase))
          let turn_view = case phase {
            // New iteration: the loop reset its accumulator cells, so the
            // mirror's per-iteration text/reasoning restart too.
            "request" ->
              option.map(state.turn_view, fn(live) {
                LiveTurn(..live, text: "", reasoning: "")
              })
            // Tool phase: the loop appended the iteration's assistant
            // message (text + calls + reasoning) before executing. Flush
            // the text half here; the calls ride the per-call assembled
            // events that follow.
            "tools" ->
              option.map(state.turn_view, fn(live) { flush_live_text(live) })
            _ -> state.turn_view
          }
          actor.continue(State(..state, turn_view: turn_view))
        }

        // Usage rides on the outcome's stats; raw usage events need no
        // session-level handling. Stale worker events are ignored.
        _, _ -> actor.continue(state)
      }

    WorkerDone(worker, outcome) -> {
      let is_current = case state.turn {
        Starting(candidate, ..) | Streaming(candidate, ..) ->
          candidate == worker
        Idle -> False
      }
      case is_current {
        False -> actor.continue(state)
        True -> {
          case state.turn {
            Starting(_, monitor, _, _) | Streaming(_, monitor, ..) ->
              process.demonitor_process(monitor)
            Idle -> Nil
          }
          let #(tr, event, sample) =
            finish_outcome(state.turn, state.transcript, outcome)
          emit(state, event)
          // Done/stopped/guard outcomes install the worker's extended
          // transcript (a commit); only a pure error leaves it untouched.
          let committed = case outcome {
            StreamErrored(_) -> False
            _ -> True
          }
          // Write-behind at the turn commit point (after the actor state
          // is decided, still in order with the Send-time hook).
          case committed {
            True -> {
              let _ = state.commit_hook(tr)
              Nil
            }
            False -> Nil
          }
          let state =
            State(
              ..state,
              transcript: tr,
              turn: Idle,
              // The turn is over — committed (the real transcript now
              // carries everything) or failed (nothing committed, so the
              // mirror must not leak into the next turn's replay).
              turn_view: None,
              metrics: push_metric(state.metrics, sample),
              last_commit_s: case committed {
                True -> timing.wall_now_s()
                False -> state.last_commit_s
              },
            )
          // The utility trigger (utility-titles plan §4.2): the turn
          // committed → maybe arm the title-branch debounce. A failed turn
          // (nothing committed) never triggers it.
          actor.continue(arm_utility(state, committed))
        }
      }
    }

    UtilityStart ->
      // The debounce fired. Every condition is re-checked at fire time, so
      // a stale or racing timer is simply dropped. When the ONLY blocker is
      // a turn in flight, mark a trigger OWED instead: the side call must
      // not queue behind a turn (serialized backends), and the owed trigger
      // is delivered when the turn ends — even a turn that then FAILS (a
      // failed turn re-arms nothing itself), so the already-committed first
      // exchange is never stranded untitled. Deliberately NOT a timer
      // re-arm: with NEXUS_UTILITY_DELAY_MS = 0 that would busy-loop for
      // the whole turn.
      case
        state.turn,
        state.utility,
        state.utility_attempted,
        state.cfg.utility_enabled,
        transcript.length(state.transcript) >= 3
      {
        Idle, UtilityIdle, False, True, True -> {
          // Unlinked worker (mirror of the turn worker): holds the
          // committed transcript snapshot — an immutable value, and the
          // branch (Y + reply B) never enters the session's transcript,
          // structurally unable to change a request byte — and creates its
          // own cancel subject (stream_with_cancel ownership rule). The
          // WORKER applies the title through the registry ask (the actor
          // never blocks), then reports the outcome.
          let snapshot = state.transcript
          // The instruction variant is fixed at spawn time: below the
          // pass cap the model may reply PASS; after it the forced
          // instruction applies and a PASS reply comes back as a failure.
          let allow_pass = state.utility_passes < max_utility_passes
          let worker =
            process.spawn_unlinked(fn() {
              let cancel = process.new_subject()
              let pid = process.self()
              process.send(state.self, UtilityStarted(pid, cancel))
              let result = case
                state.utility_runner(
                  state.endpoint,
                  snapshot,
                  cancel,
                  allow_pass,
                )
              {
                // A PASS counts only on an attempt that offered it: under
                // the forced instruction the attempt cannot defer again,
                // so a PASS reply is an unusable title — a failure that
                // spends the once-flag. (The parser already rejects it;
                // this guard pins the invariant at the actor boundary
                // too, so no runner can smuggle an endless postpone
                // through.)
                Ok(utility.Pass) ->
                  case allow_pass {
                    True -> UtilityPassed
                    False -> UtilityFailed
                  }
                Ok(utility.Title(title, tags)) ->
                  case state.utility_apply(title, tags) {
                    Ok(meta) -> UtilityApplied(meta.title, meta.tags)
                    Error(Nil) -> UtilityFailed
                  }
                Error(_) -> UtilityFailed
              }
              process.send(state.self, UtilityDone(pid, result))
            })
          let monitor = process.monitor(worker)
          actor.continue(
            State(
              ..state,
              utility: UtilityStarting(worker, monitor, False),
              utility_pending: False,
            ),
          )
        }
        _, UtilityIdle, False, True, True ->
          actor.continue(State(..state, utility_pending: True))
        // Genuinely terminal (attempt in flight, flag consumed, feature
        // off): drop, and with it any owed trigger that can no longer
        // matter.
        _, _, _, _, _ -> actor.continue(State(..state, utility_pending: False))
      }

    UtilityStarted(worker, cancel) ->
      case state.utility {
        UtilityStarting(pid, monitor, cancelled) if pid == worker -> {
          // A Send raced the handshake: cancel immediately, exactly like a
          // turn's stop_requested.
          case cancelled {
            True -> process.send(cancel, Nil)
            False -> Nil
          }
          actor.continue(
            State(
              ..state,
              utility: UtilityRunning(worker, monitor, cancel, cancelled),
            ),
          )
        }
        _ -> actor.continue(state)
      }

    UtilityDone(worker, result) ->
      case state.utility {
        UtilityStarting(pid, monitor, cancelled) if pid == worker ->
          finish_utility(state, monitor, cancelled, result)
        UtilityRunning(pid, monitor, _, cancelled) if pid == worker ->
          finish_utility(state, monitor, cancelled, result)
        _ -> actor.continue(state)
      }

    WorkerDown(worker) -> {
      // Every monitored process funnels here (the selector maps all
      // ProcessDowns), not just turn workers: a subscriber runtime that
      // died with its socket prunes its fan-out entry. Without this,
      // stale subjects accumulate per historical connection — sends to
      // them are silent no-ops, but the list would grow unboundedly.
      // Their owner monitors are spent; demonitor them on the way out.
      let #(kept, dead) =
        dict.to_list(state.subs)
        |> list.partition(fn(entry) {
          case process.subject_owner(entry.0) {
            Ok(owner) -> owner != worker
            Error(_) -> True
          }
        })
      list.each(dead, fn(entry) {
        case entry.1.monitor {
          Some(monitor) -> process.demonitor_process(monitor)
          None -> Nil
        }
      })
      let state = State(..state, subs: dict.from_list(kept))
      let is_current = case state.turn {
        Starting(candidate, ..) | Streaming(candidate, ..) ->
          candidate == worker
        Idle -> False
      }
      // A crashed UTILITY worker is best-effort: reset the side-call state
      // WITHOUT consuming `utility_attempted` (a crash must not eat the
      // session's only attempt) — and deliver any trigger already recorded
      // as owed right here: the slot is idle again, and waiting for the
      // next turn-commit point would strand the retry when no further turn
      // ever commits.
      case state.utility {
        UtilityStarting(pid, _, _)
          | UtilityRunning(pid, _, _, _)
          if pid == worker
        -> {
          let state = State(..state, utility: UtilityIdle)
          actor.continue(arm_utility(state, False))
        }
        _ ->
          case is_current {
            False -> actor.continue(state)
            True -> {
              emit(state, TurnFailed("turn worker exited unexpectedly"))
              actor.continue(
                State(
                  ..state,
                  turn: Idle,
                  // The worker died mid-turn: nothing further will be
                  // mirrored, and the turn committed nothing — drop the
                  // mirror so the next turn's replay starts clean.
                  turn_view: None,
                  metrics: push_metric(
                    state.metrics,
                    MetricSample(
                      outcome: Failed,
                      ttft_ms: None,
                      duration_ms: turn_duration_ms(state.turn),
                      token_deltas: turn_deltas(state.turn),
                      prompt_tokens: None,
                      cached_tokens: None,
                      stopped_chars: None,
                      failure_reason: Some("turn worker exited unexpectedly"),
                    ),
                  ),
                ),
              )
            }
          }
      }
    }

    MonitorNoise -> actor.continue(state)
  }
}

/// Fan one payload out to every subscriber, stamped with this session's
/// id AND each subscriber's current visit generation — the two
/// subscriber-side filter keys (see `SessionEvent`).
fn emit(state: State, kind: EventKind) -> Nil {
  dict.each(state.subs, fn(sub, subscriber) {
    process.send(sub, SessionEvent(state.id, subscriber.visit, kind))
  })
}

/// Flush the mirror iteration's accumulated text (with its reasoning, if
/// the text exists) into the view — the mirror twin of the loop's
/// `append_calls` text handling. Empty text consumes nothing: reasoning
/// stays pending for the first assembled call, exactly like the loop's
/// reasoning-only-iteration shape.
fn flush_live_text(live: LiveTurn) -> LiveTurn {
  case live.text {
    "" -> live
    text -> {
      let view =
        transcript.append_assistant_with_reasoning(
          live.view,
          text,
          reasoning: case live.reasoning {
            "" -> None
            reasoning -> Some(reasoning)
          },
        )
      LiveTurn(view: view, text: "", reasoning: "")
    }
  }
}

// ---------------------------------------------------------------------------
// Utility side-call (utility-titles plan §4.2): trigger, cancel, result
// ---------------------------------------------------------------------------

/// Cancel any in-flight utility attempt (a `Send` arriving mid-flight).
/// The attempt's completion will still arrive as `UtilityDone`, but the
/// `cancelled` mark keeps it from consuming `utility_attempted`.
fn cancel_utility(state: State) -> State {
  case state.utility {
    UtilityIdle -> state
    UtilityStarting(worker, monitor, _) ->
      State(..state, utility: UtilityStarting(worker, monitor, True))
    UtilityRunning(worker, monitor, cancel, _) -> {
      process.send(cancel, Nil)
      State(..state, utility: UtilityRunning(worker, monitor, cancel, True))
    }
  }
}

/// The utility trigger, called at the turn-commit point: when the turn
/// committed — or an earlier-committed exchange still owes a deferred
/// trigger (`utility_pending`, set when the debounce fired mid-turn) — and
/// the once-per-session attempt is still available, the feature is
/// enabled, and no side call is in flight → arm the debounce timer
/// (`NEXUS_UTILITY_DELAY_MS`). Nothing else changes here: the timer's
/// message re-checks every condition at fire time, so racing timers are
/// harmless.
fn arm_utility(state: State, committed: Bool) -> State {
  case
    committed || state.utility_pending,
    state.utility_attempted,
    state.cfg.utility_enabled,
    state.utility,
    transcript.length(state.transcript) >= 3
  {
    True, False, True, UtilityIdle, True -> {
      process.send_after(state.self, state.cfg.utility_delay_ms, UtilityStart)
      State(..state, utility_pending: False)
    }
    // A FAILED turn with an attempt still in flight (necessarily one the
    // turn's own Send cancelled): neither this turn nor the attempt has a
    // delivery point, so record the trigger as owed — the attempt's
    // cancelled completion must re-arm instead of stranding the session's
    // only try. (With a COMMITTED turn this is branch one's delivery; the
    // attempt's completion needs this only when the turn failed.)
    False, False, True, UtilityStarting(..), True ->
      State(..state, utility_pending: True)
    False, False, True, UtilityRunning(..), True ->
      State(..state, utility_pending: True)
    // The side call is still busy (e.g. a cancelled-but-unreported
    // worker): record the trigger as OWED — finish_utility delivers it
    // when this attempt completes. Dropping it here would silently spend
    // the re-arm a cancelled attempt is entitled to (the once-flag is
    // still unset, so the next commit point would arm again — but there
    // may never be one).
    True, False, True, _, _ -> State(..state, utility_pending: True)
    _, _, _, _, _ -> State(..state, utility_pending: False)
  }
}

/// A completed utility attempt: the once-flag flips ONLY here (never when
/// armed or cancelled), and the new metadata is broadcast to subscribers
/// ONLY when something applied — every connected tab's sidebar refreshes
/// from the event.
fn finish_utility(
  state: State,
  monitor: Monitor,
  cancelled: Bool,
  result: UtilityResult,
) -> actor.Next(State, Msg) {
  process.demonitor_process(monitor)
  // The once-flag: an APPLIED title consumes the attempt even when a Send's
  // cancellation raced it — the registry applied, so a second request would
  // be pure waste. A FAILED attempt consumes it only when it actually
  // completed on its own; a cancelled one is re-armed by the next
  // turn-commit point. A PASS never consumes it: the model said "not
  // enough signal yet" — the attempt stays available and re-arms (the
  // forced instruction takes over once `max_utility_passes` is spent).
  let utility_attempted = case result, cancelled {
    UtilityApplied(..), _ -> True
    UtilityPassed, _ -> state.utility_attempted
    UtilityFailed, True -> state.utility_attempted
    UtilityFailed, False -> True
  }
  let state =
    State(
      ..state,
      utility: UtilityIdle,
      utility_attempted: utility_attempted,
      utility_passes: case result {
        UtilityPassed -> state.utility_passes + 1
        _ -> state.utility_passes
      },
      // The once-flag is spent: an owed trigger could never fire again.
      utility_pending: case utility_attempted {
        True -> False
        False -> state.utility_pending
      },
    )
  // A CANCELLED attempt freed the side-call slot WITHOUT consuming the
  // once-flag. If the turn-commit arm ran while this worker was still
  // unreported, the trigger was recorded as owed — deliver it NOW: the
  // slot is idle again and waiting for the next commit point could
  // strand the session's only attempt when no further turn commits. A
  // PASS that raced a Send behaves the same: nothing was consumed, so
  // the owed trigger is still deliverable.
  let state = case result, cancelled {
    UtilityFailed, True -> arm_utility(state, False)
    UtilityPassed, True -> arm_utility(state, False)
    _, _ -> state
  }
  case result {
    UtilityApplied(title, tags) -> {
      emit(state, MetaUpdated(Some(title), tags))
      actor.continue(state)
    }
    UtilityFailed | UtilityPassed -> actor.continue(state)
  }
}

/// Finalise a turn. The worker returns the full extended transcript for
/// done/stopped/guard outcomes (M3 tool rounds were appended as they
/// happened); on error the actor's transcript stays untouched so a retry
/// resends a byte-identical prefix. Text that streamed in the *final*
/// iteration was already committed by the worker.
fn finish_outcome(
  turn: TurnState,
  tr: Transcript,
  outcome: TurnOutcome,
) -> #(Transcript, EventKind, MetricSample) {
  let now = timing.now_us()
  let started_us = turn_start_us(turn)
  let ttft_ms = case turn_first_us(turn) {
    Some(first) -> Some(timing.elapsed_ms(started_us, first))
    None -> None
  }
  let deltas = turn_deltas(turn)
  let duration_ms = timing.elapsed_ms(started_us, now)
  case outcome {
    StreamDone(stats, tr2) -> #(
      tr2,
      TurnDone(stats),
      MetricSample(
        outcome: Completed,
        ttft_ms: ttft_ms,
        duration_ms: duration_ms,
        token_deltas: deltas,
        prompt_tokens: usage_prompt(stats.usage),
        cached_tokens: usage_cached(stats.usage),
        stopped_chars: None,
        failure_reason: None,
      ),
    )
    StreamStopped(tr2) -> {
      let chars = turn_chars(turn)
      #(
        tr2,
        TurnStopped(chars),
        MetricSample(
          outcome: Stopped,
          ttft_ms: ttft_ms,
          duration_ms: duration_ms,
          token_deltas: deltas,
          prompt_tokens: None,
          cached_tokens: None,
          stopped_chars: Some(chars),
          failure_reason: None,
        ),
      )
    }
    StreamGuard(max, tr2) -> {
      let reason =
        "iteration guard: reached max "
        <> int.to_string(max)
        <> " model round-trips"
      #(
        tr2,
        TurnFailed(reason),
        MetricSample(
          outcome: Failed,
          ttft_ms: ttft_ms,
          duration_ms: duration_ms,
          token_deltas: deltas,
          prompt_tokens: None,
          cached_tokens: None,
          stopped_chars: None,
          failure_reason: Some(reason),
        ),
      )
    }
    StreamErrored(reason) -> #(
      tr,
      TurnFailed(reason),
      MetricSample(
        outcome: Failed,
        ttft_ms: ttft_ms,
        duration_ms: duration_ms,
        token_deltas: deltas,
        prompt_tokens: None,
        cached_tokens: None,
        stopped_chars: None,
        failure_reason: Some(reason),
      ),
    )
  }
}

/// Store a sample newest-first, capped at `metrics_cap`.
fn push_metric(
  metrics: List(MetricSample),
  sample: MetricSample,
) -> List(MetricSample) {
  [sample, ..metrics]
  |> list.take(metrics_cap)
}

fn turn_start_us(turn: TurnState) -> Int {
  case turn {
    Starting(_, _, _, started_us) -> started_us
    Streaming(_, _, _, _, _, started_us, _) -> started_us
    Idle -> timing.now_us()
  }
}

fn turn_first_us(turn: TurnState) -> Option(Int) {
  case turn {
    Streaming(_, _, _, _, _, _, first) -> first
    _ -> None
  }
}

fn turn_deltas(turn: TurnState) -> Int {
  case turn {
    Streaming(_, _, _, _, deltas, _, _) -> deltas
    _ -> 0
  }
}

/// Characters of assistant text streamed in the final iteration (used for
/// the TurnStopped event; the worker already committed them).
fn turn_chars(turn: TurnState) -> Int {
  case turn {
    Streaming(_, _, _, acc, _, _, _) -> string.length(acc)
    _ -> 0
  }
}

fn turn_duration_ms(turn: TurnState) -> Int {
  timing.elapsed_ms(turn_start_us(turn), timing.now_us())
}

fn usage_prompt(usage: Option(CompletionUsage)) -> Option(Int) {
  case usage {
    Some(u) -> Some(u.prompt_tokens)
    None -> None
  }
}

fn usage_cached(usage: Option(CompletionUsage)) -> Option(Int) {
  case usage {
    Some(u) ->
      case u.prompt_tokens_details {
        Some(details) -> details.cached_tokens
        None -> None
      }
    None -> None
  }
}

/// Request/response helpers over the actor's subject.
pub fn send_message(session: Subject(Msg), text: String) -> SendResult {
  actor.call(session, 5000, fn(reply) { Send(text, reply) })
}

pub fn stop(session: Subject(Msg)) -> Nil {
  process.send(session, Stop)
}

pub fn snapshot(session: Subject(Msg)) -> Transcript {
  actor.call(session, 5000, Snapshot)
}

/// Ask a session for its current status (model, counts, metrics).
pub fn describe(session: Subject(Msg)) -> SessionStatus {
  actor.call(session, 5000, Describe)
}
