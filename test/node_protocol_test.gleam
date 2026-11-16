//// Offline pins for the `/node/ws` client protocol v1
//// (`nexus/node_protocol`): the codec is pure string↔frame, so every
//// wire shape is pinned exactly — the fake-node e2e (environments plan
//// 2b-4) consumes these shapes, and the protocol is additive-only, so
//// a change here is a protocol change, never a refactor.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/node_protocol
import nexus/openai
import nexus/thread

// ---------------------------------------------------------------------------
// Client → server decode
// ---------------------------------------------------------------------------

pub fn decode_send_test() {
  node_protocol.decode_client_frame(
    "{\"v\":1,\"type\":\"send\",\"text\":\"case:bash now\"}",
  )
  |> should.equal(Ok(node_protocol.Send("case:bash now")))
}

pub fn decode_ping_test() {
  node_protocol.decode_client_frame("{\"v\":1,\"type\":\"ping\"}")
  |> should.equal(Ok(node_protocol.Ping))
}

pub fn decode_response_ok_test() {
  node_protocol.decode_client_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{"
    <> "\"content\":[{\"type\":\"text\",\"text\":\"node says: hi\"}],"
    <> "\"isError\":false}}",
  )
  |> should.equal(Ok(node_protocol.CallResponse(3, True, "node says: hi")))
}

pub fn decode_response_error_flag_test() {
  node_protocol.decode_client_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{"
    <> "\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}}",
  )
  |> should.equal(Ok(node_protocol.CallResponse(7, False, "boom")))
}

/// A JSON-RPC error-object response is a FAILED call carrying the
/// message — a node cannot smuggle a success past a refused call.
pub fn decode_response_error_object_test() {
  node_protocol.decode_client_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"message\":\"no disk\"}}",
  )
  |> should.equal(Ok(node_protocol.CallResponse(9, False, "no disk")))
}

/// Content parts join in order; non-text parts skip (no v1 projection),
/// a missing text part reads empty; a missing isError reads false.
pub fn decode_response_content_join_test() {
  node_protocol.decode_client_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{"
    <> "\"content\":["
    <> "{\"type\":\"text\",\"text\":\"a\"},"
    <> "{\"type\":\"image\",\"data\":\"…\"},"
    <> "{\"type\":\"text\",\"text\":\"b\"}"
    <> "]}}",
  )
  |> should.equal(Ok(node_protocol.CallResponse(1, True, "ab")))
}

pub fn decode_refuses_garbage_test() {
  node_protocol.decode_client_frame("not json") |> should.equal(Error(Nil))
}

pub fn decode_refuses_wrong_version_test() {
  node_protocol.decode_client_frame("{\"v\":2,\"type\":\"ping\"}")
  |> should.equal(Error(Nil))
}

pub fn decode_refuses_unknown_type_test() {
  node_protocol.decode_client_frame("{\"v\":1,\"type\":\"wat\"}")
  |> should.equal(Error(Nil))
}

pub fn decode_refuses_missing_fields_test() {
  // A send without text, and a response without id: both refuse rather
  // than decode into half-shapes.
  node_protocol.decode_client_frame("{\"v\":1,\"type\":\"send\"}")
  |> should.equal(Error(Nil))
  node_protocol.decode_client_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"result\":{\"content\":[]}}",
  )
  |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// Tool plane encode
// ---------------------------------------------------------------------------

/// The argument JSON embeds VERBATIM — byte-preserving, no
/// re-serialization: the node executes the same argument bytes the
/// model produced. Pinned as an exact string.
pub fn encode_call_request_test() {
  node_protocol.encode_call_request(
    4,
    "bash",
    "{\"target\":\"node-a\",\"command\":\"echo hi\"}",
  )
  |> should.equal(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"bash\",\"arguments\":"
    <> "{\"target\":\"node-a\",\"command\":\"echo hi\"}}}",
  )
}

/// The hand-concatenated frame is valid JSON (the raw-embed trick must
/// never produce a malformed frame for well-formed inputs).
pub fn encode_call_request_parses_test() {
  let frame =
    node_protocol.encode_call_request(
      11,
      "read_file",
      "{\"target\":\"node-a\",\"path\":\"notes.txt\"}",
    )
  let assert Ok(_) =
    json.parse("{\"wrap\":" <> frame <> "}", using: decode.dynamic)
  Nil
}

