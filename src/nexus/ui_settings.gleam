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
//// - results the parent must act on travel back as `Signal`s: every
////   mutation asks for a list reload, bot deletion scrubs the thread
////   registry mirror, and failures surface as notes in the chat log.
////
//// Like the rest of the UI, everything rendered here is a Lustre text
//// node — provider names, base URLs, model aliases, and failure reasons
//// are all hostile text; there is no `innerHTML` anywhere.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
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
import nexus/rescue
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

/// Live model aliases for one provider, fetched on demand for the bot
/// forms' model combobox: loading, the settled list, or failed (the
/// form's note is static — the reason stays diagnostics-only, on the
/// provider row's Test control). Cached per provider id for the
/// connection, so re-selecting a provider never re-fetches a settled
/// list.
pub type AliasState {
  AliasLoading
  AliasOk(aliases: List(String))
  AliasFailed
}

/// The bot forms' tool-picker catalog (issue #121): not yet fetched,
/// fetching, the settled catalog (the pinnable names plus the servers
/// whose live listing failed — their tools are display-omitted), or
/// failed (the form degrades to the free-text field). Cached per
/// connection — the alias-cache rule: the compiled ∪ plugin half is
/// process-static, and a server's liveness is re-read on the next
/// connection's fetch.
pub type ToolCatalogState {
  ToolCatalogIdle
  ToolCatalogLoading
  ToolCatalogOk(catalog: bot_registry.ToolCatalog)
  ToolCatalogFailed
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
    /// The provider whose live model list the OPEN bot form's model
    /// combobox is scoped to (the add form and the single inline editor
    /// are mutually exclusive, so one slot serves whichever is open).
    bot_alias_provider: Option(String),
    /// Per-provider cache of live model lists fetched for the bot
    /// forms' combobox (see `AliasState`).
    bot_aliases: Dict(String, AliasState),
    /// The tool picker (issue #121): the pinnable catalog, fetched on
    /// the first bot-form open (add or edit — they are mutually
    /// exclusive, so one slot serves whichever is open), the currently
    /// ticked names, and the Custom switch. OFF the picker is folded:
    /// the bot saves as the DEFAULT set (every built-in tool that
    /// works in this deployment, including ones added later). ON the
    /// checkboxes
    /// unfold; an EMPTY selection saves as chat-only — the switch is
    /// what disambiguates empty from default, retiring the old
    /// chat-only checkbox. Seeded from the edited bot's stored toolset
    /// (`Some` = ON, ticks = names; `None` = OFF).
    bot_tools: ToolCatalogState,
    bot_tools_picked: List(String),
    bot_tools_custom: Bool,
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
  /// A provider was created (the parent reloads the provider list).
  Created(provider: Provider)
  /// An update/enable/delete landed (the parent reloads the list).
  Mutated
  /// Any provider mutation failed; `reason` is the registry's fixed
  /// text (e.g. the delete 409 guard) — surfaced as a chat-log note.
  MutateFailed(reason: String)
  ModelsLoaded(id: String, aliases: List(String))
  TestFailed(id: String, reason: String)
  // ---- Bots (bots plan P1) ----
  /// The add-bot form toggled. Opening carries the provider select's
  /// default (the first provider) so the model combobox can scope to
  /// it; closing ignores it.
  BotAddToggled(provider: Option(String))
  /// The add-bot form's provider select changed: the model combobox
  /// re-scopes to the new provider's live model list.
  BotAddProviderPicked(provider_id: String)
  /// The edit form's provider select changed (same rule; the bot id
  /// rides so the pick is unambiguous per row).
  BotEditProviderPicked(bot_id: String, provider_id: String)
  /// The add-bot form submitted. `system_prompt` blank = the global
  /// default (resolved when a thread is created from the bot).
  /// `tools` is the raw free-text field (only rendered in the degraded
  /// picker mode); the toolset itself follows the Custom switch
  /// (parsing happens in the effect).
  BotSubmitted(
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: String,
    tools: String,
  )
  /// Toggling open carries the bot's provider (the select's
  /// preselected value) for the same combobox scoping, and its stored
  /// toolset to seed the tool picker's ticks (issue #121); closing
  /// ignores both.
  BotEditToggled(id: String, provider_id: String, tools: Option(List(String)))
  /// The edit form submitted: blank name/model/provider keep the stored
  /// values; a blank system prompt CLEARS back to the default (a real
  /// change — the two field classes in `bot.BotUpdate`). The tools field
  /// rides only for the degraded picker mode; the toolset always
  /// replaces, following the Custom switch — untouched resubmits the
  /// stored state verbatim (bots plan P2).
  BotEditSubmitted(
    id: String,
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: String,
    tools: String,
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
  /// A bot form's live model list landed (dispatched by the combobox
  /// fetch effect).
  BotAliasesLoaded(provider_id: String, aliases: List(String))
  /// The fetch failed (the combobox's note is static, so no reason
  /// rides).
  BotAliasesFailed(provider_id: String)
  // ---- Tool picker (issue #121) ----
  /// The Custom switch flipped: OFF folds the picker (default set), ON
  /// unfolds the checkboxes (empty selection = chat-only).
  BotToolsCustomToggled
  /// One picker checkbox flipped.
  BotToolToggled(name: String)
  /// The picker's All/None toggles: All ticks every catalog name, None
  /// clears the picks — which, saved with the switch ON, is chat-only
  /// (no tools at all).
  BotToolsAll
  BotToolsNone
  /// The pinnable tool catalog landed (dispatched by the picker fetch
  /// effect).
  BotToolsLoaded(catalog: bot_registry.ToolCatalog)
  /// The fetch failed: the picker degrades to the free-text field.
  BotToolsFetchFailed
}

/// What the sub-component asks the parent (chat) model to do. Signals
/// are returned synchronously from `update`; the parent folds them into
/// its own model/effects.
pub type Signal {
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
    bot_alias_provider: None,
    bot_aliases: dict.new(),
    bot_tools: ToolCatalogIdle,
    bot_tools_picked: [],
    bot_tools_custom: False,
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
        // The combobox slot goes with the forms; the per-provider
        // alias cache survives (still valid for the next open).
        bot_alias_provider: None,
      ),
      effect.none(),
      // Refresh both lists on tab switch so another session's new
      // providers or bots appear without a page reload.
      [ProvidersChanged, BotsChanged],
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

    Created(_provider) -> #(State(..state, last_error: None), effect.none(), [
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

    Mutated -> #(
      // A provider mutation (edit, enable/disable, delete) landed through
      // this same connection: drop the bot forms' alias cache so a
      // re-selected provider refetches instead of showing the pre-edit
      // list. The cache is connection-lifetime, not mutation-proof.
      State(
        ..state,
        last_error: None,
        bot_aliases: dict.new(),
        bot_alias_provider: None,
      ),
      effect.none(),
      [ProvidersChanged],
    )

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
    BotAddToggled(provider) -> {
      // Opening scopes the model combobox to the select's default (the
      // first provider) and fetches its live list unless a usable copy
      // is already cached; closing clears the slot.
      let opening = !state.bots_open
      let #(state, fetch) =
        scope_bot_form(
          State(
            ..state,
            bots_open: opening,
            bot_edit: None,
            bot_confirm: None,
            // One form section-wide, like the provider forms: opening
            // one closes the other section's open form/editor/confirm.
            open: False,
            edit: None,
            confirm: None,
          ),
          case opening {
            True -> provider
            False -> None
          },
          providers,
          models_timeout_ms,
        )
      // The tool picker (issue #121): a fresh form starts with the
      // switch OFF (default set), and the catalog fetches on the first
      // open (cached per connection).
      let #(state, tools_fetch) = case opening {
        True ->
          ensure_tool_catalog(
            State(..state, bot_tools_picked: [], bot_tools_custom: False),
            bots,
          )
        False -> #(state, effect.none())
      }
      let signals = case opening {
        True -> [ProvidersChanged, BotsChanged]
        False -> []
      }
      #(state, effect.batch([fetch, tools_fetch]), signals)
    }

    // The open bot form's provider select changed (add or edit — the
    // forms are mutually exclusive, so the pick lands in the same
    // slot): re-scope the model combobox. A stale fetched list must
    // not survive a provider switch (the create panel's ProviderPicked
    // rule); a cached settled list is reused as-is.
    BotAddProviderPicked(provider_id) -> {
      let #(state, fetch) =
        scope_bot_form(state, Some(provider_id), providers, models_timeout_ms)
      #(state, fetch, [])
    }

    BotEditProviderPicked(_bot_id, provider_id) -> {
      let #(state, fetch) =
        scope_bot_form(state, Some(provider_id), providers, models_timeout_ms)
      #(state, fetch, [])
    }

    BotSubmitted(
      name,
      description,
      provider_id,
      model,
      system_prompt,
      tools_text,
    ) -> {
      // The toolset's channel is the Custom switch (issue #121): OFF
      // saves the default set; ON the ticks (or, degraded, the text
      // field) are the toolset, empty = chat-only.
      let tools = form_toolset(state, tools_text)
      #(
        State(..state, bots_open: False),
        create_bot_effect(
          bots,
          name,
          description,
          provider_id,
          model,
          system_prompt,
          tools,
        ),
        [],
      )
    }

    BotCreated(_bot) -> #(State(..state, bot_last_error: None), effect.none(), [
      BotsChanged,
    ])

    BotEditToggled(id, provider_id, tools) -> {
      // Opening scopes the model combobox to the bot's own provider
      // (the select's preselected value), seeds the picker from the
      // bot's stored toolset — switch ON for any explicit set (a
      // chat-only bot unfolds to an empty grid), OFF for the default —
      // and fetches the catalog unless cached; closing clears the
      // slot.
      let opening = state.bot_edit != Some(id)
      let #(state, fetch) =
        scope_bot_form(
          State(
            ..state,
            bot_edit: toggle_open(state.bot_edit, id),
            bots_open: False,
            bot_confirm: None,
            // One form section-wide, like the provider forms: opening
            // one closes the other section's open form/editor/confirm.
            open: False,
            edit: None,
            confirm: None,
          ),
          case opening {
            True -> Some(provider_id)
            False -> None
          },
          providers,
          models_timeout_ms,
        )
      let #(state, tools_fetch) = case opening {
        True ->
          ensure_tool_catalog(
            State(
              ..state,
              bot_tools_picked: option.unwrap(tools, []),
              bot_tools_custom: option.is_some(tools),
            ),
            bots,
          )
        False -> #(state, effect.none())
      }
      let signals = case opening {
        True -> [ProvidersChanged, BotsChanged]
        False -> []
      }
      #(state, effect.batch([fetch, tools_fetch]), signals)
    }

    BotEditSubmitted(
      id,
      name,
      description,
      provider_id,
      model,
      system_prompt,
      tools_text,
    ) -> {
      // The toolset's channel is the Custom switch (see
      // `BotSubmitted`): the ticks are always seeded on open, so an
      // untouched form resubmits the stored state verbatim (bots plan
      // P2).
      let tools = form_toolset(state, tools_text)
      #(
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
        ),
        [],
      )
    }

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

    BotAliasesLoaded(id, aliases) ->
      // Only a live fetch settles into the cache: a late reply for a
      // superseded selection finds no waiting Loading entry and is
      // dropped (the Test control's stale-reply rule).
      case dict.get(state.bot_aliases, id) {
        Ok(AliasLoading) -> #(
          State(
            ..state,
            bot_aliases: dict.insert(state.bot_aliases, id, AliasOk(aliases)),
          ),
          effect.none(),
          [],
        )
        _ -> #(state, effect.none(), [])
      }

    BotAliasesFailed(id) ->
      case dict.get(state.bot_aliases, id) {
        Ok(AliasLoading) -> #(
          State(
            ..state,
            bot_aliases: dict.insert(state.bot_aliases, id, AliasFailed),
          ),
          effect.none(),
          [],
        )
        _ -> #(state, effect.none(), [])
      }

    // ---- Tool picker (issue #121) ----
    BotToolsCustomToggled ->
      // Flip the Custom switch: OFF folds the picker (the submitted
      // toolset is the DEFAULT set regardless of any ticks), ON unfolds
      // the checkboxes (an empty selection saves as chat-only).
      #(
        State(..state, bot_tools_custom: !state.bot_tools_custom),
        effect.none(),
        [],
      )

    BotToolToggled(name) ->
      // Flip one tick. The list's order is catalog order for known
      // names (`order_toolset` re-derives it at submit), so insertion
      // order here is irrelevant.
      case list.contains(state.bot_tools_picked, name) {
        True -> #(
          State(
            ..state,
            bot_tools_picked: list.filter(state.bot_tools_picked, fn(picked) {
              picked != name
            }),
          ),
          effect.none(),
          [],
        )
        False -> #(
          State(
            ..state,
            bot_tools_picked: list.append(state.bot_tools_picked, [name]),
          ),
          effect.none(),
          [],
        )
      }

    BotToolsAll ->
      // Tick every catalog name. With no settled catalog there is
      // nothing to tick (the buttons render only over the settled
      // list anyway).
      case state.bot_tools {
        ToolCatalogOk(bot_registry.ToolCatalog(names, _)) -> #(
          State(..state, bot_tools_picked: names),
          effect.none(),
          [],
        )
        _ -> #(state, effect.none(), [])
      }

    BotToolsNone -> #(State(..state, bot_tools_picked: []), effect.none(), [])

    BotToolsLoaded(catalog) ->
      // Settles the one picker slot (add and edit are mutually
      // exclusive). Picked ticks are NOT reset: they were seeded from
      // the edited bot's stored toolset, or are a fresh form's empty
      // set, and a late fetch must never disturb the user's ticks.
      #(State(..state, bot_tools: ToolCatalogOk(catalog)), effect.none(), [])

    BotToolsFetchFailed ->
      // The picker degrades to the free-text field (the combobox's
      // graceful-degradation rule); the next form open retries.
      #(State(..state, bot_tools: ToolCatalogFailed), effect.none(), [])
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
          // The select's default (the first provider) rides along so
          // the model combobox can scope to it on open.
          event.on_click(
            BotAddToggled(case provider_list {
              [] -> None
              [first, ..] -> Some(first.id)
            }),
          ),
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
      control(
        "Edit",
        "Edit this bot",
        BotEditToggled(id, b.provider_id, b.tools),
      ),
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
            bot_edit_provider_change(id),
          ],
          list.map(provider_list, fn(p) {
            html.option(
              [attr.value(p.id), attr.selected(p.id == b.provider_id)],
              p.name,
            )
          }),
        ),
        html.div([attr.class("combo-wrap")], [
          html.input([
            attr.type_("text"),
            attr.name("model"),
            attr.value(b.model),
            // Combobox: the scoped provider's live aliases suggest, free
            // entry stays possible (a stale alias saves fine — aliases
            // are not validated at thread create either). The combo
            // class draws the
            // select-style chevron and autocomplete=off keeps the
            // browser's own history/autofill popup out of the field —
            // no native datalist, so no popup over the form.
            attr.class("combo"),
            attr.attribute("autocomplete", "off"),
            attr.placeholder("Model alias"),
            attr.aria("label", "Model alias for " <> b.name),
          ]),
          bot_model_suggestions(state, state.bot_edit == Some(id)),
        ]),
        bot_model_options(
          state,
          state.bot_edit == Some(id),
          combobox_provider_name(provider_list, state.bot_alias_provider),
        ),
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
        // The tool picker (issue #121): the Custom switch folds it —
        // OFF the bot saves as the default set, ON the checkboxes
        // unfold over the ticks seeded from the stored toolset (empty
        // saves chat-only).
        bot_tools_picker(state),
        html.div([attr.class("provider-form-buttons")], [
          html.button([attr.type_("submit")], [html.text("Save")]),
          html.button(
            [
              attr.type_("button"),
              event.on_click(BotEditToggled(id, b.provider_id, b.tools)),
            ],
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
          bot_add_provider_change(),
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
      html.div([attr.class("combo-wrap")], [
        html.input([
          attr.type_("text"),
          attr.name("model"),
          // Combobox, same rule as the edit form: live suggestions over
          // free entry, chevron + autocomplete=off marking the field as
          // ours — no native datalist, so no popup over the form.
          attr.class("combo"),
          attr.attribute("autocomplete", "off"),
          attr.placeholder("Model alias"),
          attr.aria("label", "New bot model alias"),
        ]),
        bot_model_suggestions(state, state.bots_open),
      ]),
      bot_model_options(
        state,
        state.bots_open,
        combobox_provider_name(provider_list, state.bot_alias_provider),
      ),
      html.textarea(
        [
          attr.name("system_prompt"),
          attr.rows(3),
          attr.placeholder("System prompt (blank = default)"),
          attr.aria("label", "New bot system prompt"),
        ],
        "",
      ),
      // The tool picker (issue #121), same as the editor's: a fresh
      // form starts switch-OFF — the default set.
      bot_tools_picker(state),
      html.div([attr.class("provider-form-buttons")], [
        html.button([attr.type_("submit")], [html.text("Add bot")]),
        html.button(
          [attr.type_("button"), event.on_click(BotAddToggled(None))],
          [
            html.text("Cancel"),
          ],
        ),
      ]),
    ],
  )
}

