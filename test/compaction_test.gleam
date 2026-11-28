//// Offline unit tests for `nexus/compaction` (context-compaction Phase 2):
//// slash-command parser, focus validation, token budgets, safe cut-point
//// picker (strict role alternation on both sides), prompt construction,
//// fence stripping / size capping, and single-stream runner behavior.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import nexus/compaction
import nexus/openai
import nexus/transcript

@external(erlang, "openai_property_test_ffi", "serve_once")
fn serve_once(response: BitArray) -> Int

// ---------------------------------------------------------------------------
// Slash command parser & focus validation (§7.1)
// ---------------------------------------------------------------------------

pub fn parse_command_strict_matching_test() {
  compaction.parse_command("/compact")
  |> should.equal(Some(compaction.Compact(None)))
  compaction.parse_command("  /compact  ")
  |> should.equal(Some(compaction.Compact(None)))
  compaction.parse_command("/compact   ")
  |> should.equal(Some(compaction.Compact(None)))
  compaction.parse_command("/compact\t")
  |> should.equal(Some(compaction.Compact(None)))
  compaction.parse_command("/compact preserve SQL migrations")
  |> should.equal(Some(compaction.Compact(Some("preserve SQL migrations"))))
  compaction.parse_command("/compact\tkeep line numbers")
  |> should.equal(Some(compaction.Compact(Some("keep line numbers"))))
  compaction.parse_command("/compact\nfocus on auth")
  |> should.equal(Some(compaction.Compact(Some("focus on auth"))))

  // Must NEVER swallow ordinary slash-prefixed paths or other words.
  compaction.parse_command("/etc/hosts") |> should.equal(None)
  compaction.parse_command("/compact-notes") |> should.equal(None)
  compaction.parse_command("/compaction") |> should.equal(None)
  compaction.parse_command("please /compact") |> should.equal(None)
  compaction.parse_command("") |> should.equal(None)
}

pub fn validate_focus_normalizes_and_enforces_limit_test() {
  compaction.validate_focus(None) |> should.equal(Ok(None))
  compaction.validate_focus(Some("   \t\n ")) |> should.equal(Ok(None))
  compaction.validate_focus(Some("  keep paths  "))
  |> should.equal(Ok(Some("keep paths")))

  let exact = string.repeat("a", compaction.max_focus_chars)
  compaction.validate_focus(Some(exact)) |> should.equal(Ok(Some(exact)))

  let over = string.repeat("a", compaction.max_focus_chars + 1)
  compaction.validate_focus(Some(over))
  |> should.equal(Error(compaction.max_focus_chars))
}

// ---------------------------------------------------------------------------
// Budget helpers (§5.2, §5.3)
// ---------------------------------------------------------------------------

pub fn budget_helpers_clamp_correctly_test() {
  // summary_max_tokens: min(cfg, max(512, limit / 4)) when configured
  compaction.summary_max_tokens(4096, Some(8192)) |> should.equal(2048)
  compaction.summary_max_tokens(4096, Some(1024)) |> should.equal(512)
  compaction.summary_max_tokens(4096, Some(128_000)) |> should.equal(4096)
  compaction.summary_max_tokens(4096, None) |> should.equal(4096)
  compaction.summary_max_tokens(200, None) |> should.equal(512)

  // keep_tail_tokens: 0 when pct == 0; clamp [2000, 16000] when configured; 4000 when None
  compaction.keep_tail_tokens(0, Some(65_536)) |> should.equal(0)
  compaction.keep_tail_tokens(0, None) |> should.equal(0)
  compaction.keep_tail_tokens(20, Some(8192)) |> should.equal(2000)
  compaction.keep_tail_tokens(20, Some(32_768)) |> should.equal(6553)
  compaction.keep_tail_tokens(20, Some(200_000)) |> should.equal(16_000)
  compaction.keep_tail_tokens(20, None) |> should.equal(4000)

  // max_summary_chars: global 32_000 ceiling only when context_window is None
  compaction.max_summary_chars(4096, None, 4.0) |> should.equal(16_384)
  compaction.max_summary_chars(20_000, None, 4.0)
  |> should.equal(compaction.max_summary_chars_unbounded)
  compaction.max_summary_chars(20_000, Some(128_000), 4.0)
  |> should.equal(80_000)
}

// ---------------------------------------------------------------------------
// Safe cut-point picker (§5.2)
// ---------------------------------------------------------------------------

