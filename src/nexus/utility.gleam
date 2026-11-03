//// Prefix-cache piggybacking (utility-titles plan §4.1, extended by
//// the utility-tags plan): after a session's first committed exchange,
//// one background completion — branched off the committed transcript's
//// cached prefix — proposes a session title AND a handful of tags. The
//// request reuses the session's frozen envelope (same model, system
//// prompt, tool schemas) so cache-capable backends reprocess only the
//// instruction message; the reply becomes the session's organizational
//// metadata while both provenance columns are 'auto' and is otherwise
//// discarded (best-effort).
////
//// Reply protocol (utility-tags plan §3.1) — two lines of plain text:
//// line 1 is the title (required: unusable/empty fails the attempt,
//// exactly the title-only semantics), line 2 is a comma-separated tag
//// list (best-effort: absent or malformed means zero tags, and the
//// title still applies). No JSON — parsing stays string-shaping, which
//// small local models fumble less than structured output. A leading
//// `Title:` / `Tags:` label on either line is stripped (models like
//// echoing the schema).
////
//// Tag vocabulary is shaped structurally, not just prompted: at most
//// `max_new_tags` tags absent from the supplied corpus survive the
//// parse (reuse dominates; growth is bounded per attempt), and the
//// union with a session's existing display set is capped at
//// `tags_per_session` entries (`merge_tags` — what the registry applies).
//// Every tag — manual or model — passes through the ONE normalization
//// rule below, so the two paths can never drift apart.
////
//// PASS postpone: when the first exchange gives the model too little to
//// title specifically (a greeting-only opener, say), it may reply
//// exactly PASS instead. A PASS is not a failure and not a title: the
//// session actor treats it as "not yet" — the once-per-session attempt
//// stays available and re-arms at the next turn-commit point. Exactly
//// one pass is honored per session; after that the forced instruction
//// (no PASS option) demands the best title available, so the forced
//// attempt cannot defer again. A PASS under the forced instruction is an
//// unusable title, not a postpone — it defers title AND tags together.
////
//// Structure: pure request/parse helpers plus one blocking runner — no
//// actor of its own. The runner executes inside the session's unlinked
//// utility worker (like the turn worker), never the session actor.
////
//// Cache contract: the request is built by the SAME `nexus/transcript`
//// encoder from the committed transcript with the SAME envelope as every
//// turn (`loop.frozen_options`, the one shared construction site), with
//// exactly one delta — `max_completion_tokens` — which is generation-side
//// only and never tokenizes into the prompt. The transcript this module
//// branches from is a throwaway snapshot: the instruction (Y) and reply
//// (B) never enter the session's transcript, so conversation re-encoding
//// stays byte-identical turn over turn.
////
//// Hostile text: the reply is model output. It is display data only —
//// it becomes a session title string that the UI renders as a Lustre
//// text node (no `innerHTML` anywhere), and it never rides back into a
//// request body (the branch is never committed).

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import nexus/openai
import nexus/transcript.{type Options, type Transcript}

/// Reply length cap — the same rule as the heuristic first-message title
/// (`session_registry.title_from_first_message`): collapse whitespace,
/// truncate (with an ellipsis) at 60 characters.
const title_limit = 60

/// Per-tag character cap (utility-tags plan §3.1): truncate each tag at
/// 24 characters — no ellipsis, unlike the title cap, because a tag is a
/// kebab-word (filtering vocabulary), not display prose. Together with
/// the corpus cap this bounds the corpus's contribution to Y: 30 entries
/// × 24 chars is a hard ceiling.
const tag_limit = 24

/// Maximum tags one session may carry (§3.1): the union of existing
/// display tags and one attempt's new tags preserves existing order,
/// appends the new, then truncates here.
const tags_per_session = 5

/// Maximum NEW tags one attempt may introduce (§3.1, the K cap): tags
/// already present in the supplied corpus survive freely — reuse
/// dominates, growth is bounded per attempt. Enforced structurally in
/// `parse_tags`, not just prompted.
const max_new_tags = 2

/// Bounds the side call's cost and rambling. Generation-side params do not
/// affect the tokenized prompt (utility-titles plan §4.1), so the prefix is
/// untouched. Deliberately generous headroom over the one-line title:
/// reasoning models emit their chain of thought INSIDE this completion
/// budget, so a tight cap lets a thinking model exhaust it before any
/// title text arrives — wasting the session's only attempt. The reply
/// itself stays bounded by `shape_title`'s 60-character cap.
const utility_token_cap = 512

