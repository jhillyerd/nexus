//// The Settings sub-component: provider and bot management (and, over
//// time, further settings categories) rendered as a full-page view
//// inside the chat component's shell, laid out as a left-hand tab rail
//// beside the active category's section. `nexus/ui` swaps its main
//// area for this view when the header's Settings button opens it, and
//// lifts the sub-component into the parent app with
//// `element.map`/`effect.map`.
////
//// The split is deliberately one-way:
////
//// - the parent owns the masked provider list (it feeds the create
////   panel's picker and the thread-row subtitles) and passes it into
////   `view`;
//// - this module owns the editor states (add form, inline edit,
////   two-step delete confirmation, per-row connection test) and the
////   CRUD effects against the provider registry;
//// - results the parent must act on travel back as `Signal`s: a
////   created provider re-aims the picker, every mutation asks for a
////   list reload, and failures surface as notes in the chat log.
////
//// Like the rest of the UI, everything rendered here is a Lustre text
//// node — provider names, base URLs, model aliases, and failure reasons
//// are all hostile text; there is no `innerHTML` anywhere.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import lustre/server_component
import nexus/bot.{type Bot}
import nexus/bot_registry
import nexus/provider.{type Provider}
import nexus/provider_registry
import nexus/utility

/// Which settings category the page's tab rail shows. Providers is the
/// default: it is the page's original category and the first-run flow's
/// target (a fresh database auto-opens the page with an empty provider
/// list, and the user must add one before bots are usable at all).
pub type SettingsTab {
  ProvidersTab
  BotsTab
}

/// On-demand connection-test state for the row Test control: idle,
/// fetching, or the settled result (model aliases / fixed failure text)
/// for one provider id. Kept per-settings-view, not per row — only the
/// most recent test renders, under its own row.
pub type ModelsState {
  ModelsIdle
  ModelsLoading(id: String)
  ModelsOk(id: String, aliases: List(String))
  ModelsFailed(id: String, reason: String)
}

pub type State {
  State(
    /// The add-provider form is open (at most one form section-wide).
    open: Bool,
    /// The provider row whose inline editor is open.
    edit: Option(String),
    /// The provider row whose two-step delete confirmation is armed.
    confirm: Option(String),
    /// The latest on-demand connection test.
    models: ModelsState,
    /// The latest provider-mutation failure, rendered in the settings
    /// page — the user is standing here when a mutation fails, so the
    /// reason must be visible without switching views (the chat-log
    /// note via `OpFailed` stays for the transcript).
    last_error: Option(String),
    // ---- Bots (bots plan P1) ----
    /// The add-bot form is open (at most one form section-wide).
    bots_open: Bool,
    /// The bot row whose inline editor is open.
    bot_edit: Option(String),
    /// The bot row whose two-step delete confirmation is armed.
    bot_confirm: Option(String),
    /// The latest bot-mutation failure, rendered beside the Bots section
    /// (same rule as `last_error`).
    bot_last_error: Option(String),
    /// Which tab the page's left rail shows. Both sections stay in the
    /// DOM (the inactive one `hidden`, like the forms) so uncontrolled
    /// form state survives tab switches; this only picks the visible one.
    tab: SettingsTab,
  )
}

pub type Msg {
  /// A decoded event that carries nothing actionable (the submit
  /// decoders' fallback arm).
  Ignored
  /// A tab in the page's left rail was clicked: the section switches,
  /// and every open form/editor/confirm stands down (see `update`).
  TabSelected(SettingsTab)
  /// The add-provider form toggled.
  AddToggled
  /// The add-provider form submitted (blank key = keyless).
  Submitted(name: String, base_url: String, api_key: String)
  EditToggled(id: String)
  /// The edit form submitted: blank fields keep the stored values; a
  /// blank key keeps the stored envelope (write-only field, §12).
  EditSubmitted(id: String, name: String, base_url: String, api_key: String)
  /// Enable/disable flipped from a row control.
  EnabledToggled(id: String, enabled: Bool)
  DeleteRequested(id: String)
  DeleteCancelled
  DeleteConfirmed(id: String)
  /// Row control: call the registry's live model list for this provider
  /// and render ok (+ aliases) or the fixed failure reason.
  TestRequested(id: String)
  // ---- Registry replies (dispatched by this module's effects) ----
  /// A provider was created (the parent re-aims the picker and reloads).
  Created(provider: Provider)
  /// An update/enable/delete landed (the parent reloads the list).
  Mutated
  /// Any provider mutation failed; `reason` is the registry's fixed
  /// text (e.g. the delete 409 guard) — surfaced as a chat-log note.
  MutateFailed(reason: String)
  ModelsLoaded(id: String, aliases: List(String))
  TestFailed(id: String, reason: String)
  // ---- Bots (bots plan P1) ----
  /// The add-bot form toggled.
  BotAddToggled
  /// The add-bot form submitted. `system_prompt` blank = the global
  /// default (resolved when a thread is created from the bot).
  /// `tools` is the raw comma-separated field; `chat_only` is the
  /// checkbox state (bots plan P2 — parsing happens in the effect).
  BotSubmitted(
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: String,
    tools: String,
    chat_only: Bool,
  )
  BotEditToggled(id: String)
  /// The edit form submitted: blank name/model/provider keep the stored
  /// values; a blank system prompt CLEARS back to the default (a real
  /// change — the two field classes in `bot.BotUpdate`). The tools field
  /// is always present (prefilled), so the patch replaces — untouched
  /// resubmits the stored list verbatim (bots plan P2).
  BotEditSubmitted(
    id: String,
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: String,
    tools: String,
    chat_only: Bool,
  )
  /// The row's inbound gate toggled (bots plan P3a): `allow` is the NEW
  /// value. A one-field PATCH — nothing else on the row moves.
  BotInboundToggled(id: String, allow: Bool)
  BotDeleteRequested(id: String)
  BotDeleteCancelled
  BotDeleteConfirmed(id: String)
  // ---- Bot registry replies ----
  /// A bot was created (the parent reloads the bot list).
  BotCreated(bot: Bot)
  /// A bot update landed (the parent reloads the bot list).
  BotMutated
  /// A bot DELETED (the parent reloads the bot list AND scrubs the
  /// thread registry's provenance mirror — deletion is the one mutation
  /// whose id the parent needs).
  BotDeletedOk(id: String)
  /// Any bot mutation failed; `reason` is the registry's fixed text —
  /// surfaced here AND as a chat-log note via `OpFailed`.
  BotMutateFailed(reason: String)
}

