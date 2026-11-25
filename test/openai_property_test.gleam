//// Phase 3a property-based & adversarial SSE framing / provider-dialect tests
//// (`docs/plans/verification.md`).
////
//// Exercises `nexus/openai`'s pure byte-level `StreamFeeder` offline ($0,
//// deterministic seeds):
////   - Targeted regression tests for multi-byte UTF-8 and `\r\n` splits
////     across TCP chunk boundaries (plus invalid/truncated UTF-8 rejection).
////   - Chunk-boundary invariance property across 200 generated SSE streams
////     (ASCII, multi-byte UTF-8, mixed `\r\n`/`\n`/`\r`, reasoning deltas,
////     parallel tool calls, usage blocks, comments) split at random boundaries
////     and 1-byte boundaries.
////   - Deterministic clock verification of `ttft_ms` and `duration_ms`.
////   - Hostile / malformed stream fuzzing (truncation, garbage JSON,
////     missing/duplicate tool call IDs, reasoning-only turns, whitespace-only
////     content alongside tool calls, out-of-order usage chunks).
////   - Recorded dialect fixtures (`test/fixtures/wire/*.sse`) for vLLM,
////     llama.cpp (keyless), OpenAI, and OpenRouter replayed whole, 1-byte at a
////     time, and under random chunk splits.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import glopenai/shared
import nexus/openai
import prop
import simplifile

// ---------------------------------------------------------------------------
// Feeder replay helpers
// ---------------------------------------------------------------------------

type TimingIndependentStats {
  TimingIndependentStats(
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
    events_parsed: Int,
    decode_errors: Int,
    saw_done: Bool,
    usage: Option(shared.CompletionUsage),
  )
}

fn strip_timing(stats: openai.StreamStats) -> TimingIndependentStats {
  TimingIndependentStats(
    token_deltas: stats.token_deltas,
    reasoning_deltas: stats.reasoning_deltas,
    tool_call_deltas: stats.tool_call_deltas,
    events_parsed: stats.events_parsed,
    decode_errors: stats.decode_errors,
    saw_done: stats.saw_done,
    usage: stats.usage,
  )
}

type ReplayResult {
  ReplayResult(
    events: List(openai.StreamEvent),
    outcome: Result(openai.StreamStats, openai.StreamError),
  )
}

/// Replay a sequence of raw byte chunks through `openai.StreamFeeder` using a
/// deterministic clock that starts at `started_us` and advances by `step_us`
/// per chunk.
fn replay_chunks(
  chunks: List(BitArray),
  started_us: Int,
  step_us: Int,
) -> ReplayResult {
  let inbox = process.new_subject()
  let on_event = fn(ev) { process.send(inbox, ev) }
  let feeder = openai.new_feeder(started_us)
  let #(fed, final_us) =
    feed_chunks_loop(chunks, feeder, started_us, step_us, on_event)
  let outcome = case fed {
    Ok(done_feeder) -> openai.finish_feeder(done_feeder, final_us + step_us)
    Error(err) -> Error(err)
  }
  ReplayResult(events: drain_events(inbox, []), outcome: outcome)
}

fn feed_chunks_loop(
  chunks: List(BitArray),
  feeder: openai.StreamFeeder,
  now_us: Int,
  step_us: Int,
  on_event: fn(openai.StreamEvent) -> Nil,
) -> #(Result(openai.StreamFeeder, openai.StreamError), Int) {
  case chunks {
    [] -> #(Ok(feeder), now_us)
    [chunk, ..rest] -> {
      let next_us = now_us + step_us
      case openai.feed_bytes(feeder, chunk, next_us, on_event) {
        Ok(next_feeder) ->
          feed_chunks_loop(rest, next_feeder, next_us, step_us, on_event)
        Error(err) -> #(Error(err), next_us)
      }
    }
  }
}

