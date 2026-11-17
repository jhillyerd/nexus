//// The ONE thread-creation orchestration shared by the HTTP API and the
//// UI (bots prep, #73): resolve the provider (id first, then name),
//// then ask the thread registry to create.
////
//// The provider resolution is a registry ask, so it happens HERE —
//// outside the registry's loop. The model alias is NOT validated
//// against the provider's live list: proxies like Bifrost accept
//// aliases ("smart", "fast") that remap to whatever is deployed at the
//// time, and such aliases come and go from the proxy's /v1/models — a
//// create-time check refuses legitimate pins and races the very list
//// the picker just offered. A dead alias instead lands as a pinned
//// thread whose first turn fails at stream time — the same semantics
//// the registry's bot-to-bot DM create always had. (This supersedes
//// the old multi-provider §11 "400 unknown model" preflight; the
//// empty-model and unknown-toolset refusals stay.)
////
//// Registry errors that can only be races (the provider vanished
//// between resolve and create) surface as `CreateFailed` and stay
//// server-side problems (502/503), not client errors.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/result
import nexus/bot_registry
import nexus/config.{type Config}
import nexus/provider.{type Provider}
import nexus/provider_registry
import nexus/thread
import nexus/thread_registry

/// The live model-list budget: the endpoint's first-response timeout plus
/// round-trip headroom. ONE rule for every `list_models` call in the app
/// — web's provider models route, the UI's create panel picker, and the
/// settings page's connection Test and bot-form comboboxes (all of which
/// previously hard-coded or re-derived the value per surface). Thread
/// creation itself no longer fetches the list at all: aliases are not
/// validated at create (see the module doc), so the fetch would be a
/// pointless preflight round-trip.
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
  /// The bot registry itself could not be asked — server-side.
  /// Defensive exhaustiveness arm: `get_bot` in practice only refuses
  /// with `Unknown` (the registry serves reads from its boot-loaded
  /// state, and a dead registry crashes the `actor.call` rather than
  /// erroring), but `RegistryError` is a closed vocabulary — this arm
  /// keeps the match honest and maps any future store-reading failure
  /// onto the server-side 502.
  BotsUnavailable
  /// No bot with that id (bots plan P1: `POST {"bot": id}`).
  BotUnknown(id: String)
  /// The registry refused. After the provider resolution, these are
  /// races (provider vanished mid-flight) or start failures — the caller
  /// still maps them (400 empty model, 502 provider, 503 start).
  CreateFailed(thread_registry.CreateError)
}

/// Resolve, create — the whole orchestration. Returns the registry's
/// fresh `ThreadSummary` on success; callers never build one.
pub fn create_thread(
  providers: Subject(provider_registry.Msg),
  registry: Subject(thread_registry.Msg),
  requested: thread_registry.NewThread,
) -> Result(thread.ThreadSummary, CreateProblem) {
  use found <- result.try(resolve_provider(providers, requested.provider_id))
  // The registry pins the CANONICAL provider id — the identifier a caller
  // may supply by NAME must never land in the frozen pin or the stored
  // row (web's id-or-name rule, §11).
  let pinned = thread_registry.NewThread(..requested, provider_id: found.id)
  thread_registry.create(registry, pinned)
  |> result.map_error(CreateFailed)
}

/// Create a thread FROM a bot (bots plan P1): resolve the bot, copy its
/// provider/model/system prompt into the creation request (the bot is a
/// creation-time template — the values freeze into the thread's columns
/// and `bot_id` rides along as provenance), then run the SAME shared
/// create. The bot registry is only asked HERE, in the orchestration both
/// surfaces share — it never resolves providers, and the thread registry
/// never sees bots beyond the `bot_id` column. The bot's model alias is
/// NOT re-validated: a bot can go stale, but a stale alias is legitimate
/// at rest (the bots plan) and at create (see the module doc) — the
/// thread still lands and its first turn fails at stream time.
pub fn create_thread_from_bot(
  bots: Subject(bot_registry.Msg),
  providers: Subject(provider_registry.Msg),
  registry: Subject(thread_registry.Msg),
  bot_id: String,
) -> Result(thread.ThreadSummary, CreateProblem) {
  case bot_registry.get_bot(bots, bot_id) {
    Error(bot_registry.Unknown) -> Error(BotUnknown(bot_id))
    Error(_) -> Error(BotsUnavailable)
    Ok(bot) ->
      create_thread(
        providers,
        registry,
        thread_registry.NewThread(
          // The bot's provider id is canonical (the registry-validated
          // `provider_id` the bot was saved with), so `resolve_provider`'s
          // id-first lookup pins the same row.
          provider_id: bot.provider_id,
          model: bot.model,
          // `None` (the bot's default-prompt sentinel) resolves to the
          // config default at the one creation point, exactly like a
          // plain create; an explicit prompt is used VERBATIM, never
          // amended (the same rule as an explicit NEXUS_SYSTEM_PROMPT).
          system_prompt: bot.system_prompt,
          // The toolset snapshot source (bots plan P2): `None` = the
          // current default (the bot stays a live template); `Some` =
          // the bot's explicit list, resolved against the
          // config-independent catalog — an unknown name (a bot gone
          // stale past an upgrade) refuses the create (`UnknownToolset`),
          // never silently narrowed.
          toolset: bot.tools,
          bot_id: Some(bot.id),
          // A user-facing create-from-bot is an ORDINARY thread (never a
          // channel): no parent, open auto-title path (bot-channels
          // plan, #123 — channels are born only from `bot_message`
          // delivery).
          parent_thread_id: option.None,
          title: "",
        ),
      )
  }
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

/// Fixed human text for a refused create — the same string both surfaces
/// show (the HTTP error body embeds it verbatim). Never echoes key
/// material; only identifiers the caller already supplied.
pub fn describe(problem: CreateProblem) -> String {
  case problem {
    ProvidersUnavailable -> "provider registry unavailable"
    ProviderNotFound(ident) -> "unknown provider: " <> ident
    ProviderDisabled(name) -> "provider is disabled: " <> name
    BotsUnavailable -> "bot registry unavailable"
    BotUnknown(id) -> "unknown bot: " <> id
    CreateFailed(thread_registry.EmptyModel) -> "empty model"
    CreateFailed(thread_registry.ProviderFailed(_)) ->
      "provider became unusable"
    CreateFailed(thread_registry.UnknownToolset(reason)) ->
      "toolset unavailable: " <> reason
    CreateFailed(thread_registry.StartFailed(reason)) ->
      "thread unavailable: " <> reason
    CreateFailed(thread_registry.ChannelPersistFailed) ->
      "channel could not be persisted"
  }
}
