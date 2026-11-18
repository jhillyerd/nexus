//// http_fetch adapter tests against a controlled local HTTP service
//// (mist on loopback — `allow_private` is exactly the dev/test escape
//// hatch for this), plus pure SSRF-guard tests.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import gleeunit/should
import mist
import nexus/http_fetch
import nexus/net

const port = 18_041

/// One controlled service: routes under /ok, /big, /redirect, /relative.
fn handler(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
  let #(path, query) = split_query(req)
  case path, req.method {
    "/ok", Get ->
      respond(200, "text/plain", "hello from the controlled service")
    "/big", Get -> respond(200, "text/plain", string.repeat("x", 1000))
    "/redirect", Get ->
      case query {
        Some("loop") -> respond_status(302, "/redirect?loop")
        _ -> respond_status(302, "/ok")
      }
    "/relative", Get -> respond_status(302, "ok")
    _, _ -> respond_status(404, "not found")
  }
}

fn respond(
  status: Int,
  content_type: String,
  body: String,
) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn respond_status(
  status: Int,
  location: String,
) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("location", location)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
}

fn split_query(req: Request(mist.Connection)) -> #(String, Option(String)) {
  let parsed = request.to_uri(req)
  #(parsed.path, parsed.query)
}

fn start_service() -> Nil {
  // Idempotent: later tests in this module reuse the listener started by
  // the first one (the port is fixed).
  let _ =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  process.sleep(100)
}

fn base() -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn fetch(path: String) -> Result(String, String) {
  let run = http_fetch.run(500, 2000, True)
  run("{\"url\":\"" <> base() <> path <> "\"}")
}

pub fn adapter_roundtrips_test() {
  start_service()

  // Plain 200 fetch.
  let assert Ok(content) = fetch("/ok")
  should.be_true(string.contains(content, "\"status\":200"))
  should.be_true(string.contains(content, "controlled service"))
  should.be_true(string.contains(content, "\"truncated\":false"))

  // Body cap: 1000 bytes served, 500 kept.
  let assert Ok(big) = fetch("/big")
  should.be_true(string.contains(big, "\"truncated\":true"))
  should.be_true(string.length(big) < 700)

  // Same fetch twice: the listener must survive a closed connection.
  let assert Ok(again) = fetch("/ok")
  should.be_true(string.contains(again, "\"status\":200"))

  // Manual redirects, absolute and relative, re-validated per hop.
  let assert Ok(redirected) = fetch("/redirect")
  should.be_true(string.contains(redirected, "\"status\":200"))
  let assert Ok(relative) = fetch("/relative")
  should.be_true(string.contains(relative, "\"status\":200"))

  // Redirect chains are bounded.
  let assert Error(loop_reason) = fetch("/redirect?loop")
  should.be_true(string.contains(loop_reason, "too many redirects"))

  // Non-2xx statuses surface as error results carrying the status.
  let assert Error(missing) = fetch("/missing")
  should.be_true(string.contains(missing, "\"status\":404"))

  // Malformed arguments are a tool error.
  let run = http_fetch.run(500, 2000, True)
  let assert Error(reason) = run("not json")
  should.be_true(string.contains(reason, "url"))
}

// ---------------------------------------------------------------------------
// Hard deadline (the wedged-TLS-handshake regression)
// ---------------------------------------------------------------------------

const silent_tls_port = 18_043

@external(erlang, "net_test_ffi", "start_silent_listener")
fn start_silent_listener(port: Int) -> Result(Nil, String)

@external(erlang, "net_test_ffi", "now_ms")
fn now_ms() -> Int

/// Found live (thread s2 on plastic.home.arpa, 2026-11-17): a server that
/// completes the TCP connect but never speaks TLS stalls the TLS handshake
/// forever — hackney 1.25 performs it with `ssl:connect(Sock, Opts)`, the
/// no-timeout two-argument form; its `connect_timeout` covers only the TCP
/// stage and `recv_timeout` only starts after the request is sent. The
/// fetch worker used to hang past every configured bound, wedging the
/// turn. nexus_net_ffi now runs each hop under a hard total deadline and
/// kills the fetch at it: the call must RETURN (an error — tool data, not
/// a loop error) within roughly 2×timeout + slack, instead of never.
pub fn stalled_tls_handshake_is_deadline_bounded_test() {
  let assert Ok(_) = start_silent_listener(silent_tls_port)
  // The fetch runs in a worker that reports back through a subject: if
  // the deadline itself regresses (the bug this test guards), the
  // receive below times out and the suite FAILS loudly instead of
  // hanging forever inside net.fetch.
  let reporter = process.new_subject()
  process.spawn(fn() {
    let started = now_ms()
    let result =
      net.fetch(
        "https://127.0.0.1:" <> int.to_string(silent_tls_port) <> "/",
        [],
        20_000,
        // 1s budget → 4s hard deadline: fast enough to keep the suite
        // snappy, long enough that the deadline (not a fast TLS refusal)
        // is what ends the call.
        1000,
        True,
        3,
      )
    process.send(reporter, #(now_ms() - started, result))
  })
  // The deadline is 4s; 20s of receive slack before declaring it dead.
  case process.receive(reporter, 20_000) {
    Ok(#(elapsed, result)) -> {
      // The deadline floor proves the stall really happened and was
      // waited out (a fast failure would mean the listener answered TLS
      // somehow); the ceiling proves the deadline fired — pre-fix this
      // call NEVER returned and hung the whole suite.
      should.be_true(elapsed >= 3500)
      should.be_true(elapsed < 15_000)
      // net.fetch surfaces the FFI error verbatim; the "fetch failed: "
      // prefix is added by the http_fetch tool adapter above it.
      let assert Error("timeout (hard deadline)") = result
    }
    Error(Nil) ->
      panic as "stalled-TLS fetch never returned: the hard deadline did not fire"
  }
}

// ---------------------------------------------------------------------------
// SSRF guard (pure)
// ---------------------------------------------------------------------------

pub fn private_addresses_are_recognised_test() {
  [
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.1",
    "169.254.169.254", "0.0.0.0", "100.64.0.1", "::1", "fe80::1", "fd00::1",
  ]
  |> list.each(fn(address) { should.be_true(net.is_private_address(address)) })
  ["93.184.216.34", "1.1.1.1", "2606:4700:4700::1111"]
  |> list.each(fn(address) { should.be_false(net.is_private_address(address)) })
}

pub fn guard_rejects_private_and_schemes_test() {
  // Loopback and LAN targets are refused even though they resolve.
  let assert Error(reason) = net.validate_url("http://127.0.0.1/", False)
  should.be_true(string.contains(reason, "private"))
  let assert Error(reason) = net.validate_url("http://localhost/", False)
  should.be_true(string.contains(reason, "private"))
  let assert Error(reason) = net.validate_url("http://192.168.1.1/", False)
  should.be_true(string.contains(reason, "private"))
  // Non-http(s) schemes and userinfo are refused outright.
  let assert Error(_) = net.validate_url("file:///etc/passwd", True)
  let assert Error(_) = net.validate_url("ftp://example.invalid/", True)
  let assert Error(_) = net.validate_url("http://u:p@example.invalid/", True)
  // Unresolvable hosts report the resolve failure.
  let assert Error(reason) = net.validate_url("http://example.invalid/", False)
  should.be_true(string.contains(reason, "resolve"))
}
