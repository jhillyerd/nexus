//// Offline tests for the M3 Lustre server-component UI: init/update
//// behaviour (selection, token assembly, turn terminal states, reconnect)
//// and view rendering (element/text APIs only, no innerHTML).

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import lustre/element
import nexus/provider
import nexus/session
import nexus/ui
import nexus/ui_settings

fn new_model() -> ui.Model {
  let #(model, _effect) =
    ui.init(ui.Flags(
      registry: process.new_subject(),
      providers: process.new_subject(),
      session: None,
    ))
  model
}

/// A model whose connection supplied a last-selected session (the /ws
/// route's `session` parameter, persisted by the page shell).
fn new_model_with_session(id: Option(String)) -> ui.Model {
  let #(model, _effect) =
    ui.init(ui.Flags(
      registry: process.new_subject(),
      providers: process.new_subject(),
      session: id,
    ))
  model
}

fn step(model: ui.Model, msg: ui.Msg) -> ui.Model {
  let #(next, _effect) = ui.update(model, msg)
  next
}

fn summary(id: String, streaming: Bool) -> session.SessionSummary {
  session.SessionSummary(
    id: id,
    provider_id: "p1",
    model: "smart",
    title: "",
    title_source: session.AutoTitle,
    pinned: False,
    tags: [],
    archived: False,
    message_count: 0,
    streaming: streaming,
    created_at: 0,
    last_active_at: 0,
    metrics: [],
  )
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

pub fn init_starts_empty_test() {
  let model = new_model()
  model.sessions |> should.equal([])
  model.aliases |> should.equal([])
  model.selected |> should.equal(None)
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log |> should.equal([])
  model.model_label |> should.equal("connecting…")
}

// ---------------------------------------------------------------------------
// Session list / selection
// ---------------------------------------------------------------------------

pub fn sessions_auto_select_first_test() {
  let model = new_model() |> step(ui.SessionsLoaded([summary("s-1", False)]))
  model.selected |> should.equal(Some("s-1"))
  model.create_open |> should.be_false
}

pub fn sessions_empty_opens_create_panel_test() {
  let model = new_model() |> step(ui.SessionsLoaded([]))
  model.selected |> should.equal(None)
  model.create_open |> should.be_true
}

pub fn select_resets_log_and_streams_test() {
  let model =
    new_model()
    |> step(ui.SessionsLoaded([summary("s-1", False), summary("s-2", False)]))
    |> step(ui.Hello("smart", []))
    |> step(ui.UserEcho("hi"))
    |> step(ui.Select("s-2"))
  model.selected |> should.equal(Some("s-2"))
  model.log |> should.equal([])
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.model_label |> should.equal("connecting…")
}

pub fn select_same_session_is_noop_test() {
  let model = new_model() |> step(ui.Select("s-1"))
  let again = step(model, ui.Select("s-1"))
  again.log |> should.equal(model.log)
  again.model_label |> should.equal(model.model_label)
}

pub fn vanished_selection_ends_session_test() {
  let model =
    new_model()
    |> step(ui.SessionsLoaded([summary("s-1", False)]))
    |> step(ui.Hello("smart", []))
    |> step(ui.UserEcho("hi"))
    |> step(ui.Token("par"))
  let model = model |> step(ui.SessionsLoaded([]))
  model.selected |> should.equal(None)
  model.log |> should.equal([])
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.model_label |> should.equal("session ended")
  model.create_open |> should.be_true
}

pub fn hello_sets_label_and_busy_state_test() {
  let model =
    new_model()
    |> step(ui.SessionsLoaded([summary("s-1", True)]))
    |> step(ui.Hello("smart", []))
  model.model_label |> should.equal("smart")
  model.streaming |> should.be_true
}

// ---------------------------------------------------------------------------
// Token assembly / turn terminal states
// ---------------------------------------------------------------------------

pub fn tokens_assemble_into_bubble_test() {
  let model =
    new_model()
    |> step(ui.Token("Hel"))
    |> step(ui.Token("lo "))
    |> step(ui.Token("world"))
  model.bubble |> should.equal(Some("Hello world"))
  model.streaming |> should.be_true
}

pub fn turn_done_commits_bubble_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Token("Hel"))
    |> step(ui.Token("lo"))
    |> step(ui.TurnDone)
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> list.reverse
  |> should.equal([ui.UserLine("hi"), ui.AssistantLine("Hello")])
}

pub fn turn_stopped_commits_partial_test() {
  let model = new_model() |> step(ui.Token("par")) |> step(ui.TurnStopped)
  model.bubble |> should.equal(None)
  model.log |> should.equal([ui.AssistantLine("par")])
}

pub fn turn_failed_discards_partial_test() {
  let model =
    new_model()
    |> step(ui.Token("par"))
    |> step(ui.TurnFailed("boom"))
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> should.equal([ui.NoteLine(err: True, text: "turn failed: boom")])
}

pub fn replay_events_render_in_order_test() {
  let model =
    new_model()
    |> step(ui.AssistantFull("old answer"))
    |> step(ui.UserEcho("hi"))
  model.log
  |> list.reverse
  |> should.equal([ui.AssistantLine("old answer"), ui.UserLine("hi")])
}

// ---------------------------------------------------------------------------
// Composer / stop / send state
// ---------------------------------------------------------------------------

pub fn send_rejected_busy_note_test() {
  let model = new_model() |> step(ui.SendRejected("busy"))
  model.log
  |> should.equal([
    ui.NoteLine(err: True, text: "a reply is already streaming — stop it first"),
  ])
}

pub fn send_accepted_rotates_composer_and_streams_test() {
  let model = new_model() |> step(ui.SendAccepted)
  model.composer |> should.equal(1)
  model.streaming |> should.be_true
}

pub fn send_requested_with_blank_text_is_noop_test() {
  let model = new_model() |> step(ui.SendRequested("   "))
  model.composer |> should.equal(0)
  model.streaming |> should.be_false
}

pub fn send_requested_without_session_is_noop_test() {
  let model = new_model() |> step(ui.SendRequested("hi"))
  model.composer |> should.equal(0)
  model.streaming |> should.be_false
}

pub fn stop_keeps_state_until_terminal_event_test() {
  let model = new_model() |> step(ui.StopRequested)
  model.streaming |> should.be_false
  model.log |> should.equal([])
}

// ---------------------------------------------------------------------------
// Per-client connect (the runtime break)
// ---------------------------------------------------------------------------

/// A first-time visitor supplies no session: nothing is selected until the
/// loaded list auto-selects (or the user picks one).
pub fn init_without_client_session_selects_nothing_test() {
  new_model().selected |> should.equal(None)
}

/// A reload supplies the client's last-selected session: the fresh
/// per-connection model re-opens exactly that one.
pub fn init_with_client_session_preselects_it_test() {
  new_model_with_session(Some("s1")).selected
  |> should.equal(Some("s1"))
}

/// The supplied session survives the session-list load: the auto-selection
/// rule (first active) must not clobber it.
pub fn sessions_loaded_keeps_client_session_test() {
  let model =
    new_model_with_session(Some("s2"))
    |> step(ui.SessionsLoaded([summary("s1", False), summary("s2", False)]))
  model.selected |> should.equal(Some("s2"))
}

