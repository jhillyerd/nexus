//// The transport seam: the single module that moves bytes to and from a
//// Bifrost (OpenAI-compatible) endpoint.
////
//// Design (from the M0 plan, §5):
////
//// - Requests are always built through `nexus/transcript.to_request`, so
////   every caller (the TTFT audit tool, and the thread server) encodes
////   identically — the precondition for the audit's byte-stability evidence.
//// - Streaming uses hackney's async messages directly so the request can set
////   `recv_timeout` above `NEXUS_STREAM_IDLE_TIMEOUT_MS`; the buffered
////   helpers otherwise hard-wire hackney's five-second default and close
////   during reasoning gaps. Nexus parses SSE frames in this module and
////   retains typed transport errors.
//// - Non-200 detection works in two layers: a buffered `list_models`
////   preflight (real status, cheap), and a stream that closes with zero
////   parsed events is re-sent **buffered once** to capture the true
////   status/body before failing.
//// - First-response and idle timeouts are enforced by one selector that also
////   receives cancellation, preserving the thread stop mechanism.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{type Method}
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import glopenai/chat
import glopenai/config.{type Config as OpenAiConfig} as oai_config
import glopenai/model
import glopenai/shared.{type CompletionUsage}
import nexus/hackney
import nexus/timing
import nexus/transcript.{type Options, type Transcript}

@external(erlang, "nexus_boot_ffi", "ensure_hackney_started")
fn ensure_hackney_started() -> Result(Nil, String)

/// Typed events forwarded to the caller's callback during a stream.
pub type StreamEvent {
  /// A fragment of assistant text content.
  TokenDelta(text: String)
  /// A fragment of the model's reasoning (chain of thought) — emitted by
  /// reasoning models before any content/tool output. Decoded here
  /// because glopenai 1.0.0's delta decoder drops the non-standard
  /// `reasoning_content` / `reasoning` fields.
  ReasoningDelta(text: String)
  /// A fragment of a native tool call, still unassembled.
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    args_fragment: String,
  )
  /// Final usage block, when the backend emits one (needs
  /// `stream_options.include_usage` — see caveats in the verdict doc).
  Usage(usage: CompletionUsage)
}

pub type StreamStats {
  StreamStats(
    /// Send → first reasoning/content/tool delta, ms — reasoning models
    /// lead with chain of thought, so the clock starts there.
    /// `None` if no output arrived.
    ttft_ms: Option(Int),
    duration_ms: Int,
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
    /// SSE events that decoded into stream chunks.
    events_parsed: Int,
    /// SSE events that failed to decode (kept, not fatal).
    decode_errors: Int,
    /// Whether the `[DONE]` sentinel was observed.
    saw_done: Bool,
    /// Latest usage block seen on any stream chunk (usually only sent
    /// with `stream_options.include_usage`, which glopenai cannot request;
    /// see verdict doc findings 1 and 8).
    usage: Option(CompletionUsage),
  )
}

pub type StreamError {
  Non200(status: Int, body: String)
  Transport(reason: String)
  Decode(reason: String)
}

/// Runtime identity of one OpenAI-compatible endpoint: where to send, how
/// to authenticate, and the stream timeouts to enforce. Deliberately
/// narrow — the server resolves one per thread from the provider
/// registry (frozen at thread creation), while standalone tools (the
/// TTFT audit harness) build it from their own configuration and never
/// touch the server config surface.
pub type Endpoint {
  Endpoint(
    /// OpenAI-compatible base URL including the `/v1` suffix.
    base_url: String,
    /// Bearer key; `None` targets keyless local endpoints.
    api_key: Option(String),
    /// SSE first-response (status/headers) timeout in ms.
    sse_first_response_timeout_ms: Int,
    /// Receive timeout between SSE events mid-stream, in ms.
    stream_idle_timeout_ms: Int,
  )
}

/// Buffered `GET /v1/models` — doubles as preflight (validates URL + auth
/// with a real status code) and as the Bifrost sanity check.
pub fn list_models(endpoint: Endpoint) -> Result(List(String), StreamError) {
  use <- ensure_boot()
  let req =
    model.list_request(to_openai_config(endpoint))
    |> drop_empty_bearer(endpoint)
  use response <- result.try(
    hackney.send(req) |> result.map_error(fn(e) { Transport(send_error(e)) }),
  )
  case response.status {
    200 ->
      // Bifrost finding (live, spike A preflight): its /v1/models omits the
      // per-entry `object` field real OpenAI sends, and glopenai 1.0.0's
      // `model.list_response` decoder requires it — decode the Bifrost alias (falling back to id) here.
      case json.parse(response.body, using: model_ids_decoder()) {
        Ok(ids) -> Ok(list.unique(ids))
        Error(errors) -> Error(Decode(string.inspect(errors)))
      }
    status -> Error(Non200(status, snippet(response.body)))
  }
}

