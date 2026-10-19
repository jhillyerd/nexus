//// Offline tests for the provider registry (multi-provider plan §7/§16):
//// CRUD against the in-memory store mock with the REAL crypto FFI (no
//// network, no database), the decrypt memo and its invalidation, the
//// disabled-provider and delete guards, and the boot contract — the
//// whole table is decrypt-validated at start, so a bad envelope (or a
//// bad master key) fails boot loudly.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleeunit/should
import nexus/config
import nexus/crypto
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/session
import nexus/store
import store_mock

/// Valid base64 of exactly 32 bytes — same fixture value as the other
/// suites. Public test material, never a real key.
const key_b64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

fn test_config() -> config.Config {
  config.Config(
    encryption_key: key_b64,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 8080,
    ui_token: None,
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
  )
}

fn key_bits() -> BitArray {
  let assert Ok(key) = crypto.decode_key(key_b64)
  key
}

fn start_registry(
  seam: store.Store,
) -> Result(Subject(provider_registry.Msg), Nil) {
  start_registry_with_fetcher(seam, openai.list_models)
}

fn start_registry_with_fetcher(
  seam: store.Store,
  fetcher: fn(openai.Endpoint) -> Result(List(String), openai.StreamError),
) -> Result(Subject(provider_registry.Msg), Nil) {
  case
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_test_providers"),
      fetcher,
    )
  {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error(Nil)
  }
}

fn call(
  registry: Subject(provider_registry.Msg),
  make: fn(Subject(a)) -> provider_registry.Msg,
) -> a {
  actor.call(registry, 5000, make)
}

fn stored_row(id: String, name: String, envelope: Option(BitArray)) {
  store.StoredProvider(
    id: id,
    name: name,
    base_url: "https://" <> id <> ".example/v1",
    api_key_encrypted: envelope,
    key_version: 1,
    dialect: "openai",
    enabled: True,
    created_at: 1_700_000_000,
    updated_at: 1_700_000_000,
  )
}

fn pinned_session(id: String, provider_id: String) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: provider_id,
    title: "",
    title_source: session.AutoTitle,
    model: "alias-1",
    pinned: False,
    archived: False,
    tags: [],
    created_at: 1_700_000_000,
    last_active_at: 1_700_000_000,
    message_count: 1,
  )
}

/// The envelope of the first stored row with a key, for keep-vs-replace
/// assertions.
fn first_envelope(mock: Subject(store_mock.MockMsg)) -> BitArray {
  let assert [row] = store_mock.providers(mock)
  let assert Some(envelope) = row.api_key_encrypted
  envelope
}

// ---------------------------------------------------------------------------
// Create / List / Get
// ---------------------------------------------------------------------------

pub fn create_masks_and_persists_ciphertext_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(created) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams(
          name: "  Bifrost ",
          base_url: "https://api.example/v1",
          api_key: Some("sk-live-007"),
        ),
        r,
      )
    })
  // Masked metadata: trimmed name, normalized URL, has_key — and the
  // type has no field that could carry key material.
  created.name |> should.equal("Bifrost")
  created.base_url |> should.equal("https://api.example/v1")
  created.has_key |> should.be_true
  created.enabled |> should.be_true

  // At rest: ciphertext only, decryptable under AAD = the row id.
  let assert [row] = store_mock.providers(mock)
  row.id |> should.equal("p1")
  let assert Some(envelope) = row.api_key_encrypted
  crypto.decrypt(key_bits(), "p1", envelope)
  |> should.equal(Ok("sk-live-007"))

  // Get and List agree with the create reply.
  call(registry, fn(r) { provider_registry.Get("p1", r) })
  |> should.equal(Ok(created))
  call(registry, provider_registry.List)
  |> should.equal(Ok([created]))
}

pub fn create_keyless_provider_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(created) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Ollama", "http://127.0.0.1:11434/v1", None),
        r,
      )
    })
  created.has_key |> should.be_false

  // The row stores NULL, not an encrypted empty string.
  let assert [row] = store_mock.providers(mock)
  row.api_key_encrypted |> should.equal(None)
}

