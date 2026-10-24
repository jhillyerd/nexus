//// The M3 bounded agent loop: stream → assemble native tool calls →
//// execute tools → append results → stream again, until the model stops
//// calling tools, the iteration guard trips, the user cancels, or the
//// transport fails.
////
//// Invariants preserved:
////
//// - the transcript is only ever appended to, through `nexus/transcript`;
////   every model call re-encodes the whole (immutable) message list, so
////   prefixes stay byte-identical (KV-cache contract rule 4);
//// - the tool schema is whatever the caller passes — built once at boot
////   from the global config, frozen for the VM's lifetime;
//// - cancellation: the cancel subject is threaded through every stream
////   call; a stop between iterations aborts immediately;
//// - a failed stream commits nothing (the caller keeps its own transcript),
////   so a retry resends a byte-identical prefix.
////
//// Streamed fragments are accumulated per iteration through the process
//// dictionary (`nexus_loop_ffi`): the transport seam pushes events through
//// a plain callback, and this module only ever runs inside the per-turn
//// worker process, never the session actor.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glopenai/chat
import glopenai/shared
import nexus/openai
import nexus/tool_calls.{type Accumulator}
import nexus/tools.{type ToolSpec}
import nexus/transcript.{type Options, type Transcript}

@external(erlang, "nexus_loop_ffi", "cell_init")
fn cell_init() -> Nil

@external(erlang, "nexus_loop_ffi", "put_text")
fn put_text(text: String) -> Nil

@external(erlang, "nexus_loop_ffi", "take_text")
fn take_text() -> String

@external(erlang, "nexus_loop_ffi", "put_calls")
fn put_calls(calls: Accumulator) -> Nil

@external(erlang, "nexus_loop_ffi", "take_calls")
fn take_calls() -> Accumulator

@external(erlang, "nexus_loop_ffi", "put_reasoning")
fn put_reasoning(text: String) -> Nil

@external(erlang, "nexus_loop_ffi", "take_reasoning")
fn take_reasoning() -> String

@external(erlang, "nexus_loop_ffi", "peek_reasoning")
fn peek_reasoning() -> String

/// The stream seam: one (cancellable) model round-trip. Production wraps
/// `openai.stream_with_cancel`; tests inject fakes.
pub type StreamFn =
  fn(Transcript, Options, fn(openai.StreamEvent) -> Nil, Subject(Nil)) ->
    openai.StreamOutcome

pub type LoopEvent {
  /// A raw transport event forwarded while streaming (token/tool deltas).
  StreamEvent(openai.StreamEvent)
  /// One fully-assembled native tool call about to be executed.
  ToolCallAssembled(id: String, name: String, arguments: String)
  /// A tool finished; `content` is the (already truncated) result or a
  /// rendered error object.
  ToolResultEvent(call_id: String, name: String, ok: Bool, content: String)
  /// Loop progress: `iteration` is 1-based. `phase` is "request" before a
  /// model call, "tools" before executing calls, "guard" when the guard
  /// trips.
  LoopStatus(iteration: Int, max_iterations: Int, phase: String)
}

pub type LoopOutcome {
  LoopDone(stats: openai.StreamStats, tr: Transcript)
  LoopStopped(tr: Transcript)
  LoopGuardHit(max_iterations: Int, tr: Transcript)
  LoopFailed(reason: String)
}

/// Production stream seam over the transport module. The endpoint is the
/// session's frozen one (resolved from the provider registry at creation
/// and never swapped — the multi-provider plan §8): one session, one
/// endpoint, for every round-trip of every turn.
pub fn endpoint_stream(endpoint: openai.Endpoint) -> StreamFn {
  fn(tr, opts, on_event, cancel) {
    openai.stream_with_cancel(endpoint, tr, opts, on_event, cancel)
  }
}

/// The frozen request envelope: streaming on, the boot-built tool schemas,
/// auto tool choice. This is the ONE construction site — both the agent
/// loop and the utility runner consume it, so their envelopes are
/// byte-identical by construction (KV-cache contract): the tool schema is
/// built once at boot from the global config, never per session, and
/// generation-side params (the utility's only delta,
/// `max_completion_tokens`) do not tokenize into the prompt.
pub fn frozen_options(specs: List(ToolSpec)) -> Options {
  transcript.Options(
    ..transcript.default_options(),
    stream: True,
    tools: tools.schemas(specs),
    tool_choice: Some(chat.ToolChoiceModeChoice(chat.ToolChoiceAuto)),
  )
}

