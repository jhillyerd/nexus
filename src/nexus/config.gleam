//// Environment-driven configuration for the web server.
////
//// Misconfiguration must fail loudly *before* any network call, so `load`
//// validates and parses everything up front. The TTFT audit tool has its
//// own loader (`audit/config`) and must not depend on this surface.

import envoy
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/crypto

pub type Config {
  Config(
    /// Master key for provider API keys at rest: base64 of exactly 32
    /// random bytes (`openssl rand -base64 32`), validated at load so
    /// boot fails loudly on a missing/invalid key. Never logged or
    /// echoed; the provider registry is its only consumer.
    encryption_key: String,
    /// SSE first-response (status/headers) timeout in ms.
    sse_first_response_timeout_ms: Int,
    /// Our own receive timeout between SSE events mid-stream, in ms.
    stream_idle_timeout_ms: Int,
    /// M1 web server bind address (loopback by default, PRD hard req. 5).
    http_bind: String,
    /// M1 web server port.
    http_port: Int,
    /// Optional single-user bearer token; `None` disables auth (dev).
    ui_token: Option(String),
    /// System prompt, frozen at session creation (contract rule 2).
    system_prompt: String,
    /// M3 tool loop: maximum model round-trips per user turn (the guard).
    max_tool_iterations: Int,
    /// M3 http_fetch: maximum response body kept, in bytes.
    http_fetch_max_bytes: Int,
    /// M3 http_fetch: connect+receive timeout per hop, in ms.
    http_fetch_timeout_ms: Int,
    /// M3 http_fetch: dev/test escape hatch allowing private/loopback
    /// targets. Never enable in production (SSRF guard).
    http_fetch_allow_private: Bool,
    /// M3 web_search: SearxNG base URL (e.g. `https://searx.example`).
    searxng_base_url: Option(String),
    /// M3 web_search: optional bearer token; never logged or echoed.
    searxng_token: Option(String),
    /// Phase 2 persistence: Postgres host. Defaults match the repo's
    /// docker-compose.yml (postgres:17 on host port 5433). Persistence is
    /// mandatory — an unreachable database fails boot; there is no silent
    /// ephemeral mode.
    pg_host: String,
    /// Phase 2 persistence: Postgres port (compose maps 5433 -> 5432).
    pg_port: Int,
    /// Phase 2 persistence: database name.
    pg_database: String,
    /// Phase 2 persistence: user.
    pg_user: String,
    /// Phase 2 persistence: optional password; never logged or echoed.
    pg_password: Option(String),
    /// Utility calls (utility-titles plan §4.6): the once-per-session
    /// model-generated title upgrade, branched off the committed
    /// transcript's cached prefix. Off switches the feature entirely —
    /// the heuristic first-message title then stays forever.
    utility_enabled: Bool,
    /// Utility debounce: how long after a turn commit the side call waits
    /// (so a fast follow-up message cancels it before it starts).
    utility_delay_ms: Int,
  )
}

/// Load config from the process environment.
pub fn load() -> Result(Config, String) {
  from_env(envoy.get)
}

