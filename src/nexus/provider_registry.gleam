//// The provider registry (docs/plans/multi-provider.md §7): the one
//// actor that owns provider rows between the store and everything
//// else. It loads the whole table once at boot — so a bad envelope or
//// an unreachable store fails boot loudly, not the first message —
//// serves masked metadata for reads, decrypts lazily into a small
//// memo on `Resolve`, and invalidates that memo on update/delete.
////
//// Key-material boundary: plaintext keys exist only here (in flight,
//// during encrypt/decrypt) and inside the `ResolvedProvider` handed to
//// the caller. Reads reply with `nexus/provider.Provider` — `has_key`
//// instead of any envelope bytes — and every error is a fixed string
//// or the store's already-sanitized text. The store seam stays
//// ciphertext-only by construction (see `nexus/store`).
////
//// Guard rails mirrored from the schema: duplicate names are refused
//// (the `provider_name_key` pre-check), deletes are refused while any
//// session pins the provider (`count_sessions_for_provider` — the
//// friendly copy of the `ON DELETE RESTRICT` FK), and updates are
//// existence-checked in state because the SQL `update ... where id`'
//// empty match is a silent no-op by design.
////
//// `ListModels` is the one network-touching message: it resolves the
//// endpoint synchronously (state-only, fast) and then runs the live
//// fetch in an unlinked process so a slow provider can never stall the
//// actor — `Resolve` sits on the session-create path. The fetch
//// transport is injected at start (`openai.list_models` in
//// production) so offline tests can hold a fetch and prove that
//// guarantee.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import nexus/config.{type Config}
import nexus/crypto
import nexus/openai
import nexus/provider.{type Provider}
import nexus/store.{type Store, type StoredProvider, StoredProvider}
import nexus/timing

/// Runtime identity of one provider: the metadata callers need for
/// display plus the decrypted transport endpoint. Holds the PLAINTEXT
/// key inside its `Endpoint`; never persisted, never serialized, never
/// replied with on metadata paths.
pub type ResolvedProvider {
  ResolvedProvider(id: String, name: String, endpoint: openai.Endpoint)
}

/// Closed error vocabulary for callers (the HTTP layer maps it onto
/// 400/404/409/502 in P4). Fixed strings only — no key material, no
/// envelope bytes.
pub type RegistryError {
  /// No provider with that id.
  Unknown
  /// Resolve/ListModels on a disabled provider. Disabling is the
  /// reversible alternative to deleting a referenced provider.
  Disabled
  InvalidName
  InvalidBaseUrl
  /// Create/rename onto an existing provider's name (unique).
  DuplicateName
  /// Delete while sessions still pin the provider (the 409 guard).
  StillReferenced
  /// An envelope failed authentication at resolve time. Boot already
  /// validated every stored envelope, so this means the row (or the
  /// master key) changed under us since boot.
  DecryptFailed
  /// Encrypting a submitted key was refused (nonce/AEAD backend).
  /// Unreachable in practice; typed rather than crashed.
  KeyOperationFailed
  /// The store refused or failed; carries the seam's sanitized text.
  StoreFailed(String)
  /// Live model list failed; carries fixed public text — the upstream
  /// status at most, never bodies or inspected transport details.
  ModelsFailed(String)
}

/// Fixed human-readable error text.
pub fn describe(error: RegistryError) -> String {
  case error {
    Unknown -> "unknown provider"
    Disabled -> "provider is disabled"
    InvalidName -> provider.describe(provider.InvalidName)
    InvalidBaseUrl -> provider.describe(provider.InvalidBaseUrl)
    DuplicateName -> "provider name already exists"
    StillReferenced ->
      "provider is still pinned by sessions; disable it instead"
    DecryptFailed -> crypto.describe(crypto.AuthenticationFailed)
    KeyOperationFailed -> "provider key operation failed"
    StoreFailed(reason) -> reason
    ModelsFailed(reason) -> reason
  }
}

