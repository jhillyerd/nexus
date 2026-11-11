-- Hard delete. No guard: `thread.bot_id` is ON DELETE SET NULL
-- (provenance only — a bot's threads are self-contained frozen columns),
-- so deleting a bot orphans nothing. The provider RESTRICT is the other
-- direction and lives on delete_provider.
delete from bot where id = $1