pub fn encode_cancelled_test() {
  node_protocol.encode_cancelled(4)
  |> should.equal(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\","
    <> "\"params\":{\"requestId\":4}}",
  )
}

pub fn valid_arguments_test() {
  node_protocol.valid_arguments("{\"a\":1}") |> should.be_true
  node_protocol.valid_arguments("{}") |> should.be_true
  // Arrays, scalars, and garbage are not tool arguments.
  node_protocol.valid_arguments("[1,2]") |> should.be_false
  node_protocol.valid_arguments("\"x\"") |> should.be_false
  node_protocol.valid_arguments("{oops") |> should.be_false
}

// ---------------------------------------------------------------------------
// Event plane encode
// ---------------------------------------------------------------------------

pub fn event_hello_test() {
  node_protocol.event_frame(event("t1", thread.Hello("smart", 4, [])))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"hello\",\"model\":\"smart\",\"messages\":4}",
  ))
}

pub fn event_user_test() {
  node_protocol.event_frame(event(
    "t1",
    thread.UserEcho("hi there", Some(123), Some("system")),
  ))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"user\",\"text\":\"hi there\",\"at\":123,"
    <> "\"author\":\"system\"}",
  ))
  node_protocol.event_frame(event("t1", thread.UserEcho("x", None, None)))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"user\",\"text\":\"x\",\"at\":null,\"author\":null}",
  ))
}

/// Quotes inside hostile text ride ESCAPED — the frame stays one JSON
/// document regardless of what the model or a node reports.
pub fn event_user_hostile_text_test() {
  let assert Ok(frame) =
    node_protocol.event_frame(event(
      "t1",
      thread.UserEcho("he said \"hi\" <script>", None, None),
    ))
  // The double-quoted payload must not appear raw (an unescaped quote
  // would break the document); re-parse proves the frame is still one
  // JSON value.
  let assert Ok(_) = json.parse(frame, using: decode.dynamic)
  should.be_false(string.contains(frame, "\"hi\""))
}

pub fn event_tool_round_test() {
  node_protocol.event_frame(event(
    "t1",
    thread.ToolCallAssembled(
      "call_1",
      "bash",
      "{\"target\":\"node-a\"}",
      Some(9),
    ),
  ))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"tool_call\",\"id\":\"call_1\",\"name\":\"bash\","
    <> "\"arguments\":\"{\\\"target\\\":\\\"node-a\\\"}\",\"at\":9}",
  ))
  node_protocol.event_frame(event(
    "t1",
    thread.ToolResult("call_1", "bash", False, "exit status 1"),
  ))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"tool_result\",\"call_id\":\"call_1\",\"name\":\"bash\","
    <> "\"ok\":false,\"content\":\"exit status 1\"}",
  ))
}

pub fn event_turn_lifecycle_test() {
  let stats =
    openai.StreamStats(
      ttft_ms: Some(42),
      duration_ms: 1000,
      token_deltas: 3,
      reasoning_deltas: 0,
      tool_call_deltas: 2,
      events_parsed: 10,
      decode_errors: 0,
      saw_done: True,
      usage: None,
    )
  let assert Ok(done) =
    node_protocol.event_frame(event("t1", thread.TurnDone(stats, Some(77))))
  should.be_true(string.contains(done, "\"type\":\"turn_done\""))
  should.be_true(string.contains(done, "\"ttft_ms\":42"))
  should.be_true(string.contains(done, "\"duration_ms\":1000"))
  let assert Ok(failed) =
    node_protocol.event_frame(event("t1", thread.TurnFailed("boom", None)))
  should.be_true(string.contains(failed, "\"type\":\"turn_failed\""))
  should.be_true(string.contains(failed, "\"reason\":\"boom\""))
}

// ---------------------------------------------------------------------------
// Connection-level encode
// ---------------------------------------------------------------------------

pub fn encode_connection_frames_test() {
  node_protocol.encode_attached("proxmox-2")
  |> should.equal("{\"v\":1,\"type\":\"attached\",\"target\":\"proxmox-2\"}")
  node_protocol.encode_pong() |> should.equal("{\"v\":1,\"type\":\"pong\"}")
  node_protocol.encode_error("nope")
  |> should.equal("{\"v\":1,\"type\":\"error\",\"message\":\"nope\"}")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn event(id: String, kind: thread.EventKind) -> thread.ThreadEvent {
  thread.ThreadEvent(id, 1, kind)
}
