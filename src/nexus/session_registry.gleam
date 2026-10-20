//// M2 session registry: a supervised actor that owns the user-visible
//// session IDs, the model aliases pinned per session, the session subjects
//// and their monitors, and the child-start specification handed to the
//// factory supervisor.
////
//// Multi-provider P3: creation and lazy hydration resolve each session's
//// provider id into a FROZEN `openai.Endpoint` through an injected
//// resolver (boot maps `nexus/provider_registry`; tests inject a pure
//// fn) — a session only ever exists with its (provider, model) pin in
//// place, and the endpoint rides the spec for the actor's whole life.
////
//// Supervision model (M2 §4.1): session children run under the named
//// factory supervisor with a **temporary** restart strategy, so the factory
//// never silently replaces a PID behind our back. The registry owns the
//// monitors and asks the factory to start the *same* specification again
//// when a session actor exits — the replacement reuses the registered name
//// and keeps the user-visible ID.
////
//// Dependency direction is strictly registry → session: the registry calls
//// `session.describe`, and no session code path ever calls back into the
//// registry (that would deadlock). Phase 2 persistence keeps this: the
//// session actor only sees an injected `commit_hook` closure (the store's
//// write-behind lane), exactly like the injected turn runner.
////
//// Phase 2 (durable persistence): the registry hydrates the **dormant**
//// set (stored-but-not-live sessions) from the store seam at boot and
//// mints ids past every stored id. Never-used sessions (system prompt
//// only, untitled, unpinned) past a grace window do not survive a boot:
//// one bulk delete (the seam's `prune_never_used`) runs before
//// hydration, so abandoned empties cannot accumulate in the sidebar —
//// sessions exist because someone put a message in them. The
//// first `Get` of a dormant id lazily
//// starts a hydrated actor — the transcript is rebuilt through
//// `nexus/transcript.new(model, system_prompt)` + the existing `append_*`
//// functions only, so the request prefix is byte-identical across the
//// restart (KV-cache contract). Turn commits persist write-behind through
//// the hook; metadata mutations write through synchronously. A dead
//// actor's replacement rehydrates from the store instead of starting
//// empty (Phase 1 semantics survive only for sessions whose row insert
//// failed at create).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import nexus/config.{type Config}
import nexus/openai
import nexus/session
import nexus/store.{type Store, type StoredSummary}
import nexus/timing
import nexus/tools
import nexus/transcript.{type Transcript}

/// The factory's child-start argument: everything needed to (re)start one
/// session actor identically.
pub type ChildArgument {
  ChildArgument(spec: session.SessionSpec, name: process.Name(session.Msg))
}

/// A live session as the registry hands it to callers (the HTTP layer).
pub type SessionRecord {
  SessionRecord(
    id: String,
    model: String,
    subject: Subject(session.Msg),
    /// The live actor's PID. Exposed so callers (and tests) can observe the
    /// restart: the replacement keeps `id` and `name` but is a new PID.
    pid: Pid,
  )
}

/// Reply payload for `Create`: a live record, or a failure the HTTP layer
/// maps onto a status code.
pub type CreateError {
  EmptyModel
  /// The pinned provider could not be resolved into a streaming
  /// endpoint (unknown / disabled / key unavailable). Carries the typed
  /// reason so callers can answer 400 vs 502 without string matching.
  ProviderFailed(ProviderError)
  StartFailed(reason: String)
}

/// Why a provider id could not be turned into a frozen endpoint. The
/// registry's own vocabulary, decoupled from `nexus/provider_registry`
/// (the resolver is an injected fn; boot maps the registry's errors onto
/// these, tests build them directly).
pub type ProviderError {
  ProviderUnknown
  ProviderDisabled
  /// The stored envelope failed authentication (a rotated-away master
  /// key or a tampered row): the session cannot stream until an operator
  /// intervenes. Surfaced as a server-side failure, not a client error.
  ProviderKeyUnavailable
}

/// The provider seam: `provider_id` → the endpoint a session freezes for
/// its lifetime. Production resolves through `nexus/provider_registry`;
/// tests inject a pure fn.
pub type ResolveProvider =
  fn(String) -> Result(openai.Endpoint, ProviderError)

