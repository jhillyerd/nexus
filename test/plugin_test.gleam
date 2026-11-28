//// Plugin SDK + boot tests (plugin-api plan Phase 1): the tier-1
//// actor's guarantees (exactly-one-reply under a crashing call fn,
//// Cancelled kills the worker without wedging the actor), the boot
//// pipeline (empty config = empty table, unknown name = loud error, the
//// example plugin's full-stack round trip through adapter → SDK →
//// tool), and the catalog merge (`tools.by_names_with`). All offline:
//// providers are real SDK actors, never sockets or ports.

import gleam/dict
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit/should
import nexus/config
import nexus/log
import nexus/plugin
import nexus/tool_provider.{
  type Plugin, type ToolDef, Call, Cancelled, Plugin, ToolDef,
}
import nexus/tools

const schema = "{\"type\":\"object\",\"properties\":{}}"

fn def(name: String) -> ToolDef {
  ToolDef(name: name, description: "test " <> name, parameters_json: schema)
}

fn test_config() -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 0,
    ui_token: None,
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_cache_ttl_ms: 600_000,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    max_bot_hops: 4,
    plugins: [],
    plugin_timeout_ms: 2000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    workspace_sandbox: config.SandboxNone,
    workspace_sandbox_bin: None,
    workspace_toolchain: None,
    workspace_state_dir: None,
    workspace_max_memory_mb: 1024,
    workspace_max_pids: 64,
    env_timeout_ms: 60_000,
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    default_context_window: None,
  )
}

fn with_plugins(plugins: List(String)) -> config.Config {
  config.Config(..test_config(), plugins: plugins)
}

// ---------------------------------------------------------------------------
// The SDK actor through the adapter
// ---------------------------------------------------------------------------

fn instant_plugin(
  name: String,
  call: fn(String, String) -> Result(String, String),
) -> Plugin {
  Plugin(name: name, tools: [def("go")], call: call, timeout_ms: None)
}

fn run_go(
  name: process.Name(tool_provider.Msg),
  timeout_ms: Int,
) -> Result(String, String) {
  let cancel = process.new_subject()
  tool_provider.run(name, "go", timeout_ms, 1000, cancel, "{}")
}

pub fn sdk_call_ok_and_err_test() {
  let name = process.new_name("nexus_plugin_sdk_echo")
  let assert Ok(_) =
    plugin.start_named(
      instant_plugin("sdkecho", fn(tool, _args) {
        case tool {
          "go" -> Ok("went")
          other -> Error("unexpected " <> other)
        }
      }),
      name,
    )
  should.equal(run_go(name, 2000), Ok("went"))
}

pub fn sdk_call_err_test() {
  let name = process.new_name("nexus_plugin_sdk_grump")
  let assert Ok(_) =
    plugin.start_named(
      instant_plugin("sdkgrump", fn(_tool, _args) { Error("no") }),
      name,
    )
  should.equal(run_go(name, 2000), Error("no"))
}

/// The exactly-one-reply guarantee under a crashing call fn: the worker
/// dies without reporting, the monitor answers, the ACTOR (linked to
/// this test) survives.
pub fn sdk_crashing_call_is_a_tool_error_test() {
  let name = process.new_name("nexus_plugin_sdk_boom")
  let assert Ok(_) =
    plugin.start_named(
      instant_plugin("sdkboom", fn(_tool, _args) { panic as "kaboom" }),
      name,
    )
  should.equal(run_go(name, 2000), Error("plugin tool crashed"))
  // The actor (linked to this test) survived the worker crash and is
  // not wedged: a second crashing call is answered the same way.
  should.equal(run_go(name, 2000), Error("plugin tool crashed"))
}

/// The boot-time ask against a live SDK actor.
pub fn sdk_list_tools_test() {
  let name = process.new_name("nexus_plugin_sdk_ask")
  let assert Ok(_) =
    plugin.start_named(
      Plugin(
        name: "sdkask",
        tools: [def("a"), def("b")],
        call: fn(_, _) { Ok("") },
        timeout_ms: None,
      ),
      name,
    )
  let assert Ok(defs) = tool_provider.list_tools(name, 2000)
  should.equal(list.map(defs, fn(d) { d.name }), ["a", "b"])
}

