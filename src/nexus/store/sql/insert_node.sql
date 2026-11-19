-- A new node row (environments plan Phase 2b): the remote paired-TUI
-- node entity. Per-thread names (environments 2b-2): the row is bound
-- to its thread — the roster it serves — and (thread_id, name) is the
-- node identity (node_thread_name UNIQUE). `token_hash` is the SHA-256
-- digest of the bearer token (nexus/node.gleam) — NEVER the plaintext.
-- `last_seen_at` is to_timestamp(nullif($5, 0)): the 0 sentinel — a
-- fresh pair has never connected, so the column is NULL.
insert into node (id, thread_id, name, token_hash, created_at, last_seen_at)
values ($1, $2, $3, $4, to_timestamp($5), to_timestamp(nullif($6, 0::bigint)))