pub type Msg {
  /// All providers as masked metadata, name-then-id sorted. Never keys.
  List(reply: Subject(Result(List(Provider), RegistryError)))
  /// One provider as masked metadata.
  Get(id: String, reply: Subject(Result(Provider, RegistryError)))
  /// Decrypt and return the runtime endpoint pair. Refuses disabled
  /// providers; memoizes per id; the only path that produces a
  /// `ResolvedProvider`.
  Resolve(id: String, reply: Subject(Result(ResolvedProvider, RegistryError)))
  /// Create a provider (enabled). The plaintext key, if any, is
  /// encrypted here and never stored or logged in the clear.
  Create(
    params: provider.ProviderParams,
    reply: Subject(Result(Provider, RegistryError)),
  )
  /// PATCH: present fields replace, absent fields keep. A present
  /// non-blank `api_key` replaces the stored key; absent/blank keeps
  /// the envelope byte-for-byte.
  Update(
    id: String,
    patch: provider.ProviderUpdate,
    reply: Subject(Result(Provider, RegistryError)),
  )
  /// Hard delete, guarded: refused while any session pins the provider.
  Delete(id: String, reply: Subject(Result(Nil, RegistryError)))
  /// Toggle the reversible off-switch. Resolve/ListModels refuse
  /// disabled providers; reads keep showing them.
  SetEnabled(
    id: String,
    enabled: Bool,
    reply: Subject(Result(Provider, RegistryError)),
  )
  /// Live model list from the provider's own `/v1/models`. Runs the
  /// fetch off the actor's message loop (see module docs).
  ListModels(id: String, reply: Subject(Result(List(String), RegistryError)))
}

type State {
  State(
    /// SSE timeout policy for built endpoints — server-global today;
    /// per-provider overrides are deferred (plan §18).
    cfg: Config,
    /// The decoded master key (NEXUS_ENCRYPTION_KEY). In memory only.
    key: BitArray,
    /// The loaded table, by id — the actor's source of truth for
    /// metadata, enabled flags, and existence pre-checks.
    rows: Dict(String, StoredProvider),
    /// Decrypt memo by id — the plan's cache: populated on first
    /// Resolve, dropped on update/delete.
    resolved: Dict(String, ResolvedProvider),
    /// ID minting only (`p<N>`), seeded past every stored id at boot.
    counter: Int,
    store: Store,
    /// The live model-list transport. Injectable so the offline tests
    /// can park a fetch mid-flight and assert the actor loop (and so
    /// `Resolve`) never waits on it; production passes
    /// `openai.list_models`.
    fetch: fn(openai.Endpoint) -> Result(List(String), openai.StreamError),
  )
}

/// Start the registry actor (boot and tests). Boot semantics: the
/// initialiser loads and DECRYPT-VALIDATES the whole table — an
/// unreachable store or a bad envelope fails start (and with the
/// OneForAll root, the whole boot) loudly. There is no lazy-failure
/// mode for persisted secrets.
pub fn start(
  cfg: Config,
  persistence: Store,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  start_with_model_fetcher(cfg, persistence, name, openai.list_models)
}

/// Identical to `start`, with the model-list transport injected: the
/// offline tests park a fetch to prove `ListModels` never blocks the
/// actor loop (and therefore never `Resolve`). Production callers use
/// `start`, which always passes `openai.list_models`.
pub fn start_with_model_fetcher(
  cfg: Config,
  persistence: Store,
  name: process.Name(Msg),
  fetch: fn(openai.Endpoint) -> Result(List(String), openai.StreamError),
) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      case crypto.decode_key(cfg.encryption_key) {
        // Defense in depth: config.load already validated the key. A
        // directly-constructed Config (tests) still fails loudly here.
        Error(error) -> Error(crypto.describe(error))
        Ok(key) ->
          case persistence.list_providers() {
            Error(error) -> Error("provider store unreachable: " <> error)
            Ok(rows) ->
              case validate_envelopes(key, rows) {
                Error(error) -> Error(crypto.describe(error))
                Ok(Nil) ->
                  actor.initialised(State(
                    cfg: cfg,
                    key: key,
                    rows: rows_by_id(rows),
                    resolved: dict.new(),
                    counter: max_provider_counter(rows),
                    store: persistence,
                    fetch: fetch,
                  ))
                  |> actor.returning(self)
                  |> actor.selecting(
                    process.new_selector() |> process.select(self),
                  )
                  |> Ok
              }
          }
      }
    })
    |> actor.on_message(handle)
    |> actor.named(name)
  actor.start(builder)
}

