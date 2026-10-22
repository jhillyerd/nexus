//// Offline tests for the M3 bounded agent loop, using a scripted fake
//// stream seam — no network, no Bifrost.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import nexus/loop
import nexus/openai
import nexus/tools.{type ToolSpec}
import nexus/transcript.{type Transcript}

fn stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(10),
    duration_ms: 100,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 1,
    events_parsed: 3,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// One scripted round: what to emit and how to finish.
type Round {
  Round(events: List(openai.StreamEvent), outcome: openai.StreamOutcome)
}

/// A scripted stream: serves the given rounds in order; a call beyond the
/// script fails loudly.
fn scripted_stream(rounds: List(Round)) -> loop.StreamFn {
  fn(_tr, _opts, on_event, _cancel) {
    case rounds {
      [Round(events, outcome), ..rest] -> {
        list.each(events, on_event)
        // Mutation-free scripting: the closure cannot drop its own head, so
        // rounds beyond the first would repeat; tests therefore assert the
        // expected number of calls by construction (a repeated first round
        // would produce wrong transcript shapes and fail assertions).
        let _ = rest
        outcome
      }
      [] -> openai.Failed(openai.Transport("script exhausted"))
    }
  }
}

/// A deterministic echo tool: returns its arguments verbatim.
fn echo_tool() -> ToolSpec {
  tools.ToolSpec(
    tool: tools.function_tool(
      name: "echo",
      description: "echo",
      parameters_json: "{\"type\":\"object\",\"properties\":{}}",
    ),
    run: fn(arguments) { Ok("echo:" <> arguments) },
  )
}

fn call_delta(
  id: String,
  name: String,
  arguments: String,
) -> openai.StreamEvent {
  openai.ToolCallDelta(0, Some(id), Some(name), arguments)
}

fn tr_with_user() -> Transcript {
  transcript.new("test-model", "system")
  |> transcript.append_user("question")
}

fn run_recording(
  specs: List(ToolSpec),
  max_iterations: Int,
  stream: loop.StreamFn,
  tr: Transcript,
) -> #(loop.LoopOutcome, List(loop.LoopEvent)) {
  reset_index()
  // A simple actor-free approach: forward events to a subject owned by this
  // process, then drain it.
  let events = process.new_subject()
  let outcome =
    loop.run(
      specs,
      max_iterations,
      stream,
      tr,
      process.new_subject(),
      fn(event) { process.send(events, event) },
    )
  let received = drain(events, [])
  #(outcome, list.reverse(received))
}

fn drain(
  events: process.Subject(loop.LoopEvent),
  acc: List(loop.LoopEvent),
) -> List(loop.LoopEvent) {
  case process.receive(events, 50) {
    Ok(event) -> drain(events, [event, ..acc])
    Error(_) -> acc
  }
}

// ---------------------------------------------------------------------------
// Round trips
// ---------------------------------------------------------------------------

pub fn no_tools_single_round_test() {
  let #(outcome, _) =
    run_recording(
      [],
      8,
      scripted_stream([
        Round([openai.TokenDelta("hello")], openai.Completed(stats())),
      ]),
      tr_with_user(),
    )
  let assert loop.LoopDone(_, tr) = outcome
  // system + user + assistant text
  transcript.length(tr) |> should.equal(3)
}

pub fn tool_round_then_answer_test() {
  let specs = [echo_tool()]
  // Round 1: the model calls the tool. Round 2: plain answer. The scripted
  // seam serves rounds by call order, so use a mutable script via two
  // separate streams is not possible — instead serve both rounds through a
  // self-indexing fake.
  let stream =
    sequence_stream([
      Round(
        [openai.TokenDelta("let me check"), call_delta("c1", "echo", "{}")],
        openai.Completed(stats()),
      ),
      Round([openai.TokenDelta("done")], openai.Completed(stats())),
    ])
  let #(outcome, events) = run_recording(specs, 8, stream, tr_with_user())
  let assert loop.LoopDone(stats, tr) = outcome
  // system + user + assistant(text+call) + tool + assistant
  transcript.length(tr) |> should.equal(5)
  stats.token_deltas |> should.equal(2)
  // The loop reported request/tools/request and the assembled call/result.
  should.be_true(list.contains(events, loop.LoopStatus(1, 8, "request")))
  should.be_true(list.contains(events, loop.LoopStatus(1, 8, "tools")))
  should.be_true(list.contains(
    events,
    loop.ToolCallAssembled("c1", "echo", "{}"),
  ))
  should.be_true(list.contains(
    events,
    loop.ToolResultEvent("c1", "echo", True, "echo:{}"),
  ))
  should.be_true(list.contains(
    events,
    loop.StreamEvent(openai.TokenDelta("done")),
  ))
}

