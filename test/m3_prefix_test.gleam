//// The M3 production-cache golden prefix test (workstream C).
////
//// The integration smoke archives a REAL multi-turn tool session (live
//// Bifrost + llama.cpp + SearxNG — see `e2e/integration.spec.mjs`) as
//// `test/fixtures/m3_cache_session.json`: the exact system prompt (with
//// its cache nonce), user texts, assistant tool-call ids/names/arguments,
//// tool results, and final answers.
////
//// This test rebuilds that transcript turn-by-turn through the SAME
//// append-only `nexus/transcript` path the agent loop uses and asserts the
//// KV-cache contract on the real data:
////
////   1. determinism — re-encoding an unchanged transcript is byte-equal;
////   2. byte-identical prefixes — every turn's request body embeds the
////      previous turn's message array verbatim (suffix-only growth, with
////      the envelope after the messages array unchanged).
////
//// That is exactly what the upstream engine needs for prefix cache hits,
//// and the smoke's live measurements (warm/cold TTFT ratio, cached token
//// counts) confirm the hits happen end-to-end.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor

import gleam/string
import gleeunit/should
import glopenai/chat
import glopenai/config as oai_config
import nexus/config.{type Config}
import nexus/loop
import nexus/openai
import nexus/session
import nexus/session_registry
import nexus/tools
import nexus/transcript.{type Options, type Transcript}
import store_mock

@external(erlang, "nexus_loop_test_ffi", "read_file")
fn read_file(path: String) -> BitArray

const fixture_path = "test/fixtures/m3_cache_session.json"

// ---------------------------------------------------------------------------
// Fixture decoding
// ---------------------------------------------------------------------------

type FixtureMsg {
  FxUser(content: String)
  FxAssistant(content: String)
  FxToolCall(id: String, name: String, arguments: String)
  FxToolResult(tool_call_id: String, content: String)
}

type FixtureTurn {
  FixtureTurn(messages: List(FixtureMsg))
}

type Fixture {
  Fixture(alias: String, system: String, turns: List(FixtureTurn))
}

fn fixture_msg_decoder() -> decode.Decoder(FixtureMsg) {
  use role <- decode.field("role", decode.string)
  case role {
    "user" -> {
      use content <- decode.field("content", decode.string)
      decode.success(FxUser(content))
    }
    "assistant" -> {
      use content <- decode.field("content", decode.string)
      decode.success(FxAssistant(content))
    }
    "assistant_tool_call" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", decode.string)
      decode.success(FxToolCall(id, name, arguments))
    }
    "tool" -> {
      use tool_call_id <- decode.field("tool_call_id", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(FxToolResult(tool_call_id, content))
    }
    // Unknown roles (never present in the capture) fail loudly.
    other -> decode.failure(FxUser(""), "fixture message with role " <> other)
  }
}

fn fixture_decoder() -> decode.Decoder(Fixture) {
  use alias <- decode.field("alias", decode.string)
  use system <- decode.field("system", decode.string)
  use turns <- decode.field(
    "turns",
    decode.list({
      use messages <- decode.field(
        "messages",
        decode.list(fixture_msg_decoder()),
      )
      decode.success(FixtureTurn(messages))
    }),
  )
  decode.success(Fixture(alias:, system:, turns:))
}

fn load_fixture() -> Fixture {
  let assert Ok(raw) = read_file(fixture_path) |> bit_array.to_string
  let assert Ok(fixture) = json.parse(raw, fixture_decoder())
  fixture
}

// ---------------------------------------------------------------------------
// Transcript reconstruction (mirrors the agent loop's append order)
// ---------------------------------------------------------------------------

/// Apply one captured turn to the transcript exactly like `nexus/loop`:
/// the user message, then — per model iteration — one assistant message
/// carrying that iteration's text and tool calls, then each tool result,
/// then the final assistant answer.
fn apply_turn(tr: Transcript, messages: List(FixtureMsg)) -> Transcript {
  let tr = case messages {
    [FxUser(text), ..rest] ->
      apply_iteration(transcript.append_user(tr, text), rest, "", [])
    _ -> tr
  }
  tr
}

