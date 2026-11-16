//// Offline node-store tests (docs/plans/environments.md, Phase 2b).
////
//// The `node` table's seam contract against the in-memory mock: pair
//// (insert), stateless verification lookup (get-by-name), boot load
//// (list), recency bump (touch), revoke (delete), and the unique-name
//// constraint. The pog-backed implementation is drift-gated in CI by
//// `squirrel check`; these pin the seam's SEMANTICS, not the SQL.

import gleam/option.{None, Some}
import gleeunit/should
import nexus/node
import nexus/store
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