fn drain_events(
  inbox: process.Subject(openai.StreamEvent),
  acc: List(openai.StreamEvent),
) -> List(openai.StreamEvent) {
  case process.receive(inbox, 0) {
    Ok(ev) -> drain_events(inbox, [ev, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn compare_timing_independent(
  reference: ReplayResult,
  actual: ReplayResult,
) -> Result(Nil, String) {
  case reference.events == actual.events {
    False ->
      Error(
        "events diverged:\n  expected="
        <> string.inspect(reference.events)
        <> "\n  actual="
        <> string.inspect(actual.events),
      )
    True ->
      case reference.outcome, actual.outcome {
        Ok(ref_stats), Ok(act_stats) ->
          case strip_timing(ref_stats) == strip_timing(act_stats) {
            True -> Ok(Nil)
            False ->
              Error(
                "stats diverged:\n  expected="
                <> string.inspect(strip_timing(ref_stats))
                <> "\n  actual="
                <> string.inspect(strip_timing(act_stats)),
              )
          }
        Error(ref_err), Error(act_err) ->
          case ref_err == act_err {
            True -> Ok(Nil)
            False ->
              Error(
                "errors diverged:\n  expected="
                <> string.inspect(ref_err)
                <> "\n  actual="
                <> string.inspect(act_err),
              )
          }
        _, _ ->
          Error(
            "outcome diverged:\n  expected="
            <> string.inspect(reference.outcome)
            <> "\n  actual="
            <> string.inspect(actual.outcome),
          )
      }
  }
}

// ---------------------------------------------------------------------------
// 1. Targeted regression tests for the two framing bugs + UTF-8 validation
// ---------------------------------------------------------------------------

pub fn split_multibyte_utf8_across_every_byte_boundary_test() {
  // Contains 2-byte (é), 3-byte (中, “, ”), and 4-byte (🚀, 🌤️) UTF-8.
  let wire =
    "data: {\"id\":\"u1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":"
    <> "{\"reasoning_content\":\"café “日本語” 🚀\"},\"finish_reason\":null}]}\n\n"
    <> "data: {\"id\":\"u1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":"
    <> "{\"content\":\"🌤️ done — naïve!\"},\"finish_reason\":\"stop\"}]}\n\n"
    <> "data: [DONE]\n\n"
  let raw = bit_array.from_string(wire)

  let whole = replay_chunks([raw], 0, 1000)
  let by_byte = replay_chunks(prop.single_byte_chunks(raw), 0, 1000)

  compare_timing_independent(whole, by_byte) |> should.equal(Ok(Nil))
  whole.events
  |> should.equal([
    openai.ReasoningDelta("café “日本語” 🚀"),
    openai.TokenDelta("🌤️ done — naïve!"),
  ])
  let assert Ok(stats) = whole.outcome
  stats.reasoning_deltas |> should.equal(1)
  stats.token_deltas |> should.equal(1)
  stats.events_parsed |> should.equal(2)
  stats.decode_errors |> should.equal(0)
  stats.saw_done |> should.equal(True)
}

pub fn split_crlf_and_mixed_line_endings_across_chunks_test() {
  // Deliberately exercises \r\n\r\n, \r\n\n, \n\r\n, \r\r\n, and bare \r\r
  // split directly between \r and \n and interspersed with empty chunks.
  let c1 =
    "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"one\"}}]}"
  let c2 =
    "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"two\"}}]}"
  let c3 =
    "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"three\"}"
    <> ",\"finish_reason\":\"stop\"}]}"

  let wire =
    c1
    <> "\r\n\r\n"
    <> c2
    <> "\r\r\n\n"
    <> c3
    <> "\n\r\n"
    <> "data: [DONE]\r\n\r\n"
  let raw = bit_array.from_string(wire)

  let whole = replay_chunks([raw], 0, 1000)
  let by_byte = replay_chunks(prop.single_byte_chunks(raw), 0, 1000)

  // Explicit split directly inside \r|\n\r|\n with empty chunks between.
  let surgical_chunks = [
    bit_array.from_string(c1 <> "\r"),
    <<>>,
    bit_array.from_string("\n\r"),
    <<>>,
    bit_array.from_string("\n" <> c2 <> "\r"),
    bit_array.from_string("\r"),
    bit_array.from_string("\n\n" <> c3 <> "\n\r"),
    bit_array.from_string("\ndata: [DONE]\r"),
    bit_array.from_string("\n\r"),
    bit_array.from_string("\n"),
  ]
  let surgical = replay_chunks(surgical_chunks, 0, 1000)

  compare_timing_independent(whole, by_byte) |> should.equal(Ok(Nil))
  compare_timing_independent(whole, surgical) |> should.equal(Ok(Nil))
  whole.events
  |> should.equal([
    openai.TokenDelta("one"),
    openai.TokenDelta("two"),
    openai.TokenDelta("three"),
  ])
  let assert Ok(stats) = whole.outcome
  stats.saw_done |> should.equal(True)
  stats.events_parsed |> should.equal(3)
}

pub fn invalid_and_truncated_utf8_rejected_consistently_test() {
  // Invalid byte sequences: orphan continuation, overlong 2-byte, UTF-16
  // surrogate (U+D800), out-of-range (> U+10FFFF), and 0xFF.
  let invalid_payloads = [
    <<0x80>>,
    <<0xC0, 0xAF>>,
    <<0xED, 0xA0, 0x80>>,
    <<0xF4, 0x90, 0x80, 0x80>>,
    <<0xFF>>,
    // Valid SSE prefix followed by truncated 4-byte emoji at EOF (first 3 bytes of 🚀).
    bit_array.append(
      bit_array.from_string(
        "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\n\n",
      ),
      <<0xF0, 0x9F, 0x9A>>,
    ),
  ]

  list.each(invalid_payloads, fn(payload) {
    let whole = replay_chunks([payload], 0, 1000)
    let by_byte = replay_chunks(prop.single_byte_chunks(payload), 0, 1000)
    let assert Error(openai.Transport("stream contained non-UTF-8 bytes")) =
      whole.outcome
    compare_timing_independent(whole, by_byte) |> should.equal(Ok(Nil))
  })
}

// ---------------------------------------------------------------------------
// 2. Deterministic clock verification for ttft_ms and duration_ms
// ---------------------------------------------------------------------------

pub fn deterministic_clock_ttft_and_duration_test() {
  let inbox = process.new_subject()
  let on_event = fn(ev) { process.send(inbox, ev) }

  // Started at t = 10_000 us (10 ms).
  let f0 = openai.new_feeder(10_000)

  // t = 25_000 us: heartbeat comment + role-only delta -> must NOT start TTFT.
  let c0 =
    ": heartbeat\n\ndata: {\"id\":\"t1\",\"object\":\"chat.completion.chunk\","
    <> "\"created\":1,\"model\":\"m\",\"choices\":[{\"index\":0,"
    <> "\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n"
  let assert Ok(f1) =
    openai.feed_bytes(f0, bit_array.from_string(c0), 25_000, on_event)
  openai.feeder_acc(f1).ttft_us |> should.equal(None)

  // t = 55_000 us: first reasoning delta -> starts TTFT at 55_000 - 10_000 = 45 ms.
  let c1 =
    "data: {\"id\":\"t1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,"
    <> "\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n"
  let assert Ok(f2) =
    openai.feed_bytes(f1, bit_array.from_string(c1), 55_000, on_event)
  openai.feeder_acc(f2).ttft_us |> should.equal(Some(55_000))

  // t = 120_000 us: content delta + finish + [DONE] -> TTFT stays 45 ms.
  let c2 =
    "data: {\"id\":\"t1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,"
    <> "\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\n"
    <> "data: [DONE]\n\n"
  let assert Ok(f3) =
    openai.feed_bytes(f2, bit_array.from_string(c2), 120_000, on_event)

  // Ended at t = 260_000 us -> duration = (260_000 - 10_000) / 1000 = 250 ms.
  let assert Ok(stats) = openai.finish_feeder(f3, 260_000)
  stats.ttft_ms |> should.equal(Some(45))
  stats.duration_ms |> should.equal(250)
  stats.reasoning_deltas |> should.equal(1)
  stats.token_deltas |> should.equal(1)

  // Usage-only + [DONE] stream has ttft_ms = None and exact duration_ms.
  let u_wire =
    "data: {\"id\":\"t2\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,"
    <> "\"completion_tokens\":0,\"total_tokens\":10}}\n\ndata: [DONE]\n\n"
  let u0 = openai.new_feeder(5000)
  let assert Ok(u1) =
    openai.feed_bytes(u0, bit_array.from_string(u_wire), 18_000, fn(_) { Nil })
  let assert Ok(u_stats) = openai.finish_feeder(u1, 45_000)
  u_stats.ttft_ms |> should.equal(None)
  u_stats.duration_ms |> should.equal(40)
}

// ---------------------------------------------------------------------------
// 3. Chunk-boundary invariance property (200 seeded trials)
// ---------------------------------------------------------------------------

type ExpectedCounts {
  ExpectedCounts(
    events_parsed: Int,
    decode_errors: Int,
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
    usage_events: Int,
    saw_done: Bool,
    saw_finish: Bool,
  )
}

fn zero_counts() -> ExpectedCounts {
  ExpectedCounts(
    events_parsed: 0,
    decode_errors: 0,
    token_deltas: 0,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    usage_events: 0,
    saw_done: False,
    saw_finish: False,
  )
}

fn add_counts(a: ExpectedCounts, b: ExpectedCounts) -> ExpectedCounts {
  ExpectedCounts(
    events_parsed: a.events_parsed + b.events_parsed,
    decode_errors: a.decode_errors + b.decode_errors,
    token_deltas: a.token_deltas + b.token_deltas,
    reasoning_deltas: a.reasoning_deltas + b.reasoning_deltas,
    tool_call_deltas: a.tool_call_deltas + b.tool_call_deltas,
    usage_events: a.usage_events + b.usage_events,
    saw_done: a.saw_done || b.saw_done,
    saw_finish: a.saw_finish || b.saw_finish,
  )
}

fn gen_text_fragment(rng: prop.Rng) -> #(String, prop.Rng) {
  prop.one_of(rng, "hello ", [
    "world!",
    "café naïve résumé",
    "日本語テスト",
    "检查天气 “Tokyo”",
    "🚀🌤️✅",
    "line1\\nline2",
    "   ",
    "\\t\\n",
    "quote: \\\"hi\\\"",
    "<script>alert(1)</script>",
    "€100 — ½ price",
  ])
}

fn gen_newline(rng: prop.Rng) -> #(String, prop.Rng) {
  prop.one_of(rng, "\n", ["\r\n", "\r"])
}

fn gen_data_prefix(rng: prop.Rng) -> #(String, prop.Rng) {
  prop.one_of(rng, "data: ", ["data:"])
}

fn gen_valid_chunk_frame(
  rng: prop.Rng,
) -> #(#(String, ExpectedCounts), prop.Rng) {
  let #(kind, rng) = prop.int_range(rng, 0, 7)
  let #(nl, rng) = gen_newline(rng)
  let #(prefix, rng) = gen_data_prefix(rng)
  case kind {
    0 -> {
      // SSE comment / keepalive
      let #(note, rng) =
        prop.one_of(rng, ": heartbeat", [
          ": OPENROUTER PROCESSING",
          ": ping 🚀",
          ":",
        ])
      #(#(note <> nl <> nl, zero_counts()), rng)
    }
    1 -> {
      // Role-only chunk (empty content emits no TokenDelta)
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":"
        <> "{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1),
        ),
        rng,
      )
    }
    2 -> {
      // Reasoning delta (vLLM reasoning_content or OpenRouter reasoning)
      let #(field, rng) = prop.one_of(rng, "reasoning_content", ["reasoning"])
      let #(text, rng) = gen_text_fragment(rng)
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{"
        <> json.to_string(json.string(field))
        <> ":"
        <> json.to_string(json.string(text))
        <> "},\"finish_reason\":null}]}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1, reasoning_deltas: 1),
        ),
        rng,
      )
    }
    3 | 4 -> {
      // Content delta
      let #(text, rng) = gen_text_fragment(rng)
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":"
        <> json.to_string(json.string(text))
        <> "},\"finish_reason\":null}]}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1, token_deltas: 1),
        ),
        rng,
      )
    }
    5 -> {
      // Tool call delta
      let #(idx, rng) = prop.int_range(rng, 0, 2)
      let #(with_id, rng) = prop.bool(rng)
      let #(with_name, rng) = prop.bool(rng)
      let #(args, rng) =
        prop.one_of(rng, "{\"q\":", ["\"東京\"}", "{ \"x\" : 1 }", ""])
      let id_part = case with_id {
        True -> ",\"id\":\"call_" <> int.to_string(idx) <> "\""
        False -> ""
      }
      let name_part = case with_name {
        True -> "\"name\":\"web_search\","
        False -> ""
      }
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{"
        <> "\"index\":"
        <> int.to_string(idx)
        <> id_part
        <> ",\"type\":\"function\",\"function\":{"
        <> name_part
        <> "\"arguments\":"
        <> json.to_string(json.string(args))
        <> "}}]},\"finish_reason\":null}]}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1, tool_call_deltas: 1),
        ),
        rng,
      )
    }
    6 -> {
      // Reasoning + content in the same chunk (reasoning must precede content)
      let #(r_text, rng) = gen_text_fragment(rng)
      let #(c_text, rng) = gen_text_fragment(rng)
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{"
        <> "\"reasoning_content\":"
        <> json.to_string(json.string(r_text))
        <> ",\"content\":"
        <> json.to_string(json.string(c_text))
        <> "},\"finish_reason\":null}]}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(
            ..zero_counts(),
            events_parsed: 1,
            token_deltas: 1,
            reasoning_deltas: 1,
          ),
        ),
        rng,
      )
    }
    _ -> {
      // Usage chunk with empty choices
      let #(prompt_toks, rng) = prop.int_range(rng, 10, 2000)
      let #(cached_toks, rng) = prop.int_range(rng, 0, prompt_toks)
      let #(comp_toks, rng) = prop.int_range(rng, 1, 200)
      let payload =
        "{\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
        <> "\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":"
        <> int.to_string(prompt_toks)
        <> ",\"completion_tokens\":"
        <> int.to_string(comp_toks)
        <> ",\"total_tokens\":"
        <> int.to_string(prompt_toks + comp_toks)
        <> ",\"prompt_tokens_details\":{\"cached_tokens\":"
        <> int.to_string(cached_toks)
        <> "}}}"
      #(
        #(
          prefix <> payload <> nl <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1, usage_events: 1),
        ),
        rng,
      )
    }
  }
}