/// The appended user instruction (Y in the plan). Tool use is forbidden
/// in the prompt because the frozen `tools` array renders into the prompt
/// and cannot be stripped without diverging the cached prefix.
///
/// The reply is two lines (utility-tags plan §3.2): line 1 the title,
/// line 2 a comma-separated tag list of zero to three tags. When
/// `corpus` is non-empty it is listed — corpus-constrained generation
/// steers the model toward reuse — and the new-tag allowance matches the
/// parser's structural cap (`max_new_tags`). The corpus makes Y dynamic;
/// that is safe by construction because Y is the tail message —
/// generation-side, never committed — so the conversation prefix is
/// untouched no matter what the corpus contains.
///
/// `allow_pass` picks the variant: the first (unpassed) attempt offers
/// the PASS escape hatch — the model judges whether the conversation has
/// enough signal for a specific title — while a re-armed attempt after a
/// pass uses the forced variant, which must not mention the sentinel at
/// all (a model that never saw the option cannot be steered into it).
pub fn instruction(allow_pass: Bool, corpus: List(String)) -> String {
  let base =
    "You are being asked a housekeeping question about the conversation above. "
    <> "Reply with exactly two lines. Line 1: give this conversation a "
    <> "concise sentence-case title of 3–7 words. Line 2: list zero to "
    <> "three short tags for its topic, comma-separated."
  let reuse = case corpus {
    [] -> ""
    _ ->
      " Prefer reusing a tag from this list when one fits: "
      <> string.join(corpus, ", ")
      <> " — you may introduce at most "
      <> int.to_string(max_new_tags)
      <> " new tags."
  }
  let tail = " Do not call any tools. Reply with the title and tags only."
  case allow_pass {
    True ->
      base
      <> reuse
      <> " If the conversation so far does not yet give you enough to write "
      <> "a specific title, reply with exactly PASS instead."
      <> tail
    False ->
      base
      <> reuse
      <> " Even if the conversation is still slight, reply with the best "
      <> "title you can — do not defer."
      <> tail
  }
}

/// The utility transcript: the committed snapshot plus the instruction as
/// one user message (Y). Never committed back into the session.
pub fn prepare(
  tr: Transcript,
  allow_pass: Bool,
  corpus: List(String),
) -> Transcript {
  transcript.append_user(tr, instruction(allow_pass, corpus))
}

/// The loop's frozen envelope with exactly one delta: the generation-side
/// token cap. `base` is `loop.frozen_options(specs)` — the shared
/// construction — so every byte above the cap matches a turn request.
pub fn options(base: Options) -> Options {
  transcript.Options(..base, max_completion_tokens: Some(utility_token_cap))
}

/// A parsed utility reply: a display title plus its attempt's surviving
/// tags (already normalized and corpus-capped; the registry merges them
/// into the session's display set), or the model's PASS — its "not enough
/// signal yet" verdict, honored once per session (the session actor owns
/// that policy; this module only reports it). A PASS defers title AND
/// tags together.
pub type Verdict {
  Title(title: String, tags: List(String))
  Pass
}

/// Parse a utility reply into a verdict (utility-tags plan §3.1):
///
/// - PASS matches only the WHOLE shaped reply (whitespace-collapsed,
///   case-folded) and defers title + tags together; a real title that
///   merely contains the word ("Password Manager Setup") never
///   postpones. Under the forced instruction (`allow_pass = False`) a
///   PASS reply is an unusable title: the forced attempt cannot defer
///   again, so it is a failure, not a postpone.
/// - Line 1 is the title: strip a leading `Title:` label, collapse
///   whitespace, cap length with the same rule as
///   `title_from_first_message`, and reject empty (a refusal arrives as
///   no content, so it fails here too).
/// - Line 2 is best-effort tags: absent or malformed means zero tags, and
///   the title still applies. Tags are normalized (the shared rule) and
///   structurally capped — at most `max_new_tags` tags absent from
///   `corpus` survive.
pub fn parse(
  allow_pass: Bool,
  corpus: List(String),
  text: String,
) -> Result(Verdict, Nil) {
  let stripped = strip_code_fences(text)
  case is_pass(collapse_whitespace(stripped)) {
    True ->
      case allow_pass {
        True -> Ok(Pass)
        False -> Error(Nil)
      }
    False ->
      case reply_lines(stripped) {
        [] -> Error(Nil)
        [title_line, ..rest] ->
          case shape_title(strip_label("title:", title_line)) {
            "" -> Error(Nil)
            title ->
              Ok(
                Title(title: title, tags: case rest {
                  [tags_line, ..] -> parse_tags(corpus, tags_line)
                  [] -> []
                }),
              )
          }
      }
  }
}

