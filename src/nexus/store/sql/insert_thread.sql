-- A new thread row: created/last_active from the registry's epoch
-- seconds; message_count is the transcript length (1 = system prompt).
-- provider_id is frozen at creation with the model (contract rule 2).
-- bot_id is provenance only (bots plan P1): the '' sentinel inserts
-- NULL (see insert_bot.sql) — a thread created without a bot.
-- tags_manual is '{}' literally and tags_source is left to its column
-- default 'auto' (utility-tags plan §3.5): a new thread has no tags and
-- an open auto path.
insert into thread (id, provider_id, title, title_source, model, system_prompt, pinned, tags, tags_manual, created_at, last_active_at, message_count, bot_id)
values ($1, $2, $3, $4, $5, $6, $7, $8, '{}', to_timestamp($9), to_timestamp($9), $10, nullif($11, ''))
