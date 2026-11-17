-- Archive ONE thread and CASCADE down its channel subtree (bot-channels
-- plan, #123): parent_thread_id makes channels of channels (hop chains),
-- and an archived parent cannot originate turns, so its whole descendant
-- tree goes quiescent with it. ONE idempotent recursive statement is the
-- authority — the registry syncs memory only from its acknowledged
-- outcome, so a failed write leaves nothing archived (in memory or on
-- disk). Archiving implicitly clears the pin everywhere it lands (the
-- `archived ⇒ ¬pinned` invariant). Retried on a transient failure, the
-- statement converges (already-archived rows just re-stamp).
with recursive tree as (
  select id from thread where id = $1
  union all
  select t.id from thread t join tree on t.parent_thread_id = tree.id
)
update thread set archived_at = now(), pinned = false
where id in (select id from tree)
