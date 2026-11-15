//// The MCP client codec + stdio transport (plugin-api plan Phase 2).
////
//// One configured MCP server is a stdio child process speaking
//// newline-delimited JSON-RPC on stdin/stdout (the MCP transport
//// spec: one message per line, no embedded newlines, UTF-8). This
//// module is the pure layer between those frames and the provider
//// protocol (`nexus/tool_provider`): request builders, response
//// parsers, the canonical-JSON normalizer that turns an untrusted
//// `inputSchema` into FREEZABLE TEXT, the bounded line reader, and
//// the `Transport` seam that lets `gleam test` run the adapter actor
//// against an in-memory fake server with no OS process at all.
////
//// Boundary rules enforced here (the hostile-text invariant):
//// - Every byte is capped WHILE READING (`max_frame_bytes` on the
////   line reader) — truncation after receipt would not bound
////   allocation.
//// - Tool names must pass `tool_provider.valid_name` (the server's
////   name is the other half of the qualified wire name, so MCP tool
////   names obey the plugin half-name rule).
//// - Schemas are canonicalized (deterministic, whitespace-free,
////   sorted keys) before they can be frozen into a thread manifest —
////   the envelope bytes that matter are built from THIS text, so it
////   must be byte-stable across parses and restarts. OTP's JSON
////   decoder loses object key order, so re-encoding without sorting
////   keys would not be stable; sorted keys are.
//// - Descriptions are truncated (`max_description_chars`): display
////   hygiene for a field that would otherwise ride the envelope
////   unbounded from an untrusted source.
////
//// The actor that speaks `tool_provider.Msg` on top of a Transport
//// lives in `nexus/mcp_adapter`; this module deliberately knows
//// nothing about actors beyond the selector contribution a Transport
//// carries (`arm`), which is what makes the fake transport possible.

import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/tool_provider.{type ToolDef, ToolDef, ToolErr, ToolOk}

/// The protocol version nexus requests. The server replies with the
/// version it selected (the spec's negotiation: same, or any version
/// it supports). Nexus is liberal — it proceeds with whatever parses —
/// because a strict check would refuse servers one revision behind the
/// literal this constant carries, and nothing in the three messages
/// nexus sends (initialize, tools/list, tools/call) differs across the
/// revisions in the wild today.
pub const protocol_version = "2025-06-18"

/// The read cap on one frame (one JSON-RPC line). Bounded accumulation:
/// a hostile or wedged server streaming a never-terminated line is cut
/// off here, before allocation, not after. Generous by orders of
/// magnitude — a tools/list response with hundreds of schemas stays
/// far under it.
pub const max_frame_bytes = 8_388_608

/// The description cap on a tools/list entry. Descriptions ride the
/// request envelope forever (frozen at create), so an untrusted server
/// does not get to inflate it.
pub const max_description_chars = 2000

// ---------------------------------------------------------------------------
// Outbound frames
// ---------------------------------------------------------------------------

/// The `initialize` request that opens the handshake.
pub fn initialize_request(id: Int) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("initialize")),
    #(
      "params",
      json.object([
        #("protocolVersion", json.string(protocol_version)),
        #("capabilities", json.object([])),
        #(
          "clientInfo",
          json.object([
            #("name", json.string("nexus")),
            #("version", json.string("1.0.0")),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// The `notifications/initialized` acknowledgment that closes the
/// handshake (a notification: no id, no reply expected).
pub fn initialized_notification() -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/initialized")),
  ])
  |> json.to_string
}

/// A `tools/list` request. MCP pages tool lists; `cursor` continues a
/// page (`nextCursor` from the previous response).
pub fn tools_list_request(id: Int, cursor: Option(String)) -> String {
  let params = case cursor {
    Some(c) -> [#("cursor", json.string(c))]
    None -> []
  }
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string("tools/list")),
    #("params", json.object(params)),
  ])
  |> json.to_string
}

