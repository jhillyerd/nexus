//// Offline node-store tests (docs/plans/environments.md, Phase 2b).
////
//// The `node` table's seam contract against the in-memory mock: pair
//// (insert), stateless verification lookup (get-by-name), boot load
//// (list), recency bump (touch), revoke (delete), and the unique-name
//// constraint. The pog-backed implementation is drift-gated in CI by
//// `squirrel check`; these pin the seam's SEMANTICS, not the SQL.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import nexus/config
import nexus/log
import nexus/node
import nexus/store
import nexus/store/persist
import nexus/thread
import nexus/timing
import store_mock

fn seed_thread(seam: store.Store, id: String) -> Nil {
  store_mock.ensure_fixture_provider(seam)
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        id: id,
        // The mock enforces thread_provider_id_fkey: the fixture
        // provider the mock boots with.
        provider_id: store_mock.fixture_provider_id,
        model: "alias-1",
        meta: thread.ThreadMeta(
          title: "",
          title_source: thread.AutoTitle,
          pinned: False,
          tags: [],
          tags_manual: [],
          tags_source: thread.AutoTags,
          archived: False,
          bot_id: None,
          parent_thread_id: None,
          created_at: 1_700_000_000,
        ),
        last_active_at: 1_700_000_000,
        toolset: [],
        workspace_root: None,
        workspaces: None,
        roster: None,
        message_count: 1,
      ),
      "sys",
    )
  Nil
}

fn row(id: String, thread_id: String, name: String) -> store.StoredNode {
  node.Node(
    id: id,
    thread_id: thread_id,
    name: name,
    token_hash: node.hash_token("token-" <> name),
    created_at: 1_700_000_000,
    last_seen_at: None,
  )
}

pub fn node_pair_and_verify_roundtrip_test() {
  let seam = store_mock.seam(store_mock.start())
  seed_thread(seam, "t1")
  let n = row("n1", "t1", "proxmox-2")
  seam.insert_node(n) |> should.be_ok

  // Stateless verification: look up by (THREAD, name), check the
  // token hash — per-thread node names, so the thread scopes it.
  let assert Ok(stored) = seam.get_thread_node("t1", "proxmox-2")
  stored.id |> should.equal("n1")
  stored.thread_id |> should.equal("t1")
  node.verify_token("token-proxmox-2", stored.token_hash) |> should.be_true
  node.verify_token("wrong", stored.token_hash) |> should.be_false

  // The same name under ANOTHER thread does not resolve: a different
  // node identity (the /node/ws auth is scoped by the pair).
  seed_thread(seam, "t2")
  seam.get_thread_node("t2", "proxmox-2") |> should.be_error
  // Unknown name refuses (no row to verify against).
  seam.get_thread_node("t1", "ghost") |> should.be_error
}

/// `list_nodes` returns nodes id-sorted, NOT insertion-sorted: insert a
/// lexically-greater id first, then a lexically-lesser one, so an
/// insertion-order (unsorted) implementation yields the wrong sequence
/// and fails.
pub fn node_list_is_id_sorted_not_insertion_sorted_test() {
  let seam = store_mock.seam(store_mock.start())
  seed_thread(seam, "t1")
  // Insertion order: n9, then n2. Lexical order: n2, then n9.
  seam.insert_node(row("n9", "t1", "zeta")) |> should.be_ok
  seam.insert_node(row("n2", "t1", "alpha")) |> should.be_ok
  let assert Ok(nodes) = seam.list_nodes()
  let assert [a, b] = nodes
  a.id |> should.equal("n2")
  b.id |> should.equal("n9")
}

pub fn node_name_is_unique_per_thread_test() {
  let seam = store_mock.seam(store_mock.start())
  seed_thread(seam, "t1")
  seed_thread(seam, "t2")
  seam.insert_node(row("n1", "t1", "proxmox-2")) |> should.be_ok
  // The same (thread, name) refuses (node_thread_name UNIQUE).
  seam.insert_node(row("n2", "t1", "proxmox-2")) |> should.be_error
  // The SAME NAME under a DIFFERENT thread is a different node —
  // allowed (the environments 2b-2 rule the store now enforces).
  seam.insert_node(row("n3", "t2", "proxmox-2")) |> should.be_ok
  // A second row with the same ID refuses too (node pkey).
  seam.insert_node(row("n1", "t2", "other")) |> should.be_error
  // An unknown thread refuses (node_thread_id_fkey).
  seam.insert_node(row("n4", "t-ghost", "other")) |> should.be_error
}