/// What the sub-component asks the parent (chat) model to do. Signals
/// are returned synchronously from `update`; the parent folds them into
/// its own model/effects.
pub type Signal {
  /// A provider was created: the parent applies the first-run picker
  /// re-aim, and (still in the auto-opened settings view) returns to
  /// chat.
  ProviderCreated(Provider)
  /// The masked list must be reloaded (a provider mutation landed).
  ProvidersChanged
  /// The bot list must be reloaded (a bot mutation landed).
  BotsChanged
  /// A bot was deleted: besides the list reload (`BotsChanged` also
  /// rides), the parent scrubs the deleted id from the thread registry's
  /// in-memory provenance mirror — the store's rows were already fixed
  /// by the FK's ON DELETE SET NULL inside the delete itself.
  BotRemoved(id: String)
  /// A mutation failed; `reason` is the ready-to-show note text (the
  /// per-surface prefix included) — the parent notes it in the chat log
  /// (settings has no log surface of its own).
  OpFailed(String)
}

pub fn init() -> State {
  State(
    open: False,
    edit: None,
    confirm: None,
    models: ModelsIdle,
    last_error: None,
    bots_open: False,
    bot_edit: None,
    bot_confirm: None,
    bot_last_error: None,
    tab: ProvidersTab,
  )
}

/// The sub-update. `providers`/`bots` are the registry subjects for this
/// connection's runtime (passed down from the parent model), and
/// `models_timeout_ms` the shared live-model budget
/// (`thread_create.models_timeout`) — every `list_models` call this
/// connection makes uses it, the Test control included. Returns
/// the next state, the sub-effect (already typed to `Msg`; the parent
/// maps it), and the signals the parent must fold.
pub fn update(
  state: State,
  msg: Msg,
  providers: Subject(provider_registry.Msg),
  bots: Subject(bot_registry.Msg),
  models_timeout_ms: Int,
) -> #(State, Effect(Msg), List(Signal)) {
  case msg {
    Ignored -> #(state, effect.none(), [])

    // Re-clicking the active tab does nothing: a stray double click on
    // a tab must not close a form the user is mid-way through. Only a
    // real switch stands the transient state down.
    TabSelected(tab) if tab == state.tab -> #(state, effect.none(), [])

    TabSelected(tab) -> #(
      State(
        ..state,
        tab: tab,
        // Switching tabs stands every open form/editor/confirm down —
        // the generalisation of the old one-form-per-page rule, which
        // made each section's form stand the other section's down. The
        // forms stay mounted under their `hidden` attributes, so typed
        // values survive the stand-down; only the open state closes.
        open: False,
        edit: None,
        confirm: None,
        bots_open: False,
        bot_edit: None,
        bot_confirm: None,
      ),
      effect.none(),
      [],
    )

    AddToggled -> #(
      State(
        ..state,
        open: !state.open,
        edit: None,
        confirm: None,
        // One form section-wide: opening the provider form closes the
        // Bots section's open form/editor/confirm too.
        bots_open: False,
        bot_edit: None,
        bot_confirm: None,
      ),
      effect.none(),
      [],
    )

    Submitted(name, base_url, api_key) -> #(
      State(..state, open: False),
      create_provider_effect(providers, name, base_url, api_key),
      [],
    )

    Created(provider) -> #(State(..state, last_error: None), effect.none(), [
      ProviderCreated(provider),
      ProvidersChanged,
    ])

    EditToggled(id) -> #(
      State(
        ..state,
        edit: toggle_open(state.edit, id),
        open: False,
        confirm: None,
        bots_open: False,
        bot_edit: None,
        bot_confirm: None,
      ),
      effect.none(),
      [],
    )

    EditSubmitted(id, name, base_url, api_key) -> #(
      State(..state, edit: None),
      update_provider_effect(providers, id, name, base_url, api_key),
      [],
    )

    EnabledToggled(id, enabled) -> #(
      state,
      set_provider_enabled_effect(providers, id, enabled),
      [],
    )

    DeleteRequested(id) -> #(
      State(
        ..state,
        confirm: Some(id),
        edit: None,
        open: False,
        bots_open: False,
        bot_edit: None,
        bot_confirm: None,
      ),
      effect.none(),
      [],
    )

    DeleteCancelled -> #(State(..state, confirm: None), effect.none(), [])

    DeleteConfirmed(id) -> #(
      State(..state, confirm: None),
      delete_provider_effect(providers, id),
      [],
    )

    Mutated -> #(State(..state, last_error: None), effect.none(), [
      ProvidersChanged,
    ])

    MutateFailed(reason) -> #(
      State(..state, last_error: Some(reason)),
      effect.none(),
      [OpFailed("provider operation failed: " <> reason)],
    )

    TestRequested(id) -> #(
      State(..state, models: ModelsLoading(id)),
      models_effect(providers, id, models_timeout_ms),
      [],
    )

    ModelsLoaded(id, aliases) ->
      // A reply is only live while its request is the current test: a
      // late reply for a superseded request must not clobber the newer
      // result (each row's status renders only under its own id, but
      // the state is single-slot).
      case state.models {
        ModelsLoading(loading) if loading == id -> #(
          State(..state, models: ModelsOk(id, aliases)),
          effect.none(),
          [],
        )
        _ -> #(state, effect.none(), [])
      }

    TestFailed(id, reason) ->
      case state.models {
        ModelsLoading(loading) if loading == id -> #(
          State(..state, models: ModelsFailed(id, reason)),
          effect.none(),
          [],
        )
        _ -> #(state, effect.none(), [])
      }

    // ---- Bots (bots plan P1) ----
    BotAddToggled -> #(
      State(
        ..state,
        bots_open: !state.bots_open,
        bot_edit: None,
        bot_confirm: None,
        // One form section-wide, like the provider forms: opening one
        // closes the other section's open form/editor/confirm.
        open: False,
        edit: None,
        confirm: None,
      ),
      effect.none(),
      [],
    )

    BotSubmitted(
      name,
      description,
      provider_id,
      model,
      system_prompt,
      tools,
      chat_only,
    ) -> #(
      State(..state, bots_open: False),
      create_bot_effect(
        bots,
        name,
        description,
        provider_id,
        model,
        system_prompt,
        tools,
        chat_only,
      ),
      [],
    )

    BotCreated(_bot) -> #(State(..state, bot_last_error: None), effect.none(), [
      BotsChanged,
    ])

    BotEditToggled(id) -> #(
      State(
        ..state,
        bot_edit: toggle_open(state.bot_edit, id),
        bots_open: False,
        bot_confirm: None,
        // One form section-wide, like the provider forms: opening one
        // closes the other section's open form/editor/confirm.
        open: False,
        edit: None,
        confirm: None,
      ),
      effect.none(),
      [],
    )

    BotEditSubmitted(
      id,
      name,
      description,
      provider_id,
      model,
      system_prompt,
      tools,
      chat_only,
    ) -> #(
      State(..state, bot_edit: None),
      update_bot_effect(
        bots,
        id,
        name,
        description,
        provider_id,
        model,
        system_prompt,
        tools,
        chat_only,
      ),
      [],
    )

    BotInboundToggled(id, allow) -> #(
      state,
      set_bot_inbound_effect(bots, id, allow),
      [],
    )

    BotDeleteRequested(id) -> #(
      State(
        ..state,
        bot_confirm: Some(id),
        bot_edit: None,
        bots_open: False,
        // One form section-wide: the provider section's form/editor/
        // confirm stand down with the bots section's own.
        open: False,
        edit: None,
        confirm: None,
      ),
      effect.none(),
      [],
    )

    BotDeleteCancelled -> #(
      State(..state, bot_confirm: None),
      effect.none(),
      [],
    )

    BotDeleteConfirmed(id) -> #(
      State(..state, bot_confirm: None),
      delete_bot_effect(bots, id),
      [],
    )

    BotMutated -> #(State(..state, bot_last_error: None), effect.none(), [
      BotsChanged,
    ])

    BotDeletedOk(id) -> #(State(..state, bot_last_error: None), effect.none(), [
      BotsChanged,
      BotRemoved(id),
    ])

    BotMutateFailed(reason) -> #(
      State(..state, bot_last_error: Some(reason)),
      effect.none(),
      [OpFailed("bot operation failed: " <> reason)],
    )
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/// The whole settings page: a left-hand tab rail (one entry per
/// settings category) beside the category sections. Both sections stay
/// in the DOM — the inactive one carries `hidden` and CSS-displayed
/// none, mirroring the forms — so the uncontrolled inputs keep typed
/// values across tab switches, and the keyed bot list never unmounts.
pub fn view(
  state: State,
  provider_list: List(Provider),
  bot_list: List(Bot),
) -> Element(Msg) {
  html.div([attr.id("settings-page"), attr.class("settings-page")], [
    settings_nav(state.tab),
    html.div([attr.class("settings-body")], [
      providers_section(state, provider_list),
      bots_section(state, provider_list, bot_list),
    ]),
  ])
}

