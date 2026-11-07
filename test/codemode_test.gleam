//// Offline tests for the phase-1 codemode tool: sandboxed Lua eval, host
//// round-trips against mock tools, budgets, cancellation, and the
//// registry envelope. No network, no database — hosts are plain closures
//// and the engine is pure BEAM (glua/Luerl).

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import nexus/codemode
import nexus/config
import nexus/tools

const default_timeout_ms = 5000

const default_cap = 32_768

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A deterministic echo host: returns its raw JSON arguments verbatim.
fn echo_host() -> codemode.HostTool {
  codemode.HostTool(name: "echo", call: fn(arguments) {
    Ok("echo:" <> arguments)
  })
}

/// A host that always fails, carrying error text through.
fn failing_host() -> codemode.HostTool {
  codemode.HostTool(name: "boom", call: fn(_) { Error("boom tool failed") })
}

fn mock_hosts() -> List(codemode.HostTool) {
  [echo_host(), failing_host()]
}

/// Run one script against the mock hosts in this (test) process — exactly
/// the process model of the real per-turn worker.
fn run_code(code: String) -> Result(String, String) {
  codemode.run(
    hosts: mock_hosts(),
    timeout_ms: default_timeout_ms,
    max_output_chars: default_cap,
    cancel: process.new_subject(),
    arguments: json.object([#("code", json.string(code))]) |> json.to_string,
  )
}

fn code_argument(code: String) -> String {
  json.object([#("code", json.string(code))]) |> json.to_string
}

fn base_config() -> config.Config {
  let assert Ok(cfg) =
    config.from_env(fn(name) {
      case name {
        "NEXUS_ENCRYPTION_KEY" ->
          Ok("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
        _ -> Error(Nil)
      }
    })
  cfg
}

// ---------------------------------------------------------------------------
// Lua eval and host round-trips
// ---------------------------------------------------------------------------

pub fn completes_with_output_items_test() {
  let assert Ok(result) =
    run_code("local r = tools.echo({code = 'hi'})\ntext(r)\nreturn 'done'")
  should.be_true(string.contains(result, "Script completed ("))
  should.be_true(string.contains(result, " ms)"))
  // The args table round-tripped to sorted JSON and back as content.
  should.be_true(string.contains(result, "echo:{\"code\":\"hi\"}"))
  // Items in order: the text() item, then the final return value.
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["echo:{\"code\":\"hi\"}", "done"])
}

pub fn final_return_table_rendered_as_json_test() {
  let assert Ok(result) = run_code("text({b = 2, a = 'x'})\nreturn {1, true}")
  // Object keys sorted, arrays positional.
  should.be_true(string.contains(result, "{\"a\":\"x\",\"b\":2}"))
  should.be_true(string.contains(result, "[1,true]"))
}

pub fn print_overridden_to_console_block_test() {
  let assert Ok(result) = run_code("print('a', 1, true)\nprint('line two')")
  should.be_true(string.contains(result, "<console_output>"))
  should.be_true(string.contains(result, "a\t1\ttrue\nline two"))
  should.be_true(string.contains(result, "</console_output>"))
  // And the console block renders after the (empty) items.
  should.be_true(string.ends_with(
    result,
    "\n\n<console_output>\na\t1\ttrue\nline two\n</console_output>",
  ))
}

pub fn tool_error_aborts_script_with_reason_test() {
  let assert Ok(result) =
    run_code("text('before')\ntools.boom({})\ntext('after')")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "before"))
  should.be_false(string.contains(result, "after"))
  should.be_true(string.contains(result, "Script error:"))
  // The tool's error text is carried into the Lua error.
  should.be_true(string.contains(result, "boom tool failed"))
}

// ---------------------------------------------------------------------------
// Hostile text
// ---------------------------------------------------------------------------

/// Everything a script emits is inert data: the payload strings pass
/// through verbatim (the UI renders them as Lustre text nodes).
pub fn hostile_output_is_inert_test() {
  let assert Ok(result) =
    run_code(
      "text('<script>alert(1)</script>')\nprint('<img src=x onerror=1>')\nreturn '</style>'",
    )
  should.be_true(string.contains(result, "<script>alert(1)</script>"))
  should.be_true(string.contains(result, "<img src=x onerror=1>"))
  should.be_true(string.contains(result, "</style>"))
}

// ---------------------------------------------------------------------------
// Deadline
// ---------------------------------------------------------------------------

pub fn infinite_loop_killed_at_deadline_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: 1000,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument("text('before')\nwhile true do end"),
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "Script error: timeout"))
  should.be_true(string.contains(result, "before"))
}

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

/// A host call that cancels the turn from inside the script: the worker's
/// select sees the cancel subject fire mid-run, kills the engine, and
/// keeps the partial output.
pub fn mid_script_cancellation_test() {
  let cancel = process.new_subject()
  let hosts = [
    echo_host(),
    codemode.HostTool(name: "cancel_now", call: fn(_) {
      process.send(cancel, Nil)
      Ok("cancelling")
    }),
  ]
  let assert Ok(result) =
    codemode.run(
      hosts: hosts,
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: cancel,
      arguments: code_argument(
        "text('partial')\ntools.cancel_now({})\nwhile true do end",
      ),
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "Script error: cancelled"))
  should.be_true(string.contains(result, "partial"))
}

