//// Offline tests for the M3 Lustre server-component UI: init/update
//// behaviour (selection, token assembly, turn terminal states, reconnect)
//// and view rendering (element/text APIs only, no innerHTML).

import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/string
import gleeunit/should
import lustre
import lustre/effect
import lustre/element
import lustre/server_component
import nexus/bot
import nexus/bot_registry
import nexus/config
import nexus/env
import nexus/log
import nexus/loop
import nexus/node
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/store
import nexus/thread
import nexus/thread_registry
import nexus/timing
import nexus/tools
import nexus/transcript
import nexus/ui
import nexus/ui_runtime
import nexus/ui_settings
import store_mock

fn new_model() -> ui.Model {
  let #(model, _effect) =
    ui.init(ui.Flags(
      registry: process.new_subject(),
      providers: process.new_subject(),
      bots: process.new_subject(),
      models_timeout_ms: 60_000,
      thread: None,
      store: store_mock.seam(store_mock.start()),
      pair_base: "http://127.0.0.1:8080",
    ))
  model
}

/// A model whose connection supplied a last-selected thread (the /ws
/// route's `thread` parameter, persisted by the page shell).
fn new_model_with_thread(id: Option(String)) -> ui.Model {
  let #(model, _effect) =
    ui.init(ui.Flags(
      registry: process.new_subject(),
      providers: process.new_subject(),
      bots: process.new_subject(),
      models_timeout_ms: 60_000,
      thread: id,
      store: store_mock.seam(store_mock.start()),
      pair_base: "http://127.0.0.1:8080",
    ))
  model
}

fn step(model: ui.Model, msg: ui.Msg) -> ui.Model {
  let #(next, _effect) = ui.update(model, msg)
  next
}

fn summary(id: String, streaming: Bool) -> thread.ThreadSummary {
  thread.ThreadSummary(
    id: id,
    provider_id: "p1",
    model: "smart",
    title: "",
    title_source: thread.AutoTitle,
    pinned: False,
    tags: [],
    archived: False,
    bot_id: None,
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
  model.threads |> should.equal([])
  model.provider_list |> should.equal([])
  model.selected |> should.equal(None)
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log |> should.equal([])
  model.model_label |> should.equal("")
}

// ---------------------------------------------------------------------------
// Thread list / selection
// ---------------------------------------------------------------------------

pub fn threads_auto_select_first_test() {
  let model = new_model() |> step(ui.ThreadsLoaded([summary("s-1", False)]))
  model.selected |> should.equal(Some("s-1"))
}

/// The auto-selection fires a join carrying a NEW visit generation, and
/// that generation must land on the RETURNED model: a delivery only
/// applies when the model's generation matches, so a bump that lives only
/// in the join effect leaves the model one generation behind — deaf to
/// the whole Hello + replay. That was the blank-chat-on-boot bug: the
/// top-most thread showed selected while the pane stayed empty until the
/// user switched away and back (#58 regression).
pub fn threads_loaded_auto_select_bumps_visit_test() {
  let model = new_model() |> step(ui.ThreadsLoaded([summary("s-1", False)]))
  let visit = model.visit
  // The fresh harness model sits at generation 0 (its GotEvents effect is
  // dropped), so the auto-switch must have bumped to 1 — the same value
  // the join carried.
  visit |> should.equal(1)
  // A replay delivery stamped with the join's generation APPLIES — this
  // is the assertion that failed while the bump was shadowed.
  let model = step(model, ui.ThreadScoped("s-1", visit, ui.Token("kept")))
  model.bubble |> should.equal(Some("kept"))
}

/// Archiving the OPEN thread ends the visit: the selection clears and
/// the chat pane goes blank (the row is soft-hidden, so keeping the
/// selection highlighted nothing while the pane still showed the archived
/// content — the ghost-selection bug). The refresh that the registry
/// write triggers must not auto-select a replacement, and an explicit
/// pick works normally afterwards.
pub fn archive_of_selection_clears_selection_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False), summary("s-2", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Archived("s-1", True))
  model.selected |> should.equal(None)
  model.log |> should.equal([])
  model.model_label |> should.equal("no thread selected")
  // The post-write refresh (active threads available) must NOT
  // auto-select: the empty state is deliberate.
  let model =
    step(
      model,
      ui.ThreadsLoaded([summary("s-1", False), summary("s-2", False)]),
    )
  model.selected |> should.equal(None)
  // An explicit pick re-arms normal selection behaviour.
  let model = step(model, ui.Select("s-2"))
  model.selected |> should.equal(Some("s-2"))
}

/// The New button can be clicked BEFORE the first thread list arrives
/// (the sidebar renders immediately on a fresh connection). The click
/// must mark the no-selection state as deliberate, or the arriving list
/// auto-selects right over the compose-new state.
pub fn new_thread_before_first_load_suppresses_autoselect_test() {
  let model = new_model() |> step(ui.NewThreadToggled)
  model.selected |> should.equal(None)
  model.suppress_autoselect |> should.be_true
  // The first (or any later) list load must not auto-select over the
  // compose-new state.
  let model = step(model, ui.ThreadsLoaded([summary("s-1", False)]))
  model.selected |> should.equal(None)
  // A row pick recovers normally.
  let model = step(model, ui.Select("s-1"))
  model.selected |> should.equal(Some("s-1"))
}

/// Archiving a thread that is NOT the open one leaves the selection
/// alone — the pane keeps showing what the user is reading.
pub fn archive_of_other_thread_keeps_selection_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False), summary("s-2", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.Archived("s-2", True))
  model.selected |> should.equal(Some("s-1"))
  model.log |> should.equal([])
}

/// The New-thread button enters COMPOSE-NEW, the same deliberate
/// no-selection state: the open thread's view clears, and the composer
/// grows its bot picker (the bot the first send starts the thread from).
/// The state holds across refreshes until a row is picked; pressing New
/// again while already composing stays there (there is no panel to
/// close — the composer is the compose surface).
pub fn new_thread_button_clears_selection_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.NewThreadToggled)
  model.selected |> should.equal(None)
  model.log |> should.equal([])
  model.model_label |> should.equal("new thread")
  // A refresh (title upgrade from any thread) keeps the state: no
  // auto-select, still composing.
  let model = step(model, ui.ThreadsLoaded([summary("s-1", False)]))
  model.selected |> should.equal(None)
  // A second press while composing stays composing.
  let again = step(model, ui.NewThreadToggled)
  again.selected |> should.equal(None)
  // A row pick recovers.
  let model = step(again, ui.Select("s-1"))
  model.selected |> should.equal(Some("s-1"))
}

pub fn threads_empty_leaves_compose_new_test() {
  let model = new_model() |> step(ui.ThreadsLoaded([]))
  // Nothing to select: the composer sits in its compose-new shape (the
  // bot picker is visible — see the view tests below).
  model.selected |> should.equal(None)
  model.suppress_autoselect |> should.be_false
}

pub fn select_resets_log_and_streams_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False), summary("s-2", False)]))
    |> step(ui.Hello("smart"))
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Select("s-2"))
  model.selected |> should.equal(Some("s-2"))
  model.log |> should.equal([])
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.model_label |> should.equal("")
}

/// Every fan-out delivery carries the emitting thread's id AND the
/// subscriber's visit generation (`thread.ThreadEvent`), and the update
/// applies a delivery only when BOTH match: the id drops deliveries from
/// other threads; the generation drops leftovers from an EARLIER visit
/// to the same thread (rapid A→B→A). `Leave` cannot stop broadcasts
/// already in the mailbox when it lands, so without these filters a
/// thread that kept streaming after being switched away from rendered
/// into the OTHER thread's view, and stale same-thread events
/// duplicated history on top of the second visit's replay.
pub fn events_from_other_thread_are_dropped_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False), summary("s-2", False)]))
    |> step(ui.Select("s-2"))
  let visit = model.visit

  // The selected thread's CURRENT-visit events flow normally.
  let model = step(model, ui.ThreadScoped("s-2", visit, ui.Token("kept")))
  model.bubble |> should.equal(Some("kept"))
  model.streaming |> should.be_true

  // The same payload from the thread this connection LEFT is dropped
  // whole: no bubble growth, no streaming flag, no log lines.
  let model =
    model
    |> step(ui.ThreadScoped("s-1", visit, ui.Token("dropped")))
    |> step(ui.ThreadScoped(
      "s-1",
      visit,
      ui.ToolCallAssembled("c1", "web_search", "{}", None),
    ))
    |> step(ui.ThreadScoped("s-1", visit, ui.TurnDone(None)))
  model.bubble |> should.equal(Some("kept"))
  model.log |> should.equal([])
  model.pending |> should.equal([])
  model.streaming |> should.be_true

  // So are SAME-thread deliveries from an earlier visit (the id now
  // matches; only the stale generation saves us).
  let model =
    step(model, ui.ThreadScoped("s-2", visit - 1, ui.Token("stale visit")))
  model.bubble |> should.equal(Some("kept"))
  model.streaming |> should.be_true
}

/// Offline shape of the pass-through rule: a `MetaUpdated` from a foreign
/// thread (id and generation both foreign) reaches the update arm, whose
/// only observable here is the refresh effect this harness drops. The
/// end-to-end pass-through — refresh actually landing on the client — is
/// pinned by `meta_updated_from_other_thread_refreshes_sidebar_test`
/// below.
pub fn meta_updated_from_other_thread_passes_filter_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
  let model =
    step(
      model,
      ui.ThreadScoped(
        "s-9",
        model.visit + 7,
        ui.MetaUpdated(Some("Other"), ["tag"]),
      ),
    )
  model.threads |> list.map(fn(s) { s.id }) |> should.equal(["s-1"])
  model.selected |> should.equal(Some("s-1"))
}

pub fn select_same_thread_is_noop_test() {
  let model = new_model() |> step(ui.Select("s-1"))
  let again = step(model, ui.Select("s-1"))
  again.log |> should.equal(model.log)
  again.model_label |> should.equal(model.model_label)
}

pub fn vanished_selection_ends_thread_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Hello("smart"))
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Token("par"))
  let model = model |> step(ui.ThreadsLoaded([]))
  model.selected |> should.equal(None)
  model.log |> should.equal([])
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.model_label |> should.equal("thread ended")
  // The hidden flag resets with the bubble it belonged to: a stale False
  // (the ended thread's bubble was visible) would let the NEXT thread's
  // first streamed token — even whitespace-only — render, bypassing the
  // render-empty rule.
  model.bubble_hidden |> should.equal(True)
  let model = model |> step(ui.Token("\n\n"))
  model.bubble_hidden |> should.equal(True)
  let html = model |> view_string
  should_not_contain(html, "turn assistant")
}

pub fn hello_sets_label_and_busy_state_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", True)]))
    |> step(ui.Hello("smart"))
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
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Token("Hel"))
    |> step(ui.Token("lo"))
    |> step(ui.TurnDone(None))
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> list.reverse
  |> log_shapes
  |> should.equal([
    ui.UserLine("hi", None, None),
    ui.AssistantLine("Hello", None),
  ])
}

pub fn turn_stopped_commits_partial_test() {
  let model = new_model() |> step(ui.Token("par")) |> step(ui.TurnStopped(None))
  model.bubble |> should.equal(None)
  model.log |> log_shapes |> should.equal([ui.AssistantLine("par", None)])
}

pub fn turn_failed_discards_partial_test() {
  let model =
    new_model()
    |> step(ui.Token("par"))
    |> step(ui.TurnFailed("boom", None))
  model.bubble |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> should.equal([ui.NoteLine(err: True, text: "turn failed: boom")])
}

pub fn replay_events_render_in_order_test() {
  let model =
    new_model()
    |> step(ui.AssistantFull("old answer", None))
    |> step(ui.UserEcho("hi", None, None))
  model.log
  |> list.reverse
  |> should.equal([
    ui.AssistantLine("old answer", None),
    ui.UserLine("hi", None, None),
  ])
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

pub fn send_requested_without_thread_is_noop_test() {
  let model = new_model() |> step(ui.SendRequested("hi"))
  model.composer |> should.equal(0)
  model.streaming |> should.be_false
}

pub fn stop_keeps_state_until_terminal_event_test() {
  let model = new_model() |> step(ui.StopRequested)
  model.streaming |> should.be_false
  model.log |> should.equal([])
}

/// Stop mounts only while a turn streams — idle it is `hidden` (Pico's
/// global `[hidden] { display: none !important }` hides it), so the
/// composer no longer shows a permanently-disabled control (F8).
pub fn stop_visible_only_while_streaming_test() {
  let idle = new_model() |> view_string
  // SSR sorts attributes; the bare `hidden` lands right before the id.
  should_contain(idle, "hidden id=\"stop\"")
  let streaming = new_model() |> step(ui.SendAccepted) |> view_string
  should_contain(streaming, "id=\"stop\"")
  should_not_contain(streaming, "hidden id=\"stop\"")
}

// ---------------------------------------------------------------------------
// Per-client connect (the runtime break)
// ---------------------------------------------------------------------------

/// A first-time visitor supplies no thread: nothing is selected until the
/// loaded list auto-selects (or the user picks one).
pub fn init_without_client_thread_selects_nothing_test() {
  new_model().selected |> should.equal(None)
}

/// A reload supplies the client's last-selected thread: the fresh
/// per-connection model re-opens exactly that one.
pub fn init_with_client_thread_preselects_it_test() {
  new_model_with_thread(Some("s1")).selected
  |> should.equal(Some("s1"))
}

/// The supplied thread survives the thread-list load: the auto-selection
/// rule (first active) must not clobber it.
pub fn threads_loaded_keeps_client_thread_test() {
  let model =
    new_model_with_thread(Some("s2"))
    |> step(ui.ThreadsLoaded([summary("s1", False), summary("s2", False)]))
  model.selected |> should.equal(Some("s2"))
}

/// A stale supplied thread (deleted server-side while the tab was away)
/// drops out and the auto-selection rules take over — same as any other
/// vanished selection.
pub fn threads_loaded_drops_stale_client_thread_test() {
  let model =
    new_model_with_thread(Some("gone"))
    |> step(ui.ThreadsLoaded([summary("s1", False), summary("s2", False)]))
  model.selected |> should.equal(Some("s1"))
}

/// A fresh model can see Hello (replay) before the summaries land; Hello
/// then finds an empty thread list and reports `streaming: False`. The
/// loaded summary must reconcile the busy state — otherwise the composer
/// looks idle and a send is rejected with "busy" mid-stream.
pub fn threads_loaded_reconciles_streaming_after_hello_test() {
  let model =
    new_model_with_thread(Some("s1"))
    |> step(ui.Hello("smart"))
    |> step(ui.ThreadsLoaded([summary("s1", True)]))
  model.streaming |> should.be_true
}

/// The reconcile only fires for the unchanged selection: a vanished or
/// switched selection keeps the state `after_threads` computed.
pub fn threads_loaded_reconcile_skips_changed_selection_test() {
  let model =
    new_model_with_thread(Some("gone"))
    |> step(ui.Hello("smart"))
    |> step(ui.ThreadsLoaded([summary("s1", True)]))
  model.selected |> should.equal(Some("s1"))
  model.streaming |> should.be_false
}

// ---------------------------------------------------------------------------
// Event translation
// ---------------------------------------------------------------------------

pub fn event_translation_test() {
  ui.from_thread_event(thread.Hello("smart", 3, []))
  |> should.equal(ui.Hello("smart"))
  ui.from_thread_event(thread.UserEcho("hi", Some(1_700_000_000), None))
  |> should.equal(ui.UserEcho("hi", Some(1_700_000_000), None))
  // Bot-authored shape carries through too — a mapping that dropped the
  // author would silently strip every badge.
  ui.from_thread_event(thread.UserEcho(
    "status",
    Some(1_700_000_000),
    Some("Hermes"),
  ))
  |> should.equal(ui.UserEcho("status", Some(1_700_000_000), Some("Hermes")))
  ui.from_thread_event(thread.AssistantFull("full", None))
  |> should.equal(ui.AssistantFull("full", None))
  ui.from_thread_event(thread.Token("t"))
  |> should.equal(ui.Token("t"))
  ui.from_thread_event(thread.TurnStopped(4, Some(1_700_000_000)))
  |> should.equal(ui.TurnStopped(Some(1_700_000_000)))
  ui.from_thread_event(thread.TurnFailed("x", None))
  |> should.equal(ui.TurnFailed("x", None))
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
    |> step(ui.UserEcho("look this up", None, None))
    |> step(ui.Token("checking"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{}"))
  model.log
  |> list.reverse
  |> log_shapes
  |> should.equal([
    ui.UserLine("look this up", None, None),
    ui.AssistantLine("checking", None),
  ])
  model.bubble |> should.equal(None)
}

pub fn tool_assembled_replaces_pending_with_running_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"q"))
    |> step(ui.ToolCallAssembled(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      None,
    ))
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
    |> step(ui.ToolCallAssembled(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      None,
    ))
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
    |> step(ui.ToolCallAssembled("call_9", "http_fetch", "{}", None))
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
    |> step(ui.UserEcho("search", None, None))
    |> step(ui.Token("looking"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}", None))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(2, 8, "request"))
    |> step(ui.Token("found it"))
    |> step(ui.TurnDone(None))
  model.loop |> should.equal(None)
  model.streaming |> should.be_false
  model.log
  |> list.reverse
  |> log_shapes
  |> should.equal([
    ui.UserLine("search", None, None),
    ui.AssistantLine("looking", None),
    ui.ToolLine("call_1", "web_search", "{}", ui.ToolDone(True), Some("[]")),
    ui.AssistantLine("found it", None),
  ])
}

pub fn turn_stopped_drops_pending_keeps_completed_rounds_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolResult("call_1", "http_fetch", True, "ok"))
    |> step(ui.ToolCallDelta(0, Some("call_2"), Some("web_search"), "{\"q"))
    |> step(ui.Token("partial"))
    |> step(ui.TurnStopped(None))
  model.pending |> should.equal([])
  model.log
  |> list.reverse
  |> log_shapes
  |> should.equal([
    ui.ToolLine("call_1", "http_fetch", "{}", ui.ToolDone(True), Some("ok")),
    ui.AssistantLine("partial", None),
  ])
}

pub fn turn_failed_rolls_back_uncommitted_turn_test() {
  let model =
    new_model()
    |> step(ui.AssistantFull("previous answer", None))
    |> step(ui.UserEcho("search", None, None))
    |> step(ui.Token("looking"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}", None))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(2, 8, "request"))
    |> step(ui.Token("more"))
    |> step(ui.TurnFailed("transport error: boom", None))
  // Nothing from the failed turn survives except the user line and note.
  model.log
  |> list.reverse
  |> should.equal([
    ui.AssistantLine("previous answer", None),
    ui.UserLine("search", None, None),
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
    |> step(ui.UserEcho("keep searching", None, None))
    |> step(ui.Token("partial text"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}", None))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.LoopStatus(8, 8, "guard"))
    |> step(ui.TurnFailed(
      "iteration guard: reached max 8 model round-trips",
      None,
    ))
  // The guard commits final text + completed rounds; only the never-run
  // trailing call is absent.
  model.log
  |> list.reverse
  |> log_shapes
  |> should.equal([
    ui.UserLine("keep searching", None, None),
    ui.AssistantLine("partial text", None),
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
    |> step(ui.Hello("smart"))
    |> step(ui.UserEcho("search for cats", None, None))
    |> step(ui.AssistantFull("checking", None))
    |> step(ui.ToolCallAssembled(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      None,
    ))
    |> step(ui.ToolResult(
      "call_1",
      "web_search",
      True,
      "[{\"title\":\"cats\"}]",
    ))
    |> step(ui.AssistantFull("cats are great", None))
  model.log
  |> list.reverse
  |> should.equal([
    ui.UserLine("search for cats", None, None),
    ui.AssistantLine("checking", None),
    ui.ToolLine(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      ui.ToolDone(True),
      Some("[{\"title\":\"cats\"}]"),
    ),
    ui.AssistantLine("cats are great", None),
  ])
  model.pending |> should.equal([])
}

// ---------------------------------------------------------------------------
// Tool view rendering
// ---------------------------------------------------------------------------

pub fn view_renders_tool_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      None,
    ))
    |> step(ui.ToolResult(
      "call_1",
      "web_search",
      True,
      "[{\"title\":\"cats\"}]",
    ))
  let html = view_string(model)
  // A completed call renders as ONE compact clickable chip — the whole
  // chip is the popup opener (no separate affordance, no inline body).
  // The status rides the aria-label so the collapsed state is never
  // color-only.
  should_contain(
    html,
    "<button aria-label=\"web_search (completed)\" class=\"turn tool done\" data-call-id=\"call_1\" data-tool=\"web_search\" title=\"View full call\" type=\"button\"><strong class=\"tool-name\">web_search</strong></button>",
  )
  // The full call text lives in the popup only — nothing renders inline.
  should_not_contain(html, "{&quot;query&quot;:&quot;cats&quot;}")
  should_not_contain(html, "[{&quot;title&quot;:&quot;cats&quot;}]")
}

pub fn view_renders_running_and_failed_states_test() {
  let running =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
  running |> view_string |> should_contain("turn tool running")
  // The status is legible without color: it rides the aria-label.
  running
  |> view_string
  |> should_contain("aria-label=\"http_fetch (running)\"")
  let failed =
    new_model()
    |> step(ui.ToolCallAssembled("call_2", "http_fetch", "{}", None))
    |> step(ui.ToolResult("call_2", "http_fetch", False, "{\"error\":\"no\"}"))
  failed |> view_string |> should_contain("turn tool failed")
  failed
  |> view_string
  |> should_contain("aria-label=\"http_fetch (failed)\"")
}

// The old inline previews are gone: the chip shows the tool name only,
// and the complete argument/result text appears only in the popup.
pub fn view_chip_shows_name_only_test() {
  let long_args = string.repeat("a", 500)
  let long_result = string.repeat("r", 500)
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", long_args, None))
    |> step(ui.ToolResult("call_1", "http_fetch", True, long_result))
  let html = view_string(model)
  should.be_false(string.contains(html, long_args))
  should.be_false(string.contains(html, long_result))
  // Opening the popup is where the full text renders.
  let open = step(model, ui.ToolViewOpened(ui.CallPop("call_1")))
  let open_html = view_string(open)
  should.be_true(string.contains(open_html, long_args))
  should.be_true(string.contains(open_html, long_result))
}

// The full-call popup: clicking the chip opens a <dialog> with the
// COMPLETE argument and result text.
pub fn view_popup_shows_full_call_test() {
  let long_args = string.repeat("a", 500)
  let long_result = string.repeat("r", 500)
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", long_args, None))
    |> step(ui.ToolResult("call_1", "http_fetch", True, long_result))
    // The result line is stored with the full content only; the earlier
    // assembled log line carries the arguments.
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  let html = view_string(model)
  should_contain(html, "<dialog open>")
  // The backdrop click-catcher renders as the dialog's first child, so
  // clicking outside the card dismisses the popup (see the .tool-pop-hit
  // CSS note; server components cannot stop an event's bubble, so the
  // card simply paints above the catcher).
  should_contain(
    html,
    "<dialog open><div class=\"tool-pop-hit\"></div><article class=\"tool-pop done\"",
  )
  should.be_true(string.contains(html, ">http_fetch</h2>"))
  // Full text, not the truncated preview.
  should.be_true(string.contains(html, string.repeat("a", 500)))
  should.be_true(string.contains(html, string.repeat("r", 500)))
}

pub fn view_popup_closed_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolResult("call_1", "http_fetch", True, "[]"))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
    |> step(ui.ToolViewClosed)
  let html = view_string(model)
  should_not_contain(html, "<dialog open>")
  // The chip stays; only the popup closed.
  should_contain(
    html,
    "<button aria-label=\"http_fetch (completed)\" class=\"turn tool done\"",
  )
}

pub fn view_popup_defaults_closed_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
  view_string(model) |> should_not_contain("<dialog")
}

