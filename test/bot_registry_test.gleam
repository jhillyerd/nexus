//// Offline bot-registry tests — Phase 1 of docs/plans/completed/bots.md (#74).
////
//// The registry actor against the in-memory store mock: the CRUD
//// round-trip, the in-state duplicate-name pre-check, unknown-id
//// update/delete refusals, blank-model validation, and — the
//// §8-shaped no-cross-edges rule's other half — the PROVIDER side:
//// `delete_provider`'s 409 counts bots through the STORE, never a call
//// into this registry.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/boot
import nexus/bot
import nexus/bot_registry
import nexus/config
import nexus/log
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
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_cache_ttl_ms: 600_000,
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
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: None,
    workspace_sandbox: config.SandboxNone,
    workspace_sandbox_bin: None,
    workspace_toolchain: None,
    workspace_state_dir: None,
    workspace_max_memory_mb: 1024,
    workspace_max_pids: 64,
    env_timeout_ms: 60_000,
    env_max_output_bytes: 100_000,
    node_idle_days: 7,
    log_level: log.Info,
    // Bots P3c: the delivery hop guard; 4 = the shipped default.
    max_bot_hops: 4,
  )
}

fn params(name: String) -> bot.BotParams {
  bot.BotParams(
    name: name,
    description: "a test bot",
    provider_id: store_mock.fixture_provider_id,
    model: "alias-1",
    system_prompt: None,
    tools: None,
  )
}

fn start_registry(seam: store.Store) -> process.Subject(bot_registry.Msg) {
  start_registry_with_validator(seam, fn(names) { Ok(names) })
}

/// `validate_tools` is the injected catalog seam; most tests pass the
/// identity (tool NAMES are not their subject), the toolset tests pass a
/// closed fake catalog.
fn start_registry_with_validator(
  seam: store.Store,
  validate_tools: bot_registry.ValidateTools,
) -> process.Subject(bot_registry.Msg) {
  start_registry_with_catalog(seam, validate_tools, fn() {
    bot_registry.ToolCatalog([], [])
  })
}

/// Same, with the picker-catalog seam injected (issue #121).
fn start_registry_with_catalog(
  seam: store.Store,
  validate_tools: bot_registry.ValidateTools,
  tool_catalog: bot_registry.CatalogFn,
) -> process.Subject(bot_registry.Msg) {
  let assert Ok(started) =
    bot_registry.start(
      seam,
      process.new_name("nexus_bot_registry_test"),
      validate_tools,
      tool_catalog,
    )
  started.data
}

/// The catalog ask (issue #121) answers the injected closure's value
/// verbatim — the actor adds nothing, drops nothing.
pub fn tool_catalog_ask_answers_the_closure_test() {
  let mock = store_mock.start()
  let registry =
    start_registry_with_catalog(
      store_mock.seam(mock),
      fn(names) { Ok(names) },
      fn() { bot_registry.ToolCatalog(["http_fetch"], ["mcpsrv"]) },
    )
  bot_registry.tool_catalog(registry, 5000)
  |> should.equal(bot_registry.ToolCatalog(["http_fetch"], ["mcpsrv"]))
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
      tools: None,
      allow_inbound: True,
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

/// The counter DRIFT case: another nexus over the SAME store mints
/// ids with its own counter, and its rows land after this registry's
/// boot (empty here — counter 0). A mint re-seeds past the whole stored
/// table first, so `b1` is never re-minted under a row minted elsewhere
/// — the multi-instance 502 the browser rig hit: a secondary instance's
/// first bot collided with the main instance's `b1` (bot_pkey).
pub fn mint_reseeds_past_rows_minted_elsewhere_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)
  let assert Ok(all) = bot_registry.list_bots(registry)
  should.equal(all, [])
  // Another instance's mint lands after this registry's boot.
  let assert Ok(Nil) =
    seam.insert_bot(bot.Bot(
      id: "b3",
      name: "minted-elsewhere",
      description: "",
      provider_id: store_mock.fixture_provider_id,
      model: "alias-1",
      system_prompt: None,
      tools: None,
      allow_inbound: True,
      created_at: 1_700_000_000,
      updated_at: 1_700_000_000,
    ))
  // The mint re-seeds past it instead of colliding on b1.
  let assert Ok(created) = bot_registry.create_bot(registry, params("fresh"))
  should.equal(created.id, "b4")
  // The healed rows also serve the duplicate-name pre-check: a name
  // minted elsewhere answers the friendly 409, not the store's
  // unique-name backstop via StoreFailed.
  bot_registry.create_bot(registry, params("minted-elsewhere"))
  |> should.equal(Error(bot_registry.DuplicateName))
  // The store holds both rows — no lost update (List sorts by name,
  // so assert on the id set).
  let assert Ok(all) = bot_registry.list_bots(registry)
  should.equal(
    all |> list.map(fn(b) { b.id }) |> list.sort(by: string.compare),
    ["b3", "b4"],
  )
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
        tools: None,
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
        tools: None,
        allow_inbound: None,
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
        tools: None,
        allow_inbound: None,
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