/// Verify strict role alternation on BOTH the summarization request and the
/// post-compaction projected active window for any chosen cutoff.
fn assert_strict_alternation(msgs: List(chat.ChatMessage)) -> Nil {
  // After leading system message, no two adjacent user messages may appear,
  // no assistant tool_calls without following tool messages, and no leading
  // tool message.
  let body = case msgs {
    [chat.SystemMessage(..), ..rest] -> rest
    other -> other
  }
  let _ =
    list.fold(body, None, fn(prev, cur) {
      case prev, cur {
        Some(chat.UserMessage(..)), chat.UserMessage(..) ->
          panic as "adjacent UserMessage violates strict role alternation"
        None, chat.ToolMessage(..) ->
          panic as "orphaned leading ToolMessage in active window"
        Some(chat.AssistantMessage(tool_calls: Some([_, ..]), ..)),
          chat.UserMessage(..)
        -> panic as "UserMessage immediately after unfulfilled tool_calls"
        _, _ -> Some(cur)
      }
    })
  Nil
}

pub fn pick_cutoff_empty_or_single_small_turn_returns_nothing_test() {
  let empty = transcript.new("m", "sys")
  compaction.pick_cutoff(empty, 4000, Some(32_768), 4.0)
  |> should.equal(Error(compaction.NothingToCompact))

  let user_only = empty |> transcript.append_user("hello")
  compaction.pick_cutoff(user_only, 4000, Some(32_768), 4.0)
  |> should.equal(Error(compaction.NothingToCompact))

  // One tiny completed turn with keep_tail_tokens > turn size -> NothingToCompact.
  let one_small = user_only |> transcript.append_assistant("hi")
  compaction.pick_cutoff(one_small, 4000, Some(32_768), 4.0)
  |> should.equal(Error(compaction.NothingToCompact))

  // Same single turn when keep_tail_tokens == 0 -> allowed to compact to end.
  compaction.pick_cutoff(one_small, 0, Some(32_768), 4.0)
  |> should.equal(Ok(3))
}

pub fn pick_cutoff_allows_single_huge_turn_to_end_test() {
  // One massive turn exceeding keep_tail_tokens compacts up to total_len.
  let huge =
    transcript.new("m", "sys")
    |> transcript.append_user(string.repeat("x", 20_000))
    |> transcript.append_assistant("done")
  compaction.pick_cutoff(huge, 4000, Some(32_768), 4.0)
  |> should.equal(Ok(3))
}

pub fn pick_cutoff_never_splits_tool_round_test() {
  // Indices:
  // 0: system
  // 1: user ("turn 1")
  // 2: assistant tool_calls
  // 3: tool result
  // 4: assistant ("turn 1 answer")
  // 5: user ("turn 2")
  // 6: assistant tool_calls
  // 7: tool result
  // 8: assistant ("turn 2 answer")
  let tr =
    transcript.new("m", "sys")
    |> transcript.append_user(string.repeat("a", 8000))
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c1", "bash", "{\"command\":\"ls\"}")],
      reasoning: None,
    )
    |> transcript.append_tool_result("c1", string.repeat("b", 8000), ok: True)
    |> transcript.append_assistant("turn 1 answer")
    |> transcript.append_user(string.repeat("c", 2000))
    |> transcript.append_assistant_tool_calls(
      text: None,
      calls: [#("c2", "bash", "{\"command\":\"pwd\"}")],
      reasoning: None,
    )
    |> transcript.append_tool_result("c2", "ok", ok: True)
    |> transcript.append_assistant("turn 2 answer")

  let assert Ok(cutoff) = compaction.pick_cutoff(tr, 1000, Some(32_768), 4.0)
  // Must cut cleanly at index 5 (between turn 1's final assistant and turn 2's user).
  cutoff |> should.equal(5)

  // Both summarization request and post-compaction active window strictly alternate.
  let prep = compaction.prepare(tr, cutoff, None)
  assert_strict_alternation(transcript.request_messages(prep))
  let compacted =
    transcript.apply_compaction(
      tr,
      transcript.Compaction(
        cutoff_index: cutoff,
        summary: "Summary of turn 1.",
        roster_snapshot: None,
        focus: None,
        trigger: transcript.ManualCompact,
        before_tokens: None,
        after_tokens: None,
        created_at: 1000,
      ),
    )
  assert_strict_alternation(transcript.request_messages(compacted))
}

