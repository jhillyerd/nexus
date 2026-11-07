//// The codemode tool (phase 1 of the codemode plan): the model authors a
//// Lua 5.3 script; the script calls nexus's sibling tools through a host
//// API, digests the results, and returns one compact tool result — N tool
//// round-trips collapse into one model turn.
////
//// Process model: `run` executes in the per-turn worker. It spawns a
//// dedicated engine child (linked, so turn teardown and worker death reap
//// it) that builds a sandboxed glua/Luerl VM and evaluates the script.
//// `text()`/`print()` events stream to the worker as they happen, so
//// partial output survives every failure mode. The worker blocks in a
//// select over `{engine reply, turn cancel subject, wall-clock deadline,
//// engine exit}` — cancel, timeout, and engine death (out of memory,
//// crash) all end the run and keep the partial output. The worker traps
//// exits for the duration (the engine is its only link) and consumes the
//// engine's exit message BEFORE restoring the flag, or the delayed
//// `killed` signal would take the worker down after the run.
////
//// This module is deliberately a leaf — it must not import
//// `nexus/tools`: the registry (`tools.default`) builds the host list
//// from the sibling specs and appends the codemode tool itself, so
//// codemode is structurally absent from its own `tools` table (recursion
//// guard) and the schema list stays frozen per boot (KV-cache contract
//// rule 4).
////
//// Bounds (all documented in the tool description):
//// - wall-clock deadline (config, default 30 s; kill, not preemption),
//// - output cap (config; head and tail kept, omission noted),
//// - tool-call budget (constant, 25 calls — bounds retained host results,
////   each already truncated by its own tool's limits),
//// - engine heap ceiling (`max_heap_size`, ~64 MiB in words — bounds the
////   pure-Lua allocation the call budget cannot see).

import gleam/dynamic/decode
import gleam/erlang/process.{type ExitMessage, type Subject, ExitMessage}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glopenai/chat
import glopenai/shared.{FunctionObject}
import glua
import glua/lib
import nexus/timing

/// Per-script tool-call budget: exceeding it fails the script. Bounds
/// retained host results at budget x per-tool truncation size.
const tool_call_budget = 25

/// Engine heap ceiling: ~64 MiB counted in 8-byte words. Exceeding it
/// kills the engine (reason `killed`), reported as `out of memory`.
const max_heap_words = 8_388_608

/// A failed script's reason line is capped so a Lua stacktrace can never
/// blow past the output budget from the error path alone.
const max_reason_chars = 2000

// ---------------------------------------------------------------------------
// Tool surface
// ---------------------------------------------------------------------------

const description =
  "Run a Lua 5.3 script that calls this assistant's other tools and "
  <> "combines their results into one answer. In the script: "
  <> "tools.<name>(args) calls a sibling tool synchronously (args is a "
  <> "Lua table shaped like that tool's JSON schema; returns its result "
  <> "text, or aborts the script with the tool's error); text(value) "
  <> "appends an output item (strings as-is, other values as JSON); "
  <> "print(...) appends console lines; the script's final return value "
  <> "becomes the last output item. Sandboxed Lua only: no io, files, "
  <> "os.execute, or code loading. Limits: wall-clock deadline (killed at "
  <> "the deadline, partial output kept), output size cap (head and tail "
  <> "kept), at most 25 tool calls, bounded VM memory. Keep scripts small: "
  <> "fetch, filter, and summarize."

const parameters =
  "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":"
  <> "\"string\",\"description\":\"Lua 5.3 source. Use tools.<name>(args) "
  <> "to call a tool, text(...) and print(...) for output, and return the "
  <> "final answer.\"}},\"required\":[\"code\"]}"

/// One callable sibling tool, as seen from inside a script. Built by the
/// registry from the specs: `call` runs the tool synchronously in the
/// engine process and returns its (already sanitised, truncated) content.
/// Codemode itself never appears in this list — recursion guard.
pub type HostTool {
  HostTool(name: String, call: fn(String) -> Result(String, String))
}

