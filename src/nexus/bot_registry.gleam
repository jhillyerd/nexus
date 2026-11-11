//// The bot registry (docs/plans/bots.md, Phase 1 — issue #74): the
//// small actor that owns bot rows between the store and everything
//// else. The provider-registry pattern MINUS its security machinery:
//// bots carry no key material, so there is no envelope to
//// decrypt-validate at boot, no resolve memo, and no network call ever
//// runs inside it (nothing `ListModels`-like to quarantine).
////
//// State is the whole table loaded once at start — an unreachable
//// store fails boot loudly, exactly like the provider registry — with
//// write-through CRUD on top and the in-state duplicate-name pre-check
//// answering before the `bot_name` unique index (the cross-instance
//// backstop, surfaced as `StoreFailed`). Unlike providers there is
//// nothing to validate at load: a bot row cannot be invalid at rest,
//// and a stale model alias is legitimate (thread create re-validates
//// it against the provider's LIVE list and refuses dead ones).
////
//// **No registry-to-registry edges** (ARCHITECTURE.md §8): this actor
//// never resolves providers — `bot.provider_id` existence is validated
//// by the CALLERS (web/UI) against the provider registry they already
//// hold, with `ON DELETE RESTRICT` as the backstop. Symmetrically, the
//// provider registry's delete guard counts bots through the STORE
//// (`count_bots_for_provider`), never through a call in here.
//// Create-from-bot orchestration lives with its callers too, in
//// `nexus/thread_create` — the one creation path web and the UI
//// runtime share.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import nexus/bot
import nexus/store.{type Store, type StoredBot}
import nexus/timing

/// Closed error vocabulary for callers (the HTTP layer maps it onto
/// 400/404/409/502, exactly like `provider_registry.RegistryError`).
/// Fixed strings only.
pub type RegistryError {
  /// No bot with that id.
  Unknown
  InvalidName
  InvalidModel
  /// Create/rename onto an existing bot's name (unique).
  DuplicateName
  /// The store refused or failed; carries the seam's sanitized text.
  StoreFailed(String)
}

/// Fixed human-readable error text.
pub fn describe(error: RegistryError) -> String {
  case error {
    Unknown -> "unknown bot"
    InvalidName -> bot.describe(bot.InvalidName)
    InvalidModel -> bot.describe(bot.InvalidModel)
    DuplicateName -> "bot name already exists"
    StoreFailed(reason) -> reason
  }
}

pub type Msg {
  /// All bots, name-then-id sorted (the settings list's order).
  List(reply: Subject(Result(List(StoredBot), RegistryError)))
  /// One bot.
  Get(id: String, reply: Subject(Result(StoredBot, RegistryError)))
  /// Create a bot. `provider_id` is NOT validated here — the caller
  /// checks it against the provider registry (no cross-registry edge);
  /// the FK is the backstop.
  Create(
    params: bot.BotParams,
    reply: Subject(Result(StoredBot, RegistryError)),
  )
  /// PATCH: present fields replace, absent keep (see `bot.BotUpdate`'s
  /// two field classes). Existence is pre-checked in state because the
  /// SQL's empty-match update is a deliberate no-op.
  Update(
    id: String,
    patch: bot.BotUpdate,
    reply: Subject(Result(StoredBot, RegistryError)),
  )
  /// Hard delete. No guard: `thread.bot_id` is ON DELETE SET NULL
  /// (provenance only), so deleting a bot orphans nothing.
  Delete(id: String, reply: Subject(Result(Nil, RegistryError)))
}

type State {
  State(
    /// The loaded table, by id — the actor's source of truth for
    /// existence and the duplicate-name pre-check.
    rows: Dict(String, StoredBot),
    /// ID minting only (`b<N>`), seeded past every stored id at boot.
    counter: Int,
    store: Store,
  )
}

