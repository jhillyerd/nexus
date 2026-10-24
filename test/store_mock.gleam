//// A fully functional **in-memory** implementation of the `nexus/store`
//// seam for offline tests: no database, no network, but the real
//// semantics — idempotent write-behind commits (an unchanged or older
//// transcript is a no-op), guarded auto-title, archive-clears-pin,
//// cascade delete, recency bumps. The persistence tests use it as the
//// "external Postgres" that survives a registry teardown, which makes
//// the whole hydrate/restart cycle testable inside plain `gleam test`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import nexus/session
import nexus/store.{type Store, type StoredProvider, type StoredSummary}
import nexus/timing
import nexus/transcript.{type Transcript}

/// Recorded seam calls, oldest first — for write-behind ordering and
/// metadata write-through assertions.
pub type Event {
  EvInsertSession(id: String)
  EvCommit(id: String, messages: Int)
  EvSetTitle(id: String, title: String)
  EvAutoTitle(id: String, title: String)
  EvAutoTitleUpgrade(id: String, title: String)
  EvSetTags(id: String, tags: List(String))
  EvSetPinned(id: String, pinned: Bool)
  EvArchive(id: String)
  EvUnarchive(id: String)
  EvDeleteSession(id: String)
  /// One boot sweep: the ids it deleted (sorted).
  EvPruneNeverUsed(ids: List(String))
  EvInsertProvider(id: String)
  EvUpdateProvider(id: String)
  EvDeleteProvider(id: String)
}

