//// Live-loopback route tests for the M3 thread-organization surface:
//// PATCH/DELETE /threads/<id>, the archived query on GET /threads, and
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
import nexus/bot_registry
import nexus/config.{type Config}
import nexus/hackney
import nexus/loop
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/thread
import nexus/thread_registry
import nexus/tools
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
    // These suites boot the registry via `start`, whose real utility
    // runner would stream from a network endpoint once a debounce fired —
    // and they never assert on the side call. Keep the feature off so
    // `gleam test` stays strictly offline/network-free (AGENTS.md).
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    // Bots P3c: the delivery hop guard; 4 = the shipped default.
    max_bot_hops: 4,
  )
}

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  _delivery,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  thread.StreamDone(fake_stats(), transcript.append_assistant(tr, "hi"))
}

fn fake_stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(1),
    duration_ms: 2,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 1,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Boot factory + registry + mist once; hand back the registry subject.
/// One mist listener per test, bound to port 0 so the KERNEL assigns a
/// port that is free by construction — and the assigned port is read
/// back from mist's `after_start`, which also replaces the old racy
/// post-start sleep. (A clock-derived port guess previously lived in
/// Linux's ephemeral range 32768-60999, where the test client's own
/// outbound sockets — and their TIME_WAIT remnants — occasionally held
/// the port and killed the listener with Eaddrinuse; CI flake, run
/// 42399810506.)
fn start_server() -> #(process.Subject(thread_registry.Msg), Int) {
  let #(registry, _providers, port) = start_server_with(fn(_providers) { Nil })
  #(registry, port)
}

/// The full rig: factory + store mock + REAL provider registry (per-base-
/// URL model fetcher, so tests can tell providers apart) + thread
/// registry + mist. `extra` runs against the fresh provider registry
/// before the server starts — used to set up colliding providers.
fn start_server_with(
  extra: fn(process.Subject(provider_registry.Msg)) -> Nil,
) -> #(
  process.Subject(thread_registry.Msg),
  process.Subject(provider_registry.Msg),
  Int,
) {
  let cfg = test_config()
  let factory_name = process.new_name("nexus_routes_factory")
  let registry_name = process.new_name("nexus_routes_registry")
  let providers_name = process.new_name("nexus_routes_providers")
  let bots_name = process.new_name("nexus_routes_bots")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  // The REAL provider registry over the same mock store, with the live
  // model fetch replaced by a fixed alias list — offline, like the rest
  // of the suite. The thread registry resolves through it exactly like
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
  // The REAL bot registry over the same mock store (bots plan P1):
  // plain start — no crypto, no fetcher to fake.
  let assert Ok(_bots) =
    bot_registry.start(persistence, bots_name, fn(names) {
      tools.by_names(cfg, names) |> result.replace(names)
    })
  let assert Ok(started) =
    thread_registry.start(
      cfg,
      factory_supervisor.get_by_name(factory_name),
      registry_name,
      persistence,
      fn(id) {
        provider_registry.resolve(providers, id)
        |> result.map(fn(resolved) { resolved.endpoint })
        |> result.replace_error(thread_registry.ProviderUnknown)
      },
      process.new_name("nexus_bot_registry"),
    )
  // Port 0: the kernel picks a free port and mist's after_start hands
  // it back; a bind failure now fails the test loudly at this line
  // instead of surfacing later as connection-refused noise.
  let bound = process.new_subject()
  let assert Ok(_) =
    mist.new(web.handler(cfg, registry_name, providers_name, bots_name))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(bound, port) })
    |> mist.start
  let assert Ok(port) = process.receive(bound, 5000)
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

/// Wait until the freshly created thread's fake turn has committed.
fn drain_turn(subject: process.Subject(thread.Msg)) -> Nil {
  let sub = process.new_subject()
  process.send(subject, thread.Join(sub, 0))
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

fn thread_ids(body: String) -> List(String) {
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

/// A create for route tests: the summary's id plus the live subject
/// (resolved through the registry — the create reply is a ThreadSummary).
type Created {
  Created(id: String, subject: process.Subject(thread.Msg))
}

/// Wrap a fake turn runner in the toolset bundle the registry seams now
/// carry (#76): the default specs of the test config, named by their own
/// wire names. The utility side refuses — these tests drive turns through
/// the turn runner only.
fn toolset(runner: thread.TurnRunner) -> thread.Toolset {
  let specs = tools.default(test_config())
  thread.Toolset(
    names: list.map(specs, tools.tool_name),
    specs: specs,
    runner: runner,
    utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
      Error("no utility call in this test")
    },
  )
}

fn create(
  registry: process.Subject(thread_registry.Msg),
  model: String,
) -> Created {
  let assert Ok(summary) =
    thread_registry.create_with_toolset(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: model,
        system_prompt: None,
        toolset: None,
        bot_id: None,
      ),
      toolset(happy_runner),
    )
  let assert Ok(subject) = thread_registry.get(registry, summary.id)
  Created(id: summary.id, subject: subject)
}