/// Start the registry actor (boot and tests). Boot semantics: the
/// initialiser loads the whole table — an unreachable store fails start
/// (and with the OneForAll root, the whole boot) loudly.
pub fn start(
  persistence: Store,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      case persistence.list_bots() {
        Error(error) -> Error("bot store unreachable: " <> error)
        Ok(rows) ->
          actor.initialised(State(
            rows: rows_by_id(rows),
            counter: max_bot_counter(rows),
            store: persistence,
          ))
          |> actor.returning(self)
          |> actor.selecting(process.new_selector() |> process.select(self))
          |> Ok
      }
    })
    |> actor.on_message(handle)
    |> actor.named(name)
  actor.start(builder)
}

fn rows_by_id(rows: List(StoredBot)) -> Dict(String, StoredBot) {
  list.fold(rows, dict.new(), fn(rows, row) { dict.insert(rows, row.id, row) })
}

/// The highest numeric suffix among `b<N>`-shaped ids, so freshly
/// minted ids never collide with stored bots (same scheme as the
/// provider registry's `p<N>`).
fn max_bot_counter(rows: List(StoredBot)) -> Int {
  rows
  |> list.fold(0, fn(max, row) {
    case string.split(row.id, on: "b") {
      ["", suffix] ->
        case int.parse(suffix) {
          Ok(n) -> int.max(max, n)
          Error(_) -> max
        }
      _ -> max
    }
  })
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    List(reply) -> {
      let bots =
        state.rows
        |> dict.values
        |> list.sort(fn(a, b) {
          case string.compare(a.name, b.name) {
            order.Eq -> string.compare(a.id, b.id)
            other -> other
          }
        })
      process.send(reply, Ok(bots))
      actor.continue(state)
    }

    Get(id, reply) ->
      case dict.get(state.rows, id) {
        Ok(row) -> {
          process.send(reply, Ok(row))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
      }

    Create(params, reply) -> {
      let counter = state.counter + 1
      let id = "b" <> int.to_string(counter)
      case create_row(state, id, params) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(row) ->
          case state.store.insert_bot(row) {
            Error(error) -> {
              // bot_pkey / bot_name are the multi-instance backstop;
              // the registry's own pre-check covers the normal path.
              process.send(reply, Error(StoreFailed(error)))
              actor.continue(state)
            }
            Ok(Nil) -> {
              process.send(reply, Ok(row))
              actor.continue(
                State(
                  ..state,
                  rows: dict.insert(state.rows, id, row),
                  counter: counter,
                ),
              )
            }
          }
      }
    }

    Update(id, patch, reply) ->
      case dict.get(state.rows, id) {
        Error(_) -> {
          // Existence is pre-checked HERE because the SQL's empty-match
          // update is a deliberate no-op — without this a PATCH of a
          // deleted id would silently "succeed" (same guard as the
          // provider registry).
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(row) ->
          case update_row(state, row, patch) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(updated) ->
              case state.store.update_bot(updated) {
                Error(error) -> {
                  process.send(reply, Error(StoreFailed(error)))
                  actor.continue(state)
                }
                Ok(Nil) -> {
                  process.send(reply, Ok(updated))
                  actor.continue(
                    State(..state, rows: dict.insert(state.rows, id, updated)),
                  )
                }
              }
          }
      }

    Delete(id, reply) ->
      case dict.get(state.rows, id) {
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(_) ->
          case state.store.delete_bot(id) {
            Error(error) -> {
              process.send(reply, Error(StoreFailed(error)))
              actor.continue(state)
            }
            Ok(Nil) -> {
              // No re-check race to bridge: threads carry ON DELETE SET
              // NULL provenance, so nothing can pin a bot.
              process.send(reply, Ok(Nil))
              actor.continue(State(..state, rows: dict.delete(state.rows, id)))
            }
          }
      }
  }
}