/// The wire schema. `parameters` is parsed the same way as every other
/// tool schema (see http_fetch).
pub fn schema() -> chat.ChatCompletionTool {
  chat.FunctionTool(function: FunctionObject(
    name: "codemode",
    description: Some(description),
    parameters: option.from_result(json.parse(parameters, decode.dynamic)),
    strict: None,
  ))
}

/// Execute one codemode call. A script that RUNS to completion or fails
/// at runtime is tool CONTENT (`Ok`) — the status line carries the
/// outcome; only a malformed call (`missing 'code'`) is an `Error`, which
/// the agent loop renders like any other tool error.
pub fn run(
  hosts hosts: List(HostTool),
  timeout_ms timeout_ms: Int,
  max_output_chars max_output_chars: Int,
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  use code <- result.try(decode_code(arguments))
  Ok(run_script(hosts, timeout_ms, max_output_chars, cancel, code))
}

fn decode_code(arguments: String) -> Result(String, String) {
  let decoder = {
    use code <- decode.field("code", decode.string)
    decode.success(code)
  }
  case json.parse(arguments, decode.dynamic) {
    Error(_) -> Error("codemode: invalid arguments JSON")
    Ok(dynamic) ->
      case decode.run(dynamic, decoder) {
        Ok(code) -> Ok(code)
        Error(_) -> Error("codemode: missing required string field 'code'")
      }
  }
}

// ---------------------------------------------------------------------------
// Worker side: spawn, select, kill, render
// ---------------------------------------------------------------------------

/// Events streamed by the engine child as they happen. `EngineDone` is
/// always the engine's last send, so anything queued before it (partial
/// output) is consumed first.
type EngineEvent {
  TextOut(String)
  ConsoleLine(String)
  EngineDone(Result(Nil, String))
}

type WorkerMsg {
  FromEngine(EngineEvent)
  TurnCancelled
  EngineExit(ExitMessage)
}

/// How the worker's select loop ended.
type Ended {
  /// The engine reported a finished script (Ok) or a script failure with
  /// a formatted reason.
  EngineReported(Result(Nil, String))
  /// The engine died without reporting (out of memory, crash).
  EngineDied
  Cancelled
  Deadline
}

fn run_script(
  hosts: List(HostTool),
  timeout_ms: Int,
  max_output_chars: Int,
  cancel: Subject(Nil),
  code: String,
) -> String {
  let started_us = timing.now_us()
  let deadline_us = started_us + timeout_ms * 1000
  let events = process.new_subject()
  // Trap while the engine is linked: its exit (normal, killed by us, or
  // killed by max_heap_size) must arrive as a message, not a crash. The
  // engine is the worker's only link, so no other EXITs are expected —
  // any that appear are consumed and discarded below.
  let was_trapping = set_trap_exit(True)
  let engine = process.spawn(fn() { engine_main(events, hosts, code) })
  let #(ended, out) =
    await(engine, events, cancel, deadline_us, new_output(max_output_chars))
  // Kill first (a no-op on a dead engine), then consume the engine's exit
  // message while still trapping: restoring the flag first would let a
  // still-in-flight `killed` exit signal destroy this worker.
  process.kill(engine)
  let already_seen = case ended {
    EngineDied -> True
    _ -> False
  }
  let _ = drain_exit(engine, already_seen)
  let _ = set_trap_exit(was_trapping)
  render(ended, elapsed_ms(started_us), out)
}