pub type Msg {
  /// Start a new session pinned to `provider_id` + `model` using the
  /// registry's frozen tool runner (built once at registry start, so the
  /// tool schema is identical in every request of every session).
  Create(
    provider_id: String,
    model: String,
    reply: Subject(Result(SessionRecord, CreateError)),
  )
  /// Test seam: start a session with an injected runner.
  CreateWithRunner(
    provider_id: String,
    model: String,
    runner: session.TurnRunner,
    reply: Subject(Result(SessionRecord, CreateError)),
  )
  /// Resolve a session subject — live, or a stored-but-not-live id
  /// (Phase 2: which lazily starts a hydrated actor). `Error(Nil)` for
  /// unknown ids or for sessions whose restart failed.
  Get(id: String, reply: Subject(Result(Subject(session.Msg), Nil)))
  /// All sessions (live + dormant), pinned first then most-recently-active
  /// first. Archiving does not hide a session from the list — callers
  /// (HTTP, UI) filter by the `archived` flag.
  List(reply: Subject(List(session.SessionSummary)))
  /// Manual rename: always wins and marks the title `ManualTitle` so no
  /// later auto-generation can clobber it.
  SetTitle(id: String, title: String, reply: Subject(Bool))
  /// Auto-title from the first user message (HTTP send boundary). Applies
  /// only while the title is still the untouched auto default, so a manual
  /// rename is never overwritten. Keeps `title_source` auto.
  AutoTitle(id: String, title: String, reply: Subject(Bool))
  SetPinned(id: String, pinned: Bool, reply: Subject(Bool))
  SetTags(id: String, tags: List(String), reply: Subject(Bool))
  SetArchived(id: String, archived: Bool, reply: Subject(Bool))
  /// Hard removal: stop the child actor (factory children are Temporary,
  /// and the registry owns the monitors), delete the stored rows, then
  /// drop the record. `False` for unknown IDs.
  Delete(id: String, reply: Subject(Bool))
  /// Monitor plumbing (internal): a monitored session actor exited.
  Down(pid: Pid, monitor: Monitor)
  /// Selector plumbing for non-process monitors; always ignored.
  MonitorNoise
}

type Record {
  Record(
    id: String,
    /// The frozen provider pin (multi-provider plan §8): carried so
    /// summaries can report it without reaching into the spec's endpoint.
    provider_id: String,
    model: String,
    subject: Subject(session.Msg),
    pid: Pid,
    monitor: Monitor,
    /// Retained so a dead actor can be restarted identically.
    spec: session.SessionSpec,
    name: process.Name(session.Msg),
    /// Set when a restart failed: the session stays listed but reports as
    /// unavailable, rather than the registry looping on start attempts.
    start_error: Option(String),
    // ---- Organizational metadata (beside the transcript, never in it) ----
    /// Display title; "" until the first user message auto-titles it.
    title: String,
    /// Auto titles are generated once from the first user message; a
    /// manual rename pins the title forever.
    title_source: session.TitleSource,
    pinned: Bool,
    /// Normalized on write: trimmed, non-empty, de-duplicated.
    tags: List(String),
    /// Soft-hide flag: archived sessions stay restorable until deleted.
    archived: Bool,
    /// Wall-clock epoch seconds at creation (display ordering only).
    created_at: Int,
    /// Phase 2: the session row was persisted. Unpersisted sessions (the
    /// insert failed at create) keep Phase 1 restart semantics — empty
    /// transcript, no rehydration attempts.
    persisted: Bool,
  )
}

type State {
  State(
    cfg: Config,
    /// The M3 agent-loop runner with the registry's frozen tool set —
    /// every session this registry starts (create, restart, replacement)
    /// gets the identical tool schema.
    runner: session.TurnRunner,
    /// The provider seam: resolves the endpoint frozen into each session
    /// spec at create and lazy-hydration time.
    resolve_provider: ResolveProvider,
    factory: Factory,
    sessions: Dict(String, Record),
    /// Phase 2: stored-but-not-live sessions (boot hydration). The first
    /// Get of such an id lazily starts a hydrated actor and promotes the
    /// entry to `sessions`.
    dormant: Dict(String, StoredSummary),
    /// ID minting only — list order is computed at list time (pinned
    /// first, then last activity, newest ties first). Boot-seeded past
    /// every stored id so a fresh create can never collide.
    counter: Int,
    /// The swappable persistence seam (mockable for offline tests).
    store: Store,
  )
}

/// The outcome of resolving a Get: either a subject to reply with, or a
/// state transition the caller must install (lazy start / retry).
type Resolved {
  Subject(subject: Subject(session.Msg))
  Missing
  Started(next: State)
}

pub type Factory =
  factory_supervisor.Supervisor(ChildArgument, Subject(session.Msg))

/// The named factory supervisor's child template: start one session actor
/// under its own registered name.
pub fn session_child(
  argument: ChildArgument,
) -> actor.StartResult(Subject(session.Msg)) {
  session.supervised(argument.spec, argument.name)
}

/// Builder for the boot-time factory supervisor: session actors are started
/// dynamically as temporary children, so only the registry replaces them.
pub fn factory_builder(
  name: process.Name(
    factory_supervisor.Message(ChildArgument, Subject(session.Msg)),
  ),
) -> factory_supervisor.Builder(ChildArgument, Subject(session.Msg)) {
  factory_builder_with_child(name, session_child)
}

/// Test seam: build the factory with a custom child starter so a startup
/// failure can be produced without touching the real session constructor.
pub fn factory_builder_with_child(
  name: process.Name(
    factory_supervisor.Message(ChildArgument, Subject(session.Msg)),
  ),
  child: fn(ChildArgument) -> actor.StartResult(Subject(session.Msg)),
) -> factory_supervisor.Builder(ChildArgument, Subject(session.Msg)) {
  factory_supervisor.worker_child(child)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  // The registry — not the factory — drives replacements, so give it room:
  // a burst of session churn must not take the factory itself down.
  |> factory_supervisor.restart_tolerance(intensity: 20, period: 60)
  |> factory_supervisor.named(name)
}

