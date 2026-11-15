//// The MCP client adapter actor + boot mount (plugin-api plan Phase 2).
////
//// One actor per configured stdio server (a config option, NOT a
//// plugin — `NEXUS_MCP_SERVERS_JSON`), speaking the provider protocol
//// (`tool_provider.Msg`) on top of an MCP transport (`nexus/mcp`). The
//// actor registers under `nexus_plugin_<server>` — the SAME name
//// scheme and subject-ownership rules as a plugin — so the compiled
//// executor (`tool_provider.run`) addresses it exactly like a plugin
//// actor: by name, deadline-armed, monitor-backed, never a loop error.
////
//// Lifecycle (the plan's degrade rule): at boot the actor performs the
//// `initialize` handshake with its child process; boot then asks every
//// adapter `ListTools` under a bounded budget. A server that will not
//// spawn, answer, or produce a valid catalog DEGRADES — logged loudly,
//// absent from the foreign map, so a create naming its tools is the
//// honest 400 — because it is an external dependency, like SearxNG
//// absence. A compiled plugin failing boot is the opposite (fail
//// boot): it is part of the release. Once mounted, a server that dies
//// mid-life puts the actor into a `Down` phase — the ACTOR never
//// crashes (a crash-looping supervisor would take boot with it) — and
//// every later call renders the honest tool error; nexus's next
//// restart is the retry.
////
//// Wire mapping: `Call` → JSON-RPC `tools/call` (arguments
//// canonicalized to an object so the newline framing survives);
//// `Cancelled` → `notifications/cancelled`; `ListTools` → a LIVE
//// `tools/list` round trip (boot mount AND create-time freeze get the
//// server's current catalog, never a boot-time cache — the freeze
//// persists what the server serves at create, and the manifest makes
//// it byte-stable thereafter). Content results flatten to plain text
//// (`ToolOk`/`ToolErr`); server-initiated requests are answered
//// `method not found` (nexus is a tool client only); notifications
//// are ignored. Each outbound request is deadline-tracked: a wedged
//// server answers as a tool error, and its pending calls get the
//// cancelled notification, mirroring the executor's own timeout.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import nexus/config.{type Config}
import nexus/mcp
import nexus/tool_provider.{type ToolDef, type ToolReply}
import nexus/tools

/// The boot-time `ListTools` budget per server. A bit over the plugin
/// ask's: a stdio server may be a slow first-run `npx` download, and
/// this budget is bounded but not hostile to that. Handshakes already
/// ran concurrently in the initialisers, so total boot wait is the
/// slowest server, not the sum.
const boot_ask_ms = 10_000

/// The handshake budget: how long `initialize` may take before the
/// actor gives up and degrades. Late frames after this are ignored —
/// a server that finished starting at second 11 is unusable until the
/// next nexus restart (the documented retry).
const handshake_ms = 10_000

/// tools/list pagination cap: pages followed before the ask fails. A
/// server serving honest pages is far past anything a thread toolset
/// would freeze.
const max_list_pages = 10

/// The actor's mailbox: the public provider protocol via the named
/// subject, plus internal transport/timer traffic.
pub type Msg {
  Provider(tool_provider.Msg)
  Internal(Internal)
}

pub type Internal {
  Event(mcp.TransportEvent)
  BootTimeout
  RequestTimeout(id: Int)
}

/// Everyone waiting on one `tools/list` round trip. Askers that arrive
/// while a round trip (or the handshake) is in flight ride it: one
/// server ask serves every concurrent asker — the answer is equally
/// "live" for all of them.
type Askers =
  List(Subject(Result(List(ToolDef), String)))

/// One in-flight `tools/call`, tracked by BOTH halves of its identity:
/// the outbound JSON-RPC id (the response matches by id) and the
/// protocol `Reference` (a `Cancelled` notice matches by ref). The
/// reply subject is caller-owned (the per-turn worker); exactly one
/// reply is sent, or none after a cancel (the caller already ended
/// the call — a late reply would be inert).
type CallPending {
  CallPending(ref: reference.Reference, reply: Subject(ToolReply))
}