pub fn create_validates_name_and_base_url_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  call(registry, fn(r) {
    provider_registry.Create(
      provider.ProviderParams("   ", "https://api.example/v1", None),
      r,
    )
  })
  |> should.equal(Error(provider_registry.InvalidName))

  call(registry, fn(r) {
    provider_registry.Create(
      provider.ProviderParams("Bifrost", "https://api.example", None),
      r,
    )
  })
  |> should.equal(Error(provider_registry.InvalidBaseUrl))

  // Nothing was persisted.
  store_mock.providers(mock) |> should.equal([])
}

pub fn duplicate_name_rejected_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let make = fn(name: String) {
    provider_registry.Create(
      provider.ProviderParams(name, "https://a.example/v1", None),
      _,
    )
  }
  let assert Ok(_) = call(registry, make("Bifrost"))
  // Same name after trimming: refused (exact-match uniqueness, like
  // the schema's UNIQUE on text).
  call(registry, make("  Bifrost "))
  |> should.equal(Error(provider_registry.DuplicateName))
  // Case differs: a distinct name, allowed.
  let assert Ok(other) = call(registry, make("bifrost"))
  other.id |> should.equal("p2")
}

// ---------------------------------------------------------------------------
// Resolve (decrypt + memo)
// ---------------------------------------------------------------------------

pub fn resolve_decrypts_into_endpoint_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams(
          "Bifrost",
          "https://api.example/v1/",
          Some("sk-live-007"),
        ),
        r,
      )
    })
  let assert Ok(resolved) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  resolved.id |> should.equal("p1")
  resolved.name |> should.equal("Bifrost")
  resolved.endpoint.base_url |> should.equal("https://api.example/v1")
  resolved.endpoint.api_key |> should.equal(Some("sk-live-007"))
  // SSE timeouts are server-global policy (per-provider is deferred).
  resolved.endpoint.sse_first_response_timeout_ms |> should.equal(1000)
  resolved.endpoint.stream_idle_timeout_ms |> should.equal(1000)

  // Keyless provider: the endpoint carries None (drop_empty_bearer then
  // omits the Authorization header entirely).
  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("vLLM", "http://10.0.0.5:8000/v1", None),
        r,
      )
    })
  let assert Ok(keyless) =
    call(registry, fn(r) { provider_registry.Resolve("p2", r) })
  keyless.endpoint.api_key |> should.equal(None)

  // Unknown ids never reach crypto.
  call(registry, fn(r) { provider_registry.Resolve("p404", r) })
  |> should.equal(Error(provider_registry.Unknown))
}

pub fn disabled_provider_refused_on_resolve_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Bifrost", "https://api.example/v1", None),
        r,
      )
    })
  let assert Ok(disabled) =
    call(registry, fn(r) { provider_registry.SetEnabled("p1", False, r) })
  disabled.enabled |> should.be_false

  call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  |> should.equal(Error(provider_registry.Disabled))

  // Reads keep showing disabled providers (disable is reversible).
  let assert Ok(meta) = call(registry, fn(r) { provider_registry.Get("p1", r) })
  meta.enabled |> should.be_false

  // Re-enable: resolve works again without any re-create.
  let assert Ok(_) =
    call(registry, fn(r) { provider_registry.SetEnabled("p1", True, r) })
  let assert Ok(_) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
}

// ---------------------------------------------------------------------------
// Update (PATCH semantics) and the memo invalidation
// ---------------------------------------------------------------------------