/// Start the registry actor (boot and tests). The name is registered so
/// HTTP handlers can resolve it at request time, even after a restart.
///
/// Phase 2: takes the persistence seam and hydrates the dormant set from
/// it at start — if the store is unreachable, starting FAILS (persistence
/// is mandatory; there is no silent ephemeral mode).
pub fn start(
  cfg: Config,
  factory: Factory,
  name: process.Name(Msg),
  persistence: Store,
  resolve_provider: ResolveProvider,
) -> actor.StartResult(Subject(Msg)) {
  // The tool registry is built once, here, from the global config — before
  // any session exists — so every request any session of this VM ever
  // sends carries the identical (byte-stable) tool schema.
  start_with_runner(
    cfg,
    factory,
    name,
    persistence,
    session.agent_runner(cfg.max_tool_iterations, tools.default(cfg)),
    resolve_provider,
  )
}

/// Test seam: the same registry with an injected turn runner — hydration
/// (boot, lazy start, restart recovery) then uses it for every session it
/// starts, exactly like production uses the frozen agent-loop runner.
pub fn start_with_runner(
  cfg: Config,
  factory: Factory,
  name: process.Name(Msg),
  persistence: Store,
  runner: session.TurnRunner,
  resolve_provider: ResolveProvider,
) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      // Boot sweep first — ONE bulk delete through the seam (a per-row
      // loop here would put unbounded work inside this initialiser's
      // 5s deadline), then hydrate whatever survived. A prune error is
      // logged and ignored: nothing was deleted, so the list still
      // matches the store, and the next boot retries.
      let pruned = boot_sweep(persistence)
      case persistence.list_summaries() {
        Error(error) ->
          Error("session store unreachable, cannot hydrate: " <> error)
        Ok(summaries) -> {
          let dormant =
            list.fold(summaries, dict.new(), fn(dormant, summary) {
              dict.insert(dormant, summary.id, summary)
            })
          actor.initialised(State(
            cfg: cfg,
            runner: runner,
            resolve_provider: resolve_provider,
            factory: factory,
            sessions: dict.new(),
            dormant: dormant,
            // Seeded past the survivors AND the pruned ids: the bulk
            // prune is atomic, so reuse of a pruned id could not
            // collide — but minted ids stay monotonically increasing
            // across sweeps anyway (a deleted s5 must not come back as
            // a different session).
            counter: int.max(
              max_stored_counter(summaries),
              max_id_suffix(pruned),
            ),
            store: persistence,
          ))
          |> actor.returning(self)
          |> actor.selecting(
            process.new_selector()
            |> process.select(self)
            |> process.select_monitors(fn(down) {
              case down {
                process.ProcessDown(monitor, pid, _reason) -> Down(pid, monitor)
                process.PortDown(_, _, _) -> MonitorNoise
              }
            }),
          )
          |> Ok
        }
      }
    })
    |> actor.on_message(handle)
    |> actor.named(name)
  actor.start(builder)
}

/// The highest numeric suffix among stored `s<N>` ids, so freshly minted
/// ids never collide with dormant (stored-but-not-live) sessions.
fn max_stored_counter(summaries: List(StoredSummary)) -> Int {
  max_id_suffix(list.map(summaries, fn(summary) { summary.id }))
}

/// The highest numeric suffix among `s<N>`-shaped ids, 0 for none.
fn max_id_suffix(ids: List(String)) -> Int {
  ids
  |> list.fold(0, fn(max, id) {
    case string.split(id, on: "s") {
      ["", suffix] ->
        case int.parse(suffix) {
          Ok(n) -> int.max(max, n)
          Error(_) -> max
        }
      _ -> max
    }
  })
}

/// The boot sweep: delete every stored never-used session older than
/// the grace window (see `prune_never_used.sql` for the full contract),
/// returning the ids it deleted ([] when the store had none or the
/// prune failed — a failure deletes nothing).
///
/// Why a boot-time sweep: sessions used to be minted unconditionally at
/// every server start, so restarts (and nothing else) accumulated empty
/// rows forever. Creation is now always user-initiated, and this sweep
/// retires whatever empties earlier runs left behind — including one
/// created and abandoned mid-run, which is indistinguishable from those
/// rows and costs nothing (there is no content to lose; a first message
/// only counts once its turn committed). The grace window is what keeps
/// a session another concurrently-running server created moments ago
/// (still empty until its first commit) from being deleted under its
/// live actor — 15 minutes is far past any first turn.
fn boot_sweep(persistence: Store) -> List(String) {
  case persistence.prune_never_used() {
    Ok([]) -> []
    Ok(ids) -> {
      io.println(
        "boot sweep: deleted "
        <> int.to_string(list.length(ids))
        <> " never-used session(s): "
        <> string.join(ids, ", "),
      )
      ids
    }
    Error(error) -> {
      log_store_error("prune never-used", error)
      []
    }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Create(provider_id, model, reply) ->
      handle_create(state, provider_id, model, state.runner, reply)

    CreateWithRunner(provider_id, model, runner, reply) ->
      handle_create(state, provider_id, model, runner, reply)

    _ -> handle_rest(state, msg)
  }
}

