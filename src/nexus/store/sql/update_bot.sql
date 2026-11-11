-- Full-metadata bot update (the registry merges the PATCH onto the row
-- first, so this is a plain replace). `system_prompt` rides the ''
-- sentinel for NULL = global default (see insert_bot.sql). `updated_at`
-- is server-side now(), like the provider/thread metadata writes.
update bot set
  name = $2,
  description = $3,
  provider_id = $4,
  model = $5,
  system_prompt = nullif($6, ''),
  updated_at = now()
where id = $1
