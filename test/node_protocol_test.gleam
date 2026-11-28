//// Offline pins for the `/node/ws` client protocol v1
//// (`nexus/node_protocol`): the codec is pure string↔frame, so every
//// wire shape is pinned exactly — the fake-node e2e (environments plan
//// 2b-4) consumes these shapes, and the protocol is additive-only, so
//// a change here is a protocol change, never a refactor.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/node_protocol
import nexus/openai
import nexus/thread
import nexus/transcript

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

pub fn event_usage_updated_unprojected_test() {
  node_protocol.event_frame(event(
    "t1",
    thread.UsageUpdated(thread.ContextUsage(
      tokens: 0,
      source: thread.Estimated,
      context_window: None,
      last_prompt_tokens: None,
      last_cached_tokens: None,
      bytes_per_token: thread.default_bytes_per_token,
    )),
  ))
  |> should.equal(Error(Nil))
}

pub fn event_compaction_events_unprojected_test() {
  let cp =
    transcript.Compaction(
      cutoff_index: 3,
      summary: "summary",
      roster_snapshot: None,
      focus: None,
      trigger: transcript.ManualCompact,
      before_tokens: Some(4000),
      after_tokens: Some(800),
      created_at: 1000,
    )
  node_protocol.event_frame(event(
    "t1",
    thread.CompactionStarted(transcript.ManualCompact),
  ))
  |> should.equal(Error(Nil))
  node_protocol.event_frame(event("t1", thread.Compacted(cp, 0)))
  |> should.equal(Error(Nil))
  node_protocol.event_frame(event(
    "t1",
    thread.CompactionFinished(transcript.ManualCompact, None),
  ))
  |> should.equal(Error(Nil))
}

pub fn event_hello_test() {
  node_protocol.event_frame(event(
    "t1",
    thread.Hello(
      "smart",
      4,
      [],
      thread.ContextUsage(
        tokens: 0,
        source: thread.Estimated,
        context_window: None,
        last_prompt_tokens: None,
        last_cached_tokens: None,
        bytes_per_token: thread.default_bytes_per_token,
      ),
    ),
  ))
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

/// The remaining event kinds, pinned exactly (the additive-only
/// contract means a byte change here is a protocol change).
pub fn event_remaining_kinds_exact_test() {
  node_protocol.event_frame(event("t1", thread.AssistantFull("done", Some(5))))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"assistant\",\"text\":\"done\",\"at\":5}",
  ))
  node_protocol.event_frame(event("t1", thread.ReasoningFull("why")))
  |> should.equal(Ok("{\"v\":1,\"type\":\"reasoning_full\",\"text\":\"why\"}"))
  node_protocol.event_frame(event("t1", thread.Token("x ")))
  |> should.equal(Ok("{\"v\":1,\"type\":\"token\",\"text\":\"x \"}"))
  node_protocol.event_frame(event("t1", thread.Reasoning("hm")))
  |> should.equal(Ok("{\"v\":1,\"type\":\"reasoning\",\"text\":\"hm\"}"))
  node_protocol.event_frame(event("t1", thread.TurnStopped(9, Some(4))))
  |> should.equal(Ok("{\"v\":1,\"type\":\"turn_stopped\",\"chars\":9,\"at\":4}"))
  node_protocol.event_frame(event(
    "t1",
    thread.ToolCallDelta(0, Some("c1"), Some("bash"), "{\"tar"),
  ))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"tool_call_delta\",\"index\":0,\"id\":\"c1\",\"name\":\"bash\",\"fragment\":\"{\\\"tar\"}",
  ))
  node_protocol.event_frame(event("t1", thread.LoopStatus(2, 8, "tools")))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"loop_status\",\"iteration\":2,\"max\":8,\"phase\":\"tools\"}",
  ))
  node_protocol.event_frame(event(
    "t1",
    thread.MetaUpdated(Some("new title"), ["a", "b"]),
  ))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"meta\",\"title\":\"new title\",\"tags\":[\"a\",\"b\"]}",
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
  node_protocol.event_frame(event("t1", thread.TurnDone(stats, Some(77))))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"turn_done\",\"at\":77,\"stats\":{\"ttft_ms\":42,"
    <> "\"duration_ms\":1000,\"token_deltas\":3,\"reasoning_deltas\":0,"
    <> "\"tool_call_deltas\":2}}",
  ))
  node_protocol.event_frame(event("t1", thread.TurnFailed("boom", None)))
  |> should.equal(Ok(
    "{\"v\":1,\"type\":\"turn_failed\",\"reason\":\"boom\",\"at\":null}",
  ))
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
// Client → server encode (the Gleam TUI's sending half, 2b-5)
// ---------------------------------------------------------------------------

