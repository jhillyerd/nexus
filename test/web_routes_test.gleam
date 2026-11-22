//// Live-loopback route tests for the M3 thread-organization surface:
//// PATCH/DELETE /threads/<id>, the archived query on GET /threads, and
//// the auto-title-at-send boundary — over a real mist server and a real
//// registry (fake turn runner; no Bifrost, no network beyond loopback).

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Delete, Get, Patch, Post}
import gleam/http/request.{type Request}
import gleam/int
import gleam/json
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
import nexus/log
import nexus/loop
import nexus/node
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/store
import nexus/thread
import nexus/thread_registry
import nexus/timing
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
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_cache_ttl_ms: 600_000,
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
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    env_timeout_ms: 60_000,
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    // Bots P3c: the delivery hop guard; 4 = the shipped default.
    max_bot_hops: 4,
  )
}

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  _delivery,
  _environment,
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

/// A rig that hands back its store seam: the exchange tests create a
/// REAL thread first (the mock enforces node_grant's thread FK exactly
/// like production Postgres), then seed grants through the seam —
/// there is deliberately no HTTP mint route (the web UI mints through
/// the server component, Phase C).
fn start_server_with_store() -> #(
  process.Subject(thread_registry.Msg),
  Int,
  store.Store,
) {
  let #(registry, _providers, port, seam) =
    start_server_rig(fn(_providers) { Nil }, fn(_store) { Nil })
  #(registry, port, seam)
}

/// The full rig behind every start_server variant: factory + store mock
/// + REAL provider registry (per-base-URL model fetcher, so tests can
/// tell providers apart) + thread registry + mist.
fn start_server_with(
  extra: fn(process.Subject(provider_registry.Msg)) -> Nil,
) -> #(
  process.Subject(thread_registry.Msg),
  process.Subject(provider_registry.Msg),
  Int,
) {
  let #(registry, providers, port, _seam) =
    start_server_rig(extra, fn(_store) { Nil })
  #(registry, providers, port)
}

/// `extra` runs against the fresh provider registry before the server
/// starts — used to set up colliding providers; `seed` runs against
/// the mock store before the server starts — the pairing-exchange
/// tests' grant rows land there (no HTTP mint route exists by design;
/// the web UI mints through the server component).
fn start_server_rig(
  extra: fn(process.Subject(provider_registry.Msg)) -> Nil,
  seed: fn(store.Store) -> Nil,
) -> #(
  process.Subject(thread_registry.Msg),
  process.Subject(provider_registry.Msg),
  Int,
  store.Store,
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
  store_mock.ensure_fixture_bot(persistence)
  seed(persistence)
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
    bot_registry.start(
      persistence,
      bots_name,
      fn(names) { tools.by_names(cfg, names) |> result.replace(names) },
      fn() { bot_registry.ToolCatalog([], []) },
    )
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
      // The SAME name this harness started the bot registry under: the
      // delivery wrapper's sender-name ask resolves it at ask time.
      bots_name,
      dict.new(),
      dict.new(),
      None,
    )
  // Port 0: the kernel picks a free port and mist's after_start hands
  // it back; a bind failure now fails the test loudly at this line
  // instead of surfacing later as connection-refused noise.
  let bound = process.new_subject()
  let assert Ok(_) =
    mist.new(web.handler(
      cfg,
      registry_name,
      providers_name,
      bots_name,
      persistence,
    ))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(bound, port) })
    |> mist.start
  let assert Ok(port) = process.receive(bound, 5000)
  #(started.data, providers, port, persistence)
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
        bot_id: "b-fixture",
        parent_thread_id: None,
        title: "",
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
// P3: POST /threads is BOT-ONLY (threads require a bot)
// ---------------------------------------------------------------------------

