//// The M3 chat UI as a Lustre server component: Model, Msg, init, update,
//// and view. This module is the pure half — transport, WebSocket upgrade,
//// and runtime wiring live in `nexus/ui_runtime`.
////
//// The component mirrors the M2 client plus the M3 tool surface: alias
//// picker, session sidebar, streaming log with a single in-flight assistant
//// bubble, **typed tool-call cards** (name, stable call id, argument
//// preview, running/completed/failed status, compact inert result
//// picker, session sidebar, streaming log with a single in-flight assistant
//// bubble, **typed tool-call cards** (name, stable call id, argument
//// preview, running/completed/failed status) rendered as compact
//// clickable chips — clicking one opens the **full-call popup** (a Pico
//// `<dialog>` carrying the entire argument and result text; codemode
//// scripts render decoded, not as escaped JSON), loop/iteration status, the model's streamed **reasoning**
//// (chain of thought, as an inert collapsible block whose commit/rollback
//// mirrors the server's). Log
//// auto-follow and the jump-to-latest control are browser-only behaviour
//// driven by the page shell's static autoscroll script. Tool and
//// reasoning events are never rendered as model text, live or on Hello
//// replay. All dynamic text is produced with Lustre `text` nodes; there is
//// no `innerHTML` anywhere.
////
//// The shell hosts two views (per client): the chat layout and the
//// Settings page (`nexus/ui_settings`, provider management), swapped
//// via the header button. Settings state is a lifted sub-component —
//// `ui.Settings(msg)` delegates to `ui_settings.update` and folds its
//// signals back into this model.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import lustre/server_component
import nexus/provider.{type Provider}
import nexus/provider_registry
import nexus/session.{type SessionEvent}
import nexus/session_registry
import nexus/timing
import nexus/ui/markdown
import nexus/ui_settings

/// Everything the component needs to talk to the rest of the app. The
/// registry subjects are resolved from their names at boot and stay
/// stable across component restarts.
///
/// `session` is the client-supplied last-selected session (the `/ws`
/// route's `session` query parameter, persisted by the page shell): each
/// connection gets a fresh runtime and model, so this is what re-opens the
/// same session after a reload instead of falling back to the arbitrary
/// auto-selection. `None` for a first-time visitor.
pub type Flags {
  Flags(
    registry: Subject(session_registry.Msg),
    providers: Subject(provider_registry.Msg),
    session: Option(String),
  )
}

/// Status of one assistant tool call.
pub type ToolStatus {
  /// The call is streaming its arguments or executing.
  ToolRunning
  /// The tool finished; `ok` is the executor's verdict.
  ToolDone(ok: Bool)
}

/// One completed line in the chat log. The in-flight assistant bubble is
/// kept separately (like M2) so tokens can be appended cheaply. `at` on
/// the text lines is the message's display stamp (wall-clock epoch
/// seconds; None = unstamped legacy history) — display metadata like the
/// reasoning sidecar it mirrors, never a request byte.
pub type Line {
  UserLine(text: String, at: Option(Int))
  AssistantLine(text: String, at: Option(Int))
  /// The reasoning (chain of thought) a committed assistant message was
  /// preceded by — replayed from history or committed from the live
  /// thinking stream. Rendered as an inert, collapsed block.
  ReasoningLine(text: String)
  /// One assistant tool call. Rendered as a compact card: tool name, stable
  /// call id, truncated argument preview, status, and (once available) a
  /// truncated inert result preview. `result` is None while running.
  ToolLine(
    id: String,
    name: String,
    arguments: String,
    status: ToolStatus,
    result: Option(String),
  )
  NoteLine(err: Bool, text: String)
}

/// A tool call still streaming its arguments (before assembly). Keyed by
/// the stream chunk index so fragments from parallel calls stay separate.
pub type PendingCall {
  PendingCall(
    index: Int,
    id: Option(String),
    name: Option(String),
    args: String,
  )
}

/// Which tool call the full-call popup shows, if any. One popup at a time.
/// A committed call is keyed by its stable call id (resolved against the
/// log at render time — a rolled-back turn's id resolves to nothing and
/// the popup silently disappears); a still-streaming call has no stable id
/// yet, so it is keyed by its chunk index and resolved against `pending`.
/// Display-only per-client state: it never touches a request byte.
pub type Pop {
  CallPop(id: String)
  PendingPop(index: Int)
}

/// Live loop state for the turn in flight (M3 iteration chip).
pub type LoopState {
  LoopState(iteration: Int, max_iterations: Int, phase: String)
}

/// Sidebar recency bucket for a session's last activity. Pure UTC-day
/// arithmetic over epoch seconds — deliberately deterministic, with frozen
/// boundary fixtures in the tests.
pub type Bucket {
  Today
  Yesterday
  Previous7Days
  Older
}

/// Which recency bucket `at` falls into relative to `now_epoch`. Same UTC
/// day → Today (future timestamps too — clock skew must not crash the
/// view); then Yesterday, the previous 7 days, and Older.
pub fn bucket(now_epoch: Int, at: Int) -> Bucket {
  case day_index(now_epoch) - day_index(at) {
    days if days <= 0 -> Today
    1 -> Yesterday
    days if days <= 7 -> Previous7Days
    _ -> Older
  }
}

fn day_index(epoch: Int) -> Int {
  epoch / 86_400
}

pub fn bucket_label(bucket: Bucket) -> String {
  case bucket {
    Today -> "Today"
    Yesterday -> "Yesterday"
    Previous7Days -> "Previous 7 days"
    Older -> "Older"
  }
}

/// Compact relative age for the row subtitle ("just now", "12m", "3h",
/// "2d", "5w", "1y"). Pure; `at` in the future reads as "just now".
pub fn rel_time(now_epoch: Int, at: Int) -> String {
  let seconds = int.max(0, now_epoch - at)
  case seconds {
    s if s < 60 -> "just now"
    s if s < 3600 -> int.to_string(s / 60) <> "m"
    s if s < 86_400 -> int.to_string(s / 3600) <> "h"
    s if s < 7 * 86_400 -> int.to_string(s / 86_400) <> "d"
    s if s < 365 * 86_400 -> int.to_string(s / { 7 * 86_400 }) <> "w"
    s -> int.to_string(s / { 365 * 86_400 }) <> "y"
  }
}

/// Which main view the shell renders. The header (title, session context,
/// connection state, settings button) persists across both; the `#layout`
/// area swaps between the chat triple and the settings page.
pub type UiView {
  ChatView
  SettingsView
}

pub type Model {
  Model(
    providers: Subject(provider_registry.Msg),
    registry: Subject(session_registry.Msg),
    // Long-lived subscription to the selected session's events, owned by
    // this connection's runtime (one runtime per /ws client since the
    // per-client break; a reload is a new subject, and the session actor
    // de-duplicates re-Joins by subject).
    events: Option(Subject(SessionEvent)),
    /// The provider whose models fill the create panel's picker (P5): the
    /// user's selection, defaulting to the first enabled provider. Aliases
    /// reload whenever this changes.
    provider: Option(String),
    /// All providers as masked metadata (the Settings page, the picker's
    /// options, and provider-name resolution for session subtitles).
    /// `has_key` only — key material never reaches this model.
    provider_list: List(Provider),
    /// Which main view the shell renders (chat vs settings).
    view: UiView,
    /// The Settings sub-component's state (provider editors + the
    /// on-demand connection test), lifted through `ui.Settings(msg)`.
    settings: ui_settings.State,
    /// True once the user has toggled the settings view BY HAND: the
    /// first-run auto-open rule (empty provider list → settings) then
    /// stops firing — mirroring `create_auto`.
    settings_manual: Bool,
    /// True once any `ProvidersLoaded` has arrived on this connection:
    /// the auto-open rule fires only on the FIRST load, so a provider
    /// list that later becomes empty (e.g. external deletes + reconnect
    /// refresh) never hijacks a session in progress back into settings.
    providers_seen: Bool,
    /// Set by the deliberate no-selection entry points (archiving the
    /// open session, the New-session button): the loaded list must not
    /// auto-select a replacement — an empty selection is a real state,
    /// not a gap to paper over. Cleared whenever a selection exists or
    /// lands (auto-select or `Select`), so the boot auto-selection and
    /// the vanished-selection reselect keep working unchanged.
    suppress_autoselect: Bool,
    aliases: List(String),
    sessions: List(session.SessionSummary),
    selected: Option(String),
    /// Monotonic per-connection visit generation, bumped on every session
    /// join (`GotEvents`, `Select`, the `SessionsLoaded` auto-switch) and
    /// sent with `session.Join`; the actor echoes it on every delivery to
    /// this subscriber. `SessionScoped` applies a delivery only when BOTH
    /// the session id and this generation match — a rapid A→B→A switch
    /// must not re-apply session A's queued first-visit events (same id,
    /// stale generation) on top of the second visit's replay.
    visit: Int,
    /// The text the `ToolCallDelta` arm committed ahead of the worker's
    /// append (the loop commits round text at assembly time, but the UI
    /// commits at the first fragment so the pill lands above the pending
    /// card — pinned display behaviour). Its authoritative stamp arrives
    /// on the round's `ToolCallAssembled` (`loop.append_calls`' sidecar
    /// entry), which restamps all of them; `finish_turn` restamps with the
    /// terminal event's stamp for a Stop that landed between the fragments
    /// and the assembly. Text and call fragments can interleave within one
    /// round, so a round may flush MORE THAN ONE segment — all are tracked,
    /// newest-first. Cleared when the selection changes or the session
    /// ends: a stale entry must never stamp another session's (possibly
    /// legacy-unstamped) line that happens to carry the same text.
    flushed: List(String),
    picker: String,
    create_open: Bool,
    log: List(Line),
    bubble: Option(String),
    /// Whether the live bubble must not render: either there is no bubble
    /// or its text renders to nothing under markdown (whitespace-only, or
    /// e.g. a lone footnote definition) — the SAME rule the commit and
    /// replay paths apply to `AssistantLine`s, so the bubble can never
    /// show text that then vanishes at commit. True whenever the bubble
    /// resets; the `Token` arm flips it to False the first time the
    /// accumulated text renders non-empty and never flips back (the
    /// bubble only grows), so the parse never re-runs per streamed token.
    bubble_hidden: Bool,
    // The reasoning (chain of thought) streaming in ahead of the bubble —
    // the display-side twin of the server's reasoning-only-commit rule:
    // it is committed to the log only when the turn's assistant output
    // commits, and rolls back with a failed turn.
    thinking: Option(String),
    streaming: Bool,
    // Tool calls whose arguments are still streaming (not yet assembled).
    pending: List(PendingCall),
    // Iteration chip for the turn in flight ("iter 2/8 · tools").
    loop: Option(LoopState),
    // The loop guard fired this turn: the final partial text *is* committed
    // server-side, so the terminal handler must not roll the turn back.
    guard: Bool,
    // Log length (in lines) at the start of the live turn — the rollback
    // point when a turn fails without committing anything server-side.
    turn_base: Int,
    // Monotonic generation counter for the keyed composer textarea: bumping
    // it after an accepted send replaces the (uncontrolled) textarea, which
    // is the only way a server component can clear it — see `composer` below.
    composer: Int,
    // True while the create panel is open *because the session list was
    // empty* (e.g. the component booted before the registry's first
    // session existed) — auto-opened, so it also auto-closes again once
    // there is something to select.
    create_auto: Bool,
    // Header fallback label (ui-polish F8): what the `#model` span shows
    // while NO session is selected — "connecting…" at boot and on select,
    // "session ended" after the selection drops. With a selection the
    // header shows the session's title instead (see `header_title`).
    model_label: String,
    // ---- Session organization (registry metadata, display only) ----
    /// Free-text filter over titles + tags, case-insensitive.
    tag_filter: String,
    /// Bumped on every *programmatic* filter change (chip click, clear) so
    /// the keyed filter input is replaced wholesale — an uncontrolled
    /// input cannot be patched, only replaced (the composer pattern).
    filter_gen: Int,
    /// Soft-hidden sessions are listed only while this is on.
    show_archived: Bool,
    /// The row whose inline rename editor is open (at most one).
    rename_open: Option(String),
    /// The row whose inline tag editor is open (at most one).
    tags_open: Option(String),
    /// The row whose two-step delete confirmation is armed.
    confirm_delete: Option(String),
    /// The tool call the full-call popup shows, if any (at most one).
    /// See `Pop` — cleared on session switch, turn rollback, and when a
    /// new turn begins (call ids are only unique within a turn); a stale
    /// entry whose call no longer resolves simply renders nothing.
    pop: Option(Pop),
    /// Rendered markdown element trees for committed assistant lines,
    /// keyed by exact message text. Populated when a turn commits, never
    /// in the view: the log re-renders on every streamed token, and
    /// reparsing every committed message each time would make long
    /// transcripts quadratic. assistant_turn reads it, falling back to a
    /// direct parse on a miss (render is pure, so a stale hit is
    /// impossible — equal text means equal tree).
    md_cache: dict.Dict(String, List(Element(Msg))),
  )
}

