//// Offline unit tests for `nexus/web_fetch`: HTML conversion, native Markdown
//// & text/JSON passthrough, unsolicited Content-Encoding rejection, binary
//// rejection, missing Content-Type sniffing, cache pagination & fragment hits,
//// start_index past end, max_length clamping, non-2xx non-caching, SSRF/
//// transport errors, and raw_truncated propagation.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import nexus/net.{FetchResponse}
import nexus/web_fetch
import nexus/web_fetch_cache

type PageResult {
  PageResult(
    status: Int,
    url: String,
    title: Option(String),
    content_type: String,
    format: String,
    total_chars: Int,
    start_index: Int,
    returned_chars: Int,
    has_more: Bool,
    raw_truncated: Bool,
    cached: Bool,
    content: String,
  )
}

fn decode_page(raw: String) -> PageResult {
  let decoder = {
    use status <- decode.field("status", decode.int)
    use url <- decode.field("url", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use content_type <- decode.field("content_type", decode.string)
    use format <- decode.field("format", decode.string)
    use total_chars <- decode.field("total_chars", decode.int)
    use start_index <- decode.field("start_index", decode.int)
    use returned_chars <- decode.field("returned_chars", decode.int)
    use has_more <- decode.field("has_more", decode.bool)
    use raw_truncated <- decode.field("raw_truncated", decode.bool)
    use cached <- decode.field("cached", decode.bool)
    use content <- decode.field("content", decode.string)
    decode.success(PageResult(
      status:,
      url:,
      title:,
      content_type:,
      format:,
      total_chars:,
      start_index:,
      returned_chars:,
      has_more:,
      raw_truncated:,
      cached:,
      content:,
    ))
  }
  let assert Ok(page) = json.parse(raw, decoder)
  page
}

fn opts(cache: Option(web_fetch_cache.Seam)) -> web_fetch.Options {
  web_fetch.Options(
    max_raw_bytes: 1_048_576,
    timeout_ms: 5000,
    allow_private: False,
    default_chars: 12_000,
    max_chars: 32_000,
    cache: cache,
  )
}

fn ok_resp(
  content_type: String,
  final_url: String,
  body: String,
) -> net.FetchResponse {
  FetchResponse(
    status: 200,
    content_type: content_type,
    location: "",
    body: body,
    truncated: False,
    final_url: final_url,
    content_encoding: "",
  )
}

pub fn html_conversion_and_headers_test() {
  let run =
    web_fetch.run_with(opts(None), fn(_url, headers) {
      // Request headers must advertise Markdown preference and identity encoding.
      should.be_true(
        list.any(headers, fn(h) {
          h.0 == "Accept" && string.contains(h.1, "text/markdown")
        }),
      )
      should.be_true(list.contains(headers, #("Accept-Encoding", "identity")))
      Ok(ok_resp(
        "text/html; charset=utf-8",
        "https://example.com/docs/v1/intro.html",
        "<html><head><title>Intro</title></head><body><h1>Welcome</h1>"
          <> "<p>Read the <a href=\"guide.html\">guide</a>.</p></body></html>",
      ))
    })

  let assert Ok(raw) = run("{\"url\":\"https://example.com/start\"}")
  let page = decode_page(raw)
  page.status |> should.equal(200)
  page.url |> should.equal("https://example.com/docs/v1/intro.html")
  page.title |> should.equal(Some("Intro"))
  page.content_type |> should.equal("text/html; charset=utf-8")
  page.format |> should.equal("markdown")
  page.has_more |> should.equal(False)
  page.raw_truncated |> should.equal(False)
  page.cached |> should.equal(False)
  page.content
  |> should.equal(
    "# Welcome\n\nRead the [guide](https://example.com/docs/v1/guide.html).",
  )
  page.total_chars |> should.equal(string.length(page.content))
  page.returned_chars |> should.equal(page.total_chars)
}

pub fn native_markdown_and_text_json_passthrough_test() {
  let md_run =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp("text/markdown; charset=utf-8", url, "# Native\n\nBody"))
    })
  let assert Ok(raw_md) = md_run("{\"url\":\"https://example.com/doc.md\"}")
  let md = decode_page(raw_md)
  md.format |> should.equal("markdown")
  md.title |> should.equal(None)
  md.content |> should.equal("# Native\n\nBody")

  let json_run =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp("application/problem+json", url, "{\"ok\":true}"))
    })
  let assert Ok(raw_json) = json_run("{\"url\":\"https://example.com/api\"}")
  let js = decode_page(raw_json)
  js.format |> should.equal("text")
  js.title |> should.equal(None)
  js.content |> should.equal("{\"ok\":true}")

  // Missing Content-Type sniffs HTML vs plain text and rejects NUL bytes.
  let sniff_html =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp(
        "",
        url,
        "\u{FEFF}  <!DOCTYPE html><html><body><p>Hi</p></body></html>",
      ))
    })
  let assert Ok(raw_sniff) = sniff_html("{\"url\":\"https://example.com/s\"}")
  let sn = decode_page(raw_sniff)
  sn.format |> should.equal("markdown")
  sn.content |> should.equal("Hi")

  let sniff_text =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp("", url, "plain text body"))
    })
  let assert Ok(raw_txt) = sniff_text("{\"url\":\"https://example.com/t\"}")
  let txt = decode_page(raw_txt)
  txt.format |> should.equal("text")
  txt.content |> should.equal("plain text body")

  let sniff_bin =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp("", url, "abc\u{0000}def"))
    })
  let assert Error(reason) = sniff_bin("{\"url\":\"https://example.com/b\"}")
  should.be_true(string.contains(reason, "unsupported binary content-type"))
}