/// The provider+model create shape is GONE: any provider/model/tools
/// body answers the honest 400 naming the one live shape (the bot).
pub fn create_thread_requires_bot_test() {
  let #(_registry, port) = start_server()
  let refused = fn(body) { send_authorized(req(port, Post, "/threads", body)) }
  should.equal(
    refused(
      "{\"provider\":\""
      <> store_mock.fixture_provider_id
      <> "\",\"model\":\"alias-a\"}",
    ),
    #(
      400,
      "{\"error\":\"threads require a bot: pass a bot id —"
        <> " the provider/model create shape is gone\"}",
    ),
  )
  // Blank halves, tools lists — every non-bot shape refuses the same way.
  should.equal(refused("{\"model\":\"alias-a\"}") |> fn(pair) { pair.0 }, 400)
  should.equal(
    refused("{\"provider\":\"\",\"model\":\"alias-a\"}")
      |> fn(pair) { pair.0 },
    400,
  )
  should.equal(refused("{\"tools\":[]}") |> fn(pair) { pair.0 }, 400)
  // And nothing was created.
  let #(_, listed) = send_authorized(req(port, Get, "/threads", ""))
  should.be_false(string.contains(listed, "alias-a"))
}

/// The bot shape keeps its own validations: unknown bot -> 400; a bot
/// pinned to an alias the provider no longer lists still creates (the
/// pin freezes "dead-alias"; the first turn fails at stream time if
/// dead). Full flow coverage lives in create_thread_from_bot_test below.
pub fn create_thread_bot_shape_refusals_test() {
  let #(_registry, port) = start_server()
  should.equal(
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b-nope\"}")),
    #(400, "{\"error\":\"unknown bot: b-nope\"}"),
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

/// GET /threads/<id> serves the page shell — the RESTful app view the
/// static script reads location.pathname from. Auth-gated like `/`, and
/// thread-agnostic: the shell carries no thread data, so any id (existing
/// or not) gets the identical HTML; a vanished id degrades client-side to
/// the auto-selection.
pub fn thread_page_route_test() {
  let #(_registry, port) = start_server()

  // The token gate covers the app view like every other route.
  let assert Ok(denied) = hackney.send(req(port, Get, "/threads/s-1", ""))
  should.equal(denied.status, 401)

  let #(status, body) = send_authorized(req(port, Get, "/threads/s-1", ""))
  should.equal(status, 200)
  should.be_true(string.contains(body, "lustre-server-component"))
  let #(status2, body2) =
    send_authorized(req(port, Get, "/threads/not-a-thread", ""))
  should.equal(status2, 200)
  should.equal(body2, body)
}

// A provider may be NAMED after another provider's id — the id is the
// unambiguous key and must win (review finding on PR #12). With bot-only
// creates the HTTP surface carries no provider identifier at all: the
// bot row stores the CANONICAL id, so resolve_provider's id-first rule
// is what the bot path always hits (the name fallback is defensive
// only). What THIS surface can still pin is the dead-shape refusal that
// replaced the old provider/model test.
pub fn create_thread_dead_provider_model_shape_refused_test() {
  let #(_registry, _providers, port) =
    start_server_with(fn(providers) {
      create_provider(providers, "beta", "https://beta.test/v1")
      create_provider(providers, "p1", "https://gamma.test/v1")
    })
  // The dead shape refuses like any other non-bot body.
  let #(status, body) =
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"provider\":\"p1\",\"model\":\"gamma-only\"}",
    ))
  should.equal(status, 400)
  should.be_true(string.contains(body, "threads require a bot"))
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

  // Threads are bot-only: a BOT pins the provider, and the thread
  // created from it pins the same row.
  let assert #(201, bot) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"gamma-bot\",\"provider\":\""
        <> provider_id
        <> "\",\"model\":\"gamma-only\"}",
    ))
  let bot_id = first_id(bot)
  let assert #(201, thread) =
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"bot\":\"" <> bot_id <> "\"}",
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
  // the bot and its thread still reference the row, so the guard holds.
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

  // Unpin: hard-delete the thread, then the bot (the thread's bot_id
  // was already scrubbed by the delete — but the BOT row itself still
  // RESTRICTs the provider until it is gone too).
  should.equal(
    send_authorized(req(port, Delete, "/threads/" <> thread_id, ""))
      |> fn(pair) { #(pair.0, "") },
    #(204, ""),
  )
  should.equal(
    send_authorized(req(port, Delete, "/providers/" <> provider_id, ""))
      |> fn(pair) { pair.0 },
    409,
  )
  should.equal(
    send_authorized(req(port, Delete, "/bots/" <> bot_id, ""))
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
    #(
      409,
      "{\"error\":\"bot name already exists (names are case-insensitive)\"}",
    ),
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
/// paths hold — an unknown bot is a 400, a stale alias is NOT a refusal
/// (aliases are not validated at create; the thread lands and its first
/// turn fails at stream time), and bot + provider/model in one body is a
/// conflict.
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

  // Stale alias -> lands anyway: a bot pinned to an alias the provider
  // no longer lists creates fine (the pin freezes "dead-alias"; the
  // first turn fails at stream time if the proxy can't serve it).
  let assert #(201, _stale) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\"Stale\",\"provider\":\"p-test\",\"model\":\"dead-alias\"}",
    ))
  let assert #(201, stale_thread) =
    send_authorized(req(port, Post, "/threads", "{\"bot\":\"b2\"}"))
  should.be_true(string.contains(stale_thread, "\"model\":\"dead-alias\""))

  // Conflict: bot plus provider/model in one body.
  should.equal(
    send_authorized(req(
      port,
      Post,
      "/threads",
      "{\"bot\":\"b1\",\"model\":\"alias-a\"}",
    )),
    #(
      400,
      "{\"error\":\"bot conflicts with provider/model/tools — pick one shape\"}",
    ),
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
    #(
      400,
      "{\"error\":\"bot conflicts with provider/model/tools — pick one shape\"}",
    ),
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

