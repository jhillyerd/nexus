//// Environment-driven configuration for the web server.
////
//// Misconfiguration must fail loudly *before* any network call, so `load`
//// validates and parses everything up front. The TTFT audit tool has its
//// own loader (`audit/config`) and must not depend on this surface.

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/crypto
import nexus/log
import nexus/tool_provider

/// Default system prompt (NEXUS_SYSTEM_PROMPT unset).
const default_system_prompt =
  "You are nexus, a concise personal assistant running on a self-hosted "
  <> "Gleam/BEAM harness. Answer directly and briefly."

/// Appended to the default system prompt while codemode is enabled.
/// Manual testing showed models tripping over this in every new thread
/// (em-dash in a string literal -> compile failure): Luerl's tokenizer
/// rejects non-ASCII in Lua source (both binary and codepoint forms -
/// upstream, see codemode plan / issue #54), so the warning belongs in
/// the standing instructions, not only the tool description. ASCII
/// throughout, leading space to splice onto the prompt.
const codemode_ascii_note =
  " When writing codemode (Lua) scripts: script source must be ASCII-only"
  <> " - non-ASCII characters in string literals (em dashes, curly quotes,"
  <> " non-Latin text) fail to compile. Build such strings from bytes with"
  <> " string.char(); text returned by other tools may contain non-ASCII"
  <> " freely."

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
    /// System prompt, frozen at thread creation (contract rule 2).
    system_prompt: String,
    /// M3 tool loop: maximum model round-trips per user turn (the guard).
    max_tool_iterations: Int,
    /// Bots P3c (issue #97): the bot-to-bot hop guard. A delivery whose
    /// depth exceeds this is refused by the thread registry's `Deliver`,
    /// so a runaway A→B→C→… chain stops after N bot-to-bot hops — the
    /// inter-bot analogue of `max_tool_iterations`.
    max_bot_hops: Int,
    /// M3 http_fetch: maximum response body kept, in bytes.
    http_fetch_max_bytes: Int,
    /// M3 http_fetch: connect+receive timeout per hop, in ms.
    http_fetch_timeout_ms: Int,
    /// M3 http_fetch: dev/test escape hatch allowing private/loopback
    /// targets. Never enable in production (SSRF guard).
    http_fetch_allow_private: Bool,
    /// web_fetch: streaming raw response byte cap enforced in `nexus_net_ffi`
    /// before decompression and HTML-to-Markdown conversion.
    web_fetch_max_raw_bytes: Int,
    /// web_fetch: hard cap on DECOMPRESSED bytes when decoding a gzip/deflate
    /// response (`net.inflate_bounded` truncates there, mirroring the wire
    /// cap, so a decompression bomb costs at most this much).
    web_fetch_max_decompressed_bytes: Int,
    /// web_fetch: default returned Markdown/text slice length in characters
    /// when the model omits `max_length`.
    web_fetch_default_chars: Int,
    /// web_fetch: hard upper clamp on `max_length` per call, in characters.
    web_fetch_max_chars: Int,
    /// web_fetch: in-memory extracted-document cache TTL in ms (`0` disables
    /// the cache).
    web_fetch_cache_ttl_ms: Int,
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
    /// Utility calls (utility-titles plan §4.6): the once-per-thread
    /// model-generated title upgrade, branched off the committed
    /// transcript's cached prefix. Off switches the feature entirely —
    /// the heuristic first-message title then stays forever.
    utility_enabled: Bool,
    /// Utility debounce: how long after a turn commit the side call waits
    /// (so a fast follow-up message cancels it before it starts).
    utility_delay_ms: Int,
    /// Codemode (codemode plan phase 1): register the Lua-script tool.
    /// Off keeps the tool schema list byte-identical to the pre-codemode
    /// registry (KV-cache contract rule 4).
    codemode: Bool,
    /// Codemode: per-script wall-clock deadline in ms.
    codemode_timeout_ms: Int,
    /// Codemode: rendered-output cap in characters (head and tail kept,
    /// omission noted; item/console separators are budgeted with their
    /// segments — issue #53).
    codemode_max_output_chars: Int,
    /// Plugins (plugin-api plan Phase 1): compiled-in plugin names to
    /// start as tool providers (`NEXUS_PLUGINS`, comma-separated).
    /// Empty — the default — starts no provider and keeps the boot
    /// byte-identical to the pre-plugin world. Gates availability
    /// only, never default membership.
    plugins: List(String),
    /// Plugins: per-call wall-clock deadline in ms (the adapter's
    /// timeout), the config default a provider may override.
    plugin_timeout_ms: Int,
    /// Plugins: the adapter's central output cap in characters for
    /// provider results and error messages (display hygiene enforced
    /// at the boundary, never delegated to untrusted sources).
    plugin_max_output_chars: Int,
    /// MCP servers (plugin-api plan Phase 2): configured stdio servers
    /// to start as tool providers (`NEXUS_MCP_SERVERS_JSON`, a JSON
    /// array). Empty — the default — starts no adapter and keeps the
    /// boot byte-identical to the pre-MCP world. Gates availability
    /// only, never default membership: an MCP tool enters a thread only
    /// via a bot template or an explicit create toolset, and its schema
    /// freezes into the thread's manifest at creation.
    mcp_servers: List(McpServer),
    /// Environments plan Phase 1: the root directory under which each
    /// env-carrying thread gets its own workspace (`<root>/<thread
    /// id>`, created lazily on first use). `None` — the default —
    /// disables env toolset selection at creation entirely (the
    /// SearxNG-gating pattern): the four env tools are never in the
    /// default toolset, and a create or bot save naming them refuses
    /// with the honest reason. The RESOLVED root freezes per thread at
    /// creation (`thread.workspace_root`), so changing it later affects
    /// new threads only.
    workspace_root: Option(String),
    /// Workspace sandbox backend (`NEXUS_WORKSPACE_SANDBOX`: `none`, `bwrap`,
    /// or `nono`; default `none` so offline tests and unsupported platforms
    /// stay deterministic).
    workspace_sandbox: WorkspaceSandbox,
    /// Optional explicit absolute path to the sandbox binary (`bwrap` or
    /// `nono`, `NEXUS_WORKSPACE_SANDBOX_BIN`). `None` resolves on `PATH`.
    workspace_sandbox_bin: Option(String),
    /// Optional absolute path to the immutable workspace toolchain profile
    /// directory (`NEXUS_WORKSPACE_TOOLCHAIN`, e.g. a Nix `pkgs.buildEnv`
    /// carrying `/bin` and `/etc/ssl`).
    workspace_toolchain: Option(String),
    /// Optional absolute directory for sandbox state/profiles outside every
    /// workspace grant (`NEXUS_WORKSPACE_STATE_DIR`). Required when
    /// `workspace_sandbox == SandboxNono` (Phase 0 embedding contract: nono
    /// refuses any grant overlapping its `HOME`/`XDG_*` state roots) and
    /// forbidden from overlapping `workspace_root` (checked lexically in pure
    /// `from_env` — symlinks are not resolved at config load, matching
    /// `env.confined` and `workspace_gc.safe_target_path`).
    workspace_state_dir: Option(String),
    /// Per-command workspace memory cap in MiB (`NEXUS_WORKSPACE_MAX_MEMORY_MB`,
    /// default `1024`, floor `16`).
    workspace_max_memory_mb: Int,
    /// Per-command workspace PID cap (`NEXUS_WORKSPACE_MAX_PIDS`, default `64`,
    /// floor `4`).
    workspace_max_pids: Int,
    /// Environments: per-call wall-clock deadline for `bash`, in ms.
    env_timeout_ms: Int,
    /// Environments: the byte cap enforced WHILE READING bash output
    /// and file reads (accumulation-bounded — post-hoc truncation does
    /// not bound memory).
    env_max_output_bytes: Int,
    /// TUI pairing hygiene (tui-pairing plan): a node whose credential
    /// has gone idle this many days (since last seen; `created_at` for
    /// never-connected rows) is deleted by the boot sweep. `0` disables
    /// the sweep entirely — a daily-driver TUI keeps its credential
    /// indefinitely; a crashed one has a week by default.
    node_idle_days: Int,
    /// Minimum server log level (`NEXUS_LOG_LEVEL`: `debug`, `info`,
    /// `warn`/`warning`, `error`; default `info`).
    log_level: log.Level,
  )
}