/// A stale supplied session (deleted server-side while the tab was away)
/// drops out and the auto-selection rules take over — same as any other
/// vanished selection.
pub fn sessions_loaded_drops_stale_client_session_test() {
  let model =
    new_model_with_session(Some("gone"))
    |> step(ui.SessionsLoaded([summary("s1", False), summary("s2", False)]))
  model.selected |> should.equal(Some("s1"))
}

/// A fresh model can see Hello (replay) before the summaries land; Hello
/// then finds an empty session list and reports `streaming: False`. The
/// loaded summary must reconcile the busy state — otherwise the composer
/// looks idle and a send is rejected with "busy" mid-stream.
pub fn sessions_loaded_reconciles_streaming_after_hello_test() {
  let model =
    new_model_with_session(Some("s1"))
    |> step(ui.Hello("smart", []))
    |> step(ui.SessionsLoaded([summary("s1", True)]))
  model.streaming |> should.be_true
}

/// The reconcile only fires for the unchanged selection: a vanished or
/// switched selection keeps the state `after_sessions` computed.
pub fn sessions_loaded_reconcile_skips_changed_selection_test() {
  let model =
    new_model_with_session(Some("gone"))
    |> step(ui.Hello("smart", []))
    |> step(ui.SessionsLoaded([summary("s1", True)]))
  model.selected |> should.equal(Some("s1"))
  model.streaming |> should.be_false
}

// ---------------------------------------------------------------------------
// Event translation
// ---------------------------------------------------------------------------

pub fn event_translation_test() {
  ui.from_session_event(session.Hello("smart", 3, []))
  |> should.equal(ui.Hello("smart", []))
  ui.from_session_event(session.UserEcho("hi"))
  |> should.equal(ui.UserEcho("hi"))
  ui.from_session_event(session.AssistantFull("full"))
  |> should.equal(ui.AssistantFull("full"))
  ui.from_session_event(session.Token("t"))
  |> should.equal(ui.Token("t"))
  ui.from_session_event(session.TurnStopped(4))
  |> should.equal(ui.TurnStopped)
  ui.from_session_event(session.TurnFailed("x"))
  |> should.equal(ui.TurnFailed("x"))
}

// ---------------------------------------------------------------------------
// Tool calls: live assembly, statuses, results
// ---------------------------------------------------------------------------

pub fn tool_deltas_accumulate_into_pending_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"que"))
    |> step(ui.ToolCallDelta(0, None, None, "ry\":\"cats\"}"))
  model.pending
  |> should.equal([
    ui.PendingCall(
      0,
      Some("call_1"),
      Some("web_search"),
      "{\"query\":\"cats\"}",
    ),
  ])
  model.streaming |> should.be_true
}

pub fn tool_delta_keeps_parallel_calls_separate_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(1, Some("call_b"), Some("http_fetch"), "{\"b"))
    |> step(ui.ToolCallDelta(0, Some("call_a"), Some("web_search"), "{\"a"))
    |> step(ui.ToolCallDelta(1, None, None, "\":1}"))
  model.pending
  |> should.equal([
    ui.PendingCall(0, Some("call_a"), Some("web_search"), "{\"a"),
    ui.PendingCall(1, Some("call_b"), Some("http_fetch"), "{\"b\":1}"),
  ])
}

pub fn tool_delta_commits_bubble_first_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("look this up"))
    |> step(ui.Token("checking"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{}"))
  model.log
  |> list.reverse
  |> should.equal([
    ui.UserLine("look this up"),
    ui.AssistantLine("checking"),
  ])
  model.bubble |> should.equal(None)
}

pub fn tool_assembled_replaces_pending_with_running_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"q"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{\"query\":\"cats\"}"))
  model.pending |> should.equal([])
  model.log
  |> should.equal([
    ui.ToolLine(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      ui.ToolRunning,
      None,
    ),
  ])
}

pub fn tools_phase_clears_stale_pending_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"q"))
    |> step(ui.LoopStatus(1, 8, "tools"))
  model.pending |> should.equal([])
  model.loop
  |> should.equal(Some(ui.LoopState(1, 8, "tools")))
}

pub fn tool_result_completes_matching_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{\"query\":\"cats\"}"))
    |> step(ui.ToolResult(
      "call_1",
      "web_search",
      True,
      "[{\"title\":\"cats\"}]",
    ))
  model.log
  |> should.equal([
    ui.ToolLine(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      ui.ToolDone(True),
      Some("[{\"title\":\"cats\"}]"),
    ),
  ])
}

pub fn tool_result_failure_marks_card_failed_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_9", "http_fetch", "{}"))
    |> step(ui.ToolResult("call_9", "http_fetch", False, "{\"error\":\"ssrf\"}"))
  let assert [ui.ToolLine(_, _, _, status, result), ..] = model.log
  status |> should.equal(ui.ToolDone(False))
  result |> should.equal(Some("{\"error\":\"ssrf\"}"))
}

pub fn unmatched_tool_result_becomes_completed_card_test() {
  let model =
    new_model()
    |> step(ui.ToolResult("call_x", "web_search", True, "[]"))
  model.log
  |> should.equal([
    ui.ToolLine("call_x", "web_search", "", ui.ToolDone(True), Some("[]")),
  ])
}

pub fn turn_done_commits_tool_round_and_clears_loop_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("search"))
    |> step(ui.Token("looking"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}"))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(2, 8, "request"))
    |> step(ui.Token("found it"))
    |> step(ui.TurnDone)
  model.loop |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> list.reverse
  |> should.equal([
    ui.UserLine("search"),
    ui.AssistantLine("looking"),
    ui.ToolLine("call_1", "web_search", "{}", ui.ToolDone(True), Some("[]")),
    ui.AssistantLine("found it"),
  ])
}

pub fn turn_stopped_drops_pending_keeps_completed_rounds_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}"))
    |> step(ui.ToolResult("call_1", "http_fetch", True, "ok"))
    |> step(ui.ToolCallDelta(0, Some("call_2"), Some("web_search"), "{\"q"))
    |> step(ui.Token("partial"))
    |> step(ui.TurnStopped)
  model.pending |> should.equal([])
  model.log
  |> list.reverse
  |> should.equal([
    ui.ToolLine("call_1", "http_fetch", "{}", ui.ToolDone(True), Some("ok")),
    ui.AssistantLine("partial"),
  ])
}

