-- One stored session row (lazy hydration of a dormant session). The
-- provenance columns ride along (utility-tags plan §3.5): rehydration
-- must never lack them.
select
  id,
  provider_id,
  title,
  title_source,
  model,
  system_prompt,
  pinned,
  (archived_at is not null) as archived,
  tags,
  tags_manual,
  tags_source,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from session
where id = $1
