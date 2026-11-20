//// The bot registry (docs/plans/completed/bots.md, Phase 1 — issue #74): the
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
//// and a stale model alias is legitimate (aliases are not validated
//// at thread create either — a dead alias fails its first turn at
//// stream time; see `nexus/thread_create`).
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

/// The tool-catalog seam (bots plan P2): a submitted name list → the
/// normalized list, or a reason string when some name is not in the
/// catalog. Boot wires `tools.by_names_with(cfg, providers, _)` — the
/// compiled catalog ∪ the boot-built provider table — validation
/// against the SAME registry that builds the schemas — so this actor
/// stays decoupled from the config and the tool modules (the same
/// injected-fn pattern as the thread registry's `ResolveProvider`).
pub type ValidateTools =
  fn(List(String)) -> Result(List(String), String)

/// The pinnable tool catalog (issue #121): every name a submitted
/// toolset may contain, for the bot forms' checkbox list, plus the MCP
/// servers whose live listing failed (their tools are display-omitted,
/// never refused). A plain structural value on purpose — this actor
/// stays decoupled from the tool modules, so boot's injected closure
/// (see `CatalogFn`) builds it from the same ONE provider/foreign
/// values the validate seam checks against.
pub type ToolCatalog {
  ToolCatalog(names: List(String), unavailable: List(String))
}

/// The catalog enumeration seam: boot wires
/// `tools.catalog(providers, foreign)` wrapped into a `ToolCatalog` —
/// the same ONE values the validate closure captured. Tests pass a
/// canned value (the ask may block on live per-server asks inside the
/// closure, so tests never wire a live one).
pub type CatalogFn =
  fn() -> ToolCatalog

/// Closed error vocabulary for callers (the HTTP layer maps it onto
/// 400/404/409/502, exactly like `provider_registry.RegistryError`).
/// Fixed strings only.
pub type RegistryError {
  /// No bot with that id.
  Unknown
  InvalidName
  /// The reserved roster-message author name (environments plan
  /// Phase 1) — surfaced separately from InvalidName so the message
  /// names the actual restriction (cubic PR review).
  ReservedName
  InvalidModel
  /// Create/rename onto an existing bot's name (unique).
  DuplicateName
  /// A submitted toolset was structurally malformed (all-blank) or
  /// named a tool outside the compiled-in catalog (bots plan P2). The
  /// reason is the structural text or the catalog checker's ("unknown
  /// tool name: …").
  InvalidTools(reason: String)
  /// The store refused or failed; carries the seam's sanitized text.
  StoreFailed(String)
}

/// Fixed human-readable error text.
pub fn describe(error: RegistryError) -> String {
  case error {
    Unknown -> "unknown bot"
    InvalidName -> bot.describe(bot.InvalidName)
    ReservedName -> bot.describe(bot.ReservedName)
    InvalidModel -> bot.describe(bot.InvalidModel)
    DuplicateName -> "bot name already exists (names are case-insensitive)"
    InvalidTools(reason) -> reason
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
  /// The pinnable tool catalog (issue #121) — the same boot-injected
  /// truth the validate seam checks against, enumerated for the bot
  /// forms' checkbox list. The closure's live per-server asks must not
  /// stall unrelated bot CRUD, so the actor does NOT run it inline: it
  /// spawns an unlinked worker and the result comes back through
  /// `CatalogDone`, replying to this ask's caller. The caller's
  /// timeout (generous, fixed) is the bound if the worker dies.
  /// (`Catalog`, not `ToolCatalog` — the type constructor below owns
  /// that name.)
  Catalog(reply: Subject(ToolCatalog))
  /// Internal: the catalog worker's result, routed back through the
  /// actor to reply to the ask it belongs to. Harmless if forged — it
  /// just answers a catalog.
  CatalogDone(reply: Subject(ToolCatalog), catalog: ToolCatalog)
}

type State {
  State(
    /// The loaded table, by id — the actor's source of truth for
    /// existence and the duplicate-name pre-check.
    rows: Dict(String, StoredBot),
    /// ID minting only (`b<N>`), seeded past every stored id at boot.
    counter: Int,
    store: Store,
    /// The catalog check every submitted toolset passes through (see
    /// `ValidateTools`).
    validate_tools: ValidateTools,
    /// The pinnable-catalog enumeration (see `CatalogFn`, issue #121).
    tool_catalog: CatalogFn,
    /// The actor's own subject — the catalog worker routes its result
    /// back through here (see the `Catalog` arm).
    self: Subject(Msg),
  )
}

/// Start the registry actor (boot and tests). Boot semantics: the
/// initialiser loads the whole table — an unreachable store fails start
/// (and with the OneForAll root, the whole boot) loudly. `validate_tools`
/// is the catalog check (boot wires `tools.by_names_with(cfg,
/// providers, _)`; tests pass a pure list). `tool_catalog` enumerates
/// the same catalog for the forms' picker (boot wires `tools.catalog`;
/// tests pass a canned value).
pub fn start(
  persistence: Store,
  name: process.Name(Msg),
  validate_tools: ValidateTools,
  tool_catalog: CatalogFn,
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
            validate_tools: validate_tools,
            tool_catalog: tool_catalog,
            self: self,
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
      // The counter is seeded past the stored table at BOOT only, but
      // another nexus over the SAME store (the e2e rig runs three
      // instances on one database) mints with its own counter, and its
      // rows never reach this actor's memory — minting from the boot
      // seed alone collides on bot_pkey and answers StoreFailed. Every
      // create therefore re-reads the table and heals BOTH halves from
      // it: the counter re-seeds past every stored id (no id minted
      // elsewhere is minted again here) and the rows dict absorbs the
      // externally-minted rows (List and the duplicate-name pre-check
      // stop serving a stale view). One rare-path read; the store's
      // pkey/name constraints stay the last-resort backstop.
      let #(rows, counter) = case state.store.list_bots() {
        Ok(fresh) -> #(
          list.fold(fresh, state.rows, fn(rows, row) {
            dict.insert(rows, row.id, row)
          }),
          int.max(state.counter, max_bot_counter(fresh)),
        )
        Error(_) -> #(state.rows, state.counter)
      }
      let counter = counter + 1
      let id = "b" <> int.to_string(counter)
      // The pre-check reads the HEALED rows: a name minted by another
      // instance answers DuplicateName (409), not the store's
      // unique-name backstop via StoreFailed (502).
      case create_row(State(..state, rows: rows), id, params) {
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
                  rows: dict.insert(rows, id, row),
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

    Catalog(reply) -> {
      // OFF the actor loop: the closure's live per-server asks (one
      // freeze budget + slack, concurrent) must not stall unrelated
      // bot CRUD behind them — the registry actor replies within
      // microseconds and keeps serving. The unlinked worker runs the
      // closure and routes the result back through `CatalogDone`; if
      // the worker dies, no reply lands and the CALLER's timeout
      // fires (the UI turns that into its degraded field).
      process.spawn_unlinked(fn() {
        let catalog = state.tool_catalog()
        process.send(state.self, CatalogDone(reply, catalog))
      })
      actor.continue(state)
    }

    CatalogDone(reply, catalog) -> {
      process.send(reply, catalog)
      actor.continue(state)
    }
  }
}