/// The tab rail. A plain button pair with `aria-pressed` — the same
/// pragmatic a11y as the sidebar toggles; full tablist/arrow-key
/// semantics can come later if a third category ever needs them.
fn settings_nav(active: SettingsTab) -> Element(Msg) {
  html.nav(
    [
      attr.id("settings-nav"),
      attr.class("settings-nav"),
      attr.aria("label", "Settings sections"),
    ],
    [
      tab_button("providers", "Providers", ProvidersTab, active),
      tab_button("bots", "Bots", BotsTab, active),
    ],
  )
}

fn tab_button(
  slug: String,
  label: String,
  tab: SettingsTab,
  active: SettingsTab,
) -> Element(Msg) {
  html.button(
    [
      attr.id("tab-" <> slug),
      attr.type_("button"),
      attr.class(case tab == active {
        True -> "settings-tab on"
        False -> "settings-tab"
      }),
      attr.aria("pressed", case tab == active {
        True -> "true"
        False -> "false"
      }),
      event.on_click(TabSelected(tab)),
    ],
    [html.text(label)],
  )
}

/// The Providers section, verbatim from the pre-bots settings page.
fn providers_section(
  state: State,
  provider_list: List(Provider),
) -> Element(Msg) {
  html.section(
    [attr.id("providers-panel"), attr.hidden(state.tab != ProvidersTab)],
    [
      // One header row: title left, Add right (ui-polish F7). The page
      // itself is the settings surface the header button toggles, so the
      // section head names only its category — the rail carries the
      // between-category navigation.
      html.div([attr.class("section-head")], [
        html.h2([], [html.text("Providers")]),
        html.button(
          [
            attr.id("add-provider"),
            attr.type_("button"),
            event.on_click(AddToggled),
          ],
          [html.text("Add")],
        ),
      ]),
      html.p([attr.class("muted")], [
        html.text(
          "Providers are OpenAI-compatible endpoints. Keys are encrypted "
          <> "at rest and never shown back.",
        ),
      ]),
      // The latest mutation failure renders HERE (the user is on this
      // page when it happens) — the chat-log note via `OpFailed` is the
      // durable transcript copy.
      case state.last_error {
        Some(reason) ->
          html.p([attr.class("settings-error")], [
            html.text("provider operation failed: " <> reason),
          ])
        None -> element.none()
      },
      add_provider_form(state),
      ..case provider_list {
        [] -> [
          html.p([attr.class("muted")], [
            html.text("No providers yet. Add one to start chatting."),
          ]),
        ]
        providers -> list.map(providers, provider_row(state, _))
      }
    ],
  )
}

