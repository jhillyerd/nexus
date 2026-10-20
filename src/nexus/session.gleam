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

/// Events broadcast to subscribers (Mist SSE connections, tests).
pub type SessionEvent {
  /// Sent once to a fresh subscriber after `Join` (before any replay).
  Hello(model: String, messages: Int, metrics: List(MetricSample))
  /// A user turn, echoed so every tab sees it. Also used for history replay.
  UserEcho(text: String)
  /// A complete assistant turn, used for history replay on (re)connect.
  AssistantFull(text: String)
  /// A streamed fragment of the assistant turn in flight.
  Token(text: String)
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
      self: self,
      metrics: [],
      last_commit_s: 0,
      commit_hook: commit_hook,
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
      |> list.each(fn(message) {
        case message {
          chat.UserMessage(content: chat.UserTextContent(text), ..) ->
            process.send(sub, UserEcho(text))
          chat.AssistantMessage(
            content: Some(chat.AssistantTextContent(text)),
            tool_calls: None,
            ..,
          ) -> process.send(sub, AssistantFull(text))
          chat.AssistantMessage(content: text, tool_calls: calls, ..) -> {
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
      })
      // M3: the UI component keeps one long-lived subscription across
      // reconnects, so a re-Join must not duplicate the fan-out entry.
      let subs = case list.contains(state.subs, sub) {
        True -> state.subs
        False -> [sub, ..state.subs]
      }
      actor.continue(State(..state, subs:))
    }

    Send(text, reply) ->
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
          actor.continue(
            State(
              ..state,
              transcript: tr,
              turn: Idle,
              metrics: push_metric(state.metrics, sample),
              last_commit_s: case committed {
                True -> timing.wall_now_s()
                False -> state.last_commit_s
              },
            ),
          )
        }
      }
    }

    WorkerDown(worker) -> {
      let is_current = case state.turn {
        Starting(candidate, ..) | Streaming(candidate, ..) ->
          candidate == worker
        Idle -> False
      }
      case is_current {
        False -> actor.continue(state)
        True -> {
          broadcast(state.subs, TurnFailed("turn worker exited unexpectedly"))
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

    MonitorNoise -> actor.continue(state)
  }
}

fn broadcast(subs: List(Subject(SessionEvent)), event: SessionEvent) -> Nil {
  list.each(subs, fn(sub) { process.send(sub, event) })
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