pub fn turn_failed_rolls_back_uncommitted_turn_test() {
  let model =
    new_model()
    |> step(ui.AssistantFull("previous answer"))
    |> step(ui.UserEcho("search"))
    |> step(ui.Token("looking"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}"))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(2, 8, "request"))
    |> step(ui.Token("more"))
    |> step(ui.TurnFailed("transport error: boom"))
  // Nothing from the failed turn survives except the user line and note.
  model.log
  |> list.reverse
  |> should.equal([
    ui.AssistantLine("previous answer"),
    ui.UserLine("search"),
    ui.NoteLine(err: True, text: "turn failed: transport error: boom"),
  ])
  model.bubble |> should.equal(None)
  model.pending |> should.equal([])
  model.loop |> should.equal(None)
  model.streaming |> should.be_false
}

pub fn guard_failure_keeps_committed_rounds_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("keep searching"))
    |> step(ui.Token("partial text"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}"))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(8, 8, "guard"))
    |> step(ui.TurnFailed("iteration guard: reached max 8 model round-trips"))
  // The guard commits final text + completed rounds; only the never-run
  // trailing call is absent.
  model.log
  |> list.reverse
  |> should.equal([
    ui.UserLine("keep searching"),
    ui.AssistantLine("partial text"),
    ui.ToolLine("call_1", "web_search", "{}", ui.ToolDone(True), Some("[]")),
    ui.NoteLine(
      err: True,
      text: "turn failed: iteration guard: reached max 8 model round-trips",
    ),
  ])
  model.guard |> should.be_false
}

// ---------------------------------------------------------------------------
// Replay reconstruction
// ---------------------------------------------------------------------------

/// Hello replay order: user echo, assistant text, assembled calls, results.
/// The component must rebuild the same card structure live events produce.
pub fn replay_reconstructs_complete_tool_history_test() {
  let model =
    new_model()
    |> step(ui.Hello("smart", []))
    |> step(ui.UserEcho("search for cats"))
    |> step(ui.AssistantFull("checking"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{\"query\":\"cats\"}"))
    |> step(ui.ToolResult(
      "call_1",
      "web_search",
      True,
      "[{\"title\":\"cats\"}]",
    ))
    |> step(ui.AssistantFull("cats are great"))
  model.log
  |> list.reverse
  |> should.equal([
    ui.UserLine("search for cats"),
    ui.AssistantLine("checking"),
    ui.ToolLine(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      ui.ToolDone(True),
      Some("[{\"title\":\"cats\"}]"),
    ),
    ui.AssistantLine("cats are great"),
  ])
  model.pending |> should.equal([])
}

// ---------------------------------------------------------------------------
// Tool view rendering
// ---------------------------------------------------------------------------

pub fn view_renders_tool_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{\"query\":\"cats\"}"))
    |> step(ui.ToolResult(
      "call_1",
      "web_search",
      True,
      "[{\"title\":\"cats\"}]",
    ))
  let html = view_string(model)
  should.be_true(string.contains(html, "turn tool done"))
  should.be_true(string.contains(html, "data-call-id=\"call_1\""))
  should.be_true(string.contains(html, "data-tool=\"web_search\""))
  should.be_true(string.contains(html, ">web_search</strong>"))
  should.be_true(string.contains(html, ">completed</span>"))
  // Lustre escapes quotes in text nodes.
  should.be_true(string.contains(html, "{&quot;query&quot;:&quot;cats&quot;}"))
  should.be_true(string.contains(html, "[{&quot;title&quot;:&quot;cats&quot;}]"))
}

pub fn view_renders_running_and_failed_states_test() {
  let running =
    new_model() |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}"))
  running |> view_string |> should_contain("turn tool running")
  running |> view_string |> should_contain(">running</span>")
  let failed =
    new_model()
    |> step(ui.ToolCallAssembled("call_2", "http_fetch", "{}"))
    |> step(ui.ToolResult("call_2", "http_fetch", False, "{\"error\":\"no\"}"))
  failed |> view_string |> should_contain("turn tool failed")
  failed |> view_string |> should_contain(">failed</span>")
}

pub fn view_truncates_tool_previews_test() {
  let long_args = string.repeat("a", 500)
  let long_result = string.repeat("r", 500)
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", long_args))
    |> step(ui.ToolResult("call_1", "http_fetch", True, long_result))
  let html = view_string(model)
  // 120-char argument preview + ellipsis, 200-char result preview.
  should.be_true(string.contains(html, string.repeat("a", 120) <> "…"))
  should.be_false(string.contains(html, string.repeat("a", 121)))
  should.be_true(string.contains(html, string.repeat("r", 200) <> "…"))
  should.be_false(string.contains(html, string.repeat("r", 201)))
}

pub fn view_renders_pending_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"que"))
  let html = view_string(model)
  should.be_true(string.contains(html, "turn tool running pending"))
  should.be_true(string.contains(html, "data-call-index=\"0\""))
  should.be_true(string.contains(html, ">web_search</strong>"))
  should.be_true(string.contains(html, "{&quot;que"))
}

pub fn view_escapes_tool_content_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("<x>", "web_search", "{}"))
    |> step(ui.ToolResult(
      "<x>",
      "web_search",
      True,
      "<script>alert(1)</script>",
    ))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>alert"))
}

pub fn view_renders_loop_chip_test() {
  let model = new_model() |> step(ui.LoopStatus(2, 8, "tools"))
  let html = view_string(model)
  should.be_true(string.contains(html, "id=\"loop-status\""))
  should.be_true(string.contains(html, "iter 2/8 · tools"))
}

pub fn view_hides_loop_chip_without_loop_test() {
  // Lustre SSR sorts attributes: hidden precedes id.
  new_model() |> view_string |> should_contain("hidden id=\"loop-status\"")
}

pub fn view_renders_guard_chip_terminal_test() {
  let model = new_model() |> step(ui.LoopStatus(8, 8, "guard"))
  model |> view_string |> should_contain("iter 8/8 · guard")
  let terminal = model |> step(ui.TurnFailed("iteration guard: reached max 8"))
  terminal |> view_string |> should_contain("turn failed: iteration guard")
}

fn should_contain(haystack: String, needle: String) {
  should.be_true(string.contains(haystack, needle))
}

fn should_not_contain(haystack: String, needle: String) {
  should.be_false(string.contains(haystack, needle))
}

// ---------------------------------------------------------------------------
// View strings
// ---------------------------------------------------------------------------

fn view_string(model: ui.Model) -> String {
  element.to_string(ui.view(model))
}

pub fn view_renders_shell_and_sidebar_test() {
  let model =
    new_model()
    |> step(ui.AliasesLoaded("p1", ["smart", "fast"]))
    |> step(ui.SessionsLoaded([summary("s-1", False)]))
  let html = view_string(model)
  should.be_true(string.contains(html, "id=\"app\""))
  should.be_true(string.contains(html, "id=\"session-list\""))
  // M3 organization: the row carries the session id and the model alias as
  // its subtitle (title falls back to the alias until auto-titled).
  should.be_true(string.contains(html, "data-session-id=\"s-1\""))
  should.be_true(string.contains(html, "smart · "))
  should.be_true(string.contains(html, "aria-current=\"true\""))
  should.be_true(string.contains(html, "id=\"model-picker\""))
  should.be_true(string.contains(html, "value=\"fast\""))
  should.be_true(string.contains(html, "id=\"tag-filter\""))
  should.be_true(string.contains(html, "Show archived"))
  // No raw HTML injection: dynamic text is escaped by Lustre text nodes.
  should.be_false(string.contains(html, "innerHTML"))
}