/// The Bots section (bots plan P1): per-row inline editor, add form,
/// two-step delete — mirroring the provider rows. Everything bot-fed
/// (names, descriptions, prompts) is hostile text under the UI
/// contract: Lustre text nodes, never innerHTML.
fn bots_section(
  state: State,
  provider_list: List(Provider),
  bot_list: List(Bot),
) -> Element(Msg) {
  html.section([attr.id("bots-panel"), attr.hidden(state.tab != BotsTab)], [
    html.div([attr.class("section-head")], [
      html.h2([], [html.text("Bots")]),
      html.button(
        [
          attr.id("add-bot"),
          attr.type_("button"),
          event.on_click(BotAddToggled),
        ],
        [html.text("Add")],
      ),
    ]),
    html.p([attr.class("muted")], [
      html.text(
        "A bot is a named profile — provider, model, system prompt — "
        <> "that a new thread is created from. Existing threads keep "
        <> "what they froze at creation.",
      ),
    ]),
    case state.bot_last_error {
      Some(reason) ->
        html.p([attr.class("settings-error")], [
          html.text("bot operation failed: " <> reason),
        ])
      None -> element.none()
    },
    case bot_list, provider_list {
      // Without a provider there is nothing to template: the add form
      // stays unusable, so say so instead of rendering a picker of
      // nothing (mirrors the provider section's empty state).
      _, [] ->
        html.p([attr.class("muted")], [
          html.text("No providers yet — add one before creating bots."),
        ])
      [], _ ->
        html.p([attr.class("muted")], [
          html.text(
            "No bots yet. Add one to start threads from a preset "
            <> "provider, model, and prompt.",
          ),
        ])
      bots, _ ->
        // Keyed by bot id (the keyed composer's precedent in ui.gleam):
        // rows reorder when a rename re-sorts the list, and an unkeyed
        // positional diff would hand a reused DOM node — dirty textarea
        // included — to whichever bot now sorts into its slot. A saved
        // edit could then store one bot's prompt under another bot's
        // name.
        keyed.element(
          "div",
          [attr.class("bot-list")],
          list.map(bots, fn(bot) {
            #(bot.id, bot_row(state, bot, provider_list))
          }),
        )
    },
    // Without a provider there is nothing to template (the empty state
    // above says so): the add form stays down rather than offering a
    // toggle whose form could only attempt an invalid write.
    case provider_list {
      [] -> element.none()
      _ -> add_bot_form(state, provider_list)
    },
  ])
}

/// One bot row: name, description, provider/model identity, the edit +
/// delete controls, the hidden inline editor, and the two-step delete
/// confirmation — the provider-row shape. The prompt (explicit or the
/// default) shows as a truncated preview under the identity line.
fn bot_row(
  state: State,
  b: Bot,
  provider_list: List(Provider),
) -> Element(Msg) {
  let id = b.id
  let provider_name = case
    list.find(provider_list, fn(p) { p.id == b.provider_id })
  {
    Ok(provider) -> provider.name
    // The provider cannot be deleted while a bot pins it (RESTRICT), so
    // this is a list-lag cosmetic fallback only.
    Error(_) -> b.provider_id
  }
  html.div([attr.class("bot-row"), attr.data("bot-id", id)], [
    html.div([attr.class("provider-main")], [
      html.div([attr.class("provider-head")], [
        html.strong([attr.class("provider-name")], [html.text(b.name)]),
        // The blocked-gate badge (bots plan P3a), mirroring the
        // provider row's "off" badge: the open gate is the normal
        // state and says nothing.
        case b.allow_inbound {
          True -> element.none()
          False -> span_badge("off", "inbound off")
        },
      ]),
      html.span([attr.class("provider-sub")], [
        html.text(
          provider_name
          <> "/"
          <> b.model
          <> case b.description {
            "" -> ""
            description -> " · " <> description
          },
        ),
      ]),
      case b.system_prompt {
        None ->
          html.span([attr.class("provider-sub muted")], [
            html.text("default system prompt"),
          ])
        Some(prompt) ->
          html.span([attr.class("provider-sub muted")], [
            html.text(truncate_preview(prompt, 120)),
          ])
      },
      // The toolset display (bots plan P2): what NEW threads from this
      // bot will snapshot — the live template, not any thread's frozen
      // copy.
      html.span([attr.class("provider-sub muted")], [
        html.text(case b.tools {
          None -> "default tools"
          Some([]) -> "no tools (chat only)"
          Some(names) -> "tools: " <> string.join(names, ", ")
        }),
      ]),
    ]),
    html.div([attr.class("row-controls")], [
      // The inbound gate toggle (bots plan P3a): the button names the
      // action, Enable/Disable style — clicking an open gate closes it.
      control(
        case b.allow_inbound {
          True -> "Block inbound"
          False -> "Allow inbound"
        },
        case b.allow_inbound {
          True -> "Block inbound bot-to-bot messages to this bot"
          False -> "Allow inbound bot-to-bot messages to this bot"
        },
        BotInboundToggled(id, !b.allow_inbound),
      ),
      control("Edit", "Edit this bot", BotEditToggled(id)),
      control("Delete", "Delete this bot forever", BotDeleteRequested(id)),
    ]),
    // Inline editor: prefilled name/model/prompt; the provider select
    // offers every provider (a bot's provider can be disabled — it only
    // blocks NEW threads, and re-aiming the bot is the cure).
    html.form(
      [
        attr.class("provider-form"),
        attr.action("#"),
        attr.hidden(state.bot_edit != Some(id)),
        bot_edit_submitted(id),
      ],
      [
        html.h3([], [html.text("Edit bot")]),
        html.input([
          attr.type_("text"),
          attr.name("name"),
          attr.value(b.name),
          attr.placeholder("Name"),
          attr.aria("label", "Name for " <> b.name),
        ]),
        html.input([
          attr.type_("text"),
          attr.name("description"),
          attr.value(b.description),
          attr.placeholder("Description (optional)"),
          attr.aria("label", "Description for " <> b.name),
        ]),
        html.label([attr.for("bot-provider-" <> id)], [html.text("Provider")]),
        html.select(
          [
            attr.id("bot-provider-" <> id),
            attr.name("provider"),
            attr.aria("label", "Provider for " <> b.name),
          ],
          list.map(provider_list, fn(p) {
            html.option(
              [attr.value(p.id), attr.selected(p.id == b.provider_id)],
              p.name,
            )
          }),
        ),
        html.input([
          attr.type_("text"),
          attr.name("model"),
          attr.value(b.model),
          attr.placeholder("Model alias"),
          attr.aria("label", "Model alias for " <> b.name),
        ]),
        html.textarea(
          [
            attr.name("system_prompt"),
            attr.rows(3),
            attr.placeholder("System prompt (blank = default)"),
            attr.aria("label", "System prompt for " <> b.name),
          ],
          case b.system_prompt {
            Some(prompt) -> prompt
            None -> ""
          },
        ),
        html.input([
          attr.type_("text"),
          attr.name("tools"),
          attr.value(case b.tools {
            Some(names) -> string.join(names, ", ")
            None -> ""
          }),
          attr.placeholder("Tools, comma-separated (blank = default)"),
          attr.aria("label", "Tools for " <> b.name),
        ]),
        html.label([attr.class("checkbox-field")], [
          html.input([
            attr.type_("checkbox"),
            attr.name("chat_only"),
            attr.value("on"),
            attr.checked(b.tools == Some([])),
          ]),
          html.text("Chat only (no tools)"),
        ]),
        html.div([attr.class("provider-form-buttons")], [
          html.button([attr.type_("submit")], [html.text("Save")]),
          html.button(
            [attr.type_("button"), event.on_click(BotEditToggled(id))],
            [html.text("Cancel")],
          ),
        ]),
      ],
    ),
    // Two-step delete: no guard behind it — a bot's threads keep their
    // frozen columns (bot_id SET NULL), which the copy makes explicit.
    html.div(
      [
        attr.class("confirm-delete"),
        attr.hidden(state.bot_confirm != Some(id)),
      ],
      [
        html.span([], [
          html.text(
            "Delete "
            <> b.name
            <> "? Threads already created from it keep their settings.",
          ),
        ]),
        html.button(
          [
            attr.type_("button"),
            attr.class("danger"),
            event.on_click(BotDeleteConfirmed(id)),
          ],
          [html.text("Delete forever")],
        ),
        html.button([attr.type_("button"), event.on_click(BotDeleteCancelled)], [
          html.text("Keep"),
        ]),
      ],
    ),
  ])
}

