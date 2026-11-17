//// The `/node/ws` client protocol, version 1 (environments plan Phase
//// 2b-3): the pure frame codec. Everything here is JSON over one
//// WebSocket — deliberately NOT Lustre's `/ws` server-component
//// protocol, which is Lustre-internal and version-coupled to the
//// generated `runtime.mjs` it ships with. This is a nexus-owned,
//// versioned (`"v":1`), additive-only wire format: every frame is a
//// JSON object carrying `"v":1`, new fields and new frame types may be
//// added over time, and existing fields never change meaning or shape.
////
//// Two planes share the socket (see `docs/plans/environments.md`):
////
////   - **Event plane** (server→client): a JSON projection of
////     `thread.ThreadEvent` — transcript lines, tool chips, turn
////     lifecycle, metrics. The TUI renders from these exactly like the
////     web UI renders from the Lustre events.
////   - **Tool plane** (bidirectional, MCP-shaped JSON-RPC): `tools/call`
////     requests flow server→client, JSON-RPC responses flow
////     client→server, and `notifications/cancelled` flows server→client
////     — the third deployment of the provider protocol
////     (`docs/plans/plugin-api.md`). Familiar shapes, zero novel
////     semantics: a future standalone MCP listener on the node could
////     share the handler. MCP-SHAPED, not MCP-exact: `params.arguments`
////     carries the call's argument JSON **verbatim** (the same bytes the
////     model produced), embedded without re-serialization, and results
////     are a single flattened text rather than a raw content array.
////
//// Client→server user input (`send`) rides the same socket via the same
//// `Send` path the web UI and `POST /threads/<id>/send` use.
////
//// This module is a pure leaf over `json`/`decode` plus the event types
//// — no actors, no network — so the whole codec is offline-testable
//// against strings alone (the store-seam discipline applied to a wire
//// format: owned boundary, versioned deliberately, mockable offline).

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/openai
import nexus/thread

pub const version = 1

// ---------------------------------------------------------------------------
// Client → server frames
// ---------------------------------------------------------------------------

/// One decoded inbound frame. The JSON-RPC response is the tool plane's
/// answer half; `Send` is user input; `Ping` is liveness.
pub type ClientFrame {
  /// `{"v":1,"type":"send","text":"…"}` — a human turn from the TUI.
  Send(text: String)
  /// `{"v":1,"type":"ping"}` — answered `pong`.
  Ping
  /// A `tools/call` response: the flattened result text plus the
  /// MCP `isError` outcome flag.
  CallResponse(id: Int, ok: Bool, text: String)
}

/// Decode one inbound frame. Unknown frame types, malformed JSON, and
/// wrong-version frames all refuse (`Error(Nil)`): the connection-level
/// policy (an error frame, or a close) belongs to the adapter, not the
/// codec.
pub fn decode_client_frame(text: String) -> Result(ClientFrame, Nil) {
  use shape <- result.try(
    json.parse(text, using: shape_decoder()) |> result.replace_error(Nil),
  )
  case shape {
    ShapeSend ->
      json.parse(text, using: send_decoder()) |> result.replace_error(Nil)
    ShapePing -> Ok(Ping)
    ShapeResponse ->
      json.parse(text, using: response_decoder()) |> result.replace_error(Nil)
    ShapeUnknown -> Error(Nil)
  }
}

type FrameShape {
  ShapeSend
  ShapePing
  ShapeResponse
  ShapeUnknown
}

/// Discriminate the inbound shape: the JSON-RPC response carries
/// `"jsonrpc"` (per the wire shape) and an `id`; user frames carry
/// `type`. The version is checked once here for every shape.
fn shape_decoder() -> decode.Decoder(FrameShape) {
  use v <- decode.field("v", decode.int)
  use kind <- decode.optional_field(
    "type",
    None,
    decode.optional(decode.string),
  )
  use jsonrpc <- decode.optional_field("jsonrpc", "", decode.string)
  decode.success(case v == version, kind, jsonrpc {
    True, Some("send"), _ -> ShapeSend
    True, Some("ping"), _ -> ShapePing
    True, _, "2.0" -> ShapeResponse
    _, _, _ -> ShapeUnknown
  })
}

