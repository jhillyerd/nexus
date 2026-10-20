//// Live-loopback route tests for the M3 session-organization surface:
//// PATCH/DELETE /sessions/<id>, the archived query on GET /sessions, and
//// the auto-title-at-send boundary — over a real mist server and a real
//// registry (fake turn runner; no Bifrost, no network beyond loopback).

import gleam/erlang/process
import gleam/http.{Delete, Get, Patch, Post}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import mist
import nexus/config.{type Config}
import nexus/hackney
import nexus/loop
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/session
import nexus/session_registry
import nexus/timing
import nexus/transcript
import nexus/web
import store_mock

const token = "sekrit"

fn test_config() -> Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 0,
    ui_token: Some(token),
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
  )
}

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  session.StreamDone(fake_stats(), transcript.append_assistant(tr, "hi"))
}

fn fake_stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(1),
    duration_ms: 2,
    token_deltas: 1,
    tool_call_deltas: 0,
    events_parsed: 1,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Boot factory + registry + mist once; hand back the registry subject.
/// One mist listener per test: the port is derived from the monotonic
/// microsecond clock, so concurrent/serial start_server calls never bind
/// the same port.
fn start_server() -> #(process.Subject(session_registry.Msg), Int) {
  let #(registry, _providers, port) = start_server_with(fn(_providers) { Nil })
  #(registry, port)
}

/// The full rig: factory + store mock + REAL provider registry (per-base-
/// URL model fetcher, so tests can tell providers apart) + session
/// registry + mist. `extra` runs against the fresh provider registry
/// before the server starts — used to set up colliding providers.
fn start_server_with(
  extra: fn(process.Subject(provider_registry.Msg)) -> Nil,
) -> #(
  process.Subject(session_registry.Msg),
  process.Subject(provider_registry.Msg),
  Int,
) {
  let port = 20_000 + { int.absolute_value(timing.now_us()) % 40_000 }
  let cfg = test_config()
  let factory_name = process.new_name("nexus_routes_factory")
  let registry_name = process.new_name("nexus_routes_registry")
  let providers_name = process.new_name("nexus_routes_providers")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  // The REAL provider registry over the same mock store, with the live
  // model fetch replaced by a fixed alias list — offline, like the rest
  // of the suite. The session registry resolves through it exactly like
  // boot does.
  let assert Ok(_providers) =
    provider_registry.start_with_model_fetcher(
      cfg,
      persistence,
      providers_name,
      fn(endpoint) {
        case endpoint.base_url {
          // Per-provider lists let tests observe WHICH provider a create
          // resolved — the one distinguishing signal on this rig.
          "https://gamma.test/v1" -> Ok(["gamma-only"])
          _ -> Ok(["default-alias", "alias-a", "alias-b"])
        }
      },
    )
  let providers = process.named_subject(providers_name)
  extra(providers)
  let assert Ok(started) =
    session_registry.start(
      cfg,
      factory_supervisor.get_by_name(factory_name),
      registry_name,
      persistence,
      fn(id) {
        provider_registry.resolve(providers, id)
        |> result.map(fn(resolved) { resolved.endpoint })
        |> result.replace_error(session_registry.ProviderUnknown)
      },
    )
  let _ =
    mist.new(web.handler(cfg, registry_name, providers_name))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  process.sleep(100)
  #(started.data, providers, port)
}

/// Create a keyless provider through the real registry (ids are minted
/// p1, p2, … past the fixture's).
fn create_provider(
  providers: process.Subject(provider_registry.Msg),
  name: String,
  base_url: String,
) -> Nil {
  let assert Ok(_) =
    actor.call(providers, 5000, fn(reply) {
      provider_registry.Create(
        provider.ProviderParams(name: name, base_url: base_url, api_key: None),
        reply,
      )
    })
  Nil
}

fn req(
  port: Int,
  method: http.Method,
  path: String,
  body: String,
) -> Request(String) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> path)
  request.set_body(req, body)
  |> request.set_method(method)
}

fn authorized(req: Request(String)) -> Request(String) {
  request.set_header(req, "authorization", "Bearer " <> token)
}

fn send_authorized(req: Request(String)) -> #(Int, String) {
  let assert Ok(response) = hackney.send(authorized(req))
  #(response.status, response.body)
}

/// Wait until the freshly created session's fake turn has committed.
fn drain_turn(subject: process.Subject(session.Msg)) -> Nil {
  let sub = process.new_subject()
  process.send(subject, session.Join(sub))
  let _ = process.receive(sub, 2000)
  // hello + user echo + assistant + turn done
  list.each(range(4), fn(_) {
    let _ = process.receive(sub, 2000)
    Nil
  })
}

