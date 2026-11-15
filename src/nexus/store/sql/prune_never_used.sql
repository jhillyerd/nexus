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
-- env thread would never be swept, cubic PR review), never titled
-- (title_source 'auto'; a manual rename is intent and survives), never
-- pinned (also intent). Archived or not: an archived empty is still
-- litter.
--
-- The grace window protects a thread another concurrently-running
-- server created moments ago and still holds live — it stays empty
-- until its first turn commits. 15 minutes is far past any first turn.
delete from thread
where (message_count <= 1 or (workspace_root is not null and message_count <= 2))
  and title_source = 'auto'
  and pinned = false
  and last_active_at < now() - interval '15 minutes'
returning id