/// The add-bot form: same fields as the editor, blank defaults, the
/// provider select defaulting to the first provider.
fn add_bot_form(state: State, provider_list: List(Provider)) -> Element(Msg) {
  html.form(
    [
      attr.id("add-bot-form"),
      attr.class("provider-form"),
      attr.action("#"),
      attr.hidden(!state.bots_open),
      bot_submitted(),
    ],
    [
      html.h3([], [html.text("Add bot")]),
      html.input([
        attr.type_("text"),
        attr.name("name"),
        attr.placeholder("Name (e.g. research assistant)"),
        attr.aria("label", "New bot name"),
      ]),
      html.input([
        attr.type_("text"),
        attr.name("description"),
        attr.placeholder("Description (optional)"),
        attr.aria("label", "New bot description"),
      ]),
      html.label([attr.for("add-bot-provider")], [html.text("Provider")]),
      html.select(
        [
          attr.id("add-bot-provider"),
          attr.name("provider"),
          attr.aria("label", "Provider"),
        ],
        case provider_list {
          [] -> [html.option([attr.value("")], "no providers")]
          [first, ..] as providers ->
            list.map(providers, fn(p) {
              html.option(
                [attr.value(p.id), attr.selected(p.id == first.id)],
                p.name,
              )
            })
        },
      ),
      html.input([
        attr.type_("text"),
        attr.name("model"),
        attr.placeholder("Model alias"),
        attr.aria("label", "New bot model alias"),
      ]),
      html.textarea(
        [
          attr.name("system_prompt"),
          attr.rows(3),
          attr.placeholder("System prompt (blank = default)"),
          attr.aria("label", "New bot system prompt"),
        ],
        "",
      ),
      html.input([
        attr.type_("text"),
        attr.name("tools"),
        attr.placeholder("Tools, comma-separated (blank = default)"),
        attr.aria("label", "New bot tools"),
      ]),
      html.label([attr.class("checkbox-field")], [
        html.input([
          attr.type_("checkbox"),
          attr.name("chat_only"),
          attr.value("on"),
        ]),
        html.text("Chat only (no tools)"),
      ]),
      html.div([attr.class("provider-form-buttons")], [
        html.button([attr.type_("submit")], [html.text("Add bot")]),
        html.button([attr.type_("button"), event.on_click(BotAddToggled)], [
          html.text("Cancel"),
        ]),
      ]),
    ],
  )
}

/// The add-provider form. The key input is a password field with
/// autocomplete off — it never carries a value and never echoes one
/// back; the registry is the only place plaintext exists.
fn add_provider_form(state: State) -> Element(Msg) {
  html.form(
    [
      attr.id("add-provider-form"),
      attr.class("provider-form"),
      attr.action("#"),
      attr.hidden(!state.open),
      provider_submitted(),
    ],
    [
      // Card heading (F7): the form renders as a bordered card, and the
      // heading is what makes it read as a form rather than three bare
      // stacked inputs. Present even while hidden — the form's visibility
      // is the `hidden` attribute, not existence.
      html.h3([], [html.text("Add provider")]),
      html.input([
        attr.type_("text"),
        attr.name("name"),
        attr.placeholder("Name (e.g. bifrost)"),
        attr.aria("label", "New provider name"),
      ]),
      html.input([
        attr.type_("text"),
        attr.name("base_url"),
        attr.placeholder("Base URL (https://…/v1)"),
        attr.aria("label", "New provider base URL"),
      ]),
      html.input([
        attr.type_("password"),
        attr.name("api_key"),
        attr.placeholder("API key (optional)"),
        attr.aria("label", "New provider API key"),
        attr.autocomplete("off"),
      ]),
      html.div([attr.class("provider-form-buttons")], [
        html.button([attr.type_("submit")], [html.text("Add provider")]),
        html.button([attr.type_("button"), event.on_click(AddToggled)], [
          html.text("Cancel"),
        ]),
      ]),
    ],
  )
}