/// Split a reply into its meaningful lines: newlines normalized (the
/// CRLF pair first — Erlang's `string:replace` does not match a lone
/// "\r" inside "\r\n"), trailing blank lines dropped (a trailing "\n" is
/// not a tags line), then at most the first TWO lines — line 1 the
/// title, line 2 the tags. Anything after line 2 is ignored (the
/// protocol is two lines; extra prose is malformed, and tags are
/// best-effort).
fn reply_lines(text: String) -> List(String) {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
  // Drop trailing blank lines (a trailing "\n" is not a tags line).
  |> list.reverse
  |> list.drop_while(fn(line) { string.trim(line) == "" })
  |> list.reverse
  |> list.take(2)
}

/// Strip a leading `Title:` / `Tags:` label (case-insensitive, optional
/// whitespace after the colon) from one line — models like echoing the
/// schema. Anything else passes through; a word that merely starts like
/// the label without the colon ("Titleist clubs") is left alone.
fn strip_label(label: String, line: String) -> String {
  let line = string.trim(line)
  let lowered = string.lowercase(line)
  case string.starts_with(lowered, label) {
    True ->
      line
      |> string.drop_start(string.length(label))
      |> string.trim
    False -> line
  }
}

/// Parse the tags line (line 2) into the attempt's surviving tags:
/// strip a leading `Tags:` label, split on commas, normalize each tag
/// through the shared rule, drop empties and duplicates (first wins),
/// then enforce the structural K cap — at most `max_new_tags` tags NOT
/// present in `corpus` survive, in reply order. The per-session cap is
/// NOT applied here: it governs the union with the existing display set
/// (`merge_tags`), which only the registry can compute.
pub fn parse_tags(corpus: List(String), line: String) -> List(String) {
  let corpus_keys = list.map(corpus, string.lowercase)
  let #(kept, _new_count) =
    normalize_tags(string.split(strip_label("tags:", line), ","))
    |> list.fold(#([], 0), fn(acc, tag) {
      let #(kept, new_count) = acc
      case list.contains(corpus_keys, string.lowercase(tag)) {
        // A corpus tag is reuse, not growth: always welcome.
        True -> #([tag, ..kept], new_count)
        False ->
          case new_count < max_new_tags {
            True -> #([tag, ..kept], new_count + 1)
            False -> acc
          }
      }
    })
  list.reverse(kept)
}

/// The ONE tag normalization rule (utility-tags plan §3.1), shared by
/// manual tag saves (`session_registry` delegates here) and model tags:
/// trim, lowercase, collapse internal whitespace runs to a single `-`
/// (kebab-case), drop empties and duplicates (first occurrence wins —
/// insertion order is display order), truncate each tag at `tag_limit`.
/// Normalized tags are therefore bounded, whitespace-free kebab strings
/// — which is what keeps a corpus embedding in Y bounded by
/// construction.
pub fn normalize_tags(tags: List(String)) -> List(String) {
  tags
  |> list.map(normalize_tag)
  |> list.filter(fn(tag) { tag != "" })
  |> list.unique
}

fn normalize_tag(tag: String) -> String {
  let kebab =
    tag
    |> string.trim
    |> string.lowercase
    |> collapse_whitespace
    |> string.replace(" ", "-")
  case string.length(kebab) > tag_limit {
    True -> string.slice(kebab, 0, tag_limit)
    False -> kebab
  }
}

/// The model-tags merge into a session's display set (utility-tags plan
/// §3.5 — what the registry's UpgradeAutoTitle applies): existing
/// display entries pass through VERBATIM, never re-canonicalized (a
/// legacy `Work Notes` stays `Work Notes`, so display − manual
/// bookkeeping cannot manufacture a phantom auto tag); new model tags
/// are normalized and appended when not already present (the presence
/// check compares through the SAME normalization — the kebab shape —
/// not bare lowercasing, so `Work Notes` and `work-notes` are one tag
/// and do not duplicate); the union preserves existing order, appends
/// the new, then truncates at `tags_per_session`.
pub fn merge_tags(existing: List(String), new: List(String)) -> List(String) {
  // The presence key is the full shared normalization (`normalize_tag`,
  // below) — never the raw display spelling: only the comparison is
  // canonicalized, so verbatim passthrough and no-duplicates hold
  // together. New tags arrive already normalized, so they are their own
  // keys.
  let #(appended, _present) =
    normalize_tags(new)
    |> list.fold(#([], list.map(existing, normalize_tag)), fn(acc, tag) {
      let #(appended, present) = acc
      case list.contains(present, tag) {
        True -> acc
        False -> #([tag, ..appended], [tag, ..present])
      }
    })
  // Existing entries keep their order VERBATIM; the appended arrive in
  // reply order (the fold prepended, so reverse them); the union caps.
  list.append(existing, list.reverse(appended))
  |> list.take(tags_per_session)
}

