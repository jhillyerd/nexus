//// Unit tests for `nexus/net`: RFC 3986 relative URL / redirect resolution,
//// `final_url` & `content_encoding` plumbing, and lossy UTF-8 decoding.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, Some}
import gleam/string
import gleeunit/should
import mist
import nexus/net

@external(erlang, "net_test_ffi", "gzip")
fn gzip(body: String) -> String

@external(erlang, "net_test_ffi", "zlib_wrap")
fn zlib_wrap(body: String) -> String

@external(erlang, "net_test_ffi", "deflate_raw")
fn deflate_raw(body: String) -> String

@external(erlang, "net_test_ffi", "gzip_corrupt")
fn gzip_corrupt() -> String

@external(erlang, "net_test_ffi", "gzip_cut")
fn gzip_cut() -> String

@external(erlang, "net_test_ffi", "incompressible")
fn incompressible(size: Int) -> String

// ---------------------------------------------------------------------------
// RFC 3986 relative URL resolution (pure)
// ---------------------------------------------------------------------------

pub fn resolve_url_nested_relative_paths_test() {
  net.resolve_url("https://example.com/docs/v1/intro.html", "guide.html")
  |> should.equal(Ok("https://example.com/docs/v1/guide.html"))

  net.resolve_url("https://example.com/docs/v1/", "guide.html")
  |> should.equal(Ok("https://example.com/docs/v1/guide.html"))

  net.resolve_url("https://example.com/docs/v1/intro.html", "../v2/guide.html")
  |> should.equal(Ok("https://example.com/docs/v2/guide.html"))

  net.resolve_url("https://example.com/docs/v1/intro.html", "./sub/page.html")
  |> should.equal(Ok("https://example.com/docs/v1/sub/page.html"))

  // Trailing directory slashes stay intact.
  net.resolve_url("https://example.com/docs/v1/intro.html", "../v2/")
  |> should.equal(Ok("https://example.com/docs/v2/"))
}

pub fn resolve_url_root_query_fragment_and_protocol_relative_test() {
  net.resolve_url("https://example.com/docs/v1/intro.html", "/root/page")
  |> should.equal(Ok("https://example.com/root/page"))

  net.resolve_url("https://example.com/docs/v1/intro.html?a=1", "?b=2")
  |> should.equal(Ok("https://example.com/docs/v1/intro.html?b=2"))

  net.resolve_url("https://example.com/docs/v1/intro.html?a=1", "#section")
  |> should.equal(Ok("https://example.com/docs/v1/intro.html?a=1#section"))

  // Protocol-relative inherits scheme ONLY — never the base port.
  net.resolve_url("https://example.com:8443/a/b", "//cdn.example.net/x.js")
  |> should.equal(Ok("https://cdn.example.net/x.js"))

  // Absolute URL is returned verbatim — never inherits the base port.
  net.resolve_url("http://127.0.0.1:18041/redirect", "https://example.com/ok")
  |> should.equal(Ok("https://example.com/ok"))

  // Userinfo on an absolute or protocol-relative target is preserved so
  // `validate_url` can refuse it on the next hop.
  net.resolve_url("http://example.com/", "//user:pass@evil.example/x")
  |> should.equal(Ok("http://user:pass@evil.example/x"))
}

// ---------------------------------------------------------------------------
// Lossy UTF-8 decoding (pure)
// ---------------------------------------------------------------------------