/// One provider row: name, badges (key/keyless, off), base URL, the
/// enable/disable + edit + test + delete controls, the hidden inline
/// editor, the two-step delete confirmation, and (after a Test) the
/// connection-test result. Mirrors the thread rows.
fn provider_row(state: State, p: Provider) -> Element(Msg) {
  let id = p.id
  html.div([attr.class("provider-row"), attr.data("provider-id", id)], [
    html.div([attr.class("provider-main")], [
      // The row head: name and badges on one line, base URL under it —
      // the thread-row shape (title line, subtitle line). Badges used
      // to sit on their own line, which read as loose text (F7).
      html.div([attr.class("provider-head")], [
        html.strong([attr.class("provider-name")], [html.text(p.name)]),
        case p.enabled {
          True -> element.none()
          False -> span_badge("off", "disabled")
        },
        case p.has_key {
          True -> span_badge("", "key")
          False -> span_badge("", "keyless")
        },
      ]),
      html.span([attr.class("provider-sub")], [html.text(p.base_url)]),
    ]),
    html.div([attr.class("row-controls")], [
      control(
        case p.enabled {
          True -> "Disable"
          False -> "Enable"
        },
        case p.enabled {
          True -> "Disable this provider (reversible)"
          False -> "Re-enable this provider"
        },
        EnabledToggled(id, !p.enabled),
      ),
      control("Edit", "Edit this provider", EditToggled(id)),
      // The on-demand connection test: one at a time — the control
      // disables while any test is in flight, so repeat clicks cannot
      // stack concurrent fetches.
      html.button(
        [
          attr.class("ctl"),
          attr.type_("button"),
          attr.title("Test this provider (fetch its live model list)"),
          attr.disabled(case state.models {
            ModelsLoading(_) -> True
            _ -> False
          }),
          event.on_click(TestRequested(id)),
        ],
        [html.text("Test")],
      ),
      control("Delete", "Delete this provider forever", DeleteRequested(id)),
    ]),
    // Inline editor: name and base URL start from the stored values;
    // the key field is blank by construction — blank keeps the stored
    // envelope, so the stored key can be replaced but never read.
    html.form(
      [
        attr.class("provider-form"),
        attr.action("#"),
        attr.hidden(state.edit != Some(id)),
        provider_edit_submitted(id),
      ],
      [
        // Card heading, same treatment as the add form — the editor opens
        // INSIDE its row's card, so the heading marks where the form is.
        html.h3([], [html.text("Edit provider")]),
        html.input([
          attr.type_("text"),
          attr.name("name"),
          attr.value(p.name),
          attr.placeholder("Name"),
          attr.aria("label", "Name for " <> p.name),
        ]),
        html.input([
          attr.type_("text"),
          attr.name("base_url"),
          attr.value(p.base_url),
          attr.placeholder("Base URL (https://…/v1)"),
          attr.aria("label", "Base URL for " <> p.name),
        ]),
        html.input([
          attr.type_("password"),
          attr.name("api_key"),
          attr.placeholder("API key (blank keeps existing)"),
          attr.aria("label", "Replacement API key for " <> p.name),
          attr.autocomplete("off"),
        ]),
        html.div([attr.class("provider-form-buttons")], [
          html.button([attr.type_("submit")], [html.text("Save")]),
          html.button([attr.type_("button"), event.on_click(EditToggled(id))], [
            html.text("Cancel"),
          ]),
        ]),
      ],
    ),
    // Two-step delete confirmation. The registry still refuses while
    // threads pin the provider (the 409 guard) — that refusal lands
    // as a note in the chat log.
    html.div(
      [
        attr.class("confirm-delete"),
        attr.hidden(state.confirm != Some(id)),
      ],
      [
        html.span([], [
          html.text(
            "Delete " <> p.name <> "? Threads pinning it block the delete.",
          ),
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
    // On-demand connection test result, only under the tested row.
    models_status(state.models, id),
  ])
}

/// The connection-test result for `id`'s row: a marker while loading,
/// ok plus the model aliases, or the fixed failure reason. Aliases and
/// reasons are text nodes — inert by construction.
fn models_status(models: ModelsState, id: String) -> Element(Msg) {
  case models {
    ModelsIdle -> element.none()
    ModelsLoading(loading) if loading == id ->
      html.div([attr.class("models-status loading")], [html.text("testing…")])
    ModelsOk(loaded, aliases) if loaded == id ->
      html.div([attr.class("models-status ok")], [
        html.text("ok · models: " <> string.join(aliases, ", ")),
      ])
    ModelsFailed(failed, reason) if failed == id ->
      html.div([attr.class("models-status failed")], [
        html.text("failed · " <> reason),
      ])
    _ -> element.none()
  }
}

fn span_badge(class: String, label: String) -> Element(Msg) {
  html.span([attr.class("badge " <> class)], [html.text(label)])
}

/// One compact row-control button. Generic in the message type so the
/// parent's thread rows reuse the same builder (ui.gleam imports this
/// module; the reverse would be circular).
pub fn control(label: String, title: String, msg: a) -> Element(a) {
  html.button(
    [
      attr.class("ctl"),
      attr.type_("button"),
      attr.title(title),
      event.on_click(msg),
    ],
    [html.text(label)],
  )
}

// ---------------------------------------------------------------------------
// Effects (provider registry glue; §11 semantics via the registry — the
// UI never sees key material, only blank-or-present)
// ---------------------------------------------------------------------------

/// Create a provider from the add-form's fields. A blank key is a
/// KEYLESS provider (local endpoints); the plaintext exists only inside
/// the registry call.
fn create_provider_effect(
  providers: Subject(provider_registry.Msg),
  name: String,
  base_url: String,
  api_key: String,
) -> Effect(Msg) {
  let params =
    provider.ProviderParams(
      name: name,
      base_url: base_url,
      api_key: blank_as_none(api_key),
    )
  effect.from(fn(dispatch) {
    case provider_registry.create(providers, params) {
      Ok(created) -> dispatch(Created(created))
      Error(error) -> dispatch(MutateFailed(provider_registry.describe(error)))
    }
  })
}

/// Submit the edit form as a PATCH: blank fields keep the stored values,
/// and a blank key keeps the stored envelope (there is deliberately no
/// "remove the key" path — §11). An all-blank form is a plain no-op.
fn update_provider_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
  name: String,
  base_url: String,
  api_key: String,
) -> Effect(Msg) {
  let patch =
    provider.ProviderUpdate(
      name: keep_blank(name),
      base_url: keep_blank(base_url),
      api_key: blank_as_none(api_key),
      enabled: None,
    )
  case
    option.is_none(patch.name)
    && option.is_none(patch.base_url)
    && option.is_none(patch.api_key)
  {
    True -> effect.none()
    False ->
      effect.from(fn(dispatch) {
        case provider_registry.update(providers, id, patch) {
          Ok(_) -> dispatch(Mutated)
          Error(error) ->
            dispatch(MutateFailed(provider_registry.describe(error)))
        }
      })
  }
}

/// Flip the reversible off-switch from a row control; the parent's
/// reload carries the new flag (and re-aims the picker if the disabled
/// row was its target).
fn set_provider_enabled_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
  enabled: Bool,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    case provider_registry.set_enabled(providers, id, enabled) {
      Ok(_) -> dispatch(Mutated)
      Error(error) -> dispatch(MutateFailed(provider_registry.describe(error)))
    }
  })
}

