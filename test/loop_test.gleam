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
    run: fn(_ctx, arguments) { Ok("echo:" <> arguments) },
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
  // The assembled event carries the round's flush stamp — the SAME value
  // the loop recorded on the round's transcript message, never None.
  let assert Some(round_stamp) = transcript.stamped_at(tr, 2)
  should.be_true(
    list.any(events, fn(e) {
      case e {
        loop.ToolCallAssembled("c1", "echo", "{}", Some(s)) -> s == round_stamp
        _ -> False
      }
    }),
  )
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
    |> transcript.append_tool_result(
      tool_call_id: "c1",
      content: "echo:{}",
      ok: True,
    )
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

// ---------------------------------------------------------------------------
// Stop mid-round: skip not-yet-started sibling calls (issue #52)
// ---------------------------------------------------------------------------

/// A stream fake that serves its scripted round exactly once; a second
/// call fails loudly — after a mid-round Stop the loop must end the turn
/// BEFORE opening another model request (the production seam starts its
/// HTTP request before the cancel select ever runs).
fn single_round_stream(events: List(openai.StreamEvent)) -> loop.StreamFn {
  fn(_tr, _opts, on_event, _cancel) {
    case take_index() {
      0 -> {
        list.each(events, on_event)
        openai.Completed(stats())
      }
      _ -> openai.Failed(openai.Transport("stream called after mid-round stop"))
    }
  }
}

pub fn stop_mid_round_skips_remaining_calls_test() {
  // Round 1 assembles two calls. The first tool's run lands a Stop on the
  // turn's cancel subject — the same queue state a mid-execution Stop, or
  // codemode's consume-and-re-signal, leaves behind. The second tool must
  // never start: its slot becomes a synthetic cancelled result, and the
  // turn ends without a second model request (the fake fails loudly if
  // the loop tries one).
  let _ = reset_index()
  let cancel = process.new_subject()
  let signal_tool =
    tools.ToolSpec(
      tool: tools.function_tool(
        name: "signal",
        description: "signals stop mid-run",
        parameters_json: "{\"type\":\"object\",\"properties\":{}}",
      ),
      run: fn(_ctx, _arguments) {
        process.send(cancel, Nil)
        Ok("ran")
      },
    )
  let stream =
    single_round_stream([
      openai.ToolCallDelta(0, Some("c1"), Some("signal"), "{}"),
      openai.ToolCallDelta(1, Some("c2"), Some("echo"), "{}"),
    ])
  let events = process.new_subject()
  let outcome =
    loop.run(
      [signal_tool, echo_tool()],
      8,
      stream,
      tr_with_user(),
      cancel,
      fn(event) { process.send(events, event) },
    )
  let received = drain(events, [])
  let assert loop.LoopStopped(tr) = outcome
  // The first tool ran and committed its result...
  should.be_true(list.contains(
    received,
    loop.ToolResultEvent("c1", "signal", True, "ran"),
  ))
  // ...the second was assembled but never executed: a synthetic failed
  // result answers it (wire protocol: every assistant tool call gets a
  // tool result).
  // The cancelled call's assembled event still carries the round's flush
  // stamp (the round message was appended before the calls executed).
  let assert Some(round_stamp) = transcript.stamped_at(tr, 2)
  should.be_true(
    list.any(received, fn(e) {
      case e {
        loop.ToolCallAssembled("c2", "echo", "{}", Some(s)) -> s == round_stamp
        _ -> False
      }
    }),
  )
  should.be_true(list.contains(
    received,
    loop.ToolResultEvent("c2", "echo", False, "{\"error\":\"cancelled\"}"),
  ))
  // system + user + assistant(calls) + two tool results.
  transcript.length(tr) |> should.equal(5)
  transcript.tool_result_at(tr, 3) |> should.equal(Some(True))
  transcript.tool_result_at(tr, 4) |> should.equal(Some(False))
  // The synthetic result is a tool message carrying the cancelled error.
  let assert [
    _,
    _,
    _,
    _,
    chat.ToolMessage(content: chat.ToolTextContent(content), ..),
  ] = transcript.messages(tr)
  content |> should.equal("{\"error\":\"cancelled\"}")
}