fn range(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, ..range(n - 1)]
  }
}

fn session_ids(body: String) -> List(String) {
  // Lightweight extraction: pull "id":"s…" pairs out of the JSON array.
  body
  |> string.split("\"id\":\"")
  |> list.drop(1)
  |> list.map(fn(rest) { string.split(rest, "\"") |> list.first |> unwrap })
  |> list.filter(fn(id) { string.starts_with(id, "s") })
}

fn unwrap(value: Result(String, Nil)) -> String {
  case value {
    Ok(text) -> text
    Error(_) -> ""
  }
}

pub fn patch_delete_and_archive_routes_test() {
  let #(registry, port) = start_server()
  let assert Ok(record) =
    session_registry.create_with_runner(
      registry,
      store_mock.fixture_provider_id,
      "alpha",
      happy_runner,
    )

  // ---- auth gates the new routes --------------------------------------
  // A PATCH without the token never reaches the handler.
  let assert Ok(denied) =
    hackney.send(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"pinned\":true}",
    ))
  should.equal(denied.status, 401)
  let assert Ok(unauthorized) =
    hackney.send(req(port, Delete, "/sessions/" <> record.id, ""))
  should.equal(unauthorized.status, 401)

  // ---- auto-title at the send boundary --------------------------------
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions/" <> record.id <> "/send",
      "{\"text\":\"  first   message\\nhere  \"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  drain_turn(record.subject)
  let #(status, body) = send_authorized(req(port, Get, "/sessions", ""))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"title\":\"first message here\""))
  should.be_true(string.contains(body, "\"title_source\":\"auto\""))
  should.be_true(string.contains(body, "\"pinned\":false"))
  should.be_true(string.contains(body, "\"archived\":false"))
  should.be_true(string.contains(body, "\"created_at\":"))
  should.be_true(string.contains(body, "\"last_active_rfc3339\":\""))

  // ---- PATCH: rename + pin + tag in one call ---------------------------
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"title\":\"Renamed\",\"pinned\":true,\"tags\":[\"ops\",\"ops\"]}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"title\":\"Renamed\""))
  should.be_true(string.contains(body, "\"title_source\":\"manual\""))
  should.be_true(string.contains(body, "\"pinned\":true"))
  should.be_true(string.contains(body, "\"tags\":[\"ops\"]"))

  // A later auto-title must not clobber the manual rename: send again and
  // check the title survived (message_count is past the first message).
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions/" <> record.id <> "/send",
      "{\"text\":\"second\"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  let #(_status, body) = send_authorized(req(port, Get, "/sessions", ""))
  should.be_true(string.contains(body, "\"title\":\"Renamed\""))

  // ---- archive: soft-hide + archived view + restore --------------------
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"archived\":true}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":true"))

  // Default list hides it; ?archived=1 shows exactly it.
  let #(_status, active) = send_authorized(req(port, Get, "/sessions", ""))
  should.equal(session_ids(active), [])
  let #(_status, archived) =
    send_authorized(req(port, Get, "/sessions?archived=1", ""))
  should.equal(session_ids(archived), [record.id])

  // ---- pinned/archived invariant ----------------------------------------
  // Pinning an archived session via PATCH is rejected wholesale…
  should.equal(
    send_authorized(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"pinned\":true}",
    )),
    #(409, "{\"error\":\"cannot pin an archived session\"}"),
  )
  // …and the refusal changed nothing.
  let #(_status, still) =
    send_authorized(req(port, Get, "/sessions?archived=1", ""))
  should.be_true(string.contains(still, "\"pinned\":false"))
  // A restore+pin in one patch is fine (archive state applies first),
  // and the earlier pin was cleared by archiving, so it re-pins cleanly.
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"archived\":false,\"pinned\":true}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":false"))
  should.be_true(string.contains(body, "\"pinned\":true"))

  // ---- PATCH validation -------------------------------------------------
  should.equal(
    send_authorized(req(port, Patch, "/sessions/" <> record.id, "{}")),
    #(400, "{\"error\":\"empty patch\"}"),
  )
  should.equal(
    send_authorized(req(port, Patch, "/sessions/" <> record.id, "not json")),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Patch,
      "/sessions/" <> record.id,
      "{\"title\":\"  \"}",
    )),
    #(400, "{\"error\":\"empty title\"}"),
  )
  should.equal(
    send_authorized(req(port, Patch, "/sessions/nope", "{\"pinned\":true}")),
    #(404, "{\"error\":\"session not found\"}"),
  )

  // ---- DELETE: hard removal ---------------------------------------------
  should.equal(
    send_authorized(req(port, Delete, "/sessions/" <> record.id, "")),
    #(204, ""),
  )
  let #(_status, after) =
    send_authorized(req(port, Get, "/sessions?archived=1", ""))
  should.equal(session_ids(after), [])
  should.equal(
    send_authorized(req(port, Delete, "/sessions/" <> record.id, "")),
    #(404, "{\"error\":\"session not found\"}"),
  )
  session_registry.get(registry, record.id) |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// P3: POST /sessions pins provider + model