fn handle_create(
  state: State,
  provider_id: String,
  model: String,
  runner: session.TurnRunner,
  reply: Subject(Result(SessionRecord, CreateError)),
) -> actor.Next(State, Msg) {
  case string.trim(model) {
    "" -> {
      process.send(reply, Error(EmptyModel))
      actor.continue(state)
    }
    alias ->
      // Resolve the endpoint FIRST: a session is only ever created with
      // its frozen (provider, model) pin in place — there is no
      // create-then-attach path (multi-provider plan §8).
      case state.resolve_provider(provider_id) {
        Error(reason) -> {
          process.send(reply, Error(ProviderFailed(reason)))
          actor.continue(state)
        }
        Ok(endpoint) -> {
          let counter = state.counter + 1
          let id = "s" <> int.to_string(counter)
          let name = process.new_name("nexus_session_" <> id)
          let spec =
            session.SessionSpec(
              cfg: state.cfg,
              model: alias,
              endpoint: endpoint,
              runner: runner,
              commit_hook: commit_hook_for(state.store, id),
              hydrate: None,
            )
          case
            factory_supervisor.start_child(
              state.factory,
              ChildArgument(spec:, name:),
            )
          {
            Ok(started) -> {
              let created_at = timing.wall_now_s()
              // Write-through: the session row lands now, with the frozen
              // alias and the frozen system prompt (contract rule 2), so
              // hydration can rebuild the frozen prefix byte-identically.
              let persisted = case
                state.store.insert_session(
                  store.StoredSummary(
                    id: id,
                    provider_id: provider_id,
                    title: "",
                    title_source: session.AutoTitle,
                    model: alias,
                    pinned: False,
                    archived: False,
                    tags: [],
                    created_at: created_at,
                    last_active_at: created_at,
                    // 1 = the system prompt (Phase 1 message_count).
                    message_count: 1,
                  ),
                  state.cfg.system_prompt,
                )
              {
                Ok(_) -> True
                Error(error) -> {
                  log_store_error("insert_session " <> id, error)
                  False
                }
              }
              let record =
                Record(
                  id: id,
                  provider_id: provider_id,
                  model: alias,
                  subject: started.data,
                  pid: started.pid,
                  monitor: process.monitor(started.pid),
                  spec: spec,
                  name: name,
                  start_error: None,
                  title: "",
                  title_source: session.AutoTitle,
                  pinned: False,
                  tags: [],
                  archived: False,
                  created_at: created_at,
                  persisted: persisted,
                )
              process.send(reply, Ok(as_public(record)))
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, id, record),
                  counter: counter,
                ),
              )
            }
            Error(reason) -> {
              process.send(reply, Error(StartFailed(string.inspect(reason))))
              actor.continue(state)
            }
          }
        }
      }
  }
}

