//// The node adapter actor + `/node/ws` socket glue (environments plan
//// Phase 2b-3): one adapter per connection, translating between the
//// client protocol (`nexus/node_protocol`, version 1) and the two
//// in-process seams it bridges — the thread's fan-out (`Join`, the
//// `ui_runtime` pattern) and the tool-provider protocol
//// (`tool_provider.Msg`, the plugin-api seam; this actor is the
//// `EnvExec` the thread actor's execution map registers).
////
//// ## Process topology (the mist constraint)
////
//// mist PANICS when a WebSocket frame is sent from any process other
//// than the socket's owner (permessage-deflate state is process-local),
//// so the socket-handler process owns every outbound frame: the adapter
//// sends finished frame STRINGS to a `frames` subject the socket
//// process created (and selects on — `mist.Custom`), and the socket
//// loop does the actual `send_text_frame`. Inbound, the socket loop
//// decodes client frames and forwards them to the adapter's subject.
//// The adapter is LINKED to the socket process (`actor.start` links to
//// its caller, the `ui_runtime` pattern): a closed or crashed socket
//// takes the adapter down, and a crashed adapter takes the socket down
//// so the node's client reconnects into a fresh pair. The thread
//// actor's monitor on the adapter pid (taken at `AttachTarget`) then
//// detaches the target through the same queueing rules as an explicit
//// `DetachTarget` — no explicit cleanup path exists or needs to.
////
//// ## Deadlines are the executor's, never the adapter's
////
//// The per-turn worker calls `tool_provider.run_remote` against this
//// actor's `(subject, pid)`: the executor arms its monitor BEFORE the
//// dispatch, enforces the per-call deadline (`NEXUS_ENV_TIMEOUT_MS`),
//// and re-signals cancel on the Stop path. The adapter therefore keeps
//// NO timers — a wedged node is answered by the executor's timeout, a
//// dead adapter by its monitor, and both render as ordinary failed
//// tool results (tool errors commit; the loop and UI are unaware).
//// Result text is capped at the boundary on receipt
//// (`NEXUS_ENV_MAX_OUTPUT_BYTES`, chars): WS frames arrive whole — the
//// frame is the read unit — so the cap lands on the first nexus-side
//// touch of the node's bytes, before anything crosses into the seam.
////
//// ## Identity and replacement
////
//// The connection's identity is the authenticated `node` row (the
//// route verified the token pre-upgrade); the row's name IS the roster
//// target. A fresh connection for a live name REPLACES the roster
//// entry — the thread actor kills the old adapter (its linked socket
//// dies with it), registers the new plane immediately, and appends NO
//// roster line (the attached list is unchanged; the model already
//// knows the target). Routing is not transcript state.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist
import nexus/config.{type Config}
import nexus/node
import nexus/node_protocol
import nexus/store.{type Store}
import nexus/thread
import nexus/thread_registry
import nexus/tool_provider.{type ToolReply}

/// The connection's role, from the route's `role` query parameter.
/// `EnvRole` (the default — the TUI is a full client) attaches with the
/// execution plane and is refused on threads whose toolset has no env
/// tools ("thread has no workspace toolset", the `UnknownToolset`
/// loud-refusal philosophy). `ViewerRole` joins any thread with the
/// event plane and `send` but no tool plane — matching the web UI's
/// read model.
pub type Role {
  EnvRole
  ViewerRole
}

// ---------------------------------------------------------------------------
// The route
// ---------------------------------------------------------------------------

