//// Offline tests for the phase-1 codemode tool: sandboxed Lua eval, host
//// round-trips against mock tools, budgets, cancellation, and the
//// registry envelope. No network, no database — hosts are plain closures
//// and the engine is pure BEAM (glua/Luerl).

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import nexus/codemode
import nexus/config
import nexus/loop
import nexus/openai
import nexus/timing
import nexus/tools
import nexus/transcript

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

/// Lua's idiomatic multi-returns must not silently lose values: every
/// returned value becomes a trailing output item, in order, rendered
/// like text() (live-agent review amendment — the first cut kept only
/// the first value).
pub fn multi_value_return_renders_every_value_test() {
  let assert Ok(result) = run_code("return 1, 'two', {k = 'v'}")
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["1", "two", "{\"k\":\"v\"}"])
}

/// No-dedup is deliberate (same review): emitting and returning the same
/// value duplicates it — visible and predictable beats harness magic that
/// could eat legitimate repeats. Pinned so the stance cannot regress
/// silently.
pub fn emitted_and_returned_value_duplicates_test() {
  let assert Ok(result) = run_code("text('answer')\nreturn 'answer'")
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["answer", "answer"])
}

/// `nil` returns add no phantom item (an absent return already does not).
pub fn nil_return_adds_no_item_test() {
  let assert Ok(result) = run_code("text('only')\nreturn nil")
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["only"])
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
  let assert Error(result) =
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
  let assert Error(result) =
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
  let assert Error(result) =
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
  let assert Error(result) =
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
  let assert Error(result) =
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
  let assert Error(result) = run_code("local f = load('return 1')\nreturn f()")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "load is sandboxed"))
}

pub fn sandbox_denies_require_test() {
  let assert Error(result) = run_code("require('nope')")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "require is sandboxed"))
}

pub fn sandbox_denies_os_execute_test() {
  let assert Error(result) = run_code("os.execute('echo hi')")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "os.execute is sandboxed"))
}

// ---------------------------------------------------------------------------
// string.gmatch polyfill (Luerl 1.5 ships a badarg stub, rvirding/luerl#150)
// ---------------------------------------------------------------------------

pub fn gmatch_iterates_words_test() {
  let assert Ok(result) =
    run_code(
      "local out = {}"
      <> "\nfor w in ('a b c'):gmatch('%w+') do out[#out + 1] = w end"
      <> "\nreturn table.concat(out, ',')",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["a,b,c"])
}

/// gmatch yields every capture as its own loop variable (whole match
/// only when the pattern has no captures) -- via string.find's extra
/// returns, which carry the captures after the two positions.
pub fn gmatch_yields_captures_test() {
  let assert Ok(result) =
    run_code(
      "local out = {}"
      <> "\nfor k, v in ('k=v x=y'):gmatch('(%w+)=(%w+)') do"
      <> "\n  out[#out + 1] = k .. v"
      <> "\nend"
      <> "\nreturn table.concat(out, ',')",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["kv,xy"])
}

/// Zero-or-more patterns advance one position per empty match, and an
/// empty match landing exactly at the previous match's end is skipped
/// (lstrlib.c's e != lastmatch guard). Real Lua 5.3 yields exactly
/// '', 'b', '' for ('abc'):gmatch('b*') -- and just 'a' for ('a'):gmatch('a*'),
/// with no trailing empty string. Pinned so the polyfill cannot drift.
pub fn gmatch_empty_match_semantics_test() {
  let assert Ok(result) =
    run_code(
      "local out = {}"
      <> "\nfor m in ('abc'):gmatch('b*') do out[#out + 1] = '[' .. m .. ']' end"
      <> "\nfor m in ('a'):gmatch('a*') do out[#out + 1] = m end"
      <> "\nreturn table.concat(out, ',')",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["[],[b],[],a"])
}

/// Position captures must come through too, including the empty match at
/// len+1 (Luerl's own string.match cannot serve the polyfill's yield: it
/// rejects init > len).
pub fn gmatch_position_captures_test() {
  let assert Ok(result) =
    run_code(
      "local out = {}"
      <> "\nfor pos in ('abc'):gmatch('()') do out[#out + 1] = pos end"
      <> "\nreturn table.concat(out, ',')",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["1,2,3,4"])
}

pub fn gmatch_no_match_yields_nothing_test() {
  let assert Ok(result) =
    run_code(
      "local n = 0\nfor _ in ('abc'):gmatch('%d') do n = n + 1 end\nreturn n",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["0"])
}