fn handle_rest(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Get(id, reply) -> {
      let resolved = case dict.get(state.sessions, id) {
        Ok(record) ->
          case record.start_error {
            Some(_) ->
              // A persisted session whose rehydrating restart failed:
              // retry now rather than staying unavailable (the store may
              // have come back). Unpersisted ones stay Phase 1.
              case record.persisted {
                True -> retry_rehydrate(state, record)
                False -> Missing
              }
            None -> Subject(record.subject)
          }
        Error(_) ->
          // Phase 2: a stored-but-not-live id lazily starts hydrated.
          case dict.get(state.dormant, id) {
            Ok(summary) -> lazy_start(state, summary)
            Error(_) -> Missing
          }
      }
      case resolved {
        Subject(subject) -> {
          process.send(reply, Ok(subject))
          actor.continue(state)
        }
        Missing -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        Started(next) -> {
          case dict.get(next.sessions, id) {
            Ok(record) -> process.send(reply, Ok(record.subject))
            Error(_) -> process.send(reply, Error(Nil))
          }
          actor.continue(next)
        }
      }
    }

    List(reply) -> {
      let live =
        state.sessions
        |> dict.values()
        |> list.filter_map(fn(record) {
          case record.start_error {
            Some(_) -> Error(Nil)
            None ->
              // A session killed a moment ago may still be listed with
              // its down message queued; skip it rather than blocking
              // the whole list on a dead subject.
              case process.is_alive(record.pid) {
                True -> Ok(summarise(record, session.describe(record.subject)))
                False -> Error(Nil)
              }
          }
        })
      // Dormant (stored-but-not-live) sessions are listed too: metadata
      // comes from the store; metrics are in-memory only by design, so
      // they resume empty.
      let dormant =
        state.dormant
        |> dict.values()
        |> list.map(stored_summary_as)
      process.send(
        reply,
        list.sort(list.append(live, dormant), compare_summaries),
      )
      actor.continue(state)
    }

    SetTitle(id, title, reply) ->
      apply_meta(
        state,
        id,
        reply,
        fn(record) {
          Record(
            ..record,
            title: string.trim(title),
            title_source: session.ManualTitle,
          )
        },
        fn(summary) {
          store.StoredSummary(
            ..summary,
            title: string.trim(title),
            title_source: session.ManualTitle,
          )
        },
        fn() { state.store.set_title(id, string.trim(title)) },
      )

    AutoTitle(id, title, reply) ->
      // Only while the auto title is untouched: a manual rename (or an
      // earlier auto title) must never be clobbered. The reply says whether
      // it actually applied. The store's auto_title carries the same guard
      // in SQL, so the write-through cannot resurrect a clobbered title.
      apply_meta_guarded(
        state,
        id,
        reply,
        fn(record) {
          case record.title_source, record.title {
            session.AutoTitle, "" -> {
              write_through_or_log(id, fn() {
                state.store.auto_title(id, string.trim(title))
                |> result.map(fn(_) { Nil })
              })
              Ok(Record(..record, title: string.trim(title)))
            }
            _, _ -> Error(Nil)
          }
        },
        fn(summary) {
          case summary.title_source, summary.title {
            session.AutoTitle, "" -> {
              write_through_or_log(id, fn() {
                state.store.auto_title(id, string.trim(title))
                |> result.map(fn(_) { Nil })
              })
              Ok(store.StoredSummary(..summary, title: string.trim(title)))
            }
            _, _ -> Error(Nil)
          }
        },
      )

    SetPinned(id, pinned, reply) ->
      // Invariant: an archived session is never pinned. Pinning is
      // refused (reply False, record untouched) so a pin can never
      // resurface from behind the archive toggle — pairing with
      // `SetArchived`, which clears the pin when archiving.
      apply_meta_guarded(
        state,
        id,
        reply,
        fn(record) {
          let #(record, applied) = case pinned, record.archived {
            True, True -> #(record, False)
            _, _ -> #(Record(..record, pinned: pinned), True)
          }
          case applied {
            True -> {
              let _ = state.store.set_pinned(id, pinned)
              Ok(record)
            }
            False -> Error(Nil)
          }
        },
        fn(summary) {
          let #(summary, applied) = case pinned, summary.archived {
            True, True -> #(summary, False)
            _, _ -> #(store.StoredSummary(..summary, pinned: pinned), True)
          }
          case applied {
            True -> {
              let _ = state.store.set_pinned(id, pinned)
              Ok(summary)
            }
            False -> Error(Nil)
          }
        },
      )

    SetTags(id, tags, reply) ->
      apply_meta(
        state,
        id,
        reply,
        fn(record) { Record(..record, tags: normalize_tags(tags)) },
        fn(summary) {
          store.StoredSummary(..summary, tags: normalize_tags(tags))
        },
        fn() { state.store.set_tags(id, normalize_tags(tags)) },
      )

    SetArchived(id, archived, reply) ->
      apply_meta(
        state,
        id,
        reply,
        fn(record) {
          case archived {
            // Archiving implicitly unpins — the pinned section only ever
            // holds active sessions (the twin of the SetPinned refusal
            // above; together they keep `archived ⇒ ¬pinned` true).
            True -> Record(..record, archived: True, pinned: False)
            False -> Record(..record, archived: False)
          }
        },
        fn(summary) {
          case archived {
            True ->
              store.StoredSummary(..summary, archived: True, pinned: False)
            False -> store.StoredSummary(..summary, archived: False)
          }
        },
        fn() {
          case archived {
            True -> state.store.archive(id)
            False -> state.store.unarchive(id)
          }
        },
      )

    Delete(id, reply) -> {
      let known = case dict.get(state.sessions, id) {
        Ok(record) -> {
          // Drop the monitor BEFORE the kill so the actor's DOWN cannot
          // trigger a replacement (factory children are Temporary; only
          // the registry restarts them, and a deleted session must stay
          // dead). demonitor flushes, so no stale DOWN can loop later.
          let _ = process.demonitor_process(record.monitor)
          // Ask the actor to cancel any in-flight turn (the cancel path
          // commits partial text server-side), then take it down. The
          // stored rows go with the record either way.
          process.send(record.subject, session.Stop)
          process.kill(record.pid)
          True
        }
        Error(_) ->
          case dict.get(state.dormant, id) {
            Ok(_) -> True
            Error(_) -> False
          }
      }
      case known {
        False -> {
          process.send(reply, False)
          actor.continue(state)
        }
        True -> {
          // Hard delete in the store; Postgres cascades to the session's
          // message rows.
          case state.store.delete_session(id) {
            Ok(_) -> Nil
            Error(error) -> log_store_error("delete_session " <> id, error)
          }
          process.send(reply, True)
          actor.continue(
            State(
              ..state,
              sessions: dict.delete(state.sessions, id),
              dormant: dict.delete(state.dormant, id),
            ),
          )
        }
      }
    }

    Down(pid, monitor) -> {
      case find_by_pid(state.sessions, pid) {
        None -> actor.continue(state)
        Some(record) -> {
          // Drop the stale monitor before restarting so a duplicate down
          // for the dead actor cannot loop the restart.
          let _ = process.demonitor_process(monitor)
          // Phase 2: a persisted session's replacement rehydrates from the
          // store (its commits were persisted write-behind, in order,
          // before this DOWN was processed). Unpersisted sessions keep
          // the Phase 1 empty-restart semantics.
          let spec = case record.persisted {
            True ->
              case rebuild_transcript(state, record.id) {
                Ok(transcript) ->
                  session.SessionSpec(..record.spec, hydrate: Some(transcript))
                Error(error) -> {
                  log_store_error("rehydrate " <> record.id, error)
                  record.spec
                }
              }
            False -> record.spec
          }
          let argument = ChildArgument(spec: spec, name: record.name)
          case restart(state.factory, argument) {
            Ok(started) -> {
              let restarted =
                Record(
                  ..record,
                  subject: started.data,
                  pid: started.pid,
                  monitor: process.monitor(started.pid),
                  start_error: None,
                )
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, record.id, restarted),
                ),
              )
            }
            Error(reason) -> {
              // Keep the record so the failure is visible (HTTP 503) rather
              // than silently dropping the session.
              let failed =
                Record(..record, start_error: Some(string.inspect(reason)))
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, record.id, failed),
                ),
              )
            }
          }
        }
      }
    }

    MonitorNoise -> actor.continue(state)

    // Create cases are handled in `handle` before delegating here.
    Create(..) | CreateWithRunner(..) -> actor.continue(state)
  }
}