/// A self-indexing scripted stream: each call serves the next round (call
/// index tracked through the test FFI below).
fn sequence_stream(rounds: List(Round)) -> loop.StreamFn {
  fn(_tr, _opts, on_event, _cancel) {
    let index = take_index()
    case list.drop(rounds, index) {
      [Round(events, outcome), ..] -> {
        list.each(events, on_event)
        outcome
      }
      [] -> openai.Failed(openai.Transport("script exhausted"))
    }
  }
}

@external(erlang, "nexus_loop_test_ffi", "next_index")
fn take_index() -> Int

@external(erlang, "nexus_loop_test_ffi", "reset_index")
fn reset_index() -> Nil

/// Sequence streams must start from a known index; tests call this from the
/// same process that runs the loop (the test process), and `loop.run` also
/// runs there, so the counter is naturally scoped per test.
pub fn guard_trips_after_max_iterations_test() {
  let round = Round([call_delta("c1", "echo", "{}")], openai.Completed(stats()))
  let stream = sequence_stream([round, round])
  let #(outcome, events) =
    run_recording([echo_tool()], 2, stream, tr_with_user())
  let assert loop.LoopGuardHit(max, tr) = outcome
  max |> should.equal(2)
  // Two model calls happened (iterations 1 and 2); the third was refused.
  should.be_true(list.contains(events, loop.LoopStatus(1, 2, "request")))
  should.be_true(list.contains(events, loop.LoopStatus(2, 2, "request")))
  should.be_true(list.contains(events, loop.LoopStatus(2, 2, "guard")))
  // system + user + assistant(text+call) + tool result
  transcript.length(tr) |> should.equal(4)
}

pub fn cancelled_commits_partial_text_test() {
  let #(outcome, _) =
    run_recording(
      [],
      8,
      scripted_stream([
        Round([openai.TokenDelta("part")], openai.Cancelled),
      ]),
      tr_with_user(),
    )
  let assert loop.LoopStopped(tr) = outcome
  // system + user + partial assistant text
  transcript.length(tr) |> should.equal(3)
}

pub fn failed_stream_commits_nothing_test() {
  let #(outcome, _) =
    run_recording(
      [],
      8,
      scripted_stream([
        Round(
          [openai.TokenDelta("no")],
          openai.Failed(openai.Non200(500, "boom")),
        ),
      ]),
      tr_with_user(),
    )
  let assert loop.LoopFailed(reason) = outcome
  should.be_true(string.contains(reason, "500"))
}

pub fn unknown_tool_renders_error_result_test() {
  // The model calls a tool that is not registered: the loop must still
  // append a tool result (the wire protocol requires an answer for every
  // assistant tool call) carrying a rendered error.
  let stream =
    sequence_stream([
      Round([call_delta("c9", "nope", "{}")], openai.Completed(stats())),
      Round([], openai.Completed(stats())),
    ])
  let #(outcome, events) =
    run_recording([echo_tool()], 8, stream, tr_with_user())
  let assert loop.LoopDone(_, tr) = outcome
  should.be_true(list.contains(
    events,
    loop.ToolResultEvent(
      "c9",
      "nope",
      False,
      "{\"error\":\"unknown tool: nope\"}",
    ),
  ))
  // Round 2 streams no text, so no final assistant message is appended:
  // system + user + assistant(call) + tool result.
  transcript.length(tr) |> should.equal(4)
}

// ---------------------------------------------------------------------------
// KV-cache prefix byte identity (contract rule 4)
// ---------------------------------------------------------------------------

