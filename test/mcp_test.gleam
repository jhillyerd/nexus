//// The MCP layer's offline suite (plugin-api plan Phase 2): the codec
//// (frames, canonical JSON, the bounded reader, boundary validation),
//// the adapter ACTOR driven through the fake transport (the
//// `gated_runner` inversion — the test plays the server on the
//// actor-owned events subject), and the whole registry freeze path
//// (create → live `tools/list` → frozen manifest → hydration that
//// never contacts the server → down-at-call). No OS process, no
//// network — `gleam test` stays offline.

import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import nexus/config.{type Config}
import nexus/mcp
import nexus/mcp_adapter
import nexus/openai
import nexus/store
import nexus/thread_registry
import nexus/tool_provider
import nexus/tools
import store_mock

// ---------------------------------------------------------------------------
// Helpers: the fake transport + handshake choreography
// ---------------------------------------------------------------------------

/// Mint a unique adapter name per test (process.new_name suffixes a
/// counter, so the same string never collides across tests).
fn adapter_name(tag: String) -> process.Name(tool_provider.Msg) {
  tool_provider.name(tag <> int.to_string(erlang_unique_int()))
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_int() -> Int

/// The fake transport: `send_line` forwards frames the adapter writes
/// onto the TEST-owned `to_server` subject (sending is legal from the
/// adapter — only receiving is owner-checked); `arm` selects the
/// ACTOR-owned events subject handed over through the probe, onto
/// which the test sends `Chunk` frames AS the server.
fn fake_transport(
  to_server: process.Subject(String),
) -> mcp.Transport(mcp_adapter.Msg) {
  mcp.Transport(
    send_line: fn(line) {
      process.send(to_server, line)
      Ok(Nil)
    },
    arm: fn(events, selector, wrap) {
      process.select_map(selector, events, wrap)
    },
  )
}

type Fake {
  Fake(
    name: process.Name(tool_provider.Msg),
    /// The adapter's public address (subject of its named mailbox).
    actor: process.Subject(mcp_adapter.Msg),
    /// Frames the adapter writes (the test reads them AS the server).
    to_server: process.Subject(String),
    /// The actor-owned gate: the test sends `Chunk`/`Exited` events.
    events: process.Subject(mcp.TransportEvent),
  )
}

fn start_fake(tag: String, deadline_ms: Int) -> Fake {
  let name = adapter_name(tag)
  let to_server = process.new_subject()
  let probe = process.new_subject()
  let assert Ok(started) =
    mcp_adapter.start_probing(
      server: config.McpServer(
        name: tag,
        command: "./unused",
        args: [],
        env: [],
        timeout_ms: None,
      ),
      name: name,
      deadline_ms: deadline_ms,
      transport: fake_transport(to_server),
      probe: probe,
    )
  let assert Ok(events) = process.receive(probe, 5000)
  Fake(name: name, actor: started.data, to_server: to_server, events: events)
}

/// Complete the initialize handshake: read the initialize request,
/// answer it, read the initialized notification.
fn complete_handshake(fake: Fake) -> Nil {
  let assert Ok(init_frame) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(init_frame, "\"initialize\""))
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\""
      <> mcp.protocol_version
      <> "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"0\"}}}",
  )
  let assert Ok(initialized) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(initialized, "notifications/initialized"))
}

/// The test, as the server, writes a frame to the adapter.
fn server_says(fake: Fake, frame: String) -> Nil {
  process.send(fake.events, mcp.Chunk(bit_array.from_string(frame <> "\n")))
}

/// Ask ListTools from a spawned worker (the ask blocks its caller; the
/// test must stay free to play the server).
fn ask_list_tools(
  fake: Fake,
  timeout_ms: Int,
) -> process.Subject(Result(List(tool_provider.ToolDef), String)) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      reply,
      tool_provider.list_tools(provider: fake.name, timeout_ms: timeout_ms),
    )
  })
  reply
}

/// Wait for the next tools/list request and answer it with `tools`.
fn serve_tools_list(fake: Fake, tools_json: String) -> Nil {
  let assert Ok(frame) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(frame, "\"tools/list\""))
  let assert Ok(id) = extract_int_field(frame, "id")
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(id)
      <> ",\"result\":{\"tools\":"
      <> tools_json
      <> "}}",
  )
}