/// Fold a turn's post-user messages, buffering consecutive assistant text
/// and tool calls into a single assistant message (the loop appends one
/// assistant message per iteration, with its text and calls together).
fn apply_iteration(
  tr: Transcript,
  rest: List(FixtureMsg),
  text: String,
  calls: List(#(String, String, String)),
) -> Transcript {
  case rest {
    [] -> flush_assistant(tr, text, calls)
    [FxAssistant(more), ..next] ->
      apply_iteration(tr, next, text <> more, calls)
    [FxToolCall(id, name, arguments), ..next] ->
      apply_iteration(tr, next, text, [#(id, name, arguments), ..calls])
    [FxToolResult(tool_call_id, content), ..next] -> {
      let tr = flush_assistant(tr, text, calls)
      apply_iteration(
        transcript.append_tool_result(tr, tool_call_id, content),
        next,
        "",
        [],
      )
    }
    [FxUser(_), ..] -> tr
  }
}

fn flush_assistant(
  tr: Transcript,
  text: String,
  calls: List(#(String, String, String)),
) -> Transcript {
  case string.trim(text), list.reverse(calls) {
    "", [] -> tr
    "", calls ->
      transcript.append_assistant_tool_calls(
        tr,
        text: None,
        calls: calls,
        reasoning: None,
      )
    text, [] -> transcript.append_assistant(tr, text)
    text, calls ->
      transcript.append_assistant_tool_calls(
        tr,
        text: Some(text),
        calls: calls,
        reasoning: None,
      )
  }
}

// ---------------------------------------------------------------------------
// Options mirroring the loop
// ---------------------------------------------------------------------------

fn smoke_config() -> Config {
  let assert Ok(base) =
    config.from_env(fn(name) {
      case name {
        "NEXUS_ENCRYPTION_KEY" ->
          Ok("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
        _ -> Error(Nil)
      }
    })
  // The smoke server ran with SearxNG configured, so the registry froze
  // [http_fetch, web_search] — same order, same schemas, as production.
  config.Config(..base, searxng_base_url: Some("https://searx.example"))
}

fn loop_options() -> Options {
  transcript.Options(
    ..transcript.default_options(),
    stream: True,
    tools: tools.default(smoke_config()) |> tools.schemas,
    tool_choice: Some(chat.ToolChoiceModeChoice(chat.ToolChoiceAuto)),
  )
}

// ---------------------------------------------------------------------------
// The contract, on real captured data
// ---------------------------------------------------------------------------

/// Split a serialized body at the messages/stream boundary: the messages
/// array must grow by suffix only, and the envelope after it must stay
/// byte-identical (model, stream, tools, tool_choice — tools frozen at
/// boot).
fn body_parts(body: String) -> #(String, String) {
  case string.split(body, on: ",\"stream\"") {
    [messages, envelope] -> #(messages, ",\"stream\"" <> envelope)
    _ -> panic as "request body has no stream marker"
  }
}

fn extends(prev: String, next: String) -> Bool {
  let #(prev_messages, prev_envelope) = body_parts(prev)
  let #(next_messages, next_envelope) = body_parts(next)
  // Appending messages inserts before the messages array's closing `]`,
  // so drop that one byte before the prefix comparison.
  string.starts_with(next_messages, string.drop_end(prev_messages, 1))
  && prev_envelope == next_envelope
}

pub fn golden_real_session_deterministic_encode_test() {
  let fixture = load_fixture()
  let opts = loop_options()
  let tr =
    list.fold(
      fixture.turns,
      transcript.new(fixture.alias, fixture.system),
      fn(tr, turn) { apply_turn(tr, turn.messages) },
    )
  transcript.request_body(tr, opts)
  should.equal(
    transcript.request_body(tr, opts),
    transcript.request_body(tr, opts),
  )
}

pub fn golden_real_session_turn_by_turn_test() {
  let fixture = load_fixture()
  let opts = loop_options()
  // Bodies at each turn boundary, oldest first.
  let bodies =
    list.fold(fixture.turns, [], fn(bodies, turn) {
      let tr = case bodies {
        [] -> transcript.new(fixture.alias, fixture.system)
        [#(tr, _), ..] -> tr
      }
      let tr = apply_turn(tr, turn.messages)
      [#(tr, transcript.request_body(tr, opts)), ..bodies]
    })
    |> list.reverse
    |> list.map(fn(entry) { entry.1 })
  should.be_true(list.length(bodies) >= 4)
  list.each(list.zip(list.drop(bodies, 1), bodies), fn(pair) {
    let #(next, prev) = pair
    should.be_true(extends(prev, next))
  })
  // The tool schema is frozen: every body carries the same envelope.
  let envelopes =
    bodies
    |> list.map(fn(body) { body_parts(body).1 })
    |> list.unique
  should.equal(list.length(envelopes), 1)
}

// ---------------------------------------------------------------------------
// M3 session organization vs. the cache contract
// ---------------------------------------------------------------------------

/// The registry holds organizational metadata (title, pin, tags, archive)
/// BESIDE the transcript. This drives the real registry through every
/// metadata mutation and asserts the encoded request body — built through
/// the single `nexus/transcript` path — does not change by a single byte,
/// and that no metadata marker ever leaks into a body.
pub fn golden_metadata_never_alters_request_bytes_test() {
  let fixture = load_fixture()
  let opts = loop_options()
  let registry = start_registry()
  let assert Ok(record) =
    session_registry.create_with_runner(
      registry,
      store_mock.fixture_provider_id,
      fixture.alias,
      happy_runner,
    )

  // The first user message, exactly like the HTTP send boundary: auto-title
  // from its text (never an LLM call, never into the body).
  should.equal(
    session.send_message(record.subject, "ZZ-FIRST-MSG-ZZ"),
    session.Sent,
  )
  drain_turn(record.subject)
  should.be_true(session_registry.auto_title(registry, record.id, "ZZ-TITLE-ZZ"))

  let body_before =
    transcript.request_body(session.snapshot(record.subject), opts)

  // Mutate every organizational field.
  should.be_true(session_registry.set_title(
    registry,
    record.id,
    "ZZ-MANUAL-TITLE-ZZ",
  ))
  should.be_true(
    session_registry.set_tags(registry, record.id, ["ZZ-TAG-ZZ", "ZZ-TAG2-ZZ"]),
  )
  should.be_true(session_registry.set_pinned(registry, record.id, True))
  should.be_true(session_registry.set_archived(registry, record.id, True))

  // Byte-identical re-encode after the metadata churn.
  let body_after =
    transcript.request_body(session.snapshot(record.subject), opts)
  should.equal(body_after, body_before)

  // No metadata marker (or metadata key name) appears in the body.
  list.each(
    [
      "ZZ-TITLE-ZZ",
      "ZZ-MANUAL-TITLE-ZZ",
      "ZZ-TAG-ZZ",
      "ZZ-TAG2-ZZ",
      "title_source",
      "pinned",
      "archived",
      "created_at",
      "last_active",
    ],
    fn(marker) { should.be_false(string.contains(body_before, marker)) },
  )

  // And a follow-up turn still grows the body by suffix only.
  let tr2 =
    session.snapshot(record.subject)
    |> transcript.append_user("ZZ-SECOND-MSG-ZZ")
  should.be_true(extends(body_before, transcript.request_body(tr2, opts)))
}

fn start_registry() -> process.Subject(session_registry.Msg) {
  let factory_name = process.new_name("nexus_m3_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(session_registry.factory_builder(factory_name))
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  let assert Ok(started) =
    session_registry.start(
      smoke_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_m3_registry"),
      persistence,
      fixture_resolver(),
    )
  started.data
}

/// The offline stand-in for the boot resolver: the fixture provider
/// resolves to a fixed endpoint, anything else is unknown.
fn fixture_resolver() -> session_registry.ResolveProvider {
  fn(id) {
    case id == store_mock.fixture_provider_id {
      True -> Ok(test_endpoint())
      False -> Error(session_registry.ProviderUnknown)
    }
  }
}

/// The endpoint shape the smoke session streams through. The base URL and
/// key material never enter the request body — see the key-invariance
/// golden test at the bottom of this suite.
fn test_endpoint() -> openai.Endpoint {
  openai.Endpoint(
    base_url: "https://bifrost.example/v1",
    api_key: Some("sk-smoke"),
    sse_first_response_timeout_ms: 30_000,
    stream_idle_timeout_ms: 120_000,
  )
}

/// The same endpoint with a DIFFERENT key — used by the key-invariance
/// golden test (plan §9).
fn rekeyed_endpoint() -> openai.Endpoint {
  openai.Endpoint(..test_endpoint(), api_key: Some("sk-other"))
}

fn happy_runner(
  _endpoint,
  tr,
  _cancel,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> session.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("hi")))
  session.StreamDone(fake_stats(), transcript.append_assistant(tr, "hi"))
}

fn fake_stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(1),
    duration_ms: 2,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 1,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Subscribe and wait for the fake runner's terminal event, so the turn's
/// commits have landed before the snapshot.
fn drain_turn(subject: process.Subject(session.Msg)) -> Nil {
  let sub = process.new_subject()
  process.send(subject, session.Join(sub))
  let _ = process.receive(sub, 2000)
  // hello + user echo + assistant full + turn done
  let _ = drain(sub, 4)
  Nil
}

fn drain(
  sub: process.Subject(session.SessionEvent),
  n: Int,
) -> List(session.SessionEvent) {
  case n {
    0 -> []
    _ ->
      case process.receive(sub, 2000) {
        Ok(event) -> [event, ..drain(sub, n - 1)]
        Error(_) -> []
      }
  }
}

// ---------------------------------------------------------------------------
// Multi-provider §9: credentials never touch the request body
// ---------------------------------------------------------------------------

/// Switching a provider's KEY (same base URL, same model) must leave
/// request BODIES byte-identical — credentials appear only in the
/// `Authorization` header, and are omitted entirely for keyless
/// endpoints (`openai.drop_empty_bearer`). This is the multi-provider
/// twin of the prefix goldens: re-keying a provider must not invalidate
/// any session's cache prefix.
pub fn golden_key_change_never_alters_request_bytes_test() {
  let fixture = load_fixture()
  let opts = loop_options()
  let tr =
    list.fold(
      fixture.turns,
      transcript.new(fixture.alias, fixture.system),
      fn(tr, turn) { apply_turn(tr, turn.messages) },
    )
  let params = transcript.to_request(tr, opts)

  // The wire request exactly as `nexus/openai` builds it: glopenai
  // config from the endpoint, then `chat.create_request`.
  let wire = fn(endpoint: openai.Endpoint) {
    let cfg =
      oai_config.new(option.unwrap(endpoint.api_key, ""))
      |> oai_config.with_api_base(endpoint.base_url)
    chat.create_request(cfg, params)
  }
  let keyed = wire(test_endpoint())
  let rekeyed = wire(rekeyed_endpoint())
  let keyless_endpoint = openai.Endpoint(..test_endpoint(), api_key: None)
  let keyless_raw = wire(keyless_endpoint)

  // Bodies identical across all three key worlds — and equal to the
  // pure transcript body (the single encode path).
  keyed.body |> should.equal(rekeyed.body)
  keyed.body |> should.equal(keyless_raw.body)
  keyed.body |> should.equal(transcript.request_body(tr, opts))

  // The difference lives in the Authorization header ONLY.
  request.get_header(keyed, "authorization")
  |> should.equal(Ok("Bearer sk-smoke"))
  request.get_header(rekeyed, "authorization")
  |> should.equal(Ok("Bearer sk-other"))

  // glopenai still prepends a (empty) bearer for keyless endpoints —
  // nexus's transport seam strips it, and that strip changes nothing
  // else: same body, no header.
  let dropped = openai.drop_empty_bearer(keyless_raw, keyless_endpoint)
  should.be_error(request.get_header(dropped, "authorization"))
  dropped.body |> should.equal(keyed.body)
}
