-- Boot sweep: hard-delete never-used threads older than the grace
-- window, in ONE statement (bounded startup work — the registry runs
-- this inside its actor-initialiser deadline).
--
-- Never-used = holds nothing but the frozen system prompt
-- (message_count <= 1 — the same "no user message yet" rule the send
-- paths use for auto-titling) PLUS, for environment threads, the
-- creation-time roster row (workspace_root IS NOT NULL AND
-- message_count <= 2 — the row exists from creation and the first send
-- takes the count to >= 3; without the second arm an abandoned empty
-- env thread would never be swept), never titled
-- (title_source 'auto'; a manual rename is intent and survives), never
-- pinned (also intent). Archived or not: an archived empty is still
-- litter.
--
-- The grace window protects a thread another concurrently-running
-- server created moments ago and still holds live — it stays empty
-- until its first turn commits. 15 minutes is far past any first turn.
--
-- Parents with channel children are NEVER swept: the FK's CASCADE
-- would take the channels' committed history with them — a parent
-- looks never-used until its first turn commits, so a crash
-- mid-first-turn plus a restart after the grace window is exactly the
-- state where an old parent row still hangs a channel with durable
-- transcripts. The child check reads the same table CASCADE would
-- delete from.
-- Workspace tombstoning (docs/plans/workspace-sandbox.md, Phase 1): any
-- pruned thread's owned workspaces (and any orphaned bot workspace whose
-- last referencing thread is pruned) are tombstoned in the SAME statement
-- so the boot GC sweep removes their directories on disk.
with candidates as (
  select id, workspace_id, tmp_workspace_id
  from thread
  where (message_count <= 1 or (workspace_root is not null and message_count <= 2))
    and title_source = 'auto'
    and pinned = false
    and last_active_at < now() - interval '15 minutes'
    and not exists (
      select 1 from thread c where c.parent_thread_id = thread.id
    )
),
tombstoned as (
  update workspace w
  set deleted_at = now(),
      thread_id = case when w.kind in ('thread', 'tmp') then null else w.thread_id end
  where w.deleted_at is null
    and (
      (
        w.kind in ('thread', 'tmp')
        and (
          w.thread_id in (select id from candidates)
          or w.id in (select workspace_id from candidates where workspace_id is not null)
          or w.id in (select tmp_workspace_id from candidates where tmp_workspace_id is not null)
        )
      )
      or (
        w.kind = 'bot'
        and w.bot_id is null
        and w.id in (select workspace_id from candidates where workspace_id is not null)
        and not exists (
          select 1 from thread t
          where t.workspace_id = w.id
            and t.id not in (select id from candidates)
        )
      )
    )
  returning w.id
),
deleted as (
  delete from thread
  where id in (select id from candidates)
  returning id
)
select id from deleted
