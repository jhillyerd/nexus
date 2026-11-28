//// The pog-backed store implementation behind the `nexus/store` seam: a
//// supervised actor owning one Postgres connection pool (pog over pgo)
//// and the per-thread write-behind bookkeeping.
////
//// Boot starts this actor BEFORE the registry (persistence is mandatory —
//// there is no ephemeral fallback; if the pool cannot start, boot fails).
//// Reads and metadata writes are synchronous `actor.call`s from the
//// registry; turn commits arrive as fire-and-forget `Commit` messages
//// from the thread actors' injected commit hooks and are applied
//// strictly in arrival order, which preserves per-thread seq order.
////
//// The SQL itself lives in `src/nexus/store/sql/*.sql` and is turned into
//// typed Gleam by squirrel (`gleam run -m squirrel`); the generated
//// `nexus/store/sql` module is committed and drift-gated in CI via
//// `gleam run -m squirrel check`.
////
//// Idempotency / recovery:
//// - every message insert carries `on conflict (thread_id, seq) do
////   nothing`, so replaying a commit after a crash re-inserts nothing;
//// - `last_active_at` / `message_count` are written as absolute values
////   (now() / the committed transcript length), so a replayed bump is a
////   no-op;
//// - the persisted-length bookkeeping is in-memory; if this actor
////   restarts it re-derives each thread's length from the thread's
////   denormalized message_count on the next commit, never from guesswork.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import nexus/bot
import nexus/config.{type Config}
import nexus/log
import nexus/node
import nexus/store
import nexus/store/sql
import nexus/thread
import nexus/transcript.{type Transcript}
import nexus/workspace_gc
import pog

pub type Msg {
  ListSummaries(
    reply: Subject(Result(#(List(store.StoredSummary), List(String)), String)),
  )
  GetThread(id: String, reply: Subject(Result(store.StoredThread, String)))
  LoadMessages(
    id: String,
    reply: Subject(Result(List(store.MessageRow), String)),
  )
  LoadCompactions(
    id: String,
    reply: Subject(Result(List(transcript.Compaction), String)),
  )
  InsertThread(
    summary: store.StoredSummary,
    system_prompt: String,
    reply: Subject(Result(Nil, String)),
  )
  /// The channel re-derivation lookup (bot-channels plan, #123):
  /// find the existing channel row for one (parent thread, target bot)
  /// pair — `Ok(None)` = no row, may create; `Ok(Some(id))` = repoint;
  /// `Error` = store outage, the caller refuses retryably.
  FindChannel(
    parent_thread_id: String,
    bot_id: String,
    reply: Subject(Result(option.Option(String), String)),
  )
  /// Write-behind turn commit (fire-and-forget, ordered by arrival).
  Commit(id: String, transcript: Transcript)
  /// Write-behind atomic compaction persistence (fire-and-forget, ordered
  /// in the same mailbox as Commit; executes inside one `pog.transaction`).
  RecordCompaction(
    id: String,
    transcript: Transcript,
    checkpoint: transcript.Compaction,
  )
  /// Write-behind context-token watermark update (fire-and-forget).
  SetLastContextTokens(id: String, tokens: Int)
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
  DeleteThread(
    id: String,
    reply: Subject(Result(List(store.TombstonedWorkspace), String)),
  )
  /// Boot sweep (see `prune_never_used.sql`): bulk delete of stale
  /// never-used threads, replying with the deleted ids.
  PruneNeverUsed(reply: Subject(Result(List(String), String)))
  // ---- workspace rows (docs/plans/workspace-sandbox.md, Phase 1) ----
  ListDeletedWorkspaces(
    reply: Subject(Result(List(store.TombstonedWorkspace), String)),
  )
  DeleteWorkspace(id: String, reply: Subject(Result(Nil, String)))
  InsertWorkspace(
    workspace: store.StoredWorkspace,
    reply: Subject(Result(Nil, String)),
  )
  // ---- provider rows (docs/plans/multi-provider.md §5.3) ----
  ListProviders(reply: Subject(Result(List(store.StoredProvider), String)))
  GetProvider(id: String, reply: Subject(Result(store.StoredProvider, String)))
  InsertProvider(
    provider: store.StoredProvider,
    reply: Subject(Result(Nil, String)),
  )
  /// `replace_key = False` keeps the stored envelope (see
  /// `update_provider.sql`).
  UpdateProvider(
    provider: store.StoredProvider,
    replace_key: Bool,
    reply: Subject(Result(Nil, String)),
  )
  CountThreadsForProvider(id: String, reply: Subject(Result(Int, String)))
  DeleteProvider(id: String, reply: Subject(Result(Nil, String)))
  // ---- bot rows (docs/plans/completed/bots.md, Phase 1) ----
  ListBots(reply: Subject(Result(List(store.StoredBot), String)))
  GetBot(id: String, reply: Subject(Result(store.StoredBot, String)))
  InsertBot(bot: store.StoredBot, reply: Subject(Result(Nil, String)))
  UpdateBot(bot: store.StoredBot, reply: Subject(Result(Nil, String)))
  DeleteBot(
    id: String,
    reply: Subject(Result(List(store.TombstonedWorkspace), String)),
  )
  CountBotsForProvider(id: String, reply: Subject(Result(Int, String)))
  // ---- node rows (docs/plans/environments.md, Phase 2b) ----
  ListNodes(reply: Subject(Result(List(store.StoredNode), String)))
  GetThreadNode(
    thread_id: String,
    name: String,
    reply: Subject(Result(store.StoredNode, String)),
  )
  InsertNode(node: store.StoredNode, reply: Subject(Result(Nil, String)))
  TouchNode(id: String, reply: Subject(Result(Nil, String)))
  DeleteNode(id: String, reply: Subject(Result(Nil, String)))
  // ---- node pairing grants (docs/plans/tui-pairing.md, Phase A) ----
  ListNodeGrants(reply: Subject(Result(List(store.StoredGrant), String)))
  InsertNodeGrant(grant: store.StoredGrant, reply: Subject(Result(Nil, String)))
  TouchNodeGrant(id: String, reply: Subject(Result(Nil, String)))
  DeleteNodeGrant(id: String, reply: Subject(Result(Nil, String)))
  DeleteExpiredNodeGrants(reply: Subject(Result(Nil, String)))
  /// Boot sweep (tui-pairing plan hygiene): delete idle node rows,
  /// replying with the swept names.
  DeleteIdleNodes(days: Int, reply: Subject(Result(List(String), String)))
}

type State {
  State(
    db: pog.Connection,
    /// Chronological transcript length (including the system prompt)
    /// already persisted per thread. `-1` marks a thread whose row is
    /// known absent — commits are dropped for it until it is created.
    persisted: Dict(String, Int),
  )
}

const call_timeout_ms = 15_000

/// Start the store actor with its own pog pool (linked: if the actor dies
/// the pool dies with it and supervision restarts both).
pub fn start(
  cfg: Config,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  let pg_config =
    pog.default_config(pool_name: process.new_name("nexus_store_pool"))
    |> pog.host(cfg.pg_host)
    |> pog.port(cfg.pg_port)
    |> pog.database(cfg.pg_database)
    |> pog.user(cfg.pg_user)
    |> pog.password(cfg.pg_password)
    // Hygiene only (the schema is timestamptz and every read goes
    // through extract(epoch ...)); pinning keeps ad-hoc renders and any
    // future naive-typed debugging deterministic.
    |> pog.connection_parameter("timezone", "UTC")
  start_with_pg_config(
    pg_config,
    name,
    cfg.pg_host <> ":" <> int.to_string(cfg.pg_port),
  )
}

/// Start the store actor with a caller-supplied `pog.Config` (used by
/// `start` and by the Postgres contract verifier `nexus/store/verify` to
/// pin an isolated `search_path` or test non-UTC `timezone` settings).
pub fn start_with_pg_config(
  pg_config: pog.Config,
  name: process.Name(Msg),
  target_label: String,
) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self) {
      case pog.start(pg_config) {
        Ok(started) ->
          actor.initialised(State(db: started.data, persisted: dict.new()))
          |> actor.returning(self)
          |> Ok
        Error(reason) ->
          // Fail fast and loudly: persistence is mandatory, there is no
          // silent ephemeral mode (see README env table).
          panic as {
            "nexus store: could not start Postgres pool on "
            <> target_label
            <> " ("
            <> start_error_text(reason)
            <> ") — is the database up? see docker-compose.yml"
          }
      }
    })
    |> actor.on_message(handle)
    |> actor.named(name)
  actor.start(builder)
}

