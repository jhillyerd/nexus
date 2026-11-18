//// A fully functional **in-memory** implementation of the `nexus/store`
//// seam for offline tests: no database, no network, but the real
//// semantics — idempotent write-behind commits (an unchanged or older
//// transcript is a no-op), guarded auto-title / auto metadata upgrade,
//// archive-clears-pin, cascade delete, recency bumps. The persistence
//// tests use it as the "external Postgres" that survives a registry
//// teardown, which makes the whole hydrate/restart cycle testable
//// inside plain `gleam test`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import nexus/node
import nexus/store.{
  type Store, type StoredBot, type StoredProvider, type StoredSummary,
}
import nexus/thread
import nexus/timing
import nexus/transcript.{type Transcript}

/// Recorded seam calls, oldest first — for write-behind ordering and
/// metadata write-through assertions.
pub type Event {
  EvInsertThread(id: String)
  EvCommit(id: String, messages: Int)
  EvSetTitle(id: String, title: String)
  EvAutoTitle(id: String, title: String)
  EvAutoMetaUpgrade(id: String, title: String, tags: List(String))
  EvSetTags(id: String, tags: List(String))
  EvSetPinned(id: String, pinned: Bool)
  EvArchive(id: String)
  EvUnarchive(id: String)
  EvDeleteThread(id: String)
  /// One boot sweep: the ids it deleted (sorted).
  EvPruneNeverUsed(ids: List(String))
  EvInsertProvider(id: String)
  EvUpdateProvider(id: String)
  EvDeleteProvider(id: String)
  EvInsertBot(id: String)
  EvUpdateBot(id: String)
  EvDeleteBot(id: String)
  EvInsertNode(id: String)
  EvTouchNode(id: String)
  EvDeleteNode(id: String)
  EvInsertNodeGrant(id: String)
  EvTouchNodeGrant(id: String)
  EvDeleteNodeGrant(id: String)
}

