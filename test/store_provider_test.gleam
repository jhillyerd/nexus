//// Offline provider-store tests — P1 of docs/plans/multi-provider.md.
////
//// The `provider` table's seam contract against the in-memory mock:
//// ciphertext round-trips (the store never sees plaintext — an envelope
//// from `nexus/crypto` survives unchanged and decrypts on the other
//// side), the keep-vs-replace PATCH key semantics, the session FK, and
//// the delete guard. The pog-backed implementation is drift-gated in CI
//// by `squirrel check`; these tests pin the seam's semantics.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import nexus/crypto
import nexus/session
import nexus/store
import store_mock

/// Fixed 32-byte test key. Public test material — the real master key
/// only ever exists in `NEXUS_ENCRYPTION_KEY` (same convention as
/// crypto_test).
const test_key = "0123456789abcdef0123456789abcdef"

fn key() -> BitArray {
  bit_array.from_string(test_key)
}

fn provider(
  id: String,
  name: String,
  envelope: Option(BitArray),
  key_version: Int,
) -> store.StoredProvider {
  store.StoredProvider(
    id: id,
    name: name,
    base_url: "http://" <> id <> ".test/v1",
    api_key_encrypted: envelope,
    key_version: key_version,
    dialect: "openai",
    enabled: True,
    created_at: 1_700_000_000,
    updated_at: 1_700_000_000,
  )
}

fn summary(id: String, provider_id: String) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: provider_id,
    title: "",
    title_source: session.AutoTitle,
    model: "alias-1",
    pinned: False,
    archived: False,
    tags: [],
    tags_manual: [],
    tags_source: session.AutoTags,
    created_at: 1_700_000_000,
    last_active_at: 1_700_000_000,
    message_count: 1,
  )
}

pub fn ciphertext_round_trips_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)

  // What the registry will do in P2: encrypt under AAD = provider id.
  let assert Ok(envelope) = crypto.encrypt(key(), "p1", "sk-live-1")
  let assert Ok(Nil) =
    seam.insert_provider(provider("p1", "one", Some(envelope), 1))

  // The store hands back the same bytes — never normalized, never
  // decoded — and the envelope still decrypts under its AAD.
  let assert Ok(stored) = seam.get_provider("p1")
  stored.api_key_encrypted |> should.equal(Some(envelope))
  let assert Ok(plain) = case stored.api_key_encrypted {
    Some(env) -> crypto.decrypt(key(), "p1", env)
    None -> Error(crypto.InvalidEnvelope)
  }
  plain |> should.equal("sk-live-1")

  // Keyless is a first-class shape: NULL in, None out.
  let assert Ok(Nil) = seam.insert_provider(provider("p2", "two", None, 1))
  let assert Ok(keyless) = seam.get_provider("p2")
  keyless.api_key_encrypted |> should.equal(None)

  // List is id-ordered, ciphertext + metadata included.
  let assert Ok(all) = seam.list_providers()
  should.equal(all |> list.map(fn(p) { p.id }), ["p1", "p2"])
}

pub fn get_unknown_provider_errors_test() {
  let seam = store_mock.seam(store_mock.start())
  seam.get_provider("nope") |> should.be_error
}

pub fn duplicate_id_and_name_rejected_test() {
  let seam = store_mock.seam(store_mock.start())
  let assert Ok(Nil) = seam.insert_provider(provider("p1", "one", None, 1))
  // provider_pkey
  seam.insert_provider(provider("p1", "other", None, 1))
  |> should.be_error
  // provider_name_key
  seam.insert_provider(provider("p9", "one", None, 1))
  |> should.be_error
}

pub fn update_without_key_keeps_envelope_test() {
  let seam = store_mock.seam(store_mock.start())
  let assert Ok(envelope) = crypto.encrypt(key(), "p1", "sk-live-1")
  let assert Ok(Nil) =
    seam.insert_provider(provider("p1", "one", Some(envelope), 1))

  // A PATCH without an api_key: the caller's record carries None and a
  // different version, but replace_key = False must keep both.
  let assert Ok(Nil) =
    seam.update_provider(
      store.StoredProvider(
        ..provider("p1", "renamed", None, 9),
        base_url: "http://moved.test/v1",
        enabled: False,
      ),
      False,
    )

  let assert Ok(stored) = seam.get_provider("p1")
  stored.name |> should.equal("renamed")
  stored.base_url |> should.equal("http://moved.test/v1")
  stored.enabled |> should.be_false
  stored.api_key_encrypted |> should.equal(Some(envelope))
  stored.key_version |> should.equal(1)
}