pub fn node_touch_and_revoke_test() {
  let seam = store_mock.seam(store_mock.start())
  seed_thread(seam, "t1")
  seam.insert_node(row("n1", "t1", "proxmox-2")) |> should.be_ok

  // Touch bumps last_seen_at from None (never connected) to a stamp.
  seam.touch_node("n1") |> should.be_ok
  let assert Ok(touched) = seam.get_thread_node("t1", "proxmox-2")
  should.be_true(case touched.last_seen_at {
    None -> False
    Some(_) -> True
  })

  // Revoke = hard delete: the name no longer resolves (token authority
  // gone).
  seam.delete_node("n1") |> should.be_ok
  seam.get_thread_node("t1", "proxmox-2") |> should.be_error
  seam.list_nodes() |> should.equal(Ok([]))
}

// ---------------------------------------------------------------------------
// Pairing grants (docs/plans/tui-pairing.md, Phase A)
// ---------------------------------------------------------------------------

pub fn grant_crud_roundtrip_test() {
  let seam = store_mock.seam(store_mock.start())
  // Unpinned: this test exercises row/touch/delete semantics, not the
  // thread pin (the FK makes a pinned seed need a REAL thread — that
  // round-trip is web_routes_test's, against a created thread; the
  // refusal itself is grant_thread_fk_refused_test).
  let #(code, grant) = node.mint_grant(None, 1_000_000)
  seam.insert_node_grant(grant) |> should.be_ok

  // Duplicate id errors (the pkey); codes are 256-bit random, so no
  // unique hash index exists to model.
  seam.insert_node_grant(grant) |> should.be_error

  // The list round-trips the whole row — including the Option shapes
  // (reserved unpinned thread, never-exchanged sentinel).
  let assert Ok([row]) = seam.list_node_grants()
  should.equal(row.id, grant.id)
  should.equal(row.code_hash, node.hash_token(code))
  should.equal(row.thread_id, None)
  should.equal(row.use_count, 0)
  should.equal(row.last_used_at, None)

  // Touch: use_count is a server-side increment (never lost counts),
  // last_used stamps; a MISSING id is a silent no-op (the SQL update
  // shape — best-effort diagnostics, never an error).
  seam.touch_node_grant("ghost") |> should.be_ok
  let before = timing.wall_now_s()
  seam.touch_node_grant(grant.id) |> should.be_ok
  seam.touch_node_grant(grant.id) |> should.be_ok
  let after = timing.wall_now_s()
  let assert Ok([stamped]) = seam.list_node_grants()
  should.equal(stamped.use_count, 2)
  // The stamp is the CURRENT time, not any post-1970 value (cubic
  // review): bounded by samples taken either side of the touches.
  case stamped.last_used_at {
    Some(at) -> {
      should.be_true(at >= before)
      should.be_true(at <= after)
    }
    None -> should.fail()
  }

  // Revoke: idempotent row delete, the node posture.
  seam.delete_node_grant(grant.id) |> should.be_ok
  seam.delete_node_grant(grant.id) |> should.be_ok
  seam.list_node_grants() |> should.equal(Ok([]))
}

/// The boot sweep's semantics: `expires_at < now()` deletes. No
/// exactly-at-boundary row here — the sweep samples the wall clock
/// itself (inside the mock), so a boundary row would race the test's
/// own `now` sample (cubic review); the exact window edge is pinned
/// by the PURE grant_live_window_test in node_test instead.
pub fn grant_expiry_sweep_test() {
  let seam = store_mock.seam(store_mock.start())
  let now = timing.wall_now_s()
  let grant_at = fn(id: String, expires_at: Int) {
    let #(_, grant) = node.mint_grant(None, expires_at - node.grant_ttl_s)
    node.Grant(..grant, id: id, expires_at: expires_at)
  }
  seam.insert_node_grant(grant_at("g-old", now - 60)) |> should.be_ok
  seam.insert_node_grant(grant_at("g-live", now + 60)) |> should.be_ok

  seam.delete_expired_node_grants() |> should.be_ok

  let assert Ok(rows) = seam.list_node_grants()
  rows
  |> list.map(fn(row) { row.id })
  |> should.equal(["g-live"])
}

/// node_grant_thread_id_fkey (cubic review): the mock models it like
/// the provider/bot FK checks above it — a pinned grant must reference
/// a stored thread, so the offline seam agrees with production
/// Postgres, which would refuse the same insert.
pub fn grant_thread_fk_refused_test() {
  let seam = store_mock.seam(store_mock.start())
  let #(_, pinned) = node.mint_grant(Some("t-ghost"), 1_000_000)
  seam.insert_node_grant(pinned) |> should.be_error
  // The reserved unpinned shape stays insertable.
  let #(_, unpinned) = node.mint_grant(None, 1_000_000)
  seam.insert_node_grant(unpinned) |> should.be_ok
}