pub fn pick_cutoff_respects_roster_lines_and_failed_turn_user_messages_test() {
  // Indices:
  // 0: system
  // 1: system roster line (UserMessage, origin=system)
  // 2: user ("q1")
  // 3: assistant ("a1")
  // 4: system roster line (UserMessage, origin=system)
  // 5: user ("q2 failed")   <-- retained failed turn user message!
  // 6: user ("q3")
  // 7: assistant ("a3")
  let tr =
    transcript.new("m", "sys")
    |> transcript.append_user("Attached environments: workspace.")
    |> transcript.mark_origin(Some("system"), 0)
    |> transcript.append_user(string.repeat("q", 6000))
    |> transcript.append_assistant(string.repeat("a", 6000))
    |> transcript.append_user("Attached environments: workspace, laptop.")
    |> transcript.mark_origin(Some("system"), 0)
    |> transcript.append_user("q2 failed")
    |> transcript.append_user("q3")
    |> transcript.append_assistant("a3")

  // Boundary 4 has right = system roster line (disallowed!).
  // Boundary 5 has left = system roster line (UserMessage, disallowed!).
  // Boundary 6 has left = failed-turn UserMessage (disallowed!).
  // Only boundary 8 (total_len) is strictly valid on both sides!
  let assert Ok(cutoff) = compaction.pick_cutoff(tr, 1000, Some(32_768), 4.0)
  cutoff |> should.equal(8)

  // At the cut boundary, the message before the appended compaction instruction
  // is an assistant message (never a user/roster message), and the post-compaction
  // active window strictly alternates.
  let prep = compaction.prepare(tr, cutoff, None)
  let assert [chat.UserMessage(..), chat.AssistantMessage(..), ..] =
    list.reverse(transcript.request_messages(prep))
  let compacted =
    transcript.apply_compaction(
      tr,
      transcript.Compaction(
        cutoff_index: cutoff,
        summary: "Compacted summary.",
        roster_snapshot: Some("attached targets: workspace, laptop."),
        focus: None,
        trigger: transcript.ManualCompact,
        before_tokens: None,
        after_tokens: None,
        created_at: 1000,
      ),
    )
  assert_strict_alternation(transcript.request_messages(compacted))
}

pub fn pick_cutoff_incremental_advances_past_prior_checkpoint_test() {
  let tr0 =
    transcript.new("m", "sys")
    |> transcript.append_user("u1")
    |> transcript.append_assistant("a1")
    |> transcript.append_user("u2")
    |> transcript.append_assistant("a2")
    |> transcript.append_user("u3")
    |> transcript.append_assistant("a3")
  let cp1 =
    transcript.Compaction(
      cutoff_index: 3,
      summary: "Summary 1",
      roster_snapshot: None,
      focus: None,
      trigger: transcript.ManualCompact,
      before_tokens: None,
      after_tokens: None,
      created_at: 1000,
    )
  let tr1 = transcript.apply_compaction(tr0, cp1)
  // Active window now starts at 3 (u2, a2, u3, a3). With small tail budget, cuts at 5.
  let assert Ok(cutoff2) = compaction.pick_cutoff(tr1, 50, Some(32_768), 4.0)
  cutoff2 |> should.equal(5)

  // Prepare uses incremental merge phrasing when a prior checkpoint is active.
  let prep = compaction.prepare(tr1, cutoff2, Some("keep API names"))
  let req_msgs = transcript.request_messages(prep)
  assert_strict_alternation(req_msgs)
  let assert Ok(chat.UserMessage(content: chat.UserTextContent(prompt), ..)) =
    list.last(req_msgs)
  should.be_true(string.contains(prompt, "merge and update"))
  should.be_true(string.contains(
    prompt,
    "Preserve detail especially regarding: keep API names",
  ))
  should.be_true(string.contains(prompt, "Do not call any tools."))
}

// ---------------------------------------------------------------------------
// Fence stripping & summary shaping (§5.3)
// ---------------------------------------------------------------------------

