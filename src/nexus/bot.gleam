//// Pure bot domain (docs/plans/bots.md, Phase 1): the profile shape
//// other modules see, input validation, and the PATCH merge semantics.
//// A bot is a named, user-editable **creation-time template** — default
//// provider + model + system prompt that a new thread is created FROM.
//// Creating a thread copies the bot's values into the thread's
//// frozen-at-creation columns and keeps `bot_id` as a provenance
//// pointer; editing or deleting a bot never changes an existing thread.
////
//// Like `nexus/provider` this module never touches the network or the
//// store. Unlike providers, bots carry no secret material — nothing to
//// mask — so the stored row and the public shape are ONE type
//// (`Bot`), shared verbatim by the store seam and the registry the
//// same way `thread.ThreadMeta` is (issue #75's one-type rule).
//// Everything bot-sourced is hostile text under the UI contract.

import gleam/option.{type Option, None, Some}
import gleam/string

/// A bot profile — the stored row AND the public shape (no secrets, so
/// no masked twin; see the module docs). `system_prompt: None` is the
/// global default, resolved AT CREATION into the new thread's frozen
/// prompt (never at request time — the KV-cache contract's rule 2).
/// The store seam aliases this as `StoredBot` (one type, like
/// `thread.ThreadMeta`).
pub type Bot {
  Bot(
    id: String,
    /// Display + lookup key (unique across bots).
    name: String,
    /// Free-form one-liner shown in the settings list. Hostile text.
    description: String,
    /// The provider new threads pin (canonical registry id). Validated
    /// by the CALLER against the provider registry (no
    /// registry-to-registry edge); the FK is the backstop. A stale
    /// model alias is legitimate at rest — thread create re-validates
    /// it live and refuses dead ones.
    provider_id: String,
    /// The model alias new threads freeze.
    model: String,
    /// `None` = the global default prompt; `Some(prompt)` = used
    /// verbatim, never amended (the same default-versus-explicit rule
    /// as an explicit `NEXUS_SYSTEM_PROMPT`).
    system_prompt: Option(String),
    /// Epoch seconds.
    created_at: Int,
    /// Epoch seconds; bumped on update.
    updated_at: Int,
  )
}

/// Create input: the add-form / POST body fields. A blank
/// `system_prompt` (after trimming) means the default — there is no
/// distinct "empty explicit prompt" bot.
pub type BotParams {
  BotParams(
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: Option(String),
  )
}

/// PATCH input: present fields replace, absent fields keep. Two field
/// classes, deliberately: the identity fields (`name`, `model`,
/// `provider_id`) treat a BLANK present value as "keep" — they can
/// never be empty, so a prefilled form's untouched field just resubmits
/// the stored value — while the free-text fields (`description`,
/// `system_prompt`) treat a present value as a true replace (blank
/// CLEARS: back to "" and back to the default prompt respectively).
/// The HTTP/UI decoders keep absent and present-blank distinct so this
/// rule stays expressible.
pub type BotUpdate {
  BotUpdate(
    /// Blank or absent keeps the stored name.
    name: Option(String),
    /// Present replaces (blank clears); absent keeps.
    description: Option(String),
    /// `Some(id)` moves the bot to another provider (a friendly-400
    /// existence check against the provider registry lives with the
    /// CALLER; the FK is the backstop).
    provider_id: Option(String),
    /// Blank or absent keeps the stored model.
    model: Option(String),
    /// Present replaces (blank clears back to the default); absent
    /// keeps.
    system_prompt: Option(String),
  )
}

/// Validation failures — closed, fixed strings, no operator input
/// echoed beyond what the HTTP layer chooses to include.
pub type BotError {
  InvalidName
  /// A blank model alias (the create-time rule: a thread only ever
  /// exists with a non-empty pin).
  InvalidModel
}

/// Fixed human-readable error text.
pub fn describe(error: BotError) -> String {
  case error {
    InvalidName -> "bot name must be non-empty after trimming"
    InvalidModel -> "bot model must be non-empty after trimming"
  }
}

/// A display/lookup name: trimmed and non-empty, like providers.
pub fn validate_name(name: String) -> Result(String, BotError) {
  case string.trim(name) {
    "" -> Error(InvalidName)
    trimmed -> Ok(trimmed)
  }
}

/// The frozen pin a bot templates: trimmed and non-empty (an empty
/// model would only defer the refusal to thread create — refuse it at
/// save time, where the operator still has the form open).
pub fn validate_model(model: String) -> Result(String, BotError) {
  case string.trim(model) {
    "" -> Error(InvalidModel)
    trimmed -> Ok(trimmed)
  }
}

/// Normalize a submitted prompt: trimmed, blank collapses to `None`
/// (the default). The ONE rule for create and patch alike.
pub fn normalize_prompt(prompt: Option(String)) -> Option(String) {
  case prompt {
    Some(text) ->
      case string.trim(text) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

/// Build a fresh row from validated params (id and stamps are the
/// registry's — it mints the id and owns the clock).
pub fn to_row(
  params: BotParams,
  id: String,
  name: String,
  model: String,
  now: Int,
) -> Bot {
  Bot(
    id: id,
    name: name,
    description: string.trim(params.description),
    provider_id: params.provider_id,
    model: model,
    system_prompt: normalize_prompt(params.system_prompt),
    created_at: now,
    updated_at: now,
  )
}

/// Merge a PATCH onto a row: absent fields keep the stored value, a
/// present `description`/`system_prompt` replaces (blank clears — see
/// `BotUpdate`'s two field classes), and `updated_at` moves to `now`.
/// The merged row is a FULL row — the store's update is a plain
/// replace (no gated fields, unlike providers' key envelope).
pub fn apply_update(row: Bot, update: BotUpdate, now: Int) -> Bot {
  Bot(
    ..row,
    name: option.unwrap(update.name, row.name),
    description: case update.description {
      Some(text) -> string.trim(text)
      None -> row.description
    },
    provider_id: option.unwrap(update.provider_id, row.provider_id),
    model: option.unwrap(update.model, row.model),
    system_prompt: case update.system_prompt {
      Some(text) -> normalize_prompt(Some(text))
      None -> row.system_prompt
    },
    updated_at: now,
  )
}

/// True when a PATCH would change nothing (the HTTP layer's "empty
/// patch" 400; the registry never sees all-absent patches).
pub fn empty_update(update: BotUpdate) -> Bool {
  option.is_none(update.name)
  && option.is_none(update.description)
  && option.is_none(update.provider_id)
  && option.is_none(update.model)
  && option.is_none(update.system_prompt)
}
