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
  thread.id,
  thread.provider_id,
  thread.title,
  thread.title_source,
  thread.model,
  thread.system_prompt,
  thread.pinned,
  (thread.archived_at is not null) as archived,
  thread.tags,
  thread.tags_manual,
  thread.tags_source,
  (select coalesce(json_agg(row_to_json(e) order by e.seq), '[]'::json)::text
     from thread_toolset e
    where e.thread_id = thread.id) as toolset,
  thread.bot_id,
  thread.workspace_root,
  thread.workspace_id,
  coalesce(w.rel_path, '') as workspace_rel_path,
  thread.tmp_workspace_id,
  coalesce(tw.rel_path, '') as tmp_rel_path,
  thread.parent_thread_id,
  extract(epoch from thread.created_at)::int8 as created_s,
  extract(epoch from thread.last_active_at)::int8 as last_active_s,
  thread.message_count
from thread
left join workspace w on w.id = thread.workspace_id
left join workspace tw on tw.id = thread.tmp_workspace_id
where thread.id = $1