fn gen_valid_sse_stream(
  rng: prop.Rng,
) -> #(BitArray, ExpectedCounts, prop.Rng) {
  let #(frames, rng) = prop.list_of(rng, 1, 10, gen_valid_chunk_frame)
  let #(finish_reason, rng) = prop.one_of(rng, "stop", ["tool_calls", "length"])
  let #(nl1, rng) = gen_newline(rng)
  let #(nl2, rng) = gen_newline(rng)
  let #(include_done, rng) = prop.bool(rng)
  let finish_frame =
    "data: {\"id\":\"p1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
    <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":"
    <> json.to_string(json.string(finish_reason))
    <> "}]}"
    <> nl1
    <> nl1
  let done_frame = case include_done {
    True -> "data: [DONE]" <> nl2 <> nl2
    False -> ""
  }
  let body_wire = frames |> list.map(fn(f) { f.0 }) |> string.concat
  let body_counts =
    list.fold(frames, zero_counts(), fn(acc, f) { add_counts(acc, f.1) })
  let expected =
    add_counts(
      body_counts,
      ExpectedCounts(
        ..zero_counts(),
        events_parsed: 1,
        saw_done: include_done,
        saw_finish: True,
      ),
    )
  let wire = body_wire <> finish_frame <> done_frame
  #(bit_array.from_string(wire), expected, rng)
}

