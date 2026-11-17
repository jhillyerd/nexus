-- Unarchive ONE thread and its channel subtree (bot-channels plan,
-- #123) — the symmetric twin of archive.sql: restoring a parent restores
-- everything that cascade-archived with it (unambiguous today because
-- channels have no individual archive affordance). ONE idempotent
-- recursive statement, the same authority rule as archive.sql.
with recursive tree as (
  select id from thread where id = $1
  union all
  select t.id from thread t join tree on t.parent_thread_id = tree.id
)
update thread set archived_at = null
where id in (select id from tree)
