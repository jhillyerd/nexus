//// The `web_fetch` tool: fetches public http(s) URLs with a bounded raw-byte
//// budget, converts HTML to compact Markdown (passing Markdown/plain/JSON
//// through), caches converted 2xx documents in memory for instant,
//// offset-stable pagination, and returns bounded character slices.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glopenai/chat
import glopenai/shared.{FunctionObject}
import nexus/html_markdown
import nexus/net
import nexus/web_fetch_cache.{type CachedDoc, CachedDoc}

const description =
  "Fetch a public http(s) URL, convert HTML to compact Markdown (passing "
  <> "Markdown, plain text, and JSON through), and paginate long pages via "
  <> "start_index and max_length."

const parameters =
  "{\"type\":\"object\",\"properties\":{"
  <> "\"url\":{\"type\":\"string\",\"description\":\"Absolute http:// or https:// URL to fetch\"},"
  <> "\"start_index\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Character offset to start reading from (default 0). Use with has_more to read further chunks.\"},"
  <> "\"max_length\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Maximum number of characters to return (default 12000; clamped to server max).\"}"
  <> "},\"required\":[\"url\"],\"additionalProperties\":false}"

/// Request headers sent on every `web_fetch` hop: prefer native Markdown when
/// the origin supports it, send an honest User-Agent, and request identity
/// encoding so `max_raw_bytes` bounds uncompressed bytes directly.
pub const request_headers = [
  #("Accept", "text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.5"),
  #("User-Agent", "nexus-web-fetch/1.0"),
  #("Accept-Encoding", "identity"),
]

/// Maximum manual redirect hops per fetch (each hop re-validated via SSRF
/// guard in `nexus/net`).
const max_redirects = 3

/// Runtime configuration + optional cache seam for `web_fetch`.
pub type Options {
  Options(
    max_raw_bytes: Int,
    timeout_ms: Int,
    allow_private: Bool,
    default_chars: Int,
    max_chars: Int,
    cache: Option(web_fetch_cache.Seam),
  )
}