// ---------------------------------------------------------------------------
// Node pairing routes + /node/ws pre-upgrade auth (environments 2b-3)
// ---------------------------------------------------------------------------

/// The minimal pairing surface: POST mints the (thread-bound) row and
/// answers the plaintext token ONCE (never the hash), duplicates
/// refuse PER THREAD, the same name under another thread is a NEW row
/// (per-thread node names), the list carries no secrets, revoke is an
/// idempotent row delete, and the UI token still guards the admin
/// surface.
/// The node/pairing tests' thread: bot-sourced (the only create shape —
/// every thread names its bot). Returns (status, body) of POST /threads.
fn create_thread_via_bot(port: Int) -> #(Int, String) {
  // Bot names are case-insensitively unique, and a test may call this
  // twice (the per-thread-names round trip) — the microsecond suffix
  // keeps the rows distinct.
  let name = "node-bot-" <> int.to_string(timing.now_us())
  let #(_, bot_body) =
    send_authorized(req(
      port,
      Post,
      "/bots",
      "{\"name\":\""
        <> name
        <> "\",\"provider\":\""
        <> store_mock.fixture_provider_id
        <> "\",\"model\":\"alias-a\"}",
    ))
  let assert Ok(bot_id) = json.parse(bot_body, decode.at(["id"], decode.string))
  send_authorized(req(port, Post, "/threads", "{\"bot\":\"" <> bot_id <> "\"}"))
}

pub fn node_pairing_round_trip_test() {
  let #(_registry, port) = start_server()
  let #(thread_status, thread_body) = create_thread_via_bot(port)
  should.equal(thread_status, 201)
  let assert Ok(thread_id) =
    json.parse(thread_body, decode.at(["id"], decode.string))
  let create = fn(thread: String, name: String) {
    send_authorized(req(
      port,
      Post,
      "/nodes",
      "{\"thread\":\"" <> thread <> "\",\"name\":\"" <> name <> "\"}",
    ))
  }
  let #(status, body) = create(thread_id, "proxmox-2")
  should.equal(status, 201)
  should.be_true(string.contains(body, "\"name\":\"proxmox-2\""))
  should.be_true(string.contains(body, "\"token\":\""))
  should.be_true(string.contains(body, "\"thread_id\":\"" <> thread_id))
  should.be_false(string.contains(body, "token_hash"))
  let assert Ok(node_id) = json.parse(body, decode.at(["id"], decode.string))

  // A duplicate name IN ITS THREAD is the friendly 409.
  let #(dup, _dup_body) = create(thread_id, "proxmox-2")
  should.equal(dup, 409)

  // The list carries the row (with its thread), never the hash.
  let #(list_status, listed) = send_authorized(req(port, Get, "/nodes", ""))
  should.equal(list_status, 200)
  should.be_true(string.contains(listed, "proxmox-2"))
  should.be_true(string.contains(listed, thread_id))
  should.be_false(string.contains(listed, "token_hash"))

  // A reserved/invalid name refuses.
  let #(reserved, _) = create(thread_id, "workspace")
  should.equal(reserved, 400)

  // An unknown thread refuses (the row binds to its thread).
  let #(ghost, _) = create("t-ghost", "x3")
  should.equal(ghost, 404)

  // Revoke: 204, idempotent.
  let #(del, _) = send_authorized(req(port, Delete, "/nodes/" <> node_id, ""))
  should.equal(del, 204)
  let #(del2, _) = send_authorized(req(port, Delete, "/nodes/" <> node_id, ""))
  should.equal(del2, 204)
  // The row is really gone, not just 204'd: the list no longer names it.
  let #(_, after_revoke) = send_authorized(req(port, Get, "/nodes", ""))
  should.be_false(string.contains(after_revoke, "proxmox-2"))

  // The admin surface stays behind the UI token.
  let assert Ok(unauth) =
    hackney.send(req(
      port,
      Post,
      "/nodes",
      "{\"thread\":\"" <> thread_id <> "\",\"name\":\"x2\"}",
    ))
  should.equal(unauth.status, 401)
}