fn send_decoder() -> decode.Decoder(ClientFrame) {
  use text <- decode.field("text", decode.string)
  decode.success(Send(text))
}

/// The JSON-RPC response half: `{"v":1,"jsonrpc":"2.0","id":N,
/// "result":{"content":[{"type":"text","text":"…"}],"isError":b}}`.
/// MCP-shaped — `content` is a list of typed parts and the texts are
/// joined in order; a missing `isError` reads false (MCP's default).
/// A JSON-RPC error-object response (`"error":{"message":…}`) decodes
/// as a FAILED call carrying the message, and a response with neither
/// a result nor an error object is a failed call too — a hostile or
/// minimal client cannot smuggle a success past a refused call.
fn response_decoder() -> decode.Decoder(ClientFrame) {
  use id <- decode.field("id", decode.int)
  use err <- decode.optional_field(
    "error",
    None,
    decode.optional(error_message_decoder()),
  )
  use res <- decode.optional_field(
    "result",
    None,
    decode.optional(result_decoder()),
  )
  decode.success(case err, res {
    Some(message), _ -> CallResponse(id, False, message)
    None, Some(#(is_error, text)) -> CallResponse(id, !is_error, text)
    None, None -> CallResponse(id, False, "node sent a response with no result")
  })
}

fn error_message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

fn result_decoder() -> decode.Decoder(#(Bool, String)) {
  use is_error <- decode.optional_field("isError", False, decode.bool)
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(text_part_decoder()),
  )
  decode.success(#(is_error, string.join(content, "")))
}

fn text_part_decoder() -> decode.Decoder(String) {
  use part_type <- decode.optional_field("type", "", decode.string)
  use text <- decode.optional_field("text", "", decode.string)
  decode.success(case part_type {
    "text" -> text
    // Non-text content parts (images, resources) have no v1 projection
    // — skipped, not fatal; a text part elsewhere in the list still
    // lands. Additive-only growth can add them later.
    _ -> ""
  })
}

// ---------------------------------------------------------------------------
// Server → client frames: the event plane
// ---------------------------------------------------------------------------

/// Project one fan-out event into its wire frame. Pure: the same event
/// always encodes the same frame. The emitting-thread filter is the
/// ADAPTER's (it knows which thread it serves); the codec encodes
/// whatever it is given.
pub fn event_frame(event: thread.ThreadEvent) -> Result(String, Nil) {
  let thread.ThreadEvent(thread_id: _id, visit: _, kind: kind) = event
  let body = case kind {
    thread.Hello(model, messages, _metrics) ->
      // Metrics have no v1 projection (the TUI's per-turn numbers ride
      // `turn_done.stats`); additive growth can add a metrics array.
      object("hello", [
        #("model", json.string(model)),
        #("messages", json.int(messages)),
      ])
    thread.UserEcho(text, at, author) ->
      object("user", [
        #("text", json.string(text)),
        #("at", optional_int(at)),
        #("author", optional_string(author)),
      ])
    thread.AssistantFull(text, at) ->
      object("assistant", [
        #("text", json.string(text)),
        #("at", optional_int(at)),
      ])
    thread.ReasoningFull(text) ->
      object("reasoning_full", [#("text", json.string(text))])
    thread.Token(text) -> object("token", [#("text", json.string(text))])
    thread.Reasoning(text) ->
      object("reasoning", [#("text", json.string(text))])
    thread.TurnDone(stats, at) ->
      object("turn_done", [
        #("at", optional_int(at)),
        #("stats", stats_json(stats)),
      ])
    thread.TurnStopped(chars, at) ->
      object("turn_stopped", [
        #("chars", json.int(chars)),
        #("at", optional_int(at)),
      ])
    thread.TurnFailed(reason, at) ->
      object("turn_failed", [
        #("reason", json.string(reason)),
        #("at", optional_int(at)),
      ])
    thread.ToolCallDelta(index, id, name, fragment) ->
      object("tool_call_delta", [
        #("index", json.int(index)),
        #("id", optional_string(id)),
        #("name", optional_string(name)),
        #("fragment", json.string(fragment)),
      ])
    thread.ToolCallAssembled(call_id, name, arguments, at) ->
      object("tool_call", [
        #("id", json.string(call_id)),
        #("name", json.string(name)),
        #("arguments", json.string(arguments)),
        #("at", optional_int(at)),
      ])
    thread.ToolResult(call_id, name, ok, content) ->
      object("tool_result", [
        #("call_id", json.string(call_id)),
        #("name", json.string(name)),
        #("ok", json.bool(ok)),
        #("content", json.string(content)),
      ])
    thread.LoopStatus(iteration, max_iterations, phase) ->
      object("loop_status", [
        #("iteration", json.int(iteration)),
        #("max", json.int(max_iterations)),
        #("phase", json.string(phase)),
      ])
    thread.MetaUpdated(title, tags) ->
      object("meta", [
        #("title", optional_string(title)),
        #("tags", json.array(tags, json.string)),
      ])
  }
  Ok(json.to_string(body))
}

/// The turn metrics a TUI renders per turn — the same numbers the web
/// UI's metrics panel shows. A projection, never a request byte.
fn stats_json(stats: openai.StreamStats) -> Json {
  json.object([
    #("ttft_ms", optional_int(stats.ttft_ms)),
    #("duration_ms", json.int(stats.duration_ms)),
    #("token_deltas", json.int(stats.token_deltas)),
    #("reasoning_deltas", json.int(stats.reasoning_deltas)),
    #("tool_call_deltas", json.int(stats.tool_call_deltas)),
  ])
}

// ---------------------------------------------------------------------------
// Client → server frames: encoders (the TUI's sending half)
// ---------------------------------------------------------------------------

/// `{"v":1,"type":"send","text":…}` — a human turn from the TUI. The
/// mirror of `send_decoder`; escapes through `json` so hostile text
/// cannot shape the frame. (Built with the `json` encoder — same
/// compact bytes, no hand-escaped string literals.)
pub fn encode_send(text: String) -> String {
  json.to_string(object("send", [#("text", json.string(text))]))
}

/// `{"v":1,"type":"ping"}` — liveness, answered `pong`.
pub fn encode_ping() -> String {
  json.to_string(object("ping", []))
}

/// The `tools/call` response half: `{"v":1,"jsonrpc":"2.0","id":N,
/// "result":{"content":[{"type":"text","text":…}],"isError":b}}`. The
/// mirror of `response_decoder` (whose `CallResponse.ok` is the INVERTED
/// wire flag — here the argument is the wire's own `isError`, the fake
/// node's `answer(id, text, isError)` shape). The text escapes through
/// `json`; a node cannot shape the frame with its result bytes.
pub fn encode_call_response(id: Int, is_error: Bool, text: String) -> String {
  json.to_string(
    json.object([
      #("v", json.int(version)),
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #(
        "result",
        json.object([
          #(
            "content",
            json.preprocessed_array([
              json.object([
                #("type", json.string("text")),
                #("text", json.string(text)),
              ]),
            ]),
          ),
          #("isError", json.bool(is_error)),
        ]),
      ),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Server → client frames: the event plane (the TUI's decode half)
// ---------------------------------------------------------------------------

/// The per-turn stream metrics a `turn_done` frame carries — the same
/// numbers the web UI's metrics panel shows. `ttft_ms` is optional at
/// the wire (absent/null until a first token exists).
pub type TurnStats {
  TurnStats(
    ttft_ms: Option(Int),
    duration_ms: Int,
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
  )
}

/// One decoded server→client frame: the event plane's projection of
/// `thread.ThreadEvent`, the connection-level frames (`attached`,
/// `pong`, `error`), and the tool plane's request half. The mirror of
/// `event_frame` / `encode_call_request` / `encode_cancelled` — decode
/// lives beside encode so ONE module owns the whole wire and the
/// round-trips are testable offline (`node_protocol_test`).
///
/// An unknown event KIND — or a WRONG VERSION, which falls through the
/// shape discriminator the same way — decodes as `Unknown`:
/// forward-compatible by rule, the TUI's renderer skips it. Malformed
/// JSON or a malformed KNOWN shape is `Error(Nil)`.
pub type ServerFrame {
  Hello(model: String, messages: Int)
  UserLine(text: String, at: Option(Int), author: Option(String))
  AssistantFull(text: String, at: Option(Int))
  ReasoningFull(text: String)
  Token(text: String)
  Reasoning(text: String)
  TurnDone(stats: TurnStats, at: Option(Int))
  TurnStopped(chars: Int, at: Option(Int))
  TurnFailed(reason: String, at: Option(Int))
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    fragment: String,
  )
  ToolCall(call_id: String, name: String, arguments: String, at: Option(Int))
  ToolResult(call_id: String, name: String, ok: Bool, content: String)
  LoopStatus(iteration: Int, max_iterations: Int, phase: String)
  Meta(title: Option(String), tags: List(String))
  Attached(target: String)
  Pong
  ProtocolError(message: String)
  CallRequest(id: Int, tool: String, arguments: String)
  Cancelled(id: Int)
  Unknown
}

/// Decode one server→client frame. Mirrors `decode_client_frame`'s
/// discipline: discriminate the shape once, then decode the known
/// shape's fields; anything unrecognized decodes as `Unknown` rather
/// than failing (a NEWER server talking to an older TUI is the
/// additive-only contract's forward direction).
pub fn decode_server_frame(text: String) -> Result(ServerFrame, Nil) {
  use shape <- result.try(server_shape(text))
  json.parse(text, using: server_frame_decoder(shape))
  |> result.replace_error(Nil)
}

type ServerShape {
  EventShape(kind: String)
  CallShape
  CancelledShape
}

fn server_shape(text: String) -> Result(ServerShape, Nil) {
  let decoder = {
    use v <- decode.field("v", decode.int)
    use kind <- decode.optional_field("type", "", decode.string)
    use method <- decode.optional_field("method", "", decode.string)
    use jsonrpc <- decode.optional_field("jsonrpc", "", decode.string)
    decode.success(case v == version, kind, method, jsonrpc {
      // The tool plane validates its JSON-RPC marker, mirroring
      // decode_client_frame's response discrimination — a frame that
      // falsifies or omits it cannot arrive as an executable request
      // or a cancellation (cubic PR review).
      True, "", "tools/call", "2.0" -> CallShape
      True, "", "notifications/cancelled", "2.0" -> CancelledShape
      True, kind, "", "" -> EventShape(kind)
      _, _, _, _ -> EventShape("")
    })
  }
  json.parse(text, using: decoder) |> result.replace_error(Nil)
}

fn server_frame_decoder(shape: ServerShape) -> decode.Decoder(ServerFrame) {
  case shape {
    CallShape -> call_request_decoder()
    CancelledShape -> cancelled_decoder()
    EventShape(kind) ->
      case kind {
        "hello" -> hello_decoder()
        "user" -> user_decoder()
        "assistant" -> assistant_decoder()
        "reasoning_full" -> text_frame_decoder(ReasoningFull)
        "token" -> text_frame_decoder(Token)
        "reasoning" -> text_frame_decoder(Reasoning)
        "turn_done" -> turn_done_decoder()
        "turn_stopped" -> turn_stopped_decoder()
        "turn_failed" -> turn_failed_decoder()
        "tool_call_delta" -> tool_call_delta_decoder()
        "tool_call" -> tool_call_decoder()
        "tool_result" -> tool_result_decoder()
        "loop_status" -> loop_status_decoder()
        "meta" -> meta_decoder()
        "attached" -> attached_decoder()
        "pong" -> decode.success(Pong)
        "error" -> error_decoder()
        _ -> decode.success(Unknown)
      }
  }
}

fn text_frame_decoder(
  wrap: fn(String) -> ServerFrame,
) -> decode.Decoder(ServerFrame) {
  use text <- decode.field("text", decode.string)
  decode.success(wrap(text))
}

fn hello_decoder() -> decode.Decoder(ServerFrame) {
  use model <- decode.field("model", decode.string)
  use messages <- decode.field("messages", decode.int)
  decode.success(Hello(model, messages))
}

fn user_decoder() -> decode.Decoder(ServerFrame) {
  use text <- decode.field("text", decode.string)
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  use author <- decode.optional_field(
    "author",
    None,
    decode.optional(decode.string),
  )
  decode.success(UserLine(text, at, author))
}

fn assistant_decoder() -> decode.Decoder(ServerFrame) {
  use text <- decode.field("text", decode.string)
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  decode.success(AssistantFull(text, at))
}

fn stats_decoder() -> decode.Decoder(TurnStats) {
  use ttft <- decode.optional_field(
    "ttft_ms",
    None,
    decode.optional(decode.int),
  )
  use duration <- decode.field("duration_ms", decode.int)
  use tokens <- decode.field("token_deltas", decode.int)
  use reasoning <- decode.field("reasoning_deltas", decode.int)
  use calls <- decode.field("tool_call_deltas", decode.int)
  decode.success(TurnStats(
    ttft_ms: ttft,
    duration_ms: duration,
    token_deltas: tokens,
    reasoning_deltas: reasoning,
    tool_call_deltas: calls,
  ))
}

fn turn_done_decoder() -> decode.Decoder(ServerFrame) {
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  use stats <- decode.field("stats", stats_decoder())
  decode.success(TurnDone(stats, at))
}

fn turn_stopped_decoder() -> decode.Decoder(ServerFrame) {
  use chars <- decode.field("chars", decode.int)
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  decode.success(TurnStopped(chars, at))
}

fn turn_failed_decoder() -> decode.Decoder(ServerFrame) {
  use reason <- decode.field("reason", decode.string)
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  decode.success(TurnFailed(reason, at))
}

fn tool_call_delta_decoder() -> decode.Decoder(ServerFrame) {
  use index <- decode.field("index", decode.int)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use fragment <- decode.field("fragment", decode.string)
  decode.success(ToolCallDelta(index, id, name, fragment))
}

fn tool_call_decoder() -> decode.Decoder(ServerFrame) {
  use call_id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  use at <- decode.optional_field("at", None, decode.optional(decode.int))
  decode.success(ToolCall(call_id, name, arguments, at))
}

fn tool_result_decoder() -> decode.Decoder(ServerFrame) {
  use call_id <- decode.field("call_id", decode.string)
  use name <- decode.field("name", decode.string)
  use ok <- decode.field("ok", decode.bool)
  use content <- decode.field("content", decode.string)
  decode.success(ToolResult(call_id, name, ok, content))
}

fn loop_status_decoder() -> decode.Decoder(ServerFrame) {
  use iteration <- decode.field("iteration", decode.int)
  use max <- decode.field("max", decode.int)
  use phase <- decode.field("phase", decode.string)
  decode.success(LoopStatus(iteration, max, phase))
}

fn meta_decoder() -> decode.Decoder(ServerFrame) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use tags <- decode.field("tags", decode.list(decode.string))
  decode.success(Meta(title, tags))
}

fn attached_decoder() -> decode.Decoder(ServerFrame) {
  use target <- decode.field("target", decode.string)
  decode.success(Attached(target))
}

fn error_decoder() -> decode.Decoder(ServerFrame) {
  use message <- decode.field("message", decode.string)
  decode.success(ProtocolError(message))
}

fn call_request_decoder() -> decode.Decoder(ServerFrame) {
  use id <- decode.field("id", decode.int)
  use params <- decode.field("params", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", arguments_decoder())
    decode.success(#(name, arguments))
  })
  decode.success(CallRequest(id, params.0, params.1))
}

/// `params.arguments` rides the wire as a RAW JSON OBJECT — the
/// encoder embeds it verbatim (see `encode_call_request`) — so the
/// client decoder reads it as a VALUE and re-encodes it canonically
/// (compact gleam_json bytes, dict order). The VERBATIM property is a
/// wire property of the ENCODER (pinned by the encode tests and the
/// fake-node e2e wire capture); what a node's executors read is the
/// VALUE, and that round-trips exactly.
fn arguments_decoder() -> decode.Decoder(String) {
  decode.dict(decode.string, json_value_decoder())
  |> decode.map(fn(entries) {
    json.to_string(json.object(dict.to_list(entries)))
  })
}

/// One raw JSON value back to its `Json` form, for the canonical
/// re-encoding above. Self-referential by construction — `decode.recursive`
/// defers the inner references so the decoder's construction terminates.
fn json_value_decoder() -> decode.Decoder(Json) {
  use <- decode.recursive
  decode.one_of(decode.string |> decode.map(json.string), or: [
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.bool |> decode.map(json.bool),
    decode.list(json_value_decoder())
      |> decode.map(json.preprocessed_array),
    decode.dict(decode.string, json_value_decoder())
      |> decode.map(fn(entries) { json.object(dict.to_list(entries)) }),
    null_decoder(),
  ])
}

fn null_decoder() -> decode.Decoder(Json) {
  decode.new_primitive_decoder("Null", fn(data) {
    case is_null(data) {
      True -> Ok(json.null())
      // The placeholder is discarded: new_primitive_decoder records
      // the "Null" decode error itself when the function errors.
      False -> Error(json.null())
    }
  })
}

@external(erlang, "gleam_stdlib", "is_null")
@external(javascript, "../../gleam_stdlib.mjs", "is_null")
fn is_null(data: decode.Dynamic) -> Bool

fn cancelled_decoder() -> decode.Decoder(ServerFrame) {
  use id <- decode.field("params", {
    use request_id <- decode.field("requestId", decode.int)
    decode.success(request_id)
  })
  decode.success(Cancelled(id))
}

// ---------------------------------------------------------------------------
// Server → client frames: the tool plane
// ---------------------------------------------------------------------------

/// One `tools/call` request. The arguments JSON embeds VERBATIM — the
/// call site has already verified it parses as a JSON object (see
/// `valid_arguments`), so string concatenation around it is safe and
/// byte-preserving: the node executes against the same argument bytes
/// the model produced. The tool name rides JSON-encoded (defensive —
/// compiled env tool names are charset-safe, but the encoder never
/// depends on that).
pub fn encode_call_request(id: Int, tool: String, arguments: String) -> String {
  "{\"v\":"
  <> int.to_string(version)
  <> ",\"jsonrpc\":\"2.0\",\"id\":"
  <> int.to_string(id)
  <> ",\"method\":\"tools/call\",\"params\":{\"name\":"
  <> json.to_string(json.string(tool))
  <> ",\"arguments\":"
  <> arguments
  <> "}}"
}

/// One `notifications/cancelled` notice for the request `id` (MCP's
/// shape; best-effort by contract — the node may already be gone).
pub fn encode_cancelled(id: Int) -> String {
  "{\"v\":"
  <> int.to_string(version)
  <> ",\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\","
  <> "\"params\":{\"requestId\":"
  <> int.to_string(id)
  <> "}}"
}

/// True when `arguments` is non-empty, parses as JSON, and roots at an
/// object — the precondition for verbatim embedding in
/// `encode_call_request`. The env executors only ever route
/// already-parsed object arguments, so a failure here is a nexus-side
/// invariant break, answered as an ordinary tool error rather than a
/// malformed frame on the wire.
pub fn valid_arguments(arguments: String) -> Bool {
  case
    json.parse(arguments, using: decode.dict(decode.string, decode.dynamic))
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ---------------------------------------------------------------------------
// Server → client frames: connection-level
// ---------------------------------------------------------------------------

/// Sent after the adapter's `AttachTarget` is accepted (env role only):
/// the node's roster target is live and routable.
pub fn encode_attached(target: String) -> String {
  frame_json(object("attached", [#("target", json.string(target))]))
}

pub fn encode_pong() -> String {
  frame_json(object("pong", []))
}

/// A protocol-level error (refused send, unknown frame, refused join):
/// informational — the connection-level policy decides whether to close.
pub fn encode_error(message: String) -> String {
  frame_json(object("error", [#("message", json.string(message))]))
}

fn object(kind: String, fields: List(#(String, Json))) -> Json {
  json.object([
    #("v", json.int(version)),
    #("type", json.string(kind)),
    ..fields
  ])
}

fn frame_json(body: Json) -> String {
  json.to_string(body)
}

fn optional_int(value: Option(Int)) -> Json {
  case value {
    Some(n) -> json.int(n)
    None -> json.null()
  }
}

fn optional_string(value: Option(String)) -> Json {
  case value {
    Some(s) -> json.string(s)
    None -> json.null()
  }
}
