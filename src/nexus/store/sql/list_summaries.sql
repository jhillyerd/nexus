-- All stored thread summaries, ordered by id (the registry re-sorts).
-- The provenance columns ride along (utility-tags plan §3.5): the boot
-- load must never lack them. bot_id is the bots plan's provenance
-- pointer (NULL = created without a bot); toolset is the frozen
-- toolset manifest (plugin-api plan Phase 2), aggregated in seq order
-- as ONE json text — the entries a dormant thread rehydrates its
-- runner bundle from, without contacting any server.
select
  id,
  provider_id,
  title,
  title_source,
  model,
  pinned,
  (archived_at is not null) as archived,
  tags,
  tags_manual,
  tags_source,
  (select coalesce(json_agg(row_to_json(e) order by e.seq), '[]'::json)::text
     from thread_toolset e
    where e.thread_id = thread.id) as toolset,
  bot_id,
  workspace_root,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from thread
order by id
