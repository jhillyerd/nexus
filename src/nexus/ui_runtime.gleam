//// M3 runtime wiring for the Lustre server component: app construction,
//// supervision child spec, WebSocket upgrade glue, and the client-runtime
//// asset route.
////
//// One persistent, named component runtime is started by `nexus/boot`
//// between the session registry and Mist. Each WebSocket connection
//// registers a fresh subject with that shared runtime (the multi-client
//// pattern); closing a socket deregisters only that subject — the
//// component itself keeps running with its model and subscriptions intact,
//// which is what gives reconnects their snapshot/replay semantics.

import gleam/erlang/application
import gleam/erlang/process.{type Name, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/supervision
import lustre
import lustre/component
import lustre/server_component.{type ClientMessage}
import mist
import nexus/provider_registry
import nexus/session_registry
import nexus/ui

/// Name for the shared component runtime, created once in `nexus/boot`.
pub type ComponentName =
  Name(lustre.RuntimeMessage(ui.Msg))

pub type Flags =
  ui.Flags

/// The M3 app: the M2 UI as a Lustre server component. `on_connect` /
/// `on_disconnect` track connected clients and drive reconnect behaviour.
pub fn app(name: ComponentName) -> lustre.App(Flags, ui.Model, ui.Msg) {
  lustre.component(init: ui.init, update: ui.update, view: ui.view, options: [
    component.on_connect(ui.ClientConnected),
    component.on_disconnect(ui.ClientDisconnected),
    // Lustre server components always render into a shadow root; an *open*
    // root keeps the rendered tree pierceable (integration tests, browser
    // devtools) while `adopt_styles` (on by default) clones the page's
    // stylesheet in so the M3 markup stays styled exactly like M2.
    component.open_shadow_root(True),
  ])
  |> lustre.named(name)
}

/// Child specification for the root supervisor: a named, supervised server
/// component. Started after the registry (it resolves sessions through it)
/// and before Mist (the WebSocket handler looks it up by name).
pub fn supervised(
  name: ComponentName,
  registry: Subject(session_registry.Msg),
  providers: Subject(provider_registry.Msg),
) -> supervision.ChildSpecification(Subject(lustre.RuntimeMessage(ui.Msg))) {
  lustre.supervised(
    app(name),
    ui.Flags(registry: registry, providers: providers),
  )
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

/// Upgrade a request to the component's WebSocket transport. The browser-side
/// runtime (served from `/lustre/runtime.mjs`) connects here.
pub fn websocket(
  req: Request(mist.Connection),
  runtime: lustre.Runtime(ui.Msg),
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) { init_socket(runtime) },
    handler: loop_socket,
    on_close: close_socket,
  )
}

fn init_socket(
  runtime: lustre.Runtime(ui.Msg),
) -> #(SocketState, option.Option(process.Selector(ClientMessage(ui.Msg)))) {
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
  // Only deregister this connection's subject: the shared runtime (and the
  // session subscription it owns) survives for reconnects and other clients.
  server_component.deregister_subject(state.client)
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

/// Recover the shared `Runtime` handle from its registered name. `Runtime`
/// is the runtime's `Subject` under the hood (same coercion Lustre itself
/// uses in `server_component.subject`), which is what makes name-based
/// lookup after a supervised restart work.
@external(erlang, "gleam@function", "identity")
fn coerce_runtime(
  subject: Subject(lustre.RuntimeMessage(ui.Msg)),
) -> lustre.Runtime(ui.Msg)

pub fn runtime_from_name(
  name: Name(lustre.RuntimeMessage(ui.Msg)),
) -> lustre.Runtime(ui.Msg) {
  coerce_runtime(process.named_subject(name))
}