/// The pre-upgrade gates on /node/ws answer as ordinary HTTP statuses
/// (a reconnecting client can tell bad token from bad path). The
/// upgrade itself is the e2e fake node's to prove.
pub fn node_ws_pre_upgrade_refusals_test() {
  let #(_registry, port) = start_server()
  // The node's OWN (plain) thread: names are per-thread, so the row
  // binds to it, and the auth lookup is scoped by the pair.
  let #(thread_status, thread_body) = create_thread_via_bot(port)
  should.equal(thread_status, 201)
  let assert Ok(thread_id) =
    json.parse(thread_body, decode.at(["id"], decode.string))
  let #(_, node_body) =
    send_authorized(req(
      port,
      Post,
      "/nodes",
      "{\"thread\":\"" <> thread_id <> "\",\"name\":\"node-a\"}",
    ))
  let assert Ok(node_token) =
    json.parse(node_body, decode.at(["token"], decode.string))

  // No credentials: 401.
  let assert Ok(no_creds) =
    hackney.send(req(port, Get, "/node/ws?thread=" <> thread_id, ""))
  should.equal(no_creds.status, 401)

  // Wrong token: 401 — identical to an unknown node, no oracle.
  let assert Ok(bad_token) =
    hackney.send(req(
      port,
      Get,
      "/node/ws?node=node-a&token=wrong&thread=" <> thread_id,
      "",
    ))
  should.equal(bad_token.status, 401)

  // Right credentials, ANOTHER (real, existing) thread: 401 — the
  // (thread, name) pair has no row there (per-thread names scope the
  // credential). A REAL second thread, not a ghost id: the point is
  // that a VALID token is rejected wherever its row is not, so global
  // node authentication cannot sneak back in.
  let #(t2_status, t2_body) = create_thread_via_bot(port)
  should.equal(t2_status, 201)
  let assert Ok(thread_2) =
    json.parse(t2_body, decode.at(["id"], decode.string))
  let assert Ok(other_thread) =
    hackney.send(req(
      port,
      Get,
      "/node/ws?node=node-a&token=" <> node_token <> "&thread=" <> thread_2,
      "",
    ))
  should.equal(other_thread.status, 401)

  // Missing thread parameter: 400 (the thread scopes the lookup, so
  // the parameter is read before auth).
  let assert Ok(no_thread_param) =
    hackney.send(req(port, Get, "/node/ws?node=node-a&token=" <> node_token, ""))
  should.equal(no_thread_param.status, 400)

  // Env role on the plain thread: 403, the UnknownToolset philosophy
  // (auth passed — the row's own thread — the toolset gate refuses).
  let assert Ok(no_env) =
    hackney.send(req(
      port,
      Get,
      "/node/ws?node=node-a&token=" <> node_token <> "&thread=" <> thread_id,
      "",
    ))
  should.equal(no_env.status, 403)
  // Viewer role skipping the gate is NOT pinned here: a plain GET
  // cannot complete the WebSocket handshake (mist's upgrade path needs
  // the Upgrade headers), so the viewer happy path belongs to the e2e
  // fake node, which speaks real WS.
}

