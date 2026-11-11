//// Offline bot-registry tests — Phase 1 of docs/plans/bots.md (#74).
////
//// The registry actor against the in-memory store mock: the CRUD
//// round-trip, the in-state duplicate-name pre-check, unknown-id
//// update/delete refusals, blank-model validation, and — the
//// §8-shaped no-cross-edges rule's other half — the PROVIDER side:
//// `delete_provider`'s 409 counts bots through the STORE, never a call
//// into this registry.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import nexus/bot
import nexus/bot_registry
import nexus/config
import nexus/openai
import nexus/provider
import nexus/provider_registry
import nexus/store
import store_mock

const test_key = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

fn test_config() {
  config.Config(
    encryption_key: test_key,
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 0,
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
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
  )
}

fn params(name: String) -> bot.BotParams {
  bot.BotParams(
    name: name,
    description: "a test bot",
    provider_id: store_mock.fixture_provider_id,
    model: "alias-1",
    system_prompt: None,
  )
}

fn start_registry(seam: store.Store) -> process.Subject(bot_registry.Msg) {
  let assert Ok(started) =
    bot_registry.start(seam, process.new_name("nexus_bot_registry_test"))
  started.data
}

/// Boot load: rows seeded straight into the store appear in the
/// registry's state; ids mint past every stored id.
pub fn boot_loads_and_mints_past_stored_ids_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_bot(bot.Bot(
      id: "b7",
      name: "seeded",
      description: "",
      provider_id: store_mock.fixture_provider_id,
      model: "alias-1",
      system_prompt: None,
      created_at: 1_700_000_000,
      updated_at: 1_700_000_000,
    ))
  let registry = start_registry(seam)

  let assert Ok(all) = bot_registry.list_bots(registry)
  should.equal(all |> list.map(fn(b) { b.id }), ["b7"])

  // The next mint is past b7, not b1 (no collision with stored rows).
  let assert Ok(created) = bot_registry.create_bot(registry, params("fresh"))
  should.equal(created.id, "b8")
}

pub fn crud_round_trip_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)

  // Create: blank description stays "", blank prompt means the default.
  let assert Ok(created) =
    bot_registry.create_bot(
      registry,
      bot.BotParams(
        name: "  Researcher  ",
        description: "",
        provider_id: store_mock.fixture_provider_id,
        model: " alias-2 ",
        system_prompt: Some("  "),
      ),
    )
  should.equal(created.name, "Researcher")
  should.equal(created.model, "alias-2")
  should.equal(created.system_prompt, None)

  // The write reached the store (write-through).
  let assert [stored] = store_mock.bots(mock)
  should.equal(stored.id, created.id)
  should.equal(stored.name, "Researcher")

  // Get by id.
  let assert Ok(got) = bot_registry.get_bot(registry, created.id)
  should.equal(got.id, created.id)

  // PATCH: present replaces, absent keeps; a blank prompt clears back
  // to the default.
  let assert Ok(updated) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: Some("described"),
        provider_id: None,
        model: Some("alias-3"),
        system_prompt: Some("be terse"),
      ),
    )
  should.equal(updated.name, "Researcher")
  should.equal(updated.description, "described")
  should.equal(updated.model, "alias-3")
  should.equal(updated.system_prompt, Some("be terse"))

  let assert Ok(cleared) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: None,
        provider_id: None,
        model: None,
        system_prompt: Some(""),
      ),
    )
  should.equal(cleared.system_prompt, None)
  // The blank model kept the stored pin.
  should.equal(cleared.model, "alias-3")

  // Delete: no guard (threads carry SET NULL provenance).
  let assert Ok(Nil) = bot_registry.delete_bot(registry, created.id)
  bot_registry.get_bot(registry, created.id)
  |> should.be_error
  should.equal(store_mock.bots(mock), [])
}

pub fn duplicate_name_pre_check_test() {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)

  let assert Ok(_) = bot_registry.create_bot(registry, params("taken"))
  // A second create onto the same name refuses (the bot_name UNIQUE is
  // the cross-instance backstop; this is the friendly pre-check).
  bot_registry.create_bot(registry, params("taken"))
  |> should.equal(Error(bot_registry.DuplicateName))

  // Renaming ANOTHER bot onto it refuses too.
  let assert Ok(other) = bot_registry.create_bot(registry, params("other"))
  bot_registry.update_bot(
    registry,
    other.id,
    bot.BotUpdate(
      name: Some("taken"),
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
    ),
  )
  |> should.equal(Error(bot_registry.DuplicateName))
}

pub fn unknown_id_update_delete_refused_test() {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)

  bot_registry.update_bot(
    registry,
    "b404",
    bot.BotUpdate(
      name: Some("x"),
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
    ),
  )
  |> should.equal(Error(bot_registry.Unknown))
  bot_registry.delete_bot(registry, "b404")
  |> should.equal(Error(bot_registry.Unknown))
}

pub fn invalid_name_and_model_refused_test() {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)

  bot_registry.create_bot(registry, bot.BotParams(..params("  "), model: "x"))
  |> should.equal(Error(bot_registry.InvalidName))
  bot_registry.create_bot(registry, bot.BotParams(..params("x"), model: "  "))
  |> should.equal(Error(bot_registry.InvalidModel))

  // A PATCH whose EFFECTIVE name/model (after blank-keeps) is invalid
  // refuses the same way.
  let assert Ok(created) = bot_registry.create_bot(registry, params("ok"))
  bot_registry.update_bot(
    registry,
    created.id,
    bot.BotUpdate(
      name: Some("   "),
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
    ),
  )
  // Blank name keeps the stored (valid) one — the patch is a no-op on
  // the name, so it succeeds.
  |> should.be_ok
}

/// The provider-side half of the no-cross-edges rule: the provider
/// registry's delete guard refuses while a bot pins the provider,
/// through the STORE count — and deleting the bot unpins it again.
pub fn provider_delete_guard_counts_bots_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let bots = start_registry(seam)

  let assert Ok(_) =
    bot_registry.create_bot(
      bots,
      bot.BotParams(..params("pinned"), provider_id: "p-test"),
    )

  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_bots_providers_test"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let providers = started_providers.data

  // The 409 arrives from the PROVIDER registry; it never called the
  // bot registry (only the store's count).
  provider_registry.delete(providers, "p-test")
  |> should.equal(Error(provider_registry.StillReferenced))

  // Deleting the bot unpins the provider again.
  let assert [created] = store_mock.bots(mock)
  let assert Ok(Nil) = bot_registry.delete_bot(bots, created.id)
  provider_registry.delete(providers, "p-test")
  |> should.be_ok
}

/// The fixture provider round-trips as masked metadata through the
/// registry this file's guard test also uses (shape sanity for the
/// read reply type).
pub fn provider_shape_test() {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_bots_providers_shape_test"),
      fn(_endpoint) { Error(openai.Transport("offline test")) },
    )
  let providers = started_providers.data
  let assert Ok([fixture]) = provider_registry.list_providers(providers)
  should.equal(
    fixture,
    provider.Provider(
      id: "p-test",
      name: "fixture",
      base_url: "http://fixture.test/v1",
      dialect: "openai",
      enabled: True,
      has_key: False,
      created_at: fixture.created_at,
      updated_at: fixture.updated_at,
    ),
  )
}