pub fn lossy_utf8_decoding_handles_valid_truncated_and_latin1_test() {
  // Valid UTF-8 passes through unchanged.
  let valid = <<"héllo — 🚀":utf8>>
  net.bytes_to_text_lossy(valid) |> should.equal("héllo — 🚀")

  // Valid UTF-8 truncated mid-codepoint (first 2 bytes of 3-byte em-dash)
  // drops only the unfinished trailing bytes without corrupting earlier UTF-8.
  let truncated = <<"café ":utf8, 0xE2, 0x80>>
  net.bytes_to_text_lossy(truncated) |> should.equal("café ")

  // Latin-1 bytes decode to their Unicode equivalents without crashing.
  let latin1 = <<"caf":utf8, 0xE9, " na":utf8, 0xEF, "ve":utf8>>
  net.bytes_to_text_lossy(latin1) |> should.equal("café naïve")

  // Windows-1252 0x80-0x9F bytes map to smart quotes, em-dash, and euro.
  let cp1252 = <<
    0x80,
    "5 ",
    0x93,
    "hi",
    0x94,
    " ",
    0x97,
    " it",
    0x92,
    "s":utf8,
  >>
  net.bytes_to_text_lossy(cp1252) |> should.equal("€5 “hi” — it’s")
}

// ---------------------------------------------------------------------------
// Live loopback checks: relative redirects, final_url, content_encoding
// ---------------------------------------------------------------------------

const port = 18_044

fn handler(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
  let parsed = request.to_uri(req)
  let query: Option(String) = parsed.query
  case parsed.path, req.method {
    "/docs/v1/start", Get ->
      response.new(302)
      |> response.set_header("location", "next.html")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    "/docs/v1/next.html", Get ->
      response.new(302)
      |> response.set_header("location", "../v2/target?step=2")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    "/docs/v2/target", Get ->
      case query {
        Some("step=2") ->
          response.new(302)
          |> response.set_header("location", "?step=3")
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        Some("step=3") ->
          response.new(200)
          |> response.set_header("content-type", "text/plain")
          |> response.set_body(mist.Bytes(bytes_tree.from_string("arrived")))
        _ ->
          response.new(400)
          |> response.set_body(mist.Bytes(bytes_tree.from_string("bad query")))
      }
    "/gzipped", Get ->
      response.new(200)
      |> response.set_header("content-type", "text/html")
      |> response.set_header("content-encoding", "GZIP")
      |> response.set_body(mist.Bytes(bytes_tree.from_string("fake-gz")))
    "/gz-real", Get ->
      response.new(200)
      |> response.set_header("content-type", "text/plain")
      |> response.set_header("content-encoding", "gzip")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(gzip("round-trip through hackney"))),
      )
    "/multi-encoding", Get ->
      response.new(200)
      |> response.set_header("content-type", "text/html")
      |> response.prepend_header("content-encoding", "gzip")
      |> response.prepend_header("content-encoding", "identity")
      |> response.set_body(mist.Bytes(bytes_tree.from_string("fake-gz")))
    _, _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("missing")))
  }
}

