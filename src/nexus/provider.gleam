//// Pure provider domain (docs/plans/multi-provider.md §4): the masked
//// metadata shape other modules see, input validation, and the PATCH
//// key semantics. This module never touches the network, the store, or
//// the crypto envelope's contents — `has_key` is the only key fact that
//// leaves it, so List/Get replies and the UI are structurally incapable
//// of leaking key material.
////
//// The registry (`nexus/provider_registry`) owns the impure half:
//// encrypt/decrypt against the store seam, caching, and resolution into
//// a runtime `openai.Endpoint`.

import gleam/option.{type Option, None, Some}
import gleam/string
import nexus/store.{type StoredProvider, StoredProvider}

/// Provider metadata as the registry hands it to callers (HTTP in P4,
/// UI in P5) — a `StoredProvider` with the envelope replaced by a
/// boolean. This is the ONLY provider shape that leaves the registry's
/// read paths.
pub type Provider {
  Provider(
    id: String,
    /// Display + lookup key (unique across providers).
    name: String,
    /// OpenAI-compatible base URL, ends `/v1`.
    base_url: String,
    /// Always `'openai'` today; carried so the UI can badge future
    /// dialects without a schema change.
    dialect: String,
    enabled: Bool,
    /// True when the row carries an encrypted API key. Never the key.
    has_key: Bool,
    /// Epoch seconds.
    created_at: Int,
    /// Epoch seconds; bumped on update.
    updated_at: Int,
  )
}

/// Create input. `api_key` is the PLAINTEXT key for the new provider —
/// it exists only inside the registry call that encrypts it; `None` (or
/// blank, after trimming) creates a keyless provider (local endpoints).
pub type ProviderParams {
  ProviderParams(name: String, base_url: String, api_key: Option(String))
}

/// PATCH input (§11): every field optional; an absent (or blank) field
/// keeps the stored value. `api_key` present-and-non-blank REPLACES the
/// stored key — there is deliberately no "remove the key" patch (HTTP
/// blank means keep; going keyless is a create-time choice).
pub type ProviderUpdate {
  ProviderUpdate(
    name: Option(String),
    base_url: Option(String),
    /// `Some(key)` replaces the stored key once encrypted by the
    /// registry; `None` keeps the existing envelope.
    api_key: Option(String),
    enabled: Option(Bool),
  )
}

/// Validation failures — closed, fixed strings, no operator input
/// echoed beyond what the HTTP layer chooses to include.
pub type ProviderError {
  InvalidName
  InvalidBaseUrl
}

/// Fixed human-readable error text.
pub fn describe(error: ProviderError) -> String {
  case error {
    InvalidName -> "provider name must be non-empty after trimming"
    InvalidBaseUrl ->
      "provider base URL should be the OpenAI-compatible base ending in /v1"
  }
}

/// Mask a stored row: the envelope collapses to `has_key`, everything
/// else rides along untouched.
pub fn mask(row: StoredProvider) -> Provider {
  Provider(
    id: row.id,
    name: row.name,
    base_url: row.base_url,
    dialect: row.dialect,
    enabled: row.enabled,
    has_key: option.is_some(row.api_key_encrypted),
    created_at: row.created_at,
    updated_at: row.updated_at,
  )
}

/// A display/lookup name: trimmed and non-empty. Everything else
/// (length, charset) is the UI's presentation concern, not storage's.
pub fn validate_name(name: String) -> Result(String, ProviderError) {
  case string.trim(name) {
    "" -> Error(InvalidName)
    trimmed -> Ok(trimmed)
  }
}

/// Normalize an operator-supplied base URL: trim whitespace and one
/// trailing `/`, then require the OpenAI-compatible `/v1` suffix. The
/// server-side twin of `BIFROST_BASE_URL`'s rule in `nexus/config`
/// (which the P3 hard cut deletes in favour of this one).
pub fn normalize_base_url(url: String) -> Result(String, ProviderError) {
  let trimmed = string.trim(url)
  let trimmed = case string.ends_with(trimmed, "/") {
    True -> string.drop_end(trimmed, 1)
    False -> trimmed
  }
  case string.ends_with(trimmed, "/v1") {
    True -> Ok(trimmed)
    False -> Error(InvalidBaseUrl)
  }
}

/// True when a PATCH carries a real replacement key (present and
/// non-blank after trimming). This single boolean is the registry's
/// `replace_key` for the store seam — the seam's `update_provider`
/// keeps the stored envelope exactly when this is `False`.
pub fn replaces_key(update: ProviderUpdate) -> Bool {
  case update.api_key {
    Some(key) -> string.trim(key) != ""
    None -> False
  }
}

/// Merge a PATCH onto a row's metadata (everything but the key fields,
/// which the registry owns): absent fields keep the stored value,
/// `updated_at` moves to `now`. The returned row's envelope/key_version
/// are the STORED ones — the registry decides replacement separately
/// via `replaces_key`.
pub fn apply_metadata(
  row: StoredProvider,
  update: ProviderUpdate,
  now: Int,
) -> StoredProvider {
  StoredProvider(
    ..row,
    name: option.unwrap(update.name, row.name),
    base_url: option.unwrap(update.base_url, row.base_url),
    enabled: option.unwrap(update.enabled, row.enabled),
    updated_at: now,
  )
}