/// The type guards fail at iterator construction with a named-slot
/// message, and the error is an ordinary catchable Lua error (unlike the
/// stub's echoed-everything badarg the polyfill replaced).
pub fn gmatch_bad_args_raise_catchable_error_test() {
  let assert Ok(result) =
    run_code(
      "local ok, err = pcall(string.gmatch, 123, '%d+')"
      <> "\nreturn tostring(ok) .. ':' .. tostring(err)",
    )
  should.be_true(string.contains(result, "false:"))
  should.be_true(string.contains(result, "bad argument #1 to gmatch"))
}

/// A leading '^' is a LITERAL caret in Lua 5.3's gmatch: gmatch_aux
/// hands the pattern to match() unstripped and match() has no '^' case,
/// so '^%w+' matches a caret followed by word chars -- never an anchor.
/// The polyfill escapes it before find, whose engine would otherwise
/// anchor '^' at every init (luerl match_pat anchors when I =:= 1 and
/// find slices the subject from init).
pub fn gmatch_caret_is_literal_test() {
  let assert Ok(result) =
    run_code(
      "local out = {}"
      <> "\nfor w in ('hello world'):gmatch('^%w+') do out[#out + 1] = w end"
      <> "\nfor w in ('x ^abc'):gmatch('^%w+') do out[#out + 1] = w end"
      <> "\nreturn table.concat(out, ',')",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["^abc"])
}

/// Lua 5.3 has no string.gfind (removed in 5.2; gmatch is the successor)
/// -- nil is the correct value, not a missing export.
pub fn gfind_stays_nil_test() {
  let assert Ok(result) = run_code("return tostring(string.gfind)")
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["nil"])
}

/// A missing pattern errors, as in stock Lua: 5.3, 5.4, and 5.5 all read
/// the pattern with luaL_checklstring -- there is no '.' default in any
/// version (verified against lstrlib.c in each), so gmatch('abc') must
/// keep failing here. Pinned so a lenient default cannot creep in.
pub fn gmatch_missing_pattern_errors_test() {
  let assert Ok(result) =
    run_code(
      "local ok, err = pcall(string.gmatch, 'abc')"
      <> "\nreturn tostring(ok) .. ':' .. tostring(err)",
    )
  should.be_true(string.contains(result, "false:"))
  should.be_true(string.contains(result, "bad argument #2 to gmatch"))
}

// ---------------------------------------------------------------------------
// Unknown tools
// ---------------------------------------------------------------------------

pub fn unknown_tool_errors_test() {
  let assert Error(result) = run_code("return tools.no_such_tool({})")
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
// Issue #53: separators are budgeted against the output cap
// ---------------------------------------------------------------------------

/// The renderer joins output items with a blank line and console lines
/// with a newline — joins that are part of the rendered output, so the
/// accumulator budgets them with their segments. The issue's repro:
/// 32,768 one-character items at the default cap used to render ~98k
/// chars (~3x cap) before status metadata.
pub fn item_separator_flood_stays_within_cap_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument("for i = 1, 32768 do text('x') end"),
    )
  // Status line, omission note, and the joins around them add ~100
  // chars of metadata on top of the budgeted body (pre-fix: ~98k).
  should.be_true(string.length(result) < default_cap + 200)
  // Deterministic accounting: halves keep 5461 items each (charge 3
  // apiece at half-cap 16384), so 21846 one-char items are omitted.
  // A larger count would mean phantom separator units are over-evicting
  // the tail (cubic review on PR #56).
  should.be_true(string.contains(result, "21846 chars omitted"))
}

/// Console lines join with a single newline; the same bound applies.
/// 1000 one-character prints at cap 100: each line charges 2 (text +
/// separator), so the halves keep ~25 lines each and the console body
/// renders ~50 lines + separators ≈ under the cap (pre-fix: ~2x).
pub fn console_separator_flood_stays_within_cap_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 100,
      cancel: process.new_subject(),
      arguments: code_argument("for i = 1, 1000 do print('y') end"),
    )
  // Console body ≤ cap; status line and <console_output> tags wrap it.
  should.be_true(string.length(result) < 250)
  // Halves keep 25 lines each (charge 2 apiece at half-cap 50): exactly
  // 950 omitted, pinning charge-unit eviction for console sections.
  should.be_true(string.contains(result, "950 chars omitted"))
}

