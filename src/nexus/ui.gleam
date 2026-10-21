//// The M3 chat UI as a Lustre server component: Model, Msg, init, update,
//// and view. This module is the pure half — transport, WebSocket upgrade,
//// and runtime wiring live in `nexus/ui_runtime`.
////
//// The component mirrors the M2 client plus the M3 tool surface: alias
//// picker, session sidebar, streaming log with a single in-flight assistant
//// bubble, **typed tool-call cards** (name, stable call id, argument
//// preview, running/completed/failed status, compact inert result
//// preview), loop/iteration status, and the per-session metrics panel.
//// Tool events are never rendered as model text, live or on Hello replay.
//// All dynamic text is produced with Lustre `text` nodes; there is no
//// `innerHTML` anywhere.
////
//// The shell hosts two views (per client): the chat layout and the
//// Settings page (`nexus/ui_settings`, provider management), swapped
//// via the header button. Settings state is a lifted sub-component —
//// `ui.Settings(msg)` delegates to `ui_settings.update` and folds its
//// signals back into this model.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
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
/// kept separately (like M2) so tokens can be appended cheaply.
pub type Line {
  UserLine(text: String)
  AssistantLine(text: String)
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

/// Which main view the shell renders. The header (title, model label,
/// connection dot, settings button) persists across both; the `#layout`
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
    aliases: List(String),
    sessions: List(session.SessionSummary),
    metrics: List(session.MetricSample),
    selected: Option(String),
    picker: String,
    create_open: Bool,
    log: List(Line),
    bubble: Option(String),
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
  /// No enabled provider exists: the create panel has nothing to offer
  /// until an operator adds one on the Settings page.
  NoProviders
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
  Hello(model: String, metrics: List(session.MetricSample))
  UserEcho(String)
  AssistantFull(String)
  Token(String)
  TurnDone
  TurnStopped
  TurnFailed(String)
  // M3 tool events: translated 1:1 so the replay/live pipelines carry them;
  // rendering lands with the M3 UI workstream. No-ops in `update` for now.
  ToolCallDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    fragment: String,
  )
  ToolCallAssembled(id: String, name: String, arguments: String)
  ToolResult(id: String, name: String, ok: Bool, content: String)
  LoopStatus(iteration: Int, max_iterations: Int, phase: String)
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

