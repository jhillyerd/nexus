//// Pure-domain tests for `nexus/provider` (multi-provider plan §16):
//// base-URL normalization, name validation, `has_key` masking, and the
//// present-key PATCH semantics — the pieces that keep key material out
//// of every metadata shape callers can see.

import gleam/option.{None, Some}
import gleeunit/should
import nexus/crypto
import nexus/provider
import nexus/store

fn row(envelope: option.Option(BitArray)) -> store.StoredProvider {
  store.StoredProvider(
    id: "p1",
    name: "Bifrost",
    base_url: "https://api.example/v1",
    api_key_encrypted: envelope,
    key_version: 1,
    dialect: "openai",
    enabled: True,
    created_at: 1_700_000_000,
    updated_at: 1_700_000_500,
  )
}

pub fn mask_reports_has_key_without_envelope_test() {
  // With a key: has_key True. A real envelope, so the masked shape is
  // exercised against actual ciphertext (bytes never asserted — only
  // their presence).
  let key = <<
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
    32,
  >>
  let assert Ok(envelope) = crypto.encrypt(key, "p1", "sk-test")
  let masked = provider.mask(row(Some(envelope)))
  masked.has_key |> should.be_true
  masked.id |> should.equal("p1")
  masked.name |> should.equal("Bifrost")
  masked.base_url |> should.equal("https://api.example/v1")
  masked.dialect |> should.equal("openai")
  masked.enabled |> should.be_true
  masked.created_at |> should.equal(1_700_000_000)
  masked.updated_at |> should.equal(1_700_000_500)

  // Keyless: has_key False. (The Provider type has no envelope field at
  // all — this is the structural no-key-leak guarantee.)
  provider.mask(row(None)).has_key |> should.be_false
}

pub fn validate_name_trims_and_rejects_blank_test() {
  provider.validate_name("  Bifrost ") |> should.equal(Ok("Bifrost"))
  provider.validate_name("") |> should.equal(Error(provider.InvalidName))
  provider.validate_name("   ") |> should.equal(Error(provider.InvalidName))
}

pub fn normalize_base_url_requires_v1_suffix_test() {
  provider.normalize_base_url("https://api.example/v1")
  |> should.equal(Ok("https://api.example/v1"))
  // One trailing slash is trimmed, surrounding whitespace too.
  provider.normalize_base_url("  https://api.example/v1/ ")
  |> should.equal(Ok("https://api.example/v1"))
  provider.normalize_base_url("https://api.example")
  |> should.equal(Error(provider.InvalidBaseUrl))
  provider.normalize_base_url("https://api.example/v2")
  |> should.equal(Error(provider.InvalidBaseUrl))
  provider.normalize_base_url("")
  |> should.equal(Error(provider.InvalidBaseUrl))
}

pub fn replaces_key_only_for_present_non_blank_test() {
  // Absent: keep the stored envelope.
  provider.replaces_key(provider.ProviderUpdate(None, None, None, None))
  |> should.be_false
  // Blank means keep (HTTP PATCH: blank key field = keep existing).
  provider.replaces_key(provider.ProviderUpdate(None, None, Some("   "), None))
  |> should.be_false
  // Present and non-blank: replace.
  provider.replaces_key(provider.ProviderUpdate(None, None, Some("k"), None))
  |> should.be_true
}

pub fn apply_metadata_merges_and_bumps_timestamp_test() {
  let patch =
    provider.ProviderUpdate(
      name: Some("  Renamed "),
      base_url: Some("https://other.example/v1"),
      api_key: None,
      enabled: Some(False),
    )
  let updated = provider.apply_metadata(row(None), patch, 1_700_000_999)
  updated.name |> should.equal("  Renamed ")
  updated.base_url |> should.equal("https://other.example/v1")
  updated.enabled |> should.be_false
  updated.updated_at |> should.equal(1_700_000_999)
  // Untouched by the merge: identity, envelope, key bookkeeping.
  updated.id |> should.equal("p1")
  updated.api_key_encrypted |> should.equal(None)
  updated.key_version |> should.equal(1)
  updated.created_at |> should.equal(1_700_000_000)

  // An empty patch keeps every stored field and only bumps updated_at.
  let kept =
    provider.apply_metadata(
      updated,
      provider.ProviderUpdate(None, None, None, None),
      1_700_001_000,
    )
  kept.name |> should.equal("  Renamed ")
  kept.base_url |> should.equal("https://other.example/v1")
  kept.enabled |> should.be_false
  kept.updated_at |> should.equal(1_700_001_000)
}