pub fn view_renders_empty_states_test() {
  let html = new_model() |> view_string
  should.be_true(string.contains(html, "No sessions yet."))
  should.be_true(string.contains(html, "No turns yet."))
  should.be_true(string.contains(html, "disabled"))
}

/// The composer must be an uncontrolled textarea inside a keyed form: the
/// key (invisible in HTML) rotates on every accepted send so the client
/// runtime replaces — and thereby clears — the element.
pub fn view_renders_keyed_composer_form_test() {
  let html = new_model() |> view_string
  // Lustre SSR sorts attributes, so `action` precedes `id` on the form.
  should.be_true(string.contains(html, "<form action=\"#\" id=\"composer\""))
  should.be_true(string.contains(html, "<textarea"))
  should.be_true(string.contains(html, "name=\"text\""))
  // Submit (not click) carries the field value; Stop must opt out of it.
  should.be_true(string.contains(html, "type=\"submit\""))
  should.be_true(string.contains(html, "type=\"button\""))
  // No draft text is ever rendered into the element: it stays uncontrolled.
  should.be_false(string.contains(html, ">hello</textarea>"))
}

pub fn composer_key_rotates_after_send_test() {
  let before = new_model() |> view_string
  let after = new_model() |> step(ui.SendAccepted) |> view_string
  should.be_true(string.contains(before, "autofocus"))
  should.be_true(string.contains(after, "autofocus"))
  // The generation counter lives in the (virtual) key, not the HTML; the
  // observable contract is that the model rotates it exactly once.
  let model = new_model() |> step(ui.SendAccepted)
  model.composer |> should.equal(1)
}

pub fn view_escapes_markup_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("<script>alert(1)</script>"))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>alert"))
}

pub fn view_renders_streaming_bubble_test() {
  let model = new_model() |> step(ui.Token("Hel")) |> step(ui.Token("lo"))
  let html = view_string(model)
  should.be_true(string.contains(html, "Hello"))
  should.be_true(string.contains(html, "turn assistant"))
}

pub fn view_renders_metrics_line_test() {
  let sample =
    session.MetricSample(
      outcome: session.Completed,
      ttft_ms: Some(12),
      duration_ms: 345,
      token_deltas: 2,
      prompt_tokens: Some(100),
      cached_tokens: Some(80),
      stopped_chars: None,
      failure_reason: None,
    )
  let model = new_model() |> step(ui.Hello("smart", [sample]))
  let html = view_string(model)
  should.be_true(string.contains(html, "completed"))
  should.be_true(string.contains(html, "TTFT 12ms"))
  should.be_true(string.contains(html, "cached 80/100"))
}

pub fn metric_line_variants_test() {
  ui.metric_line(session.MetricSample(
    outcome: session.Stopped,
    ttft_ms: None,
    duration_ms: 10,
    token_deltas: 1,
    prompt_tokens: None,
    cached_tokens: None,
    stopped_chars: Some(4),
    failure_reason: None,
  ))
  |> should.equal("TTFT – · 10ms · 1 deltas · stopped at 4 chars")

  ui.metric_line(session.MetricSample(
    outcome: session.Failed,
    ttft_ms: None,
    duration_ms: 10,
    token_deltas: 1,
    prompt_tokens: None,
    cached_tokens: None,
    stopped_chars: None,
    failure_reason: Some("upstream"),
  ))
  |> should.equal("TTFT – · 10ms · 1 deltas · upstream")
}

// ---------------------------------------------------------------------------
// M3 session organization: buckets, relative time, filter, update flows
// ---------------------------------------------------------------------------

/// 1970-01-03T00:00:10Z — a frozen "now" so bucket edges are exact.
const bucket_now = 172_810

pub fn bucket_boundaries_test() {
  // Same UTC day (and future skew): Today.
  ui.bucket(bucket_now, bucket_now) |> should.equal(ui.Today)
  ui.bucket(bucket_now, 172_800) |> should.equal(ui.Today)
  ui.bucket(bucket_now, bucket_now + 500) |> should.equal(ui.Today)
  // One second before the day boundary: yesterday.
  ui.bucket(bucket_now, 172_799) |> should.equal(ui.Yesterday)
  ui.bucket(bucket_now, 86_400) |> should.equal(ui.Yesterday)
  // Two to seven days back: the previous-7-days bucket. (Pre-epoch
  // values are exact multiples so integer truncation stays predictable.)
  ui.bucket(bucket_now, 86_399) |> should.equal(ui.Previous7Days)
  ui.bucket(bucket_now, 0) |> should.equal(ui.Previous7Days)
  ui.bucket(bucket_now, -5 * 86_400) |> should.equal(ui.Previous7Days)
  // Eight days back and older: Older.
  ui.bucket(bucket_now, -9 * 86_400) |> should.equal(ui.Older)
  ui.bucket(bucket_now, -30 * 86_400) |> should.equal(ui.Older)
  // Labels are the rendered group headings.
  ui.bucket_label(ui.Today) |> should.equal("Today")
  ui.bucket_label(ui.Yesterday) |> should.equal("Yesterday")
  ui.bucket_label(ui.Previous7Days) |> should.equal("Previous 7 days")
  ui.bucket_label(ui.Older) |> should.equal("Older")
}

pub fn rel_time_buckets_test() {
  ui.rel_time(1000, 1000) |> should.equal("just now")
  ui.rel_time(1059, 1000) |> should.equal("just now")
  ui.rel_time(1060, 1000) |> should.equal("1m")
  ui.rel_time(1000 + 3599, 1000) |> should.equal("59m")
  ui.rel_time(1000 + 3600, 1000) |> should.equal("1h")
  ui.rel_time(1000 + 86_399, 1000) |> should.equal("23h")
  ui.rel_time(1000 + 86_400, 1000) |> should.equal("1d")
  ui.rel_time(1000 + 6 * 86_400, 1000) |> should.equal("6d")
  ui.rel_time(1000 + 7 * 86_400, 1000) |> should.equal("1w")
  ui.rel_time(1000 + 364 * 86_400, 1000) |> should.equal("52w")
  ui.rel_time(1000 + 365 * 86_400, 1000) |> should.equal("1y")
  // Clock skew reads as "just now", never a negative age.
  ui.rel_time(1000, 2000) |> should.equal("just now")
}

pub fn parse_tags_test() {
  ui.parse_tags("work, notes ,, work,GPT ")
  |> should.equal(["work", "notes", "GPT"])
  ui.parse_tags("  ") |> should.equal([])
  ui.parse_tags("") |> should.equal([])
  ui.parse_tags("single") |> should.equal(["single"])
}

pub fn matches_filter_test() {
  let s = meta_summary("s-1", "Deploy notes", False, ["Ops", "infra"], False, 0)
  // Empty filter matches everything.
  ui.matches_filter(s, "") |> should.be_true
  ui.matches_filter(s, "   ") |> should.be_true
  // Title and tags, case-insensitively.
  ui.matches_filter(s, "deploy") |> should.be_true
  ui.matches_filter(s, "DEPLOY") |> should.be_true
  ui.matches_filter(s, "ops") |> should.be_true
  ui.matches_filter(s, "INFRA") |> should.be_true
  ui.matches_filter(s, "notes") |> should.be_true
  // No match on unrelated text.
  ui.matches_filter(s, "cooking") |> should.be_false
}

