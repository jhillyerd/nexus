//// Byte-stability tests: the same immutable transcript must encode to
//// byte-identical request bodies, and appending a turn must leave the
//// serialized prefix untouched (KV-cache contract rules 1–4).
////
//// The golden literal below is a *committed* fixture encoding. It may only
//// change as a deliberate act when the encoding intentionally changes.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import glopenai/shared.{type FunctionObject, FunctionObject}
import nexus/transcript

fn system_prompt() -> String {
  "You are nexus, a precise local assistant. Reason carefully and answer concisely."
}

/// Deterministic 20-turn fixture (1 system + 19 user/assistant turns).
fn fixture_20_turns() -> transcript.Transcript {
  let base = transcript.new("llamacpp-small", system_prompt())
  list.fold(int.range(1, 21, [], list.prepend) |> list.reverse, base, fn(t, i) {
    t
    |> transcript.append_user(
      "question "
      <> int.to_string(i)
      <> ": what is "
      <> int.to_string(i)
      <> " squared plus one?",
    )
    |> transcript.append_assistant(
      "answer " <> int.to_string(i) <> ": " <> int.to_string(i * i + 1),
    )
  })
}

fn fixture_1_turn() -> transcript.Transcript {
  transcript.new("llamacpp-small", system_prompt())
  |> transcript.append_user("question 1: what is 1 squared plus one?")
  |> transcript.append_assistant("answer 1: 2")
}

fn stream_opts() -> transcript.Options {
  transcript.Options(..transcript.default_options(), stream: True)
}

pub fn deterministic_encode_test() {
  // Encoding the same immutable transcript repeatedly is byte-stable.
  let body_a =
    transcript.request_body(fixture_20_turns(), transcript.default_options())
  let body_b =
    transcript.request_body(fixture_20_turns(), transcript.default_options())
  let body_c =
    transcript.request_body(fixture_20_turns(), transcript.default_options())
  should.equal(body_a, body_b)
  should.equal(body_b, body_c)
}

pub fn prefix_invariance_test() {
  // Appending a turn must not re-encode the prefix: the entire serialized
  // messages array of the shorter body appears verbatim inside the longer
  // body, right up to (and including) its closing bracket.
  let short = transcript.request_body(fixture_20_turns(), stream_opts())
  let longer =
    fixture_20_turns()
    |> transcript.append_user("question 21: and what is 21 squared plus one?")
    |> transcript.request_body(stream_opts())
  // The fixture's tail after the messages array is exactly this.
  should.be_true(string.ends_with(short, "],\"stream\":true}"))
  let short_prefix = string.drop_end(short, 16)
  // In the longer body the array continues, so the prefix is followed by
  // a comma rather than the closing bracket.
  should.be_true(string.contains(longer, short_prefix <> ","))
}

pub fn golden_fixture_body_test() {
  // Committed golden encoding of the streamed 1-turn fixture.
  // If this fails, encoding changed — update deliberately and document why.
  let expected =
    "{\"model\":\"llamacpp-small\",\"messages\":["
    <> "{\"role\":\"system\",\"content\":\""
    <> system_prompt()
    <> "\"},"
    <> "{\"role\":\"user\",\"content\":\"question 1: what is 1 squared plus one?\"},"
    <> "{\"role\":\"assistant\",\"content\":\"answer 1: 2\"}"
    <> "],\"stream\":true}"
  should.equal(
    transcript.request_body(fixture_1_turn(), stream_opts()),
    expected,
  )
}

pub fn golden_twenty_turn_fixture_shape_test() {
  // Structural invariants of the 20-turn golden fixture: 1 system + 20
  // user/assistant pairs = 41 messages, no volatile data, chronological.
  let t = fixture_20_turns()
  should.equal(transcript.length(t), 41)
  let body = transcript.request_body(t, stream_opts())
  should.be_true(string.contains(
    body,
    "question 20: what is 20 squared plus one?",
  ))
  should.be_false(string.contains(body, "timestamp"))
}

pub fn options_change_body_test() {
  // Different options must produce a different body (no accidental caching).
  let t = fixture_1_turn()
  let plain = transcript.request_body(t, transcript.default_options())
  let streamed = transcript.request_body(t, stream_opts())
  should.be_false(plain == streamed)
}