fn extract_int_field(frame: String, field: String) -> Result(Int, Nil) {
  let decoder = {
    use v <- decode.field(field, decode.int)
    decode.success(v)
  }
  case json.parse(frame, decoder) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Codec: canonical JSON
// ---------------------------------------------------------------------------

pub fn canonical_json_is_sorted_and_stable_test() {
  let assert Ok(text) =
    json.parse(
      "{\"b\":1,\"a\":{\"y\":true,\"x\":null},\"c\":[2,1]}",
      decode.dynamic,
    )
    |> result.map(mcp.canonical_json)
    |> result.unwrap(Error("no"))
  // Sorted keys at every level; whitespace-free.
  should.equal(text, "{\"a\":{\"x\":null,\"y\":true},\"b\":1,\"c\":[2,1]}")

  // The SAME input canonicalizes identically (determinism across runs).
  let assert Ok(text2) =
    json.parse(
      "{\"b\":1,\"a\":{\"y\":true,\"x\":null},\"c\":[2,1]}",
      decode.dynamic,
    )
    |> result.map(mcp.canonical_json)
    |> result.unwrap(Error("no"))
  should.equal(text, text2)
}

pub fn canonical_json_refuses_non_object_root_test() {
  let assert Ok(array) = json.parse("[1,2]", decode.dynamic)
  let assert Error(_) = mcp.canonical_json(array)
  let assert Ok(string) = json.parse("\"x\"", decode.dynamic)
  let assert Error(_) = mcp.canonical_json(string)
}

pub fn canonical_json_text_roundtrip_test() {
  // Pretty-printed arguments collapse to canonical (newline-free) text.
  let assert Ok(text) =
    mcp.canonical_json_text("{\n  \"a\": 1,\n  \"b\": \"two\"\n}")
  should.equal(text, "{\"a\":1,\"b\":\"two\"}")
  let assert Error(_) = mcp.canonical_json_text("nope")
}

// ---------------------------------------------------------------------------
// Codec: frames
// ---------------------------------------------------------------------------

pub fn parse_incoming_classifies_test() {
  let assert mcp.Response(7, Ok(_)) =
    mcp.parse_incoming("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":1}}")
  let assert mcp.Response(8, Error(rpc)) =
    mcp.parse_incoming(
      "{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32601,\"message\":\"nope\"}}",
    )
  rpc.code |> should.equal(-32_601)
  let assert mcp.ServerRequest(id, "sampling/createMessage") =
    mcp.parse_incoming(
      "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"sampling/createMessage\"}",
    )
  // A string id is echoed through the canonical encoder, quoted.
  let reply = mcp.method_not_found_response(id)
  should.be_true(string.contains(reply, "\"id\":\"srv-1\""))
  should.be_true(string.contains(reply, "-32601"))
  let assert mcp.ServerNotification("notifications/tools/list_changed") =
    mcp.parse_incoming(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
    )
  let assert mcp.Garbage = mcp.parse_incoming("not json at all")
}

pub fn tools_call_request_embeds_canonical_arguments_test() {
  let assert Ok(frame) =
    mcp.tools_call_request(9, "fetch", "{ \"q\": \"rust\", \"n\": [1, 2] }")
  should.be_true(string.contains(
    frame,
    "\"arguments\":{\"n\":[1,2],\"q\":\"rust\"}",
  ))
  should.be_true(string.contains(frame, "\"name\":\"fetch\""))
  // Newline-free even when the model pretty-printed: the framing
  // depends on it.
  should.equal(string.contains(frame, "\n"), False)
  let assert Error(_) = mcp.tools_call_request(9, "fetch", "[1]")
  let assert Error(_) = mcp.tools_call_request(9, "fetch", "garbage")
}

// ---------------------------------------------------------------------------
// Codec: tools/list boundary
// ---------------------------------------------------------------------------

