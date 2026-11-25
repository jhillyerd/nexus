//// http_fetch adapter tests against a controlled local HTTP service
//// (mist on loopback — `allow_private` is exactly the dev/test escape
//// hatch for this), plus pure SSRF-guard tests. Phase 5 (curl upgrades,
//// docs/plans/completed/web-fetch.md): method/body/header round-trips, redirect
//// method semantics, cross-origin credential stripping, response-header
//// reporting with caps, and argument validation.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Delete, Get, Head, Options, Patch, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import mist
import nexus/http_fetch
import nexus/net

const port = 18_041

/// One controlled service: routes under /ok, /big, /redirect, /relative
/// (M3) and /echo, /r307, /r302, /cross, /teapot, /many-headers (Phase 5).
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
    "/echo", _ -> echo_response(req)
    "/r307", _ -> respond_status(307, "/echo")
    "/r302", _ -> respond_status(302, "/echo")
    // Cross-ORIGIN redirect: same port, different host spelling, so the
    // credential-stripping rule (not the port) is what the echo observes.
    "/cross", _ ->
      respond_status(302, "http://localhost:" <> int.to_string(port) <> "/echo")
    "/cookies", Get ->
      // Two Set-Cookie lines whose values embed commas (RFC 9110 §5.2:
      // set-cookie is not combinable) — they must arrive as separate
      // verbatim cookies, never a joined corruption.
      response.new(200)
      |> response.set_header(
        "set-cookie",
        "a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/",
      )
      |> response.prepend_header(
        "set-cookie",
        "b=2; Expires=Thu, 22 Oct 2015 07:28:00 GMT; Path=/",
      )
      |> response.set_body(mist.Bytes(bytes_tree.from_string("two cookies")))
    "/teapot", _ ->
      response.new(418)
      |> response.set_header("retry-after", "42")
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("short and stout")),
      )
    "/many-headers", Get -> {
      // 24 headers x ~600 bytes each: far past the 8 KiB collection cap.
      list.fold(
        list.index_map(list.repeat(Nil, 24), fn(_, i) { i + 1 }),
        response.new(200),
        fn(acc, i) {
          response.set_header(
            acc,
            "x-pad-" <> int.to_string(i),
            string.repeat("a", 600),
          )
        },
      )
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    _, _ -> respond_status(404, "not found")
  }
}