// ---------------------------------------------------------------------------
// Phase 2: hydration, lazy start, write-through plumbing
// ---------------------------------------------------------------------------

/// The store's write-behind lane for one session — the injected commit
/// hook. A closure over the seam and the id, exactly like the injected
/// turn runner: the session module never learns about the registry or the
/// store.
fn commit_hook_for(persistence: Store, id: String) -> fn(Transcript) -> Nil {
  fn(transcript) { persistence.commit(id, transcript) }
}

/// Rebuild a stored session's transcript through the one construction
/// path: `transcript.new(model, system_prompt)` + `append_*` over the rows
/// in seq order.
fn rebuild_transcript(state: State, id: String) -> Result(Transcript, String) {
  use stored <- result.try(state.store.get_session(id))
  use rows <- result.try(state.store.load_messages(id))
  Ok(store.transcript_from_rows(
    stored.summary.model,
    stored.system_prompt,
    rows,
  ))
}

/// Lazily start a dormant (stored-but-not-live) session, hydrated from the
/// store. Replies through the returned state transition; unknown-store
/// failures keep the session dormant (the next Get retries).
fn lazy_start(state: State, summary: StoredSummary) -> Resolved {
  // The dormant row pins its provider: resolve the endpoint by the
  // persisted id, exactly like create did. A provider that went away
  // (disabled, or its envelope no longer decrypts) keeps the session
  // dormant rather than starting an actor that cannot stream — the same
  // Get later (e.g. after re-enabling) retries it.
  case state.resolve_provider(summary.provider_id) {
    Error(reason) -> {
      io.println(
        "nexus registry: lazy_start "
        <> summary.id
        <> " failed: provider "
        <> summary.provider_id
        <> " cannot stream ("
        <> case reason {
          ProviderUnknown -> "unknown"
          ProviderDisabled -> "disabled"
          ProviderKeyUnavailable -> "key unavailable"
        }
        <> "); session stays dormant",
      )
      Missing
    }
    Ok(endpoint) ->
      case rebuild_transcript(state, summary.id) {
        Error(error) -> {
          log_store_error("lazy_start " <> summary.id, error)
          Missing
        }
        Ok(transcript) -> {
          let spec =
            session.SessionSpec(
              cfg: state.cfg,
              model: summary.model,
              endpoint: endpoint,
              runner: state.runner,
              commit_hook: commit_hook_for(state.store, summary.id),
              hydrate: Some(transcript),
            )
          let argument =
            ChildArgument(
              spec: spec,
              name: process.new_name("nexus_session_" <> summary.id),
            )
          case restart(state.factory, argument) {
            Ok(started) -> {
              let record =
                Record(
                  id: summary.id,
                  provider_id: summary.provider_id,
                  model: summary.model,
                  subject: started.data,
                  pid: started.pid,
                  monitor: process.monitor(started.pid),
                  spec: spec,
                  name: argument.name,
                  start_error: None,
                  title: summary.title,
                  title_source: summary.title_source,
                  pinned: summary.pinned,
                  tags: summary.tags,
                  archived: summary.archived,
                  created_at: summary.created_at,
                  persisted: True,
                )
              Started(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, summary.id, record),
                  dormant: dict.delete(state.dormant, summary.id),
                ),
              )
            }
            Error(reason) -> {
              log_store_error(
                "lazy_start " <> summary.id,
                string.inspect(reason),
              )
              Missing
            }
          }
        }
      }
  }
}

