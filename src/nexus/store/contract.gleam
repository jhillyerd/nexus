//// Shared differential `Store` contract suite (`docs/plans/verification.md`,
//// Phase 1).
////
//// Every case in `cases()` takes a fresh, empty `store.Store` and exercises
//// the exact behavioral contracts shared by `store_mock` (offline `gleam test`
//// via `test/store_contract_test.gleam`) and `nexus/store/persist` (live
//// Postgres 17 via `gleam run -m nexus/store/verify`).
////
//// Keeping this module pure Gleam under `src/` (zero `gleeunit` dependency,
//// zero direct database imports) lets both runners assert identical semantics
//// against every SQL query and seam invariant.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/bot
import nexus/crypto
import nexus/node
import nexus/store.{type Store}
import nexus/thread
import nexus/timing
import nexus/tools
import nexus/transcript

/// One named contract check over a fresh, empty `Store`.
pub type Case {
  Case(name: String, run: fn(Store) -> Result(Nil, String))
}

/// Every differential contract case, in deterministic order.
pub fn cases() -> List(Case) {
  [
    Case(
      "transcript_round_trip_and_multi_call_seq",
      case_transcript_round_trip_and_multi_call_seq,
    ),
    Case(
      "atomic_creation_roster_and_watermarks",
      case_atomic_creation_roster_and_watermarks,
    ),
    Case("bot_channels_invariants", case_bot_channels_invariants),
    Case("workspace_lifecycle_and_gc", case_workspace_lifecycle_and_gc),
    Case("metadata_guards_and_timestamps", case_metadata_guards_and_timestamps),
    Case("providers_and_bots", case_providers_and_bots),
    Case("nodes_and_pairing_grants", case_nodes_and_pairing_grants),
  ]
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

fn expect_eq(label: String, actual: a, expected: a) -> Result(Nil, String) {
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(
        label
        <> ": expected "
        <> string.inspect(expected)
        <> ", got "
        <> string.inspect(actual),
      )
  }
}

fn expect_true(label: String, cond: Bool) -> Result(Nil, String) {
  case cond {
    True -> Ok(Nil)
    False -> Error(label <> ": expected True, got False")
  }
}

fn expect_ok(label: String, res: Result(a, String)) -> Result(a, String) {
  case res {
    Ok(v) -> Ok(v)
    Error(e) -> Error(label <> ": expected Ok, got Error(" <> e <> ")")
  }
}

fn expect_err(label: String, res: Result(a, String)) -> Result(Nil, String) {
  case res {
    Ok(v) ->
      Error(label <> ": expected Error, got Ok(" <> string.inspect(v) <> ")")
    Error(_) -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

const test_epoch = 1_700_000_000

const test_crypto_key = "0123456789abcdef0123456789abcdef"

fn make_provider(
  id: String,
  name: String,
  key: Option(BitArray),
) -> store.StoredProvider {
  store.StoredProvider(
    id: id,
    name: name,
    base_url: "http://" <> id <> ".test/v1",
    api_key_encrypted: key,
    key_version: 1,
    dialect: "openai",
    enabled: True,
    created_at: test_epoch,
    updated_at: test_epoch,
  )
}

fn make_bot(id: String, name: String, provider_id: String) -> store.StoredBot {
  bot.Bot(
    id: id,
    name: name,
    description: "bot " <> name,
    provider_id: provider_id,
    model: "alias-1",
    system_prompt: Some("prompt for " <> name),
    tools: None,
    allow_inbound: True,
    created_at: test_epoch,
    updated_at: test_epoch,
  )
}

fn make_meta(
  bot_id: Option(String),
  parent_thread_id: Option(String),
  created_at: Int,
) -> thread.ThreadMeta {
  thread.ThreadMeta(
    title: "",
    title_source: thread.AutoTitle,
    pinned: False,
    tags: [],
    tags_manual: [],
    tags_source: thread.AutoTags,
    archived: False,
    bot_id: bot_id,
    parent_thread_id: parent_thread_id,
    created_at: created_at,
  )
}

fn make_summary(
  id: String,
  provider_id: String,
  bot_id: Option(String),
  parent_thread_id: Option(String),
  created_at: Int,
) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: provider_id,
    model: "alias-1",
    meta: make_meta(bot_id, parent_thread_id, created_at),
    toolset: [
      tools.ToolsetEntry(name: "web_search", description: "", schema_json: None),
    ],
    workspace_root: None,
    workspaces: None,
    roster: None,
    last_active_at: created_at,
    message_count: 1,
  )
}

