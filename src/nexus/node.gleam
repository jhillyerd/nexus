//// Pure node domain (docs/plans/environments.md, Phase 2b): the remote
//// paired-TUI-node entity and its token hashing. A node is a machine
//// running the nexus TUI client that dials OUT to nexus over WebSocket
//// and serves its machine as an environment target under a stable
//// user-assigned name.
////
//// Like `nexus/bot` this module never touches the network, the store,
//// or an actor. The stored row carries NO secret material — only the
//// token HASH — so the stored row and the public shape are ONE type
//// (`Node`), shared verbatim by the store seam (the bots-plan one-type
//// rule, issue #75).
////
//// Token hashing is one-way (SHA-256 via the pinned `gleam_crypto`):
//// the plaintext bearer token is minted at pair time and handed to the
//// operator ONCE; only its digest is stored. Verification re-hashes the
//// presented token and compares in constant time (`secure_compare`), so
//// a stolen DB dump cannot mint a node connection, and a revoke is a
//// row delete (a re-pair mints a fresh token + hash). Token authority
//// is instance-wide by design (v1 single-user); per-thread grants grow
//// on the join-authorization seam when multi-user accounts exist.

import gleam/bit_array
import gleam/crypto
import gleam/option.{type Option}
import gleam/result
import gleam/string
import nexus/env

/// A stored node row — the whole entity (no secrets: the token HASH is
/// public by nature, the plaintext token never rests).
pub type Node {
  Node(
    id: String,
    name: String,
    token_hash: String,
    created_at: Int,
    last_seen_at: Option(Int),
  )
}

/// Validate a proposed node name. Trimmed non-empty, charset-checked,
/// and `workspace` reserved. The charset + reserved check DELEGATES to
/// `env.valid_target_name` (one rule, no drift): a node's name IS its
/// roster target name. The trim + return-the-trimmed-name shape mirrors
/// `bot.validate_name`.
pub fn valid_name(name: String) -> Result(String, String) {
  case string.trim(name) {
    "" -> Error("node name must not be empty")
    trimmed -> {
      use Nil <- result.try(env.valid_target_name(trimmed))
      Ok(trimmed)
    }
  }
}

/// Hash a bearer token to its stored form (hex SHA-256; the exact byte
/// case is base16-encode's — verification decodes case-insensitively).
pub fn hash_token(token: String) -> String {
  crypto.hash(crypto.Sha256, <<token:utf8>>) |> bit_array.base16_encode
}

/// Constant-time verify of a presented token against a stored hash.
pub fn verify_token(token: String, stored_hash: String) -> Bool {
  case bit_array.base16_decode(stored_hash) {
    Ok(stored) -> {
      let presented = crypto.hash(crypto.Sha256, <<token:utf8>>)
      crypto.secure_compare(presented, stored)
    }
    Error(_) -> False
  }
}