pub fn rejects_unsolicited_content_encoding_and_binary_types_test() {
  let gz_run =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(
        FetchResponse(
          ..ok_resp("text/html", url, "compressed-bytes"),
          content_encoding: "gzip",
        ),
      )
    })
  let assert Error(reason) = gz_run("{\"url\":\"https://example.com/gz\"}")
  reason |> should.equal("unsupported content-encoding: gzip")

  // Explicit "identity" is accepted.
  let id_run =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(
        FetchResponse(
          ..ok_resp("text/plain", url, "ok"),
          content_encoding: "identity",
        ),
      )
    })
  let assert Ok(raw) = id_run("{\"url\":\"https://example.com/id\"}")
  decode_page(raw).content |> should.equal("ok")

  // Binary Content-Types are rejected cleanly.
  let pdf_run =
    web_fetch.run_with(opts(None), fn(url, _) {
      Ok(ok_resp("application/pdf", url, "%PDF-1.7"))
    })
  let assert Error(pdf_err) = pdf_run("{\"url\":\"https://example.com/f.pdf\"}")
  pdf_err |> should.equal("unsupported binary content-type: application/pdf")
}

pub fn pagination_cache_hit_fragment_key_clamping_and_past_end_test() {
  let cache_name = process.new_name("nexus_web_fetch_test_cache")
  let assert Ok(_started) = web_fetch_cache.start_named(cache_name, 60_000)
  let seam = web_fetch_cache.named_seam(cache_name)

  // Count how many times the upstream fetcher is actually called.
  let calls = process.new_subject()
  let run =
    web_fetch.run_with(
      web_fetch.Options(..opts(Some(seam)), default_chars: 10, max_chars: 15),
      fn(url, _) {
        process.send(calls, url)
        Ok(
          FetchResponse(
            ..ok_resp("text/plain", url, "0123456789abcdefghij—🚀"),
            truncated: True,
          ),
        )
      },
    )

  // First call: cache miss, uses default_chars=10, propagates raw_truncated.
  let assert Ok(r1) = run("{\"url\":\"https://example.com/doc#top\"}")
  let p1 = decode_page(r1)
  p1.cached |> should.equal(False)
  p1.raw_truncated |> should.equal(True)
  p1.total_chars |> should.equal(22)
  p1.start_index |> should.equal(0)
  p1.returned_chars |> should.equal(10)
  p1.has_more |> should.equal(True)
  p1.content |> should.equal("0123456789")

  // Second call with different fragment and huge max_length: cache HIT,
  // clamped to max_chars=15, reads remaining 12 graphemes safely (incl. emoji).
  let assert Ok(r2) =
    run(
      "{\"url\":\"https://example.com/doc#bottom\",\"start_index\":10,\"max_length\":999999}",
    )
  let p2 = decode_page(r2)
  p2.cached |> should.equal(True)
  p2.start_index |> should.equal(10)
  p2.returned_chars |> should.equal(12)
  p2.has_more |> should.equal(False)
  p2.content |> should.equal("abcdefghij—🚀")

  // Third call with start_index past end: clean empty tail, still cached.
  let assert Ok(r3) =
    run("{\"url\":\"https://example.com/doc\",\"start_index\":100}")
  let p3 = decode_page(r3)
  p3.cached |> should.equal(True)
  p3.start_index |> should.equal(100)
  p3.returned_chars |> should.equal(0)
  p3.has_more |> should.equal(False)
  p3.content |> should.equal("")

  // Upstream fetcher ran EXACTLY ONCE across all three calls.
  let assert Ok(_) = process.receive(calls, 100)
  process.receive(calls, 50) |> should.equal(Error(Nil))
}

pub fn non_2xx_not_cached_and_errors_surface_cleanly_test() {
  let cache_name = process.new_name("nexus_web_fetch_test_err_cache")
  let assert Ok(_started) = web_fetch_cache.start_named(cache_name, 60_000)
  let seam = web_fetch_cache.named_seam(cache_name)

  let not_found =
    web_fetch.run_with(opts(Some(seam)), fn(url, _) {
      Ok(FetchResponse(..ok_resp("text/plain", url, "nope"), status: 404))
    })
  let assert Error(err404) = not_found("{\"url\":\"https://example.com/404\"}")
  should.be_true(string.contains(err404, "\"status\":404"))
  // Never cached.
  seam.get("https://example.com/404") |> should.equal(None)

  // Transport / SSRF error carries "fetch failed: " prefix.
  let ssrf =
    web_fetch.run_with(opts(None), fn(_url, _) {
      Error("refusing private address for localhost: 127.0.0.1")
    })
  let assert Error(ssrf_err) = ssrf("{\"url\":\"http://localhost/\"}")
  should.be_true(string.contains(ssrf_err, "fetch failed: refusing private"))

  // Invalid arguments: negative start_index, missing url, bad json.
  let assert Error(neg) =
    ssrf("{\"url\":\"https://example.com/\",\"start_index\":-1}")
  should.be_true(string.contains(neg, "start_index"))
  let assert Error(_) = ssrf("{\"url\":\"   \"}")
  let assert Error(_) = ssrf("not json")
}
