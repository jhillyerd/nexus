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
