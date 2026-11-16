-- One node row by NAME (the stateless token-verification lookup key).
select
  id,
  name,
  token_hash,
  extract(epoch from created_at)::int8 as created_s,
  coalesce(extract(epoch from last_seen_at)::int8, 0) as last_seen_s
from node
where name = $1