fn seed_base(s: Store) -> Result(Nil, String) {
  use _ <- result.try(expect_ok(
    "seed provider p1",
    s.insert_provider(make_provider("p1", "primary", None)),
  ))
  use _ <- result.try(expect_ok(
    "seed bot b1",
    s.insert_bot(make_bot("b1", "Alpha", "p1")),
  ))
  use _ <- result.try(expect_ok(
    "seed bot b2",
    s.insert_bot(make_bot("b2", "Beta", "p1")),
  ))
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Case 1: Transcript round-trip, verbatim tool_args, multi-call seq & replay
// ---------------------------------------------------------------------------

fn case_transcript_round_trip_and_multi_call_seq(
  s: Store,
) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))

  let raw_schema =
    "{ \"type\": \"object\",  \"properties\": { \"z\": {\"type\":\"string\"}, \"a\": {\"type\":\"integer\"} } }"
  let manifest = [
    tools.ToolsetEntry(name: "http_fetch", description: "", schema_json: None),
    tools.ToolsetEntry(
      name: "mcp__srv__lookup",
      description: "Foreign lookup tool",
      schema_json: Some(raw_schema),
    ),
  ]
  let summary =
    store.StoredSummary(
      ..make_summary("t1", "p1", Some("b1"), None, test_epoch),
      toolset: manifest,
    )
  use _ <- result.try(expect_ok(
    "insert thread t1",
    s.insert_thread(summary, "Frozen system prompt."),
  ))

  // Verify foreign manifest schema_json survived verbatim (no JSON normalization).
  use stored <- result.try(expect_ok("get_thread t1", s.get_thread("t1")))
  use _ <- result.try(expect_eq(
    "manifest verbatim",
    stored.summary.toolset,
    manifest,
  ))
  use _ <- result.try(expect_eq(
    "system_prompt",
    stored.system_prompt,
    "Frozen system prompt.",
  ))

  // Non-normalized JSON strings: whitespace and key order MUST survive verbatim.
  let raw_args_1 = "{  \"z\": 1,  \"a\": [ 2, 3 ] }"
  let raw_args_2 = "{\"b\":true,   \"a\":\"keep  spaces\"}"
  let raw_args_3 = "{ }"

  // Turn 1: bot-authored user message -> 3 parallel tool calls with leading
  // text + reasoning + stamp on row 0 only -> 3 tool results (mixed ok) ->
  // final assistant with reasoning + stamp.
  let tr1 =
    transcript.new("alias-1", "Frozen system prompt.")
    |> transcript.append_user("Please run three tools")
    |> transcript.mark_origin(Some("Alpha"), 2)
    |> transcript.stamp(test_epoch + 10)
    |> transcript.append_assistant_tool_calls(
      text: Some("Calling tools now."),
      calls: [
        #("call_1", "http_fetch", raw_args_1),
        #("call_2", "mcp__srv__lookup", raw_args_2),
        #("call_3", "http_fetch", raw_args_3),
      ],
      reasoning: Some("Let me fan out three calls."),
    )
    |> transcript.stamp(test_epoch + 11)
    |> transcript.append_tool_result(
      tool_call_id: "call_1",
      content: "ok payload 1",
      ok: True,
    )
    |> transcript.stamp(test_epoch + 12)
    |> transcript.append_tool_result(
      tool_call_id: "call_2",
      content: "error payload 2",
      ok: False,
    )
    |> transcript.stamp(test_epoch + 13)
    |> transcript.append_tool_result(
      tool_call_id: "call_3",
      content: "ok payload 3",
      ok: True,
    )
    |> transcript.append_assistant_with_reasoning(
      "All three finished.",
      reasoning: Some("Summarizing outcomes."),
    )
    |> transcript.stamp(test_epoch + 14)

  s.commit("t1", tr1)

  // Synchronous load_messages orders after Commit on both actors.
  use rows1 <- result.try(expect_ok(
    "load_messages after turn 1",
    s.load_messages("t1"),
  ))
  let expected_rows1 = [
    store.UserRow(
      "Please run three tools",
      Some("Alpha"),
      2,
      Some(test_epoch + 10),
    ),
    store.ToolCallRow(
      content: "Calling tools now.",
      call_id: "call_1",
      name: "http_fetch",
      arguments: raw_args_1,
      reasoning: Some("Let me fan out three calls."),
      at: Some(test_epoch + 11),
    ),
    store.ToolCallRow(
      content: "",
      call_id: "call_2",
      name: "mcp__srv__lookup",
      arguments: raw_args_2,
      reasoning: None,
      at: None,
    ),
    store.ToolCallRow(
      content: "",
      call_id: "call_3",
      name: "http_fetch",
      arguments: raw_args_3,
      reasoning: None,
      at: None,
    ),
    store.ToolResultRow(
      "call_1",
      "http_fetch",
      True,
      "ok payload 1",
      Some(test_epoch + 12),
    ),
    store.ToolResultRow(
      "call_2",
      "mcp__srv__lookup",
      False,
      "error payload 2",
      Some(test_epoch + 13),
    ),
    store.ToolResultRow("call_3", "http_fetch", True, "ok payload 3", None),
    store.AssistantRow(
      "All three finished.",
      Some("Summarizing outcomes."),
      Some(test_epoch + 14),
    ),
  ]
  use _ <- result.try(expect_eq("turn 1 rows exact", rows1, expected_rows1))

  // Hydrated transcript must produce byte-identical request JSON.
  let hydrated1 =
    store.transcript_from_rows("alias-1", "Frozen system prompt.", rows1)
  use _ <- result.try(expect_eq(
    "turn 1 request body byte-identical",
    transcript.request_body(hydrated1, transcript.default_options()),
    transcript.request_body(tr1, transcript.default_options()),
  ))

  // Turn 2 AFTER a multi-call Turn 1: pins the seq-offset invariant (Turn 1
  // had 7 messages including system prompt, but 8 rows!).
  let tr2 =
    tr1
    |> transcript.append_user("Follow-up question")
    |> transcript.stamp(test_epoch + 20)
    |> transcript.append_assistant("Follow-up answer")
    |> transcript.stamp(test_epoch + 21)

  s.commit("t1", tr2)
  use rows2 <- result.try(expect_ok(
    "load_messages after turn 2",
    s.load_messages("t1"),
  ))
  let expected_rows2 =
    list.append(expected_rows1, [
      store.UserRow("Follow-up question", None, 0, Some(test_epoch + 20)),
      store.AssistantRow("Follow-up answer", None, Some(test_epoch + 21)),
    ])
  use _ <- result.try(expect_eq(
    "turn 2 rows exact (no seq collision)",
    rows2,
    expected_rows2,
  ))

  use after2 <- result.try(expect_ok(
    "get_thread after turn 2",
    s.get_thread("t1"),
  ))
  use _ <- result.try(expect_eq(
    "message_count after turn 2",
    after2.summary.message_count,
    transcript.length(tr2),
  ))

  let hydrated2 =
    store.transcript_from_rows("alias-1", "Frozen system prompt.", rows2)
  use _ <- result.try(expect_eq(
    "turn 2 request body byte-identical",
    transcript.request_body(hydrated2, transcript.default_options()),
    transcript.request_body(tr2, transcript.default_options()),
  ))

  // Idempotent replay: re-committing tr2 or older tr1 changes nothing.
  s.commit("t1", tr2)
  s.commit("t1", tr1)
  use rows_replay <- result.try(expect_ok(
    "load_messages after replay",
    s.load_messages("t1"),
  ))
  use _ <- result.try(expect_eq(
    "replay rows unchanged",
    rows_replay,
    expected_rows2,
  ))
  use after_replay <- result.try(expect_ok(
    "get_thread after replay",
    s.get_thread("t1"),
  ))
  use _ <- result.try(expect_eq(
    "replay message_count unchanged",
    after_replay.summary.message_count,
    transcript.length(tr2),
  ))

  // Unknown thread: load_messages returns Ok([]), and committing to an unknown
  // thread drops cleanly without breaking subsequent reads.
  use missing_rows <- result.try(expect_ok(
    "load_messages unknown thread",
    s.load_messages("does-not-exist"),
  ))
  use _ <- result.try(expect_eq("unknown thread rows empty", missing_rows, []))
  s.commit("does-not-exist", tr2)
  s.commit("does-not-exist", tr2)
  use still_ok <- result.try(expect_ok(
    "get_thread t1 after unknown commit",
    s.get_thread("t1"),
  ))
  expect_eq("t1 untouched", still_ok.summary.id, "t1")
}

// ---------------------------------------------------------------------------
// Case 2: Atomic creation, creation-time roster row, watermarks & FK checks
// ---------------------------------------------------------------------------

