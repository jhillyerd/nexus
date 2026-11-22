-- Tombstone every owned workspace ('thread', 'tmp') belonging to the given
-- thread ids, plus any orphaned ('bot', bot_id IS NULL) workspace whose only
-- remaining referencing threads are in the same set. Clears thread_id = NULL
-- on owned rows so a subsequent DELETE FROM thread triggers no overlapping
-- ON DELETE SET NULL update on those rows.
update workspace w
set deleted_at = now(),
    thread_id = case when w.kind in ('thread', 'tmp') then null else w.thread_id end
where w.deleted_at is null
  and (
    (
      w.kind in ('thread', 'tmp')
      and (
        w.thread_id = any($1::text[])
        or w.id in (
          select workspace_id from thread where id = any($1::text[]) and workspace_id is not null
        )
        or w.id in (
          select tmp_workspace_id from thread where id = any($1::text[]) and tmp_workspace_id is not null
        )
      )
    )
    or (
      w.kind = 'bot'
      and w.bot_id is null
      and w.id in (
        select workspace_id from thread where id = any($1::text[]) and workspace_id is not null
      )
      and not exists (
        select 1 from thread t
        where t.workspace_id = w.id
          and not (t.id = any($1::text[]))
      )
    )
  )
returning w.id, w.root, w.rel_path