pub fn patch_delete_and_archive_routes_test() {
  let #(registry, port) = start_server()
  let record = create(registry, "alpha")

  // ---- auth gates the new routes --------------------------------------
  // A PATCH without the token never reaches the handler.
  let assert Ok(denied) =
    hackney.send(req(port, Patch, "/threads/" <> record.id, "{\"pinned\":true}"))
  should.equal(denied.status, 401)
  let assert Ok(unauthorized) =
    hackney.send(req(port, Delete, "/threads/" <> record.id, ""))
  should.equal(unauthorized.status, 401)

  // ---- auto-title at the send boundary --------------------------------
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads/" <> record.id <> "/send",
      "{\"text\":\"  first   message\\nhere  \"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  drain_turn(record.subject)
  let #(status, body) = send_authorized(req(port, Get, "/threads", ""))
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
      "/threads/" <> record.id,
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
      "/threads/" <> record.id <> "/send",
      "{\"text\":\"second\"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  let #(_status, body) = send_authorized(req(port, Get, "/threads", ""))
  should.be_true(string.contains(body, "\"title\":\"Renamed\""))

  // ---- archive: soft-hide + archived view + restore --------------------
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/threads/" <> record.id,
      "{\"archived\":true}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":true"))

  // Default list hides it; ?archived=1 shows exactly it.
  let #(_status, active) = send_authorized(req(port, Get, "/threads", ""))
  should.equal(thread_ids(active), [])
  let #(_status, archived) =
    send_authorized(req(port, Get, "/threads?archived=1", ""))
  should.equal(thread_ids(archived), [record.id])

  // ---- pinned/archived invariant ----------------------------------------
  // Pinning an archived thread via PATCH is rejected wholesale…
  should.equal(
    send_authorized(req(
      port,
      Patch,
      "/threads/" <> record.id,
      "{\"pinned\":true}",
    )),
    #(409, "{\"error\":\"cannot pin an archived thread\"}"),
  )
  // …and the refusal changed nothing.
  let #(_status, still) =
    send_authorized(req(port, Get, "/threads?archived=1", ""))
  should.be_true(string.contains(still, "\"pinned\":false"))
  // A restore+pin in one patch is fine (archive state applies first),
  // and the earlier pin was cleared by archiving, so it re-pins cleanly.
  let #(status, body) =
    send_authorized(req(
      port,
      Patch,
      "/threads/" <> record.id,
      "{\"archived\":false,\"pinned\":true}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":false"))
  should.be_true(string.contains(body, "\"pinned\":true"))

  // ---- PATCH validation -------------------------------------------------
  should.equal(
    send_authorized(req(port, Patch, "/threads/" <> record.id, "{}")),
    #(400, "{\"error\":\"empty patch\"}"),
  )
  should.equal(
    send_authorized(req(port, Patch, "/threads/" <> record.id, "not json")),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Patch,
      "/threads/" <> record.id,
      "{\"title\":\"  \"}",
    )),
    #(400, "{\"error\":\"empty title\"}"),
  )
  should.equal(
    send_authorized(req(port, Patch, "/threads/nope", "{\"pinned\":true}")),
    #(404, "{\"error\":\"thread not found\"}"),
  )

  // ---- DELETE: hard removal ---------------------------------------------
  should.equal(
    send_authorized(req(port, Delete, "/threads/" <> record.id, "")),
    #(204, ""),
  )
  let #(_status, after) =
    send_authorized(req(port, Get, "/threads?archived=1", ""))
  should.equal(thread_ids(after), [])
  should.equal(
    send_authorized(req(port, Delete, "/threads/" <> record.id, "")),
    #(404, "{\"error\":\"thread not found\"}"),
  )
  thread_registry.get(registry, record.id) |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// P3: POST /threads pins provider + model
// ---------------------------------------------------------------------------

/// The full create flow over the real (loopback) surface: provider
/// resolved by id, model validated against the provider's list, thread
/// created and persisted with the pin.
pub fn create_thread_pins_provider_and_model_test() {
  let #(registry, port) = start_server()
  let #(status, body) =
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"alias-a\"}",
    ))
  should.equal(status, 201)
  should.be_true(string.contains(body, "\"model\":\"alias-a\""))
  // The pin is in the stored row too.
  let assert [summary] = thread_registry.list_threads(registry)
  summary.model |> should.equal("alias-a")
  let #(_, listed) = send_authorized(req(port, Get, "/threads", ""))
  should.be_true(string.contains(listed, "\"model\":\"alias-a\""))
}