/// Hard delete (two-step confirmed): the registry's 409 guard surfaces
/// as a chat-log note when threads still pin the provider.
fn delete_provider_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    case provider_registry.delete(providers, id) {
      Ok(_) -> dispatch(Mutated)
      Error(error) -> dispatch(MutateFailed(provider_registry.describe(error)))
    }
  })
}

/// The Test control's fetch: the registry's live model list. Lustre
/// performs `effect.from` tasks inline in the component runtime's
/// message loop, and `list_models` is a blocking actor call that waits
/// out its timeout when the endpoint hangs (the registry replies from
/// an unlinked fetch process) — so the call must NOT run on the
/// runtime: spawn it unlinked and dispatch the reply back (the same
/// off-loop shape the registry itself uses for the fetch). The timeout
/// is the shared live-model budget, same rule as the create-panel
/// aliases path and the create preflight.
fn models_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
  models_timeout_ms: Int,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    process.spawn_unlinked(fn() {
      case provider_registry.list_models(providers, id, models_timeout_ms) {
        Ok(aliases) -> dispatch(ModelsLoaded(id, aliases))
        Error(error) ->
          dispatch(TestFailed(id, provider_registry.describe(error)))
      }
    })
    Nil
  })
}

// ---------------------------------------------------------------------------
// Bot effects (bots plan P1; §bot semantics via the bot registry — no
// key material anywhere, so nothing to mask)
// ---------------------------------------------------------------------------

/// Create a bot from the add-form's fields. A blank system prompt is
/// the global default (resolved when a thread is created from the bot);
/// `provider_id` arrives from a select built over the parent's provider
/// list, so it is valid by construction — the FK is the backstop.
fn create_bot_effect(
  bots: Subject(bot_registry.Msg),
  name: String,
  description: String,
  provider_id: String,
  model: String,
  system_prompt: String,
  tools: String,
  chat_only: Bool,
) -> Effect(Msg) {
  let params =
    bot.BotParams(
      name: name,
      description: description,
      provider_id: provider_id,
      model: model,
      system_prompt: case string.trim(system_prompt) {
        "" -> None
        prompt -> Some(prompt)
      },
      tools: parse_tools_field(tools, chat_only),
    )
  effect.from(fn(dispatch) {
    case bot_registry.create_bot(bots, params) {
      Ok(created) -> dispatch(BotCreated(created))
      Error(error) -> dispatch(BotMutateFailed(bot_registry.describe(error)))
    }
  })
}

/// Submit the edit form as a PATCH. The identity fields (name, model,
/// provider) keep their stored value when blank; the free-text fields
/// (description, system prompt) always replace — blank CLEARS (back to
/// "" and back to the default prompt), the two field classes in
/// `bot.BotUpdate`.
fn update_bot_effect(
  bots: Subject(bot_registry.Msg),
  id: String,
  name: String,
  description: String,
  provider_id: String,
  model: String,
  system_prompt: String,
  tools: String,
  chat_only: Bool,
) -> Effect(Msg) {
  let patch =
    bot.BotUpdate(
      name: keep_blank(name),
      description: Some(description),
      provider_id: keep_blank(provider_id),
      model: keep_blank(model),
      system_prompt: Some(system_prompt),
      // The tools field is always present (prefilled), so the patch
      // always replaces — an untouched form resubmits the stored list
      // verbatim; blank clears back to the default set (bots plan P2).
      tools: Some(parse_tools_field(tools, chat_only)),
      // The gate has no form field (bots plan P3a): the row's toggle
      // patches it on its own.
      allow_inbound: None,
    )
  effect.from(fn(dispatch) {
    case bot_registry.update_bot(bots, id, patch) {
      Ok(_) -> dispatch(BotMutated)
      Error(error) -> dispatch(BotMutateFailed(bot_registry.describe(error)))
    }
  })
}