pub fn chunk_boundary_invariance_property_test() {
  prop.forall(
    "sse_chunk_boundary_invariance",
    0x3A_55E_001,
    200,
    fn(rng, trial) {
      let #(raw, expected, rng) = gen_valid_sse_stream(rng)
      let reference = replay_chunks([raw], 1000, 1000)

      // First verify the whole-chunk reference against generator-known oracle
      // expectations so parser regressions cannot pass via self-consistency.
      case reference.outcome {
        Error(err) ->
          Error(
            "valid stream failed whole-chunk parse: " <> string.inspect(err),
          )
        Ok(stats) ->
          case check_stats_against_expected(reference.events, stats, expected) {
            Error(msg) -> Error("oracle mismatch: " <> msg)
            Ok(Nil) -> {
              // Tiny random splits (1..7 bytes, with occasional empty chunks) so
              // splits routinely land inside multi-byte UTF-8 and \r\n\r\n.
              let #(tiny_splits, rng) =
                prop.bit_array_splits(rng, raw, 1, 7, True)
              let tiny_res = replay_chunks(tiny_splits, 1000, 1000)

              // Medium random splits (1..64 bytes).
              let #(med_splits, _rng) =
                prop.bit_array_splits(rng, raw, 1, 64, True)
              let med_res = replay_chunks(med_splits, 1000, 1000)

              case compare_timing_independent(reference, tiny_res) {
                Error(msg) -> Error("tiny splits: " <> msg)
                Ok(Nil) ->
                  case compare_timing_independent(reference, med_res) {
                    Error(msg) -> Error("medium splits: " <> msg)
                    Ok(Nil) ->
                      // Every 5th trial (40 streams) also runs exhaustive 1-byte chunks.
                      case trial % 5 == 0 {
                        False -> Ok(Nil)
                        True -> {
                          let byte_res =
                            replay_chunks(
                              prop.single_byte_chunks(raw),
                              1000,
                              1000,
                            )
                          compare_timing_independent(reference, byte_res)
                        }
                      }
                  }
              }
            }
          }
      }
    },
  )
}