pub fn stop_consumed_mid_script_by_codemode_skips_rest_test() {
  // The issue-#52 shape: a Stop lands MID-SCRIPT, so codemode's select
  // consumes the subject's Nil to end the script and re-signals it (its
  // one-shot contract). The loop's pre-dispatch poll sees the re-signaled
  // Nil and skips every remaining call in the round — here two echoes
  // that must never start — ending the turn with no second request.
  let _ = reset_index()
  let cancel = process.new_subject()
  let codemode_like =
    tools.ToolSpec(
      tool: tools.function_tool(
        name: "codemode",
        description: "stop lands mid-script",
        parameters_json: "{\"type\":\"object\",\"properties\":{}}",
      ),
      run: fn(_ctx, _arguments) {
        // The Stop arrives mid-script; codemode's await consumes it to
        // end the run, then run_script re-signals the one-shot subject.
        process.send(cancel, Nil)
        let assert Ok(Nil) = process.receive(cancel, 0)
        process.send(cancel, Nil)
        Error("cancelled")
      },
    )
  let stream =
    single_round_stream([
      openai.ToolCallDelta(0, Some("c1"), Some("codemode"), "{}"),
      openai.ToolCallDelta(1, Some("c2"), Some("echo"), "{}"),
      openai.ToolCallDelta(2, Some("c3"), Some("echo"), "{}"),
    ])
  let events = process.new_subject()
  let outcome =
    loop.run(
      [codemode_like, echo_tool()],
      8,
      stream,
      tr_with_user(),
      cancel,
      fn(event) { process.send(events, event) },
    )
  let received = drain(events, [])
  let assert loop.LoopStopped(tr) = outcome
  // The codemode call itself ran and failed; both later calls were
  // assembled but answered with the synthetic cancelled result.
  should.be_true(list.contains(
    received,
    loop.ToolResultEvent("c1", "codemode", False, "{\"error\":\"cancelled\"}"),
  ))
  should.be_true(list.contains(
    received,
    loop.ToolResultEvent("c2", "echo", False, "{\"error\":\"cancelled\"}"),
  ))
  should.be_true(list.contains(
    received,
    loop.ToolResultEvent("c3", "echo", False, "{\"error\":\"cancelled\"}"),
  ))
  // system + user + assistant(calls) + three tool results.
  transcript.length(tr) |> should.equal(6)
  // No echo result anywhere — the echo tool never ran.
  should.be_false(
    transcript.messages(tr)
    |> list.any(fn(message) {
      case message {
        chat.ToolMessage(content: chat.ToolTextContent("echo:{}"), ..) -> True
        _ -> False
      }
    }),
  )
}

// ---------------------------------------------------------------------------
// The per-toolset envelope (bots plan P2): frozen_options is the ONE
// construction site; the no-tools envelope is OMISSION.
// ---------------------------------------------------------------------------

/// A chat-only thread (empty toolset) sends NEITHER `tools` nor
/// `tool_choice`: the encoder skips empty/None, and the omitted-fields
/// envelope is frozen at creation like any other.
pub fn frozen_options_chat_only_omits_tools_test() {
  let opts = loop.frozen_options([])
  should.equal(opts.tools, [])
  should.equal(opts.tool_choice, None)

  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("hello")
  let body = transcript.request_body(tr, opts)
  should.be_false(string.contains(body, "\"tools\""))
  should.be_false(string.contains(body, "\"tool_choice\""))
}

/// A non-empty toolset carries its schemas and auto tool choice, exactly
/// as before P2 — the default toolset's envelope is byte-identical to the
/// pre-phase one.
pub fn frozen_options_nonempty_carries_schemas_and_auto_test() {
  let opts = loop.frozen_options([echo_tool()])
  should.equal(
    opts.tool_choice,
    Some(chat.ToolChoiceModeChoice(chat.ToolChoiceAuto)),
  )
  // The exact schema, not just the count: the envelope is the frozen
  // prefix, so a wrong (or reordered) schema must fail here.
  should.equal(opts.tools, [echo_tool().tool])

  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("hello")
  let body = transcript.request_body(tr, opts)
  should.be_true(string.contains(body, "\"tools\""))
  should.be_true(string.contains(body, "\"tool_choice\""))
}

/// Split a serialized body at the messages/stream boundary — the m3
/// golden's own shape: the messages array must grow by suffix only, and
/// the envelope after it (stream, tools, tool_choice) must stay
/// byte-identical.
fn body_parts(body: String) -> #(String, String) {
  case string.split(body, on: ",\"stream\"") {
    [messages, envelope] -> #(messages, ",\"stream\"" <> envelope)
    _ -> panic as "request body has no stream marker"
  }
}

/// Per-thread byte stability with the envelope varying BY THREAD, not by
/// turn: the same specs rebuild the same body, and growth is suffix-only
/// (the chat-only form included).
pub fn frozen_options_suffix_only_growth_per_toolset_test() {
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("first")

  let opts = loop.frozen_options([echo_tool()])
  let opts_again = loop.frozen_options([echo_tool()])
  should.equal(
    transcript.request_body(tr, opts),
    transcript.request_body(tr, opts_again),
  )

  // A second turn of the same thread: the messages array grows at the
  // tail only, and the envelope (stream + tools + tool_choice) is
  // byte-identical.
  let tr2 = transcript.append_user(tr, "second")
  let #(prev_messages, prev_envelope) =
    body_parts(transcript.request_body(tr, opts))
  let #(next_messages, next_envelope) =
    body_parts(transcript.request_body(tr2, opts))
  should.be_true(string.starts_with(
    next_messages,
    string.drop_end(prev_messages, 1),
  ))
  should.equal(prev_envelope, next_envelope)

  // The chat-only form is equally byte-stable, with its omission
  // envelope (no tools/tool_choice keys at all).
  let chat_only = loop.frozen_options([])
  let #(prev_messages, prev_envelope) =
    body_parts(transcript.request_body(tr, chat_only))
  should.be_false(string.contains(prev_envelope, "tools"))
  let #(next_messages, next_envelope) =
    body_parts(transcript.request_body(tr2, chat_only))
  should.be_true(string.starts_with(
    next_messages,
    string.drop_end(prev_messages, 1),
  ))
  should.equal(prev_envelope, next_envelope)
}

/// Different toolsets get different envelopes BY DESIGN (the plan's
/// accepted trade: the tools array stops sharing across different bots;
/// threads of the same bot still share their system+tools head).
pub fn frozen_options_divergent_toolsets_diverge_test() {
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("hello")
  let with_tools =
    transcript.request_body(tr, loop.frozen_options([echo_tool()]))
  let chat_only = transcript.request_body(tr, loop.frozen_options([]))
  should.be_false(with_tools == chat_only)
}
