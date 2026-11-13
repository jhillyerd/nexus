//// The HTTP surface: a JSON scripting API (provider CRUD, provider-
//// scoped model listing, thread CRUD, send, stop), the Lustre shell
//// page with its WebSocket transport (`/ws`, `/lustre/runtime.mjs`),
//// and a health check.
////
//// Mist remains sufficient: the WebSocket upgrade bypasses wisp, and the
//// scripting surface is still small and explicit. The thread actor is
//// resolved through the registry at request time, so HTTP traffic
//// reaches the live subject after a registry-owned restart. The browser
//// UI does not use these routes — it talks to the Lustre server
//// component over `/ws` (see `nexus/ui_runtime`).

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{type Method, Delete, Get, Patch, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import nexus/bot
import nexus/bot_registry
import nexus/config.{type Config}
import nexus/page
import nexus/provider
import nexus/provider_registry
import nexus/thread
import nexus/thread_create
import nexus/thread_registry
import nexus/timing
import nexus/ui_runtime

/// Registry-backed handler. Threads are resolved by ID at request time so
/// HTTP traffic reaches the live actor after a registry-owned restart.
/// `providers_name` resolves the provider registry the thread-create
/// path validates against (multi-provider plan §11); `bots_name` the bot
/// registry behind `/bots` and the create-from-bot half of `POST
/// /threads`. The `/ws` route starts a dedicated component runtime per
/// connection from these same subjects (see `nexus/ui_runtime`).
pub fn handler(
  cfg: Config,
  registry_name: process.Name(thread_registry.Msg),
  providers_name: process.Name(provider_registry.Msg),
  bots_name: process.Name(bot_registry.Msg),
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let registry = process.named_subject(registry_name)
  let providers = process.named_subject(providers_name)
  let bots = process.named_subject(bots_name)
  fn(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
    case req.method, request.path_segments(req) {
      Get, [] -> protected(cfg, req, fn() { page_response(cfg.ui_token) })
      Get, ["threads"] ->
        protected(cfg, req, fn() { threads_response(registry, req) })
      Post, ["threads"] ->
        protected(cfg, req, fn() {
          create_thread_response(cfg, req, registry, providers, bots)
        })
      Patch, ["threads", id] ->
        protected(cfg, req, fn() { patch_thread_response(req, registry, id) })
      Delete, ["threads", id] ->
        protected(cfg, req, fn() { delete_thread_response(registry, id) })
      Get, ["providers"] ->
        protected(cfg, req, fn() { providers_response(providers) })
      Post, ["providers"] ->
        protected(cfg, req, fn() { create_provider_response(req, providers) })
      Get, ["providers", id, "models"] ->
        protected(cfg, req, fn() {
          provider_models_response(cfg, providers, id)
        })
      Patch, ["providers", id] ->
        protected(cfg, req, fn() { patch_provider_response(req, providers, id) })
      Delete, ["providers", id] ->
        protected(cfg, req, fn() { delete_provider_response(providers, id) })
      Get, ["bots"] -> protected(cfg, req, fn() { bots_response(bots) })
      Post, ["bots"] ->
        protected(cfg, req, fn() { create_bot_response(req, bots, providers) })
      Patch, ["bots", id] ->
        protected(cfg, req, fn() {
          patch_bot_response(req, bots, id, providers)
        })
      Delete, ["bots", id] ->
        protected(cfg, req, fn() { delete_bot_response(registry, bots, id) })
      Post, ["threads", id, "send"] ->
        protected(cfg, req, fn() {
          with_thread(registry, id, send_response(req, registry, id, _))
        })
      Post, ["threads", id, "stop"] ->
        protected(cfg, req, fn() { with_thread(registry, id, stop_response) })
      Get, ["healthz"] ->
        json_response(200, json.object([#("ok", json.bool(True))]))
      Get, ["lustre", "runtime.mjs"] ->
        protected(cfg, req, fn() { runtime_asset_response() })
      Get, ["css", "pico.min.css"] ->
        protected(cfg, req, fn() { pico_asset_response() })
      Get, ["ws"] ->
        protected(cfg, req, fn() {
          ui_runtime.websocket(
            req,
            registry,
            providers,
            bots,
            thread_create.models_timeout(cfg),
          )
        })
      _, _ -> json_response(404, err_json("not found"))
    }
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

fn protected(
  cfg: Config,
  req: Request(mist.Connection),
  run: fn() -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case authorized(req, cfg.ui_token) {
    False -> unauthorized()
    True -> run()
  }
}

fn page_response(token: Option(String)) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(page.html(token))))
}

fn runtime_asset_response() -> Response(mist.ResponseData) {
  case ui_runtime.runtime_asset_response() {
    Ok(res) -> res
    Error(_) -> json_response(404, err_json("runtime asset unavailable"))
  }
}

fn pico_asset_response() -> Response(mist.ResponseData) {
  case ui_runtime.pico_asset_response() {
    Ok(res) -> res
    Error(_) -> json_response(404, err_json("stylesheet asset unavailable"))
  }
}

fn with_thread(
  registry: process.Subject(thread_registry.Msg),
  id: String,
  then: fn(process.Subject(thread.Msg)) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let summaries = thread_registry.list_threads(registry)
  case list.any(summaries, fn(summary) { summary.id == id }) {
    False -> json_response(404, err_json("thread not found"))
    True ->
      case thread_registry.get(registry, id) {
        Ok(subject) -> then(subject)
        Error(_) -> json_response(503, err_json("thread unavailable"))
      }
  }
}

// GET /models is gone (multi-provider §11): with N providers there is
// no "default" endpoint to answer it — callers ask the provider-scoped
// `GET /providers/<id>/models` below.

fn threads_response(
  registry: process.Subject(thread_registry.Msg),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let summaries =
    thread_registry.list_threads(registry)
    |> filter_archived(wants_archived(req))
  json_response(200, threads_json(summaries))
}

/// `?archived=1` (or `true`) flips the list from the default active-only
/// view to archived-only. Pure — offline-testable.
pub fn filter_archived(
  summaries: List(thread.ThreadSummary),
  want_archived: Bool,
) -> List(thread.ThreadSummary) {
  list.filter(summaries, fn(summary) { summary.archived == want_archived })
}

fn wants_archived(req: Request(a)) -> Bool {
  case query_param(req, "archived") {
    Ok("1") | Ok("true") -> True
    _ -> False
  }
}

fn create_thread_response(
  cfg: Config,
  req: Request(mist.Connection),
  registry: process.Subject(thread_registry.Msg),
  providers: process.Subject(provider_registry.Msg),
  bots: process.Subject(bot_registry.Msg),
) -> Response(mist.ResponseData) {
  // Multi-provider §11 + bots plan P1: the body pins the thread's
  // identity ONE of two ways — `{"provider":…, "model":…}` (both
  // required) or `{"bot": id}` (provider/model/system prompt copied
  // from the bot at creation). Specifying both shapes is a conflict.
  case read_create(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) ->
      case fields {
        ConflictingCreate ->
          json_response(
            400,
            err_json("bot conflicts with provider/model — pick one shape"),
          )
        BotCreate(bot_id) ->
          // The SHARED create-from-bot orchestration (#73/#74): resolve
          // the bot, copy its frozen values, re-validate the alias
          // against the provider's LIVE list, create. A stale bot alias
          // must 400, never silently succeed.
          case
            thread_create.create_thread_from_bot(
              bots,
              providers,
              registry,
              thread_create.models_timeout(cfg),
              bot_id,
            )
          {
            Ok(summary) -> json_response(201, thread_summary_json(summary))
            Error(problem) ->
              json_response(
                create_problem_status(problem),
                err_json(thread_create.describe(problem)),
              )
          }
        PlainCreate(provider: "", model: _) ->
          json_response(400, err_json("empty provider"))
        PlainCreate(provider: _, model: "") ->
          json_response(400, err_json("empty model"))
        PlainCreate(provider: ident, model: trimmed_model) -> {
          // The shared orchestration (#73): provider resolution + live
          // model-alias validation outside the registry's loop, then the
          // create. The reply IS the summary — this layer never
          // hand-builds one.
          let requested =
            thread_registry.NewThread(
              provider_id: ident,
              model: trimmed_model,
              // POST /threads pins the config default toolset; a
              // bot-sourced create arrives through the BotCreate arm
              // above instead (bots plan P2).
              system_prompt: None,
              toolset: None,
              bot_id: None,
            )
          case
            thread_create.create_thread(
              providers,
              registry,
              thread_create.models_timeout(cfg),
              requested,
            )
          {
            Ok(summary) -> json_response(201, thread_summary_json(summary))
            Error(problem) ->
              json_response(
                create_problem_status(problem),
                err_json(thread_create.describe(problem)),
              )
          }
        }
      }
  }
}

/// The shared create vocabulary onto the plan's status codes (§11):
/// pre-validation refusals are client errors (400), provider-side
/// failures are server errors (502/503).
fn create_problem_status(problem: thread_create.CreateProblem) -> Int {
  case problem {
    thread_create.ProvidersUnavailable -> 502
    thread_create.ProviderNotFound(_) -> 400
    thread_create.ProviderDisabled(_) -> 400
    thread_create.ModelsUnavailable -> 502
    thread_create.ModelUnknown(_) -> 400
    thread_create.BotsUnavailable -> 502
    thread_create.BotUnknown(_) -> 400
    // Post-validation registry refusals are races: the provider passed
    // the live check, then could not stream when the thread pinned it.
    thread_create.CreateFailed(thread_registry.EmptyModel) -> 400
    // A stale bot's toolset named a tool outside the compiled catalog
    // (bots plan P2): a client-data problem, refused like a bad alias.
    thread_create.CreateFailed(thread_registry.UnknownToolset(_)) -> 400
    thread_create.CreateFailed(thread_registry.ProviderFailed(_)) -> 502
    thread_create.CreateFailed(thread_registry.StartFailed(_)) -> 503
  }
}

fn read_json(req: Request(mist.Connection)) -> Result(String, Nil) {
  read_body_json(req, text_decoder())
}

/// The POST /threads body, already split into its two shapes (bots plan
/// P1): `PlainCreate(provider, model)` (both required — a thread always
/// pins its provider explicitly) or `BotCreate(bot)` (provider/model/
/// system prompt copied from the bot at creation). A present `bot` KEY
/// alongside a present `provider`/`model` KEY — blank or not — is a
/// conflict: the bot's frozen values must not be quietly overridden.
/// Classification is presence-aware (a trimmed-blank value is still a
/// value the caller sent); trimming happens after, so the plain path's
/// blank halves stay the empty-field 400s. Presence is read on the RAW
/// JSON value: an explicit `null` fails the decode (400) instead of
/// collapsing into the missing-key default — `decode.optional` would
/// blur `{"bot": null}` into a plain create and `{"bot": "b1",
/// "provider": null}` into a bot create (coderabbit review, PR #87).
pub type CreateFields {
  PlainCreate(provider: String, model: String)
  BotCreate(bot: String)
  /// `bot` alongside `provider` and/or `model` — the shapes cannot both
  /// be honored, and quietly preferring one would freeze values the
  /// caller may not expect.
  ConflictingCreate
}

/// A present JSON string mapped to `Some` — the ONE field decoder for
/// `create_fields_decoder`. Distinct from `decode.optional(decode.string)`
/// exactly at explicit `null`: `optional_field` runs the inner decoder on
/// any PRESENT value, so a null fails the decode (whole-body 400) instead
/// of decoding to the missing-key `None` (see the CreateFields contract).
fn present_string() -> decode.Decoder(option.Option(String)) {
  decode.map(decode.string, option.Some)
}

pub fn create_fields_decoder() -> decode.Decoder(CreateFields) {
  use provider <- decode.optional_field("provider", None, present_string())
  use model <- decode.optional_field("model", None, present_string())
  use bot <- decode.optional_field("bot", None, present_string())
  decode.success(case bot, provider, model {
    Some(bot), None, None -> BotCreate(string.trim(bot))
    None, provider, model ->
      PlainCreate(
        provider: string.trim(option.unwrap(provider, "")),
        model: string.trim(option.unwrap(model, "")),
      )
    Some(_), _, _ -> ConflictingCreate
  })
}

pub fn parse_create_json(body: String) -> Result(CreateFields, Nil) {
  json.parse(body, using: create_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

fn read_create(req: Request(mist.Connection)) -> Result(CreateFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_create_json(body)
      }
  }
}

/// The POST /providers body (§11): `{"name":…, "base_url":…,
/// "api_key":…?}` — name and base_url are required; a blank or absent
/// api_key creates a KEYLESS provider (local endpoints).
pub type ProviderCreateFields {
  ProviderCreateFields(name: String, base_url: String, api_key: Option(String))
}

pub fn provider_create_fields_decoder() -> decode.Decoder(ProviderCreateFields) {
  use name <- decode.field("name", decode.string)
  use base_url <- decode.field("base_url", decode.string)
  use api_key <- decode.optional_field(
    "api_key",
    None,
    decode.optional(decode.string),
  )
  decode.success(ProviderCreateFields(name:, base_url:, api_key:))
}

pub fn parse_provider_create_json(
  body: String,
) -> Result(ProviderCreateFields, Nil) {
  json.parse(body, using: provider_create_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

fn read_provider_create(
  req: Request(mist.Connection),
) -> Result(ProviderCreateFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_provider_create_json(body)
      }
  }
}

/// The PATCH /providers/<id> body (§11): every field optional; an
/// absent (or explicit null) field keeps the stored value. An api_key
/// that is present AND non-blank replaces the stored key — blank means
/// keep, and "going keyless" is deliberately a create-time choice.
pub type ProviderPatchFields {
  ProviderPatchFields(
    name: Option(String),
    base_url: Option(String),
    api_key: Option(String),
    enabled: Option(Bool),
  )
}

pub fn provider_patch_fields_decoder() -> decode.Decoder(ProviderPatchFields) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use base_url <- decode.optional_field(
    "base_url",
    None,
    decode.optional(decode.string),
  )
  use api_key <- decode.optional_field(
    "api_key",
    None,
    decode.optional(decode.string),
  )
  use enabled <- decode.optional_field(
    "enabled",
    None,
    decode.optional(decode.bool),
  )
  decode.success(ProviderPatchFields(name:, base_url:, api_key:, enabled:))
}

pub fn parse_provider_patch_json(
  body: String,
) -> Result(ProviderPatchFields, Nil) {
  json.parse(body, using: provider_patch_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

/// The POST /bots body: `{"name":…, "provider":…, "model":…,
/// "description":…?, "system_prompt":…?, "tools":…?}` — name/provider/
/// model are required; a blank or absent `system_prompt` is the global
/// default; `tools` absent or null is the default set (resolved at
/// thread creation), `[]` is chat-only, a non-empty array is an explicit
/// list (bots plan P2; the registry validates the names against the
/// compiled catalog).
pub type BotCreateFields {
  BotCreateFields(
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: Option(String),
    tools: Option(List(String)),
  )
}

pub fn bot_create_fields_decoder() -> decode.Decoder(BotCreateFields) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use provider_id <- decode.field("provider", decode.string)
  use model <- decode.field("model", decode.string)
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.optional(decode.string),
  )
  // Absent and null both flatten to None (the default-set sentinel);
  // there is no create-time "keep the stored list" state to preserve.
  use tools <- decode.optional_field(
    "tools",
    None,
    decode.optional(decode.list(decode.string)),
  )
  decode.success(BotCreateFields(
    name: name,
    description: description,
    provider_id: provider_id,
    model: model,
    system_prompt: system_prompt,
    tools: tools,
  ))
}

pub fn parse_bot_create_json(body: String) -> Result(BotCreateFields, Nil) {
  json.parse(body, using: bot_create_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

fn read_bot_create(
  req: Request(mist.Connection),
) -> Result(BotCreateFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_bot_create_json(body)
      }
  }
}

/// The PATCH /bots/<id> body: present fields replace, absent keep. Two
/// field classes (see `bot.BotUpdate`): a BLANK present `name`/`model`
/// keeps the stored value (normalized away here), while a present
/// `description`/`system_prompt` always replaces (blank CLEARS — back
/// to "" and back to the default prompt), so absent-vs-blank must stay
/// distinguishable for exactly those two fields. `tools` is three-state
/// (bots plan P2): absent keeps, null clears back to the default set,
/// an array replaces — hence the nested Option, passed through to the
/// registry verbatim.
pub type BotPatchFields {
  BotPatchFields(
    name: Option(String),
    description: Option(String),
    provider_id: Option(String),
    model: Option(String),
    system_prompt: Option(String),
    tools: Option(Option(List(String))),
    /// The inbound gate (bots plan P3a): present flips it, absent keeps.
    allow_inbound: Option(Bool),
  )
}

pub fn bot_patch_fields_decoder() -> decode.Decoder(BotPatchFields) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use provider_id <- decode.optional_field(
    "provider",
    None,
    decode.optional(decode.string),
  )
  use model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.optional(decode.string),
  )
  use tools <- decode.optional_field(
    "tools",
    None,
    // Three-state (bots plan P2), decided HERE because the inner
    // decoder only runs for a PRESENT key: absent → the None default
    // (keep); present null → decode.optional's None, mapped to
    // Some(None) (clear back to the default set); present array →
    // Some(Some(names)) (replace).
    decode.optional(decode.list(decode.string))
      |> decode.map(fn(list_or_null) {
        case list_or_null {
          None -> Some(None)
          Some(names) -> Some(Some(names))
        }
      }),
  )
  use allow_inbound <- decode.optional_field(
    "allow_inbound",
    None,
    // Two-state (bots plan P3a): absent keeps the stored gate,
    // present true/false replaces it.
    decode.optional(decode.bool),
  )
  decode.success(BotPatchFields(
    name: blank_as_none(name),
    description: description,
    provider_id: blank_as_none(provider_id),
    model: blank_as_none(model),
    system_prompt: system_prompt,
    tools: tools,
    allow_inbound: allow_inbound,
  ))
}