pub type Msg {
  Ignored
  // The session-event subscription created by the select effect in `init`.
  // A per-client runtime's connect point: the load cascade (and the
  // re-Join of the client-supplied session) starts once the subject is in
  // the model. There is deliberately no ClientConnected/ClientDisconnected
  // — one runtime serves exactly one client for its whole life, so connect
  // is `init` and disconnect is the runtime dying with its socket.
  GotEvents(Subject(SessionEvent))
  /// One session event delivered on the subscription, stamped with the
  /// emitting session's id AND the receiving subscriber's visit
  /// generation (`session.SessionEvent`). Both are the filter: the subject
  /// is shared by every session this connection visits, and `Leave`
  /// cannot stop broadcasts already in the mailbox when it lands (nor a
  /// replay sliced mid-flight by a fast double switch). The id drops
  /// deliveries from other sessions; the generation drops deliveries left
  /// over from an EARLIER visit to the same session (rapid A→B→A).
  /// Without these, a session that kept streaming after being switched
  /// away from rendered its tokens into the OTHER session's view.
  /// `MetaUpdated` deliberately passes the filter: sidebar metadata is
  /// global.
  SessionScoped(session_id: String, visit: Int, event: Msg)
  // ---- Providers (P5: management + provider-scoped picker) ----
  /// Masked metadata for every provider (Settings page + picker).
  ProvidersLoaded(List(Provider))
  ProvidersFailed(String)
  /// The create panel's provider select changed: aliases reload scoped
  /// to the new provider (multi-provider §12).
  ProviderPicked(id: String)
  /// The header button toggled between the chat and Settings views.
  SettingsToggled
  /// A message for the Settings sub-component (`nexus/ui_settings`),
  /// lifted into this app: `update` delegates to `ui_settings.update`
  /// and folds the returned signals back into this model.
  Settings(ui_settings.Msg)
  AliasesLoaded(provider: String, aliases: List(String))
  AliasesFailed
  SessionsLoaded(List(session.SessionSummary))
  SessionsFailed(String)
  Select(String)
  NewSessionToggled
  PickerChanged(String)
  CreateRequested
  Created(session.SessionSummary)
  CreateFailed(String)
  // The composer is uncontrolled: its text rides the event itself (the
  // keydown's `target.value` for Enter, `detail.formData` for submits).
  SendRequested(String)
  SendAccepted
  SendRejected(String)
  StopRequested
  Hello(model: String)
  /// A committed user line. `at` is its display stamp — wall-clock epoch
  /// seconds from the session's echo (live and replay carry the same
  /// value); None = unstamped legacy history, rendered without a time.
  UserEcho(String, Option(Int))
  /// A committed assistant line, replayed from history (or seen by a
  /// second tab). `at` mirrors UserEcho's display stamp.
  AssistantFull(String, Option(Int))
  /// A committed assistant message's reasoning, replayed with history
  /// (always just before that message's own events).
  ReasoningFull(String)
  Token(String)
  /// A streamed fragment of the model's reasoning (chain of thought).
  Reasoning(String)
  /// The turn's terminal state. `at` is the committed turn's final
  /// assistant-text stamp from the session actor (`transcript
  /// .last_text_stamp` — the SAME value a post-reload replay attaches to
  /// that message), so the live bubble commit renders the same absolute
  /// timestamp as replay; None = nothing committed (or unstamped legacy).
  TurnDone(Option(Int))
  TurnStopped(Option(Int))
  TurnFailed(String, Option(Int))
  /// The session's organizational metadata changed server-side (the
  /// model-generated title upgrade landed). Refreshes the session list so
  /// EVERY connected tab's sidebar updates — not just the client that
  /// happens to be mid-turn.
  MetaUpdated(title: Option(String), tags: List(String))
  // M3 tool events: translated 1:1 so the replay/live pipelines carry them;
  // rendering lands with the M3 UI workstream. No-ops in `update` for now.
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    fragment: String,
  )
  /// A tool call fully assembled (about to execute). `at` is the flushed
  /// round's committed stamp from the loop: the wall-clock epoch the
  /// round's assistant message (and the text the UI committed at
  /// first-fragment time) was appended at — the authoritative value for
  /// the pending-flush restamp. None = legacy replay (nothing to stamp).
  ToolCallAssembled(
    id: String,
    name: String,
    arguments: String,
    at: Option(Int),
  )
  ToolResult(id: String, name: String, ok: Bool, content: String)
  LoopStatus(iteration: Int, max_iterations: Int, phase: String)
  /// A chip's "view" control was clicked: open the full-call popup for
  /// that call (see `Pop`). Pure display state — the popup re-resolves
  /// the call from the log/pending lists on every render, so it live-
  /// updates while the call streams and vanishes if the turn rolls back.
  ToolViewOpened(Pop)
  /// The popup's close control was clicked.
  ToolViewClosed
  // ---- Session organization ----
  /// The filter input while typing (uncontrolled: text rides the event).
  TagFilterChanged(String)
  /// Programmatic filter set (tag-chip click, clear button): stores the
  /// text AND rotates the keyed input so it is re-created with the value.
  TagFilterSet(String)
  ArchivedToggled
  RenameToggled(id: String)
  RenameRequested(id: String, text: String)
  TagsToggled(id: String)
  TagsEdited(id: String, raw: String)
  PinToggled(id: String)
  Archived(id: String, archived: Bool)
  DeleteRequested(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  /// A registry mutation failed (session vanished mid-edit); surfaces a
  /// note in the log instead of failing silently.
  SessionOpFailed(String)
}

/// Translate a `session.EventKind` into a typed component message.
/// Session events arrive on the subject selected in `init` and flow through
/// the same `update` as DOM events. The emitting session's id rides the
/// `session.SessionEvent` envelope and is handled by `SessionScoped` —
/// this function sees only the payload.
pub fn from_session_event(event: session.EventKind) -> Msg {
  case event {
    session.Hello(model, _messages, _metrics) -> Hello(model)
    session.UserEcho(text, at) -> UserEcho(text, at)
    session.AssistantFull(text, at) -> AssistantFull(text, at)
    session.ReasoningFull(text) -> ReasoningFull(text)
    session.Token(text) -> Token(text)
    session.Reasoning(text) -> Reasoning(text)
    session.TurnDone(_stats, at) -> TurnDone(at)
    session.TurnStopped(_chars, at) -> TurnStopped(at)
    session.TurnFailed(reason, at) -> TurnFailed(reason, at)
    session.MetaUpdated(title, tags) -> MetaUpdated(title, tags)
    session.ToolCallDelta(index, id, name, fragment) ->
      ToolCallDelta(index, id, name, fragment)
    session.ToolCallAssembled(id, name, arguments, at) ->
      ToolCallAssembled(id, name, arguments, at)
    session.ToolResult(id, name, ok, content) ->
      ToolResult(id, name, ok, content)
    session.LoopStatus(iteration, max, phase) ->
      LoopStatus(iteration, max, phase)
  }
}

// ---------------------------------------------------------------------------
// Init / update
// ---------------------------------------------------------------------------

pub fn init(flags: Flags) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      providers: flags.providers,
      registry: flags.registry,
      events: None,
      provider: None,
      provider_list: [],
      view: ChatView,
      settings: ui_settings.init(),
      settings_manual: False,
      providers_seen: False,
      suppress_autoselect: False,
      aliases: [],
      sessions: [],
      // A reload re-opens the client's last-selected session: the page
      // shell persists it and supplies it on the /ws route. If it has since
      // vanished, `after_sessions` drops it and the auto-selection rules
      // take over — same as any stale selection.
      selected: flags.session,
      visit: 0,
      // The text the delta arm committed ahead of the worker's append
      // (see the ToolCallDelta arm): its authoritative stamp arrives on
      // the round's ToolCallAssembled and restamps the line.
      flushed: [],
      picker: "",
      create_open: False,
      log: [],
      bubble: None,
      bubble_hidden: True,
      thinking: None,
      streaming: False,
      pending: [],
      loop: None,
      guard: False,
      turn_base: 0,
      composer: 0,
      create_auto: False,
      model_label: "connecting…",
      tag_filter: "",
      filter_gen: 0,
      show_archived: False,
      rename_open: None,
      tags_open: None,
      confirm_delete: None,
      pop: None,
      md_cache: dict.new(),
    )
  #(model, events_effect())
}