/// The PASS sentinel test: exact match on the shaped reply, case
/// folded. Public so tests and future callers share one definition.
pub fn is_pass(shaped: String) -> Bool {
  string.lowercase(shaped) == "pass"
}

/// Shape raw text into a display title: strip code fences, collapse every
/// whitespace run to single spaces, trim, and truncate (with an ellipsis)
/// at `title_limit`. The one implementation behind BOTH title shapings —
/// the heuristic first-message title delegates here, so the two can never
/// drift apart.
pub fn shape_title(text: String) -> String {
  let flat = collapse_whitespace(text)
  case string.length(flat) > title_limit {
    True -> string.slice(flat, 0, title_limit) <> "…"
    False -> flat
  }
}

/// Strip one surrounding Markdown code fence (` ```lang … ``` `). Anything
/// else passes through trimmed.
fn strip_code_fences(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      let body = case string.split_once(trimmed, "\n") {
        Ok(#(_opening_fence_line, rest)) -> string.trim(rest)
        // A single-line fence (` ```title``` `, optionally tagged) has no
        // newline to split on: strip the surrounding ticks instead.
        Error(Nil) ->
          trimmed
          |> string.drop_start(3)
          |> string.drop_end(3)
          |> string.trim
      }
      case string.ends_with(body, "```") {
        True -> string.trim(string.drop_end(body, 3))
        False -> body
      }
    }
  }
}

/// Collapse every whitespace run (spaces, tabs, newlines) to single spaces
/// and trim — a multi-line reply still reads as one title line. The CRLF
/// pair must go first: Erlang's Unicode `string:replace` does not match a
/// lone "\r" inside "\r\n".
fn collapse_whitespace(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
  |> string.trim
}

/// What the stream feed accumulated. A tool call is a failure by
/// construction (the instruction forbids it; the frozen envelope still
/// advertises the tools) — remembered explicitly rather than inferred from
/// missing text.
type Fragment {
  Text(String)
  ToolCallSeen
}

/// One blocking, non-loop utility stream. The base options must be the
/// session's frozen envelope (`loop.frozen_options`); the delta applied
/// here is generation-side only. Accumulates text deltas, fails on any
/// tool-call assembly or transport error (best-effort: no retry), and
/// parses the reply. `cancel` must be owned by the calling process — the
/// utility worker creates it, mirroring the turn worker.
pub fn run(
  endpoint: openai.Endpoint,
  tr: Transcript,
  base_opts: Options,
  cancel: Subject(Nil),
  allow_pass: Bool,
  corpus: List(String),
) -> Result(Verdict, String) {
  // The stream feed runs synchronously in THIS process, so fragments land
  // in this subject's mailbox and are drained after the call returns.
  let acc = process.new_subject()
  let outcome =
    openai.stream_with_cancel(
      endpoint,
      prepare(tr, allow_pass, corpus),
      options(base_opts),
      fn(event) {
        case event {
          openai.TokenDelta(text) -> process.send(acc, Text(text))
          openai.ToolCallDelta(_, _, _, _) -> process.send(acc, ToolCallSeen)
          _ -> Nil
        }
      },
      cancel,
    )
  let fragments = drain(acc, [])
  case outcome {
    openai.Cancelled -> Error("utility stream cancelled")
    openai.Failed(error) -> Error("utility stream failed: " <> describe(error))
    openai.Completed(_) ->
      case list.contains(fragments, ToolCallSeen) {
        True -> Error("model answered the utility call with a tool call")
        False ->
          case
            list.filter_map(fragments, fn(fragment) {
              case fragment {
                Text(text) -> Ok(text)
                ToolCallSeen -> Error(Nil)
              }
            })
            |> string.concat
            |> parse(allow_pass, corpus, _)
          {
            Ok(verdict) -> Ok(verdict)
            Error(Nil) -> Error("no usable title in utility reply")
          }
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
