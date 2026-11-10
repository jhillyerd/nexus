//// Offline verification for the utility title branch (utility-titles
//// plan §6, item 1):
////
////   * *Prefix property* — the branch request is built from the SAME
////     `nexus/transcript` encode path over the REAL archived M3 thread
////     (`test/fixtures/m3_cache_thread.json`): its body is the turn
////     body with exactly one appended user message (the instruction Y)
////     and exactly one envelope delta, the generation-side
////     `max_completion_tokens` cap. The `body_parts` / fixture-replay
////     helpers are deliberately duplicated from `test/m3_prefix_test.gleam`
////     (which must stay untouched) — they are the golden suite's own
////     vocabulary.
////   * *Parser* — code-fenced output, multi-line replies, leading prose,
////     hostile `<script>` payloads (pass through inert + length-capped),
////     empty, refusal (a refusal arrives as no content).
////   * *Instruction* — Y forbids tool calls and is ONE user message.
////
//// `utility.run` itself is the one network-touching piece; it is never
//// called here — the thread actor tests drive it through the fake
//// `utility_runner` seam instead. Everything in this file is pure.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glopenai/chat
import nexus/config.{type Config}
import nexus/tools
import nexus/transcript.{type Options, type Transcript}
import nexus/utility

@external(erlang, "nexus_loop_test_ffi", "read_file")
fn read_file(path: String) -> BitArray

const fixture_path = "test/fixtures/m3_cache_thread.json"

// ---------------------------------------------------------------------------
// Fixture decoding (duplicated verbatim from test/m3_prefix_test.gleam)
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

/// Apply one captured turn to the transcript exactly like `nexus/loop`
/// (duplicated from the golden test: the user message, then — per model
/// iteration — one assistant message carrying that iteration's text and
/// tool calls, then each tool result).
fn apply_turn(tr: Transcript, messages: List(FixtureMsg)) -> Transcript {
  case messages {
    [FxUser(text), ..rest] ->
      apply_iteration(transcript.append_user(tr, text), rest, "", [])
    _ -> tr
  }
}

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
        transcript.append_tool_result(tr, tool_call_id, content, ok: True),
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
// Options mirroring the loop (duplicated from test/m3_prefix_test.gleam)
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
// Body splitting (duplicated from test/m3_prefix_test.gleam): the messages
// array vs the envelope after the `,"stream"` marker.
// ---------------------------------------------------------------------------

fn body_parts(body: String) -> #(String, String) {
  case string.split(body, on: ",\"stream\"") {
    [messages, envelope] -> #(messages, ",\"stream\"" <> envelope)
    _ -> panic as "request body has no stream marker"
  }
}

/// The first captured turn — the committed exchange a real utility branch
/// forks from (system + user + tool round + final answer).
fn first_exchange() -> Transcript {
  let fixture = load_fixture()
  let assert [first, ..] = fixture.turns
  transcript.new(fixture.alias, fixture.system)
  |> apply_turn(first.messages)
}

// ---------------------------------------------------------------------------
// The prefix property (§6): the branch is messages-suffix-only
// ---------------------------------------------------------------------------

/// The utility branch reuses the turn envelope: `request_body(conv)` vs
/// `request_body(conv + Y)` differ ONLY by the appended instruction
/// message and the ONE generation-side option.
pub fn utility_branch_is_messages_suffix_only_test() {
  let tr = first_exchange()
  let base = loop_options()
  let base_body = transcript.request_body(tr, base)
  let branch_body =
    transcript.request_body(
      utility.prepare(tr, True, []),
      utility.options(base),
    )

  // The messages array grew by appending ONE message before the closing
  // `]` — every byte above it is identical.
  let #(base_messages, _) = body_parts(base_body)
  let #(branch_messages, _) = body_parts(branch_body)
  let prefix = string.drop_end(base_messages, 1)
  should.be_true(string.starts_with(branch_messages, prefix))

  // The appended message is exactly the instruction, as ONE user message.
  let appended = string.drop_start(branch_messages, string.length(prefix))
  should.equal(
    appended,
    ",{\"role\":\"user\",\"content\":"
      <> json.to_string(json.string(utility.instruction(True, [])))
      <> "}]",
  )
}

