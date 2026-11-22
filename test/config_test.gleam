import envoy
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/config
import nexus/log

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
  envoy.unset("NEXUS_PLUGINS")
  envoy.unset("NEXUS_PLUGIN_TIMEOUT_MS")
  envoy.unset("NEXUS_PLUGIN_MAX_OUTPUT_CHARS")
  envoy.unset("NEXUS_MCP_SERVERS_JSON")
  envoy.unset("NEXUS_WORKSPACE_ROOT")
  envoy.unset("NEXUS_WORKSPACE_SANDBOX")
  envoy.unset("NEXUS_WORKSPACE_SANDBOX_BIN")
  envoy.unset("NEXUS_WORKSPACE_TOOLCHAIN")
  envoy.unset("NEXUS_WORKSPACE_STATE_DIR")
  envoy.unset("NEXUS_WORKSPACE_MAX_MEMORY_MB")
  envoy.unset("NEXUS_WORKSPACE_MAX_PIDS")
  envoy.unset("NEXUS_ENV_TIMEOUT_MS")
  envoy.unset("NEXUS_ENV_MAX_OUTPUT_BYTES")
  // TUI pairing hygiene (tui-pairing plan): the default-7 assertion is
  // only meaningful when the caller's shell has not exported an
  // override (env leakage is real — see the seed-key foot-gun).
  envoy.unset("NEXUS_NODE_IDLE_DAYS")
  envoy.unset("NEXUS_LOG_LEVEL")
  envoy.unset("NEXUS_HTTP_FETCH_MAX_BYTES")
  envoy.unset("NEXUS_HTTP_FETCH_TIMEOUT_MS")
  envoy.unset("NEXUS_HTTP_FETCH_ALLOW_PRIVATE")
  envoy.unset("NEXUS_WEB_FETCH_MAX_RAW_BYTES")
  envoy.unset("NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES")
  envoy.unset("NEXUS_WEB_FETCH_DEFAULT_CHARS")
  envoy.unset("NEXUS_WEB_FETCH_MAX_CHARS")
  envoy.unset("NEXUS_WEB_FETCH_CACHE_TTL_MS")
  list.each(pairs, fn(pair) { envoy.set(pair.0, pair.1) })
}

pub fn workspace_root_must_be_absolute_test() {
  // Environments plan Phase 1: a relative root would resolve against
  // the BEAM's cwd — refuse it loudly at load (smart-loop S6).
  set_all([
    #("NEXUS_ENCRYPTION_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="),
    #("NEXUS_WORKSPACE_ROOT", "ws"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_WORKSPACE_ROOT must be an"))
  set_all([
    #("NEXUS_ENCRYPTION_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="),
    #("NEXUS_WORKSPACE_ROOT", "/srv/ws"),
  ])
  let assert Ok(cfg) = config.load()
  should.equal(cfg.workspace_root, Some("/srv/ws"))

  // Reject '/' and '..' segments so config agrees with workspace_gc.
  set_all([
    #("NEXUS_ENCRYPTION_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="),
    #("NEXUS_WORKSPACE_ROOT", "/"),
  ])
  should.be_error(config.load())
  set_all([
    #("NEXUS_ENCRYPTION_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="),
    #("NEXUS_WORKSPACE_ROOT", "/srv/ws/../etc"),
  ])
  should.be_error(config.load())
}

pub fn env_knob_bounds_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="),
    #("NEXUS_ENV_TIMEOUT_MS", "10"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_ENV_TIMEOUT_MS"))
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
  // Bots P3c: the hop guard ships at 4 (four bot-to-bot hops max).
  cfg.max_bot_hops |> should.equal(4)
  should.be_true(cfg.system_prompt |> string.starts_with("You are nexus"))
}

pub fn load_overrides_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MAX_BOT_HOPS", "2"),
    #("NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS", "60000"),
    #("NEXUS_STREAM_IDLE_TIMEOUT_MS", "5000"),
    #("NEXUS_HTTP_BIND", "0.0.0.0"),
    #("NEXUS_HTTP_PORT", "9000"),
    #("NEXUS_UI_TOKEN", "sekrit"),
    #("NEXUS_SYSTEM_PROMPT", "custom prompt"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.max_bot_hops |> should.equal(2)
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

pub fn load_rejects_negative_http_fetch_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_HTTP_FETCH_TIMEOUT_MS", "-1"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_HTTP_FETCH_TIMEOUT_MS must be >= 0: -1",
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

/// Plugin-api Phase 1: no plugins by default (the boot is the
/// pre-plugin boot, byte for byte), with the timeout/cap defaults.
pub fn load_plugin_defaults_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.plugins |> should.equal([])
  cfg.plugin_timeout_ms |> should.equal(30_000)
  cfg.plugin_max_output_chars |> should.equal(32_768)
}