/// The provider half of the reserved-separator rule is enforced at BOTH
/// seams: `plugin.validate_provider_name` (boot resolve) and the SDK
/// actor's start (this test's seam) refuse an invalid name before it
/// can mint ambiguous wire names.
pub fn sdk_refuses_invalid_provider_name_test() {
  let bad = instant_plugin("my__plug", fn(_tool, _args) { Ok("never reached") })
  let assert Error(actor.InitFailed(reason)) =
    plugin.start_named(bad, process.new_name("nexus_plugin_bad_name"))
  should.be_true(string.contains(reason, "provider name must match"))
  should.be_true(string.contains(reason, "my__plug"))
  // The other boundary half, directly.
  let assert Error(_) = plugin.validate_provider_name("ex ample")
  let assert Ok(Nil) = plugin.validate_provider_name("example")
}

/// A timeout override that misses the config's floor is refused loudly
/// at both seams — a negative value would otherwise reach Erlang's
/// `after` and crash the per-turn worker with `timeout_value` (a loop
/// error, not a tool error).
pub fn sdk_refuses_timeout_override_below_floor_test() {
  let bad =
    tool_provider.Plugin(
      name: "hasty",
      tools: [def("go")],
      call: fn(_tool, _args) { Ok("never reached") },
      timeout_ms: Some(-1),
    )
  let assert Error(actor.InitFailed(reason)) =
    plugin.start_named(bad, process.new_name("nexus_plugin_bad_timeout"))
  should.be_true(string.contains(reason, "timeout_ms override must be >= 100"))
  // The floor, not just negativity: 50 ms is refused too, 100 passes.
  let assert Error(_) =
    plugin.validate_plugin(tool_provider.Plugin(..bad, timeout_ms: Some(50)))
  let assert Ok(Nil) =
    plugin.validate_plugin(tool_provider.Plugin(..bad, timeout_ms: Some(100)))
}

