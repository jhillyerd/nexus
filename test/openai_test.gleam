//// Offline tests for the seam's stream-chunk fold (`nexus/openai.handle_chunk`)
//// — no network involved.
////
//// The usage-forwarding case is the regression guard for the PR #3 review
//// finding: `chunk.usage` was silently dropped (the `Usage` event was
//// declared but never emitted), which would have lost the audit tool's
//// cached_tokens evidence.

import gleam/http/request
import gleam/option.{type Option, None, Some}
import gleeunit/should
import glopenai/chat
import glopenai/shared
import nexus/openai

fn stream_chunk(
  content content: Option(String),
  usage usage: Option(shared.CompletionUsage),
) -> chat.CreateChatCompletionStreamResponse {
  chat.CreateChatCompletionStreamResponse(
    id: "chatcmpl-test",
    object: "chat.completion.chunk",
    created: 0,
    model: "test-model",
    choices: [
      chat.ChatChoiceStream(
        index: 0,
        delta: chat.ChatCompletionStreamDelta(
          role: None,
          content: content,
          refusal: None,
          tool_calls: None,
        ),
        finish_reason: None,
      ),
    ],
    usage: usage,
    service_tier: None,
    system_fingerprint: None,
  )
}

fn acc() -> openai.Acc {
  openai.Acc(
    started_us: 0,
    ttft_us: None,
    token_deltas: 0,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 0,
    decode_errors: 0,
    saw_done: False,
    first_decode_error: None,
    usage: None,
  )
}

fn keyless_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "http://dgx.test/v1",
    api_key: None,
    sse_first_response_timeout_ms: 30_000,
    stream_idle_timeout_ms: 120_000,
  )
}

fn keyed_endpoint() -> openai.Endpoint {
  openai.Endpoint(..keyless_endpoint(), api_key: Some("sk-test"))
}

pub fn drop_empty_bearer_removes_header_for_keyless_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer ")
    |> request.set_header("content-type", "application/json")
    |> openai.drop_empty_bearer(keyless_endpoint())
  request.get_header(req, "authorization") |> should.be_error
  request.get_header(req, "content-type")
  |> should.equal(Ok("application/json"))
}

pub fn drop_empty_bearer_keeps_header_with_key_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer sk-test")
    |> openai.drop_empty_bearer(keyed_endpoint())
  request.get_header(req, "authorization")
  |> should.equal(Ok("Bearer sk-test"))
}

fn usage_with(cached cached: Int) -> shared.CompletionUsage {
  shared.CompletionUsage(
    prompt_tokens: 100,
    completion_tokens: 5,
    total_tokens: 105,
    prompt_tokens_details: Some(shared.PromptTokensDetails(
      audio_tokens: None,
      cached_tokens: Some(cached),
    )),
    completion_tokens_details: None,
  )
}

pub fn content_delta_accounting_test() {
  let out =
    openai.handle_chunk(
      stream_chunk(content: Some("hi"), usage: None),
      7,
      acc(),
      fn(_) { Nil },
    )
  out.token_deltas |> should.equal(1)
  out.ttft_us |> should.equal(Some(7))
  out.events_parsed |> should.equal(1)
  out.usage |> should.equal(None)
}

pub fn usage_is_forwarded_not_dropped_test() {
  let usage = usage_with(cached: 42)
  let out =
    openai.handle_chunk(
      stream_chunk(content: None, usage: Some(usage)),
      9,
      acc(),
      fn(_) { Nil },
    )
  // The accumulator (and thus StreamStats) must carry the usage block —
  // this is the audit tool's secondary cache-hit signal.
  out.usage |> should.equal(Some(usage))
  out.events_parsed |> should.equal(1)
  out.token_deltas |> should.equal(0)
  out.ttft_us |> should.equal(None)
}

pub fn later_usage_chunk_replaces_earlier_test() {
  let first = usage_with(cached: 42)
  let acc1 =
    openai.handle_chunk(
      stream_chunk(content: Some("a"), usage: Some(first)),
      10,
      acc(),
      fn(_) { Nil },
    )
  let second = usage_with(cached: 90)
  let acc2 =
    openai.handle_chunk(
      stream_chunk(content: None, usage: Some(second)),
      20,
      acc1,
      fn(_) { Nil },
    )
  acc2.usage |> should.equal(Some(second))
  acc2.token_deltas |> should.equal(1)
  acc2.events_parsed |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Reasoning deltas (chain of thought)
// ---------------------------------------------------------------------------

import gleam/erlang/process
import gleam/list

/// Run one SSE data payload through `handle_data`, returning the stats
/// accumulator and every event forwarded to the callback.
fn fold_data(data: String) -> #(openai.Acc, List(openai.StreamEvent)) {
  let events = process.new_subject()
  let acc =
    openai.handle_data(data, 5, acc(), fn(event) { process.send(events, event) })
  #(acc, drain(events, []))
}

fn drain(
  events: process.Subject(openai.StreamEvent),
  acc: List(openai.StreamEvent),
) -> List(openai.StreamEvent) {
  case process.receive(events, 50) {
    Ok(event) -> drain(events, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn chunk_json(delta_fields: String) -> String {
  "{\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":0,"
  <> "\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":"
  <> delta_fields
  <> "}]}"
}

pub fn reasoning_content_delta_is_forwarded_test() {
  let #(acc, events) =
    fold_data(chunk_json(
      "{\"role\":\"assistant\",\"reasoning_content\":\"step one\"}",
    ))
  events
  |> should.equal([openai.ReasoningDelta("step one")])
  acc.reasoning_deltas |> should.equal(1)
  // Reasoning is model output: it starts the TTFT clock.
  acc.ttft_us |> should.equal(Some(5))
  acc.events_parsed |> should.equal(1)
}

pub fn openrouter_reasoning_shape_is_forwarded_test() {
  let #(_, events) = fold_data(chunk_json("{\"reasoning\":\"step two\"}"))
  events |> should.equal([openai.ReasoningDelta("step two")])
}

pub fn plain_chunk_emits_no_reasoning_test() {
  let #(acc, events) = fold_data(chunk_json("{\"content\":\"hello\"}"))
  events |> should.equal([openai.TokenDelta("hello")])
  acc.reasoning_deltas |> should.equal(0)
}

pub fn empty_reasoning_field_is_skipped_test() {
  let #(acc, events) = fold_data(chunk_json("{\"reasoning_content\":\"\"}"))
  events |> should.equal([])
  acc.reasoning_deltas |> should.equal(0)
}

pub fn done_sentinel_has_no_reasoning_test() {
  let #(acc, events) = fold_data("[DONE]")
  events |> should.equal([])
  acc.saw_done |> should.equal(True)
  acc.reasoning_deltas |> should.equal(0)
}
