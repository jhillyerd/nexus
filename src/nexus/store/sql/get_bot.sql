-- One bot row by id. `Error` for unknown ids is decided by the caller
-- from the empty result. `tools` (bots plan P2): NULL = the default set
-- at thread-create time, '{}' = chat-only, else the explicit list (see
-- insert_bot.sql).
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
where id = $1