/// Comma-separated with tolerant trimming and empty-segment dropping:
/// `NEXUS_PLUGINS="a, b,,"` means ["a", "b"]. (Unknown names are NOT
/// a load error — they fail boot loudly in `plugin.boot`, which owns
/// the compiled-in registry.)
pub fn load_plugin_list_parses_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_PLUGINS", " example , b ,, "),
    #("NEXUS_PLUGIN_TIMEOUT_MS", "1234"),
    #("NEXUS_PLUGIN_MAX_OUTPUT_CHARS", "512"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.plugins |> should.equal(["example", "b"])
  cfg.plugin_timeout_ms |> should.equal(1234)
  cfg.plugin_max_output_chars |> should.equal(512)
}

/// A sub-100ms adapter deadline could never serve a call — fail the
/// load, like the codemode timeout floor.
pub fn load_rejects_low_plugin_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_PLUGIN_TIMEOUT_MS", "99"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_PLUGIN_TIMEOUT_MS must be >= 100: 99",
  )
}

pub fn load_rejects_negative_plugin_output_cap_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_PLUGIN_MAX_OUTPUT_CHARS", "-1"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_PLUGIN_MAX_OUTPUT_CHARS must be >= 0: -1",
  )
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

// ---- MCP servers (plugin-api plan Phase 2) --------------------------------

pub fn mcp_servers_absent_by_default_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.mcp_servers |> should.equal([])
}

pub fn mcp_servers_parse_full_entry_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #(
      "NEXUS_MCP_SERVERS_JSON",
      "[{\"name\":\"github\",\"command\":\"npx\","
        <> "\"args\":[\"-y\",\"@modelcontextprotocol/server-github\"],"
        <> "\"env\":{\"GITHUB_TOKEN\":\"tok\"},\"timeout_ms\":60000}]",
    ),
  ])
  let assert Ok(cfg) = config.load()
  let assert [server] = cfg.mcp_servers
  server.name |> should.equal("github")
  server.command |> should.equal("npx")
  server.args |> should.equal(["-y", "@modelcontextprotocol/server-github"])
  server.timeout_ms |> should.equal(Some(60_000))
  let assert [#(k, v)] = server.env
  k |> should.equal("GITHUB_TOKEN")
  v |> should.equal("tok")
}

pub fn mcp_servers_defaults_are_empty_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "[{\"name\":\"fs\",\"command\":\"./fs\"}]"),
  ])
  let assert Ok(cfg) = config.load()
  let assert [server] = cfg.mcp_servers
  server.args |> should.equal([])
  server.env |> should.equal([])
  server.timeout_ms |> should.equal(None)
}

pub fn mcp_servers_blank_string_is_empty_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "   "),
  ])
  let assert Ok(cfg) = config.load()
  cfg.mcp_servers |> should.equal([])
}

pub fn mcp_servers_rejects_invalid_json_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "[{name: github}]"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NEXUS_MCP_SERVERS_JSON"))
}

pub fn mcp_servers_rejects_bad_name_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "[{\"name\":\"bad__name\",\"command\":\"x\"}]"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "bad__name"))
}

pub fn mcp_servers_rejects_duplicate_names_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #(
      "NEXUS_MCP_SERVERS_JSON",
      "[{\"name\":\"a\",\"command\":\"x\"},{\"name\":\"a\",\"command\":\"y\"}]",
    ),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "duplicate"))
}

pub fn mcp_servers_rejects_empty_command_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "[{\"name\":\"a\",\"command\":\"  \"}]"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "command"))
}