/// Validate + build a new row (id pre-minted by the caller's counter).
fn create_row(
  state: State,
  id: String,
  params: bot.BotParams,
) -> Result(StoredBot, RegistryError) {
  use name <- result.try(
    bot.validate_name(params.name) |> result.replace_error(InvalidName),
  )
  use model <- result.try(
    bot.validate_model(params.model) |> result.replace_error(InvalidModel),
  )
  // Uniqueness pre-check against loaded state (the schema's UNIQUE is
  // the cross-instance backstop, surfaced as StoreFailed).
  case name_taken(state.rows, id, name) {
    True -> Error(DuplicateName)
    False -> Ok(bot.to_row(params, id, name, model, timing.wall_now_s()))
  }
}

/// Validate + merge a PATCH onto a row: the merged row is a FULL row
/// (the store's update is a plain replace — no gated fields).
fn update_row(
  state: State,
  row: StoredBot,
  patch: bot.BotUpdate,
) -> Result(StoredBot, RegistryError) {
  use name <- result.try(
    bot.validate_name(option_blank_or(patch.name, row.name))
    |> result.replace_error(InvalidName),
  )
  use model <- result.try(
    bot.validate_model(option_blank_or(patch.model, row.model))
    |> result.replace_error(InvalidModel),
  )
  case name_taken(state.rows, row.id, name) {
    True -> Error(DuplicateName)
    False -> {
      let merged = bot.apply_update(row, patch, timing.wall_now_s())
      Ok(bot.Bot(..merged, name: name, model: model))
    }
  }
}

/// The PATCH keep-rule for identity fields: a blank present value keeps
/// the stored one (a prefilled form's untouched field resubmits the
/// stored value), so validation sees the EFFECTIVE value.
fn option_blank_or(field: Option(String), fallback: String) -> String {
  case field {
    Some(value) ->
      case string.trim(value) {
        "" -> fallback
        _ -> value
      }
    None -> fallback
  }
}

/// True when some OTHER loaded bot already owns `name`.
fn name_taken(
  rows: Dict(String, StoredBot),
  own_id: String,
  name: String,
) -> Bool {
  list.any(dict.values(rows), fn(row) { row.id != own_id && row.name == name })
}

// ---------------------------------------------------------------------------
// Client helpers (boot wiring, the HTTP layer, the UI bridge)
// ---------------------------------------------------------------------------

/// CRUD calls wait on a store round-trip inside the actor: like the
/// provider registry, the budget sits ABOVE the seam's own 15s call
/// budget so a successful-but-slow store write still gets its reply
/// through. Reads answer from actor state, so they stay tight.
const crud_call_timeout_ms = 20_000

/// All bots, name-then-id sorted.
pub fn list_bots(
  registry: Subject(Msg),
) -> Result(List(StoredBot), RegistryError) {
  actor.call(registry, 5000, List)
}

/// One bot by id.
pub fn get_bot(
  registry: Subject(Msg),
  id: String,
) -> Result(StoredBot, RegistryError) {
  actor.call(registry, 5000, fn(reply) { Get(id, reply) })
}

/// Create a bot. The caller validates `provider_id` against the
/// provider registry; the FK is the backstop.
pub fn create_bot(
  registry: Subject(Msg),
  params: bot.BotParams,
) -> Result(StoredBot, RegistryError) {
  actor.call(registry, crud_call_timeout_ms, fn(reply) { Create(params, reply) })
}

/// PATCH a bot: present fields replace, absent keep.
pub fn update_bot(
  registry: Subject(Msg),
  id: String,
  patch: bot.BotUpdate,
) -> Result(StoredBot, RegistryError) {
  actor.call(registry, crud_call_timeout_ms, fn(reply) {
    Update(id, patch, reply)
  })
}

/// Hard delete (unguarded: threads carry SET-NULL provenance).
pub fn delete_bot(
  registry: Subject(Msg),
  id: String,
) -> Result(Nil, RegistryError) {
  actor.call(registry, crud_call_timeout_ms, fn(reply) { Delete(id, reply) })
}
