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
import gleam/otp/factory_supervisor
import gleam/string
import gleeunit/should
import mist
import nexus/config.{type Config}
import nexus/hackney
import nexus/loop
import nexus/openai
import nexus/session
import nexus/session_registry
import nexus/transcript
import nexus/web
import store_mock

const port = 18_061

const token = "sekrit"

fn test_config() -> Config {
  config.Config(
    base_url: "https://bifrost.example/v1",
    api_key: "sk-test",
    model_default: "default-alias",
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: port,
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
  _cfg,
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
fn start_server() -> process.Subject(session_registry.Msg) {
  let cfg = test_config()
  let factory_name = process.new_name("nexus_routes_factory")
  let registry_name = process.new_name("nexus_routes_registry")
  let component_name = process.new_name("nexus_routes_component")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    session_registry.start(
      cfg,
      factory_supervisor.get_by_name(factory_name),
      registry_name,
      persistence,
    )
  let _ =
    mist.new(web.handler(cfg, registry_name, component_name))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  process.sleep(100)
  started.data
}

fn req(method: http.Method, path: String, body: String) -> Request(String) {
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
  let registry = start_server()
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
    hackney.send(req(Patch, "/sessions/" <> record.id, "{\"pinned\":true}"))
  should.equal(denied.status, 401)
  let assert Ok(unauthorized) =
    hackney.send(req(Delete, "/sessions/" <> record.id, ""))
  should.equal(unauthorized.status, 401)

  // ---- auto-title at the send boundary --------------------------------
  should.equal(
    send_authorized(req(
      Post,
      "/sessions/" <> record.id <> "/send",
      "{\"text\":\"  first   message\\nhere  \"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  drain_turn(record.subject)
  let #(status, body) = send_authorized(req(Get, "/sessions", ""))
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
      Post,
      "/sessions/" <> record.id <> "/send",
      "{\"text\":\"second\"}",
    )),
    #(202, "{\"ok\":true}"),
  )
  let #(_status, body) = send_authorized(req(Get, "/sessions", ""))
  should.be_true(string.contains(body, "\"title\":\"Renamed\""))

  // ---- archive: soft-hide + archived view + restore --------------------
  let #(status, body) =
    send_authorized(req(Patch, "/sessions/" <> record.id, "{\"archived\":true}"))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":true"))

  // Default list hides it; ?archived=1 shows exactly it.
  let #(_status, active) = send_authorized(req(Get, "/sessions", ""))
  should.equal(session_ids(active), [])
  let #(_status, archived) =
    send_authorized(req(Get, "/sessions?archived=1", ""))
  should.equal(session_ids(archived), [record.id])

  // ---- pinned/archived invariant ----------------------------------------
  // Pinning an archived session via PATCH is rejected wholesale…
  should.equal(
    send_authorized(req(Patch, "/sessions/" <> record.id, "{\"pinned\":true}")),
    #(409, "{\"error\":\"cannot pin an archived session\"}"),
  )
  // …and the refusal changed nothing.
  let #(_status, still) = send_authorized(req(Get, "/sessions?archived=1", ""))
  should.be_true(string.contains(still, "\"pinned\":false"))
  // A restore+pin in one patch is fine (archive state applies first),
  // and the earlier pin was cleared by archiving, so it re-pins cleanly.
  let #(status, body) =
    send_authorized(req(
      Patch,
      "/sessions/" <> record.id,
      "{\"archived\":false,\"pinned\":true}",
    ))
  should.equal(status, 200)
  should.be_true(string.contains(body, "\"archived\":false"))
  should.be_true(string.contains(body, "\"pinned\":true"))

  // ---- PATCH validation -------------------------------------------------
  should.equal(send_authorized(req(Patch, "/sessions/" <> record.id, "{}")), #(
    400,
    "{\"error\":\"empty patch\"}",
  ))
  should.equal(
    send_authorized(req(Patch, "/sessions/" <> record.id, "not json")),
    #(400, "{\"error\":\"unreadable body\"}"),
  )
  should.equal(
    send_authorized(req(Patch, "/sessions/" <> record.id, "{\"title\":\"  \"}")),
    #(400, "{\"error\":\"empty title\"}"),
  )
  should.equal(
    send_authorized(req(Patch, "/sessions/nope", "{\"pinned\":true}")),
    #(404, "{\"error\":\"session not found\"}"),
  )

  // ---- DELETE: hard removal ---------------------------------------------
  should.equal(send_authorized(req(Delete, "/sessions/" <> record.id, "")), #(
    204,
    "",
  ))
  let #(_status, after) = send_authorized(req(Get, "/sessions?archived=1", ""))
  should.equal(session_ids(after), [])
  should.equal(send_authorized(req(Delete, "/sessions/" <> record.id, "")), #(
    404,
    "{\"error\":\"session not found\"}",
  ))
  session_registry.get(registry, record.id) |> should.equal(Error(Nil))
}