// ---------------------------------------------------------------------------
// 4. Hostile & malformed stream property (200 seeded trials)
// ---------------------------------------------------------------------------

fn gen_hostile_frame(rng: prop.Rng) -> #(#(String, ExpectedCounts), prop.Rng) {
  let #(kind, rng) = prop.int_range(rng, 0, 10)
  let #(nl, rng) = gen_newline(rng)
  case kind {
    0 -> #(
      #(
        "data: {not valid json at all" <> nl <> nl,
        ExpectedCounts(..zero_counts(), decode_errors: 1),
      ),
      rng,
    )
    1 -> #(#("data: " <> nl <> nl, zero_counts()), rng)
    2 -> #(
      #(
        "data: 12345" <> nl <> nl,
        ExpectedCounts(..zero_counts(), decode_errors: 1),
      ),
      rng,
    )
    3 -> #(
      #(
        "data: {\"partial\":true}" <> nl <> nl,
        ExpectedCounts(..zero_counts(), decode_errors: 1),
      ),
      rng,
    )
    4 -> #(
      #(
        // Duplicate tool call IDs and missing IDs/function fields
        "data: {\"id\":\"h1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
          <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":["
          <> "{\"index\":0,\"id\":\"dup\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\"}},"
          <> "{\"index\":0,\"id\":\"dup\",\"function\":{\"arguments\":\"}\"}},"
          <> "{\"index\":1,\"function\":null}"
          <> "]}}]}"
          <> nl
          <> nl,
        ExpectedCounts(..zero_counts(), events_parsed: 1, tool_call_deltas: 3),
      ),
      rng,
    )
    5 -> #(
      #(
        // Reasoning-only chunk (no content)
        "data: {\"id\":\"h1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
          <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{"
          <> "\"reasoning_content\":\"only thinking 🧠\"}}]}"
          <> nl
          <> nl,
        ExpectedCounts(..zero_counts(), events_parsed: 1, reasoning_deltas: 1),
      ),
      rng,
    )
    6 -> #(
      #(
        // Whitespace-only content alongside a tool call
        "data: {\"id\":\"h1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
          <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\n\\n  \","
          <> "\"tool_calls\":[{\"index\":0,\"id\":\"c_ws\",\"function\":{\"name\":\"list_dir\",\"arguments\":\"{}\"}}]}}]}"
          <> nl
          <> nl,
        ExpectedCounts(
          ..zero_counts(),
          events_parsed: 1,
          token_deltas: 1,
          tool_call_deltas: 1,
        ),
      ),
      rng,
    )
    7 -> {
      // Out-of-order / repeated usage chunks
      let #(p, rng) = prop.int_range(rng, 1, 500)
      let #(c, rng) = prop.int_range(rng, 0, 100)
      #(
        #(
          "data: {\"id\":\"h1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
            <> "\"model\":\"m\",\"choices\":[],\"usage\":{\"prompt_tokens\":"
            <> int.to_string(p)
            <> ",\"completion_tokens\":"
            <> int.to_string(c)
            <> ",\"total_tokens\":"
            <> int.to_string(p + c)
            <> "}}"
            <> nl
            <> nl,
          ExpectedCounts(..zero_counts(), events_parsed: 1, usage_events: 1),
        ),
        rng,
      )
    }
    8 -> #(
      #(
        // Multi-line data payload (valid JSON split across two data: lines)
        "data: {\"id\":\"h1\",\"object\":\"chat.completion.chunk\",\n"
          <> "data: \"created\":1,\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"multi\"}}]}"
          <> nl
          <> nl,
        ExpectedCounts(..zero_counts(), events_parsed: 1, token_deltas: 1),
      ),
      rng,
    )
    9 -> #(#("event: error\nid: 99\nretry: 500\n\n", zero_counts()), rng)
    _ -> #(
      #(
        "data: [DONE]" <> nl <> nl,
        ExpectedCounts(..zero_counts(), saw_done: True),
      ),
      rng,
    )
  }
}