// A popup whose call no longer resolves — a rolled-back turn's card, or a
// pending call whose fragments cleared — renders nothing rather than going
// stale over content that is gone.
pub fn view_popup_rolled_back_call_renders_nothing_test() {
  let model =
    new_model()
    |> step(ui.Hello("test-model"))
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  should_contain(view_string(model), "<dialog open>")
  // TurnFailed with nothing committed rolls the whole turn back; the
  // popup goes with it.
  let failed = step(model, ui.TurnFailed("boom", None))
  view_string(failed) |> should_not_contain("<dialog open>")
}

pub fn view_popup_unknown_call_renders_nothing_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolViewOpened(ui.CallPop("call_nope")))
  view_string(model) |> should_not_contain("<dialog")
}

// Selecting a different thread drops the popup with the rest of the
// per-thread display state.
pub fn view_popup_cleared_on_thread_switch_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  should_contain(view_string(model), "<dialog open>")
  let switched = step(model, ui.Select("other-thread"))
  view_string(switched) |> should_not_contain("<dialog")
}

// A pending (still-streaming) call's popup resolves against the pending
// list and live-updates as further fragments arrive.
pub fn view_popup_pending_call_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("http_fetch"), "start"))
    |> step(ui.ToolViewOpened(ui.PendingPop(0)))
  let html = view_string(model)
  should_contain(html, "<dialog open>")
  should.be_true(string.contains(html, "class=\"tool-pop running\""))
  should.be_true(string.contains(html, "<pre>start"))
  // The next fragment updates the open popup in place.
  let grown = step(model, ui.ToolCallDelta(0, Some("call_1"), None, "-more"))
  should.be_true(string.contains(view_string(grown), "<pre>start-more"))
}

// Codemode arguments are JSON {"code": "<lua source>"} with every
// newline escaped — one unreadable line as raw JSON. The popup decodes
// the string field and renders the script under a "Script" label.
pub fn view_popup_decodes_codemode_script_test() {
  let args = "{\"code\":\"-- init\\nlocal x = 1\"}"
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "codemode", args, None))
    |> step(ui.ToolResult("call_1", "codemode", True, "ok"))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  let html = view_string(model)
  should_contain(html, ">Script</h3>")
  // The decoded source with its REAL newline, not the \\n escape.
  should.be_true(string.contains(html, "<pre>-- init\nlocal x = 1</pre>"))
  should_not_contain(html, "{&quot;code&quot;")
}

// Any other argument shape renders the raw argument text under
// "Arguments" — non-JSON text, malformed JSON, non-string `code`, and
// objects with EXTRA keys (a single-key {"code": string} is codemode's
// exact schema; extra-key objects would silently hide the other
// arguments if decoded).
pub fn view_popup_raw_arguments_fallback_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled(
      "call_1",
      "web_search",
      "{\"query\":\"cats\"}",
      None,
    ))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  let html = view_string(model)
  should_contain(html, ">Arguments</h3>")
  should_not_contain(html, ">Script</h3>")
  should.be_true(string.contains(html, "{&quot;query&quot;:&quot;cats&quot;}"))
  // A code field with extra keys is NOT a codemode call: decoding it
  // would drop the sibling arguments.
  let extra =
    step(
      model,
      ui.ToolCallAssembled(
        "call_2",
        "codemode",
        "{\"code\":\"return 1\",\"note\":\"hi\"}",
        None,
      ),
    )
    |> step(ui.ToolViewOpened(ui.CallPop("call_2")))
  let extra_html = view_string(extra)
  should_contain(extra_html, ">Arguments</h3>")
  should_not_contain(extra_html, ">Script</h3>")
  // A non-string code field is not a script either.
  let typed =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "codemode", "{\"code\":1}", None))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  view_string(typed) |> should_contain(">Arguments</h3>")
}

// An open pending popup survives assembly: when the matching call
// commits under its stable id, the selection migrates from the chunk
// index to the id so the popup stays live through execution and
// completion.
pub fn view_popup_pending_survives_assembly_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("http_fetch"), "{\"u"))
    |> step(ui.ToolViewOpened(ui.PendingPop(0)))
  should_contain(view_string(model), "<dialog open>")
  let assembled =
    step(
      model,
      ui.ToolCallAssembled("call_1", "http_fetch", "{\"url\":\"x\"}", None),
    )
  let html = view_string(assembled)
  should_contain(html, "<dialog open>")
  // The migrated popup resolves against the committed line and shows the
  // complete assembled arguments.
  should.be_true(string.contains(html, "{&quot;url&quot;:&quot;x&quot;}"))
  // A DIFFERENT pending index does not migrate (its call has not
  // assembled) and stays resolvable against the pending list.
  let sibling =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{}"))
    |> step(ui.ToolCallDelta(1, Some("call_2"), Some("http_fetch"), "{\"u"))
    |> step(ui.ToolViewOpened(ui.PendingPop(1)))
  let assembled_sibling =
    step(sibling, ui.ToolCallAssembled("call_1", "web_search", "{}", None))
  should_contain(view_string(assembled_sibling), "<dialog open>")
}

// A new turn's user echo drops an open popup: call ids are only unique
// WITHIN a turn (fallback ids are `call_<index>`, restarting at 0 every
// turn), so a popup left open across turns could silently switch to the
// new turn's same-named call.
pub fn view_popup_cleared_when_turn_begins_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_0", "http_fetch", "{}", None))
    |> step(ui.ToolViewOpened(ui.CallPop("call_0")))
  should_contain(view_string(model), "<dialog open>")
  let next_turn = step(model, ui.UserEcho("run it again", None, None))
  view_string(next_turn) |> should_not_contain("<dialog")
}

// Popup content is hostile text: a script payload in a tool result renders
// as escaped text inside the dialog — never as an element.
pub fn view_popup_escapes_hostile_content_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("call_1", "http_fetch", "{}", None))
    |> step(ui.ToolResult(
      "call_1",
      "http_fetch",
      True,
      "<script>alert(1)</script>",
    ))
    |> step(ui.ToolViewOpened(ui.CallPop("call_1")))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;"))
  should_not_contain(html, "<script>")
}

pub fn view_renders_pending_card_test() {
  let model =
    new_model()
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{\"que"))
  let html = view_string(model)
  // A streaming call renders as the same compact clickable chip; its
  // popup resolves against the pending list, keyed by chunk index.
  should_contain(
    html,
    "<button aria-label=\"web_search (running)\" class=\"turn tool running pending\" data-call-index=\"0\" title=\"View full call\" type=\"button\"><strong class=\"tool-name\">web_search</strong></button>",
  )
  should_not_contain(html, "{&quot;que")
}

pub fn view_escapes_tool_content_test() {
  let model =
    new_model()
    |> step(ui.ToolCallAssembled("<x>", "web_search", "{}", None))
    |> step(ui.ToolResult(
      "<x>",
      "web_search",
      True,
      "<script>alert(1)</script>",
    ))
  let html = view_string(model)
  // The call id rides the chip as a data attribute — escaped like any
  // attribute value — and the result text does not render inline at all
  // (the popup render is pinned by view_popup_escapes_hostile_content_test).
  should.be_true(string.contains(html, "data-call-id=\"&lt;x&gt;\""))
  should_not_contain(html, "<script>alert")
}

pub fn view_renders_loop_chip_test() {
  let model = new_model() |> step(ui.LoopStatus(2, 8, "tools"))
  let html = view_string(model)
  should.be_true(string.contains(html, "id=\"loop-status\""))
  should.be_true(string.contains(html, "iter 2/8 · tools"))
}

// Message timestamps: relative age as the label, absolute instant on
// hover (`title`) and as the machine datetime, epoch for timestamps_js.
pub fn view_renders_message_timestamps_test() {
  // Five minutes ago — the label is deterministic ("5m ago") with no
  // unit-boundary anywhere near.
  let stamp = timing.wall_now_s() - 300
  let model =
    new_model()
    |> step(ui.UserEcho("hello", Some(stamp), None))
    |> step(ui.AssistantFull("hi there", Some(stamp)))
  let html = view_string(model)
  should_contain(html, "5m ago")
  let instant = timing.wall_to_rfc3339(stamp)
  should.be_true(string.contains(html, "title=\"" <> instant <> "\""))
  should.be_true(string.contains(html, "datetime=\"" <> instant <> "\""))
  should.be_true(string.contains(
    html,
    "data-epoch=\"" <> int.to_string(stamp) <> "\"",
  ))
}

pub fn view_omits_timestamps_for_unstamped_lines_test() {
  // Legacy history persisted before created_at replays with None stamps:
  // no <time> element at all, not a bogus epoch.
  let model =
    new_model()
    |> step(ui.UserEcho("legacy", None, None))
    |> step(ui.AssistantFull("legacy reply", None))
  let html = view_string(model)
  should_not_contain(html, "data-epoch")
  should_not_contain(html, "<time")
}

pub fn turn_done_stamps_committed_bubble_test() {
  // The terminal event carries the thread's committed stamp
  // (`transcript.last_text_stamp`, sourced by the actor) — the live
  // bubble before TurnDone renders no timestamp at all, and the commit
  // carries EXACTLY the event's value: one clock, no UI-side read.
  let stamp = timing.wall_now_s() - 300
  let live = new_model() |> step(ui.Token("stream"))
  live |> view_string |> should_not_contain("data-epoch")
  let committed = live |> step(ui.TurnDone(Some(stamp)))
  let html = view_string(committed)
  should_contain(html, "5m ago")
  let instant = timing.wall_to_rfc3339(stamp)
  should.be_true(string.contains(html, "title=\"" <> instant <> "\""))
  should.be_true(string.contains(
    html,
    "data-epoch=\"" <> int.to_string(stamp) <> "\"",
  ))
  // Unstamped terminal (legacy / nothing committed) renders no time.
  new_model()
  |> step(ui.Token("raw"))
  |> step(ui.TurnDone(None))
  |> view_string
  |> should_not_contain("data-epoch")
}

/// The delta arm commits the flushed round's text ahead of the worker's
/// append (display-order rule, pinned since the MVP) with NO stamp — the
/// authoritative value does not exist yet. The round's ToolCallAssembled
/// carries the loop's flush stamp and restamps exactly that line.
pub fn assembled_restamps_flushed_line_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("look this up", None, None))
    |> step(ui.Token("checking"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("web_search"), "{}"))
  // Committed at fragment time, unstamped: no UI clock read.
  let assert [ui.AssistantLine("checking", None), ..] = model.log
  let model =
    step(
      model,
      ui.ToolCallAssembled("call_1", "web_search", "{}", Some(1_700_000_000)),
    )
  // Assembly restamps by the committed text and prepends the call card.
  let assert [
    ui.ToolLine("call_1", "web_search", "{}", ui.ToolRunning, None),
    ui.AssistantLine("checking", Some(1_700_000_000)),
    ui.UserLine("look this up", None, None),
  ] = model.log
}

/// A Stop landing between the fragment commit and its round's assembly
/// restamps the flushed line from the terminal event instead (the loop
/// commits the partial text on stop, so `last_text_stamp` is its value).
pub fn turn_stopped_restamps_flushed_line_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("q", None, None))
    |> step(ui.Token("partial"))
    |> step(ui.ToolCallDelta(0, Some("c1"), Some("echo"), "{}"))
    |> step(ui.TurnStopped(Some(5_000_000)))
  let assert [
    ui.AssistantLine("partial", Some(5_000_000)),
    ui.UserLine("q", None, None),
  ] = model.log
}

pub fn age_label_units_test() {
  let now = 1_000_000
  ui.age_label(now, now) |> should.equal("just now")
  ui.age_label(now, now - 30) |> should.equal("just now")
  ui.age_label(now, now - 60) |> should.equal("1m ago")
  ui.age_label(now, now - 300) |> should.equal("5m ago")
  ui.age_label(now, now - 7200) |> should.equal("2h ago")
  ui.age_label(now, now - 3 * 86_400) |> should.equal("3d ago")
  ui.age_label(now, now - 14 * 86_400) |> should.equal("2w ago")
  ui.age_label(now, now - 400 * 86_400) |> should.equal("1y ago")
  // Future stamps (clock skew) clamp to "just now", never negative.
  ui.age_label(now, now + 100) |> should.equal("just now")
}

pub fn view_hides_loop_chip_without_loop_test() {
  // Lustre SSR sorts attributes: hidden precedes id.
  new_model() |> view_string |> should_contain("hidden id=\"loop-status\"")
}

pub fn view_renders_guard_chip_terminal_test() {
  let model = new_model() |> step(ui.LoopStatus(8, 8, "guard"))
  model |> view_string |> should_contain("iter 8/8 · guard")
  let terminal =
    model |> step(ui.TurnFailed("iteration guard: reached max 8", None))
  terminal |> view_string |> should_contain("turn failed: iteration guard")
}

fn should_contain(haystack: String, needle: String) {
  should.be_true(string.contains(haystack, needle))
}

fn should_not_contain(haystack: String, needle: String) {
  should.be_false(string.contains(haystack, needle))
}

/// Commit stamps are the wall-clock commit instant (see
/// `commit_bubble`), so commit-shape assertions compare with stamps
/// stripped; `turn_done_stamps_committed_bubble_test` pins that the
/// stamp is actually there, and the timestamp rendering tests pin its
/// value end-to-end.
fn log_shapes(log: List(ui.Line)) -> List(ui.Line) {
  list.map(log, fn(line) {
    case line {
      // Only the stamp is stripped: the author is display provenance the
      // commit-shape assertions must still see.
      ui.UserLine(text, author, _) -> ui.UserLine(text, author, None)
      ui.AssistantLine(text, _) -> ui.AssistantLine(text, None)
      other -> other
    }
  })
}

// ---------------------------------------------------------------------------
// View strings
// ---------------------------------------------------------------------------

fn view_string(model: ui.Model) -> String {
  element.to_string(ui.view(model))
}

pub fn view_new_button_precedes_thread_list_test() {
  // The New button keeps its spot (the section head above the list), and
  // the browser suite still drives it by `#new-thread`. The create panel
  // is gone — the bot picker lives beside the composer.
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> view_string
  let assert Ok(#(before_list, _)) =
    string.split_once(html, "id=\"thread-list\"")
  should.be_true(string.contains(before_list, "id=\"new-thread\""))
  should.be_false(string.contains(html, "create-panel"))
}

pub fn view_renders_shell_and_sidebar_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
  let html = view_string(model)
  should.be_true(string.contains(html, "id=\"app\""))
  should.be_true(string.contains(html, "id=\"thread-list\""))
  // M3 organization: the row carries the thread id; the title falls back
  // to "Untitled thread" until auto-titled (#107: the alias left the
  // chrome with the subtitle; provenance is bot-or-nothing, then the age).
  should.be_true(string.contains(html, "data-thread-id=\"s-1\""))
  should.be_true(string.contains(html, "Untitled thread"))
  should.be_false(string.contains(html, "smart · "))
  should.be_true(string.contains(html, "class=\"thread-sub\""))
  should.be_true(string.contains(html, "aria-current=\"true\""))
  // With a thread selected the compose-new picker is not mounted at all.
  should.be_false(string.contains(html, "bot-picker"))
  should.be_true(string.contains(html, "id=\"tag-filter\""))
  should.be_true(string.contains(html, "Show archived"))
  // No raw HTML injection: dynamic text is escaped by Lustre text nodes.
  should.be_false(string.contains(html, "innerHTML"))
}

pub fn view_renders_empty_states_test() {
  let html = new_model() |> view_string
  should.be_true(string.contains(html, "No threads yet."))
  should.be_true(string.contains(html, "disabled"))
}

// ui-polish F5: an empty transcript renders an intentional muted hint, not
// a blank void; the hint disappears the moment there is anything to show.
pub fn view_empty_transcript_note_test() {
  // Compose-new with bots available: the hint names the flow — pick the
  // bot beside the composer and send (the composer is live).
  let html =
    new_model()
    |> step(ui.BotsLoaded([bot_row("b1", "Writer", "", None)]))
    |> view_string
  should.be_true(string.contains(
    html,
    "Pick a bot beside the composer, type a message, and send",
  ))
  // Compose-new with NO bots: the composer stands down; the hint points
  // at Settings.
  let html = new_model() |> view_string
  should.be_true(string.contains(
    html,
    "No bots yet — add one in Settings (top right)",
  ))
  // With a selection and an empty transcript the hint invites a send.
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> view_string
  should.be_true(string.contains(
    html,
    "Send a message to start — tool calls and reasoning will render here",
  ))
  // A committed user line displaces the hint (streaming or committed
  // alike: both make log_lines non-empty).
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.UserEcho("hi", None, None))
    |> view_string
  should.be_false(string.contains(html, "Send a message to start"))
}

// ui-polish F8: the header's context span shows the selected thread's
// title, not the bare model alias. The alias stays as the untitled
// fallback (the row-title rule); with nothing selected the fallback
// span is BLANK until there is something to say ("thread ended") — the
// old "connecting…" placeholder claimed a connection state the conn
// indicator already owns.
pub fn view_header_shows_thread_title_test() {
  let titled =
    thread.ThreadSummary(..summary("s-1", False), title: "Renamed thread")
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([titled]))
    |> step(ui.Select("s-1"))
    |> view_string
  should.be_true(string.contains(html, "id=\"model\""))
  should.be_true(string.contains(html, "Renamed thread"))

  // Untitled thread: a plain placeholder, in the header and the row —
  // the alias fallback left the chrome with the subtitle (#107).
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> view_string
  should.be_true(string.contains(html, ">Untitled thread<"))
  should.be_false(string.contains(html, ">smart<"))
}

pub fn view_header_fallback_labels_test() {
  // No selection yet: the context span renders EMPTY — no placeholder
  // text — while the span itself stays for the title to land in. The
  // exact empty-span fragment pins the blank: any non-empty fallback
  // (a placeholder reintroduced, stray text) fails here.
  let html = new_model() |> view_string
  should.be_true(string.contains(html, "id=\"model\"></span>"))
  // Selection dropped (thread vanished): the terminal label.
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.ThreadsLoaded([]))
    |> view_string
  should.be_true(string.contains(html, "thread ended"))
}

// ui-polish F8: the connection state is a labelled group — the dot plus
// a text twin the static indicator script flips on transport events.
pub fn view_header_connection_label_test() {
  let html = new_model() |> view_string
  should.be_true(string.contains(html, "id=\"status\""))
  should.be_true(string.contains(html, "id=\"status-label\""))
  should.be_true(string.contains(html, "class=\"conn\""))
  should.be_true(string.contains(html, "connected"))
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
    |> step(ui.UserEcho("<script>alert(1)</script>", None, None))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>alert"))
}