/// The worker's select loop: accumulate streamed output until the engine
/// reports, the turn is cancelled, the deadline passes, or the engine
/// dies. Exits from other pids (none expected) are discarded.
fn await(
  engine: process.Pid,
  events: Subject(EngineEvent),
  cancel: Subject(Nil),
  deadline_us: Int,
  out: Output,
) -> #(Ended, Output) {
  case
    process.selector_receive(
      worker_selector(events, cancel),
      in_ms(deadline_us),
    )
  {
    Error(Nil) -> #(Deadline, out)
    Ok(FromEngine(EngineDone(report))) -> #(EngineReported(report), out)
    Ok(FromEngine(TextOut(text))) ->
      await(engine, events, cancel, deadline_us, out_add(out, Item(text)))
    Ok(FromEngine(ConsoleLine(text))) ->
      await(engine, events, cancel, deadline_us, out_add(out, Console(text)))
    Ok(TurnCancelled) -> #(Cancelled, out)
    Ok(EngineExit(ExitMessage(pid, _))) if pid == engine -> #(EngineDied, out)
    Ok(EngineExit(_)) -> await(engine, events, cancel, deadline_us, out)
  }
}

fn worker_selector(
  events: Subject(EngineEvent),
  cancel: Subject(Nil),
) -> process.Selector(WorkerMsg) {
  process.new_selector()
  |> process.select_map(events, FromEngine)
  |> process.select_map(cancel, fn(_) { TurnCancelled })
  |> process.select_trapped_exits(EngineExit)
}

/// Consume the engine's exit message (already seen when `await` reported
/// EngineDied). Other EXITs are discarded. Bounded: with a live link the
/// exit is always imminent (we killed the engine, or it just reported).
fn drain_exit(engine: process.Pid, seen: Bool) -> Bool {
  case seen {
    True -> True
    False ->
      case process.selector_receive(exit_selector(), 250) {
        Error(Nil) -> False
        Ok(EngineExit(ExitMessage(pid, _))) if pid == engine -> True
        Ok(_) -> drain_exit(engine, False)
      }
  }
}

fn exit_selector() -> process.Selector(WorkerMsg) {
  process.new_selector()
  |> process.select_trapped_exits(EngineExit)
}

fn in_ms(deadline_us: Int) -> Int {
  let left_ms = { deadline_us - timing.now_us() } / 1000
  case left_ms < 0 {
    True -> 0
    False -> left_ms
  }
}

fn elapsed_ms(started_us: Int) -> Int {
  { timing.now_us() - started_us } / 1000
}

fn render(ended: Ended, wall_ms: Int, out: Output) -> String {
  let status = case ended {
    EngineReported(Ok(_)) ->
      "Script completed (" <> int.to_string(wall_ms) <> " ms)"
    _ -> "Script failed (" <> int.to_string(wall_ms) <> " ms)"
  }
  let parts = case render_section(out, True) {
    "" -> []
    items -> [items]
  }
  let parts = case render_section(out, False) {
    "" -> parts
    console ->
      list.append(parts, [
        "<console_output>\n" <> console <> "\n</console_output>",
      ])
  }
  let parts = case ended {
    EngineReported(Ok(_)) -> parts
    _ -> list.append(parts, ["Script error: " <> failure_reason(ended)])
  }
  string.join([status, ..parts], "\n\n")
}

fn failure_reason(ended: Ended) -> String {
  let reason = case ended {
    EngineReported(Error(reason)) -> reason
    EngineReported(Ok(_)) -> "script completed"
    EngineDied ->
      // Killed is the max_heap_size reaper (or our own kill, never seen
      // here — that path ends as Deadline/Cancelled); anything else is an
      // engine crash.
      "engine died (out of memory)"
    Cancelled -> "cancelled"
    Deadline -> "timeout"
  }
  case string.byte_size(reason) > max_reason_chars {
    True -> string.slice(reason, 0, max_reason_chars) <> "…"
    False -> reason
  }
}

// ---------------------------------------------------------------------------
// Bounded output accumulation
// ---------------------------------------------------------------------------

/// One kept output segment in arrival order.
type Segment {
  Item(String)
  Console(String)
}

/// Amortised O(1) functional queue (front in order, back reversed) so
/// evicting the oldest tail segment cannot go quadratic under a spamming
/// script.
type SegQueue {
  SegQueue(front: List(Segment), back: List(Segment))
}