/// The insert's failure mapping (cubic review): the lost pre-check
/// race cannot be staged through the seam (the mock rejects against
/// the same state the pre-check reads), so the mapping is pinned
/// directly — present name answers the friendly 409, a genuinely
/// failing store stays 502.
pub fn node_insert_failure_test() {
  let row =
    node.Node(
      id: "n-race",
      thread_id: "t1",
      name: "proxmox-2",
      token_hash: node.hash_token("tok"),
      created_at: 1_700_000_000,
      last_seen_at: None,
    )
  web.node_insert_failure(Ok([row]), "t1", "proxmox-2")
  |> should.equal(#(409, "node name is already paired"))
  // The same name under ANOTHER thread did not lose the race — a
  // genuinely unexpected failure stays 502.
  web.node_insert_failure(Ok([row]), "t2", "proxmox-2")
  |> should.equal(#(502, "store unavailable"))
  web.node_insert_failure(Ok([row]), "t1", "other-name")
  |> should.equal(#(502, "store unavailable"))
  web.node_insert_failure(Error("disk full"), "t1", "proxmox-2")
  |> should.equal(#(502, "store unavailable"))
}

/// The pairing exchange (tui-pairing plan Phase A): a TUI host redeems
/// a code for a node credential + the grant's pinned thread — with NO
/// UI token (the whole point). Grants are seeded through the mock
/// seam because there is deliberately no HTTP mint route (the web UI
/// mints through the server component). Revocation needs no separate
/// arm here: a revoked row is simply absent from the list, the exact
/// state the unknown-code arm exercises.
pub fn node_grant_exchange_round_trip_test() {
  let #(_registry, port, seam) = start_server_with_store()

  // A REAL thread: the mock enforces node_grant's thread FK like
  // production Postgres (cubic review), so grants pin to ids that
  // exist.
  let #(thread_status, thread_body) = create_thread_via_bot(port)
  should.equal(thread_status, 201)
  let assert Ok(thread_id) =
    json.parse(thread_body, decode.at(["id"], decode.string))

  // One live grant (the pairing URL), one already expired, one
  // UNPINNED (the reserved shape) for the no-thread refusal.
  let now = timing.wall_now_s()
  let #(live_code, live) = node.mint_grant(Some(thread_id), now)
  let #(expired_code, expired) =
    node.mint_grant(Some(thread_id), now - node.grant_ttl_s - 1)
  let #(free_code, free_grant) = node.mint_grant(None, now)
  seam.insert_node_grant(live) |> should.be_ok
  seam.insert_node_grant(expired) |> should.be_ok
  seam.insert_node_grant(node.Grant(..free_grant, id: "g-free"))
  |> should.be_ok

  let pair = fn(code: String, name: String) {
    hackney.send(req(
      port,
      Post,
      "/nodes/pair",
      "{\"code\":\"" <> code <> "\",\"name\":\"" <> name <> "\"}",
    ))
  }
  // The override form: the launcher's NEXUS_THREAD rides the request
  // and binds the minted row to the given thread.
  let pair_into = fn(code: String, name: String, thread: String) {
    hackney.send(req(
      port,
      Post,
      "/nodes/pair",
      "{\"code\":\""
        <> code
        <> "\",\"name\":\""
        <> name
        <> "\",\"thread\":\""
        <> thread
        <> "\"}",
    ))
  }

  // PUBLIC: a plain send, no Authorization header — a TUI host holds
  // no UI token. The answer carries the one-time node token, the
  // pinned thread, and never any hash.
  let assert Ok(first) = pair(live_code, "laptop-a")
  should.equal(first.status, 201)
  should.be_true(string.contains(first.body, "\"name\":\"laptop-a\""))
  should.be_true(string.contains(first.body, "\"token\":\""))
  should.be_false(string.contains(first.body, "token_hash"))
  should.be_false(string.contains(first.body, "code_hash"))
  let assert Ok(thread_id_resp) =
    json.parse(first.body, decode.at(["thread_id"], decode.string))
  should.equal(thread_id_resp, thread_id)
  let assert Ok(first_id) =
    json.parse(first.body, decode.at(["id"], decode.string))

  // MULTI-USE: the same code pairs a second host (the multi-host
  // story) — a NEW node row, never a takeover.
  let assert Ok(second) = pair(live_code, "laptop-b")
  should.equal(second.status, 201)
  let assert Ok(second_id) =
    json.parse(second.body, decode.at(["id"], decode.string))
  should.be_false(first_id == second_id)

  // A name already paired is the same friendly 409 — a code must
  // never authorize a takeover (scoped to the thread, like the
  // schema's UNIQUE).
  let assert Ok(dup) = pair(live_code, "laptop-a")
  should.equal(dup.status, 409)
  // And the admin route's row collides the same way (the ONE mint
  // path's shared per-thread name space).
  let #(admin, _) =
    send_authorized(req(
      port,
      Post,
      "/nodes",
      "{\"thread\":\"" <> thread_id <> "\",\"name\":\"laptop-b\"}",
    ))
  should.equal(admin, 409)

  // PER-THREAD NAMES: the SAME name pairs fine into ANOTHER thread —
  // the ghost-row bug this scoping removes (a disconnected TUI's row
  // on thread A never blocks thread B). A second thread, the override
  // form, and the answer carries the OVERRIDE thread.
  let #(t2_status, t2_body) = create_thread_via_bot(port)
  should.equal(t2_status, 201)
  let assert Ok(thread_2) =
    json.parse(t2_body, decode.at(["id"], decode.string))
  let assert Ok(cross) = pair_into(live_code, "laptop-a", thread_2)
  should.equal(cross.status, 201)
  let assert Ok(cross_thread) =
    json.parse(cross.body, decode.at(["thread_id"], decode.string))
  should.equal(cross_thread, thread_2)
  // An override naming an UNKNOWN thread refuses (the row binds to
  // its thread) — 404, same as the admin route's thread check.
  let assert Ok(ghost_override) = pair_into(live_code, "laptop-e", "t-ghost")
  should.equal(ghost_override.status, 404)
  // An UNPINNED grant with no override has no thread to bind — 400,
  // never an unjoinable row.
  let assert Ok(unpinned) = pair(free_code, "laptop-f")
  should.equal(unpinned.status, 400)

  // Expired and unknown codes answer the IDENTICAL merged 404 — the
  // route must not become a code oracle. The EXPIRED plaintext is
  // actually redeemed here too (cubic review — it was seeded but
  // never exercised): byte-identical body, not just the same status.
  let assert Ok(unknown) = pair("not-a-real-code-at-all", "laptop-c")
  should.equal(unknown.status, 404)
  should.be_true(string.contains(unknown.body, "unknown or expired"))
  let assert Ok(expired_resp) = pair(expired_code, "laptop-d")
  should.equal(expired_resp.status, 404)
  should.equal(expired_resp.body, unknown.body)

  // An invalid name against a VALID code still refuses (the env
  // target-name gate — workspace is reserved).
  let assert Ok(reserved) = pair(live_code, "workspace")
  should.equal(reserved.status, 400)

  // THE CROSSING CASE: an invalid name must answer 400 even with a
  // BOGUS code — with the code check first, this probe distinguished
  // live (400) from bogus (404) codes: the oracle the merged 404
  // exists to prevent. Name gate first, unconditionally.
  let assert Ok(crossing) = pair("not-a-real-code-at-all", "workspace")
  should.equal(crossing.status, 400)
  let assert Ok(crossing2) = pair("not-a-real-code-at-all", "bad name")
  should.equal(crossing2.status, 400)

  // Unreadable body: 400, like the admin route.
  let assert Ok(bad) = hackney.send(req(port, Post, "/nodes/pair", "not json"))
  should.equal(bad.status, 400)

  // The nodes list (admin surface) shows both minted rows — the
  // exchange really went through the ONE mint path.
  let #(list_status, listed) = send_authorized(req(port, Get, "/nodes", ""))
  should.equal(list_status, 200)
  should.be_true(string.contains(listed, "laptop-a"))
  should.be_true(string.contains(listed, "laptop-b"))
}
