//// M2 thread registry: a supervised actor that owns the user-visible
//// thread IDs, the model aliases pinned per thread, the thread subjects
//// and their monitors, and the child-start specification handed to the
//// factory supervisor.
////
//// Multi-provider P3: creation and lazy hydration resolve each thread's
//// provider id into a FROZEN `openai.Endpoint` through an injected
//// resolver (boot maps `nexus/provider_registry`; tests inject a pure
//// fn) — a thread only ever exists with its (provider, model) pin in
//// place, and the endpoint rides the spec for the actor's whole life.
////
//// Supervision model (M2 §4.1): thread children run under the named
//// factory supervisor with a **temporary** restart strategy, so the factory
//// never silently replaces a PID behind our back. The registry owns the
//// monitors and asks the factory to start the *same* specification again
//// when a thread actor exits — the replacement reuses the registered name
//// and keeps the user-visible ID.
////
//// Dependency direction is strictly registry → thread: the registry calls
//// `thread.describe`, and no thread code path ever calls back into the
//// registry (that would deadlock). Phase 2 persistence keeps this: the
//// thread actor only sees an injected `commit_hook` closure (the store's
//// write-behind lane), exactly like the injected turn runner.
////
//// Phase 2 (durable persistence): the registry hydrates the **dormant**
//// set (stored-but-not-live threads) from the store seam at boot and
//// mints ids past every stored id. Never-used threads (system prompt
//// only, untitled, unpinned) past a grace window do not survive a boot:
//// one bulk delete (the seam's `prune_never_used`) runs before
//// hydration, so abandoned empties cannot accumulate in the sidebar —
//// threads exist because someone put a message in them. The
//// first `Get` of a dormant id lazily
//// starts a hydrated actor — the transcript is rebuilt through
//// `nexus/transcript.new(model, system_prompt)` + the existing `append_*`
//// functions only, so the request prefix is byte-identical across the
//// restart (KV-cache contract). Turn commits persist write-behind through
//// the hook; metadata mutations write through synchronously. A dead
//// actor's replacement rehydrates from the store instead of starting
//// empty (Phase 1 semantics survive only for threads whose row insert
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
import nexus/store.{type Store, type StoredSummary}
import nexus/thread
import nexus/timing
import nexus/tools
import nexus/transcript.{type Transcript}
import nexus/utility

/// The factory's child-start argument: everything needed to (re)start one
/// thread actor identically.
pub type ChildArgument {
  ChildArgument(spec: thread.ThreadSpec, name: process.Name(thread.Msg))
}

/// The creation request (bots prep, #73): everything a new thread freezes
/// at birth. `system_prompt: None` means the global default, resolved HERE
/// at creation — the one NULL/default resolution point, and the value the
/// same insert persists, so hydration rebuilds a byte-identical prefix.
/// `bot_id` is the bots plan's provenance pointer (P1): the bot a
/// create-from-bot sourced these values from, persisted onto the row and
/// projected into summaries. Display-only — the frozen columns are the
/// thread's truth; the bot row is never read back.
pub type NewThread {
  NewThread(
    provider_id: String,
    model: String,
    system_prompt: Option(String),
    bot_id: Option(String),
  )
}

/// Reply payload for `Create`: a failure the HTTP layer maps onto a
/// status code. Success carries the fresh `ThreadSummary` directly, so
/// neither surface (HTTP, UI) ever hand-builds one (#73).
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
  /// key or a tampered row): the thread cannot stream until an operator
  /// intervenes. Surfaced as a server-side failure, not a client error.
  ProviderKeyUnavailable
}

/// The provider seam: `provider_id` → the endpoint a thread freezes for
/// its lifetime. Production resolves through `nexus/provider_registry`;
/// tests inject a pure fn.
pub type ResolveProvider =
  fn(String) -> Result(openai.Endpoint, ProviderError)

/// Reply payload for `UpgradeAutoTitle`: what the guard decided. Carries
/// the fresh display metadata on success so the thread actor can broadcast
/// `MetaUpdated` truthfully without a second round-trip.
pub type UpgradeOutcome {
  /// Applied: the thread's fresh title + merged display tags.
  UpgradeApplied(title: String, tags: List(String))
  /// Refused: `title_source` OR `tags_source` is manual (a rename or a
  /// manual tag edit each win forever), the id is unknown, or the title
  /// was empty.
  UpgradeRefused
}