/// Create the long-lived session-event subscription. The fresh subject is
/// stored in the model via `GotEvents`; the registry/session lookups then
/// happen in ordinary effects.
fn events_effect() -> Effect(Msg) {
  server_component.select(fn(dispatch, subject: Subject(SessionEvent)) {
    dispatch(GotEvents(subject))
    process.new_selector()
    |> process.select_map(subject, fn(delivery) {
      let session.SessionEvent(session_id, visit, kind) = delivery
      SessionScoped(session_id, visit, from_session_event(kind))
    })
  })
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Ignored -> #(model, effect.none())

    // Per-session delivery filter — see the `SessionScoped` msg. One level
    // of recursion applies (or drops) the inner event.
    SessionScoped(session_id, visit, event) ->
      case model.selected {
        Some(selected) if selected == session_id && model.visit == visit ->
          update(model, event)
        _ ->
          case event {
            // Sidebar metadata is global by design: a title upgrade lands
            // while some OTHER client is mid-turn, and every connected
            // tab's sidebar must refresh. Applied wherever it lands.
            MetaUpdated(_, _) -> update(model, event)
            _ -> #(model, effect.none())
          }
      }

    GotEvents(subject) -> {
      // The connect point of a per-client runtime: the subscription
      // subject exists, so load everything (and re-Join the client's
      // session — Hello + replay is idempotent). This is the old
      // ClientConnected arm minus the stale-view clearing a fresh model
      // makes unnecessary.
      //
      // No alias load fires here: the fresh model has no provider
      // selection yet (that is what `ProvidersLoaded` establishes), so
      // "no provider selected" means NOT LOADED, not "none exist" —
      // the connect-time alias effect that used to run here read it as
      // the latter and logged a bogus "no provider configured" note on
      // every fresh connection. Alias loads key off the provider load:
      // the first `ProvidersLoaded` re-aims the picker (None → some
      // enabled row) and fetches that row's models, so a transient
      // registry/model-list failure still refreshes on every reconnect.
      let model = Model(..model, events: Some(subject), visit: model.visit + 1)
      let eff = case model.selected {
        Some(id) ->
          effect.batch([
            join_effect(model, id),
            // Provider metadata refreshes here: the load re-aims the
            // picker and pulls the selected provider's models with it.
            providers_effect(model),
            sessions_effect(model),
          ])
        None ->
          effect.batch([
            providers_effect(model),
            sessions_effect(model),
          ])
      }
      #(model, eff)
    }

    // ---- Providers: list + picker (P5; CRUD lives in ui_settings) ----
    ProvidersLoaded(providers) -> {
      // Keep the picker aimed at a provider that still exists and is
      // still enabled; fall back to the first enabled row otherwise.
      let previous = model.provider
      let selected = pick_provider(providers, previous)
      let changed = selected != previous
      let model =
        Model(
          ..model,
          provider_list: providers,
          provider: selected,
          // The old provider's models must not survive a selection
          // change (the ProviderPicked rule): Create stays disabled
          // until the replacement provider's list lands, so a stale
          // alias can never be pinned to a provider it did not come
          // from — and no options render when none remains.
          aliases: case changed {
            True -> []
            False -> model.aliases
          },
          picker: case changed {
            True -> ""
            False -> model.picker
          },
        )
      let eff = case selected, changed {
        Some(id), True -> aliases_for(model, id)
        _, _ -> effect.none()
      }
      // A load that concludes there is no enabled provider notes the
      // chat log — only here, where "none exist" is actually known
      // (the picker placeholder carries the same message in the create
      // panel, and the first-load auto-open rule puts the user on the
      // Settings page). The note fires on the connection's first load
      // and on the TRANSITION from an enabled provider to none — never
      // per refresh, so ordinary Settings reloads while nothing is
      // enabled cannot stack duplicates in the log (the auto-open
      // rule's `providers_seen` idiom). The clearing the old
      // `NoProviders` message did is already covered above: `selected`
      // is None and a changed selection wiped `aliases`/`picker`.
      let model = case selected, model.providers_seen, previous {
        None, False, _ ->
          Model(..model, log: [
            NoteLine(True, "no provider configured — add one in Settings"),
            ..model.log
          ])
        None, True, Some(_) ->
          Model(..model, log: [
            NoteLine(True, "no provider configured — add one in Settings"),
            ..model.log
          ])
        _, _, _ -> model
      }
      // First run: the connection's FIRST provider load arriving empty
      // auto-opens the Settings view (the guided path the always-visible
      // sidebar panel used to provide) — unless the user toggled the
      // view by hand. Later loads never re-open it (a list that becomes
      // empty mid-session must not hijack the chat view).
      let model = case providers, model.providers_seen, model.settings_manual {
        [], False, False -> Model(..model, view: SettingsView)
        _, _, _ -> model
      }
      let model = Model(..model, providers_seen: True)
      #(model, eff)
    }

    ProvidersFailed(reason) -> #(
      Model(..model, log: [
        NoteLine(True, "could not load providers: " <> reason),
        ..model.log
      ]),
      effect.none(),
    )

    ProviderPicked(id) ->
      case model.provider {
        Some(current) if current == id -> #(model, effect.none())
        _ -> #(
          // Stale aliases must not survive a provider switch: the picker
          // empties until the new provider's list lands (Create is
          // disabled while it is), and never offers another provider's
          // models as the pin for a new session.
          Model(..model, provider: Some(id), aliases: [], picker: ""),
          aliases_for(model, id),
        )
      }

    SettingsToggled -> #(
      // Manual toggle, both directions: it also latches `settings_manual`,
      // which stops the first-run auto-open rule from re-opening the
      // settings page on every empty-list refresh (mirroring the
      // `create_auto` latch for the create panel).
      Model(
        ..model,
        view: case model.view {
          ChatView -> SettingsView
          SettingsView -> ChatView
        },
        settings_manual: True,
      ),
      effect.none(),
    )

    Settings(msg) -> {
      // The lifted Settings sub-component: delegate, then fold its
      // signals (picker re-aim / list reload / log note) into this
      // model. The sub-effect rides along mapped back into `Settings`.
      let #(settings, inner_eff, signals) =
        ui_settings.update(model.settings, msg, model.providers)
      let #(model, signal_effs) =
        list.fold(
          signals,
          #(Model(..model, settings: settings), []),
          fn(acc, signal) {
            let #(model, effs) = acc
            case signal {
              ui_settings.ProviderCreated(provider) -> {
                // First-run flow: with nothing selected, the freshly
                // created (enabled) provider becomes the picker's target
                // at once — and creating the FIRST provider returns the
                // view to chat (the auto-opened settings page has served
                // its purpose; a deliberate settings visit stays put).
                let model = case model.provider {
                  None -> Model(..model, provider: Some(provider.id))
                  Some(_) -> model
                }
                let model = case model.provider_list {
                  [] -> Model(..model, view: ChatView)
                  _ -> model
                }
                let eff = case model.provider, provider.id {
                  Some(current), created if current == created ->
                    aliases_for(model, provider.id)
                  _, _ -> effect.none()
                }
                #(model, [eff, ..effs])
              }
              ui_settings.ProvidersChanged -> #(model, [
                providers_effect(model),
                ..effs
              ])
              ui_settings.OpFailed(reason) -> #(
                Model(..model, log: [
                  // Operation-neutral: this path carries create, edit,
                  // disable, and delete failures alike (e.g. the
                  // pinned-delete 409 guard).
                  NoteLine(True, "provider operation failed: " <> reason),
                  ..model.log
                ]),
                effs,
              )
            }
          },
        )
      #(model, effect.batch([effect.map(inner_eff, Settings), ..signal_effs]))
    }

    AliasesLoaded(provider, aliases) -> #(
      Model(
        ..model,
        provider: Some(provider),
        aliases: aliases,
        picker: first_alias(model, aliases),
      ),
      effect.none(),
    )

    AliasesFailed -> #(
      Model(..model, log: [
        NoteLine(True, "could not load model aliases"),
        ..model.log
      ]),
      effect.none(),
    )

    SessionsLoaded(summaries) -> {
      let next = after_sessions(model, summaries)
      // A fresh per-client model can see Hello (replay) before the
      // summaries land: Hello then found an empty session list and
      // reported `streaming: False`. Reconcile from the authoritative
      // summary when the selection is unchanged, so the composer shows
      // the true busy state instead of accepting a send that the session
      // will reject with "busy".
      let next = case next.selected, model.selected {
        Some(id), Some(previous) if id == previous ->
          case list.find(summaries, fn(s) { s.id == id }) {
            Ok(summary) -> Model(..next, streaming: summary.streaming)
            Error(_) -> next
          }
        _, _ -> next
      }
      // The selection changed under us (boot auto-selection, or the
      // previous one vanished): a NEW visit — bump the generation so any
      // stale deliveries cannot ride along. A vanished session fails the
      // registry lookup harmlessly. The bump lands on the RETURNED model:
      // the join fires carrying `next.visit`, and a delivery only applies
      // when the model's generation matches — a bump that lives only in
      // the effect leaves the model one generation behind, deaf to the
      // whole replay (the blank-chat-on-boot regression from #58).
      let #(next, eff) = case next.selected, model.selected {
        Some(id), Some(prev) if prev == id -> #(next, effect.none())
        Some(id), Some(prev) -> {
          let next = Model(..next, visit: next.visit + 1)
          #(
            next,
            effect.batch([
              leave_effect(next, prev),
              join_effect(next, id),
            ]),
          )
        }
        Some(id), None -> {
          let next = Model(..next, visit: next.visit + 1)
          #(next, join_effect(next, id))
        }
        None, _ -> #(next, effect.none())
      }
      #(next, eff)
    }

    SessionsFailed(reason) -> #(
      Model(..model, log: [
        NoteLine(True, "could not load sessions: " <> reason),
        ..model.log
      ]),
      effect.none(),
    )

    Select(id) ->
      case model.selected {
        Some(current) if current == id -> #(model, effect.none())
        _ -> {
          // A new visit: the view resets AND the generation bumps, so the
          // old session's stale deliveries (and any leftovers from an
          // earlier visit to THIS session) cannot render after the reset.
          let next =
            Model(
              ..model,
              selected: Some(id),
              visit: model.visit + 1,
              log: [],
              flushed: [],
              bubble: None,
              bubble_hidden: True,
              thinking: None,
              streaming: False,
              pending: [],
              loop: None,
              guard: False,
              turn_base: 0,
              model_label: "connecting…",
              // The popup belongs to the previous session's log; its
              // ids cannot resolve against the new selection's.
              pop: None,
              // An explicit pick re-arms the refresh auto-selection
              // window (see `suppress_autoselect`).
              suppress_autoselect: False,
            )
          let eff = case model.selected {
            Some(current) ->
              effect.batch([
                leave_effect(model, current),
                join_effect(next, id),
              ])
            None -> join_effect(next, id)
          }
          #(next, eff)
        }
      }

    NewSessionToggled -> {
      let model =
        Model(..model, create_open: !model.create_open, create_auto: False)
      // Opening the create panel enters the deliberate no-selection state:
      // the chat pane goes blank so the user composes a new session
      // against nothing, and a later refresh must not auto-select a
      // replacement (see `deselect`). Closing it just closes the panel —
      // the no-selection state stays until a row is picked. The button can
      // also be clicked BEFORE the first session list arrives (the sidebar
      // renders immediately on a fresh connection): the deliberate mark
      // must land then too, or the arriving list auto-selects right over
      // the open panel.
      case model.create_open, model.selected {
        True, Some(current) -> {
          let next = deselect(model, "no session selected")
          #(next, leave_effect(model, current))
        }
        True, None -> {
          let next = Model(..model, suppress_autoselect: True)
          #(next, effect.none())
        }
        _, _ -> #(model, effect.none())
      }
    }

    PickerChanged(alias) -> #(Model(..model, picker: alias), effect.none())

    CreateRequested ->
      case model.picker {
        "" -> #(model, effect.none())
        alias -> #(model, create_effect(model, alias))
      }

    Created(summary) -> {
      let model =
        Model(
          ..model,
          sessions: [summary, ..model.sessions],
          create_open: False,
        )
      update(model, Select(summary.id))
    }

    CreateFailed(reason) -> #(
      Model(..model, log: [
        NoteLine(True, "could not create session: " <> reason),
        ..model.log
      ]),
      effect.none(),
    )

    SendRequested(text) -> {
      let text = string.trim(text)
      case text, model.streaming, model.selected {
        "", _, _ -> #(model, effect.none())
        _, True, _ -> #(model, effect.none())
        _, _, None -> #(model, effect.none())
        text, False, Some(_) -> #(model, send_effect(model, text))
      }
    }

    // Rotate the keyed composer so the client replaces the textarea with a
    // fresh, empty one (and re-focuses it via its autofocus attribute).
    SendAccepted -> #(
      Model(..model, composer: model.composer + 1, streaming: True),
      effect.none(),
    )

    SendRejected(reason) -> {
      let note = case reason {
        "busy" -> "a reply is already streaming — stop it first"
        "gone" -> "session ended"
        other -> "send failed: " <> other
      }
      #(Model(..model, log: [NoteLine(True, note), ..model.log]), effect.none())
    }

    StopRequested -> #(model, stop_effect(model))

    Hello(name) -> #(
      Model(..model, model_label: name, streaming: case model.selected {
        Some(id) ->
          case list.find(model.sessions, fn(s) { s.id == id }) {
            Ok(summary) -> summary.streaming
            Error(_) -> False
          }
        None -> False
      }),
      effect.none(),
    )

    UserEcho(text, at) -> #(
      Model(
        ..model,
        log: [UserLine(text, at), ..model.log],
        // The user message marks the start of a (possibly live) turn: lines
          // beyond this point belong to it and roll back on a failed turn.
          turn_base: list.length(model.log) + 1,
        // A new turn is beginning: drop any open popup. Call ids are only
        // unique WITHIN a turn (providers may omit ids, and the loop's
        // fallback `call_<index>` restarts at 0 every turn), so a popup
        // left open across turns could silently switch to the new turn's
        // same-named call. The user can re-click the chip.
        pop: None,
      ),
      effect.none(),
    )

    // A committed assistant turn replayed from history (or seen by a
    // second tab). Text that renders to nothing under markdown — a model's
    // bare leading/trailing newlines beside tool calls is the live case —
    // is skipped wholesale: an AssistantLine for it would be an empty
    // tinted pill, and the live commit path skips the same shapes, so
    // replay and live display stay identical.
    AssistantFull(text, at) -> {
      let elements = markdown.render(text)
      case elements {
        [] -> #(model, effect.none())
        _ -> #(
          Model(
            ..model,
            log: [AssistantLine(text, at), ..model.log],
            md_cache: dict.insert(model.md_cache, text, elements),
          ),
          effect.none(),
        )
      }
    }

    ReasoningFull(text) -> #(
      Model(..model, log: [ReasoningLine(text), ..model.log]),
      effect.none(),
    )

    // Reasoning streams ahead of the content bubble and accumulates in
    // its own buffer — the display twin of the loop's reasoning cell.
    Reasoning(text) -> {
      let thinking = case model.thinking {
        Some(acc) -> Some(acc <> text)
        None -> Some(text)
      }
      #(Model(..model, thinking: thinking, streaming: True), effect.none())
    }

    // The first content token ends the reasoning phase: commit the
    // thinking buffer as a line (pushed BEFORE the bubble's own eventual
    // commit, so it renders above the text it preceded).
    Token(text) -> {
      let model = commit_thinking(model)
      let bubble = case model.bubble {
        Some(acc) -> Some(acc <> text)
        None -> Some(text)
      }
      // The live bubble's visibility uses the SAME render-empty decision
      // the commit and replay paths apply — a cheaper whitespace check
      // would show trim-nonempty text (a lone footnote definition, say)
      // that vanishes at commit. Decided here, when the bubble changes,
      // so the per-token view render never reparses the accumulated
      // text; once visible it stays visible, so the parse only runs
      // while the bubble is still render-empty.
      let bubble_hidden = case model.bubble_hidden {
        False -> False
        True -> markdown.render(option.unwrap(bubble, "")) == []
      }
      #(
        Model(
          ..model,
          bubble: bubble,
          bubble_hidden: bubble_hidden,
          streaming: True,
        ),
        effect.none(),
      )
    }

    TurnDone(at) -> #(
      finish_turn(model, CommitBubble(at)),
      sessions_effect(model),
    )

    TurnStopped(at) -> #(
      finish_turn(model, CommitBubble(at)),
      sessions_effect(model),
    )

    // Server-side metadata change (title upgrade): the payload is display
    // metadata — the refresh re-reads the whole list from the registry, so
    // every subscribed tab's sidebar re-renders with the new title. Titles
    // render as text nodes, so hostile model output stays inert.
    MetaUpdated(_title, _tags) -> #(model, sessions_effect(model))

    // A tool call's arguments are streaming in fragments. Any assistant
    // text seen so far belongs *before* the call (the loop commits text at
    // assembly time), so the bubble is committed first; the fragments then
    // accumulate into a pending card keyed by the chunk index. The
    // thinking buffer defers to the assembly commit unless text already
    // commits it: on a stop the loop commits only non-empty text (with
    // its reasoning), so with no text yet an early commit here would
    // orphan the reasoning line after a stop.
    ToolCallDelta(index, id, name, fragment) -> {
      // Commit the bubble with NO timestamp yet: the worker has not
      // appended (and stamped) the round's message at fragment time — its
      // instant does not exist. The authoritative stamp arrives on the
      // round's `ToolCallAssembled` and restamps this line (see `flushed`);
      // a Stop landing first restamps via the terminal event instead. No
      // UI clock read anywhere.
      let model = case model.bubble {
        Some(text) ->
          Model(..model, flushed: [text, ..model.flushed])
          |> commit_thinking
          |> commit_bubble(None)
        None -> model
      }
      let pending =
        upsert_pending(model.pending, PendingCall(index, id, name, fragment))
      #(Model(..model, pending: pending, streaming: True), effect.none())
    }

    // The call is assembled and about to execute: drop its pending card
    // (and any sibling fragments — the "tools" phase boundary clears the
    // rest), then commit a running card for the stable id.
    ToolCallAssembled(id, name, arguments, at) -> {
      // The loop's flush stamp has arrived: first restamp the line the
      // delta arm committed ahead of the append (matching by text — the
      // exact string this connection committed — so a legacy unstamped
      // line can never be hit), then commit anything still in the bubble
      // (the empty-arguments case: no fragments ever fired, so this is
      // its first commit) with the stamp directly.
      let model =
        Model(
          ..model,
          flushed: [],
          log: restamp_flushed(model.log, model.flushed, at),
        )
      let model = model |> commit_thinking |> commit_bubble(at)
      let pending = drop_pending(model.pending, id, name)
      // If the popup was open on the call that just assembled, its
      // resolution source (the pending entry) is about to disappear:
      // migrate the selection to the stable id so the popup stays live
      // through execution and completion. Same id-or-name match as
      // drop_pending above.
      let pop = case model.pop {
        Some(PendingPop(index)) ->
          case
            list.find(model.pending, fn(call) {
              call.id == Some(id) || call.name == Some(name)
            })
          {
            Ok(assembled) if assembled.index == index -> Some(CallPop(id))
            _ -> model.pop
          }
        _ -> model.pop
      }
      #(
        Model(..model, pending: pending, pop: pop, log: [
          ToolLine(id, name, arguments, ToolRunning, None),
          ..model.log
        ]),
        effect.none(),
      )
    }

    // The tool finished: attach the compact result preview to the matching
    // card (live or replayed). An unmatched result becomes a completed card
    // of its own — replay guarantees ordering, this is just belt and braces.
    ToolResult(id, name, ok, content) -> {
      let line = ToolLine(id, name, "", ToolDone(ok), Some(content))
      let log = attach_result(model.log, id, line)
      #(Model(..model, log: log), effect.none())
    }

    // Iteration status drives the chip above the composer. The "tools"
    // phase boundary is also when leftover pending fragments are stale.
    LoopStatus(iteration, max, phase) -> {
      let pending = case phase {
        "tools" -> []
        _ -> model.pending
      }
      let guard = case phase {
        "guard" -> True
        _ -> model.guard
      }
      #(
        Model(
          ..model,
          pending: pending,
          guard: guard,
          loop: Some(LoopState(iteration, max, phase)),
        ),
        effect.none(),
      )
    }

    ToolViewOpened(pop) -> #(Model(..model, pop: Some(pop)), effect.none())

    ToolViewClosed -> #(Model(..model, pop: None), effect.none())

    // Terminal failures: how much of the turn survives depends on what the
    // server committed. After the guard tripped, the final partial text and
    // all completed tool rounds ARE committed (only the trailing,
    // never-run call is dropped); any other failure commits nothing, so the
    // whole turn's display rolls back to the user line and the partial
    // bubble is discarded.
    TurnFailed(reason, at) -> {
      let model = case model.guard {
        // The guard committed: the surviving bubble carries the session's
        // own stamp, exactly as a replay of that transcript will.
        True -> commit_turn_output(settle_flushed(model, at), at)
        False ->
          // Nothing committed — the whole turn's display rolls back, so
          // the pending flush goes with it (unrestamped, like its line).
          Model(
            ..settle_flushed(model, None),
            log: rollback_log(model.log, model.turn_base),
            bubble: None,
            bubble_hidden: True,
            thinking: None,
            // Nothing committed — any popup on this turn's calls now
            // points at rolled-back lines; drop it with the rest.
            pop: None,
          )
      }
      #(
        Model(
          ..model,
          pending: [],
          loop: None,
          guard: False,
          streaming: False,
          log: [NoteLine(True, "turn failed: " <> reason), ..model.log],
        ),
        sessions_effect(model),
      )
    }

    // ---- Session organization (registry metadata mutations) ----
    TagFilterChanged(text) -> #(Model(..model, tag_filter: text), effect.none())

    TagFilterSet(text) -> #(
      Model(..model, tag_filter: text, filter_gen: model.filter_gen + 1),
      effect.none(),
    )

    ArchivedToggled -> #(
      Model(..model, show_archived: !model.show_archived),
      effect.none(),
    )

    RenameToggled(id) -> #(
      Model(
        ..model,
        rename_open: ui_settings.toggle_open(model.rename_open, id),
        tags_open: None,
        confirm_delete: None,
      ),
      effect.none(),
    )

    RenameRequested(id, text) -> {
      // Close the editor regardless; an empty rename is a no-op.
      let model = Model(..model, rename_open: None)
      case string.trim(text) {
        "" -> #(model, effect.none())
        title -> #(
          model,
          mutate_effect(model, fn(registry) {
            session_registry.set_title(registry, id, title)
          }),
        )
      }
    }

    TagsToggled(id) -> #(
      Model(
        ..model,
        tags_open: ui_settings.toggle_open(model.tags_open, id),
        rename_open: None,
        confirm_delete: None,
      ),
      effect.none(),
    )

    TagsEdited(id, raw) -> #(
      Model(..model, tags_open: None),
      mutate_effect(model, fn(registry) {
        session_registry.set_tags(registry, id, parse_tags(raw))
      }),
    )

    PinToggled(id) -> {
      let pinned = case summary_by_id(model, id) {
        Ok(summary) -> summary.pinned
        Error(_) -> False
      }
      #(
        model,
        mutate_effect(model, fn(registry) {
          session_registry.set_pinned(registry, id, !pinned)
        }),
      )
    }

    Archived(id, archived) -> {
      // Archiving the OPEN session ends the visit: the selection clears
      // (the row is soft-hidden, so a kept selection would highlight
      // nothing while the chat pane keeps showing the archived content —
      // the ghost-selection bug), the pane goes blank, and the refresh
      // that the registry write triggers must not auto-select a
      // replacement (see `deselect`). Archiving any OTHER session — or
      // restoring — leaves the selection alone.
      case archived, model.selected {
        True, Some(current) if current == id -> {
          let next = deselect(model, "no session selected")
          #(
            next,
            effect.batch([
              leave_effect(model, current),
              mutate_effect(next, fn(registry) {
                session_registry.set_archived(registry, id, archived)
              }),
            ]),
          )
        }
        _, _ -> #(
          model,
          mutate_effect(model, fn(registry) {
            session_registry.set_archived(registry, id, archived)
          }),
        )
      }
    }

    DeleteRequested(id) -> #(
      Model(
        ..model,
        confirm_delete: Some(id),
        rename_open: None,
        tags_open: None,
      ),
      effect.none(),
    )

    DeleteCancelled -> #(Model(..model, confirm_delete: None), effect.none())

    DeleteConfirmed(id) -> #(
      Model(..model, confirm_delete: None),
      mutate_effect(model, fn(registry) {
        session_registry.delete_session(registry, id)
      }),
    )

    SessionOpFailed(reason) -> #(
      Model(..model, log: [
        NoteLine(True, "session update failed: " <> reason),
        ..model.log
      ]),
      effect.none(),
    )
  }
}