/// Validate + build a new row (id pre-minted by the caller's counter).
fn create_row(
  state: State,
  id: String,
  params: bot.BotParams,
) -> Result(StoredBot, RegistryError) {
  use name <- result.try(case bot.validate_name(params.name) {
    Ok(name) -> Ok(name)
    Error(bot.InvalidName) -> Error(InvalidName)
    Error(bot.ReservedName) -> Error(ReservedName)
    // bot.BotError's remaining arms cannot escape validate_name (a
    // name-only check); the arm keeps the match total.
    Error(_) -> Error(InvalidName)
  })
  use model <- result.try(
    bot.validate_model(params.model) |> result.replace_error(InvalidModel),
  )
  use tools <- result.try(validate_tools(state, params.tools))
  let params = bot.BotParams(..params, tools: tools)
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
  // A present toolset is normalized + catalog-checked BEFORE the merge
  // (apply_update's `Some` replaces verbatim, so the patch must already
  // carry the effective list).
  use patch <- result.try(case patch.tools {
    Some(tools) -> {
      use tools <- result.try(validate_tools(state, tools))
      Ok(bot.BotUpdate(..patch, tools: Some(tools)))
    }
    None -> Ok(patch)
  })
  // `apply_update` implements the identity fields' blank-keep rule, so
  // the merged row already carries the EFFECTIVE name/model — validation
  // sees exactly what would be stored.
  let merged = bot.apply_update(row, patch, timing.wall_now_s())
  use _name <- result.try(case bot.validate_name(merged.name) {
    Ok(name) -> Ok(name)
    Error(bot.InvalidName) -> Error(InvalidName)
    Error(bot.ReservedName) -> Error(ReservedName)
    // bot.BotError's remaining arms cannot escape validate_name (a
    // name-only check); the arm keeps the match total.
    Error(_) -> Error(InvalidName)
  })
  use _model <- result.try(
    bot.validate_model(merged.model)
    |> result.replace_error(InvalidModel),
  )
  case name_taken(state.rows, row.id, merged.name) {
    True -> Error(DuplicateName)
    False -> Ok(merged)
  }
}

/// True when some OTHER loaded bot already owns `name` — compared
/// case-insensitively (#127): delivery resolves names case-insensitively, so
/// "alice" and "Alice" must be ONE bot, or the lookup below could not tell
/// them apart. Display case is preserved verbatim.
fn name_taken(
  rows: Dict(String, StoredBot),
  own_id: String,
  name: String,
) -> Bool {
  let name = string.lowercase(name)
  list.any(dict.values(rows), fn(row) {
    row.id != own_id && string.lowercase(row.name) == name
  })
}

/// One toolset rule for create and patch alike: structural
/// normalization first (trim/blank-drop/dedupe — `Some([])` is the
/// legitimate chat-only set), then the injected catalog check. `None`
/// (the default-set sentinel) bypasses both: it carries no names.
fn validate_tools(
  state: State,
  tools: Option(List(String)),
) -> Result(Option(List(String)), RegistryError) {
  case bot.normalize_tools(tools) {
    Error(bot_error) -> Error(InvalidTools(bot.describe(bot_error)))
    Ok(None) -> Ok(None)
    Ok(Some(names)) ->
      case state.validate_tools(names) {
        Ok(names) -> Ok(Some(names))
        Error(reason) -> Error(InvalidTools(reason))
      }
  }
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

/// The pinnable tool catalog (issue #121) — the bot forms' checkbox
/// list's source. The budget must cover the closure's worst case (one
/// freeze-budget ask per mounted MCP server) — generous and fixed,
/// unlike the CRUD calls: a wedged server shows up as a slow picker,
/// never as a false failure.
pub fn tool_catalog(registry: Subject(Msg), timeout_ms: Int) -> ToolCatalog {
  actor.call(registry, timeout_ms, fn(reply) { Catalog(reply) })
}
