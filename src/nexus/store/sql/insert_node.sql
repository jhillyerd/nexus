-- A new node row (environments plan Phase 2b): the remote paired-TUI
-- node entity. `token_hash` is the SHA-256 digest of the bearer token
-- (nexus/node.gleam) — NEVER the plaintext. `last_seen_at` is
-- to_timestamp(nullif($5, 0)): the 0 sentinel — a fresh pair has never
-- connected, so the column is NULL.
insert into node (id, name, token_hash, created_at, last_seen_at)
values ($1, $2, $3, to_timestamp($4), to_timestamp(nullif($5, 0::bigint)))
