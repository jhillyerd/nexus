//// Pure node domain tests (docs/plans/environments.md, Phase 2b): token
//// hashing/verification (one-way, constant-time, revocable) and the
//// name gate. Offline: no store, no actor — pure functions only.

import gleam/list
import gleam/option.{None, Some}
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
  // The KNOWN SHA-256 digest, hex (base16_encode = binary:encode_hex
  // emits UPPERCASE on the BEAM) — pins both the algorithm (SHA-256,
  // not a weaker one) and the encoding, so a regression in either fails.
  should.equal(
    h,
    "930BBDC51B6AED5C2A5678FD6E28DEE7A05E8A4B643CFC0B4427C3EFB86C0D94",
  )
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

// ---------------------------------------------------------------------------
// Pairing grants (docs/plans/tui-pairing.md, Phase A)
// ---------------------------------------------------------------------------

pub fn mint_grant_shape_test() {
  let #(code, grant) = node.mint_grant(Some("t-1"), 1_700_000_000)
  // The code is a full 256-bit URL-safe base64 token (43 chars, no
  // padding): copy-paste carries it, nobody types it. The FULL
  // alphabet is checked per character (cubic review), not just the
  // absence of the three forbidden separators.
  should.equal(string.length(code), 43)
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  should.be_true(
    code
    |> string.to_graphemes
    |> list.all(fn(ch) { string.contains(alphabet, ch) }),
  )
  should.be_false(string.contains(code, "+"))
  should.be_false(string.contains(code, "/"))
  should.be_false(string.contains(code, "="))
  // The row: id prefix, hash-only storage, pinned thread, the TTL
  // window, and untouched diagnostics.
  should.be_true(string.starts_with(grant.id, "g"))
  should.equal(grant.code_hash, node.hash_token(code))
  should.equal(grant.thread_id, Some("t-1"))
  should.equal(grant.created_at, 1_700_000_000)
  should.equal(grant.expires_at, 1_700_000_000 + node.grant_ttl_s)
  should.equal(node.grant_ttl_s, 3600)
  should.equal(grant.use_count, 0)
  should.equal(grant.last_used_at, None)
}

pub fn mint_grant_codes_are_unique_test() {
  let #(code_a, grant_a) = node.mint_grant(None, 5)
  let #(code_b, grant_b) = node.mint_grant(None, 5)
  should.be_false(code_a == code_b)
  should.be_false(grant_a.id == grant_b.id)
  // The reserved unpinned shape: NULL thread passes through verbatim
  // (the future TUI-chooses-its-thread door, no extra work).
  should.equal(grant_a.thread_id, None)
}

pub fn grant_live_window_test() {
  let #(_, grant) = node.mint_grant(None, 1000)
  // The window check guards the EXPIRY side only (`now < expires_at`):
  // live at the mint instant, live one second before the boundary,
  // dead AT it. There is no not-yet-live arm — a code cannot be
  // presented before it exists.
  should.be_true(node.grant_live(grant, 1000))
  should.be_true(node.grant_live(grant, 1000 + node.grant_ttl_s - 1))
  should.be_false(node.grant_live(grant, 1000 + node.grant_ttl_s))
}

pub fn grant_code_verifies_like_a_token_test() {
  let #(code, grant) = node.mint_grant(None, 0)
  // The SAME constant-time verify as node tokens — one hashing rule,
  // no drift: hash-only storage, re-hash + secure_compare at check.
  should.be_true(node.verify_token(code, grant.code_hash))
  should.be_false(node.verify_token("wrong-code", grant.code_hash))
  should.be_false(node.verify_token("", grant.code_hash))
}