/// Provider lookup accepts the NAME as well as the id (plan §11).
pub fn create_thread_resolves_provider_by_name_test() {
  let #(_registry, port) = start_server()
  let #(status, _body) =
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\"fixture\",\"model\":\"alias-b\"}",
    ))
  should.equal(status, 201)
}

pub fn create_thread_validation_test() {
  let #(_registry, port) = start_server()
  // Unknown provider -> 400 (plan §11 mapping).
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\"nope\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"unknown provider: nope\"}"),
  )
  // Unknown model on a KNOWN provider -> 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"nope\"}",
    )),
    #(400, "{\"error\":\"unknown model: nope\"}"),
  )
  // Missing provider field -> 400 (no default provider exists anymore;
  // the decoder is total over the two body shapes, so the refusal is the
  // route's "empty provider").
  should.equal(
    send_authorized(req(port, Post, "/threads", "{\"model\":\"alias-a\"}")),
    #(400, "{\"error\":\"empty provider\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\"\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"empty provider\"}"),
  )
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
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

// A provider may be NAMED after another provider's id — the id is the
// unambiguous key and must win: a request for "p1" pins the provider
// WITH ID p1, never the provider merely named "p1" (review finding on
// PR #12).
pub fn create_thread_provider_id_wins_over_name_test() {
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
      "/threads",
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
      "/threads",
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

/// The 409 delete guard (plan §11/§17): a provider pinned by any thread
/// cannot be hard-deleted — disabling is the reversible path, and even
/// disabled the threads still pin the row. Unpin (delete the thread)
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

  // A thread pins it (model list comes from gamma's own fetcher).
  let assert #(201, thread) =
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\"" <> provider_id <> "\",\"model\":\"gamma-only\"}",
    ))
  let thread_id = first_id(thread)

  // Referenced -> 409, with the disable hint.
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> provider_id, "")),
    #(
      409,
      "{\"error\":\"provider is still pinned by threads or bots; disable it instead\"}",
    ),
  )
  // Disabling is allowed (the reversible path) but does NOT unpin —
  // the threads still reference the row, so the guard holds.
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
      "{\"error\":\"provider is still pinned by threads or bots; disable it instead\"}",
    ),
  )

  // Unpin (hard-delete the thread) and the provider deletes cleanly.
  should.equal(
    send_authorized(req(port, Delete, "/threads/" <> thread_id, ""))
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

// ---------------------------------------------------------------------------
// Bots plan P1: /bots CRUD + create-from-bot
// ---------------------------------------------------------------------------

/// A bot created through the API: 201 with the row's public shape; the
/// list shows it; PATCH moves/updates; DELETE removes. The provider
/// existence check (the web layer's friendly 400, FK as backstop) and
/// the closed error vocabulary are exercised along the way.
pub fn bots_crud_routes_test() {
  let #(_registry, port) = start_server()

  // Create with an unknown provider -> the caller-side friendly 400.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"x\",\"provider\":\"p-nope\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"unknown provider\"}"),
  )

  // Create (keyless fixture provider, blank prompt = default).
  let #(status, body) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Writer\",\"description\":\"prose\",\"provider\":\"p-test\",\"model\":\"alias-a\",\"system_prompt\":\"be terse\"}",
    ))
  should.equal(status, 201)
  should.be_true(string.contains(body, "\"id\":\"b1\""))
  should.be_true(string.contains(body, "\"name\":\"Writer\""))
  should.be_true(string.contains(body, "\"system_prompt\":\"be terse\""))

  // List.
  let assert #(200, list_body) = send_authorized(req(port, Get, "/bots", ""))
  should.be_true(string.contains(list_body, "\"bots\":["))
  should.be_true(string.contains(list_body, "\"name\":\"Writer\""))

  // Duplicate name -> 409.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Writer\",\"provider\":\"p-test\",\"model\":\"alias-a\"}",
    )),
    #(409, "{\"error\":\"bot name already exists\"}"),
  )

  // PATCH: rename + clear the prompt back to the default.
  let assert #(200, patched) =
    send_authorized(req(
      port,
      Patch,
      "/bots/b1",
      "{\"name\":\"Author\",\"system_prompt\":\"\"}",
    ))
  should.be_true(string.contains(patched, "\"name\":\"Author\""))
  should.be_true(string.contains(patched, "\"system_prompt\":null"))

  // PATCH onto an unknown provider -> the same friendly 400.
  should.equal(
    send_authorized(req(port, Patch, "/bots/b1", "{\"provider\":\"p-nope\"}")),
    #(400, "{\"error\":\"unknown provider\"}"),
  )

  // Unknown id -> 404; empty patch -> 400; unreadable -> 400.
  should.equal(
    send_authorized(req(port, Patch, "/bots/b404", "{\"name\":\"x\"}")),
    #(404, "{\"error\":\"unknown bot\"}"),
  )
  should.equal(send_authorized(req(port, Patch, "/bots/b1", "{}")), #(
    400,
    "{\"error\":\"empty patch\"}",
  ))
  should.equal(send_authorized(req(port, Patch, "/bots/b1", "not json")), #(
    400,
    "{\"error\":\"unreadable body\"}",
  ))

  // Delete (unguarded — threads keep their frozen columns).
  should.equal(
    send_authorized(req(port, Delete, "/bots/b1", "")) |> fn(p) { p.0 },
    204,
  )
  should.equal(send_authorized(req(port, Delete, "/bots/b1", "")), #(
    404,
    "{\"error\":\"unknown bot\"}",
  ))
}