/// The seam's raison d'être: a Stop that lands while the engine is
/// BLOCKED inside a slow host tool call (previously unreachable — the
/// cancel subject only fed the streaming seam) must still kill the run.
pub fn cancel_during_slow_host_call_test() {
  let cancel = process.new_subject()
  let hosts = [
    codemode.HostTool(name: "slow", call: fn(_) {
      process.send(cancel, Nil)
      process.sleep(10_000)
      Ok("finally")
    }),
  ]
  let assert Ok(result) =
    codemode.run(
      hosts: hosts,
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: cancel,
      arguments: code_argument(
        "text('partial')\nlocal r = tools.slow({})\ntext(r)",
      ),
    )
  // The engine died mid-call (never reached the second text), and the
  // run reports cancellation — not the 5 s deadline nor success.
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "Script error: cancelled"))
  should.be_true(string.contains(result, "partial"))
  should.be_false(string.contains(result, "finally"))
}

// ---------------------------------------------------------------------------
// Tool-call budget
// ---------------------------------------------------------------------------

pub fn tool_call_budget_exceeded_test() {
  let assert Ok(result) =
    run_code(
      "local n = 0\nfor i = 1, 100 do\n  n = n + 1\n  tools.echo({i = i})\nend\nreturn 'ran ' .. n",
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "tool call budget exceeded (25 calls)"))
}

// ---------------------------------------------------------------------------
// Sandbox
// ---------------------------------------------------------------------------

pub fn sandbox_denies_load_test() {
  let assert Ok(result) = run_code("local f = load('return 1')\nreturn f()")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "load is sandboxed"))
}

pub fn sandbox_denies_require_test() {
  let assert Ok(result) = run_code("require('nope')")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "require is sandboxed"))
}

pub fn sandbox_denies_os_execute_test() {
  let assert Ok(result) = run_code("os.execute('echo hi')")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "os.execute is sandboxed"))
}

// ---------------------------------------------------------------------------
// Unknown tools
// ---------------------------------------------------------------------------

pub fn unknown_tool_errors_test() {
  let assert Ok(result) = run_code("return tools.no_such_tool({})")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "unknown tool: no_such_tool"))
}

pub fn missing_code_argument_is_a_tool_error_test() {
  let assert Error(reason) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: "{}",
    )
  should.be_true(string.contains(reason, "code"))
}

// ---------------------------------------------------------------------------
// Output truncation
// ---------------------------------------------------------------------------

pub fn output_truncated_head_and_tail_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 40,
      cancel: process.new_subject(),
      arguments: code_argument(
        "text('aaaaaaaaaaaaaaa')"
        <> "\ntext('bbbbbbbbbbbbbbb')"
        <> "\ntext('ccccccccccccccc')",
      ),
    )
  // 15+15 chars fit the head/tail halves; the middle 15 are dropped and
  // noted. (cap 40 -> half 20: head keeps 15, the second overflows to the
  // tail, the third evicts the second.)
  should.be_true(string.contains(result, "aaaaaaaaaaaaaaa"))
  should.be_true(string.contains(result, "ccccccccccccccc"))
  should.be_false(string.contains(result, "bbbbbbbbbbbbbbb"))
  should.be_true(string.contains(result, "15 chars omitted"))
}

// ---------------------------------------------------------------------------
// Registry envelope (KV-cache contract rule 4)
// ---------------------------------------------------------------------------

/// With the flag off, the registry is exactly the pre-codemode schema
/// list — the frozen envelope is unchanged until codemode is enabled.
pub fn registry_unchanged_with_flag_off_test() {
  let names = tools.default(base_config()) |> spec_names
  should.equal(names, ["http_fetch"])
}

pub fn registry_appends_codemode_when_enabled_test() {
  let cfg =
    config.Config(
      ..base_config(),
      codemode: True,
      searxng_base_url: Some("https://searx.example"),
    )
  let names = tools.default(cfg) |> spec_names
  should.equal(names, ["http_fetch", "web_search", "codemode"])
}

/// codemode is structurally absent from its own host list: the captured
/// siblings never contain it, so touching `tools.codemode` raises the
/// unknown-tool error instead of recursing.
pub fn codemode_absent_from_own_tools_table_test() {
  let cfg = config.Config(..base_config(), codemode: True)
  let specs = tools.default(cfg)
  let assert Ok(result) = run_registered(specs, "return type(tools.codemode)")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "unknown tool: codemode"))
}

/// Run the REGISTERED codemode spec (built by tools.default) rather than
/// hand-built hosts — exercises the registry bridge.
fn run_registered(
  specs: List(tools.ToolSpec),
  code: String,
) -> Result(String, String) {
  let assert Ok(spec) =
    list.find(specs, fn(spec) { tools.tool_name(spec) == "codemode" })
  spec.run(tools.ToolCtx(cancel: process.new_subject()), code_argument(code))
}

/// The registry's schema names, in order — through the spec list so the
/// Dynamic parameter payloads stay out of the comparison while order and
/// membership are still asserted exactly.
fn spec_names(specs: List(tools.ToolSpec)) -> List(String) {
  list.map(specs, tools.tool_name)
}