pub fn decode_tools_list_validates_and_canonicalizes_test() {
  let assert Ok(result) =
    json.parse(
      "{\"tools\":[{\"name\":\"get_issue\","
        <> "\"description\":\"Fetch an issue\","
        <> "\"inputSchema\":{\"type\":\"object\",\"b\":2,\"a\":1}}]}",
      decode.dynamic,
    )
  let assert Ok(#([def], None)) = mcp.decode_tools_list(result)
  def.name |> should.equal("get_issue")
  // The FROZEN text is canonical (sorted keys): byte-stable forever.
  should.equal(def.parameters_json, "{\"a\":1,\"b\":2,\"type\":\"object\"}")
}

pub fn decode_tools_list_refuses_hostile_entries_test() {
  // A name carrying the reserved separator.
  let assert Ok(result) =
    json.parse(
      "{\"tools\":[{\"name\":\"bad__name\",\"inputSchema\":{\"type\":\"object\"}}]}",
      decode.dynamic,
    )
  let assert Error(reason) = mcp.decode_tools_list(result)
  should.be_true(string.contains(reason, "bad__name"))

  // A missing inputSchema.
  let assert Ok(result2) =
    json.parse("{\"tools\":[{\"name\":\"ok\"}]}", decode.dynamic)
  let assert Error(_) = mcp.decode_tools_list(result2)

  // A non-object schema.
  let assert Ok(result3) =
    json.parse(
      "{\"tools\":[{\"name\":\"ok\",\"inputSchema\":[1]}]}",
      decode.dynamic,
    )
  let assert Error(_) = mcp.decode_tools_list(result3)
}

pub fn decode_tools_list_truncates_long_descriptions_test() {
  let long = string.repeat("x", mcp.max_description_chars + 100)
  let assert Ok(result) =
    json.parse(
      "{\"tools\":[{\"name\":\"ok\",\"description\":\""
        <> long
        <> "\",\"inputSchema\":{\"type\":\"object\"}}]}",
      decode.dynamic,
    )
  let assert Ok(#([def], _)) = mcp.decode_tools_list(result)
  should.equal(
    string.length(def.description) > mcp.max_description_chars,
    False,
  )
}

pub fn decode_call_result_flattens_content_test() {
  let assert Ok(result) =
    json.parse(
      "{\"content\":[{\"type\":\"text\",\"text\":\"line one\"},"
        <> "{\"type\":\"image\",\"data\":\"...\"},"
        <> "{\"type\":\"text\",\"text\":\"line two\"}],\"isError\":true}",
      decode.dynamic,
    )
  let assert Ok(tool_provider.ToolErr(text)) = mcp.decode_call_result(result)
  should.equal(text, "line one\n[image content omitted]\nline two")

  let assert Ok(result2) =
    json.parse(
      "{\"content\":[{\"type\":\"text\",\"text\":\"fine\"}]}",
      decode.dynamic,
    )
  let assert Ok(tool_provider.ToolOk(text2)) = mcp.decode_call_result(result2)
  text2 |> should.equal("fine")

  // No content at all: honest placeholder, never empty bytes.
  let assert Ok(result3) = json.parse("{}", decode.dynamic)
  let assert Ok(tool_provider.ToolOk("(no content)")) =
    mcp.decode_call_result(result3)
}

// ---------------------------------------------------------------------------
// Codec: the bounded reader
// ---------------------------------------------------------------------------

pub fn feed_splits_frames_across_chunks_test() {
  let feed = mcp.new_feed()
  // One chunk mid-frame, the rest in the next.
  let #(frames1, feed2) = mcp.feed(feed, bit_array_from("{\"a\":1}\n{\"b\":"))
  frames1 |> should.equal([mcp.Line("{\"a\":1}")])
  let #(frames2, _) = mcp.feed(feed2, bit_array_from("2}\n"))
  frames2 |> should.equal([mcp.Line("{\"b\":2}")])
}

fn bit_array_from(s: String) -> BitArray {
  bit_array.from_string(s)
}

pub fn feed_refuses_oversized_tail_test() {
  let feed = mcp.new_feed()
  let big = string.repeat("x", mcp.max_frame_bytes + 1)
  let #(frames, feed2) = mcp.feed(feed, bit_array_from(big <> "\n"))
  frames |> should.equal([mcp.TooBig])
  // The hostile tail was DROPPED, not accumulated: the next frame is
  // readable.
  let #(frames2, _) = mcp.feed(feed2, bit_array_from("ok\n"))
  frames2 |> should.equal([mcp.Line("ok")])
}

pub fn feed_drops_non_utf8_test() {
  let assert #([mcp.NotUtf8], _) = mcp.feed(mcp.new_feed(), <<255, 10>>)
}

// ---------------------------------------------------------------------------
// The adapter actor (fake transport)
// ---------------------------------------------------------------------------

pub fn list_tools_round_trip_canonicalizes_test() {
  let fake = start_fake("list", 30_000)
  complete_handshake(fake)
  let reply = ask_list_tools(fake, 5000)
  serve_tools_list(
    fake,
    "[{\"name\":\"t1\",\"inputSchema\":{\"z\":1,\"a\":2}},{\"name\":\"t2\",\"inputSchema\":{\"type\":\"object\"}}]",
  )
  let assert Ok(Ok(defs)) = process.receive(reply, 5000)
  let assert [def1, def2] = defs
  def1.name |> should.equal("t1")
  should.equal(def1.parameters_json, "{\"a\":2,\"z\":1}")
  def2.name |> should.equal("t2")
}

pub fn list_tools_during_handshake_queues_test() {
  let fake = start_fake("queue", 30_000)
  // Ask BEFORE the handshake completes: the asker rides the first
  // round trip after readiness.
  let reply = ask_list_tools(fake, 5000)
  complete_handshake(fake)
  serve_tools_list(
    fake,
    "[{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\"}}]",
  )
  let assert Ok(Ok(defs)) = process.receive(reply, 5000)
  list.map(defs, fn(def) { def.name })
  |> should.equal(["t"])
}

pub fn call_maps_result_to_reply_test() {
  let fake = start_fake("call", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t1",
      arguments: "{\"k\":\"v\"}",
      reply: reply,
    ),
  )
  let assert Ok(frame) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(frame, "\"tools/call\""))
  should.be_true(string.contains(frame, "\"arguments\":{\"k\":\"v\"}"))
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(extract_int_field_unsafe(frame, "id"))
      <> ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"isError\":false}}",
  )
  let assert Ok(tool_provider.ToolOk(text)) = process.receive(reply, 5000)
  text |> should.equal("hello")
}