/// The envelope after the messages array carries exactly ONE delta — the
/// `max_completion_tokens` cap — and `utility.options` is that delta and
/// nothing else.
pub fn utility_envelope_delta_is_only_the_token_cap_test() {
  let tr = first_exchange()
  let base = loop_options()
  let branch_body =
    transcript.request_body(
      utility.prepare(tr, True, []),
      utility.options(base),
    )

  let #(_, base_envelope) = body_parts(transcript.request_body(tr, base))
  let #(_, branch_envelope) = body_parts(branch_body)

  // Pull the cap out of the wire format (glopenai serializes the field
  // right after "stream") and strip it: the remainder must be the turn
  // envelope byte-for-byte — no other key moved, changed, or appeared.
  let assert Ok(#(before_cap, cap_rest)) =
    string.split_once(branch_envelope, ",\"max_completion_tokens\":")
  let assert Ok(#(cap_text, after_cap)) = string.split_once(cap_rest, ",")
  let assert Ok(cap) = int.parse(cap_text)
  should.be_true(cap > 0)
  // Re-assembling the envelope without the cap's field (the second split
  // consumed the field's trailing comma, so it goes back in) must restore
  // the turn envelope byte-for-byte — no other key moved, changed, or
  // appeared.
  should.equal(before_cap <> "," <> after_cap, base_envelope)

  // And the cap is the ONLY Options record delta: rebuilding the loop's
  // options with exactly this one field reproduces the branch options.
  should.equal(
    utility.options(base),
    transcript.Options(..base, max_completion_tokens: Some(cap)),
  )
  // Cross-checked at the byte level: same transcript + options equal ⇒
  // bodies equal.
  should.equal(
    transcript.request_body(tr, utility.options(base)),
    transcript.request_body(
      tr,
      transcript.Options(..base, max_completion_tokens: Some(cap)),
    ),
  )
}

/// Encoding is deterministic (the live cache gate's offline half): the
/// same branch encodes to the same bytes, every time.
pub fn utility_request_is_deterministic_test() {
  let tr = first_exchange()
  let opts = utility.options(loop_options())
  transcript.request_body(utility.prepare(tr, True, []), opts)
  |> should.equal(transcript.request_body(utility.prepare(tr, True, []), opts))
}

/// The corpus makes Y LONGER (utility-tags plan §4/§5): re-run the
/// request-body assertion with a corpus-carrying instruction — the
/// branch is still messages-suffix-only over the turn body, and the
/// envelope still differs by exactly `max_completion_tokens`. The
/// corpus is tail-message content (generation-side, never committed),
/// so the longer Y cannot touch the cached prefix — this pins that by
/// construction, not by wording.
pub fn utility_branch_with_corpus_is_messages_suffix_only_test() {
  let tr = first_exchange()
  let base = loop_options()
  let corpus = ["cache", "login", "auth", "work-notes", "kv-reuse"]
  let branch_body =
    transcript.request_body(
      utility.prepare(tr, True, corpus),
      utility.options(base),
    )

  // Messages: the turn body plus exactly ONE appended user message —
  // the corpus-carrying instruction, and nothing else moved.
  let #(base_messages, base_envelope) =
    body_parts(transcript.request_body(tr, base))
  let #(branch_messages, branch_envelope) = body_parts(branch_body)
  let prefix = string.drop_end(base_messages, 1)
  should.be_true(string.starts_with(branch_messages, prefix))
  should.equal(
    string.drop_start(branch_messages, string.length(prefix)),
    ",{\"role\":\"user\",\"content\":"
      <> json.to_string(json.string(utility.instruction(True, corpus)))
      <> "}]",
  )

  // Envelope: exactly ONE delta — the generation-side token cap. Strip
  // its field and the turn envelope returns byte-for-byte; the Options
  // record differs by exactly that field.
  let assert Ok(#(before_cap, cap_rest)) =
    string.split_once(branch_envelope, ",\"max_completion_tokens\":")
  let assert Ok(#(cap_text, after_cap)) = string.split_once(cap_rest, ",")
  let assert Ok(cap) = int.parse(cap_text)
  should.equal(before_cap <> "," <> after_cap, base_envelope)
  should.equal(
    utility.options(base),
    transcript.Options(..base, max_completion_tokens: Some(cap)),
  )
}

// ---------------------------------------------------------------------------
// The parser (§6)
// ---------------------------------------------------------------------------

pub fn parse_strips_code_fences_test() {
  utility.parse(True, [], "```\nGuarded Migration\n```")
  |> should.equal(Ok(utility.Title("Guarded Migration", [])))
  // A tagged fence loses its language line too.
  utility.parse(True, [], "```text\nCache Warmup\n```")
  |> should.equal(Ok(utility.Title("Cache Warmup", [])))
  // A single-line fence has no newline to split on — the ticks come off
  // anyway instead of discarding the reply.
  utility.parse(True, [], "```Cache Warmup```")
  |> should.equal(Ok(utility.Title("Cache Warmup", [])))
  // Interior fences are left alone; only a surrounding fence is stripped.
  utility.parse(True, [], "Look: ```code```")
  |> should.equal(Ok(utility.Title("Look: ```code```", [])))
}

/// The two-line protocol (utility-tags plan §3.1): line 1 shapes the
/// title (whitespace collapsed WITHIN the line), line 2 is the tags line
/// (best-effort — here one tag each, normalized to kebab-case).
pub fn parse_two_line_reply_test() {
  // With an empty corpus every tag is NEW, so the structural K cap keeps
  // only the first two — the third ("auth") is dropped, in reply order.
  utility.parse(True, [], "Fix login redirect loop\nlogin, bug, auth")
  |> should.equal(
    Ok(utility.Title("Fix login redirect loop", ["login", "bug"])),
  )
  // Line 1 collapses internal whitespace runs; CRLF is a line break, and
  // the tags line's internal whitespace collapses to kebab-case.
  utility.parse(True, [], "KV  Reuse\r\nand\tWarming")
  |> should.equal(Ok(utility.Title("KV Reuse", ["and-warming"])))
  // A trailing newline is not a tags line: the title still applies.
  utility.parse(True, [], "Title Only\n")
  |> should.equal(Ok(utility.Title("Title Only", [])))
}

/// Tags are best-effort (§3.1): a title-only reply (no line 2 at all),
/// an EMPTY tags line, or a malformed one all mean zero tags — and the
/// title still applies in every case.
pub fn parse_title_only_reply_and_empty_tags_line_test() {
  utility.parse(True, [], "Just a title")
  |> should.equal(Ok(utility.Title("Just a title", [])))
  // Trailing blank lines are not tags lines either.
  utility.parse(True, [], "Title Only\n   \n")
  |> should.equal(Ok(utility.Title("Title Only", [])))
  // An explicit but empty tags line: commas only, or a bare label.
  utility.parse(True, [], "Title Only\n, ,")
  |> should.equal(Ok(utility.Title("Title Only", [])))
  utility.parse(True, [], "Title Only\nTags:")
  |> should.equal(Ok(utility.Title("Title Only", [])))
}

/// Blank lines are not protocol lines: the title and the tags line are
/// the first two MEANINGFUL lines, however the model padded them — a
/// blank line between the two must not swallow the tags.
pub fn parse_skips_blank_lines_test() {
  utility.parse(True, [], "Fix Login\n\nlogin, bug")
  |> should.equal(Ok(utility.Title("Fix Login", ["login", "bug"])))
  // Leading padding too: the title is still the first content line.
  utility.parse(True, [], "\n\nFix Login\nTags: cache")
  |> should.equal(Ok(utility.Title("Fix Login", ["cache"])))
}

/// A tags line that opens like JSON (`[`, `{`, or `"` after label
/// strip) is malformed plain text (§3.1: "No JSON"): splitting it on
/// commas would store bracketed, quoted fragments as display tags, so
/// the whole tags attempt yields zero tags — the title still applies.
pub fn parse_json_shaped_tags_line_yields_no_tags_test() {
  utility.parse(True, [], "Fix Login\n[\"login\", \"bug\"]")
  |> should.equal(Ok(utility.Title("Fix Login", [])))
  // After a `Tags:` label too.
  utility.parse(True, [], "Fix Login\nTags: [\"login\", \"bug\"]")
  |> should.equal(Ok(utility.Title("Fix Login", [])))
  // Quotes without brackets are just as JSON-shaped.
  utility.parse(True, [], "Fix Login\n\"login\", \"bug\"")
  |> should.equal(Ok(utility.Title("Fix Login", [])))
  // An object echo is malformed the same way.
  utility.parse(True, [], "Fix Login\n{\"tags\": [\"login\"]}")
  |> should.equal(Ok(utility.Title("Fix Login", [])))
}

/// A leading `Title:` / `Tags:` label on either line is stripped
/// (models like echoing the schema) — case-insensitive, and only with
/// the colon, so a word that merely starts like the label survives.
pub fn parse_strips_leading_labels_test() {
  utility.parse(True, [], "Title: Prefix Cache Basics")
  |> should.equal(Ok(utility.Title("Prefix Cache Basics", [])))
  utility.parse(True, [], "title: lowercased label")
  |> should.equal(Ok(utility.Title("lowercased label", [])))
  utility.parse(True, [], "Tags Demo\nTags: cache, retry")
  |> should.equal(Ok(utility.Title("Tags Demo", ["cache", "retry"])))
  // No colon, no strip: "Titleist" is a word, not a label.
  utility.parse(True, [], "Titleist Golf Clubs")
  |> should.equal(Ok(utility.Title("Titleist Golf Clubs", [])))
}

/// The structural K cap (§3.1): at most `max_new_tags` (2) tags ABSENT
/// from the supplied corpus survive, in reply order — and corpus tags
/// are reuse, not growth: they survive freely beside the allowance,
/// wherever they sit in the reply.
pub fn parse_caps_new_tags_at_two_corpus_reuse_free_test() {
  // Empty corpus: every tag is new — only the first two survive.
  utility.parse(True, [], "Wide Fix\nalpha, beta, gamma, delta")
  |> should.equal(Ok(utility.Title("Wide Fix", ["alpha", "beta"])))
  // Pure reuse: corpus members never count against the allowance.
  utility.parse(True, ["cache", "retry"], "Wide Fix\ncache, retry")
  |> should.equal(Ok(utility.Title("Wide Fix", ["cache", "retry"])))
  // …so the two new slots keep their places beside any number of
  // reuses; the third new tag ("new-three") is the one dropped.
  utility.parse(
    True,
    ["cache", "retry"],
    "Wide Fix\nnew-one, cache, new-two, retry, new-three",
  )
  |> should.equal(
    Ok(utility.Title("Wide Fix", ["new-one", "cache", "new-two", "retry"])),
  )
}

/// The PASS postpone sentinel (utility-titles §4.2): a whole-reply PASS —
/// case-insensitive, optionally fenced or padded — postpones when the
/// attempt allows it.
pub fn parse_pass_sentinel_postpones_when_allowed_test() {
  utility.parse(True, [], "PASS") |> should.equal(Ok(utility.Pass))
  utility.parse(True, [], "pass") |> should.equal(Ok(utility.Pass))
  utility.parse(True, [], "  Pass \n") |> should.equal(Ok(utility.Pass))
  utility.parse(True, [], "```\nPASS\n```") |> should.equal(Ok(utility.Pass))
}

/// …but only a WHOLE-reply PASS: a real title that merely contains the
/// word never postpones, and neither does trailing punctuation — the
/// instruction says exactly PASS.
pub fn parse_pass_requires_whole_string_match_test() {
  utility.parse(True, [], "Password Manager Setup")
  |> should.equal(Ok(utility.Title("Password Manager Setup", [])))
  utility.parse(True, [], "Passing Arguments in Gleam")
  |> should.equal(Ok(utility.Title("Passing Arguments in Gleam", [])))
  utility.parse(True, [], "PASS.")
  |> should.equal(Ok(utility.Title("PASS.", [])))
}

/// Under the forced instruction the model was never offered the sentinel:
/// a PASS reply is an unusable title (a failure), not a postpone — the
/// thread cannot defer twice.
pub fn parse_pass_rejected_under_forced_instruction_test() {
  utility.parse(False, [], "PASS") |> should.equal(Error(Nil))
  utility.parse(False, [], "Real Title")
  |> should.equal(Ok(utility.Title("Real Title", [])))
}

/// Hostile model output must pass through INERT (the UI renders it as a
/// text node — the no-innerHTML contract) and length-capped like any
/// other title.
pub fn parse_passes_hostile_payload_inert_and_capped_test() {
  let hostile = "<script>alert('xss')</script>"
  // Short enough to fit: it passes through verbatim — inert data.
  utility.parse(True, [], hostile)
  |> should.equal(Ok(utility.Title(hostile, [])))

  // A long payload hits the same 60-character cap (plus ellipsis) as any
  // title — never truncated mid-tag into executable markup, just data.
  let flood = string.repeat("<script>x</script>", 10)
  let assert Ok(utility.Title(capped, _tags)) = utility.parse(True, [], flood)
  should.equal(string.length(capped), 61)
  should.be_true(string.ends_with(capped, "…"))
  should.equal(capped, string.slice(flood, 0, 60) <> "…")
}

/// Hostile model output on the TAGS line too (§5): every tag passes
/// through INERT — normalized data (lowercase, kebab-case, 24-char cap),
/// never markup — exactly like titles. What the UI renders is a Lustre
/// text node; these are plain strings by the time they leave the parser.
pub fn parse_passes_hostile_tag_payloads_inert_and_normalized_test() {
  // Short payloads pass through whole, lowercased, whitespace kebab'd:
  // inert data.
  utility.parse(True, [], "Fix login\n<SCRIPT>x</SCRIPT>, <img src=q>")
  |> should.equal(
    Ok(utility.Title("Fix login", ["<script>x</script>", "<img-src=q>"])),
  )
  // A longer payload hits the same 24-character cap as any tag —
  // truncated as data, never into executable markup.
  let long = "<script>alert('xss')</script>"
  let assert Ok(utility.Title(_, [tag, ..])) =
    utility.parse(True, [], "Fix login\n" <> long)
  should.equal(tag, string.slice(string.lowercase(long), 0, 24))
}

pub fn parse_rejects_empty_and_refusal_test() {
  // A refusal arrives as no content — the same empty reply.
  utility.parse(True, [], "") |> should.equal(Error(Nil))
  // Whitespace-only and fence-only replies carry no title either. A
  // label-only title line is empty after the strip: line 1 is required,
  // and a tags line cannot save it.
  utility.parse(True, [], "  \n\t ") |> should.equal(Error(Nil))
  utility.parse(True, [], "```\n```") |> should.equal(Error(Nil))
  utility.parse(True, [], "Title:\nlogin, bug") |> should.equal(Error(Nil))
}

/// The shaping rule is the ONE implementation behind both title paths
/// (the heuristic first-message title delegates to it).
pub fn shape_title_caps_at_sixty_chars_test() {
  utility.shape_title("  padded \n title  ") |> should.equal("padded title")
  let long = string.repeat("x", 80)
  utility.shape_title(long)
  |> should.equal(string.repeat("x", 60) <> "…")
}

/// Per-tag 24-character truncation (§3.1 — the other half of the
/// 30 × 24 corpus embedding bound): internal whitespace collapses to
/// kebab-case BEFORE the cap bites, and the cap has no ellipsis — a tag
/// is filtering vocabulary, not display prose.
pub fn parse_truncates_each_tag_at_twenty_four_chars_test() {
  let thirty = string.repeat("a", 30)
  utility.parse_tags([], thirty <> ", ok")
  |> should.equal([string.repeat("a", 24), "ok"])
  // Kebab collapse first: the 27-char kebab string truncates to 24.
  utility.parse_tags([], "aaa bbb ccc ddd eee fff ggg")
  |> should.equal(["aaa-bbb-ccc-ddd-eee-fff-"])
  // Through the whole reply too (line 2 of the protocol).
  let assert Ok(utility.Title(_, tags)) =
    utility.parse(True, [], "Wide Fix\n" <> thirty)
  should.equal(tags, [string.repeat("a", 24)])
}

/// The union the registry applies (`UpgradeAutoTitle` → `merge_tags`,
/// §3.5): existing display entries keep their order VERBATIM, the
/// attempt's tags append normalized after them, duplicates through the
/// SHARED normalization never append, and the union caps at 5 per
/// thread.
pub fn merge_tags_unions_preserve_order_verbatim_and_cap_test() {
  utility.merge_tags([], ["login", "auth"])
  |> should.equal(["login", "auth"])
  // Existing order first; new tags append in reply order.
  utility.merge_tags(["work", "notes"], ["notes", "login", "auth"])
  |> should.equal(["work", "notes", "login", "auth"])
  // Cap at 5: the union truncates past the fifth entry.
  utility.merge_tags(["work", "notes"], [
    "login", "auth", "cache", "ops", "extra",
  ])
  |> should.equal(["work", "notes", "login", "auth", "cache"])
  // A legacy spelling never re-canonicalizes in the display set — and
  // never duplicates its canonical twin: the presence check compares
  // through the same kebab normalization (the §5 union test caught the
  // bare-lowercase version of this check duplicating `Work Notes` as
  // `work-notes`).
  utility.merge_tags(["Work Notes"], ["work-notes", "WORK NOTES", "login"])
  |> should.equal(["Work Notes", "login"])
  // New tags normalize before joining the union.
  utility.merge_tags(["work"], ["Login Page "])
  |> should.equal(["work", "login-page"])
}

// ---------------------------------------------------------------------------
// The instruction (§6)
// ---------------------------------------------------------------------------

pub fn instruction_forbids_tool_calls_test() {
  // The frozen tools array renders into the prompt and cannot be
  // stripped without diverging the prefix — the instruction must carry
  // the prohibition instead. BOTH variants.
  should.be_true(string.contains(
    utility.instruction(True, []),
    "Do not call any tools",
  ))
  should.be_true(string.contains(
    utility.instruction(False, []),
    "Do not call any tools",
  ))
}

/// The PASS escape hatch exists only in the allowed variant: the forced
/// instruction must not mention the sentinel at all, so a model that
/// never saw the option cannot be steered into it.
pub fn instruction_pass_escape_hatch_variant_test() {
  should.be_true(string.contains(utility.instruction(True, []), "exactly PASS"))
  should.be_false(string.contains(
    string.lowercase(utility.instruction(False, [])),
    "pass",
  ))
}

/// BOTH variants ask for the two-line reply (utility-tags plan §3.2):
/// line 1 the title, line 2 the comma-separated tag list.
pub fn instruction_asks_for_the_two_line_form_test() {
  [True, False]
  |> list.each(fn(allow_pass) {
    let y = utility.instruction(allow_pass, [])
    should.be_true(string.contains(y, "exactly two lines"))
    should.be_true(string.contains(y, "Line 1"))
    should.be_true(string.contains(y, "Line 2"))
    should.be_true(string.contains(y, "comma-separated"))
  })
}

/// The reuse corpus rides Y only when non-empty (§3.2): listed
/// (comma-joined) with the new-tag allowance when present, entirely
/// absent when empty — in BOTH variants. Y is the tail message,
/// generation-side, so the dynamic wording cannot touch the cached
/// prefix.
pub fn instruction_lists_corpus_only_when_non_empty_test() {
  let listed = utility.instruction(True, ["cache", "login", "auth"])
  should.be_true(string.contains(
    listed,
    "Prefer reusing a tag from this list when one fits: cache, login, auth",
  ))
  should.be_true(string.contains(listed, "at most 2 new tags"))
  // The forced variant carries the corpus too.
  should.be_true(string.contains(
    utility.instruction(False, ["cache"]),
    "one fits: cache",
  ))
  // Empty corpus: no reuse clause at all.
  should.be_false(string.contains(
    utility.instruction(True, []),
    "Prefer reusing",
  ))
  should.be_false(string.contains(
    utility.instruction(False, []),
    "at most 2 new tags",
  ))
  // And a corpus makes Y strictly longer — the premise of the
  // corpus-carrying prefix property above.
  should.be_true(
    string.length(utility.instruction(True, ["cache"]))
    > string.length(utility.instruction(True, [])),
  )
}

pub fn prepare_appends_exactly_one_user_message_test() {
  let tr =
    transcript.new("test-alias", "system prompt")
    |> transcript.append_user("hi")
    |> transcript.append_assistant("hello")
  let branch = utility.prepare(tr, True, [])
  transcript.length(branch) |> should.equal(4)

  // The branch adds exactly ONE message: the instruction, as a user
  // message, at the end of the chronological list — everything before it
  // is the committed snapshot, untouched.
  let messages = transcript.messages(branch)
  list.take(messages, 3) |> should.equal(transcript.messages(tr))
  let assert [chat.UserMessage(content: chat.UserTextContent(text), ..)] =
    list.drop(messages, 3)
  text |> should.equal(utility.instruction(True, []))
}