pub fn parse_bot_patch_json(body: String) -> Result(BotPatchFields, Nil) {
  json.parse(body, using: bot_patch_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

fn read_bot_patch(
  req: Request(mist.Connection),
) -> Result(BotPatchFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_bot_patch_json(body)
      }
  }
}

fn read_provider_patch(
  req: Request(mist.Connection),
) -> Result(ProviderPatchFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_provider_patch_json(body)
      }
  }
}

/// A present-but-blank key is the same as an absent one: keep.
fn blank_as_none(value: Option(String)) -> Option(String) {
  case value {
    Some(key) ->
      case string.trim(key) {
        "" -> None
        _ -> Some(key)
      }
    None -> None
  }
}

fn empty_provider_patch(patch: provider.ProviderUpdate) -> Bool {
  option.is_none(patch.name)
  && option.is_none(patch.base_url)
  && option.is_none(patch.api_key)
  && option.is_none(patch.enabled)
}

fn read_body_json(
  req: Request(mist.Connection),
  decoder: decode.Decoder(String),
) -> Result(String, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) ->
          json.parse(body, using: decoder)
          |> result.map_error(fn(_) { Nil })
      }
  }
}

fn send_response(
  req: Request(mist.Connection),
  registry: process.Subject(thread_registry.Msg),
  id: String,
  thread: process.Subject(thread.Msg),
) -> Response(mist.ResponseData) {
  case read_json(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(text) ->
      case string.trim(text) {
        "" -> json_response(400, err_json("empty message"))
        trimmed -> {
          // Auto-title at the send boundary: this is the only place that
          // sees the outgoing text, so message content never has to cross
          // the thread→registry path. The transcript always carries the
          // system prompt, so "no user message yet" is a count of 1; only
          // the first-ever message titles the thread, and the registry
          // additionally refuses to clobber a manual (or already
          // generated) title.
          let is_first = thread.describe(thread).message_count <= 1
          case thread.send_message(thread, trimmed) {
            thread.Sent -> {
              case is_first {
                True -> {
                  let _ =
                    thread_registry.auto_title(
                      registry,
                      id,
                      thread_registry.title_from_first_message(trimmed),
                    )
                  Nil
                }
                False -> Nil
              }
              json_response(202, json.object([#("ok", json.bool(True))]))
            }
            thread.Busy ->
              json_response(409, err_json("a reply is already streaming"))
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Provider routes (multi-provider §11, P4)
// ---------------------------------------------------------------------------

/// Masked metadata only — `has_key`, never key material.
fn providers_response(
  providers: process.Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  case provider_registry.list_providers(providers) {
    Ok(all) -> json_response(200, providers_json(all))
    Error(error) -> registry_error_response(error)
  }
}

/// Validation, normalization, and encryption all live in the registry;
/// the route only decodes and maps errors.
fn create_provider_response(
  req: Request(mist.Connection),
  providers: process.Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  case read_provider_create(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) ->
      case
        provider_registry.create(
          providers,
          provider.ProviderParams(
            name: fields.name,
            base_url: fields.base_url,
            api_key: fields.api_key,
          ),
        )
      {
        Ok(created) -> json_response(201, provider_json(created))
        Error(error) -> registry_error_response(error)
      }
  }
}

fn patch_provider_response(
  req: Request(mist.Connection),
  providers: process.Subject(provider_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case read_provider_patch(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) -> {
      // A present-but-blank api_key means "keep" (there is no
      // remove-key patch), so normalize it away BEFORE the empty check:
      // `{"api_key":"  "}` is an empty patch, not a silent 200.
      let patch =
        provider.ProviderUpdate(
          name: fields.name,
          base_url: fields.base_url,
          api_key: blank_as_none(fields.api_key),
          enabled: fields.enabled,
        )
      case empty_provider_patch(patch) {
        True -> json_response(400, err_json("empty patch"))
        False ->
          case provider_registry.update(providers, id, patch) {
            Ok(updated) -> json_response(200, provider_json(updated))
            Error(error) -> registry_error_response(error)
          }
      }
    }
  }
}

fn delete_provider_response(
  providers: process.Subject(provider_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case provider_registry.delete(providers, id) {
    // The registry's StillReferenced (the 409 guard) lands in
    // registry_error_response, as does Unknown (404).
    Ok(Nil) ->
      response.new(204)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    Error(error) -> registry_error_response(error)
  }
}

fn provider_models_response(
  cfg: Config,
  providers: process.Subject(provider_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  // Same budget as the thread-create preflight (the shared rule in
  // thread_create): the live fetch mirrors the endpoint's first-response
  // timeout, plus round-trip headroom.
  case
    provider_registry.list_models(
      providers,
      id,
      thread_create.models_timeout(cfg),
    )
  {
    Ok(models) -> json_response(200, models_json(models))
    Error(error) -> registry_error_response(error)
  }
}

/// The registry's closed error vocabulary onto the plan's status codes
/// (§11). Body text is always `describe`'s fixed string — never operator
/// input beyond the id the caller already knows, never key material.
pub fn registry_error_fields(
  error: provider_registry.RegistryError,
) -> #(Int, String) {
  let status = case error {
    provider_registry.Unknown -> 404
    provider_registry.Disabled -> 400
    provider_registry.InvalidName -> 400
    provider_registry.InvalidBaseUrl -> 400
    provider_registry.DuplicateName -> 409
    provider_registry.StillReferenced -> 409
    provider_registry.DecryptFailed -> 500
    provider_registry.KeyOperationFailed -> 500
    provider_registry.StoreFailed(_) -> 502
    provider_registry.ModelsFailed(_) -> 502
  }
  #(status, provider_registry.describe(error))
}

fn registry_error_response(
  error: provider_registry.RegistryError,
) -> Response(mist.ResponseData) {
  let #(status, message) = registry_error_fields(error)
  json_response(status, err_json(message))
}

// ---------------------------------------------------------------------------
// Bot routes (bots plan P1)
// ---------------------------------------------------------------------------

/// All bots, name-then-id sorted (the registry's order).
fn bots_response(
  bots: process.Subject(bot_registry.Msg),
) -> Response(mist.ResponseData) {
  case bot_registry.list_bots(bots) {
    Ok(all) -> json_response(200, bots_json(all))
    Error(error) -> bot_error_response(error)
  }
}

/// Create: decode, validate `provider_id` against the provider registry
/// THIS LAYER already holds (the friendly 400 — the bot registry never
/// resolves providers; the FK is the backstop), then hand off.
fn create_bot_response(
  req: Request(mist.Connection),
  bots: process.Subject(bot_registry.Msg),
  providers: process.Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  case read_bot_create(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) ->
      case resolve_bot_provider(providers, string.trim(fields.provider_id)) {
        Error(_) -> providers_unavailable_response()
        Ok(None) -> json_response(400, err_json("unknown provider"))
        Ok(Some(provider_id)) ->
          case
            bot_registry.create_bot(
              bots,
              bot.BotParams(
                name: fields.name,
                description: fields.description,
                provider_id: provider_id,
                model: fields.model,
                system_prompt: fields.system_prompt,
                tools: fields.tools,
              ),
            )
          {
            Ok(created) -> json_response(201, bot_json(created))
            Error(error) -> bot_error_response(error)
          }
      }
  }
}

/// PATCH: present fields replace, absent keep. A present `provider_id`
/// (a PATCH can move a bot between providers) is validated like the
/// create's.
fn patch_bot_response(
  req: Request(mist.Connection),
  bots: process.Subject(bot_registry.Msg),
  id: String,
  providers: process.Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  case read_bot_patch(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) -> {
      let patch =
        bot.BotUpdate(
          name: fields.name,
          description: fields.description,
          provider_id: fields.provider_id,
          model: fields.model,
          system_prompt: fields.system_prompt,
          tools: fields.tools,
          allow_inbound: fields.allow_inbound,
        )
      case bot.empty_update(patch) {
        True -> json_response(400, err_json("empty patch"))
        False ->
          // A present provider_id (a PATCH can move a bot between
          // providers) is validated and canonicalized like the create's.
          case fields.provider_id {
            Some(ident) ->
              case resolve_bot_provider(providers, string.trim(ident)) {
                Error(_) -> providers_unavailable_response()
                Ok(None) -> json_response(400, err_json("unknown provider"))
                Ok(Some(provider_id)) ->
                  apply_bot_patch(
                    bots,
                    id,
                    bot.BotUpdate(..patch, provider_id: Some(provider_id)),
                  )
              }
            None -> apply_bot_patch(bots, id, patch)
          }
      }
    }
  }
}

fn apply_bot_patch(
  bots: process.Subject(bot_registry.Msg),
  id: String,
  patch: bot.BotUpdate,
) -> Response(mist.ResponseData) {
  case bot_registry.update_bot(bots, id, patch) {
    Ok(updated) -> json_response(200, bot_json(updated))
    Error(error) -> bot_error_response(error)
  }
}

fn delete_bot_response(
  registry: process.Subject(thread_registry.Msg),
  bots: process.Subject(bot_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case bot_registry.delete_bot(bots, id) {
    // Unguarded by design: threads carry ON DELETE SET NULL provenance,
    // so deleting a bot orphans nothing. The FK already NULLed every
    // stored row inside the delete; this scrub clears the thread
    // registry's in-memory mirror so summaries stop reporting the dead
    // id before the next rehydration.
    Ok(Nil) -> {
      thread_registry.bot_deleted(registry, id)
      response.new(204) |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    Error(error) -> bot_error_response(error)
  }
}

/// Friendly provider existence check against the registry this layer
/// already holds (the no-cross-registry-edge rule: validation lives with
/// the CALLER, the FK is the backstop). Like `POST /threads`, the
/// identifier may be an id or a name — the id checked first — but
/// unlike a thread create, a DISABLED provider is acceptable (a bot is
/// a template, not a runtime pin: it only blocks NEW threads, and
/// re-aiming the bot is the cure). `Ok(None)` is no matching provider
/// (the friendly 400); `Error(Nil)` is an unreachable registry — a
/// server-side failure the caller maps to 502 like thread create's
/// `ProvidersUnavailable`, never a client 400 (the FK backstop cannot
/// distinguish "no such provider" from "could not ask").
fn resolve_bot_provider(
  providers: process.Subject(provider_registry.Msg),
  ident: String,
) -> Result(Option(String), Nil) {
  case provider_registry.list_providers(providers) {
    Error(_) -> Error(Nil)
    Ok(all) -> {
      let found = case list.find(all, fn(p) { p.id == ident }) {
        Ok(by_id) -> Ok(by_id)
        Error(_) -> list.find(all, fn(p) { p.name == ident })
      }
      Ok(case found {
        Ok(found) -> Some(found.id)
        Error(_) -> None
      })
    }
  }
}

/// The unreachable-provider-registry 502, shared by bot create and
/// PATCH — same status and text as thread create's
/// `ProvidersUnavailable`.
fn providers_unavailable_response() -> Response(mist.ResponseData) {
  json_response(
    502,
    err_json(thread_create.describe(thread_create.ProvidersUnavailable)),
  )
}

/// The bot registry's closed error vocabulary onto status codes —
/// mapped exactly like `registry_error_fields`.
pub fn bot_error_fields(error: bot_registry.RegistryError) -> #(Int, String) {
  let status = case error {
    bot_registry.Unknown -> 404
    bot_registry.InvalidName -> 400
    bot_registry.InvalidModel -> 400
    bot_registry.InvalidTools(_) -> 400
    bot_registry.DuplicateName -> 409
    bot_registry.StoreFailed(_) -> 502
  }
  #(status, bot_registry.describe(error))
}

fn bot_error_response(
  error: bot_registry.RegistryError,
) -> Response(mist.ResponseData) {
  let #(status, message) = bot_error_fields(error)
  json_response(status, err_json(message))
}

// ---------------------------------------------------------------------------
// Thread metadata routes (PATCH / DELETE)
// ---------------------------------------------------------------------------

/// The PATCH /threads/<id> body: present keys are applied, absent keys
/// untouched. Presence of `title` implies a manual rename.
pub type PatchFields {
  PatchFields(
    title: Option(String),
    pinned: Option(Bool),
    tags: Option(List(String)),
    archived: Option(Bool),
  )
}

fn empty_patch(fields: PatchFields) -> Bool {
  option.is_none(fields.title)
  && option.is_none(fields.pinned)
  && option.is_none(fields.tags)
  && option.is_none(fields.archived)
}

pub fn patch_fields_decoder() -> decode.Decoder(PatchFields) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use pinned <- decode.optional_field(
    "pinned",
    None,
    decode.optional(decode.bool),
  )
  use tags <- decode.optional_field(
    "tags",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use archived <- decode.optional_field(
    "archived",
    None,
    decode.optional(decode.bool),
  )
  decode.success(PatchFields(title:, pinned:, tags:, archived:))
}

pub fn parse_patch_json(body: String) -> Result(PatchFields, Nil) {
  json.parse(body, using: patch_fields_decoder())
  |> result.map_error(fn(_) { Nil })
}

fn read_patch(req: Request(mist.Connection)) -> Result(PatchFields, Nil) {
  case mist.read_body(req, max_body_limit: 1_000_000) {
    Error(_) -> Error(Nil)
    Ok(read) ->
      case bit_array.to_string(read.body) {
        Error(_) -> Error(Nil)
        Ok(body) -> parse_patch_json(body)
      }
  }
}

fn patch_thread_response(
  req: Request(mist.Connection),
  registry: process.Subject(thread_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case read_patch(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) ->
      case empty_patch(fields) {
        True -> json_response(400, err_json("empty patch"))
        False ->
          case fields.title {
            Some(title) ->
              case string.trim(title) {
                "" -> json_response(400, err_json("empty title"))
                _ -> apply_patch(registry, id, fields)
              }
            None -> apply_patch(registry, id, fields)
          }
      }
  }
}

/// Apply the present fields, then answer with the refreshed summary.
fn apply_patch(
  registry: process.Subject(thread_registry.Msg),
  id: String,
  fields: PatchFields,
) -> Response(mist.ResponseData) {
  // Invariant: an archived thread is never pinned. A patch that pins an
  // archived thread without restoring it in the same call is rejected
  // wholesale (409) — one that restores *and* pins is fine, because the
  // archive state applies before the pin below.
  let find =
    thread_registry.list_threads(registry)
    |> list.find(fn(summary) { summary.id == id })
  case find {
    Error(_) -> json_response(404, err_json("thread not found"))
    Ok(current) -> {
      let restores = fields.archived == Some(False)
      let pin_conflicts = case fields.pinned {
        Some(True) -> current.archived && !restores
        _ -> False
      }
      case pin_conflicts {
        True -> json_response(409, err_json("cannot pin an archived thread"))
        False -> {
          let applied =
            [
              // Archive state first, so a restore+pin patch applies cleanly.
              case fields.archived {
                Some(archived) ->
                  thread_registry.set_archived(registry, id, archived)
                None -> True
              },
              case fields.title {
                Some(title) -> thread_registry.set_title(registry, id, title)
                None -> True
              },
              case fields.tags {
                Some(tags) -> thread_registry.set_tags(registry, id, tags)
                None -> True
              },
              case fields.pinned {
                Some(pinned) -> thread_registry.set_pinned(registry, id, pinned)
                None -> True
              },
            ]
            |> list.all(fn(ok) { ok })
          case applied {
            False -> json_response(404, err_json("thread not found"))
            True ->
              case
                thread_registry.list_threads(registry)
                |> list.find(fn(summary) { summary.id == id })
              {
                Ok(summary) -> json_response(200, thread_summary_json(summary))
                Error(_) -> json_response(404, err_json("thread not found"))
              }
          }
        }
      }
    }
  }
}

fn delete_thread_response(
  registry: process.Subject(thread_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case thread_registry.delete_thread(registry, id) {
    // Hard removal: the registry stopped the child actor first, so a
    // streaming turn is cancelled (partial reply committed) and the row
    // disappears.
    True ->
      response.new(204)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    False -> json_response(404, err_json("thread not found"))
  }
}

fn stop_response(
  thread: process.Subject(thread.Msg),
) -> Response(mist.ResponseData) {
  thread.stop(thread)
  json_response(202, json.object([#("ok", json.bool(True))]))
}

// ---------------------------------------------------------------------------
// Pure helpers (offline-testable)
// ---------------------------------------------------------------------------

/// Single-token auth (PRD hard req. 5). `None` disables auth. A plain
/// `<script src>` (the Lustre runtime asset) cannot set headers, so the
/// token may also arrive as `?token=` — the page passes it through from
/// its own query string into the runtime asset URL and the `/ws` route.
pub fn authorized(req: Request(a), token: Option(String)) -> Bool {
  case token {
    None -> True
    Some(expected) -> {
      let header_ok =
        request.get_header(req, "authorization") == Ok("Bearer " <> expected)
      let query_ok = query_param(req, "token") == Ok(expected)
      header_ok || query_ok
    }
  }
}

fn query_param(req: Request(a), name: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(pairs) ->
      list.find_map(pairs, fn(pair) {
        case pair {
          #(key, value) if key == name -> Ok(value)
          _ -> Error(Nil)
        }
      })
    Error(_) -> Error(Nil)
  }
}

/// Wire shape for one stored metric sample. Display-only data:
/// it never crosses into `nexus/transcript`.
fn metric_sample_json(sample: thread.MetricSample) -> Json {
  let outcome = case sample.outcome {
    thread.Completed -> "completed"
    thread.Stopped -> "stopped"
    thread.Failed -> "failed"
  }
  json.object([
    #("outcome", json.string(outcome)),
    #("ttft_ms", optional_int_json(sample.ttft_ms)),
    #("duration_ms", json.int(sample.duration_ms)),
    #("token_deltas", json.int(sample.token_deltas)),
    #("prompt_tokens", optional_int_json(sample.prompt_tokens)),
    #("cached_tokens", optional_int_json(sample.cached_tokens)),
    #("stopped_chars", optional_int_json(sample.stopped_chars)),
    #("failure_reason", case sample.failure_reason {
      Some(reason) -> json.string(reason)
      None -> json.null()
    }),
  ])
}

fn metrics_json(samples: List(thread.MetricSample)) -> Json {
  json.array(samples, metric_sample_json)
}

fn optional_int_json(value: Option(Int)) -> Json {
  case value {
    Some(n) -> json.int(n)
    None -> json.null()
  }
}

// ---------------------------------------------------------------------------
// Small response / decode helpers
// ---------------------------------------------------------------------------

fn json_response(status: Int, body: Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

fn err_json(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

pub fn models_json(models: List(String)) -> Json {
  json.object([#("models", json.array(models, json.string))])
}

pub fn providers_json(all: List(provider.Provider)) -> Json {
  json.object([#("providers", json.array(all, provider_json))])
}

pub fn bots_json(all: List(bot.Bot)) -> Json {
  json.object([#("bots", json.array(all, bot_json))])
}

/// The bot wire shape. No masked twin — bots carry no secrets, so the
/// row IS the public shape (`nexus/bot`). Every field is hostile text
/// on the client side.
pub fn bot_json(b: bot.Bot) -> Json {
  json.object([
    #("id", json.string(b.id)),
    #("name", json.string(b.name)),
    #("description", json.string(b.description)),
    #("provider_id", json.string(b.provider_id)),
    #("model", json.string(b.model)),
    #("system_prompt", case b.system_prompt {
      Some(prompt) -> json.string(prompt)
      None -> json.null()
    }),
    // The live template's toolset (bots plan P2): null = the current
    // default at thread-create time; [] = chat-only; else the explicit
    // names, in wire order.
    #("tools", case b.tools {
      Some(names) -> json.array(names, json.string)
      None -> json.null()
    }),
    // The inbound gate (bots plan P3a): false blocks other bots from
    // delivering into this bot's threads (the P3c guard will enforce it).
    #("allow_inbound", json.bool(b.allow_inbound)),
    #("created_at", json.int(b.created_at)),
    #("created_at_rfc3339", json.string(timing.wall_to_rfc3339(b.created_at))),
    #("updated_at", json.int(b.updated_at)),
    #("updated_at_rfc3339", json.string(timing.wall_to_rfc3339(b.updated_at))),
  ])
}

/// Masked provider wire shape: `has_key` is the only key fact on the
/// wire — structurally incapable of carrying key material (the masked
/// record does not contain it).
pub fn provider_json(p: provider.Provider) -> Json {
  json.object([
    #("id", json.string(p.id)),
    #("name", json.string(p.name)),
    #("base_url", json.string(p.base_url)),
    #("dialect", json.string(p.dialect)),
    #("enabled", json.bool(p.enabled)),
    #("has_key", json.bool(p.has_key)),
    // Same epoch + RFC3339 twin convention as thread summaries.
    #("created_at", json.int(p.created_at)),
    #("created_at_rfc3339", json.string(timing.wall_to_rfc3339(p.created_at))),
    #("updated_at", json.int(p.updated_at)),
    #("updated_at_rfc3339", json.string(timing.wall_to_rfc3339(p.updated_at))),
  ])
}

pub fn threads_json(summaries: List(thread.ThreadSummary)) -> Json {
  json.object([#("threads", json.array(summaries, thread_summary_json))])
}

pub fn thread_summary_json(summary: thread.ThreadSummary) -> Json {
  json.object([
    #("id", json.string(summary.id)),
    #("provider_id", json.string(summary.provider_id)),
    #("model", json.string(summary.model)),
    #("title", json.string(summary.title)),
    #("title_source", case summary.title_source {
      thread.AutoTitle -> json.string("auto")
      thread.ManualTitle -> json.string("manual")
    }),
    #("pinned", json.bool(summary.pinned)),
    #("tags", json.array(summary.tags, json.string)),
    #("archived", json.bool(summary.archived)),
    // Provenance (bots plan P1): the bot this thread was created from,
    // null for a plain create. Display-only — never a request byte.
    #("bot_id", case summary.bot_id {
      Some(bot_id) -> json.string(bot_id)
      None -> json.null()
    }),
    #("message_count", json.int(summary.message_count)),
    #("streaming", json.bool(summary.streaming)),
    // Epoch ints are what clients sort and bucket on; the RFC3339 twin is
    // the human-readable rendering. Both are metadata — display only.
    #("created_at", json.int(summary.created_at)),
    #(
      "created_at_rfc3339",
      json.string(timing.wall_to_rfc3339(summary.created_at)),
    ),
    #("last_active_at", json.int(summary.last_active_at)),
    #(
      "last_active_rfc3339",
      json.string(timing.wall_to_rfc3339(summary.last_active_at)),
    ),
    #("metrics", metrics_json(summary.metrics)),
  ])
}

fn unauthorized() -> Response(mist.ResponseData) {
  json_response(401, err_json("unauthorized"))
}

fn text_decoder() -> decode.Decoder(String) {
  use text <- decode.field("text", decode.string)
  decode.success(text)
}

pub fn requires_auth(method: Method, segments: List(String)) -> Bool {
  case method, segments {
    Get, []
    | Get, ["threads"]
    | Get, ["providers"]
    | Get, ["providers", _, "models"]
    | Get, ["bots"]
    | Get, ["lustre", "runtime.mjs"]
    | Get, ["css", "pico.min.css"]
    | Get, ["ws"]
    -> True
    Post, ["threads"]
    | Post, ["threads", _, "send"]
    | Post, ["threads", _, "stop"]
    | Post, ["providers"]
    | Post, ["bots"]
    -> True
    Patch, ["threads", _]
    | Delete, ["threads", _]
    | Patch, ["providers", _]
    | Delete, ["providers", _]
    | Patch, ["bots", _]
    | Delete, ["bots", _]
    -> True
    _, _ -> False
  }
}

pub fn parse_text_json(body: String) -> Result(String, Nil) {
  json.parse(body, using: text_decoder())
  |> result.map_error(fn(_) { Nil })
}