/// The tool picker (issue #121): the pinnable catalog as checkboxes
/// with All/None toggles over the current ticks. Stored-but-unknown
/// names ticked on open render as extra checked boxes marked "(not in
/// catalog)" — keeping one resubmits it verbatim and refuses loudly at
/// save (never silently narrowed); dropping it is the user's untick.
/// A failed catalog fetch degrades to the free-text field (the
/// combobox's graceful-degradation rule); while loading the seeded
/// ticks render over a muted loading note. No box carries a `name`:
/// the picker is controlled state — only the degraded field rides the
/// submit's form data (as `tools`).
fn bot_tools_picker(state: State) -> Element(Msg) {
  // The Custom switch folds the picker (issue #121, toggle edition).
  // OFF the bot saves as the DEFAULT set — every tool that works in
  // this deployment, including ones added later — and only the switch
  // and that promise render. ON the boxes unfold; an EMPTY selection
  // saves as chat-only (the switch is what disambiguates empty from
  // default — the retired checkbox's whole job). A failed catalog
  // fetch degrades ON to the free-text field (the combobox's
  // graceful-degradation rule). The switch is a Pico `role=switch` —
  // the vendored theme styles it as a toggle, no custom CSS.
  html.fieldset(
    [attr.class("tool-picker")],
    list.append(
      [
        html.legend([], [html.text("Tools")]),
        html.label([attr.class("checkbox-field tool-picker-switch")], [
          html.input([
            attr.type_("checkbox"),
            attr.attribute("role", "switch"),
            attr.checked(state.bot_tools_custom),
            attr.aria("label", "Custom tools"),
            event.on_click(BotToolsCustomToggled),
          ]),
          html.text("Custom tools"),
        ]),
      ],
      case state.bot_tools_custom {
        False -> [
          html.span([attr.class("muted")], [
            html.text(
              "default: every built-in tool that works in this "
              <> "deployment, including ones added later",
            ),
          ]),
        ]
        True ->
          case state.bot_tools {
            ToolCatalogFailed -> [
              html.div([], [
                html.input([
                  attr.type_("text"),
                  attr.name("tools"),
                  attr.value(string.join(state.bot_tools_picked, ", ")),
                  attr.placeholder(
                    "Tools, comma-separated (blank = none, chat only)",
                  ),
                  attr.aria("label", "Bot tools"),
                ]),
                html.span([attr.class("muted")], [
                  html.text(
                    "tool list unavailable — enter names, comma-separated",
                  ),
                ]),
              ]),
            ]
            catalog -> {
              let boxes = case catalog {
                ToolCatalogOk(bot_registry.ToolCatalog(names, _unavailable)) -> {
                  let unknown =
                    list.filter(state.bot_tools_picked, fn(name) {
                      !list.contains(names, name)
                    })
                  list.append(
                    list.map(names, fn(name) {
                      tool_checkbox(
                        name,
                        list.contains(state.bot_tools_picked, name),
                        "",
                      )
                    }),
                    list.map(unknown, fn(name) {
                      tool_checkbox(name, True, "(not in catalog)")
                    }),
                  )
                }
                // Idle/loading: the seeded ticks render alone — a tick
                // is only "not in catalog" once there is a catalog to
                // be absent from; the full list joins when the fetch
                // settles.
                _ ->
                  list.map(state.bot_tools_picked, fn(name) {
                    tool_checkbox(name, True, "")
                  })
              }
              let controls = case catalog {
                ToolCatalogOk(bot_registry.ToolCatalog(_, unavailable)) ->
                  list.append(
                    [
                      html.button(
                        [
                          attr.type_("button"),
                          attr.title("Tick every listed tool"),
                          event.on_click(BotToolsAll),
                        ],
                        [html.text("All")],
                      ),
                      html.button(
                        [
                          attr.type_("button"),
                          attr.title(
                            "Untick all — saving with nothing ticked sends no tools at all",
                          ),
                          event.on_click(BotToolsNone),
                        ],
                        [html.text("None")],
                      ),
                    ],
                    case unavailable {
                      [] -> []
                      _ -> [
                        html.span([attr.class("muted")], [
                          html.text(
                            "unavailable (not listed): "
                            <> string.join(unavailable, ", "),
                          ),
                        ]),
                      ]
                    },
                  )
                _ -> []
              }
              list.append(
                [
                  html.div([attr.class("tool-picker-controls")], controls),
                  html.div([attr.class("tool-picker-list")], boxes),
                ],
                case catalog {
                  ToolCatalogOk(_) -> []
                  _ -> [
                    html.span([attr.class("muted")], [
                      html.text("loading tool list…"),
                    ]),
                  ]
                },
              )
            }
          }
      },
    ),
  )
}

