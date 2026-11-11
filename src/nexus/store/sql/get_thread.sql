-- One stored thread row (lazy hydration of a dormant thread). The
-- provenance columns ride along (utility-tags plan §3.5): rehydration
-- must never lack them. bot_id is the bots plan's provenance pointer
-- (NULL = created without a bot; display only, never request bytes).
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
  bot_id,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from thread
where id = $1