// ---------------------------------------------------------------------------

/// The full create flow over the real (loopback) surface: provider
/// resolved by id, model validated against the provider's list, session
/// created and persisted with the pin.
pub fn create_session_pins_provider_and_model_test() {
  let #(registry, port) = start_server()
  let #(status, body) =
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"alias-a\"}",
    ))
  should.equal(status, 201)
  should.be_true(string.contains(body, "\"model\":\"alias-a\""))
  // The pin is in the stored row too.
  let assert [summary] = session_registry.list_sessions(registry)
  summary.model |> should.equal("alias-a")
  let #(_, listed) = send_authorized(req(port, Get, "/sessions", ""))
  should.be_true(string.contains(listed, "\"model\":\"alias-a\""))
}

/// Provider lookup accepts the NAME as well as the id (plan §11).
pub fn create_session_resolves_provider_by_name_test() {
  let #(_registry, port) = start_server()
  let #(status, _body) =
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"fixture\",\"model\":\"alias-b\"}",
    ))
  should.equal(status, 201)
}

pub fn create_session_validation_test() {
  let #(_registry, port) = start_server()
  // Unknown provider -> 400 (plan §11 mapping).
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"nope\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"unknown provider: nope\"}"),
  )
  // Unknown model on a KNOWN provider -> 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"nope\"}",
    )),
    #(400, "{\"error\":\"unknown model: nope\"}"),
  )
  // Missing provider field -> 400 (no default provider exists anymore).
  should.equal(
    send_authorized(req(port, Post, "/sessions", "{\"model\":\"alias-a\"}")),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"empty provider\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"   \"}",
    )),
    #(400, "{\"error\":\"empty model\"}"),
  )
}

/// GET /models was removed at the hard cut: with N providers there is no
/// default endpoint to answer it (plan §11) — it is a plain 404 now.
pub fn models_route_removed_test() {
  let #(_registry, port) = start_server()
  should.equal(send_authorized(req(port, Get, "/models", "")), #(
    404,
    "{\"error\":\"not found\"}",
  ))
}

/// A provider may be NAMED after another provider's id — the id is the
// unambiguous key and must win: a request for "p1" pins the provider
// WITH ID p1, never the provider merely named "p1" (review finding on
// PR #12).
pub fn create_session_provider_id_wins_over_name_test() {
  let #(_registry, _providers, port) =
    start_server_with(fn(providers) {
      // Registry-minted ids: beta -> p1, the second -> p2, NAMED "p1".
      create_provider(providers, "beta", "https://beta.test/v1")
      create_provider(providers, "p1", "https://gamma.test/v1")
    })
  // p1 (id) is beta, whose fetcher serves the default list; the provider
  // NAMED p1 serves only "gamma-only". If name-matching won, this would
  // be a 400 unknown model instead of a 201...
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"p1\",\"model\":\"alias-a\"}",
    ))
      |> fn(pair) { #(pair.0, "") },
    #(201, ""),
  )
  // ...and this 400 proves it did not resolve to the provider named p1.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"p1\",\"model\":\"gamma-only\"}",
    )),
    #(400, "{\"error\":\"unknown model: gamma-only\"}"),
  )
}

// ---------------------------------------------------------------------------
// P4: provider CRUD surface (multi-provider §11)
// ---------------------------------------------------------------------------

/// The first `"id":"…"` value in a single-object reply (create/patch
/// responses are one provider object).
fn first_id(body: String) -> String {
  case string.split(body, "\"id\":\"") {
    [_, rest, ..] ->
      case string.split(rest, "\"") {
        [id, ..] -> id
        _ -> ""
      }
    _ -> ""
  }
}