pub fn call_is_error_maps_to_tool_err_test() {
  let fake = start_fake("iserr", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t1",
      arguments: "{}",
      reply: reply,
    ),
  )
  let assert Ok(frame) = process.receive(fake.to_server, 5000)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(extract_int_field_unsafe(frame, "id"))
      <> ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}}",
  )
  let assert Ok(tool_provider.ToolErr("boom")) = process.receive(reply, 5000)
}

pub fn call_jsonrpc_error_maps_to_tool_err_test() {
  let fake = start_fake("rpcerr", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "nope",
      arguments: "{}",
      reply: reply,
    ),
  )
  let assert Ok(frame) = process.receive(fake.to_server, 5000)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(extract_int_field_unsafe(frame, "id"))
      <> ",\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}",
  )
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 5000)
  should.be_true(string.contains(message, "-32602"))
  should.be_true(string.contains(message, "unknown tool"))
}

pub fn call_refuses_non_object_arguments_test() {
  let fake = start_fake("badargs", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t1",
      arguments: "[1,2]",
      reply: reply,
    ),
  )
  // Refused BEFORE the wire: no frame reaches the server.
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 5000)
  should.be_true(string.contains(message, "invalid arguments"))
  let assert Error(Nil) = process.receive(fake.to_server, 200)
}

@external(erlang, "erlang", "make_ref")
fn make_ref() -> reference.Reference

fn extract_int_field_unsafe(frame: String, field: String) -> Int {
  let assert Ok(id) = extract_int_field(frame, field)
  id
}

pub fn call_timeout_notifies_cancelled_test() {
  let fake = start_fake("deadline", 200)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "slow",
      arguments: "{}",
      reply: reply,
    ),
  )
  let _frame = process.receive(fake.to_server, 5000)
  // The actor-side deadline answers first (with the cancelled notice);
  // the caller's own deadline equals it, so whoever fires first wins
  // and the other side's reply is inert.
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 5000)
  should.be_true(string.contains(message, "did not answer within"))
  let assert Ok(cancelled) = process.receive(fake.to_server, 2000)
  should.be_true(string.contains(cancelled, "notifications/cancelled"))
}

pub fn cancelled_notice_tells_server_and_stays_silent_test() {
  let fake = start_fake("cancel", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  let ref = make_ref()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(ref: ref, tool: "t1", arguments: "{}", reply: reply),
  )
  let assert Ok(_frame) = process.receive(fake.to_server, 5000)
  // The executor gave up on its own deadline (the transcript already
  // carries it) and notifies best-effort: the server is told, NO reply
  // is sent.
  process.send(process.named_subject(fake.name), tool_provider.Cancelled(ref))
  let assert Ok(cancelled) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(cancelled, "notifications/cancelled"))
  let assert Error(Nil) = process.receive(reply, 300)
}

pub fn server_exit_fails_everything_honestly_test() {
  let fake = start_fake("exit", 30_000)
  complete_handshake(fake)
  let reply = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t1",
      arguments: "{}",
      reply: reply,
    ),
  )
  let assert Ok(_frame) = process.receive(fake.to_server, 5000)
  // The child dies mid-call: the pending call fails, and every LATER
  // call fails too — the actor stays up (no supervisor churn for an
  // external process's exit), honestly unavailable.
  process.send(fake.events, mcp.Exited(1))
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 5000)
  should.be_true(string.contains(message, "exited"))
  let reply2 = process.new_subject()
  process.send(
    process.named_subject(fake.name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t1",
      arguments: "{}",
      reply: reply2,
    ),
  )
  let assert Ok(tool_provider.ToolErr(_)) = process.receive(reply2, 5000)
}

pub fn server_request_answered_method_not_found_test() {
  let fake = start_fake("srvreq", 30_000)
  complete_handshake(fake)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":\"srv-9\",\"method\":\"sampling/createMessage\",\"params\":{}}",
  )
  let assert Ok(reply_frame) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(reply_frame, "-32601"))
  should.be_true(string.contains(reply_frame, "\"id\":\"srv-9\""))
}

pub fn server_notification_ignored_test() {
  let fake = start_fake("notify", 30_000)
  complete_handshake(fake)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
  )
  // Nothing crashes, nothing is answered; the adapter is still ready.
  let reply = ask_list_tools(fake, 5000)
  serve_tools_list(
    fake,
    "[{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\"}}]",
  )
  let assert Ok(Ok(_defs)) = process.receive(reply, 5000)
}