/// Upgrade a request to the node WebSocket. Auth is NODE-token auth
/// (`?node=<name>&token=<token>` or `Authorization: Bearer <token>` +
/// `?node=<name>`), verified against the `node` table BEFORE the
/// upgrade — distinct from the UI token that guards the HTML/JSON
/// surface. The thread comes from `?thread=<id>` (one thread per
/// connection, the `/ws` route's model), the role from `?role=` (env
/// default). Failures answer as ordinary HTTP statuses so a client's
/// reconnect loop can tell "bad token" from "bad path".
pub fn websocket(
  req req: Request(mist.Connection),
  cfg cfg: Config,
  store store: Store,
  registry registry: Subject(thread_registry.Msg),
) -> Response(mist.ResponseData) {
  case node_credentials(req) {
    Error(_) ->
      json_response(
        401,
        json.object([#("error", json.string("node auth required"))]),
      )
    Ok(#(name, token)) ->
      case authenticate(store, name, token) {
        Error(_) ->
          json_response(
            401,
            json.object([#("error", json.string("unknown node or bad token"))]),
          )
        Ok(row) -> {
          let _ = store.touch_node(row.id)
          case thread_id_from(req) {
            Error(_) ->
              json_response(
                400,
                json.object([
                  #("error", json.string("thread parameter required")),
                ]),
              )
            Ok(thread_id) ->
              case thread_registry.get(registry, thread_id) {
                Error(_) ->
                  json_response(
                    404,
                    json.object([#("error", json.string("thread not found"))]),
                  )
                Ok(thread_subject) -> {
                  let role = role_from(req)
                  // The env-capability ask runs for the ENV role only:
                  // a viewer connection never pays the registry round
                  // trip (its join is ungated).
                  case role {
                    EnvRole ->
                      case env_capable(registry, thread_id) {
                        False ->
                          json_response(
                            403,
                            json.object([
                              #(
                                "error",
                                json.string("thread has no workspace toolset"),
                              ),
                            ]),
                          )
                        True ->
                          node_upgrade(
                            req,
                            cfg,
                            thread_id,
                            thread_subject,
                            store,
                            row,
                            role,
                          )
                      }
                    ViewerRole ->
                      node_upgrade(
                        req,
                        cfg,
                        thread_id,
                        thread_subject,
                        store,
                        row,
                        role,
                      )
                  }
                }
              }
          }
        }
      }
  }
}

/// The mist upgrade, shared by both roles past their gates.
fn node_upgrade(
  req: Request(mist.Connection),
  cfg: Config,
  thread_id: String,
  thread_subject: Subject(thread.Msg),
  store: Store,
  row: node.Node,
  role: Role,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      init_socket(cfg, thread_id, thread_subject, row, role)
    },
    handler: loop_socket,
    // The clean stop for the NORMAL close path (the ui_runtime
    // close_socket rule): the link alone covers ABNORMAL deaths — a
    // crashed socket, the replace-kill — because an actor's own normal
    // exit does not rupture links. Killing here is exit-reason-agnostic
    // for the thread actor's monitor (any exit spends it) and immediate.
    // The last-seen bump rides the same clean close (tui-pairing plan,
    // hygiene): a TUI connected right up to a server shutdown must
    // carry a FRESH stamp into the next boot's idle-node sweep, or the
    // sweep — which runs before any reconnect can re-stamp it — would
    // take a still-in-use credential. Best-effort like the connect-time
    // touch; an ABNORMAL death (crash, replace-kill) skips it, which is
    // exactly the "crashed TUI" case the idle window exists for.
    on_close: fn(state) {
      process.kill(state.adapter_pid)
      let _ = store.touch_node(state.node_id)
      Nil
    },
  )
}

/// `(name, token)` from the query string, with the token also accepted
/// as a bearer header (the `authorized` precedent: a WS client cannot
/// always set headers, and a script always can).
fn node_credentials(
  req: Request(mist.Connection),
) -> Result(#(String, String), Nil) {
  let name = query_param(req, "node") |> result.map(string.trim)
  let token = case request.get_header(req, "authorization") {
    Ok("Bearer " <> bearer) -> Ok(bearer)
    _ -> query_param(req, "token")
  }
  case name, token {
    Ok(n), Ok(t) ->
      case n != "" && t != "" {
        True -> Ok(#(n, t))
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn thread_id_from(req: Request(mist.Connection)) -> Result(String, Nil) {
  query_param(req, "thread")
  |> result.map(string.trim)
  |> result.try(fn(id) {
    case id {
      "" -> Error(Nil)
      _ -> Ok(id)
    }
  })
}

fn role_from(req: Request(mist.Connection)) -> Role {
  case query_param(req, "role") {
    Ok("viewer") -> ViewerRole
    _ -> EnvRole
  }
}

fn env_capable(
  registry: Subject(thread_registry.Msg),
  thread_id: String,
) -> Bool {
  thread_registry.env_capable(registry, thread_id)
}

/// Stateless per-connection verify: the named row's stored hash against
/// the presented token (`node.verify_token`, constant-time). A wrong
/// name and a wrong token answer identically — the 401 carries no
/// oracle. `touch_node` (last-seen) is best-effort at the route AND at
/// the clean close (the idle-node sweep's freshness contract — see
/// `node_upgrade`'s on_close).
fn authenticate(
  store: Store,
  name: String,
  token: String,
) -> Result(node.Node, Nil) {
  case store.get_node_by_name(name) {
    Ok(row) ->
      case node.verify_token(token, row.token_hash) {
        True -> Ok(row)
        False -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn query_param(req: Request(a), key: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(pairs) ->
      list.find_map(pairs, fn(pair) {
        case pair {
          #(k, value) if k == key -> Ok(value)
          _ -> Error(Nil)
        }
      })
    Error(_) -> Error(Nil)
  }
}

fn json_response(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

// ---------------------------------------------------------------------------
// The socket loop (runs in the socket-owner process — every outbound
// frame is SENT here, never from the adapter; see the module doc)
// ---------------------------------------------------------------------------

type SocketState {
  SocketState(
    adapter: Subject(Msg),
    adapter_pid: process.Pid,
    frames: Subject(String),
    max_frame_bytes: Int,
    /// The authenticated row's id, for the clean-close last-seen bump
    /// (see `node_upgrade`'s on_close).
    node_id: String,
  )
}

/// The socket loop's custom messages: outbound frames (written HERE —
/// only the socket owner may touch the connection) and the adapter's
/// exit, which closes the socket.
type SocketMsg {
  Frame(String)
  AdapterGone
}

/// The inbound frame bound (bytes): the receive-layer half of the
/// external-transport cap rule. mist assembles a WS frame whole —
/// there is no mid-frame hook — so this is the FIRST nexus-side touch:
/// an oversized frame is refused and the connection closed before it
/// is decoded, forwarded, or queued anywhere. The budget must let
/// every LEGITIMATE frame through: a node may JSON-escape aggressively
/// (control chars as `\\uXXXX` are 6 bytes per char; an
/// encoder-agnostic ceiling is an escaped surrogate pair, 12 bytes per
/// char), so a result within `max_output_chars` can still be several
/// times that in wire bytes — 12x plus headroom for the envelope keeps
/// "capped result ⇒ frame accepted" true for any encoder while still
/// bounding hostile frames hard.
pub fn max_frame_bytes(max_output_chars: Int) -> Int {
  max_output_chars * 12 + 16_384
}

fn init_socket(
  cfg: Config,
  thread_id: String,
  thread_subject: Subject(thread.Msg),
  row: node.Node,
  role: Role,
) -> #(SocketState, option.Option(process.Selector(SocketMsg))) {
  let frames = process.new_subject()
  // Linked to THIS process (the socket owner): the pair die together
  // on ABNORMAL exits. The MONITOR below adds the normal-exit half:
  // the adapter refuses an attach with `actor.stop()` (a normal exit,
  // which does not rupture links), so the socket watches for its death
  // and closes — queued frames flush first (they were sent before the
  // stop, so they sit ahead of the DOWN in this mailbox).
  let assert Ok(adapter) =
    start_adapter(cfg, thread_id, thread_subject, row.name, role, frames)
  let assert Ok(adapter_pid) = process.subject_owner(adapter)
  let monitor = process.monitor(adapter_pid)
  #(
    SocketState(
      adapter: adapter,
      adapter_pid: adapter_pid,
      frames: frames,
      max_frame_bytes: max_frame_bytes(cfg.env_max_output_bytes),
      node_id: row.id,
    ),
    Some(
      process.new_selector()
      |> process.select_map(frames, Frame)
      |> process.select_specific_monitor(monitor, fn(_) { AdapterGone }),
    ),
  )
}

/// Start the adapter actor, linked to the CALLER (the socket-owner
/// process in production; the test process offline — the same seam
/// `ui_runtime` gives the browser suite). The caller owns `frames` and
/// therefore every outbound byte.
pub fn start_adapter(
  cfg: Config,
  thread_id: String,
  thread_subject: Subject(thread.Msg),
  name: String,
  role: Role,
  frames: Subject(String),
) -> Result(Subject(Msg), Nil) {
  let started =
    actor.new_with_initialiser(2000, fn(self) {
      adapter_initialiser(
        self,
        cfg,
        thread_id,
        thread_subject,
        name,
        role,
        frames,
      )
    })
    |> actor.on_message(handle)
    |> actor.start
  case started {
    Ok(ok) -> Ok(ok.data)
    Error(_) -> Error(Nil)
  }
}

fn loop_socket(
  state: SocketState,
  message: mist.WebsocketMessage(SocketMsg),
  connection: mist.WebsocketConnection,
) -> mist.Next(SocketState, SocketMsg) {
  case message {
    mist.Text(text) ->
      case string.byte_size(text) > state.max_frame_bytes {
        True -> {
          // Over the receive bound: refuse and close (the external-
          // transport cap rule enforced at the first nexus-side touch
          // — see `max_frame_bytes`).
          let _ =
            mist.send_text_frame(
              connection,
              node_protocol.encode_error("frame exceeds the size bound"),
            )
          mist.stop()
        }
        False ->
          case node_protocol.decode_client_frame(text) {
            Ok(frame) -> {
              process.send(state.adapter, FrameIn(frame))
              mist.continue(state)
            }
            Error(_) -> {
              // Undecodable inbound frame: tell the client, keep the
              // socket (a TUI mid-upgrade or a probing client should
              // not lose their connection over one bad frame).
              let _ =
                mist.send_text_frame(
                  connection,
                  node_protocol.encode_error("unrecognized frame"),
                )
              mist.continue(state)
            }
          }
      }
    mist.Custom(Frame(frame)) -> {
      let _ = mist.send_text_frame(connection, frame)
      mist.continue(state)
    }
    // The adapter exited normally (an attach refusal's `actor.stop()`):
    // the refusal frame was queued ahead of the DOWN, so it flushed —
    // close now so the node's client reconnects into the post-race
    // state instead of sitting on a dead socket.
    mist.Custom(AdapterGone) -> mist.stop()
    // Binary frames have no v1 meaning; the error frame says so.
    mist.Binary(_) -> {
      let _ =
        mist.send_text_frame(
          connection,
          node_protocol.encode_error("binary frames are not supported"),
        )
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

// ---------------------------------------------------------------------------
// The adapter actor
// ---------------------------------------------------------------------------

pub type Msg {
  /// One decoded inbound client frame (from the socket loop).
  FrameIn(node_protocol.ClientFrame)
  /// The provider-protocol half: `Call`/`Cancelled` from a per-turn
  /// worker's executor (the subject the thread actor's execution map
  /// hands out), `ListTools` from nobody in particular today.
  Provider(tool_provider.Msg)
  /// One fan-out event from the thread (the subscription's delivery).
  Event(thread.ThreadEvent)
  /// The `AttachTarget` ask's answer.
  AttachAccepted(Result(Nil, String))
  /// The thread actor's monitor fired: it exited (a registry restart
  /// brings a FRESH actor — new subject, empty fan-out, empty exec
  /// map), so this connection is a zombie: no events will ever arrive,
  /// sends to the dead subject drop silently, and the restarted actor
  /// no longer routes here. Tell the node and stop; the socket-side
  /// monitor then closes the connection so the node reconnects into
  /// the restarted thread (fresh Join + AttachTarget).
  ThreadGone
}

type Pending {
  Pending(ref: Reference, reply: Subject(ToolReply))
}

type State {
  State(
    thread: Subject(thread.Msg),
    thread_id: String,
    name: String,
    role: Role,
    frames: Subject(String),
    pending: Dict(Int, Pending),
    next_id: Int,
    max_output_chars: Int,
    self: Subject(Msg),
  )
}

/// The adapter's initialiser body (extracted for readability — run by
/// `actor.new_with_initialiser`, so `self` is the actor's own subject
/// and every subject created here is owned by the actor process).
fn adapter_initialiser(
  self: Subject(Msg),
  cfg: Config,
  thread_id: String,
  thread_subject: Subject(thread.Msg),
  name: String,
  role: Role,
  frames: Subject(String),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  // Resolve and MONITOR the thread owner BEFORE any message to it
  // (CodeRabbit review): in production the subject is NAMED — a
  // registry restart re-registers a replacement under the same name —
  // so messages and the owner lookup can otherwise disagree about
  // WHICH actor. Monitor-first makes every interleaving self-healing:
  // if the sends land on the replacement while the monitor holds the
  // old owner, the old owner's DOWN fires and the node reconnects; the
  // unhealable state (monitor on the live replacement, messages lost
  // to the dead predecessor) cannot arise. An unresolvable owner fails
  // the start — the socket drops and the client reconnects.
  case process.subject_owner(thread_subject) {
    Error(_) -> Error("thread actor unavailable")
    Ok(owner_pid) -> {
      let thread_mon = process.monitor(owner_pid)
      let events = process.new_subject()
      // Join the fan-out exactly like a Lustre runtime: Hello + replay
      // (mid-turn joins replay the display mirror) land on `events`.
      process.send(thread_subject, thread.Join(events, 1))
      // The execution plane THIS actor offers: its provider-protocol
      // subject (a dedicated owned subject — `EnvExec.sub` is typed
      // `Subject(tool_provider.Msg)`, selected into `Provider` below)
      // and its pid (what the thread actor monitors).
      let provider_sub = process.new_subject()
      let attach_reply = process.new_subject()
      case role {
        EnvRole ->
          process.send(
            thread_subject,
            thread.AttachTarget(
              name,
              Some(thread.EnvExec(provider_sub, process.self())),
              attach_reply,
            ),
          )
        // Viewer: no attach, no execution plane — the reply subject
        // simply never fires (the selector mapping is harmless).
        ViewerRole -> Nil
      }
      let state =
        State(
          thread: thread_subject,
          thread_id: thread_id,
          name: name,
          role: role,
          frames: frames,
          pending: dict.new(),
          next_id: 1,
          max_output_chars: cfg.env_max_output_bytes,
          self: self,
        )
      actor.initialised(state)
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_map(events, Event)
        |> process.select_map(provider_sub, Provider)
        |> process.select_map(attach_reply, AttachAccepted)
        |> process.select_specific_monitor(thread_mon, fn(_) { ThreadGone }),
      )
      |> Ok
    }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    FrameIn(frame) -> handle_client_frame(state, frame)
    Provider(msg) -> handle_provider(state, msg)
    Event(event) -> {
      // The subscription's filter key, applied defensively: this
      // adapter serves exactly one thread, and every delivery names
      // its emitter.
      case event.thread_id == state.thread_id {
        False -> actor.continue(state)
        True -> {
          case node_protocol.event_frame(event) {
            Ok(frame) -> send_frame(state, frame)
            Error(_) -> Nil
          }
          actor.continue(state)
        }
      }
    }
    AttachAccepted(Ok(Nil)) -> {
      // Env role only: the viewer never attached, so it never hears
      // `attached` (its first post-replay frame is live events).
      case state.role {
        EnvRole -> send_frame(state, node_protocol.encode_attached(state.name))
        ViewerRole -> Nil
      }
      actor.continue(state)
    }
    ThreadGone -> {
      // The thread actor died; the registry's replacement does not know
      // this adapter. Say why, then stop. The wording is deliberately
      // neutral: the exit may be a restart (reconnecting lands on the
      // replacement) OR a thread deletion (reconnecting will 404) —
      // the node decides from its own retry policy.
      send_frame(state, node_protocol.encode_error("thread actor exited"))
      actor.stop()
    }
    AttachAccepted(Error(reason)) -> {
      // Refused at attach (e.g. a roster race): tell the node why, then
      // die — the linked socket closes and the client reconnects into
      // the post-race state.
      send_frame(
        state,
        node_protocol.encode_error("attach refused: " <> reason),
      )
      actor.stop()
    }
  }
}

fn handle_client_frame(
  state: State,
  frame: node_protocol.ClientFrame,
) -> actor.Next(State, Msg) {
  case frame {
    node_protocol.Send(text) ->
      case string.trim(text) {
        "" -> {
          send_frame(state, node_protocol.encode_error("empty message"))
          actor.continue(state)
        }
        trimmed -> {
          // The same path the web UI and POST /threads/<id>/send use.
          // A bounded ask (the thread actor answers fast — it starts a
          // worker or refuses Busy); the UserEcho lands as an Event.
          case thread.send_message(state.thread, trimmed) {
            thread.Sent -> actor.continue(state)
            thread.Busy -> {
              send_frame(
                state,
                node_protocol.encode_error("a reply is already streaming"),
              )
              actor.continue(state)
            }
            // An archived channel refuses human Sends (bot-channels
            // plan, #123): the honest reason rides the error frame.
            thread.Refused(reason) -> {
              send_frame(state, node_protocol.encode_error(reason))
              actor.continue(state)
            }
          }
        }
      }
    node_protocol.Ping -> {
      send_frame(state, node_protocol.encode_pong())
      actor.continue(state)
    }
    node_protocol.CallResponse(id, ok, text) -> {
      let capped = tool_provider.truncate(text, state.max_output_chars)
      case dict.get(state.pending, id) {
        Ok(Pending(_ref, reply)) -> {
          process.send(reply, case ok {
            True -> tool_provider.ToolOk(capped)
            False -> tool_provider.ToolErr(capped)
          })
          actor.continue(
            State(..state, pending: dict.delete(state.pending, id)),
          )
        }
        // A late response after cancel/timeout: its call already ended
        // (the executor's reply subject is per-call), so there is
        // nothing to answer — dropped, not fatal.
        Error(_) -> actor.continue(state)
      }
    }
  }
}

fn handle_provider(
  state: State,
  msg: tool_provider.Msg,
) -> actor.Next(State, Msg) {
  case msg {
    tool_provider.Call(ref, tool, arguments, reply) ->
      case node_protocol.valid_arguments(arguments) {
        False -> {
          process.send(
            reply,
            tool_provider.ToolErr(
              "node adapter: arguments are not a JSON object",
            ),
          )
          actor.continue(state)
        }
        True -> {
          let id = state.next_id
          send_frame(
            state,
            node_protocol.encode_call_request(id, tool, arguments),
          )
          actor.continue(
            State(
              ..state,
              next_id: id + 1,
              pending: dict.insert(state.pending, id, Pending(ref, reply)),
            ),
          )
        }
      }
    tool_provider.Cancelled(ref) -> {
      // Best-effort by contract: tell the node, drop the pending entry
      // (the caller already ended the call; a late response will find
      // no entry and is ignored).
      case
        list.find(dict.to_list(state.pending), fn(entry) { entry.1.ref == ref })
      {
        Ok(#(id, _pending)) -> {
          send_frame(state, node_protocol.encode_cancelled(id))
          actor.continue(
            State(..state, pending: dict.delete(state.pending, id)),
          )
        }
        Error(_) -> actor.continue(state)
      }
    }
    tool_provider.ListTools(reply) -> {
      // Nodes serve the COMPILED environment tools — there is no list
      // to ask for; the catalog owns the schemas. Honest refusal, the
      // same posture as an unreachable provider.
      process.send(reply, Error("node adapters have no tool list"))
      actor.continue(state)
    }
  }
}

/// One outbound frame: handed to the socket-owner process (which alone
/// may touch the connection — the mist constraint).
fn send_frame(state: State, frame: String) -> Nil {
  process.send(state.frames, frame)
}
