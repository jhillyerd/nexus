//// Pure node domain (docs/plans/environments.md, Phase 2b): the remote
//// paired-TUI-node entity and its token hashing. A node is a machine
//// running the nexus TUI client that dials OUT to nexus over WebSocket
//// and serves its machine as an environment target under a stable
//// user-assigned name.
////
//// The same module owns the PAIRING GRANT domain (docs/plans/
//// tui-pairing.md): the short-lived, multi-use invite the web UI mints
//// so a TUI host can exchange a code for a node credential WITHOUT the
//// UI token. Same rules, same shapes — the code is hashed exactly like
//// a token and answers exactly once, at mint.
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
//// row delete (a re-pair mints a fresh token + hash). Node NAMES are
//// unique per thread (the row carries its `thread_id`); the token's
//// OTHER authority stays instance-wide by design (v1 single-user),
//// scoped to node operations — per-thread grants grow on the
//// join-authorization seam when multi-user accounts exist.

import gleam/bit_array
import gleam/crypto
import gleam/option.{type Option}
import gleam/result
import gleam/string
import nexus/env

/// A stored node row — the whole entity (no secrets: the token HASH is
/// public by nature, the plaintext token never rests). `thread_id`
/// binds the credential to its thread: node names are unique PER
/// THREAD (the environments 2b-2 rule — two threads can host
/// same-named nodes; the per-thread execution maps and rosters already
/// route them independently), so (thread_id, name) is the node
/// identity, and the /node/ws auth lookup is scoped by it — a row
/// joins ONLY its own thread.
pub type Node {
  Node(
    id: String,
    thread_id: String,
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

// ---------------------------------------------------------------------------
// Pairing grants (docs/plans/tui-pairing.md)
// ---------------------------------------------------------------------------

/// A pairing grant's whole life: one hour, multi-use. Short enough that
/// a leaked URL dies quickly; long enough to launch several TUIs from
/// one mint (the review-locked decision — the code's ONLY job is
/// minting node credentials, so the window is the exposure).
pub const grant_ttl_s = 3600

/// A stored pairing grant row — the whole entity, no secrets (the code
/// HASH is public by nature, the plaintext never rests). `thread_id`
/// pins the grant to the issuing thread (v1 mints always pin); NULL is
/// the reserved future unpinned shape — door open, no extra work (the
/// review-locked decision). `use_count` / `last_used_at` are info-pane
/// diagnostics; there is no max_uses in v1.
pub type Grant {
  Grant(
    id: String,
    code_hash: String,
    thread_id: Option(String),
    created_at: Int,
    expires_at: Int,
    use_count: Int,
    last_used_at: Option(Int),
  )
}

/// Mint a fresh grant: the plaintext code (answered ONCE, at mint, to
/// the web UI that displays the pairing URL — never stored) and its
/// row (hash only). `now_s` is injected so the mint needs no clock of
/// its own — offline-testable; callers pass `timing.wall_now_s()`.
pub fn mint_grant(thread_id: Option(String), now_s: Int) -> #(String, Grant) {
  // The code is a bearer credential equivalent (for one hour) to the
  // UI token's minting authority: full 32 random bytes, URL-safe
  // base64 — copy-paste carries it, nobody types it.
  let code =
    crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
  let id =
    crypto.strong_random_bytes(8)
    |> bit_array.base16_encode
    |> string.lowercase
    |> fn(hex) { "g" <> hex }
  #(
    code,
    Grant(
      id: id,
      code_hash: hash_token(code),
      thread_id: thread_id,
      created_at: now_s,
      expires_at: now_s + grant_ttl_s,
      use_count: 0,
      last_used_at: option.None,
    ),
  )
}

/// Is this grant's window still open at `now_s`? The exchange's
/// expiry arm — checked beside the constant-time code verify so
/// expired and unknown codes answer identically (no oracle).
pub fn grant_live(grant: Grant, now_s: Int) -> Bool {
  now_s < grant.expires_at
}