/// The inbound gate (bots plan P3a, issue #95): creates open it, a
/// one-field PATCH flips it — write-through into the store mock AND the
/// registry's in-state read path — an absent field keeps it, and the
/// gate rides the full-row update like every other field.
pub fn allow_inbound_patch_round_trip_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let registry = start_registry(seam)

  // Create: the gate starts open (the column's DEFAULT true; no
  // create-time override exists).
  let assert Ok(created) = bot_registry.create_bot(registry, params("gated"))
  should.be_true(created.allow_inbound)

  // Patch closed: the reply, the registry's state, and the stored row
  // all read closed.
  let assert Ok(closed) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: Some(False),
      ),
    )
  should.be_false(closed.allow_inbound)
  let assert Ok(from_state) = bot_registry.get_bot(registry, created.id)
  should.be_false(from_state.allow_inbound)
  let assert [stored] = store_mock.bots(mock)
  should.be_false(stored.allow_inbound)

  // A patch WITHOUT the field keeps the stored gate (and the write is
  // still a full-row replace — the closed value must survive it).
  let assert Ok(untouched) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: Some("described"),
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: None,
      ),
    )
  should.equal(untouched.description, "described")
  should.be_false(untouched.allow_inbound)
  let assert Ok(reread) = bot_registry.get_bot(registry, created.id)
  should.be_false(reread.allow_inbound)

  // Reopen.
  let assert Ok(opened) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: Some(True),
      ),
    )
  should.be_true(opened.allow_inbound)
  let assert [final] = store_mock.bots(mock)
  should.be_true(final.allow_inbound)
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

  // Case is not a distinguishing feature (#127): delivery resolves
  // names case-insensitively, so "TAKEN" is the SAME name.
  bot_registry.create_bot(registry, params("TAKEN"))
  |> should.equal(Error(bot_registry.DuplicateName))

  // Renaming ANOTHER bot onto it refuses too — case-insensitively.
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
      tools: None,
      allow_inbound: None,
    ),
  )
  |> should.equal(Error(bot_registry.DuplicateName))
  bot_registry.update_bot(
    registry,
    other.id,
    bot.BotUpdate(
      name: Some("TAKEN"),
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
      tools: None,
      allow_inbound: None,
    ),
  )
  |> should.equal(Error(bot_registry.DuplicateName))

  // Renaming a bot to its OWN name in a different case is allowed —
  // a display-case change, not a collision (own id is excluded).
  let assert Ok(_) =
    bot_registry.update_bot(
      registry,
      other.id,
      bot.BotUpdate(
        name: Some("OTHER"),
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: None,
      ),
    )
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
      tools: None,
      allow_inbound: None,
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
  // Environments plan Phase 1: `system` is the reserved roster-message
  // author — a bot by that name would render its messages as status
  // lines on every path. Distinct from InvalidName so the message
  // names the actual restriction (cubic PR review).
  bot_registry.create_bot(
    registry,
    bot.BotParams(..params("system"), model: "x"),
  )
  |> should.equal(Error(bot_registry.ReservedName))
  should.equal(
    bot_registry.describe(bot_registry.ReservedName),
    "bot name 'system' is reserved (roster messages are authored by"
      <> " \"system\")",
  )
  bot_registry.create_bot(registry, bot.BotParams(..params("x"), model: "  "))
  |> should.equal(Error(bot_registry.InvalidModel))

  // A PATCH whose only identity fields are blank keeps the stored
  // values: the EFFECTIVE name/model are the stored (valid) ones, so
  // the patch succeeds — identity refusals come from the create-time
  // checks above, never from a blank keep.
  let assert Ok(created) = bot_registry.create_bot(registry, params("ok"))
  let assert Ok(kept) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: Some("   "),
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: None,
      ),
    )
  should.equal(kept.name, "ok")
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