/// One picker checkbox. Hostile-text rule: a tool name (reachable
/// unvalidated only through a store seed) is a Lustre text node beside
/// the input, never markup.
fn tool_checkbox(name: String, checked: Bool, note: String) -> Element(Msg) {
  html.label(
    [attr.class("checkbox-field")],
    list.append(
      [
        html.input([
          attr.type_("checkbox"),
          attr.checked(checked),
          event.on_click(BotToolToggled(name)),
        ]),
        html.text(name),
      ],
      case note {
        "" -> []
        _ -> [html.span([attr.class("muted")], [html.text(" " <> note)])]
      },
    ),
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

/// Scope the OPEN bot form's model combobox to `provider`: remember
/// the slot, and fetch the provider's live model list only when this
/// connection has no usable copy cached — a settled list is reused
/// without a second network call, an in-flight fetch is left alone,
/// and a failed one retries on the next selection (the static failure
/// note stands until then). The add form and the single inline editor
/// are mutually exclusive, so one slot serves whichever form is open.
fn scope_bot_form(
  state: State,
  provider: Option(String),
  providers: Subject(provider_registry.Msg),
  models_timeout_ms: Int,
) -> #(State, Effect(Msg)) {
  case provider {
    None -> #(State(..state, bot_alias_provider: None), effect.none())
    Some(id) ->
      case dict.get(state.bot_aliases, id) {
        Ok(AliasOk(_)) | Ok(AliasLoading) -> #(
          State(..state, bot_alias_provider: Some(id)),
          effect.none(),
        )
        _ -> #(
          State(
            ..state,
            bot_alias_provider: Some(id),
            bot_aliases: dict.insert(state.bot_aliases, id, AliasLoading),
          ),
          bot_aliases_effect(providers, id, models_timeout_ms),
        )
      }
  }
}

