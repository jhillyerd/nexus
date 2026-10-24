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

/// Events broadcast to subscribers (Mist SSE connections, tests).
pub type SessionEvent {
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
/// branch. Returns the parsed title, or `Error` for anything unusable
/// (transport failure, cancellation, a tool-call answer, a refusal):
/// best-effort, discarded, never retried. The endpoint is the session's
/// frozen one; `cancel` must be owned by the calling process.
pub type UtilityRunner =
  fn(openai.Endpoint, Transcript, Subject(Nil)) -> Result(String, String)

/// Fresh display metadata as the apply step reports it: what actually
/// landed, carried to the `MetaUpdated` broadcast.
pub type UtilityMeta {
  UtilityMeta(title: String, tags: List(String))
}

/// The apply seam: guarded title application — in production the registry
/// `UpgradeAutoTitle` ask (guard `title_source = 'auto'` only), injected
/// exactly like the turn runner so this module never depends on the
/// registry (dependency direction stays registry → session, and the
/// session actor never blocks on an ask). `Error` when the guard refused
/// (a manual rename wins forever, unknown id, empty title).
pub type UtilityApply =
  fn(String) -> Result(UtilityMeta, Nil)

/// What a completed utility attempt reports to the actor.
pub type UtilityResult {
  /// The guard applied the title; carries the fresh display metadata.
  UtilityApplied(title: String, tags: List(String))
  /// Nothing applied: stream failed/cancelled, or the guard refused.
  UtilityFailed
}

/// The real utility runner (utility-titles plan §4.2), built ONCE at boot
/// beside `agent_runner`: closes over the shared frozen envelope
/// (`loop.frozen_options` — byte-identical to every turn request by
/// construction), so the only per-call delta is the generation-side token
/// cap applied inside `utility.run`. `specs` is the same boot-frozen tool
/// registry the agent loop uses — never a per-session set.
pub fn utility_runner(specs: List(tools.ToolSpec)) -> UtilityRunner {
  let base = loop.frozen_options(specs)
  fn(endpoint, tr, cancel) { utility.run(endpoint, tr, base, cancel) }
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
/// - `utility_apply` lands the parsed title behind the registry's
///   `title_source = 'auto'` guard (a manual rename wins forever).
pub type SessionSpec {
  SessionSpec(
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
  Join(sub: Subject(SessionEvent))
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

type State {
  State(
    cfg: Config,
    endpoint: openai.Endpoint,
    runner: TurnRunner,
    transcript: Transcript,
    subs: List(Subject(SessionEvent)),
    turn: TurnState,
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
    /// (the side call must not queue behind it), so the trigger is deferred
    /// to the turn's end — committed or failed — instead of being dropped
    /// or rescheduled (a timer-based re-arm would spin at delay 0). The
    /// turn's own commit-point arm also consumes this.
    utility_pending: Bool,
    /// The session's ONE title attempt (utility-titles plan §4.2). Flips
    /// only when an attempt COMPLETES (applied or failed) — never when one
    /// is armed or cancelled — so a fast follow-up can kill at most the
    /// in-flight try, never the session's only one.
    utility_attempted: Bool,
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
      subs: [],
      turn: Idle,
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
    Join(sub) -> {
      process.send(
        sub,
        Hello(
          transcript.model(state.transcript),
          transcript.length(state.transcript),
          state.metrics,
        ),
      )
      // Replay existing history so a fresh page load / reconnect sees the
      // session (system prompt stays server-side, per the cache contract).
      // M3: tool history is replayed too — assistant tool-call messages as
      // `ToolCallAssembled`, tool results as `ToolResult` — so a reconnect
      // can rebuild the full tool state (names resolved from earlier
      // assistant messages, since tool messages only carry ids).
      let names =
        state.transcript
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
      state.transcript
      |> transcript.messages
      |> list.index_fold(Nil, fn(_, message, index) {
        case message {
          chat.UserMessage(content: chat.UserTextContent(text), ..) ->
            process.send(sub, UserEcho(text))
          chat.AssistantMessage(content: text, tool_calls: calls, ..) -> {
            // Reasoning replay first: it was streamed before the message's
            // own output, so it replays before it too.
            case transcript.reasoning_at(state.transcript, index) {
              Some(reasoning) -> process.send(sub, ReasoningFull(reasoning))
              None -> Nil
            }
            case text {
              Some(chat.AssistantTextContent(content)) ->
                process.send(sub, AssistantFull(content))
              _ -> Nil
            }
            case calls {
              Some(calls) ->
                list.each(calls, fn(call) {
                  let chat.FunctionToolCall(id: id, function: f) = call
                  process.send(sub, ToolCallAssembled(id, f.name, f.arguments))
                })
              None -> Nil
            }
          }
          chat.ToolMessage(
            content: chat.ToolTextContent(content),
            tool_call_id: id,
          ) ->
            process.send(
              sub,
              ToolResult(
                id,
                dict.get(names, id) |> result.unwrap("tool"),
                True,
                content,
              ),
            )
          _ -> Nil
        }
        Nil
      })
      // M3: the UI component keeps one long-lived subscription across
      // reconnects, so a re-Join must not duplicate the fan-out entry.
      // Per-client break: subscriber subjects are owned by per-connection
      // Lustre runtimes that die with their sockets — monitor a new
      // subscriber's owner so its exit prunes the entry in the
      // `WorkerDown` arm (every monitored ProcessDown funnels there).
      let subs = case list.contains(state.subs, sub) {
        True -> state.subs
        False -> {
          case process.subject_owner(sub) {
            Ok(owner) -> {
              let _ = process.monitor(owner)
              Nil
            }
            Error(_) -> Nil
          }
          [sub, ..state.subs]
        }
      }
      actor.continue(State(..state, subs:))
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
          broadcast(state.subs, UserEcho(text))
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
          broadcast(state.subs, Token(text))
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
          broadcast(state.subs, Reasoning(text))
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
            ),
          )
        }

        Streaming(candidate, ..),
          loop.StreamEvent(openai.ToolCallDelta(index, id, name, fragment))
          if candidate == worker
        -> {
          broadcast(state.subs, ToolCallDelta(index, id, name, fragment))
          actor.continue(state)
        }

        Streaming(candidate, ..), loop.ToolCallAssembled(id, name, arguments)
          if candidate == worker
        -> {
          broadcast(state.subs, ToolCallAssembled(id, name, arguments))
          actor.continue(state)
        }

        Streaming(candidate, ..),
          loop.ToolResultEvent(call_id, name, ok, content)
          if candidate == worker
        -> {
          broadcast(state.subs, ToolResult(call_id, name, ok, content))
          actor.continue(state)
        }

        Streaming(candidate, ..), loop.LoopStatus(iteration, max, phase)
          if candidate == worker
        -> {
          broadcast(state.subs, LoopStatus(iteration, max, phase))
          actor.continue(state)
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
          broadcast(state.subs, event)
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
          let worker =
            process.spawn_unlinked(fn() {
              let cancel = process.new_subject()
              let pid = process.self()
              process.send(state.self, UtilityStarted(pid, cancel))
              let result = case
                state.utility_runner(state.endpoint, snapshot, cancel)
              {
                Ok(title) ->
                  case state.utility_apply(title) {
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
      let state =
        State(
          ..state,
          subs: list.filter(state.subs, fn(sub) {
            case process.subject_owner(sub) {
              Ok(owner) -> owner != worker
              Error(_) -> True
            }
          }),
        )
      let is_current = case state.turn {
        Starting(candidate, ..) | Streaming(candidate, ..) ->
          candidate == worker
        Idle -> False
      }
      // A crashed UTILITY worker is best-effort: reset the side-call state
      // WITHOUT consuming `utility_attempted` (a crash must not eat the
      // session's only attempt) — the next turn-commit point re-arms.
      case state.utility {
        UtilityStarting(pid, _, _)
          | UtilityRunning(pid, _, _, _)
          if pid == worker
        -> actor.continue(State(..state, utility: UtilityIdle))
        _ ->
          case is_current {
            False -> actor.continue(state)
            True -> {
              broadcast(
                state.subs,
                TurnFailed("turn worker exited unexpectedly"),
              )
              actor.continue(
                State(
                  ..state,
                  turn: Idle,
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

fn broadcast(subs: List(Subject(SessionEvent)), event: SessionEvent) -> Nil {
  list.each(subs, fn(sub) { process.send(sub, event) })
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
    // The side call is still busy (e.g. a cancelled-but-unreported
    // worker): keep the owed trigger for a later turn end.
    True, False, True, _, _ -> state
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
  // turn-commit point.
  let utility_attempted = case result, cancelled {
    UtilityApplied(..), _ -> True
    UtilityFailed, True -> state.utility_attempted
    UtilityFailed, False -> True
  }
  let state =
    State(
      ..state,
      utility: UtilityIdle,
      utility_attempted: utility_attempted,
      // The once-flag is spent: an owed trigger could never fire again.
      utility_pending: case utility_attempted {
        True -> False
        False -> state.utility_pending
      },
    )
  case result {
    UtilityApplied(title, tags) -> {
      broadcast(state.subs, MetaUpdated(Some(title), tags))
      actor.continue(state)
    }
    UtilityFailed -> actor.continue(state)
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
) -> #(Transcript, SessionEvent, MetricSample) {
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