/// Bounded accumulator: keeps a head and a tail of the arrival-ordered
/// segments under one shared character (byte) budget — the configured cap.
/// A segment that would overflow the head goes to the tail; the tail
/// evicts its oldest segments (counted per kind) once past the half-cap,
/// so worker memory stays O(cap) no matter how much the script emits.
type Output {
  Output(
    half_cap: Int,
    head: List(Segment),
    tail: SegQueue,
    head_chars: Int,
    tail_chars: Int,
    dropped_items: Int,
    dropped_console: Int,
  )
}

fn new_output(cap: Int) -> Output {
  Output(
    half_cap: cap / 2,
    head: [],
    tail: SegQueue([], []),
    head_chars: 0,
    tail_chars: 0,
    dropped_items: 0,
    dropped_console: 0,
  )
}

fn out_add(out: Output, seg: Segment) -> Output {
  let size = seg_size(seg)
  case out.head_chars + size <= out.half_cap {
    True ->
      Output(..out, head: [seg, ..out.head], head_chars: out.head_chars + size)
    False -> push_tail(out, seg, size)
  }
}

fn push_tail(out: Output, seg: Segment, size: Int) -> Output {
  let #(tail, tail_chars, dropped_items, dropped_console) =
    evict_loop(
      SegQueue(out.tail.front, [seg, ..out.tail.back]),
      out.tail_chars + size,
      out.dropped_items,
      out.dropped_console,
      out.half_cap,
    )
  Output(
    ..out,
    tail: tail,
    tail_chars: tail_chars,
    dropped_items: dropped_items,
    dropped_console: dropped_console,
  )
}

fn evict_loop(
  tail: SegQueue,
  tail_chars: Int,
  dropped_items: Int,
  dropped_console: Int,
  half_cap: Int,
) -> #(SegQueue, Int, Int, Int) {
  case tail_chars > half_cap {
    False -> #(tail, tail_chars, dropped_items, dropped_console)
    True ->
      case seg_pop(tail) {
        Error(Nil) -> #(tail, tail_chars, dropped_items, dropped_console)
        Ok(#(seg, rest)) -> {
          let size = seg_size(seg)
          let #(dropped_items, dropped_console) = case seg {
            Item(_) -> #(dropped_items + size, dropped_console)
            Console(_) -> #(dropped_items, dropped_console + size)
          }
          evict_loop(
            rest,
            tail_chars - size,
            dropped_items,
            dropped_console,
            half_cap,
          )
        }
      }
  }
}

fn seg_size(seg: Segment) -> Int {
  case seg {
    Item(text) -> string.byte_size(text)
    Console(text) -> string.byte_size(text)
  }
}