fn check_event_counts(
  events: List(openai.StreamEvent),
  expected: ExpectedCounts,
) -> Result(Option(shared.CompletionUsage), String) {
  let token_count =
    list.count(events, fn(ev) {
      case ev {
        openai.TokenDelta(_) -> True
        _ -> False
      }
    })
  let reasoning_count =
    list.count(events, fn(ev) {
      case ev {
        openai.ReasoningDelta(_) -> True
        _ -> False
      }
    })
  let tool_count =
    list.count(events, fn(ev) {
      case ev {
        openai.ToolCallDelta(_, _, _, _) -> True
        _ -> False
      }
    })
  let usage_count =
    list.count(events, fn(ev) {
      case ev {
        openai.Usage(_) -> True
        _ -> False
      }
    })
  let last_usage =
    list.fold(events, None, fn(acc, ev) {
      case ev {
        openai.Usage(u) -> Some(u)
        _ -> acc
      }
    })
  case
    token_count == expected.token_deltas
    && reasoning_count == expected.reasoning_deltas
    && tool_count == expected.tool_call_deltas
    && usage_count == expected.usage_events
  {
    True -> Ok(last_usage)
    False ->
      Error(
        "event counts mismatch: expected="
        <> string.inspect(expected)
        <> " actual_events="
        <> string.inspect(events),
      )
  }
}

fn check_stats_against_expected(
  events: List(openai.StreamEvent),
  stats: openai.StreamStats,
  expected: ExpectedCounts,
) -> Result(Nil, String) {
  case check_event_counts(events, expected) {
    Error(msg) -> Error(msg)
    Ok(last_usage) -> {
      let has_output =
        expected.token_deltas
        + expected.reasoning_deltas
        + expected.tool_call_deltas
        > 0
      let ttft_ok = case stats.ttft_ms {
        Some(ms) -> ms >= 0 && has_output
        None -> !has_output
      }
      case
        stats.events_parsed == expected.events_parsed
        && stats.decode_errors == expected.decode_errors
        && stats.token_deltas == expected.token_deltas
        && stats.reasoning_deltas == expected.reasoning_deltas
        && stats.tool_call_deltas == expected.tool_call_deltas
        && stats.saw_done == expected.saw_done
        && stats.usage == last_usage
        && ttft_ok
      {
        True -> Ok(Nil)
        False ->
          Error(
            "stats mismatch: expected="
            <> string.inspect(expected)
            <> " actual="
            <> string.inspect(stats),
          )
      }
    }
  }
}