/// Decrypt every stored envelope (result discarded): a swapped, copied,
/// or tampered envelope — or a rotated-away master key — fails BOOT,
/// before any session can pin the provider. The memo stays empty; it
/// fills on first Resolve per the plan's caching design.
fn validate_envelopes(
  key: BitArray,
  rows: List(StoredProvider),
) -> Result(Nil, crypto.CryptoError) {
  list.try_each(rows, fn(row) {
    case row.api_key_encrypted {
      None -> Ok(Nil)
      Some(envelope) ->
        crypto.decrypt(key, row.id, envelope) |> result.replace(Nil)
    }
  })
}

fn rows_by_id(rows: List(StoredProvider)) -> Dict(String, StoredProvider) {
  list.fold(rows, dict.new(), fn(rows, row) { dict.insert(rows, row.id, row) })
}

/// The highest numeric suffix among `p<N>`-shaped ids, so freshly
/// minted ids never collide with stored providers (same scheme as the
/// session registry's `s<N>` minting).
fn max_provider_counter(rows: List(StoredProvider)) -> Int {
  rows
  |> list.fold(0, fn(max, row) {
    case string.split(row.id, on: "p") {
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
      let providers =
        state.rows
        |> dict.values
        |> list.map(provider.mask)
        |> list.sort(fn(a, b) {
          case string.compare(a.name, b.name) {
            order.Eq -> string.compare(a.id, b.id)
            other -> other
          }
        })
      process.send(reply, Ok(providers))
      actor.continue(state)
    }

    Get(id, reply) ->
      case dict.get(state.rows, id) {
        Ok(row) -> {
          process.send(reply, Ok(provider.mask(row)))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
      }

    Resolve(id, reply) ->
      case dict.get(state.rows, id) {
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(row) ->
          case row.enabled {
            False -> {
              process.send(reply, Error(Disabled))
              actor.continue(state)
            }
            True ->
              case dict.get(state.resolved, id) {
                Ok(resolved) -> {
                  process.send(reply, Ok(resolved))
                  actor.continue(state)
                }
                Error(_) ->
                  case resolve_row(state, row) {
                    Error(_) -> {
                      process.send(reply, Error(DecryptFailed))
                      actor.continue(state)
                    }
                    Ok(resolved) -> {
                      process.send(reply, Ok(resolved))
                      actor.continue(
                        State(
                          ..state,
                          resolved: dict.insert(state.resolved, id, resolved),
                        ),
                      )
                    }
                  }
              }
          }
      }

    Create(params, reply) -> {
      let counter = state.counter + 1
      let id = "p" <> int.to_string(counter)
      case create_row(state, id, params) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(row) ->
          case state.store.insert_provider(row) {
            Error(error) -> {
              // The unique constraints are the multi-instance backstop;
              // the registry's own pre-check covers the normal path.
              process.send(reply, Error(StoreFailed(error)))
              actor.continue(state)
            }
            Ok(Nil) -> {
              process.send(reply, Ok(provider.mask(row)))
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
          // deleted id would silently "succeed".
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(row) ->
          case update_row(state, row, patch) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(#(updated, replace_key)) ->
              case state.store.update_provider(updated, replace_key) {
                Error(error) -> {
                  process.send(reply, Error(StoreFailed(error)))
                  actor.continue(state)
                }
                Ok(Nil) -> {
                  process.send(reply, Ok(provider.mask(updated)))
                  actor.continue(
                    State(
                      ..state,
                      rows: dict.insert(state.rows, id, updated),
                      // Endpoint material may have moved: drop the memo.
                      resolved: dict.delete(state.resolved, id),
                    ),
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
          case state.store.count_sessions_for_provider(id) {
            Error(error) -> {
              process.send(reply, Error(StoreFailed(error)))
              actor.continue(state)
            }
            Ok(n) if n > 0 -> {
              process.send(reply, Error(StillReferenced))
              actor.continue(state)
            }
            Ok(_) ->
              // The FK's ON DELETE RESTRICT is the enforcement; this
              // count was its friendly pre-check.
              case state.store.delete_provider(id) {
                Error(error) -> {
                  // A session landing after the pre-check (another
                  // instance, mid-delete) trips the FK HERE — recheck
                  // so the caller still gets the dedicated conflict
                  // answer, never a raw store failure for that race.
                  let outcome = case still_pinned(state, id) {
                    True -> StillReferenced
                    False -> StoreFailed(error)
                  }
                  process.send(reply, Error(outcome))
                  actor.continue(state)
                }
                Ok(Nil) -> {
                  process.send(reply, Ok(Nil))
                  actor.continue(
                    State(
                      ..state,
                      rows: dict.delete(state.rows, id),
                      resolved: dict.delete(state.resolved, id),
                    ),
                  )
                }
              }
          }
      }

    SetEnabled(id, enabled, reply) ->
      case dict.get(state.rows, id) {
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(row) -> {
          // The endpoint itself is untouched, so the memo survives —
          // Resolve re-checks `enabled` against the row every time.
          let updated =
            provider.apply_metadata(
              row,
              provider.ProviderUpdate(None, None, None, Some(enabled)),
              timing.wall_now_s(),
            )
          case state.store.update_provider(updated, False) {
            Error(error) -> {
              process.send(reply, Error(StoreFailed(error)))
              actor.continue(state)
            }
            Ok(Nil) -> {
              process.send(reply, Ok(provider.mask(updated)))
              actor.continue(
                State(..state, rows: dict.insert(state.rows, id, updated)),
              )
            }
          }
        }
      }

    ListModels(id, reply) ->
      // Resolve from state (fast), then fetch off-loop: a hanging
      // provider must not stall Resolve on the session-create path.
      case dict.get(state.rows, id) {
        Error(_) -> {
          process.send(reply, Error(Unknown))
          actor.continue(state)
        }
        Ok(row) ->
          case row.enabled, resolve_row(state, row) {
            False, _ -> {
              process.send(reply, Error(Disabled))
              actor.continue(state)
            }
            True, Error(_) -> {
              process.send(reply, Error(DecryptFailed))
              actor.continue(state)
            }
            True, Ok(resolved) -> {
              process.spawn_unlinked(fn() {
                // Runs in the caller-concurrency world, not the actor:
                // up to the first-response timeout of slow time.
                let outcome =
                  state.fetch(resolved.endpoint)
                  |> result.map_error(fn(error) {
                    ModelsFailed(describe_stream_error(error))
                  })
                process.send(reply, outcome)
              })
              actor.continue(state)
            }
          }
      }
  }
}

/// After a refused delete, is the FK story confirmed? A session that
/// landed between the pre-check and the delete (the multi-instance
/// race) shows up on the recheck; a zero or unavailable count keeps
/// the ORIGINAL delete error rather than guessing a conflict.
fn still_pinned(state: State, id: String) -> Bool {
  case state.store.count_sessions_for_provider(id) {
    Ok(n) -> n > 0
    Error(_) -> False
  }
}

/// Build the runtime pair for a row: decrypt the envelope (or go
/// keyless), attach the server-global SSE timeout policy. The only
/// place plaintext appears outside `nexus/crypto`.
fn resolve_row(
  state: State,
  row: StoredProvider,
) -> Result(ResolvedProvider, Nil) {
  let api_key = case row.api_key_encrypted {
    None -> Ok(None)
    Some(envelope) ->
      crypto.decrypt(state.key, row.id, envelope)
      |> result.map(Some)
  }
  api_key
  |> result.map(fn(api_key) {
    ResolvedProvider(
      id: row.id,
      name: row.name,
      endpoint: openai.Endpoint(
        base_url: row.base_url,
        api_key: api_key,
        sse_first_response_timeout_ms: state.cfg.sse_first_response_timeout_ms,
        stream_idle_timeout_ms: state.cfg.stream_idle_timeout_ms,
      ),
    )
  })
  |> result.replace_error(Nil)
}

/// Validate + build a new row (id pre-minted by the caller's counter).
fn create_row(
  state: State,
  id: String,
  params: provider.ProviderParams,
) -> Result(StoredProvider, RegistryError) {
  use name <- result.try(
    provider.validate_name(params.name)
    |> result.replace_error(InvalidName),
  )
  use base_url <- result.try(
    provider.normalize_base_url(params.base_url)
    |> result.replace_error(InvalidBaseUrl),
  )
  // Uniqueness pre-check against loaded state (the schema's UNIQUE is
  // the cross-instance backstop, surfaced as StoreFailed).
  case name_taken(state.rows, id, name) {
    True -> Error(DuplicateName)
    False -> {
      use envelope <- result.try(encrypt_maybe(state, id, params.api_key))
      let now = timing.wall_now_s()
      Ok(store.StoredProvider(
        id: id,
        name: name,
        base_url: base_url,
        api_key_encrypted: envelope,
        key_version: 1,
        dialect: "openai",
        enabled: True,
        created_at: now,
        updated_at: now,
      ))
    }
  }
}

/// Validate + merge a PATCH onto a row, deciding key replacement: the
/// merged row carries the freshly encrypted envelope iff the key is
/// being replaced, and the returned boolean is the seam's
/// `replace_key` (False keeps the stored envelope untouched).
fn update_row(
  state: State,
  row: StoredProvider,
  patch: provider.ProviderUpdate,
) -> Result(#(StoredProvider, Bool), RegistryError) {
  use name <- result.try(
    provider.validate_name(option.unwrap(patch.name, row.name))
    |> result.replace_error(InvalidName),
  )
  use base_url <- result.try(
    provider.normalize_base_url(option.unwrap(patch.base_url, row.base_url))
    |> result.replace_error(InvalidBaseUrl),
  )
  case name_taken(state.rows, row.id, name) {
    True -> Error(DuplicateName)
    False -> {
      let replace_key = provider.replaces_key(patch)
      use envelope <- result.try(case replace_key {
        False -> Ok(row.api_key_encrypted)
        True -> encrypt_maybe(state, row.id, patch.api_key)
      })
      let merged = provider.apply_metadata(row, patch, timing.wall_now_s())
      Ok(#(
        StoredProvider(
          ..merged,
          name: name,
          base_url: base_url,
          api_key_encrypted: envelope,
        ),
        replace_key,
      ))
    }
  }
}

/// True when some OTHER loaded provider already owns `name`.
fn name_taken(
  rows: Dict(String, StoredProvider),
  own_id: String,
  name: String,
) -> Bool {
  list.any(dict.values(rows), fn(row) { row.id != own_id && row.name == name })
}

/// Encrypt a submitted plaintext key under the row's AAD. Blank or
/// absent stays/becomes keyless — never an encrypted empty string.
fn encrypt_maybe(
  state: State,
  id: String,
  submitted: Option(String),
) -> Result(Option(BitArray), RegistryError) {
  case option.map(submitted, string.trim) {
    None | Some("") -> Ok(None)
    Some(key) ->
      crypto.encrypt(state.key, id, key)
      |> result.map(Some)
      |> result.replace_error(KeyOperationFailed)
  }
}

/// Fixed public text for a failed live model list. Upstream bodies,
/// transport reasons (string.inspect of the hackney error), and decode
/// details are dropped on purpose: a provider may echo a rejected
/// bearer key back in its error body, so only the numeric status is
/// safe to surface. CLI callers of `openai.list_models` (the audit
/// tools) still see full detail directly from the seam.
pub fn describe_stream_error(error: openai.StreamError) -> String {
  case error {
    openai.Non200(status, _body) ->
      "model list failed: HTTP " <> int.to_string(status)
    openai.Transport(_reason) -> "model list failed: transport error"
    openai.Decode(_reason) -> "model list failed: unreadable model list"
  }
}

// ---------------------------------------------------------------------------
// Client helpers (boot wiring, the HTTP layer, the UI bridge)
// ---------------------------------------------------------------------------

/// Resolve a provider id to its runtime endpoint. The one call on the
/// session-create path; refuses unknown and disabled providers.
pub fn resolve(
  registry: Subject(Msg),
  id: String,
) -> Result(ResolvedProvider, RegistryError) {
  actor.call(registry, 5000, fn(reply) { Resolve(id, reply) })
}

/// All providers as masked metadata, name-then-id sorted. Never keys.
pub fn list_providers(
  registry: Subject(Msg),
) -> Result(List(Provider), RegistryError) {
  actor.call(registry, 5000, List)
}

/// Live model list for one provider. The reply arrives from an unlinked
/// fetch process, so the timeout must cover the fetch itself — it mirrors
/// the endpoint's own first-response budget (server-global SSE policy).
pub fn list_models(
  registry: Subject(Msg),
  id: String,
  timeout_ms: Int,
) -> Result(List(String), RegistryError) {
  actor.call(registry, timeout_ms, fn(reply) { ListModels(id, reply) })
}