/// `POST /threads {"bot": id}`: the bot sources the frozen pin (and its
/// prompt), the summary carries the provenance, and the plan's refusal
/// paths hold — an unknown bot is a 400, a stale alias is a 400 (the
/// create must never silently succeed on a dead alias), and bot +
/// provider/model in one body is a conflict.
pub fn create_thread_from_bot_test() {
  let #(_registry, port) = start_server()

  // One bot, default prompt: the HTTP surface's visible contract is the
  // pin + provenance (the prompt BYTES freeze at the registry level —
  // thread_registry_test pins those).
  let assert #(201, _created) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Default\",\"provider\":\"p-test\",\"model\":\"alias-a\"}",
    ))

  let assert #(201, thread) =
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b1\"}"))
  should.be_true(string.contains(thread, "\"bot_id\":\"b1\""))
  should.be_true(string.contains(thread, "\"model\":\"alias-a\""))
  should.be_true(string.contains(thread, "\"provider_id\":\"p-test\""))

  // Unknown bot -> 400.
  should.equal(
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b-nope\"}")),
    #(400, "{\"error\":\"unknown bot: b-nope\"}"),
  )

  // Stale alias -> 400 (never a silent success): a bot pinned to an
  // alias the provider no longer lists.
  let assert #(201, _stale) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Stale\",\"provider\":\"p-test\",\"model\":\"dead-alias\"}",
    ))
  should.equal(
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b2\"}")),
    #(400, "{\"error\":\"unknown model: dead-alias\"}"),
  )

  // Conflict: bot plus provider/model in one body.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"bot\":\"b1\",\"model\":\"alias-a\"}",
    )),
    #(400, "{\"error\":\"bot conflicts with provider/model — pick one shape\"}"),
  )

  // The conflict rule is about KEYS: a blank provider value still
  // conflicts with the bot instead of being quietly dropped.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"bot\":\"b1\",\"provider\":\"\"}",
    )),
    #(400, "{\"error\":\"bot conflicts with provider/model — pick one shape\"}"),
  )
}

// ---------------------------------------------------------------------------
// Bots plan P2: the tools field on the /bots surface.
// ---------------------------------------------------------------------------

