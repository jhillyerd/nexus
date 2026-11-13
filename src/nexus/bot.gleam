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

import gleam/list
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
    /// The toolset new threads snapshot (bots plan P2, the live template
    /// half): `None` = the CURRENT default set, resolved at thread
    /// creation so the bot stays a live template; `Some([])` =
    /// deliberately empty (a chat-only bot); `Some(names)` = an explicit
    /// list, validated against the compiled-in catalog at save time and
    /// re-validated at thread create. Order here is the wire order of
    /// the resolved schemas.
    tools: Option(List(String)),
    /// The inbound gate (bots plan P3a, issue #95): `False` blocks other
    /// bots from delivering messages into this bot's threads. Nothing
    /// ENFORCES it until P3c's delivery guard reads it — via a STORE
    /// read, never a bot-registry call (the §8 no-cross-registry-edges
    /// rule); the wire shape and Settings toggle already display and
    /// patch it. Create always opens the gate; PATCH moves it.
    allow_inbound: Bool,
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
    /// Same three-state semantics as `Bot.tools`; normalized by
    /// `validate_tools` (trimmed, blank entries dropped, deduplicated).
    tools: Option(List(String)),
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
    /// Three-state (present-null vs present-list vs absent must stay
    /// distinct, so the decoder nests): absent keeps the stored list;
    /// `Some(None)` clears back to the default; `Some(Some(names))`
    /// replaces with an explicit list (validated like a create).
    tools: Option(Option(List(String))),
    /// Present flips the inbound gate (bots plan P3a); absent keeps.
    allow_inbound: Option(Bool),
  )
}

/// Validation failures — closed, fixed strings, no operator input
/// echoed beyond what the HTTP layer chooses to include.
pub type BotError {
  InvalidName
  /// A blank model alias (the create-time rule: a thread only ever
  /// exists with a non-empty pin).
  InvalidModel
  /// A submitted toolset whose entries are all blank (the structural
  /// half of tool validation — see `validate_tools`). Unknown NAMES are
  /// refused by the registry's catalog check, not here: this module has
  /// no catalog access (it stays pure domain).
  InvalidTools
}

/// Fixed human-readable error text.
pub fn describe(error: BotError) -> String {
  case error {
    InvalidName -> "bot name must be non-empty after trimming"
    InvalidModel -> "bot model must be non-empty after trimming"
    InvalidTools ->
      "bot tools must contain at least one non-blank name when set"
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

/// Normalize a submitted toolset (bots plan P2): each entry trimmed,
/// blanks dropped, duplicates removed (first occurrence wins — a
/// toolset is a set, and duplicates would send one schema twice and
/// make the name tuple → envelope mapping order-dependent). `None`
/// passes through (the default). An input that held entries but
/// normalizes to nothing (`[""]`) is a structural refusal — the caller
/// meant an explicit list and wrote none; the DELIBERATE empty list is
/// written as `[]`, not `[""]`.
pub fn normalize_tools(
  tools: Option(List(String)),
) -> Result(Option(List(String)), BotError) {
  case tools {
    None -> Ok(None)
    Some(names) -> {
      let cleaned =
        names
        |> list.map(string.trim)
        |> list.filter(fn(name) { name != "" })
        |> list.unique
      case cleaned, names {
        [], [_, ..] -> Error(InvalidTools)
        _, _ -> Ok(Some(cleaned))
      }
    }
  }
}

/// Build a fresh row from validated params (id and stamps are the
/// registry's — it mints the id and owns the clock; the toolset is
/// normalized + catalog-checked before this runs).
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
    tools: params.tools,
    // The gate starts open (the column's DEFAULT true; there is no
    // create-time override — PATCH is the only way to close it).
    allow_inbound: True,
    created_at: now,
    updated_at: now,
  )
}

/// Merge a PATCH onto a row: absent fields keep the stored value, a
/// present `description`/`system_prompt` replaces (blank clears — see
/// `BotUpdate`'s two field classes), and `updated_at` moves to `now`.
/// The identity fields implement the blank-keep rule HERE, not just in
/// the decoders: a blank present value keeps the stored one, so this
/// function honours `BotUpdate`'s contract standalone (a prefilled
/// form's untouched field resubmits the stored value). The merged row
/// is a FULL row — the store's update is a plain replace (no gated
/// fields, unlike providers' key envelope).
pub fn apply_update(row: Bot, update: BotUpdate, now: Int) -> Bot {
  Bot(
    ..row,
    name: replace_identity(update.name, row.name),
    description: case update.description {
      Some(text) -> string.trim(text)
      None -> row.description
    },
    provider_id: replace_identity(update.provider_id, row.provider_id),
    model: replace_identity(update.model, row.model),
    system_prompt: case update.system_prompt {
      Some(text) -> normalize_prompt(Some(text))
      None -> row.system_prompt
    },
    tools: case update.tools {
      Some(tools) -> tools
      None -> row.tools
    },
    allow_inbound: case update.allow_inbound {
      Some(allow) -> allow
      None -> row.allow_inbound
    },
    updated_at: now,
  )
}

/// The identity fields' blank-keep rule, in one place: a present value
/// replaces (trimmed), a blank or absent one keeps the stored value.
fn replace_identity(update: Option(String), stored: String) -> String {
  case update {
    None -> stored
    Some(text) ->
      case string.trim(text) {
        "" -> stored
        trimmed -> trimmed
      }
  }
}

/// True when a PATCH would change nothing (the HTTP layer's "empty
/// patch" 400; the registry never sees all-absent patches).
pub fn empty_update(update: BotUpdate) -> Bool {
  option.is_none(update.name)
  && option.is_none(update.description)
  && option.is_none(update.provider_id)
  && option.is_none(update.model)
  && option.is_none(update.system_prompt)
  && option.is_none(update.tools)
  && option.is_none(update.allow_inbound)
}