/// Pure variant of `load` over a lookup function, for offline tests.
pub fn from_env(
  get: fn(String) -> Result(String, Nil),
) -> Result(Config, String) {
  use encryption_key <- result.try(required_encryption_key(get))
  use first_response_ms <- result.try(optional_int(
    get,
    "NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS",
    30_000,
  ))
  use idle_ms <- result.try(optional_int(
    get,
    "NEXUS_STREAM_IDLE_TIMEOUT_MS",
    120_000,
  ))
  use http_port <- result.try(optional_int(get, "NEXUS_HTTP_PORT", 8080))
  use http_bind <- result.try(optional_string_or(
    get,
    "NEXUS_HTTP_BIND",
    "127.0.0.1",
  ))
  use system_prompt <- result.try(optional_string_or(
    get,
    "NEXUS_SYSTEM_PROMPT",
    "You are nexus, a concise personal assistant running on a self-hosted "
      <> "Gleam/BEAM harness. Answer directly and briefly.",
  ))
  use max_tool_iterations <- result.try(optional_int(
    get,
    "NEXUS_MAX_TOOL_ITERATIONS",
    8,
  ))
  use http_fetch_max_bytes <- result.try(optional_int(
    get,
    "NEXUS_HTTP_FETCH_MAX_BYTES",
    20_000,
  ))
  use http_fetch_timeout_ms <- result.try(optional_int(
    get,
    "NEXUS_HTTP_FETCH_TIMEOUT_MS",
    15_000,
  ))
  use http_fetch_allow_private <- result.try(optional_bool(
    get,
    "NEXUS_HTTP_FETCH_ALLOW_PRIVATE",
    False,
  ))
  // ---- Phase 2 persistence (NEXUS_PG_*): defaults match the repo's
  // docker-compose.yml. Persistence is mandatory: invalid values fail
  // loudly here, and an unreachable database fails boot (see
  // nexus/store/persist) — there is no silent ephemeral mode.
  use pg_port <- result.try(optional_int(get, "NEXUS_PG_PORT", 5433))
  use pg_host <- result.try(optional_string_or(
    get,
    "NEXUS_PG_HOST",
    "127.0.0.1",
  ))
  use pg_database <- result.try(optional_string_or(
    get,
    "NEXUS_PG_DATABASE",
    "nexus",
  ))
  use pg_user <- result.try(optional_string_or(get, "NEXUS_PG_USER", "nexus"))
  let pg_password = optional_string(get, "NEXUS_PG_PASSWORD")
  use utility_enabled <- result.try(optional_bool(
    get,
    "NEXUS_UTILITY_ENABLED",
    True,
  ))
  use utility_delay_ms <- result.try(optional_int(
    get,
    "NEXUS_UTILITY_DELAY_MS",
    1500,
  ))
  Ok(Config(
    encryption_key: encryption_key,
    sse_first_response_timeout_ms: first_response_ms,
    stream_idle_timeout_ms: idle_ms,
    http_bind: http_bind,
    http_port: http_port,
    ui_token: optional_string(get, "NEXUS_UI_TOKEN"),
    system_prompt: system_prompt,
    max_tool_iterations: max_tool_iterations,
    http_fetch_max_bytes: http_fetch_max_bytes,
    http_fetch_timeout_ms: http_fetch_timeout_ms,
    http_fetch_allow_private: http_fetch_allow_private,
    searxng_base_url: optional_string(get, "NEXUS_SEARXNG_BASE_URL"),
    searxng_token: optional_string(get, "NEXUS_SEARXNG_TOKEN"),
    pg_host: pg_host,
    pg_port: pg_port,
    pg_database: pg_database,
    pg_user: pg_user,
    pg_password: pg_password,
    utility_enabled: utility_enabled,
    utility_delay_ms: utility_delay_ms,
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

fn optional_string_or(
  get: fn(String) -> Result(String, Nil),
  name: String,
  default: String,
) -> Result(String, String) {
  case optional_string(get, name) {
    Some(value) -> Ok(value)
    None -> Ok(default)
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
      case int.parse(string.trim(raw)) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(
            "environment variable " <> name <> " is not an integer: " <> raw,
          )
      }
  }
}

fn optional_bool(
  get: fn(String) -> Result(String, Nil),
  name: String,
  default: Bool,
) -> Result(Bool, String) {
  case get(name) {
    Error(_) -> Ok(default)
    Ok(raw) ->
      case string.lowercase(string.trim(raw)) {
        "1" | "true" | "yes" -> Ok(True)
        "0" | "false" | "no" | "" -> Ok(False)
        _ ->
          Error("environment variable " <> name <> " is not a boolean: " <> raw)
      }
  }
}

fn required_encryption_key(
  get: fn(String) -> Result(String, Nil),
) -> Result(String, String) {
  use raw <- result.try(required(get, "NEXUS_ENCRYPTION_KEY"))
  // Validate the exact shape now (base64 of 32 bytes) — the provider
  // registry decodes it again, but a mistyped key must fail boot here,
  // before any actor starts.
  case crypto.decode_key(raw) {
    Ok(_) -> Ok(raw)
    Error(error) -> Error("NEXUS_ENCRYPTION_KEY: " <> crypto.describe(error))
  }
}