fn summary_by_id(
  model: Model,
  id: String,
) -> Result(session.SessionSummary, Nil) {
  list.find(model.sessions, fn(summary) { summary.id == id })
}

/// Comma-separated editor input → the tag list handed to the registry
/// (trimmed, empties dropped, de-duplicated — the same rules the registry
/// re-applies on write).
pub fn parse_tags(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(tag) { tag != "" })
  |> list.unique
}

/// Case-insensitive free-text match over a session's title and tags. The
/// empty filter matches everything.
pub fn matches_filter(summary: session.SessionSummary, filter: String) -> Bool {
  case string.trim(filter) {
    "" -> True
    query -> {
      let needle = string.lowercase(query)
      string.contains(string.lowercase(summary.title), needle)
      || list.any(summary.tags, fn(tag) {
        string.contains(string.lowercase(tag), needle)
      })
    }
  }
}

/// How a terminal event treats the streaming bubble. `CommitBubble(at)`
/// carries the committed turn's stamp from the terminal event — the
/// session's own clock (`transcript.last_text_stamp`, read by the actor
/// off the committed transcript), never a second UI-side read.
type BubblePolicy {
  CommitBubble(at: Option(Int))
  DropBubble
}

/// Terminal turn handling: commit or drop the streamed bubble, fold away
/// per-turn tool state, and stop streaming. Tool cards already in the log
/// stay (completed rounds are committed server-side on done/stopped/guard).
fn finish_turn(model: Model, policy: BubblePolicy) -> Model {
  let model = case policy {
    CommitBubble(at) ->
      // A Stop (or guard) can land between the delta-time flush commit
      // and its round's assembly: the terminal stamp is the committed
      // transcript's (`last_text_stamp` — the loop commits the partial
      // text on stop), so restamp the pending line with it before the
      // bubble commit (which is a no-op when the delta arm already
      // consumed it).
      // settle_flushed is a no-op without a pending flush, so one call
      // covers both cases.
      commit_turn_output(settle_flushed(model, at), at)
    DropBubble ->
      Model(
        ..settle_flushed(model, None),
        bubble: None,
        bubble_hidden: True,
        thinking: None,
      )
  }
  Model(..model, pending: [], loop: None, guard: False, streaming: False)
}

/// Settle a pending delta-time flush: give the line the delta arm
/// committed ahead of the worker's append its authoritative stamp (`at` —
/// None on a rollback, where the line is about to be dropped anyway) and
/// clear the pending marker. No-op without a pending flush.
fn settle_flushed(model: Model, at: Option(Int)) -> Model {
  case model.flushed {
    [] -> model
    texts ->
      Model(..model, flushed: [], log: restamp_flushed(model.log, texts, at))
  }
}

/// Restamp every pending flush text (see the `flushed` field) with `at`.
/// Matching is by the exact committed text — it cannot hit a legacy
/// unstamped line, and within one session rounds are serial, so the
/// first (newest) match per text is the right line. A text that is
/// already restamped (or absent — replay, where no delta-time commit
/// happens) is a no-op.
fn restamp_flushed(
  log: List(Line),
  texts: List(String),
  at: Option(Int),
) -> List(Line) {
  case texts {
    [] -> log
    [text, ..rest] -> restamp_flushed(restamp_one(log, text, at), rest, at)
  }
}

/// The single-text worker of `restamp_flushed`.
fn restamp_one(log: List(Line), text: String, at: Option(Int)) -> List(Line) {
  case log {
    [] -> []
    [line, ..rest] ->
      case line {
        AssistantLine(t, None) ->
          case t == text {
            True -> [AssistantLine(t, at), ..rest]
            False -> [line, ..restamp_one(rest, text, at)]
          }
        other -> [other, ..restamp_one(rest, text, at)]
      }
  }
}

/// Commit one finished turn's visible output, mirroring the loop's own
/// commit rule: reasoning commits only alongside the assistant output it
/// preceded. A turn that produced reasoning but no text/tool output
/// commits NOTHING server-side, so the thinking buffer is dropped here
/// too — display state must mirror the server's transcript exactly.
fn commit_turn_output(model: Model, at: Option(Int)) -> Model {
  case model.bubble {
    Some(_text) -> model |> commit_thinking |> commit_bubble(at)
    None -> Model(..model, thinking: None)
  }
}

/// Commit the streaming bubble (if any) as a completed assistant line —
/// matching the session's own commit rules. Text that renders to nothing
/// under markdown (whitespace-only fragments this model streams beside
/// tool calls) commits nothing visible — the transcript keeps it, and a
/// replay skips it through the same render — so no empty pill appears and
/// live display matches the post-reload rebuild.
fn commit_bubble(model: Model, at: Option(Int)) -> Model {
  case model.bubble {
    Some(text) -> {
      let elements = markdown.render(text)
      case elements {
        [] -> Model(..model, bubble: None, bubble_hidden: True)
        _ ->
          Model(
            ..model,
            bubble: None,
            bubble_hidden: True,
            // `at` rode the terminal event from the actor: the stamp of
            // the committed turn's final assistant-text message, read off
            // the transcript sidecar — the exact value a post-reload
            // replay attaches to that message's AssistantFull. One clock
            // end to end; the UI never stamps from its own read. None =
            // unstamped (legacy), rendering without a timestamp — same
            // as the replay it mirrors.
            log: [AssistantLine(text, at), ..model.log],
            md_cache: dict.insert(model.md_cache, text, elements),
          )
      }
    }
    None -> model
  }
}

/// Commit the streaming thinking buffer (if any) as a reasoning line.
/// Pushed BEFORE whatever assistant line follows it in the same turn, so
/// in the rendered (oldest-first) log it sits above its own message.
fn commit_thinking(model: Model) -> Model {
  case model.thinking {
    Some(text) ->
      Model(..model, thinking: None, log: [ReasoningLine(text), ..model.log])
    None -> model
  }
}

