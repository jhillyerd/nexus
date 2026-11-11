-- Hard delete. No guard: `thread.bot_id` is ON DELETE SET NULL
-- (provenance only — a bot's threads are self-contained frozen columns),
-- so deleting a bot orphans nothing. The provider RESTRICT is the other
-- direction: `bot.provider_id` is ON DELETE RESTRICT (sql/schema.sql),
-- and delete_provider's 409 pre-check mirrors it.
delete from bot where id = $1
