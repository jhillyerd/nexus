//// The ONE thread-creation orchestration shared by the HTTP API and the
//// UI (bots prep, #73): resolve the provider (id first, then name),
//// validate the model alias against the provider's LIVE model list, then
//// ask the thread registry to create.
////
//// The provider lookups are network calls, so they happen HERE — outside
//// the registry's loop — and both surfaces get the same stale-alias
//// refusal for free. That matters for the bots plan's "create thread
//// from bot": a bot's stored model alias can go stale (the provider
//// renamed or dropped it), and the create must fail loudly, never
//// silently succeed with a dead alias. Before this module the UI skipped
//// the check entirely and web kept its own copy.
////
//// Registry errors that can only be pre-validation races (the provider
//// vanished between check and create) surface as `CreateFailed` and stay
//// server-side problems (502/503), not client errors.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import nexus/config.{type Config}
import nexus/provider.{type Provider}
import nexus/provider_registry
import nexus/thread
import nexus/thread_registry

/// The live model-list budget: the endpoint's first-response timeout plus
/// round-trip headroom. ONE rule for every `list_models` call in the app
/// — the create preflight below, web's models routes, the UI's create
/// panel picker, and the settings page's connection Test (all of which
/// previously hard-coded or re-derived the value per surface).
pub fn models_timeout(cfg: Config) -> Int {
  cfg.sse_first_response_timeout_ms + 5000
}

/// Why a create refused, in the shared vocabulary of both surfaces. HTTP
/// maps each variant onto the plan's status codes; the UI shows
/// `describe`'s text as a note.
pub type CreateProblem {
  /// The provider registry itself could not be asked (the store backing
  /// it is down) — a server-side problem, not a bad request.
  ProvidersUnavailable
  /// No provider matches the identifier (id checked first, then name).
  ProviderNotFound(ident: String)
  /// A provider matched but is disabled — the reversible delete.
  ProviderDisabled(name: String)
  /// The provider's live model list could not be fetched.
  ModelsUnavailable
  /// The alias is not on the provider's live list — a stale alias (the
  /// bots plan's required 400 on create-from-bot).
  ModelUnknown(alias: String)
  /// The registry refused. After the pre-validation above, these are
  /// races (provider vanished mid-flight) or start failures — the caller
  /// still maps them (400 empty model, 502 provider, 503 start).
  CreateFailed(thread_registry.CreateError)
}

/// Resolve, validate, create — the whole orchestration. Returns the
/// registry's fresh `ThreadSummary` on success; callers never build one.
pub fn create_thread(
  providers: Subject(provider_registry.Msg),
  registry: Subject(thread_registry.Msg),
  models_timeout_ms: Int,
  requested: thread_registry.NewThread,
) -> Result(thread.ThreadSummary, CreateProblem) {
  use found <- result.try(resolve_provider(providers, requested.provider_id))
  use models <- result.try(list_models(providers, found.id, models_timeout_ms))
  use _ <- result.try(known_model(models, requested.model))
  // The registry pins the CANONICAL provider id — the identifier a caller
  // may supply by NAME must never land in the frozen pin or the stored
  // row (web's id-or-name rule, §11).
  let pinned = thread_registry.NewThread(..requested, provider_id: found.id)
  thread_registry.create(registry, pinned)
  |> result.map_error(CreateFailed)
}

/// Resolve the request's provider identifier (id or name) to registry
/// metadata, refusing unknown and disabled providers. An exact ID match is
/// checked FIRST: names are free-form, so a provider may be *named* after
/// another provider's id — the id is the unambiguous key and must win when
/// the two disagree (multi-provider plan §11).
fn resolve_provider(
  providers: Subject(provider_registry.Msg),
  ident: String,
) -> Result(Provider, CreateProblem) {
  case provider_registry.list_providers(providers) {
    Error(_) -> Error(ProvidersUnavailable)
    Ok(all) -> {
      let found = case list.find(all, fn(p) { p.id == ident }) {
        Ok(by_id) -> Ok(by_id)
        Error(_) -> list.find(all, fn(p) { p.name == ident })
      }
      case found {
        Error(_) -> Error(ProviderNotFound(ident))
        Ok(found) ->
          case found.enabled {
            False -> Error(ProviderDisabled(found.name))
            True -> Ok(found)
          }
      }
    }
  }
}

fn list_models(
  providers: Subject(provider_registry.Msg),
  provider_id: String,
  models_timeout_ms: Int,
) -> Result(List(String), CreateProblem) {
  case
    provider_registry.list_models(providers, provider_id, models_timeout_ms)
  {
    Ok(models) -> Ok(models)
    Error(_) -> Error(ModelsUnavailable)
  }
}

fn known_model(
  models: List(String),
  alias: String,
) -> Result(Nil, CreateProblem) {
  case list.contains(models, alias) {
    True -> Ok(Nil)
    False -> Error(ModelUnknown(alias))
  }
}

/// Fixed human text for a refused create — the same string both surfaces
/// show (the HTTP error body embeds it verbatim). Never echoes key
/// material; only identifiers the caller already supplied.
pub fn describe(problem: CreateProblem) -> String {
  case problem {
    ProvidersUnavailable -> "provider registry unavailable"
    ProviderNotFound(ident) -> "unknown provider: " <> ident
    ProviderDisabled(name) -> "provider is disabled: " <> name
    ModelsUnavailable -> "unable to list models from provider"
    ModelUnknown(alias) -> "unknown model: " <> alias
    CreateFailed(thread_registry.EmptyModel) -> "empty model"
    CreateFailed(thread_registry.ProviderFailed(_)) ->
      "provider became unusable"
    CreateFailed(thread_registry.StartFailed(reason)) ->
      "thread unavailable: " <> reason
  }
}