/// Restore the log to its state at turn start: entries added during the
/// turn sit at the head of the newest-first list, so keep the oldest
/// `turn_base` entries (the tail).
fn rollback_log(log: List(Line), turn_base: Int) -> List(Line) {
  let extra = list.length(log) - turn_base
  case extra > 0 {
    True -> list.drop(log, extra)
    False -> log
  }
}

/// Insert or update a pending call, keeping ascending chunk-index order so
/// parallel calls render in the order the model issued them.
fn upsert_pending(
  pending: List(PendingCall),
  delta: PendingCall,
) -> List(PendingCall) {
  let updated =
    list.map(pending, fn(call: PendingCall) {
      case call.index == delta.index {
        False -> call
        True ->
          PendingCall(
            index: call.index,
            id: case delta.id {
              Some(id) -> Some(id)
              None -> call.id
            },
            name: case delta.name {
              Some(name) -> Some(name)
              None -> call.name
            },
            args: call.args <> delta.args,
          )
      }
    })
  case list.any(updated, fn(call: PendingCall) { call.index == delta.index }) {
    True -> updated
    False ->
      list.sort([delta, ..updated], fn(a: PendingCall, b: PendingCall) {
        int.compare(a.index, b.index)
      })
  }
}

/// Drop the pending card that an assembled call supersedes: by id when the
/// fragments carried one, else by name. Assembly ends the iteration that
/// produced the fragments, so any still-unmatched siblings go too.
fn drop_pending(
  pending: List(PendingCall),
  id: String,
  name: String,
) -> List(PendingCall) {
  list.filter(pending, fn(call: PendingCall) {
    call.id != Some(id) && call.name != Some(name)
  })
}

/// Attach a tool result to its call card. The log is newest-first, so the
/// head-first search finds the most recent card with the id; when no card
/// exists (unexpected), the result itself becomes a completed card.
fn attach_result(log: List(Line), id: String, line: Line) -> List(Line) {
  case log {
    [] -> [line]
    [head, ..rest] ->
      case head {
        ToolLine(head_id, name, arguments, ToolRunning, None) if head_id == id -> [
          ToolLine(id, name, arguments, line_status(line), line_result(line)),
          ..rest
        ]
        _ -> [head, ..attach_result(rest, id, line)]
      }
  }
}

fn line_status(line: Line) -> ToolStatus {
  case line {
    ToolLine(_id, _name, _arguments, status, _result) -> status
    _ -> ToolRunning
  }
}

fn line_result(line: Line) -> Option(String) {
  case line {
    ToolLine(_id, _name, _arguments, _status, result) -> result
    _ -> None
  }
}

/// Enter the deliberate no-selection state: the chat pane goes blank and
/// refresh auto-selection stays off until the user picks a row (the same
/// reset `Select` performs, minus the join — the caller sends a `Leave`
/// for the session that was selected). Shared by the archive-of-selection
/// and New-session entry points; `label` feeds the header's fallback.
fn deselect(model: Model, label: String) -> Model {
  Model(
    ..model,
    selected: None,
    visit: model.visit + 1,
    log: [],
    flushed: [],
    bubble: None,
    bubble_hidden: True,
    thinking: None,
    streaming: False,
    pending: [],
    loop: None,
    guard: False,
    turn_base: 0,
    model_label: label,
    pop: None,
    suppress_autoselect: True,
  )
}

/// Apply the M2 refresh rules to the loaded session list: drop a vanished
/// selection, auto-select the first ACTIVE (non-archived) session — unless
/// the no-selection state is deliberate (`suppress_autoselect`) — and show
/// the create panel only when there is nothing to select. An archived
/// selection stays selected (the chat pane keeps showing what the user
/// just archived, and a deliberately re-opened archived row survives a
/// refresh) but never auto-selects.
fn after_sessions(
  model: Model,
  summaries: List(session.SessionSummary),
) -> Model {
  let active = list.filter(summaries, fn(summary) { !summary.archived })
  let selected = case model.selected {
    Some(id) ->
      case list.any(summaries, fn(s) { s.id == id }) {
        True -> Some(id)
        False -> None
      }
    None -> None
  }
  let selected = case selected, active, model.suppress_autoselect {
    Some(id), _, _ -> Some(id)
    None, [first, ..], False -> Some(first.id)
    None, _, _ -> None
  }
  let ended = option.is_some(model.selected) && option.is_none(selected)
  Model(
    ..model,
    sessions: summaries,
    selected: selected,
    // A landed selection re-arms the auto-selection window (the next
    // deliberate deselect must suppress again); a deliberate no-selection
    // state keeps the suppression across refreshes.
    suppress_autoselect: case selected {
      Some(_) -> False
      None -> model.suppress_autoselect
    },
    create_open: case active, selected {
      [], _ -> True
      // No selection with sessions available is now a real state (the
      // deliberate no-selection mode), not a gap: keep the panel as the
      // user left it — closed after an archive-deselect, open when the
      // New-session button opened it alongside the deselect.
      _, None -> model.create_open
      // A panel auto-opened by an (empty-at-boot) session list closes
      // again as soon as there is something to select; one the user opened
      // by hand stays open.
      _, Some(_) ->
        case model.create_auto {
          True -> False
          False -> model.create_open
        }
    },
    create_auto: case active, selected {
      [], _ -> True
      _, _ -> False
    },
    log: case ended {
      True -> []
      False -> model.log
    },
    // The pending flushes belong to the ended session's log; a stale
    // entry must never stamp another session's (possibly legacy-
    // unstamped) line that happens to carry the same text.
    flushed: case ended {
      True -> []
      False -> model.flushed
    },
    bubble: case ended {
      True -> None
      False -> model.bubble
    },
    // The hidden flag belongs to the cleared bubble: a stale False (the
    // ended session's bubble was visible) would let the NEXT session's
    // first streamed token — even whitespace-only — render, bypassing the
    // render-empty rule the Token arm applies.
    bubble_hidden: case ended {
      True -> True
      False -> model.bubble_hidden
    },
    thinking: case ended {
      True -> None
      False -> model.thinking
    },
    streaming: case ended {
      True -> False
      False -> model.streaming
    },
    pending: case ended {
      True -> []
      False -> model.pending
    },
    loop: case ended {
      True -> None
      False -> model.loop
    },
    guard: case ended {
      True -> False
      False -> model.guard
    },
    turn_base: case ended {
      True -> 0
      False -> model.turn_base
    },
    model_label: case ended {
      True -> "session ended"
      False -> model.model_label
    },
    // The popup belongs to the ended session's log — same rule as the
    // pending flushes above it.
    pop: case ended {
      True -> None
      False -> model.pop
    },
  )
}

fn first_alias(model: Model, aliases: List(String)) -> String {
  case model.picker, aliases {
    "", [first, ..] -> first
    picker, _ -> picker
  }
}

// ---------------------------------------------------------------------------
// Effects (registry / session / model API glue)
// ---------------------------------------------------------------------------

/// Fetch the selected provider's live model list (multi-provider §12:
/// the picker is provider-scoped). Generous actor-call timeout: the
/// fetch itself is bounded by the endpoint's first-response budget
/// (server-global SSE policy), this only has to outlive it — and it
/// runs off the registry's loop (see provider_registry `ListModels`).
fn aliases_for(model: Model, provider_id: String) -> Effect(Msg) {
  let providers = model.providers
  effect.from(fn(dispatch) {
    case provider_registry.list_models(providers, provider_id, 60_000) {
      Ok(aliases) -> dispatch(AliasesLoaded(provider_id, aliases))
      Error(_) -> dispatch(AliasesFailed)
    }
  })
}

/// All providers as masked metadata: the Settings page, the picker's
/// options, and subtitle name resolution all read this list.
fn providers_effect(model: Model) -> Effect(Msg) {
  let providers = model.providers
  effect.from(fn(dispatch) {
    case provider_registry.list_providers(providers) {
      Ok(all) -> dispatch(ProvidersLoaded(all))
      Error(error) ->
        dispatch(ProvidersFailed(provider_registry.describe(error)))
    }
  })
}

/// The picker's target after a (re)load: the previous selection when it
/// still exists and is enabled, else the first enabled provider.
pub fn pick_provider(
  providers: List(Provider),
  previous: Option(String),
) -> Option(String) {
  let enabled = list.filter(providers, fn(p) { p.enabled })
  case previous {
    Some(id) ->
      case list.any(enabled, fn(p) { p.id == id }) {
        True -> Some(id)
        False ->
          list.map(enabled, fn(p) { p.id }) |> list.first |> option.from_result
      }
    None ->
      list.map(enabled, fn(p) { p.id }) |> list.first |> option.from_result
  }
}

// ---------------------------------------------------------------------------
// Session / registry effects
// ---------------------------------------------------------------------------

fn sessions_effect(model: Model) -> Effect(Msg) {
  let registry = model.registry
  effect.from(fn(dispatch) {
    dispatch(SessionsLoaded(session_registry.list_sessions(registry)))
  })
}

fn join_effect(model: Model, id: String) -> Effect(Msg) {
  let registry = model.registry
  let visit = model.visit
  case model.events {
    Some(events) ->
      effect.from(fn(_dispatch) {
        case session_registry.get(registry, id) {
          Ok(subject) -> process.send(subject, session.Join(events, visit))
          Error(_) -> Nil
        }
      })
    None -> effect.none()
  }
}

/// Detach this connection's subscription from a session it is leaving.
/// The session-event subject is ONE long-lived subject per connection
/// (see `events_effect`), so a session switch must explicitly Leave the
/// old session: the session actor only prunes subscribers whose process
/// died — a live subject stays in the fan-out forever, and without the
/// Leave the old session's stream kept rendering into the new session's
/// view. Fan-out hygiene, not correctness: correctness is the per-event
/// id filter (`SessionScoped`), because broadcasts already in the
/// subscriber's mailbox when Leave lands still arrive. Unknown/vanished
/// sessions fail the registry lookup harmlessly.
fn leave_effect(model: Model, id: String) -> Effect(Msg) {
  let registry = model.registry
  case model.events {
    Some(events) ->
      effect.from(fn(_dispatch) {
        case session_registry.get(registry, id) {
          Ok(subject) -> process.send(subject, session.Leave(events))
          Error(_) -> Nil
        }
      })
    None -> effect.none()
  }
}

fn send_effect(model: Model, text: String) -> Effect(Msg) {
  let registry = model.registry
  let id = model.selected
  effect.from(fn(dispatch) {
    let resolved = case id {
      Some(session_id) -> session_registry.get(registry, session_id)
      None -> Error(Nil)
    }
    case resolved {
      Ok(subject) -> {
        // Auto-title at the send boundary — the twin of the HTTP route's
        // rule. The transcript always carries the system prompt, so "no
        // user message yet" is a count of 1; the registry refuses to
        // clobber a manual (or already generated) title regardless.
        let is_first = session.describe(subject).message_count <= 1
        case session.send_message(subject, text) {
          session.Sent -> {
            case is_first, id {
              True, Some(session_id) -> {
                let _ =
                  session_registry.auto_title(
                    registry,
                    session_id,
                    session_registry.title_from_first_message(text),
                  )
                Nil
              }
              _, _ -> Nil
            }
            // Refresh on EVERY send, not just the first: the session
            // bumps its activity at the send itself (the user message
            // commits on append, even if the turn later fails), so a
            // previous-day conversation re-buckets to Today and jumps to
            // the top the moment the message lands. Waiting for the
            // reply's TurnDone refresh left the row under Yesterday for
            // the whole turn. The first-message case also lands the new
            // title here; the turn's own events follow.
            dispatch(SessionsLoaded(session_registry.list_sessions(registry)))
            dispatch(SendAccepted)
          }
          session.Busy -> dispatch(SendRejected("busy"))
        }
      }
      Error(_) -> dispatch(SendRejected("gone"))
    }
  })
}

fn stop_effect(model: Model) -> Effect(Msg) {
  let registry = model.registry
  let id = model.selected
  effect.from(fn(_dispatch) {
    let resolved = case id {
      Some(session_id) -> session_registry.get(registry, session_id)
      None -> Error(Nil)
    }
    case resolved {
      Ok(subject) -> session.stop(subject)
      Error(_) -> Nil
    }
  })
}

fn create_effect(model: Model, alias: String) -> Effect(Msg) {
  let registry = model.registry
  effect.from(fn(dispatch) {
    // The registry builds the M3 agent-loop runner itself, from the tool
    // registry frozen at its boot — sessions created here get the full
    // toolset, pinned to the create panel's selected provider + model
    // (multi-provider §8: the pin is explicit, never defaulted).
    let create = case model.provider {
      Some(provider_id) -> session_registry.create(registry, provider_id, alias)
      None ->
        Error(session_registry.ProviderFailed(session_registry.ProviderUnknown))
    }
    case create {
      Ok(record) -> {
        let now = timing.wall_now_s()
        dispatch(
          Created(
            session.SessionSummary(
              id: record.id,
              provider_id: option.unwrap(model.provider, ""),
              model: record.model,
              title: "",
              title_source: session.AutoTitle,
              pinned: False,
              tags: [],
              archived: False,
              message_count: 0,
              streaming: False,
              created_at: now,
              last_active_at: now,
              metrics: [],
            ),
          ),
        )
      }
      Error(session_registry.EmptyModel) ->
        dispatch(CreateFailed("empty model"))
      Error(session_registry.ProviderFailed(reason)) ->
        dispatch(CreateFailed(describe_provider_error(reason)))
      Error(session_registry.StartFailed(reason)) ->
        dispatch(CreateFailed(reason))
    }
  })
}

