-- All node rows (the pane's store read + GET /nodes), ordered by id.
-- Rows carry their thread: a node credential is bound to ONE thread
-- (per-thread node names, environments 2b-2) — consumers scope by it
-- (the info pane renders only the selected thread's rows).
select
  id,
  thread_id,
  name,
  token_hash,
  extract(epoch from created_at)::int8 as created_s,
  coalesce(extract(epoch from last_seen_at)::int8, 0) as last_seen_s
from node
order by id