fn model_ids_decoder() -> decode.Decoder(List(String)) {
  use data <- decode.field("data", decode.list(id_decoder()))
  decode.success(data)
}

fn id_decoder() -> decode.Decoder(String) {
  use id <- decode.field("id", decode.string)
  use alias <- decode.optional_field(
    "alias",
    None,
    decode.optional(decode.string),
  )
  case alias {
    Some(name) -> decode.success(name)
    None -> decode.success(id)
  }
}

/// Stream a chat completion for `transcript`, forwarding typed events to
/// `on_event` as they arrive, and returning aggregate stats on success.
pub fn stream(
  endpoint: Endpoint,
  transcript: Transcript,
  opts: Options,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(StreamStats, StreamError) {
  // Cancellable machinery with a cancel subject nobody else holds: exit
  // trapping and the selector receive still apply (verdict finding 9
  // hardening — a crashing SSE handler becomes a typed error instead of an
  // untrapped exit killing this process), but cancellation itself never
  // fires, so the audit tool keeps its exact previous semantics.
  case
    stream_with_cancel(
      endpoint,
      transcript,
      opts,
      on_event,
      process.new_subject(),
    )
  {
    Completed(stats) -> Ok(stats)
    Cancelled -> Error(Transport("cancelled without a cancel signal (bug)"))
    Failed(e) -> Error(e)
  }
}

/// Outcome of a cancellable stream: success with stats, a clean stop, or a
/// typed failure. M1's thread turn workers consume this directly.
pub type StreamOutcome {
  Completed(StreamStats)
  Cancelled
  Failed(StreamError)
}

/// Like `stream`, but stoppable: sending `Nil` on `cancel` (from any
/// process) stops the stream at the next receive boundary, shuts the SSE
/// actor down, and returns `Cancelled`. The cancel subject must be owned by
/// the process calling this function (selector receive semantics).
pub fn stream_with_cancel(
  endpoint: Endpoint,
  transcript: Transcript,
  opts: Options,
  on_event: fn(StreamEvent) -> Nil,
  cancel: Subject(Nil),
) -> StreamOutcome {
  case ensure_hackney_started() {
    Ok(_) -> {
      let req =
        chat.create_request(
          to_openai_config(endpoint),
          transcript.to_request(transcript, opts),
        )
        |> drop_empty_bearer(endpoint)
      stream_request(endpoint, req, on_event, cancel)
    }
    Error(reason) ->
      Failed(Transport("failed to start hackney: " <> string.inspect(reason)))
  }
}

@external(erlang, "nexus_boot_ffi", "hackney_stream_start")
fn hackney_stream_start(
  method: Method,
  url: String,
  headers: List(#(String, String)),
  body: bytes_tree.BytesTree,
  recv_timeout_ms: Int,
) -> Result(hackney.HackneyResponse, hackney.Error)

fn stream_request(
  endpoint: Endpoint,
  req: Request(String),
  on_event: fn(StreamEvent) -> Nil,
  cancel: Subject(Nil),
) -> StreamOutcome {
  case ensure_hackney_started() {
    Error(reason) ->
      Failed(Transport("failed to start hackney: " <> string.inspect(reason)))
    Ok(Nil) -> {
      let bytes_req = request.map(req, bytes_tree.from_string)
      let url = bytes_req |> request.to_uri |> uri.to_string
      // nexus/hackney's buffered send does not expose hackney's
      // recv_timeout option. Supply it here so
      // a reasoning model can remain silent for the configured idle interval
      // without hackney's five-second default closing the socket.
      let hackney_timeout = endpoint.stream_idle_timeout_ms + 5000
      case
        hackney_stream_start(
          bytes_req.method,
          url,
          bytes_req.headers,
          bytes_req.body,
          hackney_timeout,
        )
      {
        Error(error) ->
          Failed(Transport("failed to start stream: " <> send_error(error)))
        Ok(hackney.AsyncResponse(ref)) -> {
          let selector =
            process.new_selector()
            |> hackney.selecting_http_message(fn(_, message) {
              LoopHttp(message)
            })
            |> process.select_map(cancel, fn(_) { LoopCancel })
          let started_us = timing.now_us()
          let outcome =
            raw_stream_loop(
              selector,
              endpoint.sse_first_response_timeout_ms,
              endpoint.stream_idle_timeout_ms,
              on_event,
              Streaming(headers_received: False, feeder: new_feeder(started_us)),
            )
          let _ = hackney.close(ref)
          case outcome {
            LoopEnded(acc) ->
              case finish_stream(req, started_us, acc, on_event) {
                Ok(stats) -> Completed(stats)
                Error(error) -> Failed(error)
              }
            LoopTimedOut(reason) -> Failed(reason)
            LoopCancelled -> Cancelled
          }
        }
        Ok(_) ->
          Failed(Transport("stream start returned an unexpected response"))
      }
    }
  }
}

type LoopMsg {
  LoopHttp(hackney.HackneyMessage)
  LoopCancel
}

type LoopOutcome {
  LoopEnded(Acc)
  LoopTimedOut(StreamError)
  LoopCancelled
}

type StreamMode {
  Streaming(headers_received: Bool, feeder: StreamFeeder)
  Non200Body(status: Int, body: BitArray)
}

/// Maximum size in bytes of one SSE event (or unfinished event buffer) before
/// `feed_bytes` fails with a `Transport` error. Bounds memory and rescanning
/// work against an upstream that streams bytes without `\n\n`, while allowing
/// a single transport chunk to carry many complete events.
pub const max_sse_event_bytes = 1_048_576

const max_error_body_bytes = 1600

/// Pure, byte-level SSE stream feeder: carries incomplete multi-byte UTF-8
/// trailing bytes across TCP chunks, strips at most one leading UTF-8 BOM,
/// normalizes `\r\n` / `\r` line endings across chunk boundaries, bounds
/// unfinished event buffering, extracts complete SSE frames, and folds decoded
/// payloads into `Acc`.
///
/// Used directly by `raw_stream_loop` and exported so offline property and
/// dialect tests exercise the exact production wire-parsing path.
pub opaque type StreamFeeder {
  StreamFeeder(
    started: Bool,
    pending_utf8: BitArray,
    pending_cr: Bool,
    buffer: String,
    acc: Acc,
  )
}

/// Create a fresh byte-level SSE feeder stamped with `started_us`.
pub fn new_feeder(started_us: Int) -> StreamFeeder {
  StreamFeeder(
    started: False,
    pending_utf8: <<>>,
    pending_cr: False,
    buffer: "",
    acc: Acc(
      started_us: started_us,
      ttft_us: None,
      token_deltas: 0,
      reasoning_deltas: 0,
      tool_call_deltas: 0,
      events_parsed: 0,
      decode_errors: 0,
      saw_done: False,
      saw_finish: False,
      first_decode_error: None,
      usage: None,
    ),
  )
}

/// Read the underlying stats accumulator from a `StreamFeeder`.
pub fn feeder_acc(feeder: StreamFeeder) -> Acc {
  feeder.acc
}

/// Feed one raw byte chunk into `feeder` at monotonic timestamp `now_us`,
/// forwarding any decoded `StreamEvent`s to `on_event`.
///
/// Incomplete multi-byte UTF-8 sequences at the end of `bits` are carried into
/// the next call; invalid UTF-8 bytes or events exceeding `max_sse_event_bytes`
/// fail immediately with `Transport`.
pub fn feed_bytes(
  feeder: StreamFeeder,
  bits: BitArray,
  now_us: Int,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(StreamFeeder, StreamError) {
  let combined = case bit_array.byte_size(feeder.pending_utf8) {
    0 -> bits
    _ -> bit_array.append(feeder.pending_utf8, bits)
  }
  case decode_utf8_prefix(combined) {
    Error(Nil) -> Error(Transport("stream contained non-UTF-8 bytes"))
    Ok(#(decoded, next_pending_utf8)) -> {
      let #(incoming, next_started) = strip_leading_bom(feeder.started, decoded)
      let #(normalized, next_pending_cr) =
        normalize_line_endings(feeder.pending_cr, incoming)
      let pending_utf8_len = bit_array.byte_size(next_pending_utf8)
      case
        parse_sse_bounded(
          feeder.buffer,
          normalized,
          pending_utf8_len,
          now_us,
          feeder.acc,
          on_event,
        )
      {
        Error(err) -> Error(err)
        Ok(#(next_buffer, next_acc)) ->
          Ok(StreamFeeder(
            started: next_started,
            pending_utf8: next_pending_utf8,
            pending_cr: next_pending_cr,
            buffer: next_buffer,
            acc: next_acc,
          ))
      }
    }
  }
}

/// Finalize a `StreamFeeder` at EOF (`ended_us`), enforcing trailing incomplete
/// UTF-8 rejection, decode-error classification, and truncation checks.
/// Pure and network-free (live HTTP streams with zero events and no decode
/// error separately run the buffered status probe in `finish_stream`).
pub fn finish_feeder(
  feeder: StreamFeeder,
  ended_us: Int,
) -> Result(StreamStats, StreamError) {
  case bit_array.byte_size(feeder.pending_utf8) > 0 {
    True -> Error(Transport("stream contained non-UTF-8 bytes"))
    False -> {
      let acc = feeder.acc
      let stats = build_stats(acc.started_us, ended_us, acc)
      case classify_eof(acc, stats) {
        EofClean(final_stats) -> Ok(final_stats)
        EofFailed(error) -> Error(error)
        EofEmptyNoDecodeError -> Error(Transport("stream produced no events"))
      }
    }
  }
}

fn raw_stream_loop(
  selector: process.Selector(LoopMsg),
  first_response_timeout_ms: Int,
  idle_timeout_ms: Int,
  on_event: fn(StreamEvent) -> Nil,
  mode: StreamMode,
) -> LoopOutcome {
  let timeout = case mode {
    Streaming(headers_received: False, ..) -> first_response_timeout_ms
    Streaming(headers_received: True, ..) | Non200Body(..) -> idle_timeout_ms
  }
  case process.selector_receive(selector, timeout) {
    Error(Nil) ->
      case mode {
        Non200Body(status, body) ->
          LoopTimedOut(Non200(status, non200_snippet(body)))
        Streaming(headers_received: True, ..) ->
          LoopTimedOut(Transport(
            "idle timeout: no sse event within "
            <> int.to_string(idle_timeout_ms)
            <> " ms",
          ))
        Streaming(headers_received: False, ..) ->
          LoopTimedOut(Transport(
            "first response timeout: no status/headers within "
            <> int.to_string(first_response_timeout_ms)
            <> " ms",
          ))
      }
    Ok(LoopCancel) -> LoopCancelled
    Ok(LoopHttp(hackney.Status(200))) -> {
      let next_mode = case mode {
        Streaming(_, feeder) ->
          Streaming(headers_received: True, feeder: feeder)
        Non200Body(..) -> mode
      }
      raw_stream_loop(
        selector,
        first_response_timeout_ms,
        idle_timeout_ms,
        on_event,
        next_mode,
      )
    }
    Ok(LoopHttp(hackney.Status(status))) ->
      raw_stream_loop(
        selector,
        first_response_timeout_ms,
        idle_timeout_ms,
        on_event,
        Non200Body(status: status, body: <<>>),
      )
    Ok(LoopHttp(hackney.Headers(_))) -> {
      let next_mode = case mode {
        Streaming(_, feeder) ->
          Streaming(headers_received: True, feeder: feeder)
        Non200Body(..) -> mode
      }
      raw_stream_loop(
        selector,
        first_response_timeout_ms,
        idle_timeout_ms,
        on_event,
        next_mode,
      )
    }
    Ok(LoopHttp(hackney.Binary(bits))) ->
      case mode {
        Streaming(_, feeder) ->
          case feed_bytes(feeder, bits, timing.now_us(), on_event) {
            Error(err) -> LoopTimedOut(err)
            Ok(next_feeder) ->
              raw_stream_loop(
                selector,
                first_response_timeout_ms,
                idle_timeout_ms,
                on_event,
                Streaming(headers_received: True, feeder: next_feeder),
              )
          }
        Non200Body(status, body) -> {
          let next_body = append_bounded_bytes(body, bits, max_error_body_bytes)
          case bit_array.byte_size(next_body) >= max_error_body_bytes {
            True -> LoopTimedOut(Non200(status, non200_snippet(next_body)))
            False ->
              raw_stream_loop(
                selector,
                first_response_timeout_ms,
                idle_timeout_ms,
                on_event,
                Non200Body(status: status, body: next_body),
              )
          }
        }
      }
    Ok(LoopHttp(hackney.DoneStreaming)) ->
      case mode {
        Non200Body(status, body) ->
          LoopTimedOut(Non200(status, non200_snippet(body)))
        Streaming(_, feeder) ->
          case bit_array.byte_size(feeder.pending_utf8) > 0 {
            True -> LoopTimedOut(Transport("stream contained non-UTF-8 bytes"))
            False -> LoopEnded(feeder.acc)
          }
      }
    Ok(LoopHttp(hackney.NotDecoded(reason))) ->
      LoopTimedOut(Transport(
        "upstream stream error: " <> string.inspect(reason),
      ))
    Ok(LoopHttp(hackney.Redirect(..))) | Ok(LoopHttp(hackney.SeeOther(..))) ->
      LoopTimedOut(Transport("unexpected redirect from stream endpoint"))
  }
}

fn append_bounded_bytes(
  acc: BitArray,
  chunk: BitArray,
  max_bytes: Int,
) -> BitArray {
  let have = bit_array.byte_size(acc)
  case have >= max_bytes {
    True -> acc
    False -> {
      let room = max_bytes - have
      case bit_array.byte_size(chunk) <= room {
        True -> bit_array.append(acc, chunk)
        False ->
          case bit_array.slice(chunk, 0, room) {
            Ok(prefix) -> bit_array.append(acc, prefix)
            Error(Nil) -> acc
          }
      }
    }
  }
}

fn non200_snippet(body: BitArray) -> String {
  case decode_utf8_prefix(body) {
    Ok(#(text, _incomplete_tail)) -> snippet(text)
    Error(Nil) -> snippet(string.inspect(body))
  }
}

/// Fold one SSE data payload: decode + forward any reasoning fragment,
/// then the glopenai chunk. Public (and side-effect-free beyond `on_event`)
/// so the reasoning-aware decode/fold is offline-testable.
pub fn handle_data(
  data: String,
  now_us: Int,
  acc: Acc,
  on_event: fn(StreamEvent) -> Nil,
) -> Acc {
  case data {
    "" -> acc
    _ -> {
      // Reasoning rides outside glopenai's chunk type (1.0.0 has no
      // reasoning fields), so it is decoded from the raw data first:
      // DeepSeek-R1 / vLLM style `delta.reasoning_content`, OpenRouter
      // style `delta.reasoning`. Emitted BEFORE the chunk's own events so
      // ordering matches the wire (reasoning precedes content).
      let acc = case decode_reasoning(data) {
        Some(text) if text != "" -> {
          on_event(ReasoningDelta(text))
          Acc(
            ..acc,
            reasoning_deltas: acc.reasoning_deltas + 1,
            ttft_us: Some(acc.ttft_us |> option.unwrap(now_us)),
          )
        }
        _ -> acc
      }
      case chat.parse_stream_chunk(data) {
        Ok(None) -> Acc(..acc, saw_done: True)
        Ok(Some(chunk)) -> handle_chunk(chunk, now_us, acc, on_event)
        Error(decode_error) ->
          Acc(
            ..acc,
            decode_errors: acc.decode_errors + 1,
            first_decode_error: Some(option.unwrap(
              acc.first_decode_error,
              string.inspect(decode_error),
            )),
          )
      }
    }
  }
}

fn decode_utf8_prefix(bytes: BitArray) -> Result(#(String, BitArray), Nil) {
  case bit_array.to_string(bytes) {
    Ok(text) -> Ok(#(text, <<>>))
    Error(Nil) -> {
      let total = bit_array.byte_size(bytes)
      try_utf8_split(bytes, total, 1)
      |> result.lazy_or(fn() { try_utf8_split(bytes, total, 2) })
      |> result.lazy_or(fn() { try_utf8_split(bytes, total, 3) })
    }
  }
}

fn try_utf8_split(
  bytes: BitArray,
  total: Int,
  tail_len: Int,
) -> Result(#(String, BitArray), Nil) {
  case tail_len <= total {
    False -> Error(Nil)
    True -> {
      let head_len = total - tail_len
      use tail <- result.try(bit_array.slice(bytes, head_len, tail_len))
      case is_incomplete_utf8_prefix(tail) {
        False -> Error(Nil)
        True -> {
          use head <- result.try(bit_array.slice(bytes, 0, head_len))
          use text <- result.try(bit_array.to_string(head))
          Ok(#(text, tail))
        }
      }
    }
  }
}

fn is_incomplete_utf8_prefix(tail: BitArray) -> Bool {
  case tail {
    <<b0:8>> -> b0 >= 0xC2 && b0 <= 0xF4
    <<b0:8, b1:8>> -> is_valid_utf8_2_of_3_or_4(b0, b1)
    <<b0:8, b1:8, b2:8>> -> is_valid_utf8_2_of_4(b0, b1) && is_utf8_cont(b2)
    _ -> False
  }
}

fn is_utf8_cont(byte: Int) -> Bool {
  byte >= 0x80 && byte <= 0xBF
}

fn is_valid_utf8_2_of_4(b0: Int, b1: Int) -> Bool {
  case b0 {
    0xF0 -> b1 >= 0x90 && b1 <= 0xBF
    0xF1 | 0xF2 | 0xF3 -> is_utf8_cont(b1)
    0xF4 -> b1 >= 0x80 && b1 <= 0x8F
    _ -> False
  }
}

fn is_valid_utf8_2_of_3_or_4(b0: Int, b1: Int) -> Bool {
  case b0 {
    0xE0 -> b1 >= 0xA0 && b1 <= 0xBF
    0xED -> b1 >= 0x80 && b1 <= 0x9F
    0xE1
    | 0xE2
    | 0xE3
    | 0xE4
    | 0xE5
    | 0xE6
    | 0xE7
    | 0xE8
    | 0xE9
    | 0xEA
    | 0xEB
    | 0xEC
    | 0xEE
    | 0xEF -> is_utf8_cont(b1)
    _ -> is_valid_utf8_2_of_4(b0, b1)
  }
}

fn strip_leading_bom(started: Bool, incoming: String) -> #(String, Bool) {
  case started, incoming {
    True, _ -> #(incoming, True)
    False, "" -> #("", False)
    False, "\u{FEFF}" <> rest -> #(rest, True)
    False, _ -> #(incoming, True)
  }
}

fn normalize_line_endings(
  pending_cr: Bool,
  incoming: String,
) -> #(String, Bool) {
  case incoming {
    "" -> #("", pending_cr)
    _ -> {
      let rest = case pending_cr, incoming {
        True, "\n" <> tail -> tail
        _, _ -> incoming
      }
      let next_pending_cr = string.ends_with(rest, "\r")
      let normalized =
        rest
        |> string.replace("\r\n", "\n")
        |> string.replace("\r", "\n")
      #(normalized, next_pending_cr)
    }
  }
}

fn parse_sse_bounded(
  buffer: String,
  normalized: String,
  pending_utf8_len: Int,
  now_us: Int,
  acc: Acc,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(#(String, Acc), StreamError) {
  case normalized {
    "" ->
      case string.byte_size(buffer) + pending_utf8_len > max_sse_event_bytes {
        True -> Error(Transport("sse event exceeded maximum buffer size"))
        False -> Ok(#(buffer, acc))
      }
    _ -> {
      let full = buffer <> normalized
      let parts = string.split(full, "\n\n")
      case list.reverse(parts) {
        [next_buffer, ..rev_frames] -> {
          use next_acc <- result.try(fold_bounded_frames(
            list.reverse(rev_frames),
            now_us,
            acc,
            on_event,
          ))
          case
            string.byte_size(next_buffer) + pending_utf8_len
            > max_sse_event_bytes
          {
            True -> Error(Transport("sse event exceeded maximum buffer size"))
            False -> Ok(#(next_buffer, next_acc))
          }
        }
        [] -> Ok(#("", acc))
      }
    }
  }
}

fn fold_bounded_frames(
  frames: List(String),
  now_us: Int,
  acc: Acc,
  on_event: fn(StreamEvent) -> Nil,
) -> Result(Acc, StreamError) {
  case frames {
    [] -> Ok(acc)
    [frame, ..rest] ->
      case string.byte_size(frame) > max_sse_event_bytes {
        True -> Error(Transport("sse event exceeded maximum buffer size"))
        False -> {
          let next_acc = case frame_data(frame) {
            Ok(data) -> handle_data(data, now_us, acc, on_event)
            Error(Nil) -> acc
          }
          fold_bounded_frames(rest, now_us, next_acc, on_event)
        }
      }
  }
}

fn frame_data(frame: String) -> Result(String, Nil) {
  frame
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(line, "data:") {
      True ->
        case string.drop_start(line, 5) {
          " " <> value -> Ok(value)
          value -> Ok(value)
        }
      False -> Error(Nil)
    }
  })
  |> data_lines_value
}

fn data_lines_value(data_lines: List(String)) -> Result(String, Nil) {
  case data_lines {
    [] -> Error(Nil)
    _ -> Ok(string.join(data_lines, "\n"))
  }
}

/// Decode the reasoning fragment of one SSE data payload, if any.
/// Tolerant by design: a payload without reasoning fields (or a non-JSON
/// one like the `[DONE]` sentinel) decodes to `None`; the glopenai chunk
/// decoder remains the authority on malformed payloads.
fn decode_reasoning(data: String) -> Option(String) {
  case json.parse(data, using: chunk_reasoning_decoder()) {
    Ok(reasoning) -> reasoning
    Error(_) -> None
  }
}

fn chunk_reasoning_decoder() -> decode.Decoder(Option(String)) {
  use choices <- decode.optional_field(
    "choices",
    [],
    decode.list(delta_reasoning_decoder()),
  )
  decode.success(case choices {
    [first, ..] -> first
    [] -> None
  })
}

fn delta_reasoning_decoder() -> decode.Decoder(Option(String)) {
  use delta <- decode.optional_field(
    "delta",
    None,
    decode.optional(reasoning_text_decoder()),
  )
  decode.success(option.unwrap(delta, None))
}

fn reasoning_text_decoder() -> decode.Decoder(Option(String)) {
  use reasoning_content <- decode.optional_field(
    "reasoning_content",
    None,
    decode.optional(decode.string),
  )
  use reasoning <- decode.optional_field(
    "reasoning",
    None,
    decode.optional(decode.string),
  )
  decode.success(option.or(reasoning_content, reasoning))
}

/// Accumulator threaded through the stream loop. Public so the per-chunk
/// fold (`handle_chunk`) is offline-testable.
pub type Acc {
  Acc(
    started_us: Int,
    ttft_us: Option(Int),
    token_deltas: Int,
    reasoning_deltas: Int,
    tool_call_deltas: Int,
    events_parsed: Int,
    decode_errors: Int,
    saw_done: Bool,
    /// True once any choice delta carried a non-empty `finish_reason`
    /// (`stop`, `tool_calls`, `length`, etc.). Together with `saw_done`,
    /// distinguishes a clean completion from a truncated mid-stream TCP drop.
    saw_finish: Bool,
    first_decode_error: Option(String),
    /// Latest usage block seen on any chunk.
    usage: Option(CompletionUsage),
  )
}

/// Fold one decoded stream chunk into the accumulator, forwarding typed
/// events (`TokenDelta` / `ToolCallDelta` / `Usage`) to `on_event` as they
/// are recognised. Public and side-effect-free (beyond `on_event`) so the
/// decode/fold logic is offline-testable.
pub fn handle_chunk(
  chunk: chat.CreateChatCompletionStreamResponse,
  now_us: Int,
  acc: Acc,
  on_event: fn(StreamEvent) -> Nil,
) -> Acc {
  let acc = Acc(..acc, events_parsed: acc.events_parsed + 1)
  // Usage may ride on any chunk (typically the final one, and usually
  // only when the backend is asked via stream_options.include_usage).
  // Forward it as an event and keep the latest: the audit tool's
  // cached_tokens evidence depends on this (verdict doc finding 8).
  // Regression-guarded by test/openai_test.gleam after the PR #3 review
  // caught it being silently dropped.
  let acc = case chunk.usage {
    Some(usage) -> {
      on_event(Usage(usage))
      Acc(..acc, usage: Some(usage))
    }
    None -> acc
  }
  list.fold(chunk.choices, acc, fn(acc, choice) {
    let acc = case choice.finish_reason {
      Some(_) -> Acc(..acc, saw_finish: True)
      None -> acc
    }
    let acc = case choice.delta.content {
      Some(text) if text != "" -> {
        on_event(TokenDelta(text))
        Acc(
          ..acc,
          token_deltas: acc.token_deltas + 1,
          ttft_us: Some(acc.ttft_us |> option.unwrap(now_us)),
        )
      }
      _ -> acc
    }
    case option.unwrap(choice.delta.tool_calls, []) {
      [] -> acc
      chunks ->
        list.fold(chunks, acc, fn(acc, chunk) {
          let chat.ToolCallChunk(index, id, function) = chunk
          let #(name, args_fragment) = case function {
            Some(chat.FunctionCallStream(name, arguments)) -> #(
              name,
              option.unwrap(arguments, ""),
            )
            None -> #(None, "")
          }
          on_event(ToolCallDelta(index, id, name, args_fragment))
          Acc(
            ..acc,
            tool_call_deltas: acc.tool_call_deltas + 1,
            ttft_us: Some(acc.ttft_us |> option.unwrap(now_us)),
          )
        })
    }
  })
}

/// Pure, offline-testable truncation classification for a closed stream:
/// `None` when the stream ended cleanly (`[DONE]` or any choice `finish_reason`)
/// or produced zero events (which takes the buffered status-probe path);
/// `Some(Transport(...))` when events were delivered and the stream then closed
/// with neither `[DONE]` nor a `finish_reason`.
pub fn truncation_error(acc: Acc) -> Option(StreamError) {
  case acc.events_parsed > 0, acc.saw_done || acc.saw_finish {
    True, True -> None
    True, False ->
      Some(Transport(
        "upstream stream closed before completion (missing [DONE] and finish_reason)",
      ))
    False, _ -> None
  }
}

fn build_stats(started_us: Int, ended_us: Int, acc: Acc) -> StreamStats {
  let ttft_ms = case acc.ttft_us {
    Some(first_us) -> Some(timing.elapsed_ms(started_us, first_us))
    None -> None
  }
  StreamStats(
    ttft_ms: ttft_ms,
    duration_ms: timing.elapsed_ms(started_us, ended_us),
    token_deltas: acc.token_deltas,
    reasoning_deltas: acc.reasoning_deltas,
    tool_call_deltas: acc.tool_call_deltas,
    events_parsed: acc.events_parsed,
    decode_errors: acc.decode_errors,
    saw_done: acc.saw_done,
    usage: acc.usage,
  )
}

type EofVerdict {
  EofClean(stats: StreamStats)
  EofFailed(error: StreamError)
  EofEmptyNoDecodeError
}

fn classify_eof(acc: Acc, stats: StreamStats) -> EofVerdict {
  case acc.events_parsed == 0 && !acc.saw_done {
    False ->
      // A stream that delivered events and then closed with NEITHER
      // `data: [DONE]` NOR any choice `finish_reason` was truncated mid-flight
      // (upstream disconnect / proxy reset). Fail as a transport error so the
      // turn rolls back cleanly instead of committing a half-streamed reply.
      case truncation_error(acc) {
        None -> EofClean(stats)
        Some(error) -> EofFailed(error)
      }
    True ->
      // Zero parsed events then Closed: either a decode failure prevented any
      // event from landing, or the upstream returned an empty/non-200 body.
      case acc.first_decode_error {
        Some(reason) -> EofFailed(Decode(reason))
        None -> EofEmptyNoDecodeError
      }
  }
}

fn finish_stream(
  req: Request(String),
  started_us: Int,
  acc: Acc,
  _on_event: fn(StreamEvent) -> Nil,
) -> Result(StreamStats, StreamError) {
  let stats = build_stats(started_us, timing.now_us(), acc)
  case classify_eof(acc, stats) {
    EofClean(final_stats) -> Ok(final_stats)
    EofFailed(error) -> Error(error)
    EofEmptyNoDecodeError ->
      // Zero parsed events then Closed with no decode error: re-run buffered
      // once to capture the actual status/body.
      case hackney.send(req) {
        Error(e) ->
          Error(Transport(
            "stream produced no events and buffered retry failed: "
            <> send_error(e),
          ))
        Ok(response) ->
          case response.status {
            200 ->
              Error(Transport(
                "stream produced no events (status 200); body: "
                <> snippet(response.body),
              ))
            status -> Error(Non200(status, snippet(response.body)))
          }
      }
  }
}

fn to_openai_config(endpoint: Endpoint) -> OpenAiConfig {
  oai_config.new(option.unwrap(endpoint.api_key, ""))
  |> oai_config.with_api_base(endpoint.base_url)
}

/// glopenai's request builder always prepends `authorization: Bearer
/// <api_key>` — with no key configured that would put an empty-valued
/// `Authorization` header on the wire, which some servers and
/// intermediaries reject. For keyless endpoints, drop the header entirely
/// (verified live against a keyless vLLM: both shapes are accepted, but a
/// missing header is the unambiguous one). Pure — offline-testable.
pub fn drop_empty_bearer(req: Request(a), endpoint: Endpoint) -> Request(a) {
  case endpoint.api_key {
    Some(_) -> req
    None ->
      Request(
        ..req,
        headers: list.filter(req.headers, fn(header) {
          header.0 != "authorization"
        }),
      )
  }
}

fn ensure_boot(next: fn() -> Result(a, StreamError)) -> Result(a, StreamError) {
  case ensure_hackney_started() {
    Ok(_) -> next()
    Error(reason) ->
      Error(Transport("failed to start hackney: " <> string.inspect(reason)))
  }
}

fn send_error(e: hackney.Error) -> String {
  string.inspect(e)
}

fn snippet(body: String) -> String {
  case string.length(body) > 400 {
    True -> string.slice(body, 0, 400) <> "…[truncated]"
    False -> body
  }
}