pub fn hostile_and_malformed_stream_property_test() {
  prop.forall("sse_hostile_malformed", 0x3A_BAD_002, 200, fn(rng, _trial) {
    let #(frames, rng) = prop.list_of(rng, 0, 12, gen_hostile_frame)
    let #(truncate_tail, rng) = prop.bool(rng)
    let tail = case truncate_tail {
      True -> "data: {\"id\":\"cut_off\""
      False -> ""
    }
    let body_wire = frames |> list.map(fn(f) { f.0 }) |> string.concat
    let expected =
      list.fold(frames, zero_counts(), fn(acc, f) { add_counts(acc, f.1) })
    let raw = bit_array.from_string(body_wire <> tail)
    let reference = replay_chunks([raw], 0, 500)
    let #(splits, _rng) = prop.bit_array_splits(rng, raw, 1, 9, True)
    let chunked = replay_chunks(splits, 0, 500)

    case compare_timing_independent(reference, chunked) {
      Error(msg) -> Error(msg)
      Ok(Nil) ->
        case
          expected.events_parsed == 0 && !expected.saw_done,
          expected.events_parsed > 0
          && !expected.saw_done
          && !expected.saw_finish
        {
          True, _ ->
            case expected.decode_errors > 0, reference.outcome {
              True, Error(openai.Decode(_)) ->
                case check_event_counts(reference.events, expected) {
                  Ok(_) -> Ok(Nil)
                  Error(msg) -> Error(msg)
                }
              False, Error(openai.Transport("stream produced no events")) ->
                case check_event_counts(reference.events, expected) {
                  Ok(_) -> Ok(Nil)
                  Error(msg) -> Error(msg)
                }
              _, actual ->
                Error(
                  "expected Decode/empty Transport error for expected="
                  <> string.inspect(expected)
                  <> " got="
                  <> string.inspect(actual),
                )
            }
          False, True ->
            case reference.outcome {
              Error(openai.Transport(
                "upstream stream closed before completion (missing [DONE] and finish_reason)",
              )) ->
                case check_event_counts(reference.events, expected) {
                  Ok(_) -> Ok(Nil)
                  Error(msg) -> Error(msg)
                }
              actual ->
                Error(
                  "expected truncation Transport error for expected="
                  <> string.inspect(expected)
                  <> " got="
                  <> string.inspect(actual),
                )
            }
          False, False ->
            case reference.outcome {
              Ok(stats) ->
                check_stats_against_expected(reference.events, stats, expected)
              Error(err) ->
                Error(
                  "expected Ok outcome for expected="
                  <> string.inspect(expected)
                  <> " got="
                  <> string.inspect(err),
                )
            }
        }
    }
  })
}

pub fn hostile_specific_accounting_cases_test() {
  // 1. Truncated stream (content delivered, neither [DONE] nor finish_reason) -> Transport error.
  let truncated =
    bit_array.from_string(
      "data: {\"id\":\"x1\",\"object\":\"chat.completion.chunk\",\"created\":1,"
      <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"half\"}}]}\n\n",
    )
  let trunc_res = replay_chunks([truncated], 0, 1000)
  trunc_res.events |> should.equal([openai.TokenDelta("half")])
  let assert Error(openai.Transport(_)) = trunc_res.outcome

  // 2. Garbage JSON only -> Decode error.
  let bad_only = bit_array.from_string("data: {broken\n\n")
  let bad_res = replay_chunks([bad_only], 0, 1000)
  bad_res.events |> should.equal([])
  let assert Error(openai.Decode(_)) = bad_res.outcome

  // 3. Garbage JSON alongside a valid chunk + [DONE] -> succeeds with decode_errors == 1.
  let mixed =
    bit_array.from_string(
      "data: {broken\n\n"
      <> "data: {\"id\":\"x2\",\"object\":\"chat.completion.chunk\",\"created\":1,"
      <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\n\n"
      <> "data: [DONE]\n\n",
    )
  let mixed_res = replay_chunks(prop.single_byte_chunks(mixed), 0, 1000)
  let assert Ok(mixed_stats) = mixed_res.outcome
  mixed_stats.decode_errors |> should.equal(1)
  mixed_stats.events_parsed |> should.equal(1)
  mixed_stats.saw_done |> should.equal(True)

  // 4. Reasoning-only turn with [DONE] -> succeeds with token_deltas == 0, reasoning_deltas == 1.
  let reasoning_only =
    bit_array.from_string(
      "data: {\"id\":\"x3\",\"object\":\"chat.completion.chunk\",\"created\":1,"
      <> "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\n"
      <> "data: [DONE]\n\n",
    )
  let r_res = replay_chunks(prop.single_byte_chunks(reasoning_only), 0, 1000)
  let assert Ok(r_stats) = r_res.outcome
  r_res.events |> should.equal([openai.ReasoningDelta("hmm")])
  r_stats.token_deltas |> should.equal(0)
  r_stats.reasoning_deltas |> should.equal(1)
  r_stats.saw_done |> should.equal(True)
}

// ---------------------------------------------------------------------------
// 5. Recorded dialect fixture replay tests (test/fixtures/wire/*.sse)
// ---------------------------------------------------------------------------

fn assert_fixture_chunk_invariant(
  path: String,
  root_seed: Int,
) -> #(List(openai.StreamEvent), openai.StreamStats) {
  let assert Ok(raw) = simplifile.read_bits(path)
  let whole = replay_chunks([raw], 0, 1000)
  let by_byte = replay_chunks(prop.single_byte_chunks(raw), 0, 1000)
  compare_timing_independent(whole, by_byte) |> should.equal(Ok(Nil))

  prop.forall("fixture_" <> path, root_seed, 25, fn(rng, _trial) {
    let #(splits, _rng) = prop.bit_array_splits(rng, raw, 1, 17, True)
    let split_res = replay_chunks(splits, 0, 1000)
    compare_timing_independent(whole, split_res)
  })

  let assert Ok(stats) = whole.outcome
  stats.decode_errors |> should.equal(0)
  stats.saw_done |> should.equal(True)
  #(whole.events, stats)
}