pub type MockMsg {
  // ---- seam operations (synchronous, Result replies) ----
  ListSummaries(reply: Subject(Result(List(StoredSummary), String)))
  GetSession(id: String, reply: Subject(Result(store.StoredSession, String)))
  LoadMessages(
    id: String,
    reply: Subject(Result(List(store.MessageRow), String)),
  )
  InsertSession(
    summary: StoredSummary,
    system_prompt: String,
    reply: Subject(Result(Nil, String)),
  )
  /// The write-behind lane: fire-and-forget, ordered by arrival. Also the
  /// replay path — applying the same (or an older) transcript again is a
  /// no-op apart from the recency bump.
  Commit(id: String, transcript: Transcript)
  SetTitle(id: String, title: String, reply: Subject(Result(Nil, String)))
  AutoTitle(id: String, title: String, reply: Subject(Result(Bool, String)))
  AutoTitleUpgrade(
    id: String,
    title: String,
    reply: Subject(Result(Bool, String)),
  )
  SetTags(id: String, tags: List(String), reply: Subject(Result(Nil, String)))
  SetPinned(id: String, pinned: Bool, reply: Subject(Result(Nil, String)))
  Archive(id: String, reply: Subject(Result(Nil, String)))
  Unarchive(id: String, reply: Subject(Result(Nil, String)))
  DeleteSession(id: String, reply: Subject(Result(Nil, String)))
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
  CountSessionsForProvider(id: String, reply: Subject(Result(Int, String)))
  DeleteProvider(id: String, reply: Subject(Result(Nil, String)))
  // ---- test-only introspection ----
  Events(reply: Subject(List(Event)))
  Rows(reply: Subject(List(#(String, List(store.MessageRow)))))
  /// Every stored provider, id-sorted — for direct row assertions.
  Providers(reply: Subject(List(StoredProvider)))
  /// Test-only: truncate a session's stored rows back to `keep_rows` and
  /// its persisted message count to `messages` to model a crash between
  /// commits — the next Commit re-emits the delta, which is exactly the
  /// crash-recovery replay the real store makes idempotent.
  Rewind(id: String, keep_rows: Int, messages: Int, reply: Subject(Nil))
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
    /// (mirrors sessions.message_count in the real schema).
    messages: Int,
  )
}

type State {
  State(
    sessions: Dict(String, Stored),
    providers: Dict(String, store.StoredProvider),
    events: List(Event),
  )
}

/// The provider id that test fixtures pin their sessions to — the
/// P1 stand-in for a real provider source (`session.provider_id` is NOT
/// NULL, so every stored session needs one).
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
/// before seeding sessions or booting a registry over the mock, since
/// `insert_session` enforces the provider FK like the real store.
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
        State(sessions: dict.new(), providers: dict.new(), events: []),
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
    get_session: fn(id) { call(mock, 5000, fn(r) { GetSession(id, r) }) },
    load_messages: fn(id) { call(mock, 5000, fn(r) { LoadMessages(id, r) }) },
    insert_session: fn(summary, system_prompt) {
      call(mock, 5000, fn(r) { InsertSession(summary, system_prompt, r) })
    },
    commit: fn(id, transcript) { process.send(mock, Commit(id, transcript)) },
    set_title: fn(id, title) {
      call(mock, 5000, fn(r) { SetTitle(id, title, r) })
    },
    auto_title: fn(id, title) {
      call(mock, 5000, fn(r) { AutoTitle(id, title, r) })
    },
    auto_title_upgrade: fn(id, title) {
      call(mock, 5000, fn(r) { AutoTitleUpgrade(id, title, r) })
    },
    set_tags: fn(id, tags) { call(mock, 5000, fn(r) { SetTags(id, tags, r) }) },
    set_pinned: fn(id, pinned) {
      call(mock, 5000, fn(r) { SetPinned(id, pinned, r) })
    },
    archive: fn(id) { call(mock, 5000, fn(r) { Archive(id, r) }) },
    unarchive: fn(id) { call(mock, 5000, fn(r) { Unarchive(id, r) }) },
    delete_session: fn(id) { call(mock, 5000, fn(r) { DeleteSession(id, r) }) },
    prune_never_used: fn() { call(mock, 5000, PruneNeverUsed) },
    list_providers: fn() { call(mock, 5000, ListProviders) },
    get_provider: fn(id) { call(mock, 5000, fn(r) { GetProvider(id, r) }) },
    insert_provider: fn(provider) {
      call(mock, 5000, fn(r) { InsertProvider(provider, r) })
    },
    update_provider: fn(provider, replace_key) {
      call(mock, 5000, fn(r) { UpdateProvider(provider, replace_key, r) })
    },
    count_sessions_for_provider: fn(id) {
      call(mock, 5000, fn(r) { CountSessionsForProvider(id, r) })
    },
    delete_provider: fn(id) {
      call(mock, 5000, fn(r) { DeleteProvider(id, r) })
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

/// Every session's rows, id-sorted — for direct row assertions.
pub fn rows(mock: Subject(MockMsg)) -> List(#(String, List(store.MessageRow))) {
  call(mock, 5000, Rows)
}

/// Every stored provider, id-sorted — for direct row assertions
/// (envelopes included: the mock holds ciphertext, like the real store).
pub fn providers(mock: Subject(MockMsg)) -> List(store.StoredProvider) {
  call(mock, 5000, Providers)
}

/// Truncate a session's stored rows (models a crash between commits so
/// the next Commit replays).
pub fn rewind(
  mock: Subject(MockMsg),
  id: String,
  keep_rows: Int,
  messages: Int,
) -> Nil {
  call(mock, 5000, fn(r) { Rewind(id, keep_rows, messages, r) })
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
        state.sessions
        |> dict.values
        |> list.map(fn(stored) { stored.summary })
        |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
      process.send(reply, Ok(summaries))
      actor.continue(state)
    }

    GetSession(id, reply) ->
      case dict.get(state.sessions, id) {
        Ok(stored) -> {
          process.send(
            reply,
            Ok(store.StoredSession(
              summary: stored.summary,
              system_prompt: stored.system_prompt,
            )),
          )
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
      }

    LoadMessages(id, reply) ->
      case dict.get(state.sessions, id) {
        Ok(stored) -> {
          process.send(reply, Ok(stored.rows))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
      }

    InsertSession(summary, system_prompt, reply) ->
      // session_provider_id_fkey: the pinned provider must exist, like
      // the real store's FK refuses unknown ids.
      case dict.get(state.providers, summary.provider_id) {
        Error(_) -> {
          process.send(reply, Error("unknown provider " <> summary.provider_id))
          actor.continue(state)
        }
        Ok(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(
                state.sessions,
                summary.id,
                Stored(summary, system_prompt, [], summary.message_count),
              ),
              events: [EvInsertSession(summary.id), ..state.events],
            ),
          )
        }
      }

    Commit(id, transcript) -> {
      let events = [EvCommit(id, transcript.length(transcript)), ..state.events]
      let sessions = case dict.get(state.sessions, id) {
        Error(_) -> state.sessions
        Ok(stored) -> {
          // The delta past what is stored, in seq order; an unchanged or
          // older transcript yields nothing (matching the real store,
          // which does not even bump recency without a delta).
          let already = stored.messages
          case store.has_delta(transcript, already) {
            False -> state.sessions
            True -> {
              let delta = store.transcript_rows(transcript, already)
              let total = transcript.length(transcript)
              dict.insert(
                state.sessions,
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
      actor.continue(State(..state, sessions: sessions, events: events))
    }

    SetTitle(id, title, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(
              ..summary,
              title: title,
              title_source: session.ManualTitle,
            )
          }),
          events: [EvSetTitle(id, title), ..state.events],
        ),
      )
    }

    AutoTitle(id, title, reply) ->
      case dict.get(state.sessions, id) {
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
        Ok(stored) ->
          case stored.summary.title_source, stored.summary.title {
            session.AutoTitle, "" -> {
              process.send(reply, Ok(True))
              actor.continue(
                State(
                  ..update(state, id, fn(summary) {
                    store.StoredSummary(..summary, title: title)
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

    AutoTitleUpgrade(id, title, reply) ->
      // Mirrors `auto_title_upgrade.sql` (utility-titles plan §4.4): the
      // guard is provenance ONLY — an auto title (even the heuristic
      // placeholder, even a previously upgraded one) may be replaced; a
      // manual rename wins forever.
      case dict.get(state.sessions, id) {
        Error(_) -> {
          process.send(reply, Error("no stored session " <> id))
          actor.continue(state)
        }
        Ok(stored) ->
          case stored.summary.title_source {
            session.AutoTitle -> {
              process.send(reply, Ok(True))
              actor.continue(
                State(
                  ..update(state, id, fn(summary) {
                    store.StoredSummary(..summary, title: title)
                  }),
                  events: [EvAutoTitleUpgrade(id, title), ..state.events],
                ),
              )
            }
            _ -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
      }

    SetTags(id, tags, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, tags: tags)
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
            store.StoredSummary(..summary, pinned: pinned)
          }),
          events: [EvSetPinned(id, pinned), ..state.events],
        ),
      )
    }

    Archive(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, archived: True, pinned: False)
          }),
          events: [EvArchive(id), ..state.events],
        ),
      )
    }

    Unarchive(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..update(state, id, fn(summary) {
            store.StoredSummary(..summary, archived: False)
          }),
          events: [EvUnarchive(id), ..state.events],
        ),
      )
    }

    DeleteSession(id, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, sessions: dict.delete(state.sessions, id), events: [
          EvDeleteSession(id),
          ..state.events
        ]),
      )
    }

    PruneNeverUsed(reply) -> {
      // Same contract as prune_never_used.sql: never-used (system
      // prompt only, auto-titled, unpinned) AND older than the grace
      // window that protects a concurrent server's fresh empty.
      let cutoff = timing.wall_now_s() - prune_grace_s
      let ids =
        state.sessions
        |> dict.values
        |> list.filter(fn(stored) { never_used(stored.summary, cutoff) })
        |> list.map(fn(stored) { stored.summary.id })
        |> list.sort(string.compare)
      let sessions =
        list.fold(ids, state.sessions, fn(sessions, id) {
          dict.delete(sessions, id)
        })
      process.send(reply, Ok(ids))
      // An empty sweep is a no-op — not an observable store event (the
      // metadata tests assert the exact event stream).
      let events = case ids {
        [] -> state.events
        _ -> [EvPruneNeverUsed(ids), ..state.events]
      }
      actor.continue(State(..state, sessions: sessions, events: events))
    }

    Events(reply) -> {
      process.send(reply, list.reverse(state.events))
      actor.continue(state)
    }

    Rows(reply) -> {
      let rows =
        state.sessions
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

    CountSessionsForProvider(id, reply) -> {
      let count =
        state.sessions
        |> dict.values
        |> list.filter(fn(stored) { stored.summary.provider_id == id })
        |> list.length
      process.send(reply, Ok(count))
      actor.continue(state)
    }

    DeleteProvider(id, reply) -> {
      // ON DELETE RESTRICT: the FK refuses while any session pins the
      // provider (the count is the registry's friendly 409 pre-check).
      let referenced =
        state.sessions
        |> dict.values
        |> list.any(fn(stored) { stored.summary.provider_id == id })
      case dict.has_key(state.providers, id), referenced {
        False, _ -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        True, True -> {
          process.send(
            reply,
            Error("provider " <> id <> " still pinned by sessions"),
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
  case dict.get(state.sessions, id) {
    Ok(stored) ->
      State(..state, sessions: dict.insert(state.sessions, id, f(stored)))
    Error(_) -> state
  }
}

/// The grace window, in seconds — mirrors the `interval '15 minutes'`
/// in prune_never_used.sql.
const prune_grace_s = 900

fn never_used(summary: StoredSummary, cutoff_s: Int) -> Bool {
  summary.message_count <= 1
  && summary.title_source == session.AutoTitle
  && !summary.pinned
  && summary.last_active_at < cutoff_s
}
