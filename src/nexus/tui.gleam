//// The nexus node TUI — a REPL-style proof of concept (environments
//// plan Phase 2b-5). A terminal client that dials OUT to nexus over
//// `/node/ws` (the Codex exec-server connectivity model: outbound
//// only, token auth), renders the event plane as plain lines, sends
//// user turns, and serves the tool plane by executing the four env
//// tools in ITS OWN local workspace (`env.serve_node_call` — the node
//// IS the target the server routed to).
////
////     NEXUS_URL=http://host:port \
////     NEXUS_NODE=proxmox-2 \
////     NEXUS_NODE_TOKEN=… \
////     NEXUS_THREAD=<thread id> \
////     gleam run -m nexus/tui
////
//// This is a PROOF OF CONCEPT, deliberately: line-oriented REPL, no
//// full-screen TUI (the high-fidelity client is a separate future
//// initiative — survey existing coding-agent TUIs and modify one).
//// Known PoC jank, documented rather than hidden: output arriving
//// while a line is being typed interleaves with it (Erlang's group
//// leader has no read-the-half-typed-line primitive), and there is no
//// input history. What the PoC DOES prove is the protocol: it speaks
//// `node_protocol` v1 both ways, shares the server's decode types, and
//// serves tools/call through the exact code path the in-process
//// workspace uses.
////
//// Process shape: the stratus connection actor owns the socket (the
//// socket-owner rule — every frame send happens inside `on_message`),
//// an actor-owned `inbox` subject feeds user messages in (created in
//// the connection's init, handed to main through a main-owned handoff
//// subject — the `gated_runner` ownership rule from AGENTS.md: never
//// RECEIVE on a subject owned by another process; sending across
//// owners is fine), a spawned stdin loop reads `io:get_line` lines,
//// and each `tools/call` runs in a short-lived worker so a full
//// deadline block never stalls the render loop. `notifications/
//// cancelled` re-signals the in-flight worker's cancel subject (the
//// codemode rule).

import envoy
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/string
import nexus/env
import nexus/node_protocol
import nexus/tui/render
import nexus/tui/tools
import stratus

@external(erlang, "nexus_tui_ffi", "get_line")
fn ffi_get_line(prompt: String) -> Result(String, Nil)

@external(erlang, "nexus_boot_ffi", "halt")
fn halt(code: Int) -> Nil

/// Everything the REPL needs, read from the environment once at boot.
type Config {
  Config(
    /// e.g. "http://127.0.0.1:8080" — /node/ws is appended.
    base_url: String,
    node: String,
    token: String,
    thread_id: String,
    /// "env" (default) or "viewer" — the route's join role.
    role: String,
    /// The node's LOCAL workspace root (defaults to ./node-workspace).
    workspace: String,
    timeout_ms: Int,
    max_output_bytes: Int,
  )
}

/// Messages posted INTO the connection actor: stdin lines, finished
/// tool calls, and shutdown.
type Msg {
  SendLine(String)
  /// The worker has created its cancel subject and is about to
  /// execute — the actor registers it so `Cancelled` frames can reach
  /// it. Subject ownership stays with the process that receives on it
  /// (the executor's select loop lives in the worker), so the worker
  /// must be the creator; the actor only records it.
  CallArmed(Int, Subject(Nil))
  CallDone(Int, Bool, String)
  Quit
}

/// The connection actor's per-connection state. `calls` maps an
/// in-flight `tools/call` id to its cancel subject — the registry the
/// server's `notifications/cancelled` frame re-signals.
type State {
  State(
    handle: env.Environment,
    config: Config,
    inbox: Subject(Msg),
    calls: Dict(Int, Subject(Nil)),
  )
}

pub fn main() -> Nil {
  case load_config() {
    Error(reason) -> {
      io.println("! nexus-tui: " <> reason)
      io.println(usage())
      halt(2)
    }
    Ok(config) -> run(config)
  }
}

