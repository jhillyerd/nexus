//// The node-side tool plane (environments plan Phase 2b-5): one
//// `tools/call` request in, executed against the TUI's LOCAL workspace
//// through the same env executors the server runs for its own
//// workspace (`env.serve_node_call` — kill-tree, caps while reading,
//// lexical confinement are all inherited, not reimplemented), the
//// `(is_error, text)` response half out. The thin seam exists so the
//// offline tests can drive real bash with no socket, and so the
//// entrypoint never touches the executor seam directly.

import gleam/erlang/process.{type Subject}
import nexus/env
import nexus/node_protocol

/// Execute one call and produce `encode_call_response`'s argument pair.
/// `Ok` executor results carry their text as DATA (a non-zero bash exit
/// included — the Phase 1 posture: a failing command is signal for the
/// model); `Error` becomes an `isError:true` result carrying the
/// message. Runs in the TUI's worker process — the executor may block
/// up to the full deadline — and the `cancel` subject is the
/// server's `notifications/cancelled` re-signal (the codemode rule).
pub fn execute(
  handle handle: env.Environment,
  timeout_ms timeout_ms: Int,
  max_output_bytes max_output_bytes: Int,
  tool tool: String,
  arguments arguments: String,
  cancel cancel: Subject(Nil),
) -> #(Bool, String) {
  case
    env.serve_node_call(
      handle,
      tool,
      arguments,
      timeout_ms,
      max_output_bytes,
      cancel,
    )
  {
    Ok(text) -> #(False, text)
    Error(message) -> #(True, message)
  }
}

/// Build the wire frame for an executed call — the worker's only
/// contact with the protocol, kept here so `tui_test` pins the exact
/// bytes a node emits.
pub fn response_frame(id: Int, outcome: #(Bool, String)) -> String {
  let #(is_error, text) = outcome
  node_protocol.encode_call_response(id, is_error, text)
}