pub fn mcp_servers_rejects_env_key_with_equals_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #(
      "NEXUS_MCP_SERVERS_JSON",
      "[{\"name\":\"a\",\"command\":\"x\",\"env\":{\"A=B\":\"v\"}}]",
    ),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "'='"))
}

pub fn mcp_servers_rejects_low_timeout_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #(
      "NEXUS_MCP_SERVERS_JSON",
      "[{\"name\":\"a\",\"command\":\"x\",\"timeout_ms\":10}]",
    ),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "timeout_ms"))
}

pub fn mcp_servers_rejects_nul_in_env_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #(
      "NEXUS_MCP_SERVERS_JSON",
      "[{\"name\":\"a\",\"command\":\"x\",\"env\":{\"K\":\"v\\u0000\"}}]",
    ),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NUL"))
}

pub fn mcp_servers_rejects_nul_in_command_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_MCP_SERVERS_JSON", "[{\"name\":\"a\",\"command\":\"x\\u0000y\"}]"),
  ])
  let assert Error(message) = config.load()
  should.be_true(string.contains(message, "NUL"))
}

// ---------------------------------------------------------------------------
// TUI pairing hygiene (tui-pairing plan)
// ---------------------------------------------------------------------------

/// The idle-node sweep ships enabled at 7 days.
pub fn node_idle_days_defaults_and_overrides_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.node_idle_days |> should.equal(7)
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_NODE_IDLE_DAYS", "0"),
  ])
  let assert Ok(cfg) = config.load()
  // 0 legitimately DISABLES the sweep (a credential lives until
  // revoked) — the floor is non-negative, not positive.
  cfg.node_idle_days |> should.equal(0)
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_NODE_IDLE_DAYS", "30"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.node_idle_days |> should.equal(30)
}

pub fn node_idle_days_rejects_negative_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_NODE_IDLE_DAYS", "-1"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal("environment variable NEXUS_NODE_IDLE_DAYS must be >= 0: -1")
}

pub fn log_level_defaults_and_overrides_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.log_level |> should.equal(log.Info)

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_LOG_LEVEL", "debug"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.log_level |> should.equal(log.Debug)

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_LOG_LEVEL", "WARNING"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.log_level |> should.equal(log.Warn)

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_LOG_LEVEL", "error"),
  ])
  let assert Ok(cfg) = config.load()
  cfg.log_level |> should.equal(log.Error)
}

pub fn log_level_rejects_invalid_value_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_LOG_LEVEL", "verbose"),
  ])
  let assert Error(message) = config.load()
  message
  |> should.equal(
    "environment variable NEXUS_LOG_LEVEL must be one of: debug, info, warn, error: verbose",
  )
}

// ---------------------------------------------------------------------------
// web_fetch knobs
// ---------------------------------------------------------------------------

pub fn web_fetch_defaults_and_overrides_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.web_fetch_max_raw_bytes |> should.equal(1_048_576)
  cfg.web_fetch_max_decompressed_bytes |> should.equal(8_388_608)
  cfg.web_fetch_default_chars |> should.equal(12_000)
  cfg.web_fetch_max_chars |> should.equal(32_000)
  cfg.web_fetch_cache_ttl_ms |> should.equal(600_000)

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_MAX_RAW_BYTES", "524288"),
    #("NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES", "4194304"),
    #("NEXUS_WEB_FETCH_DEFAULT_CHARS", "8000"),
    #("NEXUS_WEB_FETCH_MAX_CHARS", "16000"),
    #("NEXUS_WEB_FETCH_CACHE_TTL_MS", "0"),
  ])
  let assert Ok(custom) = config.load()
  custom.web_fetch_max_raw_bytes |> should.equal(524_288)
  custom.web_fetch_max_decompressed_bytes |> should.equal(4_194_304)
  custom.web_fetch_default_chars |> should.equal(8000)
  custom.web_fetch_max_chars |> should.equal(16_000)
  custom.web_fetch_cache_ttl_ms |> should.equal(0)
}

