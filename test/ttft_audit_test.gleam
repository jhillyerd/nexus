import audit/config
import audit/ttft
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import glopenai/shared
import nexus/openai
import nexus/transcript

pub fn deterministic_transcript_test() {
  let body =
    ttft.system_prompt(123)
    |> transcript.new("test-model", _)
    |> transcript.append_user(ttft.user_prompt(1))
    |> transcript.request_body(transcript.default_options())
  should.be_true(string.contains(body, "Session nonce: 123"))
  should.be_true(string.contains(body, "Cache audit turn"))
}

pub fn summarize_cold_and_warm_test() {
  let metrics =
    ttft.summarize([
      turn(1, 1, 100, None),
      turn(1, 10, 20, usage(75)),
      turn(1, 11, 40, usage(90)),
      turn(2, 1, 200, usage(0)),
      turn(2, 10, 30, usage(120)),
    ])
    |> result.unwrap(ttft.Metrics(0.0, 0.0, 0.0, False))
  should.equal(metrics.cold_median_ms, 150.0)
  should.equal(metrics.warm_median_ms, 30.0)
  should.equal(metrics.ratio, 0.2)
  should.be_true(metrics.passed)
}

pub fn csv_row_test() {
  should.equal(
    ttft.csv_header(),
    "session,turn,ttft_ms,duration_ms,token_deltas,events_parsed,prompt_tokens,cached_tokens,prompt_tokens_estimated,tokens_per_second",
  )
  should.equal(
    ttft.csv_row(turn(1, 10, 20, usage(75))),
    "1,10,20,100,4,8,100,75,100,40.0",
  )
}

pub fn validity_rejects_incomplete_streams_test() {
  let cfg =
    config.AuditConfig(
      base_url: "http://bifrost.test/v1",
      api_key: Some("sk-test"),
      model: "test-model",
      turns: 20,
      repeats: 1,
      sse_first_response_timeout_ms: 30_000,
      stream_idle_timeout_ms: 120_000,
    )
  should.be_false(ttft.valid_results(cfg, [turn(1, 1, 100, usage(0))]))
}

fn turn(
  session: Int,
  turn_number: Int,
  ttft_ms: Int,
  usage: option.Option(shared.CompletionUsage),
) -> ttft.TurnResult {
  ttft.TurnResult(
    session: session,
    turn: turn_number,
    prompt_chars: 400,
    stats: openai.StreamStats(
      ttft_ms: Some(ttft_ms),
      duration_ms: 100,
      token_deltas: 4,
      reasoning_deltas: 0,
      tool_call_deltas: 0,
      events_parsed: 8,
      decode_errors: 0,
      saw_done: True,
      usage: usage,
    ),
  )
}

fn usage(cached: Int) -> option.Option(shared.CompletionUsage) {
  Some(shared.CompletionUsage(
    prompt_tokens: 100,
    completion_tokens: 4,
    total_tokens: 104,
    prompt_tokens_details: Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(cached),
    )),
    completion_tokens_details: None,
  ))
}