/// Transport seam (injectable for offline tests).
pub type Fetcher =
  fn(String, List(#(String, String))) -> Result(net.FetchResponse, String)

pub fn schema() -> chat.ChatCompletionTool {
  let parsed = case json.parse(parameters, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: "web_fetch",
    description: Some(description),
    parameters: parsed,
    strict: None,
  ))
}

/// Production executor wired to `nexus/net.fetch`.
pub fn run(opts: Options) -> fn(String) -> Result(String, String) {
  run_with(opts, fn(url, headers) {
    net.fetch(
      url,
      headers,
      opts.max_raw_bytes,
      opts.timeout_ms,
      opts.allow_private,
      max_redirects,
    )
  })
}

/// Pure/offline-testable executor over an injected `Fetcher`.
pub fn run_with(
  opts: Options,
  fetcher: Fetcher,
) -> fn(String) -> Result(String, String) {
  fn(arguments: String) {
    use args <- result.try(parse_args(arguments, opts))
    let cache_key = web_fetch_cache.cache_key(args.url)
    case lookup_cache(opts.cache, cache_key) {
      Some(doc) ->
        Ok(encode_page(doc, args.start_index, args.max_length, cached: True))
      None -> {
        use response <- result.try(
          fetcher(args.url, request_headers)
          |> result.map_error(fn(reason) { "fetch failed: " <> reason }),
        )
        use doc <- result.try(process_response(args.url, response))
        store_cache(opts.cache, cache_key, doc)
        Ok(encode_page(doc, args.start_index, args.max_length, cached: False))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

type Args {
  Args(url: String, start_index: Int, max_length: Int)
}

fn parse_args(arguments: String, opts: Options) -> Result(Args, String) {
  let decoder = {
    use url <- decode.field("url", decode.string)
    use start_index <- decode.optional_field(
      "start_index",
      None,
      decode.optional(decode.int),
    )
    use max_length <- decode.optional_field(
      "max_length",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(url, start_index, max_length))
  }
  use #(raw_url, raw_start, raw_max) <- result.try(
    json.parse(arguments, decoder)
    |> result.replace_error(
      "arguments must be JSON with a string \"url\" field (optional integer \"start_index\" and \"max_length\")",
    ),
  )
  let url = string.trim(raw_url)
  use Nil <- result.try(case url == "" {
    True -> Error("url must be non-empty")
    False -> Ok(Nil)
  })
  let start_index = option.unwrap(raw_start, 0)
  use Nil <- result.try(case start_index < 0 {
    True -> Error("start_index must be >= 0")
    False -> Ok(Nil)
  })
  let requested_max = option.unwrap(raw_max, opts.default_chars)
  let upper = int.max(1, opts.max_chars)
  let max_length = int.clamp(requested_max, min: 1, max: upper)
  Ok(Args(url: url, start_index: start_index, max_length: max_length))
}

// ---------------------------------------------------------------------------
// Response handling, Content-Encoding guard, Content-Type dispatch
// ---------------------------------------------------------------------------

fn process_response(
  requested_url: String,
  response: net.FetchResponse,
) -> Result(CachedDoc, String) {
  case response.status >= 200 && response.status < 300 {
    False ->
      Error(
        json.object([
          #("status", json.int(response.status)),
          #("error", json.string("non-success status")),
        ])
        |> json.to_string,
      )
    True -> {
      use Nil <- result.try(check_encoding(response.content_encoding))
      let final_url = case string.trim(response.final_url) {
        "" -> requested_url
        url -> url
      }
      use #(format, title, content) <- result.try(dispatch_body(
        response.content_type,
        response.body,
        final_url,
      ))
      Ok(CachedDoc(
        status: response.status,
        final_url: final_url,
        title: title,
        content_type: response.content_type,
        format: format,
        content: content,
        total_chars: string.length(content),
        raw_truncated: response.truncated,
      ))
    }
  }
}

fn check_encoding(raw_encoding: String) -> Result(Nil, String) {
  let tokens =
    raw_encoding
    |> string.split(",")
    |> list.map(fn(part) { string.lowercase(string.trim(part)) })
    |> list.filter(fn(part) { part != "" })
  case list.find(tokens, fn(token) { token != "identity" }) {
    Error(Nil) -> Ok(Nil)
    Ok(unsupported) -> Error("unsupported content-encoding: " <> unsupported)
  }
}

fn dispatch_body(
  content_type: String,
  raw_body: String,
  final_url: String,
) -> Result(#(String, Option(String), String), String) {
  let media_type = parse_media_type(content_type)
  case media_type {
    "text/html" | "application/xhtml+xml" -> {
      let body = net.decode_utf8_lossy(raw_body)
      let converted = html_markdown.convert(body, final_url)
      Ok(#("markdown", converted.title, converted.markdown))
    }
    "text/markdown" | "text/x-markdown" -> {
      let body = net.decode_utf8_lossy(raw_body)
      Ok(#("markdown", None, body))
    }
    "" ->
      case string.contains(raw_body, "\u{0000}") {
        True ->
          Error("unsupported binary content-type: application/octet-stream")
        False -> {
          let body = net.decode_utf8_lossy(raw_body)
          case looks_like_html(body) {
            True -> {
              let converted = html_markdown.convert(body, final_url)
              Ok(#("markdown", converted.title, converted.markdown))
            }
            False -> Ok(#("text", None, body))
          }
        }
      }
    other ->
      case is_passthrough_text_type(other) {
        True -> {
          let body = net.decode_utf8_lossy(raw_body)
          Ok(#("text", None, body))
        }
        False -> Error("unsupported binary content-type: " <> other)
      }
  }
}

fn parse_media_type(content_type: String) -> String {
  let main = case string.split_once(content_type, ";") {
    Ok(#(before, _)) -> before
    Error(Nil) -> content_type
  }
  string.lowercase(string.trim(main))
}

fn is_passthrough_text_type(media_type: String) -> Bool {
  case media_type {
    "text/plain"
    | "application/json"
    | "application/xml"
    | "text/xml"
    | "text/csv"
    | "application/javascript"
    | "text/javascript"
    | "text/css"
    | "application/yaml"
    | "text/yaml"
    | "application/toml"
    | "application/graphql"
    | "application/x-ndjson" -> True
    _ ->
      case
        string.starts_with(media_type, "image/")
        || string.starts_with(media_type, "audio/")
        || string.starts_with(media_type, "video/")
        || string.starts_with(media_type, "font/")
      {
        True -> False
        False ->
          string.starts_with(media_type, "text/")
          || string.ends_with(media_type, "+json")
          || string.ends_with(media_type, "+xml")
      }
  }
}

fn looks_like_html(body: String) -> Bool {
  let lead =
    body
    |> strip_bom
    |> string.trim_start
    |> string.slice(at_index: 0, length: 32)
    |> string.lowercase
  string.starts_with(lead, "<!doctype html")
  || string.starts_with(lead, "<html")
}

fn strip_bom(text: String) -> String {
  case string.starts_with(text, "\u{FEFF}") {
    True -> string.drop_start(text, 1)
    False -> text
  }
}

// ---------------------------------------------------------------------------
// Pagination & JSON output encoding
// ---------------------------------------------------------------------------

fn encode_page(
  doc: CachedDoc,
  start_index: Int,
  max_length: Int,
  cached cached: Bool,
) -> String {
  let slice = case start_index >= doc.total_chars {
    True -> ""
    False ->
      string.slice(doc.content, at_index: start_index, length: max_length)
  }
  let returned_chars = string.length(slice)
  let has_more = start_index + returned_chars < doc.total_chars
  let base_fields = [
    #("status", json.int(doc.status)),
    #("url", json.string(doc.final_url)),
  ]
  let with_title = case doc.title {
    Some(title) -> list.append(base_fields, [#("title", json.string(title))])
    None -> base_fields
  }
  let fields =
    list.append(with_title, [
      #("content_type", json.string(doc.content_type)),
      #("format", json.string(doc.format)),
      #("total_chars", json.int(doc.total_chars)),
      #("start_index", json.int(start_index)),
      #("returned_chars", json.int(returned_chars)),
      #("has_more", json.bool(has_more)),
      #("raw_truncated", json.bool(doc.raw_truncated)),
      #("cached", json.bool(cached)),
      #("content", json.string(slice)),
    ])
  json.object(fields) |> json.to_string
}

fn lookup_cache(
  cache: Option(web_fetch_cache.Seam),
  key: String,
) -> Option(CachedDoc) {
  case cache {
    None -> None
    Some(seam) -> seam.get(key)
  }
}

fn store_cache(
  cache: Option(web_fetch_cache.Seam),
  key: String,
  doc: CachedDoc,
) -> Nil {
  case cache {
    None -> Nil
    Some(seam) -> seam.put(key, doc)
  }
}
