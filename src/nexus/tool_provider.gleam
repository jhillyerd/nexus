//// The tool-provider protocol (docs/plans/plugin-api.md): the ONE
//// in-process seam every external tool source speaks. A provider is a
//// named OTP actor registered under `nexus_plugin_<name>`; tool
//// executors address it BY NAME (never a captured `Subject`), so a
//// restart cannot dangle a reference in the catalog.
////
//// Three deployments share this protocol: compiled-in plugin actors
//// (tier-1 via `nexus/plugin`, v1 compiled into the release), MCP
//// client adapters (a config option, Phase 2), and remote node
//// adapters (the environments plan's tool plane). The agent loop never
//// learns what a provider is — `nexus/plugin` turns ToolDefs into
//// ordinary `ToolSpec`s at the catalog, and the loop executes them like
//// any compiled tool.
////
//// This module is deliberately a LEAF (gleam_erlang + stdlib + the
//// tiny `nexus/rescue` catch-all — nothing nexus-side imports back):
//// the protocol types, the boundary validation every ToolDef passes
//// before its name may enter the catalog, the per-call adapter
//// executor (the select loop), and the bounded boot-time ListTools
//// ask. Catalog assembly (`ToolSpec` construction, bundle wiring)
//// lives in `nexus/plugin`, which imports this module; nothing here
//// imports `nexus/tools` — no cycle, and the protocol stays testable
//// against fake actors alone.
////
//// Subject ownership (the AGENTS.md pitfall): only the CALLER of
//// `run` — the per-turn worker — receives on its subjects. The reply
//// subject is minted inside `run` (caller-owned), the cancel subject
//// arrives from the caller, and providers only ever RECEIVE messages;
//// plugins never see a Gleam subject they don't own.

import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string
import nexus/rescue

/// The byte bound on a ToolDef's `parameters_json`: schemas are small;
/// anything bigger is refused at the boundary before it can enter the
/// catalog or a frozen manifest (Phase 2). Generous by an order of
/// magnitude against every schema in this repo.
pub const max_parameters_bytes = 16_384

/// One tool a provider exposes. `name` is UNQUALIFIED ("fetch"); the
/// catalog qualifies it to "<provider>__fetch" so wire names stay in
/// `^[a-zA-Z0-9_-]+$`. `parameters_json` is raw JSON-schema text — the
/// same convention as `tools.function_tool`, except here it is
/// UNTRUSTED input and must pass `valid_parameters` before use.
pub type ToolDef {
  ToolDef(name: String, description: String, parameters_json: String)
}

/// A provider's reply to one call. Plain text plus an ok/err flag —
/// the ADAPTER truncates centrally (hostile-text invariant enforced at
/// the boundary, not delegated to untrusted sources). `ToolErr` is a
/// failed tool result, never a loop error: the round commits and the
/// model self-corrects.
pub type ToolReply {
  ToolOk(content: String)
  ToolErr(message: String)
}

/// A tier-1 plugin DECLARATION (the vocabulary; the actor that runs it
/// lives in `nexus/plugin`). One synchronous `call` fn serves every
/// tool — dispatch by `tool` name is the plugin's business — and the
/// SDK gives each call its own process, so `call` may block and a
/// crash is answered as a tool error, never an actor death.
/// `timeout_ms` overrides the config default per provider. Hosted here
/// (not in `nexus/plugin`) so plugin declarations — `nexus/plugins/*` —
/// import only this leaf, never the SDK module that imports them
/// (the codemode↔tools cycle rule).
pub type Plugin {
  Plugin(
    name: String,
    tools: List(ToolDef),
    call: fn(String, String) -> Result(String, String),
    timeout_ms: Option(Int),
  )
}

/// The protocol. `Call`'s `reply` is created by and owned by the
/// CALLER (the per-turn worker); exactly one reply must eventually
/// arrive, and the adapter enforces the deadline regardless.
/// `Cancelled` is a best-effort notice (user Stop or adapter deadline):
/// the transcript already carries its cancelled/timeout result — this
/// lets the provider stop work. Mirrors MCP's notifications/cancelled.
pub type Msg {
  ListTools(reply: Subject(Result(List(ToolDef), String)))
  Call(
    ref: Reference,
    tool: String,
    arguments: String,
    reply: Subject(ToolReply),
  )
  Cancelled(ref: Reference)
}

// ---------------------------------------------------------------------------
// Names and boundary validation
// ---------------------------------------------------------------------------

