//// The `http_fetch` tool adapter (M3; Phase 5 curl upgrades in
//// docs/plans/web-fetch.md): the low-level opt-in raw HTTP tool for bots
//// without `bash`. Fetches one public http/https URL per call with an
//// optional method, request headers, and request body — under the
//// SSRF/size/time policy in `nexus/net` — and reports status, final URL,
//// response headers, and the (byte-capped) body.

import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glopenai/chat
import glopenai/shared.{FunctionObject}
import nexus/net

const description =
  "Fetch a public http(s) URL and return status, response headers, and the "
  <> "response body (truncated). Supports an HTTP method, request headers, "
  <> "and a request body for APIs — a low-level curl-like escape hatch; "
  <> "prefer web_fetch for reading pages."

const parameters =
  "{\"type\":\"object\",\"properties\":{"
  <> "\"url\":{\"type\":\"string\",\"description\":\"Absolute http:// or https:// URL to fetch\"},"
  <> "\"method\":{\"type\":\"string\",\"enum\":[\"GET\",\"POST\",\"PUT\",\"PATCH\",\"DELETE\",\"HEAD\",\"OPTIONS\"],\"description\":\"HTTP method (default GET)\"},"
  <> "\"headers\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"},\"description\":\"Request headers as an object of name to value, e.g. {\\\"authorization\\\":\\\"Bearer ...\\\",\\\"content-type\\\":\\\"application/json\\\"}. Hop-by-hop and framing headers (host, content-length, transfer-encoding, connection) are refused.\"},"
  <> "\"body\":{\"type\":\"string\",\"description\":\"Request body sent verbatim (e.g. a JSON payload)\"}"
  <> "},\"required\":[\"url\"],\"additionalProperties\":false}"

/// Redirect chain budget shared with `web_fetch` — one policy decision
/// in `nexus/net`.
const max_redirects = net.default_follow_limit

pub fn schema() -> chat.ChatCompletionTool {
  let parameters = case json.parse(parameters, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: "http_fetch",
    description: Some(description),
    parameters: parameters,
    strict: None,
  ))
}

pub fn run(
  max_bytes: Int,
  timeout_ms: Int,
  allow_private: Bool,
) -> fn(String) -> Result(String, String) {
  fn(arguments: String) {
    use args <- result.try(parse_args(arguments))
    use response <- result.try(
      net.request(
        args.method,
        args.url,
        args.headers,
        args.body,
        max_bytes,
        timeout_ms,
        allow_private,
        max_redirects,
      )
      |> result.map_error(fn(reason) {
        // net.request errors never carry credentials the caller did not
        // itself send (authorization headers are echoed nowhere).
        "fetch failed: " <> reason
      }),
    )
    // Non-2xx statuses are data, not transport errors: the model can react
    // (and still sees the error body and headers, curl-style).
    case response.status >= 200 && response.status < 300 {
      True -> Ok(encode_response(response))
      False -> Error(encode_response(response))
    }
  }
}

// ---------------------------------------------------------------------------
// Argument parsing & validation
// ---------------------------------------------------------------------------