/// The full curl-able CRUD walk (plan §17 acceptance): create with a
/// key, list, patch (rename / keep-key / replace-key / validation),
/// delete — and the submitted key material NEVER appears in any
/// response body along the way.
pub fn providers_crud_test() {
  let #(_registry, _providers, port) = start_server_with(fn(_) { Nil })
  let secret = "sk-live-never-echo-me-0123456789"

  // ---- auth gates the provider surface --------------------------------
  let assert Ok(denied) = hackney.send(req(port, Get, "/providers", ""))
  should.equal(denied.status, 401)
  let assert Ok(denied_create) =
    hackney.send(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"x\",\"base_url\":\"https://x.test/v1\"}",
    ))
  should.equal(denied_create.status, 401)

  // ---- create (with key): 201, masked, key never echoed ----------------
  let #(status, body) =
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"openai\",\"base_url\":\"https://api.openai.test/v1\",\"api_key\":\""
        <> secret
        <> "\"}",
    ))
  should.equal(status, 201)
  let id = first_id(body)
  should.be_true(string.starts_with(id, "p"))
  should.be_true(string.contains(body, "\"name\":\"openai\""))
  should.be_true(string.contains(
    body,
    "\"base_url\":\"https://api.openai.test/v1\"",
  ))
  should.be_true(string.contains(body, "\"dialect\":\"openai\""))
  should.be_true(string.contains(body, "\"enabled\":true"))
  should.be_true(string.contains(body, "\"has_key\":true"))
  should.be_true(string.contains(body, "\"created_at_rfc3339\":\""))
  should.be_true(string.contains(body, "\"updated_at_rfc3339\":\""))
  should.be_false(string.contains(body, secret))

  // ---- list: both providers, fixture keyless, still no key -------------
  let #(status, listed) = send_authorized(req(port, Get, "/providers", ""))
  should.equal(status, 200)
  should.be_true(string.contains(listed, "\"providers\":["))
  should.be_true(string.contains(listed, "\"name\":\"fixture\""))
  should.be_true(string.contains(listed, "\"has_key\":false"))
  should.be_true(string.contains(listed, "\"name\":\"openai\""))
  should.be_false(string.contains(listed, secret))

  // ---- patch: rename; blank api_key KEEPS the key -----------------------
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/providers/" <> id,
      "{\"name\":\"openai-prod\",\"api_key\":\"   \"}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"name\":\"openai-prod\""))
  should.be_true(string.contains(body, "\"has_key\":true"))
  should.be_false(string.contains(body, secret))

  // ---- patch: replace the key (has_key stays true, neither key echoes) --
  let replacement = "sk-live-also-secret-9876543210"
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/providers/" <> id,
      "{\"api_key\":\"" <> replacement <> "\"}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"has_key\":true"))
  should.be_false(string.contains(body, secret))
  should.be_false(string.contains(body, replacement))

  // ---- patch: disable reads back enabled:false --------------------------
  let #(status, body) =
    send_authorized(req(port, Patch, "/providers/" <> id, "{\"enabled\":false}"))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"enabled\":false"))

  // ---- validation -------------------------------------------------------
  // Duplicate name -> 409 (unique).
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"fixture\",\"base_url\":\"https://dup.test/v1\"}",
    )),
    #(409, "{\"error\":\"provider name already exists\"}"),
  )
  // Rename onto a taken name -> 409 too.
  should.equal(
    send_authorized(req(
      port,
      Patch,
      "/providers/" <> id,
      "{\"name\":\"fixture\"}",
    )),
    #(409, "{\"error\":\"provider name already exists\"}"),
  )
  // Base URL must end /v1 -> 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"bad\",\"base_url\":\"https://api.openai.test\"}",
    )),
    #(
      400,
      "{\"error\":\"provider base URL should be the OpenAI-compatible base ending in /v1\"}",
    ),
  )
  // Blank name -> 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"   \",\"base_url\":\"https://api.openai.test/v1\"}",
    )),
    #(400, "{\"error\":\"provider name must be non-empty after trimming\"}"),
  )
  // Missing required field -> 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"base_url\":\"https://api.openai.test/v1\"}",
    )),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  // Unknown id -> 404; empty patch -> 400; blank-only key patch is an
  // empty patch (keep means no-op), not a silent 200.
  should.equal(
    send_authorized(req(port, Patch, "/providers/nope", "{\"name\":\"x\"}")),
    #(404, "{\"error\":\"unknown provider\"}"),
  )
  should.equal(send_authorized(req(port, Patch, "/providers/" <> id, "{}")), #(
    400,
    "{\"error\":\"empty patch\"}",
  ))
  should.equal(
    send_authorized(req(port, Patch, "/providers/" <> id, "{\"api_key\":\" \"}")),
    #(400, "{\"error\":\"empty patch\"}"),
  )
  should.equal(
    send_authorized(req(port, Patch, "/providers/" <> id, "not json")),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  should.equal(send_authorized(req(port, Delete, "/providers/nope", "")), #(
    404,
    "{\"error\":\"unknown provider\"}",
  ))

  // ---- delete: unreferenced -> 204, then gone ---------------------------
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> id, ""))
      |> fn(pair) { #(pair.0, "") },
    #(204, ""),
  )
  let #(_status, after) = send_authorized(req(port, Get, "/providers", ""))
  should.be_false(string.contains(after, "\"name\":\"openai-prod\""))
  should.equal(send_authorized(req(port, Delete, "/providers/" <> id, "")), #(
    404,
    "{\"error\":\"unknown provider\"}",
  ))
}