// Bots P3b / issue #122: bot-delivered user lines fold up as a chip —
// the collapsed summary names the sender, and the line no longer reads
// as the user's own bubble. A human line beside it stays a plain user
// bubble. Bot text renders as inert content; only the chip wraps it, and
// only when an author exists.
pub fn view_renders_bot_message_chip_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hello", None, Some("Hermes")))
    |> step(ui.UserEcho("mine", None, None))
  let html = view_string(model)
  should.be_true(string.contains(html, "<details class=\"turn bot\">"))
  should.be_true(string.contains(html, ">Hermes<"))
  should.be_true(string.contains(html, ">mine<"))
  // The chip carries the delivery provenance on hover, like the
  // timestamp's absolute instant.
  should.be_true(string.contains(html, "delivered by Hermes"))
  // The bot payload must NOT read as the user's own bubble: the human
  // line beside it keeps the plain user-bubble shape, and the bot text
  // appears nowhere in one (the same class="turn user" probe on its own
  // would pass off the human line alone).
  should.be_true(string.contains(
    html,
    "<div class=\"turn user\"><span>mine</span>",
  ))
  should.be_false(string.contains(
    html,
    "<div class=\"turn user\"><span>hello</span>",
  ))
}

// Environments plan Phase 1: roster messages (author sidecar `system`)
// render as muted status lines — never chat bubbles, never badges.
pub fn view_renders_roster_status_line_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("attached targets: workspace.", None, Some("system")))
  let html = view_string(model)
  should.be_true(string.contains(html, "turn status"))
  should.be_true(string.contains(html, "attached targets: workspace."))
  // Not a chat bubble: no user pill, no origin badge.
  should.be_false(string.contains(html, "turn user"))
  should.be_false(string.contains(html, "class=\"origin\""))
}

// A roster message's bytes are external content under the hostile-text
// rules — a node could report anything in its metadata.
pub fn roster_status_line_hostile_text_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("<script>x</script>", None, Some("system")))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>x"))
}

pub fn view_escapes_author_names_test() {
  // The author name is bot-sourced display text frozen at send time —
  // hostile-text rules apply to it exactly like message content: it is a
  // text node in the chip summary and an escaped attribute value on its
  // hover title, never markup.
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, Some("<img src=x onerror=alert(1)>")))
  let html = view_string(model)
  should.be_true(string.contains(html, "&lt;img"))
  should.be_false(string.contains(html, "<img "))
}

pub fn view_bot_message_renders_markdown_safely_test() {
  // The chip body renders the sender's text through the same
  // security-safe markdown renderer as assistant turns (issue #122):
  // markdown structures render, hostile raw HTML stays inert escaped
  // text. A HUMAN send carrying the same bytes keeps verbatim plain
  // text — markdown is never applied to the user's own lane.
  let model =
    new_model()
    |> step(ui.UserEcho(
      "**bold** forecast\n\n- 12°C\n\n<script>alert(1)</script>",
      None,
      Some("researcher"),
    ))
  let html = view_string(model)
  should.be_true(string.contains(html, "<strong>bold</strong>"))
  should.be_true(string.contains(html, "&lt;script&gt;"))
  should.be_false(string.contains(html, "<script>alert"))
  let plain =
    new_model()
    |> step(ui.UserEcho("**bold**", None, None))
    |> view_string
  // The verbatim bytes survive untouched (a dropped or altered human
  // message must not pass this probe), and markdown never applied.
  should.be_true(string.contains(plain, "<span>**bold**</span>"))
  should.be_false(string.contains(plain, "<strong>"))
}

pub fn view_renders_streaming_bubble_test() {
  let model = new_model() |> step(ui.Token("Hel")) |> step(ui.Token("lo"))
  let html = view_string(model)
  should.be_true(string.contains(html, "Hello"))
  should.be_true(string.contains(html, "turn assistant"))
}

// ---------------------------------------------------------------------------
// M3 thread organization: buckets, relative time, filter, update flows
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
) -> thread.ThreadSummary {
  thread.ThreadSummary(
    id: id,
    provider_id: "p1",
    model: "smart",
    title: title,
    title_source: thread.AutoTitle,
    pinned: pinned,
    tags: tags,
    archived: archived,
    bot_id: None,
    message_count: 2,
    streaming: False,
    created_at: last_active_at,
    last_active_at: last_active_at,
    metrics: [],
  )
}

pub fn threads_auto_select_first_active_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let active = meta_summary("s-2", "New", False, [], False, 0)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([archived, active]))
  // The archived row is soft-hidden, so auto-selection skips it.
  model.selected |> should.equal(Some("s-2"))
}

pub fn archived_selection_survives_refresh_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let model =
    new_model()
    |> step(ui.Select("s-1"))
    |> step(ui.ThreadsLoaded([archived]))
  // A selection POINTING at an archived thread (e.g. the user re-opened
  // the row via Show archived) survives a refresh — only a real
  // disappearance ends it. (Archiving the open thread is different: the
  // `Archived` arm clears the selection itself — see
  // archive_of_selection_clears_selection_test.)
  model.selected |> should.equal(Some("s-1"))
  // The fallback label is blank — a not-yet-resolved selection renders
  // nothing, never a connection state.
  model.model_label |> should.equal("")
}

pub fn all_archived_leaves_compose_new_test() {
  let archived = meta_summary("s-1", "Old", False, [], True, 0)
  let model = new_model() |> step(ui.ThreadsLoaded([archived]))
  model.selected |> should.equal(None)
  // No active thread to select: the composer sits in its compose-new
  // shape (bot picker beside the entry field) so the sidebar is never a
  // dead end.
}

pub fn delete_of_selection_reselects_first_active_test() {
  let a = meta_summary("s-1", "A", False, [], False, 0)
  let b = meta_summary("s-2", "B", False, [], False, 0)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([a, b]))
    |> step(ui.Select("s-2"))
    |> step(ui.ThreadsLoaded([a]))
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
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
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
    |> step(ui.ThreadsLoaded([pinned, today, older]))
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
    |> step(ui.ThreadsLoaded([archived]))
    |> view_string
  // Soft-hidden by default: the row is absent, the empty state shows.
  should.be_false(string.contains(hidden, "Shelved"))
  should.be_true(string.contains(hidden, "No threads yet."))

  let shown =
    new_model()
    |> step(ui.ThreadsLoaded([archived]))
    |> step(ui.ArchivedToggled)
    |> view_string
  should.be_true(string.contains(shown, "Archived"))
  should.be_true(string.contains(shown, "Shelved"))
  should.be_true(string.contains(shown, "Restore"))
  // The group keeps list semantics next to #thread-list — it moved
  // below the toggle, not out of the thread list.
  should.be_true(string.contains(shown, "archive-group\" role=\"list\""))
  // Invariant: archived rows carry no pin control (archiving unpins;
  // the registry refuses pins on archived threads).
  should.be_false(string.contains(shown, ">Pin<"))
  should.be_false(string.contains(shown, ">Unpin<"))

  // A filter that matches only archived rows must not print "no
  // matches" above the matching rows: the active section's empty line
  // steps aside while the group below carries the results.
  let filtered =
    new_model()
    |> step(ui.ThreadsLoaded([archived]))
    |> step(ui.ArchivedToggled)
    |> step(ui.TagFilterChanged("shel"))
    |> view_string
  should.be_true(string.contains(filtered, "Shelved"))
  should.be_false(string.contains(filtered, "No threads match the filter."))

  // No archived match under the filter: the honest empty text returns.
  let none_match =
    new_model()
    |> step(ui.ThreadsLoaded([archived]))
    |> step(ui.ArchivedToggled)
    |> step(ui.TagFilterChanged("zzz"))
    |> view_string
  should.be_false(string.contains(none_match, "Shelved"))
  should.be_true(string.contains(none_match, "No threads match the filter."))
}

pub fn view_hides_rows_failing_the_filter_test() {
  let a =
    meta_summary("s-1", "Deploy notes", False, ["ops"], False, 1_700_000_000)
  let b = meta_summary("s-2", "Cooking", False, [], False, 1_700_000_000)
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([a, b]))
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
    |> step(ui.ThreadsLoaded([a]))
    |> view_string
  // Editors and the delete confirm render but are hidden (attr.hidden).
  should.be_true(string.contains(base, "inline-editor"))
  should.be_true(string.contains(base, "confirm-delete"))
  let opened =
    new_model()
    |> step(ui.ThreadsLoaded([a]))
    |> step(ui.RenameToggled("s-1"))
    |> view_string
  // The rename input carries the current title as its starting value.
  should.be_true(string.contains(opened, "value=\"Deploy notes\""))
  let tags_open =
    new_model()
    |> step(ui.ThreadsLoaded([a]))
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

pub fn providers_loaded_keeps_masked_metadata_test() {
  let model =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", False, True),
        prov("p2", "ollama", True, False),
      ]),
    )
  list.length(model.provider_list) |> should.equal(2)
  // has_key is the only key fact that reaches the UI model.
  list.map(model.provider_list, fn(p) { p.has_key })
  |> should.equal([True, False])
}

pub fn providers_loaded_notes_only_when_load_concludes_empty_test() {
  // The "no provider configured" note fires only when a provider LOAD
  // concludes no enabled provider exists — never from a mere "nothing
  // selected yet" (the pre-load state of every fresh connection, which
  // the old connect-time alias effect misread as "none exist" and
  // logged the bogus note for).
  let empty =
    new_model()
    |> step(ui.ProvidersLoaded([]))
  note_count(empty.log) |> should.equal(1)

  // A load with an enabled provider — the fresh-start path that used to
  // be defamed by the bug — notes nothing.
  let offered =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
  offered.log |> should.equal([])

  // All-disabled is "none exist" too: same note.
  let disabled =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", False, True)]))
  note_count(disabled.log) |> should.equal(1)

  // Repeated refreshes that STAY empty add nothing: the note fires on
  // the first load and on transitions, never per refresh — ordinary
  // Settings reloads while nothing is enabled must not stack duplicate
  // notes in the log.
  let refreshed =
    new_model()
    |> step(ui.ProvidersLoaded([]))
    |> step(ui.ProvidersLoaded([]))
    |> step(ui.ProvidersLoaded([]))
  note_count(refreshed.log) |> should.equal(1)

  // Losing the last enabled provider mid-thread still notes: the
  // Some -> None transition is new information, not a repeat.
  let lost =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.ProvidersLoaded([]))
  note_count(lost.log) |> should.equal(1)
}

/// How many "no provider configured" note lines the log carries.
fn note_count(log: List(ui.Line)) -> Int {
  log
  |> list.filter(fn(line) {
    case line {
      ui.NoteLine(_, text) -> string.contains(text, "no provider configured")
      _ -> False
    }
  })
  |> list.length
}

pub fn provider_created_returns_to_chat_on_first_provider_test() {
  // The creation lands in the settings sub-component; the signal fold
  // in ui.update returns the view to chat when the FIRST provider lands
  // (the auto-opened settings page has served its purpose). There is no
  // picker re-aim anymore — the composer's bot picker has no provider
  // selection of its own. Start from the AUTO-OPENED settings view
  // (first load empty) so the ChatView assertion is load-bearing.
  let opened = new_model() |> step(ui.ProvidersLoaded([]))
  opened.view |> should.equal(ui.SettingsView)
  let model =
    opened
    |> step(ui.Settings(ui_settings.Created(prov("p3", "new", True, True))))
  // The provider list itself reloads via the paired ProvidersChanged
  // signal (the harness drops effects) — the fold's own verdict is the
  // view flip.
  model.view |> should.equal(ui.ChatView)
  // A settings visit that was NOT the first-run auto-open stays put.
  let kept =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p2", "ollama", True, False)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.Created(prov("p3", "new", True, True))))
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
  // Controls mirror the thread rows' compact pattern — plus the
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

pub fn view_settings_page_structured_test() {
  // ui-polish F7 markup: one header row (title left, Add right), provider
  // rows with the badge in a .provider-head next to the name, and form
  // cards that carry a heading. (The card LOOK — borders, centering — is
  // CSS pinned in web_test; this pins the markup that carries it.)
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, False)]))
    |> step(ui.SettingsToggled)
    |> view_string
  // Header row: the section head names only its category — the header
  // button's Settings/Back-to-chat toggle is the page context.
  should.be_true(string.contains(html, "section-head"))
  should.be_true(string.contains(html, ">Providers<"))
  should.be_false(string.contains(html, "Settings · Providers"))
  // Badge lives in the row head beside the name, not on its own line.
  let head_at = position_of(html, "provider-head")
  let name_at = position_of(html, "provider-name")
  let badge_at = position_of(html, ">keyless<")
  // Presence first: position_of is -1 on a miss, and a -1 would make the
  // ordering comparisons below pass vacuously.
  should.be_true(head_at >= 0)
  should.be_true(name_at >= 0)
  should.be_true(badge_at >= 0)
  should.be_true(head_at < name_at && name_at < badge_at)
  let sub_at = position_of(html, "provider-sub")
  // The base URL follows the head (the head wraps name + badges).
  should.be_true(sub_at >= 0)
  should.be_true(badge_at < sub_at)
  // Both form cards carry a heading, present even while hidden.
  should.be_true(string.contains(html, "<h3"))
  should.be_true(string.contains(html, ">Add provider<"))
  let editing =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, False)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.EditToggled("p1")))
    |> view_string
  should.be_true(string.contains(editing, ">Edit provider<"))
}

pub fn view_provider_forms_hidden_until_opened_test() {
  let base =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> view_string
  // Both forms render but are hidden (the thread-editor pattern).
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

/// The rendered text of the first `.thread-sub` span in a view string —
/// empty when no row subtitle rendered. Subtitle assertions compare it
/// whole, so a subtitle that silently dropped its age (or grew a
/// provider/model prefix back) fails loudly instead of merely not
/// matching a negative contains.
fn first_thread_sub(html: String) -> String {
  case string.split_once(html, "class=\"thread-sub\">") {
    Error(_) -> ""
    Ok(#(_, rest)) ->
      case string.split_once(rest, "</span>") {
        Error(_) -> ""
        Ok(#(text, _)) -> text
      }
  }
}

pub fn view_thread_subtitle_omits_provider_model_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> view_string
  // #107: the bot-less subtitle IS the age alone — compared whole against
  // rel_time at (nearly) the same instant. The gap from epoch 0 is
  // year-granular, so a second boundary between the render and this
  // check cannot change the label. A subtitle that dropped its age or
  // grew a provider/model prefix fails either way; the id fallback the
  // old test pinned (`p1/smart`) has no render to exist in.
  should.equal(first_thread_sub(html), ui.rel_time(timing.wall_now_s(), 0))
  let lagging =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> view_string
  should.equal(first_thread_sub(lagging), ui.rel_time(timing.wall_now_s(), 0))
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

pub fn view_jump_latest_button_test() {
  // The "jump to latest" control is server-rendered structure only, and
  // inert by construction: hidden up front (a fresh view opens at the
  // bottom; Lustre SSR sorts attributes), no event handler, and none of
  // the old repo's inline `onclick` script. It is a sibling AFTER #log,
  // inside #log-wrap, so it never lands in the log's aria-live region
  // (with a thread selected and an empty transcript the log renders the
  // F5 empty-state note inside the centered `.conversation` column F6
  // puts in #log, which is why the log is no longer bare).
  new_model()
  |> step(ui.ThreadsLoaded([summary("s-1", False)]))
  |> step(ui.Select("s-1"))
  |> view_string
  |> should_contain(
    "<div id=\"log-wrap\"><div aria-live=\"polite\" id=\"log\">"
    <> "<div class=\"conversation\"><div class=\"note\">Send a message to "
    <> "start — tool calls and reasoning will render here</div></div></div>"
    <> "<button aria-label=\"Jump to latest\" hidden id=\"jump-latest\" "
    <> "type=\"button\">↓</button></div>",
  )
  should.be_false(string.contains(new_model() |> view_string, "onclick"))
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

pub fn settings_tabs_render_providers_by_default_test() {
  // The page is a left tab rail (Providers / Bots) beside the category
  // sections. BOTH sections stay in the DOM — the inactive one carries
  // `hidden`, mirroring the forms — so uncontrolled inputs keep typed
  // values across tab switches. Providers is the default tab: the
  // first-run auto-open lands there with an empty list.
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> view_string
  should.be_true(string.contains(html, "id=\"settings-nav\""))
  should.be_true(string.contains(html, "id=\"tab-providers\""))
  should.be_true(string.contains(html, "id=\"tab-bots\""))
  // The pressed state and the `.on` class name the same tab, and the
  // sections' visibility follows it.
  should.be_true(string.contains(
    html,
    "class=\"settings-tab on\" id=\"tab-providers\"",
  ))
  should.be_false(string.contains(html, "hidden id=\"providers-panel\""))
  should.be_true(string.contains(html, "hidden id=\"bots-panel\""))
}

pub fn settings_tab_switch_flips_visibility_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> view_string
  // The sections swap visibility; both stay mounted.
  should.be_true(string.contains(html, "hidden id=\"providers-panel\""))
  should.be_false(string.contains(html, "hidden id=\"bots-panel\""))
  should.be_true(string.contains(
    html,
    "class=\"settings-tab on\" id=\"tab-bots\"",
  ))
}

pub fn settings_tab_switch_stands_forms_down_test() {
  // Switching tabs stands every open form/editor/confirm down. The
  // update rules only ever let ONE transient be active at a time (the
  // one-form-per-page mutual exclusion), so a single setup cannot arm
  // all six at once — the switch is exercised once from EACH state,
  // with a precondition assert that the setup actually armed it, so a
  // mutual-exclusion change that breaks reachability fails here
  // instead of passing vacuously.
  let base =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
  let bots = ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab))

  let with_add = step(base, ui.Settings(ui_settings.AddToggled))
  with_add.settings.open |> should.be_true
  assert_settings_transients_down(step(with_add, bots))

  let with_edit = step(base, ui.Settings(ui_settings.EditToggled("p1")))
  with_edit.settings.edit |> should.equal(Some("p1"))
  assert_settings_transients_down(step(with_edit, bots))

  let with_confirm = step(base, ui.Settings(ui_settings.DeleteRequested("p1")))
  with_confirm.settings.confirm |> should.equal(Some("p1"))
  assert_settings_transients_down(step(with_confirm, bots))

  let with_bot_add =
    step(base, ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
  with_bot_add.settings.bots_open |> should.be_true
  assert_settings_transients_down(step(with_bot_add, bots))

  let with_bot_edit =
    step(base, ui.Settings(ui_settings.BotEditToggled("b1", "p1", None)))
  with_bot_edit.settings.bot_edit |> should.equal(Some("b1"))
  assert_settings_transients_down(step(with_bot_edit, bots))

  let with_bot_confirm =
    step(base, ui.Settings(ui_settings.BotDeleteRequested("b1")))
  with_bot_confirm.settings.bot_confirm |> should.equal(Some("b1"))
  assert_settings_transients_down(step(with_bot_confirm, bots))
}

/// Every settings transient (both sections) is down after a tab
/// switch, and the tab landed on Bots.
fn assert_settings_transients_down(m: ui.Model) -> Nil {
  m.settings.tab |> should.equal(ui_settings.BotsTab)
  m.settings.open |> should.be_false
  m.settings.edit |> should.be_none
  m.settings.confirm |> should.be_none
  m.settings.bots_open |> should.be_false
  m.settings.bot_edit |> should.be_none
  m.settings.bot_confirm |> should.be_none
  // The combobox slot goes down with the forms.
  m.settings.bot_alias_provider |> should.be_none
}

pub fn settings_tab_reclick_is_noop_test() {
  // Clicking the tab you are already on does nothing: a stray double
  // click must not close a form you are mid-way through.
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.AddToggled))
  let same =
    step(model, ui.Settings(ui_settings.TabSelected(ui_settings.ProvidersTab)))
  same.settings.tab |> should.equal(ui_settings.ProvidersTab)
  same.settings.open |> should.be_true
  same.settings.edit |> should.be_none
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
// Bot model combobox (Settings → Bots): live aliases suggest over free entry
// ---------------------------------------------------------------------------

pub fn bot_model_combobox_scopes_and_lists_test() {
  // Opening the add form scopes the combobox to the first provider and
  // fetches its live list; the reply settles the per-provider cache and
  // renders as a suggestion list anchored inside the field's wrap.
  let model =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", True, True),
        prov("p2", "other", True, True),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> step(ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
  model.settings.bot_alias_provider |> should.equal(option.Some("p1"))
  model.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasLoading))

  let loaded =
    step(
      model,
      ui.Settings(ui_settings.BotAliasesLoaded("p1", ["smart", "fast"])),
    )
  loaded.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasOk(["smart", "fast"])))

  let html = view_string(loaded)
  // The decoration: a select-style chevron class, the browser's own
  // history/autofill popup suppressed, and a hint naming the source —
  // the popup reads as our data, not the browser's suggestions.
  should.be_true(string.contains(html, "class=\"combo\""))
  should.be_true(string.contains(html, "autocomplete=\"off\""))
  should.be_true(string.contains(html, "live suggestions: bifrost model list"))
  // The suggestions are OUR list (no native datalist): server-rendered
  // options inside the field's wrap, carrying the alias in data-value
  // for the combobox script to fill on pick.
  should.be_true(string.contains(html, "class=\"combo-wrap\""))
  should.be_true(string.contains(html, "class=\"combo-list\""))
  should.be_true(string.contains(html, "data-value=\"smart\""))
  should.be_true(string.contains(html, "data-value=\"fast\""))
  // No editor is open, so the page renders exactly one list (the add
  // form's): split on the class and count the pieces.
  string.split(html, "class=\"combo-list\"")
  |> list.length
  |> should.equal(2)
}

