//// Runtime wiring for the Lustre server component: app construction,
//// per-connection runtime startup, WebSocket upgrade glue, and the
//// client-runtime asset route.
////
//// Each WebSocket connection gets its **own** component runtime and model
//// (the per-client break): `init_socket` starts one via
//// `lustre.start_server_component` and registers the socket's subject with
//// it — closing a socket deregisters only that subject because the runtime
//// itself is going away. gleam_otp's `actor.start` spawns the runtime
//// linked to the calling process — the socket handler — and the runtime
//// does not trap exits, so the pair die together: a closed or crashed
//// socket takes its runtime (and session subscription) down, and a crashed
//// runtime takes the socket down so the browser reconnects into a fresh
//// runtime. Nothing is shared between browsers, so tabs no longer mirror
//// each other's selected session or panels; sessions themselves are
//// server-global, so every client still sees the same sidebar.
////
//// A reload therefore boots a fresh model: the page shell (`nexus/page`)
//// persists the client's last-selected session and re-supplies it as the
//// `/ws` route's `session` query parameter, which lands in
//// `ui.Flags.session` so `init` re-opens that session (Hello + replay
//// re-render the transcript).

import gleam/erlang/application
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/component
import lustre/server_component.{type ClientMessage}
import mist
import nexus/provider_registry
import nexus/session_registry
import nexus/ui

pub type Flags =
  ui.Flags

/// The chat UI as a Lustre server component, started once per WebSocket
/// connection. There are deliberately no on_connect/on_disconnect hooks:
/// one runtime serves exactly one client for its whole life, so connect is
/// `init` and disconnect is the runtime dying with its socket.
pub fn app() -> lustre.App(Flags, ui.Model, ui.Msg) {
  lustre.component(init: ui.init, update: ui.update, view: ui.view, options: [
    // Lustre server components always render into a shadow root; an *open*
    // root keeps the rendered tree pierceable (integration tests, browser
    // devtools) while `adopt_styles` (on by default) clones the page's
    // stylesheet in so the M3 markup stays styled exactly like M2.
    component.open_shadow_root(True),
  ])
}

// ---------------------------------------------------------------------------
// WebSocket glue
// ---------------------------------------------------------------------------

type SocketState {
  SocketState(
    runtime: lustre.Runtime(ui.Msg),
    client: Subject(ClientMessage(ui.Msg)),
  )
}

/// Upgrade a request to the component's WebSocket transport, starting a
/// dedicated runtime for this connection. The browser-side runtime (served
/// from `/lustre/runtime.mjs`) connects here.
pub fn websocket(
  req: Request(mist.Connection),
  registry: Subject(session_registry.Msg),
  providers: Subject(provider_registry.Msg),
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) { init_socket(runtime_flags(req, registry, providers)) },
    handler: loop_socket,
    on_close: close_socket,
  )
}

/// The per-connection flags: the registry/provider subjects plus the
/// client-supplied last-selected session from the route's query string
/// (the page shell persists it; see `nexus/page`).
fn runtime_flags(
  req: Request(mist.Connection),
  registry: Subject(session_registry.Msg),
  providers: Subject(provider_registry.Msg),
) -> Flags {
  ui.Flags(
    registry: registry,
    providers: providers,
    session: query_param(req, "session"),
  )
}

fn query_param(req: Request(mist.Connection), key: String) -> Option(String) {
  case request.get_query(req) {
    Ok(pairs) ->
      case list.key_find(pairs, key) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn init_socket(
  flags: Flags,
) -> #(SocketState, option.Option(process.Selector(ClientMessage(ui.Msg)))) {
  // One runtime per connection, linked to this socket process (see the
  // module doc). `start_server_component` only fails if the actor cannot
  // start at all; crashing here drops the socket and the client runtime
  // reconnects to try again.
  let assert Ok(runtime) = lustre.start_server_component(app(), flags)
  let client = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(client)
  server_component.register_subject(client)
  |> lustre.send(to: runtime)
  #(SocketState(runtime:, client:), Some(selector))
}

fn loop_socket(
  state: SocketState,
  message: mist.WebsocketMessage(ClientMessage(ui.Msg)),
  connection: mist.WebsocketConnection,
) -> mist.Next(SocketState, ClientMessage(ui.Msg)) {
  case message {
    mist.Text(text) -> {
      case json.parse(text, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.runtime, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }

    mist.Custom(client_message) -> {
      let payload = server_component.client_message_to_json(client_message)
      let _ = mist.send_text_frame(connection, json.to_string(payload))
      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: SocketState) -> Nil {
  // The link already ties the runtime to this socket process; shutdown is
  // the clean stop for the normal close path. No deregistration is needed:
  // the runtime served exactly this client and is going away with it.
  lustre.shutdown()
  |> lustre.send(to: state.runtime)
}

// ---------------------------------------------------------------------------
// Client runtime asset
// ---------------------------------------------------------------------------

/// Serve Lustre's pre-built server-component client runtime from the
/// package's private static directory.
pub fn runtime_asset_response() -> Result(Response(mist.ResponseData), Nil) {
  case application.priv_directory("lustre") {
    Error(_) -> Error(Nil)
    Ok(priv) -> {
      let file = priv <> "/static/lustre-server-component.mjs"
      case mist.send_file(file, offset: 0, limit: None) {
        Ok(sent) ->
          response.new(200)
          |> response.prepend_header("content-type", "application/javascript")
          |> response.set_body(sent)
          |> Ok
        Error(_) -> Error(Nil)
      }
    }
  }
}
