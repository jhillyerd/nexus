//// Offline pins for the node TUI's pure halves (environments plan
//// Phase 2b-5): the REPL renderer (`nexus/tui/render` — decoded
//// frames in, terminal lines out) and the tool-plane seam
//// (`nexus/tui/tools` — one `tools/call` executed against a REAL
//// local workspace through `env.serve_node_call`, no socket). The
//// stratus connection and the stdin loop stay behind the entrypoint
//// (`gleam test` stays network-free and non-interactive).

import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/env
import nexus/node_protocol
import nexus/timing
import nexus/tui/render
import nexus/tui/tools
import simplifile

// ---------------------------------------------------------------------------
// Render: line-oriented frames
// ---------------------------------------------------------------------------

pub fn render_hello_test() {
  render.render(node_protocol.Hello("smart", 3))
  |> should.equal([
    render.Line("-- joined thread — model smart, 3 messages replayed"),
  ])
}

/// User lines carry their display author; the roster's system lines
/// (the transcript's status lines) render with it, a human send reads
/// "user:".
pub fn render_user_lines_test() {
  render.render(node_protocol.UserLine(
    "attached targets: workspace, node-a.",
    None,
    Some("system"),
  ))
  |> should.equal([
    render.Line("system: attached targets: workspace, node-a."),
  ])
  render.render(node_protocol.UserLine("hello", Some(1000), None))
  |> should.equal([render.Line("user: hello")])
}

pub fn render_assistant_and_reasoning_test() {
  render.render(node_protocol.AssistantFull("all done", Some(1)))
  |> should.equal([render.Line("all done")])
  render.render(node_protocol.ReasoningFull("because"))
  |> should.equal([render.Line("· because")])
}

/// Streaming deltas print INLINE (no newline) — the turn's text
/// accumulates on one line until a line-oriented frame closes it.
pub fn render_streaming_inline_test() {
  render.render(node_protocol.Token("he"))
  |> should.equal([render.Inline("he")])
  render.render(node_protocol.Token("llo"))
  |> should.equal([render.Inline("llo")])
  render.render(node_protocol.Reasoning("hmm"))
  |> should.equal([render.Inline("hmm")])
}

pub fn render_turn_lifecycle_test() {
  render.render(node_protocol.TurnDone(
    node_protocol.TurnStats(
      ttft_ms: Some(42),
      duration_ms: 1000,
      token_deltas: 3,
      reasoning_deltas: 0,
      tool_call_deltas: 1,
    ),
    Some(77),
  ))
  |> should.equal([
    render.Line(""),
    render.Line("-- turn done — 1000 ms, ttft 42 ms, 3 token deltas"),
  ])
  // ttft absent at the wire reads "n/a".
  render.render(node_protocol.TurnDone(
    node_protocol.TurnStats(
      ttft_ms: None,
      duration_ms: 5,
      token_deltas: 0,
      reasoning_deltas: 0,
      tool_call_deltas: 0,
    ),
    None,
  ))
  |> should.equal([
    render.Line(""),
    render.Line("-- turn done — 5 ms, ttft n/a, 0 token deltas"),
  ])
  render.render(node_protocol.TurnStopped(120, Some(9)))
  |> should.equal([render.Line("-- turn stopped (120 chars)")])
  render.render(node_protocol.TurnFailed("provider down", None))
  |> should.equal([render.Line("! turn failed: provider down")])
  render.render(node_protocol.LoopStatus(2, 8, "tools"))
  |> should.equal([render.Line("-- round 2/8 (tools)")])
}

/// Tool chips truncate display-only — hostile output stays inert
/// plain text, and never floods a line.
pub fn render_tool_chips_truncate_test() {
  render.render(node_protocol.ToolCall(
    "call_1",
    "bash",
    "{\"command\":\"echo hi\",\"target\":\"node-a\"}",
    Some(1),
  ))
  |> should.equal([
    render.Line("→ bash({\"command\":\"echo hi\",\"target\":\"node-a\"})"),
  ])
  let long = string.repeat("x", 500)
  let assert [render.Line(rendered)] =
    render.render(node_protocol.ToolResult("call_1", "bash", True, long))
  // Truncation is exact and display-only: 400 chars of payload kept
  // (399 + the ellipsis) behind the chip prefix.
  rendered
  |> should.equal("← bash ok: " <> string.repeat("x", 399) <> "…")
  let assert [render.Line(rendered_error)] =
    render.render(node_protocol.ToolResult("call_2", "bash", False, long))
  string.starts_with(rendered_error, "← bash ERROR: ") |> should.be_true
  // The failed branch truncates through the same helper — pinned
  // exactly so unbounded hostile error output cannot regress (cubic
  // PR review).
  rendered_error
  |> should.equal("← bash ERROR: " <> string.repeat("x", 399) <> "…")
  // Every rendered piece is plain text: no markup, no escapes.
  let assert [render.Line(hostile)] =
    render.render(node_protocol.ToolResult(
      "call_3",
      "bash",
      True,
      "<script>alert(1)</script>",
    ))
  hostile |> should.equal("← bash ok: <script>alert(1)</script>")
}

pub fn render_meta_attached_protocol_test() {
  render.render(node_protocol.Meta(Some("deploy"), ["ops"]))
  |> should.equal([render.Line("-- meta: deploy [ops]")])
  render.render(node_protocol.Meta(None, []))
  |> should.equal([render.Line("-- meta: (untitled) []")])
  render.render(node_protocol.Attached("node-a"))
  |> should.equal([render.Line("-- attached: node-a")])
  render.render(node_protocol.ProtocolError("refused send"))
  |> should.equal([render.Line("! server: refused send")])
  render.render(node_protocol.CallRequest(11, "bash", "{}"))
  |> should.equal([render.Line("→ serving node call #11: bash")])
  render.render(node_protocol.Cancelled(11))
  |> should.equal([render.Line("! cancelled node call #11")])
}