type Args {
  Args(
    url: String,
    method: http.Method,
    headers: List(#(String, String)),
    body: String,
  )
}

/// The standard verbs http_fetch may use. Whitelisting (rather than
/// accepting any RFC 9110 token) keeps `CONNECT`, `TRACE`, and arbitrary
/// verbs off the wire; the FFI re-checks the same list.
const allowed_methods = [
  "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
]

/// Framing and hop-by-hop request headers the model may not set: hackney
/// owns `content-length` (computed from the body — a second value invites
/// request smuggling), and the rest are per-hop connection state a single
/// client request has no business overriding.
const blocked_header_names = [
  "host", "content-length", "transfer-encoding", "connection", "keep-alive",
  "proxy-connection", "te", "trailer", "upgrade", "expect",
]

const argument_fields = ["url", "method", "headers", "body"]

fn parse_args(arguments: String) -> Result(Args, String) {
  use Nil <- result.try(check_known_fields(arguments))
  let decoder = {
    use url <- decode.field("url", decode.string)
    use method <- decode.optional_field(
      "method",
      None,
      decode.optional(decode.string),
    )
    use headers <- decode.optional_field(
      "headers",
      None,
      decode.optional(decode.dict(decode.string, decode.string)),
    )
    use body <- decode.optional_field(
      "body",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(url, method, headers, body))
  }
  use #(raw_url, raw_method, raw_headers, raw_body) <- result.try(
    json.parse(arguments, decoder)
    |> result.replace_error(
      "arguments must be JSON with a string \"url\" field (optional \"method\", \"headers\", \"body\")",
    ),
  )
  let url = string.trim(raw_url)
  use Nil <- result.try(case url == "" {
    True -> Error("url must be non-empty")
    False -> Ok(Nil)
  })
  use method <- result.try(parse_method(option.unwrap(raw_method, "GET")))
  use headers <- result.try(
    parse_headers(dict.to_list(option.unwrap(raw_headers, dict.new()))),
  )
  Ok(Args(
    url: url,
    method: method,
    headers: headers,
    body: option.unwrap(raw_body, ""),
  ))
}

/// The schema declares `additionalProperties: false`, but a decoder that
/// merely reads the known fields would silently DROP a misspelled one —
/// a `data` meant as `body` sends the request out without its payload
/// and the model never learns why. Surface the mistake as a tool error.
fn check_known_fields(arguments: String) -> Result(Nil, String) {
  case json.parse(arguments, decode.dict(decode.string, decode.dynamic)) {
    Ok(object) ->
      case
        list.find(dict.keys(object), fn(key) {
          !list.contains(argument_fields, key)
        })
      {
        Ok(unknown) ->
          Error(
            "unknown argument field: \""
            <> unknown
            <> "\" (expected one of "
            <> string.join(argument_fields, ", ")
            <> ")",
          )
        Error(Nil) -> Ok(Nil)
      }
    Error(_) ->
      Error(
        "arguments must be JSON with a string \"url\" field (optional \"method\", \"headers\", \"body\")",
      )
  }
}

fn parse_method(raw: String) -> Result(http.Method, String) {
  let method = string.uppercase(string.trim(raw))
  case list.contains(allowed_methods, method) {
    False ->
      Error("method must be one of " <> string.join(allowed_methods, ", "))
    True ->
      case http.parse_method(method) {
        Ok(parsed) -> Ok(parsed)
        // Unreachable: every allowed name round-trips through parse_method.
        Error(Nil) ->
          Error("method must be one of " <> string.join(allowed_methods, ", "))
      }
  }
}

/// Validate model-supplied header names and values BEFORE they reach the
/// wire: names must be RFC 9110 tokens outside the blocked set (no `:`,
/// spaces, or control bytes — structurally preventing header smuggling),
/// and values must contain no CR/LF/NUL or other control bytes (bar TAB),
/// so nothing can split or re-frame the request.
fn parse_headers(
  raw: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  use Nil <- result.try(
    list.try_each(raw, fn(pair) {
      let #(name, value) = pair
      case string.trim(name) != name {
        True ->
          Error(
            "header name must not have surrounding whitespace: \""
            <> name
            <> "\"",
          )
        False ->
          case is_token_name(name) {
            False -> Error("invalid header name: \"" <> name <> "\"")
            True ->
              case list.contains(blocked_header_names, string.lowercase(name)) {
                True ->
                  Error(
                    "header is managed by the client and cannot be set: "
                    <> name,
                  )
                False ->
                  case is_valid_header_value(value) {
                    True -> Ok(Nil)
                    False ->
                      Error(
                        "header value for \""
                        <> name
                        <> "\" must not contain control characters",
                      )
                  }
              }
          }
      }
    }),
  )
  // JSON object keys are case-sensitive, so "Authorization" and
  // "authorization" would BOTH survive and both reach the wire; header
  // names are case-insensitive per RFC 9110, so refuse duplicates.
  let lowercased = list.map(raw, fn(pair) { string.lowercase(pair.0) })
  case list.length(list.unique(lowercased)) == list.length(raw) {
    True -> Ok(raw)
    False -> Error("header names must be unique (case-insensitive)")
  }
}