pub fn bot_alias_cache_invalidated_on_provider_mutation_test() {
  // A provider edit/disable lands through the same connection that
  // cached its alias list: the cache must not outlive the mutation, or
  // re-selecting the provider would show the pre-edit list forever.
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> step(ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
    |> step(ui.Settings(ui_settings.BotAliasesLoaded("p1", ["smart"])))
  model.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasOk(["smart"])))

  let mutated = step(model, ui.Settings(ui_settings.Mutated))
  mutated.settings.bot_aliases |> dict.size |> should.equal(0)
  mutated.settings.bot_alias_provider |> should.be_none

  // Re-selecting refetches instead of trusting the dropped entry.
  let repicked =
    step(mutated, ui.Settings(ui_settings.BotAddProviderPicked("p1")))
  repicked.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasLoading))
}

pub fn bot_model_combobox_provider_switch_rescopes_test() {
  // Switching the open form's provider re-scopes the combobox and
  // fetches the new provider; the old list must not survive into it.
  let model =
    new_model()
    |> step(
      ui.ProvidersLoaded([
        prov("p1", "bifrost", True, True),
        prov("p2", "other", True, True),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> step(ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
    |> step(ui.Settings(ui_settings.BotAliasesLoaded("p1", ["smart"])))

  let switched =
    step(model, ui.Settings(ui_settings.BotAddProviderPicked("p2")))
  switched.settings.bot_alias_provider |> should.equal(option.Some("p2"))
  switched.settings.bot_aliases
  |> dict.get("p2")
  |> should.equal(Ok(ui_settings.AliasLoading))

  // A late reply for the superseded provider is dropped (its cache
  // entry already settled) — the Test control's stale-reply rule.
  let late =
    step(switched, ui.Settings(ui_settings.BotAliasesLoaded("p1", ["late"])))
  late.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasOk(["smart"])))

  // The new provider's reply lands and is the only thing suggested.
  let settled =
    step(late, ui.Settings(ui_settings.BotAliasesLoaded("p2", ["fast"])))
  let html = view_string(settled)
  should.be_true(string.contains(html, "data-value=\"fast\""))
  should_not_contain(html, "data-value=\"smart\"")
  should_not_contain(html, "data-value=\"late\"")
}

pub fn bot_model_combobox_failure_note_test() {
  // A failed fetch degrades to today's free-text behaviour with a
  // muted hint; a later re-selection retries (a fresh Loading entry).
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> step(ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
    |> step(ui.Settings(ui_settings.BotAliasesFailed("p1")))
  let html = view_string(model)
  should.be_true(string.contains(
    html,
    "could not load the model list — type the alias manually",
  ))
  model.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasFailed))

  let retried = step(model, ui.Settings(ui_settings.BotAddProviderPicked("p1")))
  retried.settings.bot_aliases
  |> dict.get("p1")
  |> should.equal(Ok(ui_settings.AliasLoading))
}

pub fn bot_edit_model_combobox_scopes_to_bot_provider_test() {
  // The inline editor scopes the combobox to the bot's own provider
  // (the select's preselected value), rendering the list inside that
  // row's wrap.
  let model =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.BotsLoaded([bot_row("b1", "Writer", "", None)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.BotEditToggled("b1", "p1", None)))
  model.settings.bot_alias_provider |> should.equal(option.Some("p1"))

  let html =
    step(model, ui.Settings(ui_settings.BotAliasesLoaded("p1", ["smart"])))
    |> view_string
  should.be_true(string.contains(html, "data-value=\"smart\""))
  should.be_true(string.contains(html, "live suggestions: bifrost"))
}

pub fn bot_model_combobox_hostile_aliases_escape_test() {
  // Model aliases come from the provider (hostile by contract): the
  // suggestion list's labels are inert Lustre text nodes AND the
  // data-value attribute the combobox script reads on pick is an
  // escaped attribute value — the script does getAttribute (no HTML
  // parsing), so a quote-bearing alias must arrive escaped in both
  // places or not at all.
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.TabSelected(ui_settings.BotsTab)))
    |> step(ui.Settings(ui_settings.BotAddToggled(Some("p1"))))
    |> step(
      ui.Settings(
        ui_settings.BotAliasesLoaded("p1", [
          "<img src=x onerror=alert(2)>",
          "x\" onmouseover=\"alert(1)",
        ]),
      ),
    )
    |> view_string
  should.be_true(string.contains(html, "&lt;img src=x onerror=alert(2)&gt;"))
  should.be_true(string.contains(html, "x&quot; onmouseover=&quot;alert(1)"))
  should.be_true(string.contains(
    html,
    "data-value=\"x&quot; onmouseover=&quot;alert(1)\"",
  ))
  should_not_contain(html, "<img src=x")
  should_not_contain(html, "onmouseover=\"alert(1)\"")
}

// ---------------------------------------------------------------------------
// Reasoning (chain of thought)
// ---------------------------------------------------------------------------

pub fn reasoning_streams_into_thinking_block_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
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
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("chain"))
    |> step(ui.Token("answer"))
    |> step(ui.TurnDone(None))
  model.thinking |> should.equal(None)
  model.bubble |> should.equal(None)
  // ReasoningLine was pushed before AssistantLine, so it renders above it.
  model.log
  |> log_shapes
  |> should.equal([
    ui.AssistantLine("answer", None),
    ui.ReasoningLine("chain"),
    ui.UserLine("hi", None, None),
  ])
  // …and the rendered log agrees: the collapsed reasoning block sits
  // above the assistant turn it preceded, not just first in the list.
  let html = model |> view_string
  let assert [before_assistant, ..] = string.split(html, "turn assistant")
  should_contain(before_assistant, "<details class=\"turn reasoning\">")
  // One label in both states: the committed chip says "thinking" too
  // (F8) — the chevrons around it are the summary marker and Pico's
  // details::after, never authored text.
  should_contain(before_assistant, "reasoning-label\">thinking</summary>")
}

pub fn reasoning_commits_before_tool_call_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("need a tool"))
    |> step(ui.ToolCallAssembled("call_1", "echo", "{}", None))
  model.log
  |> should.equal([
    ui.ToolLine("call_1", "echo", "{}", ui.ToolRunning, None),
    ui.ReasoningLine("need a tool"),
    ui.UserLine("hi", None, None),
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
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("reached for a tool"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("echo"), "{\"x\""))
    |> step(ui.TurnStopped(None))
  model.thinking |> should.equal(None)
  model.log |> should.equal([ui.UserLine("hi", None, None)])
}

pub fn tool_call_fragment_with_text_commits_reasoning_test() {
  // Text ahead of the fragments commits both immediately: a stop then
  // commits text + reasoning server-side, exactly like this display.
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("reached for a tool"))
    |> step(ui.Token("partial"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("echo"), "{\"x\""))
    |> step(ui.TurnStopped(None))
  model.log
  |> log_shapes
  |> should.equal([
    ui.AssistantLine("partial", None),
    ui.ReasoningLine("reached for a tool"),
    ui.UserLine("hi", None, None),
  ])
  model.thinking |> should.equal(None)
}

pub fn replayed_reasoning_renders_collapsed_test() {
  let model =
    new_model()
    |> step(ui.ReasoningFull("the chain of thought"))
    |> step(ui.AssistantFull("the answer", None))
  let html = model |> view_string
  should_contain(html, "turn reasoning\"")
  should_not_contain(html, "thinking…")
  should_contain(html, "the chain of thought")
  // Collapsed in the markup itself: a live block carries a bare `open`
  // attribute, a replayed one must carry none at all.
  should_not_contain(html, "<details open")
  should_not_contain(html, "reasoning\" open")
}

pub fn view_groups_consecutive_chips_into_one_row_test() {
  // Collapsed chips flow like spans, not stacked blocks: committed
  // reasoning + tool cards share one .chip-row, and an assistant turn
  // ends the run. Each chip keeps its exact card markup inside the row —
  // the compaction is the wrapper + CSS, not the chip itself.
  let model =
    new_model()
    |> step(ui.ReasoningFull("the chain"))
    |> step(ui.ToolCallAssembled("call_1", "web_search", "{}", None))
    |> step(ui.ToolResult("call_1", "web_search", True, "[]"))
    |> step(ui.AssistantFull("done", None))
  let html = model |> view_string
  // The row opens with the reasoning chip and the tool chip is its
  // sibling inside it — no </div> between the two chips.
  should_contain(
    html,
    "<div class=\"chip-row\"><details class=\"turn reasoning\">",
  )
  should_contain(
    html,
    "</details><button aria-label=\"web_search (completed)\" class=\"turn tool done\"",
  )
  // The assistant turn breaks the run: the row closes right before it.
  // Committed assistant turns render markdown (nexus/ui/markdown) and
  // carry the .md class that switches the bubble to block flow.
  should_contain(html, "</div><div class=\"turn assistant md\">")
}

pub fn view_keeps_live_thinking_outside_chip_rows_test() {
  // The live thinking block renders open and full-width — it must stay a
  // bare element after the committed chips' row, never folded in as a
  // collapsed chip.
  let model =
    new_model()
    |> step(ui.ReasoningFull("committed chain"))
    |> step(ui.Reasoning(" still streaming"))
  let html = model |> view_string
  should_contain(
    html,
    "<div class=\"chip-row\"><details class=\"turn reasoning\">",
  )
  // The row closes and the live block follows OUTSIDE it.
  should_contain(html, "</div><details class=\"turn reasoning live\" open>")
  should_not_contain(html, "chip-row\"><details class=\"turn reasoning live\"")
  should_contain(html, "thinking…")
}

pub fn reasoning_only_turn_discards_thinking_on_done_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("never finished"))
    |> step(ui.TurnDone(None))
  // The server committed nothing (no empty assistant messages), so the
  // display rolls the uncommitted thinking back with the turn.
  model.thinking |> should.equal(None)
  model.log |> should.equal([ui.UserLine("hi", None, None)])
}

pub fn whitespace_assistant_commit_renders_no_pill_test() {
  // The live commit path: a model streams bare newlines as its text
  // beside tool calls. The loop commits that text server-side (it is not
  // empty), but markdown renders it to nothing — an AssistantLine for it
  // would be an empty tinted pill (the "empty response bubble" glitch).
  // The reasoning it preceded still commits, exactly as the transcript
  // carries it, and no pill renders live.
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("thinking out loud"))
    |> step(ui.Token("\n\n"))
    |> step(ui.ToolCallDelta(0, Some("call_1"), Some("http_fetch"), "{}"))
  // The bubble committed (and was skipped) at the tool-call boundary.
  model.bubble |> should.equal(None)
  let model = step(model, ui.TurnDone(None))
  model.log
  |> should.equal([
    ui.ReasoningLine("thinking out loud"),
    ui.UserLine("hi", None, None),
  ])
  let html = model |> view_string
  should_contain(html, "turn reasoning")
  should_not_contain(html, "turn assistant md\"></div>")
}

pub fn whitespace_assistant_replay_renders_no_pill_test() {
  // Replay must skip the same shapes the live commit skips, so a reload
  // cannot resurrect the pill (and cannot drop a real line either).
  let model =
    new_model()
    |> step(ui.AssistantFull("\n\n", None))
    |> step(ui.AssistantFull("the real answer", None))
  model.log |> should.equal([ui.AssistantLine("the real answer", None)])
  let html = model |> view_string
  should_contain(html, "the real answer")
  should_not_contain(html, "turn assistant md\"></div>")
}

pub fn live_bubble_waits_for_visible_text_test() {
  // The streaming bubble stays hidden while its text renders to nothing,
  // decided by the SAME rule the commit path applies (see
  // live_bubble_follows_the_commit_render_rule_test for the
  // whitespace-vs-render distinction).
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Token("  \n"))
  model.bubble_hidden |> should.equal(True)
  let html = model |> view_string
  should_not_contain(html, "turn assistant")
  let model = step(model, ui.Token("Hello"))
  model.bubble_hidden |> should.equal(False)
  let html = model |> view_string
  should_contain(html, "turn assistant")
  should_contain(html, "Hello")
}

pub fn live_bubble_follows_the_commit_render_rule_test() {
  // The live bubble's visibility uses the SAME render-empty decision as
  // the commit and replay paths — not a whitespace approximation. A lone
  // footnote definition is trim-NONEMPTY but renders to nothing, so it
  // must stay hidden live (a whitespace check would show it, then the
  // commit would drop it — the exact live/replay divergence this fix
  // closes). Once visible, the decision never flips back: the bubble
  // only grows, and a text that already renders blocks keeps them.
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Token("[^1]: note"))
  model.bubble_hidden |> should.equal(True)
  let html = model |> view_string
  should_not_contain(html, "turn assistant")
  let model = step(model, ui.Token("\n\nanswer body"))
  model.bubble_hidden |> should.equal(False)
  let html = model |> view_string
  should_contain(html, "turn assistant")
  // And the commit path drops the same shapes on the replay side.
  let model = step(model, ui.TurnDone(None))
  model.log
  |> log_shapes
  |> should.equal([
    ui.AssistantLine("[^1]: note\n\nanswer body", None),
    ui.UserLine("hi", None, None),
  ])
}

pub fn failed_turn_rolls_back_reasoning_test() {
  let model =
    new_model()
    |> step(ui.UserEcho("hi", None, None))
    |> step(ui.Reasoning("doomed"))
    |> step(ui.Token("partial"))
    |> step(ui.TurnFailed("non-200", None))
  model.log
  |> should.equal([
    ui.NoteLine(True, "turn failed: non-200"),
    ui.UserLine("hi", None, None),
  ])
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

pub fn from_thread_event_maps_reasoning_test() {
  ui.from_thread_event(thread.Reasoning("bit"))
  |> should.equal(ui.Reasoning("bit"))
  ui.from_thread_event(thread.ReasoningFull("whole"))
  |> should.equal(ui.ReasoningFull("whole"))
}

// ---------------------------------------------------------------------------
// Utility-titles P3 (§6): MetaUpdated → sidebar refresh, hostile title inert
// ---------------------------------------------------------------------------

/// A model-generated title is hostile model output: it renders as a
/// Lustre TEXT node in the sidebar row — escaped, never markup.
pub fn view_escapes_hostile_title_test() {
  let hostile =
    thread.ThreadSummary(
      ..summary("s-1", False),
      title: "<script>alert(1)</script>",
    )
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([hostile]))
    |> view_string
  should_contain(html, "&lt;script&gt;")
  should_not_contain(html, "<script>alert")
  // The payload reaches the DOM as inert data — the full escaped text.
  should_contain(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
}

/// A model-generated TAG is hostile model output too (utility-tags
/// plan §5): chips render it as a Lustre TEXT node — escaped, inert,
/// never markup — in both the button label and its `title` attribute.
/// The `MetaUpdated` payload itself never reaches the DOM at all: the
/// refresh re-reads the registry, so the summary's tags are what render.
pub fn view_escapes_hostile_model_tags_in_chips_test() {
  let hostile =
    thread.ThreadSummary(..summary("s-1", False), title: "ok title", tags: [
      "<script>alert(1)</script>",
      "work",
    ])
  let html =
    new_model()
    |> step(ui.ThreadsLoaded([hostile]))
    |> step(
      ui.MetaUpdated(Some("<b>ignored</b>"), ["<script>payload</script>"]),
    )
    |> view_string
  // The chip payload reaches the DOM as inert data — the full escaped
  // text, in the label and the escaped `title` attribute both.
  should_contain(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  should_contain(html, "Filter by &lt;script&gt;")
  should_not_contain(html, "<script>alert")
  // The MetaUpdated event's own payload never renders anywhere.
  should_not_contain(html, "ignored")
  should_not_contain(html, "payload")
  // A benign chip renders beside the hostile one, unharmed.
  should_contain(html, "Filter by work")
}

/// `MetaUpdated` nudges the sidebar through the SAME threads_effect a
/// `TurnDone` uses — asserted against a REAL Lustre server-component
/// runtime over REAL (offline) registries: after the nudge, a reconcile
/// carrying the registry's CURRENT title reaches the socket. The event's
/// own payload is deliberately NOT the real title — the refresh must
/// re-read the registry, never trust the broadcast.
pub fn meta_updated_refreshes_sidebar_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  // Real registries over the offline seams — the refresh effect calls
  // both, so a dead subject would crash the runtime's actor.
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry"),
      seam,
      toolset(unused_turn_runner),
      // The corpus seam: never asked here (the fake runner refuses), pure
      // so the boot stays offline.
      fn() { [] },
      fixture_resolver(),
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  // A titled thread, so the sidebar has something to refresh.
  let assert Ok(record) =
    thread_registry.create_with_toolset(
      registry,
      new_thread(store_mock.fixture_provider_id, "alias-1"),
      toolset(unused_turn_runner),
    )
  should.be_true(thread_registry.auto_title(registry, record.id, "Before"))

  // One per-connection runtime, started exactly like the /ws socket
  // handler does, with a test-owned client subject as the socket.
  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: None,
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // The sidebar first renders the current title (init's effects landed).
  let _ = wait_for_patch(client, "Before", 40)

  // The title changes server-side, BEHIND this client's back.
  should.be_true(thread_registry.set_title(registry, record.id, "After"))

  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.MetaUpdated(Some("EVENT-PAYLOAD"), [])),
  )

  // A reconcile carrying the re-read title reaches the socket — and the
  // event's payload never does.
  let seen = wait_for_patch(client, "After", 40)
  should.be_false(string.contains(seen, "EVENT-PAYLOAD"))
}

/// A send into a previous-day conversation must move its sidebar row up
/// to Today the MOMENT the message lands — not when the reply finishes.
/// The thread bumps its activity at the send itself (the user message
/// commits on append, even if the turn later fails), and the send path
/// refreshes the sidebar from the registry, so the row re-buckets while
/// the turn is still running. Pinned over a REAL runtime and registries:
/// the turn's runner parks until long after the test ends, so no
/// TurnDone refresh can produce the observed signal — with the refresh
/// gone from the send path, the row sits under Yesterday until the
/// (never-arriving) reply.
pub fn send_moves_previous_day_row_into_today_immediately_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  // Seed the previous-day conversation through the store seam: the row
  // first, then one committed user message — so the send below is NOT
  // the first message (the auto-title branch always refreshed; this pins
  // the path that did not) — then age the row back to yesterday (Commit
  // stamps recency with the wall clock). Exactly 86_400, never more: the
  // bucket is calendar-day arithmetic (day_index = epoch / 86_400), so a
  // longer offset crosses a second UTC day boundary whenever the test
  // runs within that excess after midnight UTC — 86_400 lands exactly one
  // boundary back at any wall-clock time and still renders "1d".
  let yesterday = timing.wall_now_s() - 86_400
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        id: "s-old",
        provider_id: store_mock.fixture_provider_id,
        model: "alias-1",
        meta: thread.ThreadMeta(
          title: "Resumed chat",
          title_source: thread.ManualTitle,
          pinned: False,
          archived: False,
          tags: [],
          tags_manual: [],
          tags_source: thread.AutoTags,
          bot_id: None,
          parent_thread_id: None,
          created_at: yesterday,
        ),
        toolset: thread_registry.plain_entries(
          tools.default_names(test_config()),
        ),
        workspace_root: None,
        workspaces: None,
        roster: None,
        last_active_at: yesterday,
        message_count: 1,
      ),
      "test system prompt",
    )
  seam.commit(
    "s-old",
    transcript.new("alias-1", "test system prompt")
      |> transcript.append_user("yesterday's question"),
  )
  store_mock.set_last_active(mock, "s-old", yesterday)

  // Real registries over the offline seams — the refresh effect calls
  // both, so a dead subject would crash the runtime's actor. The turn
  // runner parks on its cancel subject: the reply never finishes here.
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers_row"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory_row")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry_row"),
      seam,
      toolset(parked_runner),
      // The corpus seam: never asked here (the fake runner refuses), pure
      // so the boot stays offline.
      fn() { [] },
      fixture_resolver(),
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  // A today thread, so the Today bucket exists before the send: the old
  // row must move INTO it, jumping above it by recency.
  let assert Ok(_today) =
    thread_registry.create(
      registry,
      new_thread(store_mock.fixture_provider_id, "alias-1"),
    )

  // The connection re-opens the previous-day thread (the /ws route's
  // persisted selection).
  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: Some("s-old"),
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // The connect cascade settles with the old row under Yesterday — its
  // subtitle age reads "1d". #107 made the bare age the whole bot-less
  // subtitle, so the middot is gone, and the log's age stamp ("1d ago",
  // inside a <time>) makes plain "1d" ambiguous — these payloads are
  // Lustre element JSON, not HTML, so the anchor pins the age to its
  // span by the encoder's shape: a text node reading exactly "1d" as the
  // sole child of a span whose first attribute is class thread-sub. No
  // other node pairs that text with that class.
  let before = collect_until_quiet(client, 10, 10, "")
  should.be_true(string.contains(before, "Yesterday"))
  should.be_true(string.contains(
    before,
    "\"1d\",\"kind\":2}],\"attributes\":[{\"value\":\"thread-sub\"",
  ))

  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.SendRequested("hello again")),
  )

  // While the reply is still parked, the row re-buckets into Today: its
  // subtitle age flips to "just now" — written by nothing but the
  // send-time refresh (the user echo proves the cascade itself flowed).
  // Same adjacency anchor as `before`: the log's stamp for the new
  // message also reads "just now" (inside a <time>), so bare text can't
  // carry the claim. The created today-thread's subtitle shares the
  // text — so did the old middot anchor.
  let after = collect_until_quiet(client, 10, 10, "")
  should.be_true(string.contains(after, "hello again"))
  // The today row's subtitle flipped to just-now — bot-sourced threads
  // lead with the provenance name, so the whole subtitle text anchors.
  should.be_true(string.contains(
    after,
    "Fixture · just now\",\"kind\":2}],\"attributes\":[{\"value\":\"thread-sub\"",
  ))
}

