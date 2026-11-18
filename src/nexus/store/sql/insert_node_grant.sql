-- A new pairing grant row (tui-pairing plan Phase A). `code_hash` is
-- the SHA-256 digest of the pairing code (nexus/node.gleam) — NEVER
-- the plaintext. `thread_id` uses the '' sentinel (the insert_bot /
-- insert_thread nullif pattern): v1 mints always pin a thread, NULL is
-- the reserved future unpinned shape. `last_used_at` rides the same
-- 0-sentinel convention as insert_node's last_seen_at: a fresh grant
-- has never been exchanged.
insert into node_grant (id, code_hash, thread_id, created_at, expires_at, use_count, last_used_at)
values ($1, $2, nullif($3, ''), to_timestamp($4), to_timestamp($5), $6, to_timestamp(nullif($7, 0::bigint)))
