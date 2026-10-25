//// Prefix-cache piggybacking (utility-titles plan §4.1): after a session's
//// first committed exchange, one background completion — branched off the
//// committed transcript's cached prefix — proposes a session title. The
//// request reuses the session's frozen envelope (same model, system
//// prompt, tool schemas) so cache-capable backends reprocess only the
//// instruction message; the reply becomes the title while
//// `title_source = 'auto'` and is otherwise discarded (best-effort).
////
//// Structure: pure request/parse helpers plus one blocking runner — no
//// actor of its own. The runner executes inside the session's unlinked
//// utility worker (like the turn worker), never the session actor.
////
//// Cache contract: the request is built by the SAME `nexus/transcript`
//// encoder from the committed transcript with the SAME envelope as every
//// turn (`loop.frozen_options`, the one shared construction site), with
//// exactly one delta — `max_completion_tokens` — which is generation-side
//// only and never tokenizes into the prompt. The transcript this module
//// branches from is a throwaway snapshot: the instruction (Y) and reply
//// (B) never enter the session's transcript, so conversation re-encoding
//// stays byte-identical turn over turn.
////
//// Hostile text: the reply is model output. It is display data only —
//// it becomes a session title string that the UI renders as a Lustre
//// text node (no `innerHTML` anywhere), and it never rides back into a
//// request body (the branch is never committed).

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import nexus/openai
import nexus/transcript.{type Options, type Transcript}

/// Reply length cap — the same rule as the heuristic first-message title
/// (`session_registry.title_from_first_message`): collapse whitespace,
/// truncate (with an ellipsis) at 60 characters.
const title_limit = 60

/// Bounds the side call's cost and rambling. Generation-side params do not
/// affect the tokenized prompt (utility-titles plan §4.1), so the prefix is
/// untouched. Deliberately generous headroom over the one-line title:
/// reasoning models emit their chain of thought INSIDE this completion
/// budget, so a tight cap lets a thinking model exhaust it before any
/// title text arrives — wasting the session's only attempt. The reply
/// itself stays bounded by `shape_title`'s 60-character cap.
const utility_token_cap = 512

/// The appended user instruction (Y in the plan). Tool use is forbidden
/// in the prompt because the frozen `tools` array renders into the prompt
/// and cannot be stripped without diverging the cached prefix.
pub fn instruction() -> String {
  "You are being asked a housekeeping question about the conversation above. "
  <> "In one line, give this conversation a concise sentence-case title of "
  <> "3–7 words. Do not call any tools. Reply with the title only."
}

/// The utility transcript: the committed snapshot plus the instruction as
/// one user message (Y). Never committed back into the session.
pub fn prepare(tr: Transcript) -> Transcript {
  transcript.append_user(tr, instruction())
}

/// The loop's frozen envelope with exactly one delta: the generation-side
/// token cap. `base` is `loop.frozen_options(specs)` — the shared
/// construction — so every byte above the cap matches a turn request.
pub fn options(base: Options) -> Options {
  transcript.Options(..base, max_completion_tokens: Some(utility_token_cap))
}

/// Parse a utility reply into a title: trim, strip Markdown code fences,
/// collapse whitespace, cap length with the same rule as
/// `title_from_first_message`, and reject empty (a refusal arrives as no
/// content, so it fails here too).
pub fn parse(text: String) -> Result(String, Nil) {
  case shape_title(strip_code_fences(text)) {
    "" -> Error(Nil)
    title -> Ok(title)
  }
}

/// Shape raw text into a display title: strip code fences, collapse every
/// whitespace run to single spaces, trim, and truncate (with an ellipsis)
/// at `title_limit`. The one implementation behind BOTH title shapings —
/// the heuristic first-message title delegates here, so the two can never
/// drift apart.
pub fn shape_title(text: String) -> String {
  let flat = collapse_whitespace(text)
  case string.length(flat) > title_limit {
    True -> string.slice(flat, 0, title_limit) <> "…"
    False -> flat
  }
}

/// Strip one surrounding Markdown code fence (` ```lang … ``` `). Anything
/// else passes through trimmed.
fn strip_code_fences(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      let body = case string.split_once(trimmed, "\n") {
        Ok(#(_opening_fence_line, rest)) -> string.trim(rest)
        // A single-line fence (` ```title``` `, optionally tagged) has no
        // newline to split on: strip the surrounding ticks instead.
        Error(Nil) ->
          trimmed
          |> string.drop_start(3)
          |> string.drop_end(3)
          |> string.trim
      }
      case string.ends_with(body, "```") {
        True -> string.trim(string.drop_end(body, 3))
        False -> body
      }
    }
  }
}

/// Collapse every whitespace run (spaces, tabs, newlines) to single spaces
/// and trim — a multi-line reply still reads as one title line. The CRLF
/// pair must go first: Erlang's Unicode `string:replace` does not match a
/// lone "\r" inside "\r\n".
fn collapse_whitespace(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
  |> string.trim
}

/// What the stream feed accumulated. A tool call is a failure by
/// construction (the instruction forbids it; the frozen envelope still
/// advertises the tools) — remembered explicitly rather than inferred from
/// missing text.
type Fragment {
  Text(String)
  ToolCallSeen
}

/// One blocking, non-loop utility stream. The base options must be the
/// session's frozen envelope (`loop.frozen_options`); the delta applied
/// here is generation-side only. Accumulates text deltas, fails on any
/// tool-call assembly or transport error (best-effort: no retry), and
/// parses the reply. `cancel` must be owned by the calling process — the
/// utility worker creates it, mirroring the turn worker.
pub fn run(
  endpoint: openai.Endpoint,
  tr: Transcript,
  base_opts: Options,
  cancel: Subject(Nil),
) -> Result(String, String) {
  // The stream feed runs synchronously in THIS process, so fragments land
  // in this subject's mailbox and are drained after the call returns.
  let acc = process.new_subject()
  let outcome =
    openai.stream_with_cancel(
      endpoint,
      prepare(tr),
      options(base_opts),
      fn(event) {
        case event {
          openai.TokenDelta(text) -> process.send(acc, Text(text))
          openai.ToolCallDelta(_, _, _, _) -> process.send(acc, ToolCallSeen)
          _ -> Nil
        }
      },
      cancel,
    )
  let fragments = drain(acc, [])
  case outcome {
    openai.Cancelled -> Error("utility stream cancelled")
    openai.Failed(error) -> Error("utility stream failed: " <> describe(error))
    openai.Completed(_) ->
      case list.contains(fragments, ToolCallSeen) {
        True -> Error("model answered the utility call with a tool call")
        False ->
          case
            list.filter_map(fragments, fn(fragment) {
              case fragment {
                Text(text) -> Ok(text)
                ToolCallSeen -> Error(Nil)
              }
            })
            |> string.concat
            |> parse
          {
            Ok(title) -> Ok(title)
            Error(Nil) -> Error("no usable title in utility reply")
          }
      }
  }
}

fn drain(acc: Subject(Fragment), fragments: List(Fragment)) -> List(Fragment) {
  case process.receive(acc, 0) {
    Ok(fragment) -> drain(acc, [fragment, ..fragments])
    Error(Nil) -> list.reverse(fragments)
  }
}

fn describe(error: openai.StreamError) -> String {
  case error {
    openai.Non200(status, body) ->
      "non-200 response: "
      <> int.to_string(status)
      <> ": "
      <> string.slice(body, 0, 200)
    openai.Transport(reason) -> "transport error: " <> reason
    openai.Decode(reason) -> "decode error: " <> reason
  }
}
