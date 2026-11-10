//// Environment-driven configuration for the TTFT audit tool
//// (`audit/ttft`).
////
//// Deliberately independent of the server's `nexus/config`: the audit
//// tool is a standalone operator harness and must not track the server
//// config surface (which is moving to the database alongside the
//// provider store). Misconfiguration fails loudly here, before any
//// network call.

import envoy
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type AuditConfig {
  AuditConfig(
    /// OpenAI-compatible base URL including the `/v1` suffix.
    base_url: String,
    /// Optional bearer key; unset targets keyless local endpoints.
    api_key: Option(String),
    /// Model alias under audit.
    model: String,
    /// Turns per measured thread (turn 1 is the cold sample).
    turns: Int,
    /// Thread repeats; each repeat is a fresh cold start.
    repeats: Int,
    /// SSE first-response (status/headers) timeout in ms.
    sse_first_response_timeout_ms: Int,
    /// Receive timeout between SSE events mid-stream, in ms.
    stream_idle_timeout_ms: Int,
  )
}

/// Load audit config from the process environment.
pub fn load() -> Result(AuditConfig, String) {
  from_env(envoy.get)
}

/// Pure variant of `load` over a lookup function, for offline tests.
pub fn from_env(
  get: fn(String) -> Result(String, Nil),
) -> Result(AuditConfig, String) {
  use base_url <- result.try(required(get, "NEXUS_AUDIT_BASE_URL"))
  use base_url <- result.try(normalize_base_url(base_url))
  use model <- result.try(required(get, "NEXUS_AUDIT_MODEL"))
  use turns <- result.try(optional_int(get, "NEXUS_AUDIT_TURNS", 20))
  use repeats <- result.try(optional_int(get, "NEXUS_AUDIT_REPEATS", 5))
  use first_response_ms <- result.try(optional_int(
    get,
    "NEXUS_AUDIT_SSE_FIRST_RESPONSE_TIMEOUT_MS",
    30_000,
  ))
  use idle_ms <- result.try(optional_int(
    get,
    "NEXUS_AUDIT_STREAM_IDLE_TIMEOUT_MS",
    120_000,
  ))
  Ok(AuditConfig(
    base_url: base_url,
    api_key: optional_string(get, "NEXUS_AUDIT_API_KEY"),
    model: model,
    turns: turns,
    repeats: repeats,
    sse_first_response_timeout_ms: first_response_ms,
    stream_idle_timeout_ms: idle_ms,
  ))
}

fn required(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(String, String) {
  case get(name) {
    Ok(raw) ->
      case string.trim(raw) {
        "" -> Error(missing(name))
        value -> Ok(value)
      }
    Error(_) -> Error(missing(name))
  }
}

fn missing(name: String) -> String {
  "missing required environment variable: " <> name
}

fn optional_string(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Option(String) {
  case get(name) {
    Ok(raw) ->
      case string.trim(raw) {
        "" -> None
        value -> Some(value)
      }
    Error(_) -> None
  }
}

fn optional_int(
  get: fn(String) -> Result(String, Nil),
  name: String,
  default: Int,
) -> Result(Int, String) {
  case get(name) {
    Error(_) -> Ok(default)
    Ok(raw) ->
      case string.trim(raw) |> int.parse {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(
            "environment variable " <> name <> " is not an integer: " <> raw,
          )
      }
  }
}

fn normalize_base_url(url: String) -> Result(String, String) {
  let trimmed = case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
  case string.ends_with(trimmed, "/v1") {
    True -> Ok(trimmed)
    False ->
      Error(
        "NEXUS_AUDIT_BASE_URL should be the OpenAI-compatible base ending in /v1, got: "
        <> url,
      )
  }
}