pub fn web_fetch_rejects_invalid_bounds_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_MAX_RAW_BYTES", "0"),
  ])
  let assert Error(msg1) = config.load()
  should.be_true(string.contains(msg1, "NEXUS_WEB_FETCH_MAX_RAW_BYTES"))

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_DEFAULT_CHARS", "0"),
  ])
  let assert Error(msg2) = config.load()
  should.be_true(string.contains(msg2, "NEXUS_WEB_FETCH_DEFAULT_CHARS"))

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES", "0"),
  ])
  let assert Error(msg_d) = config.load()
  should.be_true(string.contains(
    msg_d,
    "NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES",
  ))

  // max_chars must be >= default_chars (including when only DEFAULT_CHARS is
  // raised above the 32_000 default MAX_CHARS).
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_DEFAULT_CHARS", "20000"),
    #("NEXUS_WEB_FETCH_MAX_CHARS", "10000"),
  ])
  let assert Error(msg3) = config.load()
  should.be_true(string.contains(msg3, "NEXUS_WEB_FETCH_MAX_CHARS"))
  should.be_true(string.contains(msg3, "NEXUS_WEB_FETCH_DEFAULT_CHARS"))

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_DEFAULT_CHARS", "40000"),
  ])
  let assert Error(msg3b) = config.load()
  should.be_true(string.contains(msg3b, "NEXUS_WEB_FETCH_MAX_CHARS (32000)"))
  should.be_true(string.contains(msg3b, "NEXUS_WEB_FETCH_DEFAULT_CHARS (40000)"))

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WEB_FETCH_CACHE_TTL_MS", "-1"),
  ])
  let assert Error(msg4) = config.load()
  should.be_true(string.contains(msg4, "NEXUS_WEB_FETCH_CACHE_TTL_MS"))
}

// ---------------------------------------------------------------------------
// Workspace sandbox & cap knobs (workspace-sandbox plan Phase 2)
// ---------------------------------------------------------------------------

pub fn workspace_sandbox_defaults_and_overrides_test() {
  set_all([#("NEXUS_ENCRYPTION_KEY", key_b64)])
  let assert Ok(cfg) = config.load()
  cfg.workspace_sandbox |> should.equal(config.SandboxNone)
  cfg.workspace_sandbox_bin |> should.equal(None)
  cfg.workspace_toolchain |> should.equal(None)
  cfg.workspace_state_dir |> should.equal(None)
  cfg.workspace_max_memory_mb |> should.equal(1024)
  cfg.workspace_max_pids |> should.equal(64)

  // bwrap with explicit bin, toolchain, state dir, and custom caps.
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_ROOT", "/var/lib/nexus/workspaces/"),
    #("NEXUS_WORKSPACE_SANDBOX", "BWRAP"),
    #("NEXUS_WORKSPACE_SANDBOX_BIN", "/nix/store/abc-bwrap/bin/bwrap"),
    #("NEXUS_WORKSPACE_TOOLCHAIN", "/nix/store/def-ws-tools/"),
    #("NEXUS_WORKSPACE_STATE_DIR", "/var/lib/nexus/state/"),
    #("NEXUS_WORKSPACE_MAX_MEMORY_MB", "512"),
    #("NEXUS_WORKSPACE_MAX_PIDS", "32"),
  ])
  let assert Ok(bwrap) = config.load()
  bwrap.workspace_root |> should.equal(Some("/var/lib/nexus/workspaces"))
  bwrap.workspace_sandbox |> should.equal(config.SandboxBwrap)
  bwrap.workspace_sandbox_bin
  |> should.equal(Some("/nix/store/abc-bwrap/bin/bwrap"))
  bwrap.workspace_toolchain |> should.equal(Some("/nix/store/def-ws-tools"))
  bwrap.workspace_state_dir |> should.equal(Some("/var/lib/nexus/state"))
  bwrap.workspace_max_memory_mb |> should.equal(512)
  bwrap.workspace_max_pids |> should.equal(32)

  // nono with a non-overlapping state dir (including sibling-prefix paths).
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_ROOT", "/var/lib/nexus/ws"),
    #("NEXUS_WORKSPACE_SANDBOX", "nono"),
    #("NEXUS_WORKSPACE_STATE_DIR", "/var/lib/nexus/ws-state"),
  ])
  let assert Ok(nono) = config.load()
  nono.workspace_sandbox |> should.equal(config.SandboxNono)
  nono.workspace_state_dir |> should.equal(Some("/var/lib/nexus/ws-state"))
}