/// A summary with explicit organization metadata for the tests below.
fn meta_summary(
  id: String,
  title: String,
  pinned: Bool,
  tags: List(String),
  archived: Bool,
  last_active_at: Int,
) -> session.SessionSummary {
  session.SessionSummary(
    id: id,
    provider_id: "p1",
    model: "smart",
    title: title,
    title_source: session.AutoTitle,
    pinned: pinned,
    tags: tags,
    archived: archived,
    message_count: 2,
    streaming: False,
    created_at: last_active_at,
    last_active_at: last_active_at,
    metrics: [],
  )
}

pub fn sessions_auto_select_first_active_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let active = meta_summary("s-2", "New", False, [], False, 0)
  let model =
    new_model()
    |> step(ui.SessionsLoaded([archived, active]))
  // The archived row is soft-hidden, so auto-selection skips it.
  model.selected |> should.equal(Some("s-2"))
  model.create_open |> should.be_false
}

pub fn archived_selection_survives_refresh_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let model =
    new_model()
    |> step(ui.Select("s-1"))
    |> step(ui.SessionsLoaded([archived]))
  // Archiving the open session keeps it open (the user sees what they
  // archived); only a real disappearance ends it.
  model.selected |> should.equal(Some("s-1"))
  model.model_label |> should.equal("connecting…")
}

pub fn all_archived_opens_create_panel_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let model = new_model() |> step(ui.SessionsLoaded([archived]))
  model.selected |> should.equal(None)
  // No active session to select: the create panel opens so the sidebar is
  // never a dead end.
  model.create_open |> should.be_true
}

pub fn delete_of_selection_reselects_first_active_test() {
  let a = meta_summary("s-1", "A", False, [], False, 0)
  let b = meta_summary("s-2", "B", False, [], False, 0)
  let model =
    new_model()
    |> step(ui.SessionsLoaded([a, b]))
    |> step(ui.Select("s-2"))
    |> step(ui.SessionsLoaded([a]))
  model.selected |> should.equal(Some("s-1"))
  model.log |> should.equal([])
}

// ---------------------------------------------------------------------------
// Organization update flows
// ---------------------------------------------------------------------------

pub fn tag_filter_update_test() {
  let model = new_model() |> step(ui.TagFilterChanged("op"))
  model.tag_filter |> should.equal("op")
  // Typing never rotates the keyed input.
  model.filter_gen |> should.equal(0)
  // Programmatic sets do (chip click / clear).
  let set = step(model, ui.TagFilterSet("ops"))
  set.tag_filter |> should.equal("ops")
  set.filter_gen |> should.equal(1)
  let cleared = step(set, ui.TagFilterSet(""))
  cleared.tag_filter |> should.equal("")
  cleared.filter_gen |> should.equal(2)
}

pub fn archived_toggle_and_row_editors_test() {
  let model =
    new_model()
    |> step(ui.SessionsLoaded([summary("s-1", False)]))
    |> step(ui.ArchivedToggled)
  model.show_archived |> should.be_true

  // Editors open one at a time and close on a second click.
  let model = step(model, ui.RenameToggled("s-1"))
  model.rename_open |> should.equal(Some("s-1"))
  let model = step(model, ui.TagsToggled("s-1"))
  model.rename_open |> should.equal(None)
  model.tags_open |> should.equal(Some("s-1"))
  let model = step(model, ui.TagsToggled("s-1"))
  model.tags_open |> should.equal(None)

  // Two-step delete: arm, keep calm, cancel.
  let model = step(model, ui.DeleteRequested("s-1"))
  model.confirm_delete |> should.equal(Some("s-1"))
  let model = step(model, ui.DeleteCancelled)
  model.confirm_delete |> should.equal(None)
  // Arming the confirm closes any open editor.
  let model = step(model, ui.RenameToggled("s-1"))
  let model = step(model, ui.DeleteRequested("s-1"))
  model.rename_open |> should.equal(None)
  model.confirm_delete |> should.equal(Some("s-1"))
}

// ---------------------------------------------------------------------------
// Organization view rendering
// ---------------------------------------------------------------------------

pub fn view_renders_pinned_and_buckets_test() {
  let now = 1_700_000_000
  let pinned = meta_summary("s-1", "Pinned one", True, [], False, now)
  let today = meta_summary("s-2", "Today chat", False, ["ops"], False, now)
  let older =
    meta_summary("s-3", "Old chat", False, [], False, now - 30 * 86_400)
  let html =
    new_model()
    |> step(ui.SessionsLoaded([pinned, today, older]))
    |> view_string
  should.be_true(string.contains(html, "Pinned"))
  should.be_true(string.contains(html, "Pinned one"))
  should.be_true(string.contains(html, "Today"))
  should.be_true(string.contains(html, "Today chat"))
  should.be_true(string.contains(html, "Older"))
  should.be_true(string.contains(html, "Old chat"))
  // No yesterday / previous-7 groups: empty buckets render nothing.
  should.be_false(string.contains(html, "Yesterday"))
  should.be_false(string.contains(html, "Previous 7 days"))
  // Tag chips render; clicking one sets the filter (server-side handler).
  should.be_true(string.contains(html, "tag-chip"))
  should.be_true(string.contains(html, "ops"))
  // Compact controls are all present.
  should.be_true(string.contains(html, "Unpin"))
  should.be_true(string.contains(html, "Pin"))
  should.be_true(string.contains(html, "Rename"))
  should.be_true(string.contains(html, "Archive"))
  should.be_true(string.contains(html, "Delete"))
}

pub fn view_renders_archived_only_when_shown_test() {
  let archived = meta_summary("s-9", "Shelved", False, [], True, 1_700_000_000)
  let hidden =
    new_model()
    |> step(ui.SessionsLoaded([archived]))
    |> view_string
  // Soft-hidden by default: the row is absent, the empty state shows.
  should.be_false(string.contains(hidden, "Shelved"))
  should.be_true(string.contains(hidden, "No sessions yet."))

  let shown =
    new_model()
    |> step(ui.SessionsLoaded([archived]))
    |> step(ui.ArchivedToggled)
    |> view_string
  should.be_true(string.contains(shown, "Archived"))
  should.be_true(string.contains(shown, "Shelved"))
  should.be_true(string.contains(shown, "Restore"))
  // Invariant: archived rows carry no pin control (archiving unpins;
  // the registry refuses pins on archived sessions).
  should.be_false(string.contains(shown, ">Pin<"))
  should.be_false(string.contains(shown, ">Unpin<"))
}

pub fn view_hides_rows_failing_the_filter_test() {
  let a =
    meta_summary("s-1", "Deploy notes", False, ["ops"], False, 1_700_000_000)
  let b = meta_summary("s-2", "Cooking", False, [], False, 1_700_000_000)
  let html =
    new_model()
    |> step(ui.SessionsLoaded([a, b]))
    |> step(ui.TagFilterChanged("dep"))
    |> view_string
  should.be_true(string.contains(html, "Deploy notes"))
  should.be_false(string.contains(html, "Cooking"))
  // And the clear affordance appears with a non-empty filter.
  should.be_true(string.contains(html, "filter-clear"))
}