pub type Msg {
  /// Start a new thread from `NewThread` (provider pin + model + optional
  /// explicit system prompt) using the registry's frozen tool runner
  /// (built once at registry start, so the tool schema is identical in
  /// every request of every thread). Replies with the fresh
  /// `ThreadSummary`.
  Create(
    requested: NewThread,
    reply: Subject(Result(thread.ThreadSummary, CreateError)),
  )
  /// Test seam: start a thread with an injected toolset bundle — its own
  /// specs and turn + utility runners, carried verbatim into the thread
  /// spec (no cache consult: an injected bundle means "use THIS one").
  CreateWithToolset(
    requested: NewThread,
    toolset: thread.Toolset,
    reply: Subject(Result(thread.ThreadSummary, CreateError)),
  )
  /// Resolve a thread subject — live, or a stored-but-not-live id
  /// (Phase 2: which lazily starts a hydrated actor). `Error(Nil)` for
  /// unknown ids or for threads whose restart failed.
  Get(id: String, reply: Subject(Result(Subject(thread.Msg), Nil)))
  /// All threads (live + dormant), pinned first then most-recently-active
  /// first. Archiving does not hide a thread from the list — callers
  /// (HTTP, UI) filter by the `archived` flag.
  List(reply: Subject(List(thread.ThreadSummary)))
  /// Manual rename: always wins and marks the title `ManualTitle` so no
  /// later auto-generation can clobber it.
  SetTitle(id: String, title: String, reply: Subject(Bool))
  /// Auto-title from the first user message (HTTP send boundary). Applies
  /// only while the title is still the untouched auto default, so a manual
  /// rename is never overwritten. Keeps `title_source` auto.
  AutoTitle(id: String, title: String, reply: Subject(Bool))
  /// Model-generated metadata upgrade (utility-titles plan §4.3 +
  /// utility-tags plan §3.5): replaces the heuristic placeholder title
  /// AND merges the model's tags into the display set while
  /// `title_source = 'auto'` AND `tags_source = 'auto'` — a manual rename
  /// or a manual tag edit each close their side forever, refusing the
  /// whole ask. The reply says what happened (and carries the fresh
  /// metadata); the store write-through carries the same guard, so the
  /// twin invariant of the `AutoTitle` pair holds on both provenance
  /// columns.
  UpgradeAutoTitle(
    id: String,
    title: String,
    tags: List(String),
    reply: Subject(UpgradeOutcome),
  )
  /// The reuse-vocabulary ask (utility-tags plan §3.3): the top tags
  /// across every thread the registry knows (active + dormant),
  /// normalized before counting, frequency-floored, count-ordered with
  /// alphabetical tie-break. Asked by the utility WORKER through the
  /// real runner's corpus closure — never by the registry's own process.
  TagCorpus(reply: Subject(List(String)))
  SetPinned(id: String, pinned: Bool, reply: Subject(Bool))
  SetTags(id: String, tags: List(String), reply: Subject(Bool))
  SetArchived(id: String, archived: Bool, reply: Subject(Bool))
  /// Hard removal: stop the child actor (factory children are Temporary,
  /// and the registry owns the monitors), delete the stored rows, then
  /// drop the record. `False` for unknown IDs.
  Delete(id: String, reply: Subject(Bool))
  /// A bot was deleted (bots plan P1): scrub that id from every summary
  /// half's provenance pointer. The caller orchestrates — registries
  /// never call each other. No store write (the FK's SET NULL already
  /// fixed every row inside the delete itself).
  BotDeleted(id: String, reply: Subject(Nil))
  /// Monitor plumbing (internal): a monitored thread actor exited.
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
    subject: Subject(thread.Msg),
    pid: Pid,
    monitor: Monitor,
    /// Retained so a dead actor can be restarted identically.
    spec: thread.ThreadSpec,
    name: process.Name(thread.Msg),
    /// Set when a restart failed: the thread stays listed but reports as
    /// unavailable, rather than the registry looping on start attempts.
    start_error: Option(String),
    // ---- Organizational metadata (beside the transcript, never in it) ----
    /// Shared verbatim with the dormant store summaries
    /// (`thread.ThreadMeta`, issue #75): one type, so a new metadata
    /// column is one field in one place and every meta mutation below
    /// has a single guard instead of twin Record/StoredSummary closures.
    meta: thread.ThreadMeta,
    /// Phase 2: the thread row was persisted. Unpersisted threads (the
    /// insert failed at create) keep Phase 1 restart semantics — empty
    /// transcript, no rehydration attempts.
    persisted: Bool,
  )
}