/// Regression (bogus "no provider configured" note): the connect-time
/// alias effect used to dispatch `NoProviders` whenever the model had no
/// *selected* provider — always true before the first provider load
/// lands — so EVERY fresh connection logged "no provider configured —
/// add one in Settings" even with a provider configured, and nothing
/// ever removed the line. The note must fire only when a provider LOAD
/// concludes no enabled provider exists. Asserted against a REAL
/// per-connection runtime over REAL (offline) registries, so the whole
/// connect cascade runs: the create panel must offer the fixture
/// provider, and the note must never reach the client.
pub fn connect_with_configured_provider_never_notes_no_provider_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry"),
      seam,
      toolset(unused_turn_runner),
      // The corpus seam: never asked here (the fake runner refuses), pure
      // so the boot stays offline.
      fn() { [] },
      fixture_resolver(),
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  // One per-connection runtime, started exactly like the /ws socket
  // handler does: the connect-time effect batch runs for real against
  // the registries above.
  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: None,
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // The whole connect cascade (provider load, thread load) settles
  // before anything is asserted. The provider's masked metadata is
  // rendered by the SETTINGS page only, so the view flip proves
  // `ProvidersLoaded` landed: open Settings, collect again, and the
  // fixture row in the SAME stream is the verdict anchor — the note's
  // absence across the whole stream is a verdict, not a stall.
  lustre.send(to: runtime, message: lustre.dispatch(ui.SettingsToggled))
  let seen = collect_until_quiet(client, 10, 10, "")

  // The configured provider is offered (its row + the keyless badge;
  // patches are element JSON, so plain substrings are the anchors)…
  should.be_true(string.contains(seen, "fixture"))
  should.be_true(string.contains(seen, "keyless"))
  // …and the bogus note never reached the client.
  should.be_false(string.contains(seen, "no provider configured"))
}

fn unused_turn_runner(
  _endpoint,
  _tr,
  _cancel,
  _delivery,
  _environment,
  _on_event,
) -> thread.TurnOutcome {
  thread.StreamErrored("no turn expected in this test")
}

/// Parks on the thread's cancel subject until long after any test ends —
/// the stand-in for a reply that is still streaming. Whatever a test
/// observes while a turn runs this runner cannot have come from the
/// turn's own commit.
fn parked_runner(
  _endpoint,
  tr,
  cancel,
  _delivery,
  _environment,
  _on_event,
) -> thread.TurnOutcome {
  let selector =
    process.new_selector()
    |> process.select_map(cancel, fn(_) { Nil })
  let _ = process.selector_receive(selector, 60_000)
  thread.StreamStopped(tr)
}

/// Emits one distinctive token delta then completes. The stream the
/// thread-switch regression test must prove never reaches the client
/// after the client switched away from its thread.
fn leak_runner(
  _endpoint,
  tr,
  _cancel,
  _delivery,
  _environment,
  on_event: fn(loop.LoopEvent) -> Nil,
) -> thread.TurnOutcome {
  on_event(loop.StreamEvent(openai.TokenDelta("LEAK-TOKEN")))
  thread.StreamDone(
    stream_stats(),
    transcript.append_assistant(tr, "LEAK-TOKEN"),
  )
}

fn stream_stats() -> openai.StreamStats {
  openai.StreamStats(
    ttft_ms: Some(12),
    duration_ms: 345,
    token_deltas: 1,
    reasoning_deltas: 0,
    tool_call_deltas: 0,
    events_parsed: 3,
    decode_errors: 0,
    saw_done: True,
    usage: None,
  )
}

/// Poll until the thread's turn is over, so a "never reached the client"
/// assertion is a verdict on the whole turn rather than a race.
fn wait_until_idle(subject: process.Subject(thread.Msg), attempts: Int) -> Nil {
  case thread.describe(subject).streaming {
    False -> Nil
    True if attempts <= 0 -> Nil
    True -> {
      process.sleep(50)
      wait_until_idle(subject, attempts - 1)
    }
  }
}

/// Regression (cross-thread stream contamination): the component keeps
/// ONE thread-event subject per connection, and a thread switch used to
/// Join that subject to the new thread WITHOUT detaching it from the old
/// one — so a turn streamed into the old thread kept fanning out to the
/// shared subject and rendered its tokens into the new thread's view.
/// Asserted against a REAL per-connection runtime over REAL (offline)
/// registries: switch A -> B, then stream a whole turn into A and prove
/// nothing of it reaches the client.
pub fn thread_switch_drops_left_thread_stream_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers_leak"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory_leak")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry_leak"),
      seam,
      toolset(leak_runner),
      fn() { [] },
      fixture_resolver(),
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  let assert Ok(a) =
    thread_registry.create(
      registry,
      new_thread(store_mock.fixture_provider_id, "smart"),
    )
  let assert Ok(b) =
    thread_registry.create(
      registry,
      new_thread(store_mock.fixture_provider_id, "smart"),
    )

  // The connection boots bound to thread A (the /ws route's persisted
  // selection), exactly like a reload into a streaming thread.
  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: Some(a.id),
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // Let the connect cascade (join A + loads) settle.
  let _ = collect_until_quiet(client, 4, 4, "")

  // Switch to B: the Leave detaches the subject from A (fan-out hygiene);
  // the per-event id filter carries the correctness half.
  lustre.send(to: runtime, message: lustre.dispatch(ui.Select(b.id)))
  let _ = collect_until_quiet(client, 4, 4, "")

  // Stream a whole turn into A — the thread the client just left.
  let assert Ok(subject_a) = thread_registry.get(registry, a.id)
  should.equal(thread.send_message(subject_a, "leak"), thread.Sent)
  wait_until_idle(subject_a, 40)

  // Nothing of A's stream reaches the client: with the bug, A's UserEcho
  // and Token events rendered straight into B's view.
  let seen = collect_until_quiet(client, 10, 10, "")
  should.be_false(string.contains(seen, "leak"))
  should.be_false(string.contains(seen, "LEAK-TOKEN"))
}

/// The `MetaUpdated` pass-through, end to end. A delivery from a foreign
/// thread (id AND generation foreign to the current visit) must reach
/// the update and trigger the sidebar refresh. The refresh is observable
/// because the registry's truth changed WITHOUT any broadcast first — a
/// registry rename fans nothing out (the acting client refreshes via its
/// own reply path) — so the only way "FRESH-TITLE" can reach the client
/// is the foreign delivery's refresh. The event's own decoy title must
/// never appear: the arm re-fetches truth, it does not trust payloads.
pub fn meta_updated_from_other_thread_refreshes_sidebar_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers_meta"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory_meta")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry_meta"),
      seam,
      toolset(unused_turn_runner),
      fn() { [] },
      fixture_resolver(),
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  let assert Ok(a) =
    thread_registry.create(
      registry,
      new_thread(store_mock.fixture_provider_id, "smart"),
    )

  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: Some(a.id),
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // Let the connect cascade settle, then change the sidebar's truth
  // silently: no refresh has run, so the client still shows the old view.
  let _ = collect_until_quiet(client, 4, 4, "")
  should.be_true(thread_registry.set_title(registry, a.id, "FRESH-TITLE"))

  // A foreign thread's MetaUpdated passes the filter and triggers the
  // refresh that carries the new truth to the client.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.ThreadScoped(
      "s-other",
      999,
      ui.MetaUpdated(Some("HACKED"), []),
    )),
  )
  let seen = wait_for_patch(client, "FRESH-TITLE", 40)
  should.be_true(string.contains(seen, "FRESH-TITLE"))

  // The foreign payload's own title is decoy data — never rendered.
  let rest = collect_until_quiet(client, 5, 5, "")
  should.be_false(string.contains(seen <> rest, "HACKED"))
}

/// The offline stand-in for the boot resolver (same as the golden suite).
fn fixture_resolver() -> thread_registry.ResolveProvider {
  fn(id) {
    case id == store_mock.fixture_provider_id {
      True ->
        Ok(openai.Endpoint(
          base_url: "https://provider.example/v1",
          api_key: None,
          sse_first_response_timeout_ms: 1000,
          stream_idle_timeout_ms: 1000,
        ))
      False -> Error(thread_registry.ProviderUnknown)
    }
  }
}

/// The common creation request shape: a bot-sourced pin (every thread is
/// bot-sourced now — the id is provenance only here), config-default
/// prompt.
fn new_thread(provider_id: String, model: String) -> thread_registry.NewThread {
  thread_registry.NewThread(
    provider_id: provider_id,
    model: model,
    system_prompt: None,
    toolset: None,
    bot_id: "b-fixture",
    parent_thread_id: None,
    title: "",
  )
}

/// Config for the real registries: valid key material (the provider
/// registry decrypt-validates at boot), otherwise test defaults.
/// Wrap a fake turn runner in the toolset bundle the registry seams now
/// carry (#76): the default specs of the test config, named by their own
/// wire names. The utility side refuses — these tests drive turns through
/// the turn runner only.
fn toolset(runner: thread.TurnRunner) -> thread.Toolset {
  let specs = tools.default(test_config())
  thread.Toolset(
    names: list.map(specs, tools.tool_name),
    specs: specs,
    runner: runner,
    utility_runner: fn(_endpoint, _tr, _cancel, _allow_pass) {
      Error("no utility call in this test")
    },
  )
}

fn test_config() -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 8080,
    ui_token: None,
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_cache_ttl_ms: 600_000,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
    utility_enabled: True,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    workspace_sandbox: config.SandboxNone,
    workspace_sandbox_bin: None,
    workspace_toolchain: None,
    workspace_state_dir: None,
    workspace_max_memory_mb: 1024,
    workspace_max_pids: 64,
    env_timeout_ms: 60_000,
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    // Bots P3c: the delivery hop guard; 4 = the shipped default.
    max_bot_hops: 4,
  )
}

/// Receive client messages until `limit` consecutive 200 ms quiet
/// intervals pass with no traffic, returning the concatenated JSON —
/// for NEGATIVE assertions ("this string never reaches the client"):
/// unlike `wait_for_patch`, which stops at the first match, this keeps
/// every patch so an assertion can rule a string out across the whole
/// stream. Every received patch RESETS the quiet budget to `limit`:
/// quiet gaps between a cascade's patches must not erode the budget,
/// or collection could stop while the cascade is still producing.
fn collect_until_quiet(
  client: process.Subject(server_component.ClientMessage(ui.Msg)),
  limit: Int,
  remaining: Int,
  acc: String,
) -> String {
  case process.receive(client, 200) {
    Error(_) ->
      case remaining {
        0 -> acc
        _ -> collect_until_quiet(client, limit, remaining - 1, acc)
      }
    Ok(message) -> {
      let text =
        server_component.client_message_to_json(message)
        |> json.to_string
      collect_until_quiet(client, limit, limit, acc <> text)
    }
  }
}

/// Receive client messages until one carries `needle`, returning its JSON.
/// A quiet 200 ms interval retries — renders land asynchronously — and
/// only `attempts` exhausted quiet intervals is the failure under test.
fn wait_for_patch(
  client: process.Subject(server_component.ClientMessage(ui.Msg)),
  needle: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as { "patch never arrived: " <> needle }
    _ ->
      case process.receive(client, 200) {
        Error(_) -> wait_for_patch(client, needle, attempts - 1)
        Ok(message) -> {
          let text =
            server_component.client_message_to_json(message)
            |> json.to_string
          case string.contains(text, needle) {
            True -> text
            False -> wait_for_patch(client, needle, attempts - 1)
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Bots plan P1: settings Bots section, start-from-bot picker, provenance
// ---------------------------------------------------------------------------

fn bot_row(
  id: String,
  name: String,
  description: String,
  prompt: option.Option(String),
) -> bot.Bot {
  bot.Bot(
    id: id,
    name: name,
    description: description,
    provider_id: "p1",
    model: "smart",
    system_prompt: prompt,
    tools: None,
    allow_inbound: True,
    created_at: 0,
    updated_at: 0,
  )
}

/// Same row shape with an explicit toolset (bots plan P2's display).
fn bot_row_with_tools(
  id: String,
  name: String,
  description: String,
  prompt: option.Option(String),
  tools: option.Option(List(String)),
) -> bot.Bot {
  bot.Bot(..bot_row(id, name, description, prompt), tools: tools)
}

/// Same row shape with the inbound gate set (bots plan P3a's display).
fn bot_row_inbound(
  id: String,
  name: String,
  description: String,
  prompt: option.Option(String),
  allow_inbound: Bool,
) -> bot.Bot {
  bot.Bot(
    ..bot_row(id, name, description, prompt),
    allow_inbound: allow_inbound,
  )
}

/// The Bots section renders beside Providers, mirroring the provider
/// rows — and everything bot-fed is HOSTILE TEXT: names, descriptions,
/// and prompt previews escape as Lustre text nodes, never innerHTML.
pub fn view_settings_bots_section_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([
        bot_row(
          "b1",
          "<script>alert(1)</script>",
          "desc with \"quotes\"",
          Some("prompt <b>bold</b>"),
        ),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> view_string
  should.be_true(string.contains(html, ">Bots<"))
  should.be_true(string.contains(html, "bot-row"))
  // The hostile name and prompt preview are ESCAPED text nodes.
  should.be_true(string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;"))
  should.be_true(string.contains(html, "prompt &lt;b&gt;bold&lt;/b&gt;"))
  should_not_contain(html, "<script>alert(1)</script>")
  // The add form is present-but-hidden until opened; the edit form
  // carries the stored values.
  should.be_true(string.contains(html, "add-bot-form"))
  should.be_true(string.contains(html, ">Add bot<"))
  let editing =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.BotsLoaded([bot_row("b1", "Writer", "", Some("be terse"))]))
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.BotEditToggled("b1", "p1", None)))
    |> view_string
  should.be_true(string.contains(editing, ">Edit bot<"))
  should.be_true(string.contains(editing, "value=\"Writer\""))
  should.be_true(string.contains(editing, "be terse"))
}

/// The inbound gate toggle's two shapes (bots plan P3a's display): the
/// open gate renders the "Block" affordance, the closed one the "Allow"
/// affordance plus the "inbound off" badge, and the hostile name still
/// escapes as text.
pub fn view_settings_bots_inbound_toggle_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([
        bot_row("b1", "<script>alert(3)</script>", "", None),
        bot_row_inbound("b2", "quiet", "", None, False),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> view_string
  // Both toggle shapes are in the list, one per row.
  should.be_true(string.contains(html, ">Block inbound<"))
  should.be_true(string.contains(html, ">Allow inbound<"))
  // The blocked gate's badge, mirroring the provider row's "off".
  should.be_true(string.contains(html, "inbound off"))
  // The hostile name is escaped text, never markup.
  should.be_true(string.contains(html, "&lt;script&gt;alert(3)&lt;/script&gt;"))
  should_not_contain(html, "<script>alert(3)</script>")
}

/// The toolset display (bots plan P2): the three states read distinctly
/// — default, chat-only, explicit list — and a payload-laden "tool name"
/// (reachable only through an unvalidated store seed, exactly the
/// hostile-text threat model) escapes as inert text.
pub fn view_settings_bots_tools_display_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([
        bot_row("b1", "default tools bot", "", None),
        bot_row_with_tools("b2", "chat only bot", "", None, Some([])),
        bot_row_with_tools(
          "b3",
          "tooled bot",
          "",
          None,
          Some([
            "http_fetch",
            "codemode",
          ]),
        ),
        bot_row_with_tools(
          "b4",
          "hostile tools bot",
          "",
          None,
          Some([
            "<script>alert(2)</script>",
          ]),
        ),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> view_string
  should.be_true(string.contains(html, "default tools"))
  should.be_true(string.contains(html, "no tools (chat only)"))
  should.be_true(string.contains(html, "tools: http_fetch, codemode"))
  // The hostile "name" is escaped text, never markup.
  should.be_true(string.contains(html, "&lt;script&gt;alert(2)&lt;/script&gt;"))
  should_not_contain(html, "<script>alert(2)</script>")

  // The edit form prefills the comma-separated field and checks the
  // chat-only box for an empty set.
  let editing =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([
        bot_row_with_tools(
          "b3",
          "tooled",
          "",
          None,
          Some([
            "http_fetch",
          ]),
        ),
      ]),
    )
    |> step(ui.SettingsToggled)
    |> step(
      ui.Settings(ui_settings.BotEditToggled("b3", "p1", Some(["http_fetch"]))),
    )
    |> view_string
  // The picker seeds the stored toolset: http_fetch renders as a
  // ticked box (the catalog has not landed in this offline view, so
  // the seeded ticks render alone over the loading note).
  should.be_true(string.contains(editing, "type=\"checkbox\""))
  should.be_true(string.contains(editing, "checked"))
  should.be_true(string.contains(editing, ">http_fetch<"))

  // Chat-only (Some([])) now seeds the Custom switch ON over an empty
  // grid — the retired chat-only checkbox is gone from the form.
  let editing_chat_only =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([bot_row_with_tools("b2", "quiet", "", None, Some([]))]),
    )
    |> step(ui.SettingsToggled)
    |> step(ui.Settings(ui_settings.BotEditToggled("b2", "p1", Some([]))))
    |> view_string
  should.be_true(string.contains(editing_chat_only, ">Custom tools<"))
  should.be_true(string.contains(editing_chat_only, "checked"))
  should_not_contain(editing_chat_only, "Chat only (no tools)")
}

/// The tool picker (issue #121): the settled catalog renders as
/// checkboxes under All/None toggles; ticks seed from the edited bot
/// and flip per box; All/None set/clear the whole selection; a kept
/// unknown name renders as a ticked "(not in catalog)" box with
/// hostile names as inert text; a failed fetch degrades to the
/// free-text field.
pub fn view_settings_bots_tool_picker_test() {
  let catalog =
    bot_registry.ToolCatalog(
      ["bot_message", "codemode", "http_fetch", "web_search"],
      [],
    )
  let base =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.BotsLoaded([
        bot_row_with_tools("b1", "tooled", "", None, Some(["http_fetch"])),
        bot_row_with_tools(
          "b2",
          "stale",
          "",
          None,
          Some(["http_fetch", "<script>alert(2)</script>"]),
        ),
      ]),
    )
    |> step(ui.SettingsToggled)
  let open_b1 =
    ui.Settings(ui_settings.BotEditToggled("b1", "p1", Some(["http_fetch"])))

  // The settled picker: four catalog boxes, the Custom switch (ON —
  // the edit seeded an explicit set), All/None controls, the seeded
  // tick the only ticked box.
  let settled =
    base
    |> step(open_b1)
    |> step(ui.Settings(ui_settings.BotToolsLoaded(catalog)))
    |> view_string
  should.be_true(string.contains(settled, ">Tools<"))
  should.be_true(string.contains(settled, ">All<"))
  should.be_true(string.contains(settled, ">None<"))
  should.be_true(string.contains(settled, ">bot_message<"))
  should.be_true(string.contains(settled, ">web_search<"))
  // The picker renders once per form instance — the add form plus each
  // row's hidden editor, three with two bots — all reflecting the ONE
  // shared picker state, so counts are ×3 (the ON switch + the ticked
  // http_fetch each render a `checked` attribute).
  should.equal(count_occurrences(settled, "checked"), 6)

  // All ticks everything, None clears back to the default-set state,
  // a single flip re-ticks one box.
  let all =
    base
    |> step(open_b1)
    |> step(ui.Settings(ui_settings.BotToolsLoaded(catalog)))
    |> step(ui.Settings(ui_settings.BotToolsAll))
    |> view_string
  should.equal(count_occurrences(all, "checked"), 15)

  let none_then_one =
    base
    |> step(open_b1)
    |> step(ui.Settings(ui_settings.BotToolsLoaded(catalog)))
    |> step(ui.Settings(ui_settings.BotToolsNone))
    |> step(ui.Settings(ui_settings.BotToolToggled("web_search")))
    |> view_string
  should.equal(count_occurrences(none_then_one, "checked"), 6)
  should.be_true(string.contains(none_then_one, ">web_search<"))

  // A kept stored-but-unknown name renders as a ticked "(not in
  // catalog)" box beside the catalog boxes; a hostile "name" is
  // escaped text, never markup.
  let stale =
    base
    |> step(
      ui.Settings(ui_settings.BotEditToggled(
        "b2",
        "p1",
        Some(["http_fetch", "<script>alert(2)</script>"]),
      )),
    )
    |> step(ui.Settings(ui_settings.BotToolsLoaded(catalog)))
    |> view_string
  should.equal(count_occurrences(stale, "checked"), 9)
  should.be_true(string.contains(stale, "(not in catalog)"))
  should.be_true(string.contains(stale, "&lt;script&gt;alert(2)&lt;/script&gt;"))
  should_not_contain(stale, "<script>alert(2)</script>")

  // Flipping the Custom switch OFF folds the grid: no boxes, no
  // All/None, just the default-set promise; the switch itself unticks.
  let folded =
    base
    |> step(open_b1)
    |> step(ui.Settings(ui_settings.BotToolsLoaded(catalog)))
    |> step(ui.Settings(ui_settings.BotToolsCustomToggled))
    |> view_string
  should.be_true(string.contains(folded, ">Custom tools<"))
  should.be_true(string.contains(
    folded,
    "default: every built-in tool that works in this deployment",
  ))
  should_not_contain(folded, ">All<")
  should_not_contain(folded, ">http_fetch<")
  should.equal(count_occurrences(folded, "checked"), 0)

  // A failed fetch degrades to the free-text field (the combobox's
  // graceful-degradation rule), prefilled with the stored list.
  let degraded =
    base
    |> step(open_b1)
    |> step(ui.Settings(ui_settings.BotToolsFetchFailed))
    |> view_string
  should.be_true(string.contains(
    degraded,
    "tool list unavailable — enter names, comma-separated",
  ))
  should.be_true(string.contains(degraded, "value=\"http_fetch\""))
}

/// Occurrences of `needle` in `haystack` — the picker assertions count
/// `checked` attributes (lustre omits the false-boolean entirely, so
/// the count is exactly the ticked boxes).
fn count_occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

/// The picker's submit channel (issue #121, toggle edition), pinned
/// end-to-end over a REAL runtime and a REAL bot registry: flipping
/// the Custom switch ON unfolds the fetched catalog, ticking two boxes
/// and submitting creates a bot whose stored toolset is the TICKS in
/// catalog order; the switch ON with nothing ticked saves chat-only
/// (Some([])); the switch OFF saves the default set (None) regardless
/// of any stale ticks. The degraded free-text channel is the view
/// test's concern — this pins the three switch states landing in the
/// store.
pub fn bot_picker_submit_roundtrip_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)

  // Real registries over the offline seams — the add form's open
  // effect asks both (the alias fetch fails offline; the catalog
  // fetch settles from the canned closure).
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_providers"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let bots_name = process.new_name("nexus_ui_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog(
        ["bot_message", "codemode", "http_fetch", "web_search"],
        [],
      )
    })
  let bots = started_bots.data
  let providers = started_providers.data
  let factory_name = process.new_name("nexus_ui_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_registry"),
      seam,
      toolset(unused_turn_runner),
      fn() { [] },
      fixture_resolver(),
      bots_name,
      dict.new(),
      dict.new(),
    )
  let registry = started_registry.data

  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: None,
        store: seam,
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  // Open the settings page, then the add form: the catalog fetch
  // settles from the canned closure and the picker renders the four
  // names.
  lustre.send(to: runtime, message: lustre.dispatch(ui.SettingsToggled))
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(
        ui_settings.BotAddToggled(Some(store_mock.fixture_provider_id)),
      ),
    ),
  )
  // OFF only the switch renders, so flip the Custom switch ON before
  // waiting for the unfolded picker.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.Settings(ui_settings.BotToolsCustomToggled)),
  )
  let _ = wait_for_patch(client, "bot_message", 40)

  // Tick http_fetch + codemode and submit — the stored toolset is the
  // ticks in CATALOG order (the envelope order of the resolved
  // schemas), not tick order.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotToolToggled("http_fetch")),
    ),
  )
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotToolToggled("codemode")),
    ),
  )
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotSubmitted(
        "Picker A",
        "",
        store_mock.fixture_provider_id,
        "smart",
        "",
        "",
      )),
    ),
  )

  // B: the switch still ON — None clears every tick, and saving with
  // nothing ticked is chat-only, Some([]).
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotToolToggled("web_search")),
    ),
  )
  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.Settings(ui_settings.BotToolsNone)),
  )
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotSubmitted(
        "Picker B",
        "",
        store_mock.fixture_provider_id,
        "smart",
        "",
        "",
      )),
    ),
  )
  // C: the switch flips OFF — the default set, regardless of any ticks
  // the folded picker still holds.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.Settings(ui_settings.BotToolsCustomToggled)),
  )
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotSubmitted(
        "Picker C",
        "",
        store_mock.fixture_provider_id,
        "smart",
        "",
        "",
      )),
    ),
  )

  let rows = poll_bots(bots, 40)
  let assert [a, b, c] =
    list.filter(rows, fn(b) { b.id != store_mock.fixture_bot_id })
  a.name |> should.equal("Picker A")
  a.tools |> should.equal(Some(["codemode", "http_fetch"]))
  b.tools |> should.equal(Some([]))
  c.tools |> should.equal(None)
}