fn case_atomic_creation_roster_and_watermarks(s: Store) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))

  let roster_text = "Attached environments: workspace"
  let env_summary =
    store.StoredSummary(
      id: "t-env",
      provider_id: "p1",
      model: "alias-1",
      meta: thread.ThreadMeta(
        ..make_meta(Some("b1"), None, test_epoch),
        tags: ["seed-tag"],
        // Fresh inserts must ignore passed manual provenance / archived state.
        tags_manual: ["ignored"],
        tags_source: thread.ManualTags,
        archived: True,
      ),
      toolset: [
        tools.ToolsetEntry(name: "bash", description: "", schema_json: None),
      ],
      workspace_root: Some("/srv/workspaces"),
      workspaces: Some(store.ThreadWorkspaces(
        workspace_id: "ws-thread-t-env",
        rel_path: "threads/t-env",
        tmp_id: Some("ws-tmp-t-env"),
        tmp_rel_path: Some("tmp/t-env"),
      )),
      roster: Some(#(roster_text, test_epoch + 1)),
      last_active_at: test_epoch + 999,
      message_count: 2,
    )

  use _ <- result.try(expect_ok(
    "insert env thread",
    s.insert_thread(env_summary, "Env prompt"),
  ))

  // Duplicate thread id refused (thread_pkey).
  use _ <- result.try(expect_err(
    "duplicate thread id",
    s.insert_thread(env_summary, "Env prompt"),
  ))

  // Unknown provider / bot / parent FKs refused.
  use _ <- result.try(expect_err(
    "unknown provider FK",
    s.insert_thread(
      make_summary("t-bad-p", "p-nope", None, None, test_epoch),
      "s",
    ),
  ))
  use _ <- result.try(expect_err(
    "unknown bot FK",
    s.insert_thread(
      make_summary("t-bad-b", "p1", Some("b-nope"), None, test_epoch),
      "s",
    ),
  ))
  use _ <- result.try(expect_err(
    "unknown parent FK",
    s.insert_thread(
      make_summary("t-bad-parent", "p1", Some("b1"), Some("t-nope"), test_epoch),
      "s",
    ),
  ))

  // Check get_thread and list_summaries agree and reflect insert defaults.
  use got <- result.try(expect_ok("get_thread t-env", s.get_thread("t-env")))
  use #(summaries, skipped) <- result.try(expect_ok(
    "list_summaries",
    s.list_summaries(),
  ))
  use _ <- result.try(expect_eq("skipped corrupt rows", skipped, []))
  use _ <- result.try(
    expect_eq("list_summaries matches get_thread", summaries, [got.summary]),
  )
  use _ <- result.try(expect_eq(
    "roster cleared on read",
    got.summary.roster,
    None,
  ))
  use _ <- result.try(expect_eq(
    "archived false on insert",
    got.summary.meta.archived,
    False,
  ))
  use _ <- result.try(
    expect_eq("tags_manual empty on insert", got.summary.meta.tags_manual, []),
  )
  use _ <- result.try(expect_eq(
    "tags_source auto on insert",
    got.summary.meta.tags_source,
    thread.AutoTags,
  ))
  use _ <- result.try(expect_eq(
    "last_active_at equals created_at on insert",
    got.summary.last_active_at,
    test_epoch,
  ))
  use _ <- result.try(expect_eq(
    "workspaces round-tripped",
    got.summary.workspaces,
    env_summary.workspaces,
  ))

  // Creation-time roster row exists at seq 0 BEFORE any Commit.
  use initial_rows <- result.try(expect_ok(
    "initial load_messages",
    s.load_messages("t-env"),
  ))
  let expected_roster =
    store.UserRow(roster_text, Some("system"), 0, Some(test_epoch + 1))
  use _ <- result.try(
    expect_eq("creation-time roster row", initial_rows, [expected_roster]),
  )

  // First turn Commit starts at watermark=2 (system + roster), appending user
  // at seq 1 and assistant at seq 2 without duplicating or skipping the roster.
  let tr =
    transcript.new("alias-1", "Env prompt")
    |> transcript.append_user(roster_text)
    |> transcript.mark_origin(Some("system"), 0)
    |> transcript.stamp(test_epoch + 1)
    |> transcript.append_user("ls")
    |> transcript.stamp(test_epoch + 5)
    |> transcript.append_assistant("done")
    |> transcript.stamp(test_epoch + 6)

  s.commit("t-env", tr)
  use after_rows <- result.try(expect_ok(
    "load_messages after first turn",
    s.load_messages("t-env"),
  ))
  expect_eq("roster + first turn rows", after_rows, [
    expected_roster,
    store.UserRow("ls", None, 0, Some(test_epoch + 5)),
    store.AssistantRow("done", None, Some(test_epoch + 6)),
  ])
}

// ---------------------------------------------------------------------------
// Case 3: Bot channels, partial unique index, recursive archive/delete, prune
// ---------------------------------------------------------------------------