/// Cancelled kills the in-flight worker (a blocking call must not keep
/// a process alive) and the actor keeps serving afterwards. The test
/// drives the protocol directly so it owns the ref.
pub fn sdk_cancelled_kills_worker_and_stays_live_test() {
  let name = process.new_name("nexus_plugin_sdk_block")
  // The worker announces its OWN pid before blocking, so the test can
  // monitor it: the kill is pinned by the worker's DOWN, which only
  // arrives if Cancelled actually reaped it (an unkilled worker lives
  // out the sleep and never goes down).
  let woke = process.new_subject()
  let assert Ok(_) =
    plugin.start_named(
      instant_plugin("sdkblock", fn(_tool, _args) {
        process.send(woke, process.self())
        // Block "forever": only Cancelled's kill ends this worker.
        process.sleep(30_000)
        Ok("slept")
      }),
      name,
    )
  let subject = process.named_subject(name)
  let ref = reference.new()
  let reply = process.new_subject()
  process.send(subject, Call(ref, "go", "{}", reply))
  let assert Ok(worker) = process.receive(woke, 2000)
  let mon = process.monitor(worker)
  let selector =
    process.new_selector() |> process.select_specific_monitor(mon, fn(d) { d })
  process.send(subject, Cancelled(ref))
  // The kill: the worker's DOWN lands (a test-owned monitor — only the
  // test receives on it, and only the kill can produce it).
  let assert Ok(process.ProcessDown(pid: _, ..)) =
    process.selector_receive(selector, 2000)
  // No reply ever lands for a cancelled call (the adapter already
  // ended it; the transcript carries the cancelled result).
  should.equal(process.receive(reply, 300), Error(Nil))
  // The actor is not wedged by the kill or the dropped tracking: it
  // still answers ListTools promptly (the blocking call fn would never
  // answer a second Call, so the ask is the liveness probe).
  let assert Ok(defs) = tool_provider.list_tools(name, 1000)
  should.equal(list.map(defs, fn(d) { d.name }), ["go"])
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

pub fn boot_empty_config_is_empty_table_test() {
  let assert Ok(table) = plugin.boot(test_config())
  should.equal(dict.size(table), 0)
}

pub fn boot_unknown_plugin_is_loud_test() {
  let assert Error(reason) = plugin.boot(with_plugins(["nope"]))
  should.be_true(string.contains(reason, "unknown plugin"))
  should.be_true(string.contains(reason, "nope"))
}

pub fn boot_duplicate_plugin_is_loud_test() {
  let assert Error(reason) = plugin.boot(with_plugins(["example", "example"]))
  should.be_true(string.contains(reason, "duplicate plugin"))
}

/// The full stack, exactly as production boots it: config-listed
/// plugin → plugin_sup actor → bounded ListTools → validated table
/// entry → the spec's executor (adapter select loop) → SDK worker →
/// the tool.
pub fn boot_example_plugin_full_stack_test() {
  let assert Ok(table) = plugin.boot(with_plugins(["example"]))
  let assert Ok(spec) = dict.get(table, "example__echo")
  should.equal(tools.tool_name(spec), "example__echo")
  let cancel = process.new_subject()
  should.equal(
    spec.run(
      tools.ToolCtx(cancel:, delivery: None, environment: None),
      "{\"text\":\"round trip\"}",
    ),
    Ok("round trip"),
  )
  // Hostile-ish content passes through as plain truncated text.
  should.equal(
    spec.run(
      tools.ToolCtx(cancel:, delivery: None, environment: None),
      "{\"text\":\"<script>alert(1)</script>\"}",
    ),
    Ok("<script>alert(1)</script>"),
  )
}

// ---------------------------------------------------------------------------
// The catalog merge
// ---------------------------------------------------------------------------

fn stub_spec(name: String) -> tools.ToolSpec {
  tools.ToolSpec(
    tool: tools.function_tool(name, "stub", schema),
    run: fn(_ctx, _args) { Ok("stub") },
  )
}

/// Mixed compiled + provider resolution, in list order; unknown names
/// still fail loudly with the offending name.
pub fn by_names_with_merges_catalogs_test() {
  let cfg = test_config()
  let providers =
    dict.from_list([
      #("p__one", stub_spec("p__one")),
      #("p__two", stub_spec("p__two")),
    ])
  let assert Ok(specs) =
    tools.by_names_with(cfg, providers, ["http_fetch", "p__two", "p__one"])
  should.equal(list.map(specs, tools.tool_name), [
    "http_fetch",
    "p__two",
    "p__one",
  ])
  let assert Error(reason) =
    tools.by_names_with(cfg, providers, ["http_fetch", "p__missing"])
  should.equal(reason, "unknown tool name: p__missing")
  // The empty table is exactly `by_names`.
  let assert Ok(compiled_only) =
    tools.by_names_with(cfg, dict.new(), ["web_search"])
  should.equal(list.map(compiled_only, tools.tool_name), ["web_search"])
}

/// Codemode still registers LAST over the full sibling list — provider
/// tools included, so a script can call them like any sibling.
pub fn by_names_with_codemode_last_over_providers_test() {
  let cfg = config.Config(..test_config(), codemode: True)
  let providers = dict.from_list([#("p__one", stub_spec("p__one"))])
  let assert Ok(specs) =
    tools.by_names_with(cfg, providers, ["p__one", "codemode"])
  should.equal(list.map(specs, tools.tool_name), ["p__one", "codemode"])
}

/// The reserved-separator invariant this all rests on: qualified names
/// are disjoint from compiled names by construction.
pub fn compiled_names_have_no_separator_test() {
  list.each(["http_fetch", "web_search", "bot_message", "codemode"], fn(name) {
    should.be_false(string.contains(name, "__"))
  })
  should.be_true(tools.is_compiled_name("codemode"))
  should.be_false(tools.is_compiled_name("example__echo"))
}

/// The SDK answers an unknown tool name with an honest ToolErr — the
/// protocol-level refusal (the catalog path cannot reach it; driving
/// the adapter directly bypasses the catalog on purpose).
pub fn sdk_unknown_tool_reply_is_error_test() {
  let name = process.new_name("nexus_plugin_sdk_unknown")
  let assert Ok(_) =
    plugin.start_named(
      instant_plugin("sdkunknown", fn(tool, _args) { Ok("served " <> tool) }),
      name,
    )
  let cancel = process.new_subject()
  should.equal(
    tool_provider.run(name, "not-a-tool", 2000, 1000, cancel, "{}"),
    Error("unknown plugin tool: not-a-tool"),
  )
}