/// The provider twin of `mint_reseeds_past_rows_minted_elsewhere_test`:
/// the same boot-only counter, the same multi-instance drift (p<N>
/// ids minted by another nexus on the same store), the same re-seed at
/// mint time. `p-test` (non-numeric) deliberately leaves the counter
/// alone — only `p<N>`-shaped ids count.
pub fn provider_mint_reseeds_past_rows_minted_elsewhere_test() {
  let seam = store_mock.seam(store_mock.start())
  let assert Ok(started_providers) =
    provider_registry.start_with_model_fetcher(
      test_config(),
      seam,
      process.new_name("nexus_bots_providers_drift_test"),
      fn(_endpoint) { Ok(["alias-1"]) },
    )
  let providers = started_providers.data
  let assert Ok([]) = provider_registry.list_providers(providers)
  // Another instance's mint lands after this registry's boot.
  let now = 1_700_000_000
  let assert Ok(Nil) =
    seam.insert_provider(store.StoredProvider(
      id: "p9",
      name: "minted-elsewhere",
      base_url: "http://elsewhere.test/v1",
      api_key_encrypted: None,
      key_version: 1,
      dialect: "openai",
      enabled: True,
      created_at: now,
      updated_at: now,
    ))
  // The mint re-seeds past it instead of colliding on p1.
  let assert Ok(created) =
    provider_registry.create(
      providers,
      provider.ProviderParams(
        name: "fresh",
        base_url: "http://fresh.test/v1",
        api_key: None,
      ),
    )
  should.equal(created.id, "p10")
  // The healed rows serve the duplicate-name pre-check too.
  provider_registry.create(
    providers,
    provider.ProviderParams(
      name: "minted-elsewhere",
      base_url: "http://elsewhere.test/v1",
      api_key: None,
    ),
  )
  |> should.equal(Error(provider_registry.DuplicateName))
}

// ---------------------------------------------------------------------------
// Per-bot toolsets (bots plan P2): save-time validation and normalization.
// ---------------------------------------------------------------------------

/// A fake catalog checker over a closed name list, reporting the first
/// unknown name exactly like `tools.by_names` does.
fn catalog_checker(known: List(String)) -> bot_registry.ValidateTools {
  fn(names) {
    case list.find(names, fn(name) { !list.contains(known, name) }) {
      Ok(unknown) -> Error("unknown tool name: " <> unknown)
      Error(_) -> Ok(names)
    }
  }
}

/// The catalog seam refuses unknown names; the registry surfaces the
/// checker's reason verbatim (`InvalidTools`), on create and patch alike,
/// and the store never sees the rejected rows.
pub fn unknown_tool_name_refused_test() {
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let registry =
    start_registry_with_validator(
      seam,
      catalog_checker([
        "http_fetch",
        "web_search",
      ]),
    )

  bot_registry.create_bot(
    registry,
    bot.BotParams(
      ..params("tooled"),
      tools: Some([
        "http_fetch",
        "nope",
      ]),
    ),
  )
  |> should.equal(Error(bot_registry.InvalidTools("unknown tool name: nope")))

  let assert Ok(created) = bot_registry.create_bot(registry, params("plain"))
  bot_registry.update_bot(
    registry,
    created.id,
    bot.BotUpdate(
      name: None,
      description: None,
      provider_id: None,
      model: None,
      system_prompt: None,
      tools: Some(Some(["web_search", "ghost"])),
      allow_inbound: None,
    ),
  )
  |> should.equal(Error(bot_registry.InvalidTools("unknown tool name: ghost")))

  // Only the one VALID create reached the store; both rejections were
  // refused before any write.
  let assert [plain_stored] = store_mock.bots(mock)
  should.equal(plain_stored.id, created.id)
}