/// Run the loop for one user turn. `tr` must already include the user
/// message; the returned transcript (on non-failed outcomes) extends it.
pub fn run(
  specs: List(ToolSpec),
  max_iterations: Int,
  stream: StreamFn,
  tr: Transcript,
  cancel: Subject(Nil),
  on_event: fn(LoopEvent) -> Nil,
) -> LoopOutcome {
  cell_init()
  iterate(
    specs,
    max_iterations,
    stream,
    tr,
    cancel,
    on_event,
    1,
    StatsAcc(None, 0, 0, 0, 0, 0, 0, False, None),
  )
}

type StatsAcc {
  StatsAcc(
    ttft_ms: Option(Int),
    duration_ms: Int,
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
    events_parsed: Int,
    decode_errors: Int,
    saw_done: Bool,
    usage: Option(shared.CompletionUsage),
  )
}

fn iterate(
  specs,
  max_iterations,
  stream,
  tr,
  cancel,
  on_event,
  iteration,
  stats,
) -> LoopOutcome {
  on_event(LoopStatus(iteration, max_iterations, "request"))
  let opts = frozen_options(specs)
  cell_init()
  put_text("")
  put_calls(tool_calls.new())
  put_reasoning("")
  let outcome = stream(tr, opts, fn(event) { forward(event, on_event) }, cancel)
  let partial_text = take_text()
  let assembled =
    take_calls()
    |> tool_calls.tool_calls
  case outcome {
    openai.Failed(reason) -> LoopFailed(error_string(reason))
    openai.Cancelled -> {
      // Commit whatever partial output arrived, exactly like a plain stop.
      let tr2 = append_iteration_output(tr, partial_text)
      LoopStopped(tr2)
    }
    openai.Completed(iteration_stats) -> {
      let stats = fold_stats(stats, iteration_stats)
      case assembled {
        [] -> {
          let tr2 = append_iteration_output(tr, partial_text)
          LoopDone(stats_to_openai(stats), tr2)
        }
        _ ->
          case iteration >= max_iterations {
            True -> {
              // Guard: another model round-trip would exceed the limit.
              // The trailing assistant tool-call message is NOT appended
              // (its results would dangle) and the calls are not run.
              on_event(LoopStatus(iteration, max_iterations, "guard"))
              let tr2 = append_iteration_output(tr, partial_text)
              LoopGuardHit(max_iterations, tr2)
            }
            False -> {
              on_event(LoopStatus(iteration, max_iterations, "tools"))
              let tr2 = append_calls(tr, partial_text, assembled)
              case execute_all(specs, assembled, on_event, tr2) {
                Error(reason) -> LoopFailed(reason)
                Ok(tr3) ->
                  iterate(
                    specs,
                    max_iterations,
                    stream,
                    tr3,
                    cancel,
                    on_event,
                    iteration + 1,
                    stats,
                  )
              }
            }
          }
      }
    }
  }
}

/// Forward one raw event, updating this iteration's accumulators.
fn forward(event: openai.StreamEvent, on_event: fn(LoopEvent) -> Nil) -> Nil {
  case event {
    openai.TokenDelta(fragment) -> put_text(take_text_fresh() <> fragment)
    openai.ReasoningDelta(fragment) ->
      put_reasoning(peek_reasoning() <> fragment)
    openai.ToolCallDelta(index, id, name, args_fragment) -> {
      let chunk =
        chat.ToolCallChunk(
          index: index,
          id: id,
          function: Some(chat.FunctionCallStream(
            name: name,
            arguments: Some(args_fragment),
          )),
        )
      put_calls(tool_calls.push(take_calls_fresh(), chunk))
    }
    _ -> Nil
  }
  on_event(StreamEvent(event))
}

// During forwarding the cells always exist (cell_init ran); these wrappers
// only exist because `take_text`/`take_calls` erase.
fn take_text_fresh() -> String {
  fresh_text()
}

@external(erlang, "nexus_loop_ffi", "peek_text")
fn fresh_text() -> String

fn take_calls_fresh() -> Accumulator {
  fresh_calls()
}

