//// The Settings sub-component: provider management (and, over time,
//// other settings categories) rendered as a full-page view inside the
//// chat component's shell. `nexus/ui` swaps its main area for this view
//// when the header's Settings button opens it, and lifts the
//// sub-component into the parent app with `element.map`/`effect.map`.
////
//// The split is deliberately one-way:
////
//// - the parent owns the masked provider list (it feeds the create
////   panel's picker and the session-row subtitles) and passes it into
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
import lustre/event
import lustre/server_component
import nexus/provider.{type Provider}
import nexus/provider_registry

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
  )
}

pub type Msg {
  /// A decoded event that carries nothing actionable (the submit
  /// decoders' fallback arm).
  Ignored
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
}

/// What the sub-component asks the parent (chat) model to do. Signals
/// are returned synchronously from `update`; the parent folds them into
/// its own model/effects.
pub type Signal {
  /// A provider was created: the parent applies the first-run picker
  /// re-aim, and (still in the auto-opened settings view) returns to
  /// chat.
  ProviderCreated(Provider)
  /// The masked list must be reloaded (a mutation landed).
  ProvidersChanged
  /// A mutation failed; the parent notes it in the chat log (settings
  /// has no log surface of its own).
  OpFailed(String)
}

pub fn init() -> State {
  State(
    open: False,
    edit: None,
    confirm: None,
    models: ModelsIdle,
    last_error: None,
  )
}

/// The sub-update. `providers` is the registry subject for this
/// connection's runtime (passed down from the parent model). Returns
/// the next state, the sub-effect (already typed to `Msg`; the parent
/// maps it), and the signals the parent must fold.
pub fn update(
  state: State,
  msg: Msg,
  providers: Subject(provider_registry.Msg),
) -> #(State, Effect(Msg), List(Signal)) {
  case msg {
    Ignored -> #(state, effect.none(), [])

    AddToggled -> #(
      State(..state, open: !state.open, edit: None, confirm: None),
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
      State(..state, confirm: Some(id), edit: None, open: False),
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
      [OpFailed(reason)],
    )

    TestRequested(id) -> #(
      State(..state, models: ModelsLoading(id)),
      models_effect(providers, id),
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
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/// The whole settings page. Sectioned so future settings categories
/// (each a `<section>` with its own `section-head`) slot in under the
/// Providers section without structural changes.
pub fn view(state: State, provider_list: List(Provider)) -> Element(Msg) {
  html.div([attr.id("settings-page"), attr.class("settings-page")], [
    html.section([attr.id("providers-panel")], [
      html.div([attr.class("section-head")], [
        html.h2([], [html.text("Settings · Providers")]),
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
    ]),
  ])
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
/// connection-test result. Mirrors the session rows.
fn provider_row(state: State, p: Provider) -> Element(Msg) {
  let id = p.id
  html.div([attr.class("provider-row"), attr.data("provider-id", id)], [
    html.div([attr.class("provider-main")], [
      html.strong([attr.class("provider-name")], [html.text(p.name)]),
      case p.enabled {
        True -> element.none()
        False -> span_badge("off", "disabled")
      },
      case p.has_key {
        True -> span_badge("", "key")
        False -> span_badge("", "keyless")
      },
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
    // sessions pin the provider (the 409 guard) — that refusal lands
    // as a note in the chat log.
    html.div(
      [
        attr.class("confirm-delete"),
        attr.hidden(state.confirm != Some(id)),
      ],
      [
        html.span([], [
          html.text(
            "Delete " <> p.name <> "? Sessions pinning it block the delete.",
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
/// parent's session rows reuse the same builder (ui.gleam imports this
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
/// as a chat-log note when sessions still pin the provider.
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
/// off-loop shape the registry itself uses for the fetch). The
/// generous timeout mirrors the create-panel aliases path.
fn models_effect(
  providers: Subject(provider_registry.Msg),
  id: String,
) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    process.spawn_unlinked(fn() {
      case provider_registry.list_models(providers, id, 60_000) {
        Ok(aliases) -> dispatch(ModelsLoaded(id, aliases))
        Error(error) ->
          dispatch(TestFailed(id, provider_registry.describe(error)))
      }
    })
    Nil
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Toggle a per-row editor open-state: clicking the same row closes
/// it. Shared with the parent's session rows (ui.gleam imports this
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
