//// The HTTP surface: a JSON scripting API (model listing, session CRUD,
//// send, stop), the Lustre shell page with its WebSocket transport
//// (`/ws`, `/lustre/runtime.mjs`), and a health check.
////
//// Mist remains sufficient: the WebSocket upgrade bypasses wisp, and the
//// scripting surface is still small and explicit. The session actor is
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
import nexus/config.{type Config}
import nexus/page
import nexus/provider
import nexus/provider_registry
import nexus/session
import nexus/session_registry
import nexus/timing
import nexus/ui_runtime

/// Registry-backed handler. Sessions are resolved by ID at request time so
/// HTTP traffic reaches the live actor after a registry-owned restart.
/// `providers_name` resolves the provider registry the session-create
/// path validates against (multi-provider plan §11).
pub fn handler(
  cfg: Config,
  registry_name: process.Name(session_registry.Msg),
  providers_name: process.Name(provider_registry.Msg),
  component_name: ui_runtime.ComponentName,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let registry = process.named_subject(registry_name)
  let providers = process.named_subject(providers_name)
  fn(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
    case req.method, request.path_segments(req) {
      Get, [] -> protected(cfg, req, fn() { page_response(cfg.ui_token) })
      Get, ["sessions"] ->
        protected(cfg, req, fn() { sessions_response(registry, req) })
      Post, ["sessions"] ->
        protected(cfg, req, fn() {
          create_session_response(cfg, req, registry, providers)
        })
      Patch, ["sessions", id] ->
        protected(cfg, req, fn() { patch_session_response(req, registry, id) })
      Delete, ["sessions", id] ->
        protected(cfg, req, fn() { delete_session_response(registry, id) })
      Post, ["sessions", id, "send"] ->
        protected(cfg, req, fn() {
          with_session(registry, id, send_response(req, registry, id, _))
        })
      Post, ["sessions", id, "stop"] ->
        protected(cfg, req, fn() { with_session(registry, id, stop_response) })
      Get, ["healthz"] ->
        json_response(200, json.object([#("ok", json.bool(True))]))
      Get, ["lustre", "runtime.mjs"] ->
        protected(cfg, req, fn() { runtime_asset_response() })
      Get, ["ws"] ->
        protected(cfg, req, fn() {
          ui_runtime.websocket(
            req,
            ui_runtime.runtime_from_name(component_name),
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

fn with_session(
  registry: process.Subject(session_registry.Msg),
  id: String,
  then: fn(process.Subject(session.Msg)) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let summaries = session_registry.list_sessions(registry)
  case list.any(summaries, fn(summary) { summary.id == id }) {
    False -> json_response(404, err_json("session not found"))
    True ->
      case session_registry.get(registry, id) {
        Ok(subject) -> then(subject)
        Error(_) -> json_response(503, err_json("session unavailable"))
      }
  }
}

// GET /models is gone (multi-provider §11): with N providers there is
// no "default" endpoint to answer it — callers ask the provider-scoped
// surface instead (P4's GET /providers/<id>/models; the registry's
// ListModels message already exists).

fn sessions_response(
  registry: process.Subject(session_registry.Msg),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let summaries =
    session_registry.list_sessions(registry)
    |> filter_archived(wants_archived(req))
  json_response(200, sessions_json(summaries))
}

/// `?archived=1` (or `true`) flips the list from the default active-only
/// view to archived-only. Pure — offline-testable.
pub fn filter_archived(
  summaries: List(session.SessionSummary),
  want_archived: Bool,
) -> List(session.SessionSummary) {
  list.filter(summaries, fn(summary) { summary.archived == want_archived })
}

fn wants_archived(req: Request(a)) -> Bool {
  case query_param(req, "archived") {
    Ok("1") | Ok("true") -> True
    _ -> False
  }
}

fn create_session_response(
  cfg: Config,
  req: Request(mist.Connection),
  registry: process.Subject(session_registry.Msg),
  providers: process.Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  // Multi-provider §11: the body pins BOTH halves of the session's
  // identity — `provider` (id or name) and `model` (alias). There is no
  // default provider to fall back to; both fields are required.
  case read_create(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(fields) ->
      case string.trim(fields.model), string.trim(fields.provider) {
        _, "" -> json_response(400, err_json("empty provider"))
        "", _ -> json_response(400, err_json("empty model"))
        trimmed_model, ident ->
          case resolve_provider(providers, ident) {
            Error(#(status, reason)) -> json_response(status, err_json(reason))
            Ok(found) ->
              // Validate the alias against the provider's own live model
              // list — the same preflight the old single-provider route
              // did, now scoped to the pinned provider.
              case
                provider_registry.list_models(
                  providers,
                  found.id,
                  cfg.sse_first_response_timeout_ms + 5000,
                )
              {
                Error(_) ->
                  json_response(
                    502,
                    err_json("unable to list models from provider"),
                  )
                Ok(models) ->
                  case list.contains(models, trimmed_model) {
                    False ->
                      json_response(
                        400,
                        err_json("unknown model: " <> trimmed_model),
                      )
                    True ->
                      case
                        session_registry.create(
                          registry,
                          found.id,
                          trimmed_model,
                        )
                      {
                        Ok(record) -> {
                          let now = timing.wall_now_s()
                          json_response(
                            201,
                            session_summary_json(
                              session.SessionSummary(
                                id: record.id,
                                model: record.model,
                                title: "",
                                title_source: session.AutoTitle,
                                pinned: False,
                                tags: [],
                                archived: False,
                                message_count: 0,
                                streaming: False,
                                created_at: now,
                                last_active_at: now,
                                metrics: [],
                              ),
                            ),
                          )
                        }
                        Error(session_registry.EmptyModel) ->
                          json_response(400, err_json("empty model"))
                        Error(session_registry.ProviderFailed(_)) ->
                          // Pre-validation above owned the 400s; landing
                          // here means the provider went away between
                          // validation and create — a server-side race.
                          json_response(
                            502,
                            err_json("provider became unusable"),
                          )
                        Error(session_registry.StartFailed(reason)) ->
                          json_response(
                            503,
                            err_json("session unavailable: " <> reason),
                          )
                      }
                  }
              }
          }
      }
  }
}

/// Resolve the request's provider identifier (id or name) to registry
/// metadata, refusing unknown and disabled providers with the plan's
/// status mapping (§11: unknown → 400, disabled → 400). An exact ID match
/// is checked FIRST: names are free-form, so a provider may be *named*
/// after another provider's id — the id is the unambiguous key and must
/// win when the two disagree.
fn resolve_provider(
  providers: process.Subject(provider_registry.Msg),
  ident: String,
) -> Result(provider.Provider, #(Int, String)) {
  case provider_registry.list_providers(providers) {
    Error(_) -> Error(#(502, "provider registry unavailable"))
    Ok(all) -> {
      let found = case list.find(all, fn(p) { p.id == ident }) {
        Ok(by_id) -> Ok(by_id)
        Error(_) -> list.find(all, fn(p) { p.name == ident })
      }
      case found {
        Error(_) -> Error(#(400, "unknown provider: " <> ident))
        Ok(found) ->
          case found.enabled {
            False -> Error(#(400, "provider is disabled: " <> found.name))
            True -> Ok(found)
          }
      }
    }
  }
}

fn read_json(req: Request(mist.Connection)) -> Result(String, Nil) {
  read_body_json(req, text_decoder())
}

/// The POST /sessions body: `{"provider": …, "model": …}` (both
/// required — a session always pins its provider explicitly).
pub type CreateFields {
  CreateFields(provider: String, model: String)
}

pub fn create_fields_decoder() -> decode.Decoder(CreateFields) {
  use provider_id <- decode.field("provider", decode.string)
  use model <- decode.field("model", decode.string)
  decode.success(CreateFields(provider: provider_id, model: model))
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
  registry: process.Subject(session_registry.Msg),
  id: String,
  session: process.Subject(session.Msg),
) -> Response(mist.ResponseData) {
  case read_json(req) {
    Error(_) -> json_response(400, err_json("unreadable body"))
    Ok(text) ->
      case string.trim(text) {
        "" -> json_response(400, err_json("empty message"))
        trimmed -> {
          // Auto-title at the send boundary: this is the only place that
          // sees the outgoing text, so message content never has to cross
          // the session→registry path. The transcript always carries the
          // system prompt, so "no user message yet" is a count of 1; only
          // the first-ever message titles the session, and the registry
          // additionally refuses to clobber a manual (or already
          // generated) title.
          let is_first = session.describe(session).message_count <= 1
          case session.send_message(session, trimmed) {
            session.Sent -> {
              case is_first {
                True -> {
                  let _ =
                    session_registry.auto_title(
                      registry,
                      id,
                      session_registry.title_from_first_message(trimmed),
                    )
                  Nil
                }
                False -> Nil
              }
              json_response(202, json.object([#("ok", json.bool(True))]))
            }
            session.Busy ->
              json_response(409, err_json("a reply is already streaming"))
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Session metadata routes (PATCH / DELETE)
// ---------------------------------------------------------------------------

/// The PATCH /sessions/<id> body: present keys are applied, absent keys
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

fn patch_session_response(
  req: Request(mist.Connection),
  registry: process.Subject(session_registry.Msg),
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
  registry: process.Subject(session_registry.Msg),
  id: String,
  fields: PatchFields,
) -> Response(mist.ResponseData) {
  // Invariant: an archived session is never pinned. A patch that pins an
  // archived session without restoring it in the same call is rejected
  // wholesale (409) — one that restores *and* pins is fine, because the
  // archive state applies before the pin below.
  let find =
    session_registry.list_sessions(registry)
    |> list.find(fn(summary) { summary.id == id })
  case find {
    Error(_) -> json_response(404, err_json("session not found"))
    Ok(current) -> {
      let restores = fields.archived == Some(False)
      let pin_conflicts = case fields.pinned {
        Some(True) -> current.archived && !restores
        _ -> False
      }
      case pin_conflicts {
        True -> json_response(409, err_json("cannot pin an archived session"))
        False -> {
          let applied =
            [
              // Archive state first, so a restore+pin patch applies cleanly.
              case fields.archived {
                Some(archived) ->
                  session_registry.set_archived(registry, id, archived)
                None -> True
              },
              case fields.title {
                Some(title) -> session_registry.set_title(registry, id, title)
                None -> True
              },
              case fields.tags {
                Some(tags) -> session_registry.set_tags(registry, id, tags)
                None -> True
              },
              case fields.pinned {
                Some(pinned) ->
                  session_registry.set_pinned(registry, id, pinned)
                None -> True
              },
            ]
            |> list.all(fn(ok) { ok })
          case applied {
            False -> json_response(404, err_json("session not found"))
            True ->
              case
                session_registry.list_sessions(registry)
                |> list.find(fn(summary) { summary.id == id })
              {
                Ok(summary) -> json_response(200, session_summary_json(summary))
                Error(_) -> json_response(404, err_json("session not found"))
              }
          }
        }
      }
    }
  }
}

fn delete_session_response(
  registry: process.Subject(session_registry.Msg),
  id: String,
) -> Response(mist.ResponseData) {
  case session_registry.delete_session(registry, id) {
    // Hard removal: the registry stopped the child actor first, so a
    // streaming turn is cancelled (partial reply committed) and the row
    // disappears.
    True ->
      response.new(204)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    False -> json_response(404, err_json("session not found"))
  }
}

fn stop_response(
  session: process.Subject(session.Msg),
) -> Response(mist.ResponseData) {
  session.stop(session)
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
fn metric_sample_json(sample: session.MetricSample) -> Json {
  let outcome = case sample.outcome {
    session.Completed -> "completed"
    session.Stopped -> "stopped"
    session.Failed -> "failed"
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

fn metrics_json(samples: List(session.MetricSample)) -> Json {
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

pub fn sessions_json(summaries: List(session.SessionSummary)) -> Json {
  json.object([#("sessions", json.array(summaries, session_summary_json))])
}

pub fn session_summary_json(summary: session.SessionSummary) -> Json {
  json.object([
    #("id", json.string(summary.id)),
    #("model", json.string(summary.model)),
    #("title", json.string(summary.title)),
    #("title_source", case summary.title_source {
      session.AutoTitle -> json.string("auto")
      session.ManualTitle -> json.string("manual")
    }),
    #("pinned", json.bool(summary.pinned)),
    #("tags", json.array(summary.tags, json.string)),
    #("archived", json.bool(summary.archived)),
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
    | Get, ["sessions"]
    | Get, ["lustre", "runtime.mjs"]
    | Get, ["ws"]
    -> True
    Post, ["sessions"]
    | Post, ["sessions", _, "send"]
    | Post, ["sessions", _, "stop"]
    -> True
    Patch, ["sessions", _] | Delete, ["sessions", _] -> True
    _, _ -> False
  }
}

pub fn parse_text_json(body: String) -> Result(String, Nil) {
  json.parse(body, using: text_decoder())
  |> result.map_error(fn(_) { Nil })
}