pub fn encode_send_test() {
  node_protocol.encode_send("run the deploy")
  |> should.equal("{\"v\":1,\"type\":\"send\",\"text\":\"run the deploy\"}")
}

/// Hostile text escapes through the json encoder — a send cannot
/// shape the frame.
pub fn encode_send_hostile_text_test() {
  let frame = node_protocol.encode_send("say \"hi\"\nnewline")
  node_protocol.decode_client_frame(frame)
  |> should.equal(Ok(node_protocol.Send("say \"hi\"\nnewline")))
}

pub fn encode_ping_test() {
  node_protocol.encode_ping()
  |> should.equal("{\"v\":1,\"type\":\"ping\"}")
}

pub fn encode_call_response_ok_test() {
  node_protocol.encode_call_response(3, False, "node says: hi")
  |> should.equal(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{"
    <> "\"content\":[{\"type\":\"text\",\"text\":\"node says: hi\"}],"
    <> "\"isError\":false}}",
  )
}

/// The response flag is the wire's own isError (the fake node's
/// answer(id, text, isError) shape); decoding flips it to ok-ness.
pub fn encode_call_response_error_test() {
  let frame = node_protocol.encode_call_response(7, True, "boom")
  node_protocol.decode_client_frame(frame)
  |> should.equal(Ok(node_protocol.CallResponse(7, False, "boom")))
}

// ---------------------------------------------------------------------------
// Server → client decode (the TUI's receive half, 2b-5)
// ---------------------------------------------------------------------------

pub fn decode_hello_test() {
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"hello\",\"model\":\"smart\",\"messages\":3}",
  )
  |> should.equal(Ok(node_protocol.Hello("smart", 3)))
}

/// Encode→decode round-trip over the real projection: the same
/// ThreadEvent that event_frame encodes decodes back to the same flat
/// values.
pub fn decode_event_round_trip_test() {
  // Each sample carries its expected decoded frame — the round trip
  // is asserted value-for-value, not just non-Unknown (cubic PR
  // review: field regressions in text, stamps, ids, flags must fail).
  let samples = [
    #(
      thread.UserEcho("hello", Some(1000), Some("system")),
      node_protocol.UserLine("hello", Some(1000), Some("system")),
    ),
    #(
      thread.UserEcho("hello", None, None),
      node_protocol.UserLine("hello", None, None),
    ),
    #(
      thread.AssistantFull("done", Some(1001)),
      node_protocol.AssistantFull("done", Some(1001)),
    ),
    #(thread.ReasoningFull("thinking"), node_protocol.ReasoningFull("thinking")),
    #(thread.Token("fr"), node_protocol.Token("fr")),
    #(thread.Reasoning("why"), node_protocol.Reasoning("why")),
    #(
      thread.ToolCallAssembled(
        "call_1",
        "bash",
        "{\"command\":\"echo hi\"}",
        Some(1002),
      ),
      node_protocol.ToolCall(
        "call_1",
        "bash",
        "{\"command\":\"echo hi\"}",
        Some(1002),
      ),
    ),
    #(
      thread.ToolResult("call_1", "bash", True, "hi"),
      node_protocol.ToolResult("call_1", "bash", True, "hi"),
    ),
    #(
      thread.ToolResult("call_2", "bash", False, "nope"),
      node_protocol.ToolResult("call_2", "bash", False, "nope"),
    ),
    #(thread.LoopStatus(2, 8, "tools"), node_protocol.LoopStatus(2, 8, "tools")),
    #(
      thread.MetaUpdated(Some("title"), ["a", "b"]),
      node_protocol.Meta(Some("title"), ["a", "b"]),
    ),
    #(thread.MetaUpdated(None, []), node_protocol.Meta(None, [])),
  ]
  samples
  |> list.each(fn(sample) {
    let #(kind, expected) = sample
    let assert Ok(frame) = node_protocol.event_frame(event("t1", kind))
    node_protocol.decode_server_frame(frame)
    |> should.equal(Ok(expected))
  })
}