/// Save-time normalization (the structural half): entries are trimmed,
/// blanks dropped, duplicates removed — first occurrence wins, because a
/// toolset is a set and the name tuple is the cache key. An explicit
/// empty list is the legitimate chat-only set; `[""]` is a refusal (the
/// caller meant a list and wrote none).
pub fn toolset_normalization_test() {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  let registry =
    start_registry_with_validator(
      seam,
      catalog_checker([
        "http_fetch",
        "web_search",
      ]),
    )

  let assert Ok(created) =
    bot_registry.create_bot(
      registry,
      bot.BotParams(
        ..params("messy"),
        tools: Some([
          "  http_fetch ",
          "",
          "web_search",
          "http_fetch",
        ]),
      ),
    )
  should.equal(created.tools, Some(["http_fetch", "web_search"]))

  // Chat-only survives normalization verbatim.
  let assert Ok(chat_only) =
    bot_registry.create_bot(
      registry,
      bot.BotParams(..params("quiet"), tools: Some([])),
    )
  should.equal(chat_only.tools, Some([]))

  // `[""]` refuses: an explicit list with no name in it.
  bot_registry.create_bot(
    registry,
    bot.BotParams(..params("blank"), tools: Some(["   "])),
  )
  |> should.equal(
    Error(bot_registry.InvalidTools(bot.describe(bot.InvalidTools))),
  )

  // PATCH three-state: a present list replaces (normalized), a present
  // null clears back to the default, absent keeps.
  let assert Ok(replaced) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: Some(Some(["web_search"])),
        allow_inbound: None,
      ),
    )
  should.equal(replaced.tools, Some(["web_search"]))

  let assert Ok(cleared) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: None,
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: Some(None),
        allow_inbound: None,
      ),
    )
  should.equal(cleared.tools, None)

  let assert Ok(kept) =
    bot_registry.update_bot(
      registry,
      created.id,
      bot.BotUpdate(
        name: None,
        description: Some("a description"),
        provider_id: None,
        model: None,
        system_prompt: None,
        tools: None,
        allow_inbound: None,
      ),
    )
  should.equal(kept.tools, None)
  should.equal(kept.description, "a description")
}

// ---------------------------------------------------------------------------
// Environments plan Phase 1: the boot validation closure's env gate
// ---------------------------------------------------------------------------

/// The REAL boot closure (`boot.bot_validate_tools`): a bot template
/// naming env tools is refused while no workspace root exists — the
/// same refusal a thread create gets — and accepted once one does.
/// Offline-provable because the closure was extracted from boot's
/// wiring; no tree is started.
pub fn boot_tool_validation_env_gate_test() {
  let assert Ok(no_root) =
    config.from_env(fn(name) {
      case name {
        "NEXUS_ENCRYPTION_KEY" ->
          Ok("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
        _ -> Error(Nil)
      }
    })
  let with_root = config.Config(..no_root, workspace_root: Some("/srv/nx"))
  // Refused without a root, naming the honest reason.
  boot.bot_validate_tools(no_root, dict.new(), dict.new())(["bash"])
  |> should.equal(Error(
    "workspace tools require NEXUS_WORKSPACE_ROOT to be set",
  ))
  // Accepted with one (the catalog resolves env names config-
  // independently — the freeze overrides the gate past creation).
  boot.bot_validate_tools(with_root, dict.new(), dict.new())([
    "bash",
    "read_file",
  ])
  |> should.equal(Ok(["bash", "read_file"]))
  // Plain names keep the loud unknown refusal either way.
  boot.bot_validate_tools(with_root, dict.new(), dict.new())(["nope"])
  |> should.equal(Error("unknown tool name: nope"))
}