/// Eviction must spend real budget, not phantom separator units: the
/// buggy counter (subtracting only an evicted segment's text) keeps
/// separator units behind after every eviction, so sustained
/// one-character console spam first erodes the tail to nothing and then
/// inflates the counter past the half-cap with an empty queue — after
/// which EVERY later segment (the final item included) is pushed and
/// instantly evicted. ~50 tail pushes are needed to drain it, so the
/// script spams 100 and then emits a large final item.
pub fn spam_then_final_item_survives_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 100,
      cancel: process.new_subject(),
      arguments: code_argument(
        "for i = 1, 100 do print('x') end\nreturn 'END-OF-SCRIPT'",
      ),
    )
  should.be_true(string.contains(result, "END-OF-SCRIPT"))
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
  let assert Error(result) =
    run_registered(specs, "return type(tools.codemode)")
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
  spec.run(
    tools.ToolCtx(cancel: process.new_subject(), delivery: None),
    code_argument(code),
  )
}

/// The registry's schema names, in order — through the spec list so the
/// Dynamic parameter payloads stay out of the comparison while order and
/// membership are still asserted exactly.
fn spec_names(specs: List(tools.ToolSpec)) -> List(String) {
  list.map(specs, tools.tool_name)
}

// ---------------------------------------------------------------------------
// Review fixes (cubic findings on PR #50)
// ---------------------------------------------------------------------------

/// The cancel subject is one-shot: a Stop that lands mid-script is
/// consumed by codemode's select loop, so codemode must re-signal it —
/// otherwise the agent loop issues the next model request on an empty
/// subject and the turn keeps running after the user pressed Stop.
pub fn stop_during_script_stops_the_turn_test() {
  let cancel = process.new_subject()
  let hosts = [
    codemode.HostTool(name: "cancel_now", call: fn(_) {
      process.send(cancel, Nil)
      Ok("ok")
    }),
  ]
  let spec =
    tools.ToolSpec(tool: codemode.schema(), run: fn(ctx, arguments) {
      codemode.run(hosts, 5000, 32_768, ctx.cancel, arguments)
    })
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("run a script")
  let stats =
    openai.StreamStats(
      ttft_ms: Some(10),
      duration_ms: 100,
      token_deltas: 1,
      reasoning_deltas: 0,
      tool_call_deltas: 1,
      events_parsed: 3,
      decode_errors: 0,
      saw_done: True,
      usage: None,
    )
  let stream = fn(_tr, _opts, on_event, stream_cancel) {
    case take_index() {
      0 -> {
        // Round 1: the model calls codemode; the script cancels the turn
        // from inside a host call.
        on_event(openai.TokenDelta("running script"))
        on_event(openai.ToolCallDelta(
          0,
          Some("c1"),
          Some("codemode"),
          code_argument("tools.cancel_now({})"),
        ))
        openai.Completed(stats)
      }
      _ ->
        // Round 2: the turn's cancel subject must still carry the Stop —
        // codemode consumed it to kill the script, so it re-signals.
        case process.receive(stream_cancel, 500) {
          Ok(Nil) -> openai.Cancelled
          Error(Nil) ->
            openai.Failed(openai.Transport("cancel was not re-signalled"))
        }
    }
  }
  let _ = reset_index()
  let outcome = loop.run([spec], 8, stream, tr, cancel, None, fn(_) { Nil })
  case outcome {
    loop.LoopStopped(_) -> Nil
    loop.LoopFailed(reason) ->
      panic as { "expected LoopStopped, got LoopFailed: " <> reason }
    _ -> panic as "expected LoopStopped"
  }
}

@external(erlang, "nexus_loop_test_ffi", "next_index")
fn take_index() -> Int

@external(erlang, "nexus_loop_test_ffi", "reset_index")
fn reset_index() -> Nil