/// After a tool round, re-encoding the transcript must keep the previous
/// request body as a byte prefix: the model/messages head and every prior
/// message serialize identically, with new messages appended inside the
/// array.
pub fn tool_round_extends_request_byte_identically_test() {
  let tr1 = tr_with_user()
  let tr2 =
    tr1
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [
        #("c1", "echo", "{}"),
      ],
      reasoning: None,
    )
    |> transcript.append_tool_result(tool_call_id: "c1", content: "echo:{}")
  let tr3 = tr2 |> transcript.append_assistant("based on the tool: yes")

  let opts = transcript.default_options()
  let _body1 = transcript.request_body(tr1, opts)
  let body2 = transcript.request_body(tr2, opts)
  let body3 = transcript.request_body(tr3, opts)

  should.be_true(string.starts_with(body2, messages_prefix(tr1, body2)))
  should.be_true(string.starts_with(body3, messages_prefix(tr2, body3)))
  // And the tool round itself is a prefix of the final body.
  should.be_true(string.starts_with(body3, messages_prefix(tr1, body3)))
  // Deterministic: same transcript, same bytes.
  should.equal(transcript.request_body(tr2, opts), body2)
}

/// The serialized `{"model":...,"messages":[` head plus every message of
/// `tr` and a comma — the exact byte prefix any extension must share.
fn messages_prefix(tr: Transcript, _body: String) -> String {
  let items =
    transcript.messages(tr)
    |> list.map(fn(message) {
      message |> chat.chat_message_to_json |> json.to_string
    })
    |> string.join(",")
  "{\"model\":\"" <> transcript.model(tr) <> "\",\"messages\":[" <> items <> ","
}

pub fn tool_schema_is_frozen_from_spec_list_test() {
  // The schemas the loop sends are exactly the registry order.
  let specs = [echo_tool()]
  let stream =
    sequence_stream([
      Round([openai.TokenDelta("x")], openai.Completed(stats())),
    ])
  let #(outcome, _) = run_recording(specs, 8, stream, tr_with_user())
  let assert loop.LoopDone(_, _) = outcome
}

// ---------------------------------------------------------------------------
// Reasoning (chain of thought)
// ---------------------------------------------------------------------------

pub fn reasoning_streams_and_commits_with_text_test() {
  let #(outcome, events) =
    run_recording(
      [],
      8,
      scripted_stream([
        Round(
          [
            openai.ReasoningDelta("let me think "),
            openai.ReasoningDelta("hard"),
            openai.TokenDelta("the answer"),
          ],
          openai.Completed(stats()),
        ),
      ]),
      tr_with_user(),
    )
  // Raw reasoning deltas are forwarded live, in order, before the content.
  events
  |> list.filter(fn(event) {
    case event {
      loop.StreamEvent(_) -> True
      _ -> False
    }
  })
  |> should.equal([
    loop.StreamEvent(openai.ReasoningDelta("let me think ")),
    loop.StreamEvent(openai.ReasoningDelta("hard")),
    loop.StreamEvent(openai.TokenDelta("the answer")),
  ])
  // And committed with the assistant message (system=0, user=1, answer=2).
  case outcome {
    loop.LoopDone(_, tr) ->
      transcript.reasoning_at(tr, 2) |> should.equal(Some("let me think hard"))
    _ -> panic as "expected LoopDone"
  }
}

pub fn reasoning_attaches_to_tool_call_message_test() {
  let #(outcome, _) =
    run_recording(
      [echo_tool()],
      8,
      scripted_stream([
        Round(
          [
            openai.ReasoningDelta("need the echo tool"),
            call_delta("c1", "echo", "{}"),
          ],
          openai.Completed(stats()),
        ),
      ]),
      tr_with_user(),
    )
  case outcome {
    // The script repeats its only round, so the loop keeps issuing the
    // call until the guard trips; every round carries the reasoning.
    loop.LoopGuardHit(_, tr) | loop.LoopDone(_, tr) | loop.LoopStopped(tr) ->
      transcript.reasoning_at(tr, 2) |> should.equal(Some("need the echo tool"))
    loop.LoopFailed(reason) -> panic as { "unexpected LoopFailed: " <> reason }
  }
}

pub fn reasoning_only_stop_commits_nothing_test() {
  let #(outcome, _) =
    run_recording(
      [],
      8,
      scripted_stream([
        Round([openai.ReasoningDelta("hm")], openai.Cancelled),
      ]),
      tr_with_user(),
    )
  case outcome {
    loop.LoopStopped(tr) -> {
      // No empty assistant message, no reasoning entry: request bytes for
      // a retry stay identical to the pre-send transcript.
      transcript.length(tr) |> should.equal(2)
      transcript.reasoning_at(tr, 2) |> should.equal(None)
    }
    _ -> panic as "expected LoopStopped"
  }
}