pub fn tools_list_pagination_follows_cursor_test() {
  let fake = start_fake("pages", 30_000)
  complete_handshake(fake)
  let reply = ask_list_tools(fake, 5000)
  let assert Ok(frame1) = process.receive(fake.to_server, 5000)
  let id1 = extract_int_field_unsafe(frame1, "id")
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(id1)
      <> ",\"result\":{\"tools\":[{\"name\":\"p1\",\"inputSchema\":{\"type\":\"object\"}}],"
      <> "\"nextCursor\":\"page-2\"}}",
  )
  let assert Ok(frame2) = process.receive(fake.to_server, 5000)
  should.be_true(string.contains(frame2, "\"cursor\":\"page-2\""))
  let id2 = extract_int_field_unsafe(frame2, "id")
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(id2)
      <> ",\"result\":{\"tools\":[{\"name\":\"p2\",\"inputSchema\":{\"type\":\"object\"}}]}}",
  )
  let assert Ok(Ok(defs)) = process.receive(reply, 5000)
  list.map(defs, fn(def) { def.name })
  |> should.equal(["p1", "p2"])
}

pub fn boot_collision_with_plugin_name_refuses_test() {
  // Config-level check, no tree started: a server named like a plugin
  // is refused loudly at boot (both are user config, deterministic —
  // the loud-refusal rule, not the degrade rule).
  let cfg =
    config.Config(..test_config(), plugins: ["example"], mcp_servers: [
      config.McpServer(
        name: "example",
        command: "./x",
        args: [],
        env: [],
        timeout_ms: None,
      ),
    ])
  let assert Error(reason) = mcp_adapter.boot(cfg)
  should.be_true(string.contains(reason, "NEXUS_PLUGINS"))
}

pub fn boot_empty_config_starts_nothing_test() {
  let assert Ok([]) = mcp_adapter.boot(test_config())
}

// ---------------------------------------------------------------------------
// The registry freeze path (the whole Phase 2 create/hydrate story)
// ---------------------------------------------------------------------------

fn fixture_resolver(
  id: String,
) -> Result(openai.Endpoint, thread_registry.ProviderError) {
  case id == store_mock.fixture_provider_id {
    True ->
      Ok(openai.Endpoint(
        base_url: "http://fixture.invalid/v1",
        api_key: Some("sk-fixture"),
        sse_first_response_timeout_ms: 1000,
        stream_idle_timeout_ms: 1000,
      ))
    False -> Error(thread_registry.ProviderUnknown)
  }
}

fn test_config() -> Config {
  let assert Ok(cfg) =
    config.from_env(fn(name) {
      case name {
        "NEXUS_ENCRYPTION_KEY" ->
          Ok("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
        _ -> Error(Nil)
      }
    })
  cfg
}

pub fn create_freezes_live_schema_into_manifest_test() {
  let fake = start_fake("freeze", 30_000)
  complete_handshake(fake)
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  store_mock.ensure_fixture_bot(persistence)
  let factory_name = process.new_name("nexus_freeze_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_freeze_registry"),
      persistence,
      fixture_resolver,
      process.new_name("nexus_freeze_bots"),
      dict.new(),
      dict.from_list([
        #("fakesrv", tools.ForeignServer(name: fake.name, timeout_ms: 30_000)),
      ]),
    )
  // Create naming the foreign tool: the freeze asks the server LIVE.
  let reply = process.new_subject()
  process.send(
    started.data,
    thread_registry.Create(
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some(["fakesrv__get_issue"]),
        bot_id: "b-fixture",
        parent_thread_id: None,
        title: "",
      ),
      reply,
    ),
  )
  serve_tools_list(
    fake,
    "[{\"name\":\"get_issue\",\"description\":\"Fetch an issue\","
      <> "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"string\"}}}}]",
  )
  let assert Ok(Ok(summary)) = process.receive(reply, 5000)
  // The manifest carries the FROZEN entry — canonical schema, frozen
  // description.
  let assert Ok(stored) = persistence.get_thread(summary.id)
  should.equal(stored.summary.toolset, [
    tools.ToolsetEntry(
      name: "fakesrv__get_issue",
      description: "Fetch an issue",
      schema_json: Some(
        "{\"properties\":{\"n\":{\"type\":\"string\"}},\"type\":\"object\"}",
      ),
    ),
  ])
}

pub fn unmounted_server_create_is_honest_400_test() {
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  store_mock.ensure_fixture_bot(persistence)
  let factory_name = process.new_name("nexus_unmount_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_unmount_registry"),
      persistence,
      fixture_resolver,
      process.new_name("nexus_unmount_bots"),
      dict.new(),
      dict.new(),
    )
  let reply = process.new_subject()
  process.send(
    started.data,
    thread_registry.Create(
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some(["ghost__tool"]),
        bot_id: "b-fixture",
        parent_thread_id: None,
        title: "",
      ),
      reply,
    ),
  )
  let assert Ok(Error(thread_registry.UnknownToolset(reason))) =
    process.receive(reply, 5000)
  should.be_true(string.contains(reason, "ghost"))
}