/// Mint a provider's registered name. Names are atoms: minted ONCE at
/// boot and threaded as a value (`process.new_name` suffixes a unique
/// counter, so a second mint is a DIFFERENT name — never re-derive a
/// provider's name from its string).
pub fn name(provider: String) -> Name(Msg) {
  process.new_name("nexus_plugin_" <> provider)
}

/// The qualified wire name `<provider>__<tool>`. `__` is reserved on
/// both halves (see `valid_name`), so qualification is unambiguous and
/// a qualified name can never equal a compiled-in tool name (none of
/// which contain `__`).
pub fn qualified(provider: String, tool: String) -> String {
  provider <> "__" <> tool
}

/// Split a qualified wire name back into its halves — the provider
/// (MCP server / plugin) and the unqualified tool — at the FIRST `__`.
/// Valid halves contain no `__`, so the reserved separator splits
/// unambiguously; a name without one was never qualified (a compiled
/// name) and refuses.
pub fn split(qualified: String) -> Result(#(String, String), Nil) {
  string.split_once(qualified, "__")
}

/// A provider or tool half-name is admissible when it is non-empty,
/// every character is in `[a-zA-Z0-9_-]`, it contains no `__`, and it
/// neither starts nor ends with `_` (so `a_`+`b` and `a`+`_b` cannot
/// both qualify to `a___b`): the reserved separator is then the ONLY
/// `__` in a qualified name and `p__t` splits back unambiguously.
pub fn valid_name(name: String) -> Bool {
  name != ""
  && !string.contains(name, "__")
  && !string.starts_with(name, "_")
  && !string.ends_with(name, "_")
  && list.all(string.to_graphemes(name), is_name_char)
}

fn is_name_char(g: String) -> Bool {
  case g {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "-" | "_" -> True
    _ -> False
  }
}