/// Flip the inbound gate (bots plan P3a): a one-field PATCH — the
/// registry merges it onto the stored row and writes through, and the
/// reply reloads the list like every other bot mutation.
fn set_bot_inbound_effect(
  bots: Subject(bot_registry.Msg),
  id: String,
  allow: Bool,
) -> Effect(Msg) {
  let patch =
    bot.BotUpdate(
      name: None,
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
      tools: None,
      allow_inbound: Some(allow),
    )
  effect.from(fn(dispatch) {
    case bot_registry.update_bot(bots, id, patch) {
      Ok(_) -> dispatch(BotMutated)
      Error(error) -> dispatch(BotMutateFailed(bot_registry.describe(error)))
    }
  })
}

/// The form's tool fields → the bot's three-state toolset (bots plan
/// P2): the chat-only checkbox wins (`Some([])`); otherwise the
/// comma-separated names (trimmed, blanks dropped) — none left means
/// the default set (`None`). An explicit empty list is unreachable from
/// the form without the checkbox, which is the point: blank MEANS the
/// default here.
fn parse_tools_field(text: String, chat_only: Bool) -> Option(List(String)) {
  case chat_only {
    True -> Some([])
    False ->
      case
        text
        |> string.split(",")
        |> list.map(string.trim)
        |> list.filter(fn(name) { name != "" })
      {
        [] -> None
        names -> Some(names)
      }
  }
}

/// Hard delete (two-step confirmed): no guard — a bot's threads keep
/// their frozen columns (bot_id SET NULL).
fn delete_bot_effect(
  bots: Subject(bot_registry.Msg),
  id: String,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    case bot_registry.delete_bot(bots, id) {
      // The id rides the reply: the parent scrubs the thread registry's
      // provenance mirror for exactly this bot (BotRemoved).
      Ok(_) -> dispatch(BotDeletedOk(id))
      Error(error) -> dispatch(BotMutateFailed(bot_registry.describe(error)))
    }
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Toggle a per-row editor open-state: clicking the same row closes
/// it. Shared with the parent's thread rows (ui.gleam imports this
/// module; the reverse would be circular).
pub fn toggle_open(current: Option(String), id: String) -> Option(String) {
  case current {
    Some(open) if open == id -> None
    _ -> Some(id)
  }
}

/// A present-but-blank field is the same as an absent one: keyless on
/// create, keep-on-patch.
fn blank_as_none(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    _ -> Some(value)
  }
}

/// PATCH "keep" semantics for text fields: blank keeps the stored value.
fn keep_blank(value: String) -> Option(String) {
  blank_as_none(value)
}

// ---------------------------------------------------------------------------
// Event decoders
// ---------------------------------------------------------------------------

/// The add-provider form submits with its three fields riding the form
/// data (the composer pattern). The key field is a password input — its
/// value crosses here once and exists in the clear only inside the
/// registry call.
fn provider_submitted() -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case
      form_field(entries, "name"),
      form_field(entries, "base_url"),
      form_field(entries, "api_key")
    {
      Ok(name), Ok(base_url), api_key ->
        Submitted(name, base_url, result.unwrap(api_key, ""))
      _, _, _ -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

/// The edit form: blank fields keep the stored values (name, base URL,
/// and key alike — §11 PATCH semantics).
fn provider_edit_submitted(id: String) -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case
      form_field(entries, "name"),
      form_field(entries, "base_url"),
      form_field(entries, "api_key")
    {
      Ok(name), Ok(base_url), api_key ->
        EditSubmitted(id, name, base_url, result.unwrap(api_key, ""))
      _, _, _ -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

/// One required form field; an optional field defaults to "".
fn form_field(
  entries: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case list.find(entries, fn(entry) { entry.0 == name }) {
    Ok(#(_, value)) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

/// The add-bot form submits with its fields riding the form data (the
/// composer pattern). A select's chosen option rides form data the same
/// way an input's value does, so the provider picks up from `provider`.
/// The prompt is optional (blank = the global default).
fn bot_submitted() -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case
      form_field(entries, "name"),
      form_field(entries, "description"),
      form_field(entries, "provider"),
      form_field(entries, "model"),
      form_field(entries, "system_prompt"),
      form_field(entries, "tools")
    {
      Ok(name), description, Ok(provider_id), Ok(model), prompt, tools ->
        BotSubmitted(
          name,
          result.unwrap(description, ""),
          provider_id,
          model,
          result.unwrap(prompt, ""),
          result.unwrap(tools, ""),
          result.is_ok(form_field(entries, "chat_only")),
        )
      _, _, _, _, _, _ -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

/// The edit form: blank name/model/provider keep the stored values; a
/// blank system prompt CLEARS back to the default (a real change).
fn bot_edit_submitted(id: String) -> attr.Attribute(Msg) {
  event.on_submit(fn(entries) {
    case
      form_field(entries, "name"),
      form_field(entries, "description"),
      form_field(entries, "provider"),
      form_field(entries, "model"),
      form_field(entries, "system_prompt"),
      form_field(entries, "tools")
    {
      Ok(name), description, provider_id, Ok(model), prompt, tools ->
        BotEditSubmitted(
          id,
          name,
          result.unwrap(description, ""),
          result.unwrap(provider_id, ""),
          model,
          result.unwrap(prompt, ""),
          result.unwrap(tools, ""),
          result.is_ok(form_field(entries, "chat_only")),
        )
      _, _, _, _, _, _ -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])
}

/// One-line preview of a bot's prompt for the row's subtitle: collapse
/// whitespace runs (tabs and newlines too — the shared
/// `utility.collapse_whitespace`), then truncate with an ellipsis at
/// `limit` characters — the same shaping as `utility.shape_title`,
/// applied to presentation, not stored metadata.
fn truncate_preview(text: String, limit: Int) -> String {
  let collapsed = utility.collapse_whitespace(text)
  case string.length(collapsed) > limit {
    True -> string.slice(collapsed, 0, limit) <> "…"
    False -> collapsed
  }
}