/// Fetch a provider's live model list for the bot forms' combobox. Off
/// the runtime loop (`models_effect` states the rule — a blocking
/// actor call must never run on the component's message loop), same
/// shared live-model budget.
fn bot_aliases_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
  models_timeout_ms: Int,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    process.spawn_unlinked(fn() {
      case provider_registry.list_models(providers, id, models_timeout_ms) {
        Ok(aliases) -> dispatch(BotAliasesLoaded(id, aliases))
        Error(_) -> dispatch(BotAliasesFailed(id))
      }
    })
    Nil
  })
}

/// The picker catalog's ask budget (issue #121). The registry-side
/// closure blocks once for the whole concurrent per-server collection
/// (~freeze_ask_ms + slack, regardless of server count), so this fixed
/// budget is generous with room for the registry's own queueing.
const catalog_ask_ms = 15_000

/// Fetch the pinnable tool catalog unless the slot already holds a
/// usable state (the alias-cache rule): Idle fetches, Loading waits,
/// Ok is cached for the connection, Failed retries on the next form
/// open.
fn ensure_tool_catalog(
  state: State,
  bots: Subject(bot_registry.Msg),
) -> #(State, Effect(Msg)) {
  case state.bot_tools {
    ToolCatalogOk(_) | ToolCatalogLoading -> #(state, effect.none())
    _ -> #(
      State(..state, bot_tools: ToolCatalogLoading),
      bot_tools_effect(bots),
    )
  }
}