fn seg_pop(q: SegQueue) -> Result(#(Segment, SegQueue), Nil) {
  case q.front {
    [seg, ..rest] -> Ok(#(seg, SegQueue(rest, q.back)))
    [] ->
      case list.reverse(q.back) {
        [] -> Error(Nil)
        [seg, ..rest] -> Ok(#(seg, SegQueue(rest, [])))
      }
  }
}

fn seg_queue_to_list(q: SegQueue) -> List(Segment) {
  list.append(q.front, list.reverse(q.back))
}

/// Render one section (items or console lines): head, an omission note
/// when this section lost characters, then tail.
fn render_section(out: Output, is_items: Bool) -> String {
  let #(dropped, pick, separator) = case is_items {
    True -> #(out.dropped_items, pick_item, "\n\n")
    False -> #(out.dropped_console, pick_console, "\n")
  }
  let head = list.filter_map(list.reverse(out.head), pick)
  let tail = list.filter_map(seg_queue_to_list(out.tail), pick)
  case dropped > 0 {
    False -> string.join(list.append(head, tail), separator)
    True ->
      string.join(
        list.flatten([
          head,
          ["[... " <> int.to_string(dropped) <> " chars omitted ...]"],
          tail,
        ]),
        separator,
      )
  }
}

fn pick_item(seg: Segment) -> Result(String, Nil) {
  case seg {
    Item(text) -> Ok(text)
    Console(_) -> Error(Nil)
  }
}

fn pick_console(seg: Segment) -> Result(String, Nil) {
  case seg {
    Item(_) -> Error(Nil)
    Console(text) -> Ok(text)
  }
}

// ---------------------------------------------------------------------------
// Engine child
// ---------------------------------------------------------------------------

/// Runs in the engine process: build the sandboxed VM, evaluate the
/// script (host calls run synchronously here), stream events to the
/// worker, report once. A death before the report is the worker's
/// `EngineDied` path.
fn engine_main(
  events: Subject(EngineEvent),
  hosts: List(HostTool),
  code: String,
) -> Nil {
  let _ = set_max_heap_size(max_heap_words)
  let outcome = case glua.new_sandboxed(allow: []) {
    Error(setup_error) -> Error(glua.format_error(setup_error))
    Ok(lua) ->
      glua.run(lua, engine_action(events, hosts, code))
      |> result.map_error(glua.format_error)
  }
  process.send(events, EngineDone(outcome))
}

fn engine_action(
  events: Subject(EngineEvent),
  hosts: List(HostTool),
  code: String,
) -> glua.Action(Nil, e) {
  use _ <- glua.then(install_hosts(events, hosts))
  use _ <- glua.then(glua.eval(code: preamble_lua))
  use values <- glua.then(glua.eval(code: code))
  case values {
    [] -> glua.success(Nil)
    [first, ..] ->
      glua.call_function_by_name(keys: ["__nexus_render"], args: [first])
      |> glua.then(fn(rendered) {
        case rendered {
          [value, ..] ->
            glua.dereference(ref: value, using: decode.optional(decode.string))
            |> glua.map(with: fn(text) {
              case text {
                Some(text) -> process.send(events, TextOut(text))
                None -> Nil
              }
            })
          [] -> glua.success(Nil)
        }
      })
  }
}

fn install_hosts(
  events: Subject(EngineEvent),
  hosts: List(HostTool),
) -> glua.Action(Nil, e) {
  use tools_tbl <- glua.then(build_tools_table(hosts))
  use _ <- glua.then(glua.set(keys: ["tools"], value: tools_tbl))
  use _ <- glua.then(glua.set(
    keys: ["text"],
    value: glua.function(text_fn(events)),
  ))
  use _ <- glua.then(glua.set(
    keys: ["print"],
    value: glua.function(print_fn(events)),
  ))
  glua.success(Nil)
}

/// Build the `tools` table explicitly so it can carry a `__index`
/// metamethod: a missing name raises `unknown tool: <name>` right at the
/// access site (plain nil would surface later as Luerl's cryptic
/// "Undefined function: nil", and the recursion guard — `tools.codemode`
/// — names itself the same way).
fn build_tools_table(hosts: List(HostTool)) -> glua.Action(glua.Value, e) {
  use tools_tbl <- glua.then(glua.table([]))
  use _ <- glua.then(
    hosts
    |> list.map(fn(host) {
      glua.new_index(
        table: tools_tbl,
        key: glua.string(host.name),
        value: glua.function(host_call(hosts, host.name)),
      )
    })
    |> list.fold(glua.success(Nil), fn(acc, action) {
      glua.then(acc, fn(_) { action })
    }),
  )
  use index_fn <- glua.then(
    glua.table([
      #(glua.string("__index"), glua.function(unknown_tool_fn())),
    ]),
  )
  use _ <- glua.then(
    glua.call_function(lib.set_meta_table(), [tools_tbl, index_fn])
    |> glua.map(with: fn(_) { Nil }),
  )
  glua.success(tools_tbl)
}

fn unknown_tool_fn() -> fn(List(glua.Value)) ->
  glua.Action(List(glua.Value), glua.Never) {
  fn(args) {
    case args {
      // __index receives (table, key).
      [_table, key, ..] ->
        glua.dereference(ref: key, using: decode.string)
        |> glua.then(fn(name) { glua.error("unknown tool: " <> name) })
      _ -> glua.error("unknown tool: ?")
    }
  }
}

/// `tools.<name>(args_table)`: encodes the args table to JSON with the
/// Lua-side encoder, runs the host tool synchronously (in this engine
/// process), and returns its content — or aborts the script with the
/// tool's error text. Every call counts against the budget, checked in
/// the engine process's own counter cell.
fn host_call(
  hosts: List(HostTool),
  name: String,
) -> fn(List(glua.Value)) -> glua.Action(List(glua.Value), glua.Never) {
  fn(args) {
    let calls = counter_next("nexus_codemode_tool_calls")
    case calls > tool_call_budget {
      True ->
        glua.error(
          "tool call budget exceeded ("
          <> int.to_string(tool_call_budget)
          <> " calls)",
        )
      False ->
        glua.call_function_by_name(keys: ["__nexus_encode_args"], args: args)
        |> glua.then(fn(values) {
          use encoded <- glua.then(case values {
            [first, ..] -> glua.dereference(ref: first, using: decode.string)
            [] -> glua.success("{}")
          })
          case execute_host(hosts, name, encoded) {
            Ok(content) -> glua.success([glua.string(content)])
            Error(reason) -> glua.error(reason)
          }
        })
    }
  }
}

fn execute_host(
  hosts: List(HostTool),
  name: String,
  arguments: String,
) -> Result(String, String) {
  case list.find(hosts, fn(host) { host.name == name }) {
    Error(Nil) -> Error("unknown tool: " <> name)
    Ok(host) -> host.call(arguments)
  }
}

/// `text(value)`: append one output item — strings as-is, other values as
/// JSON (rendered Lua-side, so hostile text passes through as data).
fn text_fn(
  events: Subject(EngineEvent),
) -> fn(List(glua.Value)) -> glua.Action(List(glua.Value), glua.Never) {
  fn(args) {
    case args {
      [value, ..] ->
        render_value(value)
        |> glua.then(fn(text) {
          case text {
            Some(text) -> process.send(events, TextOut(text))
            None -> Nil
          }
          glua.success([glua.nil()])
        })
      [] -> glua.success([glua.nil()])
    }
  }
}

/// Overridden `print(...)`: each argument rendered (strings as-is, other
/// values as JSON), tab-joined, appended to the console block.
fn print_fn(
  events: Subject(EngineEvent),
) -> fn(List(glua.Value)) -> glua.Action(List(glua.Value), glua.Never) {
  fn(args) {
    render_values(args)
    |> glua.then(fn(parts) {
      process.send(events, ConsoleLine(string.join(parts, "\t")))
      glua.success([])
    })
  }
}

fn render_value(value: glua.Value) -> glua.Action(Option(String), glua.Never) {
  glua.call_function_by_name(keys: ["__nexus_render"], args: [value])
  |> glua.then(fn(values) {
    case values {
      [first, ..] ->
        glua.dereference(ref: first, using: decode.optional(decode.string))
      [] -> glua.success(None)
    }
  })
}

fn render_values(
  values: List(glua.Value),
) -> glua.Action(List(String), glua.Never) {
  case values {
    [] -> glua.success([])
    [first, ..rest] -> {
      use text <- glua.then(render_value(first))
      use rest_texts <- glua.then(render_values(rest))
      glua.success([option.unwrap(text, "nil"), ..rest_texts])
    }
  }
}

// ---------------------------------------------------------------------------
// Lua-side value rendering (installed as globals by the preamble)
// ---------------------------------------------------------------------------

/// Pure-Lua JSON encoder + renderer, evaluated before the user script.
/// Encoding happens inside the VM so hostile strings pass through as data
/// and Gleam never has to walk Luerl heap terms (a cyclic table would
/// crash a dereference; here it just raises a normal Lua error). Written
/// without backslash literals (`string.char(92)`) so it embeds cleanly in
/// a Gleam string. Keys are sorted for deterministic output.
const preamble_lua =
  "local bs = string.char(92)"
  <> "\nlocal esc = {}"
  <> "\nesc[string.char(34)] = bs .. string.char(34)"
  <> "\nesc[bs] = bs .. bs"
  <> "\nesc[string.char(8)] = bs .. 'b'"
  <> "\nesc[string.char(12)] = bs .. 'f'"
  <> "\nesc[string.char(10)] = bs .. 'n'"
  <> "\nesc[string.char(13)] = bs .. 'r'"
  <> "\nesc[string.char(9)] = bs .. 't'"
  <> "\nlocal pattern = '[%c' .. string.char(34) .. bs .. ']'"
  <> "\n-- Forward-declared locals: Luerl 1.5's `local function f` sugar does"
  <> "\n-- not bind the name inside its own body, so recursive encoders must"
  <> "\n-- use the explicit `local f; f = function ...` form."
  <> "\nlocal q"
  <> "\nq = function(s)"
  <> "\n  local out = string.gsub(s, pattern, function(c)"
  <> "\n    local m = esc[c]"
  <> "\n    if m then return m end"
  <> "\n    return string.format(bs .. 'u%04x', string.byte(c))"
  <> "\n  end)"
  <> "\n  return string.char(34) .. out .. string.char(34)"
  <> "\nend"
  <> "\nlocal enc"
  <> "\nenc = function(v, depth)"
  <> "\n  if depth > 24 then error('cannot encode: table nesting too deep') end"
  <> "\n  local t = type(v)"
  <> "\n  if t == 'string' then return q(v) end"
  <> "\n  if t == 'number' then return tostring(v) end"
  <> "\n  if t == 'boolean' then"
  <> "\n    if v then return 'true' end"
  <> "\n    return 'false'"
  <> "\n  end"
  <> "\n  if t == 'function' then return q('<function>') end"
  <> "\n  if t ~= 'table' then return q(tostring(v)) end"
  <> "\n  local n = #v"
  <> "\n  local arr = n > 0"
  <> "\n  if arr then"
  <> "\n    for i = 1, n do"
  <> "\n      if v[i] == nil then"
  <> "\n        arr = false"
  <> "\n        break"
  <> "\n      end"
  <> "\n    end"
  <> "\n  end"
  <> "\n  if arr then"
  <> "\n    local parts = {}"
  <> "\n    for i = 1, n do"
  <> "\n      parts[i] = enc(v[i], depth + 1)"
  <> "\n    end"
  <> "\n    return '[' .. table.concat(parts, ',') .. ']'"
  <> "\n  end"
  <> "\n  local keys = {}"
  <> "\n  for k in pairs(v) do"
  <> "\n    keys[#keys + 1] = k"
  <> "\n  end"
  <> "\n  table.sort(keys, function(a, b)"
  <> "\n    return tostring(a) < tostring(b)"
  <> "\n  end)"
  <> "\n  local parts = {}"
  <> "\n  for i, k in ipairs(keys) do"
  <> "\n    parts[i] = q(tostring(k)) .. ':' .. enc(v[k], depth + 1)"
  <> "\n  end"
  <> "\n  return '{' .. table.concat(parts, ',') .. '}'"
  <> "\nend"
  <> "\nfunction __nexus_encode_args(v)"
  <> "\n  if v == nil then return '{}' end"
  <> "\n  return enc(v, 0)"
  <> "\nend"
  <> "\nfunction __nexus_render(v)"
  <> "\n  if v == nil then return nil end"
  <> "\n  if type(v) == 'string' then return v end"
  <> "\n  return enc(v, 0)"
  <> "\nend"

// ---------------------------------------------------------------------------
// Erlang FFI (src/nexus_codemode_ffi.erl)
// ---------------------------------------------------------------------------

@external(erlang, "nexus_codemode_ffi", "set_max_heap_size_words")
fn set_max_heap_size(words: Int) -> Int

@external(erlang, "nexus_codemode_ffi", "set_trap_exit")
fn set_trap_exit(trap: Bool) -> Bool

@external(erlang, "nexus_codemode_ffi", "counter_next")
fn counter_next(key: String) -> Int