/// Retry the rehydrating restart of a persisted session whose last attempt
/// failed (its record carries `start_error`).
fn retry_rehydrate(state: State, record: Record) -> Resolved {
  case rebuild_transcript(state, record.id) {
    Error(error) -> {
      log_store_error("retry_rehydrate " <> record.id, error)
      Missing
    }
    Ok(transcript) -> {
      let spec = session.SessionSpec(..record.spec, hydrate: Some(transcript))
      let argument = ChildArgument(spec: spec, name: record.name)
      case restart(state.factory, argument) {
        Ok(started) -> {
          let restarted =
            Record(
              ..record,
              subject: started.data,
              pid: started.pid,
              monitor: process.monitor(started.pid),
              start_error: None,
            )
          Started(
            State(
              ..state,
              sessions: dict.insert(state.sessions, record.id, restarted),
            ),
          )
        }
        Error(reason) -> {
          log_store_error(
            "retry_rehydrate " <> record.id,
            string.inspect(reason),
          )
          Missing
        }
      }
    }
  }
}

/// Apply `f` to the live record or the dormant summary (whichever holds
/// the id) and write the change through to the store. `False` when the id
/// is unknown.
fn apply_meta(
  state: State,
  id: String,
  reply: Subject(Bool),
  on_record: fn(Record) -> Record,
  on_summary: fn(StoredSummary) -> StoredSummary,
  write_through: fn() -> Result(Nil, String),
) -> actor.Next(State, Msg) {
  let #(next, applied) = case dict.get(state.sessions, id) {
    Ok(record) -> {
      write_through_or_log(id, write_through)
      #(
        State(
          ..state,
          sessions: dict.insert(state.sessions, id, on_record(record)),
        ),
        True,
      )
    }
    Error(_) ->
      case dict.get(state.dormant, id) {
        Ok(summary) -> {
          write_through_or_log(id, write_through)
          #(
            State(
              ..state,
              dormant: dict.insert(state.dormant, id, on_summary(summary)),
            ),
            True,
          )
        }
        Error(_) -> #(state, False)
      }
  }
  process.send(reply, applied)
  actor.continue(next)
}

/// Like `apply_meta`, but the mutator can refuse (e.g. pinning an archived
/// session, auto-title with an existing title): a `None` result replies
/// `False` and mutates nothing. The mutators perform their own guarded
/// write-through.
fn apply_meta_guarded(
  state: State,
  id: String,
  reply: Subject(Bool),
  on_record: fn(Record) -> Result(Record, Nil),
  on_summary: fn(StoredSummary) -> Result(StoredSummary, Nil),
) -> actor.Next(State, Msg) {
  let #(next, applied) = case dict.get(state.sessions, id) {
    Ok(record) ->
      case on_record(record) {
        Ok(updated) -> #(
          State(..state, sessions: dict.insert(state.sessions, id, updated)),
          True,
        )
        Error(Nil) -> #(state, False)
      }
    Error(_) ->
      case dict.get(state.dormant, id) {
        Ok(summary) ->
          case on_summary(summary) {
            Ok(updated) -> #(
              State(..state, dormant: dict.insert(state.dormant, id, updated)),
              True,
            )
            Error(Nil) -> #(state, False)
          }
        Error(_) -> #(state, False)
      }
  }
  process.send(reply, applied)
  actor.continue(next)
}

fn write_through_or_log(id: String, write: fn() -> Result(Nil, String)) -> Nil {
  case write() {
    Ok(_) -> Nil
    Error(error) -> log_store_error("write-through " <> id, error)
  }
}

fn log_store_error(context: String, error: String) -> Nil {
  io.println("nexus registry: store " <> context <> " failed: " <> error)
}

/// Tags are normalized on write: trimmed, empties dropped, duplicates
/// removed (first occurrence wins — insertion order is display order).
fn normalize_tags(tags: List(String)) -> List(String) {
  tags
  |> list.map(string.trim)
  |> list.filter(fn(tag) { tag != "" })
  |> list.unique
}

/// Sidebar title from a first user message: collapse whitespace runs to
/// single spaces, trim, truncate (with an ellipsis) at 60 characters. No
/// LLM call — organizational metadata that lives beside the transcript and
/// never enters a request body. Shared by the HTTP send boundary and the
/// UI component's send effect (both are places that already hold the
/// outgoing text; message content never crosses session→registry).
const title_limit = 60

pub fn title_from_first_message(text: String) -> String {
  let flat = collapse_whitespace(text)
  case string.length(flat) > title_limit {
    True -> string.slice(flat, 0, title_limit) <> "…"
    False -> flat
  }
}

/// Collapse every whitespace run (spaces, tabs, newlines) to single spaces
/// and trim — a multi-line first message still reads as one title line.
/// The CRLF pair must go first: Erlang's Unicode `string:replace` does not
/// match a lone "\r" inside "\r\n".
fn collapse_whitespace(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
  |> string.trim
}

/// Sidebar order: pinned first, then most recently active first; ties break
/// newest-created first, then by ID — deterministic and stable.
fn compare_summaries(
  a: session.SessionSummary,
  b: session.SessionSummary,
) -> Order {
  case a.pinned, b.pinned {
    True, False -> Lt
    False, True -> Gt
    _, _ ->
      case int.compare(b.last_active_at, a.last_active_at) {
        Eq ->
          case int.compare(b.created_at, a.created_at) {
            Eq -> string.compare(a.id, b.id)
            ord -> ord
          }
        ord -> ord
      }
  }
}