/// Fixed text for a provider resolution failure on the create path.
fn describe_provider_error(reason: session_registry.ProviderError) -> String {
  case reason {
    session_registry.ProviderUnknown -> "no provider configured"
    session_registry.ProviderDisabled -> "provider is disabled"
    session_registry.ProviderKeyUnavailable -> "provider key unavailable"
  }
}

/// Run one registry metadata mutation, then refresh the session list so
/// the sidebar reflects it immediately (pins re-order, archive hides,
/// delete drops the row). A `False` reply means the session vanished
/// mid-edit — surface it as a note.
fn mutate_effect(
  model: Model,
  run: fn(process.Subject(session_registry.Msg)) -> Bool,
) -> Effect(Msg) {
  let registry = model.registry
  effect.from(fn(dispatch) {
    case run(registry) {
      True -> dispatch(SessionsLoaded(session_registry.list_sessions(registry)))
      False -> dispatch(SessionOpFailed("session is gone"))
    }
  })
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  // The connection dot always renders live: one runtime serves exactly
  // one connected client, so a dead client cannot be rendered for. The
  // browser-side indicator script still flips the dot on the client
  // runtime's own lustre:close/lustre:connect transport events.
  html.div([attr.id("app")], [
    html.header([], [
      html.h1([], [html.text("nexus")]),
      html.span([attr.id("model"), attr.class("muted")], [
        html.text(header_title(model)),
      ]),
      // The connection state is a labelled group, not a bare dot
      // (ui-polish F8): the dot plus a text twin, so the state stays
      // legible without color. The label flips with the dot via the
      // page's static indicator script (nexus/page.gleam); the server
      // always renders "connected" — one runtime serves exactly one
      // live client, the only truth it can know — exactly like the
      // dot's green render above.
      html.span([attr.class("conn")], [
        html.span(
          [attr.id("status"), attr.class("dot live"), attr.title("connection")],
          [html.text("●")],
        ),
        html.span([attr.id("status-label"), attr.class("muted")], [
          html.text("connected"),
        ]),
      ]),
      html.button(
        [
          attr.id("settings"),
          attr.type_("button"),
          attr.title(case model.view {
            ChatView -> "Open settings"
            SettingsView -> "Back to chat"
          }),
          event.on_click(SettingsToggled),
        ],
        [
          html.text(case model.view {
            ChatView -> "Settings"
            SettingsView -> "Back to chat"
          }),
        ],
      ),
    ]),
    // `data-selected` mirrors the (per-client) selection into the DOM so
    // the page shell's static script can persist it and re-supply it on
    // the next connection's /ws route. The attribute stays live in the
    // Settings view too (entering settings never changes the selection;
    // the settings page simply replaces the layout's chat children).
    html.div(
      [
        attr.id("layout"),
        ..list.append(
          case model.view {
            SettingsView -> [attr.class("settings-mode")]
            ChatView -> []
          },
          [attr.attribute("data-selected", option.unwrap(model.selected, ""))],
        )
      ],
      // The chat children stay MOUNTED in the Settings view (hidden via
      // CSS, `#layout.settings-mode`): the composer's textarea is
      // uncontrolled, so unmounting it would destroy an unsent draft —
      // peeking at settings must not cost the user their message. The
      // settings page renders as an extra child; the diff only ever
      // appends/removes it, so the chat subtree's element identity
      // (including the keyed composer) survives both directions.
      case model.view {
        ChatView -> [sidebar(model), chat(model)]
        SettingsView -> [
          sidebar(model),
          chat(model),
          element.map(
            ui_settings.view(model.settings, model.provider_list),
            Settings,
          ),
        ]
      },
    ),
    // The full-call popup (`tool_pop`) renders at the shell's top level,
    // not inside the chat pane: it overlays whatever view is up, and its
    // `<dialog>` is position-fixed anyway. Renders nothing when closed.
    tool_pop(model),
  ])
}

fn sidebar(model: Model) -> Element(Msg) {
  html.aside([attr.id("sidebar")], [
    // The create panel comes FIRST (ui-polish F4): it used to sit below the
    // whole session list, so pressing "New" (top-right of the list) usually
    // opened it below the fold. Markup order is the fix — no new state, and
    // the `#create-panel` / `#new-session` selectors the browser suite drives
    // are unchanged.
    html.section([attr.id("create-panel"), attr.hidden(!model.create_open)], [
      html.label([attr.for("provider-picker")], [html.text("Provider")]),
      html.select(
        [
          attr.id("provider-picker"),
          attr.aria("label", "Provider"),
          provider_change(),
        ],
        provider_options(model),
      ),
      html.label([attr.for("model-picker")], [html.text("Model alias")]),
      html.select(
        [
          attr.id("model-picker"),
          attr.aria("label", "Model alias"),
          picker_change(),
        ],
        list.map(model.aliases, fn(alias) {
          html.option(
            [
              attr.value(alias),
              attr.selected(alias == model.picker || model.picker == ""),
            ],
            alias,
          )
        }),
      ),
      html.button(
        [
          attr.id("create-session"),
          attr.type_("button"),
          attr.disabled(model.aliases == [] || model.provider == None),
          event.on_click(CreateRequested),
        ],
        [html.text("Create session")],
      ),
    ]),
    html.section([], [
      html.div([attr.class("section-head")], [
        html.h2([], [html.text("Sessions")]),
        html.button(
          [
            attr.id("new-session"),
            attr.type_("button"),
            event.on_click(NewSessionToggled),
          ],
          [html.text("New")],
        ),
      ]),
      tag_filter_row(model),
      html.div([attr.class("archive-toggle-row")], [
        html.button(
          [
            attr.id("show-archived"),
            attr.type_("button"),
            attr.class(case model.show_archived {
              True -> "toggle on"
              False -> "toggle"
            }),
            event.on_click(ArchivedToggled),
          ],
          [
            html.text(case model.show_archived {
              True -> "Hide archived"
              False -> "Show archived"
            }),
          ],
        ),
      ]),
      html.div(
        [attr.id("session-list"), attr.class("session-list"), attr.role("list")],
        session_rows(model),
      ),
    ]),
  ])
}

/// Options for the create panel's provider select: enabled providers
/// only (the plan's `enabled = true` picker filter), the selected one
/// marked. With none, a disabled placeholder keeps the control legible.
fn provider_options(model: Model) -> List(Element(Msg)) {
  let enabled = list.filter(model.provider_list, fn(p) { p.enabled })
  case enabled {
    [] -> [
      html.option(
        [attr.value(""), attr.selected(True)],
        "no providers — add one in Settings",
      ),
    ]
    providers ->
      list.map(providers, fn(p) {
        html.option(
          [
            attr.value(p.id),
            attr.selected(model.provider == Some(p.id)),
          ],
          case p.has_key {
            True -> p.name
            False -> p.name <> " (keyless)"
          },
        )
      })
  }
}

/// The tag-filter input. Uncontrolled like the composer: its text rides the
/// `input` event, and programmatic changes (chip click, clear) rotate the
/// key so the client replaces the element with the new value baked in —
/// no value patch can race the user's typing that way.
fn tag_filter_row(model: Model) -> Element(Msg) {
  keyed.element("div", [attr.class("filter-row")], [
    #(
      "tag-filter-" <> int.to_string(model.filter_gen),
      html.input([
        attr.id("tag-filter"),
        attr.type_("text"),
        attr.value(model.tag_filter),
        attr.placeholder("Filter by title or tag…"),
        attr.aria("label", "Filter sessions"),
        filter_changed(),
      ]),
    ),
    #("filter-clear", case string.trim(model.tag_filter) {
      "" -> element.none()
      _ ->
        html.button(
          [
            attr.id("filter-clear"),
            attr.type_("button"),
            attr.title("Clear filter"),
            event.on_click(TagFilterSet("")),
          ],
          [html.text("×")],
        )
    }),
  ])
}

/// The visible rows: the filter runs first (title + tags), then the list
/// splits into the pinned section, the recency buckets, and (when the
/// toggle is on) the archived section.
fn session_rows(model: Model) -> List(Element(Msg)) {
  let visible =
    list.filter(model.sessions, fn(summary) {
      matches_filter(summary, model.tag_filter)
    })
  let has_active = list.any(visible, fn(summary) { !summary.archived })
  let has_archived =
    model.show_archived && list.any(visible, fn(summary) { summary.archived })
  case has_active || has_archived {
    False -> [
      html.p([attr.class("muted")], [html.text(empty_state_text(model))]),
    ]
    True -> {
      let pinned = list.filter(visible, fn(s) { s.pinned && !s.archived })
      let unpinned = list.filter(visible, fn(s) { !s.pinned && !s.archived })
      let archived = list.filter(visible, fn(s) { s.archived })
      let pinned_group = case pinned {
        [] -> element.none()
        rows ->
          html.div([attr.class("session-group pinned-group")], [
            html.h3([attr.class("group-label")], [html.text("Pinned")]),
            ..list.map(rows, session_row(model, _))
          ])
      }
      let archived_group = case model.show_archived, archived {
        True, [_first, ..] ->
          html.div([attr.class("session-group archive-group")], [
            html.h3([attr.class("group-label")], [html.text("Archived")]),
            ..list.map(archived, session_row(model, _))
          ])
        _, _ -> element.none()
      }
      [
        pinned_group,
        ..list.append(bucket_groups(model, unpinned), [
          archived_group,
        ])
      ]
    }
  }
}

fn empty_state_text(model: Model) -> String {
  case string.trim(model.tag_filter) {
    "" ->
      case model.show_archived {
        True -> "No sessions."
        False -> "No sessions yet."
      }
    _ -> "No sessions match the filter."
  }
}

/// Recency buckets for the unpinned rows, oldest label last. The registry
/// already sorted by activity, so each bucket keeps that order.
fn bucket_groups(
  model: Model,
  summaries: List(session.SessionSummary),
) -> List(Element(Msg)) {
  let now = timing.wall_now_s()
  [Today, Yesterday, Previous7Days, Older]
  |> list.map(fn(wanted) {
    #(
      wanted,
      list.filter(summaries, fn(s) { bucket(now, s.last_active_at) == wanted }),
    )
  })
  |> list.filter(fn(entry) { entry.1 != [] })
  |> list.map(fn(entry) {
    let #(wanted, rows) = entry
    html.div([attr.class("session-group")], [
      html.h3([attr.class("group-label")], [html.text(bucket_label(wanted))]),
      ..list.map(rows, session_row(model, _))
    ])
  })
}

/// The header's session context (ui-polish F8): the selected session's
/// title — the bare model alias ("nexus  smart") was cryptic, and the
/// alias already rides the row subtitle. An untitled session falls back
/// to its alias (the row-title rule); with nothing selected the
/// `model_label` fallbacks ("connecting…", "session ended") keep their
/// feedback role.
fn header_title(model: Model) -> String {
  case model.selected {
    Some(id) ->
      case list.find(model.sessions, fn(s) { s.id == id }) {
        Ok(summary) -> display_title(summary)
        Error(_) -> model.model_label
      }
    None -> model.model_label
  }
}

/// Display title for a session: its title, or the model alias until the
/// first message auto-titles it.
fn display_title(summary: session.SessionSummary) -> String {
  case summary.title {
    "" -> summary.model
    titled -> titled
  }
}