fn case_bot_channels_invariants(s: Store) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))
  let now = timing.wall_now_s()
  let old = now - 3600

  // Parent p -> channel c1 (b1) -> grandchild g1 (b2), plus ordinary sibling.
  use _ <- result.try(expect_ok(
    "insert parent p",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("p", "p1", Some("b1"), None, now),
        message_count: 3,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert ordinary sibling s-ord with same bot b1",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("s-ord", "p1", Some("b1"), None, now),
        message_count: 3,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert channel c1",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("c1", "p1", Some("b1"), Some("p"), now),
        message_count: 3,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert grandchild g1",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("g1", "p1", Some("b2"), Some("c1"), now),
        message_count: 3,
      ),
      "sys",
    ),
  ))

  // thread_channel partial unique index refuses duplicate (parent, bot).
  use _ <- result.try(expect_err(
    "duplicate channel (p, b1) refused",
    s.insert_thread(
      make_summary("c1-dup", "p1", Some("b1"), Some("p"), now),
      "sys",
    ),
  ))

  // find_channel re-derivation.
  use fc1 <- result.try(expect_ok(
    "find_channel p b1",
    s.find_channel("p", "b1"),
  ))
  use _ <- result.try(expect_eq("find_channel p b1 hit", fc1, Some("c1")))
  use fc2 <- result.try(expect_ok(
    "find_channel p b2",
    s.find_channel("p", "b2"),
  ))
  use _ <- result.try(expect_eq("find_channel p b2 miss", fc2, None))
  use fc3 <- result.try(expect_ok(
    "find_channel c1 b2",
    s.find_channel("c1", "b2"),
  ))
  use _ <- result.try(expect_eq("find_channel c1 b2 hit", fc3, Some("g1")))

  // Pin all four, then archive p -> recursive cascade archives p, c1, g1 and
  // clears their pins while leaving s-ord untouched.
  use _ <- result.try(expect_ok("pin p", s.set_pinned("p", True)))
  use _ <- result.try(expect_ok("pin c1", s.set_pinned("c1", True)))
  use _ <- result.try(expect_ok("pin g1", s.set_pinned("g1", True)))
  use _ <- result.try(expect_ok("pin s-ord", s.set_pinned("s-ord", True)))
  use _ <- result.try(expect_ok("archive p", s.archive("p")))

  use gp <- result.try(expect_ok("get p", s.get_thread("p")))
  use gc1 <- result.try(expect_ok("get c1", s.get_thread("c1")))
  use gg1 <- result.try(expect_ok("get g1", s.get_thread("g1")))
  use gord <- result.try(expect_ok("get s-ord", s.get_thread("s-ord")))
  use _ <- result.try(
    expect_eq(
      "p archived+unpinned",
      #(gp.summary.meta.archived, gp.summary.meta.pinned),
      #(True, False),
    ),
  )
  use _ <- result.try(
    expect_eq(
      "c1 archived+unpinned",
      #(gc1.summary.meta.archived, gc1.summary.meta.pinned),
      #(True, False),
    ),
  )
  use _ <- result.try(
    expect_eq(
      "g1 archived+unpinned",
      #(gg1.summary.meta.archived, gg1.summary.meta.pinned),
      #(True, False),
    ),
  )
  use _ <- result.try(
    expect_eq(
      "s-ord active+pinned",
      #(gord.summary.meta.archived, gord.summary.meta.pinned),
      #(False, True),
    ),
  )

  // Unarchive p -> symmetric recursive cascade restores p, c1, g1.
  use _ <- result.try(expect_ok("unarchive p", s.unarchive("p")))
  use up <- result.try(expect_ok("get p unarchived", s.get_thread("p")))
  use uc1 <- result.try(expect_ok("get c1 unarchived", s.get_thread("c1")))
  use ug1 <- result.try(expect_ok("get g1 unarchived", s.get_thread("g1")))
  use _ <- result.try(
    expect_eq(
      "subtree unarchived",
      #(
        up.summary.meta.archived,
        uc1.summary.meta.archived,
        ug1.summary.meta.archived,
      ),
      #(False, False, False),
    ),
  )

  // ON DELETE SET NULL on bot delete: c1 survives with bot_id = None and
  // frozen model/provider intact.
  use _ <- result.try(expect_ok("delete bot b1", s.delete_bot("b1")))
  use c1_after_bot <- result.try(expect_ok(
    "get c1 after delete_bot",
    s.get_thread("c1"),
  ))
  use _ <- result.try(expect_eq(
    "c1 bot_id nulled",
    c1_after_bot.summary.meta.bot_id,
    None,
  ))
  use _ <- result.try(expect_eq(
    "c1 model preserved",
    c1_after_bot.summary.model,
    "alias-1",
  ))

  // PruneNeverUsed: parent-with-children guard + env ceiling + age + pin + manual title.
  use _ <- result.try(expect_ok(
    "insert old-parent",
    s.insert_thread(make_summary("old-parent", "p1", None, None, old), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert old-child under old-parent",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("old-child", "p1", Some("b2"), Some("old-parent"), old),
        message_count: 3,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert old-orphan",
    s.insert_thread(make_summary("old-orphan", "p1", None, None, old), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert old-env (message_count 2 = never used)",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("old-env", "p1", None, None, old),
        workspace_root: Some("/srv/ws"),
        message_count: 2,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert old-env-used (message_count 3 = used)",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("old-env-used", "p1", None, None, old),
        workspace_root: Some("/srv/ws"),
        message_count: 3,
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert old-pinned",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("old-pinned", "p1", None, None, old),
        meta: thread.ThreadMeta(..make_meta(None, None, old), pinned: True),
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert old-manual-title",
    s.insert_thread(
      store.StoredSummary(
        ..make_summary("old-manual", "p1", None, None, old),
        meta: thread.ThreadMeta(
          ..make_meta(None, None, old),
          title: "keep",
          title_source: thread.ManualTitle,
        ),
      ),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert fresh-empty",
    s.insert_thread(make_summary("fresh-empty", "p1", None, None, now), "sys"),
  ))

  use pruned <- result.try(expect_ok("prune_never_used", s.prune_never_used()))
  use _ <- result.try(
    expect_eq("pruned ids exact", pruned, ["old-env", "old-orphan"]),
  )
  use _ <- result.try(expect_ok(
    "old-parent survived prune",
    s.get_thread("old-parent"),
  ))
  use _ <- result.try(expect_ok(
    "old-child survived prune",
    s.get_thread("old-child"),
  ))
  use _ <- result.try(expect_ok(
    "old-env-used survived prune",
    s.get_thread("old-env-used"),
  ))
  use _ <- result.try(expect_ok(
    "old-pinned survived prune",
    s.get_thread("old-pinned"),
  ))
  use _ <- result.try(expect_ok(
    "old-manual survived prune",
    s.get_thread("old-manual"),
  ))
  use _ <- result.try(expect_ok(
    "fresh-empty survived prune",
    s.get_thread("fresh-empty"),
  ))

  // Delete p -> ON DELETE CASCADE deletes p, c1, g1; s-ord stays.
  use _ <- result.try(expect_ok("delete_thread p", s.delete_thread("p")))
  use _ <- result.try(expect_err("p gone", s.get_thread("p")))
  use _ <- result.try(expect_err("c1 cascaded", s.get_thread("c1")))
  use _ <- result.try(expect_err("g1 cascaded", s.get_thread("g1")))
  use _ <- result.try(expect_ok("s-ord untouched", s.get_thread("s-ord")))
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Case 4: Workspace lifecycle, cascade tombstones, shared bot ws & GC
// ---------------------------------------------------------------------------

fn case_workspace_lifecycle_and_gc(s: Store) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))
  let now = timing.wall_now_s()
  let old = now - 3600
  let root = "/srv/ws"

  let env_thread = fn(id: String, parent: Option(String), ts: Int, count: Int) {
    store.StoredSummary(
      ..make_summary(id, "p1", None, parent, ts),
      workspace_root: Some(root),
      workspaces: Some(store.ThreadWorkspaces(
        workspace_id: "ws-thread-" <> id,
        rel_path: "threads/" <> id,
        tmp_id: Some("ws-tmp-" <> id),
        tmp_rel_path: Some("tmp/" <> id),
      )),
      message_count: count,
    )
  }

  // Cascade delete tombstones parent + child thread & tmp workspaces.
  use _ <- result.try(expect_ok(
    "insert t1",
    s.insert_thread(env_thread("t1", None, now, 3), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert t2 under t1",
    s.insert_thread(env_thread("t2", Some("t1"), now, 3), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert live sibling t3",
    s.insert_thread(env_thread("t3", None, now, 3), "sys"),
  ))

  // delete_workspace on a LIVE workspace must be a no-op.
  use _ <- result.try(expect_ok(
    "delete_workspace on live row is no-op",
    s.delete_workspace("ws-thread-t3"),
  ))
  use t3_still <- result.try(expect_ok(
    "t3 still has workspace",
    s.get_thread("t3"),
  ))
  use _ <- result.try(expect_eq(
    "t3 workspace intact",
    t3_still.summary.workspaces,
    Some(store.ThreadWorkspaces(
      workspace_id: "ws-thread-t3",
      rel_path: "threads/t3",
      tmp_id: Some("ws-tmp-t3"),
      tmp_rel_path: Some("tmp/t3"),
    )),
  ))

  use tombstoned <- result.try(expect_ok(
    "delete_thread t1",
    s.delete_thread("t1"),
  ))
  let expected_ids = ["ws-thread-t1", "ws-thread-t2", "ws-tmp-t1", "ws-tmp-t2"]
  use _ <- result.try(expect_eq(
    "t1 cascade tombstoned ids",
    list.map(tombstoned, fn(w) { w.id }),
    expected_ids,
  ))

  use pending <- result.try(expect_ok(
    "list_deleted_workspaces",
    s.list_deleted_workspaces(),
  ))
  use _ <- result.try(expect_eq(
    "list_deleted_workspaces sorted ids",
    list.map(pending, fn(w) { w.id }) |> list.sort(string.compare),
    expected_ids,
  ))

  // Delete one tombstoned workspace and verify it disappears from pending GC.
  use _ <- result.try(expect_ok(
    "delete_workspace ws-tmp-t1",
    s.delete_workspace("ws-tmp-t1"),
  ))
  use pending2 <- result.try(expect_ok(
    "list_deleted_workspaces after gc",
    s.list_deleted_workspaces(),
  ))
  use _ <- result.try(
    expect_eq(
      "ws-tmp-t1 removed",
      list.map(pending2, fn(w) { w.id }) |> list.sort(string.compare),
      ["ws-thread-t1", "ws-thread-t2", "ws-tmp-t2"],
    ),
  )

  // Shared BotWorkspace constraints & ref-counted tombstoning.
  let ws_b1 =
    store.StoredWorkspace(
      id: "ws-bot-b1",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b1",
      thread_id: None,
      bot_id: Some("b1"),
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    )
  use _ <- result.try(expect_ok("insert ws-bot-b1", s.insert_workspace(ws_b1)))
  // Duplicate live BotWorkspace for b1 refused (workspace_bot_live).
  use _ <- result.try(expect_err(
    "duplicate live bot workspace refused",
    s.insert_workspace(
      store.StoredWorkspace(
        ..ws_b1,
        id: "ws-bot-b1-dup",
        rel_path: "bots/b1-dup",
      ),
    ),
  ))
  // Duplicate (root, rel_path) refused (workspace_path).
  use _ <- result.try(expect_err(
    "duplicate workspace_path refused",
    s.insert_workspace(
      store.StoredWorkspace(..ws_b1, id: "ws-bot-path-dup", bot_id: Some("b2")),
    ),
  ))

  // Unreferenced bot delete immediately tombstones ws-bot-b1.
  use b1_tomb <- result.try(expect_ok("delete_bot b1", s.delete_bot("b1")))
  use _ <- result.try(
    expect_eq(
      "b1 unreferenced ws tombstoned",
      list.map(b1_tomb, fn(w) { w.id }),
      ["ws-bot-b1"],
    ),
  )

  // Referenced bot workspace stays live across delete_bot until last thread dies.
  let ws_b2 =
    store.StoredWorkspace(
      id: "ws-bot-b2",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b2",
      thread_id: None,
      bot_id: Some("b2"),
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    )
  use _ <- result.try(expect_ok("insert ws-bot-b2", s.insert_workspace(ws_b2)))
  let shared_thread = fn(id: String) {
    store.StoredSummary(
      ..make_summary(id, "p1", Some("b2"), None, now),
      workspace_root: Some(root),
      workspaces: Some(store.ThreadWorkspaces(
        workspace_id: "ws-bot-b2",
        rel_path: "bots/b2",
        tmp_id: Some("ws-tmp-" <> id),
        tmp_rel_path: Some("tmp/" <> id),
      )),
      message_count: 3,
    )
  }
  use _ <- result.try(expect_ok(
    "insert tb1",
    s.insert_thread(shared_thread("tb1"), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert tb2",
    s.insert_thread(shared_thread("tb2"), "sys"),
  ))

  use b2_tomb <- result.try(expect_ok(
    "delete_bot b2 (still referenced)",
    s.delete_bot("b2"),
  ))
  use _ <- result.try(expect_eq("b2 ws stays live", b2_tomb, []))

  use tb1_tomb <- result.try(expect_ok(
    "delete_thread tb1",
    s.delete_thread("tb1"),
  ))
  use _ <- result.try(
    expect_eq("tb1 tombstones only tmp", list.map(tb1_tomb, fn(w) { w.id }), [
      "ws-tmp-tb1",
    ]),
  )

  use tb2_tomb <- result.try(expect_ok(
    "delete_thread tb2 (last ref)",
    s.delete_thread("tb2"),
  ))
  use _ <- result.try(
    expect_eq(
      "tb2 tombstones orphaned bot ws + tmp",
      list.map(tb2_tomb, fn(w) { w.id }),
      ["ws-bot-b2", "ws-tmp-tb2"],
    ),
  )

  // prune_never_used also tombstones workspaces of pruned env threads.
  use _ <- result.try(expect_ok(
    "insert stale never-used env thread",
    s.insert_thread(env_thread("t-stale", None, old, 2), "sys"),
  ))
  use pruned <- result.try(expect_ok("prune_never_used", s.prune_never_used()))
  use _ <- result.try(expect_eq("t-stale pruned", pruned, ["t-stale"]))
  use pending3 <- result.try(expect_ok(
    "list_deleted_workspaces after prune",
    s.list_deleted_workspaces(),
  ))
  let pending3_ids = list.map(pending3, fn(w) { w.id })
  use _ <- result.try(expect_true(
    "ws-thread-t-stale tombstoned",
    list.contains(pending3_ids, "ws-thread-t-stale"),
  ))
  expect_true(
    "ws-tmp-t-stale tombstoned",
    list.contains(pending3_ids, "ws-tmp-t-stale"),
  )
}

// ---------------------------------------------------------------------------
// Case 5: Metadata guards & timestamp round-trips
// ---------------------------------------------------------------------------

fn case_metadata_guards_and_timestamps(s: Store) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))

  use _ <- result.try(expect_ok(
    "insert t1",
    s.insert_thread(
      make_summary("t1", "p1", Some("b1"), None, test_epoch),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert t2",
    s.insert_thread(
      make_summary("t2", "p1", Some("b1"), None, test_epoch),
      "sys",
    ),
  ))
  use _ <- result.try(expect_ok(
    "insert t3",
    s.insert_thread(
      make_summary("t3", "p1", Some("b1"), None, test_epoch),
      "sys",
    ),
  ))

  // auto_title applies once on untouched auto default, then refuses.
  use a1 <- result.try(expect_ok(
    "auto_title first",
    s.auto_title("t1", "Heuristic"),
  ))
  use _ <- result.try(expect_eq("auto_title first applied", a1, True))
  use a2 <- result.try(expect_ok(
    "auto_title second",
    s.auto_title("t1", "Second"),
  ))
  use _ <- result.try(expect_eq("auto_title second refused", a2, False))
  use a_missing <- result.try(expect_ok(
    "auto_title missing",
    s.auto_title("nope", "X"),
  ))
  use _ <- result.try(expect_eq(
    "auto_title missing returns False",
    a_missing,
    False,
  ))

  // auto_meta_upgrade replaces auto title + tags while both sources stay auto.
  use u1 <- result.try(expect_ok(
    "auto_meta_upgrade first",
    s.auto_meta_upgrade("t1", "Model Title", ["alpha", "beta"]),
  ))
  use _ <- result.try(expect_eq("upgrade 1 applied", u1, True))
  use t1_u1 <- result.try(expect_ok("get t1 after u1", s.get_thread("t1")))
  use _ <- result.try(expect_eq(
    "t1 title",
    t1_u1.summary.meta.title,
    "Model Title",
  ))
  use _ <- result.try(
    expect_eq("t1 tags", t1_u1.summary.meta.tags, ["alpha", "beta"]),
  )
  use _ <- result.try(expect_eq(
    "t1 title_source still auto",
    t1_u1.summary.meta.title_source,
    thread.AutoTitle,
  ))
  use _ <- result.try(expect_eq(
    "t1 tags_source still auto",
    t1_u1.summary.meta.tags_source,
    thread.AutoTags,
  ))

  // Manual rename closes auto_meta_upgrade forever on t2.
  use _ <- result.try(expect_ok(
    "set_title t2",
    s.set_title("t2", "Custom Name"),
  ))
  use u2 <- result.try(expect_ok(
    "auto_meta_upgrade refused after manual title",
    s.auto_meta_upgrade("t2", "Sneaky", ["bad"]),
  ))
  use _ <- result.try(expect_eq("u2 refused", u2, False))
  use t2 <- result.try(expect_ok("get t2", s.get_thread("t2")))
  use _ <- result.try(expect_eq(
    "t2 title kept",
    t2.summary.meta.title,
    "Custom Name",
  ))
  use _ <- result.try(expect_eq("t2 tags untouched", t2.summary.meta.tags, []))
  use _ <- result.try(expect_eq(
    "t2 title_source manual",
    t2.summary.meta.title_source,
    thread.ManualTitle,
  ))

  // Manual set_tags atomically sets tags, tags_manual, and ManualTags — and
  // closes auto_meta_upgrade on BOTH title and tags for t3.
  use _ <- result.try(expect_ok(
    "set_tags t3",
    s.set_tags("t3", ["mine", "pinned-tag"]),
  ))
  use u3 <- result.try(expect_ok(
    "auto_meta_upgrade refused after manual tags",
    s.auto_meta_upgrade("t3", "Sneaky Title", ["auto-tag"]),
  ))
  use _ <- result.try(expect_eq("u3 refused", u3, False))
  use t3 <- result.try(expect_ok("get t3", s.get_thread("t3")))
  use _ <- result.try(expect_eq("t3 title untouched", t3.summary.meta.title, ""))
  use _ <- result.try(
    expect_eq("t3 tags", t3.summary.meta.tags, ["mine", "pinned-tag"]),
  )
  use _ <- result.try(
    expect_eq("t3 tags_manual", t3.summary.meta.tags_manual, [
      "mine",
      "pinned-tag",
    ]),
  )
  use _ <- result.try(expect_eq(
    "t3 tags_source manual",
    t3.summary.meta.tags_source,
    thread.ManualTags,
  ))

  // Unknown thread id on auto_meta_upgrade returns Ok(False).
  use u_missing <- result.try(expect_ok(
    "auto_meta_upgrade missing",
    s.auto_meta_upgrade("nope", "X", []),
  ))
  use _ <- result.try(expect_eq(
    "auto_meta_upgrade missing returns False",
    u_missing,
    False,
  ))

  // Pin & archive-clears-pin + created_at epoch preservation.
  use _ <- result.try(expect_ok("set_pinned t1 True", s.set_pinned("t1", True)))
  use t1_pinned <- result.try(expect_ok("get t1 pinned", s.get_thread("t1")))
  use _ <- result.try(expect_eq(
    "t1 pinned",
    t1_pinned.summary.meta.pinned,
    True,
  ))
  use _ <- result.try(expect_ok("archive t1", s.archive("t1")))
  use t1_arch <- result.try(expect_ok("get t1 archived", s.get_thread("t1")))
  use _ <- result.try(
    expect_eq(
      "t1 archived clears pin",
      #(t1_arch.summary.meta.archived, t1_arch.summary.meta.pinned),
      #(True, False),
    ),
  )
  expect_eq(
    "t1 created_at exact epoch",
    t1_arch.summary.meta.created_at,
    test_epoch,
  )
}

// ---------------------------------------------------------------------------
// Case 6: Providers & bots (ciphertext, replace_key, guards, CI uniqueness)
// ---------------------------------------------------------------------------

fn case_providers_and_bots(s: Store) -> Result(Nil, String) {
  let key_bytes = bit_array.from_string(test_crypto_key)
  use env1 <- result.try(expect_ok(
    "encrypt env1",
    crypto.encrypt(key_bytes, "p1", "sk-secret-1")
      |> result.map_error(string.inspect),
  ))
  use env2 <- result.try(expect_ok(
    "encrypt env2",
    crypto.encrypt(key_bytes, "p1", "sk-secret-2")
      |> result.map_error(string.inspect),
  ))

  use _ <- result.try(expect_ok(
    "insert keyed p1",
    s.insert_provider(make_provider("p1", "OpenAI", Some(env1))),
  ))
  use _ <- result.try(expect_ok(
    "insert keyless p2",
    s.insert_provider(make_provider("p2", "Local", None)),
  ))
  // Duplicate id & name refused.
  use _ <- result.try(expect_err(
    "duplicate provider id",
    s.insert_provider(make_provider("p1", "Other", None)),
  ))
  use _ <- result.try(expect_err(
    "duplicate provider name",
    s.insert_provider(make_provider("p3", "OpenAI", None)),
  ))
  use _ <- result.try(expect_err("get unknown provider", s.get_provider("nope")))

  // Ciphertext round-trip & decrypt under AAD.
  use p1 <- result.try(expect_ok("get p1", s.get_provider("p1")))
  use _ <- result.try(expect_eq(
    "p1 ciphertext exact",
    p1.api_key_encrypted,
    Some(env1),
  ))
  use p2 <- result.try(expect_ok("get p2", s.get_provider("p2")))
  use _ <- result.try(expect_eq("p2 keyless", p2.api_key_encrypted, None))
  use all_p <- result.try(expect_ok("list_providers", s.list_providers()))
  use _ <- result.try(
    expect_eq("list_providers id-ordered", list.map(all_p, fn(p) { p.id }), [
      "p1",
      "p2",
    ]),
  )

  // update_provider with replace_key=False keeps envelope, key_version, created_at, dialect.
  use _ <- result.try(expect_ok(
    "update p1 replace_key=False",
    s.update_provider(
      store.StoredProvider(
        ..make_provider("p1", "OpenAI-Renamed", None),
        base_url: "http://new.test/v1",
        key_version: 99,
        dialect: "mutated",
        enabled: False,
        created_at: 9_999_999_999,
        updated_at: 9_999_999_999,
      ),
      False,
    ),
  ))
  use p1_kept <- result.try(expect_ok(
    "get p1 after keep-key update",
    s.get_provider("p1"),
  ))
  use _ <- result.try(expect_eq("p1 renamed", p1_kept.name, "OpenAI-Renamed"))
  use _ <- result.try(expect_eq(
    "p1 key kept",
    p1_kept.api_key_encrypted,
    Some(env1),
  ))
  use _ <- result.try(expect_eq("p1 key_version kept", p1_kept.key_version, 1))
  use _ <- result.try(expect_eq("p1 dialect kept", p1_kept.dialect, "openai"))
  use _ <- result.try(expect_eq(
    "p1 created_at kept",
    p1_kept.created_at,
    test_epoch,
  ))
  use _ <- result.try(expect_eq("p1 enabled false", p1_kept.enabled, False))

  // Rename collision refused.
  use _ <- result.try(expect_err(
    "update provider rename collision",
    s.update_provider(make_provider("p1", "Local", None), False),
  ))

  // replace_key=True replaces envelope, then clears to keyless (None).
  use _ <- result.try(expect_ok(
    "update p1 replace_key=True env2",
    s.update_provider(
      store.StoredProvider(
        ..make_provider("p1", "OpenAI-Renamed", Some(env2)),
        key_version: 2,
      ),
      True,
    ),
  ))
  use p1_rot <- result.try(expect_ok("get p1 rotated", s.get_provider("p1")))
  use _ <- result.try(expect_eq("p1 env2", p1_rot.api_key_encrypted, Some(env2)))
  use _ <- result.try(expect_eq("p1 version 2", p1_rot.key_version, 2))

  use _ <- result.try(expect_ok(
    "update p1 replace_key=True None",
    s.update_provider(
      store.StoredProvider(
        ..make_provider("p1", "OpenAI-Renamed", None),
        key_version: 3,
      ),
      True,
    ),
  ))
  use p1_none <- result.try(expect_ok("get p1 keyless", s.get_provider("p1")))
  use _ <- result.try(expect_eq(
    "p1 now keyless",
    p1_none.api_key_encrypted,
    None,
  ))

  // Bots: tools tri-state (None vs Some([]) vs Some([...])), CI-unique name,
  // allow_inbound, FK guards.
  let b1 =
    bot.Bot(
      ..make_bot("b1", "Researcher", "p1"),
      system_prompt: None,
      tools: Some([]),
      allow_inbound: False,
    )
  use _ <- result.try(expect_ok("insert b1", s.insert_bot(b1)))
  use _ <- result.try(expect_err(
    "bot CI duplicate name refused",
    s.insert_bot(make_bot("b2", "researcher", "p1")),
  ))
  use _ <- result.try(expect_err(
    "bot unknown provider refused",
    s.insert_bot(make_bot("b2", "Other", "p-nope")),
  ))
  use got_b1 <- result.try(expect_ok("get b1", s.get_bot("b1")))
  use _ <- result.try(expect_eq(
    "b1 system_prompt None",
    got_b1.system_prompt,
    None,
  ))
  use _ <- result.try(expect_eq("b1 tools Some([])", got_b1.tools, Some([])))
  use _ <- result.try(expect_eq(
    "b1 allow_inbound False",
    got_b1.allow_inbound,
    False,
  ))

  // Update bot across tools states and verify created_at preserved.
  use _ <- result.try(expect_ok(
    "update b1",
    s.update_bot(
      bot.Bot(
        ..b1,
        name: "Analyst",
        system_prompt: Some("Custom sys"),
        tools: Some(["web_search", "http_fetch"]),
        allow_inbound: True,
        created_at: 9_999_999_999,
      ),
    ),
  ))
  use got_b1_u <- result.try(expect_ok("get b1 updated", s.get_bot("b1")))
  use _ <- result.try(expect_eq("b1 name updated", got_b1_u.name, "Analyst"))
  use _ <- result.try(expect_eq(
    "b1 system_prompt Some",
    got_b1_u.system_prompt,
    Some("Custom sys"),
  ))
  use _ <- result.try(expect_eq(
    "b1 tools explicit",
    got_b1_u.tools,
    Some(["web_search", "http_fetch"]),
  ))
  use _ <- result.try(expect_eq(
    "b1 allow_inbound True",
    got_b1_u.allow_inbound,
    True,
  ))
  use _ <- result.try(expect_eq(
    "b1 created_at preserved",
    got_b1_u.created_at,
    test_epoch,
  ))
  use _ <- result.try(expect_true(
    "b1 updated_at >= created_at",
    got_b1_u.updated_at >= test_epoch,
  ))

  // Switch b1.tools back to None (default sentinel).
  use _ <- result.try(expect_ok(
    "update b1 tools None",
    s.update_bot(bot.Bot(..got_b1_u, tools: None)),
  ))
  use got_b1_def <- result.try(expect_ok(
    "get b1 default tools",
    s.get_bot("b1"),
  ))
  use _ <- result.try(expect_eq("b1 tools None", got_b1_def.tools, None))

  // Provider delete guard: blocked by bot AND by thread; counts match.
  use _ <- result.try(expect_ok(
    "insert thread pinning p1",
    s.insert_thread(
      make_summary("t1", "p1", Some("b1"), None, test_epoch),
      "sys",
    ),
  ))
  use tc <- result.try(expect_ok(
    "count_threads_for_provider",
    s.count_threads_for_provider("p1"),
  ))
  use _ <- result.try(expect_eq("thread count 1", tc, 1))
  use bc <- result.try(expect_ok(
    "count_bots_for_provider",
    s.count_bots_for_provider("p1"),
  ))
  use _ <- result.try(expect_eq("bot count 1", bc, 1))
  use _ <- result.try(expect_err(
    "delete_provider blocked by thread+bot",
    s.delete_provider("p1"),
  ))

  use _ <- result.try(expect_ok("delete thread t1", s.delete_thread("t1")))
  use _ <- result.try(expect_err(
    "delete_provider still blocked by bot",
    s.delete_provider("p1"),
  ))

  use _ <- result.try(expect_ok("delete bot b1", s.delete_bot("b1")))
  use _ <- result.try(expect_ok(
    "delete_provider succeeds once unreferenced",
    s.delete_provider("p1"),
  ))
  expect_err("p1 deleted", s.get_provider("p1"))
}

// ---------------------------------------------------------------------------
// Case 7: Nodes, per-thread name scoping, idle sweep, grants & cascades
// ---------------------------------------------------------------------------

fn case_nodes_and_pairing_grants(s: Store) -> Result(Nil, String) {
  use _ <- result.try(seed_base(s))
  let now = timing.wall_now_s()
  let ten_days_ago = now - 10 * 86_400

  use _ <- result.try(expect_ok(
    "insert t1",
    s.insert_thread(make_summary("t1", "p1", Some("b1"), None, now), "sys"),
  ))
  use _ <- result.try(expect_ok(
    "insert t2",
    s.insert_thread(make_summary("t2", "p1", Some("b1"), None, now), "sys"),
  ))

  let n1 =
    node.Node(
      id: "n1",
      thread_id: "t1",
      name: "laptop",
      token_hash: "hash-1",
      created_at: ten_days_ago,
      last_seen_at: None,
    )
  // Same node name allowed on a DIFFERENT thread (per-thread uniqueness).
  let n2 =
    node.Node(
      id: "n2",
      thread_id: "t2",
      name: "laptop",
      token_hash: "hash-2",
      created_at: ten_days_ago,
      last_seen_at: None,
    )
  let n3 =
    node.Node(
      id: "n3",
      thread_id: "t2",
      name: "fresh-box",
      token_hash: "hash-3",
      created_at: now,
      last_seen_at: None,
    )
  use _ <- result.try(expect_ok("insert n1", s.insert_node(n1)))
  use _ <- result.try(expect_ok(
    "insert n2 (same name, diff thread)",
    s.insert_node(n2),
  ))
  use _ <- result.try(expect_ok("insert n3", s.insert_node(n3)))

  // Duplicate (thread_id, name), duplicate id, and unknown thread refused.
  use _ <- result.try(expect_err(
    "duplicate (thread_id, name) refused",
    s.insert_node(node.Node(..n1, id: "n1-dup")),
  ))
  use _ <- result.try(expect_err(
    "duplicate node id refused",
    s.insert_node(node.Node(..n1, name: "other")),
  ))
  use _ <- result.try(expect_err(
    "unknown thread_id on node refused",
    s.insert_node(node.Node(..n1, id: "n-bad", thread_id: "t-nope", name: "x")),
  ))

  // Scoped lookup & list ordering.
  use got_n1 <- result.try(expect_ok(
    "get_thread_node t1 laptop",
    s.get_thread_node("t1", "laptop"),
  ))
  use _ <- result.try(expect_eq("got n1 exact", got_n1, n1))
  use _ <- result.try(expect_err(
    "get_thread_node wrong thread",
    s.get_thread_node("t1", "fresh-box"),
  ))
  use all_n <- result.try(expect_ok("list_nodes", s.list_nodes()))
  use _ <- result.try(
    expect_eq("list_nodes id-ordered", list.map(all_n, fn(n) { n.id }), [
      "n1",
      "n2",
      "n3",
    ]),
  )

  // Touch n2 -> last_seen_at becomes recent, so idle sweep deletes ONLY n1.
  use _ <- result.try(expect_ok("touch_node n2", s.touch_node("n2")))
  use touched_n2 <- result.try(expect_ok(
    "get touched n2",
    s.get_thread_node("t2", "laptop"),
  ))
  use _ <- result.try(case touched_n2.last_seen_at {
    Some(ts) -> expect_true("n2 last_seen_at recent", ts >= now - 60)
    None -> Error("n2 last_seen_at should be Some after touch")
  })

  use swept <- result.try(expect_ok(
    "delete_idle_nodes(7)",
    s.delete_idle_nodes(7),
  ))
  use _ <- result.try(
    expect_eq("swept idle node names", list.sort(swept, string.compare), [
      "laptop",
    ]),
  )
  use _ <- result.try(expect_err("n1 swept", s.get_thread_node("t1", "laptop")))
  use _ <- result.try(expect_ok(
    "n2 kept (touched)",
    s.get_thread_node("t2", "laptop"),
  ))
  use _ <- result.try(expect_ok(
    "n3 kept (fresh)",
    s.get_thread_node("t2", "fresh-box"),
  ))

  // Pairing grants: pinned, unpinned, expired sweep, touch increment, delete.
  let g_exp =
    node.Grant(
      id: "g1",
      code_hash: "ch-1",
      thread_id: Some("t2"),
      created_at: now - 7200,
      expires_at: now - 3600,
      use_count: 0,
      last_used_at: None,
    )
  let g_live =
    node.Grant(
      id: "g2",
      code_hash: "ch-2",
      thread_id: Some("t2"),
      created_at: now,
      expires_at: now + 3600,
      use_count: 0,
      last_used_at: None,
    )
  let g_unpinned =
    node.Grant(
      id: "g3",
      code_hash: "ch-3",
      thread_id: None,
      created_at: now,
      expires_at: now + 3600,
      use_count: 0,
      last_used_at: None,
    )
  use _ <- result.try(expect_ok("insert g1", s.insert_node_grant(g_exp)))
  use _ <- result.try(expect_ok("insert g2", s.insert_node_grant(g_live)))
  use _ <- result.try(expect_ok(
    "insert g3 (unpinned)",
    s.insert_node_grant(g_unpinned),
  ))
  use _ <- result.try(expect_err(
    "duplicate grant id",
    s.insert_node_grant(g_live),
  ))
  use _ <- result.try(expect_err(
    "unknown thread on grant",
    s.insert_node_grant(
      node.Grant(..g_live, id: "g-bad", thread_id: Some("t-nope")),
    ),
  ))

  use _ <- result.try(expect_ok("touch g2 #1", s.touch_node_grant("g2")))
  use _ <- result.try(expect_ok("touch g2 #2", s.touch_node_grant("g2")))
  use _ <- result.try(expect_ok(
    "delete_expired_node_grants",
    s.delete_expired_node_grants(),
  ))

  use grants_after <- result.try(expect_ok(
    "list_node_grants",
    s.list_node_grants(),
  ))
  use _ <- result.try(
    expect_eq(
      "only live grants remain",
      list.map(grants_after, fn(g) { #(g.id, g.use_count) }),
      [#("g2", 2), #("g3", 0)],
    ),
  )
  use _ <- result.try(case grants_after {
    [g2_row, _] ->
      case g2_row.last_used_at {
        Some(ts) -> expect_true("g2 last_used_at recent", ts >= now - 60)
        None -> Error("g2 last_used_at should be Some after touch")
      }
    _ -> Error("expected 2 grants")
  })

  // Delete thread t2 -> CASCADEs n2, n3 and pinned grant g2, leaving unpinned g3.
  use _ <- result.try(expect_ok("delete_thread t2", s.delete_thread("t2")))
  use nodes_after <- result.try(expect_ok(
    "list_nodes after t2 delete",
    s.list_nodes(),
  ))
  use _ <- result.try(expect_eq("t2 nodes cascaded", nodes_after, []))
  use grants_final <- result.try(expect_ok(
    "list_node_grants after t2 delete",
    s.list_node_grants(),
  ))
  use _ <- result.try(
    expect_eq(
      "pinned g2 cascaded, unpinned g3 kept",
      list.map(grants_final, fn(g) { g.id }),
      ["g3"],
    ),
  )

  // Idempotent deletes on grants & nodes.
  use _ <- result.try(expect_ok(
    "delete_node_grant g3",
    s.delete_node_grant("g3"),
  ))
  use _ <- result.try(expect_ok(
    "delete_node_grant missing",
    s.delete_node_grant("g3"),
  ))
  use _ <- result.try(expect_ok(
    "delete_node missing",
    s.delete_node("n-missing"),
  ))
  use grants_empty <- result.try(expect_ok(
    "list_node_grants empty",
    s.list_node_grants(),
  ))
  expect_eq("all grants gone", grants_empty, [])
}