type Phase {
  Handshaking
  Ready
  Down(reason: String)
}

type State {
  State(
    server: config.McpServer,
    transport: Option(mcp.Transport(Msg)),
    feed: mcp.Feed,
    /// The actor's own mailbox — timers (send_after) target it.
    internal: Subject(Internal),
    /// Next outbound JSON-RPC id (1 = initialize).
    out: Int,
    phase: Phase,
    /// The id of the in-flight `initialize` request.
    init_id: Int,
    /// Askers waiting for readiness (arrived during handshake).
    waiting: Askers,
    /// In-flight `tools/list`: id, askers, accumulated defs, pages so
    /// far (the pagination cap counts these).
    list: Option(#(Int, Askers, List(ToolDef), Int)),
    /// In-flight calls, by outbound JSON-RPC id.
    calls: Dict(Int, CallPending),
    /// The same calls by protocol `Reference`, for `Cancelled`.
    by_ref: Dict(reference.Reference, Int),
    /// The server's per-call wall-clock deadline (config default or
    /// the server's override) — reused as the actor-side outbound
    /// deadline, so both sides of a call give up at the same wall
    /// clock and the actor's timeout answers first (with the cancelled
    /// notice), never double-failing through the executor's clock.
    deadline_ms: Int,
  )
}

/// Start one adapter actor under its pre-minted name, with the
/// resolved per-call deadline (config default or the server's
/// validated override). The initialiser NEVER fails the supervisor
/// child: a spawn failure (bad command) is a `Down` phase — the server
/// degrades with a loud log and boot continues, exactly like any other
/// unreachable external dependency.
pub fn start(
  server server: config.McpServer,
  name name: Name(tool_provider.Msg),
  deadline_ms deadline_ms: Int,
) -> actor.StartResult(Subject(Msg)) {
  do_start(server, name, deadline_ms, None)
}

/// Test seam (`gated_runner` inversion, plugin-api plan Phase 2): start
/// the adapter over an injected transport and hand the actor-owned
/// transport-events subject back through `probe`, so a test can play
/// the SERVER — sending `Chunk` frames in, reading the frames the
/// adapter writes — with no OS process at all. Sending is legal from
/// anywhere; only the actor ever RECEIVES on the subject.
pub fn start_probing(
  server server: config.McpServer,
  name name: Name(tool_provider.Msg),
  deadline_ms deadline_ms: Int,
  transport transport: mcp.Transport(Msg),
  probe probe: Subject(Subject(mcp.TransportEvent)),
) -> actor.StartResult(Subject(Msg)) {
  do_start(server, name, deadline_ms, Some(#(transport, probe)))
}

fn do_start(
  server: config.McpServer,
  name: Name(tool_provider.Msg),
  deadline_ms: Int,
  injected: Option(#(mcp.Transport(Msg), Subject(Subject(mcp.TransportEvent)))),
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(5000, fn(self) {
    // Register HERE, not via `actor.named` — the superset-message rule
    // (see the tier-1 SDK's identical comment), and a supervisor
    // restart re-registers the fresh pid.
    case process.register(process.self(), name) {
      Error(Nil) -> Error("mcp server name already registered: " <> server.name)
      Ok(Nil) -> {
        let internal = process.new_subject()
        // The transport's inbound pipe, OWNED by this actor (the
        // subject-owner rule): a fake gets it handed over through the
        // probe (see `start_probing`) and answers through it.
        let events = process.new_subject()
        let opened = case injected {
          Some(#(transport, probe)) -> {
            // Hand the gate over before any traffic: the test plays
            // the server from now on.
            process.send(probe, events)
            case transport.send_line(mcp.initialize_request(1)) {
              Ok(Nil) -> {
                let _ = process.send_after(internal, handshake_ms, BootTimeout)
                Ok(#(Some(transport), 2, 1, Handshaking))
              }
              Error(reason) -> Ok(#(Some(transport), 2, 0, Down(reason)))
            }
          }
          None ->
            case
              mcp.stdio(
                command: server.command,
                args: server.args,
                env: server.env,
              )
            {
              Error(reason) -> Ok(#(None, 2, 0, Down(reason)))
              Ok(transport) -> {
                let _ = transport.send_line(mcp.initialize_request(1))
                let _ = process.send_after(internal, handshake_ms, BootTimeout)
                Ok(#(Some(transport), 2, 1, Handshaking))
              }
            }
        }
        case opened {
          Error(reason) -> Error(reason)
          Ok(#(transport, out, init_id, phase)) -> {
            case phase {
              Down(reason) ->
                io.println(
                  "mcp server '" <> server.name <> "' degraded: " <> reason,
                )
              _ -> Nil
            }
            Ok(initial(
              self,
              State(
                server: server,
                transport: transport,
                feed: mcp.new_feed(),
                internal: internal,
                out: out,
                phase: phase,
                init_id: init_id,
                waiting: [],
                list: None,
                calls: dict.new(),
                by_ref: dict.new(),
                deadline_ms: deadline_ms,
              ),
              name,
              events,
              // Uniform arm shape: the real transport arms via
              // select_record (ignoring `events`); the degraded case
              // selects the idle events subject directly.
              case transport {
                Some(t) -> t.arm
                None -> fn(events, selector, wrap) {
                  process.select_map(selector, events, wrap)
                }
              },
            ))
          }
        }
      }
    }
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// The common initialiser tail: register the selector over the named
/// subject (the public protocol), the internal mailbox (timers), and
/// the transport's events.
fn initial(
  self: Subject(Msg),
  state: State,
  name: Name(tool_provider.Msg),
  events: Subject(mcp.TransportEvent),
  arm: fn(
    Subject(mcp.TransportEvent),
    process.Selector(Msg),
    fn(mcp.TransportEvent) -> Msg,
  ) -> process.Selector(Msg),
) -> actor.Initialised(State, Msg, Subject(Msg)) {
  let selector =
    process.new_selector()
    |> process.select_map(process.named_subject(name), Provider)
    |> process.select_map(state.internal, Internal)
  actor.initialised(state)
  |> actor.returning(self)
  |> actor.selecting(arm(events, selector, fn(ev) { Internal(Event(ev)) }))
}

// ---------------------------------------------------------------------------
// The state machine (pure state transitions; `handle` wraps them in
// `actor.continue`)
// ---------------------------------------------------------------------------

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  actor.continue(step(state, msg))
}

fn step(state: State, msg: Msg) -> State {
  case msg {
    Provider(tool_provider.ListTools(reply)) ->
      case state.phase {
        Down(reason) -> {
          process.send(reply, Error(unavailable(state, reason)))
          state
        }
        Handshaking -> State(..state, waiting: [reply, ..state.waiting])
        Ready -> start_list(state, [reply])
      }

    Provider(tool_provider.Call(ref, tool, arguments, reply)) ->
      dispatch_call(state, ref, tool, arguments, reply)

    Provider(tool_provider.Cancelled(ref)) ->
      case dict.get(state.by_ref, ref) {
        Error(Nil) -> state
        Ok(id) -> {
          // Best-effort notice: the caller (executor deadline or user
          // Stop) already ended the call — NO reply, just tell the
          // server to stop work and untrack.
          let _ =
            send_frame(
              state,
              mcp.cancelled_notification(id, "client cancelled"),
            )
          State(
            ..state,
            calls: dict.delete(state.calls, id),
            by_ref: dict.delete(state.by_ref, ref),
          )
        }
      }

    Internal(Event(mcp.Chunk(bytes))) ->
      case state.phase {
        Down(_) -> state
        _ -> {
          let #(frames, feed) = mcp.feed(state.feed, bytes)
          list.fold(frames, State(..state, feed: feed), step_frame)
        }
      }

    Internal(Event(mcp.Exited(code))) ->
      degrade(state, "server exited with status " <> int.to_string(code))

    Internal(BootTimeout) ->
      case state.phase {
        Handshaking ->
          degrade(
            state,
            "handshake timed out after " <> int.to_string(handshake_ms) <> " ms",
          )
        _ -> state
      }

    Internal(RequestTimeout(id)) -> request_timeout(state, id)
  }
}

fn step_frame(state: State, frame: mcp.Frame) -> State {
  case frame {
    mcp.NotUtf8 -> {
      log(state, "non-UTF-8 bytes dropped")
      state
    }
    mcp.TooBig -> {
      log(state, "frame over the read cap refused")
      state
    }
    mcp.Line("") -> state
    mcp.Line(line) ->
      case mcp.parse_incoming(line) {
        mcp.Garbage -> {
          log(state, "unparseable frame dropped")
          state
        }
        mcp.ServerNotification(_) -> state
        mcp.ServerRequest(id_dyn, _method) -> {
          // Nexus is a tool client: server-initiated requests
          // (sampling, roots, ping handlers that need replies) are
          // refused — a JSON-RPC request REQUIRES a response.
          let _ = send_frame(state, mcp.method_not_found_response(id_dyn))
          state
        }
        mcp.Response(id, outcome) -> on_response(state, id, outcome)
      }
  }
}

fn on_response(
  state: State,
  id: Int,
  outcome: Result(Dynamic, mcp.RpcError),
) -> State {
  // Handshake completion first (id order makes this unambiguous).
  case state.phase, id == state.init_id {
    Handshaking, True ->
      case outcome {
        Ok(_init_result) -> {
          // Close the handshake, go Ready, and let any askers that
          // queued during the handshake start a tools/list round trip.
          let _ = send_frame(state, mcp.initialized_notification())
          let ready = State(..state, phase: Ready)
          case state.waiting {
            [] -> ready
            askers -> start_list(State(..ready, waiting: []), askers)
          }
        }
        Error(rpc) ->
          degrade(
            state,
            "initialize refused ("
              <> int.to_string(rpc.code)
              <> "): "
              <> rpc.message,
          )
      }
    Handshaking, False -> state
    _, _ ->
      case state.list {
        Some(#(list_id, askers, acc, pages)) if list_id == id ->
          case outcome {
            Error(rpc) -> {
              fail_list(
                state,
                askers,
                "tools/list failed ("
                  <> int.to_string(rpc.code)
                  <> "): "
                  <> rpc.message,
              )
            }
            Ok(result) ->
              case mcp.decode_tools_list(result) {
                Error(reason) ->
                  fail_list(state, askers, "catalog refused: " <> reason)
                Ok(#(defs, cursor)) ->
                  finish_list(state, askers, acc, pages, defs, cursor)
              }
          }
        _ ->
          case dict.get(state.calls, id) {
            Ok(pending) -> {
              let reply = case outcome {
                Error(rpc) ->
                  tool_provider.ToolErr(
                    "mcp server '"
                    <> state.server.name
                    <> "' error "
                    <> int.to_string(rpc.code)
                    <> ": "
                    <> rpc.message,
                  )
                Ok(result) ->
                  case mcp.decode_call_result(result) {
                    Ok(reply) -> reply
                    Error(reason) ->
                      tool_provider.ToolErr(
                        "mcp server '"
                        <> state.server.name
                        <> "' sent an unparseable result: "
                        <> reason,
                      )
                  }
              }
              process.send(pending.reply, reply)
              State(
                ..state,
                calls: dict.delete(state.calls, id),
                by_ref: dict.delete(state.by_ref, pending.ref),
              )
            }
            // A response to a request we already timed out or
            // cancelled: drop (the caller is long gone).
            Error(Nil) -> state
          }
      }
  }
}

/// One completed (or continued) `tools/list` page. A cursor means more
/// pages follow — under the page cap, a fresh request carries it and
/// the accumulated defs ride along; otherwise the catalog is complete
/// and EVERYONE (this round trip's askers plus anyone who queued
/// during the handshake) gets the whole list.
fn finish_list(
  state: State,
  askers: Askers,
  acc: List(ToolDef),
  pages: Int,
  defs: List(ToolDef),
  cursor: Option(String),
) -> State {
  let acc = list.append(acc, defs)
  let more_pages = pages + 1 < max_list_pages
  case cursor, more_pages {
    Some(cursor), True -> {
      let next_id = state.out
      let _ = send_frame(state, mcp.tools_list_request(next_id, Some(cursor)))
      let _ =
        process.send_after(
          state.internal,
          state.deadline_ms,
          RequestTimeout(next_id),
        )
      State(
        ..state,
        out: next_id + 1,
        list: Some(#(next_id, askers, acc, pages + 1)),
      )
    }
    _, _ -> {
      list.each(list.append(askers, state.waiting), fn(asker) {
        process.send(asker, Ok(acc))
      })
      State(..state, list: None, waiting: [])
    }
  }
}

fn fail_list(state: State, askers: Askers, reason: String) -> State {
  let text = "mcp server '" <> state.server.name <> "' tools/list " <> reason
  list.each(list.append(askers, state.waiting), fn(asker) {
    process.send(asker, Error(text))
  })
  State(..state, list: None, waiting: [])
}

/// Start (or join) a live `tools/list` round trip.
fn start_list(state: State, askers: Askers) -> State {
  case state.list {
    Some(#(id, in_flight, acc, pages)) ->
      State(
        ..state,
        list: Some(#(id, list.append(in_flight, askers), acc, pages)),
      )
    None -> {
      let id = state.out
      let _ = send_frame(state, mcp.tools_list_request(id, None))
      let _ =
        process.send_after(
          state.internal,
          state.deadline_ms,
          RequestTimeout(id),
        )
      State(..state, out: id + 1, list: Some(#(id, askers, [], 1)))
    }
  }
}

fn dispatch_call(
  state: State,
  ref: reference.Reference,
  tool: String,
  arguments: String,
  reply: Subject(ToolReply),
) -> State {
  case state.phase {
    Down(reason) -> {
      process.send(reply, tool_provider.ToolErr(unavailable(state, reason)))
      state
    }
    Handshaking -> {
      process.send(
        reply,
        tool_provider.ToolErr(unavailable(state, "server not ready")),
      )
      state
    }
    Ready ->
      case mcp.tools_call_request(state.out, tool, arguments) {
        Error(reason) -> {
          // Refused before the wire: MCP requires an arguments OBJECT,
          // and the model sent something else.
          process.send(
            reply,
            tool_provider.ToolErr("invalid arguments: " <> reason),
          )
          state
        }
        Ok(frame) ->
          case send_frame(state, frame) {
            Error(reason) -> {
              process.send(reply, tool_provider.ToolErr(reason))
              state
            }
            Ok(Nil) -> {
              let id = state.out
              let _ =
                process.send_after(
                  state.internal,
                  state.deadline_ms,
                  RequestTimeout(id),
                )
              State(
                ..state,
                out: id + 1,
                calls: dict.insert(
                  state.calls,
                  id,
                  CallPending(ref: ref, reply: reply),
                ),
                by_ref: dict.insert(state.by_ref, ref, id),
              )
            }
          }
      }
  }
}

fn request_timeout(state: State, id: Int) -> State {
  case state.list {
    Some(#(list_id, askers, _acc, _pages)) if list_id == id ->
      fail_list(
        state,
        askers,
        "timed out after " <> int.to_string(state.deadline_ms) <> " ms",
      )
    _ ->
      case dict.get(state.calls, id) {
        Ok(pending) -> {
          // The actor-side deadline: answer the caller honestly (its
          // own deadline equals this one — first timeout wins, the
          // loser's reply is inert), and tell the server to stop.
          process.send(
            pending.reply,
            tool_provider.ToolErr(
              "mcp server '"
              <> state.server.name
              <> "' did not answer within "
              <> int.to_string(state.deadline_ms)
              <> " ms",
            ),
          )
          let _ =
            send_frame(
              state,
              mcp.cancelled_notification(id, "deadline exceeded"),
            )
          State(
            ..state,
            calls: dict.delete(state.calls, id),
            by_ref: dict.delete(state.by_ref, pending.ref),
          )
        }
        Error(Nil) -> state
      }
  }
}

/// Move to `Down`, failing every pending asker and call honestly. The
/// actor STAYS UP — a supervisor restart would kill the whole tree
/// (and boot with it) for what is an external process's exit; nexus's
/// next restart re-spawns the server.
fn degrade(state: State, reason: String) -> State {
  let unavailable_text = unavailable(state, reason)
  list.each(state.waiting, fn(asker) {
    process.send(asker, Error(unavailable_text))
  })
  case state.list {
    Some(#(_id, askers, _acc, _pages)) ->
      list.each(askers, fn(asker) {
        process.send(asker, Error(unavailable_text))
      })
    None -> Nil
  }
  state.calls
  |> dict.to_list
  |> list.each(fn(pending) {
    process.send(pending.1.reply, tool_provider.ToolErr(unavailable_text))
  })
  log(state, reason)
  State(
    ..state,
    phase: Down(reason),
    waiting: [],
    list: None,
    calls: dict.new(),
    by_ref: dict.new(),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn unavailable(state: State, reason: String) -> String {
  "mcp server '" <> state.server.name <> "' is unavailable: " <> reason
}

fn log(state: State, text: String) -> Nil {
  io.println("mcp server '" <> state.server.name <> "': " <> text)
}

fn send_frame(state: State, frame: String) -> Result(Nil, String) {
  case state.transport {
    None -> Error(unavailable(state, "no transport"))
    Some(transport) ->
      case transport.send_line(frame) {
        Ok(Nil) -> Ok(Nil)
        Error(_) -> Error(unavailable(state, "server stdin is closed"))
      }
  }
}

// ---------------------------------------------------------------------------
// Boot mount
// ---------------------------------------------------------------------------

/// Boot the MCP subsystem and build the foreign map (plugin-api plan
/// Phase 2):
///
/// 1. `NEXUS_MCP_SERVERS_JSON` empty (the default) → no tree, empty
///    map — the pre-MCP boot, byte for byte.
/// 2. Otherwise start the OneForOne `mcp_sup` (linked to the caller),
///    then ask every adapter `ListTools` under the bounded budget. An
///    adapter that will not answer DEGRADES: loud log, absent from the
///    foreign map, creates naming its tools refuse with the honest
///    400. The map is ONE value shared by the bot registry's
///    validation and the thread registry's freeze — the same
///    threading rule as the plugin table.
pub fn boot(
  cfg: Config,
) -> Result(List(#(String, tools.ForeignServer)), String) {
  case cfg.mcp_servers {
    [] -> Ok([])
    servers -> {
      use Nil <- result.try(
        case list.find(servers, fn(s) { list.contains(cfg.plugins, s.name) }) {
          Ok(s) ->
            Error(
              "mcp server '"
              <> s.name
              <> "' refused: name already used by NEXUS_PLUGINS",
            )
          Error(Nil) -> Ok(Nil)
        },
      )
      let entries =
        list.map(servers, fn(s) { #(s, tool_provider.name(s.name)) })
      let sup =
        list.fold(entries, supervisor.new(supervisor.OneForOne), fn(sup, e) {
          let #(s, name) = e
          supervisor.add(
            sup,
            supervision.worker(fn() {
              start(
                server: s,
                name: name,
                deadline_ms: option.unwrap(s.timeout_ms, cfg.plugin_timeout_ms),
              )
            }),
          )
        })
      use _started <- result.try(
        supervisor.start(sup)
        |> result.replace_error("mcp_sup failed to start"),
      )
      let mounted =
        list.fold(entries, [], fn(acc, e) {
          let #(s, name) = e
          case tool_provider.list_tools(name, boot_ask_ms) {
            Error(reason) -> {
              io.println(
                "mcp server '" <> s.name <> "' degraded (unmounted): " <> reason,
              )
              acc
            }
            Ok(_defs) -> [
              #(
                s.name,
                tools.ForeignServer(
                  name: name,
                  timeout_ms: option.unwrap(s.timeout_ms, cfg.plugin_timeout_ms),
                ),
              ),
              ..acc
            ]
          }
        })
      Ok(list.reverse(mounted))
    }
  }
}
