-- Full-metadata bot update (the registry merges the PATCH onto the row
-- first, so this is a plain replace). `system_prompt` rides the ''
-- sentinel for NULL = global default (see insert_bot.sql). `tools` rides
-- the same two-parameter scheme as the insert: $7 is the explicit list
-- ('{}' = chat-only), $8 the is-default flag (true = NULL = the current
-- default set). `allow_inbound` (bots plan P3a) is the merged row's gate.
-- `updated_at` is server-side now(), like the provider/thread metadata
-- writes.
update bot set
  name = $2,
  description = $3,
  provider_id = $4,
  model = $5,
  system_prompt = nullif($6, ''),
  tools = case when $8::boolean then null else $7::text[] end,
  allow_inbound = $9::boolean,
  updated_at = now()
where id = $1