/// Echo endpoint: reflects the request method, body, and a few named
/// headers back as JSON so round-trips are assertable offline.
fn echo_response(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
  case mist.read_body(req, max_body_limit: 65_536) {
    Ok(read) -> {
      let body = case bit_array.to_string(read.body) {
        Ok(text) -> text
        Error(Nil) -> ""
      }
      let seen = fn(name) {
        case request.get_header(read, name) {
          Ok(value) -> value
          Error(Nil) -> ""
        }
      }
      respond(
        200,
        "application/json",
        json.object([
          #("method", json.string(http.method_to_string(req.method))),
          #("body", json.string(body)),
          #("authorization", json.string(seen("authorization"))),
          #("cookie", json.string(seen("cookie"))),
          #("x_probe", json.string(seen("x-probe"))),
          #("x_note", json.string(seen("x-note"))),
          #("content_type", json.string(seen("content-type"))),
        ])
          |> json.to_string,
      )
    }
    Error(_) -> respond(400, "text/plain", "unreadable body")
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

fn base() -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn run() -> fn(String) -> Result(String, String) {
  http_fetch.run(500, 2000, True)
}

fn fetch(path: String) -> Result(String, String) {
  run()(json_args(path, None, [], None))
}

/// Minimal argument encoder shared by the tests.
fn json_args(
  path: String,
  method: Option(String),
  headers: List(#(String, String)),
  body: Option(String),
) -> String {
  let method_field = case method {
    Some(m) -> [#("method", json.string(m))]
    None -> []
  }
  let header_field = case headers {
    [] -> []
    _ -> [
      #(
        "headers",
        json.object(list.map(headers, fn(h) { #(h.0, json.string(h.1)) })),
      ),
    ]
  }
  let body_field = case body {
    Some(b) -> [#("body", json.string(b))]
    None -> []
  }
  json.object([
    #("url", json.string(base() <> path)),
    ..list.flatten([method_field, header_field, body_field])
  ])
  |> json.to_string
}

// ---------------------------------------------------------------------------
// Decoding the tool's JSON result
// ---------------------------------------------------------------------------

type ToolResult {
  ToolResult(
    status: Int,
    url: String,
    body: String,
    headers: Dict(String, String),
    headers_truncated: Bool,
    truncated: Bool,
    error: Option(String),
  )
}

fn decode_tool(content: String) -> ToolResult {
  let decoder = {
    use status <- decode.field("status", decode.int)
    use url <- decode.field("url", decode.string)
    use body <- decode.field("body", decode.string)
    use headers <- decode.field(
      "headers",
      decode.dict(decode.string, decode.string),
    )
    use headers_truncated <- decode.field("headers_truncated", decode.bool)
    use truncated <- decode.field("truncated", decode.bool)
    use error <- decode.optional_field(
      "error",
      None,
      decode.optional(decode.string),
    )
    decode.success(ToolResult(
      status: status,
      url: url,
      body: body,
      headers: headers,
      headers_truncated: headers_truncated,
      truncated: truncated,
      error: error,
    ))
  }
  let assert Ok(result) = json.parse(content, decoder)
  result
}

/// The echo endpoint's reflected request: method, body, named headers.
type Echo {
  Echo(
    method: String,
    body: String,
    authorization: String,
    cookie: String,
    x_probe: String,
    x_note: String,
    content_type: String,
  )
}

fn decode_echo(tool: ToolResult) -> Echo {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use body <- decode.field("body", decode.string)
    use authorization <- decode.field("authorization", decode.string)
    use cookie <- decode.field("cookie", decode.string)
    use x_probe <- decode.field("x_probe", decode.string)
    use x_note <- decode.field("x_note", decode.string)
    use content_type <- decode.field("content_type", decode.string)
    decode.success(Echo(
      method:,
      body:,
      authorization:,
      cookie:,
      x_probe:,
      x_note:,
      content_type:,
    ))
  }
  let assert Ok(reflected) = json.parse(tool.body, decoder)
  reflected
}

// ---------------------------------------------------------------------------
// M3 behavior (unchanged posture, richer result)
// ---------------------------------------------------------------------------

pub fn adapter_roundtrips_test() {
  start_service()

  // Plain 200 fetch: status, final url, content_type in headers, body.
  let assert Ok(content) = fetch("/ok")
  let ok = decode_tool(content)
  ok.status |> should.equal(200)
  ok.url |> should.equal(base() <> "/ok")
  ok.body |> should.equal("hello from the controlled service")
  ok.truncated |> should.equal(False)
  ok.headers_truncated |> should.equal(False)
  ok.error |> should.equal(None)
  should.equal(dict.get(ok.headers, "content-type"), Ok("text/plain"))

  // Body cap: 1000 bytes served, 500 kept — the cap still bounds the BODY
  // (the new header metadata rides beside it, not through it).
  let assert Ok(big) = fetch("/big")
  let capped = decode_tool(big)
  capped.truncated |> should.equal(True)
  string.length(capped.body) |> should.equal(500)

  // Same fetch twice: the listener must survive a closed connection.
  let assert Ok(again) = fetch("/ok")
  decode_tool(again).status |> should.equal(200)

  // Manual redirects, absolute and relative, re-validated per hop; the
  // final URL reports where the chain landed.
  let assert Ok(redirected) = fetch("/redirect")
  let redir = decode_tool(redirected)
  redir.status |> should.equal(200)
  redir.url |> should.equal(base() <> "/ok")
  let assert Ok(relative) = fetch("/relative")
  decode_tool(relative).url |> should.equal(base() <> "/ok")

  // Redirect chains are bounded.
  let assert Error(loop_reason) = fetch("/redirect?loop")
  should.be_true(string.contains(loop_reason, "too many redirects"))

  // Malformed arguments are a tool error.
  let assert Error(reason) = run()("not json")
  should.be_true(string.contains(reason, "url"))
}

// ---------------------------------------------------------------------------
// Phase 5: method, body, and request headers
// ---------------------------------------------------------------------------

pub fn post_body_and_headers_roundtrip_test() {
  start_service()
  let assert Ok(content) =
    run()(json_args(
      "/echo",
      Some("POST"),
      [
        #("Authorization", "Bearer tok123"),
        #("x-probe", "yes"),
        #("x-note", "café — honnête"),
        #("content-type", "application/json"),
      ],
      Some("{\"a\":1}"),
    ))
  let tool = decode_tool(content)
  tool.status |> should.equal(200)
  tool.error |> should.equal(None)
  let reflected = decode_echo(tool)
  reflected.method |> should.equal("POST")
  reflected.body |> should.equal("{\"a\":1}")
  reflected.authorization |> should.equal("Bearer tok123")
  reflected.x_probe |> should.equal("yes")
  // Non-ASCII (obs-text) values ride the wire verbatim; only control
  // bytes are refused.
  reflected.x_note |> should.equal("café — honnête")
  reflected.content_type |> should.equal("application/json")
}

pub fn put_patch_delete_head_options_roundtrip_test() {
  start_service()
  list.each([Put, Patch, Delete, Head, Options], fn(method) {
    let assert Ok(content) =
      run()(json_args("/echo", Some(http.method_to_string(method)), [], None))
    let tool = decode_tool(content)
    tool.status |> should.equal(200)
    case method {
      // HEAD carries no response body; every other verb echoes itself.
      Head -> tool.body |> should.equal("")
      _ ->
        decode_echo(tool).method |> should.equal(http.method_to_string(method))
    }
  })
}

pub fn lowercase_method_is_accepted_test() {
  start_service()
  let assert Ok(content) = run()(json_args("/echo", Some("post"), [], None))
  decode_echo(decode_tool(content)).method |> should.equal("POST")
}

// ---------------------------------------------------------------------------
// Phase 5: redirect semantics for non-GET methods
// ---------------------------------------------------------------------------

pub fn redirect_307_preserves_method_and_body_test() {
  start_service()
  let assert Ok(content) =
    run()(json_args(
      "/r307",
      Some("POST"),
      [#("x-probe", "kept")],
      Some("cargo"),
    ))
  let reflected = decode_echo(decode_tool(content))
  reflected.method |> should.equal("POST")
  reflected.body |> should.equal("cargo")
  reflected.x_probe |> should.equal("kept")
}

pub fn redirect_302_downgrades_post_to_get_test() {
  start_service()
  let assert Ok(content) =
    run()(json_args(
      "/r302",
      Some("POST"),
      [#("x-probe", "kept")],
      Some("cargo"),
    ))
  let tool = decode_tool(content)
  tool.url |> should.equal(base() <> "/echo")
  let reflected = decode_echo(tool)
  reflected.method |> should.equal("GET")
  reflected.body |> should.equal("")
  // Same-origin redirect: custom headers survive.
  reflected.x_probe |> should.equal("kept")
}

pub fn cross_origin_redirect_strips_credentials_test() {
  start_service()
  let assert Ok(content) =
    run()(json_args(
      "/cross",
      Some("GET"),
      [
        #("Authorization", "Bearer secret-token"),
        #("Cookie", "session=1"),
        #("x-probe", "kept"),
      ],
      None,
    ))
  let tool = decode_tool(content)
  // The chain landed on the OTHER host spelling.
  tool.url
  |> should.equal("http://localhost:" <> int.to_string(port) <> "/echo")
  let reflected = decode_echo(tool)
  reflected.authorization |> should.equal("")
  reflected.cookie |> should.equal("")
  // x-probe survives; only credential-bearing headers are stripped.
  reflected.x_probe |> should.equal("kept")
}

// ---------------------------------------------------------------------------
// Phase 5: non-2xx payload and response-header caps
// ---------------------------------------------------------------------------

pub fn non_2xx_reports_body_headers_and_error_test() {
  start_service()
  // Non-2xx statuses surface as error results carrying the status — plus
  // (Phase 5) the response body and headers, curl-style.
  let assert Error(missing) = fetch("/missing")
  let missing_tool = decode_tool(missing)
  missing_tool.status |> should.equal(404)
  missing_tool.error |> should.equal(Some("non-success status"))

  let assert Error(teapot) = fetch("/teapot")
  let t = decode_tool(teapot)
  t.status |> should.equal(418)
  t.error |> should.equal(Some("non-success status"))
  t.body |> should.equal("short and stout")
  should.equal(dict.get(t.headers, "retry-after"), Ok("42"))
}

pub fn response_headers_are_capped_test() {
  start_service()
  let assert Ok(content) = fetch("/many-headers")
  let tool = decode_tool(content)
  tool.status |> should.equal(200)
  tool.headers_truncated |> should.equal(True)
  // The cap cut the set well below the 24 served padding headers, and
  // every kept padding header survived verbatim.
  let kept =
    dict.keys(tool.headers)
    |> list.filter(fn(name) { string.starts_with(name, "x-pad-") })
  should.be_true(list.length(kept) < 24)
  list.each(kept, fn(name) {
    should.equal(dict.get(tool.headers, name), Ok(string.repeat("a", 600)))
  })
  // The rendered header block stays near the 8 KiB budget.
  let rendered =
    tool.headers
    |> dict.to_list
    |> list.map(fn(pair) { string.byte_size(pair.0) + string.byte_size(pair.1) })
    |> list.fold(0, int.add)
  should.be_true(rendered <= 8192 + 128 * 4)
}

// ---------------------------------------------------------------------------
// Phase 5: argument validation
// ---------------------------------------------------------------------------

pub fn invalid_method_is_rejected_test() {
  start_service()
  let assert Error(reason) = run()(json_args("/echo", Some("FETCH"), [], None))
  should.be_true(string.contains(reason, "method must be one of"))
  let assert Error(reason) =
    run()(json_args("/echo", Some("CONNECT"), [], None))
  should.be_true(string.contains(reason, "method must be one of"))
  // Header-smuggling shapes in the method are impossible by the same
  // whitelist.
  let assert Error(reason) =
    run()(json_args("/echo", Some("GET /x HTTP/1.1"), [], None))
  should.be_true(string.contains(reason, "method must be one of"))
}

pub fn blocked_and_malformed_headers_are_rejected_test() {
  start_service()
  // Framing/hop-by-hop headers are the client's to manage.
  let assert Error(cl) =
    run()(json_args("/echo", None, [#("Content-Length", "5")], None))
  should.be_true(string.contains(cl, "managed by the client"))
  let assert Error(te) =
    run()(json_args("/echo", None, [#("Transfer-Encoding", "chunked")], None))
  should.be_true(string.contains(te, "managed by the client"))
  let assert Error(host) =
    run()(json_args("/echo", None, [#("Host", "evil.example")], None))
  should.be_true(string.contains(host, "managed by the client"))
  // Invalid token names.
  let assert Error(space) =
    run()(json_args("/echo", None, [#("Bad Name", "v")], None))
  should.be_true(string.contains(space, "invalid header name"))
  let assert Error(colon) =
    run()(json_args("/echo", None, [#("x:inject", "v")], None))
  should.be_true(string.contains(colon, "invalid header name"))
  let assert Error(empty) = run()(json_args("/echo", None, [#("", "v")], None))
  should.be_true(string.contains(empty, "invalid header name"))
  // Control bytes in values (request splitting).
  let assert Error(crlf) =
    run()(json_args("/echo", None, [#("x-safe", "a\r\nX-Injected: 1")], None))
  should.be_true(string.contains(crlf, "control characters"))
  let assert Error(nul) =
    run()(json_args("/echo", None, [#("x-safe", "a\u{0}b")], None))
  should.be_true(string.contains(nul, "control characters"))
  // Non-string header values / non-object shapes fail argument decoding.
  let assert Error(not_string) =
    run()("{\"url\":\"" <> base() <> "/echo\",\"headers\":{\"x\":5}}")
  should.be_true(string.contains(not_string, "url"))
  let assert Error(not_object) =
    run()("{\"url\":\"" <> base() <> "/echo\",\"headers\":[1,2]}")
  should.be_true(string.contains(not_object, "url"))
  let assert Error(body_not_string) =
    run()("{\"url\":\"" <> base() <> "/echo\",\"body\":7}")
  should.be_true(string.contains(body_not_string, "url"))
}

pub fn empty_url_is_rejected_test() {
  start_service()
  let assert Error(reason) = run()("{\"url\":\"  \"}")
  should.be_true(string.contains(reason, "non-empty"))
}

// ---------------------------------------------------------------------------
// Hard deadline (the wedged-TLS-handshake regression)
// ---------------------------------------------------------------------------

const silent_tls_port = 18_043

@external(erlang, "net_test_ffi", "start_silent_listener")
fn start_silent_listener(port: Int) -> Result(Nil, String)

@external(erlang, "net_test_ffi", "now_ms")
fn now_ms() -> Int

/// Memoized listener start (see net_test_ffi:ensure_listener) — true on
/// the first call, which is the one that needs the settle sleep.
@external(erlang, "net_test_ffi", "ensure_listener")
fn ensure_listener(port: Int, start: fn() -> a) -> Bool

fn start_service() -> Nil {
  case
    ensure_listener(port, fn() {
      mist.new(handler)
      |> mist.bind("127.0.0.1")
      |> mist.port(port)
      |> mist.start
    })
  {
    True -> process.sleep(100)
    False -> Nil
  }
}

/// Found live (thread s2 on plastic.home.arpa, 2026-11-17): a server that
/// completes the TCP connect but never speaks TLS stalls the TLS handshake
/// forever — hackney 1.25 performs it with `ssl:connect(Sock, Opts)`, the
/// no-timeout two-argument form; its `connect_timeout` covers only the TCP
/// stage and `recv_timeout` only starts after the request has been sent. The
/// fetch worker used to hang past every configured bound, wedging the
/// turn. nexus_net_ffi now runs each hop under a hard total deadline and
/// kills the fetch at it: the call must RETURN (an error — tool data, not
/// a loop error) within roughly 2×timeout + slack, instead of never.
pub fn stalled_tls_handshake_is_deadline_bounded_test() {
  let assert Ok(_) = start_silent_listener(silent_tls_port)
  // The fetch runs in a worker that reports back through a subject: if
  // the deadline itself regresses (the bug this test guards), the
  // receive below times out and the suite FAILS loudly instead of
  // hanging forever inside net.request.
  let reporter = process.new_subject()
  process.spawn(fn() {
    let started = now_ms()
    let result =
      net.request(
        http.Post,
        "https://127.0.0.1:" <> int.to_string(silent_tls_port) <> "/",
        [],
        "payload",
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
      // net.request surfaces the FFI error verbatim; the "fetch failed: "
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

// ---------------------------------------------------------------------------
// Phase 5 review hardening: schema regression net + validator edges
// ---------------------------------------------------------------------------

/// The `parameters` const is a long hand-escaped JSON string; one
/// unbalanced escape degrades schema() to "no parameter definitions"
/// silently — the model would then call http_fetch with unvalidated
/// guesses on every new thread. This net fails the moment that parse
/// does, and pins that the schema's property names match what parse_args
/// actually accepts.
pub fn schema_parameters_parse_and_match_args_test() {
  let chat.FunctionTool(function: f) = http_fetch.schema()
  let assert Some(params) = f.parameters
  let assert Ok(#(properties, required, additional)) =
    decode.run(params, {
      use properties <- decode.field(
        "properties",
        decode.dict(decode.string, decode.dynamic),
      )
      use required <- decode.field("required", decode.list(decode.string))
      use additional <- decode.field("additionalProperties", decode.bool)
      decode.success(#(properties, required, additional))
    })
  // Property names match what parse_args accepts — nothing more,
  // nothing less.
  list.sort(dict.keys(properties), by: string.compare)
  |> should.equal(["body", "headers", "method", "url"])
  required |> should.equal(["url"])
  additional |> should.equal(False)
}

/// A decomposed (NFD) name clusters into graphemes whose leading
/// codepoint is a tchar — the grapheme-level check let the combining
/// mark ride along; the codepoint check refuses it.
pub fn nfd_header_name_is_rejected_test() {
  start_service()
  let assert Error(reason) =
    run()(json_args("/echo", None, [#("x-cafe\u{0301}", "v")], None))
  should.be_true(string.contains(reason, "invalid header name"))
}

/// Expect is client-managed framing state (a model-supplied
/// `Expect: 100-continue` can stall the request past every soft bound):
/// refused exactly like content-length.
pub fn expect_header_is_rejected_test() {
  start_service()
  let assert Error(reason) =
    run()(json_args("/echo", None, [#("Expect", "100-continue")], None))
  should.be_true(string.contains(reason, "managed by the client"))
}

/// set-cookie is surfaced as ONE array-valued key with each cookie a
/// separate verbatim string — commas inside values survive intact.
pub fn set_cookie_headers_stay_separate_test() {
  start_service()
  let assert Ok(content) = fetch("/cookies")
  let assert Ok(cookies) =
    json.parse(
      content,
      decode.at(["headers", "set-cookie"], decode.list(decode.string)),
    )
  // prepend_header puts b FIRST on the wire: arrival order is [b, a],
  // and each cookie stays a separate verbatim string.
  cookies
  |> should.equal([
    "b=2; Expires=Thu, 22 Oct 2015 07:28:00 GMT; Path=/",
    "a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/",
  ])
  // And the body rides along as usual.
  let assert Ok(body) = json.parse(content, decode.at(["body"], decode.string))
  body |> should.equal("two cookies")
}

/// The schema says additionalProperties: false — enforce it argument-side
/// too, so a misspelled field (`data` meant as `body`) is a loud tool
/// error instead of a request silently sent without its payload.
pub fn unknown_argument_field_is_rejected_test() {
  start_service()
  let assert Error(reason) =
    run()("{\"url\":\"" <> base() <> "/echo\",\"data\":\"x\"}")
  should.be_true(string.contains(reason, "unknown argument field"))
  should.be_true(string.contains(reason, "data"))
  // Known fields still parse.
  let assert Ok(_) = run()(json_args("/echo", None, [], None))
}

/// Header names are case-insensitive per RFC 9110: "Authorization" and
/// "authorization" are the same header, so both on one request is a
/// duplicate and refused.
pub fn case_insensitive_duplicate_header_names_are_rejected_test() {
  start_service()
  let assert Error(reason) =
    run()(json_args("/echo", None, [#("X-Probe", "a"), #("x-probe", "b")], None))
  should.be_true(string.contains(reason, "unique"))
}