/// A `tools/call` request. `arguments` is the RAW argument text the
/// model emitted — it is parsed, canonicalized (object root enforced,
/// newlines eliminated so the newline framing survives) and embedded.
/// Non-object arguments are refused: MCP requires an arguments OBJECT.
pub fn tools_call_request(
  id: Int,
  tool: String,
  arguments: String,
) -> Result(String, String) {
  use canonical <- result.try(canonical_json_text(arguments))
  let params =
    "{\"name\":"
    <> json.to_string(json.string(tool))
    <> ",\"arguments\":"
    <> canonical
    <> "}"
  Ok(
    "{\"jsonrpc\":\"2.0\",\"id\":"
    <> int.to_string(id)
    <> ",\"method\":\"tools/call\",\"params\":"
    <> params
    <> "}",
  )
}

/// The `notifications/cancelled` notice (best-effort, like the
/// protocol's own `Cancelled`): tells the server to stop work on a
/// request whose caller (the adapter executor's deadline or a user
/// Stop) has already moved on.
pub fn cancelled_notification(request_id: Int, reason: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string("notifications/cancelled")),
    #(
      "params",
      json.object([
        #("requestId", json.int(request_id)),
        #("reason", json.string(reason)),
      ]),
    ),
  ])
  |> json.to_string
}

/// The JSON-RPC error reply to a SERVER-initiated request. Nexus is a
/// tool client only — sampling, roots and friends are refused with
/// `method not found` (a response is REQUIRED by JSON-RPC; the server
/// is otherwise left waiting on our reply). The id is echoed verbatim
/// from the request (JSON-RPC ids may be strings) — re-encoded through
/// the canonical encoder (an id is a scalar, not frozen, so only
/// correctness matters here).
pub fn method_not_found_response(id: Dynamic) -> String {
  let id_text = canonical_json_any(id)
  "{\"jsonrpc\":\"2.0\",\"id\":"
  <> id_text
  <> ",\"error\":{\"code\":-32601,\"message\":\"method not found\"}}"
}

// ---------------------------------------------------------------------------
// Inbound frames
// ---------------------------------------------------------------------------

/// A JSON-RPC error object (transport-level: protocol errors like
/// `method not found` or `invalid params` — distinct from a tool
/// execution error, which arrives inside a successful result's
/// `isError` flag).
pub type RpcError {
  RpcError(code: Int, message: String)
}

/// One inbound line, classified. `Response` is a reply to OUR request
/// (ids are nexus-minted ints); server-initiated requests are answered
/// `method not found`; notifications are ignored; anything unparseable
/// is `Garbage` — logged and skipped, never fatal.
pub type Incoming {
  Response(id: Int, outcome: Result(Dynamic, RpcError))
  ServerRequest(id: Dynamic, method: String)
  ServerNotification(method: String)
  Garbage
}