/// The inbound gate toggle, end to end over the real runtime (bots plan
/// P3a, issue #95): the click patches the gate closed through the bot
/// registry, and the mutation reply's reload re-renders the blocked
/// badge with the name still escaped. The harness's fixture bot is
/// filtered out of the exact-row assertions (seeding setup, not the row
/// under test).
pub fn settings_inbound_toggle_runtime_round_trip_test() {
  let #(registry, providers, bots) =
    start_offline_registries(
      fn(seam) {
        seam.insert_bot(bot.Bot(
          id: "b1",
          name: "<script>alert(3)</script>",
          description: "",
          provider_id: store_mock.fixture_provider_id,
          model: "alias-1",
          system_prompt: None,
          tools: None,
          allow_inbound: True,
          created_at: 0,
          updated_at: 0,
        ))
      },
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let #(runtime, client) = boot_create_runtime(registry, providers, bots)

  // The connect cascade loads providers, bots, and threads.
  let _connected = collect_until_quiet(client, 10, 10, "")

  // Open the settings panel so the Bots section is in the rendered tree.
  lustre.send(to: runtime, message: lustre.dispatch(ui.SettingsToggled))
  let _panel = collect_until_quiet(client, 10, 10, "")

  // The click: patch the gate closed through the registry.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(
      ui.Settings(ui_settings.BotInboundToggled("b1", False)),
    ),
  )
  wait_for_registry_gate(bots, "b1", False, 20)
  let assert Ok(closed) = bot_registry.get_bot(bots, "b1")
  should.be_false(closed.allow_inbound)

  // The mutation reply reloads the bot list; the re-render shows the
  // blocked badge with the name still escaped.
  wait_for_patch(client, "inbound off", 20)
  let assert [stored] =
    bot_registry_rows(bots)
    |> list.filter(fn(b) { b.id != store_mock.fixture_bot_id })
  should.equal(stored.name, "<script>alert(3)</script>")
}

/// The registry's current rows (its in-state mirror post-write-through).
fn bot_registry_rows(bots: process.Subject(bot_registry.Msg)) -> List(bot.Bot) {
  let assert Ok(all) = bot_registry.list_bots(bots)
  all
}

/// Poll the registry until bot `id`'s gate reads `want` (the PATCH
/// round-trips through the actor asynchronously). Panics on timeout —
/// the caller asserts the gate off the registry read that follows.
fn wait_for_registry_gate(
  bots: process.Subject(bot_registry.Msg),
  id: String,
  want: Bool,
  attempts: Int,
) -> Nil {
  case bot_registry.get_bot(bots, id) {
    Ok(row) if row.allow_inbound == want -> Nil
    _ ->
      case attempts <= 0 {
        True -> panic as "inbound gate patch never landed"
        False -> {
          process.sleep(100)
          wait_for_registry_gate(bots, id, want, attempts - 1)
        }
      }
  }
}

/// Poll the bot registry until the THREE non-fixture bots this test's
/// UI submissions create appear (the runtime's effects cross process
/// boundaries) or the attempts run out. The count is the single
/// caller's expectation, hardcoded here.
fn poll_bots(
  bots: process.Subject(bot_registry.Msg),
  attempts: Int,
) -> List(store.StoredBot) {
  poll_bots_for(bots, 3, attempts)
}

fn poll_bots_for(
  bots: process.Subject(bot_registry.Msg),
  want: Int,
  attempts: Int,
) -> List(store.StoredBot) {
  let rows = case bot_registry.list_bots(bots) {
    Ok(rows) -> rows
    Error(_) -> []
  }
  let relevant = list.filter(rows, fn(b) { b.id != store_mock.fixture_bot_id })
  case list.length(relevant) >= want || attempts <= 0 {
    True -> relevant
    False -> {
      process.sleep(25)
      poll_bots_for(bots, want, attempts - 1)
    }
  }
}

/// Without bots the section says so; without PROVIDERS it explains the
/// dependency (there is nothing to template yet).
pub fn view_settings_bots_empty_states_test() {
  let no_bots =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.SettingsToggled)
    |> view_string
  should.be_true(string.contains(no_bots, "No bots yet."))
  let no_providers =
    new_model()
    |> step(ui.ProvidersLoaded([]))
    |> view_string
  should.be_true(string.contains(
    no_providers,
    "No providers yet — add one before creating bots.",
  ))
}

/// The composer's compose-new bot picker: rendered (above the entry
/// field) whenever no thread is selected, listing the bots with the
/// DEFAULT selection on the first one — changing your mind is a select
/// away, and the draft never moves.
pub fn view_composer_bot_picker_test() {
  // Compose-new with bots: the picker rides the composer, first bot
  // pre-selected (a send is always one Enter away).
  let with_bots =
    new_model()
    |> step(
      ui.BotsLoaded([
        bot_row("b1", "Writer", "", None),
        bot_row("b2", "Coder", "", None),
      ]),
    )
    |> view_string
  should.be_true(string.contains(with_bots, "bot-picker"))
  should.be_true(string.contains(with_bots, ">Writer<"))
  should.be_true(string.contains(with_bots, ">Coder<"))
  should.be_true(string.contains(with_bots, "selected value=\"b1\""))
  should.be_true(string.contains(with_bots, "id=\"composer-bot\""))

  // Changing the pick is a pure model write: the selection moves, the
  // composer textarea is NOT re-keyed (same key = same element = the
  // draft survives the change of mind).
  let picked =
    new_model()
    |> step(
      ui.BotsLoaded([
        bot_row("b1", "Writer", "", None),
        bot_row("b2", "Coder", "", None),
      ]),
    )
    |> step(ui.CreateBotChanged("b2"))
    |> view_string
  should.be_true(string.contains(picked, "selected value=\"b2\""))
  should.be_false(string.contains(picked, "selected value=\"b1\""))

  // With a thread selected the picker is not mounted at all (the
  // thread's bot is frozen — there is nothing to pick).
  let selected =
    new_model()
    |> step(ui.BotsLoaded([bot_row("b1", "Writer", "", None)]))
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> view_string
  should.be_false(string.contains(selected, "bot-picker"))

  // Hostile bot names are escaped in the options (hostile-text rules).
  let hostile =
    new_model()
    |> step(ui.BotsLoaded([bot_row("b1", "<i>x</i>", "", None)]))
    |> view_string
  should.be_true(string.contains(hostile, "&lt;i&gt;x&lt;/i&gt;"))
  should_not_contain(hostile, "<i>x</i>")
}

/// No bots and no thread: the composer stands down entirely (textarea
/// and Send disabled) — there is nothing to start a thread from.
pub fn view_composer_disabled_without_bots_test() {
  let html = new_model() |> view_string
  should.be_true(string.contains(html, "disabled id=\"input\""))
  should.be_true(string.contains(html, "disabled id=\"send\""))
  should.be_true(string.contains(html, "no bots yet — add one in Settings"))
}

/// A bot-sourced thread's subtitle leads with the bot's name
/// (provenance — the one identity #107 keeps). A hostile bot name is
/// escaped; a bot deleted since (unresolvable id) shows nothing, and the
/// age-only subtitle never resurrects provider/model.
pub fn view_thread_subtitle_shows_bot_provenance_test() {
  let html =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(ui.BotsLoaded([bot_row("b1", "<b>Writer</b>", "", None)]))
    |> step(
      ui.ThreadsLoaded([
        thread.ThreadSummary(..summary("s-1", False), bot_id: Some("b1")),
      ]),
    )
    |> view_string
  // Subtitle compared whole: bot name (escaped) + middot + age, nothing
  // else — provider/model has no way back in.
  should.equal(
    first_thread_sub(html),
    "&lt;b&gt;Writer&lt;/b&gt; · " <> ui.rel_time(timing.wall_now_s(), 0),
  )
  // The escaped name is what rendered: raw markup never reaches the DOM.
  should_not_contain(html, "<b>Writer</b>")

  // Deleted bot: the pointer resolves to nothing, the subtitle is
  // age-only (self-heals on rehydrate, which NULLs the column).
  let gone =
    new_model()
    |> step(ui.ProvidersLoaded([prov("p1", "bifrost", True, True)]))
    |> step(
      ui.ThreadsLoaded([
        thread.ThreadSummary(..summary("s-1", False), bot_id: Some("b-gone")),
      ]),
    )
    |> view_string
  // Deleted bot: the pointer resolves to nothing, the subtitle is
  // age-only — no `b-gone · ` echo, no provider/model rescue.
  should.equal(first_thread_sub(gone), ui.rel_time(timing.wall_now_s(), 0))
}

/// The composer picker re-aims on load (the pick_provider rule, bot
/// edition): a fresh picker falls to the FIRST bot, a selection whose
/// bot was deleted falls back to the first survivor, and an empty bot
/// list leaves nothing selected (the composer stands down).
pub fn bots_load_defaults_and_reaims_selection_test() {
  // No prior selection: the first bot.
  let fresh =
    new_model() |> step(ui.BotsLoaded([bot_row("b1", "Writer", "", None)]))
  should.equal(fresh.create_bot, Some("b1"))

  // A live selection survives a reload.
  let picked =
    fresh
    |> step(ui.CreateBotChanged("b2"))
    |> step(
      ui.BotsLoaded([
        bot_row("b1", "Writer", "", None),
        bot_row("b2", "Coder", "", None),
      ]),
    )
  should.equal(picked.create_bot, Some("b2"))

  // A deleted selection falls to the first survivor — never stuck None
  // while bots exist.
  let reloaded =
    step(picked, ui.BotsLoaded([bot_row("b1", "Writer", "", None)]))
  should.equal(reloaded.create_bot, Some("b1"))

  // Bots gone entirely: nothing selected.
  let empty = step(reloaded, ui.BotsLoaded([]))
  should.equal(empty.create_bot, None)
}

// ---------------------------------------------------------------------------
// #88: creation runs in unlinked workers behind the shared pending guard;
// the compose-new send (no selection) IS the create trigger.
// ---------------------------------------------------------------------------

/// A model ready to compose a new thread: bots loaded (the picker
/// defaults to the first), nothing selected.
fn compose_ready_model() -> ui.Model {
  new_model()
  |> step(
    ui.BotsLoaded([
      bot_row("b1", "Writer", "", None),
      bot_row("b2", "Coder", "", None),
    ]),
  )
}

/// The compose-new send latches the shared pending guard AND stashes the
/// draft; a duplicate send while the create is in flight is rejected
/// wholesale. The textarea is untouched (the composer key holds), so the
/// visible draft and the stash stay the same text.
pub fn compose_send_stashes_draft_and_guards_test() {
  let model = compose_ready_model()
  model.create_pending |> should.be_false
  model.pending_send |> should.equal(None)

  let pending = step(model, ui.SendRequested("hello there"))
  pending.create_pending |> should.be_true
  pending.pending_send |> should.equal(Some("hello there"))
  // The draft survives in the untouched textarea: the key did not move.
  pending.composer |> should.equal(model.composer)

  // A duplicate send starts nothing: the guard rejects it wholesale.
  let rejected = step(pending, ui.SendRequested("hello there"))
  rejected |> should.equal(pending)
}

/// Picking a different bot while a create is in flight is allowed (it is
/// a pure model write); it does not start a second create.
pub fn compose_send_pending_bot_change_is_harmless_test() {
  let pending = compose_ready_model() |> step(ui.SendRequested("hi"))
  let switched = step(pending, ui.CreateBotChanged("b2"))
  switched.create_pending |> should.be_true
  switched.create_bot |> should.equal(Some("b2"))
  switched.pending_send |> should.equal(Some("hi"))
}

/// The worker's success reply clears the guard, selects the fresh
/// thread, and dispatches the stashed draft as its first message (the
/// send effect rides the same update — the harness drops effects, so
/// the model-level contract is what's pinned here).
pub fn created_selects_and_releases_draft_test() {
  let pending = compose_ready_model() |> step(ui.SendRequested("hello"))
  let done = step(pending, ui.Created(summary("s-new", False)))
  done.create_pending |> should.be_false
  done.pending_send |> should.equal(None)
  done.selected |> should.equal(Some("s-new"))
  list.map(done.threads, fn(t) { t.id }) |> should.equal(["s-new"])
}

/// Regression: during compose-new, `SendAccepted` can arrive before the fresh
/// thread's `Hello` replay (whose pre-send summary still has `streaming: False`).
/// `Hello` must preserve `streaming: True` instead of re-enabling Send mid-turn.
pub fn hello_preserves_streaming_after_send_accepted_test() {
  let model =
    compose_ready_model()
    |> step(ui.SendRequested("hello"))
    |> step(ui.Created(summary("s-new", False)))
    |> step(ui.SendAccepted)
    |> step(ui.Hello("smart"))
  model.streaming |> should.be_true
}

/// Regression: compose-new `Created` MUST deliver `thread.Join` to the fresh
/// thread actor strictly BEFORE `thread.Describe` / `thread.Send`. Batching
/// `join_effect` with `send_effect` via `effect.batch` reversed execution order
/// and dropped initial tokens streamed before Join landed.
pub fn created_with_draft_joins_before_sending_test() {
  let order = process.new_subject()
  // Minimal fake thread actor that records the exact order of Join / Describe /
  // Send messages it receives.
  let assert Ok(fake_thread) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg: thread.Msg) {
      case msg {
        thread.Join(_, _) -> {
          process.send(order, "join")
          actor.continue(state)
        }
        thread.Describe(reply) -> {
          process.send(order, "describe")
          process.send(
            reply,
            thread.ThreadStatus(
              model: "smart",
              message_count: 1,
              streaming: False,
              metrics: [],
              last_commit_at: 0,
            ),
          )
          actor.continue(state)
        }
        thread.Send(_, _, _, reply) -> {
          process.send(order, "send")
          process.send(reply, thread.Sent)
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    })
    |> actor.start

  // Minimal fake registry serving `Get("s-new")` with `fake_thread`.
  let assert Ok(fake_registry) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg: thread_registry.Msg) {
      case msg {
        thread_registry.Get(id, reply) if id == "s-new" -> {
          process.send(reply, Ok(fake_thread.data))
          actor.continue(state)
        }
        thread_registry.List(reply) -> {
          process.send(reply, [summary("s-new", True)])
          actor.continue(state)
        }
        thread_registry.AutoTitle(_, _, reply) -> {
          process.send(reply, True)
          actor.continue(state)
        }
        thread_registry.Channels(_, reply) -> {
          process.send(reply, [])
          actor.continue(state)
        }
        thread_registry.ChannelOf(_, reply) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    })
    |> actor.start

  let events = process.new_subject()
  let pending =
    ui.Model(
      ..compose_ready_model(),
      registry: fake_registry.data,
      events: Some(events),
    )
    |> step(ui.SendRequested("first draft"))
  let #(_done, eff) = ui.update(pending, ui.Created(summary("s-new", False)))
  // Perform the returned synchronous effects in Lustre's exact runtime order.
  effect.perform(
    eff,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { dynamic.nil() },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )

  let assert Ok(first) = process.receive(order, 1000)
  let assert Ok(second) = process.receive(order, 1000)
  let assert Ok(third) = process.receive(order, 1000)
  [first, second, third] |> should.equal(["join", "describe", "send"])
}

/// Regression (CodeRabbit PR review): if a sidebar refresh lists the newly
/// created thread and the user selects it before `Created` arrives, `Created`
/// must send the stashed draft on the existing visit without resetting it or
/// emitting `thread.Leave` for the same thread.
pub fn created_with_draft_already_selected_preserves_subscription_test() {
  let order = process.new_subject()
  let assert Ok(fake_thread) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg: thread.Msg) {
      case msg {
        thread.Join(_, _) -> {
          process.send(order, "join")
          actor.continue(state)
        }
        thread.Leave(_) -> {
          process.send(order, "leave")
          actor.continue(state)
        }
        thread.Describe(reply) -> {
          process.send(order, "describe")
          process.send(
            reply,
            thread.ThreadStatus(
              model: "smart",
              message_count: 1,
              streaming: False,
              metrics: [],
              last_commit_at: 0,
            ),
          )
          actor.continue(state)
        }
        thread.Send(_, _, _, reply) -> {
          process.send(order, "send")
          process.send(reply, thread.Sent)
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    })
    |> actor.start

  let assert Ok(fake_registry) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg: thread_registry.Msg) {
      case msg {
        thread_registry.Get(id, reply) if id == "s-new" -> {
          process.send(reply, Ok(fake_thread.data))
          actor.continue(state)
        }
        thread_registry.List(reply) -> {
          process.send(reply, [summary("s-new", True)])
          actor.continue(state)
        }
        thread_registry.AutoTitle(_, _, reply) -> {
          process.send(reply, True)
          actor.continue(state)
        }
        thread_registry.Channels(_, reply) -> {
          process.send(reply, [])
          actor.continue(state)
        }
        thread_registry.ChannelOf(_, reply) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    })
    |> actor.start

  let events = process.new_subject()
  let selected =
    ui.Model(
      ..compose_ready_model(),
      registry: fake_registry.data,
      events: Some(events),
    )
    |> step(ui.SendRequested("first draft"))
    // Simulate a sidebar refresh listing s-new and the user clicking it before
    // the create worker dispatches `Created`.
    |> step(ui.ThreadsLoaded([summary("s-new", False)]))
    |> step(ui.Select("s-new"))
  let visit_before = selected.visit

  let #(done, eff) = ui.update(selected, ui.Created(summary("s-new", False)))
  done.selected |> should.equal(Some("s-new"))
  done.visit |> should.equal(visit_before)
  done.create_pending |> should.be_false
  done.pending_send |> should.equal(None)

  effect.perform(
    eff,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { dynamic.nil() },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )

  let assert Ok(first) = process.receive(order, 1000)
  let assert Ok(second) = process.receive(order, 1000)
  [first, second] |> should.equal(["describe", "send"])
  // Neither a redundant Join nor a destructive Leave may be sent.
  process.receive(order, 100) |> should.equal(Error(Nil))
}

