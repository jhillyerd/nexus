# Configuration

All server configuration is driven by environment variables and validated
at boot (misconfiguration fails fast).

## Core & HTTP

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_ENCRYPTION_KEY` | — | **Required.** Master key for encrypting provider API keys at rest (AES-256-GCM): base64 of exactly 32 random bytes (`openssl rand -base64 32`). |
| `NEXUS_HTTP_BIND` | `127.0.0.1` | Server bind address. |
| `NEXUS_HTTP_PORT` | `8080` | Server port. |
| `NEXUS_UI_TOKEN` | unset | Single-user bearer token; unset disables auth. With it set, open `/?token=<token>` in the browser (the shell forwards it via `Bearer` header or query param on WebSocket/asset routes). |
| `NEXUS_SYSTEM_PROMPT` | built-in concise assistant prompt | Default system prompt frozen onto newly created threads whose bot leaves `system_prompt` blank. The built-in default appends a codemode note when `NEXUS_CODEMODE=true`; explicitly set values are never modified. |
| `NEXUS_LOG_LEVEL` | `info` | Minimum server log level (`debug`, `info`, `warn`/`warning`, `error`). Emitted as single-line `logfmt` via Erlang `:logger`. |

## LLM streaming timeouts

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_SSE_FIRST_RESPONSE_TIMEOUT_MS` | `30000` | Timeout in ms waiting for the initial SSE HTTP response head. |
| `NEXUS_STREAM_IDLE_TIMEOUT_MS` | `120000` | Receive timeout in ms between SSE events while streaming. |

## Postgres

Persistence is mandatory: boot fails fast if Postgres is unreachable.
Defaults match `docker-compose.yml`.

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_PG_HOST` | `127.0.0.1` | Postgres host. |
| `NEXUS_PG_PORT` | `5433` | Postgres port. |
| `NEXUS_PG_DATABASE` | `nexus` | Database name. |
| `NEXUS_PG_USER` | `nexus` | Database user. |
| `NEXUS_PG_PASSWORD` | unset | Optional password; never logged or echoed. |

CLI tools (`nexus/store/migrate`, `nexus/dev_seed`, and `squirrel`) read
`DATABASE_URL` instead of `NEXUS_PG_*`, e.g.:

```sh
DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus
```

## Agent & bot loop

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_MAX_TOOL_ITERATIONS` | `32` | Max model round-trips per user turn before the loop guard trips. |
| `NEXUS_MAX_BOT_HOPS` | `4` | Max hops in an inter-bot delivery chain (`>= 0`). |

## Web fetch & search

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_HTTP_FETCH_MAX_BYTES` | `20000` | `http_fetch` response body cap per call. |
| `NEXUS_HTTP_FETCH_TIMEOUT_MS` | `15000` | Per-hop hard deadline in ms for `http_fetch` / `web_fetch` (connect, TLS, headers, and body). |
| `NEXUS_HTTP_FETCH_ALLOW_PRIVATE` | `false` | Dev/test escape hatch allowing private/loopback targets in `http_fetch` / `web_fetch`. Keep `false` in production. |
| `NEXUS_WEB_FETCH_MAX_RAW_BYTES` | `1048576` | `web_fetch` compressed wire byte cap before decompression (`> 0`). |
| `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES` | `8388608` | `web_fetch` decompressed byte cap for gzip/deflate responses (`> 0`). |
| `NEXUS_WEB_FETCH_DEFAULT_CHARS` | `12000` | `web_fetch` default `max_length` returned per call in characters (`> 0`). |
| `NEXUS_WEB_FETCH_MAX_CHARS` | `32000` | `web_fetch` hard upper clamp on `max_length` (`>= NEXUS_WEB_FETCH_DEFAULT_CHARS`). |
| `NEXUS_WEB_FETCH_CACHE_TTL_MS` | `600000` | `web_fetch` in-memory extracted-document cache TTL in ms (`0` disables caching). |
| `NEXUS_SEARXNG_BASE_URL` | unset | Enables the `web_search` tool against a SearxNG instance. |
| `NEXUS_SEARXNG_TOKEN` | unset | Optional SearxNG bearer token; never logged or echoed. |

## Utility titles & tags

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_UTILITY_ENABLED` | `true` | Enables once-per-thread model-generated title/tag upgrades branched off the committed transcript's cached prefix. `false` keeps the heuristic first-message title. |
| `NEXUS_UTILITY_DELAY_MS` | `1500` | Debounce in ms after a turn commit before starting the utility side call. |