/// The output cap counts CHARACTERS (codepoints), not UTF-8 bytes: 10
/// CJK codepoints are 30 bytes and would be truncated under a byte
/// budget.
pub fn output_cap_counts_characters_not_bytes_test() {
  // 10 hiragana codepoints = 30 UTF-8 bytes, assembled with string.char
  // because Luerl's tokenizer rejects non-ASCII literals in source (host
  // -returned unicode is unaffected: it is never tokenized).
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 20,
      cancel: process.new_subject(),
      arguments: code_argument(
        "text(string.char(227, 129, 130, 227, 129, 132, 227, 129, 134, "
        <> "227, 129, 136, 227, 129, 138, 227, 129, 139, 227, 129, 141, "
        <> "227, 129, 143, 227, 129, 145, 227, 129, 147))",
      ),
    )
  // A byte budget (20) would truncate these 30 bytes; a character budget
  // keeps all 10 codepoints.
  should.be_true(string.contains(result, "あいうえおかきくけこ"))
  should.be_false(string.contains(result, "omitted"))
}

/// Empty text()/print() events carry nothing and must not be retained:
/// at size zero they would always fit the head and grow it unboundedly
/// under the cap.
pub fn empty_segments_are_not_retained_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 100,
      cancel: process.new_subject(),
      arguments: code_argument(
        "for i = 1, 10000 do text('') print('') end\nreturn 'ok'",
      ),
    )
  let parts = string.split(result, "\n\n")
  // Only the return item survives; ten thousand empty segments left no
  // trace (pre-fix this rendered 10000 empty items).
  should.equal(list.drop(parts, 1), ["ok"])
}

/// A sibling host that CRASHES (rather than returning an error) takes
/// the engine process down with it; the worker survives and reports a
/// crash — not out of memory.
pub fn engine_crash_reported_as_crash_test() {
  let hosts = [
    codemode.HostTool(name: "explode", call: fn(_) { panic as "host crash" }),
  ]
  let assert Error(result) =
    codemode.run(
      hosts: hosts,
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument("tools.explode({})"),
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "engine crashed"))
  should.be_false(string.contains(result, "out of memory"))
}

/// Retained Lua strings are refc binaries, so the engine's memory
/// ceiling must count them: `include_shared_binaries` is the only
/// max_heap_size flag that does on OTP 27–29 (`include_offheap` alone
/// lets ~1 GB of live binaries through on all three — verified
/// empirically). The script below retains ~200 MB across the loop; the
/// reaper must kill the engine long before it finishes.
pub fn string_rep_retention_killed_by_max_heap_test() {
  let assert Error(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument(
        "local t = {}\n"
        <> "for i = 1, 50 do\n"
        <> "  t[i] = string.rep('x', 4000000)\n"
        <> "end\n"
        <> "return #t",
      ),
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "out of memory"))
}

/// Once a segment overflows to the tail, the head is sealed: a later
/// segment that merely *fits* the head budget must still go to the tail,
/// or items render out of arrival order with no omission hint.
/// (cap 40, half 20: items of 15 then 10 overflow; a trailing 5 must
/// not sneak back into the head between them.)
pub fn head_sealed_once_tail_starts_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 40,
      cancel: process.new_subject(),
      arguments: code_argument(
        "text(string.rep('a', 15))\n"
        <> "text(string.rep('b', 10))\n"
        <> "text(string.rep('c', 5))",
      ),
    )
  // All three items, in arrival order, nothing dropped.
  let first = string.contains(result, "aaaaaaaaaaaaaaa\n\nbbbbbbbbbb\n\nccccc")
  should.be_true(first)
  should.be_false(string.contains(result, "omitted"))
}

/// A single output item larger than the tail budget must not be
/// discarded wholesale (marker-only output for a big host result):
/// it is front-truncated to the budget and the remainder is counted
/// among the omitted chars.
pub fn oversized_item_keeps_its_head_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 40,
      cancel: process.new_subject(),
      arguments: code_argument("return string.rep('a', 25)"),
    )
  // First 20 of the 25 chars kept, remainder accounted as omitted.
  should.be_true(string.contains(result, "aaaaaaaaaaaaaaaaaaaa"))
  should.be_true(string.contains(result, "5 chars omitted"))
}

/// Mixed tables (array part plus named fields) must encode as objects
/// with every field present — not take the array branch and silently
/// drop the named ones.
pub fn mixed_table_encodes_as_object_test() {
  let assert Ok(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument("return {'first', status = 'ok'}"),
    )
  should.be_true(string.contains(result, "\"1\":\"first\""))
  should.be_true(string.contains(result, "\"status\":\"ok\""))
}