/// The POST/PATCH body decoders keep the three toolset states distinct:
/// create flattens absent/null to the default sentinel; patch preserves
/// absent (keep) vs null (clear) vs array (replace).
pub fn bot_tools_body_decoders_test() {
  // Create: absent and null both mean "the default set"; an array is an
  // explicit list; [] is chat-only.
  let assert Ok(fields) =
    web.parse_bot_create_json(
      "{\"name\":\"b\",\"provider\":\"p\",\"model\":\"m\"}",
    )
  should.equal(fields.tools, None)
  let assert Ok(fields) =
    web.parse_bot_create_json(
      "{\"name\":\"b\",\"provider\":\"p\",\"model\":\"m\",\"tools\":null}",
    )
  should.equal(fields.tools, None)
  let assert Ok(fields) =
    web.parse_bot_create_json(
      "{\"name\":\"b\",\"provider\":\"p\",\"model\":\"m\",\"tools\":[]}",
    )
  should.equal(fields.tools, Some([]))
  let assert Ok(fields) =
    web.parse_bot_create_json(
      "{\"name\":\"b\",\"provider\":\"p\",\"model\":\"m\",\"tools\":[\"http_fetch\"]}",
    )
  should.equal(fields.tools, Some(["http_fetch"]))

  // Patch: absent keeps (None), null clears (Some(None)), array replaces
  // (Some(Some)).
  let assert Ok(patch) = web.parse_bot_patch_json("{\"description\":\"d\"}")
  should.equal(patch.tools, None)
  let assert Ok(patch) = web.parse_bot_patch_json("{\"tools\":null}")
  should.equal(patch.tools, Some(None))
  let assert Ok(patch) =
    web.parse_bot_patch_json("{\"tools\":[\"http_fetch\",\"codemode\"]}")
  should.equal(patch.tools, Some(Some(["http_fetch", "codemode"])))
}

/// The /bots routes validate toolsets against the REAL compiled catalog
/// (the injected seam boot wires): unknown names are a 400, valid ones
/// echo back on GET — and a bot carrying an explicit toolset creates
/// threads fine (the registry snapshots the resolved names; the create's
/// mechanics are pinned by thread_registry_test).
pub fn bots_route_toolset_validation_test() {
  let #(_registry, port) = start_server()

  // Unknown name -> 400 with the catalog checker's text.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Bad\",\"provider\":\"p-test\",\"model\":\"alias-a\",\"tools\":[\"ghost\"]}",
    )),
    #(400, "{\"error\":\"unknown tool name: ghost\"}"),
  )

  // A valid chat-only bot round-trips its toolset on the wire.
  let assert #(201, created) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Quiet\",\"provider\":\"p-test\",\"model\":\"alias-a\",\"tools\":[]}",
    ))
  should.be_true(string.contains(created, "\"tools\":[]"))

  // The rejected create consumed no id: the chat-only bot is b1.
  // PATCH: null clears back to the default (tools becomes null on the
  // wire); an array replaces; absent keeps.
  let assert #(200, cleared) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"tools\":null}"))
  should.be_true(string.contains(cleared, "\"tools\":null"))

  let assert #(200, replaced) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"tools\":[\"http_fetch\"]}"))
  should.be_true(string.contains(replaced, "\"tools\":[\"http_fetch\"]"))

  let assert #(200, kept) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"description\":\"d\"}"))
  should.be_true(string.contains(kept, "\"tools\":[\"http_fetch\"]"))

  let assert #(200, listed) = send_authorized(req(port, Get, "/bots", ""))
  should.be_true(string.contains(listed, "\"tools\":[\"http_fetch\"]"))

  // The toolset-carrying bot creates a thread fine.
  let assert #(201, _thread) =
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b1\"}"))
}

/// The inbound gate (bots plan P3a, issue #95) on the /bots surface:
/// creates open it, PATCH flips it both ways, an absent field keeps it,
/// and the wire shape carries it on every bot response.
pub fn bots_allow_inbound_patch_round_trip_test() {
  let #(_registry, port) = start_server()

  // A plain create: the gate starts open and rides the response.
  let assert #(201, created) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Gate\",\"provider\":\"p-test\",\"model\":\"alias-a\"}",
    ))
  should.be_true(string.contains(created, "\"allow_inbound\":true"))

  // PATCH false: closed on the wire.
  let assert #(200, closed) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"allow_inbound\":false}"))
  should.be_true(string.contains(closed, "\"allow_inbound\":false"))

  // An absent field keeps it (the full-row replace must not reopen the
  // gate); the field rides GET too.
  let assert #(200, kept) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"description\":\"d\"}"))
  should.be_true(string.contains(kept, "\"allow_inbound\":false"))
  let assert #(200, listed) = send_authorized(req(port, Get, "/bots", ""))
  should.be_true(string.contains(listed, "\"allow_inbound\":false"))

  // PATCH true: reopened.
  let assert #(200, opened) =
    send_authorized(req(port, Patch, "/bots/b1", "{\"allow_inbound\":true}"))
  should.be_true(string.contains(opened, "\"allow_inbound\":true"))

  // A gate-only patch is not an empty patch (no 400): it reaches the
  // unknown-id path and comes back as the 404.
  should.equal(
    send_authorized(req(port, Patch, "/bots/b404", "{\"allow_inbound\":true}")),
    #(404, "{\"error\":\"unknown bot\"}"),
  )
}
