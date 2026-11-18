-- All pairing grant rows (id-ordered, the list_nodes shape). The
-- exchange scans these against a presented code with the constant-time
-- verify (grants are few — one-hour rows), and the info pane / e2e
-- read the same list. No secrets ride the select: the code HASH is
-- public by nature, the plaintext never rests.
select
  id,
  code_hash,
  thread_id,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from expires_at)::int8 as expires_s,
  use_count,
  coalesce(extract(epoch from last_used_at)::int8, 0) as last_used_s
from node_grant
order by id