## Codemode

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_CODEMODE` | `false` | Registers the `codemode` Lua scripting tool (calls sibling tools and returns one compact result). |
| `NEXUS_CODEMODE_TIMEOUT_MS` | `30000` | Per-script wall-clock deadline in ms (`>= 1000`). |
| `NEXUS_CODEMODE_MAX_OUTPUT_CHARS` | `32768` | Rendered output cap in characters (`>= 0`; head and tail preserved). |

## Plugins & MCP

Plugin and MCP tools never enter the default toolset; attach them via a
bot template's explicit toolset.

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_PLUGINS` | unset | Comma-separated compiled-in plugins to start as tool providers (e.g. `example`). |
| `NEXUS_PLUGIN_TIMEOUT_MS` | `30000` | Per-call wall-clock deadline in ms for plugins (`>= 100`). |
| `NEXUS_PLUGIN_MAX_OUTPUT_CHARS` | `32768` | Output cap in characters for plugin and MCP tool results/errors (`>= 0`). |
| `NEXUS_MCP_SERVERS_JSON` | unset | JSON array of stdio MCP servers: `[{"name","command","args"?,"env"?,"timeout_ms"?}]`. Unreachable servers degrade loudly at boot; frozen thread manifests still hydrate without contacting the server. |

## Workspaces & sandboxing

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_WORKSPACE_ROOT` | unset | Directory under which each workspace-enabled thread gets `<root>/<thread-id>` (created lazily and frozen per thread). When set, `bash`, `read_file`, `write_file`, and `list_dir` join the default toolset; when unset, saving a bot or creating a thread that requests them fails with `400`. |
| `NEXUS_WORKSPACE_SANDBOX` | `none` | OS sandbox backend for local `bash`: `none`, `bwrap` (Linux namespaces, primary), or `nono` (Landlock/Seatbelt). |
| `NEXUS_WORKSPACE_SANDBOX_BIN` | unset | Optional absolute path to `bwrap` or `nono` (requires sandbox `bwrap` or `nono`; unset searches `PATH`). |
| `NEXUS_WORKSPACE_TOOLCHAIN` | unset | Optional absolute path to an immutable toolchain directory (e.g. Nix `pkgs.buildEnv` with `bin/` and `etc/ssl`; requires sandbox `bwrap` or `nono`). |
| `NEXUS_WORKSPACE_STATE_DIR` | unset | Absolute directory for sandbox state/profiles outside `NEXUS_WORKSPACE_ROOT` (required when `NEXUS_WORKSPACE_SANDBOX=nono`). |
| `NEXUS_WORKSPACE_MAX_MEMORY_MB` | `1024` | Per-command memory cap in MiB (`>= 16`) when sandboxed: Linux cgroup v2 `memory.max` when delegated, otherwise `prlimit --as` when available. `prlimit --fsize` (256 MiB) applies on both paths when available. |
| `NEXUS_WORKSPACE_MAX_PIDS` | `64` | Per-command PID cap (`>= 4`) when sandboxed with Linux cgroup v2 delegation (`Delegate=cpu memory pids`). |
| `NEXUS_ENV_TIMEOUT_MS` | `60000` | Per-call wall-clock deadline in ms for `bash` (`>= 1000`; kills process group on Linux). |
| `NEXUS_ENV_MAX_OUTPUT_BYTES` | `262144` | Byte cap on `bash` output and `read_file` reads (`>= 1024`). |

## Remote nodes

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_NODE_IDLE_DAYS` | `7` | Delete node credentials unattended for this many days during the boot sweep (`0` disables the sweep). |