/// Local workspace `bash` sandbox backend (workspace-sandbox plan, Phase 0/2):
/// `SandboxNone` runs directly with the allowlist env scrub (default for
/// offline tests and unsupported platforms); `SandboxBwrap` is the primary
/// Linux mount/PID/net namespace backend; `SandboxNono` is the Landlock /
/// Seatbelt alternate.
pub type WorkspaceSandbox {
  SandboxNone
  SandboxBwrap
  SandboxNono
}

/// One configured MCP server (plugin-api plan Phase 2): a stdio child
/// process speaking newline-delimited JSON-RPC on stdin/stdout, adapted
/// into the provider protocol by `nexus/mcp`. `name` is the provider
/// half of the qualified wire name (`<name>__<tool>`) — same rules as
/// a plugin name. `env` entries OVERRIDE/ADD to nexus's inherited
/// environment; `timeout_ms` overrides the per-call deadline the same
/// way a plugin's does (same floor).
pub type McpServer {
  McpServer(
    name: String,
    command: String,
    args: List(String),
    env: List(#(String, String)),
    timeout_ms: Option(Int),
  )
}

/// Plugins: the per-call timeout floor shared by `NEXUS_PLUGIN_TIMEOUT_MS`
/// and a plugin's `timeout_ms` override (validated in `nexus/plugin`) —
/// ONE definition so the two rules cannot drift apart.
pub const plugin_timeout_floor_ms = 100

/// Which remediation applies to a config error. Attached AT CONSTRUCTION
/// (the key step and the workspace-sandbox rules), never re-derived from
/// the message: error text is free-form and echoes operator-supplied
/// values (paths, raw values), so substring-matching it misclassifies —
/// an overlap error echoing a root path that happens to contain
/// "NEXUS_ENCRYPTION_KEY" once got the key hint that way.
pub type Hint {
  KeyHint
  WorkspaceSandboxHint
  GenericHint
}

/// A failed `load`: the human-readable message and the hint class
/// attached where the failure was raised.
pub type ConfigError {
  ConfigError(message: String, hint: Hint)
}

/// The remediation text boot logs beside a config error — a pure mapping
/// from the hint class, so reworded messages can never silently drop a
/// hint to the generic pointer. The hardcoded encryption-key hint this
/// replaced logged a wrong variable name for every non-key failure
/// (e.g. the workspace-sandbox rules), which read as two unrelated
/// problems in one line.
pub fn hint(error: ConfigError) -> String {
  case error.hint {
    KeyHint ->
      "required: NEXUS_ENCRYPTION_KEY (base64 of 32 bytes); see the README env table"
    WorkspaceSandboxHint ->
      "workspace sandboxing: NEXUS_WORKSPACE_SANDBOX selects the backend"
      <> " (none | bwrap | nono); nono requires NEXUS_WORKSPACE_STATE_DIR"
      <> " outside NEXUS_WORKSPACE_ROOT; see the README env table"
      <> " and docs/plans/workspace-sandbox.md"
    GenericHint -> "see the README env table"
  }
}

/// Load config from the process environment.
pub fn load() -> Result(Config, ConfigError) {
  from_env(envoy.get)
}

/// Pure variant of `load` over a lookup function, for offline tests.
pub fn from_env(
  get: fn(String) -> Result(String, Nil),
) -> Result(Config, ConfigError) {
  use encryption_key <- result.try(
    required_encryption_key(get)
    |> result.map_error(fn(message) { ConfigError(message, KeyHint) }),
  )
  use cfg <- result.try(
    parse_env(get, encryption_key)
    |> result.map_error(fn(message) { ConfigError(message, GenericHint) }),
  )
  use Nil <- result.try(validate_workspace(cfg))
  Ok(cfg)
}

/// The parse chain behind `from_env`: every env var read, its default,
/// and the inline cross-checks, on plain String errors. `from_env` maps
/// a failure here to the generic hint; the workspace-sandbox rules live
/// in `validate_workspace` instead of this chain precisely because they
/// classify themselves instead of being guessed from their text.
fn parse_env(
  get: fn(String) -> Result(String, Nil),
  encryption_key: String,
) -> Result(Config, String) {
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
  use max_tool_iterations <- result.try(optional_int(
    get,
    "NEXUS_MAX_TOOL_ITERATIONS",
    32,
  ))
  // Non-negative like the other guards: a negative hop limit would
  // refuse every bot delivery, so misconfiguration fails the load
  // instead of surfacing as a broken feature at first use (the
  // loud-boot philosophy).
  use max_bot_hops <- result.try(optional_non_negative_int(
    get,
    "NEXUS_MAX_BOT_HOPS",
    4,
  ))
  use http_fetch_max_bytes <- result.try(optional_int(
    get,
    "NEXUS_HTTP_FETCH_MAX_BYTES",
    20_000,
  ))
  use http_fetch_timeout_ms <- result.try(optional_non_negative_int(
    get,
    "NEXUS_HTTP_FETCH_TIMEOUT_MS",
    15_000,
  ))
  use http_fetch_allow_private <- result.try(optional_bool(
    get,
    "NEXUS_HTTP_FETCH_ALLOW_PRIVATE",
    False,
  ))
  use web_fetch_max_raw_bytes <- result.try(optional_min_int(
    get,
    "NEXUS_WEB_FETCH_MAX_RAW_BYTES",
    1_048_576,
    min: 1,
  ))
  use web_fetch_max_decompressed_bytes <- result.try(optional_min_int(
    get,
    "NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES",
    8_388_608,
    min: 1,
  ))
  use web_fetch_default_chars <- result.try(optional_min_int(
    get,
    "NEXUS_WEB_FETCH_DEFAULT_CHARS",
    12_000,
    min: 1,
  ))
  use web_fetch_max_chars <- result.try(optional_min_int(
    get,
    "NEXUS_WEB_FETCH_MAX_CHARS",
    32_000,
    min: 1,
  ))
  use Nil <- result.try(case web_fetch_max_chars < web_fetch_default_chars {
    True ->
      Error(
        "environment variable NEXUS_WEB_FETCH_MAX_CHARS ("
        <> int.to_string(web_fetch_max_chars)
        <> ") must be >= NEXUS_WEB_FETCH_DEFAULT_CHARS ("
        <> int.to_string(web_fetch_default_chars)
        <> ")",
      )
    False -> Ok(Nil)
  })
  use web_fetch_cache_ttl_ms <- result.try(optional_non_negative_int(
    get,
    "NEXUS_WEB_FETCH_CACHE_TTL_MS",
    600_000,
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
  use utility_delay_ms <- result.try(optional_non_negative_int(
    get,
    "NEXUS_UTILITY_DELAY_MS",
    1500,
  ))
  // ---- Codemode (codemode plan phase 1). Off by default so the frozen
  // tool envelope is unchanged until explicitly enabled.
  use codemode <- result.try(optional_bool(get, "NEXUS_CODEMODE", False))
  use codemode_timeout_ms <- result.try(optional_min_int(
    get,
    "NEXUS_CODEMODE_TIMEOUT_MS",
    30_000,
    min: 1000,
  ))
  use codemode_max_output_chars <- result.try(optional_min_int(
    get,
    "NEXUS_CODEMODE_MAX_OUTPUT_CHARS",
    32_768,
    min: 0,
  ))
  // ---- Plugins (plugin-api plan Phase 1). `NEXUS_PLUGINS` gates a
  // provider's AVAILABILITY, never default membership: plugin tools
  // enter a thread only via a bot template or an explicit create
  // toolset, so the default envelope cannot change under config drift.
  // Unknown names here fail boot loudly in `plugin.boot` (the
  // compiled-in registry), not silently at first use.
  let plugins = optional_string_list(get, "NEXUS_PLUGINS")
  use plugin_timeout_ms <- result.try(optional_min_int(
    get,
    "NEXUS_PLUGIN_TIMEOUT_MS",
    30_000,
    min: plugin_timeout_floor_ms,
  ))
  use plugin_max_output_chars <- result.try(optional_min_int(
    get,
    "NEXUS_PLUGIN_MAX_OUTPUT_CHARS",
    32_768,
    min: 0,
  ))
  // ---- MCP servers (plugin-api plan Phase 2). One JSON env var, not a
  // comma list: a stdio command carries arguments with spaces, and a
  // command list would need quoting rules JSON already has. Parsed and
  // validated HERE (loud config failure, the boot philosophy); the
  // adapter's per-server degrade lives in `nexus/mcp`'s boot mount.
  use mcp_servers <- result.try(mcp_servers(get))
  // ---- Environments plan Phase 1. `NEXUS_WORKSPACE_ROOT` gates env
  // toolset AVAILABILITY at create/bot-save (the SearxNG pattern),
  // never default membership; the timeout floor keeps a sub-second
  // bash deadline from configuring a broken tool (the loud-boot
  // philosophy, the codemode/plugin precedent).
  use workspace_root <- result.try(optional_abs_path(
    get,
    "NEXUS_WORKSPACE_ROOT",
  ))
  use workspace_sandbox <- result.try(optional_workspace_sandbox(
    get,
    "NEXUS_WORKSPACE_SANDBOX",
  ))
  use workspace_sandbox_bin <- result.try(optional_abs_path(
    get,
    "NEXUS_WORKSPACE_SANDBOX_BIN",
  ))
  use workspace_toolchain <- result.try(optional_abs_path(
    get,
    "NEXUS_WORKSPACE_TOOLCHAIN",
  ))
  use workspace_state_dir <- result.try(optional_abs_path(
    get,
    "NEXUS_WORKSPACE_STATE_DIR",
  ))
  use workspace_max_memory_mb <- result.try(optional_min_int(
    get,
    "NEXUS_WORKSPACE_MAX_MEMORY_MB",
    1024,
    min: 16,
  ))
  use workspace_max_pids <- result.try(optional_min_int(
    get,
    "NEXUS_WORKSPACE_MAX_PIDS",
    64,
    min: 4,
  ))
  use env_timeout_ms <- result.try(optional_min_int(
    get,
    "NEXUS_ENV_TIMEOUT_MS",
    60_000,
    min: 1000,
  ))
  use env_max_output_bytes <- result.try(optional_min_int(
    get,
    "NEXUS_ENV_MAX_OUTPUT_BYTES",
    262_144,
    min: 1024,
  ))
  // TUI pairing hygiene: 0 legitimately disables the sweep, so the
  // floor is 0 (non-negative), not a positive minimum.
  use node_idle_days <- result.try(optional_non_negative_int(
    get,
    "NEXUS_NODE_IDLE_DAYS",
    7,
  ))
  use log_level <- result.try(optional_log_level(get, "NEXUS_LOG_LEVEL"))
  // The ASCII note rides the DEFAULT prompt only, and only while
  // codemode is enabled: an explicitly set NEXUS_SYSTEM_PROMPT is the
  // operator's own text and is never amended (enable codemode with a
  // custom prompt and you add the note yourself - see README). The
  // system prompt is frozen per thread at creation, so this stays
  // byte-stable within a thread (KV-cache contract).
  let system_prompt = case optional_string(get, "NEXUS_SYSTEM_PROMPT") {
    option.Some(explicit) -> explicit
    option.None ->
      case codemode {
        True -> default_system_prompt <> codemode_ascii_note
        False -> default_system_prompt
      }
  }
  Ok(Config(
    encryption_key: encryption_key,
    sse_first_response_timeout_ms: first_response_ms,
    stream_idle_timeout_ms: idle_ms,
    http_bind: http_bind,
    http_port: http_port,
    ui_token: optional_string(get, "NEXUS_UI_TOKEN"),
    system_prompt: system_prompt,
    max_tool_iterations: max_tool_iterations,
    max_bot_hops: max_bot_hops,
    http_fetch_max_bytes: http_fetch_max_bytes,
    http_fetch_timeout_ms: http_fetch_timeout_ms,
    http_fetch_allow_private: http_fetch_allow_private,
    web_fetch_max_raw_bytes: web_fetch_max_raw_bytes,
    web_fetch_max_decompressed_bytes: web_fetch_max_decompressed_bytes,
    web_fetch_default_chars: web_fetch_default_chars,
    web_fetch_max_chars: web_fetch_max_chars,
    web_fetch_cache_ttl_ms: web_fetch_cache_ttl_ms,
    searxng_base_url: optional_string(get, "NEXUS_SEARXNG_BASE_URL"),
    searxng_token: optional_string(get, "NEXUS_SEARXNG_TOKEN"),
    pg_host: pg_host,
    pg_port: pg_port,
    pg_database: pg_database,
    pg_user: pg_user,
    pg_password: pg_password,
    utility_enabled: utility_enabled,
    utility_delay_ms: utility_delay_ms,
    codemode: codemode,
    codemode_timeout_ms: codemode_timeout_ms,
    codemode_max_output_chars: codemode_max_output_chars,
    plugins: plugins,
    plugin_timeout_ms: plugin_timeout_ms,
    plugin_max_output_chars: plugin_max_output_chars,
    mcp_servers: mcp_servers,
    workspace_root: workspace_root,
    workspace_sandbox: workspace_sandbox,
    workspace_sandbox_bin: workspace_sandbox_bin,
    workspace_toolchain: workspace_toolchain,
    workspace_state_dir: workspace_state_dir,
    workspace_max_memory_mb: workspace_max_memory_mb,
    workspace_max_pids: workspace_max_pids,
    env_timeout_ms: env_timeout_ms,
    env_max_output_bytes: env_max_output_bytes,
    node_idle_days: node_idle_days,
    log_level: log_level,
  ))
}

/// The workspace-sandbox rules, validated against the PARSED config so
/// each error carries its WorkspaceSandboxHint from construction — the
/// messages echo operator-supplied paths, so their text cannot classify
/// them. Checked after the parse chain rather than mid-chain: error
/// ordering among independent misconfigurations is not load-bearing,
/// and every failure is still a loud, named, load-refusing one.
fn validate_workspace(cfg: Config) -> Result(Nil, ConfigError) {
  use Nil <- result.try(case cfg.workspace_sandbox {
    SandboxNone ->
      case
        cfg.workspace_sandbox_bin,
        cfg.workspace_toolchain,
        cfg.workspace_state_dir
      {
        Some(_), _, _ ->
          Error(ConfigError(
            "environment variable NEXUS_WORKSPACE_SANDBOX_BIN requires"
              <> " NEXUS_WORKSPACE_SANDBOX to be bwrap or nono",
            WorkspaceSandboxHint,
          ))
        _, Some(_), _ ->
          Error(ConfigError(
            "environment variable NEXUS_WORKSPACE_TOOLCHAIN requires"
              <> " NEXUS_WORKSPACE_SANDBOX to be bwrap or nono",
            WorkspaceSandboxHint,
          ))
        _, _, Some(_) ->
          Error(ConfigError(
            "environment variable NEXUS_WORKSPACE_STATE_DIR requires"
              <> " NEXUS_WORKSPACE_SANDBOX to be bwrap or nono",
            WorkspaceSandboxHint,
          ))
        None, None, None -> Ok(Nil)
      }
    SandboxBwrap -> Ok(Nil)
    SandboxNono ->
      case cfg.workspace_state_dir {
        None ->
          Error(ConfigError(
            "environment variable NEXUS_WORKSPACE_STATE_DIR is required when"
              <> " NEXUS_WORKSPACE_SANDBOX=nono",
            WorkspaceSandboxHint,
          ))
        Some(_) -> Ok(Nil)
      }
  })
  case cfg.workspace_root, cfg.workspace_state_dir {
    Some(root), Some(state) ->
      case paths_overlap(root, state) {
        True ->
          Error(ConfigError(
            "environment variable NEXUS_WORKSPACE_STATE_DIR ("
              <> state
              <> ") must not overlap NEXUS_WORKSPACE_ROOT ("
              <> root
              <> ")",
            WorkspaceSandboxHint,
          ))
        False -> Ok(Nil)
      }
    _, _ -> Ok(Nil)
  }
}

/// Parse `NEXUS_MCP_SERVERS_JSON` (plugin-api plan Phase 2): a JSON
/// array of server entries. Absent or `[]` — the default — configures
/// no server and keeps boot byte-identical to the pre-MCP world. Every
/// field is validated at the boundary (the name rule is the provider
/// rule — `tool_provider.valid_name` — because the server name becomes
/// the half-name of every qualified wire name): a bad entry fails the
/// LOAD loudly, naming the server and the rule.
fn mcp_servers(
  get: fn(String) -> Result(String, Nil),
) -> Result(List(McpServer), String) {
  case optional_string(get, "NEXUS_MCP_SERVERS_JSON") {
    None -> Ok([])
    Some(raw) ->
      case string.trim(raw) {
        "" -> Ok([])
        trimmed ->
          case json.parse(trimmed, decode.list(decode_mcp_server())) {
            Error(_) ->
              Error(
                "NEXUS_MCP_SERVERS_JSON: expected a JSON array of"
                <> " {name, command, args?, env?, timeout_ms?} objects",
              )
            Ok(servers) -> validate_mcp_servers(servers)
          }
      }
  }
}

fn decode_mcp_server() -> decode.Decoder(McpServer) {
  use name <- decode.field("name", decode.string)
  use command <- decode.field("command", decode.string)
  use args <- decode.optional_field("args", [], decode.list(decode.string))
  use env <- decode.optional_field(
    "env",
    [],
    decode.dict(decode.string, decode.string)
      |> decode.map(dict.to_list),
  )
  use timeout_ms <- decode.optional_field(
    "timeout_ms",
    None,
    decode.optional(decode.int),
  )
  decode.success(McpServer(
    name: name,
    command: command,
    args: args,
    env: env,
    timeout_ms: timeout_ms,
  ))
}

fn validate_mcp_servers(
  servers: List(McpServer),
) -> Result(List(McpServer), String) {
  use _seen <- result.try(
    list.try_fold(servers, [], fn(seen, server) {
      case list.contains(seen, server.name) {
        True ->
          Error(
            "NEXUS_MCP_SERVERS_JSON: duplicate server name '"
            <> server.name
            <> "'",
          )
        False -> Ok([server.name, ..seen])
      }
    }),
  )
  list.try_map(servers, fn(server) {
    use Nil <- result.try(case tool_provider.valid_name(server.name) {
      True -> Ok(Nil)
      False ->
        Error(
          "NEXUS_MCP_SERVERS_JSON: server name '"
          <> server.name
          <> "' refused: provider name must match ^[a-zA-Z0-9_-]+$"
          <> " with no '__' and no leading or trailing '_'",
        )
    })
    let cmd = string.trim(server.command)
    use Nil <- result.try(case cmd == "", string.contains(cmd, "\u{0000}") {
      True, _ ->
        Error(
          "NEXUS_MCP_SERVERS_JSON: server '"
          <> server.name
          <> "': command must be a non-empty executable path",
        )
      _, True ->
        Error(
          "NEXUS_MCP_SERVERS_JSON: server '"
          <> server.name
          <> "': command contains a NUL byte",
        )
      _, False -> Ok(Nil)
    })
    use Nil <- result.try(
      case list.any(server.args, fn(arg) { string.contains(arg, "\u{0000}") }) {
        True ->
          Error(
            "NEXUS_MCP_SERVERS_JSON: server '"
            <> server.name
            <> "': args must contain no NUL bytes",
          )
        False -> Ok(Nil)
      },
    )
    use Nil <- result.try(
      case
        list.any(server.env, fn(pair) {
          pair.0 == ""
          || string.contains(pair.0, "=")
          || string.contains(pair.0, "\u{0000}")
          || string.contains(pair.1, "\u{0000}")
        })
      {
        True ->
          Error(
            "NEXUS_MCP_SERVERS_JSON: server '"
            <> server.name
            <> "': env keys must be non-empty, contain no '='"
            <> " and no NUL bytes; values likewise (they are OS"
            <> " environment names and values)",
          )
        False -> Ok(Nil)
      },
    )
    use Nil <- result.try(case server.timeout_ms {
      Some(ms) if ms >= plugin_timeout_floor_ms -> Ok(Nil)
      Some(_) ->
        Error(
          "NEXUS_MCP_SERVERS_JSON: server '"
          <> server.name
          <> "': timeout_ms override must be >= "
          <> int.to_string(plugin_timeout_floor_ms)
          <> " ms",
        )
      None -> Ok(Nil)
    })
    Ok(server)
  })
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

fn optional_string_list(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> List(String) {
  // Comma-separated with tolerant trimming and empty-segment
  // dropping, so `NEXUS_PLUGINS="a, b,,"` means ["a", "b"].
  case optional_string(get, name) {
    None -> []
    Some(raw) ->
      raw
      |> string.split(",")
      |> list.filter_map(fn(piece) {
        case string.trim(piece) {
          "" -> Error(Nil)
          name -> Ok(name)
        }
      })
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

/// Like `optional_int`, but a negative value fails the load. For delays
/// handed to timers: a bad sign would otherwise surface as a runtime crash
/// at first use instead of the loud boot failure this module promises.
fn optional_non_negative_int(
  get: fn(String) -> Result(String, Nil),
  name: String,
  default: Int,
) -> Result(Int, String) {
  use value <- result.try(optional_int(get, name, default))
  case value < 0 {
    True ->
      Error(
        "environment variable "
        <> name
        <> " must be >= 0: "
        <> int.to_string(value),
      )
    False -> Ok(value)
  }
}

/// Like `optional_int`, but a value below `min` fails the load. Codemode's
/// ranges must be usable the moment the tool runs — a sub-second deadline
/// or a negative cap would otherwise surface as a broken tool at first
/// use instead of the loud boot failure this module promises.
fn optional_min_int(
  get: fn(String) -> Result(String, Nil),
  name: String,
  default: Int,
  min min_value: Int,
) -> Result(Int, String) {
  use value <- result.try(optional_int(get, name, default))
  case value < min_value {
    True ->
      Error(
        "environment variable "
        <> name
        <> " must be >= "
        <> int.to_string(min_value)
        <> ": "
        <> int.to_string(value),
      )
    False -> Ok(value)
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

fn optional_log_level(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(log.Level, String) {
  case optional_string(get, name) {
    None -> Ok(log.Info)
    Some(raw) ->
      case log.parse_level(raw) {
        Ok(level) -> Ok(level)
        Error(reason) ->
          Error("environment variable " <> name <> " " <> reason <> ": " <> raw)
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

fn optional_workspace_sandbox(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(WorkspaceSandbox, String) {
  case optional_string(get, name) {
    None -> Ok(SandboxNone)
    Some(raw) ->
      case string.lowercase(raw) {
        "none" -> Ok(SandboxNone)
        "bwrap" -> Ok(SandboxBwrap)
        "nono" -> Ok(SandboxNono)
        _ ->
          Error(
            "environment variable "
            <> name
            <> " must be one of: none, bwrap, nono: "
            <> raw,
          )
      }
  }
}

fn optional_abs_path(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(Option(String), String) {
  case optional_string(get, name) {
    None -> Ok(None)
    Some(path) -> validate_abs_path(name, path) |> result.map(Some)
  }
}

/// Validate an absolute path env var at boot so every configured path satisfies
/// `workspace_gc.safe_target_path`: absolute, no NUL bytes, no `..` segments,
/// and never collapsing to `/`.
fn validate_abs_path(name: String, path: String) -> Result(String, String) {
  case string.starts_with(path, "/") {
    False ->
      Error(
        "environment variable " <> name <> " must be an absolute path: " <> path,
      )
    True ->
      case string.contains(path, "\u{0}") {
        True ->
          Error(
            "environment variable " <> name <> " must not contain NUL bytes",
          )
        False -> {
          let raw_segments = string.split(path, "/")
          case list.any(raw_segments, fn(seg) { seg == ".." }) {
            True ->
              Error(
                "environment variable "
                <> name
                <> " must not contain '..': "
                <> path,
              )
            False -> {
              let clean =
                list.filter(raw_segments, fn(seg) { seg != "" && seg != "." })
              case clean {
                [] ->
                  Error(
                    "environment variable "
                    <> name
                    <> " cannot be '/': "
                    <> path,
                  )
                _ -> Ok("/" <> string.join(clean, "/"))
              }
            }
          }
        }
      }
  }
}

/// True when two normalized absolute paths are equal or one is an ancestor
/// directory of the other. Lexical only (pure `from_env` performs no
/// filesystem I/O / symlink resolution).
fn paths_overlap(a: String, b: String) -> Bool {
  a == b || string.starts_with(a, b <> "/") || string.starts_with(b, a <> "/")
}
