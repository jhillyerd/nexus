//// Pure context compaction logic and `/compact` slash-command parsing
//// (`docs/plans/context-compaction.md` §5.2, §5.3, §7.1).
////
//// Mirrors `nexus/utility`: zero actor imports, fully offline-testable, and
//// rides the single `nexus/transcript` encode path with the thread's frozen
//// envelope (`loop.frozen_options`) so cache-capable backends reuse the
//// already-cached prompt prefix up to `cutoff_index`.
////
//// Strict role alternation guarantee:
//// - `pick_cutoff` enforces BOTH sides of the cut boundary:
////   - left (`messages[cutoff_index - 1]`): plain `AssistantMessage` or
////     `ToolMessage` (never `UserMessage`, including env roster lines and
////     retained failed-turn user messages, and never an unfulfilled tool-call
////     assistant message), so appending the `user`-role compaction instruction
////     always alternates cleanly;
////   - right (`cutoff_index == total_len` or `messages[cutoff_index]` is a
////     non-system `UserMessage`), so the kept tail never splits a tool round
////     or strands a system roster line at the head of the active window.

import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glopenai/chat
import nexus/openai
import nexus/transcript.{type Options, type Transcript}

/// Slash command parsed from the composer input.
pub type Command {
  Compact(focus: Option(String))
}

/// Why `pick_cutoff` refused compaction.
pub type PickError {
  NothingToCompact
}

/// Maximum character length accepted for `/compact <focus>` instructions
/// (~250 tokens, fitting comfortably inside the 512-token instruction headroom).
pub const max_focus_chars = 1000

/// Minimum `max_completion_tokens` granted to the summarization call.
pub const min_summary_max_tokens = 512

/// Default kept-tail token budget for manual `/compact` when `context_window`
/// is unconfigured (`None`).
pub const default_keep_tail_tokens = 4000

/// Lower bound for kept-tail token budget when `context_window` is configured
/// and `keep_tail_pct > 0`.
pub const min_keep_tail_tokens = 2000

/// Upper bound for kept-tail token budget when `context_window` is configured.
pub const max_keep_tail_tokens = 16_000

/// Defensive global character ceiling on stored summary size when
/// `context_window` is `None`.
pub const max_summary_chars_unbounded = 32_000

/// Minimum trimmed character length for a usable compaction summary.
pub const min_summary_chars = 8

const min_bytes_per_token = 2.0

const max_bytes_per_token = 6.0

// ---------------------------------------------------------------------------
// Slash command parser (§7.1)
// ---------------------------------------------------------------------------

/// Parse composer input for `/compact [focus]`.
///
/// Strict matching rule so ordinary messages starting with `/` (such as
/// `/etc/hosts` or `/compact-notes`) are never swallowed:
/// - `"/compact"` (after trim) → `Some(Compact(None))`
/// - `"/compact"` followed by ASCII whitespace (` `, `\t`, `\n`, `\r`) →
///   `Some(Compact(non_empty_trim(rest)))`
/// - anything else → `None`
pub fn parse_command(input: String) -> Option(Command) {
  let trimmed = string.trim(input)
  case trimmed {
    "/compact" -> Some(Compact(None))
    "/compact " <> rest
    | "/compact\t" <> rest
    | "/compact\n" <> rest
    | "/compact\r" <> rest ->
      case string.trim(rest) {
        "" -> Some(Compact(None))
        focus -> Some(Compact(Some(focus)))
      }
    _ -> None
  }
}

