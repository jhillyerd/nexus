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
  // Clear every variable we might read — including the hard-cut
  // BIFROST_*/NEXUS_MODEL_DEFAULT trio, so the "ignored" tests below
  // prove the loader no longer reads them even when present.
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
  envoy.unset("NEXUS_UTILITY_ENABLED")
  envoy.unset("NEXUS_UTILITY_DELAY_MS")
  envoy.unset("NEXUS_CODEMODE")
  envoy.unset("NEXUS_CODEMODE_TIMEOUT_MS")
  envoy.unset("NEXUS_CODEMODE_MAX_OUTPUT_CHARS")
  list.each(pairs, fn(pair) { envoy.set(pair.0, pair.1) })
}

pub fn load_requires_encryption_key_test() {
  set_all([])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_ENCRYPTION_KEY"))
}

pub fn empty_string_counts_as_missing_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", "")])
  should.be_error(config.load())
}

pub fn load_rejects_wrong_length_encryption_key_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", "c2hvcnQ=")])
  let assert Error(message) = config.load()
  // Fixed crypto error text — never the submitted value.
  should.be_true(string.contains(message, "32 bytes"))
}

pub fn load_rejects_non_base64_encryption_key_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", "not!base64!!")])
  should.be_error(config.load())
}

/// The P3 hard cut: the single-provider env trio is GONE. Booting with
/// them set (but no encryption key) must fail on the encryption key —
/// not read them — and a fully valid load ignores them entirely.
pub fn load_ignores_bifrost_env_test() {
  set_all([
    #("BIFROST_BASE_URL", "https://bifrost.example"),
    #("BIFROST_API_KEY", "sk-test"),
    #("NEXUS_MODEL_DEFAULT", "m"),
    #("NEXUS_ENCRYPTION_KEY", key_b64),
  ])
  // The /v1-less BIFROST_BASE_URL would have failed the old loader;
  // today it is not read at all.
  let assert Ok(cfg) = config.load()
  cfg.encryption_key |> should.equal(key_b64)
}

pub fn load_defaults_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.sse_first_response_timeout_ms |> should.equal(30_000)
  cfg.stream_idle_timeout_ms |> should.equal(120_000)
  cfg.http_bind |> should.equal("127.0.0.1")
  cfg.http_port |> should.equal(8080)
  cfg.ui_token |> should.equal(None)
  should.be_true(cfg.system_prompt |> string.starts_with("You are nexus"))
}

pub fn load_overrides_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS", "60000"),
    #("NEXUS_STREAM_IDLE_TIMEOUT_MS", "5000"),
    #("NEXUS_HTTP_BIND", "0.0.0.0"),
    #("NEXUS_HTTP_PORT", "9000"),
    #("NEXUS_UI_TOKEN", "sekrit"),
    #("NEXUS_SYSTEM_PROMPT", "custom prompt"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.sse_first_response_timeout_ms |> should.equal(60_000)
  cfg.stream_idle_timeout_ms |> should.equal(5000)
  cfg.http_bind |> should.equal("0.0.0.0")
  cfg.http_port |> should.equal(9000)
  cfg.ui_token |> should.equal(Some("sekrit"))
  cfg.system_prompt |> should.equal("custom prompt")
}

/// The ASCII-only codemode warning rides the DEFAULT prompt only while
/// codemode is on: manual testing showed models writing em dashes into
/// Lua string literals in every new thread, and the tool description
/// alone was not being read first.
pub fn system_prompt_gains_codemode_ascii_note_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE", "true"),
  ])
  let assert Ok(cfg) = config.load()
  should.be_true(cfg.system_prompt |> string.starts_with("You are nexus"))
  should.be_true(cfg.system_prompt |> string.contains("ASCII-only"))
  should.be_true(cfg.system_prompt |> string.contains("string.char"))
}

pub fn system_prompt_without_codemode_has_no_ascii_note_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  should.be_false(cfg.system_prompt |> string.contains("ASCII"))
}

/// An explicitly set NEXUS_SYSTEM_PROMPT is the operator's text: never
/// amended, even with codemode enabled.
pub fn explicit_system_prompt_is_never_amended_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE", "true"),
    #("NEXUS_SYSTEM_PROMPT", "custom prompt"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.system_prompt |> should.equal("custom prompt")
}

pub fn load_rejects_non_integer_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS", "soon"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS"))
}

/// A negative delay would only surface as a timer crash at the first
/// committed exchange — misconfiguration must fail the load instead.
pub fn load_rejects_negative_utility_delay_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_UTILITY_DELAY_MS", "-1"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_UTILITY_DELAY_MS must be >= 0: -1",
  )
}

// ---------------------------------------------------------------------------
// Codemode (phase 1)
// ---------------------------------------------------------------------------

/// Off by default: the frozen tool envelope is byte-identical to the
/// pre-codemode registry until the flag is explicitly set.
pub fn load_codemode_defaults_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.codemode |> should.equal(False)
  cfg.codemode_timeout_ms |> should.equal(30_000)
  cfg.codemode_max_output_chars |> should.equal(32_768)
}

pub fn load_codemode_overrides_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE", "true"),
    #("NEXUS_CODEMODE_TIMEOUT_MS", "5000"),
    #("NEXUS_CODEMODE_MAX_OUTPUT_CHARS", "1024"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.codemode |> should.equal(True)
  cfg.codemode_timeout_ms |> should.equal(5000)
  cfg.codemode_max_output_chars |> should.equal(1024)
}

/// A sub-second deadline could never run a script — fail the load.
pub fn load_rejects_low_codemode_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE_TIMEOUT_MS", "999"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_CODEMODE_TIMEOUT_MS must be >= 1000: 999",
  )
}

pub fn load_rejects_negative_codemode_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE_TIMEOUT_MS", "-1"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_CODEMODE_TIMEOUT_MS"))
}

pub fn load_rejects_non_integer_codemode_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE_TIMEOUT_MS", "soon"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_CODEMODE_TIMEOUT_MS"))
}

pub fn load_rejects_negative_codemode_output_cap_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE_MAX_OUTPUT_CHARS", "-1"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_CODEMODE_MAX_OUTPUT_CHARS must be >= 0: -1",
  )
}

pub fn load_rejects_non_boolean_codemode_flag_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_CODEMODE", "maybe"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_CODEMODE"))
}