/// RFC 9110 token: 1*`tchar` — visible ASCII minus delimiters, checked
/// per CODEPOINT. A grapheme-level range check has an NFD hole (a
/// decomposed "e" + U+0301 clusters into one grapheme whose leading
/// codepoint is a tchar, so the combining mark rides the compare) and
/// would put non-token bytes in a header NAME on the wire.
fn is_token_name(name: String) -> Bool {
  let codepoints =
    name
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
  codepoints != [] && list.all(codepoints, is_tchar)
}

fn is_tchar(cp: Int) -> Bool {
  { cp >= 0x30 && cp <= 0x39 }
  || { cp >= 0x41 && cp <= 0x5a }
  || { cp >= 0x61 && cp <= 0x7a }
  || list.contains(
    [
      0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x5e, 0x5f,
      0x60, 0x7c, 0x7e,
    ],
    cp,
  )
}

/// Header values may carry visible characters, spaces, TAB, and non-ASCII
/// text (obs-text — UTF-8 values ride the wire verbatim); CR/LF, NUL, DEL,
/// and other C0 controls are refused (request-splitting guard), checked
/// per codepoint — true by construction, not by grapheme-cluster folklore.
fn is_valid_header_value(value: String) -> Bool {
  let codepoints =
    value
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
  list.all(codepoints, fn(cp) { cp == 0x09 || { cp >= 0x20 && cp != 0x7f } })
}

// ---------------------------------------------------------------------------
// Result encoding
// ---------------------------------------------------------------------------

/// One JSON object for both paths: Ok (2xx) and Error (non-2xx — the
/// `error` key marks it, and body/headers are still there, curl-style).
fn encode_response(response: net.FetchResponse) -> String {
  let is_2xx = response.status >= 200 && response.status < 300
  let error_fields = case is_2xx {
    True -> []
    False -> [#("error", json.string("non-success status"))]
  }
  json.object([
    #("status", json.int(response.status)),
    ..list.append(error_fields, [
      #("url", json.string(response.final_url)),
      #("content_type", json.string(response.content_type)),
      #("headers", encode_headers(response.headers)),
      #("headers_truncated", json.bool(response.headers_truncated)),
      #("truncated", json.bool(response.truncated)),
      // The body is already byte-capped by the FFI and lossily decoded to
      // valid UTF-8 here so non-UTF-8 bytes never corrupt the JSON
      // envelope; it is returned as inert JSON string content, never
      // executed or rendered raw.
      #("body", json.string(net.decode_utf8_lossy(response.body))),
    ])
  ])
  |> json.to_string
}

fn encode_headers(headers: List(#(String, String))) -> json.Json {
  // `set-cookie` is legally non-combinable (RFC 9110 §5.2 — cookie
  // values embed commas) and arrives from the FFI as separate verbatim
  // pairs; render it as ONE array-valued key so multiple cookies stay
  // distinguishable and a duplicate key never reaches the JSON. Every
  // other name arrives already combined.
  let #(cookies, others) =
    list.partition(headers, fn(pair) {
      string.lowercase(pair.0) == "set-cookie"
    })
  let base =
    list.map(others, fn(pair) {
      #(pair.0, json.string(net.decode_utf8_lossy(pair.1)))
    })
  case cookies {
    [] -> json.object(base)
    _ ->
      json.object([
        #(
          "set-cookie",
          json.array(cookies, fn(pair) {
            json.string(net.decode_utf8_lossy(pair.1))
          }),
        ),
        ..base
      ])
  }
}
