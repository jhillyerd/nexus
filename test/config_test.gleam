import envoy
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/config

/// Valid base64 of exactly 32 bytes — the shared test fixture value
/// (same convention as the other suites' `encryption_key` field).
const key_b64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

fn set_all(pairs: List(#(String, String))) -> Nil {
  // Clear every variable we might read, then set the given ones.
  envoy.unset("BIFROST_BASE_URL")
  envoy.unset("BIFROST_API_KEY")
  envoy.unset("NEXUS_MODEL_DEFAULT")
  envoy.unset("NEXUS_ENCRYPTION_KEY")
  envoy.unset("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS")
  envoy.unset("NEXUS_STREAM_IDLE_TIMEOUT_MS")
  envoy.unset("NEXUS_HTTP_BIND")
  envoy.unset("NEXUS_HTTP_PORT")
  envoy.unset("NEXUS_UI_TOKEN")
  envoy.unset("NEXUS_SYSTEM_PROMPT")
  list.each(pairs, fn(pair) { envoy.set(pair.0, pair.1) })
}

pub fn load_requires_base_url_test() {
  set_all([
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "llamacpp"),
  ])
  config.load() |> should.be_error
}

pub fn load_requires_api_key_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("NEXUS_MODEL_DEFAULT", "llamacpp"),
  ])
  config.load() |> should.be_error
}

pub fn load_requires_model_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
  ])
  config.load() |> should.be_error
}

pub fn load_rejects_base_url_without_v1_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "llamacpp"),
  ])
  should.be_error(config.load())
}

pub fn load_defaults_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "vllm-alias"),
    #("NEXUS_ENCRYPTION_KEY", key_b64),
  ])
  let assert Ok(cfg) = config.load()
  cfg.base_url |> should.equal("https://bifrost.example/v1")
  cfg.model_default |> should.equal("vllm-alias")
  cfg.sse_first_response_timeout_ms |> should.equal(30_000)
  cfg.stream_idle_timeout_ms |> should.equal(120_000)
  cfg.http_bind |> should.equal("127.0.0.1")
  cfg.http_port |> should.equal(8080)
  cfg.ui_token |> should.equal(None)
  should.be_true(cfg.system_prompt |> string.starts_with("You are nexus"))
}

pub fn load_overrides_and_trims_test() {
  set_all([
    #("BIFROST_BASE_URL", "  https://bifrost.example/v1/ "),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS", "60000"),
    #("NEXUS_STREAM_IDLE_TIMEOUT_MS", "5000"),
    #("NEXUS_HTTP_BIND", "0.0.0.0"),
    #("NEXUS_HTTP_PORT", "9000"),
    #("NEXUS_UI_TOKEN", "sekrit"),
    #("NEXUS_SYSTEM_PROMPT", "custom prompt"),
  ])
  let assert Ok(cfg) = config.load()
  // Trailing slash on a /v1 base is trimmed.
  cfg.base_url |> should.equal("https://bifrost.example/v1")
  cfg.sse_first_response_timeout_ms |> should.equal(60_000)
  cfg.stream_idle_timeout_ms |> should.equal(5000)
  cfg.http_bind |> should.equal("0.0.0.0")
  cfg.http_port |> should.equal(9000)
  cfg.ui_token |> should.equal(Some("sekrit"))
  cfg.system_prompt |> should.equal("custom prompt")
}

pub fn load_rejects_non_integer_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS", "soon"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS"))
}

pub fn empty_string_counts_as_missing_test() {
  set_all([
    #("BIFROST_BASE_URL", ""),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", key_b64),
  ])
  should.be_error(config.load())
}

pub fn load_requires_encryption_key_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_ENCRYPTION_KEY"))
}

pub fn load_rejects_wrong_length_encryption_key_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", "c2hvcnQ="),
  ])
  let assert Error(message) = config.load()
  // Fixed crypto error text — never the submitted value.
  should.be_true(string.contains(message, "32 bytes"))
}

pub fn load_rejects_non_base64_encryption_key_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example/v1"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", "not!base64!!"),
  ])
  should.be_error(config.load())
}