type State {
  State(
    cfg: Config,
    /// The default toolset's resolved names — the key under which the
    /// boot-built bundle is cached below, and what plain creates resolve
    /// through the cache (the default snapshot IS the boot bundle).
    default_names: List(String),
    /// Per-toolset runner bundles, cached by the name tuple (bots plan
    /// P2 prep, #76). Seeded at boot with the default bundle — today the
    /// only entry, since plain creates all resolve through it. P2's
    /// create-from-bot path is the first WRITER: a new name tuple builds
    /// its bundle once (specs via `tools.by_names`, turn + utility
    /// runners over them) and every later thread of that toolset shares
    /// it, so threads of one toolset keep byte-identical
    /// `tools` / `tool_choice` envelopes and each bundle's utility
    /// side-call rides its own turn envelope by construction.
    toolsets: Dict(List(String), thread.Toolset),
    /// This actor's own subject: the utility apply closures ask the
    /// UpgradeAutoTitle guard through it from the (unlinked) utility
    /// worker process.
    self: Subject(Msg),
    /// The provider seam: resolves the endpoint frozen into each thread
    /// spec at create and lazy-hydration time.
    resolve_provider: ResolveProvider,
    factory: Factory,
    threads: Dict(String, Record),
    /// Phase 2: stored-but-not-live threads (boot hydration). The first
    /// Get of such an id lazily starts a hydrated actor and promotes the
    /// entry to `threads`.
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
  Subject(subject: Subject(thread.Msg))
  Missing
  Started(next: State)
}

pub type Factory =
  factory_supervisor.Supervisor(ChildArgument, Subject(thread.Msg))

/// The named factory supervisor's child template: start one thread actor
/// under its own registered name.
pub fn thread_child(
  argument: ChildArgument,
) -> actor.StartResult(Subject(thread.Msg)) {
  thread.supervised(argument.spec, argument.name)
}

/// Builder for the boot-time factory supervisor: thread actors are started
/// dynamically as temporary children, so only the registry replaces them.
pub fn factory_builder(
  name: process.Name(
    factory_supervisor.Message(ChildArgument, Subject(thread.Msg)),
  ),
) -> factory_supervisor.Builder(ChildArgument, Subject(thread.Msg)) {
  factory_builder_with_child(name, thread_child)
}

/// Test seam: build the factory with a custom child starter so a startup
/// failure can be produced without touching the real thread constructor.
pub fn factory_builder_with_child(
  name: process.Name(
    factory_supervisor.Message(ChildArgument, Subject(thread.Msg)),
  ),
  child: fn(ChildArgument) -> actor.StartResult(Subject(thread.Msg)),
) -> factory_supervisor.Builder(ChildArgument, Subject(thread.Msg)) {
  factory_supervisor.worker_child(child)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  // The registry — not the factory — drives replacements, so give it room:
  // a burst of thread churn must not take the factory itself down.
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
  // any thread exists — so every request any thread of the default toolset
  // ever sends carries the identical (byte-stable) tool schema. The SAME
  // specs build the utility side-call runner, so the title branch's
  // envelope is the turn envelope by construction (KV-cache contract);
  // bundling them into one Toolset keeps that property per toolset. The
  // runner's corpus closure asks THIS registry (by name) for the reuse
  // vocabulary from inside the utility worker — Y is the tail message,
  // generation-side only, so the dynamic corpus can never touch the
  // cached prefix (utility-tags plan §3.3).
  let names = tools.default_names(cfg)
  let assert Ok(specs) = tools.by_names(cfg, names)
  let corpus = tag_corpus_for(name)
  let default_toolset =
    thread.Toolset(
      names: names,
      specs: specs,
      runner: thread.agent_runner(cfg.max_tool_iterations, specs),
      utility_runner: thread.utility_runner(specs, corpus),
    )
  start_with_toolset(
    cfg,
    factory,
    name,
    persistence,
    default_toolset,
    corpus,
    resolve_provider,
  )
}

/// Test seam: the same registry with an injected default toolset bundle —
/// hydration (boot, lazy start, restart recovery) then uses it for every
/// thread it starts, exactly like production uses the boot-built bundle.
/// `_corpus` is the TagCorpus seam the real utility runner asks (§3.3):
/// accepted beside the bundle so the seam mirrors `start`'s plumbing (a
/// test booting the real runner closes over its corpus the same way), and
/// deliberately unused here — whether a corpus is asked at all is the
/// injected runner's business, and fakes never ask.
pub fn start_with_toolset(
  cfg: Config,
  factory: Factory,
  name: process.Name(Msg),
  persistence: Store,
  default_toolset: thread.Toolset,
  _corpus: fn() -> List(String),
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
          Error("thread store unreachable, cannot hydrate: " <> error)
        Ok(summaries) -> {
          let dormant =
            list.fold(summaries, dict.new(), fn(dormant, summary) {
              dict.insert(dormant, summary.id, summary)
            })
          actor.initialised(State(
            cfg: cfg,
            default_names: default_toolset.names,
            toolsets: dict.from_list([
              #(default_toolset.names, default_toolset),
            ]),
            self: self,
            resolve_provider: resolve_provider,
            factory: factory,
            threads: dict.new(),
            dormant: dormant,
            // Seeded past the survivors AND the pruned ids: the bulk
            // prune is atomic, so reuse of a pruned id could not
            // collide — but minted ids stay monotonically increasing
            // across sweeps anyway (a deleted s5 must not come back as
            // a different thread).
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
/// ids never collide with dormant (stored-but-not-live) threads.
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

/// The boot sweep: delete every stored never-used thread older than
/// the grace window (see `prune_never_used.sql` for the full contract),
/// returning the ids it deleted ([] when the store had none or the
/// prune failed — a failure deletes nothing).
///
/// Why a boot-time sweep: threads used to be minted unconditionally at
/// every server start, so restarts (and nothing else) accumulated empty
/// rows forever. Creation is now always user-initiated, and this sweep
/// retires whatever empties earlier runs left behind — including one
/// created and abandoned mid-run, which is indistinguishable from those
/// rows and costs nothing (there is no content to lose; a first message
/// only counts once its turn committed). The grace window is what keeps
/// a thread another concurrently-running server created moments ago
/// (still empty until its first commit) from being deleted under its
/// live actor — 15 minutes is far past any first turn.
fn boot_sweep(persistence: Store) -> List(String) {
  case persistence.prune_never_used() {
    Ok([]) -> []
    Ok(ids) -> {
      io.println(
        "boot sweep: deleted "
        <> int.to_string(list.length(ids))
        <> " never-used thread(s): "
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
    Create(requested, reply) ->
      handle_create(state, requested, default_toolset(state), reply)

    CreateWithToolset(requested, toolset, reply) ->
      handle_create(state, requested, toolset, reply)

    _ -> handle_rest(state, msg)
  }
}

/// The registry's default toolset bundle: resolved through the boot-seeded
/// cache, so the default snapshot IS the boot-built bundle (#76). A miss
/// would mean the seed was dropped — a programmer error, crashed loudly.
fn default_toolset(state: State) -> thread.Toolset {
  let assert Ok(toolset) = dict.get(state.toolsets, state.default_names)
  toolset
}

fn handle_create(
  state: State,
  requested: NewThread,
  toolset: thread.Toolset,
  reply: Subject(Result(thread.ThreadSummary, CreateError)),
) -> actor.Next(State, Msg) {
  case string.trim(requested.model) {
    "" -> {
      process.send(reply, Error(EmptyModel))
      actor.continue(state)
    }
    alias ->
      // Resolve the endpoint FIRST: a thread is only ever created with
      // its frozen (provider, model) pin in place — there is no
      // create-then-attach path (multi-provider plan §8).
      case state.resolve_provider(requested.provider_id) {
        Error(reason) -> {
          process.send(reply, Error(ProviderFailed(reason)))
          actor.continue(state)
        }
        Ok(endpoint) -> {
          let counter = state.counter + 1
          let id = "s" <> int.to_string(counter)
          let name = process.new_name("nexus_thread_" <> id)
          // The registry resolves the system prompt at creation: an
          // explicit request prompt (a bot's, from the bots plan) or the
          // config default — the ONE NULL/default resolution point (#72).
          // It is frozen into the transcript here — the ONE construction
          // path — and the same prompt is persisted by insert_thread
          // below, so create and hydration always agree byte-identically.
          let prompt =
            option.unwrap(requested.system_prompt, state.cfg.system_prompt)
          let transcript = transcript.new(alias, prompt)
          let spec =
            thread.ThreadSpec(
              id: id,
              cfg: state.cfg,
              endpoint: endpoint,
              toolset: toolset,
              commit_hook: commit_hook_for(state.store, id),
              transcript: transcript,
              hydrated: False,
              utility_apply: utility_apply_for(state.self, id),
            )
          case
            factory_supervisor.start_child(
              state.factory,
              ChildArgument(spec:, name:),
            )
          {
            Ok(started) -> {
              let created_at = timing.wall_now_s()
              // The organizational block, built ONCE and shared by the
              // stored row and the live record (issue #75) — the reply
              // summary below only projects the same VALUES into the
              // deliberately flat `ThreadSummary`. "" title, open auto
              // paths, unlisted.
              let meta =
                thread.ThreadMeta(
                  title: "",
                  title_source: thread.AutoTitle,
                  pinned: False,
                  tags: [],
                  tags_manual: [],
                  tags_source: thread.AutoTags,
                  archived: False,
                  // Provenance only (bots plan P1): never read back — the
                  // frozen columns above are the thread's truth.
                  bot_id: requested.bot_id,
                  created_at: created_at,
                )
              // Write-through: the thread row lands now, with the frozen
              // alias and the frozen system prompt (contract rule 2), so
              // hydration can rebuild the frozen prefix byte-identically.
              let persisted = case
                state.store.insert_thread(
                  store.StoredSummary(
                    id: id,
                    provider_id: requested.provider_id,
                    model: alias,
                    meta: meta,
                    last_active_at: created_at,
                    // 1 = the system prompt (Phase 1 message_count).
                    message_count: 1,
                  ),
                  // The RESOLVED prompt — the exact bytes frozen into the
                  // transcript above, never the config default an explicit
                  // request may have overridden.
                  prompt,
                )
              {
                Ok(_) -> True
                Error(error) -> {
                  log_store_error("insert_thread " <> id, error)
                  False
                }
              }
              // The provenance pointer mirrors a STORED row's
              // FK-maintained column, so an unpersisted create (the insert
              // failed — store down, or the bot deleted between the
              // orchestration's lookup and this insert) must not claim one:
              // the bot-delete scrub cannot reach this record (it did not
              // exist at delete time), making this the one place a dead id
              // could otherwise ride a summary for the session's whole
              // life. The insert ATTEMPT above still carries the pointer —
              // the FK is what rejects a dead one.
              let meta = case persisted {
                True -> meta
                False -> thread.ThreadMeta(..meta, bot_id: None)
              }
              let record =
                Record(
                  id: id,
                  provider_id: requested.provider_id,
                  model: alias,
                  subject: started.data,
                  pid: started.pid,
                  monitor: process.monitor(started.pid),
                  spec: spec,
                  name: name,
                  start_error: None,
                  meta: meta,
                  persisted: persisted,
                )
              // The create reply IS the summary (#73): the same shape a
              // following List would report (message_count 1 = the system
              // prompt, activity = creation) — web and UI never hand-build
              // one again.
              process.send(
                reply,
                Ok(thread.ThreadSummary(
                  id: id,
                  provider_id: requested.provider_id,
                  model: alias,
                  title: "",
                  title_source: thread.AutoTitle,
                  pinned: False,
                  tags: [],
                  archived: False,
                  bot_id: meta.bot_id,
                  message_count: 1,
                  streaming: False,
                  created_at: created_at,
                  // Until the first commit, a thread's activity is its
                  // creation.
                  last_active_at: created_at,
                  metrics: [],
                )),
              )
              actor.continue(
                State(
                  ..state,
                  threads: dict.insert(state.threads, id, record),
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
      let resolved = case dict.get(state.threads, id) {
        Ok(record) ->
          case record.start_error {
            Some(_) ->
              // A persisted thread whose rehydrating restart failed:
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
          case dict.get(next.threads, id) {
            Ok(record) -> process.send(reply, Ok(record.subject))
            Error(_) -> process.send(reply, Error(Nil))
          }
          actor.continue(next)
        }
      }
    }

    List(reply) -> {
      let live =
        state.threads
        |> dict.values()
        |> list.filter_map(fn(record) {
          case record.start_error {
            Some(_) -> Error(Nil)
            None ->
              // A thread killed a moment ago may still be listed with
              // its down message queued; skip it rather than blocking
              // the whole list on a dead subject.
              case process.is_alive(record.pid) {
                True -> Ok(summarise(record, thread.describe(record.subject)))
                False -> Error(Nil)
              }
          }
        })
      // Dormant (stored-but-not-live) threads are listed too: metadata
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
        fn(meta) {
          thread.ThreadMeta(
            ..meta,
            title: string.trim(title),
            title_source: thread.ManualTitle,
          )
        },
        fn() { state.store.set_title(id, string.trim(title)) },
      )

    AutoTitle(id, title, reply) ->
      // Only while the auto title is untouched: a manual rename (or an
      // earlier auto title) must never be clobbered. The reply says whether
      // it actually applied. The store's auto_title carries the same guard
      // in SQL, so the write-through cannot resurrect a clobbered title.
      apply_meta_guarded(state, id, reply, fn(meta) {
        case meta.title_source, meta.title {
          thread.AutoTitle, "" -> {
            write_through_or_log(id, fn() {
              state.store.auto_title(id, string.trim(title))
              |> result.map(fn(_) { Nil })
            })
            Ok(thread.ThreadMeta(..meta, title: string.trim(title)))
          }
          _, _ -> Error(Nil)
        }
      })

    UpgradeAutoTitle(id, title, tags, reply) -> {
      // Model-metadata upgrade (utility-titles plan §4.3, extended by
      // utility-tags plan §3.5): the guard is provenance ONLY — the
      // title may upgrade while `title_source = 'auto'`, the display
      // tags may be written while `tags_source = 'auto'`; a manual
      // rename OR a manual tag edit refuses the whole ask (one request,
      // one guard, both writes — the review-caught P1). The in-memory
      // update and the store write-through carry the same guard
      // (twin-invariant pattern of the AutoTitle pair: the SQL refuses
      // what the memory would have refused, so a write-through cannot
      // resurrect a clobbered title or a frozen tag set). Unlike
      // AutoTitle there is no empty-title precondition: an auto title
      // may be REPLACED.
      //
      // Tags are MERGED, never clobbered: existing display entries pass
      // through VERBATIM (never re-canonicalized — a legacy `Work Notes`
      // stays `Work Notes`), the model's tags are normalized and appended
      // when not already present (case-insensitive, so `Work Notes` and
      // `work-notes` do not duplicate), and the union preserves existing
      // order, appends the new, then truncates at 5 — `utility.merge_tags`,
      // the one merge rule. The outcome carries the fresh display set so
      // the caller can broadcast it truthfully.
      let title = string.trim(title)
      // One guard + merge + store handshake over the shared meta
      // (issue #75): the live-record half and the dormant-summary half
      // differ only in WHICH dict they write back to. The store guard
      // has the final word (twin-invariant): `Ok(False)` means a
      // concurrent write changed the row's provenance behind this
      // instance's back — refuse and leave the in-memory state
      // untouched. An unreachable store keeps the documented degrade
      // mode: log, and keep the in-memory write so the UI stays
      // consistent.
      let upgrade = fn(meta: thread.ThreadMeta) -> Result(
        thread.ThreadMeta,
        UpgradeOutcome,
      ) {
        case meta.title_source, meta.tags_source {
          thread.AutoTitle, thread.AutoTags -> {
            let merged = utility.merge_tags(meta.tags, tags)
            case state.store.auto_meta_upgrade(id, title, merged) {
              Ok(True) ->
                Ok(thread.ThreadMeta(..meta, title: title, tags: merged))
              Ok(False) -> Error(UpgradeRefused)
              Error(error) -> {
                log_store_error("write-through " <> id, error)
                Ok(thread.ThreadMeta(..meta, title: title, tags: merged))
              }
            }
          }
          // A manual rename OR a manual tag edit wins forever:
          // refuse the whole ask, touch nothing. (For a dormant
          // summary the stored row is its ONLY state, so its refusal
          // is final.)
          _, _ -> Error(UpgradeRefused)
        }
      }
      let #(state, outcome) = case title {
        "" -> #(state, UpgradeRefused)
        _ ->
          case dict.get(state.threads, id) {
            Ok(record) ->
              case upgrade(record.meta) {
                Ok(meta) -> #(
                  State(
                    ..state,
                    threads: dict.insert(
                      state.threads,
                      id,
                      Record(..record, meta: meta),
                    ),
                  ),
                  UpgradeApplied(title, meta.tags),
                )
                Error(refused) -> #(state, refused)
              }
            Error(_) ->
              case dict.get(state.dormant, id) {
                Ok(summary) ->
                  case upgrade(summary.meta) {
                    Ok(meta) -> #(
                      State(
                        ..state,
                        dormant: dict.insert(
                          state.dormant,
                          id,
                          store.StoredSummary(..summary, meta: meta),
                        ),
                      ),
                      UpgradeApplied(title, meta.tags),
                    )
                    Error(refused) -> #(state, refused)
                  }
                Error(_) -> #(state, UpgradeRefused)
              }
          }
      }
      process.send(reply, outcome)
      actor.continue(state)
    }

    SetPinned(id, pinned, reply) ->
      // Invariant: an archived thread is never pinned. Pinning is
      // refused (reply False, state untouched) so a pin can never
      // resurface from behind the archive toggle — pairing with
      // `SetArchived`, which clears the pin when archiving.
      apply_meta_guarded(state, id, reply, fn(meta) {
        case pinned, meta.archived {
          True, True -> Error(Nil)
          _, _ -> {
            let _ = state.store.set_pinned(id, pinned)
            Ok(thread.ThreadMeta(..meta, pinned: pinned))
          }
        }
      })

    SetTags(id, tags, reply) -> {
      // The manual tags save (utility-tags plan §3.5): the user's exact
      // (normalized) set becomes the display set AND the manual set, and
      // the row's auto path closes — `set_tags.sql` writes
      // `tags = $1, tags_manual = $1, tags_source = 'manual'` in ONE
      // statement, so the freeze itself is atomic (all three fields or
      // nothing). A manual edit freezes the display set as the user wrote
      // it: no later merge can alter it, in flight or otherwise — the
      // in-memory twin check refuses a racing utility apply before the
      // store is ever consulted. On a store error the in-memory freeze
      // stands (the apply_meta degrade mode): the persisted row may lag,
      // the next manual save re-attempts the triple-write and heals it.
      let normalized = normalize_tags(tags)
      apply_meta(
        state,
        id,
        reply,
        fn(meta) {
          thread.ThreadMeta(
            ..meta,
            tags: normalized,
            tags_manual: normalized,
            tags_source: thread.ManualTags,
          )
        },
        fn() { state.store.set_tags(id, normalized) },
      )
    }

    SetArchived(id, archived, reply) ->
      apply_meta(
        state,
        id,
        reply,
        fn(meta) {
          case archived {
            // Archiving implicitly unpins — the pinned section only ever
            // holds active threads (the twin of the SetPinned refusal
            // above; together they keep `archived ⇒ ¬pinned` true).
            True -> thread.ThreadMeta(..meta, archived: True, pinned: False)
            False -> thread.ThreadMeta(..meta, archived: False)
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
      let known = case dict.get(state.threads, id) {
        Ok(record) -> {
          // Drop the monitor BEFORE the kill so the actor's DOWN cannot
          // trigger a replacement (factory children are Temporary; only
          // the registry restarts them, and a deleted thread must stay
          // dead). demonitor flushes, so no stale DOWN can loop later.
          let _ = process.demonitor_process(record.monitor)
          // Ask the actor to cancel any in-flight turn (the cancel path
          // commits partial text server-side), then take it down. The
          // stored rows go with the record either way.
          process.send(record.subject, thread.Stop)
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
          // Hard delete in the store; Postgres cascades to the thread's
          // message rows.
          case state.store.delete_thread(id) {
            Ok(_) -> Nil
            Error(error) -> log_store_error("delete_thread " <> id, error)
          }
          process.send(reply, True)
          actor.continue(
            State(
              ..state,
              threads: dict.delete(state.threads, id),
              dormant: dict.delete(state.dormant, id),
            ),
          )
        }
      }
    }

    BotDeleted(id, reply) -> {
      // One guard over the shared meta (issue #75 shape): the
      // live-record half and the dormant-summary half differ only in
      // WHICH dict they write back to. Everything but the pointer is
      // preserved; a stale pointer would otherwise ride both summary
      // paths until the next rehydration (`bot_display`'s missing-name
      // fallback hides it in the UI, but GET /threads would still
      // report a dead id). bot_id rides no query but insert_thread, so
      // nothing can write the dead pointer back behind this scrub.
      let scrub = fn(meta: thread.ThreadMeta) -> thread.ThreadMeta {
        case meta.bot_id {
          Some(bot_id) if bot_id == id -> thread.ThreadMeta(..meta, bot_id: None)
          _ -> meta
        }
      }
      let scrub_record = fn(record: Record) {
        Record(..record, meta: scrub(record.meta))
      }
      let threads =
        state.threads
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(id, record) = pair
          #(id, scrub_record(record))
        })
        |> dict.from_list
      let dormant =
        state.dormant
        |> dict.to_list
        |> list.map(fn(pair) {
          let #(id, summary) = pair
          #(id, store.StoredSummary(..summary, meta: scrub(summary.meta)))
        })
        |> dict.from_list
      process.send(reply, Nil)
      actor.continue(State(..state, threads: threads, dormant: dormant))
    }

    Down(pid, monitor) -> {
      case find_by_pid(state.threads, pid) {
        None -> actor.continue(state)
        Some(record) -> {
          // Drop the stale monitor before restarting so a duplicate down
          // for the dead actor cannot loop the restart.
          let _ = process.demonitor_process(monitor)
          // Phase 2: a persisted thread's replacement rehydrates from the
          // store (its commits were persisted write-behind, in order,
          // before this DOWN was processed). Unpersisted threads keep
          // the Phase 1 empty-restart semantics.
          let spec = case record.persisted {
            True ->
              case rebuild_transcript(state, record.id) {
                Ok(transcript) ->
                  thread.ThreadSpec(
                    ..record.spec,
                    transcript: transcript,
                    // The replacement is a hydrated restart: its first
                    // exchange predates the new actor, so it never
                    // attempts the utility-titles upgrade.
                    hydrated: True,
                  )
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
                  threads: dict.insert(state.threads, record.id, restarted),
                ),
              )
            }
            Error(reason) -> {
              // Keep the record so the failure is visible (HTTP 503) rather
              // than silently dropping the thread.
              let failed =
                Record(..record, start_error: Some(string.inspect(reason)))
              actor.continue(
                State(
                  ..state,
                  threads: dict.insert(state.threads, record.id, failed),
                ),
              )
            }
          }
        }
      }
    }

    TagCorpus(reply) -> {
      // The reuse-vocabulary ask (§3.3): answered from registry state
      // alone — the registry never calls into a thread, so the worker's
      // ask cannot deadlock.
      process.send(reply, compute_tag_corpus(state.threads, state.dormant))
      actor.continue(state)
    }

    MonitorNoise -> actor.continue(state)

    // Create cases are handled in `handle` before delegating here.
    Create(..) | CreateWithToolset(..) -> actor.continue(state)
  }
}

// ---------------------------------------------------------------------------
// Phase 2: hydration, lazy start, write-through plumbing
// ---------------------------------------------------------------------------

/// The store's write-behind lane for one thread — the injected commit
/// hook. A closure over the seam and the id, exactly like the injected
/// turn runner: the thread module never learns about the registry or the
/// store.
fn commit_hook_for(persistence: Store, id: String) -> fn(Transcript) -> Nil {
  fn(transcript) { persistence.commit(id, transcript) }
}

/// The utility apply seam for one thread — the injected `UtilityApply`.
/// A closure over this actor's subject and the id (exactly like the
/// commit hook), performing the `UpgradeAutoTitle` ask with the parsed
/// title AND tags. It runs inside the unlinked utility WORKER process —
/// never the thread actor — so the ask cannot deadlock: the registry
/// answers it without ever calling back into a thread. The outcome's
/// fresh metadata (title + the merged display set) feeds the thread's
/// `MetaUpdated` broadcast.
fn utility_apply_for(
  registry: Subject(Msg),
  id: String,
) -> fn(String, List(String)) -> Result(thread.UtilityMeta, Nil) {
  fn(title, tags) {
    case upgrade_auto_title(registry, id, title, tags) {
      UpgradeApplied(title, tags) -> Ok(thread.UtilityMeta(title, tags))
      UpgradeRefused -> Error(Nil)
    }
  }
}

/// Rebuild a stored thread's transcript through the one construction
/// path: `transcript.new(model, system_prompt)` + `append_*` over the rows
/// in seq order.
fn rebuild_transcript(state: State, id: String) -> Result(Transcript, String) {
  use stored <- result.try(state.store.get_thread(id))
  use rows <- result.try(state.store.load_messages(id))
  Ok(store.transcript_from_rows(
    stored.summary.model,
    stored.system_prompt,
    rows,
  ))
}

/// Lazily start a dormant (stored-but-not-live) thread, hydrated from the
/// store. Replies through the returned state transition; unknown-store
/// failures keep the thread dormant (the next Get retries).
fn lazy_start(state: State, summary: StoredSummary) -> Resolved {
  // The dormant row pins its provider: resolve the endpoint by the
  // persisted id, exactly like create did. A provider that went away
  // (disabled, or its envelope no longer decrypts) keeps the thread
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
        <> "); thread stays dormant",
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
            thread.ThreadSpec(
              id: summary.id,
              cfg: state.cfg,
              endpoint: endpoint,
              toolset: default_toolset(state),
              commit_hook: commit_hook_for(state.store, summary.id),
              transcript: transcript,
              hydrated: True,
              utility_apply: utility_apply_for(state.self, summary.id),
            )
          let argument =
            ChildArgument(
              spec: spec,
              name: process.new_name("nexus_thread_" <> summary.id),
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
                  meta: summary.meta,
                  persisted: True,
                )
              Started(
                State(
                  ..state,
                  threads: dict.insert(state.threads, summary.id, record),
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

/// Retry the rehydrating restart of a persisted thread whose last attempt
/// failed (its record carries `start_error`).
fn retry_rehydrate(state: State, record: Record) -> Resolved {
  case rebuild_transcript(state, record.id) {
    Error(error) -> {
      log_store_error("retry_rehydrate " <> record.id, error)
      Missing
    }
    Ok(transcript) -> {
      let spec =
        thread.ThreadSpec(
          ..record.spec,
          transcript: transcript,
          // Same rule as the Down replacement: a rehydrating restart
          // never attempts the utility-titles upgrade.
          hydrated: True,
        )
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
              threads: dict.insert(state.threads, record.id, restarted),
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

/// Apply `f` to the organizational metadata — of the live record or the
/// dormant summary, whichever holds the id (both carry the SAME
/// `thread.ThreadMeta`, issue #75, so ONE mutator serves both) — and
/// write the change through to the store. `False` when the id is
/// unknown.
fn apply_meta(
  state: State,
  id: String,
  reply: Subject(Bool),
  on_meta: fn(thread.ThreadMeta) -> thread.ThreadMeta,
  write_through: fn() -> Result(Nil, String),
) -> actor.Next(State, Msg) {
  let #(next, applied) = case dict.get(state.threads, id) {
    Ok(record) -> {
      write_through_or_log(id, write_through)
      #(
        State(
          ..state,
          threads: dict.insert(
            state.threads,
            id,
            Record(..record, meta: on_meta(record.meta)),
          ),
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
              dormant: dict.insert(
                state.dormant,
                id,
                store.StoredSummary(..summary, meta: on_meta(summary.meta)),
              ),
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
/// thread, auto-title with an existing title): a `None` result replies
/// `False` and mutates nothing. The mutators perform their own guarded
/// write-through.
fn apply_meta_guarded(
  state: State,
  id: String,
  reply: Subject(Bool),
  on_meta: fn(thread.ThreadMeta) -> Result(thread.ThreadMeta, Nil),
) -> actor.Next(State, Msg) {
  let #(next, applied) = case dict.get(state.threads, id) {
    Ok(record) ->
      case on_meta(record.meta) {
        Ok(meta) -> #(
          State(
            ..state,
            threads: dict.insert(
              state.threads,
              id,
              Record(..record, meta: meta),
            ),
          ),
          True,
        )
        Error(Nil) -> #(state, False)
      }
    Error(_) ->
      case dict.get(state.dormant, id) {
        Ok(summary) ->
          case on_meta(summary.meta) {
            Ok(meta) -> #(
              State(
                ..state,
                dormant: dict.insert(
                  state.dormant,
                  id,
                  store.StoredSummary(..summary, meta: meta),
                ),
              ),
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

/// Tags are normalized on write through the ONE shared rule
/// (`nexus/utility.normalize_tags`, utility-tags plan §3.1): trimmed,
/// lowercased, internal whitespace collapsed to kebab-case, empties
/// dropped, duplicates removed (first occurrence wins — insertion order
/// is display order), each tag truncated at 24 characters. Manual saves
/// and model tags share this rule, so the two can never drift apart.
fn normalize_tags(tags: List(String)) -> List(String) {
  utility.normalize_tags(tags)
}

// ---------------------------------------------------------------------------
// Tag corpus (utility-tags plan §3.3)
// ---------------------------------------------------------------------------

/// The frequency floor: a tag becomes reuse vocabulary once at least 2
/// threads carry it. A singleton tag is not yet vocabulary — it stays
/// out of Y, so one thread's fresh tag does not immediately promote
/// itself to a reuse candidate for the next.
const corpus_floor = 2

/// The corpus cap: top entries by thread count, ties broken
/// alphabetically — deterministic for a given registry state. With the
/// per-tag cap in `nexus/utility` this bounds Y's corpus share at
/// 30 × 24 characters, whatever older rows contain.
const corpus_size = 30

/// The reuse vocabulary across every thread the registry knows — active
/// records plus dormant summaries (both hold their threads' display
/// tags in memory). Every candidate is normalized with the SAME rule as
/// manual and model tags BEFORE counting — `utility.normalize_tags` also
/// dedupes within a thread, so the floor counts THREADS, not mentions —
/// and counting pools case-insensitively (after normalization a legacy
/// `Work Notes` and a canonical `work-notes` are one entry; the display
/// sets themselves are never rewritten). Tags used by ≥ `corpus_floor`
/// threads survive, ordered by count descending, alphabetical tie-break,
/// capped at `corpus_size`.
fn compute_tag_corpus(
  threads: Dict(String, Record),
  dormant: Dict(String, StoredSummary),
) -> List(String) {
  let per_thread =
    list.append(
      list.map(dict.values(threads), fn(record) {
        utility.normalize_tags(record.meta.tags)
      }),
      list.map(dict.values(dormant), fn(summary) {
        utility.normalize_tags(summary.meta.tags)
      }),
    )
  let counts =
    list.fold(per_thread, dict.new(), fn(counts, tags) {
      list.fold(tags, counts, fn(counts, tag) {
        let count = case dict.get(counts, tag) {
          Ok(n) -> n + 1
          Error(_) -> 1
        }
        dict.insert(counts, tag, count)
      })
    })
  counts
  |> dict.to_list
  |> list.filter(fn(entry) { entry.1 >= corpus_floor })
  |> list.sort(fn(a, b) {
    case int.compare(b.1, a.1) {
      order.Eq -> string.compare(a.0, b.0)
      ord -> ord
    }
  })
  |> list.map(fn(entry) { entry.0 })
  |> list.take(corpus_size)
}

/// The corpus closure the real utility runner asks (§3.3): built from the
/// registry's NAME — it exists before the actor starts, so no subject
/// capture is needed at build time — and resolved to a subject at ask
/// time, from inside the utility WORKER. Exactly the `utility_apply_for`
/// ask pattern: the registry never blocks on itself.
fn tag_corpus_for(name: process.Name(Msg)) -> fn() -> List(String) {
  fn() { tag_corpus(process.named_subject(name)) }
}

/// Sidebar title from a first user message: collapse whitespace runs to
/// single spaces, trim, truncate (with an ellipsis) at 60 characters. No
/// LLM call — organizational metadata that lives beside the transcript and
/// never enters a request body. Shared by the HTTP send boundary and the
/// UI component's send effect (both are places that already hold the
/// outgoing text; message content never crosses thread→registry).
///
/// The shaping rule lives in `nexus/utility.shape_title` — the SAME rule
/// caps a model-generated title, so the two can never drift apart.
pub fn title_from_first_message(text: String) -> String {
  utility.shape_title(text)
}

/// Sidebar order: pinned first, then most recently active first; ties break
/// newest-created first, then by ID — deterministic and stable.
fn compare_summaries(
  a: thread.ThreadSummary,
  b: thread.ThreadSummary,
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

fn summarise(
  record: Record,
  status: thread.ThreadStatus,
) -> thread.ThreadSummary {
  thread.ThreadSummary(
    id: record.id,
    provider_id: record.provider_id,
    model: record.model,
    title: record.meta.title,
    title_source: record.meta.title_source,
    pinned: record.meta.pinned,
    tags: record.meta.tags,
    archived: record.meta.archived,
    bot_id: record.meta.bot_id,
    message_count: status.message_count,
    streaming: status.streaming,
    created_at: record.meta.created_at,
    // Until the first commit, a thread's activity is its creation.
    last_active_at: case status.last_commit_at {
      0 -> record.meta.created_at
      committed -> committed
    },
    metrics: status.metrics,
  )
}

/// A dormant thread's summary: stored metadata, never streaming, and
/// metrics empty by design (MetricSample history is in-memory only).
fn stored_summary_as(summary: StoredSummary) -> thread.ThreadSummary {
  thread.ThreadSummary(
    id: summary.id,
    provider_id: summary.provider_id,
    model: summary.model,
    title: summary.meta.title,
    title_source: summary.meta.title_source,
    pinned: summary.meta.pinned,
    tags: summary.meta.tags,
    archived: summary.meta.archived,
    bot_id: summary.meta.bot_id,
    message_count: summary.message_count,
    streaming: False,
    created_at: summary.meta.created_at,
    last_active_at: summary.last_active_at,
    metrics: [],
  )
}

fn find_by_pid(threads: Dict(String, Record), pid: Pid) -> Option(Record) {
  let found =
    threads
    |> dict.values()
    |> list.filter(fn(record: Record) { record.pid == pid })
    |> list.first
  case found {
    Ok(record) -> Some(record)
    Error(_) -> None
  }
}

/// Start a thread child, retrying once after a short pause. A killed
/// actor's registered name frees asynchronously, so the first attempt can
/// hit `already_started` even though the process is gone (M2 §9 restart
/// races). One retry keeps the loop bounded and the failure visible.
fn restart(
  factory: Factory,
  argument: ChildArgument,
) -> Result(actor.Started(Subject(thread.Msg)), actor.StartError) {
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

/// Create a thread from the request record. The provider/model validation
/// (a network call) belongs in `nexus/thread_create`, OUTSIDE this loop —
/// this ask only resolves the endpoint and starts the child. Replies with
/// the fresh summary.
pub fn create(
  registry: Subject(Msg),
  requested: NewThread,
) -> Result(thread.ThreadSummary, CreateError) {
  actor.call(registry, 5000, fn(reply) { Create(requested:, reply:) })
}

/// Test seam: create a thread with an injected toolset bundle — its own
/// specs and turn + utility runners, carried verbatim into the thread spec
/// (see `CreateWithToolset`).
pub fn create_with_toolset(
  registry: Subject(Msg),
  requested: NewThread,
  toolset: thread.Toolset,
) -> Result(thread.ThreadSummary, CreateError) {
  actor.call(registry, 5000, fn(reply) {
    CreateWithToolset(requested:, toolset:, reply:)
  })
}

pub fn get(
  registry: Subject(Msg),
  id: String,
) -> Result(Subject(thread.Msg), Nil) {
  actor.call(registry, 5000, fn(reply) { Get(id:, reply:) })
}

pub fn list_threads(registry: Subject(Msg)) -> List(thread.ThreadSummary) {
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

/// The model-metadata upgrade (the utility worker's apply step): title
/// AND tags from the same completion. Applies only while BOTH provenance
/// columns are 'auto' — a manual rename or a manual tag edit wins forever
/// — and merges the tags into the display set. The reply carries the
/// fresh metadata when it applied.
pub fn upgrade_auto_title(
  registry: Subject(Msg),
  id: String,
  title: String,
  tags: List(String),
) -> UpgradeOutcome {
  actor.call(registry, 5000, fn(reply) {
    UpgradeAutoTitle(id:, title:, tags:, reply:)
  })
}

/// The reuse-vocabulary ask (§3.3): the top tags across every thread
/// the registry knows. In production this is called from inside the
/// utility worker (the real runner's corpus closure); tests call it
/// directly against a booted registry.
pub fn tag_corpus(registry: Subject(Msg)) -> List(String) {
  actor.call(registry, 5000, TagCorpus)
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
pub fn delete_thread(registry: Subject(Msg), id: String) -> Bool {
  actor.call(registry, 5000, fn(reply) { Delete(id:, reply:) })
}

/// A bot was deleted (bots plan P1): scrub its provenance pointer from both
/// summary halves. The bot delete's caller orchestrates (the registries
/// stay mutually ignorant) — the store needs nothing, `thread.bot_id` is
/// ON DELETE SET NULL and bot_id rides no query but insert_thread.
pub fn bot_deleted(registry: Subject(Msg), id: String) -> Nil {
  actor.call(registry, 5000, fn(reply) { BotDeleted(id:, reply:) })
}