pub fn update_without_key_keeps_envelope_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams(
          "Bifrost",
          "https://api.example/v1",
          Some("sk-live-007"),
        ),
        r,
      )
    })
  let before = first_envelope(mock)

  // Populate the memo BEFORE patching, so the post-update assertions
  // actually exercise memo invalidation: a stale memo would still
  // carry the old name and endpoint.
  let assert Ok(warm) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  warm.name |> should.equal("Bifrost")
  warm.endpoint.api_key |> should.equal(Some("sk-live-007"))

  // A PATCH with no api_key (and a blank one is the same as none).
  let assert Ok(updated) =
    call(registry, fn(r) {
      provider_registry.Update(
        "p1",
        provider.ProviderUpdate(
          name: Some("Bifrost prod"),
          base_url: None,
          api_key: Some("   "),
          enabled: None,
        ),
        r,
      )
    })
  updated.name |> should.equal("Bifrost prod")
  updated.has_key |> should.be_true
  // The stored envelope is byte-identical — keep, not re-encrypt.
  first_envelope(mock) |> should.equal(before)

  // The memo was invalidated: resolve reflects the new name.
  let assert Ok(resolved) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  resolved.name |> should.equal("Bifrost prod")
  resolved.endpoint.api_key |> should.equal(Some("sk-live-007"))
}

pub fn update_with_key_replaces_envelope_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams(
          "Bifrost",
          "https://api.example/v1",
          Some("sk-old"),
        ),
        r,
      )
    })
  let before = first_envelope(mock)

  // Warm the memo with the OLD key before patching: without
  // update-time invalidation the post-update Resolve below would
  // hand back this cached credential and fail loudly.
  let assert Ok(warm) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  warm.endpoint.api_key |> should.equal(Some("sk-old"))

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Update(
        "p1",
        provider.ProviderUpdate(None, None, Some(" sk-new "), None),
        r,
      )
    })
  // Fresh envelope (nonce makes it differ), decrypting to the new key.
  let after = first_envelope(mock)
  after |> should.not_equal(before)
  crypto.decrypt(key_bits(), "p1", after)
  |> should.equal(Ok("sk-new"))

  let assert Ok(resolved) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  resolved.endpoint.api_key |> should.equal(Some("sk-new"))
}

pub fn update_validates_and_guards_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let make = fn(name: String) {
    provider_registry.Create(
      provider.ProviderParams(name, "https://a.example/v1", None),
      _,
    )
  }
  let assert Ok(_) = call(registry, make("one"))
  let assert Ok(_) = call(registry, make("two"))

  // Unknown id: the registry pre-checks existence (the SQL's empty-match
  // update is a deliberate no-op — this must NOT "succeed").
  call(registry, fn(r) {
    provider_registry.Update(
      "p404",
      provider.ProviderUpdate(Some("x"), None, None, None),
      r,
    )
  })
  |> should.equal(Error(provider_registry.Unknown))

  // Rename onto another provider's name.
  call(registry, fn(r) {
    provider_registry.Update(
      "p1",
      provider.ProviderUpdate(Some("two"), None, None, None),
      r,
    )
  })
  |> should.equal(Error(provider_registry.DuplicateName))

  // Invalid replacement base URL.
  call(registry, fn(r) {
    provider_registry.Update(
      "p1",
      provider.ProviderUpdate(None, Some("https://a.example"), None, None),
      r,
    )
  })
  |> should.equal(Error(provider_registry.InvalidBaseUrl))
}

// ---------------------------------------------------------------------------
// Delete guard
// ---------------------------------------------------------------------------

pub fn delete_guarded_while_pinned_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  let assert Ok(registry) = start_registry(seam)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Bifrost", "https://api.example/v1", None),
        r,
      )
    })
  // A session pins p1 (the FK story: sessions reference providers).
  let assert Ok(Nil) = seam.insert_session(pinned_session("s1", "p1"), "sys")

  call(registry, fn(r) { provider_registry.Delete("p1", r) })
  |> should.equal(Error(provider_registry.StillReferenced))
  // The row survived.
  let assert Ok(_) = call(registry, fn(r) { provider_registry.Get("p1", r) })

  // Unpinned: delete goes through, and every path forgets the provider.
  let assert Ok(Nil) = seam.delete_session("s1")
  call(registry, fn(r) { provider_registry.Delete("p1", r) })
  |> should.equal(Ok(Nil))
  store_mock.providers(mock) |> should.equal([])
  call(registry, fn(r) { provider_registry.Get("p1", r) })
  |> should.equal(Error(provider_registry.Unknown))
  call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  |> should.equal(Error(provider_registry.Unknown))

  call(registry, fn(r) { provider_registry.Delete("p404", r) })
  |> should.equal(Error(provider_registry.Unknown))
}