/// Degenerate cap handling (cubic review): cap 1 must truncate to one
/// kept character rather than erasing every nonempty segment (cap/2
/// rounds to zero), and cap 0 keeps its suppress-everything meaning.
pub fn tiny_cap_truncates_instead_of_erasing_test() {
  let assert Ok(one) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 1,
      cancel: process.new_subject(),
      arguments: code_argument("text('abc')"),
    )
  // Exactly one character survives, the rest accounted as omitted.
  should.be_true(string.contains(one, "a"))
  should.be_true(string.contains(one, "2 chars omitted"))

  let assert Ok(zero) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: default_timeout_ms,
      max_output_chars: 0,
      cancel: process.new_subject(),
      arguments: code_argument("text('abc')"),
    )
  should.be_false(string.contains(zero, "abc"))
  should.be_true(string.contains(zero, "3 chars omitted"))
}

/// An event-spamming script (fast producer, ack'd every event) must
/// still die at the wall-clock deadline: once the deadline passes the
/// worker stops draining stream events even when one is always queued
/// (a queued message wins the mailbox race over a fired timeout).
pub fn event_spam_script_dies_at_deadline_test() {
  let assert Error(result) =
    codemode.run(
      hosts: mock_hosts(),
      timeout_ms: 1000,
      max_output_chars: default_cap,
      cancel: process.new_subject(),
      arguments: code_argument("while true do print('spam') end"),
    )
  should.be_true(string.contains(result, "timeout"))
}

// ---------------------------------------------------------------------------
// Phase 2: tools.call_all — parallel batch (allSettled)
// ---------------------------------------------------------------------------

/// Monitor a pid and assert it reports DOWN within 1 s — proves batch
/// children never outlive the engine (killed as stragglers on the happy
/// path, reaped through the link on every death path).
fn assert_down(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(pid: _pid, ..)) =
    process.selector_receive(selector, 1000)
  Nil
}

/// One array, input order — not completion order.
pub fn call_all_returns_results_in_input_order_test() {
  let assert Ok(result) =
    run_code(
      "local rs = tools.call_all({"
      <> "{name = 'echo', args = {i = 3}},"
      <> "{name = 'echo', args = {i = 1}},"
      <> "{name = 'echo', args = {i = 2}}})"
      <> "\nreturn rs[1].result .. '|' .. rs[2].result .. '|' .. rs[3].result",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), [
    "echo:{\"i\":3}|echo:{\"i\":1}|echo:{\"i\":2}",
  ])
}

/// Each entry carries its own ok flag and payload; a failing entry's
/// error text rides the value.
pub fn call_all_entries_carry_ok_flags_test() {
  let assert Ok(result) =
    run_code(
      "local rs = tools.call_all({{name = 'boom'}, {name = 'echo', args = {}}})"
      <> "\nreturn tostring(rs[1].ok) .. tostring(rs[2].ok) .. rs[2].result"
      <> " .. '|' .. rs[1].error",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["falsetrueecho:{}|boom tool failed"])
}

/// A CRASHING entry is an error value, not an engine death (contrast
/// engine_crash_reported_as_crash_test, the sync path) — one failure
/// never aborts the batch.
pub fn call_all_crashing_entry_is_an_error_value_test() {
  let hosts = [
    echo_host(),
    codemode.HostTool(name: "explode", call: fn(_) {
      panic as "batch child crash"
    }),
  ]
  let assert Ok(result) =
    codemode.run(
      hosts,
      default_timeout_ms,
      default_cap,
      process.new_subject(),
      code_argument(
        "local rs = tools.call_all({{name = 'explode'}, {name = 'echo'}})"
        <> "\ntext(tostring(rs[1].ok))"
        <> "\nreturn rs[2].result .. ' / ' .. rs[1].error",
      ),
    )
  should.be_true(string.contains(result, "Script completed ("))
  should.be_true(string.contains(result, "false"))
  should.be_true(string.contains(result, "echo:{}"))
  should.be_true(string.contains(result, "host crashed"))
}

/// Three 400 ms calls finish in ~1x the single-call wall time, not 3x:
/// the entries genuinely overlap. Generous margin for CI scheduling.
pub fn call_all_overlaps_wall_time_test() {
  let hosts = [
    codemode.HostTool(name: "slow", call: fn(_) {
      process.sleep(400)
      Ok("s")
    }),
  ]
  let started_us = timing.now_us()
  let assert Ok(result) =
    codemode.run(
      hosts,
      default_timeout_ms,
      default_cap,
      process.new_subject(),
      code_argument(
        "local rs = tools.call_all({"
        <> "{name = 'slow'}, {name = 'slow'}, {name = 'slow'}})"
        <> "\nreturn #rs",
      ),
    )
  let wall_ms = { timing.now_us() - started_us } / 1000
  should.be_true(string.contains(result, "3"))
  should.be_true(wall_ms < 900)
}