pub fn decode_turn_done_stats_test() {
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"turn_done\",\"at\":77,\"stats\":{"
    <> "\"ttft_ms\":42,\"duration_ms\":1000,\"token_deltas\":3,"
    <> "\"reasoning_deltas\":0,\"tool_call_deltas\":2}}",
  )
  |> should.equal(
    Ok(node_protocol.TurnDone(
      node_protocol.TurnStats(
        ttft_ms: Some(42),
        duration_ms: 1000,
        token_deltas: 3,
        reasoning_deltas: 0,
        tool_call_deltas: 2,
      ),
      Some(77),
    )),
  )
  // ttft is optional at the wire (null reads None).
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"turn_done\",\"at\":null,\"stats\":{"
    <> "\"ttft_ms\":null,\"duration_ms\":5,\"token_deltas\":0,"
    <> "\"reasoning_deltas\":0,\"tool_call_deltas\":0}}",
  )
  |> should.equal(
    Ok(node_protocol.TurnDone(
      node_protocol.TurnStats(
        ttft_ms: None,
        duration_ms: 5,
        token_deltas: 0,
        reasoning_deltas: 0,
        tool_call_deltas: 0,
      ),
      None,
    )),
  )
}

pub fn decode_user_author_optional_test() {
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"user\",\"text\":\"attached targets: workspace.\","
    <> "\"at\":null,\"author\":\"system\"}",
  )
  |> should.equal(
    Ok(node_protocol.UserLine(
      "attached targets: workspace.",
      None,
      Some("system"),
    )),
  )
}

pub fn decode_tool_call_delta_test() {
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"tool_call_delta\",\"index\":0,\"id\":\"call_1\","
    <> "\"name\":null,\"fragment\":\"{\"}",
  )
  |> should.equal(Ok(node_protocol.ToolCallDelta(0, Some("call_1"), None, "{")))
}

pub fn decode_connection_frames_test() {
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"attached\",\"target\":\"node-a\"}",
  )
  |> should.equal(Ok(node_protocol.Attached("node-a")))
  node_protocol.decode_server_frame("{\"v\":1,\"type\":\"pong\"}")
  |> should.equal(Ok(node_protocol.Pong))
  node_protocol.decode_server_frame(
    "{\"v\":1,\"type\":\"error\",\"message\":\"refused\"}",
  )
  |> should.equal(Ok(node_protocol.ProtocolError("refused")))
}

/// The tool plane's request half: the mirror of encode_call_request.
/// The wire carries arguments VERBATIM (an encoder property, pinned by
/// the encode tests and the fake-node e2e wire capture); the decoded
/// representation re-encodes the VALUE canonically — what a node's
/// executors read round-trips exactly.
pub fn decode_call_request_test() {
  let arguments = "{\"target\": \"node-a\", \"command\":\"echo  spaced  \"}"
  let frame = node_protocol.encode_call_request(11, "bash", arguments)
  let assert Ok(node_protocol.CallRequest(11, "bash", decoded)) =
    node_protocol.decode_server_frame(frame)
  arg_field(decoded, "target") |> should.equal("node-a")
  arg_field(decoded, "command") |> should.equal("echo  spaced  ")
}

fn arg_field(arguments: String, name: String) -> String {
  let assert Ok(value) =
    json.parse(arguments, using: {
      use field <- decode.field(name, decode.string)
      decode.success(field)
    })
  value
}

pub fn decode_cancelled_test() {
  node_protocol.decode_server_frame(node_protocol.encode_cancelled(9))
  |> should.equal(Ok(node_protocol.Cancelled(9)))
}

/// Additive growth: an event KIND this client predates decodes as
/// Unknown — forward-compatible by rule — while malformed JSON and a
/// malformed KNOWN shape refuse.
pub fn decode_unknown_and_malformed_test() {
  node_protocol.decode_server_frame("{\"v\":1,\"type\":\"telemetry_v2\"}")
  |> should.equal(Ok(node_protocol.Unknown))
  node_protocol.decode_server_frame("{\"v\":2,\"type\":\"send\"}")
  |> should.equal(Ok(node_protocol.Unknown))
  node_protocol.decode_server_frame("not json at all")
  |> should.equal(Error(Nil))
  node_protocol.decode_server_frame("{\"v\":1,\"type\":\"user\"}")
  |> should.equal(Error(Nil))
  node_protocol.decode_server_frame(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"bash\"}}",
  )
  |> should.equal(Error(Nil))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn event(id: String, kind: thread.EventKind) -> thread.ThreadEvent {
  thread.ThreadEvent(id, 1, kind)
}
