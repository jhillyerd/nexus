-- One stored thread row (lazy hydration of a dormant thread). The
-- provenance columns ride along (utility-tags plan §3.5): rehydration
-- must never lack them. bot_id is the bots plan's provenance pointer
-- (NULL = created without a bot; display only, never request bytes).
-- toolset is the frozen toolset manifest (plugin-api plan Phase 2),
-- aggregated in seq order as ONE json text (a transport encoding; the
-- stored columns are TEXT — see thread_toolset in schema.sql): the
-- ordered entries hydration replays through the config-independent
-- catalog ∪ foreign mounts, NEVER contacting the server.
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
  (select coalesce(json_agg(row_to_json(e) order by e.seq), '[]'::json)::text
     from thread_toolset e
    where e.thread_id = thread.id) as toolset,
  bot_id,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from thread
where id = $1
