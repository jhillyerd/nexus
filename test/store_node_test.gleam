//// Offline node-store tests (docs/plans/environments.md, Phase 2b).
////
//// The `node` table's seam contract against the in-memory mock: pair
//// (insert), stateless verification lookup (get-by-name), boot load
//// (list), recency bump (touch), revoke (delete), and the unique-name
//// constraint. The pog-backed implementation is drift-gated in CI by
//// `squirrel check`; these pin the seam's SEMANTICS, not the SQL.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import nexus/node
import nexus/store
import nexus/timing
import store_mock

fn row(id: String, name: String) -> store.StoredNode {
  node.Node(
    id: id,
    name: name,
    token_hash: node.hash_token("token-" <> name),
    created_at: 1_700_000_000,
    last_seen_at: None,
  )
}

pub fn node_pair_and_verify_roundtrip_test() {
  let seam = store_mock.seam(store_mock.start())
  let n = row("n1", "proxmox-2")
  seam.insert_node(n) |> should.be_ok

  // Stateless verification: look up by NAME, check the token hash.
  let assert Ok(stored) = seam.get_node_by_name("proxmox-2")
  stored.id |> should.equal("n1")
  node.verify_token("token-proxmox-2", stored.token_hash) |> should.be_true
  node.verify_token("wrong", stored.token_hash) |> should.be_false

  // Unknown name refuses (no row to verify against).
  seam.get_node_by_name("ghost") |> should.be_error
}

/// `list_nodes` returns nodes id-sorted, NOT insertion-sorted: insert a
/// lexically-greater id first, then a lexically-lesser one, so an
/// insertion-order (unsorted) implementation yields the wrong sequence
/// and fails.
pub fn node_list_is_id_sorted_not_insertion_sorted_test() {
  let seam = store_mock.seam(store_mock.start())
  // Insertion order: n9, then n2. Lexical order: n2, then n9.
  seam.insert_node(row("n9", "zeta")) |> should.be_ok
  seam.insert_node(row("n2", "alpha")) |> should.be_ok
  let assert Ok(nodes) = seam.list_nodes()
  let assert [a, b] = nodes
  a.id |> should.equal("n2")
  b.id |> should.equal("n9")
}

pub fn node_name_is_unique_test() {
  let seam = store_mock.seam(store_mock.start())
  seam.insert_node(row("n1", "proxmox-2")) |> should.be_ok
  // A second row with the same NAME refuses (node_name UNIQUE).
  seam.insert_node(row("n2", "proxmox-2")) |> should.be_error
  // A second row with the same ID refuses too (node pkey).
  seam.insert_node(row("n1", "other")) |> should.be_error
}

pub fn node_touch_and_revoke_test() {
  let seam = store_mock.seam(store_mock.start())
  seam.insert_node(row("n1", "proxmox-2")) |> should.be_ok

  // Touch bumps last_seen_at from None (never connected) to a stamp.
  seam.touch_node("n1") |> should.be_ok
  let assert Ok(touched) = seam.get_node_by_name("proxmox-2")
  should.be_true(case touched.last_seen_at {
    None -> False
    Some(_) -> True
  })

  // Revoke = hard delete: the name no longer resolves (token authority
  // gone).
  seam.delete_node("n1") |> should.be_ok
  seam.get_node_by_name("proxmox-2") |> should.be_error
  seam.list_nodes() |> should.equal(Ok([]))
}

// ---------------------------------------------------------------------------
// Pairing grants (docs/plans/tui-pairing.md, Phase A)
// ---------------------------------------------------------------------------

pub fn grant_crud_roundtrip_test() {
  let seam = store_mock.seam(store_mock.start())
  let #(code, grant) = node.mint_grant(Some("t-1"), 1_000_000)
  seam.insert_node_grant(grant) |> should.be_ok

  // Duplicate id errors (the pkey); codes are 256-bit random, so no
  // unique hash index exists to model.
  seam.insert_node_grant(grant) |> should.be_error

  // The list round-trips the whole row — including the Option shapes
  // (pinned thread, never-exchanged sentinel).
  let assert Ok([row]) = seam.list_node_grants()
  should.equal(row.id, grant.id)
  should.equal(row.code_hash, node.hash_token(code))
  should.equal(row.thread_id, Some("t-1"))
  should.equal(row.use_count, 0)
  should.equal(row.last_used_at, None)

  // Touch: use_count is a server-side increment (never lost counts),
  // last_used stamps; a MISSING id is a silent no-op (the SQL update
  // shape — best-effort diagnostics, never an error).
  seam.touch_node_grant("ghost") |> should.be_ok
  seam.touch_node_grant(grant.id) |> should.be_ok
  seam.touch_node_grant(grant.id) |> should.be_ok
  let assert Ok([stamped]) = seam.list_node_grants()
  should.equal(stamped.use_count, 2)
  case stamped.last_used_at {
    Some(at) -> should.be_true(at >= 1_000_000)
    None -> should.fail()
  }

  // Revoke: idempotent row delete, the node posture.
  seam.delete_node_grant(grant.id) |> should.be_ok
  seam.delete_node_grant(grant.id) |> should.be_ok
  seam.list_node_grants() |> should.equal(Ok([]))
}

/// The boot sweep's semantics (Phase D wires the call): strictly
/// `expires_at < now` deletes — a grant expiring exactly NOW survives,
/// matching delete_expired_node_grants.sql.
pub fn grant_expiry_sweep_test() {
  let seam = store_mock.seam(store_mock.start())
  let now = timing.wall_now_s()
  let grant_at = fn(id: String, expires_at: Int) {
    let #(_, grant) = node.mint_grant(None, expires_at - node.grant_ttl_s)
    node.Grant(..grant, id: id, expires_at: expires_at)
  }
  seam.insert_node_grant(grant_at("g-old", now - 1)) |> should.be_ok
  seam.insert_node_grant(grant_at("g-now", now)) |> should.be_ok
  seam.insert_node_grant(grant_at("g-live", now + 60)) |> should.be_ok

  seam.delete_expired_node_grants() |> should.be_ok

  let assert Ok(rows) = seam.list_node_grants()
  rows
  |> list.map(fn(row) { row.id })
  |> should.equal(["g-live", "g-now"])
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