/// The batch's internal deadline (script deadline less the wrap-up
/// margin) expires while the slow entry is in flight: call_all returns
/// the partial list, the script folds and finishes BEFORE the worker's
/// wall-clock kill — the run completes carrying the fold.
pub fn call_all_deadline_returns_partial_list_test() {
  let pids = process.new_subject()
  let hosts = [
    echo_host(),
    codemode.HostTool(name: "slow", call: fn(_) {
      process.send(pids, process.self())
      process.sleep(10_000)
      Ok("late")
    }),
  ]
  let assert Ok(result) =
    codemode.run(
      hosts,
      2000,
      default_cap,
      process.new_subject(),
      code_argument(
        "text('partial')"
        <> "\nlocal rs = tools.call_all({{name = 'echo'}, {name = 'slow'}})"
        <> "\nreturn rs[1].result .. ' / ' .. tostring(rs[2].error)",
      ),
    )
  should.be_true(string.contains(result, "Script completed ("))
  should.be_true(string.contains(result, "partial"))
  should.be_true(string.contains(result, "echo:{}"))
  should.be_true(string.contains(result, "deadline exceeded"))
  should.be_false(string.contains(result, "late"))
  let assert Ok(child) = process.receive(pids, within: 1000)
  assert_down(child)
}

/// A Stop during an in-flight batch kills the engine; the link reaps
/// the child. Partial output before the batch is preserved.
pub fn cancel_during_call_all_test() {
  let cancel = process.new_subject()
  let pids = process.new_subject()
  let hosts = [
    codemode.HostTool(name: "cancel_slow", call: fn(_) {
      process.send(pids, process.self())
      process.send(cancel, Nil)
      process.sleep(10_000)
      Ok("late")
    }),
  ]
  let assert Error(result) =
    codemode.run(
      hosts,
      default_timeout_ms,
      default_cap,
      cancel,
      code_argument("text('partial')\ntools.call_all({{name = 'cancel_slow'}})"),
    )
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "cancelled"))
  should.be_true(string.contains(result, "partial"))
  let assert Ok(child) = process.receive(pids, within: 1000)
  assert_down(child)
}

/// Every entry counts against the per-script budget, checked before
/// anything spawns.
pub fn call_all_budget_counts_every_entry_test() {
  let assert Error(result) =
    run_code(
      "local batch = {}\nfor i = 1, 26 do batch[i] = {name = 'echo'} end\n"
      <> "tools.call_all(batch)\nreturn 'unreachable'",
    )
  should.be_true(string.contains(result, "tool call budget exceeded (25 calls)"))
}

/// The budget is one shared counter: sync calls and batch entries draw
/// down the same 25.
pub fn call_all_budget_is_shared_with_sync_calls_test() {
  let assert Error(result) =
    run_code(
      "for i = 1, 20 do tools.echo({}) end\n"
      <> "local batch = {}\nfor i = 1, 6 do batch[i] = {name = 'echo'} end\n"
      <> "tools.call_all(batch)\nreturn 'unreachable'",
    )
  should.be_true(string.contains(result, "tool call budget exceeded (25 calls)"))
}

/// An unknown tool name is a per-entry value, not a script failure.
pub fn call_all_unknown_tool_is_a_value_test() {
  let assert Ok(result) =
    run_code(
      "local rs = tools.call_all({{name = 'nope'}, {name = 'echo'}})"
      <> "\nreturn tostring(rs[2].ok) .. '|' .. rs[1].error",
    )
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["true|unknown tool: nope"])
}

/// Malformed batches are script errors, like a malformed sync call.
pub fn call_all_malformed_entries_fail_the_script_test() {
  let assert Error(missing) =
    run_code("tools.call_all({{args = {}}})\nreturn 'unreachable'")
  should.be_true(string.contains(missing, "call_all entry missing name"))
  let assert Error(scalar) = run_code("tools.call_all({'echo'})")
  should.be_true(string.contains(scalar, "call_all entry must be a table"))
  let assert Error(not_table) = run_code("tools.call_all('nope')")
  should.be_true(string.contains(not_table, "call_all wants a table of entries"))
}