fn as_public(record: Record) -> SessionRecord {
  SessionRecord(
    id: record.id,
    model: record.model,
    subject: record.subject,
    pid: record.pid,
  )
}

fn summarise(
  record: Record,
  status: session.SessionStatus,
) -> session.SessionSummary {
  session.SessionSummary(
    id: record.id,
    provider_id: record.provider_id,
    model: record.model,
    title: record.title,
    title_source: record.title_source,
    pinned: record.pinned,
    tags: record.tags,
    archived: record.archived,
    message_count: status.message_count,
    streaming: status.streaming,
    created_at: record.created_at,
    // Until the first commit, a session's activity is its creation.
    last_active_at: case status.last_commit_at {
      0 -> record.created_at
      committed -> committed
    },
    metrics: status.metrics,
  )
}

/// A dormant session's summary: stored metadata, never streaming, and
/// metrics empty by design (MetricSample history is in-memory only).
fn stored_summary_as(summary: StoredSummary) -> session.SessionSummary {
  session.SessionSummary(
    id: summary.id,
    provider_id: summary.provider_id,
    model: summary.model,
    title: summary.title,
    title_source: summary.title_source,
    pinned: summary.pinned,
    tags: summary.tags,
    archived: summary.archived,
    message_count: summary.message_count,
    streaming: False,
    created_at: summary.created_at,
    last_active_at: summary.last_active_at,
    metrics: [],
  )
}

fn find_by_pid(sessions: Dict(String, Record), pid: Pid) -> Option(Record) {
  let found =
    sessions
    |> dict.values()
    |> list.filter(fn(record: Record) { record.pid == pid })
    |> list.first
  case found {
    Ok(record) -> Some(record)
    Error(_) -> None
  }
}

/// Start a session child, retrying once after a short pause. A killed
/// actor's registered name frees asynchronously, so the first attempt can
/// hit `already_started` even though the process is gone (M2 §9 restart
/// races). One retry keeps the loop bounded and the failure visible.
fn restart(
  factory: Factory,
  argument: ChildArgument,
) -> Result(actor.Started(Subject(session.Msg)), actor.StartError) {
  case factory_supervisor.start_child(factory, argument) {
    Error(already_started) -> {
      process.sleep(50)
      case factory_supervisor.start_child(factory, argument) {
        Ok(started) -> Ok(started)
        Error(_) -> Error(already_started)
      }
      |> result.replace_error(already_started)
    }
    other -> other
  }
}

// ---------------------------------------------------------------------------
// Client helpers
// ---------------------------------------------------------------------------

pub fn create(
  registry: Subject(Msg),
  provider_id: String,
  model: String,
) -> Result(SessionRecord, CreateError) {
  actor.call(registry, 5000, fn(reply) { Create(provider_id:, model:, reply:) })
}

/// Test seam: create a session with an injected turn runner.
pub fn create_with_runner(
  registry: Subject(Msg),
  provider_id: String,
  model: String,
  runner: session.TurnRunner,
) -> Result(SessionRecord, CreateError) {
  actor.call(registry, 5000, fn(reply) {
    CreateWithRunner(provider_id:, model:, runner:, reply:)
  })
}

pub fn get(
  registry: Subject(Msg),
  id: String,
) -> Result(Subject(session.Msg), Nil) {
  actor.call(registry, 5000, fn(reply) { Get(id:, reply:) })
}

pub fn list_sessions(registry: Subject(Msg)) -> List(session.SessionSummary) {
  actor.call(registry, 5000, List)
}

/// Manual rename — marks the title manual so auto-generation can never
/// clobber it. `False` when the ID is unknown.
pub fn set_title(registry: Subject(Msg), id: String, title: String) -> Bool {
  actor.call(registry, 5000, fn(reply) { SetTitle(id:, title:, reply:) })
}

/// Auto-title from the first user message; applies only while the title
/// is still the untouched auto default.
pub fn auto_title(registry: Subject(Msg), id: String, title: String) -> Bool {
  actor.call(registry, 5000, fn(reply) { AutoTitle(id:, title:, reply:) })
}

pub fn set_pinned(registry: Subject(Msg), id: String, pinned: Bool) -> Bool {
  actor.call(registry, 5000, fn(reply) { SetPinned(id:, pinned:, reply:) })
}

pub fn set_tags(
  registry: Subject(Msg),
  id: String,
  tags: List(String),
) -> Bool {
  actor.call(registry, 5000, fn(reply) { SetTags(id:, tags:, reply:) })
}

pub fn set_archived(
  registry: Subject(Msg),
  id: String,
  archived: Bool,
) -> Bool {
  actor.call(registry, 5000, fn(reply) { SetArchived(id:, archived:, reply:) })
}

/// Hard removal: stops the child actor, deletes the stored rows, and drops
/// the record.
pub fn delete_session(registry: Subject(Msg), id: String) -> Bool {
  actor.call(registry, 5000, fn(reply) { Delete(id:, reply:) })
}
