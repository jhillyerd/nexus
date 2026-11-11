-- Hard delete of an unreferenced provider. While any thread or bot
-- pins it, the thread_provider_id / bot.provider_id FKs (ON DELETE
-- RESTRICT) refuse the delete — the registry's count-based 409
-- pre-check is the friendly copy of that guard, this is the
-- enforcement.
delete from provider where id = $1