pub fn dialect_fixture_vllm_reasoning_tools_test() {
  let #(events, stats) =
    assert_fixture_chunk_invariant(
      "test/fixtures/wire/vllm_reasoning_tools.sse",
      0xD1A1EC7_1,
    )
  stats.reasoning_deltas |> should.equal(2)
  stats.tool_call_deltas |> should.equal(3)
  stats.token_deltas |> should.equal(0)
  stats.events_parsed |> should.equal(7)
  let assert Some(usage) = stats.usage
  usage.prompt_tokens |> should.equal(1280)
  usage.prompt_tokens_details
  |> should.equal(
    Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(1152),
    )),
  )
  events
  |> should.equal([
    openai.ReasoningDelta("Thinking: 检查天气 “Tokyo” 🌤️"),
    openai.ReasoningDelta(" and fetching docs."),
    openai.ToolCallDelta(
      index: 0,
      id: Some("call_vllm_0"),
      name: Some("web_search"),
      args_fragment: "{\"query\":",
    ),
    openai.ToolCallDelta(
      index: 0,
      id: None,
      name: None,
      args_fragment: "\"東京 天気\"}",
    ),
    openai.ToolCallDelta(
      index: 1,
      id: Some("call_vllm_1"),
      name: Some("http_fetch"),
      args_fragment: "{\"url\":\"https://example.test/café\"}",
    ),
    openai.Usage(usage),
  ])
}

pub fn dialect_fixture_llamacpp_keyless_test() {
  // Verify keyless request drops empty Authorization header alongside the
  // llama.cpp keyless wire replay.
  let keyless =
    openai.Endpoint(
      base_url: "http://127.0.0.1:8080/v1",
      api_key: None,
      sse_first_response_timeout_ms: 30_000,
      stream_idle_timeout_ms: 120_000,
    )
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer ")
    |> openai.drop_empty_bearer(keyless)
  request.get_header(req, "authorization") |> should.be_error

  let #(events, stats) =
    assert_fixture_chunk_invariant(
      "test/fixtures/wire/llamacpp_keyless.sse",
      0xD1A1EC7_2,
    )
  stats.reasoning_deltas |> should.equal(1)
  stats.token_deltas |> should.equal(2)
  stats.events_parsed |> should.equal(5)
  let assert Some(usage) = stats.usage
  usage.prompt_tokens |> should.equal(512)
  usage.prompt_tokens_details
  |> should.equal(
    Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(480),
    )),
  )
  events
  |> should.equal([
    openai.ReasoningDelta("Let’s verify: naïve café → OK."),
    openai.TokenDelta("こんにちは 🌍"),
    openai.TokenDelta(" — all clear!"),
    openai.Usage(usage),
  ])
}

pub fn dialect_fixture_openai_parallel_tools_test() {
  let #(events, stats) =
    assert_fixture_chunk_invariant(
      "test/fixtures/wire/openai_parallel_tools.sse",
      0xD1A1EC7_3,
    )
  stats.token_deltas |> should.equal(1)
  stats.tool_call_deltas |> should.equal(3)
  stats.reasoning_deltas |> should.equal(0)
  stats.events_parsed |> should.equal(7)
  let assert Some(usage) = stats.usage
  usage.prompt_tokens |> should.equal(2048)
  usage.prompt_tokens_details
  |> should.equal(
    Some(shared.PromptTokensDetails(
      audio_tokens: Some(0),
      cached_tokens: Some(1920),
    )),
  )
  events
  |> should.equal([
    openai.TokenDelta("Checking both sources…"),
    openai.ToolCallDelta(
      index: 0,
      id: Some("call_oai_a"),
      name: Some("read_file"),
      args_fragment: "",
    ),
    openai.ToolCallDelta(
      index: 0,
      id: None,
      name: None,
      args_fragment: "{ \"path\" : \"README.md\" }",
    ),
    openai.ToolCallDelta(
      index: 1,
      id: Some("call_oai_b"),
      name: Some("list_dir"),
      args_fragment: "{\"path\":\"src\"}",
    ),
    openai.Usage(usage),
  ])
}

pub fn dialect_fixture_openrouter_reasoning_test() {
  let #(events, stats) =
    assert_fixture_chunk_invariant(
      "test/fixtures/wire/openrouter_reasoning.sse",
      0xD1A1EC7_4,
    )
  stats.reasoning_deltas |> should.equal(2)
  stats.token_deltas |> should.equal(1)
  stats.events_parsed |> should.equal(5)
  let assert Some(usage) = stats.usage
  usage.prompt_tokens |> should.equal(900)
  usage.prompt_tokens_details
  |> should.equal(
    Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(768),
    )),
  )
  events
  |> should.equal([
    openai.ReasoningDelta("Step 1: parse “quoted” input"),
    openai.ReasoningDelta(" → done ✨"),
    openai.TokenDelta("Result: 日本語テスト ✅"),
    openai.Usage(usage),
  ])
}