fn start_service() -> Nil {
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

pub fn nested_relative_redirects_and_final_url_test() {
  start_service()
  let assert Ok(resp) =
    net.fetch(base() <> "/docs/v1/start", [], 4096, 2000, True, 5)
  resp.status |> should.equal(200)
  resp.body |> should.equal("arrived")
  resp.final_url |> should.equal(base() <> "/docs/v2/target?step=3")
  resp.content_encoding |> should.equal("")

  // Content-Encoding header is normalized to lowercase.
  let assert Ok(gz) = net.fetch(base() <> "/gzipped", [], 4096, 2000, True, 3)
  gz.status |> should.equal(200)
  gz.content_encoding |> should.equal("gzip")
  should.be_true(string.ends_with(gz.final_url, "/gzipped"))

  // Repeated Content-Encoding headers are all collected and joined.
  let assert Ok(multi) =
    net.fetch(base() <> "/multi-encoding", [], 4096, 2000, True, 3)
  multi.status |> should.equal(200)
  multi.content_encoding |> should.equal("identity, gzip")

  // hackney 1.25 passes content-encoded bytes through UNDECODED in the
  // manual stream_body path (verified in source; pinned here so a hackney
  // upgrade that starts decoding fails loudly) — decoding is wholly
  // `web_fetch`'s, via `net.inflate_bounded`.
  let assert Ok(raw_gz) =
    net.fetch(base() <> "/gz-real", [], 4096, 2000, True, 3)
  raw_gz.content_encoding |> should.equal("gzip")
  should.be_true(raw_gz.body != "round-trip through hackney")
  net.inflate_bounded(raw_gz.body, "gzip", 1000)
  |> should.equal(Ok(#("round-trip through hackney", False)))
}

// ---------------------------------------------------------------------------
// Bounded gzip/deflate inflation (`net.inflate_bounded`)
// ---------------------------------------------------------------------------

pub fn inflate_bounded_roundtrips_all_three_formats_test() {
  let plain = "hello compressible world " <> string.repeat("x", 5000)

  // gzip and the x-gzip alias (auto-detect windowBits 15+32).
  net.inflate_bounded(gzip(plain), "gzip", 1_000_000)
  |> should.equal(Ok(#(plain, False)))
  net.inflate_bounded(gzip(plain), "x-gzip", 1_000_000)
  |> should.equal(Ok(#(plain, False)))

  // Correct deflate: zlib-wrapped (RFC 1950).
  net.inflate_bounded(zlib_wrap(plain), "deflate", 1_000_000)
  |> should.equal(Ok(#(plain, False)))

  // Broken-server deflate: raw RFC 1951 bytes (windowBits -15 retry).
  net.inflate_bounded(deflate_raw(plain), "deflate", 1_000_000)
  |> should.equal(Ok(#(plain, False)))

  // Multi-chunk drain in BOTH directions: ~50 KB of incompressible input
  // spans several 8 KiB NIF input chunks, and its ~50 KB of output spans
  // several 16 KiB output chunks — the path the small cases never reach.
  let big = incompressible(50_000)
  should.be_true(string.byte_size(gzip(big)) > 16_384)
  net.inflate_bounded(gzip(big), "gzip", 1_000_000)
  |> should.equal(Ok(#(big, False)))

  // Trailing bytes after a complete member are ignored, and only the
  // FIRST member of a multi-member stream is decoded — neither flags
  // truncation (the member that WAS decoded ended cleanly).
  net.inflate_bounded(gzip(plain) <> "trailing garbage", "gzip", 1_000_000)
  |> should.equal(Ok(#(plain, False)))
  net.inflate_bounded(gzip(plain) <> gzip("second member"), "gzip", 1_000_000)
  |> should.equal(Ok(#(plain, False)))
}

pub fn inflate_bounded_caps_bombs_and_truncates_test() {
  // A ~9 MB decompression bomb: 9 MB of zeros compresses to under 20 KB,
  // so the WIRE cap could never stop it — only the decompressed cap does.
  let bomb = gzip(string.repeat("0", 9_000_000))
  should.be_true(string.byte_size(bomb) < 20_000)

  let assert Ok(#(out, truncated)) = net.inflate_bounded(bomb, "gzip", 4096)
  truncated |> should.equal(True)
  string.byte_size(out) |> should.equal(4096)
  out |> should.equal(string.repeat("0", 4096))

  // Output at EXACTLY the cap is not truncated (over-cap truncates).
  let exact = string.repeat("a", 100)
  net.inflate_bounded(gzip(exact), "gzip", 100)
  |> should.equal(Ok(#(exact, False)))
}

pub fn inflate_bounded_corrupt_and_empty_test() {
  // A gzip header prefix followed by garbage fails as a decode error, not
  // a crash (zlib raises error:data_error inside the FFI).
  net.inflate_bounded(gzip_corrupt(), "gzip", 1000)
  |> should.equal(Error("corrupt compressed stream"))

  // A stream cut mid-way (no terminator) decodes its partial output and
  // is flagged TRUNCATED — the verdict comes from inflateEnd, because
  // safeInflate's finished signal is spurious when input runs dry.
  net.inflate_bounded(gzip_cut(), "gzip", 1000)
  |> should.equal(Ok(#("012345678", True)))

  // An empty body carries no member to decode and passes through.
  net.inflate_bounded("", "gzip", 1000)
  |> should.equal(Ok(#("", False)))
}