pub fn hydration_replays_frozen_schema_without_server_contact_test() {
  // Boot, freeze a thread (as above), then boot a FRESH registry over
  // the same store with a FRESH adapter mount — hydration must build
  // the bundle from the frozen manifest and never ask the server for
  // its catalog.
  let fake = start_fake("hydrate", 30_000)
  complete_handshake(fake)
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  store_mock.ensure_fixture_bot(persistence)
  let factory_name = process.new_name("nexus_hydr_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_hydr_registry"),
      persistence,
      fixture_resolver,
      process.new_name("nexus_hydr_bots"),
      dict.new(),
      dict.from_list([
        #("fakesrv", tools.ForeignServer(name: fake.name, timeout_ms: 30_000)),
      ]),
    )
  let reply = process.new_subject()
  process.send(
    started.data,
    thread_registry.Create(
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: Some(["fakesrv__t"]),
        bot_id: "b-fixture",
        parent_thread_id: None,
        title: "",
      ),
      reply,
    ),
  )
  serve_tools_list(
    fake,
    "[{\"name\":\"t\",\"description\":\"d\",\"inputSchema\":{\"type\":\"object\"}}]",
  )
  let assert Ok(Ok(summary)) = process.receive(reply, 5000)

  // A fresh registry over the same store hydrates lazily. A FRESH
  // adapter (new name value) represents the restarted server.
  let fake2 = start_fake("hydrate2", 30_000)
  complete_handshake(fake2)
  let factory_name2 = process.new_name("nexus_hydr2_factory")
  let assert Ok(_factory2) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name2))
  let assert Ok(started2) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name2),
      process.new_name("nexus_hydr2_registry"),
      persistence,
      fixture_resolver,
      process.new_name("nexus_hydr2_bots"),
      dict.new(),
      dict.from_list([
        #("fakesrv", tools.ForeignServer(name: fake2.name, timeout_ms: 30_000)),
      ]),
    )
  let assert Ok(_subject) = thread_registry.get(started2.data, summary.id)
  // NO tools/list frame may arrive: hydration replays the frozen text.
  let assert Error(Nil) = process.receive(fake2.to_server, 300)
}

pub fn down_server_call_is_honest_tool_error_test() {
  // A hydrated thread's executor addresses the adapter by name; when
  // the server has exited, the call renders the honest tool error —
  // exercised here directly through the protocol executor, which is
  // exactly what a turn runs.
  let fake = start_fake("down", 30_000)
  complete_handshake(fake)
  process.send(fake.events, mcp.Exited(1))
  let assert Error(outcome) =
    tool_provider.run(
      provider: fake.name,
      tool: "t",
      timeout_ms: 2000,
      max_output_chars: 1000,
      cancel: process.new_subject(),
      arguments: "{}",
    )
  should.be_true(string.contains(outcome, "unavailable"))
  should.be_true(string.contains(outcome, "exited"))
}

pub fn corrupt_plain_manifest_entry_refuses_test() {
  // A manifest row carrying a frozen schema on a PLAIN (compiled)
  // name is corrupt — a write path that should not exist — and
  // refuses loudly instead of silently ignoring the schema.
  let assert Error(reason) =
    tools.by_entries_with(test_config(), dict.new(), dict.new(), [
      tools.ToolsetEntry("http_fetch", "x", Some("{}")),
    ])
  should.be_true(string.contains(reason, "corrupt"))
}

// ---------------------------------------------------------------------------
// Review-hardening pins (cubic round, PR #124)
// ---------------------------------------------------------------------------

pub fn feed_refuses_oversized_accumulation_before_concat_test() {
  // A partial frame left in the buffer, then a chunk big enough to
  // blow the cap: the accumulated frame is refused (TooBig) WITHOUT
  // the oversized tail ever becoming the new buffer, and the chunk's
  // own trailing line still parses.
  let #(frames1, feed2) = mcp.feed(mcp.new_feed(), bit_array_from("partial-"))
  frames1 |> should.equal([])
  let big = string.repeat("x", mcp.max_frame_bytes + 1)
  let #(frames2, _) = mcp.feed(feed2, bit_array_from(big <> "\nok\n"))
  frames2 |> should.equal([mcp.TooBig, mcp.Line("ok")])
}

pub fn parse_incoming_requires_jsonrpc_version_test() {
  // A stray log line with an unlucky "id" must not complete a pending
  // request: the spec's "jsonrpc":"2.0" is REQUIRED on every frame.
  let assert mcp.Garbage =
    mcp.parse_incoming("{\"id\":2,\"result\":{\"tools\":[]}}")
  let assert mcp.Garbage =
    mcp.parse_incoming("{\"jsonrpc\":\"1.0\",\"id\":2,\"result\":{}}")
}

pub fn decode_tools_list_refuses_duplicate_names_test() {
  let assert Ok(result) =
    json.parse(
      "{\"tools\":[{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\"}},"
        <> "{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\"}}]}",
      decode.dynamic,
    )
  let assert Error(reason) = mcp.decode_tools_list(result)
  should.be_true(string.contains(reason, "duplicate"))
}