pub fn view_inline_editors_hidden_until_opened_test() {
  let a =
    meta_summary("s-1", "Deploy notes", False, ["ops"], False, 1_700_000_000)
  let base =
    new_model()
    |> step(ui.SessionsLoaded([a]))
    |> view_string
  // Editors and the delete confirm render but are hidden (attr.hidden).
  should.be_true(string.contains(base, "inline-editor"))
  should.be_true(string.contains(base, "confirm-delete"))
  let opened =
    new_model()
    |> step(ui.SessionsLoaded([a]))
    |> step(ui.RenameToggled("s-1"))
    |> view_string
  // The rename input carries the current title as its starting value.
  should.be_true(string.contains(opened, "value=\"Deploy notes\""))
  let tags_open =
    new_model()
    |> step(ui.SessionsLoaded([a]))
    |> step(ui.TagsToggled("s-1"))
    |> view_string
  should.be_true(string.contains(tags_open, "value=\"ops\""))
}

// ---------------------------------------------------------------------------
// Providers panel + provider-scoped picker (multi-provider P5)
// ---------------------------------------------------------------------------

fn prov(
  id: String,
  name: String,
  enabled: Bool,
  has_key: Bool,
) -> provider.Provider {
  provider.Provider(
    id: id,
    name: name,
    base_url: "http://127.0.0.1:9999/v1",
    dialect: "openai",
    enabled: enabled,
    has_key: has_key,
    created_at: 0,
    updated_at: 0,
  )
}

pub fn pick_provider_test() {
  let providers = [
    prov("p1", "bifrost", False, True),
    prov("p2", "ollama", True, False),
  ]
  // No previous selection: the first ENABLED provider.
  ui.pick_provider(providers, None) |> should.equal(Some("p2"))
  ui.pick_provider([], None) |> should.equal(None)
  // A live selection survives; a disabled or vanished one falls back.
  ui.pick_provider(providers, Some("p2")) |> should.equal(Some("p2"))
  ui.pick_provider(providers, Some("p1")) |> should.equal(Some("p2"))
  ui.pick_provider(providers, Some("gone")) |> should.equal(Some("p2"))
}

pub fn providers_loaded_auto_picks_enabled_test() {
  let model =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", False, True),
        prov("p2", "ollama", True, False),
      ]),
    )
  model.provider |> should.equal(Some("p2"))
  list.length(model.provider_list) |> should.equal(2)
}

pub fn providers_loaded_falls_back_when_disabled_test() {
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p2", "ollama", True, False)]))
    |> step(ui.ProvidersLoaded([prov("p2", "ollama", False, False)]))
  model.provider |> should.equal(None)
}

pub fn providers_loaded_clears_stale_aliases_on_fallback_test() {
  // The fallback (selection disabled or gone) must not leave the old
  // provider's models offerable: Create stays disabled until the
  // replacement list lands, and a stale alias can never be pinned to a
  // provider it did not come from (the ProviderPicked rule, applied to
  // programmatic selection changes).
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.AliasesLoaded("p1", ["gpt", "claude"]))
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", False, True),
        prov("p2", "ollama", True, False),
      ]),
    )
  model.provider |> should.equal(Some("p2"))
  model.aliases |> should.equal([])
  model.picker |> should.equal("")
  // No provider left at all: same clearing, nothing stale rendered.
  let gone =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.AliasesLoaded("p1", ["gpt"]))
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", False, True)]))
  gone.provider |> should.equal(None)
  gone.aliases |> should.equal([])
  gone.picker |> should.equal("")
  // An unchanged selection keeps its loaded aliases (no flicker on
  // unrelated refreshes).
  let kept =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.AliasesLoaded("p1", ["gpt"]))
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
  kept.provider |> should.equal(Some("p1"))
  kept.aliases |> should.equal(["gpt"])
}

pub fn provider_picked_scopes_and_clears_aliases_test() {
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p2", "ollama", True, False)]))
    |> step(ui.AliasesLoaded("p2", ["qwen", "llama"]))
    |> step(ui.ProviderPicked("p2"))
  // Re-picking the same provider changes nothing.
  model.aliases |> should.equal(["qwen", "llama"])
  let switched = step(model, ui.ProviderPicked("p9"))
  // Another provider's models must never linger as pin options.
  switched.aliases |> should.equal([])
  switched.picker |> should.equal("")
}

pub fn provider_created_selects_first_provider_test() {
  // The creation lands in the settings sub-component; the signal fold
  // in ui.update re-aims the picker — and, with no provider before it,
  // returns the view to chat (the auto-opened settings page has served
  // its purpose). Start from the AUTO-OPENED settings view (first load
  // empty) so the ChatView assertion is load-bearing, not the default.
  let opened = new_model() |> step(ui.ProvidersLoaded([]))
  opened.view |> should.equal(ui.SettingsView)
  let model =
    opened
    |> step(ui.Settings(ui_settings.Created(prov("p3", "new", True, True))))
  model.provider |> should.equal(Some("p3"))
  model.view |> should.equal(ui.ChatView)
  // An existing selection is left alone — and a settings visit that was
  // NOT the first-run auto-open stays in settings.
  let kept =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p2", "ollama", True, False)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.Created(prov("p3", "new", True, True))))
  kept.provider |> should.equal(Some("p2"))
  kept.view |> should.equal(ui.SettingsView)
}

pub fn provider_editors_toggle_one_at_a_time_test() {
  let model =
    new_model() |> step(ui.ProvidersLoaded([prov("p1", "a", True, True)]))
  let model = step(model, ui.Settings(ui_settings.AddToggled))
  model.settings.open |> should.be_true
  // Opening a row editor closes the add form, and vice versa; delete
  // confirm closes both.
  let model = step(model, ui.Settings(ui_settings.EditToggled("p1")))
  model.settings.edit |> should.equal(Some("p1"))
  model.settings.open |> should.be_false
  let model = step(model, ui.Settings(ui_settings.DeleteRequested("p1")))
  model.settings.confirm |> should.equal(Some("p1"))
  model.settings.edit |> should.equal(None)
  let model = step(model, ui.Settings(ui_settings.DeleteCancelled))
  model.settings.confirm |> should.equal(None)
}

pub fn provider_op_failure_notes_the_log_test() {
  // Mutations run in the settings sub-component; their failures travel
  // back as a signal and land in the chat log (settings has no log of
  // its own).
  let model =
    new_model()
    |> step(
      ui.Settings(ui_settings.MutateFailed("provider name already exists")),
    )
  model.log
  |> should.equal([
    ui.NoteLine(True, "provider operation failed: provider name already exists"),
  ])
}