/// Translate a `session.SessionEvent` into a typed component message.
/// Session events arrive on the subject selected in `init` and flow through
/// the same `update` as DOM events.
pub fn from_session_event(event: SessionEvent) -> Msg {
  case event {
    session.Hello(model, _messages, metrics) -> Hello(model, metrics)
    session.UserEcho(text) -> UserEcho(text)
    session.AssistantFull(text) -> AssistantFull(text)
    session.Token(text) -> Token(text)
    session.TurnDone(_stats) -> TurnDone
    session.TurnStopped(_chars) -> TurnStopped
    session.TurnFailed(reason) -> TurnFailed(reason)
    session.ToolCallDelta(index, id, name, fragment) ->
      ToolCallDelta(index, id, name, fragment)
    session.ToolCallAssembled(id, name, arguments) ->
      ToolCallAssembled(id, name, arguments)
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
      aliases: [],
      sessions: [],
      metrics: [],
      // A reload re-opens the client's last-selected session: the page
      // shell persists it and supplies it on the /ws route. If it has since
      // vanished, `after_sessions` drops it and the auto-selection rules
      // take over — same as any stale selection.
      selected: flags.session,
      picker: "",
      create_open: False,
      log: [],
      bubble: None,
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
    |> process.select_map(subject, from_session_event)
  })
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Ignored -> #(model, effect.none())

    GotEvents(subject) -> {
      // The connect point of a per-client runtime: the subscription
      // subject exists, so load everything (and re-Join the client's
      // session — Hello + replay is idempotent). This is the old
      // ClientConnected arm minus the stale-view clearing a fresh model
      // makes unnecessary.
      let model = Model(..model, events: Some(subject))
      let eff = case model.selected {
        Some(id) ->
          effect.batch([
            join_effect(model, id),
            // Provider metadata + aliases refresh here too: a transient
            // registry/model-list failure must not leave the panel stale
            // for the lifetime of the connection.
            providers_effect(model),
            aliases_effect(model),
            sessions_effect(model),
          ])
        None ->
          effect.batch([
            providers_effect(model),
            aliases_effect(model),
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

    NoProviders -> #(
      Model(..model, provider: None, aliases: [], log: [
        NoteLine(True, "no provider configured — add one in Settings"),
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
      let eff = case next.selected {
        Some(id) ->
          case model.selected {
            Some(prev) if prev == id -> effect.none()
            _ -> join_effect(next, id)
          }
        None -> effect.none()
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
        _ -> #(
          Model(
            ..model,
            selected: Some(id),
            log: [],
            bubble: None,
            streaming: False,
            pending: [],
            loop: None,
            guard: False,
            turn_base: 0,
            metrics: metrics_for(model.sessions, id),
            model_label: "connecting…",
          ),
          join_effect(model, id),
        )
      }

    NewSessionToggled -> #(
      Model(..model, create_open: !model.create_open, create_auto: False),
      effect.none(),
    )

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

    Hello(name, metrics) -> #(
      Model(
        ..model,
        model_label: name,
        metrics: metrics,
        streaming: case model.selected {
          Some(id) ->
            case list.find(model.sessions, fn(s) { s.id == id }) {
              Ok(summary) -> summary.streaming
              Error(_) -> False
            }
          None -> False
        },
      ),
      effect.none(),
    )

    UserEcho(text) -> #(
      Model(
        ..model,
        log: [UserLine(text), ..model.log],
        // The user message marks the start of a (possibly live) turn: lines
          // beyond this point belong to it and roll back on a failed turn.
          turn_base: list.length(model.log) + 1,
      ),
      effect.none(),
    )

    AssistantFull(text) -> #(
      Model(..model, log: [AssistantLine(text), ..model.log]),
      effect.none(),
    )

    Token(text) -> {
      let bubble = case model.bubble {
        Some(acc) -> Some(acc <> text)
        None -> Some(text)
      }
      #(Model(..model, bubble: bubble, streaming: True), effect.none())
    }

    TurnDone -> #(finish_turn(model, CommitBubble), sessions_effect(model))

    TurnStopped -> #(finish_turn(model, CommitBubble), sessions_effect(model))

    // A tool call's arguments are streaming in fragments. Any assistant
    // text seen so far belongs *before* the call (the loop commits text at
    // assembly time), so the bubble is committed first; the fragments then
    // accumulate into a pending card keyed by the chunk index.
    ToolCallDelta(index, id, name, fragment) -> {
      let model = commit_bubble(model)
      let pending =
        upsert_pending(model.pending, PendingCall(index, id, name, fragment))
      #(Model(..model, pending: pending, streaming: True), effect.none())
    }

    // The call is assembled and about to execute: drop its pending card
    // (and any sibling fragments — the "tools" phase boundary clears the
    // rest), then commit a running card for the stable id.
    ToolCallAssembled(id, name, arguments) -> {
      let model = commit_bubble(model)
      let pending = drop_pending(model.pending, id, name)
      #(
        Model(..model, pending: pending, log: [
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

    // Terminal failures: how much of the turn survives depends on what the
    // server committed. After the guard tripped, the final partial text and
    // all completed tool rounds ARE committed (only the trailing,
    // never-run call is dropped); any other failure commits nothing, so the
    // whole turn's display rolls back to the user line and the partial
    // bubble is discarded.
    TurnFailed(reason) -> {
      let model = case model.guard {
        True -> commit_bubble(model)
        False ->
          Model(
            ..model,
            log: rollback_log(model.log, model.turn_base),
            bubble: None,
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

    Archived(id, archived) -> #(
      model,
      mutate_effect(model, fn(registry) {
        session_registry.set_archived(registry, id, archived)
      }),
    )

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

/// How a terminal event treats the streaming bubble.
type BubblePolicy {
  CommitBubble
  DropBubble
}

/// Terminal turn handling: commit or drop the streamed bubble, fold away
/// per-turn tool state, and stop streaming. Tool cards already in the log
/// stay (completed rounds are committed server-side on done/stopped/guard).
fn finish_turn(model: Model, policy: BubblePolicy) -> Model {
  let model = case policy {
    CommitBubble -> commit_bubble(model)
    DropBubble -> Model(..model, bubble: None)
  }
  Model(..model, pending: [], loop: None, guard: False, streaming: False)
}

/// Commit the streaming bubble (if any) as a completed assistant line —
/// matching the session's own commit rules.
fn commit_bubble(model: Model) -> Model {
  case model.bubble {
    Some(text) ->
      Model(..model, bubble: None, log: [AssistantLine(text), ..model.log])
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

/// Apply the M2 refresh rules to the loaded session list: drop a vanished
/// selection, auto-select the first ACTIVE (non-archived) session, and show
/// the create panel only when there is nothing to select. An archived
/// selection stays selected (the chat pane keeps showing what the user just
/// archived) but never auto-selects.
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
  let selected = case selected, active {
    Some(id), _ -> Some(id)
    None, [first, ..] -> Some(first.id)
    None, [] -> None
  }
  let ended = option.is_some(model.selected) && option.is_none(selected)
  Model(
    ..model,
    sessions: summaries,
    selected: selected,
    metrics: case selected {
      Some(id) -> metrics_for(summaries, id)
      None -> []
    },
    create_open: case active, selected {
      [], _ -> True
      _, None -> False
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
    bubble: case ended {
      True -> None
      False -> model.bubble
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
  )
}

fn first_alias(model: Model, aliases: List(String)) -> String {
  case model.picker, aliases {
    "", [first, ..] -> first
    picker, _ -> picker
  }
}

fn metrics_for(
  summaries: List(session.SessionSummary),
  id: String,
) -> List(session.MetricSample) {
  case list.find(summaries, fn(s) { s.id == id }) {
    Ok(summary) -> summary.metrics
    Error(_) -> []
  }
}

// ---------------------------------------------------------------------------
// Effects (registry / session / model API glue)
// ---------------------------------------------------------------------------

fn aliases_effect(model: Model) -> Effect(Msg) {
  // The create panel's picker follows the selected provider; with no
  // enabled provider there is nothing to offer — the note points at the
  // Settings page that creates one.
  case model.provider {
    Some(id) -> aliases_for(model, id)
    None -> effect.from(fn(dispatch) { dispatch(NoProviders) })
  }
}

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
  case model.events {
    Some(events) ->
      effect.from(fn(_dispatch) {
        case session_registry.get(registry, id) {
          Ok(subject) -> process.send(subject, session.Join(events))
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
                // Refresh so the new title lands in the sidebar at once;
                // the turn's own events (and TurnDone's refresh) follow.
                dispatch(
                  SessionsLoaded(session_registry.list_sessions(registry)),
                )
              }
              _, _ -> Nil
            }
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
        html.text(model.model_label),
      ]),
      html.span(
        [attr.id("status"), attr.class("dot live"), attr.title("connection")],
        [html.text("●")],
      ),
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
      case model.view {
        ChatView -> [sidebar(model), chat(model), metrics_panel(model)]
        SettingsView -> [
          element.map(
            ui_settings.view(model.settings, model.provider_list),
            Settings,
          ),
        ]
      },
    ),
  ])
}

fn sidebar(model: Model) -> Element(Msg) {
  html.aside([attr.id("sidebar")], [
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

/// One sidebar row: a select button (title + model/age subtitle), tag
/// chips, compact controls, and hidden inline editors + delete confirm.
/// Everything is escaped text nodes — no innerHTML anywhere.
fn session_row(model: Model, summary: session.SessionSummary) -> Element(Msg) {
  let id = summary.id
  let selected = model.selected == Some(id)
  // An untitled session falls back to its alias until the first message
  // auto-titles it.
  let title = case summary.title {
    "" -> summary.model
    titled -> titled
  }
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
    html.div([attr.id("log"), attr.aria("live", "polite")], log_lines(model)),
    loop_chip(model),
    composer(model, has_session),
  ])
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
          html.button(
            [
              attr.id("stop"),
              attr.type_("button"),
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
  let completed =
    list.reverse(model.log)
    |> list.map(fn(line) {
      case line {
        UserLine(text) -> turn("user", text)
        AssistantLine(text) -> turn("assistant", text)
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
    })
  // In-flight state renders newest-last: committed lines, the streaming
  // bubble, then tool calls still assembling their arguments.
  let with_bubble = case model.bubble {
    Some(text) -> list.append(completed, [turn("assistant", text)])
    None -> completed
  }
  case model.pending {
    [] -> with_bubble
    pending -> list.append(with_bubble, list.map(pending, pending_card))
  }
}

fn turn(kind: String, text: String) -> Element(Msg) {
  html.div([attr.class("turn " <> kind)], [html.span([], [html.text(text)])])
}

/// One assistant tool call as a compact card: head (name, stable call id,
/// status) plus truncated argument and result previews. Everything is a
/// text node — previews are inert by construction.
fn tool_card(line: Line) -> Element(Msg) {
  let assert ToolLine(id, name, arguments, status, result) = line
  let #(status_label, state_class) = case status {
    ToolRunning -> #("running", "running")
    ToolDone(True) -> #("completed", "done")
    ToolDone(False) -> #("failed", "failed")
  }
  html.div(
    [
      attr.class("turn tool " <> state_class),
      attr.data("call-id", id),
      attr.data("tool", name),
    ],
    [
      html.div([attr.class("tool-head")], [
        html.strong([attr.class("tool-name")], [html.text(name)]),
        html.span([attr.class("call-id")], [html.text(id)]),
        html.span([attr.class("tool-status")], [html.text(status_label)]),
      ]),
      html.div([attr.class("tool-args")], [html.text(preview(arguments, 120))]),
      case result {
        Some(content) ->
          html.div([attr.class("tool-result")], [
            html.text(preview(content, 200)),
          ])
        None -> element.none()
      },
    ],
  )
}

/// A tool call still streaming its arguments: name/id when the backend sent
/// them, plus the arguments accumulated so far.
fn pending_card(call: PendingCall) -> Element(Msg) {
  let name = option.unwrap(call.name, "…")
  let id = option.unwrap(call.id, "…")
  html.div(
    [
      attr.class("turn tool running pending"),
      attr.data("call-index", int.to_string(call.index)),
    ],
    [
      html.div([attr.class("tool-head")], [
        html.strong([attr.class("tool-name")], [html.text(name)]),
        html.span([attr.class("call-id")], [html.text(id)]),
        html.span([attr.class("tool-status")], [html.text("running")]),
      ]),
      html.div([attr.class("tool-args")], [html.text(preview(call.args, 120))]),
    ],
  )
}

/// Compact one-line preview: truncate with an ellipsis. Applied to tool
/// arguments and results only — never to model or user text.
fn preview(text: String, max: Int) -> String {
  case string.length(text) > max {
    True -> string.slice(text, 0, max) <> "…"
    False -> text
  }
}

fn metrics_panel(model: Model) -> Element(Msg) {
  html.aside([attr.id("metrics-panel")], [
    html.div([attr.class("section-head")], [html.h2([], [html.text("Metrics")])]),
    html.div(
      [attr.id("metrics"), attr.class("metrics-list")],
      metric_blocks(model.metrics),
    ),
  ])
}

fn metric_blocks(samples: List(session.MetricSample)) -> List(Element(Msg)) {
  case samples {
    [] -> [html.p([attr.class("muted")], [html.text("No turns yet.")])]
    _ ->
      list.map(samples, fn(sample) {
        html.div([attr.class("metric")], [
          html.strong([], [html.text(outcome_name(sample.outcome))]),
          html.div([], [html.text(metric_line(sample))]),
        ])
      })
  }
}

fn outcome_name(outcome: session.MetricOutcome) -> String {
  case outcome {
    session.Completed -> "completed"
    session.Stopped -> "stopped"
    session.Failed -> "failed"
  }
}

/// The same summary line the M2 client rendered, as plain text.
pub fn metric_line(sample: session.MetricSample) -> String {
  let ttft = case sample.ttft_ms {
    Some(ms) -> int.to_string(ms) <> "ms"
    None -> "–"
  }
  let line =
    "TTFT "
    <> ttft
    <> " · "
    <> int.to_string(sample.duration_ms)
    <> "ms · "
    <> int.to_string(sample.token_deltas)
    <> " deltas"
  let line = case sample.prompt_tokens {
    Some(prompt) -> {
      let cached = case sample.cached_tokens {
        Some(c) -> int.to_string(c)
        None -> "–"
      }
      line <> " · cached " <> cached <> "/" <> int.to_string(prompt)
    }
    None -> line
  }
  let line = case sample.outcome, sample.stopped_chars {
    session.Stopped, Some(chars) ->
      line <> " · stopped at " <> int.to_string(chars) <> " chars"
    _, _ -> line
  }
  case sample.outcome, sample.failure_reason {
    session.Failed, Some(reason) -> line <> " · " <> reason
    _, _ -> line
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