pub fn tool_result_roundtrip_encoding_test() {
  let body =
    fixture_1_turn()
    |> transcript.append_assistant_tool_call(
      id: "call_abc",
      name: "get_time",
      arguments: "{}",
    )
    |> transcript.append_tool_result(
      "call_abc",
      "\"2026-10-12T00:00:00Z\"",
      ok: True,
    )
    |> transcript.request_body(stream_opts())
  // Assistant tool-call turn shape (glopenai: type before id before function).
  should.be_true(string.contains(
    body,
    "{\"type\":\"function\",\"id\":\"call_abc\",\"function\":{\"name\":\"get_time\",\"arguments\":\"{}\"}}",
  ))
  // Tool result turn shape.
  should.be_true(string.contains(
    body,
    "{\"role\":\"tool\",\"content\":\"\\\"2026-10-12T00:00:00Z\\\"\",\"tool_call_id\":\"call_abc\"}",
  ))
}

fn get_time_tool() -> FunctionObject {
  FunctionObject(
    name: "get_time",
    description: Some("Current local time"),
    parameters: None,
    strict: None,
  )
}

pub fn tools_encoded_deterministically_test() {
  let opts =
    transcript.Options(..stream_opts(), tools: [
      chat.FunctionTool(function: get_time_tool()),
    ])
  let a = transcript.request_body(fixture_1_turn(), opts)
  let b = transcript.request_body(fixture_1_turn(), opts)
  should.equal(a, b)
  should.be_true(string.contains(
    a,
    "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_time\"",
  ))
}

// ---------------------------------------------------------------------------
// Reasoning sidecar (display-only, never in a request byte)
// ---------------------------------------------------------------------------