pub fn view_renders_providers_panel_test() {
  let html =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", True, True),
        prov("p2", "ollama", False, False),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> view_string
  should.be_true(string.contains(html, "Providers"))
  should.be_true(string.contains(html, "bifrost"))
  should.be_true(string.contains(html, "ollama"))
  should.be_true(string.contains(html, "http://127.0.0.1:9999/v1"))
  // Badges: key/keyless state, never key material.
  should.be_true(string.contains(html, ">key<"))
  should.be_true(string.contains(html, ">keyless<"))
  should.be_true(string.contains(html, ">disabled<"))
  // Controls mirror the session rows' compact pattern — plus the
  // on-demand connection test.
  should.be_true(string.contains(html, ">Disable<"))
  should.be_true(string.contains(html, ">Enable<"))
  should.be_true(string.contains(html, ">Edit<"))
  should.be_true(string.contains(html, ">Test<"))
  should.be_true(string.contains(html, ">Delete<"))
  // Empty state: the auto-opened settings page on a fresh database.
  let empty = new_model() |> step(ui.ProvidersLoaded([])) |> view_string
  should.be_true(string.contains(empty, "No providers yet."))
}

pub fn view_provider_forms_hidden_until_opened_test() {
  let base =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> view_string
  // Both forms render but are hidden (the session-editor pattern).
  should.be_true(string.contains(base, "add-provider-form"))
  should.be_true(string.contains(base, "provider-form"))
  let adding =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.AddToggled))
    |> view_string
  should.be_true(string.contains(adding, "API key (optional)"))
  let editing =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.EditToggled("p1")))
    |> view_string
  // The key field is write-only: it starts EMPTY (blank = keep) even for
  // a provider that HAS a key — has_key is the only key fact rendered.
  should.be_true(string.contains(editing, "API key (blank keeps existing)"))
  should.be_true(string.contains(editing, "value=\"bifrost\""))
  should.be_false(string.contains(editing, "value=\"sk-"))
}

pub fn view_provider_picker_lists_enabled_only_test() {
  let html =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", True, True),
        prov("p2", "ollama", True, False),
        prov("p3", "old", False, True),
      ]),
    )
    |> view_string
  should.be_true(string.contains(html, "provider-picker"))
  should.be_true(string.contains(html, ">bifrost<"))
  // Keyless providers are called out in the option label; disabled
  // providers do not appear at all.
  should.be_true(string.contains(html, ">ollama (keyless)<"))
  // Disabled providers appear in the MANAGEMENT panel but never as a
  // picker option (option values carry the id).
  should.be_false(string.contains(html, "value=\"p3\""))
  // Zero enabled providers: a legible placeholder, not an empty select.
  let none =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p3", "old", False, True)]))
    |> view_string
  should.be_true(string.contains(none, "no providers — add one in Settings"))
}

pub fn view_session_subtitle_pins_provider_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SessionsLoaded([summary("s-1", False)]))
    |> view_string
  // Subtitle: provider/model · age (§11). The summary pins p1, whose
  // display name resolves from the masked list.
  should.be_true(string.contains(html, "bifrost/smart · "))
  // While the list lags, the id stands in — never blank.
  let lagging =
    new_model()
    |> step(ui.SessionsLoaded([summary("s-1", False)]))
    |> view_string
  should.be_true(string.contains(lagging, "p1/smart · "))
}

// ---------------------------------------------------------------------------
// Settings view (relocation from the sidebar; per-client)
// ---------------------------------------------------------------------------

pub fn settings_closed_by_default_test() {
  let model = new_model()
  model.view |> should.equal(ui.ChatView)
  model.settings_manual |> should.be_false
  // The chat shell renders the header toggle but no provider surface.
  let html = model |> view_string
  should.be_true(string.contains(html, "id=\"settings\""))
  should.be_false(string.contains(html, "providers-panel"))
  should.be_false(string.contains(html, "provider-row"))
}

pub fn settings_auto_opens_on_empty_provider_list_test() {
  // Fresh database: the empty provider list opens the settings view by
  // itself — the guided first-run path the always-visible sidebar panel
  // used to provide. Idempotent on repeated empty refreshes.
  let model = new_model() |> step(ui.ProvidersLoaded([]))
  model.view |> should.equal(ui.SettingsView)
  let again = step(model, ui.ProvidersLoaded([]))
  again.view |> should.equal(ui.SettingsView)
}

pub fn settings_manual_close_beats_auto_open_test() {
  // A user who deliberately closes the settings page is not pulled back
  // on the next (still empty) refresh — the create_auto latch pattern.
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([]))
    |> step(ui.SettingsToggled)
  model.view |> should.equal(ui.ChatView)
  model.settings_manual |> should.be_true
  let again = step(model, ui.ProvidersLoaded([]))
  again.view |> should.equal(ui.ChatView)
}

pub fn settings_header_button_flips_label_test() {
  let chat = new_model() |> view_string
  should.be_true(string.contains(chat, ">Settings<"))
  let open = new_model() |> step(ui.SettingsToggled) |> view_string
  should.be_true(string.contains(open, ">Back to chat<"))
  // The settings page renders — and the chat subtree STAYS MOUNTED
  // (hidden via CSS): the composer's uncontrolled textarea must survive
  // the view swap, or an unsent draft would be destroyed by a settings
  // peek (the element keeps its value while merely hidden).
  should.be_true(string.contains(open, "id=\"settings-page\""))
  should.be_true(string.contains(open, "id=\"composer\""))
  should.be_true(string.contains(open, "settings-mode"))
}

pub fn provider_test_button_state_machine_test() {
  let base =
    new_model() |> step(ui.ProvidersLoaded([prov("p1", "a", True, True)]))
  let requested = step(base, ui.Settings(ui_settings.TestRequested("p1")))
  requested.settings.models
  |> should.equal(ui_settings.ModelsLoading("p1"))
  let ok =
    step(
      requested,
      ui.Settings(ui_settings.ModelsLoaded("p1", ["smart", "fast"])),
    )
  ok.settings.models
  |> should.equal(ui_settings.ModelsOk("p1", ["smart", "fast"]))
  // A failed test keeps the registry's fixed reason text.
  let failed =
    step(
      requested,
      ui.Settings(ui_settings.TestFailed("p1", "provider is disabled")),
    )
  failed.settings.models
  |> should.equal(ui_settings.ModelsFailed("p1", "provider is disabled"))
  // A LATE reply for a superseded request cannot clobber the newer
  // result: only the request that is still loading accepts its reply.
  let stale =
    step(ok, ui.Settings(ui_settings.TestFailed("p2", "late failure")))
  stale.settings.models
  |> should.equal(ui_settings.ModelsOk("p1", ["smart", "fast"]))
}

pub fn view_renders_models_status_under_its_row_test() {
  let html =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "first", True, True),
        prov("p2", "second", True, False),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TestRequested("p2")))
    |> step(ui.Settings(ui_settings.TestRequested("p1")))
    |> step(ui.Settings(ui_settings.ModelsLoaded("p1", ["smart", "fast"])))
    // p2's superseded request replies late — it must be ignored.
    |> step(ui.Settings(ui_settings.TestFailed("p2", "late failure")))
    |> view_string
  // The settled result renders under its own row (Lustre sorts attrs,
  // so data-provider-id precedes class on the row div) — between p1's
  // row start and p2's row.
  let first_at = position_of(html, "data-provider-id=\"p1\"")
  let second_at = position_of(html, "data-provider-id=\"p2\"")
  let ok_at = position_of(html, "ok · models: smart, fast")
  should.be_true(first_at < ok_at && ok_at < second_at)
  // One test result at a time: the superseded request for p2 leaves no
  // loading marker behind — and its late failure reply renders nowhere.
  should.be_false(string.contains(html, "testing…"))
  should.be_false(string.contains(html, "late failure"))
}