/// The 409 delete guard (plan §11/§17): a provider pinned by any session
/// cannot be hard-deleted — disabling is the reversible path, and even
/// disabled the sessions still pin the row. Unpin (delete the session)
/// and the delete goes through.
pub fn provider_delete_guard_test() {
  let #(_registry, _providers, port) = start_server_with(fn(_) { Nil })
  let assert #(201, created) =
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"gamma\",\"base_url\":\"https://gamma.test/v1\"}",
    ))
  let provider_id = first_id(created)

  // A session pins it (model list comes from gamma's own fetcher).
  let assert #(201, session) =
    send_authorized(req(
      port,
      Post,
      "/sessions",
      "{\"provider\":\"" <> provider_id <> "\",\"model\":\"gamma-only\"}",
    ))
  let session_id = first_id(session)

  // Referenced -> 409, with the disable hint.
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> provider_id, "")),
    #(
      409,
      "{\"error\":\"provider is still pinned by sessions; disable it instead\"}",
    ),
  )
  // Disabling is allowed (the reversible path) but does NOT unpin —
  // the sessions still reference the row, so the guard holds.
  let assert #(200, _disabled) =
    send_authorized(req(
      port,
      Patch,
      "/providers/" <> provider_id,
      "{\"enabled\":false}",
    ))
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> provider_id, "")),
    #(
      409,
      "{\"error\":\"provider is still pinned by sessions; disable it instead\"}",
    ),
  )

  // Unpin (hard-delete the session) and the provider deletes cleanly.
  should.equal(
    send_authorized(req(port, Delete, "/sessions/" <> session_id, ""))
      |> fn(pair) { #(pair.0, "") },
    #(204, ""),
  )
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> provider_id, ""))
      |> fn(pair) { #(pair.0, "") },
    #(204, ""),
  )
}

/// The provider-scoped model list (§11): live aliases from THAT
/// provider's endpoint, unknown provider -> 404, disabled -> 400.
pub fn provider_models_route_test() {
  let #(_registry, _providers, port) = start_server_with(fn(_) { Nil })

  // The fixture provider serves the default list.
  should.equal(
    send_authorized(req(
      port,
      Get,
      "/providers/" <> store_mock.fixture_provider_id <> "/models",
      "",
    )),
    #(200, "{\"models\":[\"default-alias\",\"alias-a\",\"alias-b\"]}"),
  )

  // A provider with its own endpoint serves its own list.
  let assert #(201, created) =
    send_authorized(req(
      port,
      Post,
      "/providers",
      "{\"name\":\"gamma\",\"base_url\":\"https://gamma.test/v1\"}",
    ))
  let gamma = first_id(created)
  should.equal(
    send_authorized(req(port, Get, "/providers/" <> gamma <> "/models", "")),
    #(200, "{\"models\":[\"gamma-only\"]}"),
  )

  // Disabled providers refuse the live fetch.
  let assert #(200, _) =
    send_authorized(req(
      port,
      Patch,
      "/providers/" <> gamma,
      "{\"enabled\":false}",
    ))
  should.equal(
    send_authorized(req(port, Get, "/providers/" <> gamma <> "/models", "")),
    #(400, "{\"error\":\"provider is disabled\"}"),
  )

  // Unknown provider -> 404.
  should.equal(send_authorized(req(port, Get, "/providers/nope/models", "")), #(
    404,
    "{\"error\":\"unknown provider\"}",
  ))
}