pub fn reasoning_never_changes_request_bytes_test() {
  let opts = transcript.default_options()
  let plain =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant("a")
  let reasoned =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant_with_reasoning(
      "a",
      reasoning: Some("secret thoughts"),
    )
  transcript.request_body(plain, opts)
  |> should.equal(transcript.request_body(reasoned, opts))

  // Same for tool-call rounds: the reasoning rides beside the message.
  let calls = [#("c1", "echo", "{}")]
  let plain_tools =
    plain
    |> transcript.append_assistant_tool_calls(
      text: Some("t"),
      calls: calls,
      reasoning: None,
    )
  let reasoned_tools =
    reasoned
    |> transcript.append_assistant_tool_calls(
      text: Some("t"),
      calls: calls,
      reasoning: Some("why"),
    )
  transcript.request_body(plain_tools, opts)
  |> should.equal(transcript.request_body(reasoned_tools, opts))
}

pub fn reasoning_at_indexes_chronologically_test() {
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant_with_reasoning("a", reasoning: Some("chain"))
    |> transcript.append_user("again")
    |> transcript.append_assistant("b")
  // system=0, user=1, assistant=2 (reasoned), user=3, assistant=4.
  transcript.reasoning_at(tr, 2) |> should.equal(Some("chain"))
  transcript.reasoning_at(tr, 0) |> should.equal(None)
  transcript.reasoning_at(tr, 4) |> should.equal(None)
}

pub fn empty_reasoning_is_dropped_test() {
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant_with_reasoning("a", reasoning: Some(""))
  transcript.reasoning_at(tr, 2) |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Timestamp sidecar (display-only, never in a request byte)
// ---------------------------------------------------------------------------

pub fn stamp_never_changes_request_bytes_test() {
  let opts = transcript.default_options()
  let plain =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant("a")
  let stamped =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.stamp(1000)
    |> transcript.append_assistant("a")
    |> transcript.stamp(2000)
  // The sidecar mirrors reasoning's contract: present on the commit /
  // write-behind / replay lane, structurally absent from every byte.
  transcript.request_body(plain, opts)
  |> should.equal(transcript.request_body(stamped, opts))
}

pub fn stamped_at_indexes_chronologically_test() {
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.stamp(1000)
    |> transcript.append_assistant("a")
    |> transcript.stamp(2000)
  // system=0 (never stamped), user=1, assistant=2.
  transcript.stamped_at(tr, 1) |> should.equal(Some(1000))
  transcript.stamped_at(tr, 2) |> should.equal(Some(2000))
  transcript.stamped_at(tr, 0) |> should.equal(None)
  // Never-stamped messages have no entry, not a zero.
  transcript.stamped_at(tr, 3) |> should.equal(None)
}

pub fn stamp_opt_passthrough_test() {
  let tr = transcript.new("m", "s") |> transcript.append_user("q")
  let kept = transcript.stamp_opt(tr, Some(5000))
  transcript.stamped_at(kept, 1) |> should.equal(Some(5000))
  // The persistence lane's no-op for unstamped (legacy) rows.
  let dropped = transcript.stamp_opt(tr, None)
  transcript.stamped_at(dropped, 1) |> should.equal(None)
}

// Origin sidecar (display-only, never in a request byte) — bots P3b.
// ---------------------------------------------------------------------------

pub fn origin_never_changes_request_bytes_test() {
  let opts = transcript.default_options()
  let plain =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.append_assistant("a")
  let authored =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.mark_origin(Some("Hermes"), 2)
    |> transcript.stamp(1000)
    |> transcript.append_assistant("a")
    |> transcript.stamp(2000)
  // The sidecar mirrors reasoning's contract: present on the commit /
  // write-behind / replay lane, structurally absent from every byte.
  transcript.request_body(plain, opts)
  |> should.equal(transcript.request_body(authored, opts))
}

pub fn origin_at_indexes_chronologically_test() {
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("human")
    |> transcript.append_assistant("a")
    |> transcript.append_user("from a bot")
    |> transcript.mark_origin(Some("Hermes"), 2)
  // system=0 (never marked); the human user message=1 records absence —
  // absence IS the human case, not a zero-depth entry; assistant=2;
  // the authored user message=3 carries the frozen name + hop count.
  transcript.origin_at(tr, 0) |> should.equal(None)
  transcript.origin_at(tr, 1) |> should.equal(None)
  transcript.origin_at(tr, 2) |> should.equal(None)
  transcript.origin_at(tr, 3)
  |> should.equal(Some(transcript.Origin("Hermes", 2)))
}

pub fn mark_origin_requires_a_real_author_test() {
  // None (a human send) and '' (never a valid author — the store's
  // nullif sentinel would file it as human anyway) both mark nothing:
  // the dict stays as sparse as `timestamps`.
  let human =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.mark_origin(None, 0)
  transcript.origin_at(human, 1) |> should.equal(None)
  let empty =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.mark_origin(Some(""), 3)
  transcript.origin_at(empty, 1) |> should.equal(None)
}

pub fn last_text_stamp_picks_newest_assistant_text_test() {
  let tr =
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.stamp(1000)
    |> transcript.append_assistant("a")
    |> transcript.stamp(2000)
    |> transcript.append_tool_result("c1", "r", ok: True)
    |> transcript.stamp(3000)
    |> transcript.append_assistant("final")
    |> transcript.stamp(4000)
  // The terminal-turn stamp: the newest assistant TEXT message (tool
  // results and the user turn in between are skipped).
  transcript.last_text_stamp(tr) |> should.equal(Some(4000))
}

pub fn last_text_stamp_none_without_stamped_assistant_text_test() {
  // Nothing committed at all.
  transcript.last_text_stamp(transcript.new("m", "s")) |> should.equal(None)
  // User/tool messages only: no assistant text to stamp.
  transcript.last_text_stamp(
    transcript.new("m", "s")
    |> transcript.append_user("q")
    |> transcript.stamp(1000),
  )
  |> should.equal(None)
  // An unstamped assistant text (legacy hydration shape) reads as None.
  transcript.last_text_stamp(
    transcript.new("m", "s") |> transcript.append_assistant("unstamped"),
  )
  |> should.equal(None)
  // An UNSTAMPED newest text over an older stamped one must report None —
  // the older stamp belongs to a different message and must not leak into
  // the newer text's terminal event.
  transcript.last_text_stamp(
    transcript.new("m", "s")
    |> transcript.append_assistant("old")
    |> transcript.stamp(2000)
    |> transcript.append_assistant("new"),
  )
  |> should.equal(None)
}