pub fn provider_mutation_failure_shows_in_settings_test() {
  // The user is ON the settings page when a mutation fails, so the
  // reason must render there — the chat-log note (OpFailed signal) is
  // the transcript copy, not the only feedback.
  let model =
    new_model()
    |> step(ui.SettingsToggled)
    |> step(
      ui.Settings(ui_settings.MutateFailed("provider name already exists")),
    )
  model.settings.last_error
  |> should.equal(Some("provider name already exists"))
  model
  |> view_string
  |> should_contain("provider operation failed: provider name already exists")
  // The next successful mutation clears it (the chat-log transcript
  // note stays by design; the settings-page element is what clears).
  let cleared = step(model, ui.Settings(ui_settings.Mutated))
  cleared.settings.last_error |> should.equal(None)
  cleared |> view_string |> should_not_contain("settings-error")
}

pub fn providers_emptied_later_does_not_reopen_settings_test() {
  // The auto-open fires on the connection's FIRST provider load only:
  // a list that becomes empty later (external deletes + refresh) must
  // not hijack an in-progress chat view into settings.
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "a", True, True)]))
    |> step(ui.ProvidersLoaded([]))
  model.view |> should.equal(ui.ChatView)
  // The first-run rule still holds when the first load IS empty.
  let fresh = new_model() |> step(ui.ProvidersLoaded([]))
  fresh.view |> should.equal(ui.SettingsView)
}

fn position_of(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> -1
  }
}

pub fn settings_view_escapes_hostile_text_test() {
  // Provider names and model aliases are hostile text: everything the
  // settings page renders is an inert Lustre text node.
  let html =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "<script>alert(1)</script>", True, True),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TestRequested("p1")))
    |> step(
      ui.Settings(
        ui_settings.ModelsLoaded("p1", ["<img src=x onerror=alert(2)>"]),
      ),
    )
    |> view_string
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>alert"))
  should.be_true(string.contains(html, "&lt;img"))
  should.be_false(string.contains(html, "<img src="))
}

// ---------------------------------------------------------------------------
// Reasoning (chain of thought)
// ---------------------------------------------------------------------------

pub fn reasoning_streams_into_thinking_block_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("step "))
    |> step(ui.Reasoning("one"))
  model.thinking |> should.equal(Some("step one"))
  model.streaming |> should.be_true
  let html = model |> view_string
  should_contain(html, "turn reasoning live")
  // The live block is open, right in the serialized markup (a boolean
  // True attribute renders bare; False renders nothing).
  should_contain(html, "turn reasoning live\" open>")
  should_contain(html, "thinking…")
  should_contain(html, "step one")
}

pub fn first_token_commits_reasoning_above_text_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("chain"))
    |> step(ui.Token("answer"))
    |> step(ui.TurnDone)
  model.thinking |> should.equal(None)
  model.bubble |> should.equal(None)
  // ReasoningLine was pushed before AssistantLine, so it renders above it.
  model.log
  |> should.equal([
    ui.AssistantLine("answer"),
    ui.ReasoningLine("chain"),
    ui.UserLine("hi"),
  ])
  // …and the rendered log agrees: the collapsed reasoning block sits
  // above the assistant turn it preceded, not just first in the list.
  let html = model |> view_string
  let assert [before_assistant, ..] = string.split(html, "turn assistant")
  should_contain(before_assistant, "<details class=\"turn reasoning\">")
}

pub fn reasoning_commits_before_tool_call_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("need a tool"))
    |> step(ui.ToolCallAssembled("call_1", "echo", "{}"))
  model.log
  |> should.equal([
    ui.ToolLine("call_1", "echo", "{}", ui.ToolRunning, None),
    ui.ReasoningLine("need a tool"),
    ui.UserLine("hi"),
  ])
  model.thinking |> should.equal(None)
}

pub fn tool_call_fragment_without_text_defers_reasoning_test() {
  // Reasoning, then a tool-call fragment, then a stop before assembly:
  // the loop's stop path commits only non-empty text, so with no text
  // the server commits nothing — the display must not commit the
  // thinking buffer either (it defers to the assembly commit).
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("reached for a tool"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("echo"), "{\"x\""))
    |> step(ui.TurnStopped)
  model.thinking |> should.equal(None)
  model.log |> should.equal([ui.UserLine("hi")])
}

pub fn tool_call_fragment_with_text_commits_reasoning_test() {
  // Text ahead of the fragments commits both immediately: a stop then
  // commits text + reasoning server-side, exactly like this display.
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("reached for a tool"))
    |> step(ui.Token("partial"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("echo"), "{\"x\""))
    |> step(ui.TurnStopped)
  model.log
  |> should.equal([
    ui.AssistantLine("partial"),
    ui.ReasoningLine("reached for a tool"),
    ui.UserLine("hi"),
  ])
  model.thinking |> should.equal(None)
}

pub fn replayed_reasoning_renders_collapsed_test() {
  let model =
    new_model()
    |> step(ui.ReasoningFull("the chain of thought"))
    |> step(ui.AssistantFull("the answer"))
  let html = model |> view_string
  should_contain(html, "turn reasoning\"")
  should_not_contain(html, "thinking…")
  should_contain(html, "the chain of thought")
  // Collapsed in the markup itself: a live block carries a bare `open`
  // attribute, a replayed one must carry none at all.
  should_not_contain(html, "<details open")
  should_not_contain(html, "reasoning\" open")
}

pub fn reasoning_only_turn_discards_thinking_on_done_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("never finished"))
    |> step(ui.TurnDone)
  // The server committed nothing (no empty assistant messages), so the
  // display rolls the uncommitted thinking back with the turn.
  model.thinking |> should.equal(None)
  model.log |> should.equal([ui.UserLine("hi")])
}

pub fn failed_turn_rolls_back_reasoning_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi"))
    |> step(ui.Reasoning("doomed"))
    |> step(ui.Token("partial"))
    |> step(ui.TurnFailed("non-200"))
  model.log
  |> should.equal([ui.NoteLine(True, "turn failed: non-200"), ui.UserLine("hi")])
  model.thinking |> should.equal(None)
  model.bubble |> should.equal(None)
}

pub fn view_escapes_reasoning_content_test() {
  let model =
    new_model()
    |> step(ui.ReasoningFull("<script>alert(1)</script>"))
  let html = model |> view_string
  should_not_contain(html, "<script>alert(1)</script>")
  should_contain(html, "&lt;script&gt;")
}

pub fn from_session_event_maps_reasoning_test() {
  ui.from_session_event(session.Reasoning("bit"))
  |> should.equal(ui.Reasoning("bit"))
  ui.from_session_event(session.ReasoningFull("whole"))
  |> should.equal(ui.ReasoningFull("whole"))
}