pub fn update_replaces_and_clears_key_test() {
  let seam = store_mock.seam(store_mock.start())
  let assert Ok(envelope_1) = crypto.encrypt(key(), "p1", "sk-one")
  let assert Ok(envelope_2) = crypto.encrypt(key(), "p1", "sk-two")
  let assert Ok(Nil) =
    seam.insert_provider(provider("p1", "one", Some(envelope_1), 1))

  // Replace with a new envelope: new bytes, new version.
  let assert Ok(Nil) =
    seam.update_provider(provider("p1", "one", Some(envelope_2), 2), True)
  let assert Ok(replaced) = seam.get_provider("p1")
  replaced.api_key_encrypted |> should.equal(Some(envelope_2))
  replaced.key_version |> should.equal(2)

  // Replace with None: the provider becomes keyless (NULL), not "".
  let assert Ok(Nil) =
    seam.update_provider(provider("p1", "one", None, 3), True)
  let assert Ok(keyless) = seam.get_provider("p1")
  keyless.api_key_encrypted |> should.equal(None)
  keyless.key_version |> should.equal(3)
}

pub fn update_unknown_provider_is_noop_test() {
  let seam = store_mock.seam(store_mock.start())
  // Mirrors `update ... where id = $1` on a missing row: 0 rows, Ok.
  seam.update_provider(provider("ghost", "g", None, 1), True)
  |> should.equal(Ok(Nil))
  seam.list_providers() |> should.equal(Ok([]))
}

pub fn update_rejects_rename_collision_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(Nil) = seam.insert_provider(provider("p1", "one", None, 1))
  let assert Ok(Nil) = seam.insert_provider(provider("p2", "two", None, 1))

  // provider_name_key: renaming p1 onto p2's name is refused — no state
  // change, no update event.
  seam.update_provider(provider("p1", "two", None, 1), False)
  |> should.be_error
  let assert Ok(unchanged) = seam.get_provider("p1")
  unchanged.name |> should.equal("one")
  should.be_false(
    store_mock.events(mock)
    |> list.any(fn(event) {
      case event {
        store_mock.EvUpdateProvider("p1") -> True
        _ -> False
      }
    }),
  )
}

pub fn update_preserves_server_controlled_fields_test() {
  let seam = store_mock.seam(store_mock.start())
  let assert Ok(Nil) = seam.insert_provider(provider("p1", "one", None, 1))

  // The caller's record carries junk created_at/updated_at/dialect. The
  // SQL SET list ignores created_at and dialect (they stay from the
  // stored row) and stamps updated_at itself (`now()`), so the mock
  // must not let any of the three through.
  let assert Ok(Nil) =
    seam.update_provider(
      store.StoredProvider(
        ..provider("p1", "renamed", None, 1),
        created_at: 9_999_999_999,
        updated_at: 9_999_999_999,
        dialect: "weird",
      ),
      False,
    )
  let assert Ok(stored) = seam.get_provider("p1")
  stored.created_at |> should.equal(1_700_000_000)
  stored.dialect |> should.equal("openai")
  // Server-stamped: between the fixture's fixed 2023 epoch and the
  // caller's junk 2286 value lies the test's real wall clock.
  should.be_true(stored.updated_at > stored.created_at)
  should.be_true(stored.updated_at < 9_999_999_999)
}

pub fn session_pin_and_delete_guard_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(Nil) = seam.insert_provider(provider("p1", "one", None, 1))

  // The pin is part of the session row, visible in summaries.
  let assert Ok(Nil) = seam.insert_session(summary("s1", "p1"), "sys")
  let assert Ok(count) = seam.count_sessions_for_provider("p1")
  count |> should.equal(1)
  let assert Ok([stored]) = seam.list_summaries()
  stored.provider_id |> should.equal("p1")

  // Referenced providers cannot be deleted (the FK's RESTRICT is the
  // enforcement; the count is the registry's friendly 409 pre-check).
  seam.delete_provider("p1") |> should.be_error

  // Unreferenced after the session's own delete: the delete lands.
  let assert Ok(Nil) = seam.delete_session("s1")
  let assert Ok(0) = seam.count_sessions_for_provider("p1")
  let assert Ok(Nil) = seam.delete_provider("p1")
  seam.get_provider("p1") |> should.be_error
}

pub fn insert_session_with_unknown_provider_fails_test() {
  let seam = store_mock.seam(store_mock.start())
  // session_provider_id_fkey: no provider row, no session row.
  seam.insert_session(summary("s1", "ghost"), "sys") |> should.be_error
  seam.list_summaries() |> should.equal(Ok([]))
}