/// An empty batch is a no-op that never touches the budget.
pub fn call_all_empty_batch_is_empty_test() {
  let assert Ok(result) = run_code("return #tools.call_all({})")
  let parts = string.split(result, "\n\n")
  should.equal(list.drop(parts, 1), ["0"])
}

/// Over-budget batches fail EVEN on the deadline short-circuit path: the
/// batch is charged before remaining-time is considered, so a
/// near-deadline script cannot keep issuing uncounted batches (cubic
/// review — deadline-exceeded entries still draw budget).
///
/// Race-free by arithmetic (cubic follow-up: an earlier cut slept 980 ms
/// of a 1 s deadline, but `process.sleep` can overshoot arbitrarily —
/// past the kill — on a loaded CI box). Instead: no sleep at all. With
/// timeout 55 ms and nominal engine startup ~20 ms, call_all is entered
/// with ~35 ms remaining — inside the 50 ms wrap-up margin, i.e. ON the
/// deadline path — while the budget error's Done still lands ~35 ms
/// ahead of the worker's kill. There is no wake-up to overshoot; the
/// only way this can time out is engine startup alone exceeding 55 ms
/// (>2.5x nominal, well past what the suite's other timing tests
/// tolerate). And post-fix the assertion holds on EITHER path, since
/// the budget check now runs before the remaining-time branch.
pub fn call_all_budget_charged_on_deadline_path_test() {
  let assert Error(result) =
    codemode.run(
      [echo_host()],
      55,
      default_cap,
      process.new_subject(),
      code_argument(
        "local batch = {}\nfor i = 1, 26 do batch[i] = {name = 'echo'} end\n"
        <> "tools.call_all(batch)\nreturn 'unreachable'",
      ),
    )
  should.be_true(string.contains(result, "tool call budget exceeded (25 calls)"))
}

/// Sparse batches (holes, or non-1..n keys) are rejected instead of
/// silently dropping entries after the hole — dropped entries would
/// dodge both the calls and the budget accounting (cubic review).
pub fn call_all_rejects_sparse_batches_test() {
  let assert Error(hole) =
    run_code("tools.call_all({{name = 'echo'}, [3] = {name = 'echo'}})")
  should.be_true(string.contains(hole, "dense 1-based array"))
  let assert Error(named) =
    run_code("tools.call_all({{name = 'echo'}, extra = 1})")
  should.be_true(string.contains(named, "dense 1-based array"))
  // A dense array is still fine.
  let assert Ok(dense) =
    run_code(
      "local rs = tools.call_all({{name = 'echo'}, {name = 'echo'}})"
      <> "\nreturn #rs",
    )
  let parts = string.split(dense, "\n\n")
  should.equal(list.drop(parts, 1), ["2"])
}

/// A host crashing with a pathological reason must not blow up the
/// child: the crash term is bounded BEFORE formatting, so the error
/// value stays small no matter how large the reason (cubic review).
pub fn crash_reason_is_bounded_test() {
  let hosts = [
    codemode.HostTool(name: "wibble", call: fn(_) {
      panic as string.repeat("x", 200_000)
    }),
  ]
  let assert Ok(result) =
    codemode.run(
      hosts,
      default_timeout_ms,
      default_cap,
      process.new_subject(),
      code_argument(
        "local rs = tools.call_all({{name = 'wibble'}})\nreturn rs[1].error",
      ),
    )
  should.be_true(string.contains(result, "host crashed"))
  should.be_true(string.length(result) < 1000)
}

/// A Lua runtime TYPE error (glua's formatter crashes on badarg/
/// badarith — format_lua_value returns IO data that string.join
/// rejects) must stay a script failure with a readable reason, not take
/// the engine down as "engine crashed". Found by the phase-2 tests;
/// reachable since phase 1 (`return 'a' .. true`).
pub fn script_type_error_reports_lua_error_not_crash_test() {
  let assert Error(result) = run_code("return 'a' .. true")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_false(string.contains(result, "engine crashed"))
  should.be_true(string.contains(result, "bad argument"))
}

/// The wire description documents call_all (the model's only manual).
pub fn call_all_is_documented_in_the_description_test() {
  let chat.FunctionTool(function: f) = codemode.schema()
  let assert Some(text) = f.description
  should.be_true(string.contains(text, "call_all"))
  should.be_true(string.contains(text, "parallel"))
}