fn start_error_text(reason: actor.StartError) -> String {
  case reason {
    actor.InitFailed(message) -> message
    _ -> "start failed"
  }
}

/// Child specification for the boot supervision tree (first child: the
/// registry resolves the seam by name afterwards).
pub fn supervised(
  cfg: Config,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  start(cfg, name)
}

/// Build the swappable seam over a started store actor.
pub fn seam(store_actor: Subject(Msg)) -> store.Store {
  store.Store(
    list_summaries: fn() {
      actor.call(store_actor, call_timeout_ms, ListSummaries)
    },
    get_thread: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        GetThread(id, reply)
      })
    },
    load_messages: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        LoadMessages(id, reply)
      })
    },
    load_compactions: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        LoadCompactions(id, reply)
      })
    },
    insert_thread: fn(summary, system_prompt) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertThread(summary, system_prompt, reply)
      })
    },
    find_channel: fn(parent_thread_id, bot_id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        FindChannel(parent_thread_id, bot_id, reply)
      })
    },
    commit: fn(id, transcript) {
      process.send(store_actor, Commit(id, transcript))
    },
    record_compaction: fn(id, transcript, checkpoint) {
      process.send(store_actor, RecordCompaction(id, transcript, checkpoint))
    },
    set_last_context_tokens: fn(id, tokens) {
      process.send(store_actor, SetLastContextTokens(id, tokens))
    },
    set_title: fn(id, title) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetTitle(id, title, reply)
      })
    },
    auto_title: fn(id, title) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        AutoTitle(id, title, reply)
      })
    },
    auto_meta_upgrade: fn(id, title, tags) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        AutoMetaUpgrade(id, title, tags, reply)
      })
    },
    set_tags: fn(id, tags) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetTags(id, tags, reply)
      })
    },
    set_pinned: fn(id, pinned) -> Result(Nil, String) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        SetPinned(id, pinned, reply)
      })
    },
    archive: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) { Archive(id, reply) })
    },
    unarchive: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        Unarchive(id, reply)
      })
    },
    delete_thread: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteThread(id, reply)
      })
    },
    prune_never_used: fn() {
      actor.call(store_actor, call_timeout_ms, PruneNeverUsed)
    },
    list_deleted_workspaces: fn() {
      actor.call(store_actor, call_timeout_ms, ListDeletedWorkspaces)
    },
    delete_workspace: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteWorkspace(id, reply)
      })
    },
    insert_workspace: fn(workspace) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertWorkspace(workspace, reply)
      })
    },
    list_providers: fn() {
      actor.call(store_actor, call_timeout_ms, ListProviders)
    },
    get_provider: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        GetProvider(id, reply)
      })
    },
    insert_provider: fn(provider) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertProvider(provider, reply)
      })
    },
    update_provider: fn(provider, replace_key) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        UpdateProvider(provider, replace_key, reply)
      })
    },
    count_threads_for_provider: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        CountThreadsForProvider(id, reply)
      })
    },
    delete_provider: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteProvider(id, reply)
      })
    },
    list_bots: fn() { actor.call(store_actor, call_timeout_ms, ListBots) },
    get_bot: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) { GetBot(id, reply) })
    },
    insert_bot: fn(bot) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertBot(bot, reply)
      })
    },
    update_bot: fn(bot) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        UpdateBot(bot, reply)
      })
    },
    delete_bot: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteBot(id, reply)
      })
    },
    count_bots_for_provider: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        CountBotsForProvider(id, reply)
      })
    },
    list_nodes: fn() { actor.call(store_actor, call_timeout_ms, ListNodes) },
    get_thread_node: fn(thread_id, name) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        GetThreadNode(thread_id, name, reply)
      })
    },
    insert_node: fn(node) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertNode(node, reply)
      })
    },
    touch_node: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        TouchNode(id, reply)
      })
    },
    delete_node: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteNode(id, reply)
      })
    },
    list_node_grants: fn() {
      actor.call(store_actor, call_timeout_ms, ListNodeGrants)
    },
    insert_node_grant: fn(grant) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        InsertNodeGrant(grant, reply)
      })
    },
    touch_node_grant: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        TouchNodeGrant(id, reply)
      })
    },
    delete_node_grant: fn(id) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteNodeGrant(id, reply)
      })
    },
    delete_expired_node_grants: fn() {
      actor.call(store_actor, call_timeout_ms, DeleteExpiredNodeGrants)
    },
    delete_idle_nodes: fn(days) {
      actor.call(store_actor, call_timeout_ms, fn(reply) {
        DeleteIdleNodes(days, reply)
      })
    },
  )
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ListSummaries(reply) -> {
      let result =
        sql.list_summaries(state.db)
        |> result.map(fn(returned) {
          // A corrupt manifest skips its row (loud log): one bad row
          // must neither brick boot (this list feeds hydration) nor
          // silently narrow that thread — the thread simply fails to
          // rehydrate later, with the corruption already logged. Its
          // ID rides back separately so the registry's minting counter
          // still seeds PAST it (a reminted id would collide on
          // insert).
          returned.rows
          |> list.fold(#([], []), fn(acc, row) {
            let #(summaries, skipped) = acc
            case stored_summary_from_row(row) {
              Ok(summary) -> #([summary, ..summaries], skipped)
              Error(e) -> {
                log.warn("store", "skipping corrupt thread row", [
                  log.str("thread_id", row.id),
                  log.str("error", e),
                ])
                #(summaries, [row.id, ..skipped])
              }
            }
          })
          |> fn(pair) {
            let #(summaries, skipped) = pair
            #(list.reverse(summaries), list.reverse(skipped))
          }
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    GetThread(id, reply) -> {
      let result = case sql.get_thread(state.db, id) {
        Error(error) -> Error(query_error(error))
        Ok(pog.Returned(_, rows)) ->
          case rows {
            [row] ->
              // The frozen toolset manifest (plugin-api plan Phase 2):
              // parsed from the row's aggregate json BEFORE the summary
              // is built — a corrupt manifest is an error the caller
              // refuses loudly, never a silent narrowing.
              case store.decode_toolset(row.toolset) {
                Error(e) -> Error(e)
                Ok(entries) ->
                  Ok(store.StoredThread(
                    summary: store.StoredSummary(
                      id: row.id,
                      provider_id: row.provider_id,
                      model: row.model,
                      meta: thread.ThreadMeta(
                        title: row.title,
                        title_source: title_source(row.title_source),
                        pinned: row.pinned,
                        archived: row.archived,
                        tags: row.tags,
                        tags_manual: row.tags_manual,
                        tags_source: tags_source(row.tags_source),
                        bot_id: row.bot_id,
                        parent_thread_id: row.parent_thread_id,
                        created_at: row.created_s,
                      ),
                      toolset: entries,
                      workspace_root: row.workspace_root,
                      workspaces: thread_workspaces_from_row(
                        row.workspace_id,
                        row.workspace_rel_path,
                        row.tmp_workspace_id,
                        row.tmp_rel_path,
                      ),
                      roster: option.None,
                      last_active_at: row.last_active_s,
                      // The column already counts the system prompt
                      // (Phase 1 semantics).
                      message_count: row.message_count,
                      context_window: row.context_window,
                      last_context_tokens: row.last_context_tokens,
                    ),
                    system_prompt: row.system_prompt,
                  ))
              }
            _ -> Error("no stored thread " <> id)
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    LoadMessages(id, reply) -> {
      let result =
        sql.load_messages(state.db, id)
        |> result.map(fn(returned) {
          let rows = returned.rows
          // The joined message_count is the authoritative persisted
          // transcript length (rows undercount when a message carried
          // several tool calls). When empty, leave `state.persisted`
          // untouched so `ensure_persisted` distinguishes a fresh thread
          // from an unknown thread id on the first commit.
          let persisted = case list.last(rows) {
            Ok(row) -> Some(row.message_count)
            Error(_) -> None
          }
          #(rows |> list.map(message_row_from_row), persisted)
        })
        |> result.map_error(query_error)
      case result {
        Ok(#(rows, Some(persisted))) -> {
          process.send(reply, Ok(rows))
          actor.continue(
            State(
              ..state,
              persisted: dict.insert(state.persisted, id, persisted),
            ),
          )
        }
        Ok(#(rows, None)) -> {
          process.send(reply, Ok(rows))
          actor.continue(state)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }

    LoadCompactions(id, reply) -> {
      let result =
        sql.load_compactions(state.db, id)
        |> result.map_error(query_error)
        |> result.try(fn(returned) {
          list.try_map(returned.rows, fn(row) {
            case transcript.trigger_from_string(row.trigger_kind) {
              Ok(trigger) ->
                Ok(transcript.Compaction(
                  cutoff_index: row.cutoff_index,
                  summary: row.summary,
                  roster_snapshot: row.roster_snapshot,
                  focus: row.focus,
                  trigger: trigger,
                  before_tokens: row.before_tokens,
                  after_tokens: row.after_tokens,
                  created_at: row.created_s,
                ))
              Error(Nil) ->
                Error(
                  "compaction row for thread "
                  <> id
                  <> " has unknown trigger_kind: "
                  <> row.trigger_kind,
                )
            }
          })
        })
      process.send(reply, result)
      actor.continue(state)
    }

    InsertThread(summary, system_prompt, reply) -> {
      let result =
        sql.insert_thread(
          state.db,
          summary.id,
          summary.provider_id,
          summary.meta.title,
          title_source_text(summary.meta.title_source),
          summary.model,
          system_prompt,
          summary.meta.pinned,
          summary.meta.tags,
          int.to_float(summary.meta.created_at),
          summary.message_count,
          // The '' sentinel writes NULL (no bot) — see insert_bot.sql.
          option.unwrap(summary.meta.bot_id, ""),
          // The frozen toolset manifest (plugin-api plan Phase 2),
          // written in the SAME statement as the row (CTE) so a
          // half-thread can never exist. Transport-encoded as json
          // ($12); the stored columns stay TEXT.
          store.encode_toolset(summary.toolset),
          // Environments plan Phase 1: the frozen workspace root ($13),
          // same '' sentinel (NULL = no env tools).
          option.unwrap(summary.workspace_root, ""),
          // The creation-time roster row ($14 text / $15 stamp): the ''
          // text sentinel skips the row entirely (plain threads).
          case summary.roster {
            option.Some(#(text, stamp)) -> #(text, stamp)
            option.None -> #("", 0)
          }
            |> fn(row) { row.0 },
          case summary.roster {
            option.Some(#(_text, stamp)) -> stamp
            option.None -> 0
          },
          // The parent link (bot-channels plan, #123, $16): the ''
          // sentinel inserts NULL (ordinary threads) — the same nullif
          // pattern as bot_id/workspace_root above.
          option.unwrap(summary.meta.parent_thread_id, ""),
          // Workspace rows (workspace-sandbox plan Phase 1, $17..$20):
          // '' sentinels insert NULL / skip workspace row creation.
          case summary.workspaces {
            Some(ws) -> ws.workspace_id
            None -> ""
          },
          case summary.workspaces {
            Some(ws) -> option.unwrap(ws.tmp_id, "")
            None -> ""
          },
          case summary.workspaces {
            Some(ws) -> ws.rel_path
            None -> ""
          },
          case summary.workspaces {
            Some(ws) -> option.unwrap(ws.tmp_rel_path, "")
            None -> ""
          },
          // Context monitoring (Phase 1, $21..$22): 0 / -1 sentinels insert NULL.
          option.unwrap(summary.context_window, 0),
          option.unwrap(summary.last_context_tokens, -1),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      let state = case result {
        Ok(_) ->
          State(
            ..state,
            persisted: dict.insert(
              state.persisted,
              summary.id,
              summary.message_count,
            ),
          )
        Error(_) -> state
      }
      process.send(reply, result)
      actor.continue(state)
    }

    FindChannel(parent_thread_id, bot_id, reply) -> {
      let result =
        sql.find_channel(state.db, parent_thread_id, bot_id)
        |> result.map_error(query_error)
        |> result.try(fn(returned) {
          case returned.rows {
            // The partial unique index thread_channel guarantees at most
            // one row per (parent, bot); more is corrupt state — refused
            // as a store ERROR (never a miss, and never a panic: this
            // actor serves every store call), so the delivery path
            // refuses retryably instead of creating behind ambiguity.
            [] -> Ok(option.None)
            [row] -> Ok(option.Some(row.id))
            _ ->
              Error(
                "duplicate channel rows for parent "
                <> parent_thread_id
                <> " bot "
                <> bot_id
                <> " (thread_channel unique index violated)",
              )
          }
        })
      process.send(reply, result)
      actor.continue(state)
    }

    Commit(id, tr) -> handle_commit(state, id, tr)

    RecordCompaction(id, tr, checkpoint) ->
      handle_record_compaction(state, id, tr, checkpoint)

    SetLastContextTokens(id, tokens) -> {
      case sql.set_last_context_tokens(state.db, int.max(0, tokens), id) {
        Ok(_) -> Nil
        Error(error) ->
          log_store_error("set_last_context_tokens " <> id, query_error(error))
      }
      actor.continue(state)
    }

    SetTitle(id, title, reply) -> {
      process.send(reply, update(sql.set_title(state.db, title, id)))
      actor.continue(state)
    }

    AutoTitle(id, title, reply) -> {
      let result =
        sql.auto_title(state.db, title, id)
        |> result.map(fn(returned) { returned.count > 0 })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    AutoMetaUpgrade(id, title, tags, reply) -> {
      // Same guard semantics as the registry's UpgradeAutoTitle:
      // provenance only, on both columns — the SQL refuses a manual title
      // OR a manual tag set, and the affected-row count says whether it
      // applied.
      let result =
        sql.auto_meta_upgrade(state.db, title, id, tags)
        |> result.map(fn(returned) { returned.count > 0 })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    SetTags(id, tags, reply) -> {
      process.send(reply, update(sql.set_tags(state.db, tags, id)))
      actor.continue(state)
    }

    SetPinned(id, pinned, reply) -> {
      process.send(reply, update(sql.set_pinned(state.db, pinned, id)))
      actor.continue(state)
    }

    Archive(id, reply) -> {
      process.send(reply, update(sql.archive(state.db, id)))
      actor.continue(state)
    }

    Unarchive(id, reply) -> {
      process.send(reply, update(sql.unarchive(state.db, id)))
      actor.continue(state)
    }

    DeleteThread(id, reply) -> {
      // Two sequential statements in ONE transaction: tombstoning owned
      // workspaces FIRST clears workspace.thread_id = NULL before DELETE FROM
      // thread runs, so ON DELETE SET NULL never overlaps with setting
      // deleted_at. Returning the full deleted subtree also lets us evict
      // every cascaded channel descendant from state.persisted.
      let outcome =
        pog.transaction(state.db, fn(tx) {
          use subtree_rows <- result.try(
            sql.select_thread_subtree(tx, id) |> result.map_error(query_error),
          )
          let subtree_ids = list.map(subtree_rows.rows, fn(row) { row.id })
          case subtree_ids {
            [] -> Ok(#([], []))
            _ -> {
              use ws_rows <- result.try(
                sql.tombstone_workspaces_for_threads(tx, subtree_ids)
                |> result.map_error(query_error),
              )
              use _ <- result.try(
                sql.delete_thread(tx, id) |> result.map_error(query_error),
              )
              let tombstoned =
                ws_rows.rows
                |> list.map(fn(row) {
                  store.TombstonedWorkspace(
                    id: row.id,
                    root: row.root,
                    rel_path: row.rel_path,
                  )
                })
                |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
              Ok(#(tombstoned, subtree_ids))
            }
          }
        })
        |> result.map_error(transaction_error)
      case outcome {
        Ok(#(tombstoned, subtree_ids)) -> {
          let persisted =
            list.fold([id, ..subtree_ids], state.persisted, fn(acc, sid) {
              dict.delete(acc, sid)
            })
          process.send(reply, Ok(tombstoned))
          actor.continue(State(..state, persisted: persisted))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }

    PruneNeverUsed(reply) -> {
      // Lock candidates FOR UPDATE, tombstone their workspaces, then delete
      // the locked threads — sequential statements in ONE transaction so
      // ON DELETE SET NULL never races setting deleted_at.
      let outcome =
        pog.transaction(state.db, fn(tx) {
          use candidates <- result.try(
            sql.select_never_used_threads(tx) |> result.map_error(query_error),
          )
          let candidate_ids = list.map(candidates.rows, fn(row) { row.id })
          case candidate_ids {
            [] -> Ok([])
            _ -> {
              use _ <- result.try(
                sql.tombstone_workspaces_for_threads(tx, candidate_ids)
                |> result.map_error(query_error),
              )
              use deleted <- result.try(
                sql.prune_never_used(tx, candidate_ids)
                |> result.map_error(query_error),
              )
              Ok(
                deleted.rows
                |> list.map(fn(row) { row.id })
                |> list.sort(string.compare),
              )
            }
          }
        })
        |> result.map_error(transaction_error)
      case outcome {
        Ok(ids) -> {
          // Same bookkeeping as DeleteThread: a pruned row is gone, so
          // its persisted-length watermark must not survive it.
          let persisted =
            list.fold(ids, state.persisted, fn(persisted, id) {
              dict.delete(persisted, id)
            })
          process.send(reply, Ok(ids))
          actor.continue(State(..state, persisted: persisted))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }

    ListProviders(reply) -> {
      let result =
        sql.list_providers(state.db)
        |> result.map(fn(returned) {
          returned.rows |> list.map(stored_provider_from_list_row)
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    GetProvider(id, reply) -> {
      let result = case sql.get_provider(state.db, id) {
        Error(error) -> Error(query_error(error))
        Ok(pog.Returned(_, rows)) ->
          case rows {
            [row] -> Ok(stored_provider_from_row(row))
            _ -> Error("no stored provider " <> id)
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    InsertProvider(provider, reply) -> {
      let result =
        sql.insert_provider(
          state.db,
          provider.id,
          provider.name,
          provider.base_url,
          key_param(provider.api_key_encrypted),
          provider.key_version,
          provider.dialect,
          provider.enabled,
          int.to_float(provider.created_at),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    UpdateProvider(provider, replace_key, reply) -> {
      let result =
        sql.update_provider(
          state.db,
          provider.id,
          provider.name,
          provider.base_url,
          replace_key,
          key_param(provider.api_key_encrypted),
          provider.key_version,
          provider.enabled,
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    CountThreadsForProvider(id, reply) -> {
      let result =
        sql.count_threads_for_provider(state.db, id)
        |> result.map(fn(returned) {
          case returned.rows {
            [row] -> row.threads
            // count(*) always yields exactly one row.
            _ -> 0
          }
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    DeleteProvider(id, reply) -> {
      // Errors (FK restrict while referenced) flow to the caller — the
      // registry maps them to its 409.
      process.send(reply, update(sql.delete_provider(state.db, id)))
      actor.continue(state)
    }

    // ---- bot rows (docs/plans/completed/bots.md, Phase 1) ----
    ListBots(reply) -> {
      let result =
        sql.list_bots(state.db)
        |> result.map(fn(returned) {
          returned.rows
          |> list.map(fn(row) {
            bot_from_row(
              row.id,
              row.name,
              row.description,
              row.provider_id,
              row.model,
              row.system_prompt,
              row.tools,
              row.allow_inbound,
              row.context_window,
              row.created_s,
              row.updated_s,
            )
          })
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    GetBot(id, reply) -> {
      // Empty result = unknown id; the caller decides. The nested
      // Result is flattened by hand (query error vs unknown id are both
      // just `Error(String)` to the seam's callers).
      let result = case sql.get_bot(state.db, id) {
        Error(error) -> Error(query_error(error))
        Ok(pog.Returned(_, rows)) ->
          case rows {
            [row] ->
              Ok(bot_from_row(
                row.id,
                row.name,
                row.description,
                row.provider_id,
                row.model,
                row.system_prompt,
                row.tools,
                row.allow_inbound,
                row.context_window,
                row.created_s,
                row.updated_s,
              ))
            _ -> Error("no stored bot " <> id)
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    InsertBot(bot, reply) -> {
      let result =
        sql.insert_bot(
          state.db,
          bot.id,
          bot.name,
          bot.description,
          bot.provider_id,
          bot.model,
          // The '' sentinel writes NULL (default prompt) — the same
          // workaround as the provider envelope (insert_provider.sql).
          option.unwrap(bot.system_prompt, ""),
          // The toolset's two parameters (bots plan P2): the explicit
          // list ('{}' = chat-only) + the is-default flag that writes
          // NULL = resolve the current default at thread creation.
          option.unwrap(bot.tools, []),
          option.is_none(bot.tools),
          int.to_float(bot.created_at),
          // The inbound gate (bots plan P3a): the row's value verbatim
          // (creates always carry true; the seam writes full rows).
          bot.allow_inbound,
          // Context window ($11): 0 sentinel inserts NULL.
          option.unwrap(bot.context_window, 0),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    UpdateBot(bot, reply) -> {
      // Like update_provider: an empty match is a silent no-op by
      // design — the registry pre-checks existence in state.
      let result =
        sql.update_bot(
          state.db,
          bot.id,
          bot.name,
          bot.description,
          bot.provider_id,
          bot.model,
          option.unwrap(bot.system_prompt, ""),
          // Same two-parameter toolset scheme as the insert (P2).
          option.unwrap(bot.tools, []),
          option.is_none(bot.tools),
          // The merged row's inbound gate (bots plan P3a).
          bot.allow_inbound,
          // Context window ($10): 0 sentinel clears to NULL.
          option.unwrap(bot.context_window, 0),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    DeleteBot(id, reply) -> {
      let outcome =
        pog.transaction(state.db, fn(tx) {
          use ws_rows <- result.try(
            sql.tombstone_bot_workspaces(tx, id)
            |> result.map_error(query_error),
          )
          use _ <- result.try(
            sql.delete_bot(tx, id) |> result.map_error(query_error),
          )
          Ok(
            ws_rows.rows
            |> list.map(fn(row) {
              store.TombstonedWorkspace(
                id: row.id,
                root: row.root,
                rel_path: row.rel_path,
              )
            })
            |> list.sort(fn(a, b) { string.compare(a.id, b.id) }),
          )
        })
        |> result.map_error(transaction_error)
      process.send(reply, outcome)
      actor.continue(state)
    }

    CountBotsForProvider(id, reply) -> {
      let result =
        sql.count_bots_for_provider(state.db, id)
        |> result.map(fn(returned) {
          case returned.rows {
            [count] -> count.bots
            _ -> 0
          }
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    // ---- node rows (docs/plans/environments.md, Phase 2b) ----
    ListNodes(reply) -> {
      let result =
        sql.list_nodes(state.db)
        |> result.map(fn(returned) {
          returned.rows
          |> list.map(fn(row) {
            node_from_row(
              row.id,
              row.thread_id,
              row.name,
              row.token_hash,
              row.created_s,
              row.last_seen_s,
            )
          })
        })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    GetThreadNode(thread_id, name, reply) -> {
      // Empty result = unknown (thread, name); the caller decides (the
      // stateless verification path refuses a lookup that finds no
      // row). Scoped by BOTH: a row answers only for its own thread.
      let result = case sql.get_thread_node(state.db, thread_id, name) {
        Error(error) -> Error(query_error(error))
        Ok(pog.Returned(_, rows)) ->
          case rows {
            [row] ->
              Ok(node_from_row(
                row.id,
                row.thread_id,
                row.name,
                row.token_hash,
                row.created_s,
                row.last_seen_s,
              ))
            _ -> Error("no stored node " <> name <> " in thread " <> thread_id)
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }

    InsertNode(node, reply) -> {
      let result =
        sql.insert_node(
          state.db,
          node.id,
          node.thread_id,
          node.name,
          node.token_hash,
          int.to_float(node.created_at),
          // The 0 sentinel writes NULL (never connected) — see
          // insert_node.sql for the squirrel nullability rationale.
          option.unwrap(node.last_seen_at, 0),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    TouchNode(id, reply) -> {
      process.send(reply, update(sql.touch_node(state.db, id)))
      actor.continue(state)
    }

    DeleteNode(id, reply) -> {
      process.send(reply, update(sql.delete_node(state.db, id)))
      actor.continue(state)
    }

    ListNodeGrants(reply) -> {
      let result =
        sql.list_node_grants(state.db)
        |> result.map(fn(returned) { returned.rows |> list.map(grant_from_row) })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    InsertNodeGrant(grant, reply) -> {
      let result =
        sql.insert_node_grant(
          state.db,
          grant.id,
          grant.code_hash,
          // insert_node_grant.sql for the ''-sentinel rationale.
          option.unwrap(grant.thread_id, ""),
          int.to_float(grant.created_at),
          int.to_float(grant.expires_at),
          grant.use_count,
          // The 0 sentinel: a fresh grant has never been exchanged.
          option.unwrap(grant.last_used_at, 0),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }

    TouchNodeGrant(id, reply) -> {
      process.send(reply, update(sql.touch_node_grant(state.db, id)))
      actor.continue(state)
    }

    DeleteNodeGrant(id, reply) -> {
      process.send(reply, update(sql.delete_node_grant(state.db, id)))
      actor.continue(state)
    }

    DeleteExpiredNodeGrants(reply) -> {
      process.send(reply, update(sql.delete_expired_node_grants(state.db)))
      actor.continue(state)
    }
    DeleteIdleNodes(days, reply) -> {
      let deleted = case sql.delete_idle_nodes(state.db, days) {
        Ok(returned) -> Ok(list.map(returned.rows, fn(row) { row.name }))
        Error(error) -> Error(query_error(error))
      }
      process.send(reply, deleted)
      actor.continue(state)
    }

    ListDeletedWorkspaces(reply) -> {
      let result = case sql.list_deleted_workspaces(state.db) {
        Ok(returned) ->
          Ok(
            list.map(returned.rows, fn(row) {
              store.TombstonedWorkspace(
                id: row.id,
                root: row.root,
                rel_path: row.rel_path,
              )
            }),
          )
        Error(error) -> Error(query_error(error))
      }
      process.send(reply, result)
      actor.continue(state)
    }

    DeleteWorkspace(id, reply) -> {
      process.send(reply, update(sql.delete_workspace(state.db, id)))
      actor.continue(state)
    }

    InsertWorkspace(workspace, reply) -> {
      let result =
        sql.insert_workspace(
          state.db,
          workspace.id,
          store.workspace_kind_to_string(workspace.kind),
          workspace.root,
          workspace.rel_path,
          option.unwrap(workspace.thread_id, ""),
          option.unwrap(workspace.bot_id, ""),
          int.to_float(workspace.created_at),
          option.unwrap(workspace.last_used_at, 0),
          option.unwrap(workspace.deleted_at, 0),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(query_error)
      process.send(reply, result)
      actor.continue(state)
    }
  }
}

type Watermark {
  Known(count: Int)
  Dropped
  Pending
}

/// The write-behind lane: append the transcript's unpersisted delta in seq
/// order, then bump recency + the denormalized count. Any row failure
/// keeps the old persisted length so the next commit retries the delta
/// (idempotent: duplicate seqs are skipped in SQL).
fn handle_commit(
  state: State,
  id: String,
  tr: Transcript,
) -> actor.Next(State, Msg) {
  case ensure_persisted(state, id) {
    #(next_state, Dropped) | #(next_state, Pending) ->
      actor.continue(next_state)
    #(state, Known(already)) -> {
      case store.has_delta(tr, already) {
        False -> actor.continue(state)
        True -> {
          let #(base_seq, rows) = store.transcript_delta(tr, already)
          let total = transcript.length(tr)
          let outcome =
            list.index_fold(rows, Ok(Nil), fn(acc, row, index) {
              case acc {
                Error(error) -> Error(error)
                Ok(_) ->
                  append_row(state.db, id, base_seq + index, row)
                  |> result.map(fn(_) { Nil })
                  |> result.map_error(query_error)
              }
            })
          case outcome {
            Ok(_) -> {
              // Absolute values: replaying this bump is a no-op.
              let _ =
                sql.bump_activity(state.db, total, id)
                |> result.map_error(query_error)
              actor.continue(
                State(
                  ..state,
                  persisted: dict.insert(state.persisted, id, total),
                ),
              )
            }
            Error(error) -> {
              log_store_error("commit " <> id, error)
              actor.continue(state)
            }
          }
        }
      }
    }
  }
}

/// Atomic compaction persistence (context-compaction plan §6.3): runs inside
/// ONE `pog.transaction` that idempotently flushes any uncommitted
/// `thread_message` delta rows up to `tr`, inserts the `thread_compaction`
/// row, and updates `thread.last_context_tokens` when `after_tokens` is set.
/// If any step fails, the entire transaction rolls back and `state.persisted`
/// stays untouched.
fn handle_record_compaction(
  state: State,
  id: String,
  tr: Transcript,
  checkpoint: transcript.Compaction,
) -> actor.Next(State, Msg) {
  case ensure_persisted(state, id) {
    #(next_state, Dropped) | #(next_state, Pending) ->
      actor.continue(next_state)
    #(state, Known(already)) -> {
      let total = transcript.length(tr)
      let outcome =
        pog.transaction(state.db, fn(tx) {
          use Nil <- result.try(case store.has_delta(tr, already) {
            False -> Ok(Nil)
            True -> {
              let #(base_seq, rows) = store.transcript_delta(tr, already)
              use Nil <- result.try(
                list.index_fold(rows, Ok(Nil), fn(acc, row, index) {
                  case acc {
                    Error(error) -> Error(error)
                    Ok(_) ->
                      append_row(tx, id, base_seq + index, row)
                      |> result.map(fn(_) { Nil })
                      |> result.map_error(query_error)
                  }
                }),
              )
              sql.bump_activity(tx, total, id)
              |> result.map(fn(_) { Nil })
              |> result.map_error(query_error)
            }
          })
          use Nil <- result.try(
            sql.insert_compaction(
              tx,
              id,
              checkpoint.cutoff_index,
              checkpoint.summary,
              option.unwrap(checkpoint.roster_snapshot, ""),
              option.unwrap(checkpoint.focus, ""),
              transcript.trigger_to_string(checkpoint.trigger),
              option.unwrap(checkpoint.before_tokens, -1),
              option.unwrap(checkpoint.after_tokens, -1),
              checkpoint.created_at,
            )
            |> result.map(fn(_) { Nil })
            |> result.map_error(query_error),
          )
          case checkpoint.after_tokens {
            Some(after_tokens) if after_tokens >= 0 ->
              sql.set_last_context_tokens(tx, after_tokens, id)
              |> result.map(fn(_) { Nil })
              |> result.map_error(query_error)
            _ -> Ok(Nil)
          }
        })
        |> result.map_error(transaction_error)
      case outcome {
        Ok(_) ->
          actor.continue(
            State(
              ..state,
              persisted: dict.insert(
                state.persisted,
                id,
                int.max(already, total),
              ),
            ),
          )
        Error(error) -> {
          log_store_error("record_compaction " <> id, error)
          actor.continue(state)
        }
      }
    }
  }
}

/// Resolve the persisted length for `id`, re-deriving it from the database
/// when unknown (first commit after this actor restarted, or a thread
/// created before it existed). Threads with no row at all are marked
/// dropped (`-1` in `state.persisted`) so their commit lane stays quiet
/// instead of spamming foreign-key errors; transient query errors return
/// `Pending` without poisoning the cache so the next commit retries cleanly.
fn ensure_persisted(state: State, id: String) -> #(State, Watermark) {
  case dict.get(state.persisted, id) {
    Ok(already) if already < 0 -> #(state, Dropped)
    Ok(already) -> #(state, Known(already))
    Error(_) ->
      case sql.get_thread(state.db, id) {
        // The thread's denormalized message_count is the safe source:
        // it only ever advances after the corresponding rows were
        // written, so it can lag but never lead — a lagging value just
        // re-emits rows that `on conflict do nothing` skips.
        Ok(pog.Returned(_, [row])) -> {
          let next_state =
            State(
              ..state,
              persisted: dict.insert(state.persisted, id, row.message_count),
            )
          #(next_state, Known(row.message_count))
        }
        Ok(_) -> {
          log_store_error(
            "commit " <> id,
            "no stored thread row — dropping its write-behind commits",
          )
          #(
            State(..state, persisted: dict.insert(state.persisted, id, -1)),
            Dropped,
          )
        }
        Error(error) -> {
          log_store_error("commit " <> id, query_error(error))
          #(state, Pending)
        }
      }
  }
}

fn append_row(
  db: pog.Connection,
  id: String,
  seq: Int,
  row: store.MessageRow,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  // The stamp travels as epoch seconds; the queries' `nullif($n, 0)`
  // sentinel turns the unstamped 0 back into NULL (see the append_*.sql
  // files). The author travels as text the same way: '' (a human send's
  // None) turns back into NULL via the query's nullif sentinel.
  case row {
    store.UserRow(content, author, hop_depth, at) ->
      sql.append_plain_message(
        db,
        id,
        seq,
        "user",
        content,
        "",
        at_param(at),
        option.unwrap(author, ""),
        hop_depth,
      )
    store.AssistantRow(content, reasoning, at) ->
      sql.append_plain_message(
        db,
        id,
        seq,
        "assistant",
        content,
        option.unwrap(reasoning, ""),
        at_param(at),
        "",
        0,
      )
    store.ToolCallRow(content, call_id, name, arguments, reasoning, at) ->
      sql.append_tool_call(
        db,
        id,
        seq,
        content,
        call_id,
        name,
        arguments,
        option.unwrap(reasoning, ""),
        at_param(at),
      )
    store.ToolResultRow(call_id, name, ok, content, at) ->
      sql.append_tool_result(
        db,
        id,
        seq,
        content,
        call_id,
        name,
        ok,
        at_param(at),
      )
  }
}

fn at_param(at: option.Option(Int)) -> Int {
  option.unwrap(at, 0)
}

/// Metadata write-through outcome: errors are logged and surfaced, never
/// fatal — the in-memory record stays authoritative while live.
fn update(
  query: Result(pog.Returned(Nil), pog.QueryError),
) -> Result(Nil, String) {
  case query {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      let error = query_error(error)
      log_store_error("metadata write-through", error)
      Error(error)
    }
  }
}

fn log_store_error(context: String, error: String) -> Nil {
  log.error("store", "store operation failed", [
    log.str("context", context),
    log.str("error", error),
  ])
}

fn query_error(error: pog.QueryError) -> String {
  case error {
    pog.ConstraintViolated(message, constraint, detail) ->
      message <> " (" <> constraint <> "): " <> detail
    pog.PostgresqlError(_, name, message) -> name <> ": " <> message
    pog.UnexpectedArgumentCount(expected, got) ->
      "argument count mismatch: expected "
      <> int.to_string(expected)
      <> ", got "
      <> int.to_string(got)
    pog.UnexpectedArgumentType(expected, got) ->
      "argument type mismatch: expected " <> expected <> ", got " <> got
    pog.UnexpectedResultType(_) -> "unexpected result type"
    pog.QueryTimeout -> "query timeout"
    pog.ConnectionUnavailable -> "connection unavailable"
  }
}

fn stored_summary_from_row(
  row: sql.ListSummariesRow,
) -> Result(store.StoredSummary, String) {
  case store.decode_toolset(row.toolset) {
    Error(e) -> Error(e)
    Ok(entries) ->
      Ok(store.StoredSummary(
        id: row.id,
        provider_id: row.provider_id,
        model: row.model,
        meta: thread.ThreadMeta(
          title: row.title,
          title_source: title_source(row.title_source),
          pinned: row.pinned,
          archived: row.archived,
          tags: row.tags,
          tags_manual: row.tags_manual,
          tags_source: tags_source(row.tags_source),
          // Provenance pointer (bots plan P1): NULL = created without a bot.
          bot_id: row.bot_id,
          // The parent link (bot-channels plan, #123): NULL = an ordinary
          // thread; Some = a bot channel hanging off its parent.
          parent_thread_id: row.parent_thread_id,
          created_at: row.created_s,
        ),
        // The frozen toolset manifest (plugin-api plan Phase 2): a
        // dormant thread rehydrates its runner bundle from these
        // entries.
        toolset: entries,
        workspace_root: row.workspace_root,
        workspaces: thread_workspaces_from_row(
          row.workspace_id,
          row.workspace_rel_path,
          row.tmp_workspace_id,
          row.tmp_rel_path,
        ),
        roster: option.None,
        last_active_at: row.last_active_s,
        // The column already counts the system prompt (Phase 1
        // semantics).
        message_count: row.message_count,
        context_window: row.context_window,
        last_context_tokens: row.last_context_tokens,
      ))
  }
}

/// A stored bot row from either query shape (get/list select the same
/// columns). Kept as one helper so the two row types cannot drift.
fn bot_from_row(
  id: String,
  name: String,
  description: String,
  provider_id: String,
  model: String,
  system_prompt: option.Option(String),
  tools: option.Option(List(String)),
  allow_inbound: Bool,
  context_window: option.Option(Int),
  created_s: Int,
  updated_s: Int,
) -> store.StoredBot {
  bot.Bot(
    id: id,
    name: name,
    description: description,
    provider_id: provider_id,
    model: model,
    system_prompt: system_prompt,
    // NULL = the current default at thread-create time (P2's live
    // template half); '{}' decodes as Some([]).
    tools: tools,
    // The inbound gate (bots plan P3a).
    allow_inbound: allow_inbound,
    context_window: context_window,
    created_at: created_s,
    updated_at: updated_s,
  )
}

/// A stored node row from either query shape (get-by-name / list select
/// the same columns). Kept as one helper so the two row types cannot
/// drift. `last_seen_s = 0` is the store's NULL sentinel (never
/// connected) → `None`, matching `node.Node`.
fn node_from_row(
  id: String,
  thread_id: String,
  name: String,
  token_hash: String,
  created_s: Int,
  last_seen_s: Int,
) -> store.StoredNode {
  node.Node(
    id: id,
    thread_id: thread_id,
    name: name,
    token_hash: token_hash,
    created_at: created_s,
    last_seen_at: case last_seen_s {
      0 -> option.None
      stamp -> option.Some(stamp)
    },
  )
}

/// A stored grant row from the list select. `last_used_s = 0` is the
/// same NULL sentinel as `node_from_row` (never exchanged) → `None`;
/// `thread_id` is squirrel-decoded nullable text, passed through
/// verbatim (NULL = the reserved future unpinned shape).
fn grant_from_row(row: sql.ListNodeGrantsRow) -> store.StoredGrant {
  node.Grant(
    id: row.id,
    code_hash: row.code_hash,
    thread_id: row.thread_id,
    created_at: row.created_s,
    expires_at: row.expires_s,
    use_count: row.use_count,
    last_used_at: case row.last_used_s {
      0 -> option.None
      stamp -> option.Some(stamp)
    },
  )
}

fn stored_provider_from_list_row(
  row: sql.ListProvidersRow,
) -> store.StoredProvider {
  store.StoredProvider(
    id: row.id,
    name: row.name,
    base_url: row.base_url,
    api_key_encrypted: row.api_key_encrypted,
    key_version: row.key_version,
    dialect: row.dialect,
    enabled: row.enabled,
    created_at: row.created_s,
    updated_at: row.updated_s,
  )
}

fn stored_provider_from_row(row: sql.GetProviderRow) -> store.StoredProvider {
  store.StoredProvider(
    id: row.id,
    name: row.name,
    base_url: row.base_url,
    api_key_encrypted: row.api_key_encrypted,
    key_version: row.key_version,
    dialect: row.dialect,
    enabled: row.enabled,
    created_at: row.created_s,
    updated_at: row.updated_s,
  )
}

/// Bind a key envelope for the write queries: Postgres exposes no
/// parameter nullability, so keyless (`None`) travels as the `''`
/// sentinel that the SQL turns back into NULL via `nullif`
/// (see `insert_provider.sql` / `update_provider.sql`).
fn key_param(key: option.Option(BitArray)) -> BitArray {
  option.unwrap(key, <<>>)
}

fn message_row_from_row(row: sql.LoadMessagesRow) -> store.MessageRow {
  let name = row.tool_name |> option.unwrap("tool")
  // The stamp rides the 0 sentinel (see load_messages.sql): 0 decodes
  // back to None, so unstamped rows — continuation rows of a multi-call
  // assistant message — render without a timestamp.
  let at = case row.created_s {
    0 -> None
    seconds -> Some(seconds)
  }
  case row.role, row.tool_call_id {
    "user", _ -> store.UserRow(row.content, row.author, row.hop_depth, at)
    "assistant", Some(call_id) ->
      store.ToolCallRow(
        content: row.content,
        call_id: call_id,
        name: name,
        arguments: row.tool_args |> option.unwrap(""),
        reasoning: row.reasoning,
        at: at,
      )
    "assistant", None -> store.AssistantRow(row.content, row.reasoning, at)
    "tool", Some(call_id) ->
      store.ToolResultRow(
        call_id: call_id,
        name: name,
        ok: row.tool_ok |> option.unwrap(True),
        content: row.content,
        at: at,
      )
    "tool", None ->
      store.ToolResultRow(
        call_id: "",
        name: name,
        ok: row.tool_ok |> option.unwrap(True),
        content: row.content,
        at: at,
      )
    _, _ -> store.AssistantRow(row.content, row.reasoning, at)
  }
}

fn thread_workspaces_from_row(
  workspace_id: option.Option(String),
  workspace_rel_path: String,
  tmp_workspace_id: option.Option(String),
  tmp_rel_path: String,
) -> option.Option(store.ThreadWorkspaces) {
  case workspace_id, workspace_rel_path {
    Some(id), rel if rel != "" ->
      Some(
        store.ThreadWorkspaces(
          workspace_id: id,
          rel_path: rel,
          tmp_id: case tmp_workspace_id, tmp_rel_path {
            Some(tid), trel if trel != "" -> Some(tid)
            _, _ -> None
          },
          tmp_rel_path: case tmp_workspace_id, tmp_rel_path {
            Some(_), trel if trel != "" -> Some(trel)
            _, _ -> None
          },
        ),
      )
    _, _ -> None
  }
}

fn transaction_error(error: pog.TransactionError(String)) -> String {
  case error {
    pog.TransactionQueryError(query_err) -> query_error(query_err)
    pog.TransactionRolledBack(message) -> message
  }
}

fn title_source(text: String) -> thread.TitleSource {
  case text {
    "manual" -> thread.ManualTitle
    _ -> thread.AutoTitle
  }
}

fn title_source_text(source: thread.TitleSource) -> String {
  case source {
    thread.ManualTitle -> "manual"
    thread.AutoTitle -> "auto"
  }
}

/// `thread.tags_source` ⇄ the schema's text values ('auto' | 'manual',
/// mirroring `title_source`). The column is written exclusively as the
/// DEFAULT 'auto' (insert) or 'manual' (`set_tags.sql`); anything
/// unexpected reads as `AutoTags` — the same defensive default as
/// `title_source`.
fn tags_source(text: String) -> thread.TagsSource {
  case text {
    "manual" -> thread.ManualTags
    _ -> thread.AutoTags
  }
}

// ---------------------------------------------------------------------------
// Boot sweeps (docs/plans/tui-pairing.md, hygiene)
// ---------------------------------------------------------------------------

/// Boot hygiene, run from `main` after the supervision tree is up, through
/// the SEAM (never inside the store actor's own initialiser — an
/// `actor.call` to self would block the initialiser on the actor it is
/// still building):
///
/// - expired pairing grants are pure garbage (the plaintext died at
///   mint; the row's only remaining purpose was refusing codes);
/// - nodes idle past `NEXUS_NODE_IDLE_DAYS` lose their credential — a
///   crashed TUI has a week by default to relaunch and re-stamp
///   last_seen; `0` disables the sweep entirely.
///
/// Both are logged-and-ignored: a failure deletes nothing and the next
/// boot retries — the same posture as the registry's prune_never_used
/// sweep. Ordering is unconstrained (unlike the thread prune, no
/// hydration depends on these rows being gone first), so running them
/// once the tree is already serving costs nothing but a moment of
/// latency-free garbage collection.
pub fn boot_sweeps(cfg: Config, db: store.Store) -> Nil {
  case db.delete_expired_node_grants() {
    Ok(_) -> log.info("store", "boot sweep deleted expired node grants", [])
    Error(error) ->
      log.error("store", "boot sweep failed", [
        log.str("sweep", "expired_node_grants"),
        log.str("error", error),
      ])
  }
  case cfg.node_idle_days {
    0 ->
      log.info("store", "boot sweep disabled", [
        log.str("sweep", "idle_nodes"),
        log.str("reason", "NEXUS_NODE_IDLE_DAYS=0"),
      ])
    days ->
      case db.delete_idle_nodes(days) {
        Ok([]) ->
          log.info("store", "boot sweep found no idle nodes", [
            log.int("idle_days", days),
          ])
        Ok(names) ->
          log.info("store", "boot sweep deleted idle nodes", [
            log.int("idle_days", days),
            log.int("count", list.length(names)),
            log.str("nodes", string.join(list.take(names, 100), ",")),
          ])
        Error(error) ->
          log.error("store", "boot sweep failed", [
            log.str("sweep", "idle_nodes"),
            log.str("error", error),
          ])
      }
  }
  workspace_gc.sweep(db)
}
