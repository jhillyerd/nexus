-- All bot rows (registry boot load), ordered by id (the registry
-- re-sorts). Bots carry no secrets — the row IS the public shape.
-- `tools` (bots plan P2): NULL = the default set at thread-create time,
-- '{}' = chat-only, else the explicit list (see insert_bot.sql).
select
  id,
  name,
  description,
  provider_id,
  model,
  system_prompt,
  tools,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from bot
order by id