/// The ''-sentinel contract for the reserved unpinned shape: a NULL
/// thread grant round-trips as None (squirrel decodes nullable text;
/// the mock agrees — no drift between the two seams).
pub fn grant_unpinned_thread_roundtrip_test() {
  let seam = store_mock.seam(store_mock.start())
  let #(_, grant) = node.mint_grant(None, 1_000_000)
  seam.insert_node_grant(grant) |> should.be_ok
  let assert Ok([row]) = seam.list_node_grants()
  should.equal(row.thread_id, None)
}

// ---------------------------------------------------------------------------
// Boot sweeps (tui-pairing plan, hygiene): persist.boot_sweeps over the
// mock seam — expired grants and idle node credentials are garbage, and
// NEXUS_NODE_IDLE_DAYS=0 disables the node half entirely.
// ---------------------------------------------------------------------------

fn sweep_config(node_idle_days: Int) -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
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
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
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
    env_timeout_ms: 60_000,
    env_max_output_bytes: 262_144,
    node_idle_days: node_idle_days,
    log_level: log.Info,
    max_bot_hops: 4,
  )
}

/// The full sweep: expired grants go, live grants stay; nodes past the
/// idle window go (never-connected rows from created_at, connected rows
/// from last_seen), fresh ones stay. The swept NAMES come back for the
/// boot log.
pub fn boot_sweeps_take_expired_grants_and_idle_nodes_test() {
  let seam = store_mock.seam(store_mock.start())
  let now = timing.wall_now_s()
  // mint_grant stamps expires_at = now_s + ttl, so the row helper
  // overrides it explicitly (the grant_expiry_sweep_test pattern).
  let grant_at = fn(id: String, expires_at: Int) {
    let #(_, grant) = node.mint_grant(None, expires_at - node.grant_ttl_s)
    node.Grant(..grant, id: id, expires_at: expires_at)
  }
  let expired = grant_at("g-expired", now - 60)
  let #(_, live) = node.mint_grant(None, now + 60)
  seam.insert_node_grant(expired) |> should.be_ok
  seam.insert_node_grant(live) |> should.be_ok
  // Old-node: never connected, created 8d ago; stale-node: connected,
  // last seen 10d ago; fresh-node: connected 1h ago. All bound to one
  // seeded thread (the row's thread FK).
  seed_thread(seam, "t1")
  let node_at = fn(id: String, name: String, created: Int, seen: Option(Int)) {
    node.Node(
      id: id,
      thread_id: "t1",
      name: name,
      token_hash: "aabbcc",
      created_at: created,
      last_seen_at: seen,
    )
  }
  seam.insert_node(node_at("n-old", "old-host", now - 8 * 86_400, None))
  |> should.be_ok
  seam.insert_node(node_at(
    "n-stale",
    "stale-host",
    now - 30 * 86_400,
    Some(now - 10 * 86_400),
  ))
  |> should.be_ok
  seam.insert_node(node_at(
    "n-fresh",
    "fresh-host",
    now - 7200,
    Some(now - 3600),
  ))
  |> should.be_ok

  persist.boot_sweeps(sweep_config(7), seam)

  let assert Ok(grants) = seam.list_node_grants()
  grants
  |> list.map(fn(g) { g.id })
  |> should.equal([live.id])
  let assert Ok(nodes) = seam.list_nodes()
  nodes |> list.map(fn(n) { n.name }) |> should.equal(["fresh-host"])
}

/// `NEXUS_NODE_IDLE_DAYS=0` disables the node sweep only — expired
/// grants still go (pure garbage, no config in front of them).
pub fn boot_sweeps_zero_idle_days_disables_node_sweep_test() {
  let seam = store_mock.seam(store_mock.start())
  let now = timing.wall_now_s()
  let grant_at = fn(id: String, expires_at: Int) {
    let #(_, grant) = node.mint_grant(None, expires_at - node.grant_ttl_s)
    node.Grant(..grant, id: id, expires_at: expires_at)
  }
  let expired = grant_at("g-expired", now - 60)
  seam.insert_node_grant(expired) |> should.be_ok
  seed_thread(seam, "t1")
  let stale =
    node.Node(
      id: "n-ancient",
      thread_id: "t1",
      name: "ancient-host",
      token_hash: "aabbcc",
      created_at: now - 400 * 86_400,
      last_seen_at: Some(now - 400 * 86_400),
    )
  seam.insert_node(stale) |> should.be_ok

  persist.boot_sweeps(sweep_config(0), seam)

  let assert Ok(grants) = seam.list_node_grants()
  grants |> should.equal([])
  let assert Ok(nodes) = seam.list_nodes()
  nodes |> list.map(fn(n) { n.name }) |> should.equal(["ancient-host"])
}
