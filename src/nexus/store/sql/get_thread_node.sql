-- One node row by (thread, NAME) — the stateless token-verification
-- lookup key (environments 2b-2's per-thread rule): the /node/ws
-- upgrade authenticates the (thread, name) pair, so a row joins ONLY
-- its own thread and the same name under another thread is a
-- DIFFERENT node (node_thread_name UNIQUE).
select
  id,
  thread_id,
  name,
  token_hash,
  extract(epoch from created_at)::int8 as created_s,
  coalesce(extract(epoch from last_seen_at)::int8, 0) as last_seen_s
from node
where thread_id = $1 and name = $2