/// The worker's failure reply clears the guard and the stash — a
/// refused create must not lock the composer — while the VISIBLE draft
/// survives (no re-key happened) and a later send can proceed.
pub fn create_failed_clears_guard_and_allows_retry_test() {
  let pending = compose_ready_model() |> step(ui.SendRequested("hello"))
  let failed = step(pending, ui.CreateFailed("provider became unusable"))
  failed.create_pending |> should.be_false
  failed.pending_send |> should.equal(None)
  failed.composer |> should.equal(pending.composer)
  let assert [
    ui.NoteLine(True, "could not create thread: provider became unusable"),
    ..
  ] = failed.log

  let retried = step(failed, ui.SendRequested("hello"))
  retried.create_pending |> should.be_true
}

/// A send into a SELECTED thread never stashes or creates.
pub fn selected_send_does_not_compose_test() {
  let model =
    compose_ready_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
  let sent = step(model, ui.SendRequested("hi"))
  sent.pending_send |> should.equal(None)
  sent.create_pending |> should.be_false
}

/// Compose-new with NO bot picked: the send is a no-op (the composer is
/// disabled in this state; the arm is the defensive twin).
pub fn compose_send_without_bot_is_noop_test() {
  let model = compose_ready_model() |> step(ui.BotsLoaded([]))
  let sent = step(model, ui.SendRequested("hi"))
  sent.pending_send |> should.equal(None)
  sent.create_pending |> should.be_false
}

/// The Send button stays honest with the guard: disabled while a
/// compose-new create is in flight, and enabled when idle with a bot to
/// start from.
pub fn view_send_button_disabled_while_pending_test() {
  let ready = compose_ready_model() |> view_string
  should.be_false(string.contains(ready, "disabled id=\"send\""))

  let pending = compose_ready_model() |> step(ui.SendRequested("hi"))
  let html = pending |> view_string
  should.be_true(string.contains(html, "disabled id=\"send\""))
}

// --- the worker harness: real runtime over real (offline) registries ---

/// Boot the real per-connection runtime over real registries backed by
/// the offline store mock, seeding the store first and injecting the
/// provider registry's live model-list fetch.
fn start_offline_registries(
  seed: fn(store.Store) -> Result(Nil, String),
  fetch: fn(openai.Endpoint) -> Result(List(String), openai.StreamError),
) -> #(
  process.Subject(thread_registry.Msg),
  process.Subject(provider_registry.Msg),
  process.Subject(bot_registry.Msg),
) {
  start_offline_registries_with_resolver(seed, fetch, fixture_resolver())
}

/// The same harness with an explicit provider seam: the compose-send
/// tests pass the DEAD loopback resolver so the draft's follow-up turn
/// fails fast at stream time, fully offline (connection refused — no
/// DNS, no TLS).
fn start_offline_registries_with_resolver(
  seed: fn(store.Store) -> Result(Nil, String),
  fetch: fn(openai.Endpoint) -> Result(List(String), openai.StreamError),
  resolve: thread_registry.ResolveProvider,
) -> #(
  process.Subject(thread_registry.Msg),
  process.Subject(provider_registry.Msg),
  process.Subject(bot_registry.Msg),
) {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  store_mock.ensure_fixture_bot(seam)
  let _ = seed(seam)

  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_ui_create_providers"),
      fetch,
    )
  let bots_name = process.new_name("nexus_ui_create_bots")
  let assert Ok(started_bots) =
    bot_registry.start(seam, bots_name, fn(names) { Ok(names) }, fn() {
      bot_registry.ToolCatalog([], [])
    })
  let factory_name = process.new_name("nexus_ui_create_factory")
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder(factory_name))
  let assert Ok(started_registry) =
    thread_registry.start_with_toolset(
      test_config(),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("nexus_ui_create_registry"),
      seam,
      toolset(unused_turn_runner),
      fn() { [] },
      resolve,
      // Bots P3c: the delivery wrapper's sender-name ask resolves this
      // name at ask time — the SAME name this harness started the bot
      // registry under.
      bots_name,
      dict.new(),
      dict.new(),
    )
  #(started_registry.data, started_providers.data, started_bots.data)
}

/// A resolver whose endpoint is a CLOSED LOOPBACK port: creates freeze
/// it, and any turn that runs against it fails immediately at stream
/// time — fully offline (connection refused; no DNS, no TLS).
fn dead_resolver() -> thread_registry.ResolveProvider {
  fn(_id) {
    Ok(openai.Endpoint(
      base_url: "http://127.0.0.1:1/v1",
      api_key: None,
      sse_first_response_timeout_ms: 100,
      stream_idle_timeout_ms: 100,
    ))
  }
}

/// Start the runtime exactly like the /ws socket handler does, with a
/// test-owned client subject as the socket.
fn boot_create_runtime(
  registry: process.Subject(thread_registry.Msg),
  providers: process.Subject(provider_registry.Msg),
  bots: process.Subject(bot_registry.Msg),
) -> #(
  lustre.Runtime(ui.Msg),
  process.Subject(server_component.ClientMessage(ui.Msg)),
) {
  let assert Ok(runtime) =
    lustre.start_server_component(
      ui_runtime.app(),
      ui.Flags(
        registry: registry,
        providers: providers,
        bots: bots,
        models_timeout_ms: 60_000,
        thread: None,
        store: store_mock.seam(store_mock.start()),
        pair_base: "http://127.0.0.1:8080",
      ),
    )
  let client = process.new_subject()
  server_component.register_subject(client)
  |> lustre.send(to: runtime)
  #(runtime, client)
}

/// Poll the registry until exactly `want` threads exist (the create
/// lands from the worker asynchronously).
fn wait_for_thread_count(
  registry: process.Subject(thread_registry.Msg),
  want: Int,
  attempts: Int,
) -> List(thread.ThreadSummary) {
  let threads = thread_registry.list_threads(registry)
  case list.length(threads) == want || attempts <= 0 {
    True -> threads
    False -> {
      process.sleep(100)
      wait_for_thread_count(registry, want, attempts - 1)
    }
  }
}

/// The create worker over the real runtime, pinning the no-preflight
/// contract end to end: a bot pinned to an alias OFF the provider's live
/// list lands as a thread (proxies like Bifrost accept aliases their
/// /v1/models may not carry — see `nexus/thread_create`), and the create
/// path fetches no model list at all. The compose-new send IS the create
/// trigger; the view-patch check below only EXERCISES runtime liveness —
/// with the preflight gone, nothing on the create path can block (that
/// guarantee is structural: the worker is spawned unlinked;
/// duplicates-while-pending stay pinned at the unit level,
/// `compose_send_stashes_draft_and_guards_test`). The dead-loopback
/// resolver keeps the draft's follow-up turn offline: the turn fails at
/// stream time, exactly the dead-alias semantics.
pub fn create_worker_lands_off_list_alias_and_runtime_stays_live_test() {
  // The gate protocol doubles as the settle barrier: the boot alias load
  // is the ONLY fetch this test answers — receiving its signal proves
  // the provider load has landed (the fetch is fired BY `ProvidersLoaded`)
  // before anything below is dispatched.
  let started = process.new_subject()
  let #(registry, providers, bots) =
    start_offline_registries_with_resolver(
      fn(seam) {
        seam.insert_bot(bot.Bot(
          id: "b-off",
          name: "Writer",
          description: "",
          provider_id: store_mock.fixture_provider_id,
          model: "alias-gone",
          system_prompt: None,
          tools: None,
          allow_inbound: True,
          created_at: 0,
          updated_at: 0,
        ))
      },
      fn(_endpoint) {
        let gate = process.new_subject()
        process.send(started, gate)
        let assert Ok(answer) = process.receive(gate, 60_000)
        answer
      },
      dead_resolver(),
    )
  let #(runtime, client) = boot_create_runtime(registry, providers, bots)

  // The settle barrier is a VIEW PATCH now: the boot cascade no longer
  // fetches a model list at all, so the old fetch-gate protocol has
  // nothing to gate on. The compose-new hint flipping to "pick a bot"
  // proves BotsLoaded landed — and the providers load (the batch's
  // first effect) completed before it.
  let _ = wait_for_patch(client, "Pick a bot beside the composer", 40)

  // Compose a new thread from the bot (an explicit pick — no ordering
  // dependency on the boot bots load) and immediately flip the view: the
  // runtime must serve the patch while the create worker runs. The send
  // carries the draft that becomes the fresh thread's first message.
  lustre.send(
    to: runtime,
    message: lustre.dispatch(ui.CreateBotChanged("b-off")),
  )
  lustre.send(to: runtime, message: lustre.dispatch(ui.SendRequested("hello")))
  lustre.send(to: runtime, message: lustre.dispatch(ui.SettingsToggled))
  let _ = wait_for_patch(client, "Back to chat", 20)

  // The thread LANDED — an off-list alias is a valid pin, not a refusal,
  // and the bot is its required provenance.
  let threads = wait_for_thread_count(registry, 1, 40)
  let assert [only] = threads
  only.model |> should.equal("alias-gone")
  only.bot_id |> should.equal(Some("b-off"))

  // And the create path fetched NO model list: the boot load was the
  // only call (the old preflight is gone, not merely permissive).
  process.receive(started, 300) |> should.equal(Error(Nil))
}

/// The bot-sourced path through the real worker: resolve the bot, freeze
/// its values, land the thread with its `bot_id` provenance intact.
pub fn create_from_bot_worker_lands_provenance_test() {
  let started = process.new_subject()
  let #(registry, providers, bots) =
    start_offline_registries_with_resolver(
      fn(seam) {
        seam.insert_bot(bot.Bot(
          id: "b7",
          name: "Writer",
          description: "",
          provider_id: store_mock.fixture_provider_id,
          model: "alias-1",
          system_prompt: Some("be terse"),
          tools: None,
          allow_inbound: True,
          created_at: 0,
          updated_at: 0,
        ))
      },
      fn(_endpoint) {
        let gate = process.new_subject()
        process.send(started, gate)
        let assert Ok(answer) = process.receive(gate, 60_000)
        answer
      },
      dead_resolver(),
    )
  let #(runtime, _client) = boot_create_runtime(registry, providers, bots)

  // Compose-from-bot: the worker resolves the bot and creates directly —
  // no live-list fetch anywhere on the create path (the fetch closure
  // below is never called; the final receive asserts that). The explicit
  // CreateBotChanged pick carries no ordering dependency on the boot
  // bots load, and the dead-loopback resolver keeps the draft's
  // follow-up turn offline (it fails at stream time — the dead-alias
  // semantics).
  lustre.send(to: runtime, message: lustre.dispatch(ui.CreateBotChanged("b7")))
  lustre.send(to: runtime, message: lustre.dispatch(ui.SendRequested("hello")))

  let threads = wait_for_thread_count(registry, 1, 40)
  let assert [only] = threads
  only.bot_id |> should.equal(Some("b7"))
  only.model |> should.equal("alias-1")
}

/// A worker CRASH (not a refusal) must still release the pending guard:
/// with the provider registry dead, the create's first registry call
/// panics inside the unlinked worker — the rescue maps that crash onto
/// the create-failure path (note reaches the client, nothing lands
/// server-side) instead of leaving `create_pending` True and Create
/// disabled for the connection until a reload (#90 review).
pub fn create_worker_crash_releases_guard_test() {
  let started = process.new_subject()
  let #(registry, providers, bots) =
    start_offline_registries(
      fn(seam) {
        seam.insert_bot(bot.Bot(
          id: "b7",
          name: "Writer",
          description: "",
          provider_id: store_mock.fixture_provider_id,
          model: "alias-1",
          system_prompt: None,
          tools: None,
          allow_inbound: True,
          created_at: 0,
          updated_at: 0,
        ))
      },
      fn(_endpoint) {
        let gate = process.new_subject()
        process.send(started, gate)
        let assert Ok(answer) = process.receive(gate, 60_000)
        answer
      },
    )
  let #(runtime, client) = boot_create_runtime(registry, providers, bots)

  // Let the boot cascade drain BEFORE the kill (the connect effect asks
  // the provider registry; a mid-cascade kill would crash the runtime
  // instead of exercising the worker). The patch barrier is the same
  // one the landing test uses.
  let _ = wait_for_patch(client, "Pick a bot beside the composer", 40)

  // Kill the provider registry (unlinked first: it is linked to this
  // test process). The worker's very next registry call now panics.
  let assert Ok(pid) = process.subject_owner(providers)
  process.unlink(pid)
  process.kill(pid)
  // process.kill is asynchronous: wait until the registry is provably
  // gone (the signal processed) so the worker's registry call is
  // guaranteed to panic — otherwise the call could beat the kill and
  // this test would exercise the success path instead of the crash path.
  wait_until_dead(pid, 100)

  // The compose-new send starts the create (the bot pick is explicit —
  // no ordering dependency on the boot bots load). The crash surfaces
  // as a create-failure note (the guard clears with it — pinned offline
  // by create_failed_clears_guard_and_allows_retry); the draft never
  // sends because nothing landed.
  lustre.send(to: runtime, message: lustre.dispatch(ui.CreateBotChanged("b7")))
  lustre.send(to: runtime, message: lustre.dispatch(ui.SendRequested("hello")))

  let _ = wait_for_patch_prefix(client, "could not create thread: ", 40)
  thread_registry.list_threads(registry) |> should.equal([])
}

/// Like `wait_for_patch`, but matching a PREFIX — the crash note's
/// reason is the rescued crash term, not fixed vocabulary.
fn wait_for_patch_prefix(
  client: process.Subject(server_component.ClientMessage(ui.Msg)),
  prefix: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as { "patch never arrived: " <> prefix }
    _ ->
      case process.receive(client, 200) {
        Error(_) -> wait_for_patch_prefix(client, prefix, attempts - 1)
        Ok(message) -> {
          let text =
            server_component.client_message_to_json(message)
            |> json.to_string
          case string.contains(text, prefix) {
            True -> text
            False -> wait_for_patch_prefix(client, prefix, attempts - 1)
          }
        }
      }
  }
}

/// Poll until the pid is provably gone, so a call to it is guaranteed
/// to panic. Bounded; a still-alive pid past the budget proceeds (the
/// test then fails loudly instead of hanging).
fn wait_until_dead(pid: process.Pid, attempts: Int) -> Nil {
  case process.is_alive(pid) && attempts > 0 {
    False -> Nil
    True -> {
      process.sleep(10)
      wait_until_dead(pid, attempts - 1)
    }
  }
}

// ---------------------------------------------------------------------------
// Thread info pane (bot-channels plan Phase 2, #123)
// ---------------------------------------------------------------------------

/// One pane row (the `Channels` ask's reply shape, registry-side).
fn channel_info(
  thread_id: String,
  bot_name: Option(String),
  running: Bool,
  archived: Bool,
) -> thread_registry.ChannelInfo {
  thread_registry.ChannelInfo(
    thread_id: thread_id,
    bot_id: option.map(bot_name, fn(_) { "bot-1" }),
    bot_name: bot_name,
    title: "RelayBeta",
    running: running,
    archived: archived,
    last_active_s: timing.wall_now_s() - 3600,
  )
}

/// The channel-context a selection carries once the pane's reverse
/// lookup (or a row click) has landed: parent `s-parent`.
fn with_ctx(model: ui.Model) -> ui.Model {
  step(
    model,
    ui.ChannelResolved(
      option.unwrap(model.selected, ""),
      Ok(thread_registry.ChannelContext(
        parent_id: "s-parent",
        bot_id: Some("bot-1"),
        title: "RelayBeta",
        archived: False,
      )),
    ),
  )
}

/// A pane row click resolves against the viewed parent: the channel
/// becomes the selection through the ordinary Join machinery, the
/// clicked row SEEDS the context (no ask in the loop — the next refresh
/// re-derives the same truth), the pane closes, and the view resets
/// (visit bump, log clear) like any selection change.
pub fn channel_row_selection_seeds_context_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.UserEcho("hello", None, None))
  let info = channel_info("s-channel", Some("RelayBeta"), False, False)
  let model = step(model, ui.PaneToggled)
  model.pane_open |> should.be_true
  let model = step(model, ui.ChannelRowSelected(info))
  model.selected |> should.equal(Some("s-channel"))
  model.pane_open |> should.be_false
  model.log |> should.equal([])
  let assert Some(ctx) = model.channel_ctx
  ctx.parent_id |> should.equal("s-parent")
  ctx.bot_id |> should.equal(Some("bot-1"))
  ctx.title |> should.equal("RelayBeta")
  ctx.archived |> should.be_false
}

/// Selection-without-listing: a channel is never a sidebar row (the
/// registry projection hides channels from the list), and the PARENT's
/// row carries the highlight instead — exactly one row selected either
/// way, `aria-current` included. The channel is selected through the
/// PANE (row click), so the highlight can only come from the
/// `channel_ctx_of` mapping: `model.selected` names the channel, which
/// matches no listed row.
pub fn channel_selection_highlights_parent_row_test() {
  let info = channel_info("s-channel", Some("RelayBeta"), False, False)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.ChannelsLoaded("s-parent", [info]))
    |> step(ui.ChannelRowSelected(info))
  model.selected |> should.equal(Some("s-channel"))
  let html = view_string(model)
  should_contain(html, "thread-row selected")
  should_contain(html, "aria-current=\"true\"")
  should_not_contain(html, "data-thread-id=\"s-channel\"")
}

/// The crumb race: a list refresh queued BEFORE a selection change
/// lands after it, and a channel is absent from every list. The pending
/// marker holds the selection for that window; the stamped reply
/// settles it — Error (the id is ordinary or deleted) clears pending,
/// and the NEXT refresh drops the selection into the ordinary
/// auto-select path: a bounded one-refresh grace, never a permanent
/// ghost.
pub fn pending_resolution_holds_channel_selection_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    // The crumb: Select a channel id (not in any list).
    |> step(ui.Select("s-channel"))
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-channel"))
  model.channel_pending |> should.equal(Some("s-channel"))
  // The resolution lands and refuses: not a channel (or deleted).
  let model = step(model, ui.ChannelResolved("s-channel", Error(Nil)))
  model.channel_pending |> should.equal(None)
  model.channel_ctx |> should.equal(None)
  // Held no longer — the next refresh drops it (auto-select replaces).
  let model = step(model, ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-parent"))
  model.channel_pending |> should.equal(None)
}

/// The same window, resolved Ok: the context pins the selection and
/// pending clears — the selection is now held the ordinary way.
pub fn pending_resolution_ok_pins_context_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.Select("s-channel"))
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.ChannelResolved(
      "s-channel",
      Ok(thread_registry.ChannelContext(
        parent_id: "s-parent",
        bot_id: Some("bot-1"),
        title: "RelayBeta",
        archived: False,
      )),
    ))
  model.channel_pending |> should.equal(None)
  let assert Some(ctx) = model.channel_ctx
  ctx.parent_id |> should.equal("s-parent")
  // Held by the context now: a further refresh keeps the selection.
  let model = step(model, ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-channel"))
}

/// The pane renders one row per channel: dot state, `↳ <bot name>`,
/// relative age, chevron — all text nodes. The running channel pulses
/// (class), the idle one does not.
pub fn pane_renders_channel_rows_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", Some("RelayBeta"), True, False),
        channel_info("s-ch-2", Some("Scout"), False, False),
      ]),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "↳ RelayBeta")
  should_contain(html, "↳ Scout")
  should_contain(html, "ch-dot run")
  should_contain(html, "ch-dot idle")
  should_contain(html, "1h")
  should_contain(html, "›")
  // Rows navigate: each carries its thread id for the click.
  should_contain(html, "data-thread-id=\"s-ch-1\"")
  should_contain(html, "data-thread-id=\"s-ch-2\"")
}

/// The header badge counts RUNNING channels. Since Phase C (tui-pairing)
/// the button renders for EVERY selected thread — the pane is the
/// Environments/mint surface and must be reachable on a channel-less
/// thread — but the count chip hides at zero and the dot stays gray
/// there (the ambient signal still exists only where channels exist).
pub fn badge_counts_running_channels_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
  // No channels: the button renders (reachability), but carries no
  // count chip and no live dot.
  let idle_html = view_string(model)
  should_contain(idle_html, "id=\"info-btn\"")
  should_not_contain(idle_html, "class=\"n\"")
  should_not_contain(idle_html, "info-dot live")
  let with_idle =
    model
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
  let idle_rows_html = view_string(with_idle)
  should_contain(idle_rows_html, "id=\"info-btn\"")
  should_not_contain(idle_rows_html, "class=\"n\"")
  should_not_contain(idle_rows_html, "info-dot live")
  let running =
    model
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
        channel_info("s-ch-2", Some("Scout"), True, False),
      ]),
    )
  let running_html = view_string(running)
  should_contain(running_html, "<span class=\"n\">1</span>")
  should_contain(running_html, "info-dot live")
}

/// Viewing a channel swaps the header to `‹ <parent title>` plus the
/// channel's label (the bot's name; the frozen title when the bot row
/// is gone), with the archive chip when archived. All text nodes.
pub fn channel_breadcrumb_renders_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> with_ctx
  let html = view_string(model)
  should_contain(html, "id=\"crumb\"")
  should_contain(html, "‹ ")
  should_contain(html, "RelayBeta")
  should_not_contain(html, "ch-archived-chip")
  let archived =
    step(
      model,
      // The stamp must name the SELECTION (the guard drops replies for
      // other ids): the archived chip is a ctx flip on the viewed
      // channel, not a selection change.
      ui.ChannelResolved(
        "s-parent",
        Ok(thread_registry.ChannelContext(
          parent_id: "s-parent",
          bot_id: None,
          title: "OldHat",
          archived: True,
        )),
      ),
    )
  let archived_html = view_string(archived)
  should_contain(archived_html, "ch-archived-chip")
  // Deleted bot: the frozen creation title stands in for the name.
  should_contain(archived_html, "OldHat")
}

