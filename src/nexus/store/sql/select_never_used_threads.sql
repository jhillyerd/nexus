-- Select never-used threads older than the 15-minute grace window for boot
-- pruning, locking matching rows for update inside the caller's transaction.
-- Parents with channel children are excluded so CASCADE cannot take a
-- child's committed history.
select id
from thread
where (message_count <= 1 or (workspace_root is not null and message_count <= 2))
  and title_source = 'auto'
  and pinned = false
  and last_active_at < now() - interval '15 minutes'
  and not exists (
    select 1 from thread c where c.parent_thread_id = thread.id
  )
order by id
for update
