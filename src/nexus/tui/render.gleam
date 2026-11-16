//// The REPL renderer (environments plan Phase 2b-5): decoded
//// `node_protocol.ServerFrame`s in, terminal lines out. PURE — the
//// same frame always renders the same lines, so the whole presentation
//// is offline-testable (`test/tui_test.gleam`) and the entrypoint's
//// only job is emitting what this returns.
////
//// PoC posture, deliberately: line-oriented output (a REPL, not a
//// full-screen TUI — the high-fidelity client is a separate future
//// initiative), streaming deltas print inline, everything else is a
//// `Line`. Every rendered string is plain text built by concatenation
//// — model and tool output is hostile text, and lines are the
//// terminal's inert analog of the web UI's Lustre text nodes: nothing
//// is interpreted, long payloads are truncated for display only.

import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import nexus/node_protocol.{
  type ServerFrame, AssistantFull, Attached, CallRequest, Cancelled, Hello,
  LoopStatus, Meta, Pong, ProtocolError, Reasoning, ReasoningFull, Token,
  ToolCall, ToolCallDelta, ToolResult, TurnDone, TurnFailed, TurnStopped,
  Unknown, UserLine,
}

/// One rendered piece: `Line` prints with a trailing newline, `Inline`
/// prints without one (streaming token/reasoning deltas accumulate on
/// the current line until a line-oriented frame closes it).
pub type Render {
  Line(String)
  Inline(String)
}

/// Render one frame. Unknown kinds (additive protocol growth) and
/// per-token tool-call assembly noise render as nothing.
pub fn render(frame: ServerFrame) -> List(Render) {
  case frame {
    Hello(model, messages) -> [
      Line(
        "-- joined thread — model "
        <> model
        <> ", "
        <> int.to_string(messages)
        <> " messages replayed",
      ),
    ]
    UserLine(text, _at, author) -> [
      Line(case author {
        Some(name) -> name <> ": " <> text
        None -> "user: " <> text
      }),
    ]
    AssistantFull(text, _at) -> [Line(text)]
    ReasoningFull(text) -> [Line("· " <> text)]
    Token(text) -> [Inline(text)]
    Reasoning(text) -> [Inline(text)]
    TurnDone(stats, _at) -> [
      Line(""),
      Line(
        "-- turn done — "
        <> int.to_string(stats.duration_ms)
        <> " ms, ttft "
        <> case stats.ttft_ms {
          Some(ttft) -> int.to_string(ttft) <> " ms"
          None -> "n/a"
        }
        <> ", "
        <> int.to_string(stats.token_deltas)
        <> " token deltas",
      ),
    ]
    TurnStopped(chars, _at) -> [
      Line("-- turn stopped (" <> int.to_string(chars) <> " chars)"),
    ]
    TurnFailed(reason, _at) -> [Line("! turn failed: " <> reason)]
    ToolCallDelta(_index, _id, _name, _fragment) -> []
    ToolCall(_call_id, name, arguments, _at) -> [
      Line("→ " <> name <> "(" <> abbreviate(arguments, 160) <> ")"),
    ]
    ToolResult(_call_id, name, ok, content) -> [
      Line(
        "← "
        <> name
        <> case ok {
          True -> " ok: "
          False -> " ERROR: "
        }
        <> abbreviate(content, 400),
      ),
    ]
    LoopStatus(iteration, max_iterations, phase) -> [
      Line(
        "-- round "
        <> int.to_string(iteration)
        <> "/"
        <> int.to_string(max_iterations)
        <> " ("
        <> phase
        <> ")",
      ),
    ]
    Meta(title, tags) -> [
      Line(
        "-- meta: "
        <> case title {
          Some(t) -> t
          None -> "(untitled)"
        }
        <> " ["
        <> string.join(tags, ", ")
        <> "]",
      ),
    ]
    Attached(target) -> [Line("-- attached: " <> target)]
    Pong -> []
    ProtocolError(message) -> [Line("! server: " <> message)]
    CallRequest(id, tool, _arguments) -> [
      Line("→ serving node call #" <> int.to_string(id) <> ": " <> tool),
    ]
    Cancelled(id) -> [Line("! cancelled node call #" <> int.to_string(id))]
    Unknown -> []
  }
}

/// A frame the codec could not decode at all (malformed JSON or a
/// malformed known shape): renderable like any other, so the
/// entrypoint never needs a special case.
pub fn undecodable() -> List(Render) {
  [Line("! undecodable frame from server")]
}

/// Emit rendered pieces to stdout. The REPL prompt re-appears only
/// when the next input line is read — output arriving mid-line
/// interleaves, the documented PoC jank (a full-screen TUI owns the
/// whole screen and does not have this problem).
pub fn emit(frames: List(Render)) -> Nil {
  case frames {
    [] -> Nil
    [piece, ..rest] -> {
      case piece {
        Line(text) -> io.println(text)
        Inline(text) -> io.print(text)
      }
      emit(rest)
    }
  }
}

/// Display-only truncation: long payloads keep the first `max`
/// characters plus an ellipsis marker (the web UI's preview posture).
fn abbreviate(text: String, max: Int) -> String {
  case string.length(text) > max {
    True -> string.slice(text, 0, max - 1) <> "…"
    False -> text
  }
}