@external(erlang, "nexus_loop_ffi", "peek_calls")
fn fresh_calls() -> Accumulator

fn append_calls(
  tr: Transcript,
  text: String,
  assembled: List(tool_calls.ToolCall),
) -> Transcript {
  let calls =
    list.map(assembled, fn(call: tool_calls.ToolCall) {
      #(call_id(call), option.unwrap(call.name, "unknown"), call.arguments)
    })
  let text = case text {
    "" -> None
    content -> Some(content)
  }
  // Emit assembled events here (not during streaming): arguments are only
  // complete once the stream closes. The caller already saw the fragments.
  transcript.append_assistant_tool_calls(
    tr,
    text: text,
    calls: calls,
    reasoning: reasoning_opt(take_reasoning()),
  )
}

/// Commit one iteration's final assistant output (no tool calls): the
/// text plus its reasoning. An EMPTY text commits nothing — including the
/// reasoning — matching the pre-reasoning `"" -> tr` guard exactly: no
/// empty assistant messages, so a reasoning model that produced only
/// chain-of-thought leaves the request bytes untouched.
fn append_iteration_output(tr: Transcript, partial_text: String) -> Transcript {
  case partial_text {
    "" -> tr
    text ->
      transcript.append_assistant_with_reasoning(
        tr,
        text,
        reasoning: reasoning_opt(take_reasoning()),
      )
  }
}

fn reasoning_opt(text: String) -> Option(String) {
  case text {
    "" -> None
    reasoning -> Some(reasoning)
  }
}

fn execute_all(
  specs: List(ToolSpec),
  assembled: List(tool_calls.ToolCall),
  on_event: fn(LoopEvent) -> Nil,
  tr: Transcript,
) -> Result(Transcript, String) {
  list.fold(assembled, Ok(tr), fn(acc, call: tool_calls.ToolCall) {
    case acc {
      Error(reason) -> Error(reason)
      Ok(tr) -> {
        let id = call_id(call)
        let name = option.unwrap(call.name, "unknown")
        on_event(ToolCallAssembled(id, name, call.arguments))
        let #(ok, content) = case tool_calls.is_complete(call) {
          False -> #(False, render_error("incomplete tool call"))
          True ->
            case tools.execute(specs, name, call.arguments) {
              Ok(content) -> #(True, content)
              Error(reason) -> #(False, render_error(reason))
            }
        }
        on_event(ToolResultEvent(id, name, ok, content))
        Ok(transcript.append_tool_result(tr, tool_call_id: id, content: content))
      }
    }
  })
}

fn render_error(reason: String) -> String {
  json.object([#("error", json.string(reason))]) |> json.to_string
}

/// Stable id for a call even when the backend omitted one (the tool result
/// must reference the same id as the assistant message).
fn call_id(call: tool_calls.ToolCall) -> String {
  case call.id {
    Some(id) -> id
    None -> "call_" <> int.to_string(call.index)
  }
}

fn fold_stats(acc: StatsAcc, add: openai.StreamStats) -> StatsAcc {
  StatsAcc(
    ttft_ms: case acc.ttft_ms {
      Some(_) -> acc.ttft_ms
      None -> add.ttft_ms
    },
    duration_ms: acc.duration_ms + add.duration_ms,
    token_deltas: acc.token_deltas + add.token_deltas,
    reasoning_deltas: acc.reasoning_deltas + add.reasoning_deltas,
    tool_call_deltas: acc.tool_call_deltas + add.tool_call_deltas,
    events_parsed: acc.events_parsed + add.events_parsed,
    decode_errors: acc.decode_errors + add.decode_errors,
    saw_done: acc.saw_done || add.saw_done,
    usage: case add.usage {
      Some(_) -> add.usage
      None -> acc.usage
    },
  )
}

fn stats_to_openai(acc: StatsAcc) -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: acc.ttft_ms,
    duration_ms: acc.duration_ms,
    token_deltas: acc.token_deltas,
    reasoning_deltas: acc.reasoning_deltas,
    tool_call_deltas: acc.tool_call_deltas,
    events_parsed: acc.events_parsed,
    decode_errors: acc.decode_errors,
    saw_done: acc.saw_done,
    usage: acc.usage,
  )
}

fn error_string(error: openai.StreamError) -> String {
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