pub type MockMsg {
  // ---- seam operations (synchronous, Result replies) ----
  ListSummaries(
    reply: Subject(Result(#(List(StoredSummary), List(String)), String)),
  )
  GetThread(id: String, reply: Subject(Result(store.StoredThread, String)))
  LoadMessages(
    id: String,
    reply: Subject(Result(List(store.MessageRow), String)),
  )
  InsertThread(
    summary: StoredSummary,
    system_prompt: String,
    reply: Subject(Result(Nil, String)),
  )
  /// The channel re-derivation lookup (bot-channels plan, #123) — the
  /// mock mirrors find_channel.sql: scan the rows for the one whose
  /// (parent, bot) matches. Failure injection rides seam overrides, not
  /// this handler.
  FindChannel(
    parent_thread_id: String,
    bot_id: String,
    reply: Subject(Result(option.Option(String), String)),
  )
  /// The write-behind lane: fire-and-forget, ordered by arrival. Also the
  /// replay path — applying the same (or an older) transcript again is a
  /// no-op apart from the recency bump.
  Commit(id: String, transcript: Transcript)
  SetTitle(id: String, title: String, reply: Subject(Result(Nil, String)))
  AutoTitle(id: String, title: String, reply: Subject(Result(Bool, String)))
  AutoMetaUpgrade(
    id: String,
    title: String,
    tags: List(String),
    reply: Subject(Result(Bool, String)),
  )
  SetTags(id: String, tags: List(String), reply: Subject(Result(Nil, String)))
  SetPinned(id: String, pinned: Bool, reply: Subject(Result(Nil, String)))
  Archive(id: String, reply: Subject(Result(Nil, String)))
  Unarchive(id: String, reply: Subject(Result(Nil, String)))
  DeleteThread(id: String, reply: Subject(Result(Nil, String)))
  /// Mirrors `prune_never_used.sql` (see the seam's docs in
  /// `nexus/store`): bulk boot sweep, replying with the deleted ids.
  PruneNeverUsed(reply: Subject(Result(List(String), String)))
  // ---- provider rows (docs/plans/multi-provider.md §5.3) ----
  ListProviders(reply: Subject(Result(List(StoredProvider), String)))
  GetProvider(id: String, reply: Subject(Result(store.StoredProvider, String)))
  InsertProvider(provider: StoredProvider, reply: Subject(Result(Nil, String)))
  UpdateProvider(
    provider: StoredProvider,
    replace_key: Bool,
    reply: Subject(Result(Nil, String)),
  )
  CountThreadsForProvider(id: String, reply: Subject(Result(Int, String)))
  DeleteProvider(id: String, reply: Subject(Result(Nil, String)))
  // ---- bot rows (docs/plans/completed/bots.md, Phase 1) ----
  ListBots(reply: Subject(Result(List(StoredBot), String)))
  GetBot(id: String, reply: Subject(Result(StoredBot, String)))
  InsertBot(bot: StoredBot, reply: Subject(Result(Nil, String)))
  UpdateBot(bot: StoredBot, reply: Subject(Result(Nil, String)))
  DeleteBot(id: String, reply: Subject(Result(Nil, String)))
  CountBotsForProvider(id: String, reply: Subject(Result(Int, String)))
  // ---- node rows (docs/plans/environments.md, Phase 2b) ----
  ListNodes(reply: Subject(Result(List(store.StoredNode), String)))
  GetNodeByName(name: String, reply: Subject(Result(store.StoredNode, String)))
  InsertNode(node: store.StoredNode, reply: Subject(Result(Nil, String)))
  TouchNode(id: String, reply: Subject(Result(Nil, String)))
  DeleteNode(id: String, reply: Subject(Result(Nil, String)))
  // ---- node pairing grants (docs/plans/tui-pairing.md, Phase A) ----
  ListNodeGrants(reply: Subject(Result(List(store.StoredGrant), String)))
  InsertNodeGrant(grant: store.StoredGrant, reply: Subject(Result(Nil, String)))
  TouchNodeGrant(id: String, reply: Subject(Result(Nil, String)))
  DeleteNodeGrant(id: String, reply: Subject(Result(Nil, String)))
  DeleteExpiredNodeGrants(reply: Subject(Result(Nil, String)))
  // ---- test-only introspection ----
  Events(reply: Subject(List(Event)))
  Rows(reply: Subject(List(#(String, List(store.MessageRow)))))
  /// Every stored provider, id-sorted — for direct row assertions.
  Providers(reply: Subject(List(StoredProvider)))
  /// Every stored bot, id-sorted — for direct row assertions.
  Bots(reply: Subject(List(StoredBot)))
  /// Every stored node, id-sorted — for direct row assertions.
  Nodes(reply: Subject(List(store.StoredNode)))
  /// Every stored grant, id-sorted — for direct row assertions.
  Grants(reply: Subject(List(store.StoredGrant)))
  /// Test-only: truncate a thread's stored rows back to `keep_rows` and
  /// its persisted message count to `messages` to model a crash between
  /// commits — the next Commit re-emits the delta, which is exactly the
  /// crash-recovery replay the real store makes idempotent.
  Rewind(id: String, keep_rows: Int, messages: Int, reply: Subject(Nil))
  /// Test-only: overwrite a stored row's `last_active_at` (epoch
  /// seconds). `Commit` stamps recency with the wall clock, so a test
  /// that lays down message rows through the seam cannot also present
  /// the thread as previously active — this restores the age afterwards.
  SetLastActive(id: String, at: Int, reply: Subject(Nil))
}

type Stored {
  Stored(
    summary: StoredSummary,
    system_prompt: String,
    /// Rows in seq order (seq = index).
    rows: List(store.MessageRow),
    /// Persisted chronological transcript length INCLUDING the system
    /// prompt — the write-behind watermark. Message count, not row count:
    /// an assistant message with N tool calls is one message but N rows
    /// (mirrors threads.message_count in the real schema).
    messages: Int,
  )
}

type State {
  State(
    threads: Dict(String, Stored),
    providers: Dict(String, store.StoredProvider),
    bots: Dict(String, StoredBot),
    nodes: Dict(String, store.StoredNode),
    grants: Dict(String, store.StoredGrant),
    events: List(Event),
  )
}

/// The provider id that test fixtures pin their threads to — the
/// P1 stand-in for a real provider source (`thread.provider_id` is NOT
/// NULL, so every stored thread needs one).
pub const fixture_provider_id = "p-test"

/// A keyless fixture provider row (ciphertext in, ciphertext out: the
/// mock never sees plaintext either).
pub fn fixture_provider() -> StoredProvider {
  let now = timing.wall_now_s()
  store.StoredProvider(
    id: fixture_provider_id,
    name: "fixture",
    base_url: "http://fixture.test/v1",
    api_key_encrypted: None,
    key_version: 1,
    dialect: "openai",
    enabled: True,
    created_at: now,
    updated_at: now,
  )
}

/// Idempotently create the fixture provider through the seam — call
/// before seeding threads or booting a registry over the mock, since
/// `insert_thread` enforces the provider FK like the real store.
pub fn ensure_fixture_provider(seam: Store) -> Nil {
  case seam.get_provider(fixture_provider_id) {
    Ok(_) -> Nil
    Error(_) -> {
      let assert Ok(Nil) = seam.insert_provider(fixture_provider())
      Nil
    }
  }
}

/// Start the mock store actor; returns its subject.
pub fn start() -> Subject(MockMsg) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      actor.initialised(
        State(
          threads: dict.new(),
          providers: dict.new(),
          bots: dict.new(),
          nodes: dict.new(),
          grants: dict.new(),
          events: [],
        ),
      )
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

/// The seam over a started mock actor.
pub fn seam(mock: Subject(MockMsg)) -> Store {
  store.Store(
    list_summaries: fn() { call(mock, 5000, ListSummaries) },
    get_thread: fn(id) { call(mock, 5000, fn(r) { GetThread(id, r) }) },
    load_messages: fn(id) { call(mock, 5000, fn(r) { LoadMessages(id, r) }) },
    insert_thread: fn(summary, system_prompt) {
      call(mock, 5000, fn(r) { InsertThread(summary, system_prompt, r) })
    },
    find_channel: fn(parent_thread_id, bot_id) {
      call(mock, 5000, fn(r) { FindChannel(parent_thread_id, bot_id, r) })
    },
    commit: fn(id, transcript) { process.send(mock, Commit(id, transcript)) },
    set_title: fn(id, title) {
      call(mock, 5000, fn(r) { SetTitle(id, title, r) })
    },
    auto_title: fn(id, title) {
      call(mock, 5000, fn(r) { AutoTitle(id, title, r) })
    },
    auto_meta_upgrade: fn(id, title, tags) {
      call(mock, 5000, fn(r) { AutoMetaUpgrade(id, title, tags, r) })
    },
    set_tags: fn(id, tags) { call(mock, 5000, fn(r) { SetTags(id, tags, r) }) },
    set_pinned: fn(id, pinned) {
      call(mock, 5000, fn(r) { SetPinned(id, pinned, r) })
    },
    archive: fn(id) { call(mock, 5000, fn(r) { Archive(id, r) }) },
    unarchive: fn(id) { call(mock, 5000, fn(r) { Unarchive(id, r) }) },
    delete_thread: fn(id) { call(mock, 5000, fn(r) { DeleteThread(id, r) }) },
    prune_never_used: fn() { call(mock, 5000, PruneNeverUsed) },
    list_providers: fn() { call(mock, 5000, ListProviders) },
    get_provider: fn(id) { call(mock, 5000, fn(r) { GetProvider(id, r) }) },
    insert_provider: fn(provider) {
      call(mock, 5000, fn(r) { InsertProvider(provider, r) })
    },
    update_provider: fn(provider, replace_key) {
      call(mock, 5000, fn(r) { UpdateProvider(provider, replace_key, r) })
    },
    count_threads_for_provider: fn(id) {
      call(mock, 5000, fn(r) { CountThreadsForProvider(id, r) })
    },
    delete_provider: fn(id) {
      call(mock, 5000, fn(r) { DeleteProvider(id, r) })
    },
    list_bots: fn() { call(mock, 5000, ListBots) },
    get_bot: fn(id) { call(mock, 5000, fn(r) { GetBot(id, r) }) },
    insert_bot: fn(row) { call(mock, 5000, fn(r) { InsertBot(row, r) }) },
    update_bot: fn(row) { call(mock, 5000, fn(r) { UpdateBot(row, r) }) },
    delete_bot: fn(id) { call(mock, 5000, fn(r) { DeleteBot(id, r) }) },
    count_bots_for_provider: fn(id) {
      call(mock, 5000, fn(r) { CountBotsForProvider(id, r) })
    },
    list_nodes: fn() { call(mock, 5000, ListNodes) },
    get_node_by_name: fn(name) {
      call(mock, 5000, fn(r) { GetNodeByName(name, r) })
    },
    insert_node: fn(row) { call(mock, 5000, fn(r) { InsertNode(row, r) }) },
    touch_node: fn(id) { call(mock, 5000, fn(r) { TouchNode(id, r) }) },
    delete_node: fn(id) { call(mock, 5000, fn(r) { DeleteNode(id, r) }) },
    list_node_grants: fn() { call(mock, 5000, ListNodeGrants) },
    insert_node_grant: fn(row) {
      call(mock, 5000, fn(r) { InsertNodeGrant(row, r) })
    },
    touch_node_grant: fn(id) {
      call(mock, 5000, fn(r) { TouchNodeGrant(id, r) })
    },
    delete_node_grant: fn(id) {
      call(mock, 5000, fn(r) { DeleteNodeGrant(id, r) })
    },
    delete_expired_node_grants: fn() {
      call(mock, 5000, DeleteExpiredNodeGrants)
    },
  )
}

// ---------------------------------------------------------------------------
// Test-side helpers (also through the actor, so ordering stays honest)
// ---------------------------------------------------------------------------

/// The recorded call log, oldest first.
pub fn events(mock: Subject(MockMsg)) -> List(Event) {
  call(mock, 5000, Events)
}

/// Every thread's rows, id-sorted — for direct row assertions.
pub fn rows(mock: Subject(MockMsg)) -> List(#(String, List(store.MessageRow))) {
  call(mock, 5000, Rows)
}

/// Every stored provider, id-sorted — for direct row assertions
/// (envelopes included: the mock holds ciphertext, like the real store).
pub fn providers(mock: Subject(MockMsg)) -> List(store.StoredProvider) {
  call(mock, 5000, Providers)
}

/// Every stored bot, id-sorted — for direct row assertions.
pub fn bots(mock: Subject(MockMsg)) -> List(store.StoredBot) {
  call(mock, 5000, Bots)
}

/// Every stored node, id-sorted — for direct row assertions.
pub fn nodes(mock: Subject(MockMsg)) -> List(store.StoredNode) {
  call(mock, 5000, Nodes)
}

/// Every stored grant, id-sorted — for direct row assertions.
pub fn grants(mock: Subject(MockMsg)) -> List(store.StoredGrant) {
  call(mock, 5000, Grants)
}

/// Truncate a thread's stored rows (models a crash between commits so
/// the next Commit replays).
pub fn rewind(
  mock: Subject(MockMsg),
  id: String,
  keep_rows: Int,
  messages: Int,
) -> Nil {
  call(mock, 5000, fn(r) { Rewind(id, keep_rows, messages, r) })
}

/// Overwrite a stored row's `last_active_at` (epoch seconds) — see
/// `SetLastActive`.
pub fn set_last_active(mock: Subject(MockMsg), id: String, at: Int) -> Nil {
  call(mock, 5000, fn(r) { SetLastActive(id, at, r) })
}

/// Wait until the mock has observed at least `n` commits — commits are
/// fire-and-forget, so tests synchronize on their effect. Gives up (and
/// fails the awaiting assertion) after ~5s.
pub fn await_commits(mock: Subject(MockMsg), n: Int) -> Nil {
  await_commits_loop(mock, n, 500)
}

fn await_commits_loop(mock: Subject(MockMsg), n: Int, patience: Int) -> Nil {
  let commits =
    events(mock)
    |> list.filter(fn(event) {
      case event {
        EvCommit(_, _) -> True
        _ -> False
      }
    })
  case list.length(commits) >= n, patience {
    True, _ -> Nil
    False, 0 -> Nil
    False, _ -> {
      process.sleep(10)
      await_commits_loop(mock, n, patience - 1)
    }
  }
}

fn call(
  mock: Subject(MockMsg),
  timeout: Int,
  make: fn(Subject(a)) -> MockMsg,
) -> a {
  actor.call(mock, timeout, make)
}

// ---------------------------------------------------------------------------
// The actor
// ---------------------------------------------------------------------------

fn handle(state: State, msg: MockMsg) -> actor.Next(State, MockMsg) {
  case msg {
    ListSummaries(reply) -> {
      let summaries =
        state.threads
        |> dict.values
        |> list.map(fn(stored) { stored.summary })
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(#(summaries, [])))
      actor.continue(state)
    }

    GetThread(id, reply) ->
      case dict.get(state.threads, id) {
        Ok(stored) -> {
          process.send(
            reply,
            Ok(store.StoredThread(
              summary: stored.summary,
              system_prompt: stored.system_prompt,
            )),
          )
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored thread " <> id))
          actor.continue(state)
        }
      }

    LoadMessages(id, reply) ->
      case dict.get(state.threads, id) {
        Ok(stored) -> {
          process.send(reply, Ok(stored.rows))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored thread " <> id))
          actor.continue(state)
        }
      }

    InsertThread(summary, system_prompt, reply) ->
      // thread_provider_id_fkey: the pinned provider must exist, like
      // the real store's FK refuses unknown ids.
      case dict.get(state.providers, summary.provider_id) {
        Error(_) -> {
          process.send(reply, Error("unknown provider " <> summary.provider_id))
          actor.continue(state)
        }
        Ok(_) -> {
          // thread_bot_id_fkey: a non-NULL provenance pointer must
          // reference a stored bot (the insert-time half; the delete-time
          // half is SET NULL, so no later guard).
          let bot_ok = case summary.meta.bot_id {
            None -> True
            Some(bot_id) -> dict.has_key(state.bots, bot_id)
          }
          // thread_parent_thread_id_fkey: a non-NULL parent link must
          // reference a stored thread (bot-channels plan, #123). CASCADE
          // is the delete-time half, mirrored by DeleteThread below.
          let parent_ok = case summary.meta.parent_thread_id {
            None -> True
            Some(parent) -> dict.has_key(state.threads, parent)
          }
          // thread_channel unique index: at most one channel per
          // (parent, bot) (bot-channels plan, #123) — the mock mirrors
          // the real store's rejection so tests fail the same way
          // production would.
          let channel_free = case
            summary.meta.parent_thread_id,
            summary.meta.bot_id
          {
            Some(parent), Some(bot_id) ->
              state.threads
              |> dict.values
              |> list.any(fn(stored) {
                stored.summary.meta.parent_thread_id == option.Some(parent)
                && stored.summary.meta.bot_id == option.Some(bot_id)
              })
              |> fn(taken) { !taken }
            _, _ -> True
          }
          case bot_ok, parent_ok, channel_free {
            False, _, _ -> {
              let assert Some(bot_id) = summary.meta.bot_id
              process.send(reply, Error("unknown bot " <> bot_id))
              actor.continue(state)
            }
            _, False, _ -> {
              let assert Some(parent) = summary.meta.parent_thread_id
              process.send(reply, Error("unknown parent thread " <> parent))
              actor.continue(state)
            }
            _, _, False -> {
              process.send(
                reply,
                Error("duplicate channel for parent/bot (thread_channel)"),
              )
              actor.continue(state)
            }
            True, True, True -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(
                  ..state,
                  threads: dict.insert(
                    state.threads,
                    summary.id,
                    // insert_thread.sql: tags_manual '{}' literally and
                    // tags_source DEFAULT 'auto' — a new row's auto path is
                    // open, regardless of what the passed summary carried
                    // (a fresh insert never inherits provenance).
                    Stored(
                      store.StoredSummary(
                        ..summary,
                        meta: thread.ThreadMeta(
                          ..summary.meta,
                          tags_manual: [],
                          tags_source: thread.AutoTags,
                        ),
                      ),
                      system_prompt,
                      // insert_thread's roster CTE: the creation-time
                      // roster row is stored WITH the thread (seq 0,
                      // system-authored) — the watermark (messages)
                      // already counts it.
                      case summary.roster {
                        option.Some(#(text, stamp)) -> [
                          store.UserRow(
                            content: text,
                            author: option.Some("system"),
                            hop_depth: 0,
                            at: option.Some(stamp),
                          ),
                        ]
                        option.None -> []
                      },
                      summary.message_count,
                    ),
                  ),
                  events: [EvInsertThread(summary.id), ..state.events],
                ),
              )
            }
          }
        }
      }

    FindChannel(parent_thread_id, bot_id, reply) -> {
      let found =
        state.threads
        |> dict.values
        |> list.find(fn(stored) {
          stored.summary.meta.parent_thread_id == option.Some(parent_thread_id)
          && stored.summary.meta.bot_id == option.Some(bot_id)
        })
      process.send(
        reply,
        Ok(case found {
          Ok(stored) -> option.Some(stored.summary.id)
          Error(_) -> option.None
        }),
      )
      actor.continue(state)
    }

    Commit(id, transcript) -> {
      let events = [EvCommit(id, transcript.length(transcript)), ..state.events]
      let threads = case dict.get(state.threads, id) {
        Error(_) -> state.threads
        Ok(stored) -> {
          // The delta past what is stored, in seq order; an unchanged or
          // older transcript yields nothing (matching the real store,
          // which does not even bump recency without a delta).
          let already = stored.messages
          case store.has_delta(transcript, already) {
            False -> state.threads
            True -> {
              let delta = store.transcript_rows(transcript, already)
              let total = transcript.length(transcript)
              dict.insert(
                state.threads,
                id,
                Stored(
                  ..stored,
                  rows: list.append(stored.rows, delta),
                  messages: total,
                  summary: store.StoredSummary(
                    ..stored.summary,
                    // Absolute values, like bump_activity: idempotent.
                    message_count: total,
                    last_active_at: timing.wall_now_s(),
                  ),
                ),
              )
            }
          }
        }
      }
      actor.continue(State(..state, threads: threads, events: events))
    }

    SetTitle(id, title, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(
              ..summary,
              meta: thread.ThreadMeta(
                ..summary.meta,
                title: title,
                title_source: thread.ManualTitle,
              ),
            )
          }),
          events: [EvSetTitle(id, title), ..state.events],
        ),
      )
    }

    AutoTitle(id, title, reply) ->
      case dict.get(state.threads, id) {
        Error(_) -> {
          process.send(reply, Error("no stored thread " <> id))
          actor.continue(state)
        }
        Ok(stored) ->
          case stored.summary.meta.title_source, stored.summary.meta.title {
            thread.AutoTitle, "" -> {
              process.send(reply, Ok(True))
              actor.continue(
                State(
                  ..update(state, id, fn(summary) {
                    store.StoredSummary(
                      ..summary,
                      meta: thread.ThreadMeta(..summary.meta, title: title),
                    )
                  }),
                  events: [EvAutoTitle(id, title), ..state.events],
                ),
              )
            }
            _, _ -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
      }

    AutoMetaUpgrade(id, title, tags, reply) ->
      // Mirrors `auto_meta_upgrade.sql` (utility-tags plan §3.6): the
      // guard is provenance ONLY, on BOTH columns — an auto title may be
      // replaced and the display tags written while `title_source` AND
      // `tags_source` are 'auto'; a manual rename OR a manual tag save
      // refuses the whole write, atomically.
      case dict.get(state.threads, id) {
        Error(_) -> {
          process.send(reply, Error("no stored thread " <> id))
          actor.continue(state)
        }
        Ok(stored) ->
          case
            stored.summary.meta.title_source,
            stored.summary.meta.tags_source
          {
            thread.AutoTitle, thread.AutoTags -> {
              process.send(reply, Ok(True))
              actor.continue(
                State(
                  ..update(state, id, fn(summary) {
                    store.StoredSummary(
                      ..summary,
                      meta: thread.ThreadMeta(
                        ..summary.meta,
                        title: title,
                        tags: tags,
                      ),
                    )
                  }),
                  events: [EvAutoMetaUpgrade(id, title, tags), ..state.events],
                ),
              )
            }
            _, _ -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
      }

    SetTags(id, tags, reply) -> {
      // Mirrors `set_tags.sql` (utility-tags plan §3.5): one atomic
      // triple-write — the display set, the manual set, and
      // `tags_source = 'manual'` (the freeze `auto_meta_upgrade` guards
      // on). All three fields or nothing.
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update_stored(state, id, fn(stored) {
            Stored(
              ..stored,
              summary: store.StoredSummary(
                ..stored.summary,
                meta: thread.ThreadMeta(
                  ..stored.summary.meta,
                  tags: tags,
                  tags_manual: tags,
                  tags_source: thread.ManualTags,
                ),
              ),
            )
          }),
          events: [EvSetTags(id, tags), ..state.events],
        ),
      )
    }

    SetPinned(id, pinned, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(
              ..summary,
              meta: thread.ThreadMeta(..summary.meta, pinned: pinned),
            )
          }),
          events: [EvSetPinned(id, pinned), ..state.events],
        ),
      )
    }

    Archive(id, reply) -> {
      // Mirrors archive.sql's recursive CTE (bot-channels plan, #123):
      // the statement is the authority and cascades DOWN the
      // parent_thread_id subtree, clearing pins everywhere it lands —
      // so the mock cascades too, not just the named row.
      let subtree = channel_subtree(state.threads, id)
      let threads =
        list.fold(subtree, state.threads, fn(threads, sid) {
          case dict.get(threads, sid) {
            Ok(stored) ->
              dict.insert(
                threads,
                sid,
                Stored(
                  ..stored,
                  summary: store.StoredSummary(
                    ..stored.summary,
                    meta: thread.ThreadMeta(
                      ..stored.summary.meta,
                      archived: True,
                      pinned: False,
                    ),
                  ),
                ),
              )
            Error(_) -> threads
          }
        })
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, threads: threads, events: [EvArchive(id), ..state.events]),
      )
    }

    Unarchive(id, reply) -> {
      // The symmetric twin (bot-channels plan, #123): restoring a
      // parent restores its channel subtree.
      let subtree = channel_subtree(state.threads, id)
      let threads =
        list.fold(subtree, state.threads, fn(threads, sid) {
          case dict.get(threads, sid) {
            Ok(stored) ->
              dict.insert(
                threads,
                sid,
                Stored(
                  ..stored,
                  summary: store.StoredSummary(
                    ..stored.summary,
                    meta: thread.ThreadMeta(
                      ..stored.summary.meta,
                      archived: False,
                    ),
                  ),
                ),
              )
            Error(_) -> threads
          }
        })
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, threads: threads, events: [
          EvUnarchive(id),
          ..state.events
        ]),
      )
    }

    DeleteThread(id, reply) -> {
      // Mirrors delete_thread.sql + the FK's ON DELETE CASCADE
      // (bot-channels plan, #123): deleting a parent removes its whole
      // channel subtree (hop chains make channels of channels).
      let subtree = channel_subtree(state.threads, id)
      let threads =
        list.fold(subtree, state.threads, fn(threads, sid) {
          dict.delete(threads, sid)
        })
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, threads: threads, events: [
          EvDeleteThread(id),
          ..state.events
        ]),
      )
    }

    PruneNeverUsed(reply) -> {
      // Same contract as prune_never_used.sql: never-used (system
      // prompt only, auto-titled, unpinned) AND older than the grace
      // window that protects a concurrent server's fresh empty. A
      // parent with a channel child is NEVER swept — the FK's CASCADE
      // would take the child's committed history with it (mirrors the
      // SQL's not-exists child check).
      let parents_with_children =
        state.threads
        |> dict.values
        |> list.filter_map(fn(stored) {
          case stored.summary.meta.parent_thread_id {
            option.Some(parent) -> Ok(parent)
            option.None -> Error(Nil)
          }
        })
      let cutoff = timing.wall_now_s() - prune_grace_s
      let ids =
        state.threads
        |> dict.values
        |> list.filter(fn(stored) {
          never_used(stored.summary, cutoff)
          && !list.contains(parents_with_children, stored.summary.id)
        })
        |> list.map(fn(stored) { stored.summary.id })
        |> list.sort(string.compare)
      let threads =
        list.fold(ids, state.threads, fn(threads, id) {
          dict.delete(threads, id)
        })
      process.send(reply, Ok(ids))
      // An empty sweep is a no-op — not an observable store event (the
      // metadata tests assert the exact event stream).
      let events = case ids {
        [] -> state.events
        _ -> [EvPruneNeverUsed(ids), ..state.events]
      }
      actor.continue(State(..state, threads: threads, events: events))
    }

    Events(reply) -> {
      process.send(reply, list.reverse(state.events))
      actor.continue(state)
    }

    Rows(reply) -> {
      let rows =
        state.threads
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, pair.1.rows) })
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      process.send(reply, rows)
      actor.continue(state)
    }

    Providers(reply) -> {
      let providers =
        state.providers
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, providers)
      actor.continue(state)
    }

    ListProviders(reply) -> {
      let providers =
        state.providers
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(providers))
      actor.continue(state)
    }

    GetProvider(id, reply) ->
      case dict.get(state.providers, id) {
        Ok(provider) -> {
          process.send(reply, Ok(provider))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored provider " <> id))
          actor.continue(state)
        }
      }

    InsertProvider(provider, reply) ->
      // provider_pkey + provider_name_key, like the schema's constraints.
      case
        dict.has_key(state.providers, provider.id),
        list.any(dict.values(state.providers), fn(existing) {
          existing.name == provider.name
        })
      {
        True, _ -> {
          process.send(reply, Error("provider " <> provider.id <> " exists"))
          actor.continue(state)
        }
        False, True -> {
          process.send(
            reply,
            Error("provider name " <> provider.name <> " exists"),
          )
          actor.continue(state)
        }
        False, False -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              providers: dict.insert(state.providers, provider.id, provider),
              events: [EvInsertProvider(provider.id), ..state.events],
            ),
          )
        }
      }

    UpdateProvider(provider, replace_key, reply) ->
      case dict.get(state.providers, provider.id) {
        // Like the SQL `update ... where id = $1`: a missing row is a
        // silent no-op, not an error.
        Error(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Ok(stored) -> {
          // provider_name_key: renaming onto another provider's name is
          // refused, like the schema's UNIQUE constraint — no state
          // change, no event.
          case
            list.any(dict.values(state.providers), fn(existing) {
              existing.id != provider.id && existing.name == provider.name
            })
          {
            True -> {
              process.send(
                reply,
                Error("provider name " <> provider.name <> " exists"),
              )
              actor.continue(state)
            }
            False -> {
              // update_provider.sql's SET list is name / base_url /
              // the gated key fields / enabled, with `updated_at =
              // now()` server-side: created_at and dialect stay from
              // the stored row. The mock mirrors that exactly, so
              // identical updates produce identical metadata through
              // either implementation.
              let updated =
                store.StoredProvider(
                  ..provider,
                  created_at: stored.created_at,
                  dialect: stored.dialect,
                  updated_at: timing.wall_now_s(),
                  api_key_encrypted: case replace_key {
                    True -> provider.api_key_encrypted
                    False -> stored.api_key_encrypted
                  },
                  key_version: case replace_key {
                    True -> provider.key_version
                    False -> stored.key_version
                  },
                )
              process.send(reply, Ok(Nil))
              actor.continue(
                State(
                  ..state,
                  providers: dict.insert(state.providers, provider.id, updated),
                  events: [EvUpdateProvider(provider.id), ..state.events],
                ),
              )
            }
          }
        }
      }

    CountThreadsForProvider(id, reply) -> {
      let count =
        state.threads
        |> dict.values
        |> list.filter(fn(stored) { stored.summary.provider_id == id })
        |> list.length
      process.send(reply, Ok(count))
      actor.continue(state)
    }

    DeleteProvider(id, reply) -> {
      // ON DELETE RESTRICT: the FK refuses while any thread OR bot pins
      // the provider (the counts are the registry's friendly 409
      // pre-check's halves).
      let referenced =
        state.threads
        |> dict.values
        |> list.any(fn(stored) { stored.summary.provider_id == id })
        || {
          state.bots
          |> dict.values
          |> list.any(fn(bot) { bot.provider_id == id })
        }
      case dict.has_key(state.providers, id), referenced {
        False, _ -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True, True -> {
          process.send(
            reply,
            Error("provider " <> id <> " still pinned by threads"),
          )
          actor.continue(state)
        }
        True, False -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(..state, providers: dict.delete(state.providers, id), events: [
              EvDeleteProvider(id),
              ..state.events
            ]),
          )
        }
      }
    }

    // ---- bot rows (docs/plans/completed/bots.md, Phase 1) ----
    ListBots(reply) -> {
      let bots =
        state.bots
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(bots))
      actor.continue(state)
    }

    GetBot(id, reply) ->
      case dict.get(state.bots, id) {
        Ok(bot) -> {
          process.send(reply, Ok(bot))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored bot " <> id))
          actor.continue(state)
        }
      }

    InsertBot(bot, reply) ->
      // bot_pkey + bot_name, like the schema's constraints; and the
      // provider FK (RESTRICT — a bot cannot outlive its provider).
      case
        dict.has_key(state.bots, bot.id),
        list.any(dict.values(state.bots), fn(existing) {
          existing.name == bot.name
        }),
        dict.has_key(state.providers, bot.provider_id)
      {
        True, _, _ -> {
          process.send(reply, Error("bot " <> bot.id <> " exists"))
          actor.continue(state)
        }
        False, True, _ -> {
          process.send(reply, Error("bot name " <> bot.name <> " exists"))
          actor.continue(state)
        }
        False, False, False -> {
          process.send(reply, Error("unknown provider " <> bot.provider_id))
          actor.continue(state)
        }
        False, False, True -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(..state, bots: dict.insert(state.bots, bot.id, bot), events: [
              EvInsertBot(bot.id),
              ..state.events
            ]),
          )
        }
      }

    UpdateBot(bot, reply) ->
      case dict.get(state.bots, bot.id) {
        // Like the SQL `update ... where id = $1`: a missing row is a
        // silent no-op, not an error.
        Error(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Ok(_) ->
          // bot_name: renaming onto another bot's name is refused, like
          // the schema's UNIQUE constraint — no state change, no event.
          // The provider FK applies to the moved provider too.
          case
            list.any(dict.values(state.bots), fn(existing) {
              existing.id != bot.id && existing.name == bot.name
            }),
            dict.has_key(state.providers, bot.provider_id)
          {
            True, _ -> {
              process.send(reply, Error("bot name " <> bot.name <> " exists"))
              actor.continue(state)
            }
            False, False -> {
              process.send(reply, Error("unknown provider " <> bot.provider_id))
              actor.continue(state)
            }
            False, True -> {
              process.send(reply, Ok(Nil))
              actor.continue(
                State(
                  ..state,
                  bots: dict.insert(state.bots, bot.id, bot),
                  events: [EvUpdateBot(bot.id), ..state.events],
                ),
              )
            }
          }
      }

    DeleteBot(id, reply) -> {
      // ON DELETE SET NULL on thread.bot_id: provenance disappears, the
      // threads keep their frozen columns — mirrored as a metadata
      // scrub over the stored summaries.
      case dict.has_key(state.bots, id) {
        False -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True -> {
          // ON DELETE SET NULL, mirrored: every stored summary that
          // carried this bot as provenance loses the pointer (the
          // threads keep their frozen columns).
          let threads =
            dict.fold(state.threads, dict.new(), fn(acc, thread_id, stored) {
              let updated = case stored.summary.meta.bot_id {
                Some(bot_id) if bot_id == id ->
                  Stored(
                    ..stored,
                    summary: store.StoredSummary(
                      ..stored.summary,
                      meta: thread.ThreadMeta(
                        ..stored.summary.meta,
                        bot_id: None,
                      ),
                    ),
                  )
                _ -> stored
              }
              dict.insert(acc, thread_id, updated)
            })
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              threads: threads,
              bots: dict.delete(state.bots, id),
              events: [EvDeleteBot(id), ..state.events],
            ),
          )
        }
      }
    }

    CountBotsForProvider(id, reply) -> {
      let count =
        state.bots
        |> dict.values
        |> list.filter(fn(bot) { bot.provider_id == id })
        |> list.length
      process.send(reply, Ok(count))
      actor.continue(state)
    }

    // ---- node rows (docs/plans/environments.md, Phase 2b) ----
    ListNodes(reply) -> {
      let nodes =
        state.nodes
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(nodes))
      actor.continue(state)
    }

    GetNodeByName(name, reply) -> {
      let found =
        state.nodes
        |> dict.values
        |> list.find(fn(node) { node.name == name })
      case found {
        Ok(node) -> {
          process.send(reply, Ok(node))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored node named " <> name))
          actor.continue(state)
        }
      }
    }

    InsertNode(node, reply) ->
      // node_pkey + node_name, like the schema's constraints.
      case
        dict.has_key(state.nodes, node.id),
        list.any(dict.values(state.nodes), fn(existing) {
          existing.name == node.name
        })
      {
        True, _ -> {
          process.send(reply, Error("node " <> node.id <> " exists"))
          actor.continue(state)
        }
        False, True -> {
          process.send(reply, Error("node name " <> node.name <> " exists"))
          actor.continue(state)
        }
        False, False -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              nodes: dict.insert(state.nodes, node.id, node),
              events: [EvInsertNode(node.id), ..state.events],
            ),
          )
        }
      }

    TouchNode(id, reply) ->
      case dict.get(state.nodes, id) {
        // Like the SQL `update ... where id = $1`: a missing row is a
        // silent no-op, not an error.
        Error(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Ok(node) -> {
          let stamped =
            node.Node(..node, last_seen_at: Some(timing.wall_now_s()))
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              nodes: dict.insert(state.nodes, id, stamped),
              events: [EvTouchNode(id), ..state.events],
            ),
          )
        }
      }

    DeleteNode(id, reply) -> {
      case dict.has_key(state.nodes, id) {
        False -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(..state, nodes: dict.delete(state.nodes, id), events: [
              EvDeleteNode(id),
              ..state.events
            ]),
          )
        }
      }
    }

    Nodes(reply) -> {
      let nodes =
        state.nodes
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, nodes)
      actor.continue(state)
    }

    // ---- node pairing grants (docs/plans/tui-pairing.md, Phase A) ----
    ListNodeGrants(reply) -> {
      let grants =
        state.grants
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(grants))
      actor.continue(state)
    }

    InsertNodeGrant(grant, reply) ->
      // node_grant_pkey, like the schema's constraint. Codes are
      // 256-bit random — no unique hash index to model.
      case dict.has_key(state.grants, grant.id) {
        True -> {
          process.send(reply, Error("node grant " <> grant.id <> " exists"))
          actor.continue(state)
        }
        False -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              grants: dict.insert(state.grants, grant.id, grant),
              events: [EvInsertNodeGrant(grant.id), ..state.events],
            ),
          )
        }
      }

    TouchNodeGrant(id, reply) ->
      // Like the SQL `update ... where id = $1`: a missing row is a
      // silent no-op, and use_count is server-side increment (no lost
      // counts under concurrency).
      case dict.get(state.grants, id) {
        Error(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Ok(grant) -> {
          let stamped =
            node.Grant(
              ..grant,
              use_count: grant.use_count + 1,
              last_used_at: Some(timing.wall_now_s()),
            )
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              grants: dict.insert(state.grants, id, stamped),
              events: [EvTouchNodeGrant(id), ..state.events],
            ),
          )
        }
      }

    DeleteNodeGrant(id, reply) -> {
      case dict.has_key(state.grants, id) {
        False -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(..state, grants: dict.delete(state.grants, id), events: [
              EvDeleteNodeGrant(id),
              ..state.events
            ]),
          )
        }
      }
    }

    DeleteExpiredNodeGrants(reply) -> {
      // The boot sweep's semantics: `expires_at < now()` deletes,
      // an exactly-now expiry survives (the SQL's strict <).
      let now = timing.wall_now_s()
      let #(kept, expired) =
        list.partition(dict.values(state.grants), fn(grant) {
          grant.expires_at >= now
        })
      let expired_ids = list.map(expired, fn(grant) { grant.id })
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..state,
          grants: list.fold(kept, dict.new(), fn(acc, grant) {
            dict.insert(acc, grant.id, grant)
          }),
          events: list.append(
            list.map(expired_ids, EvDeleteNodeGrant),
            state.events,
          ),
        ),
      )
    }

    Grants(reply) -> {
      let grants =
        state.grants
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, grants)
      actor.continue(state)
    }

    Bots(reply) -> {
      let bots =
        state.bots
        |> dict.values
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, bots)
      actor.continue(state)
    }

    Rewind(id, keep_rows, messages, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        update_stored(state, id, fn(stored) {
          Stored(
            ..stored,
            rows: list.take(stored.rows, keep_rows),
            messages: messages,
            summary: store.StoredSummary(
              ..stored.summary,
              message_count: messages,
            ),
          )
        }),
      )
    }

    SetLastActive(id, at, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        update(state, id, fn(summary) {
          store.StoredSummary(..summary, last_active_at: at)
        }),
      )
    }
  }
}