/// One sidebar row: a select button (title + model/age subtitle), tag
/// chips, compact controls, and hidden inline editors + delete confirm.
/// Everything is escaped text nodes — no innerHTML anywhere.
fn session_row(model: Model, summary: session.SessionSummary) -> Element(Msg) {
  let id = summary.id
  let selected = model.selected == Some(id)
  let title = display_title(summary)
  // The subtitle pins the session's identity: provider/model (both
  // frozen at creation, §8) plus its age. The provider name resolves
  // from the masked list so renames show at once.
  let subtitle =
    provider_display(model, summary.provider_id)
    <> "/"
    <> summary.model
    <> " · "
    <> rel_time(timing.wall_now_s(), summary.last_active_at)
  html.div(
    [
      attr.class(case selected {
        True -> "session-row selected"
        False -> "session-row"
      }),
      attr.data("session-id", id),
    ],
    [
      html.button(
        [
          attr.class("session-main"),
          attr.type_("button"),
          attr.aria("current", bool_aria(selected)),
          event.on_click(Select(id)),
        ],
        [
          html.span([attr.class("session-title")], [
            html.text(
              case summary.pinned {
                True -> "📌 "
                False -> ""
              }
              <> title,
            ),
          ]),
          html.span([attr.class("session-sub")], [html.text(subtitle)]),
        ],
      ),
      case summary.tags {
        [] -> element.none()
        tags ->
          html.span(
            [attr.class("tag-chips")],
            list.map(tags, fn(tag) {
              html.button(
                [
                  attr.class("tag-chip"),
                  attr.type_("button"),
                  attr.title("Filter by " <> tag),
                  event.on_click(TagFilterSet(tag)),
                ],
                [html.text(tag)],
              )
            }),
          )
      },
      html.div([attr.class("row-controls")], [
        // Invariant: an archived session is never pinned (archiving
        // unpins; the registry refuses pins on archived rows), so the
        // control simply does not exist there.
        case summary.archived {
          True -> element.none()
          False ->
            ui_settings.control(
              case summary.pinned {
                True -> "Unpin"
                False -> "Pin"
              },
              case summary.pinned {
                True -> "Unpin this session"
                False -> "Pin this session to the top"
              },
              PinToggled(id),
            )
        },
        ui_settings.control("Rename", "Rename this session", RenameToggled(id)),
        ui_settings.control(
          "Tags",
          "Edit tags for this session",
          TagsToggled(id),
        ),
        ui_settings.control(
          case summary.archived {
            True -> "Restore"
            False -> "Archive"
          },
          case summary.archived {
            True -> "Restore this session to the active list"
            False -> "Archive (soft-hide) this session"
          },
          Archived(id, !summary.archived),
        ),
        ui_settings.control(
          "Delete",
          "Delete this session forever",
          DeleteRequested(id),
        ),
      ]),
      // Inline rename editor (hidden until opened; the input is
      // uncontrolled-with-value — patches only fire when the stored title
      // itself changes, so typing is never clobbered mid-edit).
      html.form(
        [
          attr.class("inline-editor"),
          attr.action("#"),
          attr.hidden(model.rename_open != Some(id)),
          rename_submitted(id),
        ],
        [
          html.input([
            attr.type_("text"),
            attr.name("title"),
            attr.value(summary.title),
            attr.placeholder("Session title"),
            attr.aria("label", "New title for " <> id),
          ]),
          html.button([attr.type_("submit")], [html.text("Save")]),
          html.button(
            [attr.type_("button"), event.on_click(RenameToggled(id))],
            [html.text("Cancel")],
          ),
        ],
      ),
      // Inline tag editor: comma-separated.
      html.form(
        [
          attr.class("inline-editor"),
          attr.action("#"),
          attr.hidden(model.tags_open != Some(id)),
          tags_submitted(id),
        ],
        [
          html.input([
            attr.type_("text"),
            attr.name("tags"),
            attr.value(string.join(summary.tags, ", ")),
            attr.placeholder("Tags, comma-separated"),
            attr.aria("label", "Tags for " <> id),
          ]),
          html.button([attr.type_("submit")], [html.text("Save")]),
          html.button([attr.type_("button"), event.on_click(TagsToggled(id))], [
            html.text("Cancel"),
          ]),
        ],
      ),
      // Two-step delete confirmation.
      html.div(
        [
          attr.class("confirm-delete"),
          attr.hidden(model.confirm_delete != Some(id)),
        ],
        [
          html.span([], [
            html.text("Delete this session? This cannot be undone."),
          ]),
          html.button(
            [
              attr.type_("button"),
              attr.class("danger"),
              event.on_click(DeleteConfirmed(id)),
            ],
            [html.text("Delete forever")],
          ),
          html.button([attr.type_("button"), event.on_click(DeleteCancelled)], [
            html.text("Keep"),
          ]),
        ],
      ),
    ],
  )
}

fn chat(model: Model) -> Element(Msg) {
  let has_session = option.is_some(model.selected)
  html.main([attr.id("chat")], [
    // `#log-wrap` anchors the jump button to the log's bottom edge (the
    // log itself is the scroll container, so the button must not live in
    // it). See `jump_latest` for why the button is inert.
    html.div([attr.id("log-wrap")], [
      // `.conversation` is the centered column that keeps wide screens from
      // pinning user/assistant turns to opposite edges (ui-polish F6) — see
      // the css() comment in `nexus/page`. `#log` stays the scroll container
      // (the autoscroll script observes it), so the wrapper goes inside it.
      html.div([attr.id("log"), attr.aria("live", "polite")], [
        html.div([attr.class("conversation")], log_lines(model)),
      ]),
      jump_latest(),
    ]),
    loop_chip(model),
    composer(model, has_session),
  ])
}

/// Server-rendered "jump to latest" control, hidden until the page
/// shell's autoscroll script un-hides it. Inert by construction — no
/// event handler, a text node, nothing derived from model output: only
/// the browser knows the scroll position and the user's intent, so the
/// static `autoscroll_js` script in `nexus/page` owns the behaviour
/// (delegated click, `hidden` toggling). It starts hidden because a
/// fresh view opens at the bottom.
fn jump_latest() -> Element(Msg) {
  html.button(
    [
      attr.id("jump-latest"),
      attr.type_("button"),
      attr.aria("label", "Jump to latest"),
      attr.hidden(True),
    ],
    [html.text("↓")],
  )
}

/// Iteration status for the turn in flight: "iter 2/8 · tools". Hidden when
/// no loop is running; the "guard" phase is the terminal iteration state
/// right before the turn-failed note lands.
fn loop_chip(model: Model) -> Element(Msg) {
  case model.loop {
    None -> html.div([attr.id("loop-status"), attr.hidden(True)], [])
    Some(LoopState(iteration, max, phase)) ->
      html.div(
        [
          attr.id("loop-status"),
          attr.class("loop-status " <> phase),
          attr.aria("label", "agent loop status"),
          attr.hidden(!model.streaming),
        ],
        [
          html.text(
            "iter "
            <> int.to_string(iteration)
            <> "/"
            <> int.to_string(max)
            <> " · "
            <> phase,
          ),
        ],
      )
  }
}

/// The composer is a `<form>` holding an *uncontrolled* textarea inside a
/// *keyed* container — the pattern Lustre documents for server components.
///
/// A server component cannot cancel an event's default action conditionally
/// (its handler runs on the server, after the browser already inserted the
/// newline), so a controlled draft would always lose the race against the
/// newline's `input` echo arriving over the WebSocket. Instead the textarea
/// owns its text locally:
///
/// - Enter is read at `keydown` time, when `target.value` is still
///   newline-free, and carries the text in the message itself.
/// - The Send button is a real submit button: the browser assembles the
///   form data (`detail.formData`) for us, also newline-free.
/// - On `SendAccepted` the textarea's key changes, which replaces the
///   element wholesale — clearing it no `value` patch ever could — and its
///   `autofocus` attribute puts the caret right back for the next turn.
fn composer(model: Model, has_session: Bool) -> Element(Msg) {
  keyed.element(
    "form",
    [attr.id("composer"), attr.action("#"), submit_requested()],
    [
      #(
        "composer-" <> int.to_string(model.composer),
        html.textarea(
          [
            attr.id("input"),
            attr.name("text"),
            attr.rows(3),
            attr.placeholder(
              "Send a message… (Enter · Shift+Enter for a new line)",
            ),
            attr.autofocus(True),
            attr.disabled(!has_session),
            enter_key(),
          ],
          "",
        ),
      ),
      #(
        "controls",
        html.div([attr.class("buttons")], [
          // Stop mounts only during a turn — it used to sit permanently
          // visible-and-disabled while idle (ui-polish F8). Pico's global
          // `[hidden] { display: none !important }` does the hiding,
          // mirroring `#loop-status`'s `hidden` handling.
          html.button(
            [
              attr.id("stop"),
              attr.type_("button"),
              attr.hidden(!model.streaming),
              attr.disabled(!model.streaming),
              event.on_click(StopRequested),
            ],
            [html.text("Stop")],
          ),
          html.button(
            [
              attr.id("send"),
              attr.type_("submit"),
              attr.disabled(model.streaming || !has_session),
            ],
            [html.text("Send")],
          ),
        ]),
      ),
    ],
  )
}

fn log_lines(model: Model) -> List(Element(Msg)) {
  // Committed lines first, then the in-flight overlays newest-last: the
  // live thinking block, the streaming bubble, then tool calls still
  // assembling their arguments — reasoning precedes content, live and
  // committed alike. The live overlays render open (full-width blocks),
  // so only committed lines go through the chip-row grouping.
  let committed = group_chips(model.md_cache, list.reverse(model.log))
  let with_thinking = case model.thinking {
    Some(text) -> list.append(committed, [reasoning_block(text, True)])
    None -> committed
  }
  // The live bubble stays plain pre-wrap text until the turn commits,
  // hidden while its text would render to nothing — the same rule the
  // commit path applies (see the `Token` arm, which computes
  // `bubble_hidden`), so nothing appears live that a commit would drop.
  // No timestamp: the bubble is not committed yet, and the commit rules
  // it mirrors commit nothing server-side — the stamp lands at TurnDone.
  let with_bubble = case model.bubble {
    Some(text) ->
      case model.bubble_hidden {
        True -> with_thinking
        False -> list.append(with_thinking, [turn("assistant", text, None)])
      }
    None -> with_thinking
  }
  let lines = case model.pending {
    [] -> with_bubble
    pending -> list.append(with_bubble, list.map(pending, pending_card))
  }
  case lines {
    // ui-polish F5: an empty transcript used to render a blank void above
    // the composer. Give the fresh-session state an intentional muted
    // hint — a Lustre text node, like every word this UI renders. With no
    // session selected (the deliberate no-selection state) the composer
    // is disabled, so the hint points at the sidebar instead of a send
    // that would fail.
    [] -> [
      html.div([attr.class("note")], [
        html.text(case model.selected {
          Some(_) ->
            "Send a message to start — tool calls and reasoning will render here"
          None ->
            "No session selected — pick one from the list or create a new one."
        }),
      ]),
    ]
    _ -> lines
  }
}

fn turn(kind: String, text: String, at: Option(Int)) -> Element(Msg) {
  html.div([attr.class("turn " <> kind)], [
    html.span([], [html.text(text)]),
    time_stamp(at),
  ])
}

/// Committed assistant turns render markdown (see `nexus/ui/markdown`
/// for the hostile-text contract: raw HTML stays inert text, hrefs are
/// scheme-filtered, images become links). The `md` class switches the
/// turn from pre-wrap text flow to block flow — the live streaming
/// bubble above keeps plain `turn("assistant", …)` rendering until the
/// turn commits, so a half-streamed construct never looks committed.
fn assistant_turn(
  md_cache: dict.Dict(String, List(Element(Msg))),
  text: String,
  at: Option(Int),
) -> Element(Msg) {
  // No wrapper span: the markdown blocks are direct children of the
  // bubble, so valid HTML nesting returns and the `.turn.md >
  // :first-child`/`:last-child` margin rules reach the first and last
  // block. Cache miss renders on the fly — the miss path only exists
  // for direct view renders; both commit paths populate the cache — and
  // both reject render-empty text, so an empty element list here would
  // render an empty tinted pill; guard it anyway (defense in depth).
  // The timestamp rides AFTER the markdown blocks (it is not part of the
  // cached render — the cache is keyed by text alone) and becomes the
  // last child, where the existing `:last-child` margin reset covers it.
  let elements = case dict.get(md_cache, text) {
    Ok(elements) -> elements
    Error(_) -> markdown.render(text)
  }
  case elements {
    [] -> element.none()
    _ ->
      html.div(
        [attr.class("turn assistant md")],
        list.append(elements, [time_stamp(at)]),
      )
  }
}

/// The per-message timestamp: a `<time data-epoch>` with the compact
/// relative age ("3m ago", "just now") as its text, the RFC3339 UTC
/// instant as both `datetime` and `title` (the browser renders `title`
/// as the hover tooltip — the absolute half of the display, server-side
/// and no-JS). `data-epoch` lets the page shell's `timestamps_js` re-age
/// the labels as time passes and localize `title` to the viewer's
/// timezone; unstamped (legacy) messages render no element at all.
fn time_stamp(at: Option(Int)) -> Element(Msg) {
  case at {
    None -> element.none()
    Some(at) -> {
      let instant = timing.wall_to_rfc3339(at)
      html.time(
        [
          attr.class("ts"),
          attr.datetime(instant),
          attr.title(instant),
          attr.attribute("data-epoch", int.to_string(at)),
        ],
        [html.text(age_label(timing.wall_now_s(), at))],
      )
    }
  }
}

/// The bubble's relative-age label: the sidebar's compact `rel_time`
/// ("3m", "2h", "5d") with an " ago" suffix, except "just now" which
/// reads as itself. Pure; same deterministic UTC arithmetic as rel_time.
pub fn age_label(now_epoch: Int, at: Int) -> String {
  case rel_time(now_epoch, at) {
    "just now" -> "just now"
    compact -> compact <> " ago"
  }
}

fn render_line(
  md_cache: dict.Dict(String, List(Element(Msg))),
  line: Line,
) -> Element(Msg) {
  case line {
    UserLine(text, at) -> turn("user", text, at)
    AssistantLine(text, at) -> assistant_turn(md_cache, text, at)
    ReasoningLine(text) -> reasoning_block(text, False)
    ToolLine(..) -> tool_card(line)
    NoteLine(err, text) ->
      html.div(
        [
          attr.class(case err {
            True -> "note err"
            False -> "note"
          }),
        ],
        [html.text(text)],
      )
  }
}