/// Pane rows are hostile text: a bot name carrying markup renders as
/// inert text — the same pin the roster lines and turn lines carry.
pub fn pane_rows_escape_hostile_labels_test() {
  let payload = "<script>alert(1)</script>"
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(
      ui.ChannelsLoaded("s-parent", [
        thread_registry.ChannelInfo(
          thread_id: "s-ch-1",
          bot_id: Some("bot-1"),
          bot_name: Some(payload),
          title: payload,
          running: False,
          archived: False,
          last_active_s: timing.wall_now_s(),
        ),
      ]),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_not_contain(html, "<script>")
  should_contain(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
}

// ---- Environments section (tui-pairing plan Phase C) ----

fn env_node(thread: String, name: String, last_seen: Option(Int)) -> node.Node {
  node.Node(
    id: "n-" <> name,
    thread_id: thread,
    name: name,
    token_hash: "aabbcc",
    created_at: timing.wall_now_s() - 3600,
    last_seen_at: last_seen,
  )
}

fn env_grant(thread_id: String, use_count: Int, expires_in: Int) -> node.Grant {
  let now = timing.wall_now_s()
  node.Grant(
    id: "g-" <> thread_id,
    code_hash: node.hash_token("unused"),
    thread_id: Some(thread_id),
    created_at: now,
    expires_at: now + expires_in,
    use_count: use_count,
    last_used_at: None,
  )
}

/// An env-carrying thread (a roster row in the log) renders the roster
/// with the joined node rows: last-seen ages and revokes. Everything is
/// a text node — target names are transcript text.
pub fn env_section_renders_roster_test() {
  let now = timing.wall_now_s()
  let roster_text =
    env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(now), Some("system")))
    |> step(
      ui.EnvLoaded(
        0,
        Some("s1"),
        [env_node("s1", "proxmox-2", Some(now - 120))],
        [],
      ),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "workspace")
  should_contain(html, "local workspace")
  should_contain(html, "proxmox-2")
  should_contain(html, "last seen 2m ago")
  should_contain(html, "data-revoke-node=\"n-proxmox-2\"")
  should_contain(html, "Pair a TUI")
  // Every stored row is rostered here: no unattached group.
  should_not_contain(html, "not attached:")
}

/// A rostered target with NO stored row renders without revoke (no
/// credential to revoke); a never-connected node reads "never
/// connected".
pub fn env_section_unpaired_and_never_connected_test() {
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(
      env.roster_attach_text("ghost", ["workspace", "ghost", "fresh"]),
      Some(now),
      Some("system"),
    ))
    |> step(ui.EnvLoaded(0, Some("s1"), [env_node("s1", "fresh", None)], []))
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "no credential")
  should_not_contain(html, "data-revoke-node=\"n-ghost\"")
  should_contain(html, "never connected")
  should_contain(html, "data-revoke-node=\"n-fresh\"")
}

/// A stored node row NOT on this thread's roster — a disconnected TUI's
/// row awaiting the idle sweep — renders as a "not attached" group with
/// a Revoke button: the pairing exchange's 409 advice ("revoke it in
/// the thread info pane") must stay reachable for exactly the ghost row
/// it names. A rostered row is NOT duplicated into the group, and a
/// row of ANOTHER thread never renders here at all (names are
/// per-thread; cross-thread rows are different nodes).
pub fn env_section_unattached_ghost_rows_test() {
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(
      env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"]),
      Some(now),
      Some("system"),
    ))
    |> step(ui.EnvLoaded(
      0,
      Some("s1"),
      [
        env_node("s1", "proxmox-2", Some(now - 120)),
        env_node("s1", "plastic", Some(now - 60)),
        // Another thread's 'laptop' row: a DIFFERENT node (per-thread
        // names) — invisible here, revocable from its own thread's pane.
        env_node("s-other", "laptop", Some(now)),
      ],
      [],
    ))
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "not attached:")
  should_contain(html, "data-revoke-node=\"n-plastic\"")
  should_contain(html, "last seen 1m ago")
  should_not_contain(html, "data-revoke-node=\"n-laptop\"")
  // Exactly one row for the rostered node (split-and-count idiom).
  string.split(html, "data-revoke-node=\"n-proxmox-2\"")
  |> list.length
  |> should.equal(2)
}

/// A thread created without a workspace has NO roster row: the section
/// reads "no environment" and the mint button does not render (a TUI
/// could not serve it). A node row can still be bound to it (POST
/// /nodes only asks that the thread exist), and it renders as an
/// unattached row with its Revoke.
pub fn env_plain_thread_has_no_mint_test() {
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(
      ui.EnvLoaded(
        0,
        Some("s1"),
        [env_node("s1", "ghost-pair", Some(now - 30))],
        [],
      ),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "no environment")
  should_not_contain(html, "id=\"pair-tui\"")
  // No roster → every stored row of the thread is unattached, and its
  // revoke stays reachable (the 409's advice holds on roster-less
  // threads too).
  should_contain(html, "not attached:")
  should_contain(html, "data-revoke-node=\"n-ghost-pair\"")
}

/// The mint flow: the guard arms on request, the ONE-TIME URL display
/// takes the plaintext code (server-side only the hash is stored), and
/// the grant list renders the new row's state line.
pub fn env_mint_shows_url_once_test() {
  let roster_text =
    env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(0), Some("system")))
    |> step(ui.PaneToggled)
  let pending = step(model, ui.GrantMintRequested)
  pending.grant_minting |> should.be_true
  let grant = env_grant("s1", 0, 3540)
  let minted = step(pending, ui.GrantMinted("CODE123", grant))
  minted.grant_minting |> should.be_false
  let html = view_string(minted)
  should_contain(html, "http://127.0.0.1:8080/pair/CODE123")
  should_contain(html, "data-pair-url=\"CODE123\"")
  should_contain(html, "data-pair-copy=\"CODE123\"")
  should_contain(html, ">Copy</button>")
  // Wall-clock live (fixture and renderer read the clock separately):
  // pin the stable shape, not the exact minute — the exact labels are
  // the pure fn's contract (expires_in_label_test).
  should_contain(html, "expires in")
  should_not_contain(html, "expired")
  should_contain(html, "active")
  should_contain(html, "paired 0 TUIs")
}

/// "Shown once" is literal: the server-component model outlives the
/// pane, so CLOSING it retires the mint display — otherwise the live
/// credential would re-render on every reopen for the whole /ws
/// connection (Settings entering closes the pane with the same rule),
/// and a mint landing on an already-closed pane is dropped — the row
/// still lands (the write-through succeeded), the plaintext does not.
pub fn env_mint_url_retired_when_pane_closes_test() {
  let roster_text =
    env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  let minted =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(0), Some("system")))
    |> step(ui.PaneToggled)
    |> step(ui.GrantMintRequested)
    |> step(ui.GrantMinted("CODE123", env_grant("s1", 0, 3540)))
  view_string(minted) |> should_contain("CODE123")
  // The toggle close (× button, click-outside, the badge — all ride
  // PaneToggled): the display is gone and reopening answers with the
  // mint button, never the stale URL.
  let closed = step(minted, ui.PaneToggled)
  closed.grant_minted |> should.equal(None)
  let reopened = step(closed, ui.PaneToggled)
  reopened.grant_minted |> should.equal(None)
  let html = view_string(reopened)
  should_not_contain(html, "CODE123")
  should_contain(html, "id=\"pair-tui\"")
  // Entering Settings closes the pane: the same retirement.
  let again =
    reopened
    |> step(ui.GrantMintRequested)
    |> step(ui.GrantMinted("CODE456", env_grant("s1", 0, 3540)))
  view_string(again) |> should_contain("CODE456")
  let settings = step(again, ui.SettingsToggled)
  settings.grant_minted |> should.equal(None)
  view_string(settings) |> should_not_contain("CODE456")
  // A mint landing on a closed pane: the guard releases, the row
  // lands, the code does not. (Back to the chat view first; the pane
  // stays closed — no toggle.)
  let pending =
    settings
    |> step(ui.SettingsToggled)
    |> step(ui.GrantMintRequested)
  let landed =
    step(pending, ui.GrantMinted("CODE999", env_grant("s1", 0, 3540)))
  landed.grant_minting |> should.be_false
  landed.grant_minted |> should.equal(None)
  landed.env_grants
  |> list.any(fn(g) { g.thread_id == Some("s1") })
  |> should.be_true
  view_string(landed) |> should_not_contain("CODE999")
}

/// The mint display is stamped: a mint answering for a SUPERSEDED
/// selection is dropped (the guard still releases).
pub fn env_mint_stamps_to_selection_test() {
  // The delayed-mint scenario: a mint STARTED on s1 lands after the
  // user moved to s2 — the display must be dropped (stamped with the
  // minting thread, not applied to whoever is selected now).
  let roster_text =
    env.roster_attach_text("proxmox-2", ["workspace", "proxmox-2"])
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False), summary("s2", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(0), Some("system")))
    |> step(ui.PaneToggled)
  let pending = step(model, ui.GrantMintRequested)
  let switched = step(pending, ui.Select("s2"))
  switched.selected |> should.equal(Some("s2"))
  let minted_late =
    step(switched, ui.GrantMinted("CODE123", env_grant("s1", 0, 3540)))
  minted_late.grant_minting |> should.be_false
  minted_late.grant_minted |> should.equal(None)
  let html = view_string(minted_late)
  should_not_contain(html, "CODE123")
}

/// The grants list filters to the SELECTED thread's rows; expired-
/// but-unswept rows stay listed, labelled.
pub fn env_grants_filter_and_expire_label_test() {
  let roster_text = env.roster_attach_text("proxmox-2", ["workspace"])
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False), summary("s2", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(now), Some("system")))
    |> step(
      ui.EnvLoaded(0, Some("s1"), [], [
        env_grant("s1", 2, 1800),
        env_grant("s2", 1, 1800),
        env_grant("s1", 0, -60),
      ]),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  // The active row's minute count is wall-clock live (fixture and
  // renderer read the clock separately), so pin the stable parts: the
  // state word, the use-count diagnostic, and the fact it is NOT
  // expired. The exact labels are the pure fn's contract
  // (expires_in_label_test).
  should_contain(html, "active")
  should_contain(html, "paired 2 TUIs")
  should_contain(html, "expires in")
  // The past-due row is drift-safe: any wall time after the fixture
  // reads expired.
  should_contain(html, "expired · expired · paired 0 TUIs")
  // The other thread's grant never renders here.
  should_not_contain(html, "paired 1 TUI")
}

/// A revoke self-refreshes: the revoke worker re-reads and dispatches
/// the stamped EnvLoaded; here, the reply path — the revoked grant's
/// row is gone from the list, and the one-time display drops when ITS
/// grant is the one revoked.
pub fn env_revoke_reply_clears_display_test() {
  let roster_text = env.roster_attach_text("proxmox-2", ["workspace"])
  let grant = env_grant("s1", 0, 3540)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(0), Some("system")))
    |> step(ui.EnvLoaded(0, Some("s1"), [], [grant]))
    |> step(ui.PaneToggled)
    |> step(ui.GrantMintRequested)
    |> step(ui.GrantMinted("CODE123", grant))
  // A re-read lands WITHOUT the revoked grant: the display drops with
  // it (a revoked URL must not linger). The re-read carries the mint
  // request's generation (the bump proves the drop is CONTENT-based,
  // not a generation mismatch).
  let refreshed = step(model, ui.EnvLoaded(1, Some("s1"), [], []))
  refreshed.grant_minted |> should.equal(None)
  let html = view_string(refreshed)
  should_not_contain(html, "CODE123")
  should_not_contain(html, "data-revoke-grant")
}

/// Selection change clears the section's per-selection state (the pane
/// rule the channel rows already follow).
pub fn env_state_is_per_selection_test() {
  let roster_text = env.roster_attach_text("proxmox-2", ["workspace"])
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False), summary("s2", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(roster_text, Some(now), Some("system")))
    |> step(
      ui.EnvLoaded(0, Some("s1"), [env_node("s1", "proxmox-2", Some(now))], []),
    )
    |> step(ui.PaneToggled)
    |> step(ui.GrantMinted("CODE123", env_grant("s1", 0, 3540)))
    |> step(ui.Select("s2"))
  model.env_nodes |> should.equal([])
  model.env_grants |> should.equal([])
  model.grant_minted |> should.equal(None)
  model.env_error |> should.equal(None)
}

/// Hostile text: a crafted roster row (transcript text — a hostile
/// payload can ride a persisted roster line) renders inert; the parsed
/// "target" is a text node like any other.
pub fn env_roster_row_is_hostile_text_test() {
  let payload = env.roster_prefix <> "workspace, <script>alert(1)</script>img."
  let now = timing.wall_now_s()
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s1", False)]))
    |> step(ui.Select("s1"))
    |> step(ui.UserEcho(payload, Some(now), Some("system")))
    |> step(ui.EnvLoaded(0, Some("s1"), [], []))
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_not_contain(html, "<script>")
  should_contain(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
}

/// The pure expiry label: minute granularity, sub-minute and past-due
/// arms (the timestamps script's ticking twin uses the same
/// thresholds).
pub fn expires_in_label_test() {
  ui.expires_in_label(1000, 1600) |> should.equal("expires in 10m")
  ui.expires_in_label(1000, 1060) |> should.equal("expires in 1m")
  ui.expires_in_label(1000, 1059) |> should.equal("expires <1m")
  ui.expires_in_label(1000, 1000) |> should.equal("expired")
  ui.expires_in_label(1000, 999) |> should.equal("expired")
}

/// The deleted-bot fallback is the frozen creation title (the as-built
/// amended the plan's "falls back to the id" — `create_dm` titled the
/// channel with the bot's name, so the fallback still reads as a name).
/// The row and the header label both use it.
pub fn deleted_bot_label_falls_back_to_title_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", None, False, False),
      ]),
    )
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "↳ RelayBeta")
  // The header badge's aria label never shows a raw bot pointer either.
  should_contain(html, "aria-label=\"Thread info — 0 running\"")
}

/// An archived channel renders dimmed WITH its archive badge and stays
/// navigable: the row still selects it (read-only transcript, the actor
/// refuses Sends — never hidden).
pub fn archived_channel_row_stays_navigable_test() {
  let info = channel_info("s-ch-1", Some("OldHat"), False, True)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.ChannelsLoaded("s-parent", [info]))
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "ch archived")
  should_contain(html, ">archived</span>")
  let model = step(model, ui.ChannelRowSelected(info))
  model.selected |> should.equal(Some("s-ch-1"))
  let assert Some(ctx) = model.channel_ctx
  ctx.archived |> should.be_true
}

/// A channel selection survives a list refresh on the context's word:
/// channels are absent from the (channel-free) list, so the
/// list-only rule would drop the selection — and its transcript — on
/// the very first refresh after a reload (`Flags.thread` naming a
/// channel is a supported state). The resolution rides the same effect
/// as the list and lands first; this is the update half of that order.
pub fn threads_loaded_keeps_channel_selection_test() {
  let model =
    new_model_with_thread(Some("s-channel"))
    |> step(ui.ChannelResolved(
      "s-channel",
      Ok(thread_registry.ChannelContext(
        parent_id: "s-parent",
        bot_id: Some("bot-1"),
        title: "RelayBeta",
        archived: False,
      )),
    ))
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-channel"))
  model.model_label |> should.equal("")
  // Once the context is gone (the channel was deleted — CASCADE), the
  // next refresh drops the selection and the ordinary auto-select picks
  // a replacement; the dropped channel's pane state goes with it (the
  // `switched` rule), so the replacement is never dressed in it.
  let model =
    step(model, ui.ChannelResolved("s-channel", Error(Nil)))
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-parent"))
  model.channel_ctx |> should.equal(None)
  model.channels |> should.equal([])
}

/// The context reply is stamped with the id it was asked for: a
/// selection change while the ask ran must not dress the new selection
/// in the old thread's context.
pub fn channel_resolved_drops_stale_stamp_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(ui.ChannelResolved(
      "s-other",
      Ok(thread_registry.ChannelContext(
        parent_id: "s-parent",
        bot_id: Some("bot-1"),
        title: "RelayBeta",
        archived: False,
      )),
    ))
  model.channel_ctx |> should.equal(None)
}

/// The rows reply is stamped with the parent it was asked for: rows for
/// a thread that is no longer selected never render.
pub fn channels_loaded_drops_stale_parent_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(
      ui.ChannelsLoaded("s-other", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
  model.channels |> should.equal([])
}

/// Pane state is per-selection: any selection change (and entering
/// Settings) closes the popover and clears the rows, like `pop`.
pub fn pane_closes_on_selection_change_and_settings_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-1", False)]))
    |> step(ui.Select("s-1"))
    |> step(
      ui.ChannelsLoaded("s-1", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
    |> step(ui.PaneToggled)
  model.pane_open |> should.be_true
  // A DIFFERENT selection closes it; the same-id Select is a deliberate
  // no-op (the guard exists so a stray re-click cannot reset the view).
  let model =
    model
    |> step(
      ui.ThreadsLoaded([
        summary("s-1", False),
        summary("s-2", False),
      ]),
    )
    |> step(ui.Select("s-2"))
  model.pane_open |> should.be_false
  model.channels |> should.equal([])
  model.channel_ctx |> should.equal(None)
  let model =
    model
    |> step(
      ui.ChannelsLoaded("s-1", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
    |> step(ui.PaneToggled)
    |> step(ui.SettingsToggled)
  model.pane_open |> should.be_false
}

/// The composer hints say something true or nothing at all: the channel
/// hint exactly while a channel is viewed, the pane hint while the
/// selected thread actually has channels.
pub fn composer_hints_follow_context_test() {
  let plain =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
  view_string(plain) |> should_not_contain("hint-child")
  view_string(plain) |> should_not_contain("hint-parent")
  let with_rows =
    plain
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
  view_string(with_rows) |> should_contain("hint-parent")
  view_string(with_rows) |> should_not_contain("hint-child")
  let in_channel = with_rows |> with_ctx
  let html = view_string(in_channel)
  should_contain(html, "hint-child")
  // Text nodes are HTML-escaped (the apostrophe rides as &#39;): the
  // assert stops before the quoted title.
  should_contain(html, "bot channel of")
}

/// The Details section renders the selected thread's metadata: an
/// ordinary selection reads the summary (bot, provider·model, created
/// age); a channel selection reads the context (bot, parent). Text
/// nodes throughout.
pub fn pane_details_render_from_summary_and_ctx_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.PaneToggled)
  let html = view_string(model)
  should_contain(html, "Provider / model")
  should_contain(html, "Created")
  // created_at 0 renders as years-ago; the shape is what is pinned.
  should_contain(html, "ago")
  let in_channel = model |> with_ctx
  let html = view_string(in_channel)
  should_contain(html, ">Parent</span>")
  // The parent's DISPLAY title (the untitled fallback), not the id.
  should_contain(html, "Untitled thread")
  should_not_contain(html, "Provider / model")
}

/// A replaced selection (a dropped thread auto-replaced by the first
/// active one — e.g. a viewed channel whose parent was deleted: the
/// CASCADE takes the channel) resets the TRANSCRIPT state too, not
/// just the pane fields: the replacement's Join replay appends to the
/// log, so the vanished thread's lines would bleed into it. Ended
/// alone covers only the no-replacement drop; `switched` covers this
/// path (the CodeRabbit review finding).
pub fn replacement_auto_select_resets_vanished_channel_test() {
  let info = channel_info("s-channel", Some("RelayBeta"), False, False)
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(ui.ChannelsLoaded("s-parent", [info]))
    |> step(ui.ChannelRowSelected(info))
    // The viewed channel's transcript has content.
    |> step(ui.UserEcho("channel line", None, None))
  // The channel is gone (deleted directly — its resolution refuses),
  // while the parent remains listed: the next refresh drops the
  // selection and auto-selects the parent as the replacement.
  let model = step(model, ui.ChannelResolved("s-channel", Error(Nil)))
  let model = step(model, ui.ThreadsLoaded([summary("s-parent", False)]))
  model.selected |> should.equal(Some("s-parent"))
  // The vanished channel's transcript did not survive the switch.
  model.log |> should.equal([])
  model.streaming |> should.be_false
  model.channel_ctx |> should.equal(None)
  model.channels |> should.equal([])
}

/// Toggling the pane open re-asks for fresh rows (the effect carries
/// the ask; here we pin the update half: opening on a selection with
/// rows keeps them, and the badge's aria state follows).
pub fn pane_toggle_aria_tracks_open_state_test() {
  let model =
    new_model()
    |> step(ui.ThreadsLoaded([summary("s-parent", False)]))
    |> step(ui.Select("s-parent"))
    |> step(
      ui.ChannelsLoaded("s-parent", [
        channel_info("s-ch-1", Some("RelayBeta"), False, False),
      ]),
    )
  let closed_html = view_string(model)
  should_contain(closed_html, "aria-expanded=\"false\"")
  should_not_contain(closed_html, ">Thread info<")
  let open_html = model |> step(ui.PaneToggled) |> view_string
  should_contain(open_html, "aria-expanded=\"true\"")
  should_contain(open_html, "Thread info")
}