fn usage() -> String {
  "usage: NEXUS_URL=http://host:port NEXUS_NODE=<name> "
  <> "NEXUS_NODE_TOKEN=<token> NEXUS_THREAD=<thread id> "
  <> "gleam run -m nexus/tui\n"
  <> "  optional: NEXUS_ROLE=env|viewer (default env), "
  <> "NEXUS_NODE_WORKSPACE=<dir> (default node-workspace)\n"
  <> "  knobs: NEXUS_ENV_TIMEOUT_MS / NEXUS_ENV_MAX_OUTPUT_BYTES "
  <> "(the server's floors apply)\n"
  <> "  REPL: type a line to send it to the thread, /quit to leave"
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

fn load_config() -> Result(Config, String) {
  use base_url <- result.try(required("NEXUS_URL"))
  use node <- result.try(required("NEXUS_NODE"))
  use token <- result.try(required("NEXUS_NODE_TOKEN"))
  use thread_id <- result.try(required("NEXUS_THREAD"))
  use base_url <- result.try(check_scheme(base_url))
  use role <- result.try(case envoy.get("NEXUS_ROLE") {
    Ok("env") -> Ok("env")
    Ok("viewer") -> Ok("viewer")
    Ok(other) -> Error("NEXUS_ROLE must be env or viewer, got: " <> other)
    Error(_) -> Ok("env")
  })
  let workspace = case envoy.get("NEXUS_NODE_WORKSPACE") {
    Ok(dir) -> dir
    Error(_) -> "node-workspace"
  }
  Ok(Config(
    base_url: string.trim(base_url),
    node: string.trim(node),
    token: string.trim(token),
    thread_id: string.trim(thread_id),
    role: role,
    workspace: workspace,
    timeout_ms: int_knob("NEXUS_ENV_TIMEOUT_MS", 60_000, 1000),
    max_output_bytes: int_knob("NEXUS_ENV_MAX_OUTPUT_BYTES", 262_144, 1024),
  ))
}

fn required(name: String) -> Result(String, String) {
  case envoy.get(name) {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error(name <> " is required")
  }
}

fn check_scheme(url: String) -> Result(String, String) {
  case url {
    "http://" <> _ | "https://" <> _ -> Ok(url)
    _ -> Error("NEXUS_URL must start with http:// or https://, got: " <> url)
  }
}

/// One knob each, reusing the server's names and floors
/// (NEXUS_ENV_TIMEOUT_MS / NEXUS_ENV_MAX_OUTPUT_BYTES) so an operator
/// tunes the same numbers on both sides.
fn int_knob(name: String, default: Int, floor: Int) -> Int {
  case envoy.get(name) {
    Ok(raw) ->
      case int.parse(raw) {
        Ok(n) ->
          case n >= floor {
            True -> n
            False -> floor
          }
        Error(_) -> default
      }
    Error(_) -> default
  }
}

// ---------------------------------------------------------------------------
// The REPL
// ---------------------------------------------------------------------------

fn run(config: Config) -> Nil {
  // The node's own workspace: thread_id scopes the directory the same
  // way the server's per-thread workspaces do. Created up front so a
  // bad root fails loudly at boot, not on the first tool call.
  let handle =
    env.Environment(
      workspace_root: config.workspace,
      thread_id: config.thread_id,
      roster: env.attached_targets(),
      remote: None,
    )
  case env.ensure_workspace(handle) {
    Error(reason) -> {
      io.println(
        "! nexus-tui: workspace " <> config.workspace <> ": " <> reason,
      )
      halt(2)
    }
    Ok(_) -> Nil
  }
  let path =
    config.base_url
    <> "/node/ws?node="
    <> config.node
    <> "&token="
    <> config.token
    <> "&thread="
    <> config.thread_id
    <> "&role="
    <> config.role
  // The node name and token are charset-safe (the server validates the
  // name; tokens are URL-safe base64), so the query needs no encoding.
  case request.to(path) {
    Error(_) -> {
      io.println("! nexus-tui: cannot parse request URL: " <> path)
      halt(2)
    }
    Ok(req) -> {
      let handoff = process.new_subject()
      case
        stratus.new_with_initialiser(req, fn() {
          let inbox = process.new_subject()
          process.send(handoff, inbox)
          Ok(
            stratus.initialised(State(
              handle: handle,
              config: config,
              inbox: inbox,
              calls: dict.new(),
            ))
            |> stratus.selecting(process.select(process.new_selector(), inbox)),
          )
        })
        |> stratus.on_message(on_message)
        |> stratus.on_close(fn(_state, _reason) {
          io.println("-- disconnected")
          halt(0)
        })
        |> stratus.start
      {
        Error(start_error) -> {
          // stratus maps handshake failures to a one-line reason that
          // carries the status ("WebSocket handshake failed with
          // status 401"): the body would name the failure exactly
          // ("unknown node or bad token" vs "node auth required" vs
          // 403's "thread has no workspace toolset"), but stratus does
          // not expose it — the status still separates a token/name
          // mismatch from a wrong path or a chat-only thread.
          let detail = case start_error {
            actor.InitFailed(message) -> message
            actor.InitTimeout -> "handshake timed out"
            actor.InitExited(_) -> "connection exited during handshake"
          }
          io.println(
            "! nexus-tui: cannot connect to "
            <> config.base_url
            <> " — "
            <> detail,
          )
          halt(2)
        }
        Ok(started) -> {
          let assert Ok(inbox) = process.receive(handoff, 5000)
          process.spawn(fn() { stdin_loop(inbox) })
          // Park main on the connection actor's death: on_close handles
          // a clean close; a crashed connection lands here instead of
          // hanging the REPL.
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(
              process.monitor(started.pid),
              fn(_down) { Nil },
            )
          let _ = process.selector_receive_forever(selector)
          io.println("! nexus-tui: connection crashed")
          halt(1)
        }
      }
    }
  }
}

fn stdin_loop(inbox: Subject(Msg)) -> Nil {
  case ffi_get_line("> ") {
    Ok(line) -> {
      let text = string.trim(line)
      case text {
        "/quit" -> process.send(inbox, Quit)
        "" -> stdin_loop(inbox)
        _ -> {
          process.send(inbox, SendLine(text))
          stdin_loop(inbox)
        }
      }
    }
    // EOF (stdin closed): leave cleanly.
    Error(Nil) -> process.send(inbox, Quit)
  }
}

fn on_message(
  state: State,
  msg: stratus.Message(Msg),
  conn: stratus.Connection,
) -> stratus.Next(State, Msg) {
  case msg {
    stratus.Text(frame) -> on_frame(state, frame)
    stratus.Binary(_) -> stratus.continue(state)
    stratus.User(SendLine(text)) -> {
      let _ = stratus.send_text_message(conn, node_protocol.encode_send(text))
      stratus.continue(state)
    }
    stratus.User(CallArmed(id, cancel)) ->
      stratus.continue(
        State(..state, calls: dict.insert(state.calls, id, cancel)),
      )
    stratus.User(CallDone(id, is_error, text)) -> {
      let _ =
        stratus.send_text_message(
          conn,
          node_protocol.encode_call_response(id, is_error, text),
        )
      stratus.continue(State(..state, calls: dict.delete(state.calls, id)))
    }
    stratus.User(Quit) -> {
      // Send the close frame and KEEP SERVING until the peer's close
      // echo arrives — `stop()` here would kill the actor before the
      // handshake finishes and before `on_close` fires (found by the
      // tui e2e's graceful-exit check). on_close halts the VM. A
      // wedged close — the peer never echoing — keeps this actor
      // alive, so nothing fires and the REPL parks; there is no
      // fallback (documented PoC jank).
      let _ = stratus.close(conn, stratus.Normal(<<>>))
      stratus.continue(state)
    }
  }
}

fn on_frame(state: State, frame: String) -> stratus.Next(State, Msg) {
  case node_protocol.decode_server_frame(frame) {
    Error(Nil) -> {
      render.emit(render.undecodable())
      stratus.continue(state)
    }
    Ok(decoded) -> {
      render.emit(render.render(decoded))
      case decoded {
        node_protocol.CallRequest(id, tool, arguments) ->
          spawn_call(state, id, tool, arguments)
        node_protocol.Cancelled(id) -> {
          // Re-signal the in-flight worker's cancel subject (the
          // codemode rule). Best-effort by contract: an id already
          // answered (deregistered at CallDone) or not yet armed finds
          // no entry and the notice drops — a spawn-to-arm race is
          // narrow enough for a PoC that the executor running to its
          // deadline (answered server-side as an ordinary tool
          // timeout) is acceptable.
          case dict.get(state.calls, id) {
            Ok(cancel) -> process.send(cancel, Nil)
            Error(Nil) -> Nil
          }
          stratus.continue(state)
        }
        _ -> stratus.continue(state)
      }
    }
  }
}

/// Run the call in a worker — the executor may block up to the full
/// deadline and must never stall the render loop. The worker OWNS its
/// cancel subject: `process.send` delivers to the subject's OWNER's
/// mailbox, so a subject created in this actor would be invisible to
/// the worker's executor select loop (the inverted-ownership bug the
/// review round caught — the registry was written but never read). The
/// worker arms the subject through the inbox BEFORE executing; the
/// registration is complete once the actor processes `CallArmed`.
fn spawn_call(
  state: State,
  id: Int,
  tool: String,
  arguments: String,
) -> stratus.Next(State, Msg) {
  let inbox = state.inbox
  let handle = state.handle
  let config = state.config
  process.spawn(fn() {
    let cancel = process.new_subject()
    process.send(inbox, CallArmed(id, cancel))
    let outcome =
      tools.execute(
        handle,
        config.timeout_ms,
        config.max_output_bytes,
        tool,
        arguments,
        cancel,
      )
    process.send(inbox, CallDone(id, outcome.0, outcome.1))
  })
  stratus.continue(state)
}