pub fn workspace_sandbox_rejects_invalid_values_test() {
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_SANDBOX", "docker"),
  ])
  let assert Error(msg1) = config.load()
  msg1
  |> should.equal(
    "environment variable NEXUS_WORKSPACE_SANDBOX must be one of: none, bwrap, nono: docker",
  )

  // Phase 0 embedding contract: nono requires a state dir outside grants.
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_SANDBOX", "nono"),
  ])
  let assert Error(msg2) = config.load()
  should.be_true(string.contains(msg2, "NEXUS_WORKSPACE_STATE_DIR"))
  should.be_true(string.contains(msg2, "nono"))

  // Inert sandbox-only knobs fail loudly when NEXUS_WORKSPACE_SANDBOX is
  // unset or explicitly `none` (prevents silent unsandboxed execution).
  list.each(
    [
      #("NEXUS_WORKSPACE_SANDBOX_BIN", "/usr/bin/bwrap"),
      #("NEXUS_WORKSPACE_TOOLCHAIN", "/nix/store/def-ws-tools"),
      #("NEXUS_WORKSPACE_STATE_DIR", "/var/lib/nexus/state"),
    ],
    fn(pair) {
      set_all([
        #("NEXUS_ENCRYPTION_KEY", key_b64),
        pair,
      ])
      let assert Error(msg_unset) = config.load()
      should.be_true(string.contains(msg_unset, pair.0))
      should.be_true(string.contains(msg_unset, "NEXUS_WORKSPACE_SANDBOX"))

      set_all([
        #("NEXUS_ENCRYPTION_KEY", key_b64),
        #("NEXUS_WORKSPACE_SANDBOX", "none"),
        pair,
      ])
      let assert Error(msg_none) = config.load()
      should.be_true(string.contains(msg_none, pair.0))
      should.be_true(string.contains(msg_none, "NEXUS_WORKSPACE_SANDBOX"))
    },
  )

  // State dir must not overlap workspace root (equal, child, or parent).
  list.each(
    [
      #("/var/lib/nexus/ws", "/var/lib/nexus/ws"),
      #("/var/lib/nexus/ws", "/var/lib/nexus/ws/state"),
      #("/var/lib/nexus/ws/sub", "/var/lib/nexus/ws"),
    ],
    fn(pair) {
      set_all([
        #("NEXUS_ENCRYPTION_KEY", key_b64),
        #("NEXUS_WORKSPACE_SANDBOX", "nono"),
        #("NEXUS_WORKSPACE_ROOT", pair.0),
        #("NEXUS_WORKSPACE_STATE_DIR", pair.1),
      ])
      let assert Error(msg) = config.load()
      should.be_true(string.contains(msg, "must not overlap"))
    },
  )

  // Path hygiene applies to sandbox bin, toolchain, and state dir.
  list.each(
    [
      #("NEXUS_WORKSPACE_SANDBOX_BIN", "bwrap"),
      #("NEXUS_WORKSPACE_SANDBOX_BIN", "/"),
      #("NEXUS_WORKSPACE_TOOLCHAIN", "tools"),
      #("NEXUS_WORKSPACE_TOOLCHAIN", "/nix/store/../etc"),
      #("NEXUS_WORKSPACE_STATE_DIR", "state"),
      #("NEXUS_WORKSPACE_STATE_DIR", "/var/../etc"),
    ],
    fn(pair) {
      set_all([
        #("NEXUS_ENCRYPTION_KEY", key_b64),
        pair,
      ])
      let assert Error(msg) = config.load()
      should.be_true(string.contains(msg, pair.0))
    },
  )

  // Cap floors reject unusable memory / PID limits.
  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_MAX_MEMORY_MB", "15"),
  ])
  let assert Error(msg_mem) = config.load()
  should.be_true(string.contains(msg_mem, "NEXUS_WORKSPACE_MAX_MEMORY_MB"))

  set_all([
    #("NEXUS_ENCRYPTION_KEY", key_b64),
    #("NEXUS_WORKSPACE_MAX_PIDS", "3"),
  ])
  let assert Error(msg_pids) = config.load()
  should.be_true(string.contains(msg_pids, "NEXUS_WORKSPACE_MAX_PIDS"))
}