/// Fetch the pinnable tool catalog off the runtime loop (the
/// `models_effect` rule — a blocking actor call must never run on the
/// component's message loop).
fn bot_tools_effect(bots: Subject(bot_registry.Msg)) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    process.spawn_unlinked(fn() {
      // The ask panics (gleam_erlang call semantics) if the registry
      // never answers within the budget — a wedged catalog worker or a
      // dead registry. Rescue turns that into the degraded field
      // instead of a stuck "loading tool list…".
      case
        rescue.rescue(fn() { bot_registry.tool_catalog(bots, catalog_ask_ms) })
      {
        Ok(catalog) -> dispatch(BotToolsLoaded(catalog))
        Error(_) -> dispatch(BotToolsFetchFailed)
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
/// list, so it is valid by construction — the FK is the backstop. The
/// toolset arrives pre-parsed from the form's picker/degrade channel
/// (`form_toolset`).
fn create_bot_effect(
  bots: Subject(bot_registry.Msg),
  name: String,
  description: String,
  provider_id: String,
  model: String,
  system_prompt: String,
  tools: Option(List(String)),
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
      tools: tools,
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
  tools: Option(List(String)),
) -> Effect(Msg) {
  let patch =
    bot.BotUpdate(
      name: keep_blank(name),
      description: Some(description),
      provider_id: keep_blank(provider_id),
      model: keep_blank(model),
      system_prompt: Some(system_prompt),
      // The toolset always replaces (picker ticks or the degraded
      // field, pre-parsed) — an untouched form resubmits the stored
      // list verbatim, because the picker seeds its ticks from the
      // stored set on open (bots plan P2, issue #121).
      tools: Some(tools),
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

/// The degraded free-text field → an explicit name list (trimmed,
/// blanks dropped); blank is `None`, which `form_toolset` lifts to
/// chat-only in the switch-ON mode this field only renders in. The
/// DEFAULT state is unreachable here by construction — the switch is
/// OFF and the whole field is folded away.
fn parse_tools_field(text: String) -> Option(List(String)) {
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

/// The submitted form's toolset — the Custom switch is the channel
/// (issue #121, toggle edition). OFF: the DEFAULT set (`None`), the
/// folded picker ignored entirely. ON: the ticks are the toolset, and
/// an EMPTY selection is chat-only (`Some([])`) — the switch is what
/// disambiguates empty from default, which is why the old chat-only
/// checkbox retired. The degraded free-text field (only rendered ON)
/// parses the same rule: blank text = chat-only.
fn form_toolset(state: State, tools_text: String) -> Option(List(String)) {
  case state.bot_tools_custom {
    False -> None
    True ->
      case state.bot_tools {
        ToolCatalogFailed ->
          case parse_tools_field(tools_text) {
            None -> Some([])
            some -> some
          }
        _ -> picked_to_toolset(state.bot_tools_picked, state.bot_tools)
      }
  }
}

/// The picker's ticks → the toolset: empty = chat-only (the Custom
/// switch is ON — see `form_toolset`), else the ticks in catalog
/// order.
fn picked_to_toolset(
  picked: List(String),
  catalog: ToolCatalogState,
) -> Option(List(String)) {
  case picked {
    [] -> Some([])
    names -> Some(order_toolset(names, catalog))
  }
}

/// The saved toolset's order — the envelope order of the resolved
/// schemas — follows the picker's catalog order (sorted display
/// order), with any stored-but-unknown name a user kept ticked
/// appended after. Keeping one refuses loudly at save (the registry's
/// catalog check), never silently narrowed; dropping it is the user's
/// untick.
fn order_toolset(
  picked: List(String),
  catalog: ToolCatalogState,
) -> List(String) {
  let known = case catalog {
    ToolCatalogOk(bot_registry.ToolCatalog(names, _)) -> names
    _ -> []
  }
  list.append(
    list.filter(known, fn(name) { list.contains(picked, name) }),
    list.filter(picked, fn(name) { !list.contains(known, name) }),
  )
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

/// The open bot form's suggestion list (bots section): the scoped
/// provider's live aliases as server-rendered options inside the
/// field's `.combo-wrap`. Hidden by default — `combobox_js` opens it on
/// focus, filters as you type, and fills the field on pick — so unlike
/// the browser's datalist popup it stays anchored to the field and only
/// covers following fields while open. Manual entry stays possible in
/// every state; the save rule stays non-empty-only, and thread create
/// does not validate aliases at all (a dead alias fails its first
/// turn).
fn bot_model_suggestions(state: State, open: Bool) -> Element(Msg) {
  case open {
    False -> element.none()
    True ->
      case state.bot_alias_provider {
        None -> element.none()
        Some(id) ->
          case dict.get(state.bot_aliases, id) {
            Ok(AliasOk(aliases)) ->
              html.div(
                [
                  attr.class("combo-list"),
                  attr.attribute("aria-hidden", "true"),
                  attr.aria("label", "Model alias suggestions"),
                ],
                list.map(aliases, fn(alias) {
                  html.button(
                    [
                      attr.type_("button"),
                      attr.class("combo-opt"),
                      attr.attribute("tabindex", "-1"),
                      attr.data("value", alias),
                    ],
                    [html.text(alias)],
                  )
                }),
              )
            _ -> element.none()
          }
      }
  }
}

/// The open bot form's model-combobox hint: names the source of the
/// suggestions once loaded, and offers manual entry while loading /
/// after a failure. The list itself renders inside the field's wrap
/// (see `bot_model_suggestions`).
fn bot_model_options(
  state: State,
  open: Bool,
  provider_name: Option(String),
) -> Element(Msg) {
  case open {
    False -> element.none()
    True ->
      case state.bot_alias_provider {
        None -> element.none()
        Some(id) ->
          case dict.get(state.bot_aliases, id) {
            Ok(AliasOk(_)) ->
              html.small([attr.class("muted")], [
                html.text(
                  "live suggestions: "
                  <> option.unwrap(provider_name, "the provider")
                  <> " model list — type to filter, pick one, or enter any alias",
                ),
              ])
            Ok(AliasLoading) ->
              html.small([attr.class("muted")], [
                html.text("loading the model list…"),
              ])
            _ ->
              html.small([attr.class("muted")], [
                html.text(
                  "could not load the model list — type the alias manually",
                ),
              ])
          }
      }
  }
}

/// The display name of the provider an open bot form's combobox is
/// scoped to, for the source hint under the field. `None` (no slot or
/// no match in the masked list) falls back to the generic wording at
/// the call site.
fn combobox_provider_name(
  provider_list: List(Provider),
  slot: Option(String),
) -> Option(String) {
  case slot {
    None -> None
    Some(id) ->
      case list.find(provider_list, fn(p) { p.id == id }) {
        Ok(p) -> Some(p.name)
        Error(_) -> None
      }
  }
}

/// The add-bot form's provider select: switching providers re-scopes
/// the model combobox's datalist (the picker-re-scope rule the old
/// create panel carried; the bot forms are its surviving surface).
fn bot_add_provider_change() -> attr.Attribute(Msg) {
  let decoder =
    decode.at(["target", "value"], decode.string)
    |> decode.map(BotAddProviderPicked)
  event.on("change", decoder)
  |> server_component.include(["target.value"])
}

/// The edit form's provider select (same rule, carrying the bot id so
/// the pick is unambiguous per row).
fn bot_edit_provider_change(id: String) -> attr.Attribute(Msg) {
  let decoder =
    decode.at(["target", "value"], decode.string)
    |> decode.map(BotEditProviderPicked(id, _))
  event.on("change", decoder)
  |> server_component.include(["target.value"])
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
