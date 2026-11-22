-- Hard-delete a thread (and its cascaded bot-channel subtree) while
-- tombstoning every owned workspace row in ONE atomic statement
-- (docs/plans/workspace-sandbox.md, Phase 1).
--
-- Tombstoning clears workspace.thread_id = NULL BEFORE the DELETE so the
-- FK's ON DELETE SET NULL trigger does not conflict with this statement's
-- UPDATE, and the orphaned-bot-workspace check explicitly excludes the
-- subtree because sibling CTEs share the pre-DELETE snapshot.
with recursive subtree as (
  select id, workspace_id, tmp_workspace_id
  from thread
  where id = $1
  union all
  select child.id, child.workspace_id, child.tmp_workspace_id
  from thread child
  join subtree s on child.parent_thread_id = s.id
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
          w.thread_id in (select id from subtree)
          or w.id in (select workspace_id from subtree where workspace_id is not null)
          or w.id in (select tmp_workspace_id from subtree where tmp_workspace_id is not null)
        )
      )
      or (
        w.kind = 'bot'
        and w.bot_id is null
        and w.id in (select workspace_id from subtree where workspace_id is not null)
        and not exists (
          select 1 from thread t
          where t.workspace_id = w.id
            and t.id not in (select id from subtree)
        )
      )
    )
  returning w.id, w.root, w.rel_path
),
deleted as (
  delete from thread
  where id = $1
  returning id
)
select id, root, rel_path
from tombstoned
order by id
