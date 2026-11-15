//// Pure node domain tests (docs/plans/environments.md, Phase 2b): token
//// hashing/verification (one-way, constant-time, revocable) and the
//// name gate. Offline: no store, no actor — pure functions only.

import gleam/string
import gleeunit/should
import nexus/node

pub fn valid_name_charset_test() {
  let assert Ok("proxmox-2") = node.valid_name("proxmox-2")
  let assert Ok("node_a_1") = node.valid_name("  node_a_1  ")
  // Reserved: workspace is the thread's own environment.
  let assert Error(_) = node.valid_name("workspace")
  // Empty and charset violations refuse loudly.
  let assert Error(_) = node.valid_name("")
  let assert Error(_) = node.valid_name("   ")
  let assert Error(_) = node.valid_name("bad name")
  let assert Error(_) = node.valid_name("bad/name")
  // `__` is ALLOWED: it is the tool half-name separator, not a node-name
  // rule — a node name is a target string, never a qualified tool name.
  let assert Ok("a__b") = node.valid_name("a__b")
}

pub fn hash_token_is_hex_sha256_test() {
  let h = node.hash_token("secret-token")
  // 64 hex chars = 32 bytes.
  should.equal(string.length(h), 64)
  // Deterministic.
  should.equal(node.hash_token("secret-token"), h)
  // Distinct inputs, distinct digests.
  should.be_false(node.hash_token("secret-token") == node.hash_token("other"))
}

pub fn verify_token_roundtrip_test() {
  let h = node.hash_token("the-bearer")
  should.be_true(node.verify_token("the-bearer", h))
  should.be_false(node.verify_token("wrong", h))
  should.be_false(node.verify_token("", h))
}

pub fn verify_token_rejects_tampered_or_malformed_hash_test() {
  let h = node.hash_token("the-bearer")
  // A flipped nibble in the stored hash fails (constant-time compare on
  // the decoded bytes).
  let tampered = case h {
    "0" <> rest -> "1" <> rest
    other -> "0" <> string.drop_start(other, up_to: 1)
  }
  should.be_false(node.verify_token("the-bearer", tampered))
  // A non-hex stored hash refuses rather than crashing.
  should.be_false(node.verify_token("the-bearer", "not-a-hex-hash"))
  // A wrong-length hash refuses.
  should.be_false(node.verify_token("the-bearer", "abcd"))
}