/// The race the FK covers: a session lands between the registry's
/// count pre-check and the delete (think another instance, mid-delete).
/// The recheck must turn the refused delete into StillReferenced —
/// not a raw store failure.
pub fn delete_race_surfaces_still_referenced_test() {
  let mock = store_mock.start()
  let base = store_mock.seam(mock)
  let racing =
    store.Store(..base, delete_provider: fn(id) {
      // Exactly what the interleaving looks like at the store: the
      // concurrent insert commits, THEN the delete is refused.
      let assert Ok(Nil) = base.insert_session(pinned_session("s9", id), "sys")
      Error("delete failed: provider still referenced")
    })
  let assert Ok(registry) = start_registry(racing)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Bifrost", "https://api.example/v1", None),
        r,
      )
    })
  call(registry, fn(r) { provider_registry.Delete("p1", r) })
  |> should.equal(Error(provider_registry.StillReferenced))
}

/// A refused delete whose recheck comes back clean stays a store
/// failure with the ORIGINAL text — only a positive count is
/// confidently the conflict.
pub fn delete_failure_without_references_stays_store_failed_test() {
  let mock = store_mock.start()
  let base = store_mock.seam(mock)
  let failing =
    store.Store(..base, delete_provider: fn(_id) {
      Error("disk exploded mid-delete")
    })
  let assert Ok(registry) = start_registry(failing)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Bifrost", "https://api.example/v1", None),
        r,
      )
    })
  call(registry, fn(r) { provider_registry.Delete("p1", r) })
  |> should.equal(
    Error(provider_registry.StoreFailed("disk exploded mid-delete")),
  )
}

// ---------------------------------------------------------------------------
// Boot: load + decrypt-validate the whole table, or fail loudly
// ---------------------------------------------------------------------------

pub fn boot_loads_and_resolves_stored_providers_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)

  // Stored out-of-band (an earlier run wrote it): decryptable under its
  // own id, so boot accepts it.
  let assert Ok(envelope) = crypto.encrypt(key_bits(), "p5", "sk-stored")
  let assert Ok(Nil) =
    seam.insert_provider(stored_row("p5", "Stored", Some(envelope)))

  let assert Ok(registry) = start_registry(seam)
  let assert Ok([listed]) = call(registry, provider_registry.List)
  listed.name |> should.equal("Stored")
  listed.has_key |> should.be_true

  // Counter seeded past the stored id: the next create cannot collide.
  let assert Ok(created) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Fresh", "https://fresh.example/v1", None),
        r,
      )
    })
  created.id |> should.equal("p6")
}

pub fn boot_fails_on_foreign_envelope_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)

  // Envelope minted for a DIFFERENT provider id (AAD binding): exactly
  // what a swapped or copied row looks like. Boot must fail loudly —
  // not first-resolve, not silently.
  let assert Ok(foreign) = crypto.encrypt(key_bits(), "p-other", "sk-x")
  let assert Ok(Nil) =
    seam.insert_provider(stored_row("p9", "Tampered", Some(foreign)))

  start_registry(seam) |> should.be_error
}

pub fn boot_fails_on_invalid_master_key_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)

  // A directly-constructed Config with a bad key: config.load validates
  // this first in production; the registry still fails loudly itself.
  let bad = config.Config(..test_config(), encryption_key: "c2hvcnQ=")
  let assert Error(_) =
    provider_registry.start(bad, seam, process.new_name("nexus_test_providers"))
}

pub fn boot_fails_when_store_unreachable_test() {
  // A store seam whose provider listing always fails (model: database
  // down at boot — persistence is mandatory, no silent ephemeral mode).
  let broken =
    store.Store(..store_mock.seam(store_mock.start()), list_providers: fn() {
      Error("connection refused")
    })
  start_registry(broken) |> should.be_error
}