/// Frames the renderer stays silent on: pong, per-fragment tool-call
/// assembly noise, and unknown kinds (additive growth).
pub fn render_silent_frames_test() {
  render.render(node_protocol.Pong) |> should.equal([])
  render.render(node_protocol.ToolCallDelta(0, None, None, "{\""))
  |> should.equal([])
  render.render(node_protocol.Unknown) |> should.equal([])
}

pub fn render_undecodable_test() {
  render.undecodable()
  |> should.equal([render.Line("! undecodable frame from server")])
}

// ---------------------------------------------------------------------------
// Tools: the node-side tool plane seam
// ---------------------------------------------------------------------------

fn fresh_root() -> String {
  "/tmp/nexus-tui-test-" <> int.to_string(timing.now_us())
}

fn node_handle(root: String) -> env.Environment {
  env.Environment(
    workspace_root: root,
    thread_id: "srv-thread",
    roster: env.attached_targets(),
    remote: None,
  )
}

fn execute(root: String, tool: String, arguments: String) -> #(Bool, String) {
  tools.execute(
    handle: node_handle(root),
    timeout_ms: 10_000,
    max_output_bytes: 100_000,
    tool: tool,
    arguments: arguments,
    cancel: process.new_subject(),
  )
}

/// The core translation: arguments whose `target` names THE NODE (the
/// server routed the call here because the model targeted this node)
/// execute LOCALLY — env.serve_node_call rewrites the parsed target to
/// the reserved "workspace" and the Phase 1 path runs unchanged.
pub fn execute_bash_target_is_node_test() {
  let root = fresh_root()
  let #(is_error, text) =
    execute(
      root,
      "bash",
      "{\"target\":\"tui-node\",\"command\":\"echo served-locally\"}",
    )
  is_error |> should.be_false
  string.contains(text, "served-locally") |> should.be_true
  // The workspace directory exists under the node's root, scoped by
  // the served thread id.
  simplifile.is_directory(root <> "/srv-thread")
  |> should.equal(Ok(True))
}

pub fn execute_file_tools_test() {
  let root = fresh_root()
  let #(w_err, w_text) =
    execute(
      root,
      "write_file",
      "{\"target\":\"tui-node\",\"path\":\"notes.txt\",\"content\":\"hi\"}",
    )
  w_err |> should.be_false
  // write_file's result is the human-facing confirmation; the file's
  // CONTENT comes back through read_file.
  w_text |> should.equal("wrote 2 bytes to notes.txt")
  let #(r_err, r_text) =
    execute(
      root,
      "read_file",
      "{\"target\":\"tui-node\",\"path\":\"notes.txt\"}",
    )
  r_err |> should.be_false
  r_text |> should.equal("hi")
  let #(l_err, l_text) =
    execute(root, "list_dir", "{\"target\":\"tui-node\",\"path\":\"\"}")
  l_err |> should.be_false
  string.contains(l_text, "notes.txt") |> should.be_true
}

/// A non-zero bash exit is DATA (the Phase 1 posture) — isError stays
/// false; only nexus-side failures are errors.
pub fn execute_nonzero_exit_is_data_test() {
  let #(is_error, text) =
    execute(
      fresh_root(),
      "bash",
      "{\"target\":\"tui-node\",\"command\":\"exit 3\"}",
    )
  is_error |> should.be_false
  string.starts_with(text, "exit status 3") |> should.be_true
}

pub fn execute_unknown_tool_test() {
  let #(is_error, text) = execute(fresh_root(), "deploy", "{}")
  is_error |> should.be_true
  text |> should.equal("this node does not serve the tool \"deploy\"")
}

pub fn execute_malformed_arguments_test() {
  let #(is_error, text) =
    execute(fresh_root(), "bash", "{\"command\":\"echo hi\"}")
  is_error |> should.be_true
  string.contains(text, "target") |> should.be_true
}

/// The cancelled call path: a pre-signaled cancel subject is ALREADY
/// in the executor's mailbox when the select loop starts (the port has
/// not even spawned), so the cancel itself is deterministic; the
/// command's output may or may not have flushed by the kill, so only
/// the outcome flag and the cancel wording are asserted — never the
/// partial content (cubic PR review: asserting `partial` was a race).
pub fn execute_cancel_test() {
  let cancel = process.new_subject()
  process.send(cancel, Nil)
  let outcome =
    tools.execute(
      handle: node_handle(fresh_root()),
      timeout_ms: 10_000,
      max_output_bytes: 100_000,
      tool: "bash",
      arguments: "{\"target\":\"tui-node\",\"command\":\"echo partial\"}",
      cancel: cancel,
    )
  outcome.0 |> should.be_true
  string.starts_with(outcome.1, "cancelled. partial output:")
  |> should.be_true
}

/// The response half: an executed call encodes to the exact JSON-RPC
/// shape the server's response_decoder accepts, flag included.
pub fn response_frame_test() {
  tools.response_frame(3, #(False, "node says: hi"))
  |> should.equal(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{"
    <> "\"content\":[{\"type\":\"text\",\"text\":\"node says: hi\"}],"
    <> "\"isError\":false}}",
  )
  tools.response_frame(7, #(True, "boom"))
  |> should.equal(
    "{\"v\":1,\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{"
    <> "\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],"
    <> "\"isError\":true}}",
  )
}