/// Runs of consecutive collapsible lines — committed reasoning and tool
/// cards — render inside one `.chip-row` wrapper, so their collapsed
/// chips flow together like inline spans on a shared row instead of each
/// stacking a full-width block (a tool-heavy turn used to cost a whole
/// row plus the conversation gap per chip). Any other line ends the run;
/// an expanded chip takes its full row back via CSS off the native
/// `[open]` attribute, no script involved. Tail-recursive on purpose:
/// session history is unbounded and the per-connection UI process must
/// not grow a stack frame per transcript group.
fn group_chips(
  md_cache: dict.Dict(String, List(Element(Msg))),
  lines: List(Line),
) -> List(Element(Msg)) {
  group_chips_loop(md_cache, lines, [])
}

fn group_chips_loop(
  md_cache: dict.Dict(String, List(Element(Msg))),
  lines: List(Line),
  acc: List(Element(Msg)),
) -> List(Element(Msg)) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] ->
      case is_chip(line) {
        False ->
          group_chips_loop(md_cache, rest, [render_line(md_cache, line), ..acc])
        True -> {
          let #(run, rest) = take_chips([line], rest)
          group_chips_loop(md_cache, rest, [
            chip_row(md_cache, list.reverse(run)),
            ..acc
          ])
        }
      }
  }
}

/// Extend a chip run with every following chip line. The run accumulates
/// reversed; the caller reverses it before rendering.
fn take_chips(run: List(Line), rest: List(Line)) -> #(List(Line), List(Line)) {
  case rest {
    [line, ..more] ->
      case is_chip(line) {
        True -> take_chips([line, ..run], more)
        False -> #(run, rest)
      }
    [] -> #(run, rest)
  }
}

fn is_chip(line: Line) -> Bool {
  case line {
    ReasoningLine(_) | ToolLine(..) -> True
    UserLine(_, _) | AssistantLine(_, _) | NoteLine(_, _) -> False
  }
}

fn chip_row(
  md_cache: dict.Dict(String, List(Element(Msg))),
  lines: List(Line),
) -> Element(Msg) {
  html.div([attr.class("chip-row")], list.map(lines, render_line(md_cache, _)))
}

/// The model's reasoning (chain of thought) as an inert collapsible
/// block: one label, "thinking", in both states — the ellipsis rides only
/// the live block as its streaming cue. A native `<details>` — no script,
/// and the body is a Lustre text node, so hostile reasoning text is
/// escaped like every other model output.
fn reasoning_block(text: String, live: Bool) -> Element(Msg) {
  html.details(
    [
      attr.class(
        "turn reasoning"
        <> case live {
          True -> " live"
          False -> ""
        },
      ),
      attr.open(live),
    ],
    [
      html.summary([attr.class("reasoning-label")], [
        html.text(case live {
          True -> "thinking…"
          False -> "thinking"
        }),
      ]),
      html.div([attr.class("reasoning-body")], [html.text(text)]),
    ],
  )
}

/// One assistant tool call as a compact clickable chip: the tool name,
/// with the call state riding the border tint (and the aria-label, so the
/// state is never color-only). Clicking anywhere on the chip opens the
/// full-call popup (`tool_pop`) — the whole point of the chip; the
/// inline body of the old `<details>` cards (truncated previews, meta
/// row) moved into the popup, where the text is complete. A real button,
/// so keyboard activation works too. Every label is a Lustre text node,
/// so hostile tool output is inert by construction.
fn tool_card(line: Line) -> Element(Msg) {
  let assert ToolLine(id, name, _arguments, status, _result) = line
  let #(status_label, state_class) = case status {
    ToolRunning -> #("running", "running")
    ToolDone(True) -> #("completed", "done")
    ToolDone(False) -> #("failed", "failed")
  }
  html.button(
    [
      attr.type_("button"),
      attr.class("turn tool " <> state_class),
      attr.data("call-id", id),
      attr.data("tool", name),
      attr.attribute("aria-label", name <> " (" <> status_label <> ")"),
      attr.title("View full call"),
      event.on_click(ToolViewOpened(CallPop(id))),
    ],
    [html.strong([attr.class("tool-name")], [html.text(name)])],
  )
}

/// A tool call still streaming its arguments: the same compact clickable
/// chip as a committed card (the popup resolves it against `pending`, so
/// an open popup live-updates as fragments arrive), keyed by chunk index
/// until the backend assigns a stable call id.
fn pending_card(call: PendingCall) -> Element(Msg) {
  let name = option.unwrap(call.name, "…")
  let aria_name = case call.name {
    Some(name) -> name
    None -> "tool call"
  }
  html.button(
    [
      attr.type_("button"),
      attr.class("turn tool running pending"),
      attr.data("call-index", int.to_string(call.index)),
      attr.attribute("aria-label", aria_name <> " (running)"),
      attr.title("View full call"),
      event.on_click(ToolViewOpened(PendingPop(call.index))),
    ],
    [html.strong([attr.class("tool-name")], [html.text(name)])],
  )
}

/// The full-call popup: a native `<dialog open>` — Pico styles the open
/// dialog as the centered overlay (backdrop included, no script) and its
/// `article` child as the card. The call is re-resolved from the log /
/// pending lists on EVERY render: an open popup live-updates as arguments
/// stream and the result lands, and a popup whose call no longer resolves
/// (rolled-back turn, session switch) renders nothing instead of going
/// stale. The full argument and result strings are Lustre text nodes
/// inside `<pre>` — inert, like everything else this UI renders; the
/// popup just doesn't truncate. Codemode calls carry their script as the
/// JSON string value of a `code` field (`codemode.gleam`'s own schema);
/// that string is decoded and shown under a "Script" label — the raw
/// JSON escapes every newline into one unreadable line.
fn tool_pop(model: Model) -> Element(Msg) {
  case pop_content(model) {
    None -> element.none()
    Some(content) -> {
      let PopContent(name, id, status_label, state_class, section, body, result) =
        content
      html.dialog([attr.open(True)], [
        // Click-outside dismissal without stopPropagation (a server
        // component cannot stop an event's bubble): an invisible layer
        // under the card covers the whole overlay and carries the close
        // handler. Clicks on the card land on the article, which paints
        // above the layer; clicks on the dimmed backdrop land on the
        // layer and close the popup.
        html.div(
          [attr.class("tool-pop-hit"), event.on_click(ToolViewClosed)],
          [],
        ),
        html.article([attr.class("tool-pop " <> state_class)], [
          html.header([], [
            html.button(
              [
                attr.type_("button"),
                attr.class("close"),
                attr.aria("label", "Close"),
                attr.title("Close"),
                event.on_click(ToolViewClosed),
              ],
              // A text glyph, not Pico's background-icon close: the
              // shell's #app button reset out-ranks Pico's .close rule
              // and strips the icon (an empty-looking box). The shell
              // reads as words, so the text glyph is also consistent.
              [html.text("×")],
            ),
            html.h2([], [html.text(name)]),
          ]),
          html.div([attr.class("tool-meta")], [
            html.span([attr.class("call-id")], [html.text(id)]),
            html.span([attr.class("tool-status")], [html.text(status_label)]),
          ]),
          html.h3([], [html.text(section)]),
          html.pre([], [html.text(body)]),
          case result {
            Some(text) ->
              html.div([], [
                html.h3([], [html.text("Result")]),
                html.pre([], [html.text(text)]),
              ])
            None -> element.none()
          },
        ]),
      ])
    }
  }
}

/// The popup's resolved content: tool name, call id, status label and
/// state class, the argument section's label ("Script" when the codemode
/// `code` field decoded, "Arguments" otherwise), the full argument body,
/// and the result once available (None while the call is running).
type PopContent {
  PopContent(
    name: String,
    id: String,
    status_label: String,
    state_class: String,
    section: String,
    body: String,
    result: Option(String),
  )
}

fn pop_content(model: Model) -> Option(PopContent) {
  case model.pop {
    None -> None
    Some(CallPop(id)) ->
      case
        list.find(model.log, fn(line) {
          case line {
            ToolLine(line_id, _, _, _, _) -> line_id == id
            _ -> False
          }
        })
      {
        Error(_) -> None
        Ok(ToolLine(id, name, arguments, status, result)) -> {
          let #(status_label, state_class) = case status {
            ToolRunning -> #("running", "running")
            ToolDone(True) -> #("completed", "done")
            ToolDone(False) -> #("failed", "failed")
          }
          let #(section, body) = script_or_arguments(arguments)
          Some(PopContent(
            name: name,
            id: id,
            status_label: status_label,
            state_class: state_class,
            section: section,
            body: body,
            result: result,
          ))
        }
        Ok(_) -> None
      }
    Some(PendingPop(index)) ->
      case list.find(model.pending, fn(call) { call.index == index }) {
        Error(_) -> None
        Ok(call) -> {
          let #(section, body) = script_or_arguments(call.args)
          Some(PopContent(
            name: option.unwrap(call.name, "…"),
            id: option.unwrap(call.id, "…"),
            status_label: "running",
            state_class: "running",
            section: section,
            body: body,
            result: None,
          ))
        }
      }
  }
}

/// Codemode calls (the tool registered in `nexus/codemode`, schema
/// `{"code": string}`) carry their script as a JSON string value — every
/// newline escaped, so the raw arguments render as one unreadable line.
/// Only an object whose SINGLE key is a string `code` decodes as a
/// script; anything else — extra keys (whose values would otherwise be
/// silently hidden), a non-string `code`, malformed JSON — renders the
/// raw argument text under "Arguments", hiding nothing.
fn script_or_arguments(arguments: String) -> #(String, String) {
  case json.parse(arguments, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      case dict.size(fields) == 1, dict.get(fields, "code") {
        True, Ok(code) ->
          case decode.run(code, decode.string) {
            Ok(script) -> #("Script", script)
            Error(_) -> #("Arguments", arguments)
          }
        _, _ -> #("Arguments", arguments)
      }
    Error(_) -> #("Arguments", arguments)
  }
}

// ---------------------------------------------------------------------------
// Event decoders
// ---------------------------------------------------------------------------

fn enter_key() -> attr.Attribute(Msg) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    // The value at keydown time: the browser has not inserted the newline
    // yet, so this is the draft exactly as the user last saw it.
    use value <- decode.subfield(["target", "value"], decode.string)
    use shift <- decode.optional_field("shiftKey", False, decode.bool)
    use composing <- decode.optional_field("isComposing", False, decode.bool)
    case key, shift, composing {
      // Plain Enter sends; Shift+Enter falls through so the browser's
      // newline default stands (the textarea keeps its multi-line text
      // until the next plain Enter submits it). `isComposing` guards IME
      // users whose Enter confirms a composition instead of sending.
      "Enter", False, False -> SendRequested(value)
      _, _, _ -> Ignored
    }
    |> decode.success
  }
  event.on("keydown", decoder)
  |> server_component.include(["key", "target.value", "shiftKey", "isComposing"])
}

fn submit_requested() -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case list.find(entries, fn(entry) { entry.0 == "text" }) {
      Ok(#(_, value)) -> SendRequested(value)
      Error(_) -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

fn picker_change() -> attr.Attribute(Msg) {
  let decoder =
    decode.at(["target", "value"], decode.string)
    |> decode.map(PickerChanged)
  event.on("change", decoder)
  |> server_component.include(["target.value"])
}

/// The create panel's provider select: switching providers re-scopes
/// the model picker (multi-provider §12).
fn provider_change() -> attr.Attribute(Msg) {
  let decoder =
    decode.at(["target", "value"], decode.string)
    |> decode.map(ProviderPicked)
  event.on("change", decoder)
  |> server_component.include(["target.value"])
}

/// The display name for a summary's pinned provider, resolved from the
/// masked list (renames show at once); the id stands in while the list
/// lags. Deletes are guarded while sessions pin a provider, so the
/// fallback is cosmetic, not semantic.
fn provider_display(model: Model, provider_id: String) -> String {
  case list.find(model.provider_list, fn(p) { p.id == provider_id }) {
    Ok(p) -> p.name
    Error(_) -> provider_id
  }
}

/// The tag-filter input is uncontrolled: every keystroke carries its own
/// `target.value` — no state echo can clobber the field.
fn filter_changed() -> attr.Attribute(Msg) {
  let decoder =
    decode.at(["target", "value"], decode.string)
    |> decode.map(TagFilterChanged)
  event.on("input", decoder)
  |> server_component.include(["target.value"])
}

/// The rename editor submits with the draft riding the form data (the
/// same pattern the composer uses for its textarea).
fn rename_submitted(id: String) -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case list.find(entries, fn(entry) { entry.0 == "title" }) {
      Ok(#(_, value)) -> RenameRequested(id, value)
      Error(_) -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

fn tags_submitted(id: String) -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case list.find(entries, fn(entry) { entry.0 == "tags" }) {
      Ok(#(_, value)) -> TagsEdited(id, value)
      Error(_) -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

fn bool_aria(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