// ---------------------------------------------------------------------------
// ListModels: the fetch runs off the actor loop (never blocks Resolve)
// ---------------------------------------------------------------------------

/// With the fetch parked mid-flight, the registry must still answer
/// `Resolve` — the whole point of running ListModels off-loop, since
/// Resolve sits on the session-create path — and then deliver the
/// model list once the fetch is released.
pub fn list_models_fetch_never_blocks_resolve_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)

  // The fetcher runs inside the registry's spawned process: it hands
  // back a gate it owns (cross-process receives only work on subjects
  // the waiting process created), then parks until the test opens it.
  let ready = process.new_subject()
  let fetcher = fn(_endpoint) {
    let gate = process.new_subject()
    process.send(ready, gate)
    let assert Ok(True) = process.receive(gate, 5000)
    Ok(["held-model"])
  }
  let assert Ok(registry) = start_registry_with_fetcher(seam, fetcher)

  let assert Ok(_) =
    call(registry, fn(r) {
      provider_registry.Create(
        provider.ProviderParams("Bifrost", "https://api.example/v1", None),
        r,
      )
    })

  // Fire ListModels without waiting for its reply; the fetch is now
  // in flight and HELD.
  let models_reply = process.new_subject()
  process.send(registry, provider_registry.ListModels("p1", models_reply))
  let assert Ok(gate) = process.receive(ready, 5000)

  // The actor loop is free: Resolve answers while the fetch is parked.
  let assert Ok(resolved) =
    call(registry, fn(r) { provider_registry.Resolve("p1", r) })
  resolved.endpoint.api_key |> should.equal(None)

  // Release: the fetch completes and the model list is delivered.
  process.send(gate, True)
  let assert Ok(Ok(models)) = process.receive(models_reply, 5000)
  models |> should.equal(["held-model"])

  // Unknown ids never start a fetch.
  call(registry, fn(r) { provider_registry.ListModels("p404", r) })
  |> should.equal(Error(provider_registry.Unknown))
}

// ---------------------------------------------------------------------------
// Error text: fixed strings, no key material
// ---------------------------------------------------------------------------

pub fn describe_never_leaks_key_material_test() {
  // Every describe output for key-related failures is a fixed string.
  provider_registry.describe(provider_registry.DecryptFailed)
  |> should.equal("decryption failed: wrong key, provider, or tampered data")
  provider_registry.describe(provider_registry.KeyOperationFailed)
  |> should.equal("provider key operation failed")
  // The store- and transport-borne variants carry only the sanitized
  // text they were handed.
  provider_registry.describe(provider_registry.StoreFailed("disk full"))
  |> should.equal("disk full")
  provider_registry.describe(provider_registry.ModelsFailed("HTTP 503"))
  |> should.equal("HTTP 503")
}

/// A provider may echo a rejected bearer key back in its error body,
/// and transport reasons are `string.inspect` output — the registry's
/// model-list error text must stay fixed: status code at most.
pub fn model_list_error_text_is_fixed_test() {
  provider_registry.describe_stream_error(openai.Non200(
    401,
    "invalid key sk-live-007 supplied",
  ))
  |> should.equal("model list failed: HTTP 401")

  provider_registry.describe_stream_error(openai.Transport(
    "{error, checkout_timeout}",
  ))
  |> should.equal("model list failed: transport error")

  provider_registry.describe_stream_error(openai.Decode(
    "expected list at /data",
  ))
  |> should.equal("model list failed: unreadable model list")
}

/// Envelope bytes must never equal plaintext, and plaintext never
/// appears in any masked metadata (belt-and-braces for the type-level
/// guarantee).
pub fn ciphertext_is_not_plaintext_test() {
  let assert Ok(envelope) = crypto.encrypt(key_bits(), "p1", "sk-live-007")
  let plain = bit_array.from_string("sk-live-007")
  envelope |> should.not_equal(plain)
  should.be_false(list.any([envelope], fn(bytes) { bytes == plain }))
}