/// A `parameters_json` is admissible when it fits the byte bound,
/// parses as JSON, and has an OBJECT root (a tool schema is always an
/// object; arrays/scalars are refused). Unlike `tools.function_tool`'s
/// forgiving parse — right for compiled-in programmer error — this is
/// the boundary check for UNTRUSTED provider input.
pub fn valid_parameters(parameters_json: String) -> Bool {
  string.byte_size(parameters_json) <= max_parameters_bytes
  && case
    json.parse(parameters_json, decode.dict(decode.string, decode.dynamic))
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ---------------------------------------------------------------------------
// The adapter executor
// ---------------------------------------------------------------------------

/// Send to a provider's named subject WITHOUT ever panicking the
/// caller. The pinned `process.send` on a NamedSubject is
/// `let assert Ok(pid) = named(name)` — it badargs on an unregistered
/// name, and a provider that died mid-call unregisters itself the
/// moment it exits. A liveness check before the send narrows the race
/// but cannot close it (check→send window), so the send itself runs
/// under Erlang's catch-all: `False` means "best not sent" — for the
/// dispatch that is an honest unavailability, for a `Cancelled`
/// notice exactly its documented best-effort contract.
fn try_send(subject: Subject(Msg), msg: Msg) -> Bool {
  case rescue.rescue(fn() { process.send(subject, msg) }) {
    Ok(_done) -> True
    Error(_crash) -> False
  }
}

/// The per-call executor, run inside the per-turn worker. Ordering is
/// the contract: liveness is resolved and the monitor armed BEFORE the
/// dispatch, so a provider already down fails without a send and one
/// that dies mid-call is answered by the monitor instead of a burned
/// deadline.
///
/// Exit paths: `GotReply` (demonitor; truncate centrally), `Cancel`
/// (demonitor; RE-SIGNAL the cancel subject — an interruptible
/// executor consumes the `Nil` to wake its select, and the loop's
/// LAST-call path relies on the re-signal reaching the next
/// `cancel_pending` check; then best-effort `Cancelled`), `Down`
/// (demonitor already fired), `Timeout` (demonitor; `Cancelled`;
/// honest timeout text). Every send is panic-guarded (`try_send`): a
/// provider that died with its DOWN still in flight must degrade to a
/// tool error, never crash the worker. A late reply after
/// timeout/cancel is inert: the reply subject is minted fresh per call,
/// so no later select can ever match it, and the per-turn worker dies
/// at turn end, dropping the queue. `demonitor_process` in the pinned
/// FFI flushes, so no stale `DOWN` can survive a settled call.
pub fn run(
  provider provider: Name(Msg),
  tool tool: String,
  timeout_ms timeout_ms: Int,
  max_output_chars max_output_chars: Int,
  cancel cancel: Subject(Nil),
  arguments arguments: String,
) -> Result(String, String) {
  case process.named(provider) {
    Error(Nil) -> Error("tool provider is unavailable")
    Ok(pid) -> {
      let reply = process.new_subject()
      let ref = reference.new()
      let mon = process.monitor(pid)
      let subject = process.named_subject(provider)
      case try_send(subject, Call(ref, tool, arguments, reply)) {
        // The provider died between the liveness check and the
        // dispatch (name unregistered): same honest answer as the
        // entry check, and the monitor is demonitored first so a
        // racing DOWN (noproc fires immediately on a dead pid) is
        // flushed instead of queueing as garbage in the worker.
        False -> {
          process.demonitor_process(mon)
          Error("tool provider is unavailable")
        }
        True ->
          select(subject, ref, mon, reply, cancel, timeout_ms, max_output_chars)
      }
    }
  }
}

fn select(
  subject: Subject(Msg),
  ref: Reference,
  mon: process.Monitor,
  reply: Subject(ToolReply),
  cancel: Subject(Nil),
  timeout_ms: Int,
  max_output_chars: Int,
) -> Result(String, String) {
  let selector =
    process.new_selector()
    |> process.select_map(reply, GotReply)
    |> process.select_map(cancel, fn(_) { Cancel })
    |> process.select_specific_monitor(mon, Down)
  case process.selector_receive(selector, timeout_ms) {
    Ok(GotReply(ToolOk(content))) -> {
      process.demonitor_process(mon)
      Ok(truncate(content, max_output_chars))
    }
    Ok(GotReply(ToolErr(message))) -> {
      process.demonitor_process(mon)
      Error(truncate(message, max_output_chars))
    }
    Ok(Cancel) -> {
      process.demonitor_process(mon)
      // The re-signal is mandatory (the codemode rule): this select
      // consumed the turn's `Nil`, and the loop's LAST-call path
      // still needs to observe the Stop.
      process.send(cancel, Nil)
      // Best-effort by contract; the provider may already be gone.
      let _ = try_send(subject, Cancelled(ref))
      Error("cancelled")
    }
    Ok(Down(_)) -> Error("tool provider is unavailable")
    Error(Nil) -> {
      process.demonitor_process(mon)
      let _ = try_send(subject, Cancelled(ref))
      Error("timed out after " <> int.to_string(timeout_ms) <> " ms")
    }
  }
}

type SelectMsg {
  GotReply(ToolReply)
  Cancel
  Down(process.Down)
}

/// Central truncation for provider bytes — display hygiene, not the
/// memory bound: an in-process plugin is trusted code (the same trust
/// as compiled tools), and external transports (MCP, Phase 2) cap
/// while READING. Marker format matches codemode's omission note.
pub fn truncate(text: String, cap: Int) -> String {
  case string.length(text) > cap {
    True ->
      string.slice(text, 0, cap)
      <> "\n[... truncated at "
      <> int.to_string(cap)
      <> " chars ...]"
    False -> text
  }
}

// ---------------------------------------------------------------------------
// Boot-time ask
// ---------------------------------------------------------------------------

/// The bounded boot-time `ListTools`: the provider actor is the single
/// source of truth for its tool list (no module-vs-actor drift). The
/// caller (boot main, or a test) owns the reply subject, so the
/// receive is local and legal. A provider that will not answer within
/// `timeout_ms` fails — loudly at boot (a compiled plugin is part of
/// the release); nothing external can hang boot on this path.
pub fn list_tools(
  provider provider: Name(Msg),
  timeout_ms timeout_ms: Int,
) -> Result(List(ToolDef), String) {
  // Liveness FIRST, exactly like `run`; the send itself is
  // panic-guarded for the check→send window (an unregistered named
  // subject badargs at the send — a provider that just died must be
  // answered, not crashed on).
  case process.named(provider) {
    Error(Nil) -> Error("tool provider is unavailable")
    Ok(_pid) -> {
      let reply = process.new_subject()
      case try_send(process.named_subject(provider), ListTools(reply)) {
        False -> Error("tool provider is unavailable")
        True ->
          case process.receive(reply, timeout_ms) {
            Ok(Ok(defs)) -> Ok(defs)
            Ok(Error(reason)) -> Error(reason)
            Error(Nil) ->
              Error(
                "no ListTools reply within "
                <> int.to_string(timeout_ms)
                <> " ms",
              )
          }
      }
    }
  }
}