fn update(
  state: State,
  id: String,
  f: fn(StoredSummary) -> StoredSummary,
) -> State {
  update_stored(state, id, fn(stored) {
    Stored(..stored, summary: f(stored.summary))
  })
}

fn update_stored(state: State, id: String, f: fn(Stored) -> Stored) -> State {
  case dict.get(state.threads, id) {
    Ok(stored) ->
      State(..state, threads: dict.insert(state.threads, id, f(stored)))
    Error(_) -> state
  }
}

/// The channel subtree of `root` over the stored rows (bot-channels
/// plan, #123): a fixpoint walk over `parent_thread_id` — hop chains
/// make channels of channels, so archive/unarchive/delete must reach
/// grandchildren too, exactly like the SQL's recursive CTE / CASCADE.
fn channel_subtree(
  threads: dict.Dict(String, Stored),
  root: String,
) -> List(String) {
  let children_of = fn(parent) {
    threads
    |> dict.values
    |> list.filter_map(fn(stored) {
      case stored.summary.meta.parent_thread_id {
        Some(id) if id == parent -> Ok(stored.summary.id)
        _ -> Error(Nil)
      }
    })
  }
  grow_subtree(children_of, [root], [root])
}

fn grow_subtree(
  children_of: fn(String) -> List(String),
  frontier: List(String),
  acc: List(String),
) -> List(String) {
  case frontier {
    [] -> acc
    [head, ..rest] -> {
      let fresh =
        children_of(head)
        |> list.filter(fn(id) { !list.contains(acc, id) })
      grow_subtree(
        children_of,
        list.append(rest, fresh),
        list.append(acc, fresh),
      )
    }
  }
}

/// The grace window, in seconds — mirrors the `interval '15 minutes'`
/// in prune_never_used.sql.
const prune_grace_s = 900

fn never_used(summary: StoredSummary, cutoff_s: Int) -> Bool {
  // Mirrors prune_never_used.sql: an environment thread's creation-time
  // roster row counts too (never-used env = system + roster = 2; the
  // first send persists >= 3).
  let empty =
    summary.message_count <= 1
    || { summary.workspace_root != None && summary.message_count <= 2 }
  empty
  && summary.meta.title_source == thread.AutoTitle
  && !summary.meta.pinned
  && summary.last_active_at < cutoff_s
}
