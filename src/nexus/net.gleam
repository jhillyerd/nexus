//// Outbound HTTP for M3 tool adapters, with the SSRF guard.
////
//// Policy lives here; byte-moving lives in `nexus_net_ffi.erl`:
////
//// - http/https schemes only;
//// - every fetch hop (including redirects, which are followed manually)
////   re-validates the target host against LAN/private/loopback ranges
////   unless `allow_private` is set (dev/tests only);
//// - response bodies are capped in the FFI, never materialised whole;
//// - requests are bounded in time by connect+receive timeouts.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type FetchResponse {
  FetchResponse(
    status: Int,
    content_type: String,
    location: String,
    body: String,
    truncated: Bool,
    final_url: String,
    content_encoding: String,
  )
}

@external(erlang, "nexus_boot_ffi", "ensure_hackney_started")
fn ensure_hackney_started() -> Result(Nil, String)

@external(erlang, "nexus_net_ffi", "bounded_get")
fn bounded_get(
  url: String,
  headers: List(#(String, String)),
  max_bytes: Int,
  timeout_ms: Int,
) -> Result(FetchResponse, String)

@external(erlang, "nexus_net_ffi", "resolve_host")
fn resolve_host(host: String) -> Result(List(String), String)

/// Decode a raw response body string lossily into valid UTF-8 so Latin-1
/// pages or multi-byte sequences truncated at `max_bytes` never crash
/// downstream HTML parsing or JSON encoding.
@external(erlang, "nexus_net_ffi", "to_text_lossy")
pub fn decode_utf8_lossy(text: String) -> String

/// Byte-level variant of `decode_utf8_lossy` for callers/tests holding raw
/// `BitArray` bytes.
@external(erlang, "nexus_net_ffi", "to_text_lossy")
pub fn bytes_to_text_lossy(bytes: BitArray) -> String

/// One fetch including manual redirects (up to `follow_limit`), each hop
/// re-validated. Errors are already sanitised strings safe to return to the
/// model.
pub fn fetch(
  url: String,
  headers: List(#(String, String)),
  max_bytes: Int,
  timeout_ms: Int,
  allow_private: Bool,
  follow_limit: Int,
) -> Result(FetchResponse, String) {
  use <- ensure_boot
  do_fetch(url, headers, max_bytes, timeout_ms, allow_private, follow_limit)
}

fn do_fetch(
  url,
  headers,
  max_bytes,
  timeout_ms,
  allow_private,
  remaining,
) -> Result(FetchResponse, String) {
  use validated <- result.try(validate_url(url, allow_private))
  case remaining < 0 {
    True -> Error("too many redirects")
    False ->
      case bounded_get(validated.url, headers, max_bytes, timeout_ms) {
        Ok(response) ->
          case is_redirect(response.status) {
            True ->
              case string.trim(response.location) {
                "" -> Error("redirect without a location header")
                location -> {
                  let next = resolve_location(validated, location)
                  do_fetch(
                    next,
                    headers,
                    max_bytes,
                    timeout_ms,
                    allow_private,
                    remaining - 1,
                  )
                }
              }
            False -> Ok(response)
          }
        Error(reason) -> Error(reason)
      }
  }
}

/// Resolve a possibly-relative Location against the hop we just fetched.
fn resolve_location(previous: ValidatedUrl, location: String) -> String {
  case resolve_url(previous.url, location) {
    Ok(resolved) -> resolved
    Error(Nil) -> location
  }
}

/// Resolve a relative or absolute URI reference against `base_url` per
/// RFC 3986 (used for HTTP redirect `Location` headers and HTML `<a href>`
/// links).
///
/// Guards two quirks in `gleam_stdlib`'s `uri.merge`:
/// - Absolute references (with a scheme) are returned verbatim so a target
///   never inherits the base's port or loses its userinfo (the SSRF guard
///   must still see userinfo on redirect hops).
/// - Protocol-relative references (`//host/...`) inherit only `base.scheme`,
///   not `base.port`, and preserve `relative.userinfo`.
/// - Trailing directory slashes (`dir/`, `.`, `..`) are preserved so later
///   relative links against the resolved URL stay in the right directory.
pub fn resolve_url(base_url: String, reference: String) -> Result(String, Nil) {
  use base <- result.try(uri.parse(base_url))
  use rel <- result.try(uri.parse(reference))
  case base.scheme, base.host {
    Some(_), Some(_) ->
      case rel.scheme, rel.host {
        // Already absolute: return verbatim.
        Some(_), _ -> Ok(reference)
        // Protocol-relative (`//host/...`): inherit only the base scheme.
        None, Some(_) -> Ok(uri.to_string(uri.Uri(..rel, scheme: base.scheme)))
        // Relative path / query / fragment: delegate to RFC 3986 merge.
        None, None -> {
          use merged <- result.try(uri.merge(base, rel))
          let path = case preserve_trailing_slash(rel.path, merged.path) {
            True -> merged.path <> "/"
            False -> merged.path
          }
          Ok(uri.to_string(uri.Uri(..merged, path: path)))
        }
      }
    _, _ -> Error(Nil)
  }
}

fn preserve_trailing_slash(rel_path: String, merged_path: String) -> Bool {
  rel_path != ""
  && !string.ends_with(merged_path, "/")
  && {
    string.ends_with(rel_path, "/")
    || string.ends_with(rel_path, "/.")
    || string.ends_with(rel_path, "/..")
    || rel_path == "."
    || rel_path == ".."
  }
}

fn is_redirect(status: Int) -> Bool {
  status == 301
  || status == 302
  || status == 303
  || status == 307
  || status == 308
}

fn ensure_boot(next: fn() -> Result(a, String)) -> Result(a, String) {
  case ensure_hackney_started() {
    Ok(_) -> next()
    Error(reason) -> Error("failed to start hackney: " <> reason)
  }
}

// ---------------------------------------------------------------------------
// URL validation / SSRF guard
// ---------------------------------------------------------------------------

pub type ValidatedUrl {
  ValidatedUrl(url: String, scheme: String, host: String)
}

/// Validate a model-supplied URL: parseable, http/https, no userinfo, and
/// the host must not resolve to a private/LAN address (unless allowed).
///
/// Known limitation: resolution and the subsequent fetch are two lookups, so
/// a DNS rebinding attacker could pass validation then rebind. The MVP runs
/// on a trusted network; pinning the fetch to the validated address is
/// deferred.
pub fn validate_url(
  url: String,
  allow_private: Bool,
) -> Result(ValidatedUrl, String) {
  use parsed <- result.try(
    uri.parse(url) |> result.replace_error("invalid URL"),
  )
  case parsed.scheme {
    Some("http") | Some("https") ->
      case parsed.userinfo {
        Some(_) -> Error("URL userinfo is not allowed")
        None ->
          case parsed.host {
            Some(host) ->
              case string.is_empty(host) {
                True -> Error("URL has no host")
                False -> check_host(url, parsed, host, allow_private)
              }
            None -> Error("URL has no host")
          }
      }
    Some(scheme) -> Error("scheme not allowed: " <> scheme)
    None -> Error("URL has no scheme")
  }
}

fn check_host(
  url: String,
  parsed: uri.Uri,
  host: String,
  allow_private: Bool,
) -> Result(ValidatedUrl, String) {
  let scheme = option.unwrap(parsed.scheme, "")
  let hostport = host_with_port(host, parsed.port)
  case allow_private {
    True -> Ok(ValidatedUrl(url, scheme, hostport))
    False -> validate_host(url, scheme, host, hostport)
  }
}

/// Host plus explicit port when the URL carries one (redirect resolution
/// must not silently drop a non-default port).
fn host_with_port(host: String, port: Option(Int)) -> String {
  case port {
    Some(port) -> host <> ":" <> int.to_string(port)
    None -> host
  }
}

fn validate_host(
  url: String,
  scheme: String,
  host: String,
  hostport: String,
) -> Result(ValidatedUrl, String) {
  use addresses <- result.try(
    resolve_host(host)
    |> result.replace_error("could not resolve host: " <> host),
  )
  case list.find(addresses, is_private_address) {
    Ok(private) ->
      Error("refusing private address for " <> host <> ": " <> private)
    Error(_) -> Ok(ValidatedUrl(url, scheme, hostport))
  }
}

/// True for loopback, LAN, link-local, CGNAT, and other non-public ranges.
pub fn is_private_address(address: String) -> Bool {
  case string.split(address, ":") {
    // No colon: treat as IPv4 dotted quad.
    [dotted] -> is_private_ipv4(dotted)
    _ ->
      // IPv6 literal.
      string.starts_with(address, "::1")
      || address == "::"
      || string.starts_with(address, "fe8")
      || string.starts_with(address, "fe9")
      || string.starts_with(address, "fea")
      || string.starts_with(address, "feb")
      || string.starts_with(address, "fc")
      || string.starts_with(address, "fd")
      || case
        address
        |> string.split(":")
        |> list.last
      {
        // IPv4-mapped tail (::ffff:10.0.0.1): dotted quads only.
        Ok(dotted) -> string.contains(dotted, ".") && is_private_ipv4(dotted)
        Error(_) -> False
      }
  }
}

fn is_private_ipv4(dotted: String) -> Bool {
  case string.split(dotted, ".") |> list.map(int.parse) {
    [Ok(a), Ok(b), _, _] ->
      a == 0
      || a == 10
      || a == 127
      || { a == 169 && b == 254 }
      || { a == 172 && b >= 16 && b <= 31 }
      || { a == 192 && b == 168 }
      || { a == 100 && b >= 64 && b <= 127 }
    // Not a plain dotted quad: be conservative and refuse.
    _ -> True
  }
}
