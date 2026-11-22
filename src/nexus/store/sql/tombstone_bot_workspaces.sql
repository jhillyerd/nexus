-- Tombstone any live shared bot workspace owned by this bot that no thread
-- currently references, clearing bot_id = NULL so the subsequent DELETE FROM
-- bot triggers no overlapping ON DELETE SET NULL update. Bot workspaces
-- still referenced by any thread remain live so deleting the bot clears
-- bot_id and lets the last referencing thread's delete tombstone them.
update workspace w
set deleted_at = now(),
    bot_id = null
where w.kind = 'bot'
  and w.bot_id = $1
  and w.deleted_at is null
  and not exists (
    select 1 from thread t
    where t.workspace_id = w.id
  )
returning w.id, w.root, w.rel_path