pub fn parse_incoming(line: String) -> Incoming {
  let classified = {
    use version <- decode.optional_field(
      "jsonrpc",
      None,
      decode.optional(decode.string),
    )
    use id <- decode.optional_field("id", None, decode.optional(decode.dynamic))
    use method <- decode.optional_field(
      "method",
      None,
      decode.optional(decode.string),
    )
    use res <- decode.optional_field(
      "result",
      None,
      decode.optional(decode.dynamic),
    )
    use err <- decode.optional_field(
      "error",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(version, id, method, res, err))
  }
  case json.parse(line, classified) {
    // The spec requires `"jsonrpc":"2.0"` on EVERY frame; its absence
    // means garbage stdout (a stray log line with an unlucky "id" must
    // not complete a pending request).
    Error(_) -> Garbage
    Ok(#(None, _, _, _, _)) -> Garbage
    Ok(#(Some(v), _, _, _, _)) if v != "2.0" -> Garbage
    Ok(#(_, id, method, res, err)) ->
      case method, id {
        Some(m), Some(id_dyn) -> ServerRequest(id_dyn, m)
        Some(m), None -> ServerNotification(m)
        None, Some(id_dyn) ->
          case decode.run(id_dyn, decode.int) {
            // Not one of OUR ids (ours are ints): a server response to
            // a request nexus never sent, or a string id — dropped.
            Error(_) -> Garbage
            Ok(n) ->
              case err, res {
                Some(e), _ ->
                  Response(
                    n,
                    Error(case decode.run(e, rpc_error_decoder()) {
                      Ok(rpc) -> rpc
                      Error(_) ->
                        RpcError(
                          -32_700,
                          "unparseable error object from server",
                        )
                    }),
                  )
                None, Some(r) -> Response(n, Ok(r))
                // A response with neither result nor error is malformed.
                None, None -> Garbage
              }
          }
        None, None -> Garbage
      }
  }
}

fn rpc_error_decoder() -> decode.Decoder(RpcError) {
  use code <- decode.field("code", decode.int)
  use message <- decode.optional_field("message", "server error", decode.string)
  decode.success(RpcError(code: code, message: message))
}

// ---------------------------------------------------------------------------
// tools/list → ToolDefs (the boundary)
// ---------------------------------------------------------------------------

/// Decode a `tools/list` RESULT into validated ToolDefs plus the next
/// page cursor. EVERY entry is validated at the boundary here — the
/// name rule, the canonical-schema rule, the byte bound — because
/// these defs are what boot mounts and what create-time freezes. One
/// bad entry fails the WHOLE list (the caller degrades that server
/// loudly): a server whose catalog mixes valid and hostile entries is
/// hostile, and mounting half of it would be a silent narrowing.
pub fn decode_tools_list(
  result: Dynamic,
) -> Result(#(List(ToolDef), Option(String)), String) {
  let decoder = {
    use raw_tools <- decode.field("tools", decode.list(decode.dynamic))
    use cursor <- decode.optional_field(
      "nextCursor",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(raw_tools, cursor))
  }
  case decode.run(result, decoder) {
    Error(_) ->
      Error("tools/list result must be {tools: [...], nextCursor?: string}")
    Ok(#(raw_tools, cursor)) -> {
      use defs <- result.try(
        list.try_map(raw_tools, fn(raw) {
          tool_def_decoder(raw)
          |> result.map_error(fn(reason) { "tools/list entry: " <> reason })
        }),
      )
      // A server advertising two schemas under one name is broken or
      // hostile: the freeze would silently pick the first. Refuse the
      // page loudly.
      let names = list.map(defs, fn(def) { def.name })
      case list.length(names) == list.length(list.unique(names)) {
        True -> Ok(#(defs, cursor))
        False -> Error("duplicate tool name in tools/list page")
      }
    }
  }
}

fn tool_def_decoder(raw: Dynamic) -> Result(ToolDef, String) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use description <- decode.optional_field("description", "", decode.string)
    use schema <- decode.field("inputSchema", decode.dynamic)
    decode.success(#(name, description, schema))
  }
  case decode.run(raw, decoder) {
    Error(_) -> Error("missing name, description, or inputSchema")
    Ok(#(name, description, schema)) -> {
      use Nil <- result.try(case tool_provider.valid_name(name) {
        True -> Ok(Nil)
        False ->
          Error(
            "tool '"
            <> name
            <> "' refused: name must match ^[a-zA-Z0-9_-]+$"
            <> " with no '__' and no leading or trailing '_'",
          )
      })
      use canonical <- result.try(
        canonical_json(schema)
        |> result.map_error(fn(_) {
          "tool '" <> name <> "' refused: inputSchema must be a JSON object"
        }),
      )
      use Nil <- result.try(case tool_provider.valid_parameters(canonical) {
        True -> Ok(Nil)
        False ->
          Error(
            "tool '"
            <> name
            <> "' refused: canonical schema exceeds "
            <> int.to_string(tool_provider.max_parameters_bytes)
            <> " bytes",
          )
      })
      use Nil <- result.try(
        case
          // Both byte forms matter: a RAW NUL cannot ride the
          // envelope, and the canonical encoder emits the 6-character
          // ESCAPE sequence `\u0000` — which Postgres's json→text
          // conversion unescapes and then refuses ("\u0000 cannot be
          // converted to text"), failing a create inside the store.
          // Refuse both here, at the boundary.
          string.contains(canonical, "\u{0000}")
          || string.contains(canonical, "\\u0000")
          || string.contains(description, "\u{0000}")
        {
          True ->
            Error(
              "tool '"
              <> name
              <> "' refused: description or schema contains a NUL byte"
              <> " (cannot be frozen into a manifest)",
            )
          False -> Ok(Nil)
        },
      )
      Ok(ToolDef(
        name: name,
        description: truncate_description(description),
        parameters_json: canonical,
      ))
    }
  }
}

const truncated_marker = "… [truncated]"

fn truncate_description(description: String) -> String {
  case string.length(description) > max_description_chars {
    // The marker counts INSIDE the cap: the frozen description is
    // bounded, marker included.
    True ->
      string.slice(
        description,
        0,
        max_description_chars - string.length(truncated_marker),
      )
      <> truncated_marker
    False -> description
  }
}

// ---------------------------------------------------------------------------
// tools/call → ToolReply
// ---------------------------------------------------------------------------

/// Decode a `tools/call` RESULT into a provider reply. MCP's two error
/// channels collapse into the protocol's one: a JSON-RPC error object
/// is `ToolErr` (handled by the caller via `parse_incoming`), and an
/// `isError: true` result — a tool that ran and failed — is `ToolErr`
/// too, carrying its text content. Content blocks are flattened to
/// plain text (text blocks joined with newlines; other block types —
/// images, resource links — are announced, not inlined: nexus renders
/// text only, and hostile bytes must not slip through as anything
/// else).
pub fn decode_call_result(
  result: Dynamic,
) -> Result(tool_provider.ToolReply, String) {
  let decoder = {
    use blocks <- decode.optional_field(
      "content",
      [],
      decode.list(decode.dynamic),
    )
    use is_error <- decode.optional_field("isError", False, decode.bool)
    decode.success(#(blocks, is_error))
  }
  case decode.run(result, decoder) {
    Error(_) -> Error("tools/call result must be {content?: [...], isError?}")
    Ok(#(blocks, is_error)) -> {
      use parts <- result.try(list.try_map(blocks, content_block_text))
      let text = case parts {
        [] -> "(no content)"
        _ -> string.join(parts, "\n")
      }
      Ok(case is_error {
        True -> ToolErr(text)
        False -> ToolOk(text)
      })
    }
  }
}

fn content_block_text(raw: Dynamic) -> Result(String, String) {
  let block = {
    use kind <- decode.optional_field("type", "", decode.string)
    use text <- decode.optional_field(
      "text",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(kind, text))
  }
  case decode.run(raw, block) {
    Ok(#("text", Some(text))) -> Ok(text)
    Ok(#(kind, _)) if kind != "" -> Ok("[" <> kind <> " content omitted]")
    _ -> Ok("[unparseable content block omitted]")
  }
}

// ---------------------------------------------------------------------------
// Canonical JSON — the freeze format
// ---------------------------------------------------------------------------

/// Canonical JSON text for a decoded value: whitespace-free, object
/// keys SORTED. Determinism is the point — the text a create-time
/// freeze persists is re-encoded byte-identically on every later
/// hydration and request construction, and OTP's JSON decoder loses
/// key order, so an unsorted re-encode would drift across runs.
/// Non-OBJECT roots are refused here at the schema entry points (a
/// tool schema is always an object).
pub fn canonical_json(schema: Dynamic) -> Result(String, String) {
  case decode.run(schema, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> Error("not a JSON object")
    Ok(entries) ->
      canon_object(dict.to_list(entries))
      |> json.to_string
      |> Ok
  }
}

/// Canonicalize any JSON text (used for tool-call arguments): parse
/// then canonicalize, refusing non-objects.
pub fn canonical_json_text(text: String) -> Result(String, String) {
  case json.parse(text, decode.dynamic) {
    Error(_) -> Error("arguments are not valid JSON")
    Ok(dynamic) -> canonical_json(dynamic)
  }
}

/// Canonicalize any JSON value, any root (the id echo path: scalar
/// roots legal). Null on the unparseable backstop keeps it total.
pub fn canonical_json_any(value: Dynamic) -> String {
  canon_value(value)
  |> json.to_string
}

fn canon_object(entries: List(#(String, Dynamic))) -> json.Json {
  entries
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(entry) { #(entry.0, canon_value(entry.1)) })
  |> json.object
}

fn canon_value(value: Dynamic) -> json.Json {
  // Null first (decode.optional maps null to None), then scalars,
  // then the two containers — recursion through decode.dynamic. Each
  // rung distinguishes "matched" from "not this shape" explicitly;
  // the final rung is the object (garbage cannot arise — every byte
  // came from a JSON parse — so the dict decoder's failure backstop
  // is unreachable but keeps the function total).
  case decode.run(value, decode.optional(decode.bool)) {
    Ok(None) -> json.null()
    Ok(Some(b)) -> json.bool(b)
    Error(_) -> canon_rest(value)
  }
}

fn canon_rest(value: Dynamic) -> json.Json {
  case decode.run(value, decode.int) {
    Ok(i) -> json.int(i)
    Error(_) ->
      case decode.run(value, decode.float) {
        Ok(f) -> json.float(f)
        Error(_) -> canon_rest2(value)
      }
  }
}

fn canon_rest2(value: Dynamic) -> json.Json {
  case decode.run(value, decode.string) {
    Ok(s) -> json.string(s)
    Error(_) -> canon_rest3(value)
  }
}

fn canon_rest3(value: Dynamic) -> json.Json {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) -> json.preprocessed_array(list.map(items, canon_value))
    Error(_) -> canon_or_null(value)
  }
}

fn canon_or_null(value: Dynamic) -> json.Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) -> canon_object(dict.to_list(entries))
    Error(_) -> json.null()
  }
}

// ---------------------------------------------------------------------------
// The bounded line reader
// ---------------------------------------------------------------------------

/// One inbound line, as the reader emits it.
pub type Frame {
  /// A complete newline-terminated frame (UTF-8 decoded).
  Line(String)
  /// A frame the byte cap cut off — refused, never accumulated.
  TooBig
  /// Bytes that were not UTF-8 (the spec requires UTF-8) — dropped.
  NotUtf8
}

/// Accumulates stdin bytes and emits complete lines. The cap is
/// enforced WHILE READING, before any concatenation: the running
/// buffer is split first (so complete frames already inside it are
/// emitted), and a tail at or over `max_frame_bytes` is refused
/// (`TooBig`) and DROPPED before the new chunk is ever appended — the
/// live buffer therefore never exceeds the cap plus ONE inbound port
/// chunk (whose size is the OS driver's read buffer, not ours to
/// bound). A hostile stream of never-terminated garbage cannot grow
/// memory without bound.
pub opaque type Feed {
  Feed(buf: BitArray)
}

pub fn new_feed() -> Feed {
  Feed(<<>>)
}

pub fn feed(f: Feed, chunk: BitArray) -> #(List(Frame), Feed) {
  let Feed(buf) = f
  do_feed(buf, chunk, [])
}

fn do_feed(
  buf: BitArray,
  chunk: BitArray,
  acc: List(Frame),
) -> #(List(Frame), Feed) {
  // Split the OLD buffer first: its complete frames were received
  // before anything in `chunk` and must not be dropped with a refused
  // tail.
  let #(lines, tail) = take_lines(buf)
  let acc = collect_lines(lines, acc)
  case bit_array.byte_size(tail) >= max_frame_bytes {
    True ->
      // The running frame is over the cap: refuse it, then start the
      // new chunk on a FRESH buffer (recursing bounds that pass the
      // same way — the chunk's own complete lines survive, its tail is
      // checked again).
      case chunk {
        <<>> -> #(list.append(list.reverse(acc), [TooBig]), Feed(<<>>))
        _ -> do_feed(<<>>, chunk, [TooBig, ..acc])
      }
    False -> {
      // Safe to concatenate: tail < cap, so the sum is bounded by the
      // cap plus one inbound chunk.
      let #(more, rest) = take_lines(bit_array.append(tail, chunk))
      let acc = collect_lines(more, acc)
      case bit_array.byte_size(rest) > max_frame_bytes {
        True -> #(list.append(list.reverse(acc), [TooBig]), Feed(<<>>))
        False -> #(list.reverse(acc), Feed(rest))
      }
    }
  }
}

fn collect_lines(lines: List(BitArray), acc: List(Frame)) -> List(Frame) {
  list.fold(lines, acc, fn(acc, line) {
    case bit_array.byte_size(line) > max_frame_bytes {
      True -> [TooBig, ..acc]
      False ->
        case bit_array.to_string(line) {
          Ok(s) -> [Line(s), ..acc]
          Error(_) -> [NotUtf8, ..acc]
        }
    }
  })
}

@external(erlang, "nexus_mcp_ffi", "take_lines")
fn take_lines(buf: BitArray) -> #(List(BitArray), BitArray)

// ---------------------------------------------------------------------------
// The transport seam
// ---------------------------------------------------------------------------

/// One transport event the adapter's selector receives.
pub type TransportEvent {
  /// Raw stdin bytes from the child (framing happens in the adapter,
  /// through `Feed`, so tests can feed bytes directly).
  Chunk(BitArray)
  /// The child process exited with this status code.
  Exited(Int)
}

/// How the adapter actor talks to its server. `arm` contributes the
/// transport's inbound pipe to the actor's selector — `events` is an
/// ACTOR-OWNED subject the adapter creates for the transport (the
/// subject-owner rule: only the actor may receive on it, so a fake
/// transport gets it handed over exactly like the `gated_runner` gate —
/// the test asks for it via `start_probing` and answers through it) —
/// and `wrap` lifts each event into the actor's message type. The real
/// transport wraps a BEAM port (see `nexus_mcp_ffi`) and ignores
/// `events` (port records arrive in the mailbox directly); tests
/// substitute an in-memory fake, so the actor's whole state machine —
/// handshake, calls, cancellation, death — is offline-provable.
pub type Transport(msg) {
  Transport(
    send_line: fn(String) -> Result(Nil, String),
    arm: fn(
      Subject(TransportEvent),
      process.Selector(msg),
      fn(TransportEvent) -> msg,
    ) -> process.Selector(msg),
  )
}

/// The real stdio transport: spawn the server as a child process with
/// its stdio wired to a BEAM port. `exit_status` means the child's
/// death arrives as a `TransportEvent.Exited` message instead of an
/// exit signal — the adapter actor degrades honestly and stays up
/// (a nexus restart is the retry). A spawn failure (bad command, no
/// PATH hit) is an `Error` the caller turns into a loudly-logged,
/// degraded server — an unconfigured machine must still boot.
pub fn stdio(
  command command: String,
  args args: List(String),
  env env: List(#(String, String)),
) -> Result(Transport(a), String) {
  case ffi_open_port(command, args, env) {
    Error(_) -> Error("spawn failed: " <> command)
    Ok(p) -> {
      let send = fn(line: String) {
        case ffi_send_line(p, line) {
          Ok(Nil) -> Ok(Nil)
          Error(_) -> Error("server stdin is closed")
        }
      }
      Ok(
        Transport(send_line: send, arm: fn(_events, selector, wrap) {
          process.select_record(
            selector,
            tag: p,
            fields: 1,
            mapping: fn(message) { wrap(decode_message(message)) },
          )
        }),
      )
    }
  }
}

fn decode_message(message: Dynamic) -> TransportEvent {
  let inner = {
    use kind <- decode.field(0, atom.decoder())
    case atom.to_string(kind) {
      "data" -> {
        use bytes <- decode.field(1, decode.bit_array)
        decode.success(Chunk(bytes))
      }
      "exit_status" -> {
        use code <- decode.field(1, decode.int)
        decode.success(Exited(code))
      }
      _ -> decode.failure(Chunk(<<>>), "TransportEvent")
    }
  }
  // The port message is {Port, Inner}: extract Inner (element 1),
  // then classify it. Anything else matching the tag is treated as an
  // empty chunk (harmless).
  let inner_dyn =
    decode.run(message, decode.field(1, decode.dynamic, decode.success))
  case inner_dyn {
    Ok(d) ->
      case decode.run(d, inner) {
        Ok(event) -> event
        Error(_) -> Chunk(<<>>)
      }
    Error(_) -> Chunk(<<>>)
  }
}

@external(erlang, "nexus_mcp_ffi", "open_port")
fn ffi_open_port(
  command: String,
  args: List(String),
  env: List(#(String, String)),
) -> Result(Port, String)

@external(erlang, "nexus_mcp_ffi", "send_line")
fn ffi_send_line(port: Port, line: String) -> Result(Nil, String)