/// Validate and normalize optional `/compact` focus instructions before
/// starting compaction. Whitespace-only strings normalize to `Ok(None)`;
/// inputs exceeding `max_focus_chars` fail with `Error(max_focus_chars)`.
pub fn validate_focus(focus: Option(String)) -> Result(Option(String), Int) {
  case focus {
    None -> Ok(None)
    Some(raw) ->
      case string.trim(raw) {
        "" -> Ok(None)
        trimmed ->
          case string.length(trimmed) > max_focus_chars {
            True -> Error(max_focus_chars)
            False -> Ok(Some(trimmed))
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Token budget helpers (§5.2, §5.3)
// ---------------------------------------------------------------------------

/// Compute `summary_max_tokens` for the summarization call:
/// - `Some(limit)`: `min(cfg_max_tokens, max(512, limit / 4))`
/// - `None`: `max(512, cfg_max_tokens)`
pub fn summary_max_tokens(
  cfg_max_tokens: Int,
  context_window: Option(Int),
) -> Int {
  let max_tok = int.max(min_summary_max_tokens, cfg_max_tokens)
  case context_window {
    Some(limit) if limit > 0 ->
      int.min(max_tok, int.max(min_summary_max_tokens, limit / 4))
    _ -> max_tok
  }
}

/// Compute the kept-tail token budget from `NEXUS_COMPACTION_KEEP_TAIL_PCT`
/// and the thread's optional frozen `context_window`:
/// - `keep_tail_pct <= 0`: `0` (keep no tail, compact up to `total_len`)
/// - `Some(limit)`: `min(16_000, max(2_000, limit * keep_tail_pct / 100))`
/// - `None`: `4_000`
pub fn keep_tail_tokens(
  keep_tail_pct: Int,
  context_window: Option(Int),
) -> Int {
  case keep_tail_pct <= 0 {
    True -> 0
    False ->
      case context_window {
        Some(limit) if limit > 0 ->
          int.min(
            max_keep_tail_tokens,
            int.max(min_keep_tail_tokens, { limit * keep_tail_pct } / 100),
          )
        _ -> default_keep_tail_tokens
      }
  }
}

/// Upper bound in characters for the stored summary text, derived from
/// `summary_max_tokens` and the thread's calibrated `bytes_per_token` (with
/// a `32_000`-char ceiling when `context_window` is `None`).
pub fn max_summary_chars(
  cfg_max_tokens: Int,
  context_window: Option(Int),
  bytes_per_token: Float,
) -> Int {
  let max_tok = summary_max_tokens(cfg_max_tokens, context_window)
  let bpt = clamp_bpt(bytes_per_token)
  let by_budget = float.truncate(int.to_float(max_tok) *. bpt)
  let floored = int.max(min_summary_max_tokens, by_budget)
  case context_window {
    Some(_) -> floored
    None -> int.min(max_summary_chars_unbounded, floored)
  }
}

// ---------------------------------------------------------------------------
// Safe cut-point picker (§5.2)
// ---------------------------------------------------------------------------

/// Pick a safe chronological `cutoff_index` strictly inside `(start_index, total_len]`.
///
/// Enforces strict role alternation on BOTH sides:
/// - Left (`messages[i - 1]`): plain `AssistantMessage` (no tool calls) or
///   `ToolMessage` — never `UserMessage` (including env roster lines and
///   retained failed-turn user messages).
/// - Right (`i == total_len` or `messages[i]` is a non-system `UserMessage`).
/// - Summarized slice `[start_index .. i)` contains at least one non-system
///   user message (so at least one complete exchange is compacted).
///
/// Walks candidate boundaries and picks the earliest valid boundary whose
/// kept tail `[i .. total_len)` fits within `keep_tail_tokens`. If the only
/// valid boundary is `total_len` (e.g. a single turn in the active window),
/// allows `total_len` only when compacting makes meaningful progress
/// (`keep_tail_tokens <= 0`, active turn exceeds `keep_tail_tokens`, or active
/// turn exceeds 50% of `context_window`); otherwise returns `Error(NothingToCompact)`.
pub fn pick_cutoff(
  tr: Transcript,
  keep_tail_tokens: Int,
  context_window: Option(Int),
  bytes_per_token: Float,
) -> Result(Int, PickError) {
  let msgs = transcript.messages(tr)
  let total_len = list.length(msgs)
  let start_index = transcript.active_start(tr)
  case total_len <= start_index {
    True -> Error(NothingToCompact)
    False -> {
      // Precompute per-message estimated tokens and suffix sums for [0..total_len].
      let token_list =
        list.map(msgs, fn(msg) {
          estimate_tokens(message_bytes(msg), bytes_per_token)
        })
      let suffix_tokens = compute_suffix_sums(token_list)
      let active_tokens = list_at(suffix_tokens, start_index, 0)

      // Collect all valid boundaries strictly inside (start_index, total_len]
      // in a single O(n) left-to-right pass.
      let candidates =
        collect_valid_boundaries(
          tr,
          list.drop(msgs, start_index),
          start_index,
          False,
          [],
        )
      case candidates {
        [] -> Error(NothingToCompact)
        _ -> {
          let before_end = list.filter(candidates, fn(i) { i < total_len })
          let end_allowed =
            list.contains(candidates, total_len)
            && {
              before_end != []
              || keep_tail_tokens <= 0
              || active_tokens > keep_tail_tokens
              || exceeds_half_window(active_tokens, context_window)
            }
          let eligible = case end_allowed {
            True -> candidates
            False -> before_end
          }
          case eligible {
            [] -> Error(NothingToCompact)
            _ ->
              case
                list.find(eligible, fn(i) {
                  list_at(suffix_tokens, i, 0) <= keep_tail_tokens
                })
              {
                Ok(cutoff) -> Ok(cutoff)
                Error(Nil) ->
                  // Every eligible boundary has a tail exceeding keep_tail_tokens;
                  // if the single newest turn alone exceeds 50% of limit and
                  // total_len is valid, pick total_len, else pick the highest
                  // eligible boundary.
                  case list.last(eligible) {
                    Ok(highest) -> Ok(highest)
                    Error(Nil) -> Error(NothingToCompact)
                  }
              }
          }
        }
      }
    }
  }
}

fn exceeds_half_window(tokens: Int, context_window: Option(Int)) -> Bool {
  case context_window {
    Some(limit) if limit > 0 -> tokens * 2 > limit
    _ -> False
  }
}

/// Single O(n) pass over `msgs[start_index..]`: at each message `msg` at
/// chronological `index`, updates the monotone `seen_user` flag and tests
/// whether the boundary `index + 1` (right after `msg`) is valid on both
/// sides (`msg` is plain assistant/tool AND either `rest == []` or `rest`'s
/// head is a non-system `UserMessage`).
fn collect_valid_boundaries(
  tr: Transcript,
  remaining: List(chat.ChatMessage),
  index: Int,
  seen_user: Bool,
  acc: List(Int),
) -> List(Int) {
  case remaining {
    [] -> list.reverse(acc)
    [msg, ..rest] -> {
      let next_seen_user =
        seen_user
        || case msg {
          chat.UserMessage(..) -> !is_system_origin(tr, index)
          _ -> False
        }
      let next_index = index + 1
      let right_ok = case rest {
        [] -> True
        [chat.UserMessage(..), ..] -> !is_system_origin(tr, next_index)
        _ -> False
      }
      let valid = next_seen_user && is_valid_left_msg(msg) && right_ok
      let next_acc = case valid {
        True -> [next_index, ..acc]
        False -> acc
      }
      collect_valid_boundaries(tr, rest, next_index, next_seen_user, next_acc)
    }
  }
}

/// Left side of a valid boundary (`messages[index]`): must be a plain
/// `AssistantMessage` (no pending tool calls) or a `ToolMessage` — never a
/// `UserMessage` (including roster lines and retained failed-turn user lines).
fn is_valid_left_msg(msg: chat.ChatMessage) -> Bool {
  case msg {
    chat.AssistantMessage(tool_calls: None, ..) -> True
    chat.AssistantMessage(tool_calls: Some([]), ..) -> True
    chat.ToolMessage(..) -> True
    _ -> False
  }
}

fn is_system_origin(tr: Transcript, index: Int) -> Bool {
  case transcript.origin_at(tr, index) {
    Some(transcript.Origin("system", _)) -> True
    _ -> False
  }
}

/// Suffix sums: element `i` is the sum of `tokens[i..n)`, with trailing `0` at
/// index `n`.
fn compute_suffix_sums(tokens: List(Int)) -> List(Int) {
  let #(_sum, sums) =
    tokens
    |> list.reverse
    |> list.fold(#(0, [0]), fn(acc, tok) {
      let #(running, out) = acc
      let next = running + tok
      #(next, [next, ..out])
    })
  sums
}

fn list_nth(items: List(a), index: Int) -> Result(a, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False ->
      items
      |> list.drop(index)
      |> list.first
  }
}

fn list_at(items: List(Int), index: Int, default: Int) -> Int {
  case list_nth(items, index) {
    Ok(v) -> v
    Error(Nil) -> default
  }
}

fn message_bytes(msg: chat.ChatMessage) -> Int {
  case msg {
    chat.SystemMessage(content: chat.SystemTextContent(text), ..) ->
      string.byte_size(text) + 32
    chat.UserMessage(content: chat.UserTextContent(text), ..) ->
      string.byte_size(text) + 32
    chat.AssistantMessage(content: content, tool_calls: calls, ..) -> {
      let text_bytes = case content {
        Some(chat.AssistantTextContent(text)) -> string.byte_size(text)
        _ -> 0
      }
      let calls_bytes = case calls {
        None -> 0
        Some(cs) ->
          list.fold(cs, 0, fn(acc, call) {
            let chat.FunctionToolCall(id: id, function: f) = call
            acc
            + string.byte_size(id)
            + string.byte_size(f.name)
            + string.byte_size(f.arguments)
            + 48
          })
      }
      text_bytes + calls_bytes + 32
    }
    chat.ToolMessage(content: chat.ToolTextContent(text), tool_call_id: id) ->
      string.byte_size(text) + string.byte_size(id) + 40
    _ -> 32
  }
}

fn clamp_bpt(ratio: Float) -> Float {
  ratio
  |> float.max(min_bytes_per_token)
  |> float.min(max_bytes_per_token)
}

fn estimate_tokens(bytes: Int, bytes_per_token: Float) -> Int {
  case bytes <= 0 {
    True -> 0
    False ->
      int.to_float(bytes) /. clamp_bpt(bytes_per_token)
      |> float.ceiling
      |> float.truncate
  }
}

// ---------------------------------------------------------------------------
// Summarization prompt, envelope & single-stream runner (§5.3)
// ---------------------------------------------------------------------------

/// Build the compaction instruction appended as the final `user` message of
/// the cache-piggybacked summarization request.
pub fn instruction(has_prior: Bool, focus: Option(String)) -> String {
  let lead = case has_prior {
    True ->
      "Compact the conversation above into a single updated handoff summary so "
      <> "the conversation can continue seamlessly without the earlier turns. "
      <> "An earlier compacted summary already appears at the start of the "
      <> "conversation — merge and update it with all new developments into "
      <> "one unified summary instead of nesting summaries."
    False ->
      "Compact the conversation above into a concise, factual handoff summary "
      <> "so the conversation can continue seamlessly without the earlier turns."
  }
  let structure =
    "\n\nUse these exact headings:\n"
    <> "## Goal & Constraints\n"
    <> "## Decisions & Completed Work\n"
    <> "## Current State & Key Details\n"
    <> "## Open Questions & Next Steps\n\n"
    <> "Keep concrete details that remain relevant (file paths, commands, "
    <> "symbols, identifiers, URLs, and key error outputs). Omit pleasantries "
    <> "and superseded dead ends. Do not call any tools. Reply with the "
    <> "summary only."
  let focus_note = case focus {
    Some(note) ->
      case string.trim(note) {
        "" -> ""
        trimmed -> "\n\nPreserve detail especially regarding: " <> trimmed
      }
    None -> ""
  }
  lead <> structure <> focus_note
}

/// Build the throwaway summarization transcript: the active prefix up to
/// `cutoff_index` (`transcript.slice_active`) plus the compaction instruction
/// as one `user` message. Never committed back into the thread.
pub fn prepare(
  tr: Transcript,
  cutoff_index: Int,
  focus: Option(String),
) -> Transcript {
  let prefix = transcript.slice_active(tr, cutoff_index)
  let has_prior = option.is_some(transcript.latest_compaction(prefix))
  transcript.append_user(prefix, instruction(has_prior, focus))
}

/// The thread's frozen envelope (`loop.frozen_options`) with one generation-
/// side delta: `max_completion_tokens` bounded by `summary_max_tokens`.
pub fn options(
  base: Options,
  cfg_max_tokens: Int,
  context_window: Option(Int),
) -> Options {
  transcript.Options(
    ..base,
    max_completion_tokens: Some(summary_max_tokens(
      cfg_max_tokens,
      context_window,
    )),
  )
}

/// Clean and bound a raw model summary reply:
/// - Strips a single outer wrapping markdown fence if present (preserving
///   internal fenced code blocks).
/// - Trims whitespace and rejects blank / too-short replies.
/// - Caps length to `max_chars` (derived from `summary_max_tokens` and the
///   thread's calibrated `bytes_per_token`, or `32_000` when unconfigured).
pub fn shape_summary(raw: String, max_chars: Int) -> Result(String, String) {
  let cleaned = strip_outer_fences(raw)
  case string.length(cleaned) < min_summary_chars {
    True -> Error("compaction summary was empty or too short")
    False -> {
      let bound = int.max(min_summary_chars, max_chars)
      case string.length(cleaned) > bound {
        True -> Ok(string.trim_end(string.slice(cleaned, 0, bound)))
        False -> Ok(cleaned)
      }
    }
  }
}

/// Strip one outer wrapping markdown code fence (` ```lang ... ``` `) only
/// when the opening fence genuinely wraps the entire reply (never stripping
/// two separate code blocks that happen to sit at the start and end).
pub fn strip_outer_fences(text: String) -> String {
  let normalized =
    text
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.trim
  case string.starts_with(normalized, "```") {
    False -> normalized
    True ->
      case string.split_once(normalized, "\n") {
        Error(Nil) ->
          case
            string.ends_with(normalized, "```")
            && string.length(normalized) >= 6
          {
            True ->
              normalized
              |> string.drop_start(3)
              |> string.drop_end(3)
              |> string.trim
            False -> normalized
          }
        Ok(#(opening, rest)) -> {
          let after_ticks = string.drop_start(opening, 3)
          let lines = string.split(rest, "\n")
          case list.reverse(lines) {
            [last, ..rev_middle] ->
              case
                !string.contains(after_ticks, "```")
                && string.trim(last) == "```"
                && outer_fence_stays_open(list.reverse(rev_middle), 1)
              {
                True ->
                  rev_middle
                  |> list.reverse
                  |> string.join("\n")
                  |> string.trim
                False -> normalized
              }
            [] -> normalized
          }
        }
      }
  }
}

fn outer_fence_stays_open(lines: List(String), depth: Int) -> Bool {
  case lines {
    [] -> depth > 0
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      let next_depth = case string.starts_with(trimmed, "```") {
        False -> depth
        True ->
          case string.trim(string.drop_start(trimmed, 3)) {
            // Bare ``` closes an open fence.
            "" -> depth - 1
            // ```lang opens a nested fence.
            _ -> depth + 1
          }
      }
      case next_depth <= 0 {
        True -> False
        False -> outer_fence_stays_open(rest, next_depth)
      }
    }
  }
}

type Fragment {
  Text(String)
  ToolCallSeen
}

/// One blocking, single-stream cache-piggybacked compaction call.
/// Accumulates `TokenDelta`s (explicitly ignoring `ReasoningDelta` so chain of
/// thought never leaks into stored summaries), fails on any `ToolCallDelta`,
/// cancellation, transport error, or blank/too-short reply, and bounds the
/// stored summary to `max_summary_chars`. `cancel` must be owned by the
/// calling process.
pub fn run(
  endpoint: openai.Endpoint,
  tr: Transcript,
  cutoff_index: Int,
  focus: Option(String),
  base_opts: Options,
  cfg_max_tokens: Int,
  context_window: Option(Int),
  bytes_per_token: Float,
  cancel: Subject(Nil),
) -> Result(String, String) {
  let acc = process.new_subject()
  let outcome =
    openai.stream_with_cancel(
      endpoint,
      prepare(tr, cutoff_index, focus),
      options(base_opts, cfg_max_tokens, context_window),
      fn(event) {
        case event {
          openai.TokenDelta(text) -> process.send(acc, Text(text))
          openai.ToolCallDelta(_, _, _, _) -> process.send(acc, ToolCallSeen)
          // Deliberately ignore ReasoningDelta and Usage so CoT never
          // leaks into the stored compaction summary.
          openai.ReasoningDelta(_) | openai.Usage(_) -> Nil
        }
      },
      cancel,
    )
  let fragments = drain(acc, [])
  case outcome {
    openai.Cancelled -> Error("cancelled")
    openai.Failed(error) ->
      Error("compaction stream failed: " <> describe(error))
    openai.Completed(_) ->
      case list.contains(fragments, ToolCallSeen) {
        True -> Error("model answered compaction with a tool call")
        False ->
          fragments
          |> list.filter_map(fn(fragment) {
            case fragment {
              Text(text) -> Ok(text)
              ToolCallSeen -> Error(Nil)
            }
          })
          |> string.concat
          |> shape_summary(max_summary_chars(
            cfg_max_tokens,
            context_window,
            bytes_per_token,
          ))
      }
  }
}

fn drain(acc: Subject(Fragment), fragments: List(Fragment)) -> List(Fragment) {
  case process.receive(acc, 0) {
    Ok(fragment) -> drain(acc, [fragment, ..fragments])
    Error(Nil) -> list.reverse(fragments)
  }
}

fn describe(error: openai.StreamError) -> String {
  case error {
    openai.Non200(status, body) ->
      "non-200 response: "
      <> int.to_string(status)
      <> ": "
      <> string.slice(body, 0, 200)
    openai.Transport(reason) -> "transport error: " <> reason
    openai.Decode(reason) -> "decode error: " <> reason
  }
}