pub fn strip_outer_fences_preserves_internal_code_blocks_test() {
  let wrapped =
    "```markdown\n## Goal & Constraints\nUse this:\n```gleam\nlet x = 1\n```\n## Next Steps\nShip it.\n```"
  compaction.strip_outer_fences(wrapped)
  |> should.equal(
    "## Goal & Constraints\nUse this:\n```gleam\nlet x = 1\n```\n## Next Steps\nShip it.",
  )

  // Two separate fenced blocks must NOT have their first opening and last
  // closing ticks stripped.
  let two_blocks = "```gleam\na\n```\nmiddle\n```gleam\nb\n```"
  compaction.strip_outer_fences(two_blocks) |> should.equal(two_blocks)
}

pub fn shape_summary_rejects_short_and_caps_oversized_test() {
  compaction.shape_summary("   ", 1000) |> should.be_error
  compaction.shape_summary("ok", 1000) |> should.be_error

  let long = string.repeat("z", 500)
  let assert Ok(capped) = compaction.shape_summary(long, 100)
  string.length(capped) |> should.equal(100)
}

// ---------------------------------------------------------------------------
// Single-stream `run` against local stub OpenAI server (§5.3)
// ---------------------------------------------------------------------------

fn sample_transcript() -> transcript.Transcript {
  transcript.new("test-model", "sys")
  |> transcript.append_user("hello")
  |> transcript.append_assistant("world")
}

fn stub_endpoint(port: Int) -> openai.Endpoint {
  openai.Endpoint(
    base_url: "http://127.0.0.1:" <> int.to_string(port) <> "/v1",
    api_key: Some("test-key"),
    sse_first_response_timeout_ms: 5000,
    stream_idle_timeout_ms: 5000,
  )
}

fn serve_sse(body: String) -> Int {
  let raw =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
    <> body
  serve_once(bit_array.from_string(raw))
}

fn sse_chunk(delta_json: String) -> String {
  "data: {\"id\":\"chatcmpl-cp-1\",\"object\":\"chat.completion.chunk\","
  <> "\"created\":1730000001,\"model\":\"test-model\","
  <> "\"choices\":[{\"index\":0,\"delta\":"
  <> delta_json
  <> ",\"finish_reason\":null}]}\n\n"
}

pub fn run_ignores_reasoning_strips_fences_and_succeeds_test() {
  let sse =
    sse_chunk("{\"role\":\"assistant\",\"reasoning_content\":\"secret cot\"}")
    <> sse_chunk(
      "{\"content\":\"```markdown\\n## Goal & Constraints\\nKept.\"}",
    )
    <> sse_chunk("{\"content\":\"\\n```\"}")
    <> "data: [DONE]\n\n"
  let port = serve_sse(sse)
  let cancel = process.new_subject()
  let res =
    compaction.run(
      stub_endpoint(port),
      sample_transcript(),
      3,
      None,
      transcript.default_options(),
      4096,
      Some(32_768),
      4.0,
      cancel,
    )
  res |> should.equal(Ok("## Goal & Constraints\nKept."))
}

pub fn run_fails_on_tool_call_delta_test() {
  let sse =
    sse_chunk(
      "{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}",
    )
    <> "data: [DONE]\n\n"
  let port = serve_sse(sse)
  let cancel = process.new_subject()
  let res =
    compaction.run(
      stub_endpoint(port),
      sample_transcript(),
      3,
      None,
      transcript.default_options(),
      4096,
      Some(32_768),
      4.0,
      cancel,
    )
  let assert Error(reason) = res
  should.be_true(string.contains(reason, "tool call"))
}

pub fn run_fails_on_reasoning_only_blank_reply_test() {
  let sse =
    sse_chunk(
      "{\"role\":\"assistant\",\"reasoning_content\":\"thinking only\"}",
    )
    <> "data: [DONE]\n\n"
  let port = serve_sse(sse)
  let cancel = process.new_subject()
  let res =
    compaction.run(
      stub_endpoint(port),
      sample_transcript(),
      3,
      None,
      transcript.default_options(),
      4096,
      Some(32_768),
      4.0,
      cancel,
    )
  should.be_error(res)
}

pub fn run_respects_cancel_signal_test() {
  let port =
    serve_sse("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
  let cancel = process.new_subject()
  // Pre-signal cancellation before running.
  process.send(cancel, Nil)
  let res =
    compaction.run(
      stub_endpoint(port),
      sample_transcript(),
      3,
      None,
      transcript.default_options(),
      4096,
      Some(32_768),
      4.0,
      cancel,
    )
  res |> should.equal(Error("cancelled"))
}