pub fn decode_tools_list_refuses_nul_bytes_test() {
  // Postgres TEXT cannot carry NUL: a hostile description must refuse
  // at the MCP boundary, not fail a create inside the store.
  let assert Ok(result) =
    json.parse(
      "{\"tools\":[{\"name\":\"t\",\"description\":\"a\\u0000b\","
        <> "\"inputSchema\":{\"type\":\"object\"}}]}",
      decode.dynamic,
    )
  let assert Error(reason) = mcp.decode_tools_list(result)
  should.be_true(string.contains(reason, "NUL"))

  let assert Ok(result2) =
    json.parse(
      "{\"tools\":[{\"name\":\"t\",\"description\":\"ok\","
        <> "\"inputSchema\":{\"type\":\"object\",\"x\":\"\\u0000\"}}]}",
      decode.dynamic,
    )
  let assert Error(reason2) = mcp.decode_tools_list(result2)
  should.be_true(string.contains(reason2, "NUL"))
}

pub fn split_refuses_malformed_qualified_names_test() {
  // Never produced by `qualified` — both halves must be valid names.
  tool_provider.split("foo__bar__baz") |> should.equal(Error(Nil))
  tool_provider.split("foo__bar.") |> should.equal(Error(Nil))
  let assert Ok(#("foo", "bar")) = tool_provider.split("foo__bar")
}

pub fn tools_list_pagination_cap_fails_loudly_test() {
  let fake = start_fake("cap", 30_000)
  complete_handshake(fake)
  let reply = ask_list_tools(fake, 30_000)
  // Ten pages served, the tenth still carrying a cursor: the cap is a
  // truncation GUARD — the ask fails, never silently omits tools.
  serve_paginated_pages(fake, 10, True)
  let assert Ok(Error(reason)) = process.receive(reply, 5000)
  should.be_true(string.contains(reason, "exceeds"))
}

pub fn tools_list_pagination_tenth_page_allowed_test() {
  let fake = start_fake("capok", 30_000)
  complete_handshake(fake)
  let reply = ask_list_tools(fake, 30_000)
  // A catalog that finishes exactly ON the tenth page is valid.
  serve_paginated_pages(fake, 10, False)
  let assert Ok(Ok(defs)) = process.receive(reply, 5000)
  list.length(defs) |> should.equal(10)
}

fn serve_paginated_pages(fake: Fake, pages: Int, final_cursor: Bool) -> Nil {
  case pages {
    0 -> Nil
    n -> {
      let assert Ok(frame) = process.receive(fake.to_server, 5000)
      let id = extract_int_field_unsafe(frame, "id")
      let cursor = case n {
        1 if final_cursor -> "final-cursor-at-cap"
        _ -> "page-" <> int.to_string(n)
      }
      let cursor_json = case n == 1 && !final_cursor {
        True -> ""
        False -> ",\"nextCursor\":\"" <> cursor <> "\""
      }
      server_says(
        fake,
        "{\"jsonrpc\":\"2.0\",\"id\":"
          <> int.to_string(id)
          <> ",\"result\":{\"tools\":[{\"name\":\"p"
          <> int.to_string(n)
          <> "\",\"inputSchema\":{\"type\":\"object\"}}]"
          <> cursor_json
          <> "}}",
      )
      serve_paginated_pages(fake, n - 1, final_cursor)
    }
  }
}

pub fn corrupt_row_ids_are_not_reminted_test() {
  // A store row skipped for a corrupt manifest must still protect its
  // id: the registry's minting counter seeds PAST the skip list, so a
  // fresh create can never collide with the corrupt row on insert.
  let persistence = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(persistence)
  store_mock.ensure_fixture_bot(persistence)
  let factory_name = process.new_name("nexus_corrupt_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let seam =
    store.Store(..persistence, list_summaries: fn() { Ok(#([], ["s5"])) })
  let assert Ok(started) =
    thread_registry.start(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_corrupt_registry"),
      seam,
      fixture_resolver,
      process.new_name("nexus_corrupt_bots"),
      dict.new(),
      dict.new(),
    )
  let reply = process.new_subject()
  process.send(
    started.data,
    thread_registry.Create(
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        toolset: None,
        bot_id: "b-fixture",
        parent_thread_id: None,
        title: "",
      ),
      reply,
    ),
  )
  let assert Ok(Ok(summary)) = process.receive(reply, 5000)
  // No s5 remint: the counter jumped past the skipped id.
  should.be_true(summary.id != "s5")
}

pub fn tools_list_duplicate_name_across_pages_fails_test() {
  let fake = start_fake("dupxpage", 30_000)
  complete_handshake(fake)
  let reply = ask_list_tools(fake, 30_000)
  // Page 1 names p1; the cursor continues onto a page that names p1
  // AGAIN — each page's own check passes, the accumulated catalog must
  // not.
  let assert Ok(frame1) = process.receive(fake.to_server, 5000)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(extract_int_field_unsafe(frame1, "id"))
      <> ",\"result\":{\"tools\":[{\"name\":\"p1\",\"inputSchema\":{\"type\":\"object\"}}],"
      <> "\"nextCursor\":\"more\"}}",
  )
  let assert Ok(frame2) = process.receive(fake.to_server, 5000)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(extract_int_field_unsafe(frame2, "id"))
      <> ",\"result\":{\"tools\":[{\"name\":\"p1\",\"inputSchema\":{\"type\":\"object\"}}]}}",
  )
  let assert Ok(Error(reason)) = process.receive(reply, 5000)
  should.be_true(string.contains(reason, "duplicate"))
}

pub fn feed_exactly_cap_line_accepted_on_any_chunk_boundary_test() {
  // A line of EXACTLY max_frame_bytes is valid: chunk-independent
  // acceptance, matching the single-chunk path.
  let exact = string.repeat("y", mcp.max_frame_bytes)
  // One chunk, newline included.
  let #(single, _) = mcp.feed(mcp.new_feed(), bit_array_from(exact <> "\n"))
  single |> should.equal([mcp.Line(exact)])
  // Two chunks, newline in the second: same verdict.
  let #(_, feed_mid) = mcp.feed(mcp.new_feed(), bit_array_from(exact))
  let #(split, _) = mcp.feed(feed_mid, bit_array_from("\n"))
  split |> should.equal([mcp.Line(exact)])
}

pub fn feed_one_over_cap_line_refused_on_any_chunk_boundary_test() {
  // cap+1 bytes: refused as soon as they are seen — with or without
  // the newline having arrived — and the feed is POISONED: the refused
  // frame's remainder is discarded through its terminating newline, so
  // a hostile suffix cannot re-enter parsing at a fake frame boundary.
  let big = string.repeat("z", mcp.max_frame_bytes + 1)
  // No newline yet: the over-cap tail is refused immediately and the
  // feed poisoned.
  let #(first, feed_mid) = mcp.feed(mcp.new_feed(), bit_array_from(big))
  first |> should.equal([mcp.TooBig])
  // Same verdict when the newline DID ride the same chunk (the frame
  // was split off complete and consumed — no poison there).
  let #(one_chunk, _) = mcp.feed(mcp.new_feed(), bit_array_from(big <> "\n"))
  one_chunk |> should.equal([mcp.TooBig])
  // The poisoned feed discards the remainder through its newline —
  // even when it looks like a valid frame.
  let #(remainder, feed_mid2) = mcp.feed(feed_mid, bit_array_from("\"x\":1\n"))
  remainder |> should.equal([])
  // ...and a frame AFTER the refused frame's newline parses normally.
  let #(after, _) = mcp.feed(feed_mid2, bit_array_from("\"real\":2\n"))
  after |> should.equal([mcp.Line("\"real\":2")])
}

pub fn server_ping_answered_with_empty_result_test() {
  let fake = start_fake("ping", 30_000)
  complete_handshake(fake)
  server_says(
    fake,
    "{\"jsonrpc\":\"2.0\",\"id\":\"health-1\",\"method\":\"ping\"}",
  )
  let assert Ok(reply_frame) = process.receive(fake.to_server, 5000)
  // MCP 2025-06-18: ping MUST be answered with an empty-object result
  // — a liveness check succeeds on a responsive connection.
  should.be_true(string.contains(reply_frame, "\"id\":\"health-1\""))
  should.be_true(string.contains(reply_frame, "\"result\":{}"))
}

pub fn busy_stdin_is_not_diagnosed_as_dead_test() {
  // A transient backpressure error from the transport keeps its
  // reason: the tool error names BUSY, not a closed stdin.
  let busy_transport =
    mcp.Transport(
      send_line: fn(_line) { Error("server stdin is busy") },
      arm: fn(events, selector, wrap) {
        process.select_map(selector, events, wrap)
      },
    )
  let name = adapter_name("busy")
  let probe = process.new_subject()
  let assert Ok(_) =
    mcp_adapter.start_probing(
      server: config.McpServer(
        name: "busy",
        command: "./unused",
        args: [],
        env: [],
        timeout_ms: None,
      ),
      name: name,
      deadline_ms: 30_000,
      transport: busy_transport,
      probe: probe,
    )
  let assert Ok(_) = process.receive(probe, 5000)
  // The initialize frame's send failed → Down with the BUSY reason,
  // honest and diagnosable.
  let reply = process.new_subject()
  process.send(
    process.named_subject(name),
    tool_provider.Call(
      ref: make_ref(),
      tool: "t",
      arguments: "{}",
      reply: reply,
    ),
  )
  let assert Ok(tool_provider.ToolErr(message)) = process.receive(reply, 5000)
  should.be_true(string.contains(message, "busy"))
  should.equal(string.contains(message, "closed"), False)
}
